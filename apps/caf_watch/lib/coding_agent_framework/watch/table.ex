defmodule CodingAgentFramework.Watch.Table do
  @moduledoc """
  The `Watch`'s two tables (`model/tla/Heal.tla`'s `facts`, `asked` and `allow`).
  `CodingAgentFramework.Watch` is their one writer; this module is their SQL, and the read
  `Prompts` makes of the remedy prompts (`asked/1`).

  `symptoms`: one row per symptom state, under a unique index on `(kind, target, state)`, so a
  state is recorded once. Its columns: `kind` (`lost_viewer`, `end_owed`, …), `target` (the
  agent, socket or account it is of), `state` (the state's key as its detector numbers it,
  the key the healer's claim in `Acts` takes), `source` (who detected it: the healer's actor),
  `since` (when the state began, ms), `evidence` (what was read, as `Store.text/1` keeps it),
  `status` (`open`; `asked`, a remedy prompt open for a person; `answered`; `passed`, no longer
  read), `remedy` and `reason` (once asked: the remedy proposed and why it waits on a person),
  `answer` and `answered_by`, and the times `recorded_at`, `asked_at`, `answered_at` and
  `passed_at`.

  `remedy_acts`: the acts on the allow-list, oldest first, each `kind`, `act` (`drop`, the
  healer's narrowing after a failed verify; `revoke`, the operator's; `approve`, the
  operator's widening), `by`, `reason` and `at`. The list is the config's, then these acts in
  order (`allowed/2`).
  """

  alias CodingAgentFramework.Store

  @columns ~w(id kind target state source since evidence status remedy reason answer answered_by
              recorded_at asked_at answered_at passed_at)a
  @acts ~w(id kind act by reason at)a

  @schema """
  CREATE TABLE IF NOT EXISTS symptoms (
    id INTEGER PRIMARY KEY, kind TEXT NOT NULL, target TEXT NOT NULL, state TEXT NOT NULL,
    source TEXT NOT NULL, since INTEGER NOT NULL, evidence TEXT, status TEXT NOT NULL,
    remedy TEXT, reason TEXT, answer TEXT, answered_by TEXT, recorded_at INTEGER NOT NULL,
    asked_at INTEGER, answered_at INTEGER, passed_at INTEGER);
  CREATE UNIQUE INDEX IF NOT EXISTS symptoms_state ON symptoms (kind, target, state);
  CREATE INDEX IF NOT EXISTS symptoms_status ON symptoms (status, source);
  CREATE TABLE IF NOT EXISTS remedy_acts (
    id INTEGER PRIMARY KEY, kind TEXT NOT NULL, act TEXT NOT NULL, by TEXT NOT NULL,
    reason TEXT, at INTEGER NOT NULL);
  """

  @type db :: Store.db()

  @doc "A symptom's columns, in order."
  @spec columns() :: [atom]
  def columns, do: @columns

  @doc "Opens (and creates) the file at `path` with both tables."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema)

  @doc "The symptoms where `where` holds, oldest first."
  @spec select(db, String.t(), [term]) :: [map]
  def select(db, where, args),
    do: Store.select(db, "symptoms", @columns, where <> " ORDER BY id", args)

  @doc "The symptoms whose remedy prompt is open: status `asked`, oldest first."
  @spec asked(db) :: [map]
  def asked(db), do: select(db, "status = 'asked'", [])

  @doc "The acts on the allow-list, oldest first."
  @spec acts(db) :: [map]
  def acts(db), do: Store.select(db, "remedy_acts", @acts, "1 = 1 ORDER BY id", [])

  @doc """
  Whether `kind`'s remedy is on the list after `acts`, given the config's entry: on when the
  config names a remedy, off after a `drop` or `revoke`, on again after an `approve`, the last
  act deciding. A kind with no remedy is never on.

      iex> alias CodingAgentFramework.Watch.Table
      iex> Table.allowed(%{remedy: "reopen"}, [%{act: "drop"}])
      false
      iex> Table.allowed(%{remedy: "reopen"}, [%{act: "drop"}, %{act: "approve"}])
      true
      iex> Table.allowed(%{remedy: nil}, [%{act: "approve"}])
      false
  """
  @spec allowed(map, [map]) :: boolean
  def allowed(%{remedy: nil}, _acts), do: false

  def allowed(_entry, acts) do
    case List.last(acts) do
      %{act: act} when act in ["drop", "revoke"] -> false
      _ -> true
    end
  end
end
