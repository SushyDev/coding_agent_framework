defmodule CodingAgentFramework.ShellMuonTrapTest do
  @moduledoc """
  The evaluation of MuonTrap for `Shell` (F-32), on this machine's real processes and a real
  dtach socket. MuonTrap ends the program it starts when its owner dies, which a plain port does
  not; without cgroups (always on macOS) it ends nothing that program started. These tests keep
  that measured, so a MuonTrap release that changes it shows here.

  Each stand-in writes its own pids to a file, the test waits on that file, and every pid it
  started is killed by pid when the test ends.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Holder

  test "MuonTrap ends its program when its owner dies; a plain port leaves it running" do
    script = fn file -> announce(file, "$$") <> "exec #{program!(:sleep)} 60" end

    {[sh], _} = owned(fn file -> MuonTrap.cmd(program!(:sh), ["-c", script.(file)]) end)
    assert {:ok, :gone} = await(fn -> gone(sh) end)

    me = self()

    {[sh], _} =
      owned(fn file ->
        port = Port.open({:spawn_executable, program!(:sh)}, args: ["-c", script.(file)])
        send(me, {:port, port})
        receive do: (:never -> :ok)
      end)

    on_exit(fn -> kill(sh, "-KILL") end)
    assert_receive {:port, port}
    # The owner is dead and its port closed; nothing has signaled the program.
    assert {:ok, :closed} = await(fn -> if Port.info(port), do: :open, else: {:ok, :closed} end)
    assert alive?(sh)
  end

  test "without cgroups, a program's own child outlives MuonTrap's timeout and its owner" do
    script = fn file ->
      "#{program!(:sleep)} 60 & " <> announce(file, "$$ $!") <> "wait"
    end

    # A timeout: MuonTrap ends sh, the program it started, and nothing below it.
    file = pids_file()

    assert {"", :timeout} =
             MuonTrap.cmd(program!(:sh), ["-c", script.(file)], timeout: 2_000)

    [sh, child] = read_pids!(file)
    on_exit(fn -> kill(child, "-KILL") end)
    assert {:ok, :gone} = await(fn -> gone(sh) end)
    assert alive?(child)

    # Its owner killed: the same.
    {[sh, child], _} = owned(fn file -> MuonTrap.cmd(program!(:sh), ["-c", script.(file)]) end)
    on_exit(fn -> kill(child, "-KILL") end)
    assert {:ok, :gone} = await(fn -> gone(sh) end)
    assert alive?(child)
  end

  test "a held process started through MuonTrap outlives the run and its owner" do
    dir = test_dir()
    {:ok, h} = Holder.new(programs(), dir)
    file = Path.join(dir, "held.pids")
    held = ["-c", announce(file, "$$ $PPID") <> "exec #{program!(:cat)}"]
    {:ok, [env | args]} = Holder.hold_argv(h, "alpha", [program!(:sh) | held], [])

    owner = self()
    {pid, ref} = spawn_monitor(fn -> send(owner, {:ran, MuonTrap.cmd(env, args)}) end)
    assert_receive {:ran, {"", 0}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    [child, master] = read_pids!(file)
    on_exit(fn -> if Holder.state(h, "alpha") == {:ok, :live}, do: kill(child) end)
    assert {:ok, :live} = Holder.state(h, "alpha")
    assert alive?(child) and alive?(master)
  end

  # Runs `run.(file)` in a process of its own, waits for the pids the stand-in writes to `file`,
  # then kills that process. A caller kills by pid only what it shows alive.
  defp owned(run) do
    file = pids_file()
    {owner, ref} = spawn_monitor(fn -> run.(file) end)
    pids = read_pids!(file)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    {pids, owner}
  end

  defp pids_file, do: Path.join(test_dir(), "stand-in.pids")

  defp announce(file, words) do
    ~s(echo "#{words}" > "#{file}.tmp" && #{program!(:mv)} "#{file}.tmp" "#{file}"; )
  end

  defp read_pids!(file) do
    assert {:ok, text} = await(fn -> File.read(file) end)
    String.split(text)
  end

  defp gone(pid), do: if(alive?(pid), do: :alive, else: {:ok, :gone})
end
