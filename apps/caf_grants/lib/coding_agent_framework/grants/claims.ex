defmodule CodingAgentFramework.Grants.Claims do
  @moduledoc """
  The claims table (`docs/design.md`, "Agents working together"; `model/tla/Team.tla`: `claims`,
  `ClaimTaken`, `ClaimSettled`, `OneClaimPerState`). A fix takes a claim on its target's current
  state before it acts, so that two fixes do not act on one state.

  One process owns the SQLite file and writes it; the embedding app's supervision tree starts
  it (`start_link/1`, `child_spec/1`). Each answer is `{:ok, …}`, `{:refused, reason}` or, when
  the call itself ends without an answer, `{:unknown, reason}`. Nothing retries or waits.

  **A row** has the caller, the target, the `state` as the caller passed it, the `start_id`
  of the framework start that wrote it, and a `status`: `claimed`, then once `verified`,
  `not_verified` or `interrupted`. A settled row is never reopened.

  **The target** is an agent's name (the check is `Grants.may_fix?/3`) or `{:service, owner}`
  (the check is `Grants.may_fix_service?/3`). **The state** is whatever the caller passes, an
  agent's state as `Recoveries` numbers it or a service's held process and restart count; it is
  stored as given and compared by equality.

  **A restart** opens the table with a new `start_id`. Every row still `claimed` that another
  start wrote is closed as `interrupted`, never retried. Rows of the current start are kept, so
  a second open in the same start closes nothing live.

      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> tree = fn -> [%{name: "app-fix", project: "app", parent: "app-main"}] end
      iex> grants = CodingAgentFramework.Grants.new(tree)
      iex> {:ok, claims} =
      ...>   CodingAgentFramework.Grants.Claims.start_link(
      ...>     path: Path.join(dir, "claims.db"), grants: grants, start_id: "s1")
      iex> {:ok, id} = CodingAgentFramework.Grants.Claims.claim(claims, "app-main", "app-fix", 1, "s1")
      iex> CodingAgentFramework.Grants.Claims.claim(claims, "app-main", "app-fix", 1, "s1")
      {:refused, {:claimed, "app-main"}}
      iex> CodingAgentFramework.Grants.Claims.settle(claims, id, :verified)
      {:ok, :verified}
  """

  use GenServer

  alias CodingAgentFramework.Grants
  alias Exqlite.Sqlite3

  @timeout 5_000

  @schema """
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS claims (
    id INTEGER PRIMARY KEY, caller TEXT NOT NULL, target BLOB NOT NULL, state BLOB NOT NULL,
    start_id TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL);
  """

  @type id :: integer
  @type target :: String.t() | {:service, String.t()}

  @doc """
  Starts the writer. Options: `path` (the SQLite file), `grants` (a `Grants`), `start_id`
  (made once per framework start by the embedding app). Opening closes the rows of other starts
  that are still `claimed` as `interrupted`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Writes a row `claimed` if the fix check answers `:ok` and no open claim holds the target's state."
  @spec claim(GenServer.server(), String.t(), target, term, String.t(), keyword) ::
          {:ok, id} | {:refused, term} | {:unknown, term}
  def claim(claims, caller, target, state, start_id, opts \\ []),
    do: call(claims, {:claim, caller, target, state, start_id}, opts)

  @doc "Ends an open claim with its outcome, `:verified` or `:not_verified`."
  @spec settle(GenServer.server(), id, :verified | :not_verified, keyword) ::
          {:ok, :verified | :not_verified} | {:refused, term} | {:unknown, term}
  def settle(claims, id, outcome, opts \\ [])
      when outcome in [:verified, :not_verified],
      do: call(claims, {:settle, id, outcome}, opts)

  @doc "Row `id` as a map (`caller`, `target`, `state`, `start_id`, `status`), or `{:refused, :unknown_claim}`."
  @spec get(GenServer.server(), id, keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def get(claims, id, opts \\ []), do: call(claims, {:get, id}, opts)

  @doc "Every row, oldest first."
  @spec rows(GenServer.server(), keyword) :: {:ok, [map]} | {:unknown, term}
  def rows(claims, opts \\ []), do: call(claims, :rows, opts)

  defp call(claims, request, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    GenServer.call(claims, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_claims}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @timeout)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    start_id = Keyword.fetch!(opts, :start_id)

    with {:ok, db} <- Sqlite3.open(path),
         :ok <- Sqlite3.set_busy_timeout(db, 5_000),
         :ok <- Sqlite3.execute(db, @schema) do
      # Only a row another start wrote is cut off; this start's rows are live.
      query(
        db,
        "UPDATE claims SET status = 'interrupted', updated_at = ?2 " <>
          "WHERE status = 'claimed' AND start_id != ?1",
        [start_id, now()]
      )

      {:ok, %{db: db, grants: Keyword.fetch!(opts, :grants)}}
    else
      {:error, reason} -> {:stop, {:sqlite, reason}}
    end
  end

  @impl true
  def handle_call({:claim, caller, target, state, start_id}, _from, s) do
    reply =
      with :ok <- check(s.grants, caller, target),
           nil <- holder(s.db, target, state) do
        {:ok, insert(s.db, caller, target, state, start_id)}
      else
        {:refused, _} = refused -> refused
        by when is_binary(by) -> {:refused, {:claimed, by}}
      end

    {:reply, reply, s}
  end

  def handle_call({:settle, id, outcome}, _from, s) do
    reply =
      case fetch(s.db, id) do
        nil ->
          {:refused, :unknown_claim}

        %{status: "claimed"} ->
          query(s.db, "UPDATE claims SET status = ?2, updated_at = ?3 WHERE id = ?1", [
            id,
            Atom.to_string(outcome),
            now()
          ])

          {:ok, outcome}

        %{status: status} ->
          {:refused, {:not_open, String.to_existing_atom(status)}}
      end

    {:reply, reply, s}
  end

  def handle_call({:get, id}, _from, s) do
    {:reply, if(row = fetch(s.db, id), do: {:ok, row}, else: {:refused, :unknown_claim}), s}
  end

  def handle_call(:rows, _from, s), do: {:reply, {:ok, select(s.db, "1 = 1", [])}, s}

  defp check(grants, caller, {:service, owner}),
    do: Grants.may_fix_service?(grants, caller, owner)

  defp check(grants, caller, target) when is_binary(target),
    do: Grants.may_fix?(grants, caller, target)

  # The caller of an open claim on this target and state, or nil. Compared by equality on the
  # decoded terms, not on their encodings.
  defp holder(db, target, state) do
    db
    |> select("status = 'claimed'", [])
    |> Enum.find_value(fn row ->
      if row.target == target and row.state == state, do: row.caller
    end)
  end

  defp insert(db, caller, target, state, start_id) do
    t = now()

    [[id]] =
      query(
        db,
        "INSERT INTO claims (caller, target, state, start_id, status, created_at, updated_at) " <>
          "VALUES (?1, ?2, ?3, ?4, 'claimed', ?5, ?5) RETURNING id",
        [
          caller,
          {:blob, :erlang.term_to_binary(target)},
          {:blob, :erlang.term_to_binary(state)},
          start_id,
          t
        ]
      )

    id
  end

  defp fetch(db, id), do: List.first(select(db, "id = ?1", [id]))

  defp select(db, where, args) do
    sql =
      "SELECT id, caller, target, state, start_id, status FROM claims WHERE #{where} ORDER BY id"

    for [id, caller, target, state, start_id, status] <- query(db, sql, args) do
      %{
        id: id,
        caller: caller,
        target: :erlang.binary_to_term(target),
        state: :erlang.binary_to_term(state),
        start_id: start_id,
        status: status
      }
    end
  end

  defp now, do: System.os_time(:millisecond)

  # An error is a bug or a broken file: it raises and the supervisor restarts the writer.
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
