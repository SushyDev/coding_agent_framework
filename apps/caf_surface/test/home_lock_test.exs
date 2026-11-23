defmodule CodingAgentFramework.HomeLockTest do
  # F-215: a home belongs to one tree at a time. Each test has homes of its own, and trees
  # without agents on them (no tmux server, no ports), each with an instance name of its own.
  # A tree here is started by the test and unlinked from it, so a test can kill it.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Config, Home}

  setup do
    %{dir: test_dir()}
  end

  # A tree without agents: no gh, ssh or ssh-keygen, which it makes no tool home for (F-201).
  defp config(home) do
    programs = Map.drop(programs().paths, [:gh, :ssh, :ssh_keygen])
    name = "lock-#{System.unique_integer([:positive])}"
    fields = [home: home, instance: name, programs: programs, env: %{path: "/nonexistent"}]
    {:ok, c} = Config.new(fields ++ [agents: false, interval: 200])
    c
  end

  defp start(c) do
    {:ok, sup} = CodingAgentFramework.start_link(c)
    Process.unlink(sup)
    on_exit(fn -> stop(sup) end)
    sup
  end

  defp stop(sup) do
    Supervisor.stop(sup)
  catch
    :exit, _ -> :ok
  end

  defp holder(sup), do: CodingAgentFramework.parts(sup).home

  # The files under the home but SQLite's own journal files, which the running tree changes.
  defp files(home) do
    home
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&String.ends_with?(&1, ["-wal", "-shm"]))
  end

  defp record(c), do: File.read!(Path.join(c.home, "home.holder"))

  test "a second start on a held home is refused at once, names the holder, touches nothing",
       ctx do
    home = Path.join(ctx.dir, "home")
    {a, b} = {config(home), config(home)}
    start(a)
    {before, record} = {files(home), record(a)}

    started = System.monotonic_time(:millisecond)
    assert {:refused, {:home_held, holder}} = CodingAgentFramework.start_link(b)
    # One try, no wait: `restart_wait` (5 s) is for an instance of the same name only.
    assert System.monotonic_time(:millisecond) - started < b.restart_wait

    assert %{instance: instance, os_pid: os_pid, node: node, taken_at: at} = holder
    assert {instance, os_pid, node} == {a.instance, System.pid(), Atom.to_string(node())}
    assert is_integer(at)

    # Nothing of b's started, and nothing under the home changed.
    assert files(home) == before
    assert record(a) == record
    assert CodingAgentFramework.agent_rows(b.instance) == {:refused, :no_instance}
    assert Home.Lock.whereis(b.instance) == nil

    # The kind is read with no lock, while the home is held.
    assert CodingAgentFramework.home_kind(b) == {:ok, :agentless}
  end

  test "a normal stop gives the home back, and removes the holder's record", ctx do
    home = Path.join(ctx.dir, "home")
    {a, b} = {config(home), config(home)}
    a |> start() |> stop()

    refute File.exists?(Path.join(home, "home.holder"))
    # The lock's file stays, and holds nothing.
    assert File.exists?(Path.join(home, "home.lock"))
    start(b)
    assert record(b) =~ "instance #{b.instance}\n"
  end

  @tag :capture_log
  test "a tree killed whole is started again at once on its home, by its own name", ctx do
    a = config(Path.join(ctx.dir, "home"))
    sup = start(a)
    old = holder(sup)
    Process.exit(sup, :kill)

    # The start of its name waits for the old holder to end, and takes the home.
    again = start(a)
    refute Process.alive?(old)
    assert holder(again) != old
  end

  test "a holder's death ends its tree, and another start then takes the home", ctx do
    home = Path.join(ctx.dir, "home")
    {a, b} = {config(home), config(home)}
    sup = start(a)
    lock = holder(sup)
    {tree, held} = {Process.monitor(sup), Process.monitor(lock)}

    # A death with no cleanup: the holder's file is closed as its process goes.
    Process.exit(lock, :kill)
    assert_receive {:DOWN, ^held, :process, _, :killed}, 5_000
    assert_receive {:DOWN, ^tree, :process, _, :shutdown}, 5_000

    # Its record stays behind, and blocks nothing.
    assert record(a) =~ "instance #{a.instance}\n"
    start(b)
    assert record(b) =~ "instance #{b.instance}\n"
  end

  # A second VM on this host holds the home by the same take as a start's first step, then dies
  # with no cleanup. Its VM boots slowly on a loaded machine: its wait is 45 s, not :peer's 15.
  @tag timeout: 90_000
  test "a home held by another VM refuses a start, and is taken once that VM dies", ctx do
    home = Path.join(ctx.dir, "home")
    {a, b} = {config(home), config(home)}
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, _node} =
      :peer.start(%{connection: :standard_io, args: paths, wait_boot: 45_000})

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    vm = List.to_string(:peer.call(peer, :os, :getpid, [], 10_000))
    announce = Path.join(ctx.dir, "held")

    code = """
    {:ok, _lock} = CodingAgentFramework.Home.Lock.take(config)
    File.write!(announce, "held\\n")
    receive do: (:never -> :ok)
    """

    args = [code, [config: a, announce: announce]]
    :peer.call(peer, :erlang, :spawn, [Code, :eval_string, args], 10_000)
    assert {:ok, _} = read_when(announce, "held\n")

    assert {:refused, {:home_held, %{instance: instance, os_pid: ^vm}}} =
             CodingAgentFramework.start_link(b)

    assert instance == a.instance

    # A hard death: the operating system gives the lock back as the VM goes.
    kill(vm, "-KILL")
    assert {:ok, :gone} = await(fn -> if alive?(vm), do: :alive, else: {:ok, :gone} end)
    start(b)
    assert record(b) =~ "os_pid #{System.pid()}\n"
  end

  # Two starts at the same instant on a home no tree has started on: one takes the home, and the
  # other is refused by the lock before it opens the home's database (F-214's new-2).
  test "two starts at once on a new home give one tree and one refusal", ctx do
    for n <- 1..25 do
      home = Path.join(ctx.dir, "race-#{n}")

      tasks =
        for c <- [config(home), config(home)] do
          Task.async(fn ->
            receive do
              :go ->
                with {:ok, sup} <- CodingAgentFramework.start_link(c) do
                  Process.unlink(sup)
                  {:ok, sup}
                end
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))

      case Task.await_many(tasks, 10_000) do
        [{:ok, sup}, {:refused, {:home_held, _}}] -> stop(sup)
        [{:refused, {:home_held, _}}, {:ok, sup}] -> stop(sup)
        other -> flunk("one tree and one refusal on #{home}, got #{inspect(other)}")
      end
    end
  end
end
