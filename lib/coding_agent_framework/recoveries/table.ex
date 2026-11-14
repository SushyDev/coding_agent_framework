defmodule CodingAgentFramework.Recoveries.Table do
  @moduledoc """
  `recoveries`: one row per broken state `CodingAgentFramework.Recoveries` acted on, keyed by
  `{host, server, key}`. The key names the state (`model/tla/Agent.tla`, `RecoveryClaims`), so
  the row is the claim: it is written before the act, and a second claim of one key is refused.

  `Recoveries` is the one writer. Anyone may open the file and read. `status` is `claimed`
  (written, not yet acted on), `opened` (the act ran; the outcome waits for a later sample), or
  one of the ends: `recovered`, `failed` and `unknown`, with `reason`. `open` is the act's
  answer, `ok` when it opened a pane, and `opened_at` when it answered.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Recoveries.Table.open(path)
      iex> state = %{host: "laptop", server: "agents", key: "lost_viewer:alpha:0:7",
      ...>   kind: "lost_viewer", socket: "alpha", generation: 0, since: 7}
      iex> {:ok, _id} = CodingAgentFramework.Recoveries.Table.claim(db, state, 8)
      iex> CodingAgentFramework.Recoveries.Table.claim(db, state, 9)
      {:refused, :claimed}
  """

  alias Exqlite.Sqlite3

  @columns ~w(id host server key kind socket generation since status reason pane open
              claimed_at opened_at ended_at)a
  @claim ~w(host server key kind socket generation since)a

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS recoveries (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, server TEXT NOT NULL, key TEXT NOT NULL,
    kind TEXT NOT NULL, socket TEXT NOT NULL, generation INTEGER, since INTEGER,
    status TEXT NOT NULL, reason TEXT, pane TEXT, open TEXT,
    claimed_at INTEGER NOT NULL, opened_at INTEGER, ended_at INTEGER,
    UNIQUE (host, server, key));
  """

  @type db :: Sqlite3.db()
  @type row :: %{atom => term}

  @doc "Opens (and creates) the file at `path`, with the table. A reader opens its own."
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
  Claims a state at `at`: writes its row as `claimed` and returns its id, or
  `{:refused, :claimed}` when a row of that key exists, whatever its status.
  """
  @spec claim(db, map, integer) :: {:ok, integer} | {:refused, :claimed}
  def claim(db, state, at) do
    names = Enum.join(@claim ++ [:status, :claimed_at], ",")
    values = Enum.map(@claim, &state[&1]) ++ ["claimed", at]
    marks = Enum.map_join(1..length(values), ",", &"?#{&1}")

    case query(
           db,
           "INSERT INTO recoveries (#{names}) VALUES (#{marks}) " <>
             "ON CONFLICT (host, server, key) DO NOTHING RETURNING id",
           values
         ) do
      [[id]] -> {:ok, id}
      [] -> {:refused, :claimed}
    end
  end

  @doc "Sets `fields` (status, reason, pane, open, opened_at, ended_at) on row `id`."
  @spec update(db, integer, keyword) :: :ok
  def update(db, id, fields) do
    sets =
      fields |> Enum.with_index(2) |> Enum.map_join(",", fn {{k, _}, i} -> "#{k} = ?#{i}" end)

    query(db, "UPDATE recoveries SET #{sets} WHERE id = ?1", [id | Enum.map(fields, &dump/1)])
    :ok
  end

  @doc "A `{host, server}`'s rows that have not ended: `claimed` and `opened`."
  @spec open_rows(db, String.t(), String.t()) :: [row]
  def open_rows(db, host, server),
    do: select(db, "host = ?1 AND server = ?2 AND status IN ('claimed','opened')", [host, server])

  @doc """
  Per socket, when the newest open that answered with a pane (`open` is `ok`) answered: a loss
  read after it is a new one.
  """
  @spec last_opened(db, String.t(), String.t()) :: %{String.t() => integer}
  def last_opened(db, host, server) do
    db
    |> query(
      "SELECT socket, MAX(opened_at) FROM recoveries WHERE host = ?1 AND server = ?2 " <>
        "AND open = 'ok' GROUP BY socket",
      [host, server]
    )
    |> Map.new(fn [socket, at] -> {socket, at} end)
  end

  @doc "A `{host, server}`'s rows."
  @spec rows(db, String.t(), String.t()) :: [row]
  def rows(db, host, server), do: select(db, "host = ?1 AND server = ?2", [host, server])

  @doc "The rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, [integer]) :: [row]
  def rows_by_id(_db, []), do: []

  def rows_by_id(db, ids),
    do: select(db, "id IN (#{Enum.map_join(1..length(ids), ",", &"?#{&1}")})", ids)

  defp select(db, where, args) do
    db
    |> query(
      "SELECT #{Enum.join(@columns, ",")} FROM recoveries WHERE #{where} ORDER BY id",
      args
    )
    |> Enum.map(&(@columns |> Enum.zip(&1) |> Map.new()))
  end

  defp dump({_, value}) when is_binary(value) or is_integer(value) or is_nil(value), do: value
  defp dump({_, value}), do: inspect(value)

  # The writer's own statements: an error here is a bug or a broken file, so it raises and the
  # supervisor restarts the writer, which reads its rows again from the file.
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
