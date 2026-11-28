defmodule CodingAgentFramework.Tracker.Fold do
  @moduledoc """
  The state views read, as a pure and total fold of every source's rows.

  A fold holds, per source topic, its scope (`{host, account}`), its kind, whether it is
  `:unread` or read and when, and its rows by id. `read/4` takes what a source answered for a
  cue; `view/2` builds what views show. Nothing here raises on a row's shape: a row that is not
  a map, a nil timestamp, a column of the wrong type or a missing one all fold, and the problem
  is named on that row's entry alone.

      iex> alias CodingAgentFramework.Tracker.Fold
      iex> fold = Fold.new() |> Fold.source("registry:h:a", {"h", "a"}, :sessions)
      iex> Fold.view(fold, 0)[{"h", "a"}].age
      :unread
      iex> {fold, _} = Fold.read(fold, "registry:h:a", :all,
      ...>   {:ok, %{read_at: 10, rows: [%{id: 1, session_id: "s", pid: 7, alive: :live}, :junk]}})
      iex> %{sessions: [one, bad], age: 5} = Fold.view(fold, 15)[{"h", "a"}]
      iex> {one.pid, one.alive, bad.problems}
      {7, :live, [:not_a_map]}
  """

  defstruct sources: %{}, rows: %{}

  @type topic :: String.t()
  @type scope :: {String.t(), String.t()}
  @type outcome :: :unread | {:ok, %{read_at: term, rows: [term]}} | {:unknown, term}
  @type t :: %__MODULE__{}

  @alive [:live, :replaced, :gone, :unknown]
  # The columns a session entry shows, each with the check its value must pass. `proc_start`
  # with `pid` names the process, as `Sessions.Turn.file/2` matches an agent row's (F-153).
  # `status_updated_at` is when the status was written: the tree reads a background command's
  # end from it (F-259).
  @fields [pid: &is_integer/1, updated_at: &is_integer/1, status_updated_at: &is_integer/1] ++
            Enum.map([:session_id, :name, :status, :cwd, :file, :proc_start], fn k ->
              {k, &is_binary/1}
            end)

  @doc "An empty fold."
  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc "Adds a source, `:unread` until it answers a read."
  @spec source(t, topic, scope, atom) :: t
  def source(fold, topic, scope, kind) do
    entry = %{scope: scope, kind: kind, status: :unread, read_at: nil, problem: nil}

    %{
      fold
      | sources: Map.put_new(fold.sources, topic, entry),
        rows: Map.put_new(fold.rows, topic, %{})
    }
  end

  @doc "Whether a source has not been read yet; an unknown topic is `:unknown`."
  @spec status(t, topic) :: :unread | :read | :unknown
  def status(fold, topic), do: get_in(fold.sources, [topic, :status]) || :unknown

  @doc """
  Folds a source's answer to a read of `ids` (or `:all`). An id read and absent is deleted; with
  `:all` the rows replace the topic's. `:unread` and `{:unknown, reason}` keep the rows. Returns
  the fold and the `{topic, id}` keys whose rows changed, with `{topic, :source}` when the
  source's status or problem changed. A topic the fold does not know changes nothing.
  """
  @spec read(t, topic, :all | [term], outcome) :: {t, [{topic, term}]}
  def read(fold, topic, ids, outcome) do
    case fold.sources do
      %{^topic => source} -> read(fold, topic, source, ids, outcome)
      _ -> {fold, []}
    end
  end

  defp read(fold, topic, source, ids, outcome) do
    {new_source, rows} =
      case outcome do
        {:ok, %{rows: rows} = ok} when is_list(rows) ->
          {%{source | status: :read, read_at: int(ok[:read_at]), problem: nil}, rows}

        :unread ->
          {%{source | status: :unread}, nil}

        other ->
          {%{source | problem: problem(other)}, nil}
      end

    old = fold.rows[topic]
    new = if rows, do: merge(old, ids, rows), else: old

    changed =
      for id <- touched(old, new, ids, rows), old[id] != new[id], do: {topic, id}

    changed =
      if Map.take(source, [:status, :problem]) == Map.take(new_source, [:status, :problem]),
        do: changed,
        else: [{topic, :source} | changed]

    {%{
       fold
       | sources: Map.put(fold.sources, topic, new_source),
         rows: Map.put(fold.rows, topic, new)
     }, changed}
  end

  # The keys a read may have changed. A read of some ids drops only those and puts only the rows
  # it answered, so no other key can change: a cue of one row of a large source compares one
  # row, not all of them (F-299). A read of `:all` replaces the topic's rows.
  defp touched(_old, _new, _ids, nil), do: []

  defp touched(_old, _new, ids, rows) when is_list(ids),
    do: Enum.uniq(ids ++ Enum.map(rows, &key/1))

  defp touched(old, new, _all, _rows), do: Enum.uniq(Map.keys(old) ++ Map.keys(new))

  defp problem({:unknown, reason}), do: reason
  defp problem(other), do: {:unexpected, other}

  defp merge(_old, :all, rows), do: Map.new(rows, &{key(&1), &1})

  defp merge(old, ids, rows) do
    old = if is_list(ids), do: Map.drop(old, ids), else: old
    Enum.reduce(rows, old, &Map.put(&2, key(&1), &1))
  end

  # A row with no id is still kept, under a key of its own, so it shows with its problem.
  defp key(%{id: id}) when not is_nil(id), do: id
  defp key(row), do: {:no_id, :erlang.phash2(row)}

  @doc """
  The state per scope at time `now` (ms): its sessions, its sources with their status and age,
  and `age`, the age of its newest read, or `:unread` when no source of it has been read.
  With `kinds`, a list of row kinds, only those kinds' rows are built, each as the whole view
  has it; `sources` and `age` are every source's still (F-299).

      iex> alias CodingAgentFramework.Tracker.Fold
      iex> fold = Fold.new() |> Fold.source("t:h", {"h", "a"}, :leases)
      iex> {fold, _} = Fold.read(fold, "t:h", :all, {:ok, %{read_at: 1, rows: [%{id: 1}]}})
      iex> Fold.view(fold, 1)[{"h", "a"}] |> Map.take([:leases, :sessions])
      %{leases: [%{key: {"t:h", 1}, row: %{id: 1}}], sessions: []}
      iex> Fold.view(fold, 1, [:agents])[{"h", "a"}] |> Map.keys() |> Enum.sort()
      [:age, :sources]
  """
  @spec view(t, integer, :all | [atom]) :: %{scope => map}
  def view(fold, now, kinds \\ :all) do
    Enum.reduce(fold.sources, %{}, fn {topic, source}, acc ->
      shown = %{
        status: source.status,
        read_at: source.read_at,
        age: age(source, now),
        problem: source.problem
      }

      # A kind not asked for is not built: its rows stay in the fold (F-299).
      rows =
        if kinds == :all or source.kind in kinds,
          do: [{source.kind, entries(fold, topic, source.kind)}],
          else: []

      Map.update(acc, source.scope, part(kinds, rows, topic, shown), fn part ->
        rows
        |> Enum.reduce(part, fn {kind, e}, part -> Map.update(part, kind, e, &(&1 ++ e)) end)
        |> Map.update!(:sources, &Map.put(&1, topic, shown))
        |> Map.update!(:age, &newest(&1, shown.age))
      end)
    end)
    |> Map.new(fn {scope, part} -> {scope, sorted(part)} end)
  end

  defp entries(fold, topic, kind),
    do: Enum.map(fold.rows[topic], fn {id, row} -> entry(kind, {topic, id}, row) end)

  defp sorted(%{sessions: s} = part), do: %{part | sessions: sort(s)}
  defp sorted(part), do: part

  @doc "The sources that are `:unread`, or whose newest read is older than `bound` ms at `now`."
  @spec behind(t, integer, non_neg_integer) :: [{topic, non_neg_integer | :unread}]
  def behind(fold, now, bound) do
    fold.sources
    |> Enum.sort()
    |> Enum.map(fn {topic, source} -> {topic, age(source, now)} end)
    |> Enum.filter(fn {_, age} -> age == :unread or age > bound end)
  end

  # A scope's part always has its sessions, empty when none, unless the caller asked for kinds
  # without them.
  defp part(kinds, rows, topic, shown) do
    base = if kinds == :all or :sessions in kinds, do: %{sessions: []}, else: %{}
    Map.merge(base, Map.new(rows) |> Map.merge(%{sources: %{topic => shown}, age: shown.age}))
  end

  defp age(%{status: :unread}, _now), do: :unread
  defp age(%{read_at: at}, now) when is_integer(at), do: max(now - at, 0)
  defp age(_, _), do: :unread

  defp newest(:unread, b), do: b
  defp newest(a, :unread), do: a
  defp newest(a, b), do: min(a, b)

  # Newest first; a session with no time goes last, and the key breaks ties.
  defp sort(entries) when is_list(entries),
    do:
      Enum.sort_by(
        entries,
        &{if(is_integer(&1[:updated_at]), do: -&1.updated_at, else: :none), &1[:key]}
      )

  defp entry(:sessions, key, row) when is_map(row) do
    fields = Map.new(@fields, fn {k, ok?} -> {k, if(ok?.(Map.get(row, k)), do: row[k])} end)

    wrong =
      for {k, ok?} <- @fields, not is_nil(Map.get(row, k)), not ok?.(row[k]), do: {:wrong_type, k}

    alive = Map.get(row, :alive)
    own = Map.get(row, :problem)

    Map.merge(fields, %{
      key: key,
      alive: if(alive in @alive, do: alive, else: :unknown),
      problems: if(own, do: [own], else: []) ++ wrong
    })
  end

  defp entry(:sessions, key, _row) do
    fields = Map.new(@fields, fn {k, _} -> {k, nil} end)
    Map.merge(fields, %{key: key, alive: :unknown, problems: [:not_a_map]})
  end

  defp entry(_kind, key, row), do: %{key: key, row: row}

  defp int(v) when is_integer(v), do: v
  defp int(_), do: nil
end
