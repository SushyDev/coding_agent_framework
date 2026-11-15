defmodule CodingAgentFramework.Mailbox.Table do
  @moduledoc """
  `messages`: one row per message, keyed by its id, which `Mailbox` alone writes; anyone may
  open the file and read (`model/tla/Team.tla`: `msgs`).

  `status` is `queued`, `sending` (marked before the write, with its `session_id`), then
  `delivered` or `ended`, or `queued` again if it did not go in, under the `uuid` it was stored
  with. `attempt` is why the last delivery did not go in.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Mailbox.Table.open(path)
      iex> CodingAgentFramework.Mailbox.Table.get(db, 1)
      nil
  """

  alias Exqlite.Sqlite3

  @columns ~w(id from_agent to_agent text uuid status session_id attempt created_at
              updated_at)a

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL,
    text TEXT NOT NULL, uuid TEXT NOT NULL, status TEXT NOT NULL, session_id TEXT,
    attempt TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
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

  @doc "Stores a message as `queued` and returns its id."
  @spec queued(db, String.t(), String.t(), String.t(), String.t()) :: integer
  def queued(db, from, to, text, uuid) do
    sql =
      "INSERT INTO messages (from_agent, to_agent, text, uuid, status, created_at, updated_at)"

    sql = sql <> " VALUES (?1, ?2, ?3, ?4, 'queued', ?5, ?5) RETURNING id"
    [[id]] = query(db, sql, [from, to, text, uuid, System.os_time(:millisecond)])
    id
  end

  @doc "Sets `fields` on row `id`."
  @spec update(db, integer, keyword) :: :ok
  def update(db, id, fields) do
    fields = Keyword.put(fields, :updated_at, System.os_time(:millisecond))

    sets =
      fields |> Enum.with_index(2) |> Enum.map_join(",", fn {{k, _}, i} -> "#{k} = ?#{i}" end)

    query(db, "UPDATE messages SET #{sets} WHERE id = ?1", [id | Enum.map(fields, &dump/1)])
    :ok
  end

  @doc "The rows still `queued` or `sending`, oldest first."
  @spec open_rows(db) :: [map]
  def open_rows(db), do: select(db, "status IN ('queued', 'sending')", [])

  @doc "Row `id`, or nil."
  @spec get(db, integer) :: map | nil
  def get(db, id), do: List.first(select(db, "id = ?1", [id]))

  defp select(db, where, args) do
    sql = "SELECT #{Enum.join(@columns, ",")} FROM messages WHERE #{where} ORDER BY id"
    db |> query(sql, args) |> Enum.map(&(@columns |> Enum.zip(&1) |> Map.new()))
  end

  defp dump({_, v}) when is_binary(v) or is_integer(v) or is_nil(v), do: v
  defp dump({_, v}), do: inspect(v)

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
