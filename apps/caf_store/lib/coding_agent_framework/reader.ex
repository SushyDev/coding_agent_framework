defmodule CodingAgentFramework.Reader do
  @moduledoc """
  The loop every reader runs, and its table, over `CodingAgentFramework.Store`: read on an
  interval or a call, diff what it read against what it wrote, write the changes with a reads
  row in one transaction, and send a cue. And a `Tracker` source made from the same table
  metadata, so no reader writes a source of its own.

  A pure module: it starts no process and owns no table. Each reader (`Registry`, `Usage`,
  `Transcripts`, `TmuxSampler`) is its own process and the one writer of its own table; its
  table module gives `meta/0`, a map that names the table:

    * `:schema`: the SQL that creates both tables.
    * optional `:open`: `Store.open/3`'s options, such as the columns a later build added.
    * optional `:convert`: `[{table, columns}]` whose values an earlier build stored as
      `inspect` text, converted to `Store.text/1`'s rule at each open (`Store.convert/3`). A
      reader stores a problem by `Store.text/1` (F-130's new-2).
    * `:table` and `:reads`: the rows' table and the reads table, one row per scope read.
    * `:scope`: the columns that key a reads row, and that every row carries before its key,
      such as `[:host, :account]`.
    * `:key`: the row's own key within its scope, such as `:file`.
    * `:data`: the columns a row's data is compared and written by.
    * `:read`: the reads row's columns besides the scope; `read_at` is one of them.
    * `:topic`, `:kind` and `:name`: a source's topic is `<topic>:<host>:<name option>`, its
      scope `{host, <group><name option>}`, and its rows of kind `kind`. With `name: nil` the
      table is read per host: topic `<topic>:<host>`, scope `{host, <group>}`.
    * optional `:group` (default `""`), `:filter` (more columns a source narrows rows by),
      `:load` (a row map as stored to the row as read), `:load_read` (the same for a reads
      row), `:dump` (a column and a value to what is stored), `:view` (rows and a source's
      options to the rows it answers) and `:failed` (the word of a read whose reads row has a
      newer `failed_at`).
    * a writer's table (F-120's new-2) gives `reads: nil`, `columns:` (its own, in order) and
      `scope: []`: it has no reads table, so its source reads it now, and `read_at` is the
      time of that read.

  A scope with no reads row, or one whose `read_at` is nil, is `:unread`, never an empty list.

      iex> meta = %{schema: "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, host TEXT,
      ...>   k TEXT, v TEXT, written_at INTEGER, UNIQUE (host, k));
      ...>   CREATE TABLE IF NOT EXISTS t_reads (host TEXT PRIMARY KEY, read_at INTEGER);",
      ...>   table: "t", reads: "t_reads", scope: [:host], key: :k, data: [:v], read: [:read_at],
      ...>   topic: "t", kind: :things, name: :host}
      iex> alias CodingAgentFramework.Reader
      iex> {:ok, db} = Reader.open(meta, Path.join(CodingAgentFramework.TestHost.test_dir(), "t.db"))
      iex> Reader.rows(meta, db, host: "h")
      :unread
      iex> changes = Reader.diff(%{}, %{"a" => %{v: "1"}})
      iex> [%{ids: [id], first: true}] = Reader.write(meta, db, [{[host: "h"], changes, [read_at: 5]}])
      iex> Reader.rows(meta, db, host: "h")
      {:ok, %{read_at: 5, rows: [%{id: id, host: "h", k: "a", v: "1", written_at: 5}]}}
  """

  alias CodingAgentFramework.Store

  @type meta :: map
  @type scope :: [{atom, term}]
  @type change :: {:put, term, map} | {:delete, term}

  # The loop.

  @doc """
  Calls a reader's process: a process that is not there is `{:refused, absent}`, and a timeout
  or an exit is `{:unknown, reason}`.
  """
  @spec call(GenServer.server(), term, timeout, term) :: term
  def call(server, request, timeout, absent) do
    GenServer.call(server, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, absent}
    :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @doc """
  The common options of a reader's start: its `notify` (by default one that does nothing) and
  its `interval` (nil: it reads only when called). With an interval, the first read is now.
  """
  @spec loop(keyword) :: %{notify: (map -> term), interval: pos_integer | nil}
  def loop(opts) do
    interval = Keyword.get(opts, :interval)
    if interval, do: send(self(), :tick)
    %{notify: Keyword.get(opts, :notify, fn _ -> :ok end), interval: interval}
  end

  @doc "A tick: reads with `read`, a function of the state, and asks for the next tick."
  @spec tick(state, (state -> {term, state})) :: state when state: %{interval: pos_integer}
  def tick(state, read) do
    {_, state} = read.(state)
    Process.send_after(self(), :tick, state.interval)
    state
  end

  @doc """
  What changed from `cache` (what was written last) to `rows` (what was read now), both maps
  of a key to a row's data: a put for each new or changed row, a delete for each gone one.

      iex> CodingAgentFramework.Reader.diff(%{"a" => 1, "b" => 2}, %{"a" => 1, "b" => 3, "c" => 4})
      [{:put, "b", 3}, {:put, "c", 4}]
      iex> CodingAgentFramework.Reader.diff(%{"a" => 1}, %{})
      [{:delete, "a"}]
  """
  @spec diff(map, map) :: [change]
  def diff(cache, rows) do
    for({key, row} <- rows, cache[key] != row, do: {:put, key, row}) ++
      for key <- Map.keys(cache), not Map.has_key?(rows, key), do: {:delete, key}
  end

  @doc """
  Sends `%{topic: topic, ids: ids}` to `notify` after a write that changed rows, a scope's first
  read, or when `also` holds. The cue names the rows, never their data.
  """
  @spec cue((map -> term), String.t(), %{ids: list, first: boolean}, boolean) :: :ok
  def cue(notify, topic, %{ids: ids, first: first}, also \\ false) do
    if ids != [] or first or also, do: notify.(%{topic: topic, ids: ids})
    :ok
  end

  # The table.

  @doc """
  Opens (and creates) the reader's file at `path`, with its tables, and converts the columns
  `meta.convert` names.
  """
  @spec open(meta, String.t()) :: {:ok, Store.db()} | {:refused, term}
  def open(meta, path) do
    with {:ok, db} <- Store.open(path, meta.schema, Map.get(meta, :open, [])) do
      for {table, columns} <- Map.get(meta, :convert, []), do: Store.convert(db, table, columns)
      {:ok, db}
    end
  end

  @doc "A row's columns, in the table's order."
  @spec columns(meta) :: [atom]
  def columns(%{columns: columns}), do: columns
  def columns(meta), do: [:id | meta.scope] ++ [meta.key | meta.data] ++ [:written_at]

  @doc "A scope's reads row as stored, or nil before any."
  @spec read_row(meta, Store.db(), scope) :: map | nil
  def read_row(meta, db, scope) do
    case Store.select(db, meta.reads, meta.read, where(scope), Keyword.values(scope)) do
      [] -> nil
      [row] -> Map.get(meta, :load_read, & &1).(row)
    end
  end

  @doc "A scope's reads row, `:unread` before its first read."
  @spec last_read(meta, Store.db(), scope) :: :unread | {:ok, map}
  def last_read(meta, db, scope) do
    case read_row(meta, db, scope) do
      %{read_at: at} = read when is_integer(at) -> {:ok, read}
      _ -> :unread
    end
  end

  @doc "A scope's rows, oldest first, with its reads row; `:unread` before its first read."
  @spec rows(meta, Store.db(), scope) :: :unread | {:ok, map}
  def rows(meta, db, scope) do
    with {:ok, read} <- last_read(meta, db, scope),
         do: {:ok, Map.put(read, :rows, select(meta, db, scope))}
  end

  @doc "The rows where the columns in `filter` are equal, oldest first."
  @spec select(meta, Store.db(), scope) :: [map]
  def select(meta, db, filter) do
    db
    |> Store.select(meta.table, columns(meta), where(filter) <> " ORDER BY id", values(filter))
    |> Enum.map(&load(meta, &1))
  end

  @doc "The rows with these ids within `filter`; an id with no row there is absent."
  @spec rows_by_id(meta, Store.db(), [integer], scope) :: [map]
  def rows_by_id(meta, db, ids, filter \\ []) do
    db
    |> Store.rows_by_id(meta.table, columns(meta), ids, filter)
    |> Enum.map(&load(meta, &1))
  end

  @doc """
  Writes, in one transaction, each `{scope, changes, read}`: its changes, then its reads row
  (`scope ++ read`, in place of the last one). Answers per scope, in order, the ids put or
  deleted, the same as `{key, id}` in `keyed`, and whether it was the scope's first read.
  """
  @spec write(meta, Store.db(), [{scope, [change], keyword}]) :: [map]
  def write(meta, db, writes) do
    Store.transaction(db, fn ->
      for {scope, changes, read} <- writes do
        first = last_read(meta, db, scope) == :unread
        keyed = Enum.flat_map(changes, &change(meta, db, scope, read[:read_at], &1))
        :ok = Store.upsert(db, meta.reads, scope ++ read)
        %{scope: scope, ids: Enum.map(keyed, &elem(&1, 1)), keyed: keyed, first: first}
      end
    end)
  end

  defp change(meta, db, scope, at, {:put, key, row}) do
    dump = Map.get(meta, :dump, fn _, value -> value end)
    data = for column <- meta.data, do: {column, dump.(column, row[column])}
    conflict = Enum.join(meta.scope ++ [meta.key], ",")
    set = Enum.map_join(meta.data ++ [:written_at], ",", &"#{&1} = excluded.#{&1}")
    fields = scope ++ [{meta.key, key} | data] ++ [written_at: at]

    db
    |> Store.insert(
      meta.table,
      fields,
      "ON CONFLICT (#{conflict}) DO UPDATE SET #{set} RETURNING id"
    )
    |> Enum.map(fn [id] -> {key, id} end)
  end

  defp change(meta, db, scope, _at, {:delete, key}) do
    filter = scope ++ [{meta.key, key}]

    db
    |> Store.query(
      "DELETE FROM #{meta.table} WHERE #{where(filter)} RETURNING id",
      values(filter)
    )
    |> Enum.map(fn [id] -> {key, id} end)
  end

  defp load(meta, row), do: Map.get(meta, :load, & &1).(row)

  defp where([]), do: "1 = 1"

  defp where(filter),
    do:
      filter |> Enum.with_index(1) |> Enum.map_join(" AND ", fn {{k, _}, i} -> "#{k} = ?#{i}" end)

  defp values(filter), do: Keyword.values(filter)

  # The source.

  @doc """
  A `Tracker` source's description from its options (`host:` and the option `meta.name`
  names): the topic its reader cues on, the scope of its rows, and their kind.
  """
  @spec describe(meta, keyword) :: %{topic: String.t(), scope: {term, String.t()}, kind: atom}
  def describe(%{name: nil} = meta, opts) do
    host = Keyword.fetch!(opts, :host)
    %{topic: "#{meta.topic}:#{host}", scope: {host, meta.group}, kind: meta.kind}
  end

  def describe(meta, opts) do
    {host, name} = {Keyword.fetch!(opts, :host), Keyword.fetch!(opts, meta.name)}
    group = Map.get(meta, :group, "")
    %{topic: "#{meta.topic}:#{host}:#{name}", scope: {host, group <> name}, kind: meta.kind}
  end

  @doc """
  A `Tracker` source's read: the rows with these ids, or every row with `:all`, within the
  source's scope, and when its reader last read; `:unread` before that. A reads row with a
  `failed_at` answers `{:unknown, {failed, at, problem}}`, so the fold keeps the last good rows.
  An id is global to the table, so a row of another scope is absent from the answer.
  """
  @spec source_read(meta, Store.db(), keyword, :all | [integer]) ::
          :unread | {:ok, map} | {:unknown, term}
  def source_read(%{reads: nil} = meta, db, opts, ids) do
    filter = for k <- Map.get(meta, :filter, []), do: {k, Keyword.fetch!(opts, k)}
    rows = if ids == :all, do: select(meta, db, filter), else: rows_by_id(meta, db, ids, filter)
    view = Map.get(meta, :view, fn rows, _ -> rows end)
    {:ok, %{read_at: System.os_time(:millisecond), rows: view.(rows, opts)}}
  end

  def source_read(meta, db, opts, ids) do
    scope = for k <- meta.scope, do: {k, Keyword.fetch!(opts, k)}
    filter = scope ++ for k <- Map.get(meta, :filter, []), do: {k, Keyword.fetch!(opts, k)}

    case read_row(meta, db, scope) do
      %{failed_at: at, problem: problem} when is_integer(at) ->
        {:unknown, {Map.get(meta, :failed, :read_failed), at, problem}}

      %{read_at: at} when is_integer(at) ->
        rows =
          if ids == :all, do: select(meta, db, filter), else: rows_by_id(meta, db, ids, filter)

        {:ok, %{read_at: at, rows: Map.get(meta, :view, fn rows, _ -> rows end).(rows, opts)}}

      _ ->
        :unread
    end
  end
end
