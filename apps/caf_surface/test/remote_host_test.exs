defmodule CodingAgentFramework.RemoteHostTest do
  # The tree's jobs on another host its config declares, whose programs `Hosts` finds when work
  # goes there (Host.tla, F-280). No remote machine: the host's ssh is a stand-in that drops
  # ssh's own arguments and runs the command here with the host's own PATH, a directory of
  # links the test adds to and removes from; while the test's `down` file exists, it exits 255
  # as ssh does for a host it cannot reach.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Config, Host, Hosts, Jobs}

  setup do
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

    File.write!(Path.join(dir, "ssh"), """
    #!#{program!(:bash)}
    [ -e "#{dir}/down" ] && exit 255
    while :; do case $1 in -o|-l) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
    shift
    PATH="#{bin}" exec #{program!(:sh)} -c "$*"
    """)

    File.chmod!(Path.join(dir, "ssh"), 0o755)
    mac = Host.ssh("mac", Path.join(dir, "ssh"), "mac", program!(:kill))
    programs = Map.drop(programs().paths, [:gh, :ssh, :ssh_keygen])

    {:ok, config} =
      Config.new(
        home: Path.join(dir, "home"),
        instance: "remote-#{System.unique_integer([:positive])}",
        programs: programs,
        env: %{path: "/nonexistent"},
        agents: false,
        hosts: %{"mac" => %{host: mac, dir: Path.join(dir, "mac")}}
      )

    File.mkdir_p!(config.home)
    parts = CodingAgentFramework.parts(start_supervised!({CodingAgentFramework, config}))
    {:ok, units} = CodingAgentFramework.job_units(config, :heavy, "app")
    lease = %{class: :heavy, module: "app", units: units}
    %{dir: dir, bin: bin, repo: repo, jobs: parts.jobs, lease: lease}
  end

  defp link(bin, name, target), do: File.ln_s!(target, Path.join(bin, name))

  defp run(c, id) do
    where = %{host: "mac", project: "app", name: "app-w"}
    argv = [program!(:cat), "a.txt"]
    opts = [timeout: 10_000, start_timeout: 2_000, lease: c.lease]
    Jobs.run(c.jobs, id, where, c.repo, argv, opts)
  end

  test "a job runs on a host whose programs are found when it is placed", c do
    assert {:ok, %{exit: 0, log: "one\n"}} = run(c, "j1")
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

    File.rm!(Path.join(c.dir, "down"))
    assert {:ok, %{exit: 0}} = run(c, "j2")
  end
end
