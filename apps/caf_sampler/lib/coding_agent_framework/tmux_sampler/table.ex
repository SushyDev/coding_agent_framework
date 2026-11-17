defmodule CodingAgentFramework.TmuxSampler.Table do
  @moduledoc """
  `tmux_samples`: one row per held socket, tagged pane and problem of a `{host, server}`'s last
  good sample (`CodingAgentFramework.TmuxSampler.Join`), keyed by `{host, server, key}`; and
  `tmux_sample_reads`: per `{host, server}`, when the last good sample was taken, its server's
  generation, and the last failed sample, if newer. Its table code is
  `CodingAgentFramework.Reader`'s, from `meta/0`.

  `CodingAgentFramework.TmuxSampler` is the one writer. Anyone may open the file and read: a
  `{host, server}` with no good sample is `:unread`, never an empty list.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.TmuxSampler.Table.open(path)
      iex> CodingAgentFramework.TmuxSampler.Table.rows(db, "laptop", "agents")
      :unread
  """

  alias CodingAgentFramework.{Reader, Store}
  alias CodingAgentFramework.TmuxSampler.Join

  @reads ~w(read_at up generation start ids failed_at problem)a
  @atoms Map.new(
           ~w(held viewer problem live stale absent unknown viewed unviewed no_server gone malformed)a,
           &{Atom.to_string(&1), &1}
         )

  @schema """
  CREATE TABLE IF NOT EXISTS tmux_samples (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, server TEXT NOT NULL, key TEXT NOT NULL,
    kind TEXT NOT NULL, name TEXT, pane TEXT, generation INTEGER, socket TEXT,
    status TEXT NOT NULL, panes TEXT, problem TEXT, written_at INTEGER NOT NULL,
    UNIQUE (host, server, key));
  CREATE TABLE IF NOT EXISTS tmux_sample_reads (
    host TEXT NOT NULL, server TEXT NOT NULL, read_at INTEGER, up INTEGER, generation INTEGER,
    start TEXT, ids TEXT, failed_at INTEGER, problem TEXT, PRIMARY KEY (host, server));
  """

  @type db :: Store.db()
  @type change :: {:put, String.t(), map} | {:delete, String.t()}

  @doc """
  The table as `Reader` reads and writes it. As a `Tracker` source, for one `{host, server}`
  (options `db:`, `host:` and `server:`), its rows are of kind `:viewers` under the scope
  `{host, "tmux:<server>"}`, since a server belongs to no account; when the newest sample failed
  it answers `{:unknown, {:sample_failed, at, problem}}`.
  """
  @spec meta() :: Reader.meta()
  def meta do
    %{
      schema: @schema,
      table: "tmux_samples",
      reads: "tmux_sample_reads",
      scope: [:host, :server],
      key: :key,
      data: Join.columns(),
      read: @reads,
      dump: &dump/2,
      load: &load/1,
      load_read: &load_read/1,
      convert: [{"tmux_samples", [:problem]}, {"tmux_sample_reads", [:problem]}],
      topic: "tmux",
      group: "tmux:",
      kind: :viewers,
      name: :server,
      failed: :sample_failed
    }
  end

  @doc "Opens (and creates) the file at `path`, with the tables. A reader opens its own."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Reader.open(meta(), path)

  @doc """
  The `{host, server}`'s read row: `read_at` (nil before a good sample), `up`, `generation`,
  `start` (the server's), `ids` (the pane numbers it read), and `failed_at` with `problem` when
  the newest sample failed. `nil` before any sample.
  """
  @spec last_read(db, String.t(), String.t()) :: map | nil
  def last_read(db, host, server), do: Reader.read_row(meta(), db, host: host, server: server)

  @doc "The last good sample's rows with its read row; `:unread` before a good sample."
  @spec rows(db, String.t(), String.t()) :: :unread | {:ok, map}
  def rows(db, host, server), do: Reader.rows(meta(), db, host: host, server: server)

  @doc "The rows with these ids; an id whose row was deleted is absent."
  @spec rows_by_id(db, [integer]) :: [map]
  def rows_by_id(db, ids), do: Reader.rows_by_id(meta(), db, ids)

  @doc """
  Applies `changes` and records a good sample (`%{read_at, up, generation, start, ids}`) in
  one transaction, clearing any failure. Returns the ids put or deleted, and whether this was
  the first good sample.
  """
  @spec write(db, String.t(), String.t(), [change], map) ::
          {:ok, %{ids: [integer], first: boolean}}
  def write(db, host, server, changes, read) do
    sample = [
      read_at: read.read_at,
      up: if(read.up, do: 1, else: 0),
      generation: read.generation,
      start: read.start,
      ids: Enum.join(read.ids, ",")
    ]

    [%{ids: ids, first: first}] =
      Reader.write(meta(), db, [{[host: host, server: server], changes, sample}])

    {:ok, %{ids: ids, first: first}}
  end

  @doc "Records a failed sample at `at`; the last good sample and its rows stay."
  @spec failed(db, String.t(), String.t(), integer, term) :: :ok
  def failed(db, host, server, at, problem) do
    Store.query(
      db,
      "INSERT INTO tmux_sample_reads (host, server, failed_at, problem) VALUES (?1,?2,?3,?4) " <>
        "ON CONFLICT (host, server) DO UPDATE SET failed_at = ?3, problem = ?4",
      [host, server, at, Store.text(problem)]
    )

    :ok
  end

  defp dump(_, value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp dump(_, value), do: value

  # Total over what a column holds: a value this writer did not write loads as :unknown.
  defp load(row) do
    Map.new(row, fn
      {k, text} when k in [:kind, :socket, :status] and is_binary(text) ->
        {k, Map.get(@atoms, text, :unknown)}

      {k, nil} when k in [:kind, :socket, :status] ->
        {k, nil}

      {k, _} when k in [:kind, :socket, :status] ->
        {k, :unknown}

      other ->
        other
    end)
  end

  defp load_read(read) do
    ids =
      if is_binary(read.ids),
        do:
          for(
            n <- String.split(read.ids, ",", trim: true),
            {id, ""} <- [Integer.parse(n)],
            do: id
          ),
        else: []

    %{read | up: read.up == 1, ids: ids}
  end
end
