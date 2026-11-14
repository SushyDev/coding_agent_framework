defmodule CodingAgentFramework.Host do
  @moduledoc """
  A machine agents run on, and how it is reached: on this machine, or over ssh.

  It is data only. `CodingAgentFramework.Shell` runs programs on it, and every key of the
  host layer starts with its `name`.

      iex> CodingAgentFramework.Host.local("laptop")
      %CodingAgentFramework.Host{name: "laptop", reach: :local}

      iex> CodingAgentFramework.Host.ssh("box", "/usr/bin/ssh", "agent@box")
      %CodingAgentFramework.Host{name: "box", reach: {:ssh, "/usr/bin/ssh", "agent@box"}}
  """

  @enforce_keys [:name, :reach]
  defstruct [:name, :reach]

  @type reach :: :local | {:ssh, ssh_path :: String.t(), destination :: String.t()}
  @type t :: %__MODULE__{name: String.t(), reach: reach}

  @doc "A host reached on this machine."
  @spec local(String.t()) :: t
  def local(name) when is_binary(name), do: %__MODULE__{name: name, reach: :local}

  @doc "A host reached over ssh, with the absolute path of this machine's ssh."
  @spec ssh(String.t(), String.t(), String.t()) :: t
  def ssh(name, ssh_path, destination)
      when is_binary(name) and is_binary(ssh_path) and is_binary(destination),
      do: %__MODULE__{name: name, reach: {:ssh, ssh_path, destination}}
end
