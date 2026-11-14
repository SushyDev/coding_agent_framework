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

  @type server :: struct
  @type key :: {host :: String.t(), server :: String.t()}
  @type pane :: String.t()
  @type session :: String.t()
  @type input :: {:text, String.t()} | {:line, String.t()} | {:keys, [String.t()]}
  @type pane_info :: %{pane: pane, session: session, tag: session | nil}

  @doc "The `{host, server}` that names this server."
  @callback key(server) :: key

  @doc """
  Opens a detached session named `session` whose one pane runs `argv` and is tagged with
  `session` in the same tmux command. Starts the server when none runs. Option: `size:
  {columns, rows}`, the window's size.
  """
  @callback new_session(server, session, argv :: [String.t()], opts :: keyword) ::
              {:ok, pane} | {:refused, term} | {:unknown, term}

  @doc "Every pane on the server, with its session and its tag."
  @callback list_panes(server) :: {:ok, [pane_info]} | {:refused, term} | {:unknown, term}

  @doc """
  Sends `input` to `pane` only when the pane's tag names `session`, in one tmux command.

  Refusals: `:no_server`, `:no_pane`, `:untagged`, `{:tagged_for, other}`.
  """
  @callback write(server, pane, session, input) ::
              {:ok, :sent} | {:refused, term} | {:unknown, term}

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
  @session ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @key ~r/\A[A-Za-z0-9-]{1,32}\z/

  @doc "The `{host, server}` of a server."
  @spec key(server) :: key
  def key(%mod{} = server), do: mod.key(server)

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

  @doc """
  See the `c:write/4` callback. Text goes out literally; a line is text and then Enter in the
  one command; keys are tmux key names such as `"Enter"` or `"C-c"`.
  """
  @spec write(server, pane, session, input) ::
          {:ok, :sent} | {:refused, term} | {:unknown, term}
  def write(%mod{} = server, pane, session, input) do
    cond do
      not pane?(pane) -> {:refused, {:bad_target, pane}}
      not session?(session) -> {:refused, {:bad_session, session}}
      not input?(input) -> {:refused, {:bad_input, input}}
      true -> mod.write(server, pane, session, input)
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
end
