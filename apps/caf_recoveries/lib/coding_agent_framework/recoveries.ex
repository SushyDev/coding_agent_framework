defmodule CodingAgentFramework.Recoveries do
  @moduledoc """
  Detects a broken state on one host, acts once per state, and verifies from a later sample
  (`model/tla/Agent.tla`, `RecoveryClaims`, `RecoveryActs`, `RecoveriesRestart`,
  `PersonClears`). It keeps no table of its own: each state it acts on is a row in
  `CodingAgentFramework.Acts`, under the actor `recoveries:<host>:<server>`, and `Acts` cues it.

  The caller's supervision tree starts one per host, with no name, given the host's
  `TmuxSampler`, `Control`, `Holder`, `Sessions`, tmux server (for its key) and the instance's
  `Acts`. It reads the sampler's rows, never a pane's screen: by `check/2`, or after `cue/1`,
  which the sampler's `notify` can call.

  **The first recovery is a lost viewer** (act `reopen`): a held socket the sampler reads
  `:unviewed` or `:no_server` (its socket live). A state is keyed by the socket, the sampler's
  generation, and `since`: when the sampler's row took that status, or when this part last
  opened the socket's viewer (an open answered with a pane, or refused because the session
  exists) or a person cleared it, whichever is later. So a viewer lost again after a reopen is
  a new state, and a reading taken before that open is not acted on.

  **Two samples agree**: the sampler reads the panes and then the sockets, so a viewer opened
  between the two reads shows as lost for one sample. A state is acted on only when the last
  two samples this process checked, with two different `read_at`s, both read it. A restarted
  `Recoveries` holds no sample, so it waits for two more.

  **A sample too old is not acted on**: one older than `max_age` (default 30 s) ends nothing
  and claims nothing. Each loss it reads gets a `skipped` row whose reason says why; a later
  claim of that state takes the row over.

  A state's row is written first (the claim), then acted on, so each state is acted on at most
  once, across restarts of this process: a row a restart left `claimed` is closed
  `interrupted` when this process starts (`Acts.interrupt/3`), and never acted on. The act asks
  the host's `Sessions` for the viewer's command (`Sessions.viewer_argv/3`: `dtach -a` for an
  interactive session, the log-following command for a delegate) and opens the viewer with it
  through `Sessions.viewer/4` (tagged as it opens, one row short, then grown); tmux starts the
  server again when it is down. A refused open settles the state `failed`, and the agent runs
  on, as does a command `Sessions` refuses or cannot answer (no row of that name, or no answer
  in time): nothing was opened. One refused because the session exists (another part opened
  a viewer since the samples) settles `unknown{session_exists}`. Otherwise the row is `acted`,
  and the first sample whose reads began after the act decides: `recovered` when the agent is
  viewed, `failed{not_viewed}` when it is not, and `unknown` when its socket is gone or stale,
  or the open's answer was unknown. Nothing is retried within a state. A stale socket is not
  reopened.

  **Repeating losses**: the third loss of one socket within `window` (default 60 s) since a
  person last cleared it settles `failed{repeating}` with no act, and that socket's losses are
  not claimed again until `clear/2`.

  **The second recovery is an end owed** (F-118, `model/tla/Start.tla`'s `Kill`; act `end`): the
  process of an `orphan` row of `Sessions`, or of a stop whose deadline passed with it alive,
  which `Sessions.ends_owed/2` names with its pid and start time. Its state is keyed by the
  name, the pid, the start time and the last clear of the agent's ends; its row is claimed
  first, then the process is ended by that record alone (`Holder.Process.end_held/5`: TERM, then
  KILL at `end_grace`, default 5 s), and the row settles `recovered` once the program reads
  dead, or `unknown` with what was read. An end that settled `unknown` waits for a person, as a
  repeating loss does (F-118's new-5): its state stays claimed until `clear/2` names a new one.
  `Sessions` settles its own row at the next cue, once the process is gone and its socket dead.
  `Sessions` itself never kills.

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

  alias CodingAgentFramework.{Acts, Holder, Sessions, Tmux, TmuxSampler}

  @timeout 60_000
  @lost [:unviewed, :no_server]

  @doc """
  Starts a `Recoveries`. Options: `sampler:` (the host's `TmuxSampler`), `control:` (its
  `Control`), `holder:` (its `Holder`), `programs:` (its `Programs`, with ps, kill and sleep,
  for `Holder.Process`), `sessions:` (its `Sessions`, which answers each viewer's command and
  the ends owed), `server:` (its `Tmux` server, for the key), `acts:` (the instance's `Acts`),
  and optionally `size:` (a viewer's `{columns, rows}`, default `{200, 50}`), `max_age:` (ms,
  default 30 000), `window:` (ms, default 60 000), `end_grace:` (ms between an end's TERM and
  its KILL, default 5 000) and `clock:` (a function answering the time in ms, by default the
  system's; give the sampler and `Acts` the same one). It fails to start with
  `{:host_mismatch, server_host, holder_host}`, or `Acts`' answer when it cannot close the rows
  a restart cut.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Reads the sampler's last good sample, ends the states it verifies, and claims and acts on the
  states it and the sample before it both read. Answers `{:ok, %{claimed: ids, ended: ids, ends:
  ids}}`, `:unread` before a sample, `{:refused, :sample_failed}` while the newest sample failed,
  `{:refused, {:sample_too_old, age_ms}}`, the sampler's own refusal or unknown, or `Acts`'.
  Option: `:timeout`.
  """
  @spec check(GenServer.server(), keyword) ::
          {:ok, map} | :unread | {:refused, term} | {:unknown, term}
  def check(recoveries, opts \\ []), do: call(recoveries, :check, opts)

  @doc """
  A person clears socket `socket`'s states that wait for one: losses that repeated, and an end
  that settled `unknown`. Its losses are acted on again, a loss read after the clear is a new
  one, and its end owed is a new state. Answers `{:ok, ids}` (the rows marked cleared) or
  `{:refused, :not_waiting}`. Option: `:timeout`.
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
  The lost-viewer states in a sample `read`, given each socket's last open or clear. Pure. A
  reading whose reads began no later than that open says nothing of it, and gives no state.
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

  @doc """
  From one actor's rows in `Acts`: the sockets whose losses repeated and wait for a person.

      iex> CodingAgentFramework.Recoveries.repeating([
      ...>   %{act: "reopen", target: "a", outcome: "failed", reason: "repeating", cleared_at: nil},
      ...>   %{act: "reopen", target: "b", outcome: "failed", reason: "repeating", cleared_at: 9}])
      ["a"]
  """
  @spec repeating([map]) :: [String.t()]
  def repeating(rows) do
    for(r <- rows, r.act == "reopen", repeating?(r), is_nil(r.cleared_at), do: r.target)
    |> Enum.uniq()
  end

  defp repeating?(r), do: r.outcome == "failed" and r.reason == "repeating"

  @impl true
  def init(opts) do
    {host, server} = Tmux.key(Keyword.fetch!(opts, :server))
    %Holder{} = holder = Keyword.fetch!(opts, :holder)
    acts = Keyword.fetch!(opts, :acts)
    actor = "recoveries:#{host}:#{server}"

    # A claim this actor wrote and did not act on: the restart cut it, and it is never acted on.
    with :ok <- same_host(host, holder.host.name),
         {:ok, procs} <- Holder.Process.new(Keyword.fetch!(opts, :programs), holder),
         {:ok, _} <- Acts.interrupt(acts, actor) do
      {:ok,
       %{
         host: host,
         server: server,
         actor: actor,
         acts: acts,
         procs: procs,
         end_grace: Keyword.get(opts, :end_grace, 5_000),
         sampler: Keyword.fetch!(opts, :sampler),
         control: Keyword.fetch!(opts, :control),
         sessions: Keyword.fetch!(opts, :sessions),
         size: Keyword.get(opts, :size, {200, 50}),
         max_age: Keyword.get(opts, :max_age, 30_000),
         window: Keyword.get(opts, :window, 60_000),
         clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
         # The keys of the lost viewers in the last two samples checked, by `read_at`.
         last: nil,
         before: nil
       }}
    else
      {_, reason} -> {:stop, reason}
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
      with {:ok, rows} <- Acts.rows(state.acts, actor: state.actor, target: socket) do
        case for(r <- rows, waits?(r), do: r.id) do
          [] -> {:refused, :not_waiting}
          ids -> Acts.clear(state.acts, ids)
        end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:check, state) do
    {_, state} = check_now(state)
    {:noreply, state}
  end

  # A row that waits for a person: a loss that repeated, or an end that settled unknown.
  defp waits?(%{cleared_at: nil, act: "reopen"} = r), do: repeating?(r)
  defp waits?(%{cleared_at: nil, act: "end", outcome: "unknown"}), do: true
  defp waits?(_), do: false

  defp check_now(state) do
    with {:ok, rows} <- Acts.rows(state.acts, actor: state.actor) do
      ends = end_owed(state, rows)

      case check_viewers(state, Enum.filter(rows, &(&1.act == "reopen"))) do
        {{:ok, done}, state} -> {{:ok, Map.put(done, :ends, ends)}, state}
        other -> other
      end
    else
      other -> {other, state}
    end
  end

  # Each end owed, once per state: claimed, ended by the record alone, then the row settles.
  defp end_owed(state, rows) do
    case Sessions.ends_owed(state.sessions) do
      {:ok, owed} ->
        for o <- owed, {:ok, id} <- [claim(state, o.socket, end_key(state, o, rows), :end)] do
          case Holder.Process.end_held(state.procs, o.socket, o.record, state.end_grace) do
            {:ok, :ended} ->
              Acts.settle(state.acts, id, :recovered, answer: "ended", acted: true)

            {:unknown, why} ->
              Acts.settle(state.acts, id, :unknown, reason: why, answer: "unknown", acted: true)
          end

          id
        end

      _unread ->
        []
    end
  end

  # After a person's clear, the same process is a new state, so an end that failed is tried
  # once more.
  defp end_key(state, %{name: name, socket: socket, record: %{pid: pid, start: start}}, rows) do
    cleared =
      for(%{act: "end", target: ^socket, cleared_at: at} <- rows, at, do: at)
      |> Enum.max(fn -> nil end)

    key = "end:#{name}:#{pid}:#{Holder.Process.normal(start)}"
    scoped(state, if(cleared, do: "#{key}:cleared:#{cleared}", else: key))
  end

  defp scoped(state, key), do: "#{state.host}:#{state.server}:#{key}"

  defp check_viewers(state, rows) do
    case TmuxSampler.rows(state.sampler) do
      {:ok, %{failed_at: at}} when is_integer(at) ->
        {{:refused, :sample_failed}, state}

      {:ok, read} ->
        age = now(state) - read.read_at
        repeating = repeating(rows)
        lost = for l <- lost_viewers(read, last_opened(rows)), l.socket not in repeating, do: l

        if age > state.max_age,
          do: skip(state, lost, age),
          else: act_on(state, read, lost, rows)

      other ->
        {other, state}
    end
  end

  # Per socket, the newest of these: an open that answered with a pane (`ok`), an open refused
  # because the session exists (`exists`; a viewer existed then), and a person's clear. A loss
  # read after it is a new one.
  defp last_opened(rows) do
    opens = for %{answer: a, acted_at: at} = r <- rows, a in ["ok", "exists"], do: {r.target, at}
    clears = for %{cleared_at: at} = r <- rows, at, do: {r.target, at}
    Enum.reduce(opens ++ clears, %{}, fn {s, at}, acc -> Map.update(acc, s, at, &max(&1, at)) end)
  end

  defp skip(state, lost, age) do
    reason = {:sample_too_old, age}

    for l <- lost,
        do: Acts.skip(state.acts, state.actor, l.socket, scoped(state, l.key), :reopen, reason)

    {{:refused, reason}, state}
  end

  defp act_on(state, read, lost, rows) do
    ended = verify(state, read, rows)
    state = remember(state, read.read_at, MapSet.new(lost, & &1.key))
    agreed = for l <- lost, state.before && MapSet.member?(state.before.keys, l.key), do: l

    claimed =
      for l <- agreed,
          prior = losses(state, rows, l.socket),
          {:ok, id} <- [claim(state, l.socket, scoped(state, l.key), :reopen)],
          do: act(state, id, l, prior)

    {{:ok, %{claimed: claimed, ended: ended}}, state}
  end

  # A sample checked again (the same `read_at`) leaves the last two as they were.
  defp remember(%{last: %{read_at: at}} = state, at, _keys), do: state

  defp remember(state, at, keys),
    do: %{state | before: state.last, last: %{read_at: at, keys: keys}}

  # How many states of `socket` were claimed within the window, and after a person last cleared
  # it: the losses a new one is counted against.
  defp losses(state, rows, socket) do
    mine = for %{target: ^socket} = r <- rows, do: r

    cleared =
      mine |> Enum.map(& &1.cleared_at) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> -1 end)

    from = now(state) - state.window

    Enum.count(
      mine,
      &(&1.status != "skipped" and &1.claimed_at >= from and &1.claimed_at > cleared)
    )
  end

  defp claim(state, target, key, act), do: Acts.claim(state.acts, state.actor, target, key, act)

  # The third loss in the window: the row says so, and nothing is opened.
  defp act(state, id, _lost, prior) when prior >= 2 do
    Acts.settle(state.acts, id, :failed, reason: :repeating)
    id
  end

  defp act(state, id, %{socket: name}, _prior) do
    answer =
      case Sessions.viewer_argv(state.sessions, name) do
        {:ok, argv} -> Sessions.viewer(state.control, name, argv, state.size)
        {:refused, _} = refused -> refused
        # Asking opens nothing, so an answer that did not come is a state that did not act.
        {:unknown, why} -> {:refused, {:no_viewer_command, why}}
      end

    case answer do
      {:ok, pane} ->
        Acts.acted(state.acts, id, answer: "ok", detail: pane)

      # A viewer opened since the samples: it counts as an open, so a later loss is new.
      {:refused, {:session_exists, _}} ->
        Acts.settle(state.acts, id, :unknown,
          reason: :session_exists,
          answer: "exists",
          acted: true
        )

      {:refused, why} ->
        Acts.settle(state.acts, id, :failed, reason: why, answer: answer)

      _ ->
        Acts.acted(state.acts, id, answer: answer)
    end

    id
  end

  # Each acted state, against the first sample whose reads began after its act.
  defp verify(state, read, rows) do
    held = for %{kind: :held} = row <- read.rows, into: %{}, do: {row.name, row}

    for %{status: "acted"} = row <- rows, read.read_at > row.acted_at do
      {outcome, reason} = outcome(row, held[row.target])
      Acts.settle(state.acts, row.id, outcome, reason: reason)
      row.id
    end
  end

  defp outcome(_row, %{status: :viewed}), do: {:recovered, nil}
  defp outcome(_row, nil), do: {:unknown, :agent_gone}
  defp outcome(_row, %{status: :stale}), do: {:unknown, :stale}
  defp outcome(%{answer: "ok"}, _), do: {:failed, :not_viewed}
  defp outcome(%{answer: answer}, _), do: {:unknown, {:open, answer}}

  defp now(state), do: state.clock.()
end
