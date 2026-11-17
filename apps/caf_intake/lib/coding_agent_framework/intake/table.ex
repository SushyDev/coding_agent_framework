defmodule CodingAgentFramework.Intake.Table do
  @moduledoc """
  `Intake`'s tables, in one SQLite file the caller names: `intake_events`, one row per hook
  event by `{host, account, key}`, and `intake_starts`, when each host's `Intake` last started.

  `CodingAgentFramework.Intake` is the one writer. A host whose `Intake` never started is
  `:unread`, never an empty list. A row's `hold` is nil for an event that is not held, and
  otherwise one of `held`, `deciding`, `answered`, `expired`, `passed`, `lost` and `unknown`
  (`model/tla/Hold.tla`'s rows). A decided row's `decision` is the response, and its `actor`
  who decided (`app` for a PreToolUse).

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "intake.db")
      iex> {:ok, db} = CodingAgentFramework.Intake.Table.open(path)
      iex> CodingAgentFramework.Intake.Table.rows(db, "laptop", "work")
      :unread
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host account key event session_id data problem hold decision written_at actor)a

  @schema """
  CREATE TABLE IF NOT EXISTS intake_events (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, account TEXT NOT NULL, key TEXT NOT NULL,
    event TEXT, session_id TEXT, data TEXT, problem TEXT, hold TEXT, decision TEXT,
    written_at INTEGER NOT NULL, actor TEXT, UNIQUE (host, account, key));
  CREATE TABLE IF NOT EXISTS intake_starts (host TEXT PRIMARY KEY, started_at INTEGER NOT NULL);
  """

  @type db :: Store.db()

  @doc "Opens (and creates) the file at `path`, with the tables. A reader opens its own."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema, added: [intake_events: ["actor TEXT"]])

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
        [row.problem && inspect(row.problem), if(row.hold, do: "held"), at]

    sql =
      "INSERT INTO intake_events (host, account, key, event, session_id, data, problem, hold, " <>
        "written_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9) " <>
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
  `actor:` and `data:` when given (a tool call's row gets its input only with a decision).
  False when it was not `from`.
  """
  @spec move(db, integer, String.t(), String.t(), String.t() | nil, integer, keyword) :: boolean
  def move(db, id, from, to, decision, at, opts \\ []) do
    sql =
      "UPDATE intake_events SET hold = ?3, decision = coalesce(?4, decision), written_at = ?5, " <>
        "actor = coalesce(?6, actor), data = coalesce(?7, data) " <>
        "WHERE id = ?1 AND hold = ?2 RETURNING id"

    values = [id, from, to, decision, at, opts[:actor], opts[:data]]
    Store.query(db, sql, values) != []
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

  @doc "The rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, [integer]) :: [map]
  def rows_by_id(db, ids), do: Store.rows_by_id(db, "intake_events", @columns, ids)
end
