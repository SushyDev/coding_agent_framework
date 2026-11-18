defmodule CodingAgentFramework.AgentsTest do
  @moduledoc """
  The agent row: an earlier build's `held_sessions` taken on open, a declared main session, a
  delegate's end, the migration's hand-over from `Delegates`, and the tree `Sessions.Agents`
  reads, over a real `Sessions` (`SessionsSetup`).
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.SessionsSetup

  alias CodingAgentFramework.{Sessions, SessionsSetup, Store}
  alias CodingAgentFramework.Sessions.{Agents, Table}

  doctest Agents
  doctest Table

  setup {SessionsSetup, :sessions}

  test "an earlier build's held_sessions is taken into agents once, ids and kinds kept" do
    path = Path.join(CodingAgentFramework.TestHost.test_dir(), "old.db")

    {:ok, db} =
      Store.open(path, """
      CREATE TABLE held_sessions (id INTEGER PRIMARY KEY, host TEXT NOT NULL, name TEXT NOT NULL,
        socket TEXT NOT NULL, account TEXT NOT NULL, role TEXT NOT NULL, cwd TEXT NOT NULL,
        resume TEXT, status TEXT NOT NULL, reason TEXT, viewer TEXT, pid INTEGER,
        session_id TEXT, proc_start TEXT, started_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL, UNIQUE (host, name));
      """)

    for {id, name, role} <- [{4, "app-main", "parent"}, {9, "app-fix", "delegate"}] do
      Store.insert(db, "held_sessions",
        id: id,
        host: "h",
        name: name,
        socket: name,
        account: "work",
        role: role,
        cwd: "/w",
        status: "running",
        started_at: 1,
        updated_at: 1
      )
    end

    {:ok, agents} = Agents.open(path, "h")
    assert Agents.rows(agents) == []

    {:ok, db} = Table.open(path)
    assert %{id: 4, kind: "main", parent: nil, role: "parent"} = Table.get(db, "h", "app-main")

    assert %{id: 9, kind: "delegate", parent: nil, status: "running"} =
             Table.get(db, "h", "app-fix")

    assert Store.query(db, "SELECT 1 FROM sqlite_master WHERE name = 'held_sessions'", []) == []

    # A delegate with no parent yet is no agent of the tree: Delegates hands its parent over.
    assert [%{name: "app-main"}] = Agents.read_tree(agents)
    {:ok, _} = Table.open(path)
    assert length(Agents.rows(agents)) == 2
  end

  test "a declared main session is a row of the tree; a delegate names its parent", ctx do
    sessions = start_supervised!(Supervisor.child_spec({Sessions, ctx.opts}, id: :declared))
    {:ok, agents} = Agents.open(ctx.opts[:db], "test")
    assert {:ok, %{status: "declared"}} = Sessions.declare(sessions, "main", "app")

    assert [%{name: "main", kind: "main", project: "app", status: "declared"}] =
             Agents.read_tree(agents)

    assert Agents.declared?(Agents.get(agents, "main"))

    # A name that cannot be a session's is never declared.
    assert {:refused, {:bad, :name}} = Sessions.declare(sessions, "../x", "app")

    assert {:refused, {:missing, :parent}} =
             Sessions.start(
               sessions,
               "lone",
               ctx.account,
               Keyword.delete(headless(ctx, :at_start), :parent)
             )

    assert {:refused, {:bad, :parent}} =
             Sessions.start(
               sessions,
               "two",
               ctx.account,
               launch(ctx, :at_start) ++ [parent: "main"]
             )

    # The declared main starts on its own row, which keeps its project.
    {:ok, _} = Sessions.start(sessions, "main", ctx.account, launch(ctx, :at_start))
    assert %{kind: "main", project: "app", status: "running"} = Agents.get(agents, "main")
    assert {:refused, :main} = Sessions.ended(sessions, "main")
  end

  test "a delegate ends only once no process of it may live, and frees its parent's cap", ctx do
    {:ok, agents} = Agents.open(ctx.opts[:db], "test")
    {:ok, _} = Sessions.start(ctx.sessions, "app-fix", ctx.account, headless(ctx, :at_start))
    assert Agents.children(agents, "main") == 1
    assert {:refused, {:not_free, "running"}} = Sessions.ended(ctx.sessions, "app-fix")

    {:ok, :stopped} = Sessions.stop(ctx.sessions, "app-fix")
    assert Agents.holds?(Agents.get(agents, "app-fix"))
    assert {:ok, :ended} = Sessions.ended(ctx.sessions, "app-fix")
    assert {:ok, :ended} = Sessions.ended(ctx.sessions, "app-fix")

    row = Agents.get(agents, "app-fix")
    assert Agents.ended?(row) and Agents.free?(row)
    assert Agents.children(agents, "main") == 0
    assert Agents.ended_names(agents, [row.id]) == ["app-fix"]
    assert {:refused, :no_session} = Sessions.ended(ctx.sessions, "nobody")
  end

  test "the migration's hand-over gives a delegate with no parent its parent and its end", ctx do
    row = %{host: "test", name: "app-old", kind: "delegate", socket: "app-old", account: "work"}
    id = Table.starting(ctx.table, Map.merge(row, %{role: "delegate", cwd: ctx.dir}))
    Table.update(ctx.table, id, status: "stopped")
    {:ok, agents} = Agents.open(ctx.opts[:db], "test")
    refute Agents.holds?(Agents.get(agents, "app-old"))

    entries = [
      %{name: "app-old", parent: "main", project: "app", ended: true},
      %{name: "nobody", parent: "main", project: "app", ended: false}
    ]

    assert {:ok, 1} = Sessions.adopt_tree(ctx.sessions, entries)
    assert %{parent: "main", project: "app", status: "ended"} = Agents.get(agents, "app-old")
    # Taken once: a row with a parent takes nothing more.
    assert {:ok, 0} = Sessions.adopt_tree(ctx.sessions, entries)
  end
end
