defmodule CodingAgentFramework.Sessions.Table do
  @moduledoc """
  `held_sessions`: one row per session `CodingAgentFramework.Sessions` started on a host, keyed
  by `{host, name}`. The name is the session's name, its tmux session's and its dtach socket's.

  `Sessions` is the one writer. Anyone may open the file and read. `status` is one of
  `starting`, `running`, `stopping`, `stopped`, `refused`, `unknown` and `orphan` (a live socket
  with no session file past the start's deadline, for `Recoveries`); `reason` says why a row is
  refused, unknown or orphan, or why a stop is late (`no_exit`). `deadline` is the current start's
  or stop's deadline in wall-clock milliseconds, so a restart does not move it.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Sessions.Table.open(path)
      iex> CodingAgentFramework.Sessions.Table.get(db, "laptop", "alpha")
      nil
  """

  alias Exqlite.Sqlite3

  @columns ~w(id host name socket account role cwd resume status reason viewer pid session_id
              proc_start started_at updated_at deadline)a

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS held_sessions (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, name TEXT NOT NULL, socket TEXT NOT NULL,
    account TEXT NOT NULL, role TEXT NOT NULL, cwd TEXT NOT NULL, resume TEXT,
    status TEXT NOT NULL, reason TEXT, viewer TEXT, pid INTEGER, session_id TEXT,
    proc_start TEXT, started_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    deadline INTEGER, UNIQUE (host, name));
  """

  # A file made before the deadline column gains it; a newer file already has it.
  @add_deadline "ALTER TABLE held_sessions ADD COLUMN deadline INTEGER"

  @type db :: Sqlite3.db()
  @type row :: %{atom => term}

  @doc "Opens (and creates) the file at `path`, with the table. A reader opens its own."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path) do
    with {:ok, db} <- Sqlite3.open(path),
         :ok <- Sqlite3.set_busy_timeout(db, 5_000),
         :ok <- Sqlite3.execute(db, @schema),
         :ok <- added(Sqlite3.execute(db, @add_deadline)) do
      {:ok, db}
    else
      {:error, reason} -> {:refused, {:sqlite, reason}}
    end
  end

  defp added({:error, "duplicate column name" <> _}), do: :ok
  defp added(other), do: other

  @doc """
  Writes a new start of `{host, name}` as `starting`, over any row it had before, and returns
  its id. The caller has checked that the old row, if any, has ended. `start` holds `deadline`.
  """
  @spec starting(db, map) :: integer
  def starting(db, %{} = start) do
    now = System.os_time(:millisecond)
    keys = ~w(host name socket account role cwd resume deadline)a
    values = Enum.map(keys, &start[&1]) ++ ["starting", now, now]
    names = Enum.join(keys ++ [:status, :started_at, :updated_at], ",")
    marks = Enum.map_join(1..length(values), ",", &"?#{&1}")
    reset = "reason = NULL, viewer = NULL, pid = NULL, session_id = NULL, proc_start = NULL"

    sets =
      Enum.map_join(keys -- [:host, :name], ",", &"#{&1} = excluded.#{&1}") <>
        ", status = 'starting', started_at = excluded.started_at, " <>
        "updated_at = excluded.updated_at, " <> reset

    [[id]] =
      query(
        db,
        "INSERT INTO held_sessions (#{names}) VALUES (#{marks}) " <>
          "ON CONFLICT (host, name) DO UPDATE SET #{sets} RETURNING id",
        values
      )

    id
  end

  @doc "Sets `fields` (status, reason, viewer, pid, session_id, proc_start, deadline) on row `id`."
  @spec update(db, integer, keyword) :: :ok
  def update(db, id, fields) do
    fields = Keyword.put(fields, :updated_at, System.os_time(:millisecond))

    sets =
      fields |> Enum.with_index(2) |> Enum.map_join(",", fn {{k, _}, i} -> "#{k} = ?#{i}" end)

    values = Enum.map(fields, fn {_, v} -> dump(v) end)
    query(db, "UPDATE held_sessions SET #{sets} WHERE id = ?1", [id | values])
    :ok
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

  @doc "A `{host, account}`'s rows."
  @spec rows(db, String.t(), String.t()) :: [row]
  def rows(db, host, account), do: select(db, "host = ?1 AND account = ?2", [host, account])

  @doc "The rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, [integer]) :: [row]
  def rows_by_id(_db, []), do: []

  def rows_by_id(db, ids),
    do: select(db, "id IN (#{Enum.map_join(1..length(ids), ",", &"?#{&1}")})", ids)

  defp select(db, where, args) do
    db
    |> query(
      "SELECT #{Enum.join(@columns, ",")} FROM held_sessions WHERE #{where} ORDER BY id",
      args
    )
    |> Enum.map(&(@columns |> Enum.zip(&1) |> Map.new()))
  end

  defp dump(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp dump(value) when is_binary(value) or is_integer(value) or is_nil(value), do: value
  defp dump(value), do: inspect(value)

  # The writer's own statements: an error here is a bug or a broken file, so it raises and the
  # supervisor restarts the writer, which reads its rows again from the file.
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
