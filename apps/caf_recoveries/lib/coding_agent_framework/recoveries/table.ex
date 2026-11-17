defmodule CodingAgentFramework.Recoveries.Table do
  @moduledoc """
  `recoveries`: one row per broken state `CodingAgentFramework.Recoveries` acted on, keyed by
  `{host, server, key}`. The key names the state (`model/tla/Agent.tla`, `RecoveryClaims`), so
  the row is the claim: it is written before the act, and a second claim of one key is refused.

  `Recoveries` is the one writer. Anyone may open the file and read. `status` is `claimed`
  (written, not yet acted on), `opened` (the act ran; the outcome waits for a later sample), one
  of the ends: `recovered`, `failed` and `unknown`, with `reason`, or `skipped`: a state read
  only in a sample too old to act on, which a later claim takes over. `open` is the act's
  answer, `ok` when it opened a pane and `exists` when tmux refused it because the session
  exists, and `opened_at` when it answered. `cleared_at` is when a person cleared a row that
  ended `failed{repeating}`.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Recoveries.Table.open(path)
      iex> state = %{host: "laptop", server: "agents", key: "lost_viewer:alpha:0:7",
      ...>   kind: "lost_viewer", socket: "alpha", generation: 0, since: 7}
      iex> {:ok, _id} = CodingAgentFramework.Recoveries.Table.claim(db, state, 8)
      iex> CodingAgentFramework.Recoveries.Table.claim(db, state, 9)
      {:refused, :claimed}
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host server key kind socket generation since status reason pane open
              claimed_at opened_at ended_at cleared_at)a
  @claim ~w(host server key kind socket generation since)a
  @repeating "status = 'failed' AND reason = ':repeating' AND cleared_at IS NULL"

  @schema """
  CREATE TABLE IF NOT EXISTS recoveries (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, server TEXT NOT NULL, key TEXT NOT NULL,
    kind TEXT NOT NULL, socket TEXT NOT NULL, generation INTEGER, since INTEGER,
    status TEXT NOT NULL, reason TEXT, pane TEXT, open TEXT,
    claimed_at INTEGER NOT NULL, opened_at INTEGER, ended_at INTEGER, cleared_at INTEGER,
    UNIQUE (host, server, key));
  """

  @type db :: Store.db()
  @type row :: %{atom => term}

  @doc "Opens (and creates) the file at `path`, with the table. A reader opens its own."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema)

  @doc """
  Claims a state at `at`: writes its row as `claimed` and returns its id, or
  `{:refused, :claimed}` when a row of that key exists, unless that row is `skipped`, which the
  claim takes over.
  """
  @spec claim(db, map, integer) :: {:ok, integer} | {:refused, :claimed}
  def claim(db, state, at) do
    insert(
      db,
      state,
      ["claimed", at, nil],
      "status = 'claimed', reason = NULL, claimed_at = excluded.claimed_at"
    )
  end

  @doc """
  Writes a state read only in a sample too old to act on as `skipped`, with `reason`. A row of
  that key already `skipped` takes the new reason; any other row is left, `{:refused, :claimed}`.
  """
  @spec skip(db, map, integer, term) :: {:ok, integer} | {:refused, :claimed}
  def skip(db, state, at, reason),
    do: insert(db, state, ["skipped", at, inspect(reason)], "reason = excluded.reason")

  defp insert(db, state, [status, at, reason], update) do
    fields =
      Enum.map(@claim, &{&1, state[&1]}) ++ [status: status, claimed_at: at, reason: reason]

    case Store.insert(
           db,
           "recoveries",
           fields,
           "ON CONFLICT (host, server, key) DO UPDATE SET #{update} " <>
             "WHERE recoveries.status = 'skipped' RETURNING id"
         ) do
      [[id]] -> {:ok, id}
      [] -> {:refused, :claimed}
    end
  end

  @doc """
  How many states of `socket` were claimed at or after `from`, and after a person last cleared
  it: the losses a new one is counted against.
  """
  @spec losses(db, String.t(), String.t(), String.t(), integer) :: non_neg_integer
  def losses(db, host, server, socket, from) do
    [[n]] =
      Store.query(
        db,
        "SELECT COUNT(*) FROM recoveries WHERE host = ?1 AND server = ?2 AND socket = ?3 " <>
          "AND kind = 'lost_viewer' AND status != 'skipped' AND claimed_at >= ?4 " <>
          "AND claimed_at > COALESCE(" <>
          "(SELECT MAX(cleared_at) FROM recoveries WHERE host = ?1 AND server = ?2 " <>
          "AND socket = ?3), -1)",
        [host, server, socket, from]
      )

    n
  end

  @doc "The sockets whose losses repeated and wait for a person: a `failed{repeating}` row left."
  @spec repeating(db, String.t(), String.t()) :: [String.t()]
  def repeating(db, host, server) do
    for [socket] <-
          Store.query(
            db,
            "SELECT DISTINCT socket FROM recoveries WHERE host = ?1 AND server = ?2 " <>
              "AND #{@repeating}",
            [host, server]
          ),
        do: socket
  end

  @doc "Marks `socket`'s `failed{repeating}` rows cleared at `at`. Answers their ids."
  @spec clear(db, String.t(), String.t(), String.t(), integer) :: [integer]
  def clear(db, host, server, socket, at) do
    for [id] <-
          Store.query(
            db,
            "UPDATE recoveries SET cleared_at = ?4 WHERE host = ?1 AND server = ?2 " <>
              "AND socket = ?3 AND #{@repeating} RETURNING id",
            [host, server, socket, at]
          ),
        do: id
  end

  @doc "Sets `fields` (status, reason, pane, open, opened_at, ended_at) on row `id`."
  @spec update(db, integer, keyword) :: :ok
  def update(db, id, fields), do: Store.update(db, "recoveries", id, fields)

  @doc """
  Ends a `{host, server}`'s `end` rows left `claimed` as `unknown{interrupted}` at `at`: a
  restart cut them between their claim and their act, so they are never acted on. Answers their
  ids.
  """
  @spec interrupt_ends(db, String.t(), String.t(), integer) :: [integer]
  def interrupt_ends(db, host, server, at) do
    for [id] <-
          Store.query(
            db,
            "UPDATE recoveries SET status = 'unknown', reason = ':interrupted', ended_at = ?3 " <>
              "WHERE host = ?1 AND server = ?2 AND kind = 'end' AND status = 'claimed' " <>
              "RETURNING id",
            [host, server, at]
          ),
        do: id
  end

  @doc "A `{host, server}`'s rows that have not ended: `claimed` and `opened`."
  @spec open_rows(db, String.t(), String.t()) :: [row]
  def open_rows(db, host, server),
    do: select(db, "host = ?1 AND server = ?2 AND status IN ('claimed','opened')", [host, server])

  @doc """
  Per socket, the newest of these: an open that answered with a pane (`open` is `ok`), an open
  refused because the session exists (`exists`; a viewer existed then), and a person's clear. A
  loss read after it is a new one.
  """
  @spec last_opened(db, String.t(), String.t()) :: %{String.t() => integer}
  def last_opened(db, host, server) do
    db
    |> Store.query(
      "SELECT socket, MAX(at) FROM (" <>
        "SELECT socket, opened_at AS at FROM recoveries WHERE host = ?1 AND server = ?2 " <>
        "AND open IN ('ok', 'exists') UNION ALL " <>
        "SELECT socket, cleared_at FROM recoveries WHERE host = ?1 AND server = ?2 " <>
        "AND cleared_at IS NOT NULL) GROUP BY socket",
      [host, server]
    )
    |> Map.new(fn [socket, at] -> {socket, at} end)
  end

  @doc "A `{host, server}`'s rows."
  @spec rows(db, String.t(), String.t()) :: [row]
  def rows(db, host, server), do: select(db, "host = ?1 AND server = ?2", [host, server])

  @doc "The rows with these ids; an id with no row is absent."
  @spec rows_by_id(db, [integer]) :: [row]
  def rows_by_id(db, ids), do: Store.rows_by_id(db, "recoveries", @columns, ids)

  defp select(db, where, args),
    do: Store.select(db, "recoveries", @columns, where <> " ORDER BY id", args)
end
