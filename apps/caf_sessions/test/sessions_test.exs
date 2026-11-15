defmodule CodingAgentFramework.SessionsTest do
  @moduledoc """
  `Sessions` on a real tmux server and real dtach sockets in this test's own directory, with a
  stand-in for Claude Code (`CodingAgentFramework.ClaudeStandIn`). Each test waits on what the
  stand-in writes and on the rows `Sessions` writes, never on a fixed sleep. Deadlines come from
  the test's own clock, which a test moves on instead of waiting. The tests of F-25 each close one
  of F-21's findings; each names the `Start.tla` action it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.SessionsSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{ClaudeStandIn, Control, Holder, Registry, Sessions, SessionsSetup}
  alias CodingAgentFramework.Sessions.Table

  setup {SessionsSetup, :sessions}

  test "a resume holds the stand-in with --resume and its id", ctx do
    assert {:ok, %{session_id: "earlier-1"}} =
             Sessions.resume(
               ctx.sessions,
               "beta",
               ctx.account,
               "earlier-1",
               launch(ctx, :at_start)
             )

    assert %{status: "running", resume: "earlier-1"} = Table.get(ctx.table, "test", "beta")
  end

  test "a start whose session file never comes answers unknown, and its row says so", ctx do
    assert {:unknown, :no_session_file} = unknown_start(ctx, "gamma", launch(ctx, :never))

    assert %{status: "unknown", reason: "no_session_file", pid: nil} =
             Table.get(ctx.table, "test", "gamma")
  end

  test "new-1: Adopt waits for the start's deadline, so a slow file is adopted", ctx do
    slow = start_task(ctx, "slow", launch(ctx, :on_go))
    assert {:ok, _} = row_when(ctx, "slow", &(&1.viewer == "open"))
    sessions = restart(ctx, slow)

    # Before the deadline the adoption decides nothing.
    assert %{status: "starting"} = Table.get(ctx.table, "test", "slow")
    assert {:ok, :sent} = Control.send(ctx.control, "slow", "go")
    assert {:ok, _} = file_written(ctx)
    cue(ctx, sessions)
    assert {:ok, %{pid: pid}} = row_when(ctx, "slow", &(&1.status == "running"))
    assert alive?(pid)
  end

  test "new-2: past the deadline, Adopt makes a live socket an orphan, a dead one refused", ctx do
    # Every stand-in is written before the first start runs one (F-39).
    {dead_dir, dead_launch} = own_dir(ctx, "dead", :never)
    orphan = start_task(ctx, "orphan", launch(ctx, :never))
    dead = start_task(ctx, "dead", dead_launch)
    assert {:ok, _} = row_when(ctx, "orphan", &(&1.viewer != nil))
    assert {:ok, _} = row_when(ctx, "dead", &(&1.viewer != nil))
    Process.exit(ctx.sessions, :kill)
    assert {:unknown, {:exit, :killed}} = Task.await(orphan)
    assert {:unknown, {:exit, :killed}} = Task.await(dead)
    kill_held(ctx, dead_dir, "dead")

    advance(ctx)
    restart(ctx, nil)
    assert {:ok, row} = row_when(ctx, "orphan", &(&1.status == "orphan"))
    assert row.reason == "no_session_file"
    # Sessions never kills: the orphan's process runs on, for Recoveries.
    assert {:ok, :live} = Holder.state(ctx.holder, "orphan")
    assert {:ok, %{reason: "interrupted"}} = row_when(ctx, "dead", &(&1.status == "refused"))
  end

  test "new-3: a read that fails decides nothing, so the row stays starting", ctx do
    blind = start_task(ctx, "blind", launch(ctx, :never))
    assert {:ok, _} = row_when(ctx, "blind", &(&1.viewer != nil))
    advance(ctx)
    gone = spawn(fn -> :ok end)
    sessions = restart(ctx, blind, registries: %{"work" => gone})
    :sys.get_state(sessions)
    assert %{status: "starting"} = Table.get(ctx.table, "test", "blind")

    # With a Registry that answers, the same row is decided.
    stop_supervised!(:again)
    restart(ctx, nil)
    assert {:ok, _} = row_when(ctx, "blind", &(&1.status == "orphan"))
  end

  test "new-4: StopSettled after a restart, by the row's pid and start time", ctx do
    assert {:ok, _} = Sessions.start(ctx.sessions, "kept", ctx.account, launch(ctx, :at_start))

    assert {:ok, %{pid: reused}} =
             Sessions.start(ctx.sessions, "reused", ctx.account, launch(ctx, :at_start))

    Process.exit(ctx.sessions, :kill)
    # A restart in the middle of two stops; the second row's pid now names another process.
    Table.update(ctx.table, Table.get(ctx.table, "test", "kept").id, status: "stopping")
    other = [status: "stopping", proc_start: "Thu Jan  1 00:00:00 1970"]
    Table.update(ctx.table, Table.get(ctx.table, "test", "reused").id, other)

    restart(ctx, nil)
    assert {:ok, _} = row_when(ctx, "kept", &(&1.status == "running"))
    assert {:ok, _} = row_when(ctx, "reused", &(&1.status == "stopped"))
    assert alive?(reused)
  end

  test "new-5: ReRead makes an unknown row running or stopped", ctx do
    {lost_dir, launch} = own_dir(ctx, "lost", :never)
    late = Task.async(fn -> unknown_start(ctx, "late", launch(ctx, :on_go)) end)
    lost = Task.async(fn -> unknown_start(ctx, "lost", launch) end)
    assert {:unknown, :no_session_file} = Task.await(late, 15_000)
    assert {:unknown, :no_session_file} = Task.await(lost, 15_000)

    assert {:ok, :sent} = Control.send(ctx.control, "late", "go")
    assert {:ok, _} = file_written(ctx)
    kill_held(ctx, lost_dir, "lost")
    cue(ctx, ctx.sessions)
    assert {:ok, %{pid: pid}} = row_when(ctx, "late", &(&1.status == "running"))
    assert alive?(pid)
    assert {:ok, _} = row_when(ctx, "lost", &(&1.status == "stopped"))
  end

  test "new-6: RowWritten does not take the name of an unknown row", ctx do
    assert {:unknown, :no_session_file} = unknown_start(ctx, "taken", launch(ctx, :never))

    assert {:refused, {:exists, "unknown"}} =
             Sessions.start(ctx.sessions, "taken", ctx.account, launch(ctx, :at_start))

    assert {:ok, :live} = Holder.state(ctx.holder, "taken")
    assert %{status: "unknown"} = Table.get(ctx.table, "test", "taken")
  end

  test "new-7: a hold that answers unknown waits for the file (Held)", ctx do
    # A dtach whose `-n` holds the process and then exits 3, so the hold answers unknown.
    wrapper = Path.join(ctx.dir, "dtach-unsure")
    real = program!(:dtach)

    File.write!(wrapper, """
    #!#{program!(:sh)}
    if [ "$1" = -n ]; then "#{real}" "$@"; exit 3; fi
    exec "#{real}" "$@"
    """)

    File.chmod!(wrapper, 0o755)
    stop_supervised!(Sessions)
    opts = Keyword.put(ctx.opts, :programs, programs(host(), %{dtach: wrapper}))
    sessions = start_supervised!(Supervisor.child_spec({Sessions, opts}, id: :unsure))

    assert {:ok, %{pid: pid}} =
             Sessions.start(sessions, "unsure", ctx.account, launch(ctx, :at_start))

    assert %{status: "running", pid: ^pid} = Table.get(ctx.table, "test", "unsure")
  end

  test "new-9: StopTimedOut leaves the row stopping, late, for Recoveries", ctx do
    assert {:ok, %{pid: pid}} =
             Sessions.start(ctx.sessions, "deaf", ctx.account, launch(ctx, :at_start))

    # Stopped by signal, it cannot read `/exit` until it is continued.
    assert {:ok, %{status: 0}} = kill(pid, "-STOP")
    stop = Task.async(fn -> Sessions.stop(ctx.sessions, "deaf", :ended) end)
    assert {:ok, _} = row_when(ctx, "deaf", &(&1.status == "stopping"))
    advance(ctx)
    assert {:unknown, {:no_exit, {:ok, :sent}}} = Task.await(stop)
    assert %{reason: "no_exit", deadline: d} = Table.get(ctx.table, "test", "deaf")
    assert is_integer(d)

    # Neither a cue nor a restart sets a late stop back to running.
    cue(ctx, ctx.sessions)
    sessions = restart(ctx, nil)
    :sys.get_state(sessions)
    assert %{status: "stopping"} = Table.get(ctx.table, "test", "deaf")

    assert {:ok, %{status: 0}} = kill(pid, "-CONT")
    assert {:ok, :gone} = await(fn -> if not alive?(pid), do: {:ok, :gone} end)
    cue(ctx, sessions)
    assert {:ok, _} = row_when(ctx, "deaf", &(&1.status == "stopped"))
  end

  test "F-61: RunningSettled stops a running row whose process was killed; the name resumes",
       ctx do
    {dir, crashed} = own_dir(ctx, "crashed", :at_start)

    assert {:ok, %{session_id: id}} =
             Sessions.start(ctx.sessions, "crashed", ctx.account, crashed)

    assert {:ok, %{pid: kept}} =
             Sessions.start(ctx.sessions, "kept", ctx.account, launch(ctx, :at_start))

    # The test kills the process by the pid its stand-in recorded; its socket is then absent.
    kill_held(ctx, dir, "crashed")
    cue(ctx, ctx.sessions)
    assert {:ok, %{reason: "exited"}} = row_when(ctx, "crashed", &(&1.status == "stopped"))
    # The same settle read the live process and kept its row running.
    assert %{status: "running"} = Table.get(ctx.table, "test", "kept")
    assert alive?(kept)

    # The socket is read too: a row whose start time reads as another process's stays running
    # while its socket is live.
    Table.update(ctx.table, Table.get(ctx.table, "test", "kept").id,
      proc_start: "Thu Jan  1 1970"
    )

    cue(ctx, ctx.sessions)
    :sys.get_state(ctx.sessions)
    assert %{status: "running"} = Table.get(ctx.table, "test", "kept")

    assert {:ok, %{session_id: ^id}} =
             Sessions.resume(ctx.sessions, "crashed", ctx.account, id, launch(ctx, :at_start))

    assert %{status: "running", resume: ^id, reason: nil} =
             Table.get(ctx.table, "test", "crashed")
  end

  defp start_task(ctx, name, launch),
    do: Task.async(fn -> Sessions.start(ctx.sessions, name, ctx.account, launch) end)

  # A start that waits for its file until the test's clock passes its deadline.
  defp unknown_start(ctx, name, launch) do
    task = start_task(ctx, name, launch)
    {:ok, _} = row_when(ctx, name, &(&1.viewer != nil))
    advance(ctx)
    Task.await(task)
  end

  # Moves the test's clock past every deadline (30 s by default).
  defp advance(ctx), do: Agent.update(ctx.clock, &(&1 + 60_000))

  # Kills this test's Sessions mid-call, then starts another on the same table.
  defp restart(ctx, call, opts \\ []) do
    if Process.alive?(ctx.sessions), do: Process.exit(ctx.sessions, :kill)
    if call, do: {:unknown, {:exit, :killed}} = Task.await(call)
    child = {Sessions, Keyword.merge(ctx.opts, opts)}
    start_supervised!(Supervisor.child_spec(child, id: :again, restart: :temporary))
  end

  # The Registry reads, and its cue reaches Sessions as the host app would wire it.
  defp cue(ctx, sessions) do
    {:ok, _} = Registry.read(ctx.registry)
    Sessions.cue(sessions, %{topic: "registry:test:work", ids: []})
  end

  defp file_written(ctx) do
    sessions = Path.join(ctx.account.config_dir, "sessions")
    await(fn -> if File.ls!(sessions) != [], do: {:ok, :written} end)
  end

  # A stand-in in a directory of its own, so the test can end just it, by its pid.
  defp own_dir(ctx, name, mode) do
    dir = Path.join(ctx.dir, name)
    File.mkdir_p!(dir)
    {dir, Keyword.put(launch(ctx, mode), :claude, ClaudeStandIn.write!(dir, mode))}
  end

  defp kill_held(ctx, dir, name) do
    pids = Path.join(dir, "pids")
    {:ok, _} = await(fn -> if File.ls!(pids) != [], do: {:ok, :recorded} end)
    ClaudeStandIn.kill_all(dir)
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
end
