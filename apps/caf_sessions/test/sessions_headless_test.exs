defmodule CodingAgentFramework.SessionsHeadlessTest do
  @moduledoc """
  `Sessions` with headless delegates (`docs/design.md`, "Headless delegates"): a stand-in for
  headless Claude Code (`CodingAgentFramework.HeadlessStandIn`) held by real dtach through
  `ClaudeCLI`'s wrapper, its log read by a real `Stream`, its viewer on a real tmux server, all
  in this test's own directory. Each test waits on what the stand-in writes and on the rows, and
  moves the test's clock instead of waiting for a deadline. Each names the `Start.tla` actions
  it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.SessionsSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{HeadlessStandIn, Holder, Sessions, SessionsSetup, Stream}
  alias CodingAgentFramework.Sessions.Table

  setup {SessionsSetup, :sessions}

  test "a start is confirmed by its first event and the pid its wrapper recorded", ctx do
    # RowWritten, Held, ViewerOpened, StartDecided.
    assert {:ok, %{name: "d1", pid: pid, session_id: id}} =
             Sessions.start(ctx.sessions, "d1", ctx.account, headless(ctx, :at_start))

    assert File.ls!(Path.join(ctx.dir, "pids")) == [Integer.to_string(pid)]

    assert %{status: "running", role: "delegate", session_id: ^id, pid: ^pid, viewer: "open"} =
             row = Table.get(ctx.table, "test", "d1")

    assert is_binary(row.proc_start)
    assert %{socket: "d1", session_id: ^id} = stream_row(ctx, id)

    # The viewer follows the log; it renders nothing yet.
    assert {:ok, _} =
             await(fn -> if viewer(ctx, "d1") =~ ~s("subtype":"init"), do: {:ok, :shown} end)
  end

  test "a start whose first event never comes is unknown; ReRead settles it either way", ctx do
    # StartDecided past the deadline, then ReRead: running once the init comes, stopped once
    # the socket is dead.
    {gone_dir, never} = own_dir(ctx, "gone", :never)
    late = Task.async(fn -> unknown_start(ctx, "late", headless(ctx, :on_message)) end)
    gone = Task.async(fn -> unknown_start(ctx, "gone", never) end)
    assert {:unknown, :no_first_event} = Task.await(late, 15_000)
    assert {:unknown, :no_first_event} = Task.await(gone, 15_000)

    assert %{status: "unknown", reason: "no_first_event", pid: nil, session_id: id} =
             Table.get(ctx.table, "test", "late")

    assert {:ok, _} = Stream.write(ctx.stream, id, {:message, "wake"})
    stream_row(ctx, id, &(&1.session_id == id))
    kill_held(ctx, gone_dir, "gone")
    cue(ctx, ctx.sessions)
    assert {:ok, %{pid: pid}} = row_when(ctx, "late", &(&1.status == "running"))
    assert alive?(pid)
    assert {:ok, _} = row_when(ctx, "gone", &(&1.status == "stopped"))
  end

  test "a stop writes end_session only after the report and the turn, and sees the exit by pid",
       ctx do
    # StopAsked, StopSettled.
    assert {:ok, %{pid: pid, session_id: id}} =
             Sessions.start(ctx.sessions, "d3", ctx.account, headless(ctx, :at_start))

    {:ok, %{uuid: u}} = Stream.write(ctx.stream, id, {:message, "ask first"})
    stream_row(ctx, id, &(&1.requests["req-" <> u].state == :held))

    # A delegate's end waits for the caller's word that its report is delivered (new-5); the
    # caller's reading of the turn is not read, Stream's row is.
    assert {:refused, {:report, :ended}} = Sessions.stop(ctx.sessions, "d3", :ended)
    assert {:refused, :turn_running} = Sessions.stop(ctx.sessions, "d3", :report_delivered)
    assert %{status: "running"} = Table.get(ctx.table, "test", "d3")

    assert {:ok, _} = Stream.write(ctx.stream, id, {:answer, "req-" <> u, :allow})
    stream_row(ctx, id, & &1.idle)
    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "d3", :report_delivered)
    refute alive?(pid)
    assert %{status: "stopped"} = Table.get(ctx.table, "test", "d3")
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}", "answer req-#{u}", "end"]
  end

  test "a resume appends to the same log, read on from the offset Stream saved", ctx do
    assert {:ok, %{pid: first, session_id: id}} =
             Sessions.start(ctx.sessions, "d4", ctx.account, headless(ctx, :at_start))

    {:ok, %{uuid: u1}} = Stream.write(ctx.stream, id, {:message, "before"})
    before = stream_row(ctx, id, &(&1.messages[u1].state == :delivered and &1.idle))
    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "d4", :report_delivered)
    # The process is gone by pid; its dtach master ends a moment later.
    {:ok, :absent} = await(fn -> absent(Holder.state(ctx.holder, "d4")) end)

    assert {:ok, %{pid: second, session_id: ^id}} =
             Sessions.resume(ctx.sessions, "d4", ctx.account, id, headless(ctx, :at_start))

    assert second != first
    assert %{status: "running", resume: ^id} = Table.get(ctx.table, "test", "d4")

    {:ok, %{uuid: u2}} = Stream.write(ctx.stream, id, {:message, "after"})
    resumed = stream_row(ctx, id, &(&1.messages[u2].state == :delivered and &1.idle))
    assert resumed.offset > before.offset
    assert resumed.messages[u1].state == :delivered
    assert resumed.problems == 0

    log = File.read!(Path.join([Stream.dir(ctx.dir, id), "events.jsonl"]))
    assert length(String.split(log, ~s("subtype":"init"))) == 3
    # Each process read its own FIFO (new-1).
    fifos = Stream.dir(ctx.dir, id) |> File.ls!() |> Enum.filter(&(&1 =~ "in.")) |> Enum.sort()
    assert fifos == ["in.0", "in.1"]
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u1}", "end", "message #{u2}"]
  end

  test "a delegate that exits before any read is seen gone, since its hold was told", ctx do
    # HeldTold (Stream.tla): no read saw it live, yet Stream sees its exit (new-3).
    launch = Keyword.put(headless(ctx, :at_start), :claude, program!(true))
    assert {:unknown, :no_first_event} = unknown_start(ctx, "brief", launch)
    assert %{session_id: id} = Table.get(ctx.table, "test", "brief")
    assert %{gone: true} = stream_row(ctx, id, & &1.gone)
  end

  test "after a restart, a starting delegate is adopted when its first event comes", ctx do
    # Adopt: running.
    slow = start_task(ctx, "slow", headless(ctx, :on_message))
    assert {:ok, %{session_id: id}} = row_when(ctx, "slow", &(&1.viewer == "open"))
    sessions = restart(ctx, slow)
    assert %{status: "starting"} = Table.get(ctx.table, "test", "slow")

    assert {:ok, _} = Stream.write(ctx.stream, id, {:message, "go"})
    stream_row(ctx, id, &(&1.session_id == id))
    Sessions.cue(sessions, %{topic: "stream:test", ids: []})
    assert {:ok, %{pid: pid}} = row_when(ctx, "slow", &(&1.status == "running"))
    assert alive?(pid)
  end

  test "after a restart, past the deadline, a live delegate is an orphan, a dead one refused",
       ctx do
    # Adopt: orphan, refused{interrupted}.
    {dead_dir, dead_launch} = own_dir(ctx, "dead", :never)
    orphan = start_task(ctx, "orphan", headless(ctx, :never))
    dead = start_task(ctx, "dead", dead_launch)
    assert {:ok, _} = row_when(ctx, "orphan", &(&1.viewer != nil))
    assert {:ok, _} = row_when(ctx, "dead", &(&1.viewer != nil))
    Process.exit(ctx.sessions, :kill)
    assert {:unknown, {:exit, :killed}} = Task.await(orphan)
    assert {:unknown, {:exit, :killed}} = Task.await(dead)
    kill_held(ctx, dead_dir, "dead")

    advance(ctx)
    restart(ctx, nil)
    assert {:ok, %{reason: "no_first_event"}} = row_when(ctx, "orphan", &(&1.status == "orphan"))
    assert {:ok, :live} = Holder.state(ctx.holder, "orphan")
    assert {:ok, %{reason: "interrupted"}} = row_when(ctx, "dead", &(&1.status == "refused"))
  end

  test "after a restart, a stopping delegate is settled by its pid and start time", ctx do
    # StopSettled with no stop under way: stopped when gone, running when it lives.
    {gone_dir, gone_launch} = own_dir(ctx, "ended", :at_start)
    assert {:ok, _} = Sessions.start(ctx.sessions, "kept", ctx.account, headless(ctx, :at_start))
    assert {:ok, _} = Sessions.start(ctx.sessions, "ended", ctx.account, gone_launch)
    Process.exit(ctx.sessions, :kill)

    for name <- ~w(kept ended),
        do: Table.update(ctx.table, Table.get(ctx.table, "test", name).id, status: "stopping")

    kill_held(ctx, gone_dir, "ended")
    restart(ctx, nil)
    assert {:ok, %{pid: pid}} = row_when(ctx, "kept", &(&1.status == "running"))
    assert alive?(pid)
    assert {:ok, _} = row_when(ctx, "ended", &(&1.status == "stopped"))
  end

  test "a running delegate killed before its last reply is settled stopped, then resumed", ctx do
    # RunningSettled (F-61): gone by pid and start time, its socket dead; a live one stays.
    {dir, killed} = own_dir(ctx, "killed", :at_start)
    assert {:ok, %{session_id: id}} = Sessions.start(ctx.sessions, "killed", ctx.account, killed)

    assert {:ok, %{pid: pid}} =
             Sessions.start(ctx.sessions, "kept", ctx.account, headless(ctx, :at_start))

    kill_held(ctx, dir, "killed")
    cue(ctx, ctx.sessions)
    assert {:ok, %{reason: "exited"}} = row_when(ctx, "killed", &(&1.status == "stopped"))
    assert %{status: "running"} = Table.get(ctx.table, "test", "kept")
    assert alive?(pid)

    assert {:ok, %{session_id: ^id}} =
             Sessions.resume(ctx.sessions, "killed", ctx.account, id, headless(ctx, :at_start))

    assert %{status: "running", resume: ^id} = Table.get(ctx.table, "test", "killed")
  end

  defp start_task(ctx, name, launch),
    do: Task.async(fn -> Sessions.start(ctx.sessions, name, ctx.account, launch) end)

  # A start that waits for its first event until the test's clock passes its deadline.
  defp unknown_start(ctx, name, launch) do
    task = start_task(ctx, name, launch)
    {:ok, _} = row_when(ctx, name, &(&1.viewer != nil))
    advance(ctx)
    Task.await(task)
  end

  defp advance(ctx), do: Agent.update(ctx.clock, &(&1 + 60_000))

  # Kills this test's Sessions mid-call, then starts another on the same table and Stream.
  defp restart(ctx, call) do
    if Process.alive?(ctx.sessions), do: Process.exit(ctx.sessions, :kill)
    if call, do: {:unknown, {:exit, :killed}} = Task.await(call)
    child = {Sessions, ctx.opts}
    start_supervised!(Supervisor.child_spec(child, id: :again, restart: :temporary))
  end

  # Stream reads, and its cue reaches Sessions as the host app would wire it.
  defp cue(ctx, sessions) do
    {:ok, _} = Stream.read(ctx.stream)
    Sessions.cue(sessions, %{topic: "stream:test", ids: []})
  end

  # A stand-in in a directory of its own, so the test can end just it, by its pid.
  defp own_dir(ctx, name, mode) do
    dir = Path.join(ctx.dir, name)
    File.mkdir_p!(dir)
    on_exit(fn -> end_recorded(dir) end)
    {dir, Keyword.put(headless(ctx, mode), :claude, HeadlessStandIn.write!(dir, mode))}
  end

  defp kill_held(ctx, dir, name) do
    pids = Path.join(dir, "pids")
    {:ok, _} = await(fn -> if File.ls!(pids) != [], do: {:ok, :recorded} end)
    HeadlessStandIn.kill_all(dir)
    {:ok, :absent} = await(fn -> absent(Holder.state(ctx.holder, name)) end, 10_000)
  end

  defp absent({:ok, :absent}), do: {:ok, :absent}
  defp absent(other), do: {:not_yet, other}

  defp row_when(ctx, name, ready?) do
    await(
      fn ->
        row = Table.get(ctx.table, "test", name)
        if row && ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end

  # Reads until Stream's row of session `id` satisfies `ok?`, and answers it.
  defp stream_row(ctx, id, ok? \\ fn _ -> true end) do
    {:ok, row} =
      await(fn ->
        {:ok, _} = Stream.read(ctx.stream)
        {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
        row = Enum.find(rows, &(&1.session == id))
        if row && safe(ok?, row), do: {:ok, row}, else: row
      end)

    row
  end

  defp safe(ok?, row) do
    ok?.(row) == true
  rescue
    _ -> false
  end

  # What the viewer pane of `session` shows, from this test's own tmux server.
  defp viewer(ctx, session) do
    socket = Path.join(ctx.dir, "tmux.sock")
    args = ["-S", socket, "capture-pane", "-p", "-t", "=#{session}:"]
    {out, _} = System.cmd(program!(:tmux), args, stderr_to_stdout: true)
    out
  end
end
