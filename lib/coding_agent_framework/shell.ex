defmodule CodingAgentFramework.Shell do
  @moduledoc """
  The only module that starts programs, on this machine or over ssh.

  A program is named by its absolute path (see `CodingAgentFramework.Programs`), so no
  lookup runs through a `PATH`. Each run has a timeout; when it passes, the program is killed by
  its pid and the outcome is unknown. A non-zero exit is not a refusal here: the caller reads the
  status, since only it knows what the program's exit means.

      host = CodingAgentFramework.Host.local("laptop")
      CodingAgentFramework.Shell.run(host, "/bin/echo", ["hi"], timeout: 5_000)
      #=> {:ok, %{status: 0, output: "hi\\n"}}

  Outcomes:

    * `{:ok, %{status: status, output: output}}`: the program ran and exited; stderr is merged
      into `output`;
    * `{:refused, reason}`: nothing ran (`{:not_absolute, path}`, `{:cannot_start, path,
      reason}`, `{:unset_prefix_over_ssh, prefixes}`);
    * `{:unknown, {:timeout, ms}}`: the program did not exit in time and was killed.
  """

  alias CodingAgentFramework.Host

  @type result :: %{status: non_neg_integer, output: binary}
  @type outcome :: {:ok, result} | {:refused, term} | {:unknown, term}

  # ssh hands the remote login shell one string; a remote `env` sets and unsets variables there.
  @remote_env "/usr/bin/env"

  @doc """
  Runs `path` with `args` on `host`.

  Options:

    * `:timeout` (required): milliseconds before the program is killed;
    * `:env`: `[{name, value}]` to set;
    * `:unset`: names to remove from the environment;
    * `:unset_prefixes`: remove every variable whose name starts with one of these. It is read
      from this VM's environment, so it is refused over ssh.
  """
  @spec run(Host.t(), String.t(), [String.t()], keyword) :: outcome
  def run(%Host{} = host, path, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    case command(host, path, args, opts) do
      {:ok, {exe, argv, env}} -> spawn_and_wait(exe, argv, env, timeout)
      refused -> refused
    end
  end

  @doc """
  The executable, its arguments and the port environment that `run/4` would use. Pure.

      iex> host = CodingAgentFramework.Host.ssh("box", "/usr/bin/ssh", "box")
      iex> CodingAgentFramework.Shell.command(host, "/bin/echo", ["it's"], [])
      {:ok, {"/usr/bin/ssh", ["-o", "BatchMode=yes", "--", "box", "'/bin/echo' 'it'\\\\''s'"], []}}
  """
  @spec command(Host.t(), String.t(), [String.t()], keyword) ::
          {:ok, {String.t(), [String.t()], list}} | {:refused, term}
  def command(%Host{reach: reach}, path, args, opts) do
    env = Keyword.get(opts, :env, [])
    unset = Keyword.get(opts, :unset, [])
    prefixes = Keyword.get(opts, :unset_prefixes, [])

    cond do
      Path.type(path) != :absolute ->
        {:refused, {:not_absolute, path}}

      reach == :local ->
        {:ok, {path, args, port_env(env, unset ++ names_with_prefixes(prefixes))}}

      prefixes != [] ->
        {:refused, {:unset_prefix_over_ssh, prefixes}}

      true ->
        {:ssh, ssh, destination} = reach
        argv = ["-o", "BatchMode=yes", "--", destination, remote(path, args, env, unset)]
        {:ok, {ssh, argv, []}}
    end
  end

  @doc """
  Quotes one word for a POSIX shell.

      iex> CodingAgentFramework.Shell.shell_quote("a b'c")
      "'a b'\\\\''c'"
  """
  @spec shell_quote(String.t()) :: String.t()
  def shell_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  defp remote(path, args, [], []), do: Enum.map_join([path | args], " ", &shell_quote/1)

  defp remote(path, args, env, unset) do
    words =
      [@remote_env] ++
        Enum.flat_map(unset, &["-u", &1]) ++
        Enum.map(env, fn {k, v} -> "#{k}=#{v}" end) ++ [path | args]

    Enum.map_join(words, " ", &shell_quote/1)
  end

  defp names_with_prefixes([]), do: []

  defp names_with_prefixes(prefixes) do
    for {name, _} <- System.get_env(), String.starts_with?(name, prefixes), do: name
  end

  defp port_env(env, unset) do
    Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end) ++
      Enum.map(unset, &{to_charlist(&1), false})
  end

  defp spawn_and_wait(exe, argv, env, timeout) do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: argv,
        env: env
      ])

    # A program that has already exited has closed its port, and the port has no pid left; its
    # output and exit status are in the mailbox all the same.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, os_pid, deadline, timeout, [])
  rescue
    e in ErlangError -> {:refused, {:cannot_start, exe, e.original}}
  end

  defp collect(port, os_pid, deadline, timeout, acc) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, deadline, timeout, [acc | data])

      {^port, {:exit_status, status}} ->
        {:ok, %{status: status, output: IO.iodata_to_binary(acc)}}
    after
      left ->
        # The program was started here, so it is killed by its own pid, never by a pattern.
        if os_pid,
          do:
            System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

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
