defmodule CodingAgentFramework.ExampleTest do
  # The whole tree under this test's own framework home, with its own tmux server and ports,
  # and the headless stand-in for Claude Code. The test sends no cue: what moves the rows is the
  # tree's own wiring.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Example.Config

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Example, HeadlessStandIn, Jobs, Mailbox, MCP, Services}
  alias CodingAgentFramework.{Delegates, Operator, Tmux}
  alias CodingAgentFramework.Grants.Claims
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

  test "a delegate stopped after its report is `ended`, and its services end", ctx do
    parts = start(ctx.config)

    {:ok, %{delegate: "app-unit-one"}} =
      MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/one"))

    {:ok, ddb} = Delegates.Table.open(Path.join(ctx.home, "caf.db"))
    {:ok, %{id: id}} = row(ddb, &(&1.name == "app-unit-one"))
    svc = Path.join(ctx.dir, "svc")
    argv = [program!(:sh), "-c", echo_tail!(svc), Path.join(svc, "it")]

    {:ok, %{state: "running"}} =
      MCP.call(parts.mcp, "app-unit-one", "service_start", %{"name" => "plain", "argv" => argv})

    # Its report is taken and answered to its agent, as `run_delegate` does; then it is stopped.
    {:ok, _} = row(ddb, &(&1.id == id and &1.status == "finished"))
    assert {:ok, %{id: ^id}} = Delegates.await_report(parts.delegates, "app-main", id, 5_000)
    assert {:ok, :answered} = Delegates.answered(parts.delegates, id)
    {:ok, state} = Delegates.fix_state(parts.delegates, "app-main", "app-unit-one")
    fix = Delegates.fix(parts.delegates, "app-main", "app-unit-one", :stop, state)
    assert {:ok, :stopped} = fix

    # No cue from the test: the stop's own end writes `ended`, a `delegates:` cue shows it, and
    # the app ends the services the delegate owned.
    {:ok, _} = row(ddb, &(&1.id == id and &1.status == "ended"))

    {:ok, _} =
      await(
        fn ->
          plain = Enum.find(Services.list(parts.services), &(&1.name == "plain"))
          if plain && plain.state == "ended", do: {:ok, plain}
        end,
        20_000
      )
  end

  test "the operator starts a delegate, messages it and interrupts it, each in its name", ctx do
    parts = start(ctx.config)

    assert {:ok, %{delegate: "app-unit-one"}} =
             Operator.start_delegate(parts.mcp, "app-main", "app", "unit/one", "opus", "Go.")

    {:ok, ddb} = Delegates.Table.open(Path.join(ctx.home, "caf.db"))
    {:ok, _} = row(ddb, &(&1.parent == "app-main" and &1.status == "finished"))

    # A message that starts with `ask` waits on a permission, so its turn is there to interrupt.
    assert {:ok, {:queued, id}} = Operator.message(parts.mcp, "app-unit-one", "ask: again.")

    {:ok, _} =
      await(
        fn ->
          case Delegates.fix_state(parts.delegates, "app-main", "app-unit-one") do
            {:ok, %{held: [_]}} = held -> held
            other -> other
          end
        end,
        20_000
      )

    # The row is marked from `Stream`'s replay, which may come after the request is read.
    {:ok, _} =
      await(
        fn ->
          case Mailbox.status(parts.mailbox, id) do
            {:ok, %{from: "operator", to: "app-unit-one", status: "delivered"}} = ok -> ok
            other -> other
          end
        end,
        20_000
      )

    assert {:ok, %{claim: claim}} = Operator.interrupt(parts.mcp, "app-unit-one")
    assert {:ok, %{caller: "operator", target: "app-unit-one"}} = Claims.get(parts.claims, claim)
    assert "interrupt" in HeadlessStandIn.taken(ctx.dir)

    assert for(%{agent: "operator", tool: t} <- MCP.calls(parts.mcp), do: t) ==
             ~w(start_delegate message interrupt)

    # The interrupted turn's reply goes to the delegate's main session, as every reply does.
    {:ok, messages} = Mailbox.Table.open(Path.join(ctx.home, "caf.db"))
    from = &Enum.find(Mailbox.Table.open_rows(messages), fn m -> m.from_agent == &1 end)
    assert {:ok, %{to_agent: "app-main"}} = await(fn -> ok(from.("app-unit-one")) end, 20_000)
  end

  test "a late end `Mailbox` did not answer is kept owed, then stored once", ctx do
    parts = start(ctx.config)
    {:ok, messages} = Mailbox.Table.open(Path.join(ctx.home, "caf.db"))
    {:ok, log} = MCP.Table.open(Path.join(ctx.home, "parts/mcp/mcp.db"))
    id = MCP.Table.called(log, "app-main", "run", "{}")
    dropped = MCP.json({:unknown, %{job: "mcp-t-#{id}", reason: :dropped}})
    :ok = MCP.Table.answered(log, id, JSON.encode!(dropped))
    {:ok, jobs} = Jobs.Table.open(Path.join(ctx.home, "parts/jobs/jobs.db"))

    # `Mailbox` does not answer: the first hand-on is unknown, and nothing raises or is stored.
    :ok = :sys.suspend(parts.mailbox)
    row = %{id: "mcp-t-#{id}", host: "ws", project: "app", name: "app-main", state: "exited"}
    :ok = Jobs.Table.put(jobs, Map.merge(row, %{code: 3, late: "owed"}))

    # A cue and then a read of its state: `Jobs` has handed the end on and had no answer.
    Jobs.cue(parts.jobs, %{topic: "tick"})
    :sys.get_state(parts.jobs, 60_000)
    assert %{state: "exited", late: "owed"} = Jobs.Table.get(jobs, "mcp-t-#{id}")
    assert Enum.filter(Mailbox.Table.open_rows(messages), &(&1.from_agent == "framework")) == []

    :ok = :sys.resume(parts.mailbox)

    {:ok, _} =
      await(
        fn ->
          ok(Enum.find(Mailbox.Table.open_rows(messages), &(&1.from_agent == "framework")))
        end,
        20_000
      )

    {:ok, _} =
      await(
        fn -> if match?(%{late: "told"}, Jobs.Table.get(jobs, "mcp-t-#{id}")), do: {:ok, 1} end,
        20_000
      )

    assert Process.alive?(parts.jobs)

    assert [_one] =
             Enum.filter(Mailbox.Table.open_rows(messages), &(&1.from_agent == "framework"))
  end

  test "the app's PreToolUse callback denies a named tool through the account's hook", ctx do
    deny = fn
      %{tool_name: "WebFetch"} -> {:deny, "No fetches in this app."}
      _ -> :pass
    end

    me = self()
    tools = %{pre_tool_use: deny, post_tool_use: &send(me, {:after, &1})}
    start(%{ctx.config | tool_hooks: tools})

    # The hooks Claude Code would post, as the account's settings name them.
    {:ok, accounts} = Accounts.new(ctx.home, ["work"])
    {:ok, account} = Accounts.ready(accounts, "work")
    hooks = JSON.decode!(File.read!(account.settings[:delegate]))["hooks"]
    [%{"hooks" => [%{"url" => url, "headers" => headers}]}] = hooks["PreToolUse"]
    assert [%{"hooks" => [%{"url" => ^url}]}] = hooks["PostToolUse"]

    Mix.ensure_application!(:inets)
    {:ok, _} = Application.ensure_all_started(:inets)
    headers = for {k, v} <- headers, do: {to_charlist(k), to_charlist(v)}

    post = fn event, tool ->
      body = %{"hook_event_name" => event, "session_id" => "s1", "tool_use_id" => tool}
      body = JSON.encode!(Map.merge(body, %{"tool_name" => tool, "tool_input" => %{}}))
      request = {to_charlist(url), headers, ~c"application/json", body}
      {:ok, {{_, 200, _}, _, answer}} = :httpc.request(:post, request, [timeout: 10_000], [])
      to_string(answer)
    end

    assert %{"permissionDecision" => "deny", "permissionDecisionReason" => "No fetches" <> _} =
             JSON.decode!(post.("PreToolUse", "WebFetch"))["hookSpecificOutput"]

    assert post.("PreToolUse", "Read") == ""
    assert post.("PostToolUse", "Read") == ""
    assert_receive {:after, %{tool_name: "Read", agent: nil}}, 5_000
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
