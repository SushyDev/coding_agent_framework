defmodule CodingAgentFramework.Copies.Table do
  @moduledoc """
  `copies`: one row per copy, keyed by `{host, project, name}`, which `Copies` alone writes. It
  holds the copy's turn (`model/tla/Copy.tla`'s `turn`, durable) and what earlier syncs sent.

  `state` is `free`, or the turn's: `taken`, `syncing` (until the sync's answer), `synced`,
  `starting` (the caller is sending its start), or `cut` (a cut sync's turn, kept until `until`,
  wall-clock ms, when its host side can no longer take the lock). `holder` names the run that
  holds the turn. `sent` is every path a sync may have written into the copy, NUL-separated.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Copies.Table.open(path)
      iex> CodingAgentFramework.Copies.Table.get(db, {"laptop", "p", "w"})
      nil
  """

  alias Exqlite.Sqlite3

  @columns ~w(host project name holder state until sent)a
  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS copies (
    host TEXT NOT NULL, project TEXT NOT NULL, name TEXT NOT NULL, holder TEXT,
    state TEXT NOT NULL, until INTEGER, sent TEXT NOT NULL,
    PRIMARY KEY (host, project, name));
  """

  @type db :: Sqlite3.db()
  @type key :: {String.t(), String.t(), String.t()}

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

  @doc "The row of `key`, or nil."
  @spec get(db, key) :: map | nil
  def get(db, {host, project, name}) do
    sql =
      "SELECT #{Enum.join(@columns, ",")} FROM copies WHERE host=?1 AND project=?2 AND name=?3"

    db |> query(sql, [host, project, name]) |> Enum.map(&row/1) |> List.first()
  end

  @doc "Every row."
  @spec all(db) :: [map]
  def all(db),
    do: db |> query("SELECT #{Enum.join(@columns, ",")} FROM copies", []) |> Enum.map(&row/1)

  @doc "Writes row `key` with `fields` (`holder`, `state`, `until`, `sent`)."
  @spec put(db, key, map) :: :ok
  def put(db, {host, project, name}, fields) do
    query(
      db,
      "INSERT OR REPLACE INTO copies (#{Enum.join(@columns, ",")}) VALUES (?1,?2,?3,?4,?5,?6,?7)",
      [host, project, name, fields[:holder], fields.state, fields[:until], fields[:sent] || ""]
    )

    :ok
  end

  @doc "Removes row `key`."
  @spec delete(db, key) :: :ok
  def delete(db, {host, project, name}) do
    query(db, "DELETE FROM copies WHERE host=?1 AND project=?2 AND name=?3", [host, project, name])

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
