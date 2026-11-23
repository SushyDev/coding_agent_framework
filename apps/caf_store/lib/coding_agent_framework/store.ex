defmodule CodingAgentFramework.Store do
  @moduledoc """
  The table code every writer shares, over SQLite: open a file with WAL and a bounded busy wait,
  create its schema, add the columns a later version added, run a statement, read rows as maps,
  write rows, and load a stored map with the fields a newer build added.

  A pure module: it starts no process and owns no table. Each part keeps its own table, its own
  schema and its own functions, and is the one writer of that table (`docs/design.md`, "The
  parts"). The SQL a part passes names its own table and columns; values are always bound.

  A statement's error is a bug or a broken file, so `query/3` and the functions on it raise,
  and the writer's supervisor restarts the writer, which reads its rows again from the file.
  Only `open/3` answers `{:refused, reason}`.

  **A busy file is waited for by the clock** (F-216). When another connection holds the file's
  write lock, a statement tries again, sleeping 1 ms and then twice as long each time up to
  5 ms, until `busy_bound/0` (2 s) has passed on the monotonic clock since its first try. Then
  it is busy: `open/3`, `write/3`, `read_only/4` and `snapshot/2` answer `{:refused, {:sqlite,
  :busy}}`, and `query/3`, `transaction/2` and the functions on them raise `Store.Busy`, as any
  statement's error raises. A busy answer comes no later than the bound and 500 ms (about 100 on an idle host; the
  last try's own run and the scheduler on a loaded one, F-224): the last sleep ends at the
  deadline, one try follows it, and the sleeps are short because a longer
  sleep wakes later on a loaded host. `open/3` and `write/3` run several statements under one
  deadline. SQLite's own busy wait is off, because exqlite's handler waits about four times its
  bound (F-215's new-2).

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

  defmodule Busy do
    @moduledoc """
    Raised by a statement that found the file's write lock held by another connection for
    all of `CodingAgentFramework.Store.busy_bound/0`. `waited` is how long it waited, in ms by
    the monotonic clock.
    """
    defexception waited: 0

    @impl true
    def message(%{waited: ms}), do: "database is busy: its write lock was held for #{ms} ms"
  end

  # Every part's call timeout over a write is at least 5 s, and a call may run two writes, so
  # the bound and its slack fit twice under it (F-216).
  @busy_bound 2_000
  # A sleep of 25 ms woke up to 70 ms late on a loaded macOS host, one of 5 ms up to 33 ms.
  @busy_poll 5
  # What each kind of statement answers when SQLite refuses it busy.
  @busy ["database is locked", "Database busy"]

  @type db :: Sqlite3.db()
  @type row :: %{atom => term}

  @doc """
  How long, in ms by the monotonic clock, a statement waits for a write lock another connection
  holds before it is busy. A busy answer comes no later than this and 500 ms (F-224).

      iex> CodingAgentFramework.Store.busy_bound()
      2000
  """
  @spec busy_bound() :: pos_integer
  def busy_bound, do: @busy_bound

  @doc """
  Opens (and creates) the file at `path` with WAL and a bounded busy wait, and runs `schema`.
  Answers `{:refused, {:sqlite, :busy}}` when another connection holds the file's write lock for
  all of `busy_bound/0`, over every statement it runs.

  Options:

    * `:added`: the columns a later version added, by table, such as
      `[jobs: ["worktree TEXT"]]`. A file made before a column gains it; a newer file already
      has it.
    * `:then`: a statement run after the columns are added, such as an index on one of them.
  """
  @spec open(String.t(), String.t(), keyword) :: {:ok, db} | {:refused, {:sqlite, term}}
  def open(path, schema, opts \\ []), do: open(path, schema, opts, deadline())

  defp open(path, schema, opts, deadline) do
    with {:ok, db} <- Sqlite3.open(path) do
      with :ok <- Sqlite3.set_busy_timeout(db, 0),
           :ok <- execute(db, "PRAGMA journal_mode = WAL;", deadline),
           :ok <- execute(db, schema, deadline),
           :ok <- add_columns(db, Keyword.get(opts, :added, []), deadline),
           :ok <- after_added(db, opts[:then], deadline) do
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

  @doc """
  Reads the existing file at `path` read-only (F-195): opens it so it can write nothing and
  makes no file, answers `{:ok, fun.(db)}`, or `{:ok, empty}` when the file has no table
  `table` yet, and closes it. A reader outside the tree uses it, so it never takes a writer's
  lock or adds a writer's schema. Answers `{:refused, {:sqlite, reason}}` for a file it cannot
  open, a missing one included.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "ro.db")
      iex> alias CodingAgentFramework.Store
      iex> Store.read_only(path, "t", [], &Store.query(&1, "SELECT a FROM t", []))
      {:refused, {:sqlite, :database_open_failed}}
      iex> {:ok, db} = Store.open(path, "CREATE TABLE IF NOT EXISTS t (a TEXT);")
      iex> Store.insert(db, "t", [a: "x"], "")
      iex> Store.read_only(path, "t", [], &Store.query(&1, "SELECT a FROM t", []))
      {:ok, [["x"]]}
      iex> Store.read_only(path, "u", [], &Store.query(&1, "SELECT a FROM u", []))
      {:ok, []}
  """
  @spec read_only(String.t(), String.t(), term, (db -> term)) ::
          {:ok, term} | {:refused, {:sqlite, term}}
  def read_only(path, table, empty, fun) do
    case Sqlite3.open(path, mode: :readonly) do
      {:ok, db} ->
        try do
          :ok = Sqlite3.set_busy_timeout(db, 0)

          tables =
            query(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", [table])

          if tables == [], do: {:ok, empty}, else: {:ok, fun.(db)}
        rescue
          Busy -> {:refused, {:sqlite, :busy}}
        after
          Sqlite3.close(db)
        end

      {:error, reason} ->
        {:refused, {:sqlite, reason}}
    end
  end

  @doc """
  Opens (and creates) the file at `path` as `open/3` does, runs `fun.(db)` in one immediate
  transaction as `transaction/2` does, and closes the file (F-214): for a writer that is no
  process, which reads and writes once and keeps no connection. Answers `{:ok, fun.(db)}`, or
  `{:refused, {:sqlite, reason}}` for a file it cannot open. What `fun` writes is saved together
  or not at all, and a statement's error raises, as it does everywhere else in this module.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "write.db")
      iex> alias CodingAgentFramework.Store
      iex> schema = "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, a TEXT);"
      iex> Store.write(path, schema, &Store.insert(&1, "t", [a: "x"], "RETURNING id"))
      {:ok, [[1]]}
      iex> Store.read_only(path, "t", [], &Store.query(&1, "SELECT a FROM t", []))
      {:ok, [["x"]]}
  """
  @spec write(String.t(), String.t(), (db -> result)) ::
          {:ok, result} | {:refused, {:sqlite, term}}
        when result: term
  def write(path, schema, fun) do
    deadline = deadline()

    with {:ok, db} <- open(path, schema, [], deadline) do
      try do
        {:ok, transaction(db, fn -> fun.(db) end, deadline)}
      rescue
        Busy -> {:refused, {:sqlite, :busy}}
      after
        Sqlite3.close(db)
      end
    end
  end

  @doc """
  Reads the existing file at `path` read-only, as `read_only/4` does, in one read transaction,
  so every table `fun` reads is of one instant (F-199). `fun.(db, tables)` gets the names of the
  file's tables, so it reads only the ones made. Answers `{:ok, fun.(db, tables)}`, or
  `{:refused, {:sqlite, reason}}` for a file it cannot open, a missing one included.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "snap.db")
      iex> alias CodingAgentFramework.Store
      iex> {:ok, db} = Store.open(path, "CREATE TABLE IF NOT EXISTS t (a TEXT);")
      iex> Store.insert(db, "t", [a: "x"], "")
      iex> Store.snapshot(path, fn db, tables ->
      ...>   {MapSet.to_list(tables), Store.query(db, "SELECT a FROM t", [])}
      ...> end)
      {:ok, {["t"], [["x"]]}}
  """
  @spec snapshot(String.t(), (db, MapSet.t(String.t()) -> term)) ::
          {:ok, term} | {:refused, {:sqlite, term}}
  def snapshot(path, fun) do
    case Sqlite3.open(path, mode: :readonly) do
      {:ok, db} ->
        try do
          :ok = Sqlite3.set_busy_timeout(db, 0)
          # A deferred transaction takes its snapshot at its first read, and ends with the close.
          :ok = Sqlite3.execute(db, "BEGIN")
          names = query(db, "SELECT name FROM sqlite_master WHERE type = 'table'", [])
          {:ok, fun.(db, MapSet.new(names, &hd/1))}
        rescue
          Busy -> {:refused, {:sqlite, :busy}}
        after
          Sqlite3.close(db)
        end

      {:error, reason} ->
        {:refused, {:sqlite, reason}}
    end
  end

  @doc """
  Takes the file at `path` as a lock, for as long as the caller keeps the answer (F-215): opens
  (and creates) it, empty, and begins an immediate transaction that is never committed, so the
  file's write lock stays with this connection. SQLite takes that lock from the operating
  system, which gives it back when the process that holds it dies, and keeps it apart between
  two connections in one process as between two processes. The take is one try with no busy
  wait: `{:ok, held}`, or `{:refused, :held}` when another connection holds it now, or
  `{:refused, {:sqlite, reason}}` for a file it cannot open or lock. It writes nothing to the
  file, which stays empty, and runs no statement that would.

  `let_go/1` gives the lock back. A connection no process refers to is closed when it is
  collected, so the lock outlives its holder's process only until then: a holder keeps the
  answer in one process only, and lets go of it before it ends.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "hold.lock")
      iex> alias CodingAgentFramework.Store
      iex> {:ok, held} = Store.hold(path)
      iex> Store.hold(path)
      {:refused, :held}
      iex> Store.let_go(held)
      :ok
      iex> {:ok, again} = Store.hold(path)
      iex> Store.let_go(again)
      :ok
  """
  @spec hold(String.t()) :: {:ok, db} | {:refused, :held | {:sqlite, term}}
  def hold(path) do
    with {:ok, db} <- Sqlite3.open(path) do
      # No busy wait: a held file is refused now (SQLite's wait overshoots its bound, F-215).
      with :ok <- Sqlite3.set_busy_timeout(db, 0),
           :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
        {:ok, db}
      else
        {:error, reason} ->
          Sqlite3.close(db)
          # SQLITE_BUSY's text: another connection holds the write lock.
          if reason == "database is locked",
            do: {:refused, :held},
            else: {:refused, {:sqlite, reason}}
      end
    else
      {:error, reason} -> {:refused, {:sqlite, reason}}
    end
  end

  @doc "Gives back a lock `hold/1` took, closing its connection. Answers `:ok`."
  @spec let_go(db) :: :ok
  def let_go(db) do
    Sqlite3.close(db)
    :ok
  end

  defp add_columns(db, added, deadline) do
    added
    |> Enum.flat_map(fn {table, columns} ->
      Enum.map(columns, &"ALTER TABLE #{table} ADD COLUMN #{&1}")
    end)
    |> Enum.reduce_while(:ok, fn sql, :ok ->
      case execute(db, sql, deadline) do
        :ok -> {:cont, :ok}
        {:error, "duplicate column name" <> _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp after_added(_db, nil, _deadline), do: :ok
  defp after_added(db, sql, deadline), do: execute(db, sql, deadline)

  defp deadline, do: now() + @busy_bound
  defp now, do: System.monotonic_time(:millisecond)

  # `{:error, :busy}` once the deadline has passed with the lock still held.
  defp execute(db, sql, deadline) do
    case until_free(fn -> Sqlite3.execute(db, sql) end, deadline) do
      :busy -> {:error, :busy}
      answer -> answer
    end
  end

  # Tries `try` again while SQLite answers it busy, until `deadline`: the one wait in this
  # module, bounded by the monotonic clock. The last sleep ends at the deadline.
  defp until_free(try, deadline, sleep \\ 1) do
    case try.() do
      {:error, reason} when reason in @busy ->
        case deadline - now() do
          left when left > 0 ->
            Process.sleep(min(sleep, left))
            until_free(try, deadline, min(2 * sleep, @busy_poll))

          _ ->
            :busy
        end

      answer ->
        answer
    end
  end

  defp busy!(:busy, deadline), do: raise(Busy, waited: now() - deadline + @busy_bound)
  defp busy!(answer, _deadline), do: answer

  @doc """
  Runs `sql` with `args` bound to `?1`, `?2`, … and answers its rows as lists. Raises
  `Store.Busy` when the file's write lock stays held for all of `busy_bound/0`.
  """
  @spec query(db, String.t(), [term]) :: [[term]]
  def query(db, sql, args) do
    deadline = deadline()
    {:ok, stmt} = busy!(until_free(fn -> Sqlite3.prepare(db, sql) end, deadline), deadline)

    try do
      :ok = Sqlite3.bind(stmt, args)
      {:ok, rows} = busy!(until_free(fn -> Sqlite3.fetch_all(db, stmt) end, deadline), deadline)
      rows
    after
      Sqlite3.release(db, stmt)
    end
  end

  @doc """
  Runs `fun` in one immediate transaction and answers what it answers: what it writes is saved
  together or not at all. When `fun` raises, throws or exits, the transaction is rolled back
  and the same error goes on to the caller, so the connection is never left inside an open
  transaction that the next write would join. Raises `Store.Busy` when another connection holds
  the write lock for all of `busy_bound/0`; then nothing has begun.
  """
  @spec transaction(db, (-> result)) :: result when result: term
  def transaction(db, fun), do: transaction(db, fun, deadline())

  defp transaction(db, fun, deadline) do
    :ok = busy!(until_free(fn -> Sqlite3.execute(db, "BEGIN IMMEDIATE") end, deadline), deadline)

    try do
      result = fun.()
      :ok = Sqlite3.execute(db, "COMMIT")
      result
    catch
      kind, reason ->
        Sqlite3.execute(db, "ROLLBACK")
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
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
  Sets `fields` on row `id` of `table`. Each value is stored by `text/1`'s one rule: an atom as
  its name, a tuple, list or map as JSON, never `inspect` text.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "update.db")
      iex> alias CodingAgentFramework.Store
      iex> {:ok, db} = Store.open(path, "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, a TEXT);")
      iex> [[id]] = Store.insert(db, "t", [a: "x"], "RETURNING id")
      iex> Store.update(db, "t", id, a: {:refused, :no_waiter})
      iex> Store.rows_by_id(db, "t", [:a], [id])
      [%{a: ~s(["refused","no_waiter"])}]
  """
  @spec update(db, String.t(), term, [{atom, term}]) :: :ok
  def update(db, table, id, fields) do
    sets =
      fields |> Enum.with_index(2) |> Enum.map_join(",", fn {{k, _}, i} -> "#{k} = ?#{i}" end)

    query(db, "UPDATE #{table} SET #{sets} WHERE id = ?1", [id | Enum.map(fields, &dump/1)])
    :ok
  end

  # A blob is bound as it is.
  defp dump({_, {:blob, _} = v}), do: v
  defp dump({_, v}), do: text(v)

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
  A value an earlier build stored as `inspect` text, by `text/1`'s rule: the literal's text, or
  the value as it is when it is no literal or is already JSON. So it may run on a column more
  than once: what it answers, it answers again unchanged.

      iex> CodingAgentFramework.Store.from_inspect(":repeating")
      "repeating"
      iex> CodingAgentFramework.Store.from_inspect("{:sample_too_old, 31001}")
      ~s(["sample_too_old",31001])
      iex> CodingAgentFramework.Store.from_inspect(~s({"a":true}))
      ~s({"a":true})
      iex> CodingAgentFramework.Store.from_inspect("ok")
      "ok"
  """
  @spec from_inspect(term) :: term
  def from_inspect(text) when is_binary(text) do
    with true <- String.starts_with?(text, [":", "{", "[", "%", "\""]),
         {:error, _} <- JSON.decode(text),
         # An atom comes back as its name, which `text/1` stores the same way, and no atom is
         # made from what a file holds.
         {:ok, ast} <-
           Code.string_to_quoted(text, static_atoms_encoder: fn name, _ -> {:ok, name} end),
         {:ok, term} <- literal(ast) do
      text(term)
    else
      _ -> text
    end
  end

  def from_inspect(other), do: other

  defp literal(v) when is_atom(v) or is_number(v) or is_binary(v), do: {:ok, v}
  defp literal({a, b}), do: literal({:{}, [], [a, b]})

  defp literal({:{}, _, items}),
    do: with({:ok, l} <- literal(items), do: {:ok, List.to_tuple(l)})

  defp literal({:%{}, _, pairs}),
    do:
      with(
        {:ok, l} <- literal(Enum.map(pairs, &Tuple.to_list/1)),
        do: {:ok, Map.new(l, &List.to_tuple/1)}
      )

  defp literal(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn x, {:ok, acc} ->
      case literal(x) do
        {:ok, v} -> {:cont, {:ok, acc ++ [v]}}
        no -> {:halt, no}
      end
    end)
  end

  defp literal(_), do: :not_literal

  @doc """
  Converts what an earlier build stored as `inspect` text in `columns` of `table` to `text/1`'s
  rule (`from_inspect/1`), in one transaction, and answers how many values changed. A writer
  runs it when it opens its file; a second run changes nothing (F-117's new-2). Rows are found
  by `rowid`, so a table keyed by other columns (a reader's reads table) converts too.
  """
  @spec convert(db, String.t(), [atom]) :: non_neg_integer
  def convert(db, table, columns) do
    transaction(db, fn ->
      for column <- columns, reduce: 0 do
        n ->
          sql =
            "SELECT rowid, #{column} FROM #{table} WHERE substr(#{column}, 1, 1) IN " <>
              ~s{(':', '{', '[', '%', '"')}

          changed =
            for [id, old] <- query(db, sql, []), (new = from_inspect(old)) != old do
              query(db, "UPDATE #{table} SET #{column} = ?2 WHERE rowid = ?1", [id, new])
            end

          n + length(changed)
      end
    end)
  end

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
