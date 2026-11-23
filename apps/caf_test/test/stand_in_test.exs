defmodule CodingAgentFramework.StandInTest do
  @moduledoc """
  The stand-ins' own bounds and how a test ends them (F-66): a stand-in ends by itself after its
  idle seconds, and `TestHost.end_recorded/2` ends what one recorded, stopped or not, and only
  that.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{ClaudeStandIn, HeadlessStandIn, WaiterStandIn}

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

  # F-218: the waiter stand-in's wait for the hook has the test's own 5 s bound. A hook that
  # never exits is ended with its group, the task answers `{:timeout, 5_000}`, and nothing is
  # written to the transcript.
  test "a waiter hook that never exits is ended with its group after 5 s" do
    dir = test_dir()
    {hook, child} = {Path.join(dir, "hook.pid"), Path.join(dir, "child.pid")}

    on_exit(fn ->
      for file <- [hook, child],
          {:ok, pid} <- [File.read(file)],
          do: kill(String.trim(pid), "-KILL")
    end)

    # The hook is a shell with a child of its own in its group, waiting on it for ever.
    command =
      ~s(echo $$ > '#{hook}'; '#{program!(:sleep)}' 600 & echo $! > '#{child}'; wait)

    settings = Path.join(dir, "settings.json")
    hooks = [%{"hooks" => [%{"type" => "command", "command" => command, "asyncRewake" => true}]}]
    File.write!(settings, JSON.encode!(%{"hooks" => %{"Stop" => hooks}}))
    transcript = Path.join(dir, "transcript.jsonl")

    from = System.monotonic_time(:millisecond)
    task = WaiterStandIn.turn_end(settings, "s1", transcript, :idle)
    assert {:timeout, 5_000} = Task.await(task, 15_000)
    waited = System.monotonic_time(:millisecond) - from

    # No sooner than its bound, and within 3 s after it: the KILL and the exit's wait.
    assert waited in 5_000..(5_000 + 3_000)
    refute File.exists?(transcript)

    for file <- [hook, child] do
      pid = file |> File.read!() |> String.trim()
      assert {:ok, :ended} = await(fn -> if not alive?(pid), do: {:ok, :ended} end)
    end
  end

  # Runs `argv` with the stand-ins' one variable, through `env` as `Holder` does.
  defp run(dir, argv, timeout) do
    args = ["CLAUDE_CONFIG_DIR=#{dir}" | argv]
    CodingAgentFramework.Shell.run(host(), program!(:env), args, timeout: timeout)
  end
end
