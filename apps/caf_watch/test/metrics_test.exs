defmodule CodingAgentFramework.Watch.MetricsTest do
  @moduledoc """
  One reading of the metrics (F-199) on fixed rows, each shaped as its table's module reads it:
  a test per metric, each rule's sides, and a row on each side of a UTC day and an ISO week cut.
  """
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Watch.Metrics

  doctest Metrics

  # Monday 2026-11-23, 00:00 UTC: a day cut and an ISO week cut at once.
  @monday DateTime.to_unix(~U[2026-11-23 00:00:00Z], :millisecond)
  @hour 3_600_000

  defp delegate(id, name, at, fields \\ []) do
    Map.merge(
      %{id: id, name: name, brief_uuid: "b#{id}", status: "running", resumes: 0, created_at: at},
      Map.new([updated_at: at] ++ fields)
    )
  end

  defp report(id, of, at, fields \\ []) do
    row = %{id: id, kind: "reply", uuid: "r#{id}", reply_to: "b#{of}", status: "delivered"}
    Map.merge(row, Map.new([created_at: at, updated_at: at + 1_000, again: 0] ++ fields))
  end

  defp act(id, actor, act, target, at, fields \\ []) do
    row = %{id: id, actor: actor, act: act, target: target, state: nil, detail: nil}
    fields = [status: "settled", outcome: "verified", claimed_at: at, acted_at: at] ++ fields
    Map.merge(row, Map.new(fields))
  end

  defp symptom(id, kind, target, since, fields \\ []) do
    row = %{id: id, kind: kind, target: target, state: "s#{id}", since: since, evidence: nil}
    Map.merge(row, Map.new([status: "open", asked_at: nil, answered_at: nil] ++ fields))
  end

  defp read(rows, by \\ :all, from \\ @monday - 7 * 24 * @hour, to \\ @monday + 7 * 24 * @hour) do
    rows = Map.merge(%{acts: [], delegates: [], messages: [], symptoms: [], holds: []}, rows)
    {:ok, periods} = Metrics.fold(rows, since: from, until: to, by: by, operator: "operator")
    periods
  end

  defp all(rows), do: hd(read(rows))

  defp names(metric), do: Enum.map(metric.evidence, & &1.name)

  test "a delegate counts in the UTC day and the ISO week it started" do
    rows = %{
      delegates: [delegate(1, "app-sun", @monday - 1), delegate(2, "app-mon", @monday)],
      messages: [report(10, 1, @monday + 5 * 60_000), report(11, 2, @monday + 60_000)]
    }

    days = read(rows, :day, @monday - 24 * @hour, @monday + 24 * @hour)

    assert [{"2026-11-22", ["app-sun"]}, {"2026-11-23", ["app-mon"]}] =
             Enum.map(days, &{&1.period, names(&1.started)})

    assert [%{until: @monday}, %{from: @monday}] = days

    weeks = read(rows, :week, @monday - 24 * @hour, @monday + 24 * @hour)
    assert ["2026-W47", "2026-W48"] = Enum.map(weeks, & &1.period)
    assert [["app-sun"], ["app-mon"]] = Enum.map(weeks, &names(&1.started))

    # The report of the delegate started Sunday came Monday, and counts in Sunday's period.
    assert [%{reported: %{count: 1, ms: %{max: 300_001}}}, %{reported: %{count: 1}}] = days
    assert %{started: %{count: 2}, reported: %{count: 2, ms: %{median: 60_000}}} = all(rows)
  end

  test "stalled: once per delegate, on a stall's symptom or a Stop that never came" do
    rows = %{
      delegates: [
        delegate(1, "app-hung", @monday),
        delegate(2, "app-quiet", @monday),
        delegate(3, "app-clear", @monday),
        # The name's next row: what fires on the name from now on is this row's.
        delegate(4, "app-hung", @monday + @hour),
        # Its report read from the transcript once its process was gone (F-202), and one
        # taken from its result.
        delegate(5, "app-lost", @monday, taken_by: "transcript"),
        delegate(6, "app-fine", @monday, taken_by: "result")
      ],
      messages: [report(10, 5, @monday + 60_000), report(11, 6, @monday + 60_000)],
      symptoms: [
        symptom(20, "stuck_background", "app-hung", @monday + 60_000),
        symptom(21, "stuck_background", "app-hung", @monday + 120_000),
        symptom(22, "hooks_silent", "app-quiet", @monday + 60_000),
        symptom(23, "stuck_background", "app-hung", @monday + 2 * @hour)
      ]
    }

    stalled = all(rows).stalled
    assert %{count: 3} = stalled
    refute Map.has_key?(stalled, :unread)

    assert [
             %{delegate: 1, symptoms: [20, 21], why: ["stuck_background"]},
             %{delegate: 4, symptoms: [23], why: ["stuck_background"]},
             %{delegate: 5, symptoms: [], why: ["stop_lost"]}
           ] = stalled.evidence
  end

  test "late: (a) its Stop lost, (b) released by its healer, (c) relayed past 60 s" do
    rows = %{
      delegates:
        for(id <- 1..4, do: delegate(id, "app-#{id}", @monday)) ++
          [
            delegate(5, "app-5", @monday, taken_by: "transcript"),
            delegate(6, "app-6", @monday),
            delegate(7, "app-7", @monday)
          ],
      messages: [
        report(10, 1, @monday + 600_000),
        # Rows of an earlier build: no `delivered_at`, so `updated_at` is read.
        report(11, 2, @monday + 1_000, updated_at: @monday + 1_000 + 61_000),
        report(12, 3, @monday + 1_000, updated_at: @monday + 1_000 + 59_000),
        report(13, 4, @monday + 1_000, status: "queued", updated_at: @monday + 900_000),
        report(14, 5, @monday + 1_000),
        # `delivered_at` (F-202) is read, whatever wrote the row later.
        report(15, 6, @monday + 1_000,
          delivered_at: @monday + 1_000 + 61_000,
          updated_at: @monday + 2_000
        ),
        report(16, 7, @monday + 1_000,
          delivered_at: @monday + 1_000 + 59_000,
          updated_at: @monday + 900_000
        )
      ],
      acts: [act(30, "stuck_backgrounds:ws", "end", "app-1", @monday + 500_000)]
    }

    late = all(rows).late
    assert %{count: 4} = late
    refute Map.has_key?(late, :unread)

    assert [
             %{name: "app-1", why: ["b"]},
             %{name: "app-2", why: ["c"]},
             %{name: "app-5", why: ["a"]},
             %{name: "app-6", why: ["c"]}
           ] = late.evidence
  end

  test "killed: a process gone with no act of the framework's; restarted: its resume" do
    resume = fn id, delegate, at ->
      act(id, "delegates:ws", "resume", "app-#{delegate}", at,
        state: ~s({"delegate":#{delegate},"resumes":0}),
        outcome: "failed"
      )
    end

    rows = %{
      delegates: [
        delegate(1, "app-1", @monday, resumes: 1),
        delegate(2, "app-2", @monday, resumes: 1),
        delegate(3, "app-3", @monday),
        delegate(4, "app-4", @monday, resumes: 1)
      ],
      acts: [
        # app-1 crashed: nothing of the framework's ended it before its resume.
        resume.(40, 1, @monday + @hour),
        # app-2 was ended by the operator first: not a kill.
        act(41, "operator", "end_main", "app-2", @monday + 60_000),
        resume.(42, 2, @monday + @hour),
        # app-4's stop came after its resume: it does not excuse the kill.
        resume.(43, 4, @monday + 60_000),
        act(44, "app-main", "stop", "app-4", @monday + @hour)
      ]
    }

    period = all(rows)
    assert ["app-1", "app-4"] = names(period.killed)
    assert %{count: 2, by_outcome: %{"failed" => 2}} = period.restarted

    # A recovery counts in the period it acted, the kill in the period its delegate started.
    days = read(rows, :day, @monday - 24 * @hour, @monday + 2 * 24 * @hour)
    assert [0, 2, 0] = Enum.map(days, & &1.killed.count)
  end

  test "killed: each kill Delegates recorded, one whose resume was refused and a second" do
    killed = fn id, delegate, resumes, at ->
      act(id, "delegates:ws", "killed", "app-#{delegate}", at,
        state: "killed:ws:#{delegate}:#{resumes}",
        detail: ~s({"delegate":#{delegate},"resumes":#{resumes}})
      )
    end

    rows = %{
      delegates: [
        # Its resume refused before its claim (F-199's new-6): failed, with no resume counted.
        delegate(1, "app-1", @monday, status: "failed"),
        # Killed twice: the first resumed, the second its report.
        delegate(2, "app-2", @monday, status: "failed", resumes: 1),
        # Killed once more after the operator's end of its first life: only the second counts.
        delegate(3, "app-3", @monday, status: "failed", resumes: 1)
      ],
      acts: [
        killed.(50, 1, 0, @monday + 60_000),
        killed.(51, 2, 0, @monday + 60_000),
        act(52, "delegates:ws", "resume", "app-2", @monday + 61_000,
          state: ~s({"delegate":2,"resumes":0})
        ),
        killed.(53, 2, 1, @monday + 120_000),
        act(54, "operator", "end", "app-3", @monday + 30_000),
        killed.(55, 3, 0, @monday + 60_000),
        killed.(56, 3, 1, @monday + 120_000)
      ]
    }

    period = all(rows)
    assert %{count: 4, delegates: 3} = period.killed

    assert [
             %{delegate: 1, resumes: 0},
             %{delegate: 2, resumes: 0},
             %{delegate: 2, resumes: 1},
             %{delegate: 3, resumes: 1}
           ] = period.killed.evidence

    assert %{count: 1, by_outcome: %{"verified" => 1}} = period.restarted
    # A kill is a fact Delegates recorded, never a recovery.
    assert %{fired: 1} = period.recoveries
  end

  test "dropped: a report settled unknown or made due again" do
    rows = %{
      delegates: for(id <- 1..3, do: delegate(id, "app-#{id}", @monday)),
      messages: [
        report(10, 1, @monday, status: "unknown"),
        report(11, 2, @monday, again: 1),
        report(12, 3, @monday)
      ]
    }

    assert %{count: 2, evidence: [%{status: "unknown"}, %{again: true}]} = all(rows).dropped
  end

  test "limited, with the time past its reset; moves, by outcome" do
    reset = div(@monday, 1_000) + 3_600
    evidence = ~s({"account":"work","until":#{reset},"window":"five_hour"})

    rows = %{
      symptoms: [
        symptom(50, "limited", "app-1", @monday,
          evidence: evidence,
          status: "passed",
          passed_at: reset * 1_000 + 90_000
        ),
        symptom(51, "limited", "app-2", @monday, evidence: evidence)
      ],
      acts: [act(52, "limits:ws", "move", "app-2", @monday + 60_000, outcome: "unknown")]
    }

    period = all(rows)
    assert %{count: 2, ms: %{max: 90_000}} = period.limited
    assert [%{account: "work", ms: 90_000}, %{agent: "app-2", ms: nil}] = period.limited.evidence
    assert %{count: 1, by_outcome: %{"unknown" => 1}} = period.moves
  end

  test "prompts: opened and answered by kind, and the time to answer from the open" do
    answer = fn id, prompt, opened, at ->
      detail =
        ~s({"prompt":"#{prompt}","kind":"#{hd(String.split(prompt, ":"))}",) <>
          ~s("opened_at":#{opened}})

      act(id, "sam", "answer", "app-1", at, detail: detail)
    end

    opened = fn id, prompt, at ->
      kind = hd(String.split(prompt, ":"))
      detail = ~s({"prompt":"#{prompt}","kind":"#{kind}","opened_at":#{at}})
      act(id, "prompts:ws", "opened", "app-1", at, state: "opened:ws:#{prompt}", detail: detail)
    end

    rows = %{
      messages: [
        %{id: 1, kind: "ask", uuid: "q1", reply_to: nil, status: "kept", created_at: @monday},
        %{
          id: 2,
          kind: "answer",
          uuid: "a1",
          reply_to: "q1",
          status: "delivered",
          created_at: @monday + 30_000
        },
        %{id: 3, kind: "ask", uuid: "q2", reply_to: nil, status: "kept", created_at: @monday}
      ],
      symptoms: [
        symptom(60, "absent_main", "app-main", @monday,
          asked_at: @monday + 1_000,
          answered_at: @monday + 11_000
        )
      ],
      holds: [
        # Rows of an earlier build, with no `held_at`: one still held opened at its
        # `written_at`; one decided has lost its open time, and one an answer row names is
        # read from that row.
        %{id: 70, hold: "held", prompt: nil, written_at: @monday + 5_000},
        %{id: 71, hold: "answered", prompt: nil, written_at: @monday + 9_000},
        %{id: 72, hold: "answered", prompt: nil, written_at: @monday + 9_000},
        # F-202's: held at `held_at`, and decided by the app's callback at its settle; one
        # that expired is opened and never answered.
        %{
          id: 73,
          hold: "answered",
          prompt: nil,
          actor: "app",
          held_at: @monday + 1_000,
          written_at: @monday + 1_500
        },
        %{id: 74, hold: "expired", prompt: nil, held_at: @monday + 2_000, written_at: @monday + 9}
      ],
      acts: [
        answer.(80, "ask:1", @monday, @monday + 30_000),
        answer.(81, "permission:72", @monday + 2_000, @monday + 8_000),
        answer.(82, "dialog:app-1:5:trust", @monday + 3_000, @monday + 4_000),
        # A refused answer leaves its prompt open.
        act(83, "sam", "answer", "app-1", @monday + 6_000,
          detail: ~s({"prompt":"stop_cap:90","kind":"stop_cap","opened_at":#{@monday}}),
          outcome: "failed"
        ),
        # Each open Prompts recorded (F-202): a login and a limit never answered count too.
        opened.(84, "dialog:app-1:5:trust", @monday + 3_000),
        opened.(85, "login:work", @monday + 7_000),
        opened.(86, "limit:app-1:99", @monday + 8_000),
        opened.(87, "permission:70", @monday + 5_000)
      ]
    }

    prompts = all(rows).prompts
    assert %{opened: 11, answered: 5} = prompts
    refute Map.has_key?(prompts, :unread)

    assert %{
             "ask" => %{opened: 2, answered: 1},
             "remedy" => %{opened: 1, answered: 1},
             "permission" => %{opened: 4, answered: 2},
             "dialog" => %{opened: 1, answered: 1},
             "stop_cap" => %{opened: 1, answered: 0},
             "login" => %{opened: 1, answered: 0},
             "limit" => %{opened: 1, answered: 0}
           } = prompts.by_kind

    assert %{median: 6_000, max: 30_000} = prompts.ms

    assert [%{by: "app", ms: 500}] =
             Enum.filter(prompts.evidence, &(&1.prompt == "permission:73"))

    # A prompt counts in the period it opened.
    days = read(rows, :day, @monday - 24 * @hour, @monday + 24 * @hour)
    assert [0, 11] = Enum.map(days, & &1.prompts.opened)
  end

  test "recoveries by outcome and those left for a person; a person's interventions" do
    rows = %{
      acts: [
        act(1, "recoveries:ws:caf", "reopen", "app-main", @monday),
        act(2, "absent_mains:ws", "resume", "app-main", @monday, outcome: "not_verified"),
        act(3, "limits:ws", "go_on", "app-1", @monday, status: "claimed", outcome: nil),
        act(4, "sam", "resume", "app-main", @monday, detail: ~s({"healer":"absent_mains:ws"})),
        act(5, "person", "typed", "app-main", @monday, state: "typed:ws:41"),
        act(6, "person", "interrupt", "app-main", @monday, state: "interrupt:app-main:u-1"),
        act(7, "person", "attach", "app-main", @monday, state: "attach:ws:caf:/dev/ttys003:9"),
        act(8, "sam", "answer", "app-1", @monday, detail: ~s({"prompt":"ask:1","kind":"ask"})),
        act(9, "operator", "stop", "app-1", @monday),
        # A parent's fixes through MCP are the parent's, and an operator's interrupt is no stop.
        act(10, "app-main", "answer", "app-1", @monday),
        act(11, "app-main", "interrupt", "app-1", @monday, state: ~s({"offset":812})),
        act(12, "operator", "interrupt", "app-1", @monday)
      ],
      symptoms: [symptom(13, "end_owed", "app-1", @monday, asked_at: @monday + 1)]
    }

    period = all(rows)

    assert %{fired: 4, asked: 1, by_outcome: outcomes} = period.recoveries
    assert %{"verified" => 2, "not_verified" => 1, "claimed" => 1} = outcomes

    assert %{count: 5, by_kind: kinds, by_actor: %{"person" => 3, "sam" => 1, "operator" => 1}} =
             period.interventions

    assert %{"typed" => 1, "interrupt" => 1, "attach" => 1, "answer" => 1, "stop" => 1} = kinds
  end

  test "a window or a cut out of shape is refused" do
    rows = %{acts: [], delegates: [], messages: [], symptoms: [], holds: []}
    assert {:refused, {:bad, :since}} = Metrics.fold(rows, until: 1)
    assert {:refused, {:bad, :until}} = Metrics.fold(rows, since: 5, until: 5)
    assert {:refused, {:bad, :by}} = Metrics.fold(rows, since: 0, until: 1, by: :month)
  end
end
