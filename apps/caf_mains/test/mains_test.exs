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
  doctest CodingAgentFramework.Mains.Import

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Acts, Grants, Inlet, Intake, Mailbox, Mains, Registry}
  alias CodingAgentFramework.Scheduler
  alias CodingAgentFramework.{ScreenStandIn, Sessions, SessionsSetup, Transcripts, Usage}
  alias CodingAgentFramework.Mains.{Checkout, Import, Starts, Work}
  alias CodingAgentFramework.Sessions.{Agents, Memory}

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
     project: project,
     checkout: Mains.project(ctx.dir, "app", project).repo,
     mains_opts: opts,
     sessions: sessions,
     agents: agents,
     accounts: accounts,
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
    cut = Checkout.clone_path(ctx.dir, "origin")
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
             await(fn -> state(mains, "dirty", owed: "true", reason: ~s(["held","dirty"])) end)

    refute head(ctx, ctx.checkout) == head(ctx, ctx.origin)
    assert File.read!(edit) == "mine"

    # Cleaned by the person, it is pulled at the next read, with no landing.
    File.rm!(edit)
    assert {:ok, %{owed: "false"}} = level(ctx, mains)

    # A commit on trunk in the checkout: ahead, and git's fast-forward is never forced. It goes
    # in as a person's would while Mains reads every 100 ms: a read takes no index lock (F-145),
    # and the row just read, ready and owing nothing, was written once the pull's merge, the one
    # git command of Mains that takes the lock, had ended; none starts until the next landing.
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

  # F-258; Team.tla's FixActs for the operator's interrupt of a main session: Escape through the
  # Inlet, only on the state the caller claimed, answered once the screen shows the turn ended.
  # With no turn running no key goes, and the refusal is a delegate's (`{:screen, reading}`).
  test "the operator's interrupt of a main session ends its running turn", ctx do
    # The stand-in started mid-turn, with no trust dialog, which would end on the idle screen.
    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle())
    wrapper = Path.join(ctx.dir, "claude-running")
    File.write!(wrapper, "#!#{program!(:bash)}\nexec #{claude} --screen running \"$@\"\n")
    File.chmod!(wrapper, 0o755)
    inlet = start_supervised!(Supervisor.child_spec({Inlet, tmux: ctx.server}, id: :press))
    launch = Keyword.put(ctx.mains_opts[:launch], :claude, wrapper)
    opts = Keyword.merge(ctx.mains_opts, launch: launch, inlet: inlet)
    mains = mains(%{ctx | mains_opts: opts})
    assert {:ok, _} = level(ctx, mains)

    # A declared main session has no process: refused before any key, as a gone delegate is.
    assert {:ok, declared} = Mains.fix_state(mains, "app-main", fix: :interrupt)
    assert {:refused, :gone} = Mains.fix_check(:interrupt, declared)
    assert {:refused, :gone} = Mains.interrupt(mains, "app-main", state: declared)

    assert {:ok, %{name: "app-epic"}} =
             Mains.start_main(mains, "app", "app-epic", "Plan it.", from: "app-main")

    assert {:ok, _} = await(fn -> running(ctx, "app-epic") end)

    assert {:ok, %{status: "running", offset: nil} = state} =
             Mains.fix_state(mains, "app-epic", fix: :interrupt)

    assert :ok = Mains.fix_check(:interrupt, state)

    # A state that is no longer the session's presses nothing.
    assert {:refused, {:moved, ^state}} =
             Mains.interrupt(mains, "app-epic", state: %{state | pid: -1})

    refute File.exists?(Path.join(ctx.dir, "interrupted"))
    assert {:ok, :sent} = Mains.interrupt(mains, "app-epic", state: state)
    assert File.exists?(Path.join(ctx.dir, "interrupted"))

    # The turn ended: a second interrupt finds none, and sends no key.
    assert {:ok, now} = Mains.fix_state(mains, "app-epic", fix: :interrupt)
    assert {:refused, {:screen, %{state: :idle}}} = Mains.interrupt(mains, "app-epic", state: now)
  end

  # F-258: only an interrupt's state has the newest hook event. An answer's state is as before,
  # so a hook event between the answer's read and its act moves the interrupt's state only, and
  # the answer is still taken (Team.tla's AnswerClaimed, then FixActs).
  test "a main session's answer is taken though a hook event came after its read", ctx do
    intake = start_supervised!({Intake, db: ctx.mailbox_db, host: "test"})
    opts = ctx.mains_opts ++ [intake: intake, intake_db: ctx.mailbox_db]
    mains = mains(%{ctx | mains_opts: opts})
    assert {:ok, _} = level(ctx, mains)

    assert {:unknown, {:dialog, :trust}} =
             Mains.start_main(mains, "app", "app-epic", "Plan it.", from: "app-main")

    assert {:ok, :sent} = Sessions.answer_dialog(ctx.sessions, "app-epic", :trust, @trust)
    assert {:ok, %{session_id: sid}} = await(fn -> running(ctx, "app-epic") end)
    post = &Intake.post(intake, "work", JSON.encode!(Map.put(&1, "session_id", sid)))
    me = self()

    hold =
      Task.async(fn ->
        # The holder, as `Intake.Plug` is: it writes the decision, then says so.
        body = %{"hook_event_name" => "PermissionRequest", "tool_use_id" => "t1"}
        {:ok, {:held, held, ref, _wait}} = post.(body)
        send(me, :held)

        receive do
          {^ref, {:decision, text}} ->
            Intake.written(intake, held, ref)
            {:decision, text}
        after
          10_000 -> :none
        end
      end)

    assert_receive :held, 5_000
    assert {:ok, %{held: [id]} = state} = Mains.fix_state(mains, "app-epic")
    refute Map.has_key?(state, :offset)
    assert {:ok, before} = Mains.fix_state(mains, "app-epic", fix: :interrupt)

    # A hook event after the read: the interrupt's state moved, the answer's did not.
    assert {:ok, :stored} = post.(%{"hook_event_name" => "Notification", "message" => "Waiting"})
    assert {:ok, later} = Mains.fix_state(mains, "app-epic", fix: :interrupt)
    assert later.offset > before.offset
    assert {:ok, ^state} = Mains.fix_state(mains, "app-epic")

    assert {:ok, :sent} = Mains.answer(mains, "app-epic", id, "allow", state: state)
    assert {:decision, decision} = Task.await(hold)
    assert decision =~ "allow"
  end

  # Limit.tla's StartRefusedAtLimit, AnswerWait, a restart that keeps the row, and StartAtReset
  # (F-196): a main's start at a limit is its own row, waiting, and its sender is told once.
  test "a main's start refused at a usage limit waits as its row, and starts at its reset", ctx do
    clock = [clock: fn -> Agent.get(ctx.clock, & &1) end]
    ctx = %{ctx | mains_opts: ctx.mains_opts ++ clock}
    mains = mains(ctx)
    assert {:ok, _} = level(ctx, mains)
    until = limit(ctx, 3_600)

    assert {:ok, %{id: id, name: "app-epic", account: nil, session_id: nil, waiting: ^until}} =
             Mains.start_main(mains, "app", "app-epic", "Plan it.", from: "app-main")

    assert %{status: "waiting", account: "", until: ^until, tell: "app-main"} =
             row = Starts.get(ctx.starts, id)

    assert row.deadline == until + 120_000
    assert Agents.get(ctx.agents, "app-epic") == nil
    assert {:refused, {:waiting, "app-epic"}} = Mains.start_main(mains, "app", "app-epic", "Go.")
    assert {:refused, {:waiting, "app-epic"}} = Mains.end_main(mains, "app-epic")
    assert {:ok, :waiting} = Mains.answer_wait(mains, id, "wait", "sam")
    assert {:refused, :settled} = Mains.answer_wait(mains, id, "leave", "sam")

    # A restart keeps the row; at its deadline the pick finds room, and the start goes on under
    # its own row, the lease's holder.
    Process.exit(mains, :kill)
    mains = mains(ctx)
    Agent.update(ctx.clock, fn _ -> until + 120_000 end)
    Mains.cue(mains, %{topic: "sessions:test", ids: []})
    assert {:ok, %{account: "work"}} = await(fn -> start_row(ctx, id, "starting") end)

    # The row says `starting` before the start asks `Scheduler` for its lease: wait for the lease.
    assert {:ok, [%{holder: {"main", _}}]} = await(fn -> leases(ctx, fn _ -> true end) end)
    assert {:ok, _} = await(fn -> dialog(ctx, "app-epic") end)
    assert {:ok, :sent} = Sessions.answer_dialog(ctx.sessions, "app-epic", :trust, @trust)
    assert {:ok, _} = await(fn -> running(ctx, "app-epic") end)

    told = fn ->
      Mains.cue(mains, %{topic: "sessions:test", ids: []})

      case Starts.get(ctx.starts, id) do
        %{status: "running", tell: nil} = row -> {:ok, row}
        row -> row
      end
    end

    assert {:ok, %{account: "work"}} = await(told)

    {:ok, mtable} = Mailbox.Table.open(ctx.mailbox_db)
    notices = for n <- 1..20, %{kind: "notice"} = m <- [Mailbox.Table.get(mtable, n)], do: m
    assert [%{to_agent: "app-main", from_agent: "framework", text: text}] = notices
    assert text =~ "start of main session app-epic, which waited for a usage limit's reset"
    assert text =~ "has started on work"
  end

  # `Delegate.tla`'s CallerLate and Called past the deadline, for `Mains`' start (F-166's new-1,
  # F-172): a request that waited in `Sessions`' queue past its caller's deadline is refused
  # there and makes nothing, so no session runs under a row `Mains` refuses at its own deadline.
  test "a start Sessions takes past its caller's deadline is refused and makes nothing", ctx do
    clock = fn -> Agent.get(ctx.clock, & &1) end
    me = self()

    # The start's MCP config is made in its task right before its call of `Sessions`: held
    # there, the test suspends `Sessions` after the declare and before the start's request.
    mcp = fn _name ->
      send(me, {:mcp, self()})
      receive do: (:go -> {:ok, nil})
    end

    mains = mains(%{ctx | mains_opts: ctx.mains_opts ++ [clock: clock, mcp: mcp]})
    assert {:ok, _} = level(ctx, mains)

    late = Task.async(fn -> Mains.start_main(mains, "app", "app-epic", "Plan.") end)
    assert_receive {:mcp, task}, 10_000
    :ok = :sys.suspend(ctx.sessions)
    send(task, :go)
    assert {:ok, _} = await(fn -> start_queued(ctx.sessions, "app-epic") end)

    # The caller's deadline is the row's less its slack, 60 s: the row's own has not passed.
    [%{id: id, status: "starting", deadline: deadline}] = Starts.rows(ctx.starts, "test")
    Agent.update(ctx.clock, fn _ -> deadline - 60_000 end)
    :ok = :sys.resume(ctx.sessions)

    assert {:refused, :caller_gone} = Task.await(late, 10_000)
    assert {:ok, %{status: "refused"}} = await(fn -> start_row(ctx, id, "refused") end)
    assert %{status: "declared", pid: nil} = Agents.get(ctx.agents, "app-epic")
    assert ScreenStandIn.prompts(ctx.dir) == []
  end

  # F-143 (`Team.tla`'s `MainEnds`): the end is refused while a delegate of the main session has
  # not ended (`NoDelegateWithoutParent`); then the session is stopped while idle and its row is
  # ended, so it owns nothing more; no delegate starts under it, and its name never runs again.
  # The model it was started with is the caller's (F-141's new-8).
  test "end_main ends a main session once its delegates have ended, for good", ctx do
    mains = mains(ctx)
    assert {:ok, _} = level(ctx, mains)

    assert {:unknown, {:dialog, :trust}} =
             Mains.start_main(mains, "app", "app-epic", "Plan.", model: "sonnet")

    assert {:ok, :sent} = Sessions.answer_dialog(ctx.sessions, "app-epic", :trust, @trust)
    assert {:ok, %{model: "sonnet"}} = await(fn -> running(ctx, "app-epic") end)
    assert {:ok, _} = await(fn -> settled(ctx, mains) end)

    # A delegate of it waits on its own dialog: it has not ended.
    assert {:unknown, {:dialog, :trust}} = delegate(ctx, "app-epic-api", "app-epic")

    assert {:refused, {:delegates, ["app-epic-api"]}} = Mains.end_main(mains, "app-epic")
    assert %{status: "running"} = Agents.get(ctx.agents, "app-epic")

    assert {_, _} = Sessions.answer_dialog(ctx.sessions, "app-epic-api", :trust, "No, exit")
    assert {:ok, _} = await(fn -> status(ctx, "app-epic-api", "stopped") end)
    assert {:ok, :ended} = Sessions.ended(ctx.sessions, "app-epic-api")

    # Idle, it is stopped by SIGTERM, and its row is ended: Agents.ended?/1 now holds.
    assert {:ok, :ended} = Mains.end_main(mains, "app-epic")
    assert Agents.ended?(Agents.get(ctx.agents, "app-epic"))
    assert {:ok, :ended} = Mains.end_main(mains, "app-epic")

    assert {:refused, {:parent_ended, "app-epic"}} = delegate(ctx, "app-epic-web", "app-epic")
    assert {:refused, {:running, "app-epic"}} = Mains.start_main(mains, "app", "app-epic", "Go.")
    assert {:refused, {:not_stopped, "ended"}} = Mains.resume_main(mains, "app-epic")

    assert {:refused, {:ended, "app-epic"}} =
             Sessions.resume(ctx.sessions, "app-epic", ctx.account, "s", role: :parent)

    # A declared main session with no process is ended at once.
    assert {:ok, :ended} = Mains.end_main(mains, "app-main")
    assert {:refused, {:not_main, "delegate"}} = Mains.end_main(mains, "app-epic-api")
  end

  # Dialog.tla's AskEnd and EndDone (F-231's new-3): a main session whose start waits on its trust
  # dialog is ended by the operator, forced or not, with no answer first: its exit option is
  # pressed, its agent row ended, and the start that waited is refused, `ended`. It ran no turn.
  test "end_main ends a main session whose start waits on its trust dialog", ctx do
    mains = mains(ctx)
    assert {:ok, _} = level(ctx, mains)

    assert {:unknown, {:dialog, :trust}} = Mains.start_main(mains, "app", "app-epic", "Plan.")
    assert [%{status: "starting", id: id}] = Starts.rows(ctx.starts, "test")

    assert {:ok, :ended} = Mains.end_main(mains, "app-epic", force: true)
    assert Agents.ended?(Agents.get(ctx.agents, "app-epic"))
    assert ScreenStandIn.prompts(ctx.dir) == []

    Mains.cue(mains, %{topic: "sessions:test", ids: []})
    assert {:ok, %{reason: reason}} = await(fn -> start_row(ctx, id, "refused") end)
    assert reason =~ "ended"
    assert {:ok, [_]} = await(fn -> leases(ctx, &(&1.released_at != nil)) end)
    assert {:refused, {:running, "app-epic"}} = Mains.start_main(mains, "app", "app-epic", "Go.")
  end

  # F-141's new-5: a resume is new work, with a lease of its own, class main session; the first
  # start's lease went once its process ended.
  test "resume_main resumes a stopped main session under a lease of its own", ctx do
    mains = mains(ctx)
    assert {:ok, _} = level(ctx, mains)

    assert {:refused, {:not_stopped, "declared"}} = Mains.resume_main(mains, "app-main")
    assert {:unknown, {:dialog, :trust}} = Mains.start_main(mains, "app", "app-main", nil)
    assert {:ok, :sent} = Sessions.answer_dialog(ctx.sessions, "app-main", :trust, @trust)
    assert {:ok, %{session_id: sid}} = await(fn -> running(ctx, "app-main") end)
    assert {:ok, _} = await(fn -> settled(ctx, mains) end)

    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "app-main")
    assert {:ok, [_]} = await(fn -> leases(ctx, & &1.released_at) end)

    # A fix's resume acts only on the state its claim holds (F-143's new-1).
    assert {:ok, %{status: "stopped", session_id: ^sid} = dead} =
             Mains.fix_state(mains, "app-main")

    assert {:refused, {:moved, ^dead}} =
             Mains.resume_main(mains, "app-main", state: %{dead | pid: -1})

    assert {:unknown, {:dialog, :trust}} = Mains.resume_main(mains, "app-main", state: dead)

    # The start's row says which session it resumed (F-143's new-5).
    assert [%{resume: nil}, %{status: "starting", id: id, resume: ^sid}] =
             Starts.rows(ctx.starts, "test")

    key = Work.key("test", id)

    assert {:ok, [%{holder: {"main", ^key}}]} =
             await(fn -> leases(ctx, &is_nil(&1.released_at)) end)

    assert {:ok, :sent} = Sessions.answer_dialog(ctx.sessions, "app-main", :trust, @trust)
    assert {:ok, %{session_id: ^sid}} = await(fn -> running(ctx, "app-main") end)
  end

  # F-146's new-5: the operator answers a main session's held PermissionRequest through
  # Intake, on the state its claim holds (Team.tla's CanAct), as an interactive delegate's.
  test "answer sends a main session's held permission request its decision, once", ctx do
    db = Path.join(ctx.dir, "intake.db")
    intake = start_supervised!({Intake, db: db, host: "test"})
    mains = start_supervised!({Mains, ctx.mains_opts ++ [intake: intake, intake_db: db]})
    assert {:ok, _} = level(ctx, mains)

    assert {:ok, %{held: []}} = Mains.fix_state(mains, "app-main")
    assert {:refused, {:not_held, "1"}} = Mains.answer(mains, "app-main", "1", "allow")
    assert {:unknown, {:dialog, :trust}} = Mains.start_main(mains, "app", "app-main", nil)
    assert {:ok, :sent} = Sessions.answer_dialog(ctx.sessions, "app-main", :trust, @trust)
    assert {:ok, %{session_id: sid}} = await(fn -> running(ctx, "app-main") end)

    me = self()

    hold = fn tool ->
      body = %{
        "hook_event_name" => "PermissionRequest",
        "session_id" => sid,
        "tool_use_id" => tool
      }

      Task.async(fn ->
        # The holder, as `Intake.Plug` is: it writes the decision, then says so.
        {:ok, {:held, held, ref, _}} = Intake.post(intake, "work", JSON.encode!(body))
        send(me, {:held, tool})

        receive do
          {^ref, {:decision, text}} ->
            :ok = Intake.written(intake, held, ref)
            JSON.decode!(text)
        after
          10_000 -> :none
        end
      end)
    end

    first = hold.("t1")
    assert_receive {:held, "t1"}, 5_000
    assert {:ok, %{held: [id]} = state} = Mains.fix_state(mains, "app-main")
    assert {:refused, {:bad, :label}} = Mains.answer(mains, "app-main", id, "yes", state: state)

    assert {:refused, {:moved, ^state}} =
             Mains.answer(mains, "app-main", id, "allow", state: %{state | held: []})

    assert {:ok, :sent} = Mains.answer(mains, "app-main", id, "allow", state: state)

    assert %{"hookSpecificOutput" => %{"decision" => %{"behavior" => "allow"}}} =
             Task.await(first)

    # The answer moved the state: the old one acts nothing, and a second request is its own.
    assert {:refused, {:moved, %{held: []}}} =
             Mains.answer(mains, "app-main", id, "allow", state: state)

    second = hold.("t2")
    assert_receive {:held, "t2"}, 5_000
    assert {:ok, %{held: [two]} = state} = Mains.fix_state(mains, "app-main")
    assert {:ok, :sent} = Mains.answer(mains, "app-main", two, "deny", state: state)

    assert %{"hookSpecificOutput" => %{"decision" => %{"behavior" => "deny", "message" => _}}} =
             Task.await(second)

    # Without an Intake, Mains answers none.
    assert {:refused, :no_intake} = Mains.answer(mains(ctx), "app-main", two, "allow")
  end

  # F-141's new-4: a start refused once its brief was stored settles that one row, ended.
  test "a refused start's brief is settled ended", ctx do
    mains =
      mains(%{ctx | mains_opts: ctx.mains_opts ++ [mcp: fn _ -> {:refused, :no_config} end]})

    assert {:ok, _} = level(ctx, mains)

    assert {:refused, :no_config} = Mains.start_main(mains, "app", "app-epic", "Plan.")
    assert [%{status: "refused", brief_uuid: uuid}] = Starts.rows(ctx.starts, "test")
    {:ok, mtable} = Mailbox.Table.open(ctx.mailbox_db)
    assert %{status: "ended"} = Mailbox.Table.by_uuid(mtable, uuid)
  end

  # F-141's new-6: a stale lock is a state the view shows, never removed here; once a person
  # clears it, the pull it held back goes.
  test "a checkout's stale index.lock shows as locked until a person clears it", ctx do
    mains = mains(ctx)
    assert {:ok, _} = level(ctx, mains)

    lock = Path.join([ctx.checkout, ".git", "index.lock"])
    File.write!(lock, "")
    commit!(ctx, ctx.origin, "while locked")
    assert :ok = Mains.landed(mains, "app")

    assert {:ok, %{owed: "true"}} = await(fn -> state(mains, "locked", owed: "true") end)
    assert File.exists?(lock)

    File.rm!(lock)
    assert {:ok, _} = level(ctx, mains)
  end

  # F-156: an app's conversations copied in by `bin/caf-import`'s work, two projects each with
  # its own checkout directory, resumed by name in the right checkout; a second import copies
  # nothing; an import while a session of the account runs is refused.
  test "an imported conversation resumes by name in its project's checkout", ctx do
    web = Path.join(ctx.dir, "web_repo")
    git!(ctx, ["init", "-q", "-b", "main", web])
    commit!(ctx, web, "init")
    projects = Map.put(ctx.mains_opts[:projects], "web", %{ctx.project | origin: web})
    ctx = %{ctx | mains_opts: Keyword.put(ctx.mains_opts, :projects, projects)}
    web_checkout = Mains.project(ctx.dir, "web", projects["web"]).repo
    assert Path.basename(web_checkout) == "web_repo"

    mains = mains(ctx)
    assert {:ok, _} = level(ctx, mains)
    assert {:ok, _} = await(fn -> ready(mains, "web") end, 15_000)

    # The person's own config directory: two conversations under two old cwds, memory, settings
    # and a login that must stay behind.
    source = Path.join(ctx.dir, "old-claude")
    {:ok, app_dir} = Transcripts.project_dir(source, "/old/app")
    {:ok, web_dir} = Transcripts.project_dir(source, "/old/web")
    write!(Path.join(app_dir, "s-app.jsonl"), ~s({"type":"user"}\n))
    write!(Path.join([app_dir, "s-app", "subagents", "a.jsonl"]), "{}\n")
    write!(Path.join([app_dir, "memory", "MEMORY.md"]), "kept from before")
    write!(Path.join(web_dir, "s-web.jsonl"), ~s({"type":"user"}\n))
    # A setting naming a path this host lacks is kept, and named (F-177).
    dirs = %{"additionalDirectories" => [ctx.dir, "/old/docs"]}
    settings = JSON.encode!(%{"model" => "opus", "permissions" => dirs})
    write!(Path.join(source, "settings.json"), settings)
    write!(Path.join(source, ".credentials.json"), "secret")

    # The import's home is the framework's; its accounts are the Sessions' account's own.
    File.ln_s!(Path.join(ctx.dir, "home/accounts"), Path.join(ctx.dir, "accounts"))

    run = %{
      home: ctx.dir,
      account: "work",
      source: source,
      maps: [{"/old/app", "app"}, {"/old/web", "web"}],
      names: %{"s-app" => "app-epic", "s-web" => "web-epic"},
      metas: %{"s-app" => %{"epic" => 7}},
      programs: programs()
    }

    # The app's tables named by `--db` (F-177): none there, so it never started on this host.
    elsewhere = Path.join(ctx.dir, "elsewhere.db")
    assert {:refused, {:no_app_start, ^elsewhere}} = Import.run(Map.put(run, :db, elsewhere))

    # A Claude Code run by hand on the source or the account is no row, but its session file
    # names a live process, by its pid and start time (F-177): nothing is copied.
    me = String.to_integer(System.pid())
    live = JSON.encode!(%{pid: me, sessionId: "by-hand", procStart: lstart(me)})
    config = ctx.account.config_dir

    for dir <- [source, config] do
      file = Path.join([dir, "sessions", "#{me}.json"])
      write!(file, live)
      assert {:refused, {:running, [^me]}} = Import.run(run)
      write!(file, ~s({"pid": #{me}, "sess))
      assert {:refused, {:may_run, [^me]}} = Import.run(run)
      File.rm!(file)
    end

    refute File.exists?(Path.join(config, "settings.json"))

    assert {:ok, lines} = Import.run(run)
    assert Enum.any?(lines, &(&1 =~ "s-app: imported (main session app-epic"))

    assert ("settings: settings.json keeps permissions.additionalDirectories[1], naming " <>
              "/old/docs, not on this host") in lines

    refute Enum.any?(lines, &(&1 =~ "naming #{ctx.dir}"))
    {:ok, transcript} = Transcripts.path(config, ctx.checkout, "s-app")
    assert File.read!(transcript) == ~s({"type":"user"}\n)
    assert File.exists?(Path.join([Path.rootname(transcript), "subagents", "a.jsonl"]))
    assert {:ok, _} = Transcripts.path(config, web_checkout, "s-web") |> then(&exists/1)
    {:ok, memory} = Memory.dir(ctx.dir, ctx.checkout)
    assert File.read!(Path.join(memory, "MEMORY.md")) == "kept from before"
    assert File.read!(Path.join(config, "settings.json")) == settings
    refute File.exists?(Path.join(config, ".credentials.json"))

    # A second run copies nothing, and says so.
    assert {:ok, again} = Import.run(run)
    assert Enum.any?(again, &(&1 =~ "s-app: imported already"))
    assert Enum.any?(again, &(&1 =~ "memory: 0 file(s) copied, 1 there already"))

    # At its next start Mains has Sessions write each named one, stopped, to be resumed.
    GenServer.stop(mains)
    mains = mains(ctx)

    assert %{kind: "main", status: "stopped", session_id: "s-app", project: "app"} =
             app = Agents.get(ctx.agents, "app-epic")

    assert app.cwd == ctx.checkout and Agents.meta(app) == %{"epic" => 7}

    assert %{status: "stopped", session_id: "s-web", cwd: ^web_checkout} =
             Agents.get(ctx.agents, "web-epic")

    # The app's start-or-resume: a start is refused, as for any session to resume; the resume
    # takes it up in the app's checkout, with the memory it had.
    assert {:refused, {:running, "app-epic"}} = Mains.start_main(mains, "app", "app-epic", "Go.")
    assert {:unknown, {:dialog, :trust}} = Mains.resume_main(mains, "app-epic")
    assert {:ok, :sent} = Sessions.answer_dialog(ctx.sessions, "app-epic", :trust, @trust)
    assert {:ok, %{session_id: "s-app", cwd: cwd}} = await(fn -> running(ctx, "app-epic") end)
    assert cwd == ctx.checkout
    {:ok, account_dir} = Transcripts.project_dir(config, ctx.checkout)
    assert File.read!(Path.join([account_dir, "memory", "MEMORY.md"])) == "kept from before"

    # While a session of the account runs, nothing is imported.
    assert {:refused, {:running, ["app-epic"]}} = Import.run(run)
  end

  # F-177 (`Move.tla`'s Resume): a conversation is only in the account it ran on or was imported
  # into, so a resume runs there, even with another account's allowance larger; only when that
  # account is refused does it go to another, which first takes a copy (ResumeCopy); a copy
  # refused leaves the row on its own account (CopyRefused). `TranscriptKept`.
  test "a resume runs on its row's account, and on another only after a copy", ctx do
    {:ok, accounts} = Accounts.new(Path.join(ctx.dir, "home"), ["work", "spare"])
    {:ok, spare} = Accounts.prepare(accounts, "spare", %{})
    {:ok, file} = Accounts.usage_file(accounts, "spare")
    week = %{"seven_day" => %{"used_percentage" => 5, "resets_at" => 4_000_000_000}}
    File.write!(file, JSON.encode!(%{"rate_limits" => week}))
    usage_opts = [accounts: accounts, host: "test", db: Path.join(ctx.dir, "usage2.db")]
    usage = start_supervised!(Supervisor.child_spec({Usage, usage_opts}, id: :usage2))
    {:ok, _} = Usage.read(usage)
    room = start_supervised!(Supervisor.child_spec({Agent, fn -> %{} end}, id: :room))
    acts_db = Path.join(ctx.dir, "acts.db")
    acts = start_supervised!({Acts, db: acts_db, start_id: "s1", host: "test", instance: "t"})
    allowance = fn account -> Agent.get(room, &Map.get(&1, account, :room)) end
    # The login as `Logins.check/3` answers it (F-181): `spare` not logged in at first.
    login = start_supervised!(Supervisor.child_spec({Agent, fn -> %{} end}, id: :login))
    Agent.update(login, &Map.put(&1, "spare", {:refused, {:login, :logged_out}}))

    usable = fn account ->
      with {:ok, a} <- Accounts.ready(accounts, account),
           :ok <- Agent.get(login, &Map.get(&1, account, :ok)),
           do: {:ok, a}
    end

    more = [accounts: accounts, usage: usage, allowance: allowance, acts: acts, usable: usable]
    mains = mains(%{ctx | mains_opts: Keyword.merge(ctx.mains_opts, more)})
    assert {:ok, _} = level(ctx, mains)

    # A stopped main session of `work`, as an import leaves one: its conversation is there alone.
    {:ok, transcript} = Transcripts.path(ctx.account.config_dir, ctx.checkout, "s-epic")
    write!(transcript, ~s({"type":"user"}\n))
    write!(Path.join([Path.rootname(transcript), "subagents", "a.jsonl"]), "{}\n")
    entry = %{session_id: "s-epic", account: "work", project: "app", meta: nil}
    entry = Map.merge(entry, %{name: "app-epic", cwd: ctx.checkout})
    assert {:ok, _} = Sessions.import_main(ctx.sessions, "app-epic", entry)

    # `spare` has more allowance left; the resume runs where the conversation is (ResumeHere).
    assert {:unknown, {:dialog, :trust}} = Mains.resume_main(mains, "app-epic")
    assert [%{account: "work", resume: "s-epic"}] = Starts.rows(ctx.starts, "test")
    assert {:ok, :sent} = Sessions.answer_dialog(ctx.sessions, "app-epic", :trust, @trust)
    assert {:ok, %{account: "work"}} = await(fn -> running(ctx, "app-epic") end)
    assert {:ok, _} = await(fn -> settled(ctx, mains) end)
    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "app-epic")
    assert {:ok, :none} = await(fn -> held(ctx) end)

    # `work`'s windows spent, and `spare` never logged in: no usable account has room, so the
    # resume waits for the reset (F-196), until a person leaves it.
    Agent.update(room, &Map.put(&1, "work", {:spent, 4_000_000_000_000}))

    assert {:ok, %{id: waiting, waiting: 4_000_000_000_000}} =
             Mains.resume_main(mains, "app-epic")

    assert %{status: "waiting", resume: "s-epic", tell: nil} = Starts.get(ctx.starts, waiting)
    assert {:refused, {:waiting, "app-epic"}} = Mains.resume_main(mains, "app-epic")
    assert {:ok, :left} = Mains.answer_wait(mains, waiting, "leave", "sam")
    assert %{status: "refused", reason: "left"} = Starts.get(ctx.starts, waiting)

    # `spare` logged in, but the copy refused: the row stays on `work`, stopped (CopyRefused).
    Agent.update(login, &Map.delete(&1, "spare"))
    File.rename!(transcript, transcript <> ".away")
    assert {:refused, {:copy, {:no_transcript, :enoent}}} = Mains.resume_main(mains, "app-epic")
    assert %{account: "work", status: "stopped"} = Agents.get(ctx.agents, "app-epic")
    assert %{status: "refused", account: "spare"} = List.last(Starts.rows(ctx.starts, "test"))
    File.rename!(transcript <> ".away", transcript)
    assert {:ok, :none} = await(fn -> held(ctx) end)

    # The copy, then the resume on `spare` under the same session id (ResumeCopied).
    assert {:unknown, {:dialog, :trust}} = Mains.resume_main(mains, "app-epic")
    {:ok, copy} = Transcripts.path(spare.config_dir, ctx.checkout, "s-epic")
    assert File.read!(copy) == File.read!(transcript)
    assert File.exists?(Path.join([Path.rootname(copy), "subagents", "a.jsonl"]))

    assert %{status: "starting", account: "spare", resume: "s-epic"} =
             List.last(Starts.rows(ctx.starts, "test"))

    assert [%{outcome: "failed"}, %{outcome: "verified"}] =
             for(%{act: "copy"} = row <- elem(Acts.rows(acts), 1), do: row)
  end

  # F-156: a checkout an earlier build made under the project's name goes to its directory
  # once, with the accounts' conversations, the home's memory and its worktrees' links
  # (`Checkout.tla`'s RenameOld and Repair); while a session of the project may run, the rename
  # waits, and says which (`NoSessionMoved`).
  test "a checkout under the project's name is renamed once no session runs in it", ctx do
    old = Checkout.path(ctx.dir, "app")
    git!(ctx, ["clone", "-q", "--branch", "main", "--origin", "origin", ctx.origin, old])
    tree = Path.join(ctx.dir, "tree")
    git!(ctx, ["-C", old, "worktree", "add", "-q", "-b", "unit/a", tree, "main"])

    config = ctx.account.config_dir
    {:ok, transcript} = Transcripts.path(config, old, "s-old")
    write!(transcript, "{}\n")
    {:ok, old_memory} = Memory.dir(ctx.dir, old)
    write!(Path.join(old_memory, "MEMORY.md"), "the old memory")
    File.ln_s!(old_memory, Path.join(Path.dirname(transcript), "memory"))

    # A session of the project on a dialog in the old checkout: its process may live.
    {:ok, account} = Accounts.ready(ctx.accounts, "work")
    claude = ctx.mains_opts[:launch][:claude]
    launch = [role: :parent, cwd: old, project: "app", claude: claude]
    launch = launch ++ Keyword.delete(ctx.mains_opts[:launch], :claude)

    assert {:unknown, {:dialog, :trust}} =
             Sessions.start(ctx.sessions, "app-old", account, launch)

    acts_db = Path.join(ctx.dir, "acts.db")
    acts = start_supervised!({Acts, db: acts_db, start_id: "s1", host: "test", instance: "t"})
    mains = mains(%{ctx | mains_opts: ctx.mains_opts ++ [acts: acts]})

    assert {:ok, %{state: "old", reason: reason}} = await(fn -> state(mains, "old") end)
    assert reason =~ "app-old"
    assert File.dir?(old) and not File.exists?(ctx.checkout)
    assert {:refused, {:checkout, "old"}} = Mains.start_main(mains, "app", "app-epic", "Go.")

    # Once it ended, the next read renames it.
    assert {_, _} = Sessions.answer_dialog(ctx.sessions, "app-old", :trust, "No, exit")
    assert {:ok, _} = level(ctx, mains)
    refute File.exists?(old)
    {:ok, moved} = Transcripts.path(config, ctx.checkout, "s-old")
    assert File.read!(moved) == "{}\n"
    refute File.exists?(Path.join(Path.dirname(moved), "memory"))
    {:ok, new_memory} = Memory.dir(ctx.dir, ctx.checkout)
    assert File.read!(Path.join(new_memory, "MEMORY.md")) == "the old memory"
    assert git!(ctx, ["-C", tree, "rev-parse", "--abbrev-ref", "HEAD"]) == "unit/a\n"

    assert [%{outcome: "failed"}, %{outcome: "verified"}] =
             for(%{act: "rename"} = row <- elem(Acts.rows(acts), 1), do: row)
  end

  # F-156: two projects in one checkout directory are refused before anything starts.
  test "two projects naming one directory are refused", ctx do
    projects = Map.put(ctx.mains_opts[:projects], "web", Map.put(ctx.project, :dir, "origin"))
    Process.flag(:trap_exit, true)

    assert {:error, {:same_dir, "origin", ["app", "web"]}} =
             Mains.start_link(Keyword.put(ctx.mains_opts, :projects, projects))
  end

  # F-229: two origins of one name, each a repository with its own trunk.
  defp other_origin(ctx) do
    other = Path.join([ctx.dir, "elsewhere", "origin"])
    git!(ctx, ["init", "-q", "-b", "main", other])
    commit!(ctx, other, "elsewhere")
    other
  end

  # F-229: in one config, two origins of one name default to one directory, which is refused;
  # `dir:` gives each its own.
  test "two projects whose origins share a name are refused, and dir: gives each its own", ctx do
    web = %{ctx.project | origin: other_origin(ctx)}
    projects = Map.put(ctx.mains_opts[:projects], "web", web)
    Process.flag(:trap_exit, true)

    assert {:error, {:same_dir, "origin", ["app", "web"]}} =
             Mains.start_link(Keyword.put(ctx.mains_opts, :projects, projects))

    projects = Map.put(projects, "web", Map.put(web, :dir, "web_origin"))
    mains = mains(%{ctx | mains_opts: Keyword.put(ctx.mains_opts, :projects, projects)})
    assert {:ok, _} = level(ctx, mains)
    assert {:ok, %{path: path}} = await(fn -> ready(mains, "web") end, 15_000)
    assert path == Checkout.path(ctx.dir, "web_origin")
    assert head(ctx, path) == head(ctx, web.origin)
  end

  # F-229 (`Checkout.tla`'s `OwnCheckout`, `Break_Checkout_NoOwner`): a later config on the same
  # home names a new project whose origin has the name of an earlier project's; the earlier
  # one's row holds the directory, so `Mains` is refused, and the earlier clone is untouched.
  test "a project whose path another project's row holds is refused by Mains", ctx do
    mains = mains(ctx)
    assert {:ok, _} = level(ctx, mains)
    GenServer.stop(mains)
    before = head(ctx, ctx.checkout)

    fresh = %{ctx.project | origin: other_origin(ctx)}
    opts = Keyword.merge(ctx.mains_opts, projects: %{"fresh" => fresh}, mains: %{})
    Process.flag(:trap_exit, true)

    assert {:error, {:checkout_taken, path, "app"}} = Mains.start_link(opts)
    assert path == ctx.checkout
    assert head(ctx, ctx.checkout) == before

    # Its own directory, by `dir:`, is its own; the earlier project's row stays its own too.
    opts = Keyword.put(opts, :projects, %{"fresh" => Map.put(fresh, :dir, "fresh_origin")})
    mains = mains(%{ctx | mains_opts: opts})
    assert {:ok, %{path: path}} = await(fn -> ready(mains, "fresh") end, 15_000)
    assert path == Checkout.path(ctx.dir, "fresh_origin")
    assert head(ctx, path) == head(ctx, fresh.origin)
    GenServer.stop(mains)
    assert {:ok, _} = level(ctx, mains(ctx))
  end

  # F-229 (`Checkout.tla`'s `OriginOK`, `Break_Checkout_NoOriginCheck`): a directory at the
  # project's path whose `origin` is another repository is never taken: it reads `failed`,
  # refuses a start, and is neither pulled nor changed.
  test "a directory whose origin is another repository reads failed, origin_mismatch", ctx do
    other = other_origin(ctx)
    git!(ctx, ["clone", "-q", "--branch", "main", "--origin", "origin", other, ctx.checkout])
    before = head(ctx, ctx.checkout)
    mains = mains(ctx)

    assert {:ok, %{reason: reason}} = await(fn -> state(mains, "failed") end)
    assert reason =~ "origin_mismatch" and reason =~ other

    assert {:refused, {:origin_mismatch, path, ^other}} =
             Mains.start_main(mains, "app", "app-epic", "Go.")

    assert path == ctx.checkout

    # A landing owes a pull; the read it starts reads the origin first, and goes no further.
    commit!(ctx, ctx.origin, "landed")
    {:ok, %{updated_at: at}} = Mains.checkout(mains, "app")
    assert :ok = Mains.landed(mains, "app")

    assert {:ok, _} =
             await(fn ->
               case state(mains, "failed") do
                 {:ok, %{updated_at: now}} = ok when now > at -> ok
                 other -> {:not_yet, other}
               end
             end)

    assert head(ctx, ctx.checkout) == before
    assert File.exists?(Path.join(ctx.checkout, ".git"))
  end

  defp ready(mains, project) do
    case Mains.checkout(mains, project) do
      {:ok, %{state: "ready"} = row} -> {:ok, row}
      other -> {:not_ready, other}
    end
  end

  defp exists({:ok, path}), do: if(File.exists?(path), do: {:ok, path}, else: {:missing, path})

  defp write!(path, text) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp delegate(ctx, name, parent) do
    {:ok, account} = Accounts.ready(ctx.accounts, "work")
    claude = ctx.mains_opts[:launch][:claude]
    launch = [role: :parent, kind: :delegate, parent: parent, cwd: ctx.dir, claude: claude]

    Sessions.start(
      ctx.sessions,
      name,
      account,
      launch ++ Keyword.delete(ctx.mains_opts[:launch], :claude)
    )
  end

  defp status(ctx, name, want) do
    case Agents.get(ctx.agents, name) do
      %{status: ^want} = row -> {:ok, row}
      row -> row
    end
  end

  # The cues the app's `Cues` would hand on: `Mains` settles its starts by the agent rows.
  defp settled(ctx, mains) do
    Mains.cue(mains, %{topic: "sessions:test", ids: []})

    case Starts.starting_rows(ctx.starts, "test") do
      [] -> {:ok, :settled}
      rows -> rows
    end
  end

  # No lease held: each start's went once its work ended.
  defp held(ctx) do
    case leases(ctx, &is_nil(&1.released_at)) do
      :none -> {:ok, :none}
      {:ok, found} -> {:held, found}
    end
  end

  defp lstart(pid) do
    {out, 0} =
      System.cmd(program!(:ps), ["-o", "lstart=", "-p", "#{pid}"],
        env: [{"LC_ALL", "C"}, {"TZ", "UTC"}]
      )

    String.trim(out)
  end

  # The Scheduler reads its holders again on a cue, as on the app's.
  defp leases(ctx, keep) do
    Scheduler.cue(ctx.scheduler, %{topic: "sessions:test"})

    case Enum.filter(Scheduler.leases(ctx.scheduler), keep) do
      [] -> :none
      found -> {:ok, found}
    end
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

  # The account's record of a usage limit `s` seconds from the test's clock, read by `Usage`:
  # its reset in ms.
  defp limit(ctx, s) do
    resets = div(Agent.get(ctx.clock, & &1), 1000) + s
    limit = %{"status" => "rejected", "resetsAt" => resets, "rateLimitType" => "five_hour"}
    fact = %{at: System.os_time(:millisecond), evidence: %{"source" => "test"}, limit: limit}
    {:ok, _} = Usage.take(ctx.mains_opts[:usage], "work", fact)
    resets * 1000
  end

  defp dialog(ctx, name) do
    case Agents.get(ctx.agents, name) do
      %{status: "dialog"} = row -> {:ok, row}
      row -> row
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

  defp start_queued(sessions, name) do
    {:messages, messages} = Process.info(sessions, :messages)

    if Enum.any?(messages, &match?({:"$gen_call", _, {{:start, ^name, _, _, _, _}, _}}, &1)),
      do: {:ok, :queued}
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
