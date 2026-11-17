defmodule CodingAgentFramework.Sessions.Table do
  @moduledoc """
  `agents`: the agent row, one per agent on a host, a main session or a delegate, keyed by
  `{host, name}` (`docs/design.md`, "The parts"). The name is the session's name, its tmux
  session's and its dtach socket's.

  `Sessions` is the one writer. Other parts read the rows only through
  `CodingAgentFramework.Sessions.Agents`, which answers what a status means, so no part outside
  `Sessions` names one.

  `kind` is `main` or `delegate`, the agent's place in the tree; `parent` is a delegate's main
  session (nil for a main session); `project` the project it works on. `role` is how it runs
  (`parent`, Claude Code's terminal interface, or `delegate`, headless). `status` is one of
  `statuses/0`: `declared` (a main session the embedding app named, with no process yet),
  `starting`, `running`, `stopping`, `stopped`, `refused`, `unknown`, `orphan` (a live socket
  with no session file past the start's deadline, or a dead socket whose file names a live
  process, `unheld`, for `Recoveries`) and `ended` (a delegate done for good: its report went in
  and no process of it runs again). `reason` says why a row is refused, unknown or orphan, or
  why a stop is late (`no_exit`) or not done at its deadline though its process is gone
  (`socket_live`). `deadline` is the current start's or stop's deadline in wall-clock
  milliseconds, so a restart does not move it. A start in a worktree keeps its project's `repo`
  and its `branch`, with `cwd` the worktree's path, and `worktree` says what the start did with
  it (`added`, `reused`) and, after a restart, whether it was `removed` or why it was kept.
  `options` is the agent's own launch options as JSON (`ClaudeCLI.Options.encode/1`), or NULL
  for none. `release` is the Claude Code release an interactive start launched, as its
  `--version` reads, or NULL when it was not read.

  **A move** (F-133, `Mover`): `move` is the move's phase (`draining`, `stopping`, `copying`,
  `resuming`), NULL when no move is under way; `move_from` and `move_to` the accounts it goes
  between, `move_act` its row in `Acts`, and `move_deadline` (wall-clock ms) when a move not yet
  past its stop is given up. A start writes none of them, so a move's resume keeps them.

  **Migration** (F-129): a file an earlier build made has `held_sessions`, with no kind, parent
  or project. `open/1` takes its rows into `agents`, ids kept, each of kind `delegate` when it
  ran as one and `main` otherwise, then drops it, in one transaction, so a second open takes
  nothing. A delegate's parent and project come from `Delegates`, which hands them over
  (`Sessions.adopt_tree/3`).

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Sessions.Table.open(path)
      iex> CodingAgentFramework.Sessions.Table.get(db, "laptop", "alpha")
      nil
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host name kind parent project socket account role cwd resume status reason
              viewer pid session_id proc_start started_at updated_at deadline repo branch
              worktree options release move move_from move_to move_act move_deadline)a

  @schema """
  CREATE TABLE IF NOT EXISTS agents (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
    parent TEXT, project TEXT, socket TEXT NOT NULL, account TEXT, role TEXT, cwd TEXT,
    resume TEXT, status TEXT NOT NULL, reason TEXT, viewer TEXT, pid INTEGER, session_id TEXT,
    proc_start TEXT, started_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deadline INTEGER,
    repo TEXT, branch TEXT, worktree TEXT, options TEXT, release TEXT, move TEXT,
    move_from TEXT, move_to TEXT, move_act INTEGER, move_deadline INTEGER, UNIQUE (host, name));
  """

  # The columns a later build added to `agents`, so added if missing: the release a session
  # runs (R8), and a move's phase on the row (F-133).
  @added [
    agents: [
      "release TEXT",
      "move TEXT",
      "move_from TEXT",
      "move_to TEXT",
      "move_act INTEGER",
      "move_deadline INTEGER"
    ]
  ]

  # The columns an earlier build added to `held_sessions`; a file older still lacks them.
  @held_added ["deadline INTEGER", "repo TEXT", "branch TEXT", "worktree TEXT", "options TEXT"]

  # Every status, once. The lists below are this part's only readings of a status, and each is
  # checked against this one when the module compiles: a status renamed here and not there
  # fails the build here, not a read in another part at run time.
  @statuses ~w(declared starting running stopping stopped refused unknown orphan ended)
  # No process of the row may live, so its name and its cwd are free for a new start.
  @free ~w(declared stopped refused ended)
  # No process of the row will run again: its start was refused, or it ended.
  @done ~w(refused ended)

  for {list, name} <- [{@free, :free}, {@done, :done}], status <- list do
    unless status in @statuses,
      do: raise(CompileError, description: "#{name} names #{status}, not a status of agents")
  end

  @type db :: Store.db()
  @type row :: %{atom => term}

  @doc "Every status of the agent row."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The statuses whose row no process may hold: its name may start again."
  @spec free() :: [String.t()]
  def free, do: @free

  @doc "The statuses of a row no process of which will run again."
  @spec done() :: [String.t()]
  def done, do: @done

  @doc """
  The table's metadata for `CodingAgentFramework.Reader`'s `Tracker` source: a writer's table,
  read now; topic `sessions:<host>`, scope `{host, "agents"}`, rows of kind `:agents`.
  """
  @spec meta() :: map
  def meta do
    %{
      schema: @schema,
      table: "agents",
      reads: nil,
      columns: @columns,
      scope: [],
      filter: [:host],
      topic: "sessions",
      group: "agents",
      kind: :agents,
      name: nil
    }
  end

  @doc """
  Opens (and creates) the file at `path`, with the table, and takes the rows of an earlier
  build's `held_sessions` (see the module doc). Only `Sessions` opens it so; a reader opens it
  with `open_read/1`.
  """
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path) do
    with {:ok, db} <- Store.open(path, @schema, added: @added) do
      migrate(db)
      Store.convert(db, "agents", [:reason, :viewer])
      {:ok, db}
    end
  end

  @doc "Opens the file at `path` to read: the table is made if absent, and nothing is taken."
  @spec open_read(String.t()) :: {:ok, db} | {:refused, term}
  def open_read(path), do: Store.open(path, @schema, added: @added)

  defp migrate(db) do
    if Store.query(db, "SELECT 1 FROM sqlite_master WHERE name = 'held_sessions'", []) != [] do
      for column <- @held_added, do: add(db, column)

      old =
        @columns --
          ([:kind, :parent, :project, :release] ++
             [:move, :move_from, :move_to, :move_act, :move_deadline])

      Store.transaction(db, fn ->
        Store.query(
          db,
          "INSERT OR IGNORE INTO agents (#{Enum.join([:kind | old], ",")}) " <>
            "SELECT CASE role WHEN 'delegate' THEN 'delegate' ELSE 'main' END, " <>
            "#{Enum.join(old, ",")} FROM held_sessions",
          []
        )

        Store.query(db, "DROP TABLE held_sessions", [])
      end)
    end

    :ok
  end

  defp add(db, column) do
    Store.query(db, "ALTER TABLE held_sessions ADD COLUMN #{column}", [])
  rescue
    _duplicate -> :ok
  end

  @doc """
  Writes a new start of `{host, name}` as `starting`, over any row it had before, and returns
  its id. The caller has checked that the old row, if any, is free. `start` holds `kind` (by
  default `delegate` for role `delegate`, else `main`), `parent`, `project`, `deadline`, and a
  headless delegate's `session_id`, which the framework
  chose; an interactive session's is nil until its session file names it.
  """
  @spec starting(db, map) :: integer
  def starting(db, %{} = start) do
    now = System.os_time(:millisecond)

    start =
      Map.put_new(start, :kind, if(start[:role] == "delegate", do: "delegate", else: "main"))

    keys =
      ~w(host name kind parent project socket account role cwd resume session_id deadline repo
         branch options release)a

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
        "agents",
        fields,
        "ON CONFLICT (host, name) DO UPDATE SET #{sets} RETURNING id"
      )

    id
  end

  @doc """
  Writes a main session the embedding app declares, `declared`, of kind `main` with no parent,
  when `{host, name}` has no row; a row it has keeps its status and takes the project when it
  has none. Answers the row's id.
  """
  @spec declare(db, String.t(), String.t(), String.t()) :: integer
  def declare(db, host, name, project) do
    now = System.os_time(:millisecond)
    fields = [host: host, name: name, kind: "main", project: project, socket: name]
    fields = fields ++ [status: "declared", started_at: now, updated_at: now]
    tail = "ON CONFLICT (host, name) DO UPDATE SET project = coalesce(project, excluded.project)"
    Store.insert(db, "agents", fields, tail <> " RETURNING id") |> hd() |> hd()
  end

  @doc """
  Sets `fields` (status, reason, viewer, pid, session_id, proc_start, deadline, worktree,
  parent, project, and a move's `move`, `move_from`, `move_to`, `move_act`, `move_deadline`) on
  row `id`.
  """
  @spec update(db, integer, keyword) :: :ok
  def update(db, id, fields) do
    fields = Keyword.put(fields, :updated_at, System.os_time(:millisecond))
    Store.update(db, "agents", id, fields)
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
    marks = Store.marks(length(@free), 4)

    select(db, "host = ?1 AND cwd = ?2 AND name != ?3 AND status NOT IN (#{marks})", [
      host,
      cwd,
      name | @free
    ])
  end

  @doc "The host's rows, oldest first."
  @spec rows(db, String.t()) :: [row]
  def rows(db, host), do: select(db, "host = ?1", [host])

  @doc "The rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, [integer]) :: [row]
  def rows_by_id(db, ids), do: Store.rows_by_id(db, "agents", @columns, ids)

  defp select(db, where, args),
    do: Store.select(db, "agents", @columns, where <> " ORDER BY id", args)
end
