defmodule CodingAgentFramework.Holder do
  @moduledoc """
  dtach on one host: holds a process apart from tmux on a socket in a directory the holder owns,
  lists what it holds, and says whether a socket's process lives.

  A held process outlives the tmux server: when tmux held the agents in its panes, they ended
  mid-turn with it. Each socket is `<dir>/<name>.sock`, and the held process runs with
  `CLAUDECODE`, `CLAUDE_CODE_*`, `TMUX` and `TMUX_PANE` removed from its environment.

  A socket is `:live` while dtach answers on it (its process runs), `:stale` when its file is
  left but nothing answers (dtach was killed hard), and `:absent` with no file. A live socket is
  never removed; a stale one is removed only to hold a new process on its path
  (`model/tla/Agent.tla`, `AgentStarted`).

      iex> host = CodingAgentFramework.Host.local("laptop")
      iex> holder = CodingAgentFramework.Holder.new(host, "/tmp/agents", "/usr/bin/dtach")
      iex> CodingAgentFramework.Holder.viewer_argv(holder, "alpha")
      {:ok, ["/usr/bin/dtach", "-a", "/tmp/agents/alpha.sock", "-E", "-z", "-r", "winch"]}

  Two callers holding one name at once are serialized by dtach itself: the second `dtach -n`
  finds the path bound and is refused. The host's one writer is meant to be the only caller.
  """

  alias CodingAgentFramework.{Host, Shell}

  @enforce_keys [:host, :dir, :dtach]
  defstruct [:host, :dir, :dtach, timeout: 5_000]

  @type t :: %__MODULE__{host: Host.t(), dir: String.t(), dtach: String.t(), timeout: pos_integer}
  @type state :: :live | :stale | :absent

  @sh "/bin/sh"
  @name ~r/\A[A-Za-z0-9_-]{1,64}\z/
  # A unix socket path longer than this is cut by macOS's sockaddr_un.
  @max_socket_path 103
  # No detach key, no suspend key, and a redraw by SIGWINCH when a viewer attaches.
  @flags ["-E", "-z", "-r", "winch"]

  # One script per question, so the state is read and acted on in one process. dtach's push
  # mode with empty input connects and sends nothing: it exits 0 on a live socket and says
  # "Connection refused" on a stale one.
  @state ~S"""
  if [ ! -e "$1" ]; then echo absent; exit 0; fi
  if out=$("$0" -p "$1" </dev/null 2>&1); then echo live; exit 0; fi
  case $out in *"Connection refused"*) echo stale ;; *) echo "unknown $out" ;; esac
  """
  @remove_stale ~S"""
  if [ ! -e "$1" ]; then echo absent; exit 0; fi
  if out=$("$0" -p "$1" </dev/null 2>&1); then echo live; exit 0; fi
  case $out in *"Connection refused"*) rm -f -- "$1" && echo removed ;; *) echo "unknown $out" ;; esac
  """
  @list ~S"""
  for s in "$1"/*.sock; do
    [ -e "$s" ] || continue
    if out=$("$0" -p "$s" </dev/null 2>&1); then printf 'live\t%s\n' "$s"
    else case $out in *"Connection refused"*) printf 'stale\t%s\n' "$s" ;; *) printf 'unknown\t%s\n' "$s" ;; esac
    fi
  done
  """

  @doc "A holder of sockets in `dir` on `host`, with the host's dtach. Nothing runs."
  @spec new(Host.t(), String.t(), String.t(), keyword) :: t
  def new(%Host{} = host, dir, dtach, opts \\ []),
    do: struct!(__MODULE__, [host: host, dir: dir, dtach: dtach] ++ opts)

  @doc "The `{host, dir}` that names this holder."
  @spec key(t) :: {String.t(), String.t()}
  def key(%__MODULE__{host: host, dir: dir}), do: {host.name, dir}

  @doc """
  Holds `argv` under `dtach -n` on `name`'s socket. A stale socket file is removed first; a live
  one refuses the start.

  Returns `{:ok, socket_path}`, `{:refused, {:live, name}}`, `{:refused, {:bad_name, name}}`,
  `{:refused, {:socket_path_too_long, path}}`, or `{:unknown, reason}`.
  """
  @spec hold(t, String.t(), [String.t()], keyword) ::
          {:ok, String.t()} | {:refused, term} | {:unknown, term}
  def hold(%__MODULE__{} = h, name, argv, opts \\ []) do
    with {:ok, path} <- socket(h, name),
         {:ok, _} <- clear(h, name, path) do
      env = [
        env: Keyword.get(opts, :env, []),
        unset: ["CLAUDECODE", "TMUX", "TMUX_PANE"],
        unset_prefixes: ["CLAUDE_CODE_"],
        timeout: h.timeout
      ]

      case Shell.run(h.host, h.dtach, ["-n", path | @flags] ++ argv, env) do
        {:ok, %{status: 0}} -> {:ok, path}
        {:ok, %{status: 1, output: out}} -> started_elsewhere(name, path, out)
        {:ok, %{status: status, output: out}} -> {:unknown, {:dtach, status, out}}
        other -> other
      end
    end
  end

  @doc "Whether `name`'s socket is `:live`, `:stale` or `:absent`."
  @spec state(t, String.t()) :: {:ok, state} | {:refused, term} | {:unknown, term}
  def state(%__MODULE__{} = h, name) do
    with {:ok, path} <- socket(h, name),
         {:ok, %{status: 0, output: out}} <- script(h, @state, [path]) do
      case out do
        "absent\n" -> {:ok, :absent}
        "live\n" -> {:ok, :live}
        "stale\n" -> {:ok, :stale}
        _ -> {:unknown, {:state, out}}
      end
    else
      {:ok, %{status: status, output: out}} -> {:unknown, {:sh, status, out}}
      other -> other
    end
  end

  @doc """
  Removes `name`'s socket file only when it is stale. A live one is refused, and the check and
  the removal run in one shell.
  """
  @spec remove_stale(t, String.t()) :: {:ok, :removed} | {:refused, term} | {:unknown, term}
  def remove_stale(%__MODULE__{} = h, name) do
    with {:ok, path} <- socket(h, name) do
      case script(h, @remove_stale, [path]) do
        {:ok, %{status: 0, output: "removed\n"}} -> {:ok, :removed}
        {:ok, %{status: 0, output: "live\n"}} -> {:refused, {:live, name}}
        {:ok, %{status: 0, output: "absent\n"}} -> {:refused, {:absent, name}}
        {:ok, %{status: status, output: out}} -> {:unknown, {:sh, status, out}}
        other -> other
      end
    end
  end

  @doc """
  Every socket in the holder's directory, by name, with its state.

  Returns `{:ok, [%{name: name, socket: path, state: :live | :stale | :unknown}]}`.
  """
  @spec list(t) :: {:ok, [map]} | {:refused, term} | {:unknown, term}
  def list(%__MODULE__{} = h) do
    case script(h, @list, [h.dir]) do
      {:ok, %{status: 0, output: out}} ->
        held =
          for line <- String.split(out, "\n", trim: true),
              [state, path] <- [String.split(line, "\t", parts: 2)] do
            %{name: Path.basename(path, ".sock"), socket: path, state: listed(state)}
          end

        {:ok, held}

      {:ok, %{status: status, output: out}} ->
        {:unknown, {:sh, status, out}}

      other ->
        other
    end
  end

  @doc "The command a viewer pane runs to show `name`'s held process (`dtach -a`)."
  @spec viewer_argv(t, String.t()) :: {:ok, [String.t()]} | {:refused, term}
  def viewer_argv(%__MODULE__{} = h, name) do
    with {:ok, path} <- socket(h, name), do: {:ok, [h.dtach, "-a", path | @flags]}
  end

  defp socket(h, name) do
    if is_binary(name) and name =~ @name do
      path = Path.join(h.dir, name <> ".sock")

      if byte_size(path) > @max_socket_path,
        do: {:refused, {:socket_path_too_long, path}},
        else: {:ok, path}
    else
      {:refused, {:bad_name, name}}
    end
  end

  defp listed("live"), do: :live
  defp listed("stale"), do: :stale
  defp listed(_), do: :unknown

  defp clear(h, name, _path) do
    case remove_stale(h, name) do
      {:ok, :removed} -> {:ok, :removed}
      {:refused, {:absent, _}} -> {:ok, :absent}
      other -> other
    end
  end

  # dtach exits 1 when the path is already bound: another caller held this name in between.
  defp started_elsewhere(name, path, out) do
    if String.contains?(out, "Address already in use"),
      do: {:refused, {:live, name}},
      else: {:unknown, {:dtach, 1, out, path}}
  end

  defp script(h, script, args),
    do: Shell.run(h.host, @sh, ["-c", script, h.dtach | args], timeout: h.timeout)
end
