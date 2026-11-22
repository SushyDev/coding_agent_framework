defmodule CodingAgentFramework.AbsentMainsTest do
  @moduledoc """
  The `absent_main` healer on real `Acts`, `Watch`, `Sessions` and `Mains` files in this test's
  own directory. A main session's row is written as `Sessions` settles one whose process
  exited; the resume is a stand-in for `Mains.resume_main/3` (whose contract `MainsTest`
  checks) that tells the test of each call and writes the row as a confirmed resume leaves it,
  or a start's row waiting at a limit as `Mains` writes one. All three share a clock the test
  moves, so no test sleeps.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{AbsentMains, Acts, Mains, Sessions, Watch}

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

    ctx = %{acts: acts, watch: watch, table: table, agents: agents, id: id, time: time}
    Map.merge(ctx, %{clock: clock, db: db})
  end

  # A healer whose resume answers `answer` and, when it is ok, leaves the row running; or, for
  # `{:waiting, starts, row}`, writes a start's row waiting at a limit, as `Mains` does, and
  # answers so.
  defp healer!(ctx, answer) do
    me = self()

    resume = fn name ->
      case answer do
        {:waiting, starts, row} ->
          %{id: id} = Mains.Starts.waiting(starts, row)
          send(me, {:resumed, name, id})
          {:ok, %{id: id, name: name, account: nil, session_id: nil, waiting: row.until}}

        {:ok, _} ->
          send(me, {:resumed, name})
          Sessions.Table.update(ctx.table, ctx.id, status: "running")
          answer

        _ ->
          send(me, {:resumed, name})
          answer
      end
    end

    opts = [agents: ctx.agents, acts: ctx.acts, watch: ctx.watch, resume: resume, host: "test"]
    opts = [mains_db: ctx.db, clock: ctx.clock] ++ opts
    {:ok, healer} = AbsentMains.start_link(opts)
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

  # F-190's new-2: a person's claim names its healer, so the healer's restart closes the claim
  # it cut (Heal.tla's SettleCut, Break_Heal_CutOwnOnly), and the state is never acted on.
  test "a healer killed between a person's claim and its act closes that claim when it starts",
       ctx do
    first = healer!(ctx, {:ok, %{name: "app-epic"}})
    exit!(ctx, 1)
    assert {:ok, %{resumed: [_]}} = AbsentMains.check(first)
    exit!(ctx, 2)
    assert {:ok, %{resumed: []}} = AbsentMains.check(first)
    assert_received {:resumed, "app-epic"}
    assert [%{id: sym}] = asked(ctx)
    assert {:ok, :answered} = Watch.answer(ctx.watch, sym, "act", "sam")
    GenServer.stop(first)

    # This healer's check claims for sam and holds the resume until it is killed.
    me = self()

    held = fn name ->
      send(me, {:holding, name})

      receive do
        :go -> {:ok, %{name: name}}
      after
        30_000 -> {:unknown, :test_waited}
      end
    end

    opts = [agents: ctx.agents, acts: ctx.acts, watch: ctx.watch, host: "test", clock: ctx.clock]
    opts = [mains_db: ctx.db] ++ opts
    {:ok, cut} = AbsentMains.start_link([resume: held] ++ opts)
    assert_receive {:holding, "app-epic"}, 5_000

    assert {:ok, [%{id: id, status: "claimed", detail: detail}]} =
             Acts.rows(ctx.acts, actor: "sam", act: "resume")

    assert detail == ~s({"healer":"absent_mains:test","symptom":"absent_main:app-epic:2"})

    Process.unlink(cut)
    ref = Process.monitor(cut)
    Process.exit(cut, :kill)
    assert_receive {:DOWN, ^ref, :process, ^cut, :killed}

    # Its restart closes sam's claim; the answer was one act, and no act runs on the state.
    again = healer!(ctx, {:ok, %{name: "app-epic"}})
    assert {:ok, %{status: "interrupted", actor: "sam"}} = Acts.get(ctx.acts, id)
    assert {:ok, %{resumed: []}} = AbsentMains.check(again)
    refute_received {:resumed, _}
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

  # Remedies.tla's ActWaits and SettleWait (F-203, from F-196's new-4): a resume that waits at a
  # usage limit keeps its claim acted until its row in `Mains` ends, and is settled from it.
  test "a resume that waits at a limit is settled from its row's end", ctx do
    {:ok, starts} = Mains.Starts.open(ctx.db)
    wait = %{host: "test", project: "app", name: "app-epic", deadline: 9, until: 7, start: %{}}
    healer = healer!(ctx, {:waiting, starts, wait})
    exit!(ctx, 1)
    assert {:ok, %{resumed: [id]}} = AbsentMains.check(healer)
    assert_received {:resumed, "app-epic", row}
    assert {:ok, %{status: "acted", outcome: nil, detail: detail}} = Acts.get(ctx.acts, id)
    assert detail == ~s({"start":#{row},"symptom":"absent_main:app-epic:1"})

    # While it waits, or its pick at the reset is under way: no outcome, no second resume.
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    Mains.Starts.update(starts, row, status: "starting", account: "work")
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    refute_received {:resumed, _, _}
    assert {:ok, %{status: "acted"}} = Acts.get(ctx.acts, id)
    assert asked(ctx) == []

    Mains.Starts.update(starts, row, status: "running")
    Sessions.Table.update(ctx.table, ctx.id, status: "running")
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    assert {:ok, %{outcome: "verified", answer: ~s(["resumed","work"])}} = Acts.get(ctx.acts, id)

    # The next absence waits too, and a person leaves it: a fault, and their leave is their
    # answer to the absence (F-206, Remedies.tla's LeftNotAsked): no remedy prompt asks again.
    exit!(ctx, 2)
    :counters.add(ctx.time, 1, @bound)
    assert {:ok, %{resumed: [next]}} = AbsentMains.check(healer)
    assert_received {:resumed, "app-epic", row}
    Mains.Starts.update(starts, row, status: "refused", reason: "left", waited: "sam")
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    assert {:ok, %{outcome: "failed", reason: ~s(["waited","left"])}} = Acts.get(ctx.acts, next)
    assert {:ok, [%{id: ^next}]} = Acts.faults(ctx.acts)
    assert asked(ctx) == []

    assert {:ok, [%{status: "answered", answer: "leave", answered_by: "sam"}]} =
             Watch.read(ctx.watch, state: "absent_main:app-epic:2")

    # Read again, the absence stays the person's answered one: no prompt, no resume.
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    refute_received {:resumed, _, _}
    assert asked(ctx) == []

    # A pick refused at the reset is no one's answer: that absence is asked.
    exit!(ctx, 3)
    :counters.add(ctx.time, 1, @bound)
    assert {:ok, %{resumed: [last]}} = AbsentMains.check(healer)
    assert_received {:resumed, "app-epic", row}
    Mains.Starts.update(starts, row, status: "refused", reason: "no_account")
    assert {:ok, %{resumed: []}} = AbsentMains.check(healer)
    assert {:ok, %{outcome: "failed"}} = Acts.get(ctx.acts, last)
    assert [%{state: "absent_main:app-epic:3", reason: ~s(["waited","no_account"])}] = asked(ctx)
  end
end
