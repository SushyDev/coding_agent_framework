defmodule CodingAgentFramework.Usage.Table do
  @moduledoc """
  `Usage`'s tables, in one SQLite file the caller names: `usage_readings`, one row per account
  that has a reading, and `usage_reads`, one row once `Usage` has read at all. Its table code
  is `CodingAgentFramework.Reader`'s, from `meta/0`.

  `CodingAgentFramework.Usage` is the one writer. Anyone may open the file and read: before the
  first read, the answer is `:unread`, never an empty list.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "usage.db")
      iex> {:ok, db} = CodingAgentFramework.Usage.Table.open(path)
      iex> CodingAgentFramework.Usage.Table.rows(db)
      :unread
  """

  alias CodingAgentFramework.Reader
  alias CodingAgentFramework.Usage.Reading

  @data ~w(used resets_at five_used five_resets_at seen_at problem)a
  # A file made before the five-hour window gains its columns; a newer file already has them.
  @added [usage_readings: ["five_used REAL", "five_resets_at INTEGER"]]

  @schema """
  CREATE TABLE IF NOT EXISTS usage_readings (
    id INTEGER PRIMARY KEY, account TEXT NOT NULL UNIQUE,
    used REAL, resets_at INTEGER, five_used REAL, five_resets_at INTEGER, seen_at INTEGER,
    problem TEXT, written_at INTEGER NOT NULL);
  CREATE TABLE IF NOT EXISTS usage_reads (
    one INTEGER PRIMARY KEY CHECK (one = 1), read_at INTEGER NOT NULL);
  """

  @type db :: CodingAgentFramework.Store.db()
  @type change :: {:put, String.t(), map} | {:delete, String.t()}

  @doc """
  The table as `Reader` reads and writes it. As a `Tracker` source, for one account (options
  `db:`, `host:`, the name `Usage` was started with, and `account:`), each row has `assumed`:
  true when its window has reset since it was written (`Usage.Reading.status/3`), so a view
  shows it as 0 % used and assumed. The clock is option `clock:`, a function of no arguments
  that answers Unix seconds; without it, the system's.
  """
  @spec meta() :: Reader.meta()
  def meta do
    %{
      schema: @schema,
      open: [added: @added],
      table: "usage_readings",
      reads: "usage_reads",
      scope: [],
      filter: [:account],
      key: :account,
      data: @data,
      read: [:read_at],
      view: &assumed/2,
      convert: [{"usage_readings", [:problem]}],
      topic: "usage",
      kind: :usage,
      name: :account
    }
  end

  @doc "The columns a row's data is compared and written by."
  @spec data_columns() :: [atom]
  def data_columns, do: @data

  @doc "Opens (and creates) the file at `path`, with the tables. A reader opens its own."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Reader.open(meta(), path)

  @doc "When `Usage` last read, or `:unread`."
  @spec last_read(db) :: :unread | {:ok, %{read_at: integer}}
  def last_read(db), do: Reader.last_read(meta(), db, [])

  @doc "Every row, with when `Usage` last read; `:unread` before its first read."
  @spec rows(db) :: :unread | {:ok, %{read_at: integer, rows: [map]}}
  def rows(db), do: Reader.rows(meta(), db, [])

  @doc "The rows with these ids; an id whose row was deleted is absent."
  @spec rows_by_id(db, [integer]) :: [map]
  def rows_by_id(db, ids), do: Reader.rows_by_id(meta(), db, ids)

  @doc """
  Applies `changes` and records the read at `at` (ms), in one transaction. Returns each changed
  row as `{account, id}`, and whether this was the first read.
  """
  @spec write(db, [change], integer) :: {:ok, %{ids: [{String.t(), integer}], first: boolean}}
  def write(db, changes, at) do
    [%{keyed: keyed, first: first}] =
      Reader.write(meta(), db, [{[], changes, [one: 1, read_at: at]}])

    {:ok, %{ids: keyed, first: first}}
  end

  defp assumed(rows, opts) do
    now = Keyword.get(opts, :clock, fn -> System.os_time(:second) end).()
    for row <- rows, do: Map.put(row, :assumed, match?({:assumed, _}, Reading.status(row, now)))
  end
end
