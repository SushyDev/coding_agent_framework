defmodule CodingAgentFramework.SchedulerTest do
  @moduledoc """
  The `Scheduler` on a SQLite file in the test's own directory, against `Schedule.tla`: the
  grant within capacity, the one more answer after `queued`, the release by the owner's word,
  the reclaimer after a restart, the classes, the hold, the turns and aging, the four refusals,
  the gates and the telemetry. Owners and gates are stand-ins the test sets.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Scheduler
  alias CodingAgentFramework.Scheduler.{Pressure, Queue, Table}

  doctest Scheduler, only: [key: 1]
  doctest Table
  doctest Queue
  doctest Pressure

  setup do
    dir = test_dir()
    # The work rows' owner: key to :live, :ended or :starting (live too) in an Agent.
    {:ok, work} = Agent.start_link(fn -> %{} end)
    {:ok, gates} = Agent.start_link(fn -> %{spent: %{}, level: 0} end)
    test = self()

    opts = [
      db: Path.join(dir, "leases.db"),
      host: "ws",
      resources: %{"seat" => 1, "slot" => 2, "lock" => 1},
      holders: %{"work" => &owner(work, &1)},
      allowance: fn a -> Agent.get(gates, &Map.get(&1.spent, a, :room)) end,
      notify: &send(test, {:cue, &1}),
      queue_bound: 2,
      max_wait: 60_000
    ]

    %{opts: opts, work: work, gates: gates}
  end

  defp owner(work, key) do
    case Agent.get(work, &Map.get(&1, key, :starting)) do
      :starting -> :live
      state -> state
    end
  end

  defp start(opts, more \\ []), do: start_supervised!({Scheduler, Keyword.merge(opts, more)})

  defp req(id, class, units, more \\ []) do
    Map.merge(
      %{id: id, class: class, module: "m", account: "a", units: units, holder: {"work", id}},
      Map.new(more)
    )
  end

  defp ended(ctx, s, key) do
    Agent.update(ctx.work, &Map.put(&1, key, :ended))
    Scheduler.cue(s, %{topic: "sessions:ws"})
  end

  test "a grant within capacity, a queued request answered once, idempotent by id", ctx do
    s = start(ctx.opts)
    assert {:ok, %{id: first}} = Scheduler.request(s, req("r1", :builder, %{"seat" => 1}))
    # Granted at once: the reply is the answer, and no message follows.
    refute_received {:lease, "r1", _}

    assert {:queued, %{id: "r2", position: 1}} =
             Scheduler.request(s, req("r2", :builder, %{"seat" => 1}))

    # Asked again: the same lease, never a second.
    assert {:ok, %{id: ^first}} = Scheduler.request(s, req("r1", :builder, %{"seat" => 1}))

    ended(ctx, s, "r1")
    assert_receive {:lease, "r2", {:ok, %{id: second, waited: waited}}}
    assert second > first and waited >= 0
    refute_received {:lease, "r2", _}

    assert [%{id: ^first, released_by: "monitor"}, %{id: ^second, released_at: nil}] =
             Enum.filter(Scheduler.leases(s), &(&1.outcome == "granted"))
  end

  test "after a restart the reclaimer releases only ended work; starting work is live", ctx do
    s = start(ctx.opts)
    {:ok, %{id: a}} = Scheduler.request(s, req("a", :heavy, %{"slot" => 1}))
    {:ok, %{id: b}} = Scheduler.request(s, req("b", :heavy, %{"slot" => 1}))
    stop_supervised!(Scheduler)

    Agent.update(ctx.work, &Map.put(&1, "a", :ended))
    s = start(ctx.opts)
    assert_receive {:cue, %{topic: "scheduler:ws", ids: [^a]}}
    rows = Map.new(Scheduler.leases(s), &{&1.id, &1})
    assert %{released_by: "reclaim"} = rows[a]
    # "b" never left `starting`: live, and monitored from now on.
    assert %{released_at: nil} = rows[b]

    ended(ctx, s, "b")
    assert_receive {:cue, %{topic: "scheduler:ws", ids: [^b]}}
    assert %{released_by: "monitor"} = Enum.find(Scheduler.leases(s), &(&1.id == b))
  end

  test "a waiting landing holds the free slot; a higher class goes first", ctx do
    s = start(ctx.opts)
    {:ok, _} = Scheduler.request(s, req("l1", :landing, %{"slot" => 1, "lock" => 1}))
    # The lock is held: l2 waits, and the other slot is held for it.
    {:queued, _} = Scheduler.request(s, req("l2", :landing, %{"slot" => 1, "lock" => 1}))
    {:queued, _} = Scheduler.request(s, req("h", :heavy, %{"slot" => 1}))

    ended(ctx, s, "l1")
    assert_receive {:lease, "l2", {:ok, _}}
    refute_received {:lease, "h", _}

    ended(ctx, s, "l2")
    assert_receive {:lease, "h", {:ok, _}}
  end

  test "inside a class the modules take turns, and an aged request goes first", ctx do
    s = start(ctx.opts, queue_bound: 4, age: nil)
    {:ok, _} = Scheduler.request(s, req("hold", :builder, %{"seat" => 1}))

    for id <- ~w(x1 x2),
        do: {:queued, _} = Scheduler.request(s, req(id, :builder, %{"seat" => 1}, module: "x"))

    {:queued, _} = Scheduler.request(s, req("y1", :builder, %{"seat" => 1}, module: "y"))

    for {done, next} <- [{"hold", "x1"}, {"x1", "y1"}, {"y1", "x2"}] do
      ended(ctx, s, done)
      assert_receive {:lease, ^next, {:ok, _}}
    end

    entry = fn seq, at, module ->
      %{seq: seq, asked_at: at, req: %{class: :builder, module: module, units: %{"seat" => 1}}}
    end

    [old, young] = [entry.(1, 0, "x"), entry.(2, 900, "y")]
    yes = fn _ -> true end
    # The rotation would serve "y" after "x"; "x"'s request has waited past the age.
    assert {:grant, ^old, _} =
             Queue.next([old, young], %{builder: "x"}, %{}, %{"seat" => 1}, yes, 1_000, 500)

    assert {:grant, ^young, _} =
             Queue.next([old, young], %{builder: "x"}, %{}, %{"seat" => 1}, yes, 1_000, nil)
  end

  test "the four refusals, each final, holding nothing, and counted", ctx do
    events = [
      [:coding_agent_framework, :scheduler, :refusal],
      [:coding_agent_framework, :scheduler, :grant]
    ]

    # Handlers are global: other tests' events reach this one too, so each assert names its own.
    handler = "refusals-#{inspect(self())}"
    :telemetry.attach_many(handler, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    s = start(ctx.opts, max_wait: %{main: 60_000, landing: 60_000, builder: 60_000, heavy: 50})
    Agent.update(ctx.gates, &put_in(&1.spent["spent"], {:spent, 1_900_000_000_000}))

    assert {:refused, {:allowance, 1_900_000_000_000}} =
             Scheduler.request(s, req("s", :builder, %{"seat" => 1}, account: "spent"))

    {:ok, _} = Scheduler.request(s, req("b1", :builder, %{"seat" => 1}))
    {:queued, _} = Scheduler.request(s, req("b2", :builder, %{"seat" => 1}, account: "late"))
    {:queued, _} = Scheduler.request(s, req("b3", :builder, %{"seat" => 1}))

    assert {:refused, {:queue_full, _}} =
             Scheduler.request(s, req("b4", :builder, %{"seat" => 1}))

    {:ok, _} = Scheduler.request(s, req("h1", :heavy, %{"slot" => 2}))
    {:queued, _} = Scheduler.request(s, req("h2", :heavy, %{"slot" => 1}))
    assert_receive {:lease, "h2", {:refused, {:deadline, _}}}

    # A queued request whose account runs out of room is refused then.
    Agent.update(ctx.gates, &put_in(&1.spent["late"], {:spent, 1_900_000_000_000}))
    Scheduler.cue(s, %{topic: "usage:ws:late"})
    assert_receive {:lease, "b2", {:refused, {:allowance, 1_900_000_000_000}}}

    refused = for %{outcome: "refused"} = r <- Scheduler.leases(s), do: {r.request_id, r.reason}

    assert Enum.sort(refused) ==
             Enum.sort([
               {"s", "allowance"},
               {"b4", "queue_full"},
               {"h2", "deadline"},
               {"b2", "allowance"}
             ])

    # None of them holds a lease.
    assert Enum.all?(
             ~w(s h2 h3 h4 b2),
             &(Table.lease(Table.open(ctx.opts[:db]) |> elem(1), &1) == nil)
           )

    assert_receive {:telemetry, [_, _, :refusal], %{count: 1},
                    %{reason: :allowance, class: :builder}}

    assert_receive {:telemetry, [_, _, :grant], %{wait: _}, %{class: :heavy, module: "m"}}
  end

  # A Scheduler whose pressure is the level in `gates`, read every 5 ms and taken at once, and a
  # function that sets the level and returns once it is folded.
  defp leveled(ctx, more \\ []) do
    test = self()

    read = fn ->
      send(test, :read)

      case Agent.get(ctx.gates, & &1.level) do
        :unread -> {:unknown, {:level, "3"}}
        n -> {:ok, n}
      end
    end

    pressure = [source: {:level, read}, name: "kernel", interval: 5, window: 0]
    s = start(ctx.opts, [pressure: pressure] ++ more)

    set = fn level ->
      Agent.update(ctx.gates, &%{&1 | level: level})
      # Two reads after the change: the level is folded.
      flush_reads()
      assert_receive :read
      assert_receive :read
    end

    {s, set}
  end

  test "pressure: severe admits only a person's main session; high bars heavy runs", ctx do
    {s, set} =
      leveled(ctx, max_wait: %{main: 60_000, landing: 60_000, builder: 50, heavy: 60_000})

    set.(4)
    assert %{level: :severe, source: "kernel", at: at, unread: nil} = Scheduler.pressure(s)
    assert is_integer(at)
    # Each change of the level is cued once.
    assert_received {:cue, %{topic: "scheduler:ws", pressure: :severe}}

    assert %{reading: %{file: :level, line: :level, share: 4, threshold: 4}} =
             Scheduler.pressure(s)

    # Barred, the request queues and says why (F-276).
    assert {:queued, %{position: 1, barred: {:pressure, :severe, %{share: 4}}}} =
             Scheduler.request(s, req("b", :builder, %{"seat" => 1}))

    # At its deadline, still barred, the refusal names the reading that set the level, in the
    # answer and in the row. Samples go on every 5 ms, so the reading is the latest.
    assert_receive {:lease, "b", {:refused, {{:pressure, :severe, reading}, _}}}
    assert %{file: :level, share: 4, threshold: 4, at: read_at} = reading
    assert read_at >= at
    assert [%{reason: row}] = for(%{request_id: "b"} = r <- Scheduler.leases(s), do: r)

    assert {:ok, ["pressure", "severe", %{"file" => "level", "share" => 4, "at" => ^read_at}]} =
             JSON.decode(row)

    assert {:ok, _} = Scheduler.request(s, req("main", :main, %{"seat" => 1}))

    set.(2)
    assert %{level: :high} = Scheduler.pressure(s)
    assert_received {:cue, %{topic: "scheduler:ws", pressure: :high}}
    refute_received {:cue, %{pressure: _}}

    assert {:queued, %{barred: {:pressure, :high, %{threshold: 2}}}} =
             Scheduler.request(s, req("h", :heavy, %{"slot" => 1}))

    assert {:ok, _} = Scheduler.request(s, req("l", :landing, %{"slot" => 1, "lock" => 1}))

    # A value nobody knows changes nothing and is named, never read as ok.
    set.(:unread)
    assert %{level: :high, unread: {:level, "3"}} = Scheduler.pressure(s)
    refute_received {:cue, %{pressure: _}}
  end

  test "a barred request waits, keeps its place against a later one, and is granted once pressure eases",
       ctx do
    {s, set} = leveled(ctx)
    {:ok, _} = Scheduler.request(s, req("x", :heavy, %{"slot" => 2}))

    set.(2)

    assert {:queued, %{position: 1, barred: {:pressure, :high, _}}} =
             Scheduler.request(s, req("h1", :heavy, %{"slot" => 2}))

    # Pressure eases while the slots are still held; a later request queues behind h1.
    set.(0)

    assert {:queued, %{position: 2, barred: nil}} =
             Scheduler.request(s, req("h2", :heavy, %{"slot" => 2}))

    ended(ctx, s, "x")
    assert_receive {:lease, "h1", {:ok, _}}
    refute_received {:lease, "h2", _}

    ended(ctx, s, "h1")
    assert_receive {:lease, "h2", {:ok, _}}
  end

  test "a barred request whose caller dies is refused caller_gone, and its place frees", ctx do
    {s, set} = leveled(ctx)
    set.(2)

    {pid, ref} =
      spawn_monitor(fn ->
        {:queued, %{barred: {:pressure, :high, _}}} =
          Scheduler.request(s, req("gone", :heavy, %{"slot" => 1}))
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_receive {:cue, %{topic: "scheduler:ws", ids: [id]}}

    assert %{request_id: "gone", outcome: "refused", reason: "caller_gone"} =
             Enum.find(Scheduler.leases(s), &(&1.id == id))

    assert {:queued, %{position: 1}} = Scheduler.request(s, req("next", :heavy, %{"slot" => 1}))
    set.(0)
    assert_receive {:lease, "next", {:ok, _}}
    assert Table.lease(elem(Table.open(ctx.opts[:db]), 1), "gone") == nil
  end

  test "a request past its deadline is never granted, though its timer has not fired", ctx do
    s = start(ctx.opts, max_wait: 3_000)
    {:ok, _} = Scheduler.request(s, req("x", :builder, %{"seat" => 1}))

    # One carries its caller's wait, one only its class's.
    {:queued, _} = Scheduler.request(s, req("late", :builder, %{"seat" => 1}, wait: 2_000))
    {:queued, _} = Scheduler.request(s, req("slow", :builder, %{"seat" => 1}))

    # The seat frees while the Scheduler is held; it reads that cue only once the timers are in
    # its mailbox behind it, so the grant's own check is what refuses them. Every request has a
    # timer, the granted "x"'s too: three, the last "slow"'s.
    :sys.suspend(s)
    ended(ctx, s, "x")

    {:ok, _} =
      await(
        fn ->
          {:messages, m} = Process.info(s, :messages)
          if Enum.count(m, &match?({:deadline, _}, &1)) == 3, do: {:ok, m}, else: {:no, m}
        end,
        10_000
      )

    :sys.resume(s)
    assert_receive {:lease, "late", {:refused, {:caller_gone, _}}}
    assert_receive {:lease, "slow", {:refused, {:deadline, _}}}

    db = elem(Table.open(ctx.opts[:db]), 1)
    assert Table.lease(db, "late") == nil and Table.lease(db, "slow") == nil
    assert {:ok, _} = Scheduler.request(s, req("fresh", :builder, %{"seat" => 1}))
  end

  test "a request names declared resources and a holder", ctx do
    s = start(ctx.opts)

    assert {:refused, {:unknown_resource, "gpu"}} =
             Scheduler.request(s, req("x", :heavy, %{"gpu" => 1}))

    assert {:refused, {:bad, :class}} = Scheduler.request(s, req("x", :urgent, %{"seat" => 1}))
    assert {:refused, {:bad, :request}} = Scheduler.request(s, %{id: "x"})

    assert {:refused, {:bad, :wait}} =
             Scheduler.request(s, req("x", :heavy, %{"seat" => 1}, wait: 0))
  end

  # HostSlots.tla (F-292): the workstation's one slot and another host's two.
  defp hosted(ctx, more \\ []) do
    resources = %{"seat" => 1, "slot" => 1, {"slot", "mac"} => 2, "lock" => 1}
    start(ctx.opts, [resources: resources] ++ more)
  end

  defp on(host, id, units \\ %{"slot" => 1}),
    do: req(id, :heavy, units, where: %{host: host})

  test "CapacityHolds, OwnHost: two heavy runs on a two-slot host run while a third queues, and the workstation's slot is its own",
       ctx do
    s = hosted(ctx)
    assert {:ok, %{units: %{"slot@mac" => 1}}} = Scheduler.request(s, on("mac", "m1"))
    assert {:ok, %{units: %{"slot@mac" => 1}}} = Scheduler.request(s, on("mac", "m2"))
    assert {:queued, %{position: 1}} = Scheduler.request(s, on("mac", "m3"))

    # HostUnaffected: the other host's runs hold none of the workstation's slot.
    assert {:ok, %{units: %{"slot" => 1}}} =
             Scheduler.request(s, req("w1", :heavy, %{"slot" => 1}))

    assert {:queued, _} = Scheduler.request(s, on("ws", "w2"))

    # A slot freed on the workstation goes to its own queue, not to the other host's.
    ended(ctx, s, "w1")
    assert_receive {:lease, "w2", {:ok, %{units: %{"slot" => 1}}}}
    refute_received {:lease, "m3", _}

    ended(ctx, s, "m1")
    assert_receive {:lease, "m3", {:ok, %{units: %{"slot@mac" => 1}}}}
    refute_received {:lease, "w2", _}

    # A landing there takes that host's slot and the shared lock in one lease.
    ended(ctx, s, "m2")
    landing = req("l", :landing, %{"slot" => 1, "lock" => 1}, where: %{host: "mac"})
    assert {:ok, %{units: %{"slot@mac" => 1, "lock" => 1}}} = Scheduler.request(s, landing)
  end

  test "a request on another host never falls back on the workstation's resources", ctx do
    s = hosted(ctx)

    assert {:refused, {:unknown_host, "pi"}} =
             Scheduler.request(s, on("pi", "p1", %{"lock" => 1}))

    assert {:refused, {:unknown_resource, {"slot", "pi"}}} =
             Scheduler.request(s, on("pi", "p2"))

    assert {:refused, {:bad, :where}} =
             Scheduler.request(s, req("x", :heavy, %{"slot" => 1}, where: %{}))

    assert {:refused, {:bad, :units}} = Scheduler.request(s, on("ws", "x", %{"slot@mac" => 1}))
    assert Scheduler.leases(s) == []

    Process.flag(:trap_exit, true)

    assert {:error, {:bad, :resources}} =
             Scheduler.start_link(Keyword.put(ctx.opts, :resources, %{"a@b" => 1}))
  end

  test "pressure is the workstation's: it bars no heavy run on another host", ctx do
    {s, set} = leveled(ctx, resources: %{"slot" => 1, {"slot", "mac"} => 2})
    set.(2)
    assert %{level: :high} = Scheduler.pressure(s)
    assert {:ok, _} = Scheduler.request(s, on("mac", "m1"))
    assert {:queued, %{barred: {:pressure, :high, _}}} = Scheduler.request(s, on("ws", "w1"))
  end

  test "pressure from stall times: deltas of total, severe at once, down after a quiet window" do
    dir = test_dir()

    write = fn cpu, full ->
      File.write!(Path.join(dir, "cpu"), "some avg10=0 avg60=0 avg300=0 total=#{cpu}\n")
      mem = "some avg10=0 avg60=0 avg300=0 total=0\nfull avg10=0 avg60=0 avg300=0 total=#{full}\n"
      File.write!(Path.join(dir, "memory"), mem)
      File.write!(Path.join(dir, "io"), mem)
    end

    step = fn p, at ->
      {:ok, sample} = Pressure.psi(dir)
      Pressure.step(p, sample, at)
    end

    write.(0, 0)
    p = step.(Pressure.new(window: 2_000), 0)
    write.(0, 20_000)
    p = step.(p, 1_000)
    assert p.level == :severe
    write.(0, 20_000)
    p = step.(p, 2_000)
    assert p.level == :severe
    p = step.(p, 4_000)
    assert p.level == :ok
    assert {:unknown, {:psi, :cpu, :enoent}} = Pressure.psi(Path.join(dir, "none"))
  end

  # A sample as `Pressure.psi/1` reads it: each line's cumulative `total` in µs.
  defp psi(cpu, mem_full, mem_some \\ 0) do
    {:psi,
     %{
       cpu: %{some: cpu, full: 0},
       memory: %{some: mem_some, full: mem_full},
       io: %{some: 0, full: 0}
     }}
  end

  test "memory full: background growth reads ok, a stall over the threshold severe, the app's own threshold first" do
    # 30 µs in a 2 s span, the most the workstation's background grew `full` by (F-273).
    p = Pressure.new() |> Pressure.step(psi(0, 0), 0) |> Pressure.step(psi(0, 30), 2_000)
    assert %{level: :ok, reading: nil} = p

    # 2% of the span is past the default 1%.
    p = Pressure.step(p, psi(0, 40_030), 4_000)
    assert %{level: :severe, reading: %{file: :memory, line: :full, threshold: 0.01} = r} = p
    assert_in_delta r.share, 0.02, 1.0e-9
    assert r.at == 4_000

    # The app's threshold is read over the default: 2% is under its 5%, 6% over it.
    app = Pressure.new(full: 0.05) |> Pressure.step(psi(0, 0), 0)
    assert %{level: :ok} = Pressure.step(app, psi(0, 40_000), 2_000)

    assert %{level: :severe, reading: %{threshold: 0.05}} =
             Pressure.step(app, psi(0, 120_000), 2_000)
  end

  test "a first sample, a span of 0, a counter that went back and a clock set back read nothing" do
    # A first sample only starts a span, whatever its totals.
    p = Pressure.step(Pressure.new(), psi(0, 999_999_999), 10_000)
    assert %{level: :ok, at: 10_000} = p

    # A span of 0 ms, and a clock set back, start the next span from this sample.
    p = Pressure.step(p, psi(0, 999_999_999 + 5_000), 10_000)
    assert %{level: :ok, at: 10_000} = p
    p = Pressure.step(p, psi(0, 999_999_999 + 9_000), 1_000)
    assert %{level: :ok, at: 1_000} = p

    # So the growth before the clock went back is never divided by a span of 1 ms.
    p = Pressure.step(p, psi(0, 999_999_999 + 9_000), 10_001)
    assert %{level: :ok} = p

    # A counter that went back (a reboot) reads 0.
    p = Pressure.step(p, psi(0, 3), 12_001)
    assert %{level: :ok} = p
  end

  test "samples that flip between ok and high take severe down to high after a quiet window" do
    p = Pressure.new(window: 4_000) |> Pressure.step(psi(0, 0), 0)
    p = Pressure.step(p, psi(0, 100_000), 2_000)
    assert p.level == :severe

    # cpu `some` 40% of a span asks for high, 10% for ok, in turn: neither holds a window alone.
    {p, _} =
      Enum.reduce(1..4, {p, 0}, fn i, {p, cpu} ->
        cpu = cpu + if(rem(i, 2) == 1, do: 800_000, else: 200_000)
        {Pressure.step(p, psi(cpu, 100_000), 2_000 + i * 2_000), cpu}
      end)

    assert %{level: :high, reading: %{file: :cpu, line: :some, threshold: 0.25}} = p
  end

  @doc false
  def handle_event(event, measurements, meta, test),
    do: send(test, {:telemetry, event, measurements, meta})

  defp flush_reads do
    receive do
      :read -> flush_reads()
    after
      0 -> :ok
    end
  end
end
