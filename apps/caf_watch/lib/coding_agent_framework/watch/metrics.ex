defmodule CodingAgentFramework.Watch.Metrics do
  @moduledoc """
  One reading of the metrics (`docs/design.md`, "Metrics and healing"; F-199): a pure fold over
  rows the framework already keeps, by the rules an app's own baseline counts by, so the two
  compare. It keeps no table and reads nothing itself: `CodingAgentFramework.metrics/2` reads the
  rows once and hands them to `fold/2`.

  The rows, each as its table's module reads it: `acts` (`Acts.Table`, every act), `delegates`
  (`Delegates.Table`, one row per start of a delegate), `messages` (`Mailbox.Table`), `symptoms`
  (`Watch.Table`) and `holds` (`Intake.Table.holds/2`, every hold that could wait on a person).
  Times are wall-clock ms; a row with no time a rule needs is not counted.
  """

  @day 86_400_000
  @late 60_000
  # An act of the framework's that ends an agent's process: a parent's or the operator's stop,
  # a healer's or the operator's end, a move.
  @ends ~w(stop end end_main move)
  # The healers' actors (`<prefix><host>…`): each act of theirs is a recovery.
  @healers ~w(recoveries: absent_mains: stuck_backgrounds: limits: delegates:)
  # A person's interventions that `Interventions` and `TmuxSampler` read as facts.
  @read ~w(typed interrupt attach)
  @metrics ~w(started reported stalled late killed restarted dropped limited moves prompts
              recoveries interventions)a

  @typedoc "The rows `fold/2` reads, by table."
  @type rows :: %{
          acts: [map],
          delegates: [map],
          messages: [map],
          symptoms: [map],
          holds: [map]
        }

  @typedoc "One cut's reading: its label, its bounds (ms, `until` not in it) and each metric."
  @type period :: %{
          required(:period) => String.t(),
          required(:from) => integer,
          optional(atom) => map
        }

  @doc """
  The metrics of `rows` within `since:` and `until:` (wall-clock ms, `until` not in it), cut
  `by:` `:day`, `:week` or `:all` (the default). Answers `{:ok, periods}`, oldest first, each
  `%{period, from, until}` and one entry per metric; `{:refused, {:bad, key}}` for a bound or a
  cut out of shape. Option `operator:` names the operator, whose stops are a person's acts.

  **Cuts.** UTC: a day is `"2026-11-23"`, a week ISO's, Monday to Sunday, `"2026-W48"`; `:all` is
  one period, `"all"`. The first and last cut are clipped to `since` and `until`. A delegate counts
  in the period its row was made (it started), a recovery in the period it acted (its `acted_at`,
  else its claim), a prompt in the period it opened, a person's act in the period it was
  claimed, and a usage limit in the period it began (its symptom's `since`; the last two
  confirmed in F-202, from F-199's new-4).

  **The metrics**, each with its evidence (the rows it counted), and a time's median and max
  where it has one. A row written before F-202 lacks the fact a rule reads since (`taken_by`,
  `held_at`, `delivered_at`, a `killed` or `opened` record), and is read as F-199 read it, where
  that reading is named below:

  - `started`: each delegate row.
  - `reported`: each delegate whose report (`Mailbox`'s reply or notice to its brief) is stored;
    its time is the report's row less the delegate's.
  - `stalled`: each delegate on which a stall's symptom fired, once, by its own row, saying which
    (`why`): `"stuck_background"`, recorded on its name while the row was the name's latest, its
    bound the symptom's own (a stall that cleared before its symptom fired has no symptom row,
    and is not counted); `"stop_lost"`, its report taken from the transcript once its process
    was gone, because its `Stop` (a headless turn's `result`, an interactive turn's end) never
    came (its row's `taken_by` is `transcript`, F-202).
  - `late`: each report that reached the parent by a recovery's path, saying which: `"a"`, its
    `Stop` lost and the report taken from the transcript (`taken_by` `transcript`); `"b"`, held
    behind a background command and released by its healer (stored after the
    `stuck_backgrounds` healer's `end` on its delegate); `"c"`, relayed more than 60 s after it was
    taken (its row's `delivered_at` more than 60 s after it was stored; before F-202, its
    `updated_at` once `delivered`).
  - `killed`: each kill of a delegate's process with no act of the framework's (a crash
    included), a delegate killed twice counted twice (`delegates` counts the delegates): each
    `killed` record of `Delegates` (F-202), keyed by its row and its resumes before the kill,
    whatever followed it, a resume or a failure; before F-202, a resume its row counts or its
    resume claim names. No act that ends a process (`stop`, `end`, `end_main`, `move`) was
    claimed on its name from the kill before it (or its start) to the kill.
  - `restarted`: each resume `Delegates` claimed after such a kill, with its outcome.
  - `dropped`: each report settled `unknown` or made due again.
  - `limited`: each agent's usage limit (`Watch`'s `limited`), with its account and window, and
    its time past the reset: from the reset until the limit passed.
  - `moves`: each move `Limits` claimed, with its outcome.
  - `prompts`: each prompt that opened, `opened` and `answered`, by kind, its time to answer from
    its open to its answer, and who answered (`by`). Read from the asks (`Mailbox`), the remedy
    prompts (`Watch`), every hold (`Intake`), each open `Prompts` recorded (act `opened`,
    F-202), and every answer row of `answer/4` (F-194), which names its prompt and when it
    opened. A hold opened at its `held_at` (before F-202, a hold still open at its
    `written_at`, and a decided one is not counted); one settled `answered` or `passed` by an
    actor (the app's callback, a pause, a person) was answered by it at its settle. A dialog,
    login or limit prompt never answered counts from its `opened` record.
  - `recoveries`: each act of a healer (`recoveries:`, `absent_mains:`, `stuck_backgrounds:`,
    `limits:`, `delegates:`, but not the facts `Delegates` records, `killed`) or of a person's
    remedy (its `detail` names its healer), by outcome
    (its `outcome`, else its status); and `asked`, each symptom left for a person (its `remedy`
    prompt opened).
  - `interventions`: each of a person's acts, by its act (`by_kind`) and by actor: an answer of
    `answer/4` (`answer` with its prompt in its `detail`); typed input, an interrupt and a viewer
    attached (`typed`, `interrupt`, `attach`), each a fact recorded under a key that begins with
    its act, so a parent's interrupt through `MCP` is not one; and the operator's `stop`, `end`
    and `end_main`.

      iex> alias CodingAgentFramework.Watch.Metrics
      iex> rows = %{acts: [], messages: [], symptoms: [], holds: [],
      ...>   delegates: [%{id: 1, name: "app-a", brief_uuid: "b1", resumes: 0,
      ...>     created_at: 1_000, updated_at: 1_000}]}
      iex> {:ok, [p]} = Metrics.fold(rows, since: 0, until: 86_400_000, by: :day)
      iex> {p.period, p.started.count, p.killed.count}
      {"1970-01-01", 1, 0}
  """
  @spec fold(rows, keyword) :: {:ok, [period]} | {:refused, term}
  def fold(rows, opts) do
    with {:ok, since, until, by} <- window(opts) do
      facts = facts(rows, Keyword.get(opts, :operator))

      {:ok,
       for {label, from, to} <- cuts(since, until, by) do
         within = for {m, at, e} <- facts, at >= from and at < to, do: {m, e}
         grouped = Enum.group_by(within, &elem(&1, 0), &elem(&1, 1))
         base = %{period: label, from: from, until: to}
         Enum.reduce(@metrics, base, &Map.put(&2, &1, sum(&1, Map.get(grouped, &1, []))))
       end}
    end
  end

  defp window(opts) do
    {since, until, by} = {opts[:since], opts[:until], Keyword.get(opts, :by, :all)}

    cond do
      not is_integer(since) -> {:refused, {:bad, :since}}
      not is_integer(until) or until <= since -> {:refused, {:bad, :until}}
      by not in [:day, :week, :all] -> {:refused, {:bad, :by}}
      true -> {:ok, since, until, by}
    end
  end

  @doc """
  The UTC cuts of `[since, until)` by `by`, each `{label, from, until}`, clipped to the window.

      iex> CodingAgentFramework.Watch.Metrics.cuts(0, 86_400_001, :day)
      [{"1970-01-01", 0, 86_400_000}, {"1970-01-02", 86_400_000, 86_400_001}]
      iex> CodingAgentFramework.Watch.Metrics.cuts(0, 1, :week)
      [{"1970-W01", 0, 1}]
  """
  @spec cuts(integer, integer, :day | :week | :all) :: [{String.t(), integer, integer}]
  def cuts(since, until, :all), do: [{"all", since, until}]

  def cuts(since, until, by) do
    {first, step} =
      case by do
        :day -> {Integer.floor_div(since, @day) * @day, @day}
        :week -> {midnight(Date.beginning_of_week(date(since), :monday)), 7 * @day}
      end

    first
    |> Stream.iterate(&(&1 + step))
    |> Enum.take_while(&(&1 < until))
    |> Enum.map(&{label(by, date(&1)), max(&1, since), min(&1 + step, until)})
  end

  defp date(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date()

  defp midnight(date),
    do: date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp label(:day, date), do: Date.to_iso8601(date)

  defp label(:week, date) do
    {year, week} = :calendar.iso_week_number(Date.to_erl(date))
    "#{year}-W#{String.pad_leading("#{week}", 2, "0")}"
  end

  # Every fact the rows hold, `{metric, at, evidence}`; each period keeps the ones it holds.
  defp facts(rows, operator) do
    acts = Enum.map(Map.get(rows, :acts, []), &decode(&1, [:detail, :state]))
    messages = Map.get(rows, :messages, [])
    symptoms = Map.get(rows, :symptoms, [])
    reports = for m <- messages, m.kind in ["reply", "notice"], into: %{}, do: {m.reply_to, m}

    delegates(Map.get(rows, :delegates, []), acts, reports, symptoms) ++
      limits(symptoms, acts) ++
      prompts(acts, messages, symptoms, Map.get(rows, :holds, [])) ++
      recoveries(acts, symptoms) ++ interventions(acts, operator)
  end

  defp delegates(rows, acts, reports, symptoms) do
    own = for a <- acts, healer?(a, "delegates:"), a.act in ["resume", "killed"], do: a
    {killed, resumes} = Enum.split_with(own, &(&1.act == "killed"))

    of = %{
      resumes: Enum.group_by(resumes, &field(&1.state, "delegate")),
      killed: Enum.group_by(killed, &field(&1.detail, "delegate"))
    }

    for {d, till} <- lives(rows), fact <- delegate(d, till, acts, reports, symptoms, of) do
      fact
    end
  end

  # Each delegate row with the time the next row of its name was made (nil for the latest):
  # what is recorded on its name in between is of this row.
  defp lives(rows) do
    rows
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn {_, of_name} ->
      of_name = Enum.sort_by(of_name, & &1.id)
      Enum.zip(of_name, Enum.map(tl(of_name), & &1.created_at) ++ [nil])
    end)
    |> Enum.sort_by(fn {d, _} -> d.id end)
  end

  defp delegate(d, till, acts, reports, symptoms, of) do
    at = d.created_at
    who = %{delegate: d.id, name: d.name}
    in_life? = fn t -> is_integer(t) and t >= at and (till == nil or t < till) end
    report = reports[d.brief_uuid]
    # Its report read from the transcript once its process was gone (F-202): its `Stop` lost.
    lost? = report != nil and d[:taken_by] == "transcript"

    stuck =
      for s <- symptoms,
          s.kind == "stuck_background",
          s.target == d.name,
          in_life?.(s.since),
          do: s.id

    healed =
      for a <- acts,
          healer?(a, "stuck_backgrounds:"),
          a.act == "end",
          a.target == d.name,
          in_life?.(acted(a)),
          do: acted(a)

    stalled = Enum.filter([{"stuck_background", stuck != []}, {"stop_lost", lost?}], &elem(&1, 1))
    stalled = Map.merge(who, %{symptoms: stuck, why: Enum.map(stalled, &elem(&1, 0))})

    [{:started, at, who}] ++
      if(report, do: report_facts(at, who, report, healed, lost?), else: []) ++
      if(stalled.why != [], do: [{:stalled, at, stalled}], else: []) ++
      kill_facts(d, who, of, acts, in_life?)
  end

  defp report_facts(at, who, m, healed, lost?) do
    relayed = delivered_at(m)

    why =
      Enum.filter(
        [
          {"a", lost?},
          {"b", Enum.any?(healed, &(&1 < m.created_at))},
          {"c", is_integer(relayed) and relayed - m.created_at > @late}
        ],
        &elem(&1, 1)
      )

    of = Map.put(who, :message, m.id)

    [{:reported, at, Map.put(of, :ms, m.created_at - at)}] ++
      if(why != [], do: [{:late, at, Map.put(of, :why, Enum.map(why, &elem(&1, 0)))}], else: []) ++
      if(m.status == "unknown" or m.again in [1, true],
        do: [{:dropped, at, Map.merge(of, %{status: m.status, again: m.again in [1, true]})}],
        else: []
      )
  end

  # Killed: each kill of the row, by its resumes before it (0 the first, 1 the second), with no
  # act that ends a process claimed on its name since the kill before it (or its start). A
  # kill is `Delegates`' `killed` record (F-202); one before F-202 is read as F-199 read it, from
  # its resume's claim or the row's count of resumes. Restarted: each resume claimed after a
  # kill so counted.
  defp kill_facts(d, who, of, acts, in_life?) do
    recorded =
      for a <- Map.get(of.killed, d.id, []), do: {field(a.detail, "resumes"), a.claimed_at}

    resumes = Map.get(of.resumes, d.id, [])
    claimed = for a <- resumes, do: {field(a.state, "resumes") || 0, a.claimed_at}
    counted = if d.resumes > 0, do: [{0, d.updated_at}], else: []

    kills =
      (recorded ++ claimed ++ counted)
      |> Enum.filter(fn {n, t} -> is_integer(n) and is_integer(t) end)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort()

    ends = for a <- acts, a.act in @ends, a.target == d.name, in_life?.(a.claimed_at), do: a

    seen =
      Enum.zip(kills, [d.created_at | Enum.map(kills, &elem(&1, 1))])
      |> Enum.reject(fn {{_n, t}, from} ->
        Enum.any?(ends, &(&1.claimed_at >= from and &1.claimed_at <= t))
      end)
      |> Enum.map(fn {{n, _t}, _from} -> n end)

    for(n <- seen, do: {:killed, d.created_at, Map.put(who, :resumes, n)}) ++
      for a <- resumes,
          (field(a.state, "resumes") || 0) in seen,
          do: {:restarted, acted(a), Map.merge(who, act(a))}
  end

  defp limits(symptoms, acts) do
    for(s <- symptoms, s.kind == "limited", do: {:limited, s.since, limit(s)}) ++
      for a <- acts, healer?(a, "limits:"), a.act == "move", do: {:moves, acted(a), act(a)}
  end

  defp limit(s) do
    ev = json(s.evidence)
    reset = past_reset(ev["until"], s[:passed_at])
    %{symptom: s.id, agent: s.target, account: ev["account"], window: ev["window"], ms: reset}
  end

  # From the reset (Unix seconds) until the limit passed (ms); nil while either is unknown.
  defp past_reset(reset, passed) when is_integer(reset) and is_integer(passed),
    do: max(passed - reset * 1_000, 0)

  defp past_reset(_reset, _passed), do: nil

  defp prompts(acts, messages, symptoms, holds) do
    # A prompt's answer rows: the first the owner took answers it; any names when it opened.
    answers =
      acts
      |> Enum.filter(&(&1.act == "answer" and is_binary((&1.detail || %{})["prompt"])))
      |> Enum.group_by(& &1.detail["prompt"])

    answered =
      Enum.flat_map(answers, fn {id, rows} ->
        case Enum.find(rows, &(&1.outcome == "verified")) do
          nil -> []
          a -> [{id, a}]
        end
      end)
      |> Map.new()

    asks =
      for m <- messages, m.kind == "ask" do
        reply =
          Enum.find(messages, &(&1.kind in ["answer", "withdrawn"] and &1.reply_to == m.uuid))

        {"ask:#{m.id}", {m.created_at, reply && reply.created_at, nil}}
      end

    remedies =
      for s <- symptoms,
          is_integer(s[:asked_at]),
          do: {"remedy:#{s.id}", {s.asked_at, s[:answered_at], nil}}

    # A hold with no open time (decided before F-202) is left to its answer row, if any.
    holds =
      for h <- holds,
          {opened, _, _} = t = hold(h),
          is_integer(opened),
          do: {"#{hold_kind(h)}:#{h.id}", t}

    owned = Map.new(asks ++ remedies ++ holds)

    # Each prompt's open that `Prompts` recorded (F-202), the earliest of its id; then a prompt
    # only an answer row names (one answered before F-202), with the open time that row carries.
    recorded =
      for a <- Enum.sort_by(acts, & &1.claimed_at, :desc),
          a.act == "opened" and healer?(a, "prompts:"),
          into: %{},
          do: {field(a.detail, "prompt"), {field(a.detail, "opened_at"), nil, nil}}

    from_answers =
      for {id, [a | _]} <- answers, into: %{}, do: {id, {a.detail["opened_at"], nil, nil}}

    every = from_answers |> Map.merge(recorded) |> Map.merge(owned)

    for {id, {opened, at, by}} <- every, is_binary(id) and is_integer(opened) do
      a = answered[id]
      {at, by} = if a, do: {a.claimed_at, a.actor}, else: {at, by}

      {:prompts, opened,
       %{
         prompt: id,
         kind: (a && a.detail["kind"]) || hd(String.split(id, ":")),
         by: by,
         ms: if(is_integer(at), do: at - opened)
       }}
    end
  end

  defp hold_kind(h), do: if(h.prompt == "stop_cap", do: "stop_cap", else: "permission")

  # A hold opened at its `held_at` (F-202); one written before F-202 has only its `written_at`,
  # its open time while it is still held. A hold that settled with an actor (the app's
  # callback, a pause, a person) was answered by it, at its settle.
  defp hold(h) do
    opened = h[:held_at] || if(h.hold in ["held", "deciding"], do: h.written_at)
    decided? = h.hold in ["answered", "passed"] and is_binary(h[:actor])
    if decided?, do: {opened, h.written_at, h.actor}, else: {opened, nil, nil}
  end

  # A kill `Delegates` saw is a fact it recorded, not a recovery.
  defp recoveries(acts, symptoms) do
    for(
      a <- acts,
      a.act != "killed",
      Enum.any?(@healers, &healer?(a, &1)) or is_binary(field(a.detail, "healer")),
      do: {:recoveries, acted(a), Map.put(act(a), :actor, a.actor)}
    ) ++
      for s <- symptoms,
          is_integer(s[:asked_at]),
          do: {:recoveries, s.asked_at, %{asked: s.id, kind: s.kind, target: s.target}}
  end

  defp interventions(acts, operator) do
    for a <- acts,
        (a.act == "answer" and is_binary((a.detail || %{})["prompt"])) or read_fact?(a) or
          (a.actor == operator and a.act in ~w(stop end end_main)),
        do: {:interventions, a.claimed_at, Map.merge(act(a), %{actor: a.actor, kind: a.act})}
  end

  # A fact a reader found is keyed by its act (`typed:<host>:<intake id>`, …), so a parent's
  # interrupt through `MCP`, also act `interrupt`, is never read as a person's.
  defp read_fact?(%{act: act, state: state}),
    do: act in @read and is_binary(state) and String.starts_with?(state, act <> ":")

  # Each metric's shape from its evidence.
  defp sum(:prompts, es) do
    %{
      opened: length(es),
      answered: Enum.count(es, &is_integer(&1.ms)),
      by_kind:
        es
        |> Enum.group_by(& &1.kind)
        |> Map.new(fn {k, of} ->
          {k, %{opened: length(of), answered: Enum.count(of, & &1.ms)}}
        end),
      ms: times(es),
      evidence: es
    }
  end

  defp sum(:recoveries, es) do
    {asked, fired} = Enum.split_with(es, &Map.has_key?(&1, :asked))

    %{
      fired: length(fired),
      by_outcome: Enum.frequencies_by(fired, & &1.outcome),
      asked: length(asked),
      evidence: es
    }
  end

  defp sum(:interventions, es) do
    %{
      count: length(es),
      by_kind: Enum.frequencies_by(es, & &1.kind),
      by_actor: Enum.frequencies_by(es, & &1.actor),
      evidence: es
    }
  end

  defp sum(metric, es) do
    extra =
      case metric do
        m when m in [:reported, :limited] -> %{ms: times(es)}
        m when m in [:restarted, :moves] -> %{by_outcome: outcomes(es)}
        :killed -> %{delegates: es |> Enum.uniq_by(& &1.delegate) |> length()}
        _ -> %{}
      end

    Map.merge(%{count: length(es), evidence: es}, extra)
  end

  defp outcomes(es), do: Enum.frequencies_by(es, & &1.outcome)

  defp times(es) do
    case Enum.sort(for %{ms: ms} <- es, is_integer(ms), do: ms) do
      [] -> nil
      sorted -> %{median: Enum.at(sorted, div(length(sorted) - 1, 2)), max: List.last(sorted)}
    end
  end

  defp act(a), do: %{act: a.id, target: a.target, outcome: a.outcome || a.status}
  defp acted(a), do: a.acted_at || a.claimed_at

  defp healer?(%{actor: actor}, prefix),
    do: is_binary(actor) and String.starts_with?(actor, prefix)

  # A key of a decoded `detail` or `state`, nil for one that is not a map.
  defp field(%{} = map, key), do: map[key]
  defp field(_other, _key), do: nil

  # When a report was relayed: its `delivered_at` (F-202); a row delivered before F-202 keeps
  # no time of it, and its `updated_at` is that write's, as F-199 read it.
  defp delivered_at(%{delivered_at: at}) when is_integer(at), do: at
  defp delivered_at(%{status: "delivered", updated_at: at}), do: at
  defp delivered_at(_m), do: nil

  defp decode(row, keys),
    do: Enum.reduce(keys, row, &Map.update(&2, &1, nil, fn v -> json_or(v) end))

  # A detail or state stored as JSON reads as a map; anything else is kept as it is.
  defp json_or(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = map} -> map
      _ -> text
    end
  end

  defp json_or(other), do: other

  defp json(text) do
    case json_or(text) do
      %{} = map -> map
      _ -> %{}
    end
  end
end
