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
  alias CodingAgentFramework.Store

  @schema """
  CREATE TABLE IF NOT EXISTS stream_delegates (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, session TEXT NOT NULL, socket TEXT NOT NULL,
    transcript TEXT NOT NULL, fold BLOB NOT NULL, written_at INTEGER NOT NULL,
    UNIQUE (host, session));
  CREATE TABLE IF NOT EXISTS stream_reads (host TEXT PRIMARY KEY, read_at INTEGER NOT NULL);
  """
  @columns ~w(id session socket transcript fold written_at)a

  @type db :: Store.db()

  @doc "Opens (and creates) the file at `path`, with the tables."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema)

  @doc """
  A host's rows and when it was last read; `:unread` before. Each row holds its fold's fields
  beside `id`, `session`, `socket` and `transcript`, the lines' text left out, and
  `load_problems`: what was wrong with the stored fold (`[]` when nothing), as `load/1` says.
  """
  @spec rows(db, String.t()) :: :unread | {:ok, %{read_at: integer, rows: [map]}}
  def rows(db, host) do
    with {:ok, at} <- last_read(db, host) do
      rows = select(db, "host = ?1 ORDER BY id", [host])
      {:ok, %{read_at: at, rows: Enum.map(rows, &to_row/1)}}
    end
  end

  @doc "The rows of `host` with these ids."
  @spec rows_by_id(db, String.t(), [integer]) :: [map]
  def rows_by_id(db, host, ids) do
    db
    |> Store.rows_by_id("stream_delegates", @columns, ids, host: host)
    |> Enum.map(&to_row/1)
  end

  @doc "When `host` was last read, or `:unread`."
  @spec last_read(db, String.t()) :: :unread | {:ok, integer}
  def last_read(db, host) do
    case Store.query(db, "SELECT read_at FROM stream_reads WHERE host = ?1", [host]) do
      [] -> :unread
      [[at]] -> {:ok, at}
    end
  end

  @doc "The writer's own view at its start: each session's socket, transcript and whole fold."
  @spec delegates(db, String.t()) :: %{String.t() => map}
  def delegates(db, host) do
    for row <- select(db, "host = ?1", [host]), into: %{} do
      {fold, _problems} = load(row.fold)
      {row.session, %{socket: row.socket, transcript: row.transcript, fold: fold}}
    end
  end

  @doc """
  Writes each `{session, delegate}` and, when `read_at` is given, records the read, in one
  transaction: an event's handling and its offset are saved together. Returns the ids written.
  """
  @spec write(db, String.t(), [{String.t(), map}], integer | nil) :: [integer]
  def write(db, host, puts, read_at) do
    at = read_at || System.os_time(:millisecond)

    Store.transaction(db, fn ->
      ids =
        Enum.flat_map(puts, fn {session, d} ->
          db
          |> Store.query(
            "INSERT INTO stream_delegates (host, session, socket, transcript, fold, written_at) " <>
              "VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT (host, session) DO UPDATE SET " <>
              "fold = excluded.fold, written_at = excluded.written_at RETURNING id",
            [host, session, d.socket, d.transcript, {:blob, :erlang.term_to_binary(d.fold)}, at]
          )
          |> List.flatten()
        end)

      if read_at,
        do: Store.query(db, "INSERT OR REPLACE INTO stream_reads VALUES (?1, ?2)", [host, at])

      ids
    end)
  end

  # Total, and a row an earlier or later build wrote is never taken for a new one
  # (`Store.load/2`): a message's field this build added is filled too (`Fold.upgrade/1`), so the
  # offset, messages and requests stay.
  defp load(bytes) do
    {fold, problems} = Store.load(bytes, Fold.new())
    {Fold.upgrade(fold), problems}
  end

  defp to_row(row) do
    {fold, problems} = load(row.fold)
    lines = Map.new(fold.lines, fn {k, l} -> {k, Map.delete(l, :line)} end)
    row = row |> Map.delete(:fold) |> Map.put(:load_problems, problems)
    Map.merge(%{fold | lines: lines}, row)
  end

  defp select(db, where, args), do: Store.select(db, "stream_delegates", @columns, where, args)
end
