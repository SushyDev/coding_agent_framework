defmodule CodingAgentFramework.Shell do
  @moduledoc """
  The only module that starts programs, on this machine or over ssh.

  A program is named by its absolute path (see `CodingAgentFramework.Programs`), so no
  lookup runs through a `PATH`. Each run has a timeout; when it passes, the program is killed by
  its pid with the host's `kill` (see `CodingAgentFramework.Host`) and the outcome is unknown. A
  non-zero exit is not a refusal here: the caller reads the status, since only it knows what the
  program's exit means.

  `Shell` sets no environment. A caller that needs one runs the host's `env` program, so the
  command is the same on this machine and over ssh (see `CodingAgentFramework.Holder.hold/4`).

      host = CodingAgentFramework.Host.local("laptop", "/run/bin/kill")
      CodingAgentFramework.Shell.run(host, "/run/bin/echo", ["hi"], timeout: 5_000)
      #=> {:ok, %{status: 0, output: "hi\\n"}}

  Outcomes:

    * `{:ok, %{status: status, output: output}}`: the program ran and exited; stderr is merged
      into `output`;
    * `{:refused, reason}`: nothing ran (`{:not_absolute, path}`, `{:cannot_start, path,
      reason}`);
    * `{:unknown, {:timeout, ms}}`: the program did not exit in time and was killed.
  """

  alias CodingAgentFramework.Host

  @type result :: %{status: non_neg_integer, output: binary}
  @type outcome :: {:ok, result} | {:refused, term} | {:unknown, term}

  @doc """
  Runs `path` with `args` on `host`. Options: `:timeout` (required), milliseconds before the
  program is killed.
  """
  @spec run(Host.t(), String.t(), [String.t()], keyword) :: outcome
  def run(%Host{} = host, path, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    case command(host, path, args) do
      {:ok, {exe, argv}} -> spawn_and_wait(host, exe, argv, timeout)
      refused -> refused
    end
  end

  @doc """
  The executable and its arguments that `run/4` would use. Pure. Over ssh, every word is quoted
  for the remote shell.

      iex> host = CodingAgentFramework.Host.ssh("box", "/run/bin/ssh", "box", "/run/bin/kill")
      iex> CodingAgentFramework.Shell.command(host, "/run/bin/echo", ["it's"])
      {:ok, {"/run/bin/ssh", ["-o", "BatchMode=yes", "--", "box", "'/run/bin/echo' 'it'\\\\''s'"]}}
  """
  @spec command(Host.t(), String.t(), [String.t()]) ::
          {:ok, {String.t(), [String.t()]}} | {:refused, term}
  def command(%Host{reach: reach}, path, args) do
    cond do
      Path.type(path) != :absolute ->
        {:refused, {:not_absolute, path}}

      reach == :local ->
        {:ok, {path, args}}

      true ->
        {:ssh, ssh, destination} = reach
        remote = Enum.map_join([path | args], " ", &shell_quote/1)
        {:ok, {ssh, ["-o", "BatchMode=yes", "--", destination, remote]}}
    end
  end

  @doc """
  Quotes one word for a POSIX shell.

      iex> CodingAgentFramework.Shell.shell_quote("a b'c")
      "'a b'\\\\''c'"
  """
  @spec shell_quote(String.t()) :: String.t()
  def shell_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  defp spawn_and_wait(host, exe, argv, timeout) do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: argv
      ])

    # A program that has already exited has closed its port, and the port has no pid left; its
    # output and exit status are in the mailbox all the same.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    deadline = System.monotonic_time(:millisecond) + timeout
    collect(host, port, os_pid, deadline, timeout, [])
  rescue
    e in ErlangError -> {:refused, {:cannot_start, exe, e.original}}
  end

  defp collect(host, port, os_pid, deadline, timeout, acc) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(host, port, os_pid, deadline, timeout, [acc | data])

      {^port, {:exit_status, status}} ->
        {:ok, %{status: status, output: IO.iodata_to_binary(acc)}}
    after
      left ->
        # The program was started here, so it is killed by its own pid, never by a pattern.
        if os_pid,
          do: System.cmd(host.kill, ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

        close(port)
        {:unknown, {:timeout, timeout}}
    end
  end

  # A killed program's exit status could arrive after a `Port.close/1`, in the caller's mailbox,
  # which a GenServer does not expect. So the status of the program just killed is awaited, for
  # a bounded time, and the port is closed only when it does not come.
  defp close(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      1_000 -> Port.close(port)
    end

    drain(port)
  catch
    :error, :badarg -> drain(port)
  end

  defp drain(port) do
    receive do
      {^port, _} -> drain(port)
    after
      0 -> :ok
    end
  end
end
