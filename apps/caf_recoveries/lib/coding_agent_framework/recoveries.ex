defmodule CodingAgentFramework.Recoveries do
  @moduledoc """
  Detects a broken state on one host, acts once per state, and verifies from a later sample
  (`model/tla/Agent.tla`, `RecoveryClaims`, `RecoveryActs`, `RecoveriesRestart`,
  `PersonClears`). It writes `CodingAgentFramework.Recoveries.Table`, which it alone writes.

  The caller's supervision tree starts one per host, with no name, given the host's
  `TmuxSampler`, `Control`, `Holder` and tmux server (for its key). It reads the sampler's rows,
  never a pane's screen: by `check/2`, or after `cue/1`, which the sampler's `notify` can call.

  **The first recovery is a lost viewer**: a held socket the sampler reads `:unviewed` or
  `:no_server` (its socket live). A state is keyed by the socket, the sampler's generation, and
  `since`: when the sampler's row took that status, or when this part last opened the socket's
  viewer (an open answered with a pane, or refused because the session exists) or a person
  cleared it, whichever is later. So a viewer lost again after a reopen is a new state, and a
  reading taken before that open is not acted on.

  **Two samples agree**: the sampler reads the panes and then the sockets, so a viewer opened
  between the two reads shows as lost for one sample. A state is acted on only when the last
  two samples this process checked, with two different `read_at`s, both read it. A restarted
  `Recoveries` holds no sample, so it waits for two more.

  **A sample too old is not acted on**: one older than `max_age` (default 30 s) ends nothing
  and claims nothing. Each loss it reads gets a `skipped` row whose reason says why; a later
  claim of that state takes the row over.

  A state's row is written first (the claim), then acted on, so each state is acted on at most
  once, across restarts of this process: a row left `claimed` by a process that ended before its
  act is never acted on, and ends `unknown{interrupted}` unless the agent is viewed. The act
  opens the viewer through `Sessions.viewer/4` (`dtach -a`, tagged as it opens, one row short,
  then grown); tmux starts the server again when it is down. A refused open ends the state
  `failed`, and the agent runs on; one refused because the session exists (another part opened
  a viewer since the samples) ends `unknown{session_exists}`. Otherwise the first sample whose
  reads began after the act decides: `recovered` when the agent is viewed, `failed{not_viewed}`
  when it is not, and `unknown` when its socket is gone or stale, or the open's answer was
  unknown. Nothing is retried within a state. A stale socket is not reopened.

  **Repeating losses**: the third loss of one socket within `window` (default 60 s) since a
  person last cleared it ends `failed{repeating}` with no act, and that socket's losses are not
  claimed again until `clear/2`.

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
  optionally `notify:`, `size:` (a viewer's `{columns, rows}`, default `{200, 50}`), `max_age:`
  (ms, default 30 000), `window:` (ms, default 60 000) and `clock:` (a function answering the
  time in ms, by default the system's; give the sampler the same one). It fails to start with
  `{:host_mismatch, server_host, holder_host}`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Reads the sampler's last good sample, ends the states it verifies, and claims and acts on the
  states it and the sample before it both read. Answers `{:ok, %{claimed: ids, ended: ids}}`,
  `:unread` before a sample, `{:refused, :sample_failed}` while the newest sample failed,
  `{:refused, {:sample_too_old, age_ms}}`, or the sampler's own refusal or unknown. Option:
  `:timeout`.
  """
  @spec check(GenServer.server(), keyword) ::
          {:ok, map} | :unread | {:refused, term} | {:unknown, term}
  def check(recoveries, opts \\ []), do: call(recoveries, :check, opts)

  @doc """
  A person clears socket `socket` after its losses repeated: its losses are acted on again, and
  a loss read after the clear is a new one. Answers `{:ok, ids}` (the rows marked cleared) or
  `{:refused, :not_repeating}`. Option: `:timeout`.
  """
  @spec clear(GenServer.server(), String.t(), keyword) ::
          {:ok, [integer]} | {:refused, term} | {:unknown, term}
  def clear(recoveries, socket, opts \\ []), do: call(recoveries, {:clear, socket}, opts)

  @doc "Asks for a check without waiting for it: the sampler's cue."
  @spec cue(pid) :: :ok
  def cue(recoveries) do
    send(recoveries, :check)
    :ok
  end

  defp call(recoveries, message, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    try do
      GenServer.call(recoveries, message, timeout)
    catch
      :exit, {:noproc, _} -> {:refused, :no_recoveries}
      :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
      :exit, {reason, _} -> {:unknown, {:exit, reason}}
    end
  end

  @doc """
  The lost-viewer states in a sample `read`, given each socket's last open or clear
  (`Table.last_opened/3`). Pure. A reading whose reads began no later than that open says
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
         size: Keyword.get(opts, :size, {200, 50}),
         max_age: Keyword.get(opts, :max_age, 30_000),
         window: Keyword.get(opts, :window, 60_000),
         clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
         # The keys of the lost viewers in the last two samples checked, by `read_at`.
         last: nil,
         before: nil
       }}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  defp same_host(host, host), do: :ok
  defp same_host(a, b), do: {:refused, {:host_mismatch, a, b}}

  @impl true
  def handle_call(:check, _from, state) do
    {reply, state} = check_now(state)
    {:reply, reply, state}
  end

  def handle_call({:clear, socket}, _from, state) do
    reply =
      case Table.clear(state.db, state.host, state.server, socket, now(state)) do
        [] ->
          {:refused, :not_repeating}

        ids ->
          cue(state, ids)
          {:ok, ids}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:check, state) do
    {_, state} = check_now(state)
    {:noreply, state}
  end

  defp check_now(state) do
    case TmuxSampler.rows(state.sampler) do
      {:ok, %{failed_at: at}} when is_integer(at) ->
        {{:refused, :sample_failed}, state}

      {:ok, read} ->
        age = now(state) - read.read_at
        repeating = Table.repeating(state.db, state.host, state.server)
        last = Table.last_opened(state.db, state.host, state.server)
        lost = for l <- lost_viewers(read, last), l.socket not in repeating, do: l

        if age > state.max_age,
          do: skip(state, lost, age),
          else: act_on(state, read, lost)

      other ->
        {other, state}
    end
  end

  defp skip(state, lost, age) do
    reason = {:sample_too_old, age}

    ids =
      for l <- lost,
          {:ok, id} <- [Table.skip(state.db, row(state, l), now(state), reason)],
          do: id

    if ids != [], do: cue(state, ids)
    {{:refused, reason}, state}
  end

  defp act_on(state, read, lost) do
    ended = verify(state, read)
    state = remember(state, read.read_at, MapSet.new(lost, & &1.key))
    agreed = for l <- lost, state.before && MapSet.member?(state.before.keys, l.key), do: l

    claimed =
      for l <- agreed,
          prior = losses(state, l.socket),
          {:ok, id} <- [claim(state, l)],
          do: act(state, id, l, prior)

    {{:ok, %{claimed: claimed, ended: ended}}, state}
  end

  # A sample checked again (the same `read_at`) leaves the last two as they were.
  defp remember(%{last: %{read_at: at}} = state, at, _keys), do: state

  defp remember(state, at, keys),
    do: %{state | before: state.last, last: %{read_at: at, keys: keys}}

  defp losses(state, socket),
    do: Table.losses(state.db, state.host, state.server, socket, now(state) - state.window)

  defp claim(state, lost) do
    with {:ok, id} = claimed <- Table.claim(state.db, row(state, lost), now(state)) do
      cue(state, [id])
      claimed
    end
  end

  defp row(state, lost), do: Map.merge(lost, %{host: state.host, server: state.server})

  # The third loss in the window: the row says so, and nothing is opened.
  defp act(state, id, _lost, prior) when prior >= 2 do
    write(state, id, status: "failed", reason: :repeating, ended_at: now(state))
    id
  end

  defp act(state, id, %{socket: name}, _prior) do
    answer =
      with {:ok, argv} <- Holder.viewer_argv(state.holder, name),
           do: Sessions.viewer(state.control, name, argv, state.size)

    at = now(state)

    fields =
      case answer do
        {:ok, pane} ->
          [status: "opened", pane: pane, open: "ok", opened_at: at]

        # A viewer opened since the samples: it counts as an open, so a later loss is new.
        {:refused, {:session_exists, _}} ->
          [
            status: "unknown",
            reason: :session_exists,
            open: "exists",
            opened_at: at,
            ended_at: at
          ]

        {:refused, why} ->
          [status: "failed", reason: why, open: answer, ended_at: at]

        _ ->
          [status: "opened", open: answer, opened_at: at]
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
      write(state, row.id, status: status, reason: reason, ended_at: now(state))
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

  defp now(state), do: state.clock.()
end
