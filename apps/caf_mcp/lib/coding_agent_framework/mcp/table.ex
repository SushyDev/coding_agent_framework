defmodule CodingAgentFramework.MCP.Table do
  @moduledoc """
  `MCP`'s two tables, which `CodingAgentFramework.MCP` alone writes.

  - `mcp_tokens`: one row per agent, the SHA-256 of its token. Only the hash is kept, so the
    file never holds a token a reader could use; a new token for an agent replaces the old.
  - `mcp_calls`: one row per tool call, written `called` with its caller, tool and arguments
    before it acts, then `answered` with its outcome. A row still `called` when `MCP` starts is
    marked `cut`: a restart ended its call, and what it did is unknown.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.MCP.Table.open(path)
      iex> CodingAgentFramework.MCP.Table.agent(db, "no-such-token")
      nil
  """

  alias CodingAgentFramework.Store
  alias Exqlite.Sqlite3

  @schema """
  CREATE TABLE IF NOT EXISTS mcp_tokens (agent TEXT PRIMARY KEY, hash BLOB NOT NULL UNIQUE);
  CREATE TABLE IF NOT EXISTS mcp_calls (
    id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL, tool TEXT NOT NULL,
    args TEXT NOT NULL, state TEXT NOT NULL, outcome TEXT, called_at INTEGER NOT NULL,
    answered_at INTEGER);
  UPDATE mcp_calls SET state = 'cut' WHERE state = 'called';
  """

  @type db :: Store.db()

  @doc "Opens (and creates) the file at `path`, and marks each call a restart cut."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema)

  @doc "Keeps `token`'s hash as `agent`'s, in place of any earlier one."
  @spec put_token(db, String.t(), String.t()) :: :ok
  def put_token(db, agent, token) do
    Store.query(db, "INSERT OR REPLACE INTO mcp_tokens (agent, hash) VALUES (?1, ?2)", [
      agent,
      {:blob, hash(token)}
    ])

    :ok
  end

  @doc "The agent whose token is `token`, or nil."
  @spec agent(db, String.t()) :: String.t() | nil
  def agent(db, token) do
    case Store.query(db, "SELECT agent FROM mcp_tokens WHERE hash = ?1", [{:blob, hash(token)}]) do
      [[agent]] -> agent
      [] -> nil
    end
  end

  @doc "Writes a call's row `called` and answers its id."
  @spec called(db, String.t(), String.t(), String.t()) :: integer
  def called(db, agent, tool, args) do
    [[id]] =
      Store.query(
        db,
        "INSERT INTO mcp_calls (agent, tool, args, state, called_at) VALUES (?1, ?2, ?3, 'called', ?4) RETURNING id",
        [agent, tool, args, now()]
      )

    id
  end

  @doc "Writes the outcome of call `id`."
  @spec answered(db, integer, String.t()) :: :ok
  def answered(db, id, outcome) do
    Store.query(
      db,
      "UPDATE mcp_calls SET state = 'answered', outcome = ?2, answered_at = ?3 WHERE id = ?1",
      [id, outcome, now()]
    )

    :ok
  end

  @doc "Every call's row, oldest first, for a view or a test."
  @spec calls(db) :: [map]
  def calls(db) do
    for [id, agent, tool, args, state, outcome] <-
          Store.query(
            db,
            "SELECT id, agent, tool, args, state, outcome FROM mcp_calls ORDER BY id",
            []
          ),
        do: %{id: id, agent: agent, tool: tool, args: args, state: state, outcome: outcome}
  end

  @doc """
  The agent that made `run` call `id`, read from the file at `path` by a reader of its own,
  opened read-only, so no part's process is asked and the writer's open marks nothing `cut`.
  Answers `{:ok, agent}`, `{:refused, {:no_call, id}}`, or `{:unknown, reason}` when the file
  cannot be read.
  """
  @spec caller(String.t(), integer) :: {:ok, String.t()} | {:refused, term} | {:unknown, term}
  def caller(path, id) do
    with {:ok, db} <- Sqlite3.open(path, mode: :readonly) do
      try do
        case Store.query(db, "SELECT agent FROM mcp_calls WHERE id = ?1 AND tool = 'run'", [id]) do
          [[agent]] -> {:ok, agent}
          [] -> {:refused, {:no_call, id}}
        end
      rescue
        e in MatchError -> {:unknown, {:read, e.term}}
      after
        Sqlite3.close(db)
      end
    else
      {:error, reason} -> {:unknown, {:open, reason}}
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
  defp now, do: System.system_time(:millisecond)
end
