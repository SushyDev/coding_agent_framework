defmodule CodingAgentFramework.Copies.HeldTest do
  # Each test is named for the Copy.tla property it checks. No remote machine: the ssh host's
  # ssh is a stand-in that drops ssh's own arguments and runs the command here, or, while the
  # test's `down` file exists, exits 255 as a dropped connection does.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Copies.Held

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Copies, Holder, Host, Programs}
  alias CodingAgentFramework.Copies.Held

  # $1 the pids folder, $2 the copy; then argv. The wrapper records its pid, which exec keeps.
  @wrapper ~S"""
  p=$1 c=$2; shift 2
  : > "$p/$$"
  cd "$c" && exec "$@"
  """

  setup do
    dir = test_dir()
    on_exit(fn -> end_recorded(dir) end)
    wt = Path.join(dir, "wt")
    env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    File.mkdir_p!(wt)
    {_, 0} = System.cmd(program!(:git), ["-C", wt, "init", "-q"], env: env)
    File.write!(Path.join(wt, "a.txt"), "one\n")
    File.mkdir_p!(Path.join(dir, "pids"))

    ssh = Path.join(dir, "ssh")

    File.write!(ssh <> ".new", """
    #!#{program!(:bash)}
    [ -e "#{dir}/down" ] && exit 255
    while :; do case $1 in -o|-l) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
    shift
    exec #{program!(:sh)} -c "$*"
    """)

    File.chmod!(ssh <> ".new", 0o755)
    File.rename!(ssh <> ".new", ssh)
    {:ok, remote} = Programs.new(Host.ssh("box", ssh, "box", program!(:kill)), programs().paths)
    copies = start_supervised!({Copies, dir: Path.join(dir, "local"), programs: programs()})

    hosts = %{
      "test" => %{programs: programs(), dir: Path.join(dir, "ws")},
      "box" => %{programs: remote, dir: Path.join(dir, "box")}
    }

    %{dir: dir, wt: wt, copies: copies, config: %{hosts: hosts, copies: copies}}
  end

  defp context(c, host, name) do
    where = %{host: host, project: "p", copy: "w", kind: "held", name: name, run: "run:" <> name}
    {:ok, ctx} = Held.context(c.config, where, 2_000)
    ctx
  end

  defp ready(c, ctx) do
    test = self()
    opts = [sync_timeout: 10_000, lock_wait: 5_000]
    Held.ready(ctx, c.wt, opts, &send(test, {:refused, &1}))
  end

  # The program prints the synced file into the copy, then waits. Its `$0` names the test's own
  # directory, so the test's end, which signals a recorded pid only while its command line names
  # that directory, ends it (F-66; it was left until its idle bound, F-94).
  defp hold(c, ctx) do
    seen = "#{program!(:cat)} a.txt > seen.new && #{program!(:mv)} seen.new seen"
    me = Path.join(c.dir, "held-program")
    argv = [program!(:bash), "-c", "#{seen}; read -r -t #{stand_in_idle()} l", me]
    Held.hold(ctx, @wrapper, ["caf-held", Path.join(c.dir, "pids"), ctx.path], argv, [])
  end

  # Holder's read of the socket, as a caller's read of its program.
  defp read(ctx) do
    test = self()

    fn how ->
      send(test, {:read, how, now()})

      case Holder.state(ctx.holder, ctx.name) do
        {:ok, :live} -> {:ok, :held}
        {:ok, other} -> {:ok, other}
        unknown -> unknown
      end
    end
  end

  defp write do
    test = self()

    fn seen ->
      send(test, {:wrote, seen})
      {:ok, :settled}
    end
  end

  defp turn(c), do: Enum.find(Copies.turns(c.copies), &(&1.name == "w"))

  defp now, do: System.os_time(:millisecond)

  for host <- ["test", "box"] do
    test "StartsOnSyncedCopy: a start held by dtach's reply runs on the synced copy on #{host}",
         c do
      ctx = context(c, unquote(host), "s1")
      assert {:ok, %{record: %{}, files: 1}} = ready(c, ctx)
      assert %{state: "starting", holder: "run:s1"} = turn(c)
      assert {:ok, _socket} = reply = hold(c, ctx)

      assert {:ok, :settled} = Held.settle(ctx, reply, now() + 2_000, read(ctx), write())
      assert_received {:read, :reply, _}
      assert_received {:wrote, {:ok, :held}}
      assert {:ok, "one\n"} = read_when(Path.join(ctx.path, "seen"), "one\n")
      assert %{state: "free", holder: nil} = turn(c)
      refute_received {:refused, _}
    end
  end

  test "NoUntrackedProcess: a start whose reply was cut is read on the host after its deadline",
       c do
    ctx = context(c, "box", "s2")
    assert {:ok, _} = ready(c, ctx)
    assert {:ok, _} = hold(c, ctx)
    # The start landed, but its reply was lost: only a read of the host can say so.
    until = now() + 300

    assert {:ok, :settled} = Held.settle(ctx, {:unknown, :cut}, until, read(ctx), write())
    assert_received {:read, :cut, at}
    assert at >= until
    assert_received {:wrote, {:ok, :held}}
    assert %{state: "free"} = turn(c)
  end

  test "OneSyncWrites: an unread start keeps the copy's turn until a later read settles it", c do
    ctx = context(c, "box", "s3")
    assert {:ok, _} = ready(c, ctx)
    assert {:ok, _} = hold(c, ctx)
    File.write!(Path.join(c.dir, "down"), "")

    assert {:unknown, {:sh, 255, _}} =
             Held.settle(ctx, {:unknown, :cut}, now(), read(ctx), write())

    assert_received {:read, :cut, _}
    refute_received {:wrote, _}
    assert %{state: "starting", holder: "run:s3"} = turn(c)
    assert {:refused, {:turn_held, "run:s3"}} = Copies.take(c.copies, ctx.copy, "other")

    File.rm!(Path.join(c.dir, "down"))
    later = now() + 60_000
    assert {:unknown, {:starting_until, ^later}} = Held.settle_cut(ctx, later, read(ctx), write())
    refute_received {:read, _, _}

    assert {:ok, :settled} = Held.settle_cut(ctx, now(), read(ctx), write())
    assert_received {:wrote, {:ok, :held}}
    assert %{state: "free"} = turn(c)
  end

  test "OneProcess: a second hold of a live name is refused as a start, and the turn goes back",
       c do
    ctx = context(c, "test", "s4")
    assert {:ok, _} = ready(c, ctx)
    assert {:ok, :settled} = Held.settle(ctx, hold(c, ctx), now(), read(ctx), write())
    assert_received {:wrote, {:ok, :held}}

    assert {:ok, _} = ready(c, ctx)
    assert {:refused, {:live, "s4"}} = reply = hold(c, ctx)
    assert {:ok, :settled} = Held.settle(ctx, reply, now(), read(ctx), write())
    refute_received {:read, :cut, _}
    assert_received {:wrote, {:refused, {:start, {:live, "s4"}}}}
    assert %{state: "free"} = turn(c)
    assert {:ok, [_one]} = File.ls(Path.join(c.dir, "pids"))
  end

  test "StartsOnSyncedCopy: a refused sync is handed to the caller, and nothing is held", c do
    ctx = context(c, "box", "s5")
    File.write!(Path.join(c.dir, "down"), "")

    assert {:refused, {:sync, _}} = refused = ready(c, ctx)
    assert_received {:refused, ^refused}
    refute File.exists?(ctx.dir)
    assert File.ls!(Path.join(c.dir, "pids")) == []
  end
end
