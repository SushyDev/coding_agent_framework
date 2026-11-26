defmodule CodingAgentFramework.ProgramsBuiltinTest do
  # Sets the VM's PATH, so it runs alone (sync modules run after the async ones).
  use ExUnit.Case, async: false

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Programs

  setup do
    old = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", old) end)
  end

  test "a program that is also a shell builtin is found as a file on the PATH" do
    # Only the directories that hold kill and sleep as files: /bin on macOS, and on NixOS a
    # directory such as /run/current-system/sw/bin, since it has no /bin/kill or /usr/bin/sleep.
    dirs = Enum.map(["kill", "sleep"], &Path.dirname(System.find_executable(&1)))
    System.put_env("PATH", dirs |> Enum.uniq() |> Enum.join(":"))

    assert {:ok, programs} = Programs.find(host(), [:kill, :sleep])

    for name <- [:kill, :sleep] do
      assert {:ok, "/" <> _ = path} = Programs.fetch(programs, name)
      assert File.regular?(path)
    end
  end

  test "a builtin with no file on the PATH is refused" do
    dir = Path.join(System.tmp_dir!(), "caf-no-kill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    System.put_env("PATH", dir)

    assert {:refused, {:not_found, [:kill]}} = Programs.find(host(), [:kill])
  end
end
