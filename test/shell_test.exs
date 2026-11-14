defmodule CodingAgentFramework.ShellTest do
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Host, Programs, Shell}

  doctest Shell
  doctest Host
  doctest Programs

  test "a program's status and output come back, a non-zero exit included" do
    assert {:ok, %{status: 0, output: "a b\n"}} =
             Shell.run(host(), "/bin/echo", ["a b"], timeout: 5_000)

    assert {:ok, %{status: 3, output: "err\n"}} =
             Shell.run(host(), "/bin/sh", ["-c", "echo err >&2; exit 3"], timeout: 5_000)
  end

  test "nothing runs from a relative path or a missing one" do
    assert {:refused, {:not_absolute, "echo"}} = Shell.run(host(), "echo", [], timeout: 5_000)

    assert {:refused, {:cannot_start, "/nonexistent/x", _}} =
             Shell.run(host(), "/nonexistent/x", [], timeout: 5_000)
  end

  test "a program past its timeout is killed and its outcome is unknown" do
    pidfile = Path.join(test_dir(), "pid")
    script = ~S(echo $$ > "$0"; exec /bin/cat)

    assert {:unknown, {:timeout, 300}} =
             Shell.run(host(), "/bin/sh", ["-c", script, pidfile], timeout: 300)

    {:ok, pid} = File.read(pidfile)

    assert {:ok, :gone} =
             await(fn -> if alive?(String.trim(pid)), do: :alive, else: {:ok, :gone} end)
  end

  test "the environment is set and unset per run" do
    script = ~S(echo "${A-none} ${TMUX-none}")
    opts = [timeout: 5_000, env: [{"A", "1"}, {"TMUX", "x"}]]
    assert {:ok, %{output: "1 x\n"}} = Shell.run(host(), "/bin/sh", ["-c", script], opts)

    assert {:ok, {"/bin/sh", _, env}} =
             Shell.command(host(), "/bin/sh", [], unset: ["TMUX"], unset_prefixes: ["PATH"])

    assert {~c"TMUX", false} in env
    assert {~c"PATH", false} in env
  end

  test "over ssh, every word is quoted for the remote shell" do
    box = Host.ssh("box", "/usr/bin/ssh", "agent@box")

    assert {:ok, {"/usr/bin/ssh", ["-o", "BatchMode=yes", "--", "agent@box", remote], []}} =
             Shell.command(box, "/bin/x", ["a;b", "$HOME"], env: [{"K", "v w"}], unset: ["TMUX"])

    assert remote == "'/usr/bin/env' '-u' 'TMUX' 'K=v w' '/bin/x' 'a;b' '$HOME'"

    assert {:refused, {:unset_prefix_over_ssh, ["CLAUDE_CODE_"]}} =
             Shell.command(box, "/bin/x", [], unset_prefixes: ["CLAUDE_CODE_"])
  end

  test "programs are found as absolute paths by the host's shell" do
    assert {:ok, programs} = Programs.find(host(), [:tmux, :dtach])
    assert {:ok, "/" <> _} = Programs.fetch(programs, :tmux)
    assert {:refused, {:unknown_names, [:vim]}} = Programs.find(host(), [:tmux, :vim])
    assert {:refused, {:bad_paths, %{tmux: "tmux"}}} = Programs.new(host(), %{tmux: "tmux"})
  end
end
