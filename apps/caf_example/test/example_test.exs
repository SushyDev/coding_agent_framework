defmodule CodingAgentFramework.ExampleTest do
  # The whole tree under this test's own framework home, with its own tmux server and ports,
  # and the headless stand-in for Claude Code. The test sends no cue: what moves the rows is the
  # tree's own wiring.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Example.Config

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Delegates, Example, HeadlessStandIn, MCP, Tmux}
  alias CodingAgentFramework.Example.Config
  alias CodingAgentFramework.Sessions.Table

  setup do
    dir = test_dir()
    repo = Path.join(dir, "repo")
    git = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    {_, 0} = System.cmd(program!(:git), ["init", "-q", "-b", "main", repo], env: git)
    commit = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "i"]
    {_, 0} = System.cmd(program!(:git), commit ++ ["--allow-empty"], env: git)

    project = %{repo: repo, trunk: "main", setup: [], setup_timeout: 10_000}
    project = Map.merge(project, %{env: %{"HOME" => dir}, branches: ~r/\Aunit\//, cap: 2})
    home = Path.join(dir, "home")

    {:ok, config} =
      Config.new(
        home: home,
        instance: "t",
        programs: programs().paths,
        accounts: ["work"],
        projects: %{"app" => project},
        ports: %{intake: free_port(), mcp: free_port()},
        claude: HeadlessStandIn.write!(dir, :at_start),
        env: %{home: dir, path: "/nonexistent", term: "xterm-256color", lang: "C.UTF-8"},
        interval: 200
      )

    # The account's last weekly reading, as its status line would have written it.
    {:ok, accounts} = Accounts.new(home, ["work"])
    {:ok, file} = Accounts.usage_file(accounts, "work")
    File.mkdir_p!(Path.dirname(file))
    week = %{"seven_day" => %{"used_percentage" => 25, "resets_at" => 4_000_000_000}}
    File.write!(file, JSON.encode!(%{"rate_limits" => week}))

    {:ok, server} = Example.server(config)
    on_exit(fn -> Tmux.kill_server(server) end)
    on_exit(fn -> end_recorded(dir) end)
    {:ok, sessions} = Table.open(Path.join(home, "caf.db"))
    %{config: config, sessions: sessions}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start(config) do
    parts = Example.parts(start_supervised!({Example, config}))
    keys = ~w(reaper control usage stream intake intake_http sampler sessions recoveries tracker)a
    keys = keys ++ ~w(delegates claims mailbox copies jobs services mcp mcp_http ticker)a

    assert Enum.sort(Map.keys(parts)) ==
             Enum.sort(keys ++ [{:registry, "work"}, {:transcripts, "work"}])

    assert Enum.all?(Map.values(parts), &(is_pid(&1) and Process.alive?(&1)))
    parts
  end

  # The tree as `agents()` answers it, once both delegates have given their reports.
  defp settled(parts, ctx) do
    await(
      fn ->
        {:ok, tree} = MCP.call(parts.mcp, "app-main", "agents", %{})
        delegates = Enum.filter(tree.agents, &(&1.kind == "delegate"))
        rows = for d <- delegates, do: Table.get(ctx.sessions, "ws", d.name)

        if length(delegates) == 2 and Enum.all?(delegates, &(&1.state == "idle")) and
             Enum.all?(rows, &(&1.status == "running")),
           do: {:ok, tree}
      end,
      20_000
    )
  end

  test "every part starts; a delegate started through MCP reaches the tree; a restart settles",
       ctx do
    parts = start(ctx.config)

    # Until `Mains`, a main session is known to `Grants` only as a parent a delegate's row
    # names, so its first delegate is started past `MCP` (the note's new-1).
    assert {:refused, {:unknown_agent, "app-main"}} =
             MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/one"))

    assert {:ok, %{name: "app-unit-one"}} =
             Delegates.start_delegate(
               parts.delegates,
               "app-main",
               "app",
               "unit/one",
               "opus",
               "Go."
             )

    assert {:ok, %{delegate: "app-unit-two"}} =
             MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/two"))

    {:ok, tree} = settled(parts, ctx)

    assert [
             %{name: "app-main", kind: "main", parent: nil},
             %{name: "app-unit-one", parent: "app-main", account: "work"},
             %{name: "app-unit-two", parent: "app-main", account: "work"}
           ] = tree.agents

    {:ok, pids} = pids(ctx)

    # A restart on the same home: the parts read their tables again, `Sessions` adopts the
    # held delegates, which ran on, and the tree comes back the same.
    :ok = stop_supervised(Example)
    parts = start(ctx.config)
    {:ok, again} = settled(parts, ctx)
    assert Enum.map(again.agents, & &1.name) == Enum.map(tree.agents, & &1.name)
    assert pids(ctx) == {:ok, pids}

    # The rows came back with the start: a third delegate is past the parent's cap of two.
    assert {:refused, {:cap, _}} =
             MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/three"))
  end

  defp args(branch),
    do: %{"project" => "app", "branch" => branch, "model" => "opus", "brief" => "Go."}

  defp pids(ctx),
    do: {:ok, for(n <- ~w(app-unit-one app-unit-two), do: Table.get(ctx.sessions, "ws", n).pid)}
end
