defmodule CodingAgentFramework.MoverTest do
  @moduledoc """
  `Mover` against `model/tla/Move.tla`, over a real `Sessions`, `Mailbox`, `Intake` behind
  Bandit, `Registry`, `Transcripts`, `Stream` and `Acts`, real dtach and tmux in this test's own
  directory, the stand-ins for Claude Code (interactive and headless) and `WaiterStandIn` for
  Claude Code's side of a main session's waiter, two accounts, and every cue routed by `Cues`.
  Each test names the `Move.tla` property or Break it checks.
  """
  use ExUnit.Case, async: true

  # A refused stop and a move that goes back are logged; the rows say the same.
  @moduletag :capture_log

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Acts, Mailbox, Mover, MoverSetup, Sessions}
  alias CodingAgentFramework.{HeadlessStandIn, Stream, Transcripts, WaiterStandIn}
  alias CodingAgentFramework.Sessions.Agents

  setup {MoverSetup, :mover}

  setup ctx do
    {:ok, mtable} = Mailbox.Table.open(Path.join(ctx.dir, "caf.db"))
    {:ok, mtable: mtable}
  end

  # NoIdleRead, OneAccountAtATime (ResumeBeforeEnd), TranscriptKept (CopyBeforeEnd),
  # LateEndNeverEndsMoved, DrainedParentMoves.
  test "a main session moves: ended once idle, copied after its exit, resumed on the other",
       ctx do
    main = main(ctx)
    # F-155: what the session keeps in its memory on one account.
    memory = Path.join(Path.dirname(main.transcript), "memory")
    File.write!(Path.join(memory, "MEMORY.md"), "- the trunk is main\n")
    assert {:ok, :sent} = MoverSetup.type(ctx, "main", "busy")
    assert {:ok, _} = file_says(ctx, "work", "busy")
    # What a turn the SIGTERM cuts writes goes into its transcript as the process ends.
    assert {:ok, :sent} = MoverSetup.type(ctx, "main", "cut #{main.transcript}")

    assert {:ok, %{act: act, from: "work", to: "spare"}} = move(ctx, "main")
    assert {:refused, {:moving, _}} = move(ctx, "main")

    # NoIdleRead: a turn runs, so the stop is refused at each reading and nothing is sent.
    assert {:ok, _} = row_when(ctx, "main", &(&1.move == "stopping"))
    {:ok, _} = CodingAgentFramework.Registry.read(ctx.registry)
    :sys.get_state(mover())
    assert alive?(main.pid)
    assert %{account: "work", pid: pid} = row(ctx, "main")
    assert pid == main.pid

    # The turn ends: the SIGTERM, the exit, the copy, and the resume on the other account.
    assert {:ok, :sent} = MoverSetup.type(ctx, "main", "idle")
    assert {:ok, moved} = row_when(ctx, "main", &moved?(&1, "spare"))

    # OneAccountAtATime: the old process ended before the new one started, under one session.
    refute alive?(main.pid)
    assert moved.session_id == main.sid and moved.pid != main.pid

    # TranscriptKept: the copy is the old transcript as its exit left it, the cut turn's line
    # in it, with what Claude Code keeps beside it.
    spare = paths(ctx, "spare", main.sid)
    assert File.read!(spare.transcript) == File.read!(main.transcript)
    assert File.read!(spare.transcript) =~ ~s({"type":"cut"}\n)

    assert File.read!(Path.join([Path.rootname(spare.transcript), "subagents", "a.jsonl"])) ==
             "{}\n"

    # F-155: the memory is the checkout's one, in the home, on the other account too.
    moved_memory = Path.join(Path.dirname(spare.transcript), "memory")
    assert File.read!(Path.join(moved_memory, "MEMORY.md")) == "- the trunk is main\n"
    assert {:ok, shared} = File.read_link(moved_memory)
    assert {:ok, ^shared} = File.read_link(memory)
    assert String.starts_with?(shared, Path.join(ctx.dir, "memory"))

    # Its name, Remote Control and its waiter, on the new account.
    {args, 0} = System.cmd(program!(:ps), ["-ww", "-o", "args=", "-p", "#{moved.pid}"])
    assert args =~ "--resume #{main.sid}" and args =~ "--remote-control main"
    assert WaiterStandIn.command(spare.settings) =~ "caf-waiter"

    assert {:ok, %{status: "settled", outcome: "verified", actor: "operator"}} =
             Acts.get(ctx.acts, act)

    # LateEndNeverEndsMoved: a settle reads the row's own process, never the one that ended.
    Sessions.cue(ctx.sessions, %{topic: "tmux:test:caf", ids: []})
    {:ok, _} = Sessions.viewer_argv(ctx.sessions, "main")
    assert %{status: "running", account: "spare", pid: pid} = row(ctx, "main")
    assert pid == moved.pid
  end

  # StopWhileSending, MarkWhileEnding, OnceAcrossMove, RowsArrive (NoResumeLaunch): a row
  # sending holds the end; no row is marked while the move is under way; each goes once, to the
  # new process, first the one made due again, as the resume's prompt, since the resumed
  # process has no waiter until a turn of it ends.
  @tag take_bound: 3_000
  test "rows to the session wait through the move and go once, to the new process", ctx do
    main = main(ctx)
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "d0", "main", "report one")

    # The old process's waiter is handed row one, and the text never reached a turn.
    turn = WaiterStandIn.turn_end(main.settings, main.sid, main.transcript, :lost)
    assert {2, _} = Task.await(turn, 10_000)
    assert %{status: "sending", uuid: u1} = mrow(ctx, one)

    assert {:ok, _} = move(ctx, "main")
    {:ok, {:queued, two}} = Mailbox.message(ctx.mailbox, "d0", "main", "report two")

    # StopWhileSending: nothing ends the old process while row one is sending.
    assert %{move: "draining"} = row(ctx, "main")
    assert alive?(main.pid)

    # Past the take bound row one is due again, the drain is clear, and the move goes on.
    assert {:ok, moved} = row_when(ctx, "main", &moved?(&1, "spare"))

    # MarkWhileEnding: neither row was marked during the move; row one, made due again, went
    # by launch as the resume's prompt, for the new process, under its uuid; row two waits.
    assert %{status: "sending", via: "launch", again: 1, uuid: ^u1, at: at} = mrow(ctx, one)
    assert at == moved.pid
    assert %{status: "queued", again: 0} = mrow(ctx, two)
    {args, 0} = System.cmd(program!(:ps), ["-ww", "-o", "args=", "-p", "#{moved.pid}"])
    assert args =~ "report one" and args =~ "[delivery #{u1}]"

    # Claude Code writes the prompt as the first turn's user line, in the transcript the agent
    # row names now, which settles row one.
    spare = paths(ctx, "spare", main.sid)

    user = %{
      "type" => "user",
      "message" => %{"content" => "From d0 (message): report one\n\n[delivery #{u1}]"}
    }

    File.write!(spare.transcript, [JSON.encode!(user), "\n"], [:append])
    assert {:ok, _} = mrow_when(ctx, one, &(&1.status == "delivered"))

    # That turn's end brings the new process's first waiter, which takes row two.
    turn = WaiterStandIn.turn_end(spare.settings, main.sid, spare.transcript, :idle)
    assert {2, "From d0 (message): report two" <> _} = Task.await(turn, 10_000)
    assert {:ok, _} = mrow_when(ctx, two, &(&1.status == "delivered"))
    assert %{status: "delivered"} = mrow(ctx, one)

    # OnceAcrossMove: one take of row one, in the new transcript; none in the old.
    refute File.read!(main.transcript) =~ "[delivery #{u1}]"
    assert lines_with(spare.transcript, "[delivery #{u1}]") == 1
  end

  # ShellIsIdle, NothingLost: the session file says `shell` while a background command runs
  # after the turn ended, and the SIGTERM waits for `idle`; then the copy takes the session's
  # `session-env` beside its transcript.
  test "the end waits for background commands, and the copy takes the session's env", ctx do
    main = main(ctx)
    env = Path.join([ctx.dirs["work"], "session-env", main.sid])
    File.mkdir_p!(env)
    File.write!(Path.join(env, "hook-1.sh"), "export A=1\n")

    assert {:ok, :sent} = MoverSetup.type(ctx, "main", "shell")
    assert {:ok, _} = file_says(ctx, "work", "shell")
    assert {:ok, _} = move(ctx, "main")

    # A background command runs: the stop is refused at each reading, and nothing is sent.
    assert {:ok, _} = row_when(ctx, "main", &(&1.move == "stopping"))

    # NoDrain: while the row has a move phase, the framework's PreToolUse callback denies a new
    # background command or monitor; any other call goes to the app's callback.
    pre = Mover.pre_tool_use(ctx.agents, fn _event -> :allow end)
    bash = fn input -> %{agent: "main", tool_name: "Bash", tool_input: input} end
    assert {:deny, why} = pre.(bash.(%{"command" => "make", "run_in_background" => true}))
    assert why =~ "moving"
    assert {:deny, _} = pre.(%{agent: "main", tool_name: "Monitor", tool_input: %{}})
    assert pre.(bash.(%{"command" => "make"})) == :allow
    assert Mover.pre_tool_use(ctx.agents).(bash.(%{"command" => "make"})) == :pass
    {:ok, _} = CodingAgentFramework.Registry.read(ctx.registry)
    :sys.get_state(mover())
    assert alive?(main.pid)

    # It ends: the file says idle, and the move goes on.
    assert {:ok, :sent} = MoverSetup.type(ctx, "main", "idle")
    assert {:ok, _} = row_when(ctx, "main", &moved?(&1, "spare"))
    refute alive?(main.pid)

    # Moved: background commands start again.
    background = %{"command" => "make", "run_in_background" => true}
    assert pre.(bash.(background)) == :allow

    copy = Path.join([ctx.dirs["spare"], "session-env", main.sid, "hook-1.sh"])
    assert File.read!(copy) == "export A=1\n"
  end

  # SettleOnTarget, DeliveredIsKept: the old process ends by itself with a row in flight whose
  # take it wrote; the move goes on from the copy, and the resume waits for the row to settle
  # (no launch while a row is sending), from the transcript the agent row names, so it is
  # delivered once and never carried again as the resume's prompt.
  @tag take_bound: 60_000
  test "a row in flight when the old process ends by itself settles before the resume", ctx do
    main = main(ctx)
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "d0", "main", "report one")
    turn = WaiterStandIn.turn_end(main.settings, main.sid, main.transcript, :lost)
    assert {2, text} = Task.await(turn, 10_000)
    assert %{status: "sending"} = mrow(ctx, one)
    assert {:ok, _} = move(ctx, "main")

    # Claude Code takes the text a moment after the waiter's exit, then the process dies.
    WaiterStandIn.take(main.transcript, main.sid, String.trim_trailing(text), :idle)
    assert {:ok, %{status: 0}} = kill(main.pid, "-KILL")

    # Copied, and the resume waits while the row is sending.
    assert {:ok, _} = row_when(ctx, "main", &(&1.move == "resuming"))
    assert %{status: "sending", via: "waiter"} = mrow(ctx, one)
    assert %{account: "work", status: "stopped"} = row(ctx, "main")

    assert {:ok, %{again: 0}} =
             mrow_when(ctx, one, &(&1.status == "delivered"), "transcripts:test:work")

    assert {:ok, moved} = row_when(ctx, "main", &moved?(&1, "spare"))
    {args, 0} = System.cmd(program!(:ps), ["-ww", "-o", "args=", "-p", "#{moved.pid}"])
    refute args =~ "report one"
  end

  # How a move refused or cut settles: on one account, never two; never none unless both
  # accounts refuse the resume, which the fault ledger shows.
  test "a move given up, or refused on the other account, leaves the session on its own", ctx do
    main = main(ctx)
    assert {:ok, :sent} = MoverSetup.type(ctx, "main", "busy")
    assert {:ok, _} = file_says(ctx, "work", "busy")
    assert {:ok, %{act: act}} = move(ctx, "main")
    assert {:ok, _} = row_when(ctx, "main", &(&1.move == "stopping"))

    # Past the move's deadline while a turn still runs: given up before any SIGTERM.
    Agent.update(ctx.clock, &(&1 + 120_000))
    Mover.cue(mover(), %{topic: "registry:test:work", ids: []})
    assert {:ok, row} = row_when(ctx, "main", &(&1.move == nil))
    assert %{status: "running", account: "work"} = row
    assert row.pid == main.pid and alive?(main.pid)
    assert {:ok, %{outcome: "failed", reason: why}} = Acts.get(ctx.acts, act)
    assert why =~ "timeout"

    # The other account refuses the resume: the act failed, and it resumes on its own account.
    MoverSetup.set_launch(ctx, fn row ->
      if row.move_to == "spare", do: {:refused, :no_room}, else: MoverSetup.launch(ctx.dir, row)
    end)

    assert {:ok, :sent} = MoverSetup.type(ctx, "main", "idle")
    assert {:ok, _} = file_says(ctx, "work", "idle")
    assert {:ok, %{act: act}} = move(ctx, "main")
    assert {:ok, back} = row_when(ctx, "main", &(moved?(&1, "work") and &1.pid != main.pid))
    assert back.session_id == main.sid
    refute alive?(main.pid)
    assert {:ok, %{outcome: "failed", reason: why}} = Acts.get(ctx.acts, act)
    assert why =~ "no_room"

    # Both refuse: no process of it runs, its row says so, and the fault ledger shows it.
    MoverSetup.set_launch(ctx, fn _row -> {:refused, :no_room} end)
    assert {:ok, %{act: _}} = move(ctx, "main")
    assert {:ok, %{status: "stopped"}} = row_when(ctx, "main", &(&1.move == nil))
    refute alive?(back.pid)

    assert {:ok, [%{outcome: "failed", reason: why}]} =
             Acts.rows(ctx.acts, actor: "mover:test", act: "move")

    assert why =~ "stranded"
  end

  # Move.tla's restart: the phase is a row, so a new Mover goes on from it; an act cut before
  # its row began nothing, and is settled at the next start.
  # NoResumeOnRefused for a move (F-210), PickOnly: the app flags the target while the move waits
  # for the delegate's turn to end, so its resume reads `usable:` again and goes back to its own
  # account; with that one flagged too, it is left down with the app's reason.
  test "a target the app flags during the drain sends the delegate back, or leaves it down",
       ctx do
    flags = start_supervised!(Supervisor.child_spec({Agent, fn -> [] end}, id: :flags))

    usable = fn a ->
      if a in Agent.get(flags, & &1),
        do: {:refused, {:app, "flagged #{a}"}},
        else: Accounts.ready(ctx.accounts, a)
    end

    GenServer.stop(mover())
    MoverSetup.restart(%{ctx | mover_opts: Keyword.put(ctx.mover_opts, :usable, usable)})

    {:ok, account} = Accounts.ready(ctx.accounts, "work")
    assert {:ok, %{pid: pid, session_id: sid}} = headless(ctx, "d1", account)
    write_transcript(ctx, "work", sid)

    # A turn that waits for a permission's answer holds the stop.
    held = fn ->
      assert {:ok, _} = stream_when(ctx, sid, & &1.idle)
      {:ok, %{uuid: u}} = Stream.write(ctx.stream, sid, {:message, "ask first"})
      assert {:ok, _} = stream_when(ctx, sid, &(&1.requests["req-" <> u][:state] == :held))
      "req-" <> u
    end

    req = held.()
    assert {:ok, %{act: act, to: "spare"}} = move(ctx, "d1")
    assert {:ok, _} = row_when(ctx, "d1", &(&1.move == "stopping"))
    Agent.update(flags, fn _ -> ["spare"] end)
    assert {:ok, _} = Stream.write(ctx.stream, sid, {:answer, req, :allow})

    assert {:ok, back} = row_when(ctx, "d1", &(moved?(&1, "work") and &1.pid != pid))
    assert back.session_id == sid
    refute alive?(pid)
    assert {:ok, %{outcome: "failed", reason: why}} = Acts.get(ctx.acts, act)
    assert why =~ "flagged spare"
    assert HeadlessStandIn.argv(ctx.dir, sid) |> Enum.member?("--resume")

    # Both flagged by the time of the resume: no process of it runs, and the fault ledger says
    # why.
    Agent.update(flags, fn _ -> [] end)
    req = held.()
    assert {:ok, %{to: "spare"}} = move(ctx, "d1")
    assert {:ok, _} = row_when(ctx, "d1", &(&1.move == "stopping"))
    Agent.update(flags, fn _ -> ["spare", "work"] end)
    assert {:ok, _} = Stream.write(ctx.stream, sid, {:answer, req, :allow})

    assert {:ok, %{status: "stopped", account: "work"}} = row_when(ctx, "d1", &(&1.move == nil))
    refute alive?(back.pid)

    assert {:ok, [%{outcome: "failed", reason: why}]} =
             Acts.rows(ctx.acts, actor: "mover:test", act: "move")

    assert why =~ "stranded" and why =~ "flagged work"
  end

  # F-211 (F-210's new-2): a `usable:` that cannot tell holds a move's resume only to the
  # resume's own deadline; past it the unknown is taken as a refusal, whose reason names it.
  test "a resume whose usable: stays unknown goes back at its deadline, or leaves the row down",
       ctx do
    untold = start_supervised!(Supervisor.child_spec({Agent, fn -> {[], []} end}, id: :untold))

    usable = fn a ->
      {accounts, _} = Agent.get(untold, & &1)

      if a in accounts do
        Agent.update(untold, fn {accounts, asked} -> {accounts, [a | asked]} end)
        {:unknown, {:auth_status, "cannot tell #{a}"}}
      else
        Accounts.ready(ctx.accounts, a)
      end
    end

    opts = ctx.mover_opts |> Keyword.put(:usable, usable) |> Keyword.put(:resume_wait, 1_000)
    GenServer.stop(mover())
    MoverSetup.restart(%{ctx | mover_opts: opts})

    {:ok, account} = Accounts.ready(ctx.accounts, "work")
    assert {:ok, %{pid: pid, session_id: sid}} = headless(ctx, "d1", account)
    write_transcript(ctx, "work", sid)

    # A turn that waits for a permission's answer holds the stop, so the check can turn unknown
    # after the pick and before the resume.
    held = fn ->
      assert {:ok, _} = stream_when(ctx, sid, & &1.idle)
      {:ok, %{uuid: u}} = Stream.write(ctx.stream, sid, {:message, "ask first"})
      assert {:ok, _} = stream_when(ctx, sid, &(&1.requests["req-" <> u][:state] == :held))
      "req-" <> u
    end

    req = held.()
    assert {:ok, %{act: act, to: "spare"}} = move(ctx, "d1")
    assert {:ok, _} = row_when(ctx, "d1", &(&1.move == "stopping"))
    Agent.update(untold, fn _ -> {["spare"], []} end)
    assert {:ok, _} = Stream.write(ctx.stream, sid, {:answer, req, :allow})

    # It waits, its process gone, asking again; past the deadline it goes back to `work`.
    assert {:ok, waiting} = row_when(ctx, "d1", &(&1.move == "resuming"))
    assert waiting.account == "work" and is_integer(waiting.move_deadline)

    past_deadline = fn ->
      Agent.update(ctx.clock, &(&1 + 2_000))
      Mover.cue(mover(), %{topic: "sessions"})
    end

    past_deadline.()
    assert {:ok, back} = row_when(ctx, "d1", &(moved?(&1, "work") and &1.pid != pid))
    assert back.session_id == sid
    refute alive?(pid)
    assert {_, asked} = Agent.get(untold, & &1)
    assert length(asked) >= 2 and Enum.all?(asked, &(&1 == "spare"))
    assert {:ok, %{outcome: "failed", reason: why}} = Acts.get(ctx.acts, act)
    assert why =~ "unknown_past_deadline" and why =~ "cannot tell spare"

    # Neither account can be told: past the deadline no process of it runs, and the fault ledger
    # names the unknown that ran out.
    Agent.update(untold, fn _ -> {[], []} end)
    req = held.()
    assert {:ok, %{to: "spare"}} = move(ctx, "d1")
    assert {:ok, _} = row_when(ctx, "d1", &(&1.move == "stopping"))
    Agent.update(untold, fn _ -> {["spare", "work"], []} end)
    assert {:ok, _} = Stream.write(ctx.stream, sid, {:answer, req, :allow})
    assert {:ok, _} = row_when(ctx, "d1", &(&1.move == "resuming"))
    past_deadline.()

    assert {:ok, %{status: "stopped", account: "work"}} = row_when(ctx, "d1", &(&1.move == nil))
    refute alive?(back.pid)

    assert {:ok, [%{outcome: "failed", reason: why}]} =
             Acts.rows(ctx.acts, actor: "mover:test", act: "move")

    assert why =~ "stranded" and why =~ "unknown_past_deadline" and why =~ "cannot tell work"
  end

  # F-189's new-3: a named account is read by `usable:` before the claim, as the pick reads one;
  # one not logged in is refused, and nothing begins.
  test "a move to a named account usable: refuses begins nothing", ctx do
    main(ctx)
    usable = fn a -> if a == "spare", do: {:refused, {:not_logged_in, a}}, else: {:ok, a} end
    ctx = %{ctx | mover_opts: Keyword.put(ctx.mover_opts, :usable, usable)}
    MoverSetup.restart(ctx)

    assert {:refused, {:account, "spare", {:not_logged_in, "spare"}}} =
             Mover.move(mover(), "operator", "main", to: "spare")

    assert %{account: "work", move: nil, status: "running"} = row(ctx, "main")

    assert {:refused, {:unknown_account, "nine"}} =
             Mover.move(mover(), "operator", "main", to: "nine")
  end

  test "a restart of the Mover goes on from the phase on the row", ctx do
    main = main(ctx)
    me = self()

    MoverSetup.set_launch(ctx, fn row ->
      send(me, {:launch, self()})

      receive do
        :go -> MoverSetup.launch(ctx.dir, row)
      after
        10_000 -> {:unknown, :no_go}
      end
    end)

    assert {:ok, %{act: act}} = move(ctx, "main")
    assert_receive {:launch, old}, 15_000
    assert %{move: "resuming", status: "stopped", account: "work"} = row(ctx, "main")

    # The Mover ends while it asks for the launch; the next one takes the row's step again.
    Process.exit(old, :kill)
    MoverSetup.set_launch(ctx, &MoverSetup.launch(ctx.dir, &1))
    MoverSetup.restart(ctx)
    assert {:ok, _} = row_when(ctx, "main", &moved?(&1, "spare"))
    assert {:ok, %{outcome: "verified"}} = Acts.get(ctx.acts, act)

    {:ok, cut} = Acts.claim(ctx.acts, "operator", "main", %{cut: 1}, :move)
    {:ok, :acted} = Acts.acted(ctx.acts, cut)
    GenServer.stop(mover())
    :sys.get_state(MoverSetup.restart(ctx))

    assert {:ok, %{status: "settled", outcome: "failed", reason: "interrupted"}} =
             Acts.get(ctx.acts, cut)

    refute alive?(main.pid)
  end

  # A delegate: SIGTERM once Stream's fold reads its turn ended, resumed with the same session
  # id on the other account; what came for it during the move goes once, to the new process.
  test "a delegate moves by SIGTERM once its turn ended, and takes what waited, once", ctx do
    {:ok, account} = Accounts.ready(ctx.accounts, "work")

    assert {:ok, %{session_id: sid}} = headless(ctx, "d1", account)
    write_transcript(ctx, "work", sid)
    me = self()

    MoverSetup.set_launch(ctx, fn row ->
      send(me, :launch)

      receive do
        :go -> MoverSetup.launch(ctx.dir, row)
      after
        10_000 -> {:unknown, :no_go}
      end
    end)

    assert {:ok, _} = move(ctx, "d1")
    assert_receive :launch, 15_000
    {:ok, {:queued, id}} = Mailbox.notify(ctx.mailbox, "d1", "go on")
    assert %{status: "queued", uuid: uuid} = mrow(ctx, id)
    assert HeadlessStandIn.taken(ctx.dir) == [first_taken()]

    send(mover(), :go)
    assert {:ok, moved} = row_when(ctx, "d1", &moved?(&1, "spare"))
    assert moved.session_id == sid
    assert "--resume" in HeadlessStandIn.argv(ctx.dir, sid)
    assert {:ok, _} = mrow_when(ctx, id, &(&1.status == "delivered"))
    assert HeadlessStandIn.taken(ctx.dir) == [first_taken(), "message #{uuid}"]
  end

  # Move.tla's OwnWord and HeadlessResumeHasLine (F-193): a headless delegate moved with nothing
  # due gets a word of the move's own, a notice from `framework` stored first, as its resume's
  # first line, so Claude Code writes its init and the resume is confirmed. Under BareHeadless
  # the stand-in, in the real release's shape, would never write one.
  test "a headless delegate moved with nothing due resumes with the move's own word", ctx do
    {:ok, account} = Accounts.ready(ctx.accounts, "work")
    assert {:ok, %{session_id: sid}} = headless(ctx, "d1", account)
    write_transcript(ctx, "work", sid)
    assert {:ok, _} = row_when(ctx, "d1", &Agents.running?/1)

    assert {:ok, %{act: act}} = move(ctx, "d1")
    assert {:ok, moved} = row_when(ctx, "d1", &moved?(&1, "spare"))
    assert moved.session_id == sid
    assert {:ok, %{outcome: "verified"}} = Acts.get(ctx.acts, act)

    assert [_, "message " <> word] = HeadlessStandIn.taken(ctx.dir)

    assert %{kind: "notice", from_agent: "framework", text: text} =
             Mailbox.Table.by_uuid(ctx.mtable, word)

    assert text =~ "moved between Claude accounts"
  end

  # Move.tla's LimitMove, Back and WordStored (F-191): a delegate whose process is gone at its
  # usage limit moves with no drain and no stop, the claim its caller made taken as the move's
  # own. Refused on the other account, it stays gone (NoResumeIntoLimit): never resumed on its
  # own account. Moved, its resume carries the word stored before it as its first line
  # (LimitResumeCarriesRow).
  test "a delegate gone at its limit moves with no stop, its word first; refused, it stays gone",
       ctx do
    {:ok, account} = Accounts.ready(ctx.accounts, "work")
    assert {:ok, %{session_id: sid}} = headless(ctx, "d1", account)
    write_transcript(ctx, "work", sid)
    reset = System.os_time(:second) + 3 * 3600
    File.write!(Path.join(ctx.dir, "limit"), "#{reset}")
    {:ok, _} = Mailbox.notify(ctx.mailbox, "d1", "work on")
    assert {:ok, gone} = row_when(ctx, "d1", &Agents.free?/1)
    File.rm!(Path.join(ctx.dir, "limit"))
    limit = %{"until" => reset, "step" => "move", "line" => "stream:x"}
    assert {:ok, _} = Sessions.put_limit(ctx.sessions, "d1", limit, from: nil)
    word = "5e1f0c2a-7b3d-5a4e-9c1b-2d3e4f5a6b7c"
    assert {:ok, {:queued, wid}} = Mailbox.go_on(ctx.mailbox, "d1", "go on", word)

    # Refused there: the act failed, the process still gone, its row on its own account.
    MoverSetup.set_launch(ctx, fn _row -> {:refused, :no_room} end)
    {:ok, act} = Acts.claim(ctx.acts, "limits:test", "d1", %{limit: reset}, :move)
    assert {:ok, %{act: ^act}} = Mover.move(mover(), "limits:test", "d1", to: "spare", act: act)
    assert {:ok, left} = row_when(ctx, "d1", &(&1.move == nil))
    assert %{status: "stopped", account: "work", pid: pid} = left
    assert pid == gone.pid
    assert {:ok, %{outcome: "failed", reason: why}} = Acts.get(ctx.acts, act)
    assert why =~ "no_room"
    assert %{status: "queued"} = mrow(ctx, wid)
    assert length(HeadlessStandIn.taken(ctx.dir)) == 2

    # A second move, a claim of its own: its resume's first line is the word.
    MoverSetup.set_launch(ctx, &MoverSetup.launch(ctx.dir, &1))
    {:ok, act} = Acts.claim(ctx.acts, "sam", "d1", %{limit: reset, by: "sam"}, :move)
    assert {:ok, %{act: ^act}} = Mover.move(mover(), "sam", "d1", to: "spare", act: act)
    assert {:ok, moved} = row_when(ctx, "d1", &moved?(&1, "spare"))
    assert moved.session_id == sid
    assert {:ok, %{outcome: "verified", actor: "sam"}} = Acts.get(ctx.acts, act)
    assert {:ok, _} = mrow_when(ctx, wid, &(&1.status == "delivered"))
    assert List.last(HeadlessStandIn.taken(ctx.dir)) == "message #{word}"
  end

  defp move(ctx, name), do: Mover.move(mover(), "operator", name, to: other(ctx, name))

  # A headless delegate's start, its first line written after the hold, as `Delegates`' is.
  defp headless(ctx, name, account),
    do:
      Sessions.start(
        ctx.sessions,
        name,
        account,
        MoverSetup.headless(ctx.dir) ++ MoverSetup.first()
      )

  defp first_taken, do: "message " <> MoverSetup.first()[:first].uuid

  defp other(ctx, name) do
    if row(ctx, name).account == "work", do: "spare", else: "work"
  end

  defp mover, do: Process.get(:mover)

  defp moved?(row, account),
    do: row.move == nil and row.status == "running" and row.account == account

  # The main session on `work`, with a transcript as Claude Code keeps it, and beside it a
  # directory of its own.
  defp main(ctx) do
    {:ok, account} = Accounts.ready(ctx.accounts, "work")

    {:ok, %{pid: pid, session_id: sid}} =
      Sessions.start(ctx.sessions, "main", account, MoverSetup.interactive(ctx.dir))

    Map.merge(%{pid: pid, sid: sid}, write_transcript(ctx, "work", sid))
  end

  defp write_transcript(ctx, account, sid) do
    p = paths(ctx, account, sid)
    File.mkdir_p!(Path.join(Path.rootname(p.transcript), "subagents"))
    File.write!(Path.join([Path.rootname(p.transcript), "subagents", "a.jsonl"]), "{}\n")
    File.write!(p.transcript, ~s({"type":"user","message":{"content":"go"}}\n))
    p
  end

  defp paths(ctx, account, sid) do
    dir = ctx.dirs[account]
    {:ok, transcript} = Transcripts.path(dir, ctx.dir, sid)
    %{transcript: transcript, settings: Path.join(dir, "framework/agents/main.settings.json")}
  end

  defp row(ctx, name), do: Agents.get(ctx.agents, name)

  defp row_when(ctx, name, ready?) do
    await(
      fn ->
        row = row(ctx, name)
        if row && ready?.(row), do: {:ok, row}, else: row
      end,
      20_000
    )
  end

  # The `Stream`'s row of the session's latest process, once `ready?` holds; the `Stream` reads
  # each log on its interval.
  defp stream_when(ctx, sid, ready?) do
    await(fn ->
      {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
      row = rows |> Enum.filter(&(&1.session == sid)) |> List.last()
      if row && ready?.(row) == true, do: {:ok, row}, else: row
    end)
  end

  defp mrow(ctx, id), do: Mailbox.Table.get(ctx.mtable, id)

  defp mrow_when(ctx, id, ready?, topic \\ "transcripts:test:spare") do
    await(
      fn ->
        transcript_cue(ctx, topic)
        row = mrow(ctx, id)
        if ready?.(row), do: {:ok, row}, else: row
      end,
      15_000
    )
  end

  # A transcript's cue, the one a waiter row's lines are read on; a call after the cast answers
  # once it is handled.
  defp transcript_cue(ctx, topic) do
    Mailbox.cue(ctx.mailbox, %{topic: topic, ids: []})
    Mailbox.status(ctx.mailbox, 0)
  end

  defp file_says(ctx, account, status) do
    dir = Path.join(ctx.dirs[account], "sessions")

    await(fn ->
      Enum.find_value(File.ls!(dir), fn file ->
        case File.read(Path.join(dir, file)) do
          {:ok, text} -> if text =~ ~s("status": "#{status}"), do: {:ok, status}
          _ -> nil
        end
      end)
    end)
  end

  defp lines_with(path, text),
    do: path |> File.read!() |> String.split("\n") |> Enum.count(&String.contains?(&1, text))
end
