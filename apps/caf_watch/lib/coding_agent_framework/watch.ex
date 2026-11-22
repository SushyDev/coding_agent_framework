defmodule CodingAgentFramework.Watch do
  @moduledoc """
  The symptom record and the remedies' allow-list (`docs/design.md`, "Metrics and healing";
  B7's start and B8, F-182; `model/tla/Heal.tla`): what the healer reads before it acts, and
  what the app shows.

  **A symptom is a fact with its state.** A detector (today the healer,
  `CodingAgentFramework.Recoveries`) records each symptom state it reads with `record/3`: its
  `kind`, its `target` (an agent, a socket or an account), its `state` (the key its detector
  numbers it by, which the healer's claim in `Acts` takes too), `since`, `evidence` and its
  `source`. One state is one row: recording it again answers the same row. A state no longer
  read is `passed` (`pass/3`). Detect and record, always: a symptom is recorded before anything
  acts on it, and whatever happens next it stays shown.

  **The allow-list is data.** The config names, per kind, its one remedy (an act the healer
  knows, or nil for a symptom only shown) and its cap: the remedies of that kind the healer may
  take in one bound (`bound:`, ms). `remedies/3` answers the list now. It narrows alone and
  widens only by the operator (decision 11): the healer drops a kind's remedy whose verify
  failed (`{:drop, kind, reason}`), the operator revokes or approves one, and each act is a row,
  so a restart reads the list as it was left, never the config's again (`Heal.tla`'s
  `NarrowsAlone`, `Break_Heal_WidenOnRestart`).

  **A person's prompt for everything else.** The healer asks (`ask/4`) for a symptom state it
  does not act on: its kind off the list, the cap reached, or a remedy refused, unknown, cut by a
  restart, or failed its verify. The state's row then waits on a person, once per state: it is
  the `remedy` prompt `Prompts` reads, whose answer (`answer/5`) is `"approve"` (put the kind's
  remedy back on the list, the operator's widening) or `"leave"`. A state asked for its bound
  (`for_bound?/1`: the cap reached, or a main absent again within it) is answered `"act"` or
  `"leave"` instead (F-189's new-7): `"act"` is the person's own act, the remedy once, which the
  healer takes at its next check under a claim in `Acts` whose actor is the person, outside its
  own cap (`Heal.tla`'s `AnswerAct`). A kind with no remedy is never asked.

  **One clear** (F-182's new-2). The answer is also a person's clear of the state (`clear/3` is
  the answer `"leave"`): its `answered_at` is the time the healer reads as the state cleared, so
  a state that waits on a person (a viewer lost again and again, an end whose outcome is
  unknown) is acted on again from then. The healer reads a prompt that passed with its target
  the same way, since no answer can come to it.

  **Cues.** Each write calls `notify` with `%{topic: "watch", ids: ids}`, the symptoms' ids
  (none for an act on the list). The embedding app's tree starts one per instance.

      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> alias CodingAgentFramework.Watch
      iex> {:ok, w} = Watch.start_link(db: Path.join(dir, "w.db"),
      ...>   remedies: %{"lost_viewer" => %{remedy: "reopen", cap: 2}})
      iex> s = %{kind: "lost_viewer", target: "alpha", state: "k1", source: "healer", since: 5}
      iex> {:ok, %{id: id, status: "open"}} = Watch.record(w, s)
      iex> Watch.record(w, s)
      {:ok, %{id: id, status: "open"}}
      iex> Watch.ask(w, s, :cap_reached)
      {:ok, id}
      iex> Watch.answer(w, id, "leave", "sam")
      {:ok, :answered}
  """

  use GenServer

  alias CodingAgentFramework.Store
  alias CodingAgentFramework.Watch.{Limited, Table}

  @timeout 5_000
  @bound 3_600_000
  @filters ~w(kind target state source status)a

  @typedoc "A kind's entry on the list: its remedy (nil for none) and its cap per bound."
  @type entry :: %{remedy: String.t() | nil, cap: non_neg_integer}

  @doc """
  The default allow-list: the healer's two acts (F-182: today's `Recoveries`, a lost viewer
  reopened and an end owed) and an absent main resumed (F-183, `AbsentMains`), each capped at 10
  per bound; and two symptoms only shown, with no remedy: `hooks_silent` (F-184, `HooksSilent`)
  and `stuck_background` (F-184, `StuckBackgrounds`). The second's remedy, `"end"`, ends a quiet
  process group under the delegate, and no event names a background task's pid, so a quiet stdio
  MCP server spawned the same way would read as stuck. It stays off by default until a run on
  Linux records the group's shape; an operator turns it on with `remedies:`.

  The usage limit's three phases (F-186, `Limits`), one kind each, so each acts once per limit:
  `limit_menu` (the menu shown, the account unable to spend) by `press_stop`, and `limit_reset`
  (the reset passed, no own wait went on) by `go_on`, each 20 per bound, since one limit holds
  every agent of an account at once; and `limited`, each agent's limit with its window, shown
  only. And `limit_far` (F-191: a delegate's reset more than `move_after` away, another account
  with room) by `move`, 20 per bound, once per limit.
  """
  @spec default_remedies() :: %{String.t() => entry}
  def default_remedies do
    %{
      "lost_viewer" => %{remedy: "reopen", cap: 10},
      "end_owed" => %{remedy: "end", cap: 10},
      "absent_main" => %{remedy: "resume", cap: 10},
      "stuck_background" => %{remedy: nil, cap: 0},
      "hooks_silent" => %{remedy: nil, cap: 0},
      "limited" => %{remedy: nil, cap: 0},
      "limit_menu" => %{remedy: "press_stop", cap: 20},
      "limit_reset" => %{remedy: "go_on", cap: 20},
      "limit_far" => %{remedy: "move", cap: 20}
    }
  end

  @doc """
  Checks an allow-list's shape: kind (text) to `%{remedy: text | nil, cap: count}`.

      iex> CodingAgentFramework.Watch.check_remedies(%{"lost_viewer" => %{remedy: nil, cap: 0}})
      :ok
      iex> CodingAgentFramework.Watch.check_remedies(%{"lost_viewer" => %{remedy: :reopen}})
      {:refused, {:bad, :remedies, "lost_viewer"}}
  """
  @spec check_remedies(term) :: :ok | {:refused, term}
  def check_remedies(remedies) when is_map(remedies) do
    case Enum.find(remedies, &(not entry?(&1))) do
      nil -> :ok
      {kind, _} -> {:refused, {:bad, :remedies, kind}}
    end
  end

  def check_remedies(_), do: {:refused, {:bad, :remedies}}

  defp entry?({kind, %{remedy: r, cap: cap} = e}) when is_binary(kind) and map_size(e) == 2,
    do: (is_nil(r) or (is_binary(r) and r != "")) and is_integer(cap) and cap >= 0

  defp entry?(_), do: false

  @doc """
  Starts the record. Options: `db:` (its file), `remedies:` (the allow-list, `check_remedies/1`'s
  shape), and optionally `bound:` (ms, the cap's window, default an hour), `notify:`, `clock:`
  (ms) and `name:` (for the embedding app's tree). Fails to start with the list's refusal.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "The topics of the cues it writes (`CodingAgentFramework.Cues`): `watch`."
  @spec writes() :: [String.t()]
  def writes, do: ~w(watch)

  @doc """
  Records a symptom state, `%{kind, target, state, source, since}` and optionally `evidence`.
  Answers `{:ok, %{id, status}}`, the row's, new or recorded before, with its `answer` and
  `answered_by` once a person answered it (the healer reads an `"act"` there);
  `{:refused, {:unknown_kind, kind}}` for a kind the list does not name, or `{:refused, {:bad,
  :symptom}}`.
  """
  @spec record(GenServer.server(), map, keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def record(watch, symptom, opts \\ []) do
    if symptom?(symptom),
      do: call(watch, {:record, symptom}, opts),
      else: {:refused, {:bad, :symptom}}
  end

  defp symptom?(%{kind: k, target: t, state: s, source: src, since: since}),
    do: Enum.all?([k, t, s, src], &(is_binary(&1) and &1 != "")) and is_integer(since)

  defp symptom?(_), do: false

  @doc """
  Opens the remedy prompt of symptom state `key` (`%{kind, target, state}`), once: the row
  becomes `asked`, with the remedy the list names and `reason`. Answers `{:ok, id}`; `{:refused,
  {:status, status}}` for a state not `open` (asked once already, answered or passed);
  `{:refused, {:no_remedy, kind}}` for a kind only shown; `{:refused, :no_symptom}`.
  """
  @spec ask(GenServer.server(), map, term, keyword) ::
          {:ok, integer} | {:refused, term} | {:unknown, term}
  def ask(watch, key, reason, opts \\ []), do: call(watch, {:ask, key, reason}, opts)

  @doc """
  What `source` reads of `kind` now, `%{targets: targets, states: states}`: an `open` symptom
  state of it not in `states` passes; an `asked` one passes only when its target is not in
  `targets`, since a person's prompt stays while its target shows the kind at all (a remedy
  that failed leaves its target in a new state, still a symptom). One `answered` `"act"` passes
  by the `open` row's rule (F-203): the healer takes the act only on the state it still reads,
  so a state gone before its next check is never acted on, and its prompt leaves the inbox.
  Answers `{:ok, ids}`.
  """
  @spec pass(GenServer.server(), {String.t(), String.t()}, map, keyword) ::
          {:ok, [integer]} | {:refused, term} | {:unknown, term}
  def pass(watch, {source, kind}, %{targets: targets, states: states}, opts \\ []),
    do: call(watch, {:pass, source, kind, MapSet.new(targets), MapSet.new(states)}, opts)

  @doc """
  The symptoms within `filter` (`kind:`, `target:`, `state:`, `source:`, `status:`, each a
  value or a list of them), oldest first. Answers `{:ok, rows}` or `{:refused, {:bad, :filter}}`.
  """
  @spec read(GenServer.server(), keyword, keyword) ::
          {:ok, [map]} | {:refused, term} | {:unknown, term}
  def read(watch, filter \\ [], opts \\ []) do
    if Keyword.keyword?(filter) and Keyword.keys(filter) -- @filters == [],
      do: call(watch, {:read, filter}, opts),
      else: {:refused, {:bad, :filter}}
  end

  @doc """
  The digest of `limited` by account (F-193, `Watch.Limited.digest/2`): one reading per account
  limited now, its window and reset, and its agents, each with how long it has waited by this
  `Watch`'s clock. Answers `{:ok, readings}`.

      Watch.limited(watch)
      #=> {:ok, [%{account: "work", window: "five_hour", until: 1_800_000_000,
      #=>   agents: [%{agent: "app-unit", until: 1_800_000_000, since: …, waited: 540_000}]}]}
  """
  @spec limited(GenServer.server(), keyword) ::
          {:ok, [Limited.reading()]} | {:refused, term} | {:unknown, term}
  def limited(watch, opts \\ []), do: call(watch, :limited, opts)

  @doc """
  The allow-list (`model/tla/Heal.tla`'s `allow`):

  - `:list`: `{:ok, %{kind => %{remedy, cap, bound, allowed, last}}}`, `last` the latest act on
    the kind's entry (nil for none);
  - `{:drop, kind, reason}`: the healer's narrowing after a verify failed;
  - `{:revoke, kind, by}`: the operator's narrowing;
  - `{:approve, kind, by}`: the operator's widening, the only one; refused `{:no_remedy, kind}`
    for a kind with no remedy.

  Each act answers `{:ok, allowed}`, the entry's state after it, or `{:refused, {:unknown_kind,
  kind}}`.
  """
  @spec remedies(GenServer.server(), term, keyword) ::
          {:ok, term} | {:refused, term} | {:unknown, term}
  def remedies(watch, request, opts \\ []), do: call(watch, {:remedies, request}, opts)

  @doc """
  Whether a symptom row was asked for its bound: its reason is the cap reached (`{:cap, cap,
  bound}`) or a second absence within it (`{:again_within, bound}`), as the healers ask. Such a
  prompt offers `"act"` and `"leave"`; any other, `"approve"` and `"leave"`.

      iex> CodingAgentFramework.Watch.for_bound?(%{reason: ~s(["cap",10,3600000])})
      true
      iex> CodingAgentFramework.Watch.for_bound?(%{reason: "not_on_list"})
      false
  """
  @spec for_bound?(map) :: boolean
  def for_bound?(%{reason: reason}) when is_binary(reason),
    do: String.starts_with?(reason, [~s(["cap",), ~s(["again_within",)])

  def for_bound?(_), do: false

  @doc """
  Who takes a symptom state's remedy now, from `record/3`'s answer: the healer (`actor`) for an
  open state, the person who answered `"act"` for a state asked for its bound, or nil for any
  other (asked, left, approved, passed, or unread). The healer claims in `Acts` as that actor
  and counts only its own claims against its cap; `Acts`' one claim per state keeps a person's
  answer to one act (`Heal.tla`'s `AnswerAct`).

      iex> CodingAgentFramework.Watch.acting({:ok, %{id: 1, status: "open"}}, "healer:ws")
      "healer:ws"
      iex> CodingAgentFramework.Watch.acting(
      ...>   {:ok, %{id: 1, status: "answered", answer: "act", answered_by: "sam"}}, "healer:ws")
      "sam"
      iex> CodingAgentFramework.Watch.acting({:ok, %{id: 1, status: "asked"}}, "healer:ws")
      nil
  """
  @spec acting(term, String.t()) :: String.t() | nil
  def acting({:ok, %{status: "open"}}, actor), do: actor
  def acting({:ok, %{status: "answered", answer: "act", answered_by: by}}, _actor), do: by
  def acting(_recorded, _actor), do: nil

  @doc """
  The choices symptom row `sym`'s remedy prompt offers: `["act", "leave"]` when it was asked
  for its bound (`for_bound?/1`), else `["approve", "leave"]`.
  """
  @spec choices(map) :: [String.t()]
  def choices(sym), do: if(for_bound?(sym), do: ~w(act leave), else: ~w(approve leave))

  @doc """
  Answers symptom `id`'s remedy prompt with `choice`, as `by`, once: `"approve"` puts its
  kind's remedy back on the list (`remedies/3`'s `approve`), `"act"` is the person's act once
  (for a state asked for its bound: its healer takes it, under `by`'s claim), and `"leave"`
  leaves it as it is. Answers `{:ok, :answered}`; `{:refused, :settled}` for a symptom whose
  prompt is not open; `{:refused, :no_symptom}`; `{:refused, {:bad, :choice}}`, a choice the
  prompt does not offer (`choices/1`) among them.
  """
  @spec answer(GenServer.server(), integer, String.t(), String.t(), keyword) ::
          {:ok, :answered} | {:refused, term} | {:unknown, term}
  def answer(watch, id, choice, by, opts \\ []) do
    if choice in ["approve", "act", "leave"] and is_binary(by),
      do: call(watch, {:answer, id, choice, by}, opts),
      else: {:refused, {:bad, :choice}}
  end

  @doc """
  A person's clear of symptom `id`, a state that waits on one, as `by`: its remedy prompt
  answered `"leave"` (`answer/5`), so the healer acts on the target again from now. Answers as
  `answer/5` does.

      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> alias CodingAgentFramework.Watch
      iex> {:ok, w} = Watch.start_link(db: Path.join(dir, "c.db"),
      ...>   remedies: %{"end_owed" => %{remedy: "end", cap: 1}})
      iex> s = %{kind: "end_owed", target: "alpha", state: "e1", source: "healer", since: 5}
      iex> {:ok, %{id: id}} = Watch.record(w, s)
      iex> {:ok, ^id} = Watch.ask(w, s, :unknown)
      iex> Watch.clear(w, id, "sam")
      {:ok, :answered}
      iex> {:ok, [%{answer: "leave", answered_by: "sam"}]} = Watch.read(w, state: "e1")
      iex> Watch.clear(w, id, "sam")
      {:refused, :settled}
  """
  @spec clear(GenServer.server(), integer, String.t(), keyword) ::
          {:ok, :answered} | {:refused, term} | {:unknown, term}
  def clear(watch, id, by, opts \\ []), do: answer(watch, id, "leave", by, opts)

  defp call(watch, request, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    GenServer.call(watch, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_watch}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @timeout)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    remedies = Keyword.fetch!(opts, :remedies)

    with :ok <- check_remedies(remedies),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      {:ok,
       %{
         db: db,
         remedies: remedies,
         bound: Keyword.get(opts, :bound, @bound),
         clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
         notify: Keyword.get(opts, :notify, fn _ -> :ok end)
       }}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:record, sym}, _from, s) do
    reply =
      if Map.has_key?(s.remedies, sym.kind) do
        fields = [
          kind: sym.kind,
          target: sym.target,
          state: sym.state,
          source: sym.source,
          since: sym.since,
          evidence: Store.text(Map.get(sym, :evidence)),
          status: "open",
          recorded_at: now(s)
        ]

        case Store.insert(s.db, "symptoms", fields, "ON CONFLICT DO NOTHING RETURNING id") do
          [[id]] ->
            cue(s, [id])
            {:ok, %{id: id, status: "open"}}

          [] ->
            row = find(s, sym)

            {:ok,
             Map.take(
               row,
               if(row.answer, do: [:id, :status, :answer, :answered_by], else: [:id, :status])
             )}
        end
      else
        {:refused, {:unknown_kind, sym.kind}}
      end

    {:reply, reply, s}
  end

  def handle_call({:ask, key, reason}, _from, s) do
    reply =
      case {find(s, key), s.remedies[key[:kind]]} do
        {nil, _} ->
          {:refused, :no_symptom}

        {_, %{remedy: nil}} ->
          {:refused, {:no_remedy, key.kind}}

        {%{id: id, status: "open"}, %{remedy: remedy}} ->
          write(s, id, status: "asked", remedy: remedy, reason: reason, asked_at: now(s))
          {:ok, id}

        {%{status: status}, _} ->
          {:refused, {:status, status}}
      end

    {:reply, reply, s}
  end

  def handle_call({:pass, source, kind, targets, states}, _from, s) do
    where =
      "source = ?1 AND kind = ?2 AND " <>
        "(status IN ('open', 'asked') OR (status = 'answered' AND answer = 'act'))"

    ids =
      for %{id: id, state: state, target: target, status: status} <-
            Table.select(s.db, where, [source, kind]),
          # An answered act is the healer's to take only while its state is read (F-203).
          if(status == "asked",
            do: not MapSet.member?(targets, target),
            else: not MapSet.member?(states, state)
          ) do
        Store.update(s.db, "symptoms", id, status: "passed", passed_at: now(s))
        id
      end

    if ids != [], do: cue(s, ids)
    {:reply, {:ok, ids}, s}
  end

  def handle_call({:read, filter}, _from, s) do
    {where, args} =
      Enum.reduce(filter, {["1 = 1"], []}, fn {k, v}, {clauses, args} ->
        values = List.wrap(v)

        {clauses ++ ["#{k} IN (#{Store.marks(length(values), length(args) + 1)})"],
         args ++ values}
      end)

    {:reply, {:ok, Table.select(s.db, Enum.join(where, " AND "), args)}, s}
  end

  def handle_call(:limited, _from, s) do
    rows = Table.select(s.db, "kind = 'limited' AND status = 'open'", [])
    {:reply, {:ok, Limited.digest(rows, now(s))}, s}
  end

  def handle_call({:remedies, :list}, _from, s), do: {:reply, {:ok, list(s)}, s}

  def handle_call({:remedies, {act, kind, why}}, _from, s)
      when act in [:drop, :revoke, :approve] do
    {:reply, act_on_list(s, act, kind, why), s}
  end

  def handle_call({:remedies, _}, _from, s), do: {:reply, {:refused, {:bad, :request}}, s}

  def handle_call({:answer, id, choice, by}, _from, s) do
    reply =
      case Table.select(s.db, "id = ?1", [id]) do
        [] ->
          {:refused, :no_symptom}

        [%{status: "asked"} = sym] ->
          # The act is a person's, under a name of its own: never the healer's.
          with true <- choice in choices(sym) or {:refused, {:bad, :choice}},
               true <- choice != "act" or by not in ["", "healer"] or {:refused, {:bad, :by}},
               {:ok, _} <-
                 if(choice == "approve",
                   do: act_on_list(s, :approve, sym.kind, by),
                   else: {:ok, nil}
                 ) do
            write(s, id, status: "answered", answer: choice, answered_by: by, answered_at: now(s))
            {:ok, :answered}
          end

        [_] ->
          {:refused, :settled}
      end

    {:reply, reply, s}
  end

  defp act_on_list(s, act, kind, why) do
    case s.remedies[kind] do
      nil ->
        {:refused, {:unknown_kind, kind}}

      %{remedy: nil} when act == :approve ->
        {:refused, {:no_remedy, kind}}

      # The healer only narrows, and the operator acts under a name of its own.
      _entry when act != :drop and (not is_binary(why) or why in ["", "healer"]) ->
        {:refused, {:bad, :by}}

      _entry ->
        {by, reason} = if act == :drop, do: {"healer", Store.text(why)}, else: {why, nil}

        Store.insert(s.db, "remedy_acts",
          kind: kind,
          act: Atom.to_string(act),
          by: by,
          reason: reason,
          at: now(s)
        )

        s.notify.(%{topic: "watch", ids: []})
        {:ok, list(s)[kind].allowed}
    end
  end

  defp list(s) do
    acts = Enum.group_by(Table.acts(s.db), & &1.kind)

    Map.new(s.remedies, fn {kind, entry} ->
      mine = Map.get(acts, kind, [])

      {kind,
       Map.merge(entry, %{
         bound: s.bound,
         allowed: Table.allowed(entry, mine),
         last: List.last(mine)
       })}
    end)
  end

  defp find(s, key) do
    with %{kind: k, target: t, state: st} when is_binary(k) and is_binary(t) <- key do
      s.db
      |> Table.select("kind = ?1 AND target = ?2 AND state = ?3", [k, t, Store.text(st)])
      |> List.first()
    else
      _ -> nil
    end
  end

  defp write(s, id, fields) do
    Store.update(s.db, "symptoms", id, fields)
    cue(s, [id])
  end

  defp cue(s, ids), do: s.notify.(%{topic: "watch", ids: ids})

  defp now(s), do: s.clock.()
end
