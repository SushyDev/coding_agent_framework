defmodule CodingAgentFramework.Mains.Starts do
  @moduledoc """
  `main_starts`: one row per start of a main session that `Mains` makes (`start_main`), keyed
  by its id, which `Mains` alone writes. It is the holder of the start's lease
  (`model/tla/Schedule.tla`'s `work`; F-134's new-1): written `starting` before the lease is
  asked for. The main session itself (its process, its account, its session) is its agent row
  in `Sessions`, read through `Sessions.Agents`.

  `status` is `starting` while the lease or the call of `Sessions` is under way, or a restart
  cut it (`called_at`, in wall-clock ms, tells that call's agent row from an earlier one;
  `deadline` the wall-clock time a cut call is settled by), then `running` or `refused` with
  its `reason`, once. `brief_uuid` is the uuid of the brief's row in `Mailbox`, or nil for a
  start with no brief.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Mains.Starts.open(path)
      iex> CodingAgentFramework.Mains.Starts.rows(db, "ws")
      []
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host project name account brief_uuid status reason called_at deadline
              created_at updated_at)a

  @schema """
  CREATE TABLE IF NOT EXISTS main_starts (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, project TEXT NOT NULL, name TEXT NOT NULL,
    account TEXT NOT NULL, brief_uuid TEXT, status TEXT NOT NULL, reason TEXT,
    called_at INTEGER NOT NULL, deadline INTEGER NOT NULL, created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL);
  CREATE INDEX IF NOT EXISTS main_starts_status ON main_starts (host, status);
  CREATE INDEX IF NOT EXISTS main_starts_name ON main_starts (host, name);
  """

  @type db :: Store.db()

  @doc "Opens (and creates) the file at `path`, with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema)

  @doc "Writes a start's row, as `starting`, and returns it."
  @spec starting(db, map) :: map
  def starting(db, start) do
    now = System.os_time(:millisecond)
    keys = ~w(host project name account brief_uuid deadline)a
    first = [status: "starting", called_at: now, created_at: now, updated_at: now]

    [[id]] =
      Store.insert(db, "main_starts", Enum.map(keys, &{&1, start[&1]}) ++ first, "RETURNING id")

    get(db, id)
  end

  @doc "Sets `fields` on row `id`."
  @spec update(db, integer, keyword) :: :ok
  def update(db, id, fields),
    do: Store.update(db, "main_starts", id, fields ++ [updated_at: System.os_time(:millisecond)])

  @doc "Row `id`, or nil."
  @spec get(db, integer) :: map | nil
  def get(db, id), do: List.first(select(db, "id = ?1", [id]))

  @doc "The host's rows still `starting`, oldest first."
  @spec starting_rows(db, String.t()) :: [map]
  def starting_rows(db, host), do: select(db, "host = ?1 AND status = 'starting'", [host])

  @doc "The latest row of `name` on the host, or nil."
  @spec latest(db, String.t(), String.t()) :: map | nil
  def latest(db, host, name),
    do: List.last(select(db, "host = ?1 AND name = ?2", [host, name]))

  @doc "The host's rows, oldest first."
  @spec rows(db, String.t()) :: [map]
  def rows(db, host), do: select(db, "host = ?1", [host])

  defp select(db, where, args),
    do: Store.select(db, "main_starts", @columns, where <> " ORDER BY id", args)
end
