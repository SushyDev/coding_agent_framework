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
  import ExUnit.CaptureLog

  alias CodingAgentFramework.{Acts, ClaudeStandIn, Holder, Registry, Sessions}
  alias CodingAgentFramework.SessionsSetup
  alias CodingAgentFramework.TmuxSampler
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
    assert {:ok, :sent} = SessionsSetup.type(ctx, "slow", "go")
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
    # With the held program's record, for Recoveries (F-118).
    assert is_integer(row.pid) and is_binary(row.proc_start)
    # Sessions never kills: the orphan's process runs on, for Recoveries.
    assert {:ok, :live} = Holder.state(ctx.holder, "orphan")
    assert {:ok, %{reason: "interrupted"}} = row_when(ctx, "dead", &(&1.status == "refused"))
  end

  # F-126's new-1: a start is a row of `Acts`, written before the agent row and settled by the
  # call's answer; one a restart of `Sessions` cut is closed as interrupted when it starts again.
  test "each start is a row of Acts, settled by its answer, interrupted when cut", ctx do
    acts_db = Path.join(ctx.dir, "acts.db")
    acts = start_supervised!({Acts, db: acts_db, start_id: "t", host: "test", instance: "a"})
    sessions = restart(ctx, nil, acts: acts)
    ctx = %{ctx | sessions: sessions}

    assert {:ok, _} = Sessions.start(sessions, "alpha", ctx.account, launch(ctx, :at_start))
    cut = start_task(ctx, "cut", launch(ctx, :never))
    assert {:ok, _} = row_when(ctx, "cut", &(&1.viewer != nil))
    Process.exit(sessions, :kill)
    assert {:unknown, {:exit, :killed}} = Task.await(cut)

    child = {Sessions, Keyword.put(ctx.opts, :acts, acts)}
    again = start_supervised!(Supervisor.child_spec(child, id: :third, restart: :temporary))
    :sys.get_state(again)

    assert {:ok, [alpha, cut]} = Acts.rows(acts, actor: "sessions:test")
    assert %{target: "alpha", act: "start", status: "settled", outcome: "verified"} = alpha
    assert %{target: "cut", act: "start", status: "interrupted", state: nil} = cut
  end

  test "new-3: a read that fails decides nothing, so the row stays starting", ctx do
    blind = start_task(ctx, "blind", launch(ctx, :never))
    assert {:ok, _} = row_when(ctx, "blind", &(&1.viewer != nil))
    advance(ctx)
    gone = spawn(fn -> :ok end)
    sessions = restart(ctx, blind, registry: gone)
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
    # A restart in the middle of two stops; the second row's pid now names another process, and
    # its socket has ended (F-64: a stop is done only then).
    Table.update(ctx.table, Table.get(ctx.table, "test", "kept").id, status: "stopping")
    other = [status: "stopping", proc_start: "Thu Jan  1 00:00:00 1970", socket: "gone"]
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

    assert {:ok, :sent} = SessionsSetup.type(ctx, "late", "go")
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

  test "F-118: a stop sends SIGTERM only once the session file says idle (StopAsked)", ctx do
    {_dir, own} = own_dir(ctx, "turn", :at_start)
    assert {:ok, %{pid: pid}} = Sessions.start(ctx.sessions, "turn", ctx.account, own)

    # A turn runs: the file says busy, the stop is refused, and nothing was sent.
    assert {:ok, :sent} = SessionsSetup.type(ctx, "turn", "busy")
    assert {:ok, _} = file_says(ctx, "busy")
    assert {:refused, {:not_idle, "busy"}} = Sessions.stop(ctx.sessions, "turn")
    assert %{status: "running"} = Table.get(ctx.table, "test", "turn")
    assert alive?(pid)

    # The turn ends: SIGTERM, the stand-in exits 143 as Claude Code does, and the row stops.
    assert {:ok, :sent} = SessionsSetup.type(ctx, "turn", "idle")
    assert {:ok, _} = file_says(ctx, "idle")
    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "turn")
    refute alive?(pid)
  end

  # F-122's new-1 (Delivery.tla's IdleRead): a row Mailbox marked before the stop may still
  # become a turn, so the idle read waits for it, read through `open_to:`; queued rows are not
  # waited for, since Mailbox marks none to a stopping session.
  test "a stop waits, idle, until no Mailbox row to the session is sending", ctx do
    assert {:ok, %{pid: pid}} =
             Sessions.start(ctx.sessions, "held", ctx.account, launch(ctx, :at_start))

    Agent.update(
      ctx.open,
      &Map.merge(&1, %{{"held", :sending} => [4], {"held", :open} => [4, 5]})
    )

    stop = Task.async(fn -> Sessions.stop(ctx.sessions, "held") end)
    assert {:ok, _} = row_when(ctx, "held", &(&1.status == "stopping"))
    assert alive?(pid)

    # The row settles: the SIGTERM goes, with row 5 still queued.
    Agent.update(ctx.open, &Map.delete(&1, {"held", :sending}))
    assert {:ok, :stopped} = Task.await(stop, 10_000)
    refute alive?(pid)

    # Past the stop's deadline with a row still sending: refused, nothing sent, running again.
    assert {:ok, %{pid: pid}} =
             Sessions.resume(ctx.sessions, "held", ctx.account, "s-held", launch(ctx, :at_start))

    Agent.update(ctx.open, &Map.put(&1, {"held", :sending}, [6]))
    stop = Task.async(fn -> Sessions.stop(ctx.sessions, "held") end)
    assert {:ok, _} = row_when(ctx, "held", &(&1.status == "stopping"))
    advance(ctx)
    assert {:refused, {:sending, [6]}} = Task.await(stop, 10_000)
    assert %{status: "running"} = Table.get(ctx.table, "test", "held")
    assert alive?(pid)
  end

  test "new-9: StopTimedOut leaves the row stopping, late, for Recoveries", ctx do
    assert {:ok, %{pid: pid}} =
             Sessions.start(ctx.sessions, "deaf", ctx.account, launch(ctx, :at_start))

    # Stopped by signal, it acts on its SIGTERM only once it is continued.
    assert {:ok, %{status: 0}} = kill(pid, "-STOP")
    stop = Task.async(fn -> Sessions.stop(ctx.sessions, "deaf") end)
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
    assert {:ok, _} = cued_row_when(ctx, sessions, "deaf", &(&1.status == "stopped"))
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

    assert {:ok, %{reason: "exited"}} =
             cued_row_when(ctx, ctx.sessions, "crashed", &(&1.status == "stopped"))

    # Each settle read the live process too, and kept its row running.
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

  test "F-67: a ps that fails decides nothing and the log says why; the next cue settles", ctx do
    {dir, flaky} = own_dir(ctx, "flaky", :at_start)
    assert {:ok, _} = Sessions.start(ctx.sessions, "flaky", ctx.account, flaky)
    kill_held(ctx, dir, "flaky")

    # A Sessions whose ps fails, as one that could not run under load does, while `failing` is
    # there.
    failing = Path.join(ctx.dir, "ps-failing")
    File.write!(failing, "")
    ps = failing_ps(ctx, failing)
    sessions = restart(ctx, nil, programs: programs(host(), %{ps: ps}))

    log =
      capture_log(fn ->
        cue(ctx, sessions)
        :sys.get_state(sessions)
      end)

    assert log =~ "settle of running flaky decided nothing: process :unknown"
    assert %{status: "running"} = Table.get(ctx.table, "test", "flaky")

    # The ps runs again: the next cue settles the row, as a host's next read does.
    File.rm!(failing)

    assert {:ok, %{reason: "exited"}} =
             cued_row_when(ctx, sessions, "flaky", &(&1.status == "stopped"))
  end

  test "F-64: a stop is done only when its socket has ended too; the name then resumes", ctx do
    {dir, hold, lingers} = linger(ctx, "linger")

    assert {:ok, %{session_id: id}} =
             Sessions.start(ctx.sessions, "linger", ctx.account, lingers)

    stop = Task.async(fn -> Sessions.stop(ctx.sessions, "linger") end)

    # The stand-in exits 143 on SIGTERM; its wrapper keeps the socket live, so the stop is not done
    # by its deadline.
    assert {:ok, _} =
             await(fn -> if File.exists?(Path.join(dir, "exited")), do: {:ok, :exited} end)

    advance(ctx)
    assert {:unknown, {:socket_live, {:ok, :sent}}} = Task.await(stop)
    assert %{status: "stopping", reason: "socket_live"} = Table.get(ctx.table, "test", "linger")
    assert {:ok, :live} = Holder.state(ctx.holder, "linger")

    # StopSettled: a cue while the socket lives settles nothing, one after it ended does.
    cue(ctx, ctx.sessions)
    :sys.get_state(ctx.sessions)
    assert %{status: "stopping"} = Table.get(ctx.table, "test", "linger")
    File.rm!(hold)
    {:ok, :absent} = await(fn -> absent(Holder.state(ctx.holder, "linger")) end, 10_000)
    cue(ctx, ctx.sessions)
    assert {:ok, _} = row_when(ctx, "linger", &(&1.status == "stopped"))

    assert {:ok, %{session_id: ^id}} =
             Sessions.resume(ctx.sessions, "linger", ctx.account, id, launch(ctx, :at_start))
  end

  test "F-64: the sampler's cue settles a running row whose first settle met a live socket",
       ctx do
    {_dir, hold, lingers} = linger(ctx, "crashed")
    assert {:ok, %{pid: pid}} = Sessions.start(ctx.sessions, "crashed", ctx.account, lingers)

    # The sampler's cue reaches Sessions as the embedding app would wire it.
    sampler =
      start_supervised!(
        {TmuxSampler,
         server: ctx.server,
         holder: ctx.holder,
         db: Path.join(ctx.dir, "sampler.db"),
         notify: &Sessions.cue(ctx.sessions, &1)}
      )

    assert {:ok, %{held: 1}} = TmuxSampler.sample(sampler)

    # The test kills the stand-in by the pid it recorded; its wrapper keeps the socket live.
    assert {:ok, %{status: 0}} = kill(pid)
    assert {:ok, :gone} = await(fn -> if not alive?(pid), do: {:ok, :gone} end)
    cue(ctx, ctx.sessions)
    :sys.get_state(ctx.sessions)
    assert %{status: "running"} = Table.get(ctx.table, "test", "crashed")

    File.rm!(hold)
    {:ok, :absent} = await(fn -> absent(Holder.state(ctx.holder, "crashed")) end, 10_000)
    assert {:ok, %{held: 0}} = TmuxSampler.sample(sampler)
    assert {:ok, %{reason: "exited"}} = row_when(ctx, "crashed", &(&1.status == "stopped"))
  end

  test "F-64: ReRead and Adopt make an orphan of a dead socket whose file names a live process",
       ctx do
    assert {:ok, %{pid: unknown}} =
             Sessions.start(ctx.sessions, "unheld", ctx.account, launch(ctx, :at_start))

    assert {:ok, %{pid: starting}} =
             Sessions.start(ctx.sessions, "adopted", ctx.account, launch(ctx, :at_start))

    # As if each dtach had been killed hard: the rows name sockets that are not there, while
    # the session files name the live processes.
    Process.exit(ctx.sessions, :kill)
    lost = [socket: "gone", pid: nil, proc_start: nil]

    Table.update(
      ctx.table,
      Table.get(ctx.table, "test", "unheld").id,
      [status: "unknown"] ++ lost
    )

    Table.update(
      ctx.table,
      Table.get(ctx.table, "test", "adopted").id,
      [status: "starting"] ++ lost
    )

    advance(ctx)
    restart(ctx, nil)

    assert {:ok, %{reason: "unheld", pid: ^unknown}} =
             row_when(ctx, "unheld", &(&1.status == "orphan"))

    assert {:ok, %{reason: "unheld", pid: ^starting}} =
             row_when(ctx, "adopted", &(&1.status == "orphan"))

    # Sessions never kills: both run on, for Recoveries.
    assert alive?(unknown) and alive?(starting)
  end

  # A stand-in held under a wrapper that outlives it, as dtach holds a socket a moment after its
  # process exits: when the stand-in exits, the wrapper writes `exited` and keeps the socket live
  # while the file `hold` is there, for at most 20 s. Both record their pids, and the test's end
  # ends them by those.
  defp linger(ctx, name) do
    dir = Path.join(ctx.dir, name)
    inner = ClaudeStandIn.write!(dir, :at_start)
    hold = Path.join(dir, "hold")
    File.write!(hold, "")
    path = Path.join(dir, "claude-linger")
    tmp = "#{path}.tmp"

    File.write!(tmp, """
    #!#{program!(:sh)}
    : > "#{dir}/pids/$$"
    "#{inner}" "$@"
    : > "#{dir}/exited"
    n=0
    while [ -e "#{hold}" ] && [ $n -lt 400 ]; do #{program!(:sleep)} 0.05; n=$((n + 1)); done
    """)

    File.chmod!(tmp, 0o755)
    File.rename!(tmp, path)
    on_exit(fn -> ClaudeStandIn.kill_all(dir) end)
    {dir, hold, Keyword.put(launch(ctx, :at_start), :claude, path)}
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

  # The Registry reads, and its cue reaches Sessions as the embedding app would wire it.
  defp cue(ctx, sessions) do
    {:ok, _} = Registry.read(ctx.registry)
    send_cue(sessions)
  end

  defp send_cue(sessions), do: Sessions.cue(sessions, %{topic: "registry:test:work", ids: []})

  # `row_when/3`, with a cue at each poll before the row is read, as a host's sampler cues at
  # each read: a settle that decided nothing at one cue (a read that failed under load) is taken
  # again at the next, within the same 10 s. A read that fails is the next poll's to retry.
  defp cued_row_when(ctx, sessions, name, ready?) do
    cue = fn ->
      _ = Registry.read(ctx.registry)
      send_cue(sessions)
    end

    await_cued(sessions, cue, fn -> row_ready(ctx, name, ready?) end, 10_000)
  end

  # A ps that exits 2 while `failing` exists, and is the real one after.
  defp failing_ps(ctx, failing) do
    path = Path.join(ctx.dir, "ps-failing.sh")
    tmp = "#{path}.tmp"

    File.write!(tmp, """
    #!#{program!(:sh)}
    [ -e "#{failing}" ] && exit 2
    exec "#{program!(:ps)}" "$@"
    """)

    File.chmod!(tmp, 0o755)
    File.rename!(tmp, path)
    path
  end

  # The one session file of the account says `status`.
  defp file_says(ctx, status) do
    sessions = Path.join(ctx.account.config_dir, "sessions")

    await(fn ->
      with [file] <- File.ls!(sessions),
           {:ok, text} <- File.read(Path.join(sessions, file)),
           true <- text =~ ~s("status": "#{status}") do
        {:ok, status}
      end
    end)
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

  defp row_when(ctx, name, ready?), do: await(fn -> row_ready(ctx, name, ready?) end, 10_000)

  defp row_ready(ctx, name, ready?) do
    row = Table.get(ctx.table, "test", name)
    if row && ready?.(row), do: {:ok, row}, else: row
  end
end
