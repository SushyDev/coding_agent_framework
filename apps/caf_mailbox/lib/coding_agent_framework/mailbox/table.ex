defmodule CodingAgentFramework.Mailbox.Table do
  @moduledoc """
  `messages`: one row per delivery, keyed by its id, which `Mailbox` alone writes; anyone may
  open the file and read (`model/tla/Delivery.tla`: `row`).

  `kind` is `msg` (a message, or the app's word), `brief`, `resume` (a resumed delegate's word to
  go on with its brief), `reply`, `notice`, `ask` (an agent's questions to the operator, as
  JSON, kept for the app) or `answer` (the operator's answer to an ask, `reply_to` its uuid). `status` is `queued` (due), `sending` (marked
  before it goes, with its transport `via`, `stream`, `waiter` or `call`, the `session_id` and
  the process `at` it is for), then `delivered` or `ended`, or `queued` again if it did not go
  in, under the `uuid` it was stored with; `again` says it was made due again, so it goes first.
  A `waiter` row keeps `sent_at`, the wall-clock ms its text was handed on (the take bound runs
  from it), and `from_byte`, how much of the session's transcript was read before its mark.
  `attempt` is why the last delivery did not go in. A reply or a notice names the uuid of the
  row it answers in `reply_to` (the report is the reply to the brief's uuid), with a result's
  `subtype` and `is_error`. `reply_to` and `uuid` are unique, so one row has one answer, and a
  row stored twice under one uuid is stored once.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Mailbox.Table.open(path)
      iex> CodingAgentFramework.Mailbox.Table.get(db, 1)
      nil
  """

  alias CodingAgentFramework.Store

  @columns ~w(id from_agent to_agent text uuid status session_id attempt reply_to subtype
              is_error kind via at again sent_at from_byte created_at updated_at)a

  @schema """
  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL,
    text TEXT NOT NULL, uuid TEXT NOT NULL, status TEXT NOT NULL, session_id TEXT,
    attempt TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
  """

  # Added after a file's table may have been made (F-79, F-81, R7), so each is added if missing.
  @added [
    "reply_to TEXT",
    "subtype TEXT",
    "is_error INTEGER",
    "kind TEXT",
    "via TEXT",
    "at INTEGER",
    "again INTEGER NOT NULL DEFAULT 0",
    "sent_at INTEGER",
    "from_byte INTEGER"
  ]
  @indexes """
  CREATE UNIQUE INDEX IF NOT EXISTS messages_reply_to ON messages (reply_to);
  CREATE UNIQUE INDEX IF NOT EXISTS messages_uuid ON messages (uuid);
  """

  @type db :: Store.db()

  @doc """
  Opens (and creates) the file at `path`, with the table. An `attempt` an earlier build stored
  as `inspect` text is converted to `Store.text/1`'s rule.
  """
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path) do
    with {:ok, db} <- Store.open(path, @schema, added: [messages: @added], then: @indexes) do
      Store.convert(db, "messages", [:attempt])
      {:ok, db}
    end
  end

  @doc """
  Stores a row as `queued` and returns its id; or nil, storing nothing, when a row with its
  `uuid`, or an answer with its `reply_to`, is stored already. `row` holds `from`, `to`, `text`,
  `uuid` and `kind`, and may hold `reply_to`, `again` and a result's `subtype` and `is_error`.
  """
  @spec store(db, map) :: integer | nil
  def store(db, row) do
    now = System.os_time(:millisecond)
    error = %{true => 1, false => 0}[row[:is_error]]

    fields = [
      from_agent: row.from,
      to_agent: row.to,
      text: row.text,
      uuid: row.uuid,
      kind: row.kind,
      status: "queued",
      reply_to: row[:reply_to],
      subtype: row[:subtype],
      is_error: error,
      again: if(row[:again], do: 1, else: 0),
      created_at: now,
      updated_at: now
    ]

    case Store.insert(db, "messages", fields, "ON CONFLICT DO NOTHING RETURNING id") do
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

  @doc "The rows still `queued` or `sending`: a row made due again first, then oldest first."
  @spec open_rows(db) :: [map]
  def open_rows(db),
    do: select(db, "status IN ('queued', 'sending') ORDER BY again DESC, id", [])

  @doc """
  The rows `delivered` into session `session_id` under one of `uuids`, of a kind that a turn
  answers (`msg`; a row an earlier build stored has no kind and is one), that have no reply or notice yet, oldest first.
  """
  @spec unanswered(db, String.t(), [String.t()]) :: [map]
  def unanswered(_db, _session_id, []), do: []

  def unanswered(db, session_id, uuids) do
    where =
      "status = 'delivered' AND IFNULL(kind, 'msg') = 'msg' AND session_id = ?1 AND " <>
        "uuid IN (#{Store.marks(length(uuids), 2)}) AND NOT EXISTS " <>
        "(SELECT 1 FROM messages a WHERE a.reply_to = messages.uuid) ORDER BY id"

    select(db, where, [session_id | uuids])
  end

  @doc "The latest brief to `to`, or nil: its sender is `to`'s parent."
  @spec brief(db, String.t()) :: map | nil
  def brief(db, to),
    do: List.last(select(db, "kind = 'brief' AND to_agent = ?1 ORDER BY id", [to]))

  @doc "The answer (a reply or a notice) to the row stored under `uuid`, or nil."
  @spec answer(db, String.t()) :: map | nil
  def answer(db, uuid), do: List.first(select(db, "reply_to = ?1", [uuid]))

  @doc "The asks with no answer yet, oldest first."
  @spec open_asks(db) :: [map]
  def open_asks(db) do
    where =
      "kind = 'ask' AND NOT EXISTS (SELECT 1 FROM messages a WHERE a.reply_to = messages.uuid) " <>
        "ORDER BY id"

    select(db, where, [])
  end

  @doc "The row stored under `uuid`, or nil."
  @spec by_uuid(db, String.t()) :: map | nil
  def by_uuid(db, uuid), do: List.first(select(db, "uuid = ?1", [uuid]))

  @doc "Row `id`, or nil."
  @spec get(db, integer) :: map | nil
  def get(db, id), do: List.first(select(db, "id = ?1", [id]))

  defp select(db, where, args), do: Store.select(db, "messages", @columns, where, args)
end
