defmodule CodingAgentFramework.ShellTest do
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Host, Programs, Shell}

  doctest Shell
  doctest Host
  doctest Programs

  test "a program's status and output come back, a non-zero exit included" do
    assert {:ok, %{status: 0, output: "a b\n"}} =
             Shell.run(host(), program!(:echo), ["a b"], timeout: 5_000)

    assert {:ok, %{status: 3, output: "err\n"}} =
             Shell.run(host(), program!(:sh), ["-c", "echo err >&2; exit 3"], timeout: 5_000)
  end

  test "nothing runs from a relative path or a missing one" do
    assert {:refused, {:not_absolute, "echo"}} = Shell.run(host(), "echo", [], timeout: 5_000)

    assert {:refused, {:cannot_start, "/nonexistent/x", _}} =
             Shell.run(host(), "/nonexistent/x", [], timeout: 5_000)
  end

  test "a program past its timeout is killed and its outcome is unknown" do
    pidfile = Path.join(test_dir(), "pid")
    script = ~s(echo $$ > "$0"; exec #{program!(:cat)})

    assert {:unknown, {:timeout, 300}} =
             Shell.run(host(), program!(:sh), ["-c", script, pidfile], timeout: 300)

    {:ok, pid} = File.read(pidfile)

    assert {:ok, :gone} =
             await(fn -> if alive?(String.trim(pid)), do: :alive, else: {:ok, :gone} end)
  end

  test "on this machine a program runs as given; over ssh every word is quoted" do
    assert {:ok, {"/run/x", ["a;b"]}} = Shell.command(host(), "/run/x", ["a;b"])
    box = Host.ssh("box", "/run/bin/ssh", "agent@box", program!(:kill))

    assert {:ok, {"/run/bin/ssh", ["-o", "BatchMode=yes", "--", "agent@box", remote]}} =
             Shell.command(box, "/run/x", ["a;b", "$HOME", "K=v w"])

    assert remote == "'/run/x' 'a;b' '$HOME' 'K=v w'"
  end

  test "programs are found as absolute paths by the host's shell" do
    assert {:ok, programs} = Programs.find(host(), [:tmux, :dtach])
    assert {:ok, "/" <> _} = Programs.fetch(programs, :tmux)
    assert {:refused, {:unknown_names, [:vim]}} = Programs.find(host(), [:tmux, :vim])
    assert {:refused, {:bad_paths, %{tmux: "tmux"}}} = Programs.new(host(), %{tmux: "tmux"})
  end
end
