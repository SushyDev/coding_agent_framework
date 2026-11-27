defmodule CodingAgentFramework.Tmux do
  @moduledoc """
  Sessions, panes, tags and writes on one tmux server: the contract, with a CLI
  (`CodingAgentFramework.Tmux.CLI`) and a fake (`CodingAgentFramework.Tmux.Fake`).

  A server is a struct of either implementation, keyed by `{host, server}` (`key/1`): pane ids
  are unique only within one server, and a restarted server counts from `%0` again.

  Every pane the framework opens is tagged with its session as it opens (`new_session/4`), and a
  write goes out only to a tagged pane whose tag names the write's session. The check and the
  send are one tmux command, so tmux checks the very pane it sends to, and a server that died in
  between sends nothing (`model/tla/Agent.tla`, `WriteAsked`). Ending or respawning a pane by its
  id goes through the same check.

  This module checks its arguments, then calls the server's implementation, so both answer the
  same refusals for the same bad input:

      iex> server = %CodingAgentFramework.Tmux.Fake{pid: self(), key: {"laptop", "test"}}
      iex> CodingAgentFramework.Tmux.write(server, "", "alpha", {:text, "hi"})
      {:refused, {:bad_target, ""}}

  The refusal of a target not of the form `%<n>` is defense in depth: tmux reads an empty target
  as its current pane, and the tag check alone would refuse that pane too.
  """

  # Bracketed paste's markers, which a paste's buffer holds around its text (`bracketed/1`).
  @paste_start "\e[200~"
  @paste_end "\e[201~"

  @type server :: struct
  @type key :: {host :: String.t(), server :: String.t()}
  @type pane :: String.t()
  @type session :: String.t()
  @type input ::
          {:text, String.t()}
          | {:line, String.t()}
          | {:keys, [String.t()]}
          | {:paste, buffer :: String.t(), String.t()}
  @type pane_info ::
          %{pane: pane, session: session, tag: session | nil, start: String.t()}
          | {:malformed, String.t()}
  @type client_info ::
          %{tty: String.t(), session: session, created: integer} | {:malformed, String.t()}

  @doc "The `{host, server}` that names this server."
  @callback key(server) :: key

  @doc """
  The longest one command on this server takes, in ms, refused or not (F-245): a caller that
  waits on several commands bounds its wait by their count times this.
  """
  @callback bound(server) :: pos_integer

  @doc """
  Opens a detached session named `session` whose one pane runs `argv` and is tagged with
  `session` in the same tmux command. Starts the server when none runs. Option: `size:
  {columns, rows}`, the window's size.
  """
  @callback new_session(server, session, argv :: [String.t()], opts :: keyword) ::
              {:ok, pane} | {:refused, term} | {:unknown, term}

  @doc """
  Every pane on the server, with its session, its tag and `start`, which names this start of the
  server (the CLI's is `<server pid>@<start time>`): a new start is a new set of pane ids. A line
  that cannot be read is `{:malformed, line}`.
  """
  @callback list_panes(server) :: {:ok, [pane_info]} | {:refused, term} | {:unknown, term}

  @doc """
  Every client attached to the server (a terminal showing one of its sessions, F-199): its
  `tty`, the `session` it shows, and `created`, when it attached (Unix seconds), so a client
  is one fact by its tty and that time. A line that cannot be read is `{:malformed, line}`.
  Refusals: `:no_server`.
  """
  @callback list_clients(server) :: {:ok, [client_info]} | {:refused, term} | {:unknown, term}

  @doc """
  Sends `input` to `pane` only when the pane's tag names `session`, in one tmux command.

  A paste, `{:paste, buffer, text}`, is two (F-279): `text`, inside bracketed paste's markers
  (`bracketed/1`, F-287), is loaded into the server's buffer named `buffer` from stdin, never
  on a command line; then, under the tag check in one command, the buffer is pasted into the
  pane as it is, its newlines kept, and dropped. A buffer named
  for one write alone holds that write's text when it is pasted, whatever another writer loads
  meanwhile (`model/tla/Agent.tla`, `PastesItsOwnText`). A paste refused by the check drops
  the buffer too. A load that fails pastes nothing: it is refused `{:load, reason}`.

  Refusals: `:no_server`, `:no_pane`, `:untagged`, `{:tagged_for, other}`, and for a paste
  `{:load, reason}`.
  """
  @callback write(server, pane, session, input) ::
              {:ok, :sent} | {:refused, term} | {:unknown, term}

  @doc """
  The screen of `pane` as it shows now (`capture-pane -p -e`: its visible rows, each with its
  trailing spaces dropped, with the escapes of their colors and attributes, so a reader can
  tell a run drawn dim from typed text, F-198) and the pane's width in columns, only when its
  tag names `session`, checked in the same tmux command as a write is. Refusals as
  `c:write/4`'s.
  """
  @callback capture(server, pane, session) ::
              {:ok, %{text: String.t(), width: pos_integer}} | {:refused, term} | {:unknown, term}

  @doc """
  Ends `pane` only when its tag names `session`, checked in the same tmux command as a write is.
  """
  @callback kill_pane(server, pane, session) ::
              {:ok, :killed} | {:refused, term} | {:unknown, term}

  @doc """
  Starts `argv` again in `pane` (ending what ran there) only when its tag names `session`,
  checked in the same tmux command as a write is. The pane keeps its id and its tag.
  """
  @callback respawn_pane(server, pane, session, argv :: [String.t()]) ::
              {:ok, :respawned} | {:refused, term} | {:unknown, term}

  @doc """
  Sets the window of `pane` to `{columns, rows}` only when its tag names `session`, checked in the
  same tmux command as a write is, and then unsets the window's `window-size`, which
  `resize-window` sets and which would keep the window fixed.
  """
  @callback resize_pane(server, pane, session, {pos_integer, pos_integer}) ::
              {:ok, :resized} | {:refused, term} | {:unknown, term}

  @doc "Ends one session and its panes."
  @callback kill_session(server, session) :: {:ok, :killed} | {:refused, term} | {:unknown, term}

  @doc "Ends the server and removes its socket file."
  @callback kill_server(server) :: {:ok, :killed} | {:refused, term} | {:unknown, term}

  @pane ~r/\A%[0-9]+\z/
  @buffer ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @session ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @key ~r/\A[A-Za-z0-9-]{1,32}\z/

  @doc "The `{host, server}` of a server."
  @spec key(server) :: key
  def key(%mod{} = server), do: mod.key(server)

  @doc "See the `c:bound/1` callback."
  @spec bound(server) :: pos_integer
  def bound(%mod{} = server), do: mod.bound(server)

  @doc "See the `c:new_session/4` callback."
  @spec new_session(server, session, [String.t()], keyword) ::
          {:ok, pane} | {:refused, term} | {:unknown, term}
  def new_session(%mod{} = server, session, argv, opts \\ []) do
    cond do
      not session?(session) -> {:refused, {:bad_session, session}}
      not argv?(argv) -> {:refused, {:bad_argv, argv}}
      not size?(Keyword.get(opts, :size, {1, 1})) -> {:refused, {:bad_size, opts[:size]}}
      true -> mod.new_session(server, session, argv, opts)
    end
  end

  @doc "See the `c:list_panes/1` callback."
  @spec list_panes(server) :: {:ok, [pane_info]} | {:refused, term} | {:unknown, term}
  def list_panes(%mod{} = server), do: mod.list_panes(server)

  @doc "See the `c:list_clients/1` callback."
  @spec list_clients(server) :: {:ok, [client_info]} | {:refused, term} | {:unknown, term}
  def list_clients(%mod{} = server), do: mod.list_clients(server)

  @doc """
  See the `c:write/4` callback. Text goes out literally; a line is text and then Enter in the
  one command; keys are tmux key names such as `"Enter"` or `"C-c"`.
  """
  @spec write(server, pane, session, input) ::
          {:ok, :sent} | {:refused, term} | {:unknown, term}
  def write(%mod{} = server, pane, session, input) do
    cond do
      not pane?(pane) ->
        {:refused, {:bad_target, pane}}

      not session?(session) ->
        {:refused, {:bad_session, session}}

      match?({:paste, _, _}, input) ->
        with(:ok <- paste?(input), do: mod.write(server, pane, session, input))

      not input?(input) ->
        {:refused, {:bad_input, input}}

      true ->
        mod.write(server, pane, session, input)
    end
  end

  @doc """
  Whether `text` may be pasted (`c:write/4`'s `{:paste, buffer, text}`): `:ok`, or the
  refusal. It is valid UTF-8 and not empty, at most `paste_max/0` bytes, and holds no control
  character but newline and tab. An escape inside a bracketed paste could end the bracket
  early, and what follows would be read as keys, an Enter among them.

      iex> CodingAgentFramework.Tmux.paste_text("line one\\nline two")
      :ok
      iex> CodingAgentFramework.Tmux.paste_text("a\\e[201~b")
      {:refused, {:bad_text, :control}}
      iex> CodingAgentFramework.Tmux.paste_text(String.duplicate("x", 16_373))
      {:refused, {:too_long, 16372}}
  """
  @spec paste_text(term) :: :ok | {:refused, term}
  def paste_text(text) do
    cond do
      not is_binary(text) or text == "" -> {:refused, {:bad_text, :empty}}
      not String.valid?(text) -> {:refused, {:bad_text, :invalid}}
      byte_size(text) > paste_max() -> {:refused, {:too_long, paste_max()}}
      Regex.match?(~r/[\x00-\x08\x0b-\x1f\x7f]/, text) -> {:refused, {:bad_text, :control}}
      true -> :ok
    end
  end

  @doc """
  The most bytes one paste's text holds: `Shell.input_max/0` less the markers around it
  (`bracketed/1`), since the bracketed text goes to the load's stdin whole.

      iex> CodingAgentFramework.Tmux.paste_max()
      16372
  """
  @spec paste_max() :: pos_integer
  def paste_max,
    do: CodingAgentFramework.Shell.input_max() - byte_size(@paste_start <> @paste_end)

  @doc """
  `text` inside bracketed paste's markers, `ESC [200~` and `ESC [201~`, as a paste's buffer
  holds it (F-287). A program in bracketed mode takes all between them as typed text, so a
  newline in it does not submit. The framework brackets the text itself, since tmux brackets a
  paste (`paste-buffer -p`) only when its pane saw the program turn the mode on, and a pane
  that attached under dtach after the program started never did. `paste_text/1` refuses a
  text with an escape, so none can end the bracket early.

      iex> CodingAgentFramework.Tmux.bracketed("one\\ntwo")
      "\\e[200~one\\ntwo\\e[201~"
  """
  @spec bracketed(String.t()) :: String.t()
  def bracketed(text), do: @paste_start <> text <> @paste_end

  @doc "See the `c:capture/3` callback."
  @spec capture(server, pane, session) ::
          {:ok, %{text: String.t(), width: pos_integer}} | {:refused, term} | {:unknown, term}
  def capture(%mod{} = server, pane, session) do
    cond do
      not pane?(pane) -> {:refused, {:bad_target, pane}}
      not session?(session) -> {:refused, {:bad_session, session}}
      true -> mod.capture(server, pane, session)
    end
  end

  @doc "See the `c:kill_pane/3` callback."
  @spec kill_pane(server, pane, session) :: {:ok, :killed} | {:refused, term} | {:unknown, term}
  def kill_pane(%mod{} = server, pane, session) do
    cond do
      not pane?(pane) -> {:refused, {:bad_target, pane}}
      not session?(session) -> {:refused, {:bad_session, session}}
      true -> mod.kill_pane(server, pane, session)
    end
  end

  @doc "See the `c:respawn_pane/4` callback."
  @spec respawn_pane(server, pane, session, [String.t()]) ::
          {:ok, :respawned} | {:refused, term} | {:unknown, term}
  def respawn_pane(%mod{} = server, pane, session, argv) do
    cond do
      not pane?(pane) -> {:refused, {:bad_target, pane}}
      not session?(session) -> {:refused, {:bad_session, session}}
      not argv?(argv) -> {:refused, {:bad_argv, argv}}
      true -> mod.respawn_pane(server, pane, session, argv)
    end
  end

  @doc "See the `c:resize_pane/4` callback."
  @spec resize_pane(server, pane, session, {pos_integer, pos_integer}) ::
          {:ok, :resized} | {:refused, term} | {:unknown, term}
  def resize_pane(%mod{} = server, pane, session, size) do
    cond do
      not pane?(pane) -> {:refused, {:bad_target, pane}}
      not session?(session) -> {:refused, {:bad_session, session}}
      not size?(size) -> {:refused, {:bad_size, size}}
      true -> mod.resize_pane(server, pane, session, size)
    end
  end

  @doc "See the `c:kill_session/2` callback."
  @spec kill_session(server, session) :: {:ok, :killed} | {:refused, term} | {:unknown, term}
  def kill_session(%mod{} = server, session) do
    if session?(session),
      do: mod.kill_session(server, session),
      else: {:refused, {:bad_session, session}}
  end

  @doc "See the `c:kill_server/1` callback."
  @spec kill_server(server) :: {:ok, :killed} | {:refused, term} | {:unknown, term}
  def kill_server(%mod{} = server), do: mod.kill_server(server)

  defp pane?(pane), do: is_binary(pane) and pane =~ @pane
  defp session?(session), do: is_binary(session) and session =~ @session
  defp size?({c, r}), do: is_integer(c) and c > 0 and is_integer(r) and r > 0
  defp size?(_), do: false
  defp argv?(argv), do: is_list(argv) and argv != [] and Enum.all?(argv, &is_binary/1)

  defp input?({kind, text}) when kind in [:text, :line],
    do: is_binary(text) and text != "" and String.valid?(text)

  defp input?({:keys, [_ | _] = keys}),
    do: Enum.all?(keys, &(is_binary(&1) and &1 =~ @key))

  defp input?(_), do: false

  defp paste?({:paste, buffer, text}) do
    if is_binary(buffer) and buffer =~ @buffer,
      do: paste_text(text),
      else: {:refused, {:bad_buffer, buffer}}
  end
end
