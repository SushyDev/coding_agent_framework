defmodule CodingAgentFramework.RemoteHostTest do
  # The tree's jobs on another host its config declares, whose programs `Hosts` finds when work
  # goes there (Host.tla, F-280). No remote machine: the host's ssh is a stand-in that drops
  # ssh's own arguments and runs the command here with the host's own PATH, a directory of
  # links the test adds to and removes from; while the test's `down` file exists, it exits 255
  # as ssh does for a host it cannot reach.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Config, Copies, Host, Hosts, Jobs, Programs, Runs, Scheduler, Shell}

  # A test tagged `:app_shape` declares the host as an embedding app does (F-303): its programs
  # only on the PATH its `env` names, none on the PATH ssh gives, and an empty `Programs` beside
  # it, which the tree does not read: `Hosts` finds the programs at each placement.
  setup c do
    dir = test_dir()
    on_exit(fn -> end_recorded(dir) end)
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    {_, 0} = System.cmd(program!(:git), ["-C", repo, "init", "-q"], env: git)
    File.write!(Path.join(repo, "a.txt"), "one\n")

    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    for name <- Hosts.needs(Host.local("x", "/bin/kill")),
        do: link(bin, Atom.to_string(name), program!(name))

    # `Programs.find/3` names the kernel with `uname -s`, which coreutils has beside kill.
    link(bin, "uname", Path.join(Path.dirname(program!(:kill)), "uname"))

    # The app's commands name `cat` bare: it is found on the entry's PATH, as `mix` is there.
    if c[:app_shape], do: link(bin, "cat", program!(:cat))
    ssh_path = if c[:app_shape], do: Path.join(dir, "empty"), else: bin
    File.mkdir_p!(ssh_path)

    File.write!(Path.join(dir, "ssh"), """
    #!#{program!(:bash)}
    [ -e "#{dir}/down" ] && exit 255
    while :; do case $1 in -o|-l) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
    shift
    PATH="#{ssh_path}" exec #{program!(:sh)} -c "$*"
    """)

    File.chmod!(Path.join(dir, "ssh"), 0o755)
    mac = Host.ssh("mac", Path.join(dir, "ssh"), "mac", program!(:kill))
    programs = Map.drop(programs().paths, [:gh, :ssh, :ssh_keygen])
    entry = %{host: mac, dir: Path.join(dir, "mac")}

    entry =
      if c[:app_shape] do
        {:ok, empty} = Programs.new(mac, %{})
        Map.merge(entry, %{env: [{"PATH", bin}], programs: empty})
      else
        entry
      end

    {:ok, config} =
      Config.new(
        home: Path.join(dir, "home"),
        instance: "remote-#{System.unique_integer([:positive])}",
        programs: programs,
        env: %{path: "/nonexistent"},
        agents: false,
        hosts: %{"mac" => entry},
        # The workstation's one heavy slot, and two on the other host (F-292).
        resources: %{"seat" => 4, "slot" => 1, {"slot", "mac"} => 2}
      )

    File.mkdir_p!(config.home)
    parts = CodingAgentFramework.parts(start_supervised!({CodingAgentFramework, config}))
    {:ok, units} = CodingAgentFramework.job_units(config, :heavy, "app")
    lease = %{class: :heavy, module: "app", units: units}

    %{dir: dir, bin: bin, repo: repo, jobs: parts.jobs, scheduler: parts.scheduler, lease: lease}
    |> Map.put(:hosts, parts.hosts)
  end

  defp link(bin, name, target), do: File.ln_s!(target, Path.join(bin, name))

  defp run(c, id, host \\ "mac", argv \\ [program!(:cat), "a.txt"]) do
    # A copy of its own each, so two jobs at once never wait on one copy's turn.
    where = %{host: host, project: "app", name: "app-" <> id}
    opts = [timeout: 10_000, start_timeout: 2_000, lease: c.lease]
    Jobs.run(c.jobs, id, where, c.repo, argv, opts)
  end

  test "a job runs on a host whose programs are found when it is placed", c do
    assert {:ok, %{exit: 0, log: "one\n"}} = run(c, "j1")
  end

  @tag :app_shape
  test "a job on a host declared as an app declares it runs with the programs found there", c do
    # The stand-in's ssh PATH has no program: each is found on the entry's `env` PATH.
    assert {:ok, %{exit: 0, log: "one\n"}} = run(c, "j1", "mac", ["cat", "a.txt"])
    assert %{"mac" => %{state: :ready}} = Hosts.states(c.hosts)
  end

  test "an entry of empty programs, read as it is outside the tree, refuses with 2 elements" do
    # The refusal the tree never gives for a host of its `hosts:` (F-303): only a part started
    # outside the tree with such an entry reads it.
    {:ok, empty} = Programs.new(Host.ssh("mac", "/bin/ssh", "mac", "/bin/kill"), %{})
    config = %{hosts: %{"mac" => %{programs: empty, dir: "/caf"}}, copies: nil}
    where = %{host: "mac", project: "app", copy: "w", kind: "jobs", name: "j", run: "j"}

    assert {:refused, {:no_program, [:dtach, :sh, :env, :rm]}} =
             Copies.Held.context(config, where, 1_000, :place)
  end

  test "MissingOnlyLacking: a host missing a program refuses the job at once, naming it", c do
    File.rm!(Path.join(c.bin, "dtach"))
    assert {:refused, {:no_program, "mac", [:dtach]}} = run(c, "j1")
    # Refused before its row and its lease: nothing ran, nothing waits.
    assert Jobs.rows(c.jobs) == []

    link(c.bin, "dtach", program!(:dtach))
    assert {:ok, %{exit: 0}} = run(c, "j2")
  end

  test "NotPlacedAway: a host away refuses the job within the start's bound, then joins", c do
    File.write!(Path.join(c.dir, "down"), "")
    begun = System.monotonic_time(:millisecond)
    assert {:refused, {:host_away, "mac"}} = run(c, "j1")
    assert System.monotonic_time(:millisecond) - begun < 2_000
    assert Jobs.rows(c.jobs) == []
    # HostSlots.tla's AwayRefusedAtOnce: it never asked for a slot.
    assert Scheduler.leases(c.scheduler) == []

    File.rm!(Path.join(c.dir, "down"))
    assert {:ok, %{exit: 0}} = run(c, "j2")
  end

  test "HostSlots: two heavy runs on a two-slot host run while a third queues, and the workstation's slot is its own",
       c do
    gate = Path.join(c.dir, "gate")
    {_, 0} = System.cmd(program!(:mkfifo), [gate])
    held = [program!(:cat), gate]
    runs = for id <- ~w(m1 m2), do: Task.async(fn -> run(c, id, "mac", held) end)

    held? = fn ->
      case for(
             %{released_at: nil, units: %{"slot@mac" => 1}} = l <- Scheduler.leases(c.scheduler),
             do: l
           ) do
        [_, _] = two -> {:ok, two}
        other -> {:held, other}
      end
    end

    assert {:ok, _} = await(held?, 10_000)

    third = %{
      id: "m3",
      class: :heavy,
      module: "app",
      units: %{"slot" => 1},
      holder: {"job", "m3"},
      where: %{host: "mac"},
      wait: 60_000
    }

    assert {:queued, %{position: 1}} = Scheduler.request(c.scheduler, third)

    # The workstation's single slot is free: a job there runs at once.
    assert {:ok, %{exit: 0, log: "one\n"}} = run(c, "w1", "ws")

    File.write!(gate, "go\n")
    for t <- runs, do: assert({:ok, %{exit: 0}} = Task.await(t, 20_000))
    assert_receive {:lease, "m3", {:ok, %{units: %{"slot@mac" => 1}}}}, 10_000
  end

  describe "an agent's heavy command on the other host (F-296, RemoteRun.tla)" do
    @secret "s3cret"

    # The wrapper and its plug as the tree serves them, on the tree's `Jobs` and `Scheduler`:
    # `mix test` is placed on the other host, `make` stays on the workstation. The agent works
    # in the test's repository.
    setup c do
      heavy = [
        %{match: ~r/\bmix test\b/, class: :heavy, host: "mac"},
        %{match: ~r/\bmake\b/, class: :heavy}
      ]

      {:ok, runs} = Runs.new(Path.join(c.dir, "runs"), programs(), heavy)

      opts = [
        scheduler: fn -> c.scheduler end,
        units: fn class, _agent -> {:ok, Map.fetch!(%{heavy: %{"slot" => 1}}, class)} end,
        secret: @secret,
        host: "ws",
        policy: runs,
        jobs: fn -> c.jobs end,
        where: fn "fix-1", _cwd -> {:ok, %{project: "app", name: "fix-1", worktree: c.repo}} end,
        away: 1_000,
        poll: 50,
        beat: 200
      ]

      server =
        start_supervised!(
          {Bandit, plug: {Runs.Plug, opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      :ok = Runs.prepare(runs, programs(), port, @secret)
      %{runs: runs}
    end

    # The call as Claude Code runs it once the policy rewrote it, in `cwd`, its output and its
    # errors kept apart.
    defp wrapped(c, id, command, cwd) do
      pre = Runs.pre_tool_use(c.runs, nil)
      event = %{agent: "fix-1", tool_name: "Bash", tool_use_id: id}

      {:allow, updated_input: %{"command" => line}} =
        pre.(Map.put(event, :tool_input, %{"command" => command}))

      {out, err} = {Path.join(c.dir, id <> ".out"), Path.join(c.dir, id <> ".err")}
      sh = "cd '#{cwd}' && #{line} > '#{out}' 2> '#{err}'"

      run = fn ->
        {:ok, %{status: status}} =
          Shell.run(host(), program!(:sh), ["-c", sh], timeout: 40_000)

        {status, File.read!(out), File.read!(err)}
      end

      %{line: line, out: out, err: err, run: run}
    end

    defp job_lease(c, id) do
      Enum.find(Scheduler.leases(c.scheduler), &(&1.holder == {"job", id}))
    end

    test "its output and exit status come back, from its directory in the agent's copy", c do
      sub = Path.join(c.repo, "sub")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "b.txt"), "two\n")
      cat = program!(:cat)

      command =
        "#{cat} b.txt; echo err >&2; #{cat} ../a.txt; printf tail; mix test >/dev/null; exit 3"

      # The stand-in host has no `mix`: its complaint is the command's own.
      w = wrapped(c, "toolu_r1", command, sub)
      assert w.line =~ ~r/caf-run' --host 'mac' heavy 'toolu_r1' 'fix-1' -- /

      assert {3, out, err} = w.run.()
      assert out =~ ~r/\Atwo\nerr\none\ntail.*mix.*\n\z/s
      assert err == "caf-run: started on mac (job run-toolu_r1)\n"

      # The job held the other host's slot, its row the holder, and its end released it.
      assert %{units: %{"slot@mac" => 1}} = job_lease(c, "run-toolu_r1")
      assert {:ok, _} = await(fn -> released(c, "run-toolu_r1") end, 10_000)
    end

    @tag :app_shape
    test "on a host declared as an app declares it, it runs with the programs found there", c do
      w = wrapped(c, "toolu_a1", "cat a.txt; mix test >/dev/null 2>&1; exit 5", c.repo)
      assert w.line =~ "--host 'mac'"
      assert {5, "one\n", "caf-run: started on mac (job run-toolu_a1)\n"} = w.run.()
      assert {:ok, %{state: "exited", code: 5}} = Jobs.row(c.jobs, "run-toolu_a1")
    end

    test "a failing command's status comes back, after its last line", c do
      w = wrapped(c, "toolu_r2", "mix test; echo failed; printf 'no newline'; exit 1", c.repo)
      assert {1, out, _err} = w.run.()
      assert out =~ ~r/\n?failed\nno newline\z/
    end

    test "the host away mid-run ends it 69 at once, and its slot is freed once its end is read",
         c do
      gate = Path.join(c.dir, "gate")
      {_, 0} = System.cmd(program!(:mkfifo), [gate])

      w =
        wrapped(
          c,
          "toolu_r3",
          "echo begun; mix test 2>/dev/null; #{program!(:cat)} '#{gate}'",
          c.repo
        )

      task = Task.async(w.run)
      assert {:ok, _} = read_when(w.out, "begun")

      File.write!(Path.join(c.dir, "down"), "")
      assert {69, "begun\n", err} = Task.await(task, 20_000)
      assert err =~ "caf-run: the run on mac has no end (host_away); its job may still run there"

      # The job may still run there: its slot is held until its end is read (NoRunUnleased).
      assert %{released_at: nil} = job_lease(c, "run-toolu_r3")

      File.rm!(Path.join(c.dir, "down"))
      File.write!(gate, "go\n")

      settled = fn ->
        Jobs.cue(c.jobs, %{topic: "test"})
        released(c, "run-toolu_r3")
      end

      assert {:ok, _} = await(settled, 15_000)
      assert {:ok, %{state: "exited", code: 0}} = Jobs.row(c.jobs, "run-toolu_r3")
    end

    test "a command with no host runs on the workstation as before", c do
      w = wrapped(c, "toolu_l1", "make --version >/dev/null 2>&1; echo here; exit 4", c.repo)
      refute w.line =~ "--host"
      assert {4, "here\n", ""} = w.run.()
      # The workstation's slot, held by the wrapper's own process, and no job.
      assert [%{units: %{"slot" => 1}, holder: {"run", _}}] = Scheduler.leases(c.scheduler)
      assert Jobs.rows(c.jobs) == []
    end
  end

  describe "the app's own heavy run, and hosts in order (F-304, RemotePlace.tla)" do
    @secret "s3cret"

    # The plug as the tree serves it: no agent asks here, so a run is placed by its folder
    # (`Runs.folder/2`), the test's repository standing as project `app`'s checkout; and what
    # `Hosts` keeps of a host is read with no ssh (`Hosts.held/2`). `make` runs on the other
    # host alone; `mix test` there, else on the workstation.
    setup c do
      heavy = [
        %{match: ~r/\bmix test\b/, class: :heavy, host: ["mac", "ws"]},
        %{match: ~r/\bmake\b/, class: :heavy, host: "mac"}
      ]

      {:ok, runs} = Runs.new(Path.join(c.dir, "runs"), programs(), heavy)
      root = Path.join(c.dir, "worktrees")
      known = %{checkouts: %{c.repo => "app"}, worktrees: root, projects: ["app"]}

      opts = [
        scheduler: fn -> c.scheduler end,
        units: fn class, _agent -> {:ok, Map.fetch!(%{heavy: %{"slot" => 1}}, class)} end,
        secret: @secret,
        host: "ws",
        policy: runs,
        jobs: fn -> c.jobs end,
        where: fn _agent, cwd -> Runs.folder(known, cwd) end,
        held: &Hosts.held(c.hosts, &1),
        away: 1_000,
        poll: 50,
        beat: 200
      ]

      server =
        start_supervised!(
          {Bandit, plug: {Runs.Plug, opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      :ok = Runs.prepare(runs, programs(), port, @secret)
      %{runs: runs, root: root}
    end

    # The wrapper as the app's lander calls it, with no agent: under the name `run-app`, on the
    # host its entry names first, in `cwd`.
    defp own(c, id, command, cwd) do
      line = "'#{Runs.wrapper(c.runs)}' --host 'mac' heavy '#{id}' 'run-app' -- '#{command}'"
      {out, err} = {Path.join(c.dir, id <> ".out"), Path.join(c.dir, id <> ".err")}
      sh = "cd '#{cwd}' && #{line} > '#{out}' 2> '#{err}'"
      {:ok, %{status: status}} = Shell.run(host(), program!(:sh), ["-c", sh], timeout: 40_000)
      {status, File.read!(out), File.read!(err)}
    end

    defp local_leases(c) do
      for %{units: %{"slot" => 1}, holder: {"run", _}} = l <- Scheduler.leases(c.scheduler),
          do: l
    end

    test "a run no agent asks for, from a project's checkout, runs on the other host", c do
      command = "make --version >/dev/null 2>&1; #{program!(:cat)} a.txt; exit 6"

      assert {6, "one\n", "caf-run: started on mac (job run-o1)\n"} =
               own(c, "o1", command, c.repo)

      assert [%{id: "run-o1", state: "exited", code: 6}] = Jobs.rows(c.jobs)
      assert local_leases(c) == []
    end

    test "from a worktree under the home it runs in that worktree's copy", c do
      tree = Path.join([c.root, "app", "fix-2"])
      File.mkdir_p!(tree)
      git = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
      {_, 0} = System.cmd(program!(:git), ["-C", tree, "init", "-q"], env: git)
      File.write!(Path.join(tree, "b.txt"), "two\n")

      assert {0, "two\n", _} =
               own(c, "o2", "make -v >/dev/null 2>&1; #{program!(:cat)} b.txt", tree)

      assert [%{id: "run-o2", state: "exited", code: 0}] = Jobs.rows(c.jobs)
    end

    test "from a folder the framework does not know it is refused no_worktree, and nothing ran",
         c do
      for {id, cwd} <- [{"o3", c.dir}, {"o4", Path.join(c.root, "other")}] do
        File.mkdir_p!(cwd)
        assert {75, "", err} = own(c, id, "make; echo ran", cwd)
        assert err =~ "caf-run: not run: the lease was refused (no_worktree)"
      end

      assert Jobs.rows(c.jobs) == []
      assert Scheduler.leases(c.scheduler) == []
    end

    test "an entry [mac, ws] with mac held away runs on the workstation, with no find of mac",
         c do
      File.write!(Path.join(c.dir, "down"), "")
      assert {:refused, {:host_away, "mac"}} = Hosts.reach(c.hosts, "mac", :place, 2_000)
      %{"mac" => %{state: :away, at: at}} = Hosts.states(c.hosts)

      assert {4, "here\n", "caf-run: mac away; running on ws\n"} =
               own(c, "o5", "mix test >/dev/null 2>&1; echo here; exit 4", c.repo)

      # Chosen from what `Hosts` keeps: mac was not found again, no job was placed, and the run
      # held the workstation's slot alone.
      assert %{"mac" => %{state: :away, at: ^at}} = Hosts.states(c.hosts)
      assert Jobs.rows(c.jobs) == []
      assert [_one] = local_leases(c)
      assert length(Scheduler.leases(c.scheduler)) == 1
    end

    test "mac found away at its placement runs on the workstation once, with the line", c do
      # Nothing is kept of mac: it is chosen, and its placement finds it away.
      assert Hosts.states(c.hosts) == %{}
      File.write!(Path.join(c.dir, "down"), "")

      assert {4, "here\n", "caf-run: mac away; running on ws\n"} =
               own(c, "o6", "mix test >/dev/null 2>&1; echo here; exit 4", c.repo)

      assert %{"mac" => %{state: :away}} = Hosts.states(c.hosts)
      assert Jobs.rows(c.jobs) == []
      assert [_one] = local_leases(c)
      assert length(Scheduler.leases(c.scheduler)) == 1
    end

    test "a host found away with no host after it is refused, and nothing ran", c do
      File.write!(Path.join(c.dir, "down"), "")
      assert {75, "", err} = own(c, "o7", "make; echo ran", c.repo)
      assert err =~ "(host_away)"
      assert Jobs.rows(c.jobs) == []
      assert Scheduler.leases(c.scheduler) == []
    end
  end

  defp released(c, id) do
    case job_lease(c, id) do
      %{released_at: at} = lease when is_integer(at) -> {:ok, lease}
      other -> {:held, other}
    end
  end
end
