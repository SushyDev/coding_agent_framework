defmodule CodingAgentFramework.AbsentMainsTest do
  @moduledoc """
  The `absent_main` healer on real `Acts`, `Watch` and `Sessions` files in this test's own
  directory. A main session's row is written as `Sessions` settles one whose process exited;
  the resume is a stand-in for `Mains.resume_main/3` (whose contract `MainsTest` checks) that
  tells the test of each call and writes the row as a confirmed resume leaves it. All three
  share a clock the test moves, so no test sleeps.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{AbsentMains, Acts, Sessions, Watch}

  doctest AbsentMains

  @bound 10_000

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

    remedies = %{"absent_main" => %{remedy: "resume", cap: 5}}

    {:ok, watch} =
      Watch.start_link(
        db: Path.join(dir, "w.db"),
        remedies: remedies,
        bound: @bound,
        clock: clock
      )

    {:ok, table} = Sessions.Table.open(db)
    {:ok, agents} = Sessions.Agents.open(db, "test")
    row = %{host: "test", name: "app-epic", socket: "app-epic", account: "work", cwd: dir}
    id = Sessions.Table.starting(table, Map.merge(row, %{role: "parent", resume: nil}))

    %{acts: acts, watch: watch, table: table, agents: agents, id: id, time: time, clock: clock}
  end

  # A healer whose resume answers `answer` and, when it is ok, leaves the row running.
  defp healer!(ctx, answer) do
    me = self()

    resume = fn name ->
      send(me, {:resumed, name})
      if match?({:ok, _}, answer), do: Sessions.Table.update(ctx.table, ctx.id, status: "running")
      answer
    end

    opts = [agents: ctx.agents, acts: ctx.acts, watch: ctx.watch, resume: resume, host: "test"]
    {:ok, healer} = AbsentMains.start_link(Keyword.put(opts, :clock, ctx.clock))
    # Its first check, at start, found nothing: no main has gone yet.
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    healer
  end

  defp exit!(ctx, started_at),
    do:
      Sessions.Table.update(ctx.table, ctx.id,
        status: "stopped",
        reason: "exited",
        started_at: started_at
      )

  defp asked(ctx), do: elem(Watch.read(ctx.watch, status: "asked"), 1)

  test "an exited main is resumed once per absence, and the resume verified", ctx do
    healer = healer!(ctx, {:ok, %{name: "app-epic"}})
    exit!(ctx, 1)
    assert {:ok, %{resumed: [id]}} = AbsentMains.check(healer)
    assert_received {:resumed, "app-epic"}

    assert {:ok, %{outcome: "recovered", act: "resume", state: "absent_main:app-epic:1"}} =
             Acts.get(ctx.acts, id)

    # Running again: the absence passed, and nothing more is resumed.
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    refute_received {:resumed, _}
    assert {:ok, [%{status: "passed"}]} = Watch.read(ctx.watch, kind: "absent_main")
  end

  test "a second absence within the bound is a person's prompt, and after it a resume", ctx do
    healer = healer!(ctx, {:ok, %{name: "app-epic"}})
    exit!(ctx, 1)
    assert {:ok, %{resumed: [_]}} = AbsentMains.check(healer)
    exit!(ctx, 2)
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    assert_received {:resumed, "app-epic"}
    refute_received {:resumed, _}
    assert [%{state: "absent_main:app-epic:2", reason: ~s(["again_within",10000])}] = asked(ctx)

    # The bound passes: the next absence is resumed again.
    :counters.add(ctx.time, 1, @bound)
    exit!(ctx, 3)
    assert {:ok, %{resumed: [_]}} = AbsentMains.check(healer)
    assert_received {:resumed, "app-epic"}
  end

  # Heal.tla's AnswerAct (F-189's new-7): a prompt asked for its bound offers the act once, which
  # the next check takes under the person's claim, never the healer's; a second answer, or a
  # later check, acts no more.
  test "a second absence answered act is resumed once, under the person's claim", ctx do
    healer = healer!(ctx, {:ok, %{name: "app-epic"}})
    exit!(ctx, 1)
    assert {:ok, %{resumed: [_]}} = AbsentMains.check(healer)
    exit!(ctx, 2)
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    assert [%{id: sym} = row] = asked(ctx)
    assert Watch.choices(row) == ["act", "leave"]
    assert {:refused, {:bad, :choice}} = Watch.answer(ctx.watch, sym, "approve", "sam")
    assert {:refused, {:bad, :by}} = Watch.answer(ctx.watch, sym, "act", "healer")
    assert {:ok, :answered} = Watch.answer(ctx.watch, sym, "act", "sam")

    assert {:ok, %{resumed: [id]}} = AbsentMains.check(healer)
    assert_received {:resumed, "app-epic"}
    assert_received {:resumed, "app-epic"}

    assert {:ok, %{actor: "sam", act: "resume", state: "absent_main:app-epic:2"} = acted} =
             Acts.get(ctx.acts, id)

    assert acted.outcome == "recovered"
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    refute_received {:resumed, _}
    assert {:refused, :settled} = Watch.answer(ctx.watch, sym, "leave", "sam")
  end

  test "a resume refused or unknown is asked and never tried again in its state", ctx do
    healer = healer!(ctx, {:unknown, {:timeout, 300_000}})
    exit!(ctx, 1)
    assert {:ok, %{resumed: [id]}} = AbsentMains.check(healer)
    assert {:ok, %{outcome: "unknown"}} = Acts.get(ctx.acts, id)
    assert [%{reason: ~s(["unknown",["timeout",300000]])}] = asked(ctx)
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    assert_received {:resumed, "app-epic"}
    refute_received {:resumed, _}
  end

  test "a kind off the list is asked; the operator's approve puts the resume back", ctx do
    {:ok, _} = Watch.remedies(ctx.watch, {:revoke, "absent_main", "sam"})
    healer = healer!(ctx, {:ok, %{name: "app-epic"}})
    exit!(ctx, 1)
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    refute_received {:resumed, _}
    assert [%{id: sid, reason: "not_on_list"}] = asked(ctx)
    assert {:ok, :answered} = Watch.answer(ctx.watch, sid, "approve", "sam")

    # The asked state was answered; the main's next absence is resumed.
    exit!(ctx, 2)
    assert {:ok, %{resumed: [_]}} = AbsentMains.check(healer)
    assert_received {:resumed, "app-epic"}
  end
end
