defmodule CodingAgentFramework.Delegates.Table do
  @moduledoc """
  `delegates`: one row per start of a delegate, keyed by its id, which `Delegates` alone writes;
  anyone may open the file and read.

  `status` is `starting` and `resuming` while a call of `Sessions` is under way (`called_at`,
  in wall-clock ms, tells that call's `Sessions` row from an earlier one; `deadline` is the
  wall-clock time it is settled by), then `running`, then `finished` or `failed` once, or
  `refused` with its `reason`. `brief_uuid` and `resume_uuid` are the uuids the turn's message
  goes in under, chosen before it is written. `report` is `none`, then `held` with its `text`
  and its `mark`, or `answering` once a call that waited on it took it (`run_delegate`), then
  `answered` once that call's answer reached its agent, or `held` again when it did not; the
  delivery unit adds `sending` and `delivered`.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Delegates.Table.open(path)
      iex> CodingAgentFramework.Delegates.Table.held(db, "laptop", "main")
      []
  """

  alias Exqlite.Sqlite3

  @columns ~w(id host parent project branch name account model brief brief_uuid resume_uuid
              session_id status reason resumes report text mark called_at deadline created_at
              updated_at)a

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS delegates (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, parent TEXT NOT NULL, project TEXT NOT NULL,
    branch TEXT NOT NULL, name TEXT NOT NULL, account TEXT NOT NULL, model TEXT NOT NULL,
    brief TEXT NOT NULL, brief_uuid TEXT NOT NULL, resume_uuid TEXT, session_id TEXT,
    status TEXT NOT NULL, reason TEXT, resumes INTEGER NOT NULL, report TEXT NOT NULL,
    text TEXT, mark TEXT, called_at INTEGER NOT NULL, deadline INTEGER NOT NULL,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
  """
  # The statuses of a delegate that holds its parent's cap: started and not yet ended.
  @active ~w(starting running resuming finished failed)

  @type db :: Sqlite3.db()

  @doc "Opens (and creates) the file at `path`, with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path) do
    with {:ok, db} <- Sqlite3.open(path),
         :ok <- Sqlite3.set_busy_timeout(db, 5_000),
         :ok <- Sqlite3.execute(db, @schema) do
      {:ok, db}
    else
      {:error, reason} -> {:refused, {:sqlite, reason}}
    end
  end

  @doc "Writes a start's row, as `starting`, and returns its id."
  @spec starting(db, map) :: integer
  def starting(db, start) do
    now = System.os_time(:millisecond)
    keys = ~w(host parent project branch name account model brief brief_uuid deadline)a
    values = Enum.map(keys, &start[&1]) ++ ["starting", 0, "none", now, now, now]
    names = Enum.join(keys ++ ~w(status resumes report called_at created_at updated_at)a, ",")
    marks = Enum.map_join(1..length(values), ",", &"?#{&1}")
    [[id]] = query(db, "INSERT INTO delegates (#{names}) VALUES (#{marks}) RETURNING id", values)
    id
  end

  @doc "Sets `fields` on row `id`."
  @spec update(db, integer, keyword) :: :ok
  def update(db, id, fields) do
    fields = Keyword.put(fields, :updated_at, System.os_time(:millisecond))

    sets =
      fields |> Enum.with_index(2) |> Enum.map_join(",", fn {{k, _}, i} -> "#{k} = ?#{i}" end)

    query(db, "UPDATE delegates SET #{sets} WHERE id = ?1", [id | Enum.map(fields, &dump/1)])
    :ok
  end

  @doc "The host's rows whose status is one of `statuses`."
  @spec with_status(db, String.t(), [String.t()]) :: [map]
  def with_status(db, host, statuses),
    do: select(db, "host = ?1 AND status IN (#{marks(statuses, 2)})", [host | statuses])

  @doc "The host's rows whose report is `report`."
  @spec with_report(db, String.t(), String.t()) :: [map]
  def with_report(db, host, report), do: select(db, "host = ?1 AND report = ?2", [host, report])

  @doc "How many of `parent`'s delegates hold its cap: started, or starting, and not ended."
  @spec active(db, String.t(), String.t()) :: non_neg_integer
  def active(db, host, parent),
    do:
      length(
        select(db, "host = ?1 AND parent = ?2 AND status IN (#{marks(@active, 3)})", [
          host,
          parent | @active
        ])
      )

  @doc "`parent`'s held reports, oldest first."
  @spec held(db, String.t(), String.t()) :: [map]
  def held(db, host, parent),
    do: select(db, "host = ?1 AND parent = ?2 AND report = 'held'", [host, parent])

  @doc "Row `id`, or nil."
  @spec get(db, integer) :: map | nil
  def get(db, id), do: List.first(select(db, "id = ?1", [id]))

  @doc "The host's rows, every status, oldest first: what the `Tracker` reads."
  @spec rows(db, String.t()) :: [map]
  def rows(db, host), do: select(db, "host = ?1", [host])

  @doc "The host's rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, String.t(), [integer]) :: [map]
  def rows_by_id(_db, _host, []), do: []

  def rows_by_id(db, host, ids),
    do: select(db, "host = ?1 AND id IN (#{marks(ids, 2)})", [host | ids])

  defp marks(list, from), do: Enum.map_join(0..(length(list) - 1)//1, ",", &"?#{&1 + from}")

  defp select(db, where, args) do
    sql = "SELECT #{Enum.join(@columns, ",")} FROM delegates WHERE #{where} ORDER BY id"
    db |> query(sql, args) |> Enum.map(&(@columns |> Enum.zip(&1) |> Map.new()))
  end

  defp dump({_, v}) when is_binary(v) or is_integer(v) or is_nil(v), do: v
  defp dump({_, v}), do: inspect(v)

  # The writer's own statements: an error is a bug or a broken file, so it raises and the
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
