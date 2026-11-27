defmodule CodingAgentFramework.HostsTest do
  # Each test is named for the Host.tla property it checks. No remote machine: the host's ssh
  # is a stand-in that drops ssh's own arguments and runs the command here with the host's own
  # PATH, a directory of links the test adds to and removes from; while the test's `down` file
  # exists, it exits 255 as ssh does for a host it cannot reach, and while `hang` exists it
  # never answers, as a host asleep does.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Hosts

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Host, Hosts}

  setup do
    dir = test_dir()
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    for name <- Hosts.needs(Host.local("x", "/bin/kill")),
        do: link(bin, Atom.to_string(name), program!(name))

    # `Programs.find/3` names the kernel with `uname -s`, which coreutils has beside kill.
    link(bin, "uname", Path.join(Path.dirname(program!(:kill)), "uname"))

    File.write!(Path.join(dir, "ssh"), """
    #!#{program!(:bash)}
    [ -e "#{dir}/down" ] && exit 255
    [ -e "#{dir}/hang" ] && exec #{program!(:sleep)} 30
    while :; do case $1 in -o|-l) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
    shift
    PATH="#{bin}" exec #{program!(:sh)} -c "$*"
    """)

    File.chmod!(Path.join(dir, "ssh"), 0o755)
    mac = Host.ssh("mac", Path.join(dir, "ssh"), "mac", program!(:kill))

    hosts =
      start_supervised!({Hosts, hosts: %{"mac" => %{host: mac, dir: "/caf"}}, retry: 60_000})

    %{dir: dir, bin: bin, hosts: hosts}
  end

  defp link(bin, name, target), do: File.ln_s!(target, Path.join(bin, name))

  test "placed: a host with every program takes work, and a read of it costs no ssh", c do
    assert {:ok, %{programs: programs, dir: "/caf", env: [], ssh_env: []}} =
             Hosts.reach(c.hosts, "mac", :place, 5_000)

    assert programs.paths.dtach == Path.join(c.bin, "dtach")
    assert %{"mac" => %{state: :ready}} = Hosts.states(c.hosts)

    # Work already placed reads the programs kept, even while the host does not answer.
    File.write!(Path.join(c.dir, "down"), "")
    assert {:ok, %{programs: ^programs}} = Hosts.reach(c.hosts, "mac", :reach, 5_000)
  end

  test "NotPlacedAway: a ready host that stops answering refuses new work, then joins", c do
    assert {:ok, _} = Hosts.reach(c.hosts, "mac", :place, 5_000)
    File.write!(Path.join(c.dir, "down"), "")
    assert {:refused, {:host_away, "mac"}} = Hosts.reach(c.hosts, "mac", :place, 5_000)
    assert %{"mac" => %{state: :away}} = Hosts.states(c.hosts)

    # Within its retry interval, a read of work there answers from what is kept.
    assert {:unknown, {:host_away, "mac"}} = Hosts.reach(c.hosts, "mac", :reach, 5_000)

    File.rm!(Path.join(c.dir, "down"))
    assert {:ok, _} = Hosts.reach(c.hosts, "mac", :place, 5_000)
  end

  test "Answered: a host that never answers is refused at the placement's bound", c do
    File.write!(Path.join(c.dir, "hang"), "")
    begun = System.monotonic_time(:millisecond)
    assert {:refused, {:host_away, "mac"}} = Hosts.reach(c.hosts, "mac", :place, 300)
    assert System.monotonic_time(:millisecond) - begun < 2_000
  end

  test "MissingOnlyLacking: every program missing is named, and found once it is added", c do
    for name <- ["dtach", "flock"], do: File.rm!(Path.join(c.bin, name))

    assert {:refused, {:no_program, "mac", missing}} = Hosts.reach(c.hosts, "mac", :place, 5_000)
    assert Enum.sort(missing) == [:dtach, :flock]

    for name <- [:dtach, :flock], do: link(c.bin, Atom.to_string(name), program!(name))
    assert {:ok, _} = Hosts.reach(c.hosts, "mac", :place, 5_000)
  end

  test "an rsync too old for the copy is refused with what it says it is", c do
    File.rm!(Path.join(c.bin, "rsync"))
    old = Path.join(c.dir, "openrsync")
    File.write!(old, "#!#{program!(:sh)}\necho 'openrsync: protocol version 29'\n")
    File.chmod!(old, 0o755)
    link(c.bin, "rsync", old)

    assert {:refused, {:old_rsync, "mac", "openrsync: protocol version 29"}} =
             Hosts.reach(c.hosts, "mac", :place, 5_000)
  end

  test "a host the app did not declare is refused by name", c do
    assert {:refused, {:no_host, "pi"}} = Hosts.reach(c.hosts, "pi", :place, 5_000)
  end
end
