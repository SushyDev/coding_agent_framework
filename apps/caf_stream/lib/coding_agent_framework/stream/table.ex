defmodule CodingAgentFramework.Stream.Table do
  @moduledoc """
  `stream_delegates`, one row per headless delegate a host's `Stream` follows, with its fold
  (`CodingAgentFramework.Stream.Fold`) and so its offset, its message and request rows and its
  lines not yet claimed; and `stream_reads`, one row per host read at least once. `Stream` is
  the one writer; any process may open the file and read.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Stream.Table.open(path)
      iex> CodingAgentFramework.Stream.Table.rows(db, "laptop")
      :unread
  """

  alias CodingAgentFramework.Stream.Fold
  alias Exqlite.Sqlite3

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS stream_delegates (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, session TEXT NOT NULL, socket TEXT NOT NULL,
    transcript TEXT NOT NULL, fold BLOB NOT NULL, written_at INTEGER NOT NULL,
    UNIQUE (host, session));
  CREATE TABLE IF NOT EXISTS stream_reads (host TEXT PRIMARY KEY, read_at INTEGER NOT NULL);
  """
  @columns "id, session, socket, transcript, fold, written_at"

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
  A host's rows and when it was last read; `:unread` before. Each row holds its fold's fields
  beside `id`, `session`, `socket` and `transcript`, the lines' text left out, and
  `load_problems`: what was wrong with the stored fold (`[]` when nothing), as `load/1` says.
  """
  @spec rows(db, String.t()) :: :unread | {:ok, %{read_at: integer, rows: [map]}}
  def rows(db, host) do
    with {:ok, at} <- last_read(db, host) do
      sql = "SELECT #{@columns} FROM stream_delegates WHERE host = ?1 ORDER BY id"
      {:ok, %{read_at: at, rows: db |> query(sql, [host]) |> Enum.map(&to_row/1)}}
    end
  end

  @doc "The rows of `host` with these ids."
  @spec rows_by_id(db, String.t(), [integer]) :: [map]
  def rows_by_id(_db, _host, []), do: []

  def rows_by_id(db, host, ids) do
    marks = Enum.map_join(1..length(ids), ",", &"?#{&1 + 1}")
    sql = "SELECT #{@columns} FROM stream_delegates WHERE host = ?1 AND id IN (#{marks})"
    db |> query(sql, [host | ids]) |> Enum.map(&to_row/1)
  end

  @doc "When `host` was last read, or `:unread`."
  @spec last_read(db, String.t()) :: :unread | {:ok, integer}
  def last_read(db, host) do
    case query(db, "SELECT read_at FROM stream_reads WHERE host = ?1", [host]) do
      [] -> :unread
      [[at]] -> {:ok, at}
    end
  end

  @doc "The writer's own view at its start: each session's socket, transcript and whole fold."
  @spec delegates(db, String.t()) :: %{String.t() => map}
  def delegates(db, host) do
    sql = "SELECT #{@columns} FROM stream_delegates WHERE host = ?1"

    for [_id, session, socket, transcript, fold, _] <- query(db, sql, [host]), into: %{} do
      {fold, _problems} = load(fold)
      {session, %{socket: socket, transcript: transcript, fold: fold}}
    end
  end

  @doc """
  Writes each `{session, delegate}` and, when `read_at` is given, records the read, in one
  transaction: an event's handling and its offset are saved together. Returns the ids written.
  """
  @spec write(db, String.t(), [{String.t(), map}], integer | nil) :: [integer]
  def write(db, host, puts, read_at) do
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
    at = read_at || System.os_time(:millisecond)

    ids =
      Enum.flat_map(puts, fn {session, d} ->
        db
        |> query(
          "INSERT INTO stream_delegates (host, session, socket, transcript, fold, written_at) " <>
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT (host, session) DO UPDATE SET " <>
            "fold = excluded.fold, written_at = excluded.written_at RETURNING id",
          [host, session, d.socket, d.transcript, {:blob, :erlang.term_to_binary(d.fold)}, at]
        )
        |> List.flatten()
      end)

    if read_at, do: query(db, "INSERT OR REPLACE INTO stream_reads VALUES (?1, ?2)", [host, at])
    :ok = Sqlite3.execute(db, "COMMIT")
    ids
  end

  # Total, and a row an earlier or later build wrote is never taken for a new one: a field this
  # build added is filled with its default, so the offset, messages and requests stay; a field
  # it does not know is dropped and named. Only bytes that are not a map, or that `:safe` refuses
  # (an atom this build never saw), load as a new fold.
  defp load(bytes) when is_binary(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      %{} = stored ->
        fresh = Fold.new()
        unknown = Map.keys(stored) -- Map.keys(fresh)
        problems = if unknown == [], do: [], else: [{:unknown_fields, Enum.sort(unknown)}]
        {Map.merge(fresh, Map.take(stored, Map.keys(fresh))), problems}

      _ ->
        {Fold.new(), [:not_a_map]}
    end
  rescue
    ArgumentError -> {Fold.new(), [:unreadable]}
  end

  defp load(_), do: {Fold.new(), [:unreadable]}

  defp to_row([id, session, socket, transcript, fold, written_at]) do
    {fold, problems} = load(fold)
    lines = Map.new(fold.lines, fn {k, l} -> {k, Map.delete(l, :line)} end)

    row = %{
      id: id,
      session: session,
      socket: socket,
      transcript: transcript,
      written_at: written_at,
      load_problems: problems
    }

    Map.merge(%{fold | lines: lines}, row)
  end

  # The writer's own statements: an error is a bug or a broken file, so it raises and the
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
