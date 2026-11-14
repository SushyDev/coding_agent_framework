defmodule CodingAgentFramework.Recoveries do
  @moduledoc """
  Detects a broken state on one host, acts once per state, and verifies from a later sample
  (`model/tla/Agent.tla`, `RecoveryClaims`, `RecoveryActs`, `RecoveriesRestart`). It writes
  `CodingAgentFramework.Recoveries.Table`, which it alone writes.

  The caller's supervision tree starts one per host, with no name, given the host's
  `TmuxSampler`, `Control`, `Holder` and tmux server (for its key). It reads the sampler's rows,
  never a pane's screen: by `check/2`, or after `cue/1`, which the sampler's `notify` can call.

  **The first recovery is a lost viewer**: a held socket the sampler reads `:unviewed` or
  `:no_server` (its socket live). A state is keyed by the socket, the sampler's generation, and
  `since`: when the sampler's row took that status, or when this part's own last open of the
  socket's viewer answered with a pane, whichever is later. So a viewer lost again after a
  reopen is a new state, and a reading taken before that open is not acted on.

  A state's row is written first (the claim), then acted on, so each state is acted on at most
  once, across restarts of this process: a row left `claimed` by a process that ended before its
  act is never acted on, and ends `unknown{interrupted}` unless the agent is viewed. The act
  opens the viewer through `Sessions.viewer/4` (`dtach -a`, tagged as it opens, one row short,
  then grown); tmux starts the server again when it is down. A refused open ends the state
  `failed`, and the agent runs on. Otherwise the first sample whose reads began after the act
  decides: `recovered` when the agent is viewed, `failed{not_viewed}` when it is not, and
  `unknown` when its socket is gone or stale, or the open's answer was unknown. Nothing is
  retried within a state. A stale socket is not reopened.

  After each write it calls `notify` with `%{topic: "recoveries:<host>:<server>", ids: ids}`.

      iex> read = %{generation: 2, read_at: 50, rows: [
      ...>   %{kind: :held, name: "alpha", socket: :live, status: :unviewed, written_at: 40}]}
      iex> [state] = CodingAgentFramework.Recoveries.lost_viewers(read, %{})
      iex> state.key
      "lost_viewer:alpha:2:40"
      iex> CodingAgentFramework.Recoveries.lost_viewers(read, %{"alpha" => 45})
      [%{key: "lost_viewer:alpha:2:45", kind: "lost_viewer", socket: "alpha", generation: 2, since: 45}]
      iex> CodingAgentFramework.Recoveries.lost_viewers(read, %{"alpha" => 50})
      []
  """

  use GenServer

  alias CodingAgentFramework.{Holder, Sessions, Tmux, TmuxSampler}
  alias CodingAgentFramework.Recoveries.Table

  @timeout 60_000
  @lost [:unviewed, :no_server]

  @doc """
  Starts a `Recoveries`. Options: `sampler:` (the host's `TmuxSampler`), `control:` (its
  `Control`), `holder:` (its `Holder`), `server:` (its `Tmux` server, for the key), `db:`, and
  optionally `notify:` and `size:` (a viewer's `{columns, rows}`, default `{200, 50}`). It fails
  to start with `{:host_mismatch, server_host, holder_host}`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Reads the sampler's last good sample, ends the states it verifies, and claims and acts on the
  new ones. Answers `{:ok, %{claimed: ids, ended: ids}}`, `:unread` before a sample,
  `{:refused, :sample_failed}` while the newest sample failed, or the sampler's own refusal or
  unknown. Option: `:timeout`.
  """
  @spec check(GenServer.server(), keyword) ::
          {:ok, map} | :unread | {:refused, term} | {:unknown, term}
  def check(recoveries, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    try do
      GenServer.call(recoveries, :check, timeout)
    catch
      :exit, {:noproc, _} -> {:refused, :no_recoveries}
      :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
      :exit, {reason, _} -> {:unknown, {:exit, reason}}
    end
  end

  @doc "Asks for a check without waiting for it: the sampler's cue."
  @spec cue(pid) :: :ok
  def cue(recoveries) do
    send(recoveries, :check)
    :ok
  end

  @doc """
  The lost-viewer states in a sample `read`, given each socket's last open that answered with a
  pane (`Table.last_opened/3`). Pure. A reading whose reads began no later than that open says
  nothing of it, and gives no state.
  """
  @spec lost_viewers(map, %{String.t() => integer}) :: [map]
  def lost_viewers(read, last_opened) do
    for %{kind: :held, socket: :live, status: status, name: name} = row <- read.rows,
        status in @lost,
        {:ok, opened} <- [after_open(read, Map.get(last_opened, name))] do
      since = max(row.written_at, opened || 0)

      %{
        key: "lost_viewer:#{name}:#{read.generation}:#{since}",
        kind: "lost_viewer",
        socket: name,
        generation: read.generation,
        since: since
      }
    end
  end

  defp after_open(_read, nil), do: {:ok, nil}
  defp after_open(%{read_at: at}, opened) when at > opened, do: {:ok, opened}
  defp after_open(_read, _opened), do: :before_open

  @impl true
  def init(opts) do
    {host, server} = Tmux.key(Keyword.fetch!(opts, :server))
    %Holder{} = holder = Keyword.fetch!(opts, :holder)

    with :ok <- same_host(host, holder.host.name),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      {:ok,
       %{
         host: host,
         server: server,
         holder: holder,
         db: db,
         sampler: Keyword.fetch!(opts, :sampler),
         control: Keyword.fetch!(opts, :control),
         notify: Keyword.get(opts, :notify, fn _ -> :ok end),
         size: Keyword.get(opts, :size, {200, 50})
       }}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  defp same_host(host, host), do: :ok
  defp same_host(a, b), do: {:refused, {:host_mismatch, a, b}}

  @impl true
  def handle_call(:check, _from, state), do: {:reply, check_now(state), state}

  @impl true
  def handle_info(:check, state) do
    check_now(state)
    {:noreply, state}
  end

  defp check_now(state) do
    case TmuxSampler.rows(state.sampler) do
      {:ok, %{failed_at: at}} when is_integer(at) ->
        {:refused, :sample_failed}

      {:ok, read} ->
        ended = verify(state, read)
        last = Table.last_opened(state.db, state.host, state.server)

        claimed =
          for lost <- lost_viewers(read, last),
              {:ok, id} <- [claim(state, lost)],
              do: act(state, id, lost)

        {:ok, %{claimed: claimed, ended: ended}}

      other ->
        other
    end
  end

  defp claim(state, lost) do
    with {:ok, id} = claimed <-
           Table.claim(
             state.db,
             Map.merge(lost, %{host: state.host, server: state.server}),
             now()
           ) do
      cue(state, [id])
      claimed
    end
  end

  defp act(state, id, %{socket: name}) do
    answer =
      with {:ok, argv} <- Holder.viewer_argv(state.holder, name),
           do: Sessions.viewer(state.control, name, argv, state.size)

    fields =
      case answer do
        {:ok, pane} -> [status: "opened", pane: pane, open: "ok", opened_at: now()]
        {:refused, why} -> [status: "failed", reason: why, open: answer, ended_at: now()]
        _ -> [status: "opened", open: answer, opened_at: now()]
      end

    write(state, id, fields)
    id
  end

  # Each open state, against the first sample whose reads began after its act (or its claim,
  # when no act followed).
  defp verify(state, read) do
    held = for %{kind: :held} = row <- read.rows, into: %{}, do: {row.name, row}

    for row <- Table.open_rows(state.db, state.host, state.server),
        read.read_at > (row.opened_at || row.claimed_at) do
      {status, reason} = outcome(row, held[row.socket])
      write(state, row.id, status: status, reason: reason, ended_at: now())
      row.id
    end
  end

  defp outcome(_row, %{status: :viewed}), do: {"recovered", nil}
  defp outcome(_row, nil), do: {"unknown", :agent_gone}
  defp outcome(_row, %{status: :stale}), do: {"unknown", :stale}
  defp outcome(%{status: "claimed"}, _), do: {"unknown", :interrupted}
  defp outcome(%{open: "ok"}, _), do: {"failed", :not_viewed}
  defp outcome(%{open: open}, _), do: {"unknown", {:open, open}}

  defp write(state, id, fields) do
    Table.update(state.db, id, fields)
    cue(state, [id])
  end

  defp cue(state, ids),
    do: state.notify.(%{topic: "recoveries:#{state.host}:#{state.server}", ids: ids})

  defp now, do: System.os_time(:millisecond)
end
