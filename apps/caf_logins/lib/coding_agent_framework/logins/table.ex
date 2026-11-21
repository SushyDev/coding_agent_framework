defmodule CodingAgentFramework.Logins.Table do
  @moduledoc """
  `logins`: one row per account whose login was checked. `CodingAgentFramework.Logins` is its
  one writer; this module is its SQL, and the read `Prompts` makes of the `login` prompts
  (`refused/1`).

  Its columns: `account`, `state` (`logged_in`, `logged_out`, `expired`, or `unknown` when the
  check could not tell), `method` (Claude Code's `authMethod`), `expires_at` (ms, or nil),
  `problem` (why a check could not tell, as text), `checked_at` (ms) and `refused_at` (ms, when
  the login was first found refused since it was last logged in; nil while logged in).

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "logins.db")
      iex> {:ok, db} = CodingAgentFramework.Logins.Table.open(path)
      iex> CodingAgentFramework.Logins.Table.refused(db)
      []
  """

  alias CodingAgentFramework.Store

  @schema """
  CREATE TABLE IF NOT EXISTS logins (
    id INTEGER PRIMARY KEY, account TEXT NOT NULL UNIQUE, state TEXT NOT NULL, method TEXT,
    expires_at INTEGER, problem TEXT, checked_at INTEGER NOT NULL, refused_at INTEGER);
  """
  @columns ~w(id account state method expires_at problem checked_at refused_at)a

  @type db :: Store.db()

  @doc "Opens (and creates) the file at `path` with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema)

  @doc "Every row, by account."
  @spec rows(db) :: %{String.t() => map}
  def rows(db), do: Map.new(Store.select(db, "logins", @columns, "1 = 1", []), &{&1.account, &1})

  @doc "The rows of a login refused (`logged_out` or `expired`), oldest refusal first."
  @spec refused(db) :: [map]
  def refused(db),
    do: Store.select(db, "logins", @columns, "refused_at IS NOT NULL ORDER BY refused_at, id", [])

  @doc "Writes `account`'s row; answers its id."
  @spec put(db, String.t(), map) :: integer
  def put(db, account, fields) do
    fields = Keyword.new(Map.take(fields, @columns -- [:id, :account]))
    sets = Enum.map_join(fields, ",", fn {k, _} -> "#{k} = excluded.#{k}" end)

    [[id]] =
      Store.insert(
        db,
        "logins",
        [{:account, account} | fields],
        "ON CONFLICT (account) DO UPDATE SET #{sets} RETURNING id"
      )

    id
  end
end
