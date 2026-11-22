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
  start with no brief. `resume` is the session id a resume (`Mains.resume_main/3`) takes up,
  nil for a start (F-143's new-5), added to an older file if missing.

  A start or resume refused at a usage limit (F-196) is first `waiting` for the soonest reset:
  `account` is empty (none was picked), `until` that reset (wall-clock ms, kept after as the
  reset it waited for), `deadline` the time `Mains` picks again (the reset plus the margin),
  `start` its request as a term, `waited` the person who answered its prompt `wait` for this
  reset, and `tell` the start's sender, owed its outcome until told. A row a person left is
  `refused` with reason `left`.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Mains.Starts.open(path)
      iex> CodingAgentFramework.Mains.Starts.rows(db, "ws")
      []
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host project name account brief_uuid status reason called_at deadline
              created_at updated_at resume until waited start tell)a

  @schema """
  CREATE TABLE IF NOT EXISTS main_starts (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, project TEXT NOT NULL, name TEXT NOT NULL,
    account TEXT NOT NULL, brief_uuid TEXT, status TEXT NOT NULL, reason TEXT,
    called_at INTEGER NOT NULL, deadline INTEGER NOT NULL, created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL, resume TEXT, until INTEGER, waited TEXT, start BLOB, tell TEXT);
  CREATE INDEX IF NOT EXISTS main_starts_status ON main_starts (host, status);
  CREATE INDEX IF NOT EXISTS main_starts_name ON main_starts (host, name);
  """

  # Added after a file's table may have been made (`resume`, F-143; the wait at a limit, F-196).
  @added ["resume TEXT", "until INTEGER", "waited TEXT", "start BLOB", "tell TEXT"]

  @type db :: Store.db()

  @doc "Opens (and creates) the file at `path`, with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema, added: [main_starts: @added])

  @doc "Writes a start's row, as `starting`, and returns it."
  @spec starting(db, map) :: map
  def starting(db, start) do
    now = System.os_time(:millisecond)
    keys = ~w(host project name account brief_uuid deadline resume)a
    first = [status: "starting", called_at: now, created_at: now, updated_at: now]

    [[id]] =
      Store.insert(db, "main_starts", Enum.map(keys, &{&1, start[&1]}) ++ first, "RETURNING id")

    get(db, id)
  end

  @doc """
  Writes a start refused at a usage limit as `waiting` (F-196), for the reset `until`, `Mains`
  picking again at `deadline`, its request `start` kept as a term. Returns it.
  """
  @spec waiting(db, map) :: map
  def waiting(db, start) do
    now = System.os_time(:millisecond)
    keys = ~w(host project name brief_uuid deadline resume until tell)a
    first = [status: "waiting", account: "", called_at: now, created_at: now, updated_at: now]
    blob = {:start, {:blob, :erlang.term_to_binary(start.start)}}
    fields = Enum.map(keys, &{&1, start[&1]}) ++ first ++ [blob]
    [[id]] = Store.insert(db, "main_starts", fields, "RETURNING id")
    get(db, id)
  end

  @doc "The host's rows with `status`, oldest first."
  @spec with_status(db, String.t(), String.t()) :: [map]
  def with_status(db, host, status),
    do: select(db, "host = ?1 AND status = ?2", [host, status])

  @doc "The host's rows whose sender is owed a waited start's outcome (`tell` names it)."
  @spec owed(db, String.t()) :: [map]
  def owed(db, host), do: select(db, "host = ?1 AND tell IS NOT NULL", [host])

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
