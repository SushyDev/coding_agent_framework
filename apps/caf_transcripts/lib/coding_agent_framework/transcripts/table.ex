defmodule CodingAgentFramework.Transcripts.Table do
  @moduledoc """
  `transcripts_sessions`, one row per transcript a `{host, account}`'s `Transcripts` reads, with
  its fold (`CodingAgentFramework.Transcripts.Fold`) and so its offset; and `transcripts_reads`,
  one row per `{host, account}` read at least once. `Transcripts` is the one writer; any process
  may open the file and read. A `{host, account}` with no read row is `:unread`.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Transcripts.Table.open(path)
      iex> CodingAgentFramework.Transcripts.Table.rows(db, "laptop", "work")
      :unread
  """

  alias CodingAgentFramework.Transcripts.Fold
  alias Exqlite.Sqlite3

  @columns ~w(id host account session_id path fold rewrites problem written_at)a

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS transcripts_sessions (
    id INTEGER PRIMARY KEY,
    host TEXT NOT NULL, account TEXT NOT NULL, session_id TEXT NOT NULL, path TEXT NOT NULL,
    fold BLOB NOT NULL, rewrites INTEGER NOT NULL, problem TEXT, written_at INTEGER NOT NULL,
    UNIQUE (host, account, session_id));
  CREATE TABLE IF NOT EXISTS transcripts_reads (
    host TEXT NOT NULL, account TEXT NOT NULL, read_at INTEGER NOT NULL,
    PRIMARY KEY (host, account));
  """

  @type db :: Sqlite3.db()

  @doc "Opens (and creates) the file at `path`, with the tables."
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
  A `{host, account}`'s rows and when it was last read; `:unread` before its first read. Each
  row holds its fold's fields beside its own: `offset`, `last_reply`, `ends_with_reply`,
  `prompts`, `subagents`, `usage`, `problems`, `problem_count` and `entries`.
  """
  @spec rows(db, String.t(), String.t()) :: :unread | {:ok, %{read_at: integer, rows: [map]}}
  def rows(db, host, account) do
    with {:ok, at} <- last_read(db, host, account) do
      sql =
        "SELECT #{cols()} FROM transcripts_sessions WHERE host = ?1 AND account = ?2 ORDER BY id"

      {:ok, %{read_at: at, rows: db |> query(sql, [host, account]) |> Enum.map(&to_row/1)}}
    end
  end

  @doc "When a `{host, account}` was last read, or `:unread`."
  @spec last_read(db, String.t(), String.t()) :: :unread | {:ok, integer}
  def last_read(db, host, account) do
    sql = "SELECT read_at FROM transcripts_reads WHERE host = ?1 AND account = ?2"

    case query(db, sql, [host, account]) do
      [] -> :unread
      [[at]] -> {:ok, at}
    end
  end

  @doc "The rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, [integer]) :: [map]
  def rows_by_id(_db, []), do: []

  def rows_by_id(db, ids) do
    marks = Enum.map_join(1..length(ids), ",", &"?#{&1}")

    db
    |> query("SELECT #{cols()} FROM transcripts_sessions WHERE id IN (#{marks}) ORDER BY id", ids)
    |> Enum.map(&to_row/1)
  end

  @doc """
  Writes each `{session_id, path, fold, rewrites, problem}` and records the read, in one
  transaction. Returns the ids written and whether this was the `{host, account}`'s first read.
  """
  @spec write(db, String.t(), String.t(), [tuple], integer) ::
          {:ok, %{ids: [integer], first: boolean}}
  def write(db, host, account, puts, at) do
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
    first = last_read(db, host, account) == :unread

    ids =
      Enum.flat_map(puts, fn {session_id, path, fold, rewrites, problem} ->
        db
        |> query(
          "INSERT INTO transcripts_sessions (host, account, session_id, path, fold, rewrites, " <>
            "problem, written_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) " <>
            "ON CONFLICT (host, account, session_id) DO UPDATE SET path = excluded.path, " <>
            "fold = excluded.fold, rewrites = excluded.rewrites, problem = excluded.problem, " <>
            "written_at = excluded.written_at RETURNING id",
          [host, account, session_id, path, {:blob, :erlang.term_to_binary(fold)}, rewrites] ++
            [problem, at]
        )
        |> List.flatten()
      end)

    query(db, "INSERT OR REPLACE INTO transcripts_reads VALUES (?1, ?2, ?3)", [host, account, at])
    :ok = Sqlite3.execute(db, "COMMIT")
    {:ok, %{ids: ids, first: first}}
  end

  @doc """
  The writer's own view of its rows, by session id: each one's path, whole fold (its seam
  included, which `rows/3` leaves out), rewrites and problem. A writer loads them at its start.
  """
  @spec folds(db, String.t(), String.t()) :: %{String.t() => map}
  def folds(db, host, account) do
    sql =
      "SELECT session_id, path, fold, rewrites, problem FROM transcripts_sessions " <>
        "WHERE host = ?1 AND account = ?2"

    for [sid, path, fold, rewrites, problem] <- query(db, sql, [host, account]), into: %{} do
      {sid, %{path: path, fold: load_fold(fold), rewrites: rewrites, problem: problem}}
    end
  end

  @doc """
  A stored fold, or a new one when the bytes are not a fold this writer wrote: total, so a
  broken row is read again from its file's start rather than stopping a read.
  """
  @spec load_fold(term) :: Fold.t()
  def load_fold(bytes) when is_binary(bytes) do
    fresh = Fold.new()

    case :erlang.binary_to_term(bytes, [:safe]) do
      %{} = fold -> if Map.keys(fold) == Map.keys(fresh), do: fold, else: fresh
      _ -> fresh
    end
  rescue
    ArgumentError -> Fold.new()
  end

  def load_fold(_), do: Fold.new()

  defp cols, do: Enum.join(@columns, ",")

  defp to_row(values) do
    row = @columns |> Enum.zip(values) |> Map.new()
    fold = load_fold(row.fold)
    Map.merge(Map.delete(row, :fold), Map.drop(fold, [:seam, :message]))
  end

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
