defmodule CodingAgentFramework.Shell do
  @moduledoc """
  The only module that starts programs, on this machine or over ssh.

  A program is named by its absolute path (see `CodingAgentFramework.Programs`), so no
  lookup runs through a `PATH`. A non-zero exit is not a refusal here: the caller reads the
  status, since only it knows what the program's exit means.

  Each program runs in a process group of its own, under the host's `sh` (see
  `CodingAgentFramework.Host` and `model/tla/Shell.tla`). OTP starts every port program with
  `setsid`, so that `sh` leads a new group. It starts a watcher in the group that blocks reading
  the port's stdin, then runs the program in the group. When the port closes (the timeout
  passed, the caller died or the VM died), the watcher reads end of file and ends the whole
  group, the program's children included: TERM, half a second's grace (the host's `sleep`), then
  KILL. A process held by `dtach -n` has left the group by `setsid` and is never reached. When
  the program exits on its own, the `sh` kills the watcher and exits with the program's status;
  children the program leaves behind keep running. Every kill names the group by the `sh`'s pid,
  `-$$`, while a member of the group lives, so it never reaches a reused pid.

  `Shell` sets no environment. A caller that needs one runs the host's `env` program, so the
  command is the same on this machine and over ssh (see `CodingAgentFramework.Holder.hold/4`).

      host = CodingAgentFramework.Host.local("laptop", "/run/bin/sh", "/run/bin/sleep")
      CodingAgentFramework.Shell.run(host, "/run/bin/echo", ["hi"], timeout: 5_000)
      #=> {:ok, %{status: 0, output: "hi\\n"}}

  Outcomes:

    * `{:ok, %{status: status, output: output}}`: the program ran and exited; stderr is merged
      into `output`;
    * `{:refused, reason}`: nothing ran (`{:not_absolute, path}`, `{:cannot_start, path,
      reason}`);
    * `{:unknown, {:timeout, ms}}`: the program did not exit in time; its group is being ended.
  """

  alias CodingAgentFramework.Host

  # $1 is sleep, then the program and its arguments. Both the watcher and the program are
  # asynchronous lists, which without job control start on /dev/null before their own
  # redirections, so each gets the port's stdin back from fd 4. The program is waited for rather
  # than run in the foreground, since dash prints a foreground command's signal on stdout. The
  # sh's own messages go to /dev/null, the program's stderr to the port through fd 3, so the
  # output is the program's alone. A missing program is reported with a NUL-led line, as
  # nothing else ran.
  @wrapper ~S"""
  g=$1; shift
  [ -f "$1" ] && [ -x "$1" ] || { [ -e "$1" ] && r=eacces || r=enoent; printf '\000%s\n' "$r"; exit 127; }
  exec 3>&2 2>/dev/null 4<&0
  { trap '' TERM; while read -r _; do :; done; kill -s TERM -- "-$$"; "$g" 0.5; kill -s KILL -- "-$$"; } <&4 >/dev/null 3>&- 4<&- &
  w=$!
  "$@" <&4 2>&3 3>&- 4<&- &
  wait "$!"; s=$?
  kill -s KILL "$w"
  exit "$s"
  """

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

      iex> host = CodingAgentFramework.Host.ssh("box", "/run/bin/ssh", "box", "/run/bin/sh", "/run/bin/sleep")
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

  @doc """
  The arguments the host's `sh` runs `exe` and `argv` with: the wrapper, then the host's
  `sleep`. Pure.

      iex> host = CodingAgentFramework.Host.local("laptop", "/run/bin/sh", "/run/bin/sleep")
      iex> ["-c", _wrapper, "shell", "/run/bin/sleep", "/run/bin/echo", "hi"] =
      ...>   CodingAgentFramework.Shell.wrapped(host, "/run/bin/echo", ["hi"])
  """
  @spec wrapped(Host.t(), String.t(), [String.t()]) :: [String.t()]
  def wrapped(%Host{sleep: sleep}, exe, argv), do: ["-c", @wrapper, "shell", sleep, exe | argv]

  defp spawn_and_wait(host, exe, argv, timeout) do
    port =
      Port.open({:spawn_executable, host.sh}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: wrapped(host, exe, argv)
      ])

    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, exe, deadline, timeout, [])
  rescue
    e in ErlangError -> {:refused, {:cannot_start, host.sh, e.original}}
  end

  defp collect(port, exe, deadline, timeout, acc) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, exe, deadline, timeout, [acc | data])

      {^port, {:exit_status, status}} ->
        case {status, IO.iodata_to_binary(acc)} do
          {127, <<0, "enoent\n">>} ->
            {:refused, {:cannot_start, exe, :enoent}}

          {127, <<0, "eacces\n">>} ->
            {:refused, {:cannot_start, exe, :eacces}}

          {status, output} ->
            {:ok, %{status: status, output: output}}
        end
    after
      left ->
        # Closing the port closes the wrapper's stdin, and its watcher ends the group. No message
        # of a closed port reaches the caller after this, beyond those already in its mailbox.
        close(port)
        {:unknown, {:timeout, timeout}}
    end
  end

  defp close(port) do
    Port.close(port)
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
