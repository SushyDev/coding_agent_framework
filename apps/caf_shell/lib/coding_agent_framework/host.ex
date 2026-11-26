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

  A host names its `scope`, the launcher each process meant to outlive the app starts under
  (F-274): `:none` by default, or `:systemd_user`, where `CodingAgentFramework.Holder` and
  `CodingAgentFramework.Tmux.CLI` start each `dtach -n` holder and the tmux server through
  `systemd-run --user --scope`, so a stop of the app's own systemd unit does not end them. The
  host's config says it; nothing detects it.

      iex> CodingAgentFramework.Host.local("laptop", "/run/bin/kill")
      %CodingAgentFramework.Host{name: "laptop", reach: :local, kill: "/run/bin/kill", options: [],
        scope: :none}

      iex> CodingAgentFramework.Host.local("box", "/run/bin/kill", scope: :systemd_user).scope
      :systemd_user

      iex> CodingAgentFramework.Host.ssh("box", "/run/bin/ssh", "agent@box", "/run/bin/kill")
      %CodingAgentFramework.Host{name: "box", reach: {:ssh, "/run/bin/ssh", "agent@box"},
        kill: "/run/bin/kill", options: [], scope: :none}

      iex> host = CodingAgentFramework.Host.ssh("box", "/run/bin/ssh", "agent@box", "/run/bin/kill",
      ...>   options: ["-F", "/caf/ssh/config"])
      iex> CodingAgentFramework.Host.ssh_options(host)
      ["-F", "/caf/ssh/config"]
  """

  @enforce_keys [:name, :reach, :kill]
  defstruct [:name, :reach, :kill, options: [], scope: :none]

  @type reach :: :local | {:ssh, ssh_path :: String.t(), destination :: String.t()}
  @type scope :: :none | :systemd_user
  @type t :: %__MODULE__{
          name: String.t(),
          reach: reach,
          kill: String.t(),
          options: [String.t()],
          scope: scope
        }

  @scopes [:none, :systemd_user]

  @doc "The scopes a host may name: `:none` and `:systemd_user`."
  @spec scopes() :: [scope]
  def scopes, do: @scopes

  @doc """
  A host reached on this machine, with the absolute path of this machine's kill. Option
  `scope:`, the launcher of its held processes (`:none` by default).
  """
  @spec local(String.t(), String.t(), keyword) :: t
  def local(name, kill, opts \\ []) when is_binary(name) and is_binary(kill),
    do: %__MODULE__{name: name, reach: :local, kill: kill, scope: scope!(opts)}

  @doc """
  A host reached over ssh, with the absolute paths of this machine's ssh and kill. Options:
  `options:`, words every ssh to it takes before its destination (none by default), and
  `scope:`, the launcher of its held processes (`:none` by default).
  """
  @spec ssh(String.t(), String.t(), String.t(), String.t(), keyword) :: t
  def ssh(name, ssh_path, destination, kill, opts \\ [])
      when is_binary(name) and is_binary(ssh_path) and is_binary(destination) and is_binary(kill) do
    options = Keyword.get(opts, :options, [])
    true = Enum.all?(options, &is_binary/1)

    %__MODULE__{
      name: name,
      reach: {:ssh, ssh_path, destination},
      kill: kill,
      options: options,
      scope: scope!(opts)
    }
  end

  @doc """
  The words that start a held process on `host` in the scope unit `unit`, `systemd_run` being
  the host's `systemd-run`: none on a host whose `scope` is `:none`.

  `--quiet` keeps systemd-run's notice out of the output a caller reads.
  `--expand-environment=no` keeps the command's words as given: `systemd-run --scope` would
  otherwise read `$$` or `"$@"` in a script as its own variables.

      iex> host = CodingAgentFramework.Host.local("box", "/run/bin/kill", scope: :systemd_user)
      iex> CodingAgentFramework.Host.scope_argv(host, "/usr/bin/systemd-run", "caf-1-alpha")
      ["/usr/bin/systemd-run", "--user", "--scope", "--collect", "--quiet",
       "--expand-environment=no", "--unit=caf-1-alpha"]
      iex> CodingAgentFramework.Host.scope_argv(%{host | scope: :none}, nil, "caf-1-alpha")
      []
  """
  @spec scope_argv(t, String.t() | nil, String.t()) :: [String.t()]
  def scope_argv(%__MODULE__{scope: :none}, _systemd_run, _unit), do: []

  def scope_argv(%__MODULE__{scope: :systemd_user}, systemd_run, unit)
      when is_binary(systemd_run),
      do: [
        systemd_run,
        "--user",
        "--scope",
        "--collect",
        "--quiet",
        "--expand-environment=no",
        "--unit=" <> unit
      ]

  @doc "The words every ssh to `host` takes before its destination."
  @spec ssh_options(t) :: [String.t()]
  def ssh_options(%__MODULE__{options: options}), do: options

  defp scope!(opts) do
    scope = Keyword.get(opts, :scope, :none)
    true = scope in @scopes
    scope
  end
end
