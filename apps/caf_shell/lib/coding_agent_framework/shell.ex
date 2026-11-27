defmodule CodingAgentFramework.Shell do
  @moduledoc """
  The only module that starts programs, on this machine or over ssh.

  A program is named by its absolute path (see `CodingAgentFramework.Programs`), so no
  lookup runs through a `PATH`. A non-zero exit is not a refusal here: the caller reads the
  status, since only it knows what the program's exit means.

  Each program leads a process group of its own: OTP starts every port program with `setsid`,
  so the group's id is the program's pid (see `model/tla/Shell.tla`). When the timeout passes,
  `Shell` sends TERM to the group with the host's `kill` (see `CodingAgentFramework.Host`),
  waits half a second for the program's exit, and sends KILL to the group only if the exit did
  not come. The kills reach the program's children in its group, and never a process held by
  `dtach -n`, which has left the group by `setsid`. They aim only at the group of a program
  `Shell` started and still waits on, so they never reach a reused pid. A program that exits on
  its own, or on the TERM, leaves its children running.

  Given a `:reaper` (`CodingAgentFramework.Shell.Reaper`), a run also ends with its caller and
  with the VM: the reaper holds the group while the program runs, and ends it when the caller
  dies first, or when the VM dies. Without one, the caller's death or the VM's leaves the
  program running, as a plain port does.

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
    * `{:unknown, {:timeout, ms}}`: the program did not exit in time, and its group was ended.
  """

  alias CodingAgentFramework.{Host, Shell.Reaper}

  # MuonTrap's default wait between TERM and KILL.
  @grace 500
  # How long a killed program's exit status is awaited before its port is closed.
  @close 1_000

  # The smallest pipe buffer of the hosts the framework runs on: macOS starts a pipe at 16 KiB.
  @input_max 16_384

  @type result :: %{status: non_neg_integer, output: binary}
  @type outcome :: {:ok, result} | {:refused, term} | {:unknown, term}

  @doc """
  Runs `path` with `args` on `host`. Options: `:timeout` (required), milliseconds before the
  program's group is ended; `:reaper`, a `CodingAgentFramework.Shell.Reaper` that ends the
  group if the caller or the VM dies first; `:input`, bytes written to the program's stdin as
  it starts (`Tmux.CLI` loads a paste's text this way, so no text is on a command line).

  The stdin stays open until the program exits: a program that reads to its end must be told
  the length, as `head -c <n>` is. Input is at most `input_max/0` bytes, which every pipe holds
  whole, so the write never waits on the reader and never fails once the program has exited.
  """
  @spec run(Host.t(), String.t(), [String.t()], keyword) :: outcome
  def run(%Host{} = host, path, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    input = Keyword.get(opts, :input)

    case command(host, path, args) do
      _ when is_binary(input) and byte_size(input) > @input_max -> {:refused, {:input, :too_long}}
      {:ok, {exe, argv}} -> spawn_and_wait(host, exe, argv, timeout, {opts[:reaper], input})
      refused -> refused
    end
  end

  @doc """
  The most bytes `run/4` writes to a program's stdin (`:input`): 16 384, the smallest pipe
  buffer of the hosts the framework runs on, so the write is whole before the program reads.

      iex> CodingAgentFramework.Shell.input_max()
      16384
  """
  @spec input_max() :: pos_integer
  def input_max, do: @input_max

  @doc """
  The longest `run/4` with `timeout:` `timeout` takes, in ms (F-245): the timeout, then the
  wait between TERM and KILL, then the wait for the killed program's exit status. A caller that
  waits on a run bounds its wait by this, not by the timeout alone. The local `kill` runs that
  send TERM and KILL are not counted: they end at once (F-245's new-4).

      iex> CodingAgentFramework.Shell.bound(5_000)
      6500
  """
  @spec bound(pos_integer) :: pos_integer
  def bound(timeout) when is_integer(timeout) and timeout > 0, do: timeout + @grace + @close

  @doc """
  The executable and its arguments that `run/4` would use. Pure. Over ssh, every word is quoted
  for the remote shell.

      iex> host = CodingAgentFramework.Host.ssh("box", "/run/bin/ssh", "box", "/run/bin/kill")
      iex> CodingAgentFramework.Shell.command(host, "/run/bin/echo", ["it's"])
      {:ok, {"/run/bin/ssh", ["-o", "BatchMode=yes", "--", "box", "'/run/bin/echo' 'it'\\\\''s'"]}}
  """
  @spec command(Host.t(), String.t(), [String.t()]) ::
          {:ok, {String.t(), [String.t()]}} | {:refused, term}
  def command(%Host{reach: reach} = host, path, args) do
    cond do
      Path.type(path) != :absolute ->
        {:refused, {:not_absolute, path}}

      reach == :local ->
        {:ok, {path, args}}

      true ->
        {:ssh, ssh, destination} = reach
        remote = Enum.map_join([path | args], " ", &shell_quote/1)
        {:ok, {ssh, Host.ssh_options(host) ++ ["-o", "BatchMode=yes", "--", destination, remote]}}
    end
  end

  @doc """
  Quotes one word for a POSIX shell.

      iex> CodingAgentFramework.Shell.shell_quote("a b'c")
      "'a b'\\\\''c'"
  """
  @spec shell_quote(String.t()) :: String.t()
  def shell_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  defp spawn_and_wait(host, exe, argv, timeout, {reaper, input}) do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: argv
      ])

    # A program that has already exited has closed its port, and the port has no pid left; its
    # output and exit status are in the mailbox all the same, and there is no group to hold.
    pgid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    if reaper && pgid, do: Reaper.hold(reaper, pgid)
    if input, do: send_input(port, input)
    deadline = System.monotonic_time(:millisecond) + timeout
    outcome = collect(host, port, pgid, deadline, timeout, [])
    # Dropped only once the exit was taken or the KILL sent: the reaper never aims at an ended
    # command's id.
    if reaper && pgid, do: Reaper.drop(reaper, pgid)
    outcome
  rescue
    e in ErlangError -> {:refused, {:cannot_start, exe, e.original}}
  end

  # A program that already exited has closed its port: what it would have read is moot.
  defp send_input(port, input) do
    Port.command(port, input)
  rescue
    ArgumentError -> :ok
  end

  defp collect(host, port, pgid, deadline, timeout, acc) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(host, port, pgid, deadline, timeout, [acc | data])

      {^port, {:exit_status, status}} ->
        {:ok, %{status: status, output: IO.iodata_to_binary(acc)}}
    after
      left ->
        if pgid, do: end_group(host.kill, port, pgid), else: close(port)
        {:unknown, {:timeout, timeout}}
    end
  end

  # The port is open and its exit not taken, so the program's pid, the group's id, is still its.
  # Once the exit comes, no KILL follows: the id may be free.
  defp end_group(kill, port, pgid) do
    signal(kill, "TERM", pgid)

    receive do
      {^port, {:exit_status, _}} ->
        drain(port)
    after
      @grace ->
        signal(kill, "KILL", pgid)
        close(port)
    end
  end

  @doc false
  # Also the reaper's: `name` (TERM or KILL) to the group whose id is `pgid`, with this
  # machine's `kill`.
  @spec signal(String.t(), String.t(), pos_integer) :: :ok
  def signal(kill, name, pgid) do
    System.cmd(kill, ["-s", name, "--", "-#{pgid}"], stderr_to_stdout: true)
    :ok
  end

  # A killed program's exit status could arrive after a `Port.close/1`, in the caller's mailbox,
  # which a GenServer does not expect. So the status of the program just killed is awaited, for
  # a bounded time, and the port is closed only when it does not come.
  defp close(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      @close -> Port.close(port)
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
