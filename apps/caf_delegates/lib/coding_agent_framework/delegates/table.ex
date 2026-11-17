defmodule CodingAgentFramework.Delegates.Table do
  @moduledoc """
  `delegates`: one row per start of a delegate, keyed by its id, which `Delegates` alone writes;
  anyone may open the file and read.

  `status` is `starting` and `resuming` while a call of `Sessions` is under way (`called_at`,
  in wall-clock ms, tells that call's `Sessions` row from an earlier one; `deadline` is the
  wall-clock time it is settled by), then `running`, then `finished` or `failed` once, or
  `refused` with its `reason`. A `finished` delegate whose report was delivered is `ended` once
  its process is gone, which frees its parent's cap. `brief_uuid` and `resume_uuid` are the
  uuids of `Mailbox`'s rows of the brief and of the word to go on, chosen before they are
  stored. `report` is `none`, then `held` with its `text` until `Mailbox` takes it, then
  `taken`; how it is delivered is `Mailbox`'s row, the reply to `brief_uuid`. `mark` is no
  longer written (a row an earlier build wrote may hold one). `options` is the delegate's own
  launch options as JSON (`ClaudeCLI.Options.encode/1`), or NULL for none.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Delegates.Table.open(path)
      iex> CodingAgentFramework.Delegates.Table.rows(db, "laptop")
      []
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host parent project branch name account model brief brief_uuid resume_uuid
              session_id status reason resumes report text mark called_at deadline created_at
              updated_at options)a

  @schema """
  CREATE TABLE IF NOT EXISTS delegates (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, parent TEXT NOT NULL, project TEXT NOT NULL,
    branch TEXT NOT NULL, name TEXT NOT NULL, account TEXT NOT NULL, model TEXT NOT NULL,
    brief TEXT NOT NULL, brief_uuid TEXT NOT NULL, resume_uuid TEXT, session_id TEXT,
    status TEXT NOT NULL, reason TEXT, resumes INTEGER NOT NULL, report TEXT NOT NULL,
    text TEXT, mark TEXT, called_at INTEGER NOT NULL, deadline INTEGER NOT NULL,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, options TEXT);
  """
  # The statuses of a delegate that holds its parent's cap: started and not yet ended.
  @active ~w(starting running resuming finished failed)

  @type db :: Store.db()

  @doc "Opens (and creates) the file at `path`, with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema, added: [delegates: ["options TEXT"]])

  @doc "Writes a start's row, as `starting`, and returns its id."
  @spec starting(db, map) :: integer
  def starting(db, start) do
    now = System.os_time(:millisecond)
    keys = ~w(host parent project branch name account model brief brief_uuid deadline options)a
    first = [status: "starting", resumes: 0, report: "none", called_at: now, created_at: now]
    fields = Enum.map(keys, &{&1, start[&1]}) ++ first ++ [updated_at: now]
    [[id]] = Store.insert(db, "delegates", fields, "RETURNING id")
    id
  end

  @doc "Sets `fields` on row `id`."
  @spec update(db, integer, keyword) :: :ok
  def update(db, id, fields) do
    fields = Keyword.put(fields, :updated_at, System.os_time(:millisecond))
    Store.update(db, "delegates", id, fields)
  end

  @doc "The host's rows whose status is one of `statuses`."
  @spec with_status(db, String.t(), [String.t()]) :: [map]
  def with_status(db, host, statuses),
    do:
      select(db, "host = ?1 AND status IN (#{Store.marks(length(statuses), 2)})", [
        host | statuses
      ])

  @doc "How many of `parent`'s delegates hold its cap: started, or starting, and not ended."
  @spec active(db, String.t(), String.t()) :: non_neg_integer
  def active(db, host, parent),
    do:
      length(
        select(
          db,
          "host = ?1 AND parent = ?2 AND status IN (#{Store.marks(length(@active), 3)})",
          [
            host,
            parent | @active
          ]
        )
      )

  @doc "Row `id`, or nil."
  @spec get(db, integer) :: map | nil
  def get(db, id), do: List.first(select(db, "id = ?1", [id]))

  @doc "The host's rows, every status, oldest first: what the `Tracker` reads."
  @spec rows(db, String.t()) :: [map]
  def rows(db, host), do: select(db, "host = ?1", [host])

  @doc "The host's rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, String.t(), [integer]) :: [map]
  def rows_by_id(db, host, ids),
    do: Store.rows_by_id(db, "delegates", @columns, ids, host: host)

  defp select(db, where, args),
    do: Store.select(db, "delegates", @columns, where <> " ORDER BY id", args)
end
