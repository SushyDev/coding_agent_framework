defmodule CodingAgentFramework.StandInTest do
  @moduledoc """
  The stand-ins' own bounds and how a test ends them (F-66): a stand-in ends by itself after its
  idle seconds, and `TestHost.end_recorded/2` ends what one recorded, stopped or not, and only
  that.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{ClaudeStandIn, HeadlessStandIn}

  doctest CodingAgentFramework.TestHost

  test "ending the stand-ins of a test that started none answers :ok" do
    dir = test_dir()

    assert :ok = ClaudeStandIn.kill_all(dir)
    assert :ok = HeadlessStandIn.kill_all(dir)
  end

  test "a stand-in with no input ends by itself after its idle seconds" do
    dir = test_dir()
    on_exit(fn -> end_recorded(dir) end)

    # Its input stays open the whole time, as a dtach pty's does; only the bound ends it.
    for path <- [ClaudeStandIn.write!(dir, :never, 1), HeadlessStandIn.write!(dir, :never, 1)] do
      assert {:ok, %{status: _}} = run(dir, [path], 10_000)
    end

    assert length(File.ls!(Path.join(dir, "pids"))) == 2
  end

  test "end_recorded ends a stopped stand-in, and one that starts after it records nothing" do
    dir = test_dir()
    on_exit(fn -> end_recorded(dir) end)
    path = HeadlessStandIn.write!(dir)
    # Written before the end, as a start that runs late found it.
    late = ClaudeStandIn.write!(dir, :never)
    sock = Path.join(dir, "h.sock")
    assert {:ok, %{status: 0}} = run(dir, [program!(:dtach), "-n", sock, "-E", "-z", path], 5_000)
    pids = Path.join(dir, "pids")
    assert {:ok, [name]} = await(fn -> if (ls = File.ls!(pids)) != [], do: {:ok, ls} end)
    pid = String.to_integer(name)
    assert {:ok, %{status: 0}} = kill(pid, "-STOP")

    assert end_recorded(dir) == [pid]
    refute alive?(pid)
    refute File.exists?(pids)

    # Its pids directory is gone, so a late start cannot record and exits at once, well before
    # the run's deadline: one that read its input would wait its idle seconds.
    assert {:ok, %{status: 0}} = run(dir, [late], 5_000)
    assert end_recorded(dir) == []
  end

  test "end_recorded leaves a recorded pid whose command line does not name the directory" do
    dir = test_dir()
    File.mkdir_p!(Path.join(dir, "pids"))
    other = Port.open({:spawn_executable, program!(:sleep)}, args: ["30"])
    {:os_pid, pid} = Port.info(other, :os_pid)
    on_exit(fn -> kill(pid) end)
    File.write!(Path.join([dir, "pids", "#{pid}"]), "")

    assert end_recorded(dir) == []
    assert alive?(pid)
  end

  # Runs `argv` with the stand-ins' one variable, through `env` as `Holder` does.
  defp run(dir, argv, timeout) do
    args = ["CLAUDE_CONFIG_DIR=#{dir}" | argv]
    CodingAgentFramework.Shell.run(host(), program!(:env), args, timeout: timeout)
  end
end
