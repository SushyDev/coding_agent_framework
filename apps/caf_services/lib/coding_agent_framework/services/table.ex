defmodule CodingAgentFramework.Services.Table do
  @moduledoc """
  `services`: one row per service, keyed by its name, which `Services` alone writes
  (`model/tla/Copy.tla`'s `row`, `owner`, `keep` and `svcRestarts`, durable).

  `state` is `asked`, `starting` (its start is being sent, until `start_until`, wall-clock ms),
  `running`, `ending` (its end written before it is sent), then `ended`; or `refused` (nothing
  runs). `host`, `project` and `copy` name the copy it runs in, `worktree`
  the worktree each start syncs from, and `argv` and `env` what each start holds. `pid` and
  `started` are the held process (its pid and its start time as `ps -o lstart=` gives it, in
  the C locale and UTC); `restarts` counts its restarts; `owner` is the agent that owns it,
  none once ended; `keep` hands it to the owner's parent when the owner ends.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Services.Table.open(path)
      iex> CodingAgentFramework.Services.Table.get(db, "web")
      nil
  """

  alias Exqlite.Sqlite3

  @columns ~w(name host project copy worktree argv env owner keep pid started restarts state
              start_until)a
  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS services (
    name TEXT PRIMARY KEY, host TEXT NOT NULL, project TEXT NOT NULL, copy TEXT NOT NULL,
    worktree TEXT NOT NULL, argv TEXT NOT NULL, env TEXT NOT NULL, owner TEXT,
    keep INTEGER NOT NULL, pid INTEGER, started TEXT, restarts INTEGER NOT NULL,
    state TEXT NOT NULL, start_until INTEGER);
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

  @doc "The row of `name`, or nil."
  @spec get(db, String.t()) :: map | nil
  def get(db, name) do
    db
    |> query("SELECT #{Enum.join(@columns, ",")} FROM services WHERE name=?1", [name])
    |> Enum.map(&row/1)
    |> List.first()
  end

  @doc "Every row."
  @spec all(db) :: [map]
  def all(db),
    do: db |> query("SELECT #{Enum.join(@columns, ",")} FROM services", []) |> Enum.map(&row/1)

  @doc "Writes the row (a map with every column)."
  @spec put(db, map) :: :ok
  def put(db, row) do
    marks = Enum.map_join(1..length(@columns), ",", &"?#{&1}")

    stored = %{
      row
      | argv: encode(row.argv),
        env: encode(row.env),
        keep: if(row.keep, do: 1, else: 0)
    }

    sql = "INSERT OR REPLACE INTO services (#{Enum.join(@columns, ",")}) VALUES (#{marks})"
    query(db, sql, Enum.map(@columns, &Map.get(stored, &1)))
    :ok
  end

  # argv and env are lists of strings and pairs, kept as one text each.
  defp encode(term), do: term |> :erlang.term_to_binary() |> Base.encode64()
  defp decode(text), do: text |> Base.decode64!() |> :erlang.binary_to_term([:safe])

  defp row(values) do
    row = @columns |> Enum.zip(values) |> Map.new()
    %{row | argv: decode(row.argv), env: decode(row.env), keep: row.keep == 1}
  end

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
