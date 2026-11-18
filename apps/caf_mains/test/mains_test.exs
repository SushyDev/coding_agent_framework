defmodule CodingAgentFramework.MainsTest do
  @moduledoc """
  `Mains` over a real `Sessions`, `Inlet`, `Registry`, `Mailbox` and `Scheduler`, real dtach,
  tmux and git, a project's repository in this test's own directory, and the screen stand-in
  for Claude Code, which draws 2.1.322's trust dialog first: a new checkout is a folder Claude
  Code has not seen. Each test names the `Checkout.tla` steps or properties it checks.
  """
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Mains, only: [project: 3]
  doctest CodingAgentFramework.Mains.Checkout
  doctest CodingAgentFramework.Mains.Table
  doctest CodingAgentFramework.Mains.Starts

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Grants, Inlet, Mailbox, Mains, Registry, Scheduler}
  alias CodingAgentFramework.{ScreenStandIn, Sessions, SessionsSetup, Transcripts, Usage}
  alias CodingAgentFramework.Mains.{Checkout, Starts, Work}
  alias CodingAgentFramework.Sessions.Agents

  @trust "Yes, I trust this folder"

  setup {SessionsSetup, :sessions}

  setup ctx do
    origin = Path.join(ctx.dir, "origin")
    git!(ctx, ["init", "-q", "-b", "main", origin])
    commit!(ctx, origin, "init")

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

    # A Sessions that reads a start's pane for its startup dialogs, and answers none itself.
    inlet = start_supervised!({Inlet, tmux: ctx.server})
    reading = ctx.opts ++ [inlet: inlet, look: 50]
    sessions = start_supervised!(Supervisor.child_spec({Sessions, reading}, id: :reading))

    {:ok, agents} = Agents.open(db, "test")

    mailbox_opts = [
      db: db,
      grants: Grants.new(fn -> Agents.read_tree(agents) end, operator: "op"),
      stream: ctx.stream,
      sessions_db: db,
      host: "test",
      intake: start_supervised!(CodingAgentFramework.MainsTest.NoWaiter),
      transcripts: transcripts,
      accounts: accounts
    ]

    mailbox = start_supervised!(Supervisor.child_spec({Mailbox, mailbox_opts}, id: :mailbox))
    {:ok, work} = Work.open(db, db, "test")

    scheduler =
      start_supervised!(
        {Scheduler,
         db: db,
         host: "test",
         resources: %{"seat" => 2},
         holders: %{"main" => &Work.state(work, &1)}}
      )

    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), trust: true)
    launch = SessionsSetup.launch(ctx, :at_start) |> Keyword.take([:env, :tool_timeout, :model])
    project = %{origin: origin, trunk: "main", setup: [], setup_timeout: 10_000}
    project = Map.put(project, :env, %{"HOME" => ctx.dir})

    opts = [
      host: "test",
      home: ctx.dir,
      db: db,
      sessions_db: db,
      programs: programs(),
      reaper: ctx.opts[:reaper],
      sessions: sessions,
      mailbox: mailbox,
      usage: usage,
      accounts: accounts,
      projects: %{"app" => project},
      mains: %{"app-main" => "app"},
      launch: [claude: claude] ++ launch,
      scheduler: scheduler,
      operator: "op",
      interval: 100
    ]

    {:ok, starts} = Starts.open(db)

    {:ok,
     origin: origin,
     checkout: Checkout.path(ctx.dir, "app"),
     mains_opts: opts,
     sessions: sessions,
     agents: agents,
     scheduler: scheduler,
     starts: starts,
     mailbox_db: db}
  end

  defp mains(ctx) do
    spec = Supervisor.child_spec({Mains, ctx.mains_opts}, id: make_ref(), restart: :temporary)
    start_supervised!(spec)
  end

  # CloneStart, CloneDone and Rename after a cut clone's Recover (`WholeCheckout`); then Land,
  # Fetch, Check and Merge; an edit holds the pull back, owed (`ClearOnDirty`'s guard), and is
  # never lost (`NoLostEdit`); the read after the person cleans it pulls (`CaughtUp`).
  test "the checkout is made once, whole, and pulled after a landing only while clean", ctx do
    # A clone a restart cut, as its temporary directory: the start removes it and clones anew.
    cut = Checkout.clone_path(ctx.dir, "app")
    File.mkdir_p!(Path.join(cut, "half"))
    mains = mains(ctx)

    assert {:ok, %{state: "ready", branch: "main", clean: "true"}} = level(ctx, mains)
    refute File.exists?(cut)
    assert head(ctx, ctx.checkout) == head(ctx, ctx.origin)

    # A landing: the pull fast-forwards trunk.
    commit!(ctx, ctx.origin, "one")
    assert :ok = Mains.landed(mains, "app")
    assert {:ok, _} = level(ctx, mains)

    # An edit in the checkout: the next landing's pull is held back, owed, and fetches nothing.
    # (Read once first: an edit made between a pull's clean check and its merge is carried.)
    edit = Path.join(ctx.checkout, "edit.txt")
    File.write!(edit, "mine")
    assert {:ok, _} = await(fn -> state(mains, "dirty") end)
    commit!(ctx, ctx.origin, "two")
    assert :ok = Mains.landed(mains, "app")

    assert {:ok, %{state: "dirty", owed: "true", reason: ~s(["held","dirty"])}} =
             await(fn -> state(mains, "dirty", owed: "true") end)

    refute head(ctx, ctx.checkout) == head(ctx, ctx.origin)
    assert File.read!(edit) == "mine"

    # Cleaned by the person, it is pulled at the next read, with no landing.
    File.rm!(edit)
    assert {:ok, %{owed: "false"}} = level(ctx, mains)

    # A commit on trunk in the checkout: ahead, and git's fast-forward is never forced.
    commit!(ctx, ctx.checkout, "local")
    commit!(ctx, ctx.origin, "three")
    assert :ok = Mains.landed(mains, "app")
    assert {:ok, %{state: "ahead", ahead: 1}} = await(fn -> state(mains, "ahead") end)
  end

  # Restart and Recover: a landing while Mains was down told nobody, so its start owes a pull
  # (`NoPullAtStart`'s guard).
  test "a start of Mains pulls what landed while it was down", ctx do
    mains = mains(ctx)
    assert {:ok, _} = level(ctx, mains)
    GenServer.stop(mains)

    commit!(ctx, ctx.origin, "while down")
    mains = mains(ctx)
    assert {:ok, _} = level(ctx, mains)
  end

  # The start: its name checked, its agent row declared, its own row the lease's holder, the
  # brief from its sender carried by launch, and the trust dialog of the new checkout waiting
  # on a person (F-140); the row runs once the agent row does.
  test "start_main leases and starts a main session in the checkout, through its dialog", ctx do
    mains = mains(ctx)
    assert {:ok, _} = level(ctx, mains)

    # The declared main session is a root of the tree, with no process yet.
    assert %{kind: "main", parent: nil, project: "app", status: "declared"} =
             Agents.get(ctx.agents, "app-main")

    # The reserved names: the framework's own, and the operator's.
    for reserved <- ["framework", "op"] do
      assert {:refused, {:running, ^reserved}} = Mains.start_main(mains, "app", reserved, "Go.")
    end

    assert {:refused, {:unknown_project, "web"}} = Mains.start_main(mains, "web", "web-a", "Go.")

    assert {:unknown, {:dialog, :trust}} =
             Mains.start_main(mains, "app", "app-epic", "Plan the epic.", from: "app-main")

    # A name whose start is under way is in use.
    assert {:refused, {:running, "app-epic"}} =
             Mains.start_main(mains, "app", "app-epic", "Again.")

    assert %{kind: "main", parent: nil, project: "app", status: "dialog", cwd: cwd} =
             Agents.get(ctx.agents, "app-epic")

    assert cwd == ctx.checkout
    assert [%{status: "starting", id: id, brief_uuid: uuid}] = Starts.rows(ctx.starts, "test")

    # The lease of a person's main session, held by the start's row while its dialog waits.
    key = Work.key("test", id)

    assert [%{class: class, holder: {"main", ^key}, released_at: nil}] =
             Scheduler.leases(ctx.scheduler)

    assert to_string(class) == "main"

    # A person answers the dialog; past it the session runs, and the brief was its prompt.
    assert {:ok, :sent} = Sessions.answer_dialog(ctx.sessions, "app-epic", :trust, @trust)
    assert {:ok, _} = await(fn -> running(ctx, "app-epic") end)
    Mains.cue(mains, %{topic: "sessions:test", ids: []})
    assert {:ok, %{status: "running"}} = await(fn -> start_row(ctx, id, "running") end)

    text = "Plan the epic.\n\n[delivery #{uuid}]"
    assert {:ok, [^text]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    {:ok, mtable} = Mailbox.Table.open(ctx.mailbox_db)

    assert %{from_agent: "app-main", to_agent: "app-epic", via: "launch"} =
             Mailbox.Table.brief(mtable, "app-epic")

    # A name that runs is in use.
    assert {:refused, {:running, "app-epic"}} = Mains.start_main(mains, "app", "app-epic", "Go.")
  end

  defp level(ctx, mains) do
    await(
      fn ->
        case Mains.checkout(mains, "app") do
          {:ok, %{state: "ready"} = row} ->
            if head(ctx, ctx.checkout) == head(ctx, ctx.origin), do: {:ok, row}, else: :behind

          other ->
            {:not_ready, other}
        end
      end,
      15_000
    )
  end

  defp state(mains, want, also \\ []) do
    with {:ok, %{state: ^want} = row} = ok <- Mains.checkout(mains, "app"),
         true <- Enum.all?(also, fn {k, v} -> row[k] == v end) do
      ok
    else
      other -> {:not_yet, other}
    end
  end

  defp running(ctx, name) do
    {:ok, _} = Registry.read(ctx.registry)
    Sessions.cue(ctx.sessions, %{topic: "registry:test:work", ids: []})

    case Agents.get(ctx.agents, name) do
      %{status: "running"} = row -> {:ok, row}
      row -> row.status
    end
  end

  defp start_row(ctx, id, want) do
    case Starts.get(ctx.starts, id) do
      %{status: ^want} = row -> {:ok, row}
      row -> row
    end
  end

  defp nonempty([]), do: :none
  defp nonempty(list), do: {:ok, list}

  defp head(ctx, repo), do: git!(ctx, ["-C", repo, "rev-parse", "refs/heads/main"])

  defp commit!(ctx, repo, message) do
    as = ["-c", "user.name=t", "-c", "user.email=t@t"]
    git!(ctx, ["-C", repo | as] ++ ["commit", "-qm", message, "--allow-empty"])
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

defmodule CodingAgentFramework.MainsTest.NoWaiter do
  @moduledoc false
  # Plays `Intake` with no waiter held: the brief goes by launch.
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:waiter?, _account, _session}, _from, s), do: {:reply, {:ok, false}, s}
end
