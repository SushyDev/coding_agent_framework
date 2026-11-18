defmodule CodingAgentFramework.Jobs.Table do
  @moduledoc """
  `jobs`: one row per job, keyed by its id, which `Jobs` alone writes (`model/tla/Copy.tla`'s
  `row` and `rcode`, durable).

  `state` is `asked`, `starting` (its start is being sent, until `start_until`, wall-clock ms),
  `running`, then the end read from the host: `exited` with its `code`, `timedout`, or `lost`
  (a dead socket with no exit file); or `refused` (nothing ran), or `interrupted` (a restart, or
  the end of its caller, left it `asked`: nothing was sent). `worktree` is the path its fetch
  writes into. `lease` is the id of the `Scheduler`'s lease it runs under (its fencing token),
  if it asked for one. A job its lease refused is `refused` with `reason` (`queue_full`,
  `deadline`, `pressure`, `allowance`, or the framework's own, such as `scheduler_ended`) and
  `retry_at` (wall-clock ms): not a failed run, and when to ask again, under a new id. `host`, `project` and `name`
  name the copy it runs in; `deadline` is the call's, wall-clock ms. `late` is `owed` once its
  call answered unknown or was cut by a restart, and `told` once its end was handed on.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Jobs.Table.open(path)
      iex> CodingAgentFramework.Jobs.Table.get(db, "j1")
      nil
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host project name state code start_until deadline late worktree lease reason
              retry_at)a
  # A file made before a column gains it; a newer file already has it.
  @added ["worktree TEXT", "lease INTEGER", "reason TEXT", "retry_at INTEGER"]
  @schema """
  CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY, host TEXT NOT NULL, project TEXT NOT NULL, name TEXT NOT NULL,
    state TEXT NOT NULL, code INTEGER, start_until INTEGER, deadline INTEGER,
    late TEXT);
  """

  @type db :: Store.db()

  @doc "Opens (and creates) the file at `path`, with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema, added: [jobs: @added])

  @doc "The row of `id`, or nil."
  @spec get(db, String.t()) :: map | nil
  def get(db, id), do: List.first(Store.select(db, "jobs", @columns, "id=?1", [id]))

  @doc "Every row."
  @spec all(db) :: [map]
  def all(db), do: Store.select(db, "jobs", @columns, "1 = 1", [])

  @doc "Writes the row (a map with every column)."
  @spec put(db, map) :: :ok
  def put(db, row), do: Store.upsert(db, "jobs", Enum.map(@columns, &{&1, Map.get(row, &1)}))
end
