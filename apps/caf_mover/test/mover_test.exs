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
  alias CodingAgentFramework.{HeadlessStandIn, Transcripts, WaiterStandIn}
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
    user = %{"type" => "user", "message" => %{"content" => "report one\n\n[delivery #{u1}]"}}
    File.write!(spare.transcript, [JSON.encode!(user), "\n"], [:append])
    assert {:ok, _} = mrow_when(ctx, one, &(&1.status == "delivered"))

    # That turn's end brings the new process's first waiter, which takes row two.
    turn = WaiterStandIn.turn_end(spare.settings, main.sid, spare.transcript, :idle)
    assert {2, "report two" <> _} = Task.await(turn, 10_000)
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
    {:ok, _} = CodingAgentFramework.Registry.read(ctx.registry)
    :sys.get_state(mover())
    assert alive?(main.pid)

    # It ends: the file says idle, and the move goes on.
    assert {:ok, :sent} = MoverSetup.type(ctx, "main", "idle")
    assert {:ok, _} = row_when(ctx, "main", &moved?(&1, "spare"))
    refute alive?(main.pid)

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

    assert {:ok, %{session_id: sid}} =
             Sessions.start(ctx.sessions, "d1", account, MoverSetup.headless(ctx.dir))

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
    assert HeadlessStandIn.taken(ctx.dir) == []

    send(mover(), :go)
    assert {:ok, moved} = row_when(ctx, "d1", &moved?(&1, "spare"))
    assert moved.session_id == sid
    assert "--resume" in HeadlessStandIn.argv(ctx.dir, sid)
    assert {:ok, _} = mrow_when(ctx, id, &(&1.status == "delivered"))
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{uuid}"]
  end

  defp move(ctx, name), do: Mover.move(mover(), "operator", name, to: other(ctx, name))

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
