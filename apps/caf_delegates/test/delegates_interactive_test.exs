defmodule CodingAgentFramework.DelegatesInteractiveTest do
  @moduledoc """
  An interactive delegate (`interactive: true`, F-137) over a real `Sessions`, `Inlet`,
  `Registry`, `Transcripts` and `Mailbox`, real dtach and tmux, a real git repository in this
  test's own directory, and the screen stand-in for Claude Code, which draws 2.1.322's trust
  dialog first, which this test's app answers. The test writes the transcript lines Claude Code would. Each test names the
  `Delegate.tla` and `Delivery.tla` steps it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Delegates, Grants, Inlet, Intake, Mailbox}
  alias CodingAgentFramework.ScreenStandIn
  alias CodingAgentFramework.{Sessions, SessionsSetup, Transcripts, Usage}
  alias CodingAgentFramework.Delegates.{Table, Turn}
  alias CodingAgentFramework.Sessions.Agents
  alias CodingAgentFramework.Sessions.Turn, as: SessionsTurn

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

    # A Sessions whose app chose to answer the trust dialog (F-140's `dialog:` callback); by
    # default nothing answers it, and a person does.
    inlet = start_supervised!({Inlet, tmux: ctx.server})
    trust = fn :trust, _ -> {:answer, "Yes, I trust this folder"} end
    trusting = ctx.opts ++ [inlet: inlet, dialog: trust]
    sessions = start_supervised!(Supervisor.child_spec({Sessions, trusting}, id: :trusting))

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
      projects: %{"app" => project},
      inlet: inlet,
      intake: start_supervised!({Intake, db: db, host: "test"}),
      intake_db: db
    ]

    delegates = start_supervised!(Supervisor.child_spec({Delegates, opts}, restart: :temporary))
    {:ok, dtable} = Table.open(db)

    {:ok,
     delegates: delegates,
     dopts: opts,
     dtable: dtable,
     agents: agents,
     mailbox: mailbox,
     accounts: accounts,
     intake: opts[:intake]}
  end

  # F-137's new-3: a parent's fixes reach an interactive delegate as they reach a main session.
  # Its permission request is the PermissionRequest Intake holds, and the answer goes there;
  # its interrupt is Escape through the Inlet, which presses nothing while no turn runs.
  test "a parent's answer and interrupt reach an interactive delegate", ctx do
    assert {:ok, %{name: name, session_id: sid}} =
             Delegates.start_delegate(
               ctx.delegates,
               "main",
               "app",
               "unit/two",
               "opus",
               "Review it.",
               interactive: true
             )

    {:ok, _} = await(fn -> if ScreenStandIn.prompts(ctx.dir) != [], do: {:ok, 1} end)
    {:ok, %{held: []}} = Delegates.fix_state(ctx.delegates, "main", name)

    body = %{"hook_event_name" => "PermissionRequest", "session_id" => sid, "tool_use_id" => "t1"}
    me = self()

    hold =
      Task.async(fn ->
        # The holder, as `Intake.Plug` is: it writes the decision, then says so.
        {:ok, {:held, held, ref, _wait}} = Intake.post(ctx.intake, "work", JSON.encode!(body))
        send(me, :held)

        receive do
          {^ref, {:decision, text}} ->
            Intake.written(ctx.intake, held, ref)
            {:decision, text}
        after
          10_000 -> :none
        end
      end)

    assert_receive :held, 5_000
    assert {:ok, %{held: [id]} = state} = Delegates.fix_state(ctx.delegates, "main", name)

    assert {:refused, {:not_held, "0"}} =
             Delegates.fix(ctx.delegates, "main", name, {:answer, "0", "allow"}, state)

    assert {:ok, :sent} =
             Delegates.fix(ctx.delegates, "main", name, {:answer, id, "allow"}, state)

    assert {:decision, decision} = Task.await(hold)
    assert decision =~ "allow"

    # The answer moved its state: a fix of the old one acts nothing.
    assert {:refused, {:moved, _}} = Delegates.fix(ctx.delegates, "main", name, :interrupt, state)
    {:ok, now} = Delegates.fix_state(ctx.delegates, "main", name)

    assert {:refused, {:screen, %{state: :idle}}} =
             Delegates.fix(ctx.delegates, "main", name, :interrupt, now)
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

    before = %{"type" => "summary", "summary" => "A line before the brief."}

    lines(path, [
      before,
      user(text),
      reply("m1", "Done."),
      user("And something else?"),
      reply("m2", "Other.")
    ])

    assert {:ok, %{status: "finished", text: "Done.", report: "taken"}} =
             cue_until(ctx, id, &(&1.status == "finished" and &1.report == "taken"))

    # F-137's new-4: the brief's marked line, once found, is read from its offset.
    at = byte_size(JSON.encode!(before)) + 1
    assert %{{^sid, ^u} => ^at} = :sys.get_state(ctx.delegates).marks

    assert {:ok, %{status: "delivered"}} = brief(ctx, u)
    assert {:ok, %{kind: "reply", from: ^name, to: "main"}} = Mailbox.answer_to(ctx.mailbox, u)
  end

  # Delegate.tla's OwnWakes, OwnTurnEnds and TurnTold for an interactive delegate (F-155): a turn
  # a background command of its own began is told to its parent once, by its reply's uuid; a
  # row the framework delivered and a person's turn are not its own, and none is the report.
  test "an interactive delegate's turn of its own after its report is told once", ctx do
    assert {:ok, %{id: id, name: name, brief_uuid: u, session_id: sid}} =
             Delegates.start_delegate(ctx.delegates, "main", "app", "unit/one", "opus", "Look.",
               interactive: true
             )

    text = "Look.\n\n[delivery #{u}]"
    assert {:ok, [^text]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    {:ok, dir} = Accounts.config_dir(ctx.accounts, "work")
    {:ok, path} = Transcripts.path(dir, Agents.get(ctx.agents, name).cwd, sid)
    wake = "<task-notification>\n<status>completed</status>\n</task-notification>"
    waiter = "<task-notification>\n<summary>Stop hook feedback</summary>\n[delivery x-1]"

    lines(path, [
      user(text),
      reply("m1", "Done."),
      user(wake),
      Map.put(reply("m2", "It passed."), "uuid", "r-own"),
      user(waiter),
      Map.put(reply("m3", "A reply."), "uuid", "r-waiter"),
      user("And now?"),
      Map.put(reply("m4", "Other."), "uuid", "r-person")
    ])

    assert {:ok, %{text: "Done.", report: "taken"}} =
             cue_until(ctx, id, &(&1.status == "finished" and &1.report == "taken"))

    {:ok, [notice]} =
      await(fn ->
        Delegates.cue(ctx.delegates, %{topic: "transcripts:test:work"})
        nonempty(turn_notices(ctx))
      end)

    assert %{to_agent: "main", reply_to: "key:turn:test:r-own", text: told} = notice
    assert told == "Delegate #{name}, in a turn of its own after its report:\n\nIt passed."
    Delegates.cue(ctx.delegates, %{topic: "transcripts:test:work"})
    :sys.get_state(ctx.delegates)
    assert [_] = turn_notices(ctx)
  end

  # TurnEndsBare and IdleTold, by an interactive delegate's rule: the brief's turn ended with no
  # reply, its session file reads idle, and nothing is due to it.
  test "an interactive delegate idle with no report is told to its parent once", ctx do
    Process.exit(ctx.delegates, :kill)
    opts = ctx.dopts ++ [idle_bound: 60_000]
    child = Supervisor.child_spec({Delegates, opts}, id: make_ref(), restart: :temporary)
    delegates = start_supervised!(child)

    assert {:ok, %{id: id, name: name, brief_uuid: u, session_id: sid}} =
             Delegates.start_delegate(delegates, "main", "app", "unit/one", "opus", "Look.",
               interactive: true
             )

    text = "Look.\n\n[delivery #{u}]"
    assert {:ok, [^text]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    {:ok, dir} = Accounts.config_dir(ctx.accounts, "work")
    {:ok, path} = Transcripts.path(dir, Agents.get(ctx.agents, name).cwd, sid)
    lines(path, [user(text)])
    {:ok, _} = await(fn -> with {:ok, %{status: "delivered"}} = ok <- brief(ctx, u), do: ok end)

    {:ok, _} =
      await(fn ->
        Delegates.cue(delegates, %{topic: "transcripts:test:work"})
        if :sys.get_state(delegates).idle[id], do: {:ok, 1}
      end)

    Agent.update(ctx.clock, &(&1 + 60_000))
    Delegates.cue(delegates, %{topic: "transcripts:test:work"})
    Delegates.cue(delegates, %{topic: "transcripts:test:work"})
    :sys.get_state(delegates)
    {:ok, mtable} = Mailbox.Table.open(Path.join(ctx.dir, "caf.db"))
    rows = Enum.reject(Enum.map(1..20, &Mailbox.Table.get(mtable, &1)), &is_nil/1)

    assert [%{to_agent: "main", text: notice}] =
             Enum.filter(rows, &(&1.from_agent == "framework" and &1.kind == "msg"))

    assert notice =~ "Delegate #{name} is idle with no report"
    assert %{status: "running", report: "none"} = Table.get(ctx.dtable, id)
  end

  # F-180: a builder waiting on a startup dialog that nothing answers is `dialog` by its turn,
  # never idle with no report, past its idle bound too: no session file exists while the dialog
  # is shown, and its row is the evidence. (The prompt and its parent's one notice are
  # `Prompts`', F-179.)
  test "an interactive delegate on a dialog is `dialog`, never idle with no report", ctx do
    Process.exit(ctx.delegates, :kill)
    # A Sessions whose app answers no dialog, so a person must.
    asking =
      Supervisor.child_spec({Sessions, ctx.opts ++ [inlet: ctx.dopts[:inlet]]}, id: :asking)

    sessions = start_supervised!(asking)
    opts = Keyword.merge(ctx.dopts, sessions: sessions, idle_bound: 60_000)
    child = Supervisor.child_spec({Delegates, opts}, id: make_ref(), restart: :temporary)
    delegates = start_supervised!(child)

    started =
      Delegates.start_delegate(delegates, "main", "app", "unit/one", "opus", "Look.",
        interactive: true
      )

    # The start answers unknown while the dialog waits, and the delegate row stays starting: its
    # turn has not begun, so nothing reads it idle.
    assert started == {:unknown, {:dialog, :trust}}

    {:ok, %{name: name} = row} =
      await(fn ->
        case Agents.read_tree(ctx.agents) do
          [%{name: name}] ->
            with %{status: "dialog"} = row <- Agents.get(ctx.agents, name), do: {:ok, row}

          _ ->
            :none
        end
      end)

    assert SessionsTurn.of(row, %{files: [], waiter: false}) == :dialog

    # Past the bound, nothing tells the parent it is idle.
    for _ <- 1..2 do
      Delegates.cue(delegates, %{topic: "transcripts:test:work"})
      :sys.get_state(delegates)
      Agent.update(ctx.clock, &(&1 + 60_000))
    end

    Delegates.cue(delegates, %{topic: "registry:test:work"})
    assert :sys.get_state(delegates).idle == %{}
    {:ok, mtable} = Mailbox.Table.open(Path.join(ctx.dir, "caf.db"))
    rows = Enum.reject(Enum.map(1..20, &Mailbox.Table.get(mtable, &1)), &is_nil/1)
    refute Enum.any?(rows, &(&1.text =~ "idle with no report"))
    assert ScreenStandIn.prompts(ctx.dir) == []
    assert Agents.get(ctx.agents, name).status == "dialog"
    assert [%{status: "starting", report: "none"}] = Table.latest(ctx.dtable, "test")
  end

  # A brief longer than a launch carries goes as a pointer to its file in the due directory
  # (F-155); a Mailbox with no home has nowhere to write it, so the start is refused and
  # nothing starts.
  test "a brief longer than a launch carries, with no home for its file, starts nothing", ctx do
    long = String.duplicate("a", 600_000)

    assert {:refused, {:launch, {:refused, {:too_long, :no_home}}}} =
             Delegates.start_delegate(ctx.delegates, "main", "app", "unit/one", "opus", long,
               interactive: true
             )

    assert [%{status: "refused"}] = Table.latest(ctx.dtable, "test")
    assert ScreenStandIn.prompts(ctx.dir) == []
  end

  # Limit.tla's Report and Deliver for an interactive delegate (F-187's new-2): a turn whose
  # transcript ends with the limit's line is neither a finish nor a kill, its process gone or
  # not; the healer's word is its word to go on (`go_on/5`), its resume by launch with the word
  # as its prompt, not counted, and its report the reply of the word's turn.
  test "an interactive delegate's limit is no kill; its word resumes it, and its reply reports",
       ctx do
    assert {:ok, %{id: id, name: name, brief_uuid: u, session_id: sid}} =
             Delegates.start_delegate(ctx.delegates, "main", "app", "unit/one", "opus", "Go.",
               interactive: true
             )

    text = "Go.\n\n[delivery #{u}]"
    assert {:ok, [^text]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    {:ok, dir} = Accounts.config_dir(ctx.accounts, "work")
    {:ok, path} = Transcripts.path(dir, Agents.get(ctx.agents, name).cwd, sid)

    hit = %{
      "type" => "assistant",
      "uuid" => "a-limit",
      "isApiErrorMessage" => true,
      "apiError" => "usage_limit_reached",
      "quotaLimits" => %{"status" => "rejected", "resetsAt" => 1_800_000_000},
      "message" => %{"id" => "m0", "stop_reason" => "stop_sequence", "content" => []}
    }

    lines(path, [user(text), hit])
    # The process ends at its limit (a person's exit, say): no kill, no report.
    assert {:ok, :stopped} = Sessions.stop(ctx.dopts[:sessions], name)

    for _ <- 1..3, do: cue_until(ctx, id, fn _ -> true end)
    assert %{status: "running", resumes: 0, report: "none"} = Table.get(ctx.dtable, id)
    assert length(ScreenStandIn.prompts(ctx.dir)) == 1

    key = "limit:#{name}:1800000000"
    w = Turn.word_uuid(key)
    assert {:ok, %{session_id: ^sid}} = Delegates.go_on(ctx.delegates, name, "Go on.", key)
    word = "Go on.\n\n[delivery #{w}]"

    assert {:ok, prompts} =
             await(fn ->
               if length(ScreenStandIn.prompts(ctx.dir)) == 2,
                 do: {:ok, ScreenStandIn.prompts(ctx.dir)}
             end)

    assert word in prompts

    lines(path, [user(word), reply("m1", "Done after the limit.")])

    assert {:ok, %{text: "Done after the limit.", resumes: 0, resume_uuid: ^w}} =
             cue_until(ctx, id, &(&1.status == "finished"))
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

  defp turn_notices(ctx) do
    {:ok, mtable} = Mailbox.Table.open(Path.join(ctx.dir, "caf.db"))
    rows = Enum.reject(Enum.map(1..20, &Mailbox.Table.get(mtable, &1)), &is_nil/1)
    Enum.filter(rows, &(&1.kind == "notice" and String.starts_with?(&1.reply_to, "key:turn:")))
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
