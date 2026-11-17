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

  test "pressure: severe admits only a person's main session; high bars heavy runs", ctx do
    test = self()

    read = fn ->
      send(test, :read)
      {:ok, Agent.get(ctx.gates, & &1.level)}
    end

    s = start(ctx.opts, pressure: [source: {:level, read}, interval: 5, window: 0])

    set = fn level ->
      Agent.update(ctx.gates, &%{&1 | level: level})
      # Two reads after the change: the level is folded.
      flush_reads()
      assert_receive :read
      assert_receive :read
    end

    set.(4)
    assert :severe = Scheduler.pressure(s)
    assert {:refused, {:pressure, _}} = Scheduler.request(s, req("b", :builder, %{"seat" => 1}))
    assert {:ok, _} = Scheduler.request(s, req("main", :main, %{"seat" => 1}))

    set.(2)
    assert :high = Scheduler.pressure(s)
    assert {:refused, {:pressure, _}} = Scheduler.request(s, req("h", :heavy, %{"slot" => 1}))
    assert {:ok, _} = Scheduler.request(s, req("l", :landing, %{"slot" => 1, "lock" => 1}))
  end

  test "a requester that ends while it waits leaves the queue", ctx do
    s = start(ctx.opts)
    {:ok, _} = Scheduler.request(s, req("r1", :builder, %{"seat" => 1}))

    {pid, ref} =
      spawn_monitor(fn ->
        {:queued, _} = Scheduler.request(s, req("gone", :builder, %{"seat" => 1}))
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    {:queued, %{position: 1}} = Scheduler.request(s, req("r3", :builder, %{"seat" => 1}))
    ended(ctx, s, "r1")
    assert_receive {:lease, "r3", {:ok, _}}
    assert Table.lease(elem(Table.open(ctx.opts[:db]), 1), "gone") == nil
  end

  test "a request names declared resources and a holder", ctx do
    s = start(ctx.opts)

    assert {:refused, {:unknown_resource, "gpu"}} =
             Scheduler.request(s, req("x", :heavy, %{"gpu" => 1}))

    assert {:refused, {:bad, :class}} = Scheduler.request(s, req("x", :urgent, %{"seat" => 1}))
    assert {:refused, {:bad, :request}} = Scheduler.request(s, %{id: "x"})
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
    write.(0, 10_000)
    p = step.(p, 1_000)
    assert p.level == :severe
    write.(0, 10_000)
    p = step.(p, 2_000)
    assert p.level == :severe
    p = step.(p, 4_000)
    assert p.level == :ok
    assert {:unknown, {:psi, :cpu, :enoent}} = Pressure.psi(Path.join(dir, "none"))
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
