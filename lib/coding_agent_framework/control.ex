defmodule CodingAgentFramework.Control do
  @moduledoc """
  The one writer per host: the only caller of `CodingAgentFramework.Tmux.write/4` for its host's
  tmux server.

  The caller's supervision tree starts one `Control` per host, with no name of its own. It keeps,
  for each session, the pane id it was given when it opened that session's pane (`open/4`). A
  call names a session, and goes out only to that session's kept pane, through the one tmux
  command that checks the pane's tag and acts (`model/tla/Agent.tla`, `WriteAsked`). An id kept
  from before a server restart that now names another session's pane is refused, not sent.

      iex> {:ok, fake} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(fake, {"laptop", "fake"})
      iex> {:ok, control} = CodingAgentFramework.Control.start_link(tmux: server)
      iex> {:ok, _pane} = CodingAgentFramework.Control.open(control, "alpha", ["/bin/cat"])
      iex> CodingAgentFramework.Control.send(control, "alpha", "hello")
      {:ok, :sent}
      iex> CodingAgentFramework.Control.send(control, "beta", "hello")
      {:refused, :no_kept_pane}

  Calls are served one at a time, in the order they arrive. Each answers `{:ok, …}`,
  `{:refused, reason}` or `{:unknown, reason}`. An unknown outcome is never retried: tmux exits 0
  for a key that reached nothing, so a resend could type twice. Every call has a finite timeout
  (`:timeout`, 15 s by default); a call past it answers `{:unknown, {:timeout, ms}}`, and a
  request still queued when its time is up is dropped unsent.

  Two calls come later: "answer", which goes to the held `PermissionRequest` hook (`Intake`), and
  typing only when the turn has ended and the input box is empty, which needs `Screen`.
  """

  use GenServer

  alias CodingAgentFramework.Tmux

  @timeout 15_000

  @type session :: Tmux.session()
  @type outcome(ok) :: {:ok, ok} | {:refused, term} | {:unknown, term}

  @doc "Starts a `Control` for one host's tmux server. `opts`: `tmux:` the server (required)."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :tmux))

  @doc """
  Opens `session`'s pane running `argv`, tagged with `session` as it opens, and keeps its id.
  A later open of the same session (after its server restarted) keeps the new id.
  """
  @spec open(GenServer.server(), session, [String.t()], keyword) :: outcome(Tmux.pane())
  def open(control, session, argv, opts \\ []), do: call(control, {:open, session, argv}, opts)

  @doc "Types `text` and then Enter into the session's pane, in one tmux command."
  @spec send(GenServer.server(), session, String.t(), keyword) :: outcome(:sent)
  def send(control, session, text, opts \\ []), do: call(control, {:send, session, text}, opts)

  @doc "Sends one `C-c` to the session's pane; never two in one call, since two exit Claude Code."
  @spec interrupt(GenServer.server(), session, keyword) :: outcome(:sent)
  def interrupt(control, session, opts \\ []), do: call(control, {:interrupt, session}, opts)

  @doc "Ends the session's pane and forgets its id once it is ended."
  @spec stop(GenServer.server(), session, keyword) :: outcome(:killed)
  def stop(control, session, opts \\ []), do: call(control, {:stop, session}, opts)

  @doc "Starts `argv` again in the session's pane. The pane keeps its id and its tag."
  @spec respawn(GenServer.server(), session, [String.t()], keyword) :: outcome(:respawned)
  def respawn(control, session, argv, opts \\ []),
    do: call(control, {:respawn, session, argv}, opts)

  defp call(control, request, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      GenServer.call(control, {request, deadline}, timeout)
    catch
      # A Control that is not there sent nothing; one that ended or stalled mid-call may have.
      :exit, {:noproc, _} -> {:refused, :no_control}
      :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
      :exit, {reason, _} -> {:unknown, {:exit, reason}}
    end
  end

  @impl true
  def init(tmux), do: {:ok, %{tmux: tmux, panes: %{}}}

  @impl true
  def handle_call({request, deadline}, _from, state) do
    # The caller has already answered itself unknown; acting now would act late.
    if System.monotonic_time(:millisecond) >= deadline do
      {:reply, {:refused, :expired}, state}
    else
      {reply, state} = act(request, state)
      {:reply, reply, state}
    end
  end

  defp act({:open, session, argv}, %{tmux: tmux} = state) do
    case Tmux.new_session(tmux, session, argv) do
      {:ok, pane} -> {{:ok, pane}, put_in(state.panes[session], pane)}
      other -> {other, state}
    end
  end

  defp act({:send, session, text}, state),
    do: on_pane(state, session, &Tmux.write(&1, &2, session, {:line, text}))

  defp act({:interrupt, session}, state),
    do: on_pane(state, session, &Tmux.write(&1, &2, session, {:keys, ["C-c"]}))

  defp act({:respawn, session, argv}, state),
    do: on_pane(state, session, &Tmux.respawn_pane(&1, &2, session, argv))

  defp act({:stop, session}, state) do
    case on_pane(state, session, &Tmux.kill_pane(&1, &2, session)) do
      {{:ok, :killed}, state} ->
        {{:ok, :killed}, update_in(state.panes, &Map.delete(&1, session))}

      other ->
        other
    end
  end

  defp on_pane(%{tmux: tmux, panes: panes} = state, session, fun) do
    case panes do
      %{^session => pane} -> {fun.(tmux, pane), state}
      _ -> {{:refused, :no_kept_pane}, state}
    end
  end
end
