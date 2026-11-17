defmodule CodingAgentFramework.Acts.Table do
  @moduledoc """
  `acts`: one row per act, keyed by the state it acts on (`model/tla/Claim.tla`, `rows`). A
  unique index on `(target, state)` keeps one claim per state with no scan; a row with no state
  (a start, a raised error) claims no state, since SQLite takes no two NULLs as equal. `CodingAgentFramework.Acts` is the
  one writer; this module is its SQL and the table's metadata, from which the `Tracker` makes
  its source (`meta/0`, F-120's new-2).

  The columns: `actor` (who acts: an agent, the operator, `recoveries:<host>:<server>`),
  `target` (what it acts on: an agent's name; a socket's is its agent's), `state` (the target's
  state as the actor numbers it, as text), `act` (`reopen`, `end`, `interrupt`, `answer`,
  `resume`, `stop`, `start`, `error`, `fix` for a claim taken before acts were named),
  `start_id` (the framework start that wrote it), `status`, `outcome` and `reason` (once
  settled), `answer` and `detail` (what the act answered, and what that answer carries, such as
  a pane), and the times `claimed_at`, `acted_at`, `ended_at` and `cleared_at` (a person's
  clear). Every term is stored by `Store.text/1`.

  Opening also takes the rows of the two tables `Acts` replaces (F-126): the `recoveries` table
  in the same file, and the `claims` table of an older claims file, each converted and then
  dropped, so a state claimed before stays claimed.
  """

  alias CodingAgentFramework.Store

  @columns ~w(id actor target state act start_id status outcome reason answer detail
              claimed_at acted_at ended_at cleared_at)a

  @schema """
  CREATE TABLE IF NOT EXISTS acts (
    id INTEGER PRIMARY KEY, actor TEXT NOT NULL, target TEXT NOT NULL, state TEXT,
    act TEXT NOT NULL, start_id TEXT NOT NULL, status TEXT NOT NULL, outcome TEXT,
    reason TEXT, answer TEXT, detail TEXT, claimed_at INTEGER NOT NULL, acted_at INTEGER,
    ended_at INTEGER, cleared_at INTEGER);
  CREATE UNIQUE INDEX IF NOT EXISTS acts_state ON acts (target, state);
  CREATE INDEX IF NOT EXISTS acts_actor ON acts (actor, act);
  """

  @type db :: Store.db()

  @doc """
  The table's metadata for `CodingAgentFramework.Reader`'s source: no reads table, since the
  writer is read now; topic `acts:<host>:<instance>`, scope `{host, "acts:" <> instance}`, rows
  of kind `:acts`.
  """
  @spec meta() :: map
  def meta do
    %{
      schema: @schema,
      table: "acts",
      reads: nil,
      columns: @columns,
      scope: [],
      topic: "acts",
      group: "acts:",
      kind: :acts,
      name: :instance
    }
  end

  @doc "The columns of a row, in order."
  @spec columns() :: [atom]
  def columns, do: @columns

  @doc "Opens (and creates) the file at `path` with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema)

  @doc "The rows where `where` holds, oldest first."
  @spec select(db, String.t(), [term]) :: [map]
  def select(db, where, args),
    do: Store.select(db, "acts", @columns, where <> " ORDER BY id", args)

  # Migration (F-126).

  @doc """
  Takes the rows of the `recoveries` table in `db`'s file, if it has one, and drops it. Its key
  becomes the state behind the host and server (`<host>:<server>:<key>`), as `Recoveries` keys
  a state now. Answers how many rows it took.
  """
  @spec take_recoveries(db) :: non_neg_integer
  def take_recoveries(db) do
    if table?(db, "main", "recoveries") do
      Store.transaction(db, fn ->
        rows =
          Store.select(
            db,
            "recoveries",
            ~w(host server key kind socket status reason pane open claimed_at opened_at ended_at
               cleared_at)a,
            "1 = 1 ORDER BY id",
            []
          )

        Enum.each(rows, &insert_taken(db, recovery(&1)))
        Store.query(db, "DROP TABLE recoveries", [])
        length(rows)
      end)
    else
      0
    end
  end

  defp recovery(r) do
    reason = Store.from_inspect(r.reason)
    {status, outcome} = recovery_status(r.status, reason)

    %{
      actor: "recoveries:#{r.host}:#{r.server}",
      target: r.socket,
      state: "#{r.host}:#{r.server}:#{r.key}",
      act: if(r.kind == "end", do: "end", else: "reopen"),
      start_id: "",
      status: status,
      outcome: outcome,
      reason: if(status == "interrupted", do: nil, else: reason),
      answer: Store.from_inspect(r.open),
      detail: r.pane,
      claimed_at: r.claimed_at,
      acted_at: r.opened_at,
      ended_at: r.ended_at,
      cleared_at: r.cleared_at
    }
  end

  defp recovery_status("opened", _), do: {"acted", nil}
  defp recovery_status(s, _) when s in ["claimed", "skipped"], do: {s, nil}
  defp recovery_status("unknown", "interrupted"), do: {"interrupted", nil}
  defp recovery_status(outcome, _), do: {"settled", outcome}

  @doc """
  Takes the rows of the `claims` table in the file at `path`, if there is one, and drops it.
  Each claim's target and state, stored as terms, become `Store.text/1`'s text, so a fix's
  state read now matches the claim taken before. Answers how many rows it took.
  """
  @spec take_claims(db, String.t() | nil) :: non_neg_integer
  def take_claims(_db, nil), do: 0

  def take_claims(db, path) do
    if File.exists?(path) do
      Store.query(db, "ATTACH DATABASE ?1 AS old", [path])

      try do
        if table?(db, "old", "claims"), do: take_attached_claims(db), else: 0
      after
        Store.query(db, "DETACH DATABASE old", [])
      end
    else
      0
    end
  end

  # Each file's half is atomic on its own; a claim taken twice is the same state, which the
  # unique index keeps once.
  defp take_attached_claims(db) do
    Store.transaction(db, fn ->
      rows =
        Store.query(
          db,
          "SELECT caller, target, state, start_id, status, created_at, updated_at " <>
            "FROM old.claims ORDER BY id",
          []
        )

      for [caller, target, state, start_id, status, created, updated] <- rows do
        {status, outcome} =
          if status in ~w(verified not_verified), do: {"settled", status}, else: {status, nil}

        insert_taken(db, %{
          actor: caller,
          target: claim_target(:erlang.binary_to_term(target)),
          state: Store.text(:erlang.binary_to_term(state)),
          act: "fix",
          start_id: start_id,
          status: status,
          outcome: outcome,
          claimed_at: created,
          ended_at: if(status == "claimed", do: nil, else: updated)
        })
      end

      Store.query(db, "DROP TABLE old.claims", [])
      length(rows)
    end)
  end

  defp claim_target({:service, owner}), do: "service:" <> owner
  defp claim_target(name) when is_binary(name), do: name

  defp insert_taken(db, fields) do
    fields = for c <- tl(@columns), Map.has_key?(fields, c), do: {c, Map.fetch!(fields, c)}
    Store.insert(db, "acts", fields, "ON CONFLICT (target, state) DO NOTHING")
  end

  defp table?(db, schema, name) do
    Store.query(db, "SELECT 1 FROM #{schema}.sqlite_master WHERE type = 'table' AND name = ?1", [
      name
    ]) != []
  end
end
