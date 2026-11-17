defmodule CodingAgentFramework.SessionsSourceTest do
  @moduledoc """
  `SessionsSource` reads the rows `Sessions` writes, on a real tmux server and real dtach sockets
  in this test's own directory, with a stand-in for Claude Code.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.SessionsSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Sessions, SessionsSetup}
  alias CodingAgentFramework.Sessions.Table
  alias CodingAgentFramework.Tracker.SessionsSource

  setup {SessionsSetup, :sessions}

  test "a start is confirmed by the session file naming the held pid, and a stop ends it", ctx do
    assert {:ok, %{name: "alpha", pid: pid, session_id: id}} =
             Sessions.start(ctx.sessions, "alpha", ctx.account, launch(ctx, :at_start))

    assert alive?(pid)
    row = Table.get(ctx.table, "test", "alpha")
    assert %{status: "running", pid: ^pid, session_id: ^id, viewer: "open", socket: "alpha"} = row
    assert_received {:cue, %{topic: "sessions:test:work", ids: [_]}}

    {:ok, source} = SessionsSource.open(db: ctx.opts[:db], host: "test", account: "work")

    assert {:ok, %{rows: [%{name: "alpha", status: "running"}]}} =
             SessionsSource.read(source, :all)

    assert {:refused, {:exists, "running"}} =
             Sessions.start(ctx.sessions, "alpha", ctx.account, launch(ctx, :at_start))

    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "alpha")
    refute alive?(pid)
    assert %{status: "stopped"} = Table.get(ctx.table, "test", "alpha")
  end
end
