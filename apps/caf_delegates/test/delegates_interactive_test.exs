defmodule CodingAgentFramework.DelegatesInteractiveTest do
  @moduledoc """
  An interactive delegate (`interactive: true`, F-137) over a real `Sessions`, `Inlet`,
  `Registry`, `Transcripts` and `Mailbox`, real dtach and tmux, a real git repository in this
  test's own directory, and the screen stand-in for Claude Code, which draws 2.1.322's trust
  dialog first. The test writes the transcript lines Claude Code would. Each test names the
  `Delegate.tla` and `Delivery.tla` steps it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Delegates, Grants, Inlet, Mailbox, ScreenStandIn}
  alias CodingAgentFramework.{Sessions, SessionsSetup, Transcripts, Usage}
  alias CodingAgentFramework.Delegates.Table
  alias CodingAgentFramework.Sessions.Agents

  setup {SessionsSetup, :sessions}

  setup ctx do
    repo = Path.join(ctx.dir, "repo")
    git!(ctx, ["init", "-q", "-b", "main", repo])
    commit = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]
    git!(ctx, commit ++ ["--allow-empty"])

    {:ok, accounts} = Accounts.new(Path.join(ctx.dir, "home"), ["work"])
    {:ok, file} = Accounts.usage_file(accounts, "work")
    File.mkdir_p!(Path.dirname(file))
    week = %{"seven_day" => %{"used_percentage" => 25, "resets_at" => 4_000_000_000}}
    File.write!(file, JSON.encode!(%{"rate_limits" => week}))
    db = Path.join(ctx.dir, "caf.db")
    usage = start_supervised!({Usage, accounts: accounts, host: "test", db: db})
    {:ok, _} = Usage.read(usage)

    transcripts =
      start_supervised!({Transcripts, programs: programs(), accounts: ["work"], db: db})

    # A Sessions that answers an interactive start's trust dialog through the Inlet.
    inlet = start_supervised!({Inlet, tmux: ctx.server})

    sessions =
      start_supervised!(
        Supervisor.child_spec({Sessions, ctx.opts ++ [inlet: inlet]}, id: :trusting)
      )

    project = %{
      name: "app",
      repo: repo,
      trunk: "main",
      setup: [],
      setup_timeout: 10_000,
      env: %{"HOME" => ctx.dir},
      branches: ~r/\Aunit\//,
      cap: 1
    }

    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), trust: true)
    launch = SessionsSetup.launch(ctx, :at_start) |> Keyword.take([:env, :tool_timeout])

    {:ok, agents} = Agents.open(db, "test")
    tree = fn -> [%{name: "main", project: "app", parent: nil} | Agents.read_tree(agents)] end

    mopts = [
      db: db,
      grants: Grants.new(tree),
      stream: ctx.stream,
      sessions_db: db,
      host: "test",
      intake: start_supervised!(CodingAgentFramework.DelegatesInteractiveTest.NoWaiter),
      transcripts: transcripts,
      accounts: accounts
    ]

    mailbox = start_supervised!(Supervisor.child_spec({Mailbox, mopts}, id: make_ref()))

    opts = [
      host: "test",
      db: db,
      sessions_db: db,
      sessions: sessions,
      stream: ctx.stream,
      usage: usage,
      accounts: accounts,
      transcripts: transcripts,
      registry: ctx.registry,
      mailbox: mailbox,
      launch: [claude: claude] ++ launch,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      projects: %{"app" => project}
    ]

    delegates = start_supervised!(Supervisor.child_spec({Delegates, opts}, restart: :temporary))
    {:ok, dtable} = Table.open(db)

    {:ok,
     delegates: delegates, dtable: dtable, agents: agents, mailbox: mailbox, accounts: accounts}
  end

  # StartAsked with the brief marked by launch, the start carrying it as its prompt, the trust
  # dialog answered by label; then ReportAnswersTheBrief: the report is the reply of the turn
  # the brief began, not a later turn's, which a person's prompt gave.
  test "its brief is its start's prompt, and its report the reply to the brief", ctx do
    assert {:ok, %{id: id, name: name, brief_uuid: u, session_id: sid}} =
             Delegates.start_delegate(
               ctx.delegates,
               "main",
               "app",
               "unit/one",
               "opus",
               "Review it.",
               interactive: true
             )

    # Interactive: the terminal interface (role parent), a delegate of its parent.
    assert %{role: "parent", kind: "delegate", parent: "main", cwd: cwd} =
             Agents.get(ctx.agents, name)

    assert File.exists?(Path.join(ctx.dir, "trusted"))
    text = "Review it.\n\n[delivery #{u}]"
    assert {:ok, [^text]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    assert {:ok, %{kind: "brief", via: "launch"}} = brief(ctx, u)

    # Claude Code's lines: the brief's turn and its reply, then a person's turn and its reply.
    {:ok, dir} = Accounts.config_dir(ctx.accounts, "work")
    {:ok, path} = Transcripts.path(dir, cwd, sid)

    lines(path, [
      user(text),
      reply("m1", "Done."),
      user("And something else?"),
      reply("m2", "Other.")
    ])

    assert {:ok, %{status: "finished", text: "Done.", report: "taken"}} =
             cue_until(ctx, id, &(&1.status == "finished" and &1.report == "taken"))

    assert {:ok, %{status: "delivered"}} = brief(ctx, u)
    assert {:ok, %{kind: "reply", from: ^name, to: "main"}} = Mailbox.answer_to(ctx.mailbox, u)
  end

  # An interactive start needs a brief its argument can carry.
  test "a brief longer than a launch carries is refused before anything starts", ctx do
    long = String.duplicate("a", 600_000)

    assert {:refused, {:too_long, _}} =
             Delegates.start_delegate(ctx.delegates, "main", "app", "unit/one", "opus", long,
               interactive: true
             )

    assert Table.latest(ctx.dtable, "test") == []
  end

  defp brief(ctx, u) do
    await(fn ->
      Mailbox.cue(ctx.mailbox, %{topic: "transcripts:test:work", ids: []})

      case Enum.find(
             Enum.map(1..20, &Mailbox.status(ctx.mailbox, &1)),
             &match?({:ok, %{kind: "brief"}}, &1)
           ) do
        {:ok, %{}} = found -> if uuid_of(ctx, found) == u, do: found, else: :other
        nil -> :none
      end
    end)
  end

  defp uuid_of(ctx, {:ok, %{id: id}}) do
    {:ok, mtable} = Mailbox.Table.open(Path.join(ctx.dir, "caf.db"))
    Mailbox.Table.get(mtable, id).uuid
  end

  defp user(text), do: %{"type" => "user", "message" => %{"content" => text}}

  defp reply(id, text) do
    content = [%{"type" => "text", "text" => text}]

    %{
      "type" => "assistant",
      "message" => %{"id" => id, "stop_reason" => "end_turn", "content" => content}
    }
  end

  defp lines(path, entries) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map(entries, &[JSON.encode!(&1), "\n"]), [:append])
  end

  defp nonempty([]), do: :empty
  defp nonempty(list), do: {:ok, list}

  defp cue_until(ctx, id, ready?) do
    await(
      fn ->
        Delegates.cue(ctx.delegates, %{topic: "transcripts:test:work"})
        Mailbox.cue(ctx.mailbox, %{topic: "transcripts:test:work", ids: []})
        row = Table.get(ctx.dtable, id)
        if row && ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end

  defp git!(ctx, args) do
    {out, status} =
      System.cmd(program!(:env), ["-i", "HOME=#{ctx.dir}", program!(:git) | args],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("git #{inspect(args)}: #{out}")
    out
  end
end

defmodule CodingAgentFramework.DelegatesInteractiveTest.NoWaiter do
  @moduledoc false
  # Plays `Intake` with no waiter held: the brief goes by launch, and the report waits.
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:waiter?, _account, _session}, _from, s), do: {:reply, {:ok, false}, s}
end
