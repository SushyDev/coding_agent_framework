defmodule CodingAgentFramework.Home do
  @moduledoc """
  A home's kind (F-214): `agents` or `agentless` for its whole life. An agentless tree (`agents:
  false`) asks only `Jobs` about a lease, so on a home an agentful tree used, the leases of
  that tree's delegates, mains and runs would stay unasked and never be reclaimed (F-195's
  new-2). So a home records its kind once, and a tree of the other kind is refused on it.

  The mark is the one row of the table `home` in the home's own database (`<home>/caf.db`). The
  first start on a home writes it, before any part starts, and every later start reads it:

    * A home with no mark and no agent, delegate or main rows is new, and takes the kind of the
      tree that starts on it.
    * A home with no mark whose database already holds agent rows (a main session is one, of
      kind `main`) or delegate rows ran before the mark existed, and only an agentful tree
      writes those: it is marked `agents`, whatever kind of tree starts on it.
    * A tree of the other kind than the mark is refused, `{:refused, {:home_kind, recorded}}`.

  The kind is judged by rows, not by the tables an agentful tree made, because a lease follows
  its owner's row: a home whose tables hold no row has no lease an agentless tree would leave
  unasked (F-214's new-3).

  A pure module: it starts no process and keeps no connection. The read and the write of the
  mark are one immediate transaction (`Store.write/3`). A start marks the home only once it
  holds it (`CodingAgentFramework.Home.Lock`, F-215), so no two trees mark one home at once;
  the transaction still keeps the read and the write together for any other writer of
  `caf.db`.

      iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
      ...>   programs: %{}, env: %{path: "/bin"}, agents: false)
      iex> CodingAgentFramework.Home.wanted(c)
      :agentless
  """

  alias CodingAgentFramework.{Config, Store}

  @type kind :: :agents | :agentless

  @schema """
  CREATE TABLE IF NOT EXISTS home (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    kind TEXT NOT NULL CHECK (kind IN ('agents', 'agentless')),
    marked_at INTEGER NOT NULL);
  """

  # What only an agentful tree writes: the agent rows (`Sessions`, a main session's among them)
  # and the delegate rows (`Delegates`). No agentless part makes either table.
  @agent_tables ["agents", "delegates"]

  @doc """
  The kind of tree `config` starts: `:agents` for a tree that runs agents, `:agentless` for one
  with `agents: false`.
  """
  @spec wanted(Config.t()) :: kind
  def wanted(%Config{agents: false}), do: :agentless
  def wanted(%Config{}), do: :agents

  @doc """
  Records the home's kind on the tree's first start and checks the tree against it. Answers
  `:ok` when the home is marked with the kind `config` starts, or is new and now takes it (or
  was marked `agents` for the rows it already held, and `config` starts agents);
  `{:refused, {:home_kind, recorded}}` when the mark, or the rows of a home with none, say the
  other kind, writing nothing but that mark; `{:refused, {:sqlite, reason}}` when the database
  cannot be opened; or `{:unknown, {:home_mark, text}}` when a statement failed, so that the
  mark may or may not be written.
  """
  @spec mark(Config.t()) :: :ok | {:refused, term} | {:unknown, term}
  def mark(%Config{} = c) do
    wanted = wanted(c)

    case Store.write(path(c), @schema, &claim(&1, wanted)) do
      {:ok, ^wanted} -> :ok
      {:ok, recorded} -> {:refused, {:home_kind, recorded}}
      {:refused, _} = refused -> refused
    end
  rescue
    exception -> {:unknown, {:home_mark, Exception.message(exception)}}
  end

  # The read and the write of the first mark, in one transaction.
  defp claim(db, wanted) do
    case recorded(db) do
      nil ->
        kind = if rows?(db, tables(db)), do: :agents, else: wanted
        fields = [id: 1, kind: Atom.to_string(kind), marked_at: System.os_time(:millisecond)]
        Store.insert(db, "home", fields)
        kind

      kind ->
        kind
    end
  end

  @doc """
  The kind of the home `config` names, read now, as the next start would find it: `{:ok,
  :agents}` or `{:ok, :agentless}` for a marked home, or for an unmarked one whose database
  holds agent or delegate rows (`:agents`, which the next start marks); `{:ok, :new}` for a home
  with no database or none of those rows; `{:refused, reason}` when the database cannot be read.
  It opens the database read-only, makes no file, writes nothing and starts no process.
  """
  @spec kind(Config.t()) :: {:ok, kind | :new} | {:refused, term}
  def kind(%Config{} = c) do
    path = path(c)

    if File.regular?(path), do: Store.snapshot(path, &read/2), else: {:ok, :new}
  rescue
    exception -> {:refused, {:home_mark, Exception.message(exception)}}
  end

  defp read(db, tables) do
    case "home" in tables and recorded(db) do
      kind when kind in [:agents, :agentless] -> kind
      _unmarked -> if rows?(db, tables), do: :agents, else: :new
    end
  end

  # The mark, or nil before it is written.
  defp recorded(db) do
    case Store.select(db, "home", [:kind], "id = 1", []) do
      [] -> nil
      [%{kind: "agents"}] -> :agents
      [%{kind: "agentless"}] -> :agentless
    end
  end

  defp tables(db) do
    names = Store.query(db, "SELECT name FROM sqlite_master WHERE type = 'table'", [])
    MapSet.new(names, &hd/1)
  end

  defp rows?(db, tables) do
    Enum.any?(@agent_tables, fn table ->
      table in tables and Store.query(db, "SELECT 1 FROM #{table} LIMIT 1", []) != []
    end)
  end

  defp path(c), do: Config.path(c, "caf.db")
end
