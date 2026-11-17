defmodule CodingAgentFramework.Store do
  @moduledoc """
  The table code every writer shares, over SQLite: open a file with WAL and a busy timeout,
  create its schema, add the columns a later version added, run a statement, read rows as maps,
  write rows, and load a stored map with the fields a newer build added.

  A pure module: it starts no process and owns no table. Each part keeps its own table, its own
  schema and its own functions, and is the one writer of that table (`docs/design.md`, "The
  parts"). The SQL a part passes names its own table and columns; values are always bound.

  A statement's error is a bug or a broken file, so `query/3` and the functions on it raise,
  and the writer's supervisor restarts the writer, which reads its rows again from the file.
  Only `open/3` answers `{:refused, reason}`.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> alias CodingAgentFramework.Store
      iex> {:ok, db} = Store.open(path, "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, a TEXT);")
      iex> [[id]] = Store.insert(db, "t", [a: "x"], "RETURNING id")
      iex> Store.update(db, "t", id, a: "y")
      :ok
      iex> Store.rows_by_id(db, "t", [:id, :a], [id])
      [%{id: 1, a: "y"}]
  """

  alias Exqlite.Sqlite3

  @busy_timeout 5_000

  @type db :: Sqlite3.db()
  @type row :: %{atom => term}

  @doc """
  Opens (and creates) the file at `path` with WAL and a busy timeout, and runs `schema`.

  Options:

    * `:added`: the columns a later version added, by table, such as
      `[jobs: ["worktree TEXT"]]`. A file made before a column gains it; a newer file already
      has it.
    * `:then`: a statement run after the columns are added, such as an index on one of them.
  """
  @spec open(String.t(), String.t(), keyword) :: {:ok, db} | {:refused, {:sqlite, term}}
  def open(path, schema, opts \\ []) do
    with {:ok, db} <- Sqlite3.open(path) do
      with :ok <- Sqlite3.set_busy_timeout(db, @busy_timeout),
           :ok <- Sqlite3.execute(db, "PRAGMA journal_mode = WAL;"),
           :ok <- Sqlite3.execute(db, schema),
           :ok <- add_columns(db, Keyword.get(opts, :added, [])),
           :ok <- after_added(db, opts[:then]) do
        {:ok, db}
      else
        {:error, reason} ->
          Sqlite3.close(db)
          {:refused, {:sqlite, reason}}
      end
    else
      {:error, reason} -> {:refused, {:sqlite, reason}}
    end
  end

  defp add_columns(db, added) do
    added
    |> Enum.flat_map(fn {table, columns} ->
      Enum.map(columns, &"ALTER TABLE #{table} ADD COLUMN #{&1}")
    end)
    |> Enum.reduce_while(:ok, fn sql, :ok ->
      case Sqlite3.execute(db, sql) do
        :ok -> {:cont, :ok}
        {:error, "duplicate column name" <> _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp after_added(_db, nil), do: :ok
  defp after_added(db, sql), do: Sqlite3.execute(db, sql)

  @doc "Runs `sql` with `args` bound to `?1`, `?2`, … and answers its rows as lists."
  @spec query(db, String.t(), [term]) :: [[term]]
  def query(db, sql, args) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(stmt, args)
      {:ok, rows} = Sqlite3.fetch_all(db, stmt)
      rows
    after
      Sqlite3.release(db, stmt)
    end
  end

  @doc """
  Runs `fun` in one immediate transaction and answers what it answers: what it writes is saved
  together or not at all.
  """
  @spec transaction(db, (-> result)) :: result when result: term
  def transaction(db, fun) do
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
    result = fun.()
    :ok = Sqlite3.execute(db, "COMMIT")
    result
  end

  @doc """
  The rows of `table` where `where` holds, each a map of `columns`. `where` may end with an
  `ORDER BY`.
  """
  @spec select(db, String.t(), [atom], String.t(), [term]) :: [row]
  def select(db, table, columns, where, args) do
    db
    |> query("SELECT #{Enum.join(columns, ",")} FROM #{table} WHERE #{where}", args)
    |> Enum.map(&row(columns, &1))
  end

  @doc """
  The rows of `table` with these ids, oldest first; an id with no row is absent. `scope` narrows
  them by equal columns, such as `[host: "laptop"]`.
  """
  @spec rows_by_id(db, String.t(), [atom], [integer], keyword) :: [row]
  def rows_by_id(db, table, columns, ids, scope \\ [])
  def rows_by_id(_db, _table, _columns, [], _scope), do: []

  def rows_by_id(db, table, columns, ids, scope) do
    equal = scope |> Enum.with_index(1) |> Enum.map(fn {{k, _}, i} -> "#{k} = ?#{i} AND " end)
    where = "#{equal}id IN (#{marks(length(ids), length(scope) + 1)}) ORDER BY id"
    select(db, table, columns, where, Keyword.values(scope) ++ ids)
  end

  @doc """
  Inserts a row of `fields` into `table`, with `tail` after its values (an `ON CONFLICT` clause,
  a `RETURNING`), and answers the rows it returns.
  """
  @spec insert(db, String.t(), [{atom, term}], String.t()) :: [[term]]
  def insert(db, table, fields, tail \\ "") do
    names = Enum.map_join(fields, ",", &elem(&1, 0))
    sql = "INSERT INTO #{table} (#{names}) VALUES (#{marks(length(fields))}) #{tail}"
    query(db, sql, Enum.map(fields, &elem(&1, 1)))
  end

  @doc "Writes a row of `fields` into `table` in place of any row with its key."
  @spec upsert(db, String.t(), [{atom, term}]) :: :ok
  def upsert(db, table, fields) do
    names = Enum.map_join(fields, ",", &elem(&1, 0))
    sql = "INSERT OR REPLACE INTO #{table} (#{names}) VALUES (#{marks(length(fields))})"
    query(db, sql, Enum.map(fields, &elem(&1, 1)))
    :ok
  end

  @doc """
  Sets `fields` on row `id` of `table`. A value that is not text, an integer or nil is stored
  as its `inspect/1` text.
  """
  @spec update(db, String.t(), term, [{atom, term}]) :: :ok
  def update(db, table, id, fields) do
    sets =
      fields |> Enum.with_index(2) |> Enum.map_join(",", fn {{k, _}, i} -> "#{k} = ?#{i}" end)

    query(db, "UPDATE #{table} SET #{sets} WHERE id = ?1", [id | Enum.map(fields, &dump/1)])
    :ok
  end

  defp dump({_, v}) when is_binary(v) or is_integer(v) or is_nil(v), do: v
  defp dump({_, v}), do: inspect(v)

  @doc """
  A term as a column stores it, by one rule (F-117's new-2): text and integers as they are, nil
  as nil, an atom as its name, and anything else as canonical JSON, with a tuple as an array, an
  atom inside as its name (`true`, `false` and `nil` as JSON's), and a map's keys sorted, so
  equal terms give equal text. Never `inspect` text, except for a pid, a reference, a port or a
  function, which have no other: they name a process, not data.

      iex> CodingAgentFramework.Store.text(:repeating)
      "repeating"
      iex> CodingAgentFramework.Store.text({:sample_too_old, 31_001})
      ~s(["sample_too_old",31001])
      iex> CodingAgentFramework.Store.text(%{b: [1, nil], a: true})
      ~s({"a":true,"b":[1,null]})
  """
  @spec text(term) :: String.t() | integer | nil
  def text(nil), do: nil
  def text(v) when is_binary(v) or is_integer(v), do: v
  def text(v) when is_atom(v), do: Atom.to_string(v)
  def text(v), do: json(v)

  defp json(v) when is_boolean(v) or is_nil(v) or is_number(v) or is_binary(v),
    do: JSON.encode!(v)

  defp json(v) when is_atom(v), do: JSON.encode!(Atom.to_string(v))
  defp json(v) when is_tuple(v), do: json(Tuple.to_list(v))
  defp json(v) when is_list(v), do: "[" <> Enum.map_join(v, ",", &json/1) <> "]"

  defp json(%{} = v) do
    pairs = v |> Enum.map(fn {k, x} -> {key(k), json(x)} end) |> Enum.sort()
    "{" <> Enum.map_join(pairs, ",", fn {k, x} -> JSON.encode!(k) <> ":" <> x end) <> "}"
  end

  defp json(v), do: JSON.encode!(inspect(v))

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: json(k)

  @doc """
  `count` placeholders, numbered from `from`.

      iex> CodingAgentFramework.Store.marks(3, 2)
      "?2,?3,?4"
  """
  @spec marks(non_neg_integer, pos_integer) :: String.t()
  def marks(count, from \\ 1), do: Enum.map_join(from..(from + count - 1)//1, ",", &"?#{&1}")

  @doc """
  A row's values as a map of `columns`.

      iex> CodingAgentFramework.Store.row([:id, :a], [1, "x"])
      %{id: 1, a: "x"}
  """
  @spec row([atom], [term]) :: row
  def row(columns, values), do: columns |> Enum.zip(values) |> Map.new()

  @doc """
  Loads a map stored as a term by this build or another, total: a field this build added takes
  its value in `fresh`, and a field it does not know is dropped and named. Bytes that are not a
  map, or that `:safe` refuses (an atom this build never saw), load as `fresh`. Answers the map
  and its problems, `[]` when none.

      iex> bytes = :erlang.term_to_binary(%{a: 1, old: 2})
      iex> CodingAgentFramework.Store.load(bytes, %{a: 0, b: 0})
      {%{a: 1, b: 0}, [{:unknown_fields, [:old]}]}
  """
  @spec load(term, map) :: {map, list}
  def load(bytes, fresh) when is_binary(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      %{} = stored ->
        unknown = Map.keys(stored) -- Map.keys(fresh)
        problems = if unknown == [], do: [], else: [{:unknown_fields, Enum.sort(unknown)}]
        {Map.merge(fresh, Map.take(stored, Map.keys(fresh))), problems}

      _ ->
        {fresh, [:not_a_map]}
    end
  rescue
    ArgumentError -> {fresh, [:unreadable]}
  end

  def load(_, fresh), do: {fresh, [:unreadable]}
end
