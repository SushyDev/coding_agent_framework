defmodule CodingAgentFramework.TmuxSampler.Table do
  @moduledoc """
  `tmux_samples`: one row per held socket, tagged pane and problem of a `{host, server}`'s last
  good sample (`CodingAgentFramework.TmuxSampler.Join`), keyed by `{host, server, key}`; and
  `tmux_sample_reads`: per `{host, server}`, when the last good sample was taken, its server's
  generation, and the last failed sample, if newer.

  `CodingAgentFramework.TmuxSampler` is the one writer. Anyone may open the file and read: a
  `{host, server}` with no good sample is `:unread`, never an empty list.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.TmuxSampler.Table.open(path)
      iex> CodingAgentFramework.TmuxSampler.Table.rows(db, "laptop", "agents")
      :unread
  """

  alias CodingAgentFramework.TmuxSampler.Join
  alias Exqlite.Sqlite3

  @data Join.columns()
  @columns [:id, :host, :server, :key | @data] ++ [:written_at]
  @reads ~w(read_at up generation start ids failed_at problem)a
  @atoms Map.new(
           ~w(held viewer problem live stale absent unknown viewed unviewed no_server gone malformed)a,
           &{Atom.to_string(&1), &1}
         )

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS tmux_samples (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, server TEXT NOT NULL, key TEXT NOT NULL,
    kind TEXT NOT NULL, name TEXT, pane TEXT, generation INTEGER, socket TEXT,
    status TEXT NOT NULL, panes TEXT, problem TEXT, written_at INTEGER NOT NULL,
    UNIQUE (host, server, key));
  CREATE TABLE IF NOT EXISTS tmux_sample_reads (
    host TEXT NOT NULL, server TEXT NOT NULL, read_at INTEGER, up INTEGER, generation INTEGER,
    start TEXT, ids TEXT, failed_at INTEGER, problem TEXT, PRIMARY KEY (host, server));
  """

  @type db :: Sqlite3.db()
  @type change :: {:put, String.t(), map} | {:delete, String.t()}

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
  The `{host, server}`'s read row: `read_at` (nil before a good sample), `up`, `generation`,
  `start` (the server's), `ids` (the pane numbers it read), and `failed_at` with `problem` when the newest
  sample failed. `nil` before any sample.
  """
  @spec last_read(db, String.t(), String.t()) :: map | nil
  def last_read(db, host, server) do
    sql =
      "SELECT #{Enum.join(@reads, ",")} FROM tmux_sample_reads WHERE host = ?1 AND server = ?2"

    case query(db, sql, [host, server]) do
      [] -> nil
      [values] -> @reads |> Enum.zip(values) |> Map.new(fn {k, v} -> {k, load_read(k, v)} end)
    end
  end

  @doc "The last good sample's rows with its read row; `:unread` before a good sample."
  @spec rows(db, String.t(), String.t()) :: :unread | {:ok, map}
  def rows(db, host, server) do
    case last_read(db, host, server) do
      %{read_at: at} = read when is_integer(at) ->
        sql = "SELECT #{cols()} FROM tmux_samples WHERE host = ?1 AND server = ?2 ORDER BY id"
        {:ok, Map.put(read, :rows, db |> query(sql, [host, server]) |> Enum.map(&to_row/1))}

      _ ->
        :unread
    end
  end

  @doc "The rows with these ids; an id whose row was deleted is absent."
  @spec rows_by_id(db, [integer]) :: [map]
  def rows_by_id(_db, []), do: []

  def rows_by_id(db, ids) do
    marks = Enum.map_join(1..length(ids), ",", &"?#{&1}")

    db
    |> query("SELECT #{cols()} FROM tmux_samples WHERE id IN (#{marks}) ORDER BY id", ids)
    |> Enum.map(&to_row/1)
  end

  @doc """
  Applies `changes` and records a good sample (`%{read_at, up, generation, start, ids}`) in
  one transaction, clearing any failure. Returns the ids put or deleted, and whether this was
  the first good sample.
  """
  @spec write(db, String.t(), String.t(), [change], map) ::
          {:ok, %{ids: [integer], first: boolean}}
  def write(db, host, server, changes, read) do
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")
    first = not is_integer((last_read(db, host, server) || %{})[:read_at])
    ids = Enum.flat_map(changes, &change(db, host, server, read.read_at, &1))

    query(
      db,
      "INSERT OR REPLACE INTO tmux_sample_reads VALUES (?1,?2,?3,?4,?5,?6,?7,NULL,NULL)",
      [
        host,
        server,
        read.read_at,
        if(read.up, do: 1, else: 0),
        read.generation,
        read.start,
        Enum.join(read.ids, ",")
      ]
    )

    :ok = Sqlite3.execute(db, "COMMIT")
    {:ok, %{ids: ids, first: first}}
  end

  @doc "Records a failed sample at `at`; the last good sample and its rows stay."
  @spec failed(db, String.t(), String.t(), integer, term) :: :ok
  def failed(db, host, server, at, problem) do
    query(
      db,
      "INSERT INTO tmux_sample_reads (host, server, failed_at, problem) VALUES (?1,?2,?3,?4) " <>
        "ON CONFLICT (host, server) DO UPDATE SET failed_at = ?3, problem = ?4",
      [host, server, at, inspect(problem)]
    )

    :ok
  end

  defp change(db, host, server, at, {:put, key, row}) do
    names = [:host, :server, :key | @data] ++ [:written_at]
    values = [host, server, key | Enum.map(@data, &dump(row[&1]))] ++ [at]
    marks = Enum.map_join(1..length(names), ",", &"?#{&1}")
    set = Enum.map_join(@data ++ [:written_at], ",", &"#{&1} = excluded.#{&1}")

    db
    |> query(
      "INSERT INTO tmux_samples (#{Enum.join(names, ",")}) VALUES (#{marks}) " <>
        "ON CONFLICT (host, server, key) DO UPDATE SET #{set} RETURNING id",
      values
    )
    |> List.flatten()
  end

  defp change(db, host, server, _at, {:delete, key}) do
    db
    |> query(
      "DELETE FROM tmux_samples WHERE host = ?1 AND server = ?2 AND key = ?3 RETURNING id",
      [host, server, key]
    )
    |> List.flatten()
  end

  defp cols, do: Enum.join(@columns, ",")

  defp to_row(values),
    do: @columns |> Enum.zip(values) |> Map.new(fn {k, v} -> {k, load(k, v)} end)

  defp dump(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp dump(value), do: value

  # Total over what a column holds: a value this writer did not write loads as :unknown.
  defp load(k, text) when k in [:kind, :socket, :status] and is_binary(text),
    do: Map.get(@atoms, text, :unknown)

  defp load(k, nil) when k in [:kind, :socket, :status], do: nil
  defp load(k, _) when k in [:kind, :socket, :status], do: :unknown
  defp load(_, value), do: value

  defp load_read(:up, value), do: value == 1

  defp load_read(:ids, text) when is_binary(text) do
    for n <- String.split(text, ",", trim: true), {id, ""} <- [Integer.parse(n)], do: id
  end

  defp load_read(:ids, _), do: []
  defp load_read(_, value), do: value

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
