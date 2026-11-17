defmodule CodingAgentFramework.ServicesTest do
  # Each test is named for the Copy.tla or Team.tla property it checks. No remote machine: the
  # ssh host's ssh is a stand-in that drops ssh's own arguments and runs the command here, or,
  # while the test's `down` file exists, exits 255 as a dropped connection does. It cannot
  # forward: given `-L`, it becomes an nc that listens on the local port itself (its pid, the
  # one the forward's wrapper wrote) and relays nothing; with the `no-forward` file, it runs and
  # holds no port. That is what `OpenByPort` needs: whose process listens, not what it relays.
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

    # A service that, at TERM, writes whether its forward's local port (its argument) still
    # listens.
    File.write!(Path.join(dir, "watch"), """
    : 2>/dev/null > "#{dir}/pids/$$" || exit 0
    trap '#{program!(:nc)} -z 127.0.0.1 "$1" && r=live || r=dead; echo $r > "#{dir}/at-term"; exit 0' TERM
    echo up
    i=0; while [ $i -lt #{stand_in_idle() * 10} ]; do #{program!(:sleep)} 0.1; i=$((i+1)); done
    """)

    # A forward writes whether db's pid file was there when it began (`ForwardEarly`). Its nc
    # takes a name under this test's directory, so `end_recorded/1` can end it; a sleep ends it
    # after the stand-in's idle time.
    File.write!(Path.join(dir, "ssh"), """
    #!#{bash}
    [ -e "#{dir}/down" ] && exit 255
    f=
    while :; do case $1 in -L) f=$2; shift 2 ;; -o|-l) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
    shift
    [ -z "$f" ] && exec #{program!(:sh)} -c "$*"
    : > "#{dir}/pids/$$"
    [ -s "#{dir}/box/services/db.pid" ] && echo after > "#{dir}/fwd-saw" || echo before > "#{dir}/fwd-saw"
    [ -e "#{dir}/no-forward" ] && exec #{bash} -c 'read -r -t #{stand_in_idle()} l' "#{dir}/fwd"
    (#{program!(:sleep)} #{stand_in_idle()}; #{program!(:kill)} $$) 2>/dev/null &
    l=${f#127.0.0.1:}
    exec -a "#{dir}/fwd" #{program!(:nc)} -k -l 127.0.0.1 "${l%%:*}"
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

    opts = [dir: Path.join(dir, "services"), copies: copies, hosts: hosts, workstation: "test"]
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

  test "BoundedRead: a log read from an offset answers at most the bound, and the next offset",
       c do
    assert {:ok, _} = start(c, "web-a", "db", "box")
    assert {:ok, _} = log(c, "box", "db", "up in one\n")
    path = Path.join([c.dir, "box", "services", "db.log"])
    File.write!(path, String.duplicate("0123456789", 100_000), [:append])

    assert {:ok, %{text: text, next: 110}} = Services.logs(c.services, "db", 10, max: 100)
    assert text == String.duplicate("0123456789", 10)
    assert {:ok, %{text: text, next: next}} = Services.logs(c.services, "db", 10)
    assert byte_size(text) == 16_384 and next == 10 + 16_384

    assert {:ok, %{text: "", next: 1_000_010}} =
             Services.logs(c.services, "db", 1_000_010, max: 100)
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
    assert {:ok, :gone} = gone(pid |> String.split() |> hd())

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

  test "Wait: a line wait looks from the current start's log offset, or from one the caller names",
       c do
    assert {:ok, %{log_from: 0}} = start(c, "web-a", "db", "box")
    File.write!(Path.join(c.wt, "a.txt"), "three\n")
    assert {:ok, %{log_from: 10}} = Services.restart(c.services, "web-a", "db")

    assert {:ok, {:line, "up in three", 22}} =
             Services.wait(c.services, "db", {:line, "up"}, 5_000)

    assert {:unknown, :timeout} = Services.wait(c.services, "db", {:line, "one"}, 300)

    assert {:ok, {:line, "up in one", 10}} =
             Services.wait(c.services, "db", {:line, "one", 0}, 300)
  end

  test "Table (no property of its own): a file made before the forward's columns opens with them",
       c do
    path = Path.join(c.dir, "old.db")
    {:ok, db} = Exqlite.Sqlite3.open(path)

    old =
      "CREATE TABLE services (name TEXT PRIMARY KEY, host TEXT NOT NULL, project TEXT NOT NULL,
      copy TEXT NOT NULL, worktree TEXT NOT NULL, argv TEXT NOT NULL, env TEXT NOT NULL,
      owner TEXT, keep INTEGER NOT NULL, pid INTEGER, started TEXT, restarts INTEGER NOT NULL,
      state TEXT NOT NULL, start_until INTEGER, end_until INTEGER)"

    :ok = Exqlite.Sqlite3.execute(db, old)
    empty = Base.encode64(:erlang.term_to_binary([]))

    :ok =
      Exqlite.Sqlite3.execute(db, """
      INSERT INTO services VALUES ('db', 'box', 'web', 'w', '/wt', '#{empty}', '#{empty}', NULL,
        0, NULL, NULL, 0, 'ended', NULL, NULL)
      """)

    :ok = Exqlite.Sqlite3.close(db)
    assert {:ok, db} = Services.Table.open(path)

    assert %{state: "ended", log_from: nil, port: nil, fwd: nil, opens: 0} =
             Services.Table.get(db, "db")

    assert {:ok, ^db} = {Services.Table.open(path) |> elem(0), db}
  end

  # A port free a moment ago.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp listens?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000) do
      {:ok, socket} -> :gen_tcp.close(socket) || true
      _ -> false
    end
  end

  defp fwd_sock(c), do: Path.join(c.dir, "ws/services/db.sock")

  defp fwd_pid(c),
    do: c.dir |> Path.join("ws/services/db.pid") |> File.read!() |> String.split() |> hd()

  defp start_forwarded(c, opts \\ []) do
    {port, local} = {free_port(), free_port()}
    opts = Keyword.merge([forward: {port, local}, forward_timeout: 2_000], opts)
    {start(c, "web-a", "db", "box", opts), port, local}
  end

  test "ForwardEarly, OpenByPort: the forward is held once the service runs, and the start answers once its own ssh holds the local port",
       c do
    assert {{:ok, row}, port, local} = start_forwarded(c)
    assert %{state: "running", port: ^port, local: ^local, fwd: "open", opens: 1} = row
    assert {:ok, "after\n"} = read_when(Path.join(c.dir, "fwd-saw"), "after\n")
    assert listens?(local)
    assert {:ok, %{state: "ended"}} = Services.stop(c.services, "web-a", "db")
    refute listens?(local)

    assert {:refused, {:bad_forward, {80, 81}}} =
             start(c, "web-a", "web", "test", forward: {80, 81})
  end

  test "OpenByPort, FailKeepsService: a forward whose ssh does not hold the port, or exits, fails and ends the service",
       c do
    # Another program holds the local port; the stand-in runs and holds none.
    {:ok, other} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, local} = :inet.port(other)
    File.write!(Path.join(c.dir, "no-forward"), "")
    port = free_port()

    assert {:refused, {:forward, :not_open}} =
             start(c, "web-a", "db", "box", forward: {port, local}, forward_timeout: 1_000)

    assert %{state: "ended", fwd: "failed", owner: nil} = row(c, "db")
    refute File.exists?(fwd_sock(c))
    # Without the file, its nc cannot bind the port and exits, as ssh with ExitOnForwardFailure.
    File.rm!(Path.join(c.dir, "no-forward"))

    assert {:refused, {:forward, :exited}} =
             start(c, "web-a", "db", "box", forward: {port, local}, forward_timeout: 2_000)

    assert %{state: "ended", fwd: "failed"} = row(c, "db")
    {:ok, pid} = File.read(Path.join(c.dir, "box/services/db.pid"))
    assert {:ok, :gone} = gone(pid |> String.split() |> hd())
    :gen_tcp.close(other)
  end

  test "a name is a file name on the host: 1 to 64 letters, digits, - or _, checked before anything starts",
       c do
    for name <- ["", "../db", "a b", "db.x", String.duplicate("a", 65), 5] do
      assert {:refused, {:name, ^name}} = start(c, "web-a", name, "test")
    end

    assert Services.list(c.services) == []
    assert {:ok, %{state: "running"}} = start(c, "web-a", String.duplicate("a", 64), "test")
  end

  test "a local port another live forward holds is refused, naming its service, before anything starts",
       c do
    assert {{:ok, _}, _port, local} = start_forwarded(c)
    other = free_port()

    assert {:refused, {:local_taken, "db"}} =
             start(c, "web-a", "web", "box", forward: {other, local})

    assert row(c, "web") == nil
    assert {:ok, %{state: "ended"}} = Services.stop(c.services, "web-a", "db")
    assert {:ok, %{local: ^local}} = start(c, "web-a", "web", "box", forward: {other, local})
  end

  test "a timeout bounds the whole start, the forward's wait included", c do
    File.write!(Path.join(c.dir, "no-forward"), "")
    {port, local} = {free_port(), free_port()}
    from = System.monotonic_time(:millisecond)

    assert {:refused, {:forward, :not_open}} =
             start(c, "web-a", "db", "box",
               forward: {port, local},
               forward_timeout: 60_000,
               timeout: 4_000
             )

    assert System.monotonic_time(:millisecond) - from < 15_000
    assert %{state: "ended", fwd: "failed"} = row(c, "db")
  end

  test "ServiceEndFirst: an end ends the forward first, and is done once both sockets read dead",
       c do
    {port, local} = {free_port(), free_port()}

    assert {:ok, %{pid: pid}} =
             start(c, "web-a", "db", "box",
               script: "watch",
               args: ["#{local}"],
               forward: {port, local}
             )

    assert {:ok, _} = log(c, "box", "db")
    assert {:ok, %{state: "ended"}} = Services.stop(c.services, "web-a", "db")
    assert {:ok, "dead\n"} = read_when(Path.join(c.dir, "at-term"), "dead\n")
    refute File.exists?(fwd_sock(c))
    assert {:ok, :gone} = gone(pid)
  end

  test "ForwardReopened once per Key: a lost forward reopens once per claimed state; a failed reopen stays failed until the next start",
       c do
    assert {{:ok, %{pid: pid, started: started}}, _port, local} = start_forwarded(c)
    claim = %{pid: pid, started: started, opens: 1}
    assert {:refused, :forward_live} = Services.reopen(c.services, "db", claim)

    lose = fn ->
      kill(fwd_pid(c))
      await(fn -> if File.exists?(fwd_sock(c)), do: :live, else: {:ok, :dead} end)
    end

    assert {:ok, :dead} = lose.()
    assert {:ok, %{fwd: "open", opens: 2}} = Services.reopen(c.services, "db", claim)
    assert listens?(local)
    assert {:ok, :dead} = lose.()
    assert {:refused, {:changed, _}} = Services.reopen(c.services, "db", claim)
    File.write!(Path.join(c.dir, "down"), "")
    claim = %{claim | opens: 2}
    assert {:refused, {:forward, :exited}} = Services.reopen(c.services, "db", claim)
    assert %{state: "running", fwd: "failed", pid: ^pid} = row(c, "db")
    assert {:refused, {:changed, _}} = Services.reopen(c.services, "db", claim)
    File.rm!(Path.join(c.dir, "down"))
    assert {:ok, %{fwd: "open", opens: 1}} = Services.restart(c.services, "web-a", "db")
    assert {:refused, {:changed, _}} = Services.reopen(c.services, "db", %{claim | opens: 1})
  end
end
