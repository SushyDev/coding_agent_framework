defmodule CodingAgentFramework.SurfaceTest do
  # The whole tree under this test's own framework home, with its own tmux server and ports,
  # and the headless stand-in for Claude Code. The test sends no cue: what moves the rows is the
  # tree's own wiring.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Config
  doctest CodingAgentFramework.Endpoint
  doctest CodingAgentFramework, only: [child_spec: 1, resources: 1, job_units: 3]

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, ClaudeCLI, Cues, HeadlessStandIn, Jobs, Mailbox, MCP}
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

    instance = instance_name("surface")

    fields = [
      home: home,
      instance: instance,
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
    %{config: config, i: instance, fields: fields, sessions: sessions, dir: dir, home: home}
  end

  defp start(config) do
    parts = CodingAgentFramework.parts(start_supervised!({CodingAgentFramework, config}))
    keys = ~w(home reaper names cues inlet usage stream intake intake_http sampler sessions acts)a

    keys =
      keys ++ ~w(watch recoveries tracker scheduler delegates mover mailbox hosts copies jobs)a

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

  # F-219, from F-200's new-4: `caf_mcp` does not use `caf_cli`, so the surface, which has both,
  # hands it the one list, and this is where the two are checked as one.
  test "the MCP tools offer ClaudeCLI's efforts as the enum of their effort", ctx do
    parts = start(ctx.config)

    efforts =
      for %{name: name, inputSchema: %{properties: %{effort: effort}}} <-
            MCP.tools(parts.mcp, "app-main"),
          do: {name, effort}

    assert Enum.map(efforts, &elem(&1, 0)) == ~w(start_delegate run_delegate)

    for {_name, effort} <- efforts do
      assert %{type: "string", enum: enum} = effort
      assert enum == ClaudeCLI.efforts()
    end
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
    :ok = stop_supervised({CodingAgentFramework, ctx.i})
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
    {:ok, %{ref: _}} = CodingAgentFramework.subscribe(ctx.i, ["jobs"])
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
    fields = [home: ctx.home, instance: ctx.i, programs: programs, env: %{path: "/nonexistent"}]
    {:ok, config} = Config.new(fields ++ [agents: false])
    parts = CodingAgentFramework.parts(start_supervised!({CodingAgentFramework, config}))
    assert Enum.sort(Map.keys(parts)) == Enum.sort([:home | Config.agentless()])

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
    assert CodingAgentFramework.agent_rows(ctx.i) == {:ok, %{agents: [], delegates: []}}
    assert CodingAgentFramework.agent_rows("none") == {:refused, :no_instance}
  end

  # F-273: the tree's one `Scheduler`, which every lease asks, reads the app's `pressure:`.
  test "the tree's one Scheduler reads the config's pressure thresholds", ctx do
    programs = Map.drop(ctx.fields[:programs], [:gh, :ssh, :ssh_keygen])
    dir = Path.join(ctx.dir, "psi")
    File.mkdir_p!(dir)
    for f <- ~w(cpu memory io), do: File.write!(Path.join(dir, f), "some total=0\nfull total=0\n")
    pressure = [source: :psi, dir: dir, full: 0.05]

    fields = [home: ctx.home, instance: ctx.i, programs: programs, env: %{path: "/nonexistent"}]
    {:ok, config} = Config.new(fields ++ [agents: false, pressure: pressure])
    sup = start_supervised!({CodingAgentFramework, config})
    parts = CodingAgentFramework.parts(sup)

    schedulers =
      for {_, pid, _, _} <- Supervisor.which_children(sup),
          is_pid(pid),
          {:dictionary, d} = Process.info(pid, :dictionary),
          d[:"$initial_call"] == {Scheduler, :init, 1},
          do: pid

    assert schedulers == [parts.scheduler]
    assert %{source: :psi, psi: ^dir, pressure: %{opts: opts}} = :sys.get_state(parts.scheduler)
    assert opts[:full] == 0.05
    assert %{level: :ok, source: :psi} = Scheduler.pressure(parts.scheduler)

    # The panel's pressure carries the threshold the app set, once a span was read (F-300).
    {:ok, shares} =
      await(
        fn ->
          case CodingAgentFramework.holds(ctx.i) do
            {:ok, %{pressure: %{shares: [_ | _] = shares}}} -> {:ok, shares}
            other -> {:no, other}
          end
        end,
        20_000
      )

    assert [%{file: :memory, line: :full, threshold: 0.05, asks: :severe} | _] = shares
  end

  # F-266: an app's panel of what holds the machine, read through the facade.
  test "holds reads two leases with their jobs, the copies and the pressure", ctx do
    programs = Map.drop(ctx.fields[:programs], [:gh, :ssh, :ssh_keygen])
    fields = [home: ctx.home, instance: ctx.i, programs: programs, env: %{path: "/nonexistent"}]
    {:ok, config} = Config.new(fields ++ [agents: false])
    parts = CodingAgentFramework.parts(start_supervised!({CodingAgentFramework, config}))
    {:ok, units} = CodingAgentFramework.job_units(config, :heavy, "app")
    lease = %{class: :heavy, module: "app", units: units}
    repo = Path.join(ctx.dir, "repo")
    gate = Path.join(ctx.dir, "gate")
    # Each job says it started, then waits for the test's gate.
    script = "echo started $0; while [ ! -e \"$1\" ]; do \"$2\" 0.05; done"
    command = fn n -> [program!(:sh), "-c", script, n, gate, program!(:sleep)] end

    runs =
      for n <- ~w(one two) do
        where = %{host: "ws", project: "app", name: "app-" <> n}
        argv = command.(n)

        Task.async(fn ->
          Jobs.run(parts.jobs, n, where, repo, argv, timeout: 20_000, lease: lease)
        end)
      end

    started = fn ->
      with {:ok, %{leases: [_, _] = leases} = holds} <- CodingAgentFramework.holds(ctx.i),
           true <- Enum.all?(leases, &match?(%{job: %{state: "running"}}, &1)),
           true <- Enum.all?(leases, &(File.read(&1.job.log) == {:ok, "started #{&1.job.id}\n"})) do
        {:ok, holds}
      else
        _ -> nil
      end
    end

    {:ok, holds} = await(started, 20_000)
    ws = Path.join(ctx.home, "ws")

    for {%{job: job} = l, n} <- Enum.zip(Enum.sort_by(holds.leases, & &1.job.id), ~w(one two)) do
      assert %{class: "heavy", module: "app", released_at: nil, holder: {"job", ^n}} = l
      assert is_integer(l.since) and l.request == "job:" <> n
      assert job.argv == command.(n)
      assert job.dir == Path.join([ws, "copies", "app", "app-" <> n])
      assert %{host: "ws", worktree: ^repo} = job
    end

    # Both slots are held and nothing waits (F-300); each resource has its queue's length.
    assert holds.resources["slot"] == %{capacity: 2, held: 2, waiting: 0}
    assert Enum.all?(holds.resources, &match?({_, %{waiting: 0}}, &1))
    assert %{level: _, source: _, unread: _, shares: _, hosts: %{}} = holds.pressure

    assert [%{host: "ws", project: "app", name: "app-one", path: path}, %{name: "app-two"}] =
             holds.copies

    assert File.dir?(path)

    File.write!(gate, "")
    assert [{:ok, %{exit: 0}}, {:ok, %{exit: 0}}] = Task.await_many(runs, 20_000)

    # Each lease is released once its job's end is written: newest first, the last `ended:`.
    released = fn ->
      case CodingAgentFramework.holds(ctx.i, ended: 1) do
        {:ok, %{leases: [%{released_at: at}]} = h} when is_integer(at) -> {:ok, h}
        _ -> nil
      end
    end

    {:ok, %{leases: [last], resources: %{"slot" => %{held: 0}}}} = await(released, 20_000)
    assert %{job: %{id: id, state: "exited", code: 0}, released_by: "monitor"} = last
    assert last.id == Enum.max(Enum.map(holds.leases, & &1.id)) and id in ~w(one two)

    assert {:refused, {:bad, :ended}} = CodingAgentFramework.holds(ctx.i, ended: 201)
    assert {:refused, :no_instance} = CodingAgentFramework.holds("none")
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
    {:ok, %{tree: ^tree}} = CodingAgentFramework.subscribe(ctx.i, ["sessions"])

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
    assert {:ok, %{tree: ^again}} = CodingAgentFramework.subscribe(ctx.i, ["sessions"])

    # An instance that runs on is still refused, once the bound has passed.
    assert CodingAgentFramework.start_link(%{ctx.config | restart_wait: 100}) ==
             {:refused, {:instance_running, ctx.i}}
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
    # A module without `session_start/3` has no SessionStart hook at all (F-236).
    refute Map.has_key?(hooks, "SessionStart")

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

  # A session's start through the app's hook (F-236).
  defmodule StartHooks do
    @behaviour CodingAgentFramework.ToolHooks

    @impl true
    def session_start(%{source: source}, opts, part),
      do: {:context, "#{opts[:rules]} (#{source}, mailbox #{is_pid(part.(:mailbox))})"}
  end

  test "the app's session_start callback answers the account's SessionStart command", ctx do
    {:ok, config} = Config.new(ctx.fields ++ [tool_hooks: {StartHooks, rules: "Land with land."}])
    start(config)

    {:ok, accounts} = Accounts.new(ctx.home, ["work"])
    {:ok, account} = Accounts.ready(accounts, "work")
    hooks = JSON.decode!(File.read!(account.settings[:parent]))["hooks"]
    [%{"hooks" => [%{"type" => "command", "command" => command}]}] = hooks["SessionStart"]

    input = Path.join(ctx.home, "start.json")
    body = %{"hook_event_name" => "SessionStart", "session_id" => "s1", "source" => "startup"}
    File.write!(input, JSON.encode!(body))

    assert {:ok, %{status: 0, output: out}} =
             Shell.run(host(), program!(:sh), ["-c", ~s(eval "$1" < "$2"), "sh", command, input],
               timeout: 20_000
             )

    assert JSON.decode!(out)["hookSpecificOutput"] == %{
             "hookEventName" => "SessionStart",
             "additionalContext" => "Land with land. (startup, mailbox true)"
           }
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

  # F-207: the app's `usable` beside the framework's check, an account's flag the app's own
  # state, read at each pick.
  defmodule Flagged do
    @behaviour CodingAgentFramework.Usable

    # The flags are found by a name in the options (data), so a test changes them while the
    # tree runs. The lookup of a part must be live, as a hook's is.
    @impl true
    def usable?(account, opts, part) do
      if account in Agent.get(opts[:flags], & &1) and is_pid(part.(:logins)),
        do: {false, "flagged #{account}"},
        else: true
    end
  end

  test "the config's usable keeps a start off an account the app flags, in every part that picks",
       ctx do
    flags = :"surface_flags_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: flags,
      start: {Agent, :start_link, [fn -> ["work"] end, [name: flags]]}
    })

    flag = fn accounts -> Agent.update(flags, fn _ -> accounts end) end

    # Room under the parent's cap for the four starts below and the refused fifth, which the
    # cap is checked before the account is picked for.
    projects = Map.update!(ctx.fields[:projects], "app", &Map.put(&1, :cap, 5))

    {:ok, config} =
      Config.new(
        Keyword.merge(ctx.fields,
          accounts: ["work", "side"],
          projects: projects,
          usable: {Flagged, flags: flags}
        )
      )

    parts = start(config)

    # The account a start picked, from the agent's row, once the start wrote it.
    account = fn name ->
      {:ok, %{account: account}} =
        await(
          fn ->
            case Table.get(ctx.sessions, "ws", name) do
              %{account: account} = row when is_binary(account) -> {:ok, row}
              _ -> nil
            end
          end,
          20_000
        )

      account
    end

    by_parent = &MCP.call(parts.mcp, "app-main", "start_delegate", args(&1))
    by_operator = &Operator.start_delegate(parts.mcp, "app-main", "app", &1, "opus", "Go.")

    # With `work` flagged, a start picks `side` though `work` is first at equal room: a
    # delegate's start by its parent, which takes its lease from the `Scheduler` for the account
    # it picked, and the operator's.
    assert {:ok, %{delegate: "app-unit-one"}} = by_parent.("unit/one")
    assert account.("app-unit-one") == "side"

    assert %{outcome: "granted", account: "side"} =
             Enum.find(Scheduler.leases(parts.scheduler), &match?({"delegate", _}, &1.holder))

    assert {:ok, %{delegate: "app-unit-two"}} = by_operator.("unit/two")
    assert account.("app-unit-two") == "side"

    # The flag lifted, each goes to `work`.
    flag.([])
    assert {:ok, %{delegate: "app-unit-three"}} = by_parent.("unit/three")
    assert account.("app-unit-three") == "work"
    assert {:ok, %{delegate: "app-unit-four"}} = by_operator.("unit/four")
    assert account.("app-unit-four") == "work"

    # Every account flagged, none is picked, and each refusal reads with the app's reason beside
    # the framework's own answers, in a delegate's start and in a main session's. No row is
    # written for either. (A main session's start that is allowed is not run here: the headless
    # stand-in gives an interactive session no session file, which `Mains` waits for.)
    flag.(["work", "side"])

    both = %{
      "work" => {:refused, {:app, "flagged work"}},
      "side" => {:refused, {:app, "flagged side"}}
    }

    assert {:refused, {:none_usable, ^both}} = by_operator.("unit/five")

    assert {:refused, {:none_usable, ^both}} =
             Operator.start_main(parts.mcp, "app", "app-two", "Go.")

    assert Table.get(ctx.sessions, "ws", "app-unit-five") == nil
    assert Table.get(ctx.sessions, "ws", "app-two") == nil

    # A move's named account is read by `usable` before the claim, with nothing begun (F-190).
    {:ok, _} =
      await(
        fn ->
          case Table.get(ctx.sessions, "ws", "app-unit-four") do
            %{status: "running"} = row -> {:ok, row}
            _ -> nil
          end
        end,
        20_000
      )

    assert {:refused, {:account, "side", {:app, "flagged side"}}} =
             Operator.move(parts.mcp, "app-unit-four", "side")

    assert account.("app-unit-four") == "work"
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

    # The operator's interrupt of a main session goes to `Mains` (F-258): a declared one has no
    # process, which is checked on the state before the claim, so it takes none. No main session
    # interrupts itself through the tool.
    assert {:refused, :gone} = Operator.interrupt(parts.mcp, "app-main")
    assert {:ok, []} = Acts.rows(parts.acts, target: "app-main")

    assert {:refused, :no_self_fix} =
             MCP.call(parts.mcp, "app-main", "interrupt", %{"agent" => "app-main"})

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
    {:ok, %{ref: _}} = CodingAgentFramework.subscribe(ctx.i, ["prompts"])

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
    assert {:ok, [p]} = CodingAgentFramework.prompts(ctx.i, subtree: "app-main")
    assert %{id: ^id, kind: "permission", agent: ^name, parent: "app-main", project: "app"} = p
    assert {:ok, []} = CodingAgentFramework.prompts(ctx.i, kind: "dialog")

    {:ok, mtable} = Mailbox.Table.open(Path.join(ctx.home, "caf.db"))

    told =
      for %{kind: "prompt", to_agent: "app-main"} = m <- Mailbox.Table.open_rows(mtable), do: m

    assert [%{from_agent: ^name, text: "waiting on permission: Bash ls (prompt " <> _}] = told

    assert {:ok, :sent} = CodingAgentFramework.answer(ctx.i, id, "allow", "sam")
    assert Task.await(holder, 25_000) =~ ~s("behavior":"allow")
    assert {:refused, :settled} = CodingAgentFramework.answer(ctx.i, id, "deny", "sam")
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
    {:ok, _} = CodingAgentFramework.subscribe(ctx.i, ["watch", "prompts"])

    assert {:ok, %{"lost_viewer" => %{remedy: "reopen", cap: 10, allowed: true}}} =
             CodingAgentFramework.remedies(ctx.i, :list)

    assert {:refused, {:bad, :request}} =
             CodingAgentFramework.remedies(ctx.i, {:drop, "lost_viewer", :why})

    assert {:ok, false} = CodingAgentFramework.remedies(ctx.i, {:revoke, "end_owed", "sam"})

    sym = %{kind: "end_owed", target: "app-main", state: "k1", source: "healer", since: 1}
    {:ok, %{id: sid}} = CodingAgentFramework.Watch.record(parts.watch, sym)
    {:ok, ^sid} = CodingAgentFramework.Watch.ask(parts.watch, sym, :not_on_list)
    assert_receive {:caf_cue, %{topic: "watch", ids: [^sid]}}, 20_000

    assert {:ok, [%{id: ^sid, status: "asked"}]} =
             CodingAgentFramework.symptoms(ctx.i, kind: "end_owed")

    assert_receive {:caf_cue, %{topic: "prompts", ids: ["remedy:" <> _ = id]}}, 20_000
    assert {:ok, :answered} = CodingAgentFramework.answer(ctx.i, id, "approve", "sam")
    assert {:ok, %{"end_owed" => %{allowed: true}}} = CodingAgentFramework.remedies(ctx.i, :list)
    assert {:refused, :no_instance} = CodingAgentFramework.symptoms("nope")
  end

  # F-265: an app reads its agents' rows by session id or by a meta key, each with the turn the
  # tree reads. The stand-in's `bg` brief keeps its delegate in a turn while its background
  # command runs (no line is written to the FIFO here), and a stopped delegate ends for good.
  test "an app reads agent rows by session id or by a meta key, with their turn", ctx do
    parts = start(ctx.config)
    {_, 0} = System.cmd(program!(:mkfifo), [Path.join(ctx.dir, "bg.fifo")])

    assert {:ok, %{delegate: "app-unit-one"}} =
             MCP.call(parts.mcp, "app-main", "start_delegate", args("unit/one"))

    bg = Map.put(args("unit/two"), "brief", "bg go")

    assert {:ok, %{delegate: "app-unit-two"}} =
             MCP.call(parts.mcp, "app-main", "start_delegate", bg)

    for name <- ~w(app-unit-one app-unit-two),
        do:
          {:ok, _} = CodingAgentFramework.Sessions.put_meta(parts.sessions, name, %{"epic" => 7})

    turns = fn by ->
      with {:ok, rows} <- CodingAgentFramework.agent_rows(ctx.i, by),
           do: {:ok, Enum.map(rows, &{&1.name, &1.turn})}
    end

    # By a meta key: both rows, one idle after its report and one in a turn.
    {:ok, _} =
      await(
        fn ->
          want = {:ok, [{"app-unit-one", "idle"}, {"app-unit-two", "working"}]}
          if turns.(meta: {"epic", 7}) == want, do: want
        end,
        20_000
      )

    # By session id: the one row, as `agent_rows/1` gives it, with its turn.
    two = Table.get(ctx.sessions, "ws", "app-unit-two")
    {:ok, %{agents: all}} = CodingAgentFramework.agent_rows(ctx.i)
    listed = Enum.find(all, &(&1.name == "app-unit-two"))

    assert {:ok, [row]} = CodingAgentFramework.agent_rows(ctx.i, session_id: two.session_id)

    assert Enum.sort(Map.keys(row)) == Enum.sort([:turn | Map.keys(listed)])
    assert {row.id, row.name, row.turn} == {listed.id, "app-unit-two", "working"}

    # Ended: stopped once idle, then ended for good.
    {:ok, :stopped} = CodingAgentFramework.Sessions.stop(parts.sessions, "app-unit-one")
    {:ok, :ended} = CodingAgentFramework.Sessions.ended(parts.sessions, "app-unit-one")
    one = Table.get(ctx.sessions, "ws", "app-unit-one")

    {:ok, _} =
      await(fn ->
        want = {:ok, [{"app-unit-one", "ended"}]}
        if turns.(session_id: one.session_id) == want, do: want
      end)

    # No match, a key of no read, a value out of shape, and no instance of that name.
    assert {:ok, []} = CodingAgentFramework.agent_rows(ctx.i, meta: {"epic", 8})
    assert {:ok, []} = CodingAgentFramework.agent_rows(ctx.i, session_id: "no-such-session")
    assert {:refused, {:bad, :ticket}} = CodingAgentFramework.agent_rows(ctx.i, ticket: 41)
    assert {:refused, {:bad, :meta}} = CodingAgentFramework.agent_rows(ctx.i, meta: {"epic", 7.5})
    assert {:refused, {:bad, :by}} = CodingAgentFramework.agent_rows(ctx.i, [])

    assert {:refused, {:bad, :by}} =
             CodingAgentFramework.agent_rows(ctx.i, session_id: "a", meta: {"epic", 7})

    assert {:refused, :no_instance} = CodingAgentFramework.agent_rows("nope", session_id: "a")
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
