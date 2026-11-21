defmodule CodingAgentFramework.Mains.Table do
  @moduledoc """
  `checkouts`: one row per project's checkout on a host, the reading a view shows of it
  (`docs/design.md`, "Main sessions": "its checkout: trunk, ahead and behind its remote, and
  whether it is clean"), keyed by `{host, project}`. `Mains` alone writes it, after each clone,
  read and pull.

  `state` is `absent`, `cloning`, `failed` (the clone or a read failed; `reason` says why), or a
  reading's (`CodingAgentFramework.Mains.Checkout`): `ready`, `behind`, `dirty`, `ahead`,
  `off_trunk`. `branch`, `clean`, `ahead` and `behind` are the last reading's; `owed` whether a
  pull is owed (after a landing, a start of `Mains`, or a pull a state other than `ready` or
  `behind` held back); `reason` why the last pull did not go or failed; `read_at` and
  `pulled_at` are wall-clock ms.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Mains.Table.open(path)
      iex> CodingAgentFramework.Mains.Table.get(db, "ws", "app")
      nil
  """

  alias CodingAgentFramework.Store

  @columns ~w(id host project path trunk state branch clean ahead behind owed reason read_at
              pulled_at updated_at)a

  @schema """
  CREATE TABLE IF NOT EXISTS checkouts (
    id INTEGER PRIMARY KEY, host TEXT NOT NULL, project TEXT NOT NULL, path TEXT NOT NULL,
    trunk TEXT NOT NULL, state TEXT NOT NULL, branch TEXT, clean TEXT, ahead INTEGER,
    behind INTEGER, owed TEXT, reason TEXT, read_at INTEGER, pulled_at INTEGER,
    updated_at INTEGER NOT NULL, UNIQUE (host, project));
  """

  @type db :: Store.db()

  @doc """
  The table's metadata for `CodingAgentFramework.Reader`'s `Tracker` source: a writer's table,
  read now; topic `mains:<host>`, scope `{host, "checkouts"}`, rows of kind `:checkouts`.
  """
  @spec meta() :: map
  def meta do
    %{
      schema: @schema,
      table: "checkouts",
      reads: nil,
      columns: @columns,
      scope: [],
      filter: [:host],
      topic: "mains",
      group: "checkouts",
      kind: :checkouts,
      name: nil
    }
  end

  @doc "Opens (and creates) the file at `path`, with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema)

  @doc """
  Writes the checkout of `{host, project}` with `fields`, making its row when it has none.
  Answers the row's id.
  """
  @spec put(db, String.t(), String.t(), keyword) :: integer
  def put(db, host, project, fields) do
    now = System.os_time(:millisecond)

    id =
      case get(db, host, project) do
        nil ->
          first = [host: host, project: project, path: "", trunk: "", state: "absent"]
          [[id]] = Store.insert(db, "checkouts", first ++ [updated_at: now], "RETURNING id")
          id

        row ->
          row.id
      end

    Store.update(db, "checkouts", id, fields ++ [updated_at: now])
    id
  end

  @doc "The checkout of `{host, project}`, or nil."
  @spec get(db, String.t(), String.t()) :: map | nil
  def get(db, host, project) do
    db
    |> Store.select("checkouts", @columns, "host = ?1 AND project = ?2", [host, project])
    |> List.first()
  end

  @doc "The host's checkouts, by project."
  @spec rows(db, String.t()) :: [map]
  def rows(db, host),
    do: Store.select(db, "checkouts", @columns, "host = ?1 ORDER BY project", [host])

  @doc "`project`'s checkout on every host that has one, by host: what an import reads (F-156)."
  @spec project_rows(db, String.t()) :: [map]
  def project_rows(db, project),
    do: Store.select(db, "checkouts", @columns, "project = ?1 ORDER BY host", [project])
end
