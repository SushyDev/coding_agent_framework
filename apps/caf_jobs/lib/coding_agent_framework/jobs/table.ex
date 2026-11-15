defmodule CodingAgentFramework.Jobs.Table do
  @moduledoc """
  `jobs`: one row per job, keyed by its id, which `Jobs` alone writes (`model/tla/Copy.tla`'s
  `row` and `rcode`, durable).

  `state` is `asked`, `starting` (its start is being sent, until `start_until`, wall-clock ms),
  `running`, then the end read from the host: `exited` with its `code`, `timedout`, or `lost`
  (a dead socket with no exit file); or `refused` (nothing ran). `host`, `project` and `name`
  name the copy it runs in; `deadline` is the call's, wall-clock ms. `late` is `owed` once its
  call answered unknown or was cut by a restart, and `told` once its end was handed on.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Jobs.Table.open(path)
      iex> CodingAgentFramework.Jobs.Table.get(db, "j1")
      nil
  """

  alias Exqlite.Sqlite3

  @columns ~w(id host project name state code start_until deadline late)a
  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY, host TEXT NOT NULL, project TEXT NOT NULL, name TEXT NOT NULL,
    state TEXT NOT NULL, code INTEGER, start_until INTEGER, deadline INTEGER,
    late TEXT);
  """

  @type db :: Sqlite3.db()

  @doc "Opens (and creates) the file at `path`, with the table."
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

  @doc "The row of `id`, or nil."
  @spec get(db, String.t()) :: map | nil
  def get(db, id) do
    db
    |> query("SELECT #{Enum.join(@columns, ",")} FROM jobs WHERE id=?1", [id])
    |> Enum.map(&row/1)
    |> List.first()
  end

  @doc "Every row."
  @spec all(db) :: [map]
  def all(db),
    do: db |> query("SELECT #{Enum.join(@columns, ",")} FROM jobs", []) |> Enum.map(&row/1)

  @doc "Writes the row (a map with every column)."
  @spec put(db, map) :: :ok
  def put(db, row) do
    query(
      db,
      "INSERT OR REPLACE INTO jobs (#{Enum.join(@columns, ",")}) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
      Enum.map(@columns, &Map.get(row, &1))
    )

    :ok
  end

  defp row(values), do: @columns |> Enum.zip(values) |> Map.new()

  # The writer's own statements: an error is a bug or a broken file, so it raises and the
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
