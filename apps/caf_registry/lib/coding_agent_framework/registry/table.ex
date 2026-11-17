defmodule CodingAgentFramework.Registry.Table do
  @moduledoc """
  The framework's first tables, in one SQLite file the caller names: `registry_sessions`, one
  row per session file of a `{host, account}`, and `registry_reads`, one row per `{host,
  account}` that has been read at least once. Its table code is `CodingAgentFramework.Reader`'s,
  from `meta/0`.

  `CodingAgentFramework.Registry` is the one writer. Anyone may open the file and read: a
  `{host, account}` with no read row is `:unread`, never an empty list.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Registry.Table.open(path)
      iex> CodingAgentFramework.Registry.Table.rows(db, "laptop", "work")
      :unread
  """

  alias CodingAgentFramework.Reader

  @data ~w(pid session_id cwd name name_source status version kind entrypoint proc_start
           started_at status_updated_at updated_at extra problem alive)a

  @schema """
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

  @type db :: CodingAgentFramework.Store.db()
  @type row :: %{atom => term}
  @type change :: {:put, file :: String.t(), row} | {:delete, file :: String.t()}

  @doc "The table as `Reader` reads and writes it; a `Tracker` source is made from it."
  @spec meta() :: Reader.meta()
  def meta do
    %{
      schema: @schema,
      table: "registry_sessions",
      reads: "registry_reads",
      scope: [:host, :account],
      key: :file,
      data: @data,
      read: [:read_at, :files, :problems],
      dump: &dump/2,
      load: &load/1,
      topic: "registry",
      kind: :sessions,
      name: :account
    }
  end

  @doc "The columns a row's data is compared and written by."
  @spec data_columns() :: [atom]
  def data_columns, do: @data

  @doc "Opens (and creates) the file at `path`, with the tables. A reader opens its own."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Reader.open(meta(), path)

  @doc """
  A `{host, account}`'s rows, with when it was last read and what that read counted; `:unread`
  before its first read.
  """
  @spec rows(db, String.t(), String.t()) :: :unread | {:ok, map}
  def rows(db, host, account), do: Reader.rows(meta(), db, host: host, account: account)

  @doc "When a `{host, account}` was last read and what that read counted; `:unread` before."
  @spec last_read(db, String.t(), String.t()) :: :unread | {:ok, map}
  def last_read(db, host, account), do: Reader.last_read(meta(), db, host: host, account: account)

  @doc "The rows with these ids; an id whose row was deleted is absent."
  @spec rows_by_id(db, [integer]) :: [row]
  def rows_by_id(db, ids), do: Reader.rows_by_id(meta(), db, ids)

  @doc """
  Applies `changes` and records the read, in one transaction. Returns the ids of the rows put
  or deleted, and whether this was the `{host, account}`'s first read.
  """
  @spec write(db, String.t(), String.t(), [change], map) ::
          {:ok, %{ids: [integer], first: boolean}}
  def write(db, host, account, changes, read) do
    [%{ids: ids, first: first}] =
      Reader.write(meta(), db, [{[host: host, account: account], changes, Map.to_list(read)}])

    {:ok, %{ids: ids, first: first}}
  end

  defp dump(:extra, map), do: JSON.encode!(map || %{})
  defp dump(:alive, alive), do: Atom.to_string(alive)
  defp dump(_, value), do: value

  # Total over what a column holds: a value this writer did not write (a broken file, an older
  # or other writer) loads as nil or :unknown, so one such row never stops a read of the others.
  defp load(row), do: %{row | extra: load_extra(row.extra), alive: load_alive(row.alive)}

  defp load_extra(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp load_extra(_), do: nil

  defp load_alive(text) when text in ~w(live replaced gone unknown), do: String.to_atom(text)
  defp load_alive(_), do: :unknown
end
