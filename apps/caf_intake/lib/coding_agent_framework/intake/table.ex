defmodule CodingAgentFramework.Intake.Table do
  @moduledoc """
  `Intake`'s tables, in one SQLite file the caller names: `intake_events`, one row per hook
  event by `{host, account, key}`; `intake_starts`, when each host's `Intake` last started;
  `intake_stops`, each session's count of `Stop` blocks in a row; and `intake_pauses`, the
  pauses the `Stop` hold reads, per agent and per project.

  `CodingAgentFramework.Intake` is the one writer. A host whose `Intake` never started is
  `:unread`, never an empty list. A row's `hold` is nil for an event that is not held, and
  otherwise one of `held`, `deciding`, `answered`, `expired`, `passed`, `lost` and `unknown`
  (`model/tla/Hold.tla`'s rows). A decided row's `decision` is the response, and its `actor`
  who decided (`app` for the app's callback, `pause` for a pause's word, `person` for a
  person's answer, or the name the answer gave, `capped` for a `Stop` let pass at Claude Code's
  cap). A held `Stop` that waits on a person has `prompt` `stop_cap`. A held row's `deadline`
  is the wall-clock ms at which its hold ends with no decision (F-179).

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "intake.db")
      iex> {:ok, db} = CodingAgentFramework.Intake.Table.open(path)
      iex> CodingAgentFramework.Intake.Table.rows(db, "laptop", "work")
      :unread
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host account key event session_id data problem hold decision written_at actor
              prompt deadline)a

  @schema """
  CREATE TABLE IF NOT EXISTS intake_events (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, account TEXT NOT NULL, key TEXT NOT NULL,
    event TEXT, session_id TEXT, data TEXT, problem TEXT, hold TEXT, decision TEXT,
    written_at INTEGER NOT NULL, actor TEXT, UNIQUE (host, account, key));
  CREATE TABLE IF NOT EXISTS intake_starts (host TEXT PRIMARY KEY, started_at INTEGER NOT NULL);
  CREATE TABLE IF NOT EXISTS intake_stops (
    host TEXT NOT NULL, account TEXT NOT NULL, session_id TEXT NOT NULL,
    blocks INTEGER NOT NULL, written_at INTEGER NOT NULL,
    PRIMARY KEY (host, account, session_id));
  CREATE TABLE IF NOT EXISTS intake_pauses (
    host TEXT NOT NULL, scope TEXT NOT NULL, name TEXT NOT NULL, how TEXT NOT NULL,
    reason TEXT, set_by TEXT, set_at INTEGER NOT NULL, PRIMARY KEY (host, scope, name));
  """

  @open [added: [intake_events: ["actor TEXT", "prompt TEXT", "deadline INTEGER"]]]

  @type db :: Store.db()

  @doc """
  The table's metadata for `CodingAgentFramework.Reader`'s `Tracker` source (F-120's new-2): a
  writer's table, read per `{host, account}`, `:unread` until the host's `Intake` has started
  once (its `intake_starts` row) and read now after that, as every writer's table is; topic
  `intake:<host>:<account>`, scope `{host, account}`, rows of kind `:events`.
  """
  @spec meta() :: map
  def meta do
    %{
      schema: @schema,
      open: @open,
      table: "intake_events",
      reads: "intake_starts",
      read: [:started_at],
      load_read: &read_now/1,
      columns: @columns,
      scope: [:host],
      filter: [:account],
      topic: "intake",
      kind: :events,
      name: :account
    }
  end

  # The writer has started on the host: its rows are as fresh as the table, read now.
  defp read_now(%{started_at: at}) when is_integer(at),
    do: %{read_at: System.os_time(:millisecond)}

  defp read_now(_), do: %{read_at: nil}

  @doc "Opens (and creates) the file at `path`, with the tables. A reader opens its own."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path) do
    with {:ok, db} <- Store.open(path, @schema, @open) do
      # A problem an earlier build stored as `inspect` text (F-130's new-2).
      Store.convert(db, "intake_events", [:problem])
      {:ok, db}
    end
  end

  @doc """
  Records a start of `host`'s `Intake`, and settles the holds the last one left: a `held` row
  becomes `lost` and a `deciding` one `unknown`. Returns the settled rows' ids and accounts.
  A row an older build left `answering`, the earlier name of `deciding`, settles as one.
  """
  @spec start(db, String.t(), integer) :: [{integer, String.t()}]
  def start(db, host, at) do
    Store.query(db, "INSERT OR REPLACE INTO intake_starts VALUES (?1, ?2)", [host, at])

    # Spec action HoldSettled: the requests ended with the process that held them.
    db
    |> Store.query(
      "UPDATE intake_events SET hold = CASE hold WHEN 'held' THEN 'lost' ELSE 'unknown' END, " <>
        "written_at = ?2 WHERE host = ?1 AND hold IN ('held', 'deciding', 'answering') " <>
        "RETURNING id, account",
      [host, at]
    )
    |> Enum.map(fn [id, account] -> {id, account} end)
  end

  @doc """
  Writes an event's row, unless a row with its key is there. Returns `{:new, id}` or
  `{:seen, id, hold, decision}`, the row a post before wrote.
  """
  @spec insert(db, String.t(), String.t(), map, integer) ::
          {:new, integer} | {:seen, integer, String.t() | nil, String.t() | nil}
  def insert(db, host, account, row, at) do
    values =
      [host, account, row.key, row.event, row.session_id, row.data] ++
        [Store.text(row.problem), if(row.hold, do: "held"), at, row[:deadline]]

    sql =
      "INSERT INTO intake_events (host, account, key, event, session_id, data, problem, hold, " <>
        "written_at, deadline) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) " <>
        "ON CONFLICT (host, account, key) DO NOTHING RETURNING id"

    case Store.query(db, sql, values) do
      [[id]] ->
        {:new, id}

      [] ->
        sql =
          "SELECT id, hold, decision FROM intake_events " <>
            "WHERE host = ?1 AND account = ?2 AND key = ?3"

        [[id, hold, decision]] = Store.query(db, sql, [host, account, row.key])
        {:seen, id, hold, decision}
    end
  end

  @doc """
  Moves row `id` from hold `from` to `to`, with `decision` when given, and the options
  `actor:`, `data:`, `prompt:` and `problem:` when given (a tool call's row gets its input only
  with a decision; a callback's answer out of shape is the problem of the row it passes).
  False when it was not `from`.
  """
  @spec move(db, integer, String.t(), String.t(), String.t() | nil, integer, keyword) :: boolean
  def move(db, id, from, to, decision, at, opts \\ []) do
    sql =
      "UPDATE intake_events SET hold = ?3, decision = coalesce(?4, decision), written_at = ?5, " <>
        "actor = coalesce(?6, actor), data = coalesce(?7, data), prompt = coalesce(?8, prompt), " <>
        "problem = coalesce(?9, problem) WHERE id = ?1 AND hold = ?2 RETURNING id"

    values =
      [
        id,
        from,
        to,
        decision,
        at,
        opts[:actor],
        opts[:data],
        opts[:prompt],
        Store.text(opts[:problem])
      ]

    Store.query(db, sql, values) != []
  end

  @doc """
  A session's count of `Stop` blocks in a row, as `Intake` last wrote it: 0 when it has none.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "intake.db")
      iex> {:ok, db} = CodingAgentFramework.Intake.Table.open(path)
      iex> CodingAgentFramework.Intake.Table.put_blocks(db, "h", "work", "s1", 3, 1)
      iex> CodingAgentFramework.Intake.Table.blocks(db, "h", "work", "s1")
      3
  """
  @spec blocks(db, String.t(), String.t(), String.t()) :: non_neg_integer
  def blocks(db, host, account, session_id) do
    sql = "SELECT blocks FROM intake_stops WHERE host = ?1 AND account = ?2 AND session_id = ?3"

    case Store.query(db, sql, [host, account, session_id]) do
      [[n]] -> n
      [] -> 0
    end
  end

  @doc "Writes a session's count of `Stop` blocks in a row."
  @spec put_blocks(db, String.t(), String.t(), String.t(), non_neg_integer, integer) :: :ok
  def put_blocks(db, host, account, session_id, n, at) do
    row = [host: host, account: account, session_id: session_id, blocks: n, written_at: at]
    Store.upsert(db, "intake_stops", row)
    :ok
  end

  @doc "Sets a session's count to 0 after a tool call; true when it was more."
  @spec reset_blocks(db, String.t(), String.t(), String.t(), integer) :: boolean
  def reset_blocks(db, host, account, session_id, at) do
    sql =
      "UPDATE intake_stops SET blocks = 0, written_at = ?4 " <>
        "WHERE host = ?1 AND account = ?2 AND session_id = ?3 AND blocks > 0 RETURNING blocks"

    Store.query(db, sql, [host, account, session_id, at]) != []
  end

  @doc """
  A host's pauses, each `%{scope: :agent | :project, name, how, reason, set_by, set_at}`; `how`
  is `hold`, `pass` or `block` (with its `reason`).
  """
  @spec pauses(db, String.t()) :: [map]
  def pauses(db, host) do
    columns = [:scope, :name, :how, :reason, :set_by, :set_at]

    for row <- Store.select(db, "intake_pauses", columns, "host = ?1 ORDER BY set_at", [host]),
        do: %{row | scope: String.to_existing_atom(row.scope)}
  end

  @doc "Writes a pause in place of the one of the same scope and name."
  @spec put_pause(db, String.t(), map, integer) :: :ok
  def put_pause(db, host, pause, at) do
    row = [host: host, scope: Atom.to_string(pause.scope), name: pause.name, how: pause.how]

    Store.upsert(
      db,
      "intake_pauses",
      row ++ [reason: pause[:reason], set_by: pause[:set_by], set_at: at]
    )

    :ok
  end

  @doc "Removes a pause; true when there was one."
  @spec delete_pause(db, String.t(), :agent | :project, String.t()) :: boolean
  def delete_pause(db, host, scope, name) do
    sql = "DELETE FROM intake_pauses WHERE host = ?1 AND scope = ?2 AND name = ?3 RETURNING name"
    Store.query(db, sql, [host, Atom.to_string(scope), name]) != []
  end

  @doc "A host's account's rows, and `read_at`: its last start or newest row; `:unread` before a start."
  @spec rows(db, String.t(), String.t()) :: :unread | {:ok, map}
  def rows(db, host, account) do
    with {:ok, read} <- last_read(db, host, account) do
      where = "host = ?1 AND account = ?2 ORDER BY id"

      {:ok,
       Map.put(read, :rows, Store.select(db, "intake_events", @columns, where, [host, account]))}
    end
  end

  @doc "When a host's account's rows last changed, or its `Intake` last started; `:unread` before."
  @spec last_read(db, String.t(), String.t()) :: :unread | {:ok, %{read_at: integer}}
  def last_read(db, host, account) do
    sql =
      "SELECT max(started_at, coalesce((SELECT max(written_at) FROM intake_events " <>
        "WHERE host = ?1 AND account = ?2), 0)) FROM intake_starts WHERE host = ?1"

    case Store.query(db, sql, [host, account]) do
      [] -> :unread
      [[at]] -> {:ok, %{read_at: at}}
    end
  end

  @doc """
  What a fix reads of an interactive session (a main session, or an interactive delegate):
  `last`, the id of the newest row of its session (0 for none), and `held`, the ids of its
  `PermissionRequest` rows still `held`, in order; `:unread` before a start.
  """
  @spec session(db, String.t(), String.t(), String.t()) ::
          :unread | {:ok, %{last: non_neg_integer, held: [integer]}}
  def session(db, host, account, session_id) do
    with {:ok, _} <- last_read(db, host, account) do
      where = "host = ?1 AND account = ?2 AND session_id = ?3 ORDER BY id"
      own = Store.select(db, "intake_events", @columns, where, [host, account, session_id])
      held = for %{event: "PermissionRequest", hold: "held", id: id} <- own, do: id
      {:ok, %{last: own |> Enum.map(& &1.id) |> Enum.max(fn -> 0 end), held: held}}
    end
  end

  @doc """
  When the newest row of a session was written (ms), or nil for none: whether its hooks spoke
  since a tool call (`HooksSilent`, F-184); `:unread` before a start.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "newest.db")
      iex> {:ok, db} = CodingAgentFramework.Intake.Table.open(path)
      iex> CodingAgentFramework.Intake.Table.newest(db, "laptop", "work", "s1")
      :unread
  """
  @spec newest(db, String.t(), String.t(), String.t()) :: :unread | {:ok, integer | nil}
  def newest(db, host, account, session_id) do
    with {:ok, _} <- last_read(db, host, account) do
      sql =
        "SELECT max(written_at) FROM intake_events " <>
          "WHERE host = ?1 AND account = ?2 AND session_id = ?3"

      [[at]] = Store.query(db, sql, [host, account, session_id])
      {:ok, at}
    end
  end

  @doc """
  The host's holds that wait on a person (F-179, `Prompts`), oldest first: each
  `PermissionRequest` row and each `Stop` row at Claude Code's cap (`prompt` `stop_cap`) whose
  hold is `held`, or `deciding` (an answer on its way out).

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "intake.db")
      iex> {:ok, db} = CodingAgentFramework.Intake.Table.open(path)
      iex> CodingAgentFramework.Intake.Table.waiting(db, "laptop")
      []
  """
  @spec waiting(db, String.t()) :: [map]
  def waiting(db, host) do
    where =
      "host = ?1 AND hold IN ('held', 'deciding') AND " <>
        "(event = 'PermissionRequest' OR prompt = 'stop_cap') ORDER BY id"

    Store.select(db, "intake_events", @columns, where, [host])
  end

  @doc """
  The host's holds that could wait on a person, as `waiting/2`'s, in every hold, decided ones
  too, oldest first: what the metrics read (F-199). A decided row's `written_at` is when it
  settled, not when it opened.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "holds.db")
      iex> {:ok, db} = CodingAgentFramework.Intake.Table.open(path)
      iex> CodingAgentFramework.Intake.Table.holds(db, "laptop")
      []
  """
  @spec holds(db, String.t()) :: [map]
  def holds(db, host) do
    where =
      "host = ?1 AND hold IS NOT NULL AND " <>
        "(event = 'PermissionRequest' OR prompt = 'stop_cap') ORDER BY id"

    Store.select(db, "intake_events", @columns, where, [host])
  end

  @doc """
  The host's rows of hook event `event` whose id is past `past`, oldest first: what a reader
  that keeps its place reads next (`Interventions`' prompts, F-194).

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "events.db")
      iex> {:ok, db} = CodingAgentFramework.Intake.Table.open(path)
      iex> CodingAgentFramework.Intake.Table.events(db, "laptop", "UserPromptSubmit", 0)
      []
  """
  @spec events(db, String.t(), String.t(), integer) :: [map]
  def events(db, host, event, past),
    do:
      Store.select(
        db,
        "intake_events",
        @columns,
        "host = ?1 AND event = ?2 AND id > ?3 ORDER BY id",
        [host, event, past]
      )

  @doc "The rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, [integer]) :: [map]
  def rows_by_id(db, ids), do: Store.rows_by_id(db, "intake_events", @columns, ids)
end
