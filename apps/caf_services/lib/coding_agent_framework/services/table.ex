defmodule CodingAgentFramework.Services.Table do
  @moduledoc """
  `services`: one row per service, keyed by its name, which `Services` alone writes
  (`model/tla/Copy.tla`'s `row`, `owner`, `keep` and `svcRestarts`, durable).

  `state` is `asked`, `starting` (its start is being sent, until `start_until`, wall-clock ms),
  `running`, `ending` (its end written before it is sent; TERM until `end_until`, then KILL),
  then `ended`; `restarting` (an end, then `asked` again); or `refused` (nothing runs). `host`, `project` and `copy` name the copy it runs in, `worktree`
  the worktree each start syncs from, and `argv` and `env` what each start holds. `pid` and
  `started` are the held process (its pid and its start time as `ps -o lstart=` gives it, in
  the C locale and UTC); `restarts` counts its restarts; `owner` is the agent that owns it,
  none once ended; `keep` hands it to the owner's parent when the owner ends. `log_from` is the
  log's size when the current start began, where a line wait looks from.

  A forwarded service has `port` (on its host) and `local` (on the workstation), and `fwd`, its
  forward's state for the current start (`Copy.tla`'s `frow`): none, `starting`, `open`,
  `reopening` or `failed`; `opens` counts its opens in that start (`Key`'s second half).

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Services.Table.open(path)
      iex> CodingAgentFramework.Services.Table.get(db, "web")
      nil
  """

  alias CodingAgentFramework.Store

  @columns ~w(name host project copy worktree argv env owner keep pid started restarts state
              start_until end_until log_from port local fwd opens)a
  @schema """
  CREATE TABLE IF NOT EXISTS services (
    name TEXT PRIMARY KEY, host TEXT NOT NULL, project TEXT NOT NULL, copy TEXT NOT NULL,
    worktree TEXT NOT NULL, argv TEXT NOT NULL, env TEXT NOT NULL, owner TEXT,
    keep INTEGER NOT NULL, pid INTEGER, started TEXT, restarts INTEGER NOT NULL,
    state TEXT NOT NULL, start_until INTEGER, end_until INTEGER, log_from INTEGER,
    port INTEGER, local INTEGER, fwd TEXT, opens INTEGER NOT NULL);
  """
  # A file made before a column gains it; a newer file already has it.
  @added [
    "log_from INTEGER",
    "port INTEGER",
    "local INTEGER",
    "fwd TEXT",
    "opens INTEGER NOT NULL DEFAULT 0"
  ]

  @type db :: Store.db()

  @doc "Opens (and creates) the file at `path`, with the table; an older file gains its new columns."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema, added: [services: @added])

  @doc "The row of `name`, or nil."
  @spec get(db, String.t()) :: map | nil
  def get(db, name), do: List.first(select(db, "name=?1", [name]))

  @doc "Every row."
  @spec all(db) :: [map]
  def all(db), do: select(db, "1 = 1", [])

  @doc "Writes the row (a map with every column)."
  @spec put(db, map) :: :ok
  def put(db, row) do
    stored = %{
      row
      | argv: encode(row.argv),
        env: encode(row.env),
        keep: if(row.keep, do: 1, else: 0)
    }

    Store.upsert(db, "services", Enum.map(@columns, &{&1, Map.get(stored, &1)}))
  end

  # argv and env are lists of strings and pairs, kept as one text each.
  defp encode(term), do: term |> :erlang.term_to_binary() |> Base.encode64()
  defp decode(text), do: text |> Base.decode64!() |> :erlang.binary_to_term([:safe])

  defp select(db, where, args) do
    for row <- Store.select(db, "services", @columns, where, args),
        do: %{row | argv: decode(row.argv), env: decode(row.env), keep: row.keep == 1}
  end
end
