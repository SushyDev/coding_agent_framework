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

    # The same, ignoring TERM (an ignored signal stays ignored across exec).
    File.write!(Path.join(dir, "stubborn"), """
    trap '' TERM
    : 2>/dev/null > "#{dir}/pids/$$" || exit 0
    echo "up in $(#{program!(:cat)} a.txt)"
    exec #{bash} -c 'read -r -t #{stand_in_idle()} l; exit 0' "$0"
    """)

    # A service that echoes each line it reads, prefixed; and one that listens on the port its
    # argument names until one connection ends (nc stays a child, so the recorded pid's command
    # line names this test's directory).
    File.write!(Path.join(dir, "echo"), """
    : 2>/dev/null > "#{dir}/pids/$$" || exit 0
    echo up
    exec #{bash} -c 'while IFS= read -r -t #{stand_in_idle()} l; do echo "got $l"; done' "$0"
    """)

    File.write!(Path.join(dir, "listen"), """
    : 2>/dev/null > "#{dir}/pids/$$" || exit 0
    exec #{bash} -c '"$1" -l 127.0.0.1 "$2"; exit 0' "$0" #{program!(:nc)} "$1"
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
    # An agent has ended once the test writes its file.
    ended = fn agent -> File.exists?(Path.join(dir, "ended-" <> agent)) end
    opts = opts ++ [grants: Grants.new(fn -> tree end), ended: ended]
    %{dir: dir, wt: wt, bash: bash, opts: opts, services: start_supervised!({Services, opts})}
  end

  defp start(c, owner, name, host, opts \\ []) do
    where = [host: host, project: "web", copy: "w", worktree: c.wt, start_timeout: 2_000]
    {script, opts} = Keyword.pop(opts, :script, "svc")
    {args, opts} = Keyword.pop(opts, :args, [])
    argv = [c.bash, Path.join(c.dir, script) | args]
    Services.start(c.services, owner, name, argv, Keyword.merge(where, opts))
  end

  defp row(c, name), do: Enum.find(Services.list(c.services), &(&1.name == name))

  # The service's log on the host, read here: the hosts' directories are this test's.
  defp log(c, host, name, text \\ "up"),
    do: read_when(Path.join([c.dir, host, "services", name <> ".log"]), text)

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

  test "StartsOnSyncedCopy, OneProcess: a restart ends the service, syncs again and counts", c do
    assert {:ok, %{pid: pid, restarts: 0}} = start(c, "web-a", "db", "box")
    # Another size: rsync's quick check skips a same-size edit made in the same second.
    File.write!(Path.join(c.wt, "a.txt"), "three\n")

    assert {:refused, :service_fixed_by_owner_or_parent} =
             Services.restart(c.services, "web-b", "db")

    assert {:ok, %{state: "running", pid: new, restarts: 1, owner: "web-a"}} =
             Services.restart(c.services, "web-main", "db")

    assert new != pid
    assert {:ok, :gone} = gone(pid)
    assert {:ok, "up in one\nup in three\n"} = log(c, "box", "db", "up in one\nup in three\n")
    assert {:ok, %{restarts: 2}} = Services.restart(c.services, "web-a", "db")
    assert Copies.turns(c.opts[:copies]) |> Enum.all?(&(&1.state == "free"))
  end

  test "HandedAlongEdge, OneOwner: the owner alone hands a service, along an edge, and keep stays with it",
       c do
    assert {:ok, %{pid: pid}} = start(c, "web-a", "web", "test", keep: true)
    assert {:refused, :handed_by_owner} = Services.hand(c.services, "web-main", "web", "web-b")
    assert {:refused, :handed_along_edge} = Services.hand(c.services, "web-a", "web", "web-b")

    assert {:ok, %{owner: "web-a1", keep: true, pid: ^pid}} =
             Services.hand(c.services, "web-a", "web", "web-a1")

    assert {:refused, :handed_by_owner} = Services.hand(c.services, "web-a", "web", "web-main")
    assert {:ok, %{owner: "web-a"}} = Services.hand(c.services, "web-a1", "web", "web-a")
  end

  test "Logs (no property of its own): a service's log is read from an offset", c do
    assert {:ok, _} = start(c, "web-a", "db", "box")
    assert {:ok, _} = log(c, "box", "db", "up in one\n")
    assert {:ok, %{text: "up in one\n", next: 10}} = Services.logs(c.services, "db", 0)
    assert {:ok, %{text: "in one\n", next: 10}} = Services.logs(c.services, "db", 3)
    assert {:ok, %{text: "", next: 10}} = Services.logs(c.services, "db", 10)
    assert {:refused, {:no_service, "web"}} = Services.logs(c.services, "web", 0)
  end

  test "EndedIsEnded: a program that ignores TERM is ended by KILL after the grace", c do
    assert {:ok, %{pid: pid}} = start(c, "web-a", "db", "box", script: "stubborn")
    assert {:ok, _} = log(c, "box", "db")
    began = System.monotonic_time(:millisecond)
    assert {:ok, %{state: "ended"}} = Services.stop(c.services, "web-a", "db", timeout: 500)
    assert System.monotonic_time(:millisecond) - began >= 500
    assert {:ok, :gone} = gone(pid)
  end

  test "ServiceEndsWithOwner: a start that settles after its owner's end does not stay running",
       c do
    File.write!(Path.join(c.dir, "ended-web-a"), "")
    assert {:refused, {:start, :owner_ended}} = start(c, "web-a", "db", "box")
    assert %{state: "ended", owner: nil} = row(c, "db")
    # The wrapper wrote the program's pid before the settle read the owner's end.
    {:ok, pid} = File.read(Path.join(c.dir, "box/services/db.pid"))
    assert {:ok, :gone} = gone(String.trim(pid))

    assert {:ok, %{state: "running", owner: "web-main", keep: true}} =
             start(c, "web-a", "web", "box", keep: true)
  end

  # Send and wait are not in the models: a send's pid check is the end's, and a wait only reads.
  for host <- ["test", "box"] do
    test "Send, Wait: on #{host}, input from the owner or its parent reaches the terminal, and a wait finds its line",
         c do
      assert {:ok, _} = start(c, "web-a", "repl", unquote(host), script: "echo")
      assert {:ok, {:line, "up", 3}} = Services.wait(c.services, "repl", {:line, "^up$"}, 5_000)
      assert {:ok, :sent} = Services.send(c.services, "web-a", "repl", "one\n")
      assert {:ok, :sent} = Services.send(c.services, "web-main", "repl", "it's two\n")

      assert {:refused, :service_fixed_by_owner_or_parent} =
               Services.send(c.services, "web-b", "repl", "x\n")

      assert {:ok, {:line, "got it's two", 24}} =
               Services.wait(c.services, "repl", {:line, ~r/two/, 3}, 5_000)

      assert {:unknown, :timeout} = Services.wait(c.services, "repl", {:line, "three", 24}, 300)
      assert {:ok, _} = Services.stop(c.services, "web-a", "repl")
      assert {:refused, {:state, "ended"}} = Services.send(c.services, "web-a", "repl", "x\n")
    end
  end

  test "Send, Wait: the exit ends a wait, after a last read of the log; a program not the row's gets no input",
       c do
    assert {:ok, %{pid: pid}} = start(c, "web-a", "db", "box")
    # The stand-in reads one line, then exits.
    assert {:ok, :sent} = Services.send(c.services, "web-a", "db", "\n")
    assert {:ok, :exited} = Services.wait(c.services, "db", :exit, 5_000)
    assert {:ok, :exited} = Services.wait(c.services, "db", {:line, "never"}, 5_000)
    assert {:ok, {:line, "up in one", 10}} = Services.wait(c.services, "db", {:line, "up"}, 5_000)
    assert {:ok, :gone} = gone(pid)
    assert {:refused, :not_held} = Services.send(c.services, "web-a", "db", "x\n")
  end

  test "Send, Wait: a drop answers a send unknown and a wait dropped; bad input is refused", c do
    assert {:ok, _} = start(c, "web-a", "repl", "box", script: "echo")
    assert {:refused, :bad_input} = Services.send(c.services, "web-a", "repl", "a\0b")

    assert {:refused, {:bad_until, {:port, 0}}} =
             Services.wait(c.services, "repl", {:port, 0}, 100)

    assert {:refused, {:bad_pattern, "("}} = Services.wait(c.services, "repl", {:line, "("}, 100)
    File.write!(Path.join(c.dir, "down"), "")
    assert {:unknown, {:send, _}} = Services.send(c.services, "web-a", "repl", "x\n")
    assert {:unknown, :dropped} = Services.wait(c.services, "repl", {:line, "up"}, 300)
    File.rm!(Path.join(c.dir, "down"))
    assert {:ok, _} = Services.stop(c.services, "web-a", "repl")
  end

  test "Wait: a port that listens on the host ends a port wait", c do
    # A port free a moment ago; the service takes it.
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    assert {:ok, _} = start(c, "web-a", "web", "box", script: "listen", args: ["#{port}"])
    assert {:ok, {:port, ^port}} = Services.wait(c.services, "web", {:port, port}, 5_000)
    assert {:ok, _} = Services.stop(c.services, "web-a", "web")
  end
end
