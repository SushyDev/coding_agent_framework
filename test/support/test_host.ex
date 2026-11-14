defmodule CodingAgentFramework.TestHost do
  @moduledoc """
  Test aids for the host layer: this VM's own directory, the programs from devenv, and a
  bounded wait on an announced event.
  """

  alias CodingAgentFramework.{Host, Programs, Shell}

  @doc "This VM's own directory, named with its OS pid. `test_helper.exs` makes and removes it."
  def vm_dir, do: Path.join(System.tmp_dir!(), "caf-#{System.pid()}")

  @doc "A new directory of the calling test's own, inside `vm_dir/0`."
  def test_dir do
    dir = Path.join(vm_dir(), "t#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  @doc "The local host tests run on."
  def host, do: Host.local("test")

  @doc "The path of one program from devenv, or a failure that says to run inside devenv."
  def program!(name) do
    with {:ok, programs} <- Programs.find(host(), [name]),
         {:ok, path} <- Programs.fetch(programs, name) do
      path
    else
      other -> raise "#{name} not found (#{inspect(other)}); run: devenv shell -- mix test"
    end
  end

  @doc """
  Calls `check` until it returns `{:ok, value}` or `timeout` ms pass. The event is what `check`
  reads (a file a stand-in writes, a process gone); the pause between reads only spaces them.
  """
  def await(check, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await(check, deadline, nil)
  end

  defp await(check, deadline, last) do
    case check.() do
      {:ok, value} ->
        {:ok, value}

      other ->
        if System.monotonic_time(:millisecond) > deadline do
          {:timeout, other || last}
        else
          receive do
          after
            20 -> await(check, deadline, other)
          end
        end
    end
  end

  @doc "Reads a file a stand-in writes, once it has `expected`'s length."
  def read_when(path, expected) do
    await(fn ->
      case File.read(path) do
        {:ok, text} when byte_size(text) >= byte_size(expected) -> {:ok, text}
        other -> other
      end
    end)
  end

  @doc "Ends a process this test started, by its pid; one already gone is fine."
  def kill(pid, signal \\ "-TERM") do
    Shell.run(host(), "/bin/kill", [signal, to_string(pid)], timeout: 5_000)
  end

  @doc "Whether a process lives, by its pid (`kill -0`)."
  def alive?(pid) do
    match?({:ok, %{status: 0}}, kill(pid, "-0"))
  end
end
