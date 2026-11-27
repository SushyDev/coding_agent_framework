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

defmodule CodingAgentFramework.DelegatesInteractiveTest.Held do
  @moduledoc false
  # Plays `Intake` with a waiter held: each text handed to it goes to the test, which writes the
  # lines Claude Code 2.1.322 writes for it (`WaiterStandIn.take/4`).
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call({:waiter?, _account, _session}, _from, test), do: {:reply, {:ok, true}, test}

  def handle_call({:deliver, _account, _session, text}, _from, test) do
    send(test, {:waiter, text})
    {:reply, {:ok, :sent}, test}
  end
end

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
     intake: opts[:intake],
     mopts: mopts}
  end

  @wake "<task-notification>\n<status>completed</status>\n</task-notification>"

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

    # Its turn was read ended, closed by the next, its process still running (F-202).
    assert {:ok, %{status: "finished", text: "Done.", report: "taken", taken_by: "turn_end"}} =
             cue_until(ctx, id, &(&1.status == "finished" and &1.report == "taken"))

    # F-137's new-4: the brief's marked line, once found, is read from its offset.
    at = byte_size(JSON.encode!(before)) + 1
    assert %{{^sid, ^u} => ^at} = :sys.get_state(ctx.delegates).marks

    assert {:ok, %{status: "delivered"}} = brief(ctx, u)
    assert {:ok, %{kind: "reply", from: ^name, to: "main"}} = Mailbox.answer_to(ctx.mailbox, u)
  end

  # F-200: an interactive delegate is run as a main session is (role `parent`), but it is a
  # delegate: its launch line has `--effort`, and its settings file says no git instructions.
  # F-275: and no Remote Control, neither the flag nor in its overlay.
  test "an interactive delegate has its effort, no git instructions, no Remote Control", ctx do
    start = &Delegates.start_delegate(ctx.delegates, "main", "app", "unit/one", "opus", "Go.", &1)
    assert {:refused, {:effort, "ultra"}} = start.(interactive: true, effort: "ultra")
    assert Table.rows(ctx.dtable, "test") == []
    assert ScreenStandIn.argvs(ctx.dir) == []

    assert {:ok, %{id: id, name: name}} = start.(interactive: true, effort: "max")
    assert %{effort: "max"} = Table.get(ctx.dtable, id)
    assert {:ok, [argv]} = await(fn -> nonempty(ScreenStandIn.argvs(ctx.dir)) end)
    assert ["--model", "opus", "--name", name, "--effort", "max"] == Enum.slice(argv, 0, 6)
    # F-227: an interactive delegate's mode is pinned, `auto` unless the config says otherwise.
    assert ["--permission-mode", "auto"] == Enum.slice(argv, 6, 2)
    refute "--remote-control" in argv

    file = argv |> Enum.drop_while(&(&1 != "--settings")) |> Enum.at(1)
    {:ok, dir} = Accounts.config_dir(ctx.accounts, "work")
    assert file == Path.join(dir, "framework/agents/#{name}.settings.json")

    assert %{"includeGitInstructions" => false, "remoteControlAtStartup" => false} =
             JSON.decode!(File.read!(file))

    # What a resume launches with (its own, or a move's) is the row's effort again.
    assert {:ok, launch} = Delegates.launch(ctx.delegates, name)
    assert launch[:effort] == "max"
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

    # F-222: after a restart its marks are new, so reading the report's turn changes the state;
    # the end-to-end run's restart crashed here on every tick and took the tree down.
    ref = Process.monitor(ctx.delegates)
    Process.exit(ctx.delegates, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    child = Supervisor.child_spec({Delegates, ctx.dopts}, id: make_ref(), restart: :temporary)
    delegates = start_supervised!(child)
    Delegates.cue(delegates, %{topic: "transcripts:test:work"})
    :sys.get_state(delegates)
    assert Process.alive?(delegates)
    assert [_] = turn_notices(ctx)
  end

  # F-261: on a busy host a finished delegate's own turns were read from its report to the end of
  # its transcript at every cue, and each queued cue ran a settle of its own, so a fix's call
  # waited past its bound. Queued cues now settle once, and an unchanged transcript is not read.
  test "queued cues settle once, and a finished delegate's unchanged transcript is not read",
       ctx do
    assert {:ok, %{id: id, name: name, brief_uuid: u, session_id: sid}} =
             Delegates.start_delegate(ctx.delegates, "main", "app", "unit/one", "opus", "Look.",
               interactive: true
             )

    text = "Look.\n\n[delivery #{u}]"
    assert {:ok, [^text]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    {:ok, dir} = Accounts.config_dir(ctx.accounts, "work")
    {:ok, path} = Transcripts.path(dir, Agents.get(ctx.agents, name).cwd, sid)
    wake = "<task-notification>\n<status>completed</status>\n</task-notification>"

    lines(path, [user(text), reply("m1", "Done."), user(wake)])
    lines(path, [Map.put(reply("m2", "It passed."), "uuid", "r-own")])

    assert {:ok, %{report: "taken"}} =
             cue_until(ctx, id, &(&1.status == "finished" and &1.report == "taken"))

    assert {:ok, [_]} = told_after_read(ctx, path, 1)

    # Settled, with the transcript read to its end: count what a burst of cues costs now.
    :erlang.trace_pattern({CodingAgentFramework.Delegates, :settle, 1}, true, [:local])
    :erlang.trace_pattern({Transcripts, :text, 5}, true, [:local])
    :erlang.trace(ctx.delegates, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({:_, :_, :_}, false, [:local]) end)

    :ok = :sys.suspend(ctx.delegates)
    for _ <- 1..50, do: Delegates.cue(ctx.delegates, %{topic: "transcripts:test:work"})
    :ok = :sys.resume(ctx.delegates)
    :sys.get_state(ctx.delegates)
    :erlang.trace(ctx.delegates, false, [:call])

    calls = traced(ctx.delegates, [])
    assert Enum.count(calls, &(&1 == :settle)) == 1
    assert Enum.count(calls, &(&1 == :text)) == 0

    # The transcript grows: the next own turn is read and told, once.
    lines(path, [user(wake), Map.put(reply("m3", "Still green."), "uuid", "r-own-2")])
    assert {:ok, [_, _]} = told_after_read(ctx, path, 2)
    assert [_, _] = turn_notices(ctx)
  end

  # Reply.tla's orders (F-257): a parent's message handed to the waiter is answered once, by the
  # reply of the turn it went into, under its key, and that turn is never told as its own.
  # Into a turn of its own still running, the message is queued into that turn.
  test "a message queued into a turn of its own is answered, and that turn is not told", ctx do
    w = with_waiter(ctx)
    lines(w.path, [user(@wake)])
    m = message(w, "Is it green?", :busy)
    lines(w.path, [Map.put(reply("m2", "Yes, green."), "uuid", "r-own"), user("Thanks.")])

    assert {:ok, %{kind: "reply", from: from, to: "main", text: "Yes, green."}} =
             answered(w, m)

    assert from == w.name
    assert turn_notices(ctx) == []
  end

  # Into an idle session just after its turn of its own ended: that turn is told, its own; the
  # message's turn is its reply.
  test "a message just after a turn of its own: the turn is told, and the message answered",
       ctx do
    w = with_waiter(ctx)
    lines(w.path, [user(@wake), Map.put(reply("m2", "It passed."), "uuid", "r-own")])
    m = message(w, "Is it green?", :idle)
    lines(w.path, [Map.put(reply("m3", "Yes, green."), "uuid", "r-msg"), user("Thanks.")])

    assert {:ok, %{kind: "reply", text: "Yes, green."}} = answered(w, m)
    assert {:ok, [%{reply_to: "key:turn:test:r-own"}]} = told(ctx, w)
  end

  # After the parent was told of the turn of its own, as on the live tree: the message's turn is
  # its reply, and the turn is told once.
  test "a message after its parent was told of a turn of its own is answered", ctx do
    w = with_waiter(ctx)
    lines(w.path, [user(@wake), Map.put(reply("m2", "It passed."), "uuid", "r-own")])
    lines(w.path, [user("Thanks.")])
    assert {:ok, [_]} = told(ctx, w)
    m = message(w, "Is it green?", :idle)
    lines(w.path, [Map.put(reply("m3", "Yes, green."), "uuid", "r-msg"), user("Thanks.")])

    assert {:ok, %{kind: "reply", text: "Yes, green."}} = answered(w, m)
    assert [_] = turn_notices(ctx)
    # Read again, nothing more is stored.
    Delegates.cue(w.delegates, %{topic: "transcripts:test:work"})
    :sys.get_state(w.delegates)
    assert {:ok, %{text: "Yes, green."}} = Mailbox.reply(w.mailbox, m)
    assert [_] = turn_notices(ctx)
  end

  # The process ends in the message's turn with no reply: the notice in its place, under its key.
  test "a message whose turn the process's end cut is answered by a notice", ctx do
    w = with_waiter(ctx)
    m = message(w, "Is it green?", :idle)
    assert {:ok, :stopped} = Sessions.stop(ctx.dopts[:sessions], w.name)

    assert {:ok, %{kind: "notice", from: "framework", text: text}} = answered(w, m)
    assert text =~ "its process ended before it answered"
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

    # The resume's row, launched into the same session, settles by its line too (F-282).
    assert {:ok, %{status: "delivered", via: "launch"}} = settled(ctx, w)
  end

  # F-282: a branch's second delegate, started once its first is stopped. Its agent row named the
  # first's session, whose transcript is long by then, when its brief was marked; its start
  # made a new session, whose first line is the brief's. The brief settles delivered by it, and
  # the parent's stop is not refused for a row still open.
  test "a branch's second interactive delegate has its brief settled, and its stop goes", ctx do
    start = fn brief ->
      Delegates.start_delegate(ctx.delegates, "main", "app", "unit/one", "opus", brief,
        interactive: true
      )
    end

    assert {:ok, %{id: one, name: name, brief_uuid: u1, session_id: sid1}} = start.("First.")
    {:ok, dir} = Accounts.config_dir(ctx.accounts, "work")
    cwd = Agents.get(ctx.agents, name).cwd
    {:ok, path1} = Transcripts.path(dir, cwd, sid1)
    pad = %{"type" => "summary", "summary" => String.duplicate("x", 4_000)}
    lines(path1, [user("First.\n\n[delivery #{u1}]"), reply("m1", "Done.")])
    lines(path1, List.duplicate(pad, 50))
    assert {:ok, %{report: "taken"}} = cue_until(ctx, one, &(&1.report == "taken"))
    assert {:ok, %{status: "delivered"}} = settled(ctx, u1)
    parent_takes(ctx, u1)

    {:ok, state} = Delegates.fix_state(ctx.delegates, "main", name)
    assert {:ok, :stopped} = Delegates.fix(ctx.delegates, "main", name, :stop, state)

    assert {:ok, %{id: two, name: ^name, brief_uuid: u2, session_id: sid2}} = start.("Again.")
    assert two != one and sid2 != sid1
    {:ok, path2} = Transcripts.path(dir, cwd, sid2)
    lines(path2, [user("Again.\n\n[delivery #{u2}]"), reply("m2", "Done again.")])

    assert {:ok, %{report: "taken", text: "Done again."}} =
             cue_until(ctx, two, &(&1.report == "taken"))

    assert {:ok, %{status: "delivered"}} = settled(ctx, u2)
    parent_takes(ctx, u2)
    {:ok, state} = Delegates.fix_state(ctx.delegates, "main", name)
    assert {:ok, :stopped} = Delegates.fix(ctx.delegates, "main", name, :stop, state)
  end

  # F-284, Delivery.tla's MarkLost: the Mailbox makes the brief's mark later than the start's
  # call waits for it (a loaded host). The start is refused, and starts nothing; the mark is
  # undone and the brief ended before its answer, so the branch's next start goes, its own brief
  # its prompt.
  test "a start whose mark outlived its call leaves no row sending, and starts again", ctx do
    {delegates, mtable} = slow_mark(ctx, 6_000)

    start = fn brief ->
      Delegates.start_delegate(delegates, "main", "app", "unit/one", "opus", brief,
        interactive: true
      )
    end

    assert {:refused, {:launch, {:unknown, {:timeout, 5_000}}}} = start.("First.")
    assert [%{status: "refused", name: name, brief_uuid: u1}] = Table.rows(ctx.dtable, "test")
    assert Agents.get(ctx.agents, name) == nil
    assert %{status: "ended"} = Mailbox.Table.by_uuid(mtable, u1)
    assert ScreenStandIn.argvs(ctx.dir) == []

    assert {:ok, %{name: ^name, brief_uuid: u2, session_id: sid}} = start.("Again.")
    assert is_binary(sid)
    text = "Again.\n\n[delivery #{u2}]"
    assert {:ok, [^text]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    assert %{status: "ended"} = Mailbox.Table.by_uuid(mtable, u1)
  end

  # F-284: a brief left queued to a name no process of which runs (an earlier start's, made due
  # again by a restart after that start was refused) is ended by the name's next start, which
  # carries its own brief, never the old one.
  test "a new start ends an earlier start's brief left queued, and carries its own", ctx do
    name = Turn.name(ctx.dopts[:projects]["app"], "unit/one")
    old = CodingAgentFramework.Stream.uuid()
    {:ok, {:queued, id}} = Mailbox.brief(ctx.mailbox, "main", name, "Stale.", old)
    Mailbox.cue(ctx.mailbox, %{topic: "sessions", ids: []})
    Mailbox.status(ctx.mailbox, id)
    {:ok, mtable} = Mailbox.Table.open(Path.join(ctx.dir, "caf.db"))
    assert %{status: "queued", attempt: "no_delivery"} = Mailbox.Table.get(mtable, id)

    assert {:ok, %{name: ^name, brief_uuid: u}} =
             Delegates.start_delegate(ctx.delegates, "main", "app", "unit/one", "opus", "Go.",
               interactive: true
             )

    text = "Go.\n\n[delivery #{u}]"
    assert {:ok, [^text]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    assert %{status: "ended"} = Mailbox.Table.get(mtable, id)
  end

  # A start whose own work outlives its caller's bound goes on, and its brief follows it: the
  # caller is answered unknown, the start runs, and its brief settles delivered by its line.
  test "a start that outlives its caller's bound runs, and its brief settles by its line", ctx do
    assert {:unknown, {:timeout, 1}} =
             Delegates.start_delegate(ctx.delegates, "main", "app", "unit/one", "opus", "Go.",
               interactive: true,
               timeout: 1
             )

    assert {:ok, [%{id: id, brief_uuid: u}]} =
             await(
               fn ->
                 with [%{status: "running"}] = rows <- Table.rows(ctx.dtable, "test"),
                      do: {:ok, rows}
               end,
               30_000
             )

    text = "Go.\n\n[delivery #{u}]"
    assert {:ok, [^text]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    %{name: name} = Table.get(ctx.dtable, id)
    %{session_id: sid, cwd: cwd} = Agents.get(ctx.agents, name)
    {:ok, dir} = Accounts.config_dir(ctx.accounts, "work")
    {:ok, path} = Transcripts.path(dir, cwd, sid)
    lines(path, [user(text)])
    assert {:ok, %{status: "delivered", via: "launch"}} = settled(ctx, u)
  end

  # A Delegates over a Mailbox whose write of a launch's mark is slow: its notify of the first
  # mark waits `ms` in the Mailbox's process, past the 5 s its caller waits for the mark.
  defp slow_mark(ctx, ms) do
    Process.exit(ctx.delegates, :kill)
    {:ok, mtable} = Mailbox.Table.open(Path.join(ctx.dir, "caf.db"))
    once = :atomics.new(1, [])

    notify = fn %{ids: [id]} ->
      with %{status: "sending", via: "launch"} <- Mailbox.Table.get(mtable, id),
           :ok <- :atomics.compare_exchange(once, 1, 0, 1),
           do: Process.sleep(ms)

      :ok
    end

    mopts = Keyword.put(ctx.mopts, :notify, notify)
    mailbox = start_supervised!(Supervisor.child_spec({Mailbox, mopts}, id: make_ref()))
    opts = Keyword.put(ctx.dopts, :mailbox, mailbox)
    child = Supervisor.child_spec({Delegates, opts}, id: make_ref(), restart: :temporary)
    {start_supervised!(child), mtable}
  end

  # A delegate whose Mailbox has a waiter held for it, its report taken.
  defp with_waiter(ctx) do
    Process.exit(ctx.delegates, :kill)
    held = start_supervised!({CodingAgentFramework.DelegatesInteractiveTest.Held, self()})
    mopts = Keyword.put(ctx.mopts, :intake, held)
    mailbox = start_supervised!(Supervisor.child_spec({Mailbox, mopts}, id: make_ref()))
    opts = Keyword.put(ctx.dopts, :mailbox, mailbox)
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
    lines(path, [user(text), reply("m1", "Done.")])
    w = %{id: id, name: name, sid: sid, path: path, mailbox: mailbox, delegates: delegates}

    assert {:ok, %{report: "taken"}} =
             cue_until(
               %{ctx | delegates: delegates, mailbox: mailbox},
               id,
               &(&1.report == "taken")
             )

    w
  end

  # The parent's message, handed to the waiter, and Claude Code's take of it in `shape`.
  defp message(w, text, shape) do
    {:ok, {:queued, id}} = Mailbox.message(w.mailbox, "main", w.name, text)
    Mailbox.cue(w.mailbox, %{topic: "transcripts:test:work", ids: []})
    assert_receive {:waiter, handed}, 5_000
    CodingAgentFramework.WaiterStandIn.take(w.path, w.sid, handed, shape)

    {:ok, _} =
      await(fn ->
        Mailbox.cue(w.mailbox, %{topic: "transcripts:test:work", ids: []})
        with {:ok, %{status: "delivered"}} = ok <- Mailbox.status(w.mailbox, id), do: ok
      end)

    id
  end

  defp answered(w, id) do
    await(
      fn ->
        Delegates.cue(w.delegates, %{topic: "transcripts:test:work"})
        :sys.get_state(w.delegates)
        Mailbox.reply(w.mailbox, id)
      end,
      10_000
    )
  end

  defp told(ctx, w) do
    await(fn ->
      Delegates.cue(w.delegates, %{topic: "transcripts:test:work"})
      :sys.get_state(w.delegates)
      nonempty(turn_notices(ctx))
    end)
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

  # The parent's `run_delegate` takes the report to brief `u` (the call transport): delivered.
  defp parent_takes(ctx, u) do
    assert {:ok, %{id: id, kind: "reply"}} = Mailbox.await(ctx.mailbox, "main", u, 5_000)
    assert {:ok, :delivered} = Mailbox.told(ctx.mailbox, id, :written)
  end

  # The row stored under `u`, once it is no longer `sending`.
  defp settled(ctx, u) do
    {:ok, mtable} = Mailbox.Table.open(Path.join(ctx.dir, "caf.db"))

    await(fn ->
      Mailbox.cue(ctx.mailbox, %{topic: "transcripts:test:work", ids: []})
      :sys.get_state(ctx.mailbox)

      case Mailbox.Table.by_uuid(mtable, u) do
        %{status: "sending"} -> :sending
        %{} = row -> {:ok, row}
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

  # Cues until the transcript reader has read `path` to its end and `n` turn notices are told.
  defp told_after_read(ctx, path, n) do
    await(fn ->
      size = File.stat!(path).size
      Delegates.cue(ctx.delegates, %{topic: "transcripts:test:work"})
      Transcripts.read(ctx.dopts[:transcripts])

      with {:ok, ^size} <- offset_of(ctx, path),
           notices when length(notices) == n <- turn_notices(ctx) do
        {:ok, notices}
      end
    end)
  end

  defp offset_of(ctx, path) do
    sid = Path.basename(path, ".jsonl")
    Transcripts.offset(ctx.dopts[:transcripts], "work", sid)
  end

  defp traced(pid, acc) do
    receive do
      {:trace, ^pid, :call, {_, :settle, _}} -> traced(pid, [:settle | acc])
      {:trace, ^pid, :call, {_, :text, _}} -> traced(pid, [:text | acc])
    after
      0 -> acc
    end
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
