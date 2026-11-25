defmodule CodingAgentFramework.Scheduler.Table do
  @moduledoc """
  `leases`: one row per lease the `Scheduler` granted and per request it refused, which the
  `Scheduler` alone writes (`model/tla/Schedule.tla`'s `leases`, durable). The SQL of the grant
  and of the release is here; the order of the queue is `Scheduler.Queue`'s.

  The columns: `request_id` (the requester's, unique among granted rows, so a request asked
  again finds its lease), `outcome` (`granted` or `refused`), `class`, `module`, `account`,
  `units` (each resource's units, as JSON), `holder` (the row of the work the lease admits, as
  `[kind, key]`, whose owner says when its work ended), `asked_at` and `decided_at` (ms), and
  `waited` (ms in the queue). A refused row has `reason` and `retry_at` (ms) and holds nothing.
  A granted row has `released_at` and `released_by` (`monitor` or `reclaim`) once released.

  The `id` is the lease's fencing token: `AUTOINCREMENT` never hands an id out twice, so a
  later lease always has a greater id.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> alias CodingAgentFramework.Scheduler.Table
      iex> {:ok, db} = Table.open(path)
      iex> req = %{id: "r1", class: :builder, module: "app", account: "work",
      ...>   units: %{"seat" => 1}, holder: {"delegate", "ws:1"}, asked_at: 0}
      iex> {:ok, lease} = Table.grant(db, req, %{"seat" => 1}, %{}, 5)
      iex> {lease.id, lease.units}
      {1, %{"seat" => 1}}
      iex> Table.grant(db, %{req | id: "r2"}, %{"seat" => 1}, %{}, 6)
      {:full, "seat"}
      iex> Table.release(db, 1, "monitor", 7)
      :released
      iex> Table.release(db, 1, "reclaim", 8)
      :already
  """

  alias CodingAgentFramework.Store

  @columns ~w(id request_id outcome class module account units holder asked_at decided_at
              waited reason retry_at released_at released_by)a

  @schema """
  CREATE TABLE IF NOT EXISTS leases (
    id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL, outcome TEXT NOT NULL,
    class TEXT NOT NULL, module TEXT NOT NULL, account TEXT, units TEXT NOT NULL,
    holder TEXT, asked_at INTEGER NOT NULL, decided_at INTEGER NOT NULL, waited INTEGER,
    reason TEXT, retry_at INTEGER, released_at INTEGER, released_by TEXT);
  CREATE UNIQUE INDEX IF NOT EXISTS leases_request ON leases (request_id)
    WHERE outcome = 'granted';
  CREATE INDEX IF NOT EXISTS leases_held ON leases (outcome, released_at);
  """

  @type db :: Store.db()

  @doc """
  The table's metadata for `CodingAgentFramework.Reader`'s `Tracker` source: a writer's table,
  read now; topic `scheduler:<host>`, scope `{host, "leases"}`, rows of kind `:leases`.
  """
  @spec meta() :: map
  def meta do
    %{
      schema: @schema,
      table: "leases",
      reads: nil,
      columns: @columns,
      scope: [],
      topic: "scheduler",
      group: "leases",
      kind: :leases,
      name: nil,
      load: &load/1
    }
  end

  @doc "Opens (and creates) the file at `path`, with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema)

  @doc "The granted lease of `request_id`, released or not, or nil."
  @spec lease(db, String.t()) :: map | nil
  def lease(db, request_id),
    do: List.first(select(db, "request_id = ?1 AND outcome = 'granted'", [request_id]))

  @doc "Every granted lease not yet released, oldest first."
  @spec unreleased(db) :: [map]
  def unreleased(db), do: select(db, "outcome = 'granted' AND released_at IS NULL", [])

  @doc "The last `n` granted leases released, newest first: a view's bounded history."
  @spec released(db, pos_integer) :: [map]
  def released(db, n) do
    where = "outcome = 'granted' AND released_at IS NOT NULL ORDER BY id DESC LIMIT ?1"
    db |> Store.select("leases", @columns, where, [n]) |> Enum.map(&load/1)
  end

  @doc "The units each resource's unreleased leases hold, as the rows say."
  @spec held(db) :: %{String.t() => non_neg_integer}
  def held(db) do
    for lease <- unreleased(db), {resource, n} <- lease.units, reduce: %{} do
      held -> Map.update(held, resource, n, &(&1 + n))
    end
  end

  @doc """
  The grant: one immediate transaction that sums the units the unreleased rows hold, and
  inserts the lease only when each resource it needs fits beside them and beside `reserved`
  (the units waiting requests of a higher class need, which they hold). Answers `{:ok, lease}`
  or `{:full, resource}`, the first resource that does not fit. A resource with no capacity
  never fits.
  """
  @spec grant(db, map, map, map, integer) :: {:ok, map} | {:full, String.t()}
  def grant(db, request, capacity, reserved, now) do
    Store.transaction(db, fn ->
      held = held(db)

      full =
        request.units
        |> Enum.sort()
        |> Enum.find(fn {r, n} ->
          Map.get(held, r, 0) + Map.get(reserved, r, 0) + n > Map.get(capacity, r, 0)
        end)

      case full do
        nil -> {:ok, insert(db, request, "granted", now, waited: now - request.asked_at)}
        {resource, _} -> {:full, resource}
      end
    end)
  end

  @doc "Records `request`'s refusal: it holds nothing. Answers the row."
  @spec refuse(db, map, atom, integer, integer) :: map
  def refuse(db, request, reason, retry_at, now),
    do: insert(db, request, "refused", now, reason: reason, retry_at: retry_at)

  @doc """
  The release, a compare-and-set on the lease id: `:released` when this call released it,
  `:already` when it was released before (or there is no such lease). The monitor and the
  reclaimer both release this way, so exactly one succeeds.
  """
  @spec release(db, integer, String.t(), integer) :: :released | :already
  def release(db, id, by, now) do
    sql =
      "UPDATE leases SET released_at = ?2, released_by = ?3 " <>
        "WHERE id = ?1 AND outcome = 'granted' AND released_at IS NULL RETURNING id"

    case Store.query(db, sql, [id, now, by]) do
      [[^id]] -> :released
      [] -> :already
    end
  end

  @doc "Every row, granted and refused, oldest first."
  @spec all(db) :: [map]
  def all(db), do: select(db, "1 = 1", [])

  @doc "Row `id`, or nil."
  @spec get(db, integer) :: map | nil
  def get(db, id), do: List.first(select(db, "id = ?1", [id]))

  defp insert(db, request, outcome, now, extra) do
    fields =
      [
        request_id: request.id,
        outcome: outcome,
        class: Atom.to_string(request.class),
        module: request.module,
        account: request[:account],
        units: Store.text(request.units),
        holder: holder(request[:holder]),
        asked_at: request.asked_at,
        decided_at: now
      ] ++ Enum.map(extra, fn {k, v} -> {k, Store.text(v)} end)

    [[id]] = Store.insert(db, "leases", fields, "RETURNING id")
    get(db, id)
  end

  defp holder(nil), do: nil
  defp holder({kind, key}), do: Store.text([kind, key])

  defp select(db, where, args),
    do: db |> Store.select("leases", @columns, where <> " ORDER BY id", args) |> Enum.map(&load/1)

  # The stored JSON back to terms: units as a map, the holder as `{kind, key}`.
  defp load(row) do
    units = with u when is_binary(u) <- row.units, {:ok, m} <- JSON.decode(u), do: m

    holder =
      with h when is_binary(h) <- row.holder,
           {:ok, [kind, key]} <- JSON.decode(h),
           do: {kind, key},
           else: (_ -> nil)

    %{row | units: units, holder: holder}
  end
end
