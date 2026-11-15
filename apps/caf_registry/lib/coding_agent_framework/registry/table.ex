defmodule CodingAgentFramework.Registry.Table do
  @moduledoc """
  The framework's first tables, in one SQLite file the caller names: `registry_sessions`, one
  row per session file of a `{host, account}`, and `registry_reads`, one row per `{host,
  account}` that has been read at least once.

  `CodingAgentFramework.Registry` is the one writer. Anyone may open the file and read: a
  `{host, account}` with no read row is `:unread`, never an empty list.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Registry.Table.open(path)
      iex> CodingAgentFramework.Registry.Table.rows(db, "laptop", "work")
      :unread
  """

  alias Exqlite.Sqlite3

  @data ~w(pid session_id cwd name name_source status version kind entrypoint proc_start
           started_at status_updated_at updated_at extra problem alive)a
  @columns [:id, :host, :account, :file | @data] ++ [:written_at]

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS registry_sessions (
    id INTEGER PRIMARY KEY,
    host TEXT NOT NULL, account TEXT NOT NULL, file TEXT NOT NULL,
    pid INTEGER, session_id TEXT, cwd TEXT, name TEXT, name_source TEXT, status TEXT,
    version TEXT, kind TEXT, entrypoint TEXT, proc_start TEXT,
    started_at INTEGER, status_updated_at INTEGER, updated_at INTEGER,
    extra TEXT, problem TEXT, alive TEXT NOT NULL, written_at INTEGER NOT NULL,
    UNIQUE (host, account, file));
  CREATE TABLE IF NOT EXISTS registry_reads (
    host TEXT NOT NULL, account TEXT NOT NULL, read_at INTEGER NOT NULL,
    files INTEGER NOT NULL, problems INTEGER NOT NULL, PRIMARY KEY (host, account));
  """

  @type db :: Sqlite3.db()
  @type row :: %{atom => term}
  @type change :: {:put, file :: String.t(), row} | {:delete, file :: String.t()}

  @doc "The columns a row's data is compared and written by."
  @spec data_columns() :: [atom]
  def data_columns, do: @data

  @doc "Opens (and creates) the file at `path`, with the tables. A reader opens its own."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path) do
    with {:ok, db} <- Sqlite3.open(path),
         :ok <- Sqlite3.set_busy_timeout(db, 5_000),
         :ok <- Sqlite3.execute(db, @schema) do
      {:ok, db}
    else
      {:error, reason} -> {:refused, {:sqlite, reason}}
    end
  end

  @doc """
  A `{host, account}`'s rows, with when it was last read and what that read counted; `:unread`
  before its first read.
  """
  @spec rows(db, String.t(), String.t()) :: :unread | {:ok, map}
  def rows(db, host, account) do
    with {:ok, read} <- last_read(db, host, account) do
      sql = "SELECT #{cols()} FROM registry_sessions WHERE host = ?1 AND account = ?2 ORDER BY id"
      {:ok, Map.put(read, :rows, db |> query(sql, [host, account]) |> Enum.map(&to_row/1))}
    end
  end

  @doc "When a `{host, account}` was last read and what that read counted; `:unread` before."
  @spec last_read(db, String.t(), String.t()) :: :unread | {:ok, map}
  def last_read(db, host, account) do
    reads = "SELECT read_at, files, problems FROM registry_reads WHERE host = ?1 AND account = ?2"

    case query(db, reads, [host, account]) do
      [] -> :unread
      [[read_at, files, problems]] -> {:ok, %{read_at: read_at, files: files, problems: problems}}
    end
  end

  @doc "The rows with these ids; an id whose row was deleted is absent."
  @spec rows_by_id(db, [integer]) :: [row]
  def rows_by_id(_db, []), do: []

  def rows_by_id(db, ids) do
    marks = Enum.map_join(1..length(ids), ",", &"?#{&1}")

    db
    |> query("SELECT #{cols()} FROM registry_sessions WHERE id IN (#{marks}) ORDER BY id", ids)
    |> Enum.map(&to_row/1)
  end

  @doc """
  Applies `changes` and records the read, in one transaction. Returns the ids of the rows put
  or deleted, and whether this was the `{host, account}`'s first read.
  """
  @spec write(db, String.t(), String.t(), [change], map) ::
          {:ok, %{ids: [integer], first: boolean}}
  def write(db, host, account, changes, %{read_at: at, files: files, problems: problems}) do
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

    first =
      query(db, "SELECT 1 FROM registry_reads WHERE host = ?1 AND account = ?2", [host, account]) ==
        []

    ids = Enum.flat_map(changes, &change(db, host, account, at, &1))

    query(db, "INSERT OR REPLACE INTO registry_reads VALUES (?1, ?2, ?3, ?4, ?5)", [
      host,
      account,
      at,
      files,
      problems
    ])

    :ok = Sqlite3.execute(db, "COMMIT")
    {:ok, %{ids: ids, first: first}}
  end

  defp change(db, host, account, at, {:put, file, row}) do
    names = [:host, :account, :file | @data] ++ [:written_at]
    values = [host, account, file | Enum.map(@data, &dump(&1, row[&1]))] ++ [at]
    marks = Enum.map_join(1..length(names), ",", &"?#{&1}")
    set = Enum.map_join(@data ++ [:written_at], ",", &"#{&1} = excluded.#{&1}")

    db
    |> query(
      "INSERT INTO registry_sessions (#{Enum.join(names, ",")}) VALUES (#{marks}) " <>
        "ON CONFLICT (host, account, file) DO UPDATE SET #{set} RETURNING id",
      values
    )
    |> List.flatten()
  end

  defp change(db, host, account, _at, {:delete, file}) do
    db
    |> query(
      "DELETE FROM registry_sessions WHERE host = ?1 AND account = ?2 AND file = ?3 RETURNING id",
      [host, account, file]
    )
    |> List.flatten()
  end

  defp cols, do: Enum.join(@columns, ",")

  defp to_row(values) do
    @columns |> Enum.zip(values) |> Map.new(fn {k, v} -> {k, load(k, v)} end)
  end

  defp dump(:extra, map), do: JSON.encode!(map || %{})
  defp dump(:alive, alive), do: Atom.to_string(alive)
  defp dump(_, value), do: value

  # Total over what a column holds: a value this writer did not write (a broken file, an older
  # or other writer) loads as nil or :unknown, so one such row never stops a read of the others.
  defp load(:extra, text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp load(:extra, _), do: nil
  defp load(:alive, text) when text in ~w(live replaced gone unknown), do: String.to_atom(text)
  defp load(:alive, _), do: :unknown
  defp load(_, value), do: value

  # The writer's own statements: an error here is a bug or a broken file, so it raises and the
  # supervisor restarts the writer, which reloads its rows from the file.
  defp query(db, sql, args) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(stmt, args)
      {:ok, rows} = Sqlite3.fetch_all(db, stmt)
      rows
    after
      Sqlite3.release(db, stmt)
    end
  end
end
