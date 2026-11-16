defmodule CodingAgentFramework.ExampleTest do
  # The whole tree under this test's own framework home, with its own tmux server and ports,
  # and the headless stand-in for Claude Code. The test sends no cue: what moves the rows is the
  # tree's own wiring.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Example.Config

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Example, HeadlessStandIn, Jobs, Mailbox, MCP, Services}
  alias CodingAgentFramework.{Delegates, Tmux}
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
        mains: %{"app" => "app-main"},
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
    %{config: config, sessions: sessions, dir: dir, home: home}
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
    keys = keys ++ ~w(delegates claims mailbox copies jobs services mcp mcp_http ticker ends)a

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

  test "a declared main session starts its first delegate through MCP; a restart settles",
       ctx do
    parts = start(ctx.config)

    # The main session is a root of the tree before it has any delegate.
    for branch <- ~w(unit/one unit/two) do
      assert {:ok, %{delegate: "app-" <> _}} =
               MCP.call(parts.mcp, "app-main", "start_delegate", args(branch))
    end

    {:ok, tree} = settled(parts, ctx)

    assert [
             %{name: "app-main", kind: "main", parent: nil},
             %{name: "app-unit-one", parent: "app-main", account: "work"},
             %{name: "app-unit-two", parent: "app-main", account: "work"}
           ] = tree.agents

    # Each delegate's launch names its own MCP config after the account's, and its token
    # calls as that delegate.
    for name <- ~w(app-unit-one app-unit-two) do
      argv = HeadlessStandIn.argv(ctx.dir, Table.get(ctx.sessions, "ws", name).session_id)
      own = Path.join([ctx.home, "parts/mcp/agents", name <> ".json"])

      assert [_account, ^own, "--strict-mcp-config" | _] =
               Enum.drop_while(argv, &(&1 != "--mcp-config")) |> tl()

      %{"mcpServers" => %{"caf" => %{"headers" => %{"x-caf-token" => token}}}} =
        JSON.decode!(File.read!(own))

      assert MCP.who(parts.mcp, token) == {:ok, name}
    end

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

  test "a job's late end goes to its caller as a message from framework, once", ctx do
    # A stand-in job: its call answered `{:unknown, :dropped}`, as `MCP`'s log keeps it, and
    # `Jobs` owes its end, read since. A start hands it on before `MCP` has started.
    for d <- ~w(mcp jobs), do: File.mkdir_p!(Path.join(ctx.home, "parts/#{d}"))
    {:ok, log} = MCP.Table.open(Path.join(ctx.home, "parts/mcp/mcp.db"))
    id = MCP.Table.called(log, "app-main", "run", "{}")
    dropped = MCP.json({:unknown, %{job: "mcp-t-#{id}", reason: :dropped}})
    :ok = MCP.Table.answered(log, id, JSON.encode!(dropped))
    {:ok, jobs} = Jobs.Table.open(Path.join(ctx.home, "parts/jobs/jobs.db"))
    row = %{id: "mcp-t-#{id}", host: "ws", project: "app", name: "app-main", state: "exited"}
    :ok = Jobs.Table.put(jobs, Map.merge(row, %{code: 3, late: "owed"}))

    parts = start(ctx.config)
    {:ok, messages} = Mailbox.Table.open(Path.join(ctx.home, "caf.db"))

    {:ok, m} =
      await(fn ->
        ok(Enum.find(Mailbox.Table.open_rows(messages), &(&1.from_agent == "framework")))
      end)

    assert %{to_agent: "app-main", reply_to: "key:job:mcp-t-" <> _, text: text} = m
    assert text =~ "mcp-t-#{id}" and text =~ "{:exit, 3}" and text =~ "Nothing was fetched"
    assert %{late: "told"} = Jobs.Table.get(jobs, "mcp-t-#{id}")

    # A repeat of the same end, as a crash before `Jobs` marked it told would hand it on.
    assert {:ok, :stored_before} =
             Mailbox.notify(parts.mailbox, "app-main", text, key: "job:mcp-t-#{id}")

    assert {:refused, {:unknown_agent, "nobody"}} = Mailbox.notify(parts.mailbox, "nobody", "x")
  end

  test "a delegate's end ends its services, and hands a kept one to its parent", ctx do
    # The brief's turn waits on a permission, so the delegate runs until it is killed twice.
    File.write!(Path.join(ctx.dir, "hold"), "")
    parts = start(ctx.config)
    {:ok, _} = MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/one"))
    {:ok, ddb} = Delegates.Table.open(Path.join(ctx.home, "caf.db"))
    svc = Path.join(ctx.dir, "svc")
    argv = [program!(:sh), "-c", echo_tail!(svc), Path.join(svc, "it")]

    for {name, keep} <- [{"plain", false}, {"kept", true}] do
      {:ok, %{state: "running"}} =
        MCP.call(parts.mcp, "app-unit-one", "service_start", %{
          "name" => name,
          "argv" => argv,
          "opts" => %{"keep" => keep}
        })
    end

    # A first kill is resumed; the second before its last reply ends the delegate as `failed`,
    # which a `delegates:` cue shows.
    killed = kill_delegate(ctx, [], 1)
    {:ok, _} = row(ddb, &(&1.resumes == 1 and &1.status == "running"))
    kill_delegate(ctx, killed, 2)
    {:ok, _} = row(ddb, &(&1.status == "failed"))

    {:ok, rows} =
      await(
        fn ->
          rows = Map.new(Services.list(parts.services), &{&1.name, &1})
          if rows["plain"].state == "ended" and rows["kept"].owner == "app-main", do: {:ok, rows}
        end,
        20_000
      )

    assert %{state: "running"} = rows["kept"]
    {:ok, _} = Services.stop(parts.services, "app-main", "kept", [])
  end

  # Kills the delegate's current process, once the stand-in has taken `n` messages.
  defp kill_delegate(ctx, killed, n) do
    pids = Path.join(ctx.dir, "pids")

    {:ok, pid} =
      await(
        fn ->
          if length(HeadlessStandIn.taken(ctx.dir)) >= n,
            do: ok(List.first(File.ls!(pids) -- killed))
        end,
        20_000
      )

    kill(pid)
    [pid | killed]
  end

  defp row(ddb, ok?) do
    await(
      fn ->
        row = List.last(Delegates.Table.rows(ddb, "ws"))
        if row && ok?.(row), do: {:ok, row}, else: row
      end,
      20_000
    )
  end

  defp ok(nil), do: nil
  defp ok(value), do: {:ok, value}

  defp args(branch),
    do: %{"project" => "app", "branch" => branch, "model" => "opus", "brief" => "Go."}

  defp pids(ctx),
    do: {:ok, for(n <- ~w(app-unit-one app-unit-two), do: Table.get(ctx.sessions, "ws", n).pid)}
end
