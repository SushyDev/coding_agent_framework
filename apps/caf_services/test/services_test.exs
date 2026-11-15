defmodule CodingAgentFramework.ServicesTest do
  # Each test is named for the Copy.tla or Team.tla property it checks. No remote machine: the
  # ssh host's ssh is a stand-in that drops ssh's own arguments and runs the command here, or,
  # while the test's `down` file exists, exits 255 as a dropped connection does.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Services.Table

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Copies, Grants, Host, Programs, Services}

  setup do
    dir = test_dir()
    on_exit(fn -> end_recorded(dir) end)
    wt = Path.join(dir, "wt")
    env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    File.mkdir_p!(wt)
    {_, 0} = System.cmd(program!(:git), ["-C", wt, "init", "-q"], env: env)
    File.write!(Path.join(wt, "a.txt"), "one\n")
    File.mkdir_p!(Path.join(dir, "pids"))
    bash = program!(:bash)

    # The service: it records its pid, says what the copy's a.txt holds, and waits for input
    # (bounded by stand_in_idle/0), until it is ended.
    File.write!(Path.join(dir, "svc"), """
    : 2>/dev/null > "#{dir}/pids/$$" || exit 0
    echo "up in $(#{program!(:cat)} a.txt)"
    exec #{bash} -c 'read -r -t #{stand_in_idle()} l; exit 0' "$0"
    """)

    File.write!(Path.join(dir, "ssh"), """
    #!#{bash}
    [ -e "#{dir}/down" ] && exit 255
    while :; do case $1 in -o|-l) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
    shift
    exec #{program!(:sh)} -c "$*"
    """)

    File.chmod!(Path.join(dir, "ssh"), 0o755)
    box = Host.ssh("box", Path.join(dir, "ssh"), "box", program!(:kill))
    {:ok, remote} = Programs.new(box, programs().paths)
    copies = start_supervised!({Copies, dir: Path.join(dir, "copies"), programs: programs()})

    hosts = %{
      "test" => %{programs: programs(), dir: Path.join(dir, "ws")},
      "box" => %{programs: remote, dir: Path.join(dir, "box")}
    }

    # web-main's delegates web-a and web-b; web-a's child web-a1 (a delegate of a delegate
    # stands in for any child here: Grants reads only the parent links).
    tree = [
      %{name: "web-a", project: "web", parent: "web-main"},
      %{name: "web-b", project: "web", parent: "web-main"},
      %{name: "web-a1", project: "web", parent: "web-a"}
    ]

    opts = [dir: Path.join(dir, "services"), copies: copies, hosts: hosts]
    opts = opts ++ [grants: Grants.new(fn -> tree end)]
    %{dir: dir, wt: wt, bash: bash, opts: opts, services: start_supervised!({Services, opts})}
  end

  defp start(c, owner, name, host, opts \\ []) do
    where = [host: host, project: "web", copy: "w", worktree: c.wt, start_timeout: 2_000]
    argv = [c.bash, Path.join(c.dir, "svc")]
    Services.start(c.services, owner, name, argv, Keyword.merge(where, opts))
  end

  defp row(c, name), do: Enum.find(Services.list(c.services), &(&1.name == name))

  # The service's log on the host, read here: the hosts' directories are this test's.
  defp log(c, host, name),
    do: read_when(Path.join([c.dir, host, "services", name <> ".log"]), "up")

  defp gone(pid), do: await(fn -> if alive?(pid), do: :alive, else: {:ok, :gone} end)

  for host <- ["test", "box"] do
    test "StartsOnSyncedCopy: a service on #{host} starts on a whole sync, held with its pid",
         c do
      assert {:ok, %{state: "running", pid: pid, started: started, owner: "web-a"}} =
               start(c, "web-a", "db", unquote(host))

      assert is_integer(pid) and started =~ ~r/\d\d:\d\d:\d\d \d{4}$/
      dir = if unquote(host) == "test", do: "ws", else: "box"
      assert {:ok, "up in one\n"} = log(c, dir, "db")
      assert alive?(pid)
      assert {:refused, {:service_exists, "db"}} = start(c, "web-a", "db", unquote(host))
      assert Copies.turns(c.opts[:copies]) |> Enum.all?(&(&1.state == "free"))
    end
  end

  test "OneOwner: only an agent the tree holds starts a service, and owns it alone", c do
    assert {:refused, {:unknown_agent, "nobody"}} = start(c, "nobody", "db", "test")
    assert {:ok, %{owner: "web-main"}} = start(c, "web-main", "db", "test")
    assert {:ok, %{state: "ended", owner: nil}} = Services.stop(c.services, "web-main", "db")
  end

  test "ServiceFixedByOwnerOrParent, EndedIsEnded: a stop by the owner's parent is done on a dead socket",
       c do
    assert {:ok, %{pid: pid}} = start(c, "web-a", "db", "box")

    for other <- ["web-b", "web-a1"] do
      assert {:refused, :service_fixed_by_owner_or_parent} =
               Services.stop(c.services, other, "db")
    end

    assert {:ok, %{state: "ended", pid: nil}} = Services.stop(c.services, "web-main", "db")
    refute File.exists?(Path.join(c.dir, "box/services/db.sock"))
    assert {:ok, :gone} = gone(pid)
    assert {:refused, {:state, "ended"}} = Services.stop(c.services, "web-a", "db")
  end

  test "EndedIsEnded: an end the connection cut stays written, and is done once the socket reads dead",
       c do
    assert {:ok, %{pid: pid}} = start(c, "web-a", "db", "box")
    File.write!(Path.join(c.dir, "down"), "")
    assert {:unknown, {:end, _}} = Services.stop(c.services, "web-a", "db", timeout: 500)
    assert %{state: "ending", owner: "web-a"} = row(c, "db")
    assert alive?(pid)
    File.rm!(Path.join(c.dir, "down"))
    stop_supervised!(Services)
    services = start_supervised!({Services, c.opts})

    assert {:ok, %{state: "ended"}} =
             await_cued(
               services,
               fn -> Services.cue(services, %{topic: :host}) end,
               fn ->
                 with %{state: "ended"} = r <- row(%{c | services: services}, "db"), do: {:ok, r}
               end,
               10_000
             )

    assert {:ok, :gone} = gone(pid)
  end

  test "ServiceEndsWithOwner: an owner's end ends its services, and hands a kept one to its parent",
       c do
    assert {:ok, %{pid: pid}} = start(c, "web-a", "db", "box")
    assert {:ok, _} = start(c, "web-a", "web", "box", keep: true)
    assert {:ok, _} = start(c, "web-b", "cache", "box")

    assert {:ok, %{"db" => {:ok, :ended}, "web" => {:ok, {:handed, "web-main"}}} = ends} =
             Services.owner_ended(c.services, "web-a")

    assert map_size(ends) == 2
    assert {:ok, :gone} = gone(pid)
    assert %{state: "running", owner: "web-main", keep: true} = row(c, "web")
    assert %{state: "running", owner: "web-b"} = row(c, "cache")
  end

  test "ServiceEndsWithOwner: keep stays with a handed service, so each owner's end hands it on",
       c do
    assert {:ok, %{pid: pid}} = start(c, "web-a1", "web", "test", keep: true)

    assert {:ok, %{"web" => {:ok, {:handed, "web-a"}}}} =
             Services.owner_ended(c.services, "web-a1")

    assert {:ok, %{"web" => {:ok, {:handed, "web-main"}}}} =
             Services.owner_ended(c.services, "web-a")

    assert %{state: "running", owner: "web-main", keep: true, pid: ^pid} = row(c, "web")
    assert {:ok, %{state: "ended"}} = Services.stop(c.services, "web-main", "web")
  end
end
