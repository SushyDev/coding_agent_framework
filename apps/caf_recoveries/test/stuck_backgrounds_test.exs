defmodule CodingAgentFramework.StuckBackgroundsTest do
  @moduledoc """
  The `stuck_background` healer on real `Acts`, `Watch` and `Sessions` files in this test's own
  directory. The delegate's agent row is written as `Sessions` keeps a running one; its fold is
  the one `Stream` keeps, set by the test. The hung command is a real process group, held by a
  real dtach in the test's directory, and ended by its record; only its CPU time is the test's,
  since macOS has no `/proc` (`StuckBackgrounds.Groups` reads it on Linux). All share a clock
  the test moves, so no test sleeps.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Acts, Holder, Sessions, StuckBackgrounds, Watch}
  alias CodingAgentFramework.StuckBackgrounds.Groups

  doctest StuckBackgrounds
  doctest Groups

  @quiet 60_000

  setup do
    dir = test_dir()
    db = Path.join(dir, "caf.db")
    time = :counters.new(1, [:atomics])
    :counters.put(time, 1, 1_000_000)

    clock = fn ->
      :counters.add(time, 1, 1)
      :counters.get(time, 1)
    end

    {:ok, acts} =
      Acts.start_link(db: db, start_id: "s1", host: "test", instance: "a", clock: clock)

    remedies = %{"stuck_background" => %{remedy: "end", cap: 5}}
    {:ok, watch} = Watch.start_link(db: Path.join(dir, "w.db"), remedies: remedies, clock: clock)

    # The hung command: a group of its own, as Claude Code spawns each command.
    hold_dir = Path.join(dir, "d")
    File.mkdir_p!(hold_dir)
    {:ok, holder} = Holder.new(programs(), hold_dir)
    {:ok, procs} = Holder.Process.new(programs(), holder)
    {:ok, _} = Holder.Process.hold(procs, "bg", [program!(:sleep), "60"])
    {:ok, %{"bg" => %{record: group}}} = Holder.Process.read(procs, ["bg"], wait: 5_000)
    on_exit(fn -> Holder.Process.signal(procs, group, "KILL", group: true) end)

    {:ok, table} = Sessions.Table.open(db)
    {:ok, agents} = Sessions.Agents.open(db, "test")
    row = %{host: "test", name: "app-fix", socket: "app-fix", account: "work", cwd: dir}
    id = Sessions.Table.starting(table, Map.merge(row, %{role: "delegate", resume: nil}))
    record = [status: "running", session_id: "s1", pid: 7, proc_start: "Sat Nov 21 09:00:00 2026"]
    Sessions.Table.update(table, id, record)

    fold = %{
      session: "s1",
      gone: false,
      idle: true,
      last_result: %{text: "report"},
      background: %{tasks: ["t1"], changes: 1}
    }

    world = start_supervised!({Agent, fn -> %{fold: fold, cpu: 3, groups: :ok} end})

    %{
      acts: acts,
      watch: watch,
      agents: agents,
      time: time,
      clock: clock,
      world: world,
      group: group,
      procs: procs,
      holder: holder
    }
  end

  # A healer that reads the test's fold and CPU time, and signals by the real record unless
  # `signal` stands in.
  defp healer!(ctx, more \\ []) do
    me = self()

    groups = fn record ->
      send(me, {:read, record})

      case Agent.get(ctx.world, & &1) do
        %{groups: :ok, cpu: cpu} -> {:ok, [Map.put(ctx.group, :cpu, cpu)]}
        %{groups: other} -> other
      end
    end

    opts =
      [
        agents: ctx.agents,
        folds: fn -> {:ok, [Agent.get(ctx.world, & &1.fold)]} end,
        acts: ctx.acts,
        watch: ctx.watch,
        host: "test",
        holder: ctx.holder,
        programs: programs(),
        groups: groups,
        quiet: @quiet,
        clock: ctx.clock
      ] ++ more

    {:ok, healer} = StuckBackgrounds.start_link(opts)
    healer
  end

  defp tick(ctx, ms), do: :counters.add(ctx.time, 1, ms)
  defp set(ctx, fun), do: Agent.update(ctx.world, fun)

  defp list(ctx, tasks, changes),
    do: set(ctx, &put_in(&1.fold.background, %{tasks: tasks, changes: changes}))

  defp asked(ctx), do: elem(Watch.read(ctx.watch, status: "asked"), 1)

  defp dead?(ctx),
    do: Holder.Process.dead_by(ctx.procs, "bg", System.os_time(:millisecond) + 5_000)

  test "a group quiet for the bound is ended by its record once, and verified by the list", ctx do
    healer = healer!(ctx)
    # The first read starts the bound; the delegate's own record is read for its groups.
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)
    assert_received {:read, %{pid: 7, start: "Sat Nov 21 09:00:00 2026"}}

    tick(ctx, @quiet)
    assert {:ok, %{ended: [id]}} = StuckBackgrounds.check(healer)
    key = "stuck_background:app-fix:#{ctx.group.pid}:#{ctx.group.start}"

    assert {:ok, %{status: "acted", act: "end", state: ^key, answer: "sent"}} =
             Acts.get(ctx.acts, id)

    assert {:ok, :ended} = dead?(ctx)
    assert {:ok, [%{status: "open", target: "app-fix"}]} = Watch.read(ctx.watch, state: key)

    # Once per state: a later check before Claude Code's next list ends nothing more.
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)

    # The next list lacks the task: recovered. The state passes with its group.
    list(ctx, [], 2)
    set(ctx, &%{&1 | groups: {:ok, []}})
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)
    assert {:ok, %{outcome: "recovered"}} = Acts.get(ctx.acts, id)
    assert {:ok, [%{status: "passed"}]} = Watch.read(ctx.watch, state: key)
    assert asked(ctx) == []
  end

  test "a group that uses CPU time, a report not taken, or no /proc is never stuck", ctx do
    healer = healer!(ctx)
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)

    # More CPU time starts the bound again.
    tick(ctx, @quiet - 10)
    set(ctx, &%{&1 | cpu: 4})
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)
    tick(ctx, 20)
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)

    # A turn that runs: the report is not taken, and the groups are not read.
    set(ctx, &put_in(&1.fold.idle, false))
    tick(ctx, @quiet)
    flush_reads()
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)
    refute_received {:read, _}

    # macOS: the groups read unknown, so nothing is stuck and nothing is recorded.
    set(ctx, &%{put_in(&1.fold.idle, true) | groups: {:unknown, :no_proc}})
    tick(ctx, @quiet)
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)
    assert {:ok, []} = Watch.read(ctx.watch, kind: "stuck_background")
    assert {:ok, :alive} = alive(ctx)
  end

  # A hung command writes nothing, so no cue comes: the interval reads it again (F-189's new-4).
  test "with an interval, it reads by itself, with no cue and no check", ctx do
    _healer = healer!(ctx, interval: 10)
    assert_receive {:read, %{pid: 7}}, 5_000
    tick(ctx, @quiet)
    key = "stuck_background:app-fix:#{ctx.group.pid}:#{ctx.group.start}"
    # A read after the bound ends the group; the record is written before the signal.
    assert {:ok, :ended} = dead?(ctx)
    assert {:ok, [%{status: "open"}]} = Watch.read(ctx.watch, state: key)
  end

  test "a list that still names the task fails the verify: off the list, and asked", ctx do
    healer = healer!(ctx, signal: fn _record -> {:ok, :sent} end)
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)
    tick(ctx, @quiet)
    assert {:ok, %{ended: [id]}} = StuckBackgrounds.check(healer)

    list(ctx, ["t1", "t2"], 2)
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)
    assert {:ok, %{outcome: "failed", reason: "still_listed"}} = Acts.get(ctx.acts, id)
    assert [%{reason: ~s(["verify_failed","still_listed"])}] = asked(ctx)
    assert {:ok, %{"stuck_background" => %{allowed: false}}} = Watch.remedies(ctx.watch, :list)
  end

  test "an end whose outcome is unknown is asked and never tried again in its state", ctx do
    healer = healer!(ctx, signal: fn _record -> {:unknown, :timeout} end)
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)
    tick(ctx, @quiet)
    assert {:ok, %{ended: [id]}} = StuckBackgrounds.check(healer)
    assert {:ok, %{outcome: "unknown"}} = Acts.get(ctx.acts, id)
    assert [%{reason: ~s(["unknown","timeout"])}] = asked(ctx)
    assert {:ok, %{ended: []}} = StuckBackgrounds.check(healer)
  end

  # The host's own reader: macOS has no /proc, so it answers unknown there and never stuck.
  test "the host's reader answers unknown with no /proc, and the record's groups otherwise",
       ctx do
    answer = Groups.read(ctx.procs, ctx.group)

    if File.dir?("/proc/self"),
      do: assert({:ok, []} = answer),
      else: assert(answer == {:unknown, :no_proc})
  end

  defp alive(ctx) do
    case Holder.Process.read(ctx.procs, ["bg"]) do
      {:ok, %{"bg" => %{process: :live}}} -> {:ok, :alive}
      other -> other
    end
  end

  defp flush_reads do
    receive do
      {:read, _} -> flush_reads()
    after
      0 -> :ok
    end
  end
end
