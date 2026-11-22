defmodule CodingAgentFramework.Delegates.Table do
  @moduledoc """
  `delegates`: one row per start of a delegate, keyed by its id, which `Delegates` alone writes.
  It keeps only the protocol's own facts (`docs/design.md`, "What `Delegates` holds"); the
  agent's parent, project, account, session, launch options and whether it has ended are its
  agent row in `Sessions`, read through `Sessions.Agents`.

  `status` is `starting`, `resuming` (after a kill) and `going_on` (with the word to go on
  after a usage limit, F-187, not counted in `resumes`) while a call of `Sessions` is under way (`called_at`,
  in wall-clock ms, tells that call's agent row from an earlier one; `deadline` is the
  wall-clock time it is settled by), then `running`, then `finished` (a reply is its report) or
  `failed` (a notice is) once, or `refused` with its `reason`. `brief_uuid` and `resume_uuid`
  are the uuids of `Mailbox`'s rows of the brief and of the word to go on, chosen before they
  are stored. `report` is `none`, then `held` with its `text` until `Mailbox` takes it, then
  `taken`; how it is delivered is `Mailbox`'s row, the reply to `brief_uuid`. `model` is what
  its start and its resume launch with. `effort` is how hard that model thinks (`--effort`, one
  of `ClaudeCLI.efforts/0`), which a resume launches with again, or NULL when its start named
  none and no flag goes in (F-200). `tell` names the parent while it is owed the outcome of
  a start that answered queued at once (F-170), and is cleared once `Mailbox` has its notice.

  **Migration** (F-129): a file an earlier build made also has `parent`, `project`, `account`,
  `brief`, `session_id`, `mark` and `options`, and the status `ended`. `old_tree/1` reads what
  `Sessions` must take of them (`Sessions.adopt_tree/3`), and `rebuild/1` then rebuilds the
  table with this build's columns, an `ended` row being `finished`, in one transaction.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Delegates.Table.open(path)
      iex> CodingAgentFramework.Delegates.Table.rows(db, "laptop")
      []
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host name branch model brief_uuid resume_uuid status reason resumes report
              text called_at deadline created_at updated_at tell effort)a

  @create """
  (id INTEGER PRIMARY KEY, host TEXT NOT NULL, name TEXT NOT NULL, branch TEXT NOT NULL,
    model TEXT NOT NULL, brief_uuid TEXT NOT NULL, resume_uuid TEXT, status TEXT NOT NULL,
    reason TEXT, resumes INTEGER NOT NULL, report TEXT NOT NULL, text TEXT,
    called_at INTEGER NOT NULL, deadline INTEGER NOT NULL, created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL, tell TEXT, effort TEXT)
  """
  @schema "CREATE TABLE IF NOT EXISTS delegates #{@create};"
  # Added after a file's table may have been made (`tell`, F-170; `effort`, F-200).
  @added [delegates: ["tell TEXT", "effort TEXT"]]

  # Every status, once, and the lists read from it, checked when the module compiles.
  @statuses ~w(starting resuming going_on running finished failed refused)
  # A call of `Sessions` is under way, or was when a restart cut it.
  @calling ~w(starting resuming going_on)
  # Rows that may still move.
  @open ~w(starting resuming going_on running finished failed)
  # The report is the row's: a reply for `finished`, a notice for `failed`.
  @reported ~w(finished failed)

  for list <- [@calling, @open, @reported], status <- list do
    unless status in @statuses,
      do: raise(CompileError, description: "#{status} is not a status of delegates")
  end

  @type db :: Store.db()

  @doc "The statuses of a call of `Sessions` under way."
  @spec calling() :: [String.t()]
  def calling, do: @calling

  @doc "The statuses of a row that may still move."
  @spec open() :: [String.t()]
  def open, do: @open

  @doc "The statuses of a row whose report is its own."
  @spec reported() :: [String.t()]
  def reported, do: @reported

  @doc """
  The table's metadata for `CodingAgentFramework.Reader`'s `Tracker` source: a writer's table,
  read now; topic `delegates:<host>`, scope `{host, "delegates"}`, rows of kind `:delegates`.
  """
  @spec meta() :: map
  def meta do
    %{
      schema: @schema,
      table: "delegates",
      reads: nil,
      columns: @columns,
      scope: [],
      filter: [:host],
      topic: "delegates",
      group: "delegates",
      kind: :delegates,
      name: nil
    }
  end

  @doc """
  Opens (and creates) the file at `path`, with the table. A `reason` an earlier build stored as
  `inspect` text is converted to `Store.text/1`'s rule.
  """
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path) do
    with {:ok, db} <- Store.open(path, @schema, added: @added) do
      Store.convert(db, "delegates", [:reason])
      {:ok, db}
    end
  end

  @doc "Opens the file at `path` for a reader of its own (`Delegates.Work`): it converts nothing."
  @spec open_read(String.t()) :: {:ok, db} | {:refused, term}
  def open_read(path), do: Store.open(path, @schema, added: @added)

  @doc """
  What an earlier build's table holds that `Sessions` keeps now: per name, from its latest row,
  `%{name, parent, project, ended}`. `[]` for a table of this build.
  """
  @spec old_tree(db) :: [map]
  def old_tree(db) do
    if old?(db) do
      db
      |> Store.query(
        "SELECT name, parent, project, status FROM delegates WHERE id IN " <>
          "(SELECT max(id) FROM delegates GROUP BY host, name)",
        []
      )
      |> Enum.map(fn [n, p, pr, s] -> %{name: n, parent: p, project: pr, ended: s == "ended"} end)
    else
      []
    end
  end

  @doc "Rebuilds an earlier build's table with this build's columns; one of this build stays."
  @spec rebuild(db) :: :ok
  def rebuild(db) do
    if old?(db) do
      kept = Enum.map_join(@columns, ",", &if(&1 == :status, do: status_sql(), else: &1))

      Store.transaction(db, fn ->
        Store.query(db, "CREATE TABLE delegates_f129 #{@create}", [])

        Store.query(
          db,
          "INSERT INTO delegates_f129 (#{Enum.join(@columns, ",")}) SELECT #{kept} FROM delegates",
          []
        )

        Store.query(db, "DROP TABLE delegates", [])
        Store.query(db, "ALTER TABLE delegates_f129 RENAME TO delegates", [])
      end)
    end

    :ok
  end

  defp status_sql, do: "CASE status WHEN 'ended' THEN 'finished' ELSE status END"

  defp old?(db),
    do:
      Store.query(db, "SELECT 1 FROM pragma_table_info('delegates') WHERE name = 'parent'", []) !=
        []

  @doc "Writes a start's row, as `starting`, and returns its id."
  @spec starting(db, map) :: integer
  def starting(db, start) do
    now = System.os_time(:millisecond)
    keys = ~w(host name branch model effort brief_uuid deadline)a
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

  @doc "Each name's latest row on the host, oldest first: the delegate each name is now."
  @spec latest(db, String.t()) :: [map]
  def latest(db, host),
    do: select(db, "id IN (SELECT max(id) FROM delegates WHERE host = ?1 GROUP BY name)", [host])

  @doc "The host's rows whose parent is owed a queued start's outcome (`tell` names it)."
  @spec owed(db, String.t()) :: [map]
  def owed(db, host), do: select(db, "host = ?1 AND tell IS NOT NULL", [host])

  @doc "Row `id`, or nil."
  @spec get(db, integer) :: map | nil
  def get(db, id), do: List.first(select(db, "id = ?1", [id]))

  @doc "The host's rows, every status, oldest first."
  @spec rows(db, String.t()) :: [map]
  def rows(db, host), do: select(db, "host = ?1", [host])

  @doc """
  The host's rows in the file at `path`, read once through a read-only connection that is
  closed after (F-195), for a reader outside the tree; `{:ok, []}` before `Delegates` made its
  table.
  """
  @spec read_only(String.t(), String.t()) :: {:ok, [map]} | {:refused, term}
  def read_only(path, host), do: Store.read_only(path, "delegates", [], &rows(&1, host))

  defp select(db, where, args),
    do: Store.select(db, "delegates", @columns, where <> " ORDER BY id", args)
end
