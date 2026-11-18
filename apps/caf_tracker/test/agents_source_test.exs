defmodule CodingAgentFramework.AgentsSourceTest do
  @moduledoc """
  The agent rows `Sessions` writes, read as a `Tracker` source made from `Sessions.Table.meta/0`
  and folded into the tree, on a real tmux server and real dtach sockets in this test's own
  directory, with a stand-in for Claude Code.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.SessionsSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Sessions, SessionsSetup, Tracker}
  alias CodingAgentFramework.Sessions.{Agents, Table}
  alias CodingAgentFramework.Tracker.TableSource

  setup {SessionsSetup, :sessions}

  test "a start is an agent row of the host, read by its metadata, and a stop ends it", ctx do
    assert {:ok, %{name: "alpha", pid: pid, session_id: id}} =
             Sessions.start(ctx.sessions, "alpha", ctx.account, launch(ctx, :at_start))

    assert alive?(pid)
    row = Table.get(ctx.table, "test", "alpha")

    assert %{status: "running", kind: "main", parent: nil, pid: ^pid, session_id: ^id} = row
    assert %{viewer: "open", socket: "alpha"} = row
    assert_received {:cue, %{topic: "sessions:test", ids: [_]}}

    opts = [table: Table, db: ctx.opts[:db], host: "test"]
    assert %{topic: "sessions:test", scope: {"test", "agents"}} = TableSource.describe(opts)
    {:ok, source} = TableSource.open(opts)

    assert {:ok, %{rows: [%{name: "alpha", status: "running"}]}} =
             TableSource.read(source, :all)

    assert {:refused, {:exists, "running"}} =
             Sessions.start(ctx.sessions, "alpha", ctx.account, launch(ctx, :at_start))

    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "alpha")
    refute alive?(pid)
    assert %{status: "stopped"} = Table.get(ctx.table, "test", "alpha")
  end

  test "the app's metadata given at a start is read back through Agents and the source", ctx do
    meta = %{"ticket" => 41, "labels" => ["ui"]}
    launch = launch(ctx, :at_start) ++ [meta: meta]

    assert {:refused, {:bad, :meta}} =
             Sessions.start(
               ctx.sessions,
               "alpha",
               ctx.account,
               launch(ctx, :at_start) ++ [meta: [ticket: 41]]
             )

    assert {:ok, _} = Sessions.start(ctx.sessions, "alpha", ctx.account, launch)

    {:ok, agents} = Agents.open(ctx.opts[:db], "test")
    assert Agents.meta(Agents.get(agents, "alpha")) == meta

    {:ok, source} = TableSource.open(table: Table, db: ctx.opts[:db], host: "test")
    {:ok, %{rows: [row]}} = TableSource.read(source, :all)
    assert Agents.meta(row) == meta

    # Set later by the app, in place of what it had; a start that names none keeps it.
    assert {:ok, _} = Sessions.put_meta(ctx.sessions, "alpha", %{"ticket" => 42})
    assert {:refused, :no_session} = Sessions.put_meta(ctx.sessions, "nobody", %{})
    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "alpha")
    assert {:ok, _} = Sessions.start(ctx.sessions, "alpha", ctx.account, launch(ctx, :at_start))
    assert Agents.meta(Agents.get(agents, "alpha")) == %{"ticket" => 42}
    assert Agents.meta(Agents.get(agents, "nobody")) == %{}
  end

  test "the Tracker's tree holds what Sessions' tree holds: the main and its delegate", ctx do
    {:ok, _} = Sessions.start(ctx.sessions, "main", ctx.account, launch(ctx, :at_start))
    launch = headless(ctx, :on_message) ++ [project: "app"]
    {:ok, %{session_id: sid}} = Sessions.start(ctx.sessions, "app-fix", ctx.account, launch)

    tracker =
      start_supervised!(
        {Tracker, sources: [{TableSource, table: Table, db: ctx.opts[:db], host: "test"}]}
      )

    {:ok, %{agents: agents}} = Tracker.agents(tracker)

    assert [%{name: "main", kind: "main"}, %{name: "app-fix", kind: "delegate", parent: "main"}] =
             Enum.sort_by(agents, &(&1.kind != "main"))

    assert %{session_id: ^sid, state: "unread"} = Enum.find(agents, &(&1.kind == "delegate"))
  end
end
