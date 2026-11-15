defmodule CodingAgentFramework.Usage.Table do
  @moduledoc """
  `Usage`'s tables, in one SQLite file the caller names: `usage_readings`, one row per account
  that has a reading, and `usage_reads`, one row once `Usage` has read at all.

  `CodingAgentFramework.Usage` is the one writer. Anyone may open the file and read: before the
  first read, the answer is `:unread`, never an empty list.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "usage.db")
      iex> {:ok, db} = CodingAgentFramework.Usage.Table.open(path)
      iex> CodingAgentFramework.Usage.Table.rows(db)
      :unread
  """

  alias Exqlite.Sqlite3

  @data ~w(used resets_at seen_at problem)a
  @columns [:id, :account | @data] ++ [:written_at]

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS usage_readings (
    id INTEGER PRIMARY KEY, account TEXT NOT NULL UNIQUE,
    used REAL, resets_at INTEGER, seen_at INTEGER, problem TEXT, written_at INTEGER NOT NULL);
  CREATE TABLE IF NOT EXISTS usage_reads (
    one INTEGER PRIMARY KEY CHECK (one = 1), read_at INTEGER NOT NULL);
  """

  @type db :: Sqlite3.db()
  @type change :: {:put, String.t(), map} | {:delete, String.t()}

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

  @doc "When `Usage` last read, or `:unread`."
  @spec last_read(db) :: :unread | {:ok, %{read_at: integer}}
  def last_read(db) do
    case query(db, "SELECT read_at FROM usage_reads", []) do
      [] -> :unread
      [[at]] -> {:ok, %{read_at: at}}
    end
  end

  @doc "Every row, with when `Usage` last read; `:unread` before its first read."
  @spec rows(db) :: :unread | {:ok, %{read_at: integer, rows: [map]}}
  def rows(db) do
    with {:ok, read} <- last_read(db) do
      rows = query(db, "SELECT #{cols()} FROM usage_readings ORDER BY id", [])
      {:ok, Map.put(read, :rows, Enum.map(rows, &to_row/1))}
    end
  end

  @doc "The rows with these ids; an id whose row was deleted is absent."
  @spec rows_by_id(db, [integer]) :: [map]
  def rows_by_id(_db, []), do: []

  def rows_by_id(db, ids) do
    marks = Enum.map_join(1..length(ids), ",", &"?#{&1}")

    db
    |> query("SELECT #{cols()} FROM usage_readings WHERE id IN (#{marks}) ORDER BY id", ids)
    |> Enum.map(&to_row/1)
  end

  @doc """
  Applies `changes` and records the read at `at` (ms), in one transaction. Returns each changed
  row as `{account, id}`, and whether this was the first read.
  """
  @spec write(db, [change], integer) :: {:ok, %{ids: [{String.t(), integer}], first: boolean}}
  def write(db, changes, at) do
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
    first = last_read(db) == :unread
    ids = Enum.flat_map(changes, &change(db, at, &1))
    query(db, "INSERT OR REPLACE INTO usage_reads VALUES (1, ?1)", [at])
    :ok = Sqlite3.execute(db, "COMMIT")
    {:ok, %{ids: ids, first: first}}
  end

  defp change(db, at, {:put, account, row}) do
    set = Enum.map_join(@data ++ [:written_at], ",", &"#{&1} = excluded.#{&1}")

    db
    |> query(
      "INSERT INTO usage_readings (account,#{Enum.join(@data, ",")},written_at) " <>
        "VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT (account) DO UPDATE SET #{set} RETURNING id",
      [account | Enum.map(@data, &row[&1])] ++ [at]
    )
    |> Enum.map(fn [id] -> {account, id} end)
  end

  defp change(db, _at, {:delete, account}) do
    db
    |> query("DELETE FROM usage_readings WHERE account = ?1 RETURNING id", [account])
    |> Enum.map(fn [id] -> {account, id} end)
  end

  defp cols, do: Enum.join(@columns, ",")

  defp to_row(values), do: @columns |> Enum.zip(values) |> Map.new()

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
