defmodule CodingAgentFramework.Sessions.Table do
  @moduledoc """
  `held_sessions`: one row per session `CodingAgentFramework.Sessions` started on a host, keyed
  by `{host, name}`. The name is the session's name, its tmux session's and its dtach socket's.

  `Sessions` is the one writer. Anyone may open the file and read. `status` is one of
  `starting`, `running`, `stopping`, `stopped`, `refused`, `unknown` and `orphan` (a live socket
  with no session file past the start's deadline, or a dead socket whose file names a live
  process, `unheld`, for `Recoveries`); `reason` says why a row is refused, unknown or orphan,
  or why a stop is late (`no_exit`) or not done at its deadline though its process is gone
  (`socket_live`). `deadline` is the current start's
  or stop's deadline in wall-clock milliseconds, so a restart does not move it. A start in a
  worktree keeps its project's `repo` and its `branch`, with `cwd` the worktree's path, and
  `worktree` says what the start did with it (`added`, `reused`) and, after a restart, whether
  it was `removed` or why it was kept. `options` is the agent's own launch options as JSON
  (`ClaudeCLI.Options.encode/1`), or NULL for none.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Sessions.Table.open(path)
      iex> CodingAgentFramework.Sessions.Table.get(db, "laptop", "alpha")
      nil
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host name socket account role cwd resume status reason viewer pid session_id
              proc_start started_at updated_at deadline repo branch worktree options)a

  @schema """
  CREATE TABLE IF NOT EXISTS held_sessions (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, name TEXT NOT NULL, socket TEXT NOT NULL,
    account TEXT NOT NULL, role TEXT NOT NULL, cwd TEXT NOT NULL, resume TEXT,
    status TEXT NOT NULL, reason TEXT, viewer TEXT, pid INTEGER, session_id TEXT,
    proc_start TEXT, started_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    deadline INTEGER, repo TEXT, branch TEXT, worktree TEXT, options TEXT, UNIQUE (host, name));
  """

  # A file made before a column gains it; a newer file already has it.
  @added ["deadline INTEGER", "repo TEXT", "branch TEXT", "worktree TEXT", "options TEXT"]
  # The statuses whose process may live: such a row holds its name and its cwd.
  @ended ~w(stopped refused)

  @type db :: Store.db()
  @type row :: %{atom => term}

  @doc "Opens (and creates) the file at `path`, with the table. A reader opens its own."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema, added: [held_sessions: @added])

  @doc """
  Writes a new start of `{host, name}` as `starting`, over any row it had before, and returns
  its id. The caller has checked that the old row, if any, has ended. `start` holds `deadline`,
  and a headless delegate's `session_id`, which the framework chose; an interactive session's is
  nil until its session file names it.
  """
  @spec starting(db, map) :: integer
  def starting(db, %{} = start) do
    now = System.os_time(:millisecond)
    keys = ~w(host name socket account role cwd resume session_id deadline repo branch options)a

    fields =
      Enum.map(keys, &{&1, start[&1]}) ++ [status: "starting", started_at: now, updated_at: now]

    reset = "reason = NULL, viewer = NULL, pid = NULL, proc_start = NULL, worktree = NULL"

    sets =
      Enum.map_join(keys -- [:host, :name], ",", &"#{&1} = excluded.#{&1}") <>
        ", status = 'starting', started_at = excluded.started_at, " <>
        "updated_at = excluded.updated_at, " <> reset

    [[id]] =
      Store.insert(
        db,
        "held_sessions",
        fields,
        "ON CONFLICT (host, name) DO UPDATE SET #{sets} RETURNING id"
      )

    id
  end

  @doc """
  Sets `fields` (status, reason, viewer, pid, session_id, proc_start, deadline, worktree) on row
  `id`.
  """
  @spec update(db, integer, keyword) :: :ok
  def update(db, id, fields) do
    fields = Keyword.put(fields, :updated_at, System.os_time(:millisecond))
    Store.update(db, "held_sessions", id, Enum.map(fields, &dump/1))
  end

  @doc "The row of `{host, name}`, or nil."
  @spec get(db, String.t(), String.t()) :: row | nil
  def get(db, host, name) do
    case select(db, "host = ?1 AND name = ?2", [host, name]) do
      [row] -> row
      [] -> nil
    end
  end

  @doc "The host's rows whose status is `status`."
  @spec with_status(db, String.t(), String.t()) :: [row]
  def with_status(db, host, status),
    do: select(db, "host = ?1 AND status = ?2", [host, status])

  @doc "The host's rows other than `name`'s whose `cwd` is `cwd` and whose process may live."
  @spec holding(db, String.t(), String.t(), String.t()) :: [row]
  def holding(db, host, cwd, name) do
    select(db, "host = ?1 AND cwd = ?2 AND name != ?3 AND status NOT IN (?4, ?5)", [
      host,
      cwd,
      name | @ended
    ])
  end

  @doc "A `{host, account}`'s rows."
  @spec rows(db, String.t(), String.t()) :: [row]
  def rows(db, host, account), do: select(db, "host = ?1 AND account = ?2", [host, account])

  @doc "The rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, [integer]) :: [row]
  def rows_by_id(db, ids), do: Store.rows_by_id(db, "held_sessions", @columns, ids)

  defp select(db, where, args),
    do: Store.select(db, "held_sessions", @columns, where <> " ORDER BY id", args)

  # A status or a reason given as an atom is stored as its name; `Store` stores any other term
  # as its inspect text.
  defp dump({k, v}) when is_atom(v) and not is_nil(v), do: {k, Atom.to_string(v)}
  defp dump(field), do: field
end
