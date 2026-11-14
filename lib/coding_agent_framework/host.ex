defmodule CodingAgentFramework.Host do
  @moduledoc """
  A machine agents run on, and how it is reached: on this machine, or over ssh.

  It is data only. `CodingAgentFramework.Shell` runs programs on it, and every key of the
  host layer starts with its `name`.

  It names the programs of this machine that reach it: `ssh` to start a run on a remote host,
  and `sh` and `sleep`, which run each command in a process group of its own and end that group
  (see `CodingAgentFramework.Shell`). Each run is a process on this machine (the program itself,
  or its ssh), so `sh` and `sleep` are this machine's even for a remote host, and come from this
  machine's `CodingAgentFramework.Programs` or the caller.

      iex> CodingAgentFramework.Host.local("laptop", "/run/bin/sh", "/run/bin/sleep")
      %CodingAgentFramework.Host{name: "laptop", reach: :local, sh: "/run/bin/sh", sleep: "/run/bin/sleep"}

      iex> CodingAgentFramework.Host.ssh("box", "/run/bin/ssh", "agent@box", "/run/bin/sh", "/run/bin/sleep")
      %CodingAgentFramework.Host{name: "box", reach: {:ssh, "/run/bin/ssh", "agent@box"}, sh: "/run/bin/sh", sleep: "/run/bin/sleep"}
  """

  @enforce_keys [:name, :reach, :sh, :sleep]
  defstruct [:name, :reach, :sh, :sleep]

  @type reach :: :local | {:ssh, ssh_path :: String.t(), destination :: String.t()}
  @type t :: %__MODULE__{name: String.t(), reach: reach, sh: String.t(), sleep: String.t()}

  @doc "A host reached on this machine, with the absolute paths of this machine's sh and sleep."
  @spec local(String.t(), String.t(), String.t()) :: t
  def local(name, sh, sleep) when is_binary(name) and is_binary(sh) and is_binary(sleep),
    do: %__MODULE__{name: name, reach: :local, sh: sh, sleep: sleep}

  @doc "A host reached over ssh, with the absolute paths of this machine's ssh, sh and sleep."
  @spec ssh(String.t(), String.t(), String.t(), String.t(), String.t()) :: t
  def ssh(name, ssh_path, destination, sh, sleep)
      when is_binary(name) and is_binary(ssh_path) and is_binary(destination) and is_binary(sh) and
             is_binary(sleep),
      do: %__MODULE__{name: name, reach: {:ssh, ssh_path, destination}, sh: sh, sleep: sleep}
end
