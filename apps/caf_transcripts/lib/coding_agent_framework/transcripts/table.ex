defmodule CodingAgentFramework.Transcripts.Table do
  @moduledoc """
  `transcripts_sessions`, one row per transcript a host's `Transcripts` reads, keyed by `{host,
  account, session_id}`, with its fold (`CodingAgentFramework.Transcripts.Fold`) and so its
  offset; and `transcripts_reads`, one row per `{host, account}` read at least once. Its table
  code is `CodingAgentFramework.Reader`'s, from `meta/0`. `Transcripts` is the one writer; any
  process may open the file and read. A `{host, account}` with no read row is `:unread`.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Transcripts.Table.open(path)
      iex> CodingAgentFramework.Transcripts.Table.rows(db, "laptop", "work")
      :unread
  """

  alias CodingAgentFramework.{Reader, Store}
  alias CodingAgentFramework.Transcripts.Fold

  @schema """
  CREATE TABLE IF NOT EXISTS transcripts_sessions (
    id INTEGER PRIMARY KEY,
    host TEXT NOT NULL, account TEXT NOT NULL, session_id TEXT NOT NULL, path TEXT NOT NULL,
    fold BLOB NOT NULL, rewrites INTEGER NOT NULL, problem TEXT, written_at INTEGER NOT NULL,
    UNIQUE (host, account, session_id));
  CREATE TABLE IF NOT EXISTS transcripts_reads (
    host TEXT NOT NULL, account TEXT NOT NULL, read_at INTEGER NOT NULL,
    PRIMARY KEY (host, account));
  """

  @type db :: Store.db()

  @doc """
  The table as `Reader` reads and writes it; a `Tracker` source is made from it. A row as read
  holds its fold's fields beside its own: `offset`, `last_reply`, `ends_with_reply`, `prompts`,
  `subagents`, `usage`, `problems`, `problem_count` and `entries`.
  """
  @spec meta() :: Reader.meta()
  def meta do
    %{
      schema: @schema,
      table: "transcripts_sessions",
      reads: "transcripts_reads",
      scope: [:host, :account],
      key: :session_id,
      data: [:path, :fold, :rewrites, :problem],
      read: [:read_at],
      dump: &dump/2,
      load: &to_row/1,
      topic: "transcripts",
      kind: :transcripts,
      name: :account
    }
  end

  @doc "Opens (and creates) the file at `path`, with the tables."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Reader.open(meta(), path)

  @doc "A `{host, account}`'s rows and when it was last read; `:unread` before its first read."
  @spec rows(db, String.t(), String.t()) :: :unread | {:ok, %{read_at: integer, rows: [map]}}
  def rows(db, host, account), do: Reader.rows(meta(), db, host: host, account: account)

  @doc "The rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, [integer]) :: [map]
  def rows_by_id(db, ids), do: Reader.rows_by_id(meta(), db, ids)

  @doc """
  Writes, per account, each `{session_id, row}` put (`path`, `fold`, `rewrites`, `problem`)
  and records that account's read at `at`, in one transaction. Answers per account, in order,
  the ids written and whether it was the account's first read.
  """
  @spec write(db, String.t(), [{String.t(), [{String.t(), map}]}], integer) :: [map]
  def write(db, host, puts, at) do
    writes =
      for {account, rows} <- puts,
          do:
            {[host: host, account: account], for({sid, row} <- rows, do: {:put, sid, row}),
             [read_at: at]}

    Reader.write(meta(), db, writes)
  end

  @doc """
  The writer's own view of its rows on a host, by `{account, session_id}`: each one's path,
  whole fold (its seam included, which `rows/3` leaves out), rewrites and problem. A writer
  loads them at its start.
  """
  @spec folds(db, String.t()) :: %{{String.t(), String.t()} => map}
  def folds(db, host) do
    columns = [:account, :session_id, :path, :fold, :rewrites, :problem]

    for row <- Store.select(db, "transcripts_sessions", columns, "host = ?1", [host]),
        into: %{} do
      {{row.account, row.session_id},
       %{path: row.path, fold: load_fold(row.fold), rewrites: row.rewrites, problem: row.problem}}
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

  defp dump(:fold, fold), do: {:blob, :erlang.term_to_binary(fold)}
  defp dump(_, value), do: value

  defp to_row(row) do
    fold = load_fold(row.fold)
    Map.merge(Map.delete(row, :fold), Map.drop(fold, [:seam, :message]))
  end
end
