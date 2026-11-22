defmodule CodingAgentFramework.SurfaceTest do
  # The whole tree under this test's own framework home, with its own tmux server and ports,
  # and the headless stand-in for Claude Code. The test sends no cue: what moves the rows is the
  # tree's own wiring.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Config
  doctest CodingAgentFramework.Endpoint
  doctest CodingAgentFramework, only: [child_spec: 1, resources: 1, job_units: 3]

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Cues, HeadlessStandIn, Jobs, Mailbox, MCP}
  alias CodingAgentFramework.{Mains, Services, Shell}
  alias CodingAgentFramework.{Delegates, Operator, Scheduler, Tmux, Tracker}
  alias CodingAgentFramework.Acts
  alias CodingAgentFramework.Config
  alias CodingAgentFramework.Sessions.Table

  setup do
    dir = test_dir()
    repo = Path.join(dir, "repo")
    git = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    {_, 0} = System.cmd(program!(:git), ["init", "-q", "-b", "main", repo], env: git)
    commit = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "i"]
    {_, 0} = System.cmd(program!(:git), commit ++ ["--allow-empty"], env: git)

    # The project's repository: Mains clones its checkout from it, under the home.
    project = %{origin: repo, trunk: "main", setup: [], setup_timeout: 10_000}
    project = Map.merge(project, %{env: %{"HOME" => dir}, branches: ~r/\Aunit\//, cap: 2})
    # A home with a space, as macOS's `~/Library/Application Support/<app>/framework` is
    # (F-169, F-175).
    home = Path.join([dir, "Application Support", "app", "framework"])

    fields = [
      home: home,
      instance: "t",
      programs: programs().paths,
      accounts: ["work"],
      projects: %{"app" => project},
      mains: %{"app-main" => "app"},
      ports: %{intake: free_port(), mcp: free_port()},
      claude: HeadlessStandIn.write!(dir, :on_message),
      env: %{home: dir, path: "/nonexistent", term: "xterm-256color", lang: "C.UTF-8"},
      user: "tester",
      interval: 200,
      undeclared_cues: :raise
    ]

    {:ok, config} = Config.new(fields)

    # A new home: no account has a reading, and a start still picks one (F-147).
    File.mkdir_p!(home)
    {:ok, server} = CodingAgentFramework.server(config)
    on_exit(fn -> Tmux.kill_server(server) end)
    on_exit(fn -> end_recorded(dir) end)
    {:ok, sessions} = Table.open(Path.join(home, "caf.db"))
    %{config: config, fields: fields, sessions: sessions, dir: dir, home: home}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start(config) do
    parts = CodingAgentFramework.parts(start_supervised!({CodingAgentFramework, config}))
    keys = ~w(reaper names cues inlet usage stream intake intake_http sampler sessions acts)a
    keys = keys ++ ~w(watch recoveries tracker scheduler delegates mover mailbox copies jobs)a
    keys = keys ++ ~w(services logins)a

    keys =
      keys ++
        ~w(prompts mains absent_mains limits stuck_backgrounds hooks_silent interventions)a ++
        ~w(mcp mcp_http ends)a

    assert Enum.sort(Map.keys(parts)) ==
             Enum.sort(keys ++ [:registry, :transcripts])

    assert Enum.all?(Map.values(parts), &(is_pid(&1) and Process.alive?(&1)))

    # The project's checkout, cloned at the start, before a delegate's worktree is made from it.
    ready = fn ->
      with {:ok, %{state: state}} = r when state != "ready" <- Mains.checkout(parts.mains, "app"),
           do: {:not_ready, r}
    end

    assert {:ok, _} = await(ready, 20_000)
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
    secret = hook_secret(ctx.home)
    assert secret == File.read!(Path.join(ctx.home, "intake.secret"))

    # A restart on the same home: the parts read their tables again, `Sessions` adopts the
    # held delegates, which ran on, and the tree comes back the same. The hooks' secret is the
    # home's, so the held delegates' hooks are still taken.
    :ok = stop_supervised({CodingAgentFramework, "t"})
    parts = start(ctx.config)
    {:ok, again} = settled(parts, ctx)
    assert Enum.map(again.agents, & &1.name) == Enum.map(tree.agents, & &1.name)
    assert pids(ctx) == {:ok, pids}
    assert hook_secret(ctx.home) == secret

    # The rows came back with the start: a third delegate is past the parent's cap of two.
    assert {:refused, {:cap, _}} =
             MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/three"))
  end

  # An app's landing runs through `Jobs` itself (F-171's new-3): no agent's tool runs a job.
  test "a job's late end is kept in its row, told, and cued on jobs", ctx do
    start(ctx.config)
    {:ok, %{ref: _}} = CodingAgentFramework.subscribe("t", ["jobs"])
    {:ok, jobs} = Jobs.Table.open(Path.join(ctx.home, "parts/jobs/jobs.db"))

    # A job whose call answered `{:unknown, :dropped}`, its end read since: `Jobs` owes it, and
    # on its interval hands it on, which the tree takes as stored in the row.
    row = %{id: "land-1", host: "ws", project: "app", name: "app-land", state: "exited"}
    :ok = Jobs.Table.put(jobs, Map.merge(row, %{code: 3, late: "owed"}))

    assert_receive {:caf_cue, %{topic: "jobs", ids: ["land-1"]}}, 20_000

    {:ok, _} =
      await(fn -> ok(match?(%{code: 3, late: "told"}, Jobs.Table.get(jobs, "land-1")) || nil) end)
  end

  test "an app's landing job takes its slot and its project's lock in one lease", ctx do
    parts = start(ctx.config)
    {:ok, units} = CodingAgentFramework.job_units(ctx.config, :landing, "app")
    {:ok, %{path: checkout}} = Mains.checkout(parts.mains, "app")
    where = %{host: "ws", project: "app", name: "app-land"}
    lease = %{class: :landing, module: "app", units: units}
    argv = [program!(:sh), "-c", "exit 0"]

    assert {:ok, %{exit: 0}} =
             Jobs.run(parts.jobs, "land-2", where, checkout, argv, timeout: 10_000, lease: lease)

    # Schedule.tla: one lease of both, whose holder is the job's row, released by the monitor
    # once `Jobs` wrote the job's end.
    {:ok, lease} =
      await(fn ->
        case Enum.find(Scheduler.leases(parts.scheduler), &(&1.class == "landing")) do
          %{released_by: "monitor"} = lease -> {:ok, lease}
          _ -> nil
        end
      end)

    assert %{units: %{"slot" => 1, "land:app" => 1}, holder: {"job", "land-2"}} = lease
  end

  # F-195: an app that only leases its jobs runs the tree with no agent part. F-201: its config
  # has only the keys that tree reads, and its programs no gh, ssh or ssh-keygen, since it
  # makes no tool home.
  test "a tree with agents: false starts the lease parts alone, and a job takes its lease",
       ctx do
    programs = Map.drop(ctx.fields[:programs], [:gh, :ssh, :ssh_keygen])
    fields = [home: ctx.home, instance: "t", programs: programs, env: %{path: "/nonexistent"}]
    {:ok, config} = Config.new(fields ++ [agents: false])
    parts = CodingAgentFramework.parts(start_supervised!({CodingAgentFramework, config}))
    assert Enum.sort(Map.keys(parts)) == Enum.sort(Config.agentless())

    {:ok, units} = CodingAgentFramework.job_units(config, :heavy, "app")
    where = %{host: "ws", project: "app", name: "app-heavy"}
    lease = %{class: :heavy, module: "app", units: units}
    argv = [program!(:sh), "-c", "exit 0"]
    # The project's own repository: no checkout is cloned, since `Mains` does not run.
    repo = Path.join(ctx.dir, "repo")

    assert {:ok, %{exit: 0}} =
             Jobs.run(parts.jobs, "heavy-1", where, repo, argv, timeout: 10_000, lease: lease)

    {:ok, lease} =
      await(fn ->
        case Enum.find(Scheduler.leases(parts.scheduler), &(&1.holder == {"job", "heavy-1"})) do
          %{released_by: "monitor"} = lease -> {:ok, lease}
          _ -> nil
        end
      end)

    assert %{units: %{"slot" => 1}, holder: {"job", "heavy-1"}} = lease

    # Nothing an agent needs was made: no hooks' secret, no heavy commands' wrapper, no
    # account's settings, and the agent rows' reader answers none.
    for path <- ["intake.secret", "bin/caf-run", "accounts", "gh", "git", "ssh"],
        do: refute(File.exists?(Path.join(ctx.home, path)), path)

    assert CodingAgentFramework.agent_rows(config) == {:ok, %{agents: [], delegates: []}}
    # By the instance's name, as `subscribe/2` takes it (F-201).
    assert CodingAgentFramework.agent_rows("t") == {:ok, %{agents: [], delegates: []}}
    assert CodingAgentFramework.agent_rows("none") == {:refused, :no_instance}
  end

  # F-199: the metrics are read from the store alone, once, whether the tree runs or not.
  test "the metrics read each part's rows from the store, and a table not made has none", ctx do
    db = Path.join(ctx.home, "caf.db")
    acts = start_supervised!({Acts, db: db, start_id: "s", host: "ws", instance: "t"})
    {:ok, delegates} = Delegates.Table.open(db)
    {:ok, mailbox} = Mailbox.Table.open(db)
    start = %{host: "ws", name: "app-unit-one", branch: "unit/one", model: "opus"}
    Delegates.Table.starting(delegates, Map.merge(start, %{brief_uuid: "b1", deadline: 0}))
    report = %{from: "app-unit-one", to: "app-main", text: "Done.", uuid: "r1", kind: "reply"}
    Mailbox.Table.store(mailbox, Map.put(report, :reply_to, "b1"))
    {:ok, _} = Acts.record(acts, "person", "app-main", :typed, :verified, [], state: "typed:ws:1")

    now = System.os_time(:millisecond)
    window = [since: now - 60_000, until: now + 60_000]

    # No `Watch` nor `Intake` table was made: they read as no rows.
    assert {:ok, [period]} = CodingAgentFramework.metrics(ctx.config, window)

    assert %{started: %{count: 1}, reported: %{count: 1}, prompts: %{opened: 0}} = period
    assert %{interventions: %{count: 1, by_kind: %{"typed" => 1}}} = period

    assert {:refused, {:bad, :by}} =
             CodingAgentFramework.metrics(ctx.config, window ++ [by: :month])
  end

  # F-195's finding: the parent's restart of a tree just killed came while the old tree's named
  # `Registry` still ended, and was refused, so the parent's budget ran out.
  test "a parent's restart of a killed tree waits for the old one and starts", ctx do
    child = %{
      id: :parent,
      start:
        {Supervisor, :start_link,
         [[{CodingAgentFramework, ctx.config}], [strategy: :one_for_one, max_restarts: 1]]},
      type: :supervisor
    }

    parent = start_supervised!(child)
    watch = Process.monitor(parent)
    [{_, tree, _, _}] = Supervisor.which_children(parent)
    {:ok, %{tree: ^tree}} = CodingAgentFramework.subscribe("t", ["sessions"])

    Process.exit(tree, :kill)

    {:ok, again} =
      await(
        fn ->
          case Supervisor.which_children(parent) do
            [{_, pid, _, _}] when is_pid(pid) and pid != tree -> {:ok, pid}
            other -> {:not_yet, other}
          end
        end,
        20_000
      )

    refute_received {:DOWN, ^watch, _, _, _}
    assert {:ok, %{tree: ^again}} = CodingAgentFramework.subscribe("t", ["sessions"])

    # An instance that runs on is still refused, once the bound has passed.
    assert CodingAgentFramework.start_link(%{ctx.config | restart_wait: 100}) ==
             {:refused, {:instance_running, "t"}}
  end

  test "a delegate's end ends its services, and hands a kept one to its parent", ctx do
    # The brief's turn waits on a permission, so the delegate runs until it is killed twice.
    File.write!(Path.join(ctx.dir, "hold"), "")
    parts = start(ctx.config)
    {:ok, _} = MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/one"))
    {:ok, ddb} = Delegates.Table.open(Path.join(ctx.home, "caf.db"))
    svc = Path.join(ctx.dir, "svc")
    argv = [program!(:sh), "-c", echo_tail!(svc), Path.join(svc, "it")]

    # A service's socket is named by a key, not its name (F-205): the longest allowed name starts
    # in the tree's own home.
    long = String.duplicate("s", 64)

    for {name, keep} <- [{"plain", false}, {"kept", true}, {long, false}] do
      {:ok, %{state: "running"}} =
        MCP.call(parts.mcp, "app-unit-one", "service_start", %{
          "name" => name,
          "argv" => argv,
          "opts" => %{"keep" => keep}
        })
    end

    # A first kill is resumed; the second before its last reply fails the delegate, and its agent
    # row ends at once, which a `sessions:` cue shows.
    killed = kill_delegate(ctx, [], 1)
    {:ok, _} = row(ddb, &(&1.resumes == 1 and &1.status == "running"))
    kill_delegate(ctx, killed, 2)
    {:ok, _} = row(ddb, &(&1.status == "failed"))

    {:ok, rows} =
      await(
        fn ->
          rows = Map.new(Services.list(parts.services), &{&1.name, &1})

          if rows["plain"].state == "ended" and rows[long].state == "ended" and
               rows["kept"].owner == "app-main",
             do: {:ok, rows}
        end,
        20_000
      )

    assert %{state: "running"} = rows["kept"]
    {:ok, _} = Services.stop(parts.services, "app-main", "kept", [])

    # Schedule.tla: the start's one lease, held through the resume, is released by the monitor
    # once the delegate's work ended, and the Tracker shows it.
    {:ok, lease} =
      await(
        fn ->
          case Scheduler.leases(parts.scheduler) do
            [%{released_by: "monitor"} = lease] -> {:ok, lease}
            _ -> nil
          end
        end,
        20_000
      )

    assert %{outcome: "granted", class: "builder", holder: {"delegate", "ws:" <> _}} = lease

    {:ok, _} =
      await(fn ->
        {:ok, view} = Tracker.view(parts.tracker)
        if match?(%{{"ws", "leases"} => %{leases: [_ | _]}}, view), do: {:ok, view}
      end)

    # F-126's new-1: the start, `Delegates`' own resume and `Sessions`' resume are rows of
    # `Acts`, each settled by its answer; the resume claimed the state it resumed, once. Each
    # kill `Delegates` saw is a row before it decided (F-202): the first before the resume, the
    # second before the failure. The permission request each turn waited on is an open
    # `Prompts` recorded, a row of its own.
    {:ok, acts} =
      await(fn ->
        actors = ["sessions:ws", "delegates:ws"]
        {:ok, rows} = Acts.rows(parts.acts, target: "app-unit-one", actor: actors)
        if Enum.count(rows, &(&1.status == "settled")) == 5, do: {:ok, rows}
      end)

    assert {:ok, [_, _ | _] = opened} =
             Acts.rows(parts.acts, target: "app-unit-one", act: "opened")

    assert Enum.all?(opened, &String.starts_with?(&1.state, "opened:ws:permission:stream:"))

    assert [
             %{actor: "sessions:ws", act: "start", outcome: "verified"},
             %{actor: "delegates:ws", act: "killed", state: "killed:ws:" <> first},
             %{actor: "delegates:ws", act: "resume", outcome: "verified", state: state},
             %{actor: "sessions:ws", act: "resume", outcome: "verified"},
             %{actor: "delegates:ws", act: "killed", state: "killed:ws:" <> second}
           ] = acts

    assert state =~ ~s("resumes":0)
    assert [_id, "0"] = String.split(first, ":")
    assert [_id, "1"] = String.split(second, ":")
  end

  # F-126's new-1: a raised error the app records is a part's crash, a row of `Acts`.
  test "a part's crash is a raised error in Acts", ctx do
    parts = start(ctx.config)
    Process.exit(parts.ends, :kill)

    {:ok, [row]} =
      await(fn ->
        {:ok, rows} = Acts.rows(parts.acts, act: "error")
        if rows != [], do: {:ok, rows}
      end)

    assert %{actor: "app", target: "part:ends", outcome: "failed", reason: reason} = row
    assert reason =~ "killed"
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

    # Its report, the reply to its brief, is taken and written to its agent, as `run_delegate`
    # does; then it is stopped.
    {:ok, %{brief_uuid: u}} = row(ddb, &(&1.id == id and &1.status == "finished"))
    assert {:ok, %{id: r}} = Mailbox.await(parts.mailbox, "app-main", u, 5_000)
    assert {:ok, :delivered} = Mailbox.told(parts.mailbox, r, :written)
    {:ok, state} = Delegates.fix_state(parts.delegates, "app-main", "app-unit-one")
    fix = Delegates.fix(parts.delegates, "app-main", "app-unit-one", :stop, state)
    assert {:ok, :stopped} = fix

    # No cue from the test: the stop's own end makes the agent row `ended`, a `sessions:` cue
    # shows it, and the app ends the services the delegate owned.
    {:ok, sdb} = Table.open(Path.join(ctx.home, "caf.db"))

    {:ok, _} =
      await(fn -> ok(match?(%{status: "ended"}, Table.get(sdb, "ws", "app-unit-one")) || nil) end)

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
    {:ok, _} = row(ddb, &(&1.status == "finished"))

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

    assert {:ok, %{actor: "operator", target: "app-unit-one", act: "interrupt"}} =
             Acts.get(parts.acts, claim)

    assert "interrupt" in HeadlessStandIn.taken(ctx.dir)

    assert for(%{agent: "operator", tool: t} <- MCP.calls(parts.mcp), do: t) ==
             ~w(start_delegate message interrupt)

    # The interrupted turn's reply goes to the delegate's main session, as every reply does.
    {:ok, messages} = Mailbox.Table.open(Path.join(ctx.home, "caf.db"))
    from = &Enum.find(Mailbox.Table.open_rows(messages), fn m -> m.from_agent == &1 end)
    assert {:ok, %{to_agent: "app-main"}} = await(fn -> ok(from.("app-unit-one")) end, 20_000)
  end

  # F-138: a delegate asks through its tool, which answers at once; the app reads the open ask
  # and answers it once; the answer goes to the delegate as a row it takes.
  test "a delegate asks a person; the app answers once, and the delegate takes it", ctx do
    parts = start(ctx.config)

    {:ok, %{delegate: "app-unit-one"}} =
      MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/one"))

    {:ok, ddb} = Delegates.Table.open(Path.join(ctx.home, "caf.db"))
    {:ok, _} = row(ddb, &(&1.status == "finished"))

    options = for l <- ~w(Rebase Merge), do: %{"label" => l, "description" => "by #{l}"}

    q = %{
      "header" => "Base",
      "question" => "Which?",
      "options" => options,
      "multiSelect" => false
    }

    assert {:ok, %{ask: id}} = MCP.call(parts.mcp, "app-unit-one", "ask", %{"questions" => [q]})

    assert {:ok, [%{id: ^id, from: "app-unit-one", questions: [^q]}]} =
             Mailbox.open_asks(parts.mailbox)

    answer = [%{"labels" => ["Rebase"], "text" => "then push"}]
    assert {:ok, {:queued, a}} = Mailbox.answer(parts.mailbox, id, answer)
    assert {:refused, :settled} = Mailbox.answer(parts.mailbox, id, answer)

    {:ok, %{answer: %{id: ^a, text: "Ask " <> _}}} =
      await(
        fn ->
          case Mailbox.asked(parts.mailbox, id) do
            {:ok, %{answer: %{status: "delivered"}}} = ok -> ok
            other -> other
          end
        end,
        20_000
      )

    {:ok, messages} = Mailbox.Table.open(Path.join(ctx.home, "caf.db"))
    %{uuid: u} = Mailbox.Table.get(messages, a)
    # The replay settles the row; the stand-in's own log of what it took may come just after.
    {:ok, _} = await(fn -> ok("message #{u}" in HeadlessStandIn.taken(ctx.dir) || nil) end)
  end

  # The app's tool hooks, named in the config as a module and its options (F-195).
  defmodule Hooks do
    @behaviour CodingAgentFramework.ToolHooks

    @impl true
    def pre_tool_use(%{tool_name: "WebFetch"}, opts, _part), do: {:deny, opts[:deny]}

    def pre_tool_use(%{tool_name: "Grep"}, _opts, part) do
      context = "Code is in src; mailbox #{is_pid(part.(:mailbox))}."
      {:allow, updated_input: %{"path" => "src"}, additional_context: context}
    end

    def pre_tool_use(_event, _opts, _part), do: :pass

    @impl true
    def post_tool_use(%{tool_name: "Grep"}, _opts, _part),
      do: {:replace, %{"stdout" => "src/a.ex", "stderr" => ""}}

    def post_tool_use(event, opts, part) do
      send(opts[:to], {:after, event, part.(:mailbox)})
      :pass
    end
  end

  test "the app's PreToolUse callback denies or corrects a call through the account's hook",
       ctx do
    # Options are data: the test is found by a name of its own, not by its pid.
    me = :"surface_hooks_#{System.unique_integer([:positive])}"
    Process.register(self(), me)
    {:ok, config} = Config.new(ctx.fields ++ [tool_hooks: {Hooks, deny: "No fetches.", to: me}])
    parts = start(config)

    # The hooks Claude Code would post, as the account's settings name them.
    {:ok, accounts} = Accounts.new(ctx.home, ["work"])
    {:ok, account} = Accounts.ready(accounts, "work")
    hooks = JSON.decode!(File.read!(account.settings[:delegate]))["hooks"]
    [%{"hooks" => [%{"url" => url, "headers" => headers}]}] = hooks["PreToolUse"]
    assert [%{"hooks" => [%{"url" => ^url}]}] = hooks["PostToolUse"]

    Mix.ensure_application!(:inets)
    {:ok, _} = Application.ensure_all_started(:inets)
    headers = for {k, v} <- headers, do: {to_charlist(k), to_charlist(v)}

    post_input = fn event, tool, input ->
      body = %{"hook_event_name" => event, "session_id" => "s1", "tool_use_id" => tool}
      body = JSON.encode!(Map.merge(body, %{"tool_name" => tool, "tool_input" => input}))
      request = {to_charlist(url), headers, ~c"application/json", body}
      {:ok, {{_, 200, _}, _, answer}} = :httpc.request(:post, request, [timeout: 10_000], [])
      to_string(answer)
    end

    post = fn event, tool -> post_input.(event, tool, %{}) end

    assert %{"permissionDecision" => "deny", "permissionDecisionReason" => "No fetches" <> _} =
             JSON.decode!(post.("PreToolUse", "WebFetch"))["hookSpecificOutput"]

    assert %{"permissionDecision" => "allow", "updatedInput" => %{"path" => "src"}} =
             correction = JSON.decode!(post.("PreToolUse", "Grep"))["hookSpecificOutput"]

    assert correction["additionalContext"] == "Code is in src; mailbox true."
    assert post.("PreToolUse", "Read") == ""
    assert post.("PostToolUse", "Read") == ""

    # The app's replacement of a call's output goes out as `updatedToolOutput` (F-197).
    assert %{"updatedToolOutput" => %{"stdout" => "src/a.ex"}} =
             JSON.decode!(post.("PostToolUse", "Grep"))["hookSpecificOutput"]

    # A background command the app passes runs with its stdin at end of file, and the decision
    # stays Claude Code's (F-180).
    background = %{"command" => "ls", "run_in_background" => true}
    answer = JSON.decode!(post_input.("PreToolUse", "Bash", background))["hookSpecificOutput"]
    assert answer["updatedInput"] == %{background | "command" => "exec </dev/null; ls"}
    refute Map.has_key?(answer, "permissionDecision")
    # The hook reached the live `Mailbox` through its lookup.
    mailbox = parts.mailbox
    assert_receive {:after, %{tool_name: "Read", agent: nil}, ^mailbox}, 5_000
  end

  test "a heavy command's wrapper takes its lease from the tree's Scheduler on the intake's port",
       ctx do
    parts = start(%{ctx.config | heavy: [%{match: "^make", class: :heavy}]})
    wrapper = Path.join(ctx.home, "bin/caf-run")
    args = ["heavy", "toolu_t1", "app-main", "--", "echo ran; exit 4"]

    assert {:ok, %{status: 4, output: "ran\n"}} =
             Shell.run(host(), wrapper, args, timeout: 20_000)

    assert {:ok, %{units: %{"slot" => 1}, holder: {"run", _}, module: "app-main"}} =
             await(
               fn ->
                 case Enum.find(
                        Scheduler.leases(parts.scheduler),
                        &(&1.request_id == "run:toolu_t1")
                      ) do
                   %{released_at: at} = lease when is_integer(at) -> {:ok, lease}
                   other -> {:held, other}
                 end
               end,
               20_000
             )
  end

  # An app's extension, named in the config as a module and its options (F-188).
  defmodule Board do
    @behaviour CodingAgentFramework.Extension

    @impl true
    def bundle(opts, part) do
      tool = %{
        name: "board_cards",
        description: "The board's cards.",
        schema: %{"type" => "object"},
        call: fn caller, _args ->
          {:ok,
           %{"caller" => caller, "board" => opts[:board], "mailbox" => is_pid(part.(:mailbox))}}
        end
      }

      %{name: "board", scope: %{roles: [:main]}, tools: [tool]}
    end
  end

  # F-188: the tree reads the config's keys, and nothing else.
  test "the config's extensions, secret file and part options reach the tree", ctx do
    secret = Path.join(ctx.dir, "hooks.secret")

    {:ok, config} =
      Config.new(
        ctx.fields ++
          [
            extensions: [{Board, board: "web"}],
            secret_file: secret,
            restarts: %{max_restarts: 1, max_seconds: 10},
            dialogs: %{trust: "Yes, I trust this folder"},
            parts: %{sampler: %{interval: 100}, delegates: %{idle_bound: 600_000}}
          ]
      )

    parts = start(config)
    assert "board_cards" in Enum.map(MCP.tools(parts.mcp, "app-main"), & &1.name)

    assert {:ok, %{"caller" => "app-main", "board" => "web", "mailbox" => true}} =
             MCP.call(parts.mcp, "app-main", "board_cards", %{})

    # The hooks post with the secret of the file the config names, and none is in the home.
    assert hook_secret(ctx.home) == File.read!(secret)
    refute File.exists?(Path.join(ctx.home, "intake.secret"))
  end

  # The checkout is the framework's own clone, and `start_main` goes through `MCP` to `Mains`:
  # a reserved name is refused for a main session and for the operator alike.
  test "the whole tree runs under a home whose path has a space (F-175)", ctx do
    assert ctx.home =~ "Application Support/app/framework"
    parts = start(ctx.config)
    checkout = ctx.config.projects["app"].repo
    assert checkout =~ "Application Support/app/framework/checkouts/"
    assert {:ok, %{path: ^checkout, clean: "true"}} = Mains.checkout(parts.mains, "app")

    assert {:ok, %{delegate: "app-unit-one"}} =
             MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/one"))

    # The stand-in answers its brief at once: the delegate's report is taken, and its session
    # row exists, never refused.
    {:ok, ddb} = Delegates.Table.open(Path.join(ctx.home, "caf.db"))
    {:ok, %{report: "taken"}} = row(ddb, &(&1.report == "taken"))
    assert %{session_id: id} = Table.get(ctx.sessions, "ws", "app-unit-one")
    assert is_binary(id)

    # The declared main session is the delegate's parent in the tree.
    {:ok, tree} = MCP.call(parts.mcp, "app-main", "agents", %{})

    assert [%{name: "app-main", kind: "main"}, %{name: "app-unit-one", parent: "app-main"}] =
             tree.agents
  end

  test "Mains holds the project's checkout and serves start_main", ctx do
    parts = start(ctx.config)
    checkout = ctx.config.projects["app"].repo

    assert {:ok, %{path: ^checkout, branch: "main", clean: "true"}} =
             Mains.checkout(parts.mains, "app")

    args = %{"project" => "app", "name" => "framework", "brief" => "Go."}

    assert {:refused, {:running, "framework"}} =
             MCP.call(parts.mcp, "app-main", "start_main", args)

    assert {:refused, {:running, "operator"}} =
             Operator.start_main(parts.mcp, "app", "operator", "Go.")

    assert {:refused, {:unknown_project, "web"}} =
             Operator.start_main(parts.mcp, "web", "web-main", "Go.")

    # A name past the room the home leaves for its socket (F-169's new-2, F-172) is refused
    # before any row: a main session's, and a delegate's from its branch.
    room = Config.name_room(ctx.config).agent
    long = "app-" <> String.duplicate("m", room)

    assert {:refused, {:bad, :name, {:longer_than, ^room}}} =
             Operator.start_main(parts.mcp, "app", long, "Go.")

    assert {:refused, {:bad, :name, {:longer_than, ^room}}} =
             MCP.call(
               parts.mcp,
               "app-main",
               "start_delegate",
               args("unit/" <> String.duplicate("b", room))
             )

    {:ok, ddb} = Delegates.Table.open(Path.join(ctx.home, "caf.db"))
    assert Delegates.Table.rows(ddb, "ws") == []
    {:ok, starts} = Mains.Starts.open(Path.join(ctx.home, "caf.db"))
    assert Mains.Starts.rows(starts, "ws") == []

    # The operator's resume of a main session (F-143's new-1) claims its state and goes to
    # `Mains`, which resumes only one whose process ended: a declared one has none. That is
    # checked on the state before the claim (F-149), so no claim is taken and a second resume
    # is refused the same way. An answer's request is checked against the state's held before
    # any claim too (F-148): a declared one holds none.
    assert {:refused, {:not_stopped, "declared"}} = Operator.resume(parts.mcp, "app-main")
    assert {:refused, {:not_stopped, "declared"}} = Operator.resume(parts.mcp, "app-main")
    assert {:refused, {:not_held, "1"}} = Operator.answer(parts.mcp, "app-main", "1", "allow")
    assert {:ok, []} = Acts.rows(parts.acts, target: "app-main")

    assert {:refused, {:not_built, :main_fix}} = Operator.interrupt(parts.mcp, "app-main")

    # A main session's end (F-143) is the operator's: a declared one with no delegate ends at
    # once, and its name never starts again.
    assert {:refused, :operator_only} =
             MCP.call(parts.mcp, "app-main", "end_main", %{"name" => "app-main"})

    assert {:ok, :ended} = Operator.end_main(parts.mcp, "app-main")

    # The operator's answer of a main session's held permission request goes to `Mains`, and
    # through `Intake` (F-146's new-5), on a state of its own: an ended one holds none, and the
    # refusal takes no claim, so the same answer is refused the same way again.
    assert {:refused, {:not_held, "1"}} = Operator.answer(parts.mcp, "app-main", "1", "allow")
    assert {:refused, {:not_held, "1"}} = Operator.answer(parts.mcp, "app-main", "1", "allow")

    assert {:refused, {:running, "app-main"}} =
             Operator.start_main(parts.mcp, "app", "app-main", "Go.")
  end

  # The topics the parts write, as they declare them, each word they fill in as `x`.
  defp written do
    for {_key, shapes} <- CodingAgentFramework.writes(),
        shape <- shapes,
        do: String.replace(shape, "*", "x")
  end

  # What each part must be handed to settle (`docs/design.md`, "The parts"): beside the
  # `Tracker`, which reads every topic.
  @needs %{
    "registry" => [:sessions, :mover],
    # A headless session's windows and limit are Usage's (F-181); its held request is a
    # permission prompt (F-190).
    "stream" => [
      :sessions,
      :delegates,
      :mailbox,
      :mover,
      :usage,
      :stuck_backgrounds,
      :limits,
      :prompts
    ],
    "tmux" => [:sessions, :recoveries],
    "sessions" => [
      :delegates,
      :mailbox,
      :ends,
      :mover,
      :scheduler,
      :mains,
      :prompts,
      :absent_mains,
      :limits
    ],
    # A start that waits at a usage limit is a limit prompt (F-196), and a waited resume's end
    # settles its healer's claim (F-203).
    "mains" => [:scheduler, :prompts, :absent_mains],
    # A transcript's limit line is the account's record (F-185).
    "transcripts" => [:delegates, :mailbox, :hooks_silent, :usage, :limits, :interventions],
    "delegates" => [:mailbox, :scheduler, :prompts],
    # A remedy answered `act` stays in the inbox until its act's row ends (F-196).
    "acts" => [:prompts],
    "usage" => [:scheduler],
    "jobs" => [:scheduler],
    "mailbox" => [:delegates, :mover, :prompts],
    # The inbox reads every hook row's cue: a held request opens a prompt (F-179).
    # A StopFailure or a quota_auto_resume_* is the limit's screen to read again (F-186).
    "intake" => [:prompts, :hooks_silent, :limits, :interventions],
    "waiters" => [:mailbox, :prompts, :hooks_silent, :limits, :interventions],
    # A symptom the healer asks about is a remedy prompt (F-182); its answer is the healers'
    # clear (F-183).
    "watch" => [:prompts, :recoveries, :absent_mains, :stuck_backgrounds, :limits],
    # A login a check refused is a login prompt (F-181).
    "logins" => [:prompts]
  }

  test "an app that wires only the parts' declarations hands each part every cue it needs" do
    cues = start_supervised!({Cues, parts: CodingAgentFramework.reads()})

    # A stand-in for each part: it keeps whatever the part's own `cue` sends it.
    stand_ins =
      for {key, _} <- CodingAgentFramework.reads(), into: %{}, do: {key, spawn_link(&keep/0)}

    for {key, pid} <- stand_ins, do: Cues.started(cues, key, pid)

    # Each topic a part reads, some part writes.
    for {key, %{topics: patterns}} <- CodingAgentFramework.reads(),
        patterns != :all,
        pattern <- patterns do
      reader = [{key, %{topics: [pattern], cue: nil}}]
      assert Enum.any?(written(), &(Cues.routes(reader, &1) == [key])), pattern
    end

    for topic <- written() do
      Cues.cue(cues, %{topic: topic, ids: []})
      # Once Cues has handled the cue, each stand-in has it in its queue, before the ask.
      :sys.get_state(cues)
      got = for {key, pid} <- stand_ins, kept(pid) != [], do: key

      kind =
        if String.ends_with?(topic, ":waiters"), do: "waiters", else: hd(String.split(topic, ":"))

      assert Enum.sort(got) == Enum.sort([:tracker | Map.get(@needs, kind, [])]), topic
    end
  end

  defp keep(kept \\ []) do
    receive do
      {:kept, from} ->
        send(from, {:kept, self(), Enum.reverse(kept)})
        keep([])

      message ->
        keep([message | kept])
    end
  end

  defp kept(pid) do
    send(pid, {:kept, self()})
    assert_receive {:kept, ^pid, kept}
    kept
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

  # The inbox on the whole tree (F-179): a delegate's held permission request is a prompt, cued
  # on `prompts` to the app's subscriber, its parent told once through `Mailbox`, and answered
  # once through `answer/4`; the operator's `answer_startup` goes through the same inbox.
  test "a delegate's held request is in the inbox, cued, told to its parent, answered once",
       ctx do
    parts = start(ctx.config)
    {:ok, %{ref: _}} = CodingAgentFramework.subscribe("t", ["prompts"])

    assert {:ok, %{delegate: name}} =
             MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/one"))

    {:ok, sid} = await(fn -> ok(Table.get(ctx.sessions, "ws", name).session_id) end, 20_000)
    tool = %{"tool_use_id" => "t1", "tool_name" => "Bash", "tool_input" => %{"command" => "ls"}}
    hook = %{"hook_event_name" => "PermissionRequest", "session_id" => sid}
    body = JSON.encode!(Map.merge(hook, tool))

    holder =
      Task.async(fn ->
        {:ok, {:held, id, ref, _wait}} =
          CodingAgentFramework.Intake.post(parts.intake, "work", body)

        receive do
          {^ref, {:decision, decision}} ->
            CodingAgentFramework.Intake.written(parts.intake, id, ref)
            decision
        after
          20_000 -> :timeout
        end
      end)

    assert_receive {:caf_cue, %{topic: "prompts", ids: [id]}}, 20_000
    assert {:ok, [p]} = CodingAgentFramework.prompts("t", subtree: "app-main")
    assert %{id: ^id, kind: "permission", agent: ^name, parent: "app-main", project: "app"} = p
    assert {:ok, []} = CodingAgentFramework.prompts("t", kind: "dialog")

    {:ok, mtable} = Mailbox.Table.open(Path.join(ctx.home, "caf.db"))

    told =
      for %{kind: "prompt", to_agent: "app-main"} = m <- Mailbox.Table.open_rows(mtable), do: m

    assert [%{from_agent: ^name, text: "waiting on permission: Bash ls (prompt " <> _}] = told

    assert {:ok, :sent} = CodingAgentFramework.answer("t", id, "allow", "sam")
    assert Task.await(holder, 25_000) =~ ~s("behavior":"allow")
    assert {:refused, :settled} = CodingAgentFramework.answer("t", id, "deny", "sam")
    assert_receive {:caf_cue, %{topic: "prompts", ids: [^id]}}, 20_000
    assert {:refused, :no_instance} = CodingAgentFramework.prompts("nope")

    # The operator's answer of a dialog the agent never showed: the inbox has none.
    assert {:refused, :settled} =
             CodingAgentFramework.Operator.answer_startup(parts.mcp, name, "trust", "Yes")
  end

  # The Watch on the whole tree (F-182): a symptom the healer asks about is cued on `watch`,
  # read by `symptoms/2`, and is a remedy prompt; the list is the config's, widened only by
  # the operator.
  test "the Watch's symptoms and allow-list are the app's to read, and its prompt answered",
       ctx do
    parts = start(ctx.config)
    {:ok, _} = CodingAgentFramework.subscribe("t", ["watch", "prompts"])

    assert {:ok, %{"lost_viewer" => %{remedy: "reopen", cap: 10, allowed: true}}} =
             CodingAgentFramework.remedies("t", :list)

    assert {:refused, {:bad, :request}} =
             CodingAgentFramework.remedies("t", {:drop, "lost_viewer", :why})

    assert {:ok, false} = CodingAgentFramework.remedies("t", {:revoke, "end_owed", "sam"})

    sym = %{kind: "end_owed", target: "app-main", state: "k1", source: "healer", since: 1}
    {:ok, %{id: sid}} = CodingAgentFramework.Watch.record(parts.watch, sym)
    {:ok, ^sid} = CodingAgentFramework.Watch.ask(parts.watch, sym, :not_on_list)
    assert_receive {:caf_cue, %{topic: "watch", ids: [^sid]}}, 20_000

    assert {:ok, [%{id: ^sid, status: "asked"}]} =
             CodingAgentFramework.symptoms("t", kind: "end_owed")

    assert_receive {:caf_cue, %{topic: "prompts", ids: ["remedy:" <> _ = id]}}, 20_000
    assert {:ok, :answered} = CodingAgentFramework.answer("t", id, "approve", "sam")
    assert {:ok, %{"end_owed" => %{allowed: true}}} = CodingAgentFramework.remedies("t", :list)
    assert {:refused, :no_instance} = CodingAgentFramework.symptoms("nope")
  end

  defp ok(nil), do: nil
  defp ok(value), do: {:ok, value}

  defp args(branch),
    do: %{"project" => "app", "branch" => branch, "model" => "opus", "brief" => "Go."}

  defp pids(ctx),
    do: {:ok, for(n <- ~w(app-unit-one app-unit-two), do: Table.get(ctx.sessions, "ws", n).pid)}

  # The secret the account's hooks post with, as the start wrote them.
  defp hook_secret(home) do
    {:ok, accounts} = Accounts.new(home, ["work"])
    {:ok, dir} = Accounts.config_dir(accounts, "work")
    settings = JSON.decode!(File.read!(Path.join([dir, "framework", "delegate.settings.json"])))
    [%{"hooks" => [hook]}] = settings["hooks"]["Stop"]
    hook["headers"]["x-caf-secret"]
  end
end
