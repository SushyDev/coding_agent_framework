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

  On a host whose `scope` is `:systemd_user` (`CodingAgentFramework.Host`), `new_session/4`
  runs its tmux client through `systemd-run --user --scope`. The client that finds no server
  starts it, and the server stays in that client's scope, out of the app's cgroup, so a stop of
  the app's systemd unit does not end it. A client that finds the server exits at once, and its
  empty scope is collected. Each scope's unit is new (`caf-<key>-tmux-<time>-<n>`), since a scope
  that holds the server outlives the session it started with. A `systemd-run` that fails refuses
  the start, `{:refused, {:scope, output}}`.

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

  alias CodingAgentFramework.{Host, Programs, Shell, Tmux}

  @enforce_keys [:host, :server, :tmux, :rm]
  defstruct [
    :host,
    :server,
    :tmux,
    :rm,
    systemd_run: nil,
    tag: "@caf_session",
    config: "/dev/null",
    timeout: 5_000
  ]

  @type t :: %__MODULE__{
          host: Host.t(),
          server: {:name, String.t()} | {:socket, String.t()},
          tmux: String.t(),
          rm: String.t(),
          systemd_run: String.t() | nil,
          tag: String.t(),
          config: String.t(),
          timeout: pos_integer
        }

  @doc """
  A server handle on the host of `programs`, which must name its tmux and rm (`kill_server/1`
  removes the socket file with it), and its systemd_run on a host whose `scope` is
  `:systemd_user`. Nothing runs until a call. Options: `:tag`, `:config`,
  `:timeout`.
  """
  @spec new(Programs.t(), {:name, String.t()} | {:socket, String.t()}, keyword) ::
          {:ok, t} | {:refused, {:no_program, list}}
  def new(%Programs{host: host} = programs, server, opts \\ []) do
    with {:ok, paths} <- Programs.take(programs, [:tmux, :rm | scoped(host)]),
         do:
           {:ok, struct!(__MODULE__, [host: host, server: server] ++ Map.to_list(paths) ++ opts)}
  end

  defp scoped(%Host{scope: :systemd_user}), do: [:systemd_run]
  defp scoped(%Host{scope: :none}), do: []

  @impl true
  def key(%__MODULE__{host: host, server: {_, name}}), do: {host.name, name}

  # Each command is one `Shell.run/4` at the server's `timeout`.
  @impl true
  def bound(%__MODULE__{timeout: timeout}), do: Shell.bound(timeout)

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

    case run(s, args, scope(s)) do
      {:ok, %{status: 0, output: out}} ->
        case String.split(out, "\n", trim: true) do
          [pane] -> {:ok, pane}
          _ -> {:unknown, {:tmux_output, out}}
        end

      {:ok, %{status: 1, output: "duplicate session" <> _}} ->
        {:refused, {:session_exists, session}}

      {:ok, %{status: 1, output: "Failed to " <> _ = out}} when s.host.scope == :systemd_user ->
        {:refused, {:scope, out}}

      other ->
        failure(other)
    end
  end

  @impl true
  def list_panes(%__MODULE__{tag: tag} = s) do
    # The server's pid and start time name this start of it: start_time alone is in seconds.
    format =
      Enum.join(["\#{pane_id}", "\#{pid}@\#{start_time}", "\#{session_name}", "\#{#{tag}}"], "\t")

    case run(s, ["list-panes", "-a", "-F", format]) do
      {:ok, %{status: 0, output: out}} ->
        {:ok, for(line <- String.split(out, "\n", trim: true), do: pane_info(line))}

      other ->
        failure(other)
    end
  end

  @impl true
  def list_clients(%__MODULE__{} = s) do
    format = Enum.join(["\#{client_tty}", "\#{client_session}", "\#{client_created}"], "\t")

    case run(s, ["list-clients", "-F", format]) do
      {:ok, %{status: 0, output: out}} ->
        {:ok, for(line <- String.split(out, "\n", trim: true), do: client_info(line))}

      other ->
        failure(other)
    end
  end

  @doc """
  One line of `list-clients` as `list_clients/1` asks for it, tty, session and creation time
  apart by tabs: total over the line, one tmux could not have printed being kept whole.

      iex> CodingAgentFramework.Tmux.CLI.client_info("/dev/ttys003\\tapp-main\\t1795000000")
      %{tty: "/dev/ttys003", session: "app-main", created: 1795000000}
      iex> CodingAgentFramework.Tmux.CLI.client_info("/dev/ttys003")
      {:malformed, "/dev/ttys003"}
  """
  @spec client_info(String.t()) :: Tmux.client_info()
  def client_info(line) do
    with [tty, session, created] <- String.split(line, "\t", parts: 3),
         true <- tty != "",
         {created, ""} <- Integer.parse(created) do
      %{tty: tty, session: session, created: created}
    else
      _ -> {:malformed, line}
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

  # The width comes first, on a line of its own, so the screen after it is read whole.
  @impl true
  def capture(%__MODULE__{} = s, pane, session) do
    command =
      "display-message -p -t #{pane} 'captured\t\#{pane_width}' ; capture-pane -p -e -t #{pane}"

    guarded(s, pane, session, command, fn
      "captured\t" <> rest ->
        with [width, text] <- String.split(rest, "\n", parts: 2),
             {width, ""} when width > 0 <- Integer.parse(width) do
          {:ok, %{text: text, width: width}}
        else
          _ -> :other
        end

      _ ->
        :other
    end)
  end

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
  defp guarded(s, pane, session, command, done) when is_atom(done) do
    expected = "#{done}\n"

    guarded(s, pane, session, "#{command} ; display-message -p #{done}", fn
      ^expected -> {:ok, done}
      _ -> :other
    end)
  end

  # As above, with `parse` reading what `command` printed: `{:ok, value}`, or `:other`.
  defp guarded(%__MODULE__{tag: tag} = s, pane, session, command, parse) do
    check = "\#{&&:\#{==:\#{pane_id},#{pane}},\#{==:\#{#{tag}},#{session}}}"
    refuse = "display-message -p -t #{pane} 'refused\t\#{pane_id}\t\#{#{tag}}'"

    case run(s, ["if-shell", "-F", "-t", pane, check, command, refuse]) do
      {:ok, %{status: 0, output: "refused\t" <> rest}} ->
        case String.split(String.trim_trailing(rest, "\n"), "\t") do
          ["", _] -> {:refused, :no_pane}
          [^pane, ""] -> {:refused, :untagged}
          [^pane, other] -> {:refused, {:tagged_for, other}}
          _ -> {:unknown, {:tmux_output, rest}}
        end

      {:ok, %{status: 0, output: out}} = other ->
        with :other <- parse.(out), do: failure(other)

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

  # Total over the line: one tmux could not have printed is kept, whole, as a problem.
  defp pane_info(line) do
    with [pane, start, session, tag] <- String.split(line, "\t", parts: 4),
         [pid, time] <- String.split(start, "@"),
         {_, ""} <- Integer.parse(pid),
         {_, ""} <- Integer.parse(time) do
      %{pane: pane, session: session, tag: if(tag == "", do: nil, else: tag), start: start}
    else
      _ -> {:malformed, line}
    end
  end

  defp remove_socket(%__MODULE__{} = s, path) do
    case Shell.run(s.host, s.rm, ["-f", "--", path], timeout: s.timeout) do
      {:ok, %{status: 0}} -> {:ok, :killed}
      {:ok, %{status: status, output: out}} -> {:unknown, {:socket_left, path, status, out}}
      other -> other
    end
  end

  defp run(%__MODULE__{server: server} = s, args, scope \\ []) do
    socket =
      case server do
        {:name, name} -> ["-L", name]
        {:socket, path} -> ["-S", path]
      end

    [program | words] = scope ++ [s.tmux | socket] ++ ["-f", s.config | args]
    Shell.run(s.host, program, words, timeout: s.timeout)
  end

  # The client that may start the server runs in a scope of its own, named anew each time.
  defp scope(%__MODULE__{host: %Host{scope: :none}}), do: []

  defp scope(%__MODULE__{server: {_, name}} = s) do
    key =
      :erlang.md5(s.host.name <> "\0" <> name)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    unit = "caf-#{key}-tmux-#{System.os_time(:microsecond)}-#{System.unique_integer([:positive])}"
    Host.scope_argv(s.host, s.systemd_run, unit)
  end

  defp failure({:ok, %{status: 1, output: out}}) do
    if no_server?(out), do: {:refused, :no_server}, else: {:unknown, {:tmux, 1, out}}
  end

  defp failure({:ok, %{status: status, output: out}}), do: {:unknown, {:tmux, status, out}}
  defp failure(other), do: other

  defp no_server?(out),
    do: String.starts_with?(out, ["no server running on", "error connecting to"])
end
