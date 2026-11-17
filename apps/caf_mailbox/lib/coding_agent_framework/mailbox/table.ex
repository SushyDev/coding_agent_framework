defmodule CodingAgentFramework.Mailbox.Table do
  @moduledoc """
  `messages`: one row per message, keyed by its id, which `Mailbox` alone writes; anyone may
  open the file and read (`model/tla/Team.tla`: `msgs`).

  `status` is `queued`, `sending` (marked before the write, with its `session_id`), then
  `delivered` or `ended`, or `queued` again if it did not go in, under the `uuid` it was stored
  with. `attempt` is why the last delivery did not go in. A delegate's reply names the uuid of
  the message it answers in `reply_to`, with its result's `subtype` and `is_error`; the
  framework's notice that the delegate's process ended before it answered names it too.
  `reply_to` is unique, so one message has one reply or one notice, never both.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Mailbox.Table.open(path)
      iex> CodingAgentFramework.Mailbox.Table.get(db, 1)
      nil
  """

  alias CodingAgentFramework.Store

  @columns ~w(id from_agent to_agent text uuid status session_id attempt reply_to subtype
              is_error created_at updated_at)a

  @schema """
  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL,
    text TEXT NOT NULL, uuid TEXT NOT NULL, status TEXT NOT NULL, session_id TEXT,
    attempt TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
  """

  # Added after a file's table may have been made (F-79, F-81), so each is added if missing.
  @added ["reply_to TEXT", "subtype TEXT", "is_error INTEGER"]
  @reply "CREATE UNIQUE INDEX IF NOT EXISTS messages_reply_to ON messages (reply_to)"

  @type db :: Store.db()

  @doc "Opens (and creates) the file at `path`, with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema, added: [messages: @added], then: @reply)

  @doc "Stores a message as `queued` and returns its id."
  @spec queued(db, String.t(), String.t(), String.t(), String.t()) :: integer
  def queued(db, from, to, text, uuid) do
    sql =
      "INSERT INTO messages (from_agent, to_agent, text, uuid, status, created_at, updated_at)"

    sql = sql <> " VALUES (?1, ?2, ?3, ?4, 'queued', ?5, ?5) RETURNING id"
    [[id]] = Store.query(db, sql, [from, to, text, uuid, System.os_time(:millisecond)])
    id
  end

  @doc """
  Stores a delegate's reply, or the framework's notice, to the message stored under `reply_to`
  as `queued`, and returns its id; or nil, storing nothing, when that message has a reply or a
  notice already. `result` holds a reply's `subtype` and `is_error` (empty for a notice).
  """
  @spec reply(db, String.t(), String.t(), String.t(), String.t(), String.t(), map) ::
          integer | nil
  def reply(db, from, to, text, uuid, reply_to, result \\ %{}) do
    sql =
      "INSERT INTO messages (from_agent, to_agent, text, uuid, status, reply_to, subtype, " <>
        "is_error, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 'queued', ?5, ?6, ?7, ?8, ?8) " <>
        "ON CONFLICT (reply_to) DO NOTHING RETURNING id"

    error = %{true => 1, false => 0}[result[:is_error]]
    args = [from, to, text, uuid, reply_to, result[:subtype], error]

    case Store.query(db, sql, args ++ [System.os_time(:millisecond)]) do
      [[id]] -> id
      [] -> nil
    end
  end

  @doc "Sets `fields` on row `id`."
  @spec update(db, integer, keyword) :: :ok
  def update(db, id, fields) do
    fields = Keyword.put(fields, :updated_at, System.os_time(:millisecond))
    Store.update(db, "messages", id, fields)
  end

  @doc "The rows still `queued` or `sending`, oldest first."
  @spec open_rows(db) :: [map]
  def open_rows(db), do: select(db, "status IN ('queued', 'sending')", [])

  @doc """
  The rows `delivered` into session `session_id` under one of `uuids` that have no reply or
  notice yet, oldest first.
  """
  @spec unanswered(db, String.t(), [String.t()]) :: [map]
  def unanswered(_db, _session_id, []), do: []

  def unanswered(db, session_id, uuids) do
    where =
      "status = 'delivered' AND session_id = ?1 AND " <>
        "uuid IN (#{Store.marks(length(uuids), 2)}) AND NOT EXISTS " <>
        "(SELECT 1 FROM messages a WHERE a.reply_to = messages.uuid)"

    select(db, where, [session_id | uuids])
  end

  @doc "Row `id`, or nil."
  @spec get(db, integer) :: map | nil
  def get(db, id), do: List.first(select(db, "id = ?1", [id]))

  defp select(db, where, args),
    do: Store.select(db, "messages", @columns, where <> " ORDER BY id", args)
end
