defmodule CodingAgentFramework.Host do
  @moduledoc """
  A machine agents run on, and how it is reached: on this machine, or over ssh.

  It is data only. `CodingAgentFramework.Shell` runs programs on it, and every key of the
  host layer starts with its `name`.

  It names the programs of this machine that reach it: `ssh` to start a run on a remote host,
  and `kill` to end a run's process group past its timeout. Each run is a process on this
  machine (the program itself, or its ssh), so `kill` is this machine's even for a remote host,
  and comes from this machine's `CodingAgentFramework.Programs` or the caller.

  A host reached over ssh may name `options` that every ssh to it takes before its destination:
  the framework home's ssh config and known hosts (`CodingAgentFramework.ToolHome.ssh_options/1`),
  so ssh learns a host's key into the home, never into the person's own folder (F-155).

      iex> CodingAgentFramework.Host.local("laptop", "/run/bin/kill")
      %CodingAgentFramework.Host{name: "laptop", reach: :local, kill: "/run/bin/kill", options: []}

      iex> CodingAgentFramework.Host.ssh("box", "/run/bin/ssh", "agent@box", "/run/bin/kill")
      %CodingAgentFramework.Host{name: "box", reach: {:ssh, "/run/bin/ssh", "agent@box"},
        kill: "/run/bin/kill", options: []}

      iex> host = CodingAgentFramework.Host.ssh("box", "/run/bin/ssh", "agent@box", "/run/bin/kill",
      ...>   options: ["-F", "/caf/ssh/config"])
      iex> CodingAgentFramework.Host.ssh_options(host)
      ["-F", "/caf/ssh/config"]
  """

  @enforce_keys [:name, :reach, :kill]
  defstruct [:name, :reach, :kill, options: []]

  @type reach :: :local | {:ssh, ssh_path :: String.t(), destination :: String.t()}
  @type t :: %__MODULE__{name: String.t(), reach: reach, kill: String.t(), options: [String.t()]}

  @doc "A host reached on this machine, with the absolute path of this machine's kill."
  @spec local(String.t(), String.t()) :: t
  def local(name, kill) when is_binary(name) and is_binary(kill),
    do: %__MODULE__{name: name, reach: :local, kill: kill}

  @doc """
  A host reached over ssh, with the absolute paths of this machine's ssh and kill. Option
  `options:`, words every ssh to it takes before its destination (none by default).
  """
  @spec ssh(String.t(), String.t(), String.t(), String.t(), keyword) :: t
  def ssh(name, ssh_path, destination, kill, opts \\ [])
      when is_binary(name) and is_binary(ssh_path) and is_binary(destination) and is_binary(kill) do
    options = Keyword.get(opts, :options, [])
    true = Enum.all?(options, &is_binary/1)
    %__MODULE__{name: name, reach: {:ssh, ssh_path, destination}, kill: kill, options: options}
  end

  @doc "The words every ssh to `host` takes before its destination."
  @spec ssh_options(t) :: [String.t()]
  def ssh_options(%__MODULE__{options: options}), do: options
end
