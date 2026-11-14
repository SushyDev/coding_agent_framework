defmodule CodingAgentFramework.SessionsTest do
  @moduledoc """
  `Sessions` on a real tmux server and real dtach sockets in this test's own directory, with a
  stand-in for Claude Code (`CodingAgentFramework.ClaudeStandIn`). Each test waits on what the
  stand-in writes and on the rows `Sessions` writes, never on a fixed sleep.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, ClaudeStandIn, Control, Holder, Registry, Sessions, Tmux}
  alias CodingAgentFramework.Sessions.Table
  alias CodingAgentFramework.Tmux.CLI
  alias CodingAgentFramework.Tracker.SessionsSource

  setup do
    dir = test_dir()
    {:ok, server} = CLI.new(programs(), {:socket, Path.join(dir, "tmux.sock")})
    on_exit(fn -> Tmux.kill_server(server) end)
    control = start_supervised!({Control, tmux: server})

    {:ok, accounts} = Accounts.new(Path.join(dir, "home"), ["work"])
    {:ok, account} = Accounts.prepare(accounts, "work", %{})
    File.mkdir_p!(Path.join(account.config_dir, "sessions"))
    db = Path.join(dir, "caf.db")

    registry =
      start_supervised!(
        {Registry, programs: programs(), account: "work", config_dir: account.config_dir, db: db}
      )

    dtach = Path.join(dir, "d")
    File.mkdir_p!(dtach)
    {:ok, holder} = Holder.new(programs(), dtach)
    me = self()

    opts = [
      programs: programs(),
      dir: dtach,
      control: control,
      registries: %{"work" => registry},
      db: db,
      notify: &send(me, {:cue, &1}),
      poll: 50
    ]

    {:ok, table} = Table.open(db)
    on_exit(fn -> ClaudeStandIn.kill_all(dir) end)

    {:ok,
     dir: dir,
     account: account,
     control: control,
     holder: holder,
     table: table,
     opts: opts,
     sessions: start_supervised!(Supervisor.child_spec({Sessions, opts}, restart: :temporary))}
  end

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

    assert {:refused, {:turn, :busy}} = Sessions.stop(ctx.sessions, "alpha", :busy)
    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "alpha", :ended)
    refute alive?(pid)
    assert %{status: "stopped"} = Table.get(ctx.table, "test", "alpha")
  end

  test "a resume holds the stand-in with --resume and its id", ctx do
    assert {:ok, %{session_id: "earlier-1"}} =
             Sessions.resume(
               ctx.sessions,
               "beta",
               ctx.account,
               "earlier-1",
               launch(ctx, :at_start)
             )

    assert %{status: "running", resume: "earlier-1"} = Table.get(ctx.table, "test", "beta")
  end

  test "a start whose session file never comes answers unknown, and its row says so", ctx do
    assert {:unknown, :no_session_file} =
             Sessions.start(ctx.sessions, "gamma", ctx.account, launch(ctx, :never),
               timeout: 1_000
             )

    assert %{status: "unknown", reason: "no_session_file", pid: nil} =
             Table.get(ctx.table, "test", "gamma")
  end

  test "a restart mid-start adopts a live start and ends a dead one as interrupted", ctx do
    live =
      Task.async(fn -> Sessions.start(ctx.sessions, "live", ctx.account, launch(ctx, :on_go)) end)

    assert {:ok, _} = row_when(ctx, "live", &(&1.viewer == "open"))

    # The dead one's stand-in is in a directory of its own, so the test ends it by its pid.
    dead_dir = Path.join(ctx.dir, "dead")
    File.mkdir_p!(dead_dir)
    launch = Keyword.put(launch(ctx, :never), :claude, ClaudeStandIn.write!(dead_dir, :never))
    dead = Task.async(fn -> Sessions.start(ctx.sessions, "dead", ctx.account, launch) end)
    assert {:ok, _} = row_when(ctx, "dead", &(&1.viewer != nil))

    Process.exit(ctx.sessions, :kill)
    assert {:unknown, {:exit, :killed}} = Task.await(live)
    assert {:unknown, {:exit, :killed}} = Task.await(dead)
    pids = Path.join(dead_dir, "pids")
    assert {:ok, _} = await(fn -> if File.ls!(pids) != [], do: {:ok, :recorded} end)
    ClaudeStandIn.kill_all(dead_dir)
    assert {:ok, :absent} = await(fn -> absent(Holder.state(ctx.holder, "dead")) end, 10_000)

    # The live stand-in writes its session file only now, while no Sessions runs.
    assert {:ok, :sent} = Control.send(ctx.control, "live", "go")
    sessions = Path.join(ctx.account.config_dir, "sessions")
    assert {:ok, _} = await(fn -> if File.ls!(sessions) != [], do: {:ok, :written} end)

    start_supervised!(Supervisor.child_spec({Sessions, ctx.opts}, id: :again))
    assert {:ok, %{pid: pid}} = row_when(ctx, "live", &(&1.status == "running"))
    assert alive?(pid)
    assert {:ok, _} = row_when(ctx, "dead", &(&1.status == "refused"))
    assert %{reason: "interrupted"} = Table.get(ctx.table, "test", "dead")
  end

  defp launch(ctx, mode) do
    env = %{home: ctx.dir, path: "/nonexistent", term: "xterm-256color", lang: "C.UTF-8"}
    claude = ClaudeStandIn.write!(ctx.dir, mode)
    [role: :delegate, cwd: ctx.dir, claude: claude, model: "opus", env: env, prompt: "brief"]
  end

  defp absent({:ok, :absent}), do: {:ok, :absent}
  defp absent(other), do: {:not_yet, other}

  defp row_when(ctx, name, ready?) do
    await(
      fn ->
        row = Table.get(ctx.table, "test", name)
        if row && ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end
end
