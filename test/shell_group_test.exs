defmodule CodingAgentFramework.ShellGroupTest do
  # What a command leaves when it ends by a timeout, by its owner's death or by the VM's
  # (model/tla/Shell.tla). The stand-in is an sh with a child in its group and a process held by
  # dtach -n. Each writes its pid to a file, and every stand-in sleeps 60 s, so one a failed run
  # leaves ends on its own.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Shell
  alias CodingAgentFramework.Shell.Reaper

  @stand_in ~S"""
  d=$0; sleep=$1; dtach=$2; sh=$3
  "$sleep" 60 & echo $! > "$d/child"
  "$dtach" -n "$d/h.sock" -E -z "$sh" -c 'echo $$ > "$0/held"; exec "$1" 60' "$d" "$sleep"
  echo $$ > "$d/sh"
  wait
  """

  defp args(dir), do: ["-c", @stand_in, dir, program!(:sleep), program!(:dtach), program!(:sh)]

  # The pids of the stand-in's sh, its child and its held process, once all three are written.
  defp pids(dir) do
    for name <- ["sh", "child", "held"], into: %{} do
      {:ok, text} = await(fn -> pid_file(Path.join(dir, name)) end)
      {name, text}
    end
  end

  defp pid_file(path) do
    case File.read(path) do
      {:ok, text} -> if String.ends_with?(text, "\n"), do: {:ok, String.trim(text)}, else: :short
      other -> other
    end
  end

  defp gone(pid), do: await(fn -> if alive?(pid), do: :alive, else: {:ok, :gone} end)

  defp reaper do
    start_supervised!({Reaper, programs: programs()})
  end

  defp held(reaper) do
    await(fn -> if Reaper.held(reaper) == %{}, do: :none, else: {:ok, :held} end)
  end

  # The group is gone; the held process lives, and is then ended here, by its pid.
  defp assert_group_ended(pids) do
    assert {:ok, :gone} = gone(pids["sh"])
    assert {:ok, :gone} = gone(pids["child"])
    assert alive?(pids["held"])
    kill(pids["held"])
    assert {:ok, :gone} = gone(pids["held"])
  end

  test "a timeout ends the command's group, its child included, and not a held process" do
    dir = test_dir()

    assert {:unknown, {:timeout, 2_000}} =
             Shell.run(host(), program!(:sh), args(dir), timeout: 2_000)

    assert_group_ended(pids(dir))
  end

  test "with a reaper, the owner's death ends the command's group, and not a held process" do
    dir = test_dir()
    reaper = reaper()

    owner =
      spawn(fn ->
        Shell.run(host(), program!(:sh), args(dir), timeout: 30_000, reaper: reaper)
      end)

    pids = pids(dir)
    assert {:ok, :held} = held(reaper)
    Process.exit(owner, :kill)
    assert_group_ended(pids)
    # It drops the group once its KILL, half a second after the TERM, is sent.
    assert {:ok, :dropped} =
             await(fn -> if Reaper.held(reaper) == %{}, do: {:ok, :dropped}, else: :held end)
  end

  test "without a reaper, the owner's death leaves the command running" do
    dir = test_dir()
    owner = spawn(fn -> Shell.run(host(), program!(:sh), args(dir), timeout: 30_000) end)
    pids = pids(dir)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert alive?(pids["sh"])
    # This test started the group: it ends it by its id.
    Shell.signal(program!(:kill), "KILL", pids["sh"])
    assert_group_ended(pids)
  end

  test "the reaper drops a command that ended, and a timed-out one" do
    reaper = reaper()

    assert {:ok, %{status: 0}} =
             Shell.run(host(), program!(true), [], timeout: 5_000, reaper: reaper)

    assert {:unknown, {:timeout, 100}} =
             Shell.run(host(), program!(:sleep), ["60"], timeout: 100, reaper: reaper)

    assert Reaper.held(reaper) == %{}
  end

  # A VM boots slowly on a loaded machine: its wait is bounded at 45 s, not :peer's 15.
  @tag timeout: 90_000
  test "with a reaper, the VM's death ends the command's group, and not a held process" do
    dir = test_dir()
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, _node} =
      :peer.start(%{connection: :standard_io, args: paths, wait_boot: 45_000})

    vm = :peer.call(peer, :os, :getpid, [], 10_000)
    announce = Path.join(dir, "reaped")

    :peer.cast(peer, CodingAgentFramework.TestHost, :run_reaped, [
      program!(:sh),
      args(dir),
      30_000,
      announce
    ])

    pids = pids(dir)
    assert {:ok, _} = read_when(announce, "held\n")
    # A hard death, with no cleanup in the VM: the watcher's stdin closes as the VM's pipe does.
    kill(vm, "-KILL")
    assert_group_ended(pids)
    catch_exit(:peer.stop(peer))
  end

  test "a status and output pass unchanged, a signal's included" do
    assert {:ok, %{status: 137, output: "out\n"}} =
             Shell.run(host(), program!(:sh), ["-c", "echo out; kill -KILL $$"], timeout: 5_000)

    assert {:ok, %{status: 0, output: ""}} = Shell.run(host(), program!(true), [], timeout: 5_000)
  end
end
