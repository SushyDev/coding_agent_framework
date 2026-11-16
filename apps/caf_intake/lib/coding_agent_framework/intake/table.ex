defmodule CodingAgentFramework.Intake.Table do
  @moduledoc """
  `Intake`'s tables, in one SQLite file the caller names: `intake_events`, one row per hook
  event by `{host, account, key}`, and `intake_starts`, when each host's `Intake` last started.

  `CodingAgentFramework.Intake` is the one writer. A host whose `Intake` never started is
  `:unread`, never an empty list. A row's `hold` is nil for an event that is not held, and
  otherwise one of `held`, `answering`, `answered`, `expired`, `lost` and `unknown`. A
  PreToolUse row is written only for a decision: its `decision` is the response, and its
  `actor` who decided (`app`).

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "intake.db")
      iex> {:ok, db} = CodingAgentFramework.Intake.Table.open(path)
      iex> CodingAgentFramework.Intake.Table.rows(db, "laptop", "work")
      :unread
  """

  alias Exqlite.Sqlite3

  @columns ~w(id host account key event session_id data problem hold decision written_at actor)a

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS intake_events (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, account TEXT NOT NULL, key TEXT NOT NULL,
    event TEXT, session_id TEXT, data TEXT, problem TEXT, hold TEXT, decision TEXT,
    written_at INTEGER NOT NULL, actor TEXT, UNIQUE (host, account, key));
  CREATE TABLE IF NOT EXISTS intake_starts (host TEXT PRIMARY KEY, started_at INTEGER NOT NULL);
  """

  @type db :: Sqlite3.db()

  @doc "Opens (and creates) the file at `path`, with the tables. A reader opens its own."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path) do
    with {:ok, db} <- Sqlite3.open(path),
         :ok <- Sqlite3.set_busy_timeout(db, 5_000),
         :ok <- Sqlite3.execute(db, @schema),
         :ok <- added(Sqlite3.execute(db, "ALTER TABLE intake_events ADD COLUMN actor TEXT")) do
      {:ok, db}
    else
      {:error, reason} -> {:refused, {:sqlite, reason}}
    end
  end

  # A file made before `actor` gains it; a newer file already has it.
  defp added({:error, "duplicate column name" <> _}), do: :ok
  defp added(other), do: other

  @doc """
  Writes a PreToolUse decision's row, with the response `body` as its decision and the actor
  `app`, unless a row with its key is there. Returns the row's id and the decision it holds.
  """
  @spec decide(db, String.t(), String.t(), map, String.t(), integer) :: {integer, String.t()}
  def decide(db, host, account, row, body, at) do
    sql =
      "INSERT INTO intake_events (host, account, key, event, session_id, data, decision, " <>
        "actor, written_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'app', ?8) " <>
        "ON CONFLICT (host, account, key) DO NOTHING RETURNING id"

    case query(db, sql, [host, account, row.key, row.event, row.session_id, row.data, body, at]) do
      [[id]] -> {id, body}
      [] -> List.to_tuple(by_key(db, host, account, row.key))
    end
  end

  @doc "The decision of the row with this key, or nil when there is none."
  @spec decision(db, String.t(), String.t(), String.t()) :: String.t() | nil
  def decision(db, host, account, key) do
    case by_key(db, host, account, key) do
      [_id, decision] -> decision
      nil -> nil
    end
  end

  defp by_key(db, host, account, key) do
    sql = "SELECT id, decision FROM intake_events WHERE host = ?1 AND account = ?2 AND key = ?3"
    db |> query(sql, [host, account, key]) |> List.first()
  end

  @doc """
  Records a start of `host`'s `Intake`, and settles the holds the last one left: a `held` row
  becomes `lost` and an `answering` one `unknown`. Returns the settled rows' ids and accounts.
  """
  @spec start(db, String.t(), integer) :: [{integer, String.t()}]
  def start(db, host, at) do
    query(db, "INSERT OR REPLACE INTO intake_starts VALUES (?1, ?2)", [host, at])

    # Spec action HoldSettled: the requests ended with the process that held them.
    db
    |> query(
      "UPDATE intake_events SET hold = CASE hold WHEN 'held' THEN 'lost' ELSE 'unknown' END, " <>
        "written_at = ?2 WHERE host = ?1 AND hold IN ('held', 'answering') RETURNING id, account",
      [host, at]
    )
    |> Enum.map(fn [id, account] -> {id, account} end)
  end

  @doc """
  Writes an event's row, unless a row with its key is there. Returns `{:new, id}` or
  `{:seen, id, hold}`, the row a post before wrote.
  """
  @spec insert(db, String.t(), String.t(), map, integer) ::
          {:new, integer} | {:seen, integer, String.t() | nil}
  def insert(db, host, account, row, at) do
    values =
      [host, account, row.key, row.event, row.session_id, row.data] ++
        [row.problem && inspect(row.problem), if(row.hold, do: "held"), at]

    sql =
      "INSERT INTO intake_events (host, account, key, event, session_id, data, problem, hold, " <>
        "written_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9) " <>
        "ON CONFLICT (host, account, key) DO NOTHING RETURNING id"

    case query(db, sql, values) do
      [[id]] ->
        {:new, id}

      [] ->
        [[id, hold]] =
          query(
            db,
            "SELECT id, hold FROM intake_events WHERE host = ?1 AND account = ?2 AND key = ?3",
            [host, account, row.key]
          )

        {:seen, id, hold}
    end
  end

  @doc "Moves row `id` from hold `from` to `to`, with `decision` when given. False when it was not `from`."
  @spec move(db, integer, String.t(), String.t(), String.t() | nil, integer) :: boolean
  def move(db, id, from, to, decision, at) do
    sql =
      "UPDATE intake_events SET hold = ?3, decision = coalesce(?4, decision), written_at = ?5 " <>
        "WHERE id = ?1 AND hold = ?2 RETURNING id"

    query(db, sql, [id, from, to, decision, at]) != []
  end

  @doc "A host's account's rows, and `read_at`: its last start or newest row; `:unread` before a start."
  @spec rows(db, String.t(), String.t()) :: :unread | {:ok, map}
  def rows(db, host, account) do
    with {:ok, read} <- last_read(db, host, account) do
      sql = "SELECT #{cols()} FROM intake_events WHERE host = ?1 AND account = ?2 ORDER BY id"
      {:ok, Map.put(read, :rows, db |> query(sql, [host, account]) |> Enum.map(&to_row/1))}
    end
  end

  @doc "When a host's account's rows last changed, or its `Intake` last started; `:unread` before."
  @spec last_read(db, String.t(), String.t()) :: :unread | {:ok, %{read_at: integer}}
  def last_read(db, host, account) do
    sql =
      "SELECT max(started_at, coalesce((SELECT max(written_at) FROM intake_events " <>
        "WHERE host = ?1 AND account = ?2), 0)) FROM intake_starts WHERE host = ?1"

    case query(db, sql, [host, account]) do
      [] -> :unread
      [[at]] -> {:ok, %{read_at: at}}
    end
  end

  @doc "The rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, [integer]) :: [map]
  def rows_by_id(_db, []), do: []

  def rows_by_id(db, ids) do
    marks = Enum.map_join(1..length(ids), ",", &"?#{&1}")

    db
    |> query("SELECT #{cols()} FROM intake_events WHERE id IN (#{marks}) ORDER BY id", ids)
    |> Enum.map(&to_row/1)
  end

  defp cols, do: Enum.join(@columns, ",")

  defp to_row(values), do: @columns |> Enum.zip(values) |> Map.new()

  # The writer's own statements: an error here is a bug or a broken file, so it raises and the
  # supervisor restarts the writer, which settles its holds at start.
  defp query(db, sql, args) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(stmt, args)
      {:ok, rows} = Sqlite3.fetch_all(db, stmt)
      rows
    after
      Sqlite3.release(db, stmt)
    end
  end
end
