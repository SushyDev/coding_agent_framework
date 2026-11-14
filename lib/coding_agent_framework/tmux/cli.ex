defmodule CodingAgentFramework.Tmux.CLI do
  @moduledoc ~S"""
  The `CodingAgentFramework.Tmux` contract on a real tmux server, run through
  `CodingAgentFramework.Shell`.

  A server is named `{:name, name}` (`tmux -L name`) or `{:socket, path}` (`tmux -S path`, used
  by tests so each owns its server). The server reads `config` when it starts, `/dev/null` by
  default: it is the framework's own, and a user's config could change its indexes or options.

      iex> host = CodingAgentFramework.Host.local("laptop", "/run/bin/kill")
      iex> paths = %{tmux: "/run/bin/tmux", rm: "/run/bin/rm"}
      iex> {:ok, programs} = CodingAgentFramework.Programs.new(host, paths)
      iex> {:ok, server} = CodingAgentFramework.Tmux.CLI.new(programs, {:name, "agents"})
      iex> CodingAgentFramework.Tmux.key(server)
      {"laptop", "agents"}

  A write is one tmux command:

      if-shell -F -t %3 '#{&&:#{==:#{pane_id},%3},#{==:#{@tag},alpha}}'
        "send-keys -t %3 -l -- '<text>' ; display-message -p sent"
        "display-message -p -t %3 'refused<TAB>#{pane_id}<TAB>#{@tag}'"

  tmux resolves the target, checks that pane's id and tag, and sends to it, all in one command
  on one server, so no restart can come between the check and the send. A missing pane leaves
  `#{pane_id}` empty and is refused as `:no_pane`. `kill_pane/3` and `respawn_pane/4` run
  `kill-pane` and `respawn-pane -k` in place of `send-keys`, under the same check.
  """

  @behaviour CodingAgentFramework.Tmux

  alias CodingAgentFramework.{Host, Programs, Shell}

  @enforce_keys [:host, :server, :tmux, :rm]
  defstruct [:host, :server, :tmux, :rm, tag: "@caf_session", config: "/dev/null", timeout: 5_000]

  @type t :: %__MODULE__{
          host: Host.t(),
          server: {:name, String.t()} | {:socket, String.t()},
          tmux: String.t(),
          rm: String.t(),
          tag: String.t(),
          config: String.t(),
          timeout: pos_integer
        }

  @doc """
  A server handle on the host of `programs`, which must name its tmux and rm (`kill_server/1`
  removes the socket file with it). Nothing runs until a call. Options: `:tag`, `:config`,
  `:timeout`.
  """
  @spec new(Programs.t(), {:name, String.t()} | {:socket, String.t()}, keyword) ::
          {:ok, t} | {:refused, {:no_program, list}}
  def new(%Programs{host: host} = programs, server, opts \\ []) do
    with {:ok, paths} <- Programs.take(programs, [:tmux, :rm]),
         do:
           {:ok, struct!(__MODULE__, [host: host, server: server] ++ Map.to_list(paths) ++ opts)}
  end

  @impl true
  def key(%__MODULE__{host: host, server: {_, name}}), do: {host.name, name}

  @impl true
  def new_session(%__MODULE__{tag: tag} = s, session, argv, opts) do
    size =
      case Keyword.get(opts, :size) do
        {c, r} -> ["-x", "#{c}", "-y", "#{r}"]
        nil -> []
      end

    args =
      ["new-session", "-d", "-s", session | size] ++
        ["-P", "-F", "\#{pane_id}", "--"] ++
        Enum.map(argv, &escape/1) ++ [";", "set-option", "-p", "-t", "=#{session}:", tag, session]

    case run(s, args) do
      {:ok, %{status: 0, output: out}} ->
        case String.split(out, "\n", trim: true) do
          [pane] -> {:ok, pane}
          _ -> {:unknown, {:tmux_output, out}}
        end

      {:ok, %{status: 1, output: "duplicate session" <> _}} ->
        {:refused, {:session_exists, session}}

      other ->
        failure(other)
    end
  end

  @impl true
  def list_panes(%__MODULE__{tag: tag} = s) do
    format = Enum.join(["\#{pane_id}", "\#{session_name}", "\#{#{tag}}"], "\t")

    case run(s, ["list-panes", "-a", "-F", format]) do
      {:ok, %{status: 0, output: out}} ->
        {:ok, for(line <- String.split(out, "\n", trim: true), do: pane_info(line))}

      other ->
        failure(other)
    end
  end

  @impl true
  def write(%__MODULE__{} = s, pane, session, {:line, text}),
    do:
      guarded(
        s,
        pane,
        session,
        "send-keys -t #{pane} -l -- #{quote_arg(text)} ; send-keys -t #{pane} Enter",
        :sent
      )

  def write(%__MODULE__{} = s, pane, session, {:text, text}),
    do: guarded(s, pane, session, "send-keys -t #{pane} -l -- #{quote_arg(text)}", :sent)

  def write(%__MODULE__{} = s, pane, session, {:keys, keys}),
    do: guarded(s, pane, session, "send-keys -t #{pane} #{Enum.join(keys, " ")}", :sent)

  @impl true
  def kill_pane(%__MODULE__{} = s, pane, session),
    do: guarded(s, pane, session, "kill-pane -t #{pane}", :killed)

  @impl true
  def respawn_pane(%__MODULE__{} = s, pane, session, argv) do
    command = "respawn-pane -k -t #{pane} -- " <> Enum.map_join(argv, " ", &quote_arg/1)
    guarded(s, pane, session, command, :respawned)
  end

  @impl true
  def resize_pane(%__MODULE__{} = s, pane, session, {c, r}) do
    command = "resize-window -t #{pane} -x #{c} -y #{r} ; set-option -w -u -t #{pane} window-size"
    guarded(s, pane, session, command, :resized)
  end

  # Runs `command` only when the pane at `pane` has that id and its tag names `session`, in one
  # tmux command, and prints `done` after it.
  defp guarded(%__MODULE__{tag: tag} = s, pane, session, command, done) do
    check = "\#{&&:\#{==:\#{pane_id},#{pane}},\#{==:\#{#{tag}},#{session}}}"
    refuse = "display-message -p -t #{pane} 'refused\t\#{pane_id}\t\#{#{tag}}'"
    expected = "#{done}\n"

    case run(s, [
           "if-shell",
           "-F",
           "-t",
           pane,
           check,
           "#{command} ; display-message -p #{done}",
           refuse
         ]) do
      {:ok, %{status: 0, output: ^expected}} ->
        {:ok, done}

      {:ok, %{status: 0, output: "refused\t" <> rest}} ->
        case String.split(String.trim_trailing(rest, "\n"), "\t") do
          ["", _] -> {:refused, :no_pane}
          [^pane, ""] -> {:refused, :untagged}
          [^pane, other] -> {:refused, {:tagged_for, other}}
          _ -> {:unknown, {:tmux_output, rest}}
        end

      other ->
        failure(other)
    end
  end

  @impl true
  def kill_session(%__MODULE__{} = s, session) do
    case run(s, ["kill-session", "-t", "=#{session}"]) do
      {:ok, %{status: 0}} -> {:ok, :killed}
      {:ok, %{status: 1, output: "can't find session" <> _}} -> {:refused, :no_session}
      other -> failure(other)
    end
  end

  @impl true
  def kill_server(%__MODULE__{} = s) do
    # tmux leaves the socket file behind; ask for its path in the same command that kills it.
    case run(s, ["display-message", "-p", "\#{socket_path}", ";", "kill-server"]) do
      {:ok, %{status: 0, output: out}} ->
        remove_socket(s, String.trim_trailing(out, "\n"))

      other ->
        failure(other)
    end
  end

  @doc """
  Escapes one argument for tmux's command line: an argument ending in `;` would end the tmux
  command, and the rest would run as a new one. tmux 3.8 reads a trailing `\;` as a literal `;`
  and changes nothing else in the argument, so a backslash goes before the last `;`.

      iex> CodingAgentFramework.Tmux.CLI.escape("a;")
      "a\\\\;"
      iex> CodingAgentFramework.Tmux.CLI.escape("a b")
      "a b"
  """
  @spec escape(String.t()) :: String.t()
  def escape(arg) do
    if String.ends_with?(arg, ";"),
      do: String.slice(arg, 0..-2//1) <> "\\;",
      else: arg
  end

  # An argument goes inside tmux single quotes, where nothing is special but the quote itself.
  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", ~S('\'')) <> "'"

  defp pane_info(line) do
    [pane, session, tag] = String.split(line, "\t", parts: 3)
    %{pane: pane, session: session, tag: if(tag == "", do: nil, else: tag)}
  end

  defp remove_socket(%__MODULE__{} = s, path) do
    case Shell.run(s.host, s.rm, ["-f", "--", path], timeout: s.timeout) do
      {:ok, %{status: 0}} -> {:ok, :killed}
      {:ok, %{status: status, output: out}} -> {:unknown, {:socket_left, path, status, out}}
      other -> other
    end
  end

  defp run(%__MODULE__{server: server} = s, args) do
    socket =
      case server do
        {:name, name} -> ["-L", name]
        {:socket, path} -> ["-S", path]
      end

    Shell.run(s.host, s.tmux, socket ++ ["-f", s.config | args], timeout: s.timeout)
  end

  defp failure({:ok, %{status: 1, output: out}}) do
    if no_server?(out), do: {:refused, :no_server}, else: {:unknown, {:tmux, 1, out}}
  end

  defp failure({:ok, %{status: status, output: out}}), do: {:unknown, {:tmux, status, out}}
  defp failure(other), do: other

  defp no_server?(out),
    do: String.starts_with?(out, ["no server running on", "error connecting to"])
end
