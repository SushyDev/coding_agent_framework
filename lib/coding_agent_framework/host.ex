defmodule CodingAgentFramework.Host do
  @moduledoc """
  A machine agents run on, and how it is reached: on this machine, or over ssh.

  It is data only. `CodingAgentFramework.Shell` runs programs on it, and every key of the
  host layer starts with its `name`.

  It names the programs of this machine that reach it: `ssh` to start a run on a remote host,
  and `kill` to end a run's process group past its timeout. Each run is a process on this
  machine (the program itself, or its ssh), so `kill` is this machine's even for a remote host,
  and comes from this machine's `CodingAgentFramework.Programs` or the caller.

      iex> CodingAgentFramework.Host.local("laptop", "/run/bin/kill")
      %CodingAgentFramework.Host{name: "laptop", reach: :local, kill: "/run/bin/kill"}

      iex> CodingAgentFramework.Host.ssh("box", "/run/bin/ssh", "agent@box", "/run/bin/kill")
      %CodingAgentFramework.Host{name: "box", reach: {:ssh, "/run/bin/ssh", "agent@box"}, kill: "/run/bin/kill"}
  """

  @enforce_keys [:name, :reach, :kill]
  defstruct [:name, :reach, :kill]

  @type reach :: :local | {:ssh, ssh_path :: String.t(), destination :: String.t()}
  @type t :: %__MODULE__{name: String.t(), reach: reach, kill: String.t()}

  @doc "A host reached on this machine, with the absolute path of this machine's kill."
  @spec local(String.t(), String.t()) :: t
  def local(name, kill) when is_binary(name) and is_binary(kill),
    do: %__MODULE__{name: name, reach: :local, kill: kill}

  @doc "A host reached over ssh, with the absolute paths of this machine's ssh and kill."
  @spec ssh(String.t(), String.t(), String.t(), String.t()) :: t
  def ssh(name, ssh_path, destination, kill)
      when is_binary(name) and is_binary(ssh_path) and is_binary(destination) and is_binary(kill),
      do: %__MODULE__{name: name, reach: {:ssh, ssh_path, destination}, kill: kill}
end
