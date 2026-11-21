defmodule CodingAgentFramework.Recoveries do
  @moduledoc """
  Detects a broken state on one host, acts once per state, and verifies from a later sample
  (`model/tla/Agent.tla`, `RecoveryClaims`, `RecoveryActs`, `RecoveriesRestart`,
  `PersonClears`). It keeps no table of its own: each state it acts on is a row in
  `CodingAgentFramework.Acts`, under the actor `recoveries:<host>:<server>`, and `Acts` cues it.

  **It is the healer** (F-182, `model/tla/Heal.tla`), on the `Watch`'s allow-list. Each state it
  reads is first recorded as a symptom in `CodingAgentFramework.Watch` (kind `lost_viewer` or
  `end_owed`, its target the socket, its state the key below), whatever happens next. It acts
  only by the remedy the list names for that kind (`reopen`, `end`) and under the kind's cap:
  the claims of that act in the bound, counted from its own rows in `Acts`. A state off the list
  or past the cap, and a remedy refused, unknown, repeating, cut by a restart or whose verify
  failed, is asked: a `remedy` prompt for a person (`Watch.ask/4`), once per state. A verify that
  fails also drops the kind's remedy from the list at once; only the operator puts it back.
  Each check passes the states it no longer reads.

  **One clear** (F-182's new-2, built in F-183). A state that waits on a person (a loss that
  repeated, an end whose outcome is unknown) is cleared by its `remedy` prompt's answer
  (`Watch.answer/5`, or `Watch.clear/3`), or by the prompt passing with its target, since no
  answer can come then. Each check copies that time onto the state's own row in `Acts`
  (`cleared_at`), where the keys and counts below read it.

  The caller's supervision tree starts one per host, with no name, given the host's
  `TmuxSampler`, `Holder`, `Sessions`, tmux server (for its key and its viewers) and the instance's
  `Acts` and `Watch`. It reads the sampler's rows, never a pane's screen: by `check/2`, or after `cue/1`,
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
  `interrupted` when this process starts (`Acts.interrupt/2`, a person's claim it took among them), and never acted on. The act asks
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
  not claimed again until a person clears it.

  **The second recovery is an end owed** (F-118, `model/tla/Start.tla`'s `Kill`; act `end`): the
  process of an `orphan` row of `Sessions`, or of a stop whose deadline passed with it alive,
  which `Sessions.ends_owed/2` names with its pid and start time. Its state is keyed by the
  name, the pid, the start time and the last clear of the agent's ends; its row is claimed
  first, then the process is ended by that record alone (`Holder.Process.end_held/5`: TERM, then
  KILL at `end_grace`, default 5 s), and the row settles `recovered` once the program reads
  dead, or `unknown` with what was read. An end that settled `unknown` waits for a person, as a
  repeating loss does (F-118's new-5): its state stays claimed until a person's clear names a new one.
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

  alias CodingAgentFramework.{Acts, Holder, Sessions, Tmux, TmuxSampler, Watch}

  @timeout 60_000
  @lost [:unviewed, :no_server]
  # Each act's symptom kind on the allow-list.
  @kinds %{"reopen" => "lost_viewer", "end" => "end_owed"}

  @doc """
  Starts a `Recoveries`. Options: `sampler:` (the host's `TmuxSampler`), `holder:` (its `Holder`), `programs:` (its `Programs`, with ps, kill and sleep,
  for `Holder.Process`), `sessions:` (its `Sessions`, which answers each viewer's command and
  the ends owed), `server:` (its `Tmux` server, for the key and the viewers it opens), `acts:` (the instance's `Acts`), `watch:` (the instance's `Watch`: the symptom record and the allow-list),
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

  @doc "Asks for a check without waiting for it: the sampler's cue. Answers `:ok` at once."
  @spec cue(pid, map) :: :ok
  def cue(recoveries, _cue \\ %{}) do
    send(recoveries, :check)
    :ok
  end

  @doc """
  What `Recoveries` reads, for `Cues`: the samplers' cues, which show a lost viewer, and the
  `Watch`'s, which show a person's clear.
  """
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(tmux watch), cue: &cue/2}

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

    watch = Keyword.fetch!(opts, :watch)

    # A claim this actor wrote, or a person's it took (F-192), and did not act on: the restart cut it, and it is never acted on;
    # its symptom waits on a person (Heal.tla's SettleCut, then Ask).
    with :ok <- same_host(host, holder.host.name),
         {:ok, procs} <- Holder.Process.new(Keyword.fetch!(opts, :programs), holder),
         {:ok, cut} <- Acts.interrupt(acts, actor) do
      for id <- cut, {:ok, row} <- [Acts.get(acts, id)], do: ask(watch, row, :interrupted)

      {:ok,
       %{
         host: host,
         server: server,
         actor: actor,
         acts: acts,
         watch: watch,
         procs: procs,
         end_grace: Keyword.get(opts, :end_grace, 5_000),
         sampler: Keyword.fetch!(opts, :sampler),
         sessions: Keyword.fetch!(opts, :sessions),
         tmux: Keyword.fetch!(opts, :server),
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

  @impl true
  def handle_info(:check, state) do
    {_, state} = check_now(state)
    {:noreply, state}
  end

  # The rows that wait for a person, never cleared: a loss that repeated, or an end that settled
  # unknown. Each whose symptom state a person answered, or whose prompt passed with its target,
  # takes that time as its clear (F-182's new-2): one clear, the `Watch`'s.
  defp release(state) do
    with {:ok, loops} <-
           Acts.rows(state.acts,
             actor: state.actor,
             act: "reopen",
             reason: "repeating",
             cleared_at: nil
           ),
         {:ok, ends} <-
           Acts.rows(state.acts,
             actor: state.actor,
             act: "end",
             outcome: "unknown",
             cleared_at: nil
           ) do
      for r <- loops ++ ends,
          r.status == "settled",
          key = [kind: @kinds[r.act], target: r.target, state: r.state],
          {:ok, [sym]} <- [Watch.read(state.watch, key)],
          at = sym.answered_at || sym.passed_at,
          do: Acts.clear(state.acts, [r.id], at: at)

      :ok
    end
  end

  # The ledger keeps every row (F-126's new-5), so a check reads by index only what can decide
  # it: the acts that wait for a sample, the losses that wait for a person, and the rows of the
  # sockets lost now since the earliest time that changes a state's key or count; and per end
  # owed, that socket's ends.
  defp check_now(state) do
    with :ok <- release(state),
         {:ok, list} <- Watch.remedies(state.watch, :list),
         state = Map.put(state, :list, list),
         {:ok, open} <- acted(state.acts, state.watch, state.actor, "reopen"),
         {:ok, waiting} <-
           Acts.rows(state.acts,
             actor: state.actor,
             act: "reopen",
             reason: "repeating",
             cleared_at: nil
           ) do
      ends = end_owed(state)

      case check_viewers(state, Enum.filter(open, &(&1.act == "reopen")), repeating(waiting)) do
        {{:ok, done}, state} -> {{:ok, Map.put(done, :ends, ends)}, state}
        other -> other
      end
    else
      other -> {other, state}
    end
  end

  # Each end owed, once per state: recorded, claimed on the list and under the cap, ended by the
  # record alone, then the row settles; an end whose outcome is unknown is asked, never tried
  # again in its state.
  defp end_owed(state) do
    case Sessions.ends_owed(state.sessions) do
      {:ok, owed} ->
        ends =
          for o <- owed,
              {:ok, rows} <- [
                Acts.rows(state.acts, actor: state.actor, act: "end", target: o.socket)
              ],
              key = end_key(state, o, rows) do
            evidence = %{name: o.name, pid: o.record.pid, start: o.record.start}
            sym = %{kind: "end_owed", target: o.socket, state: key, evidence: evidence}
            {key, heal(state, sym, "end", &end_one(state, o, key, sym, &1))}
          end

        present = %{targets: Enum.map(owed, & &1.socket), states: Enum.map(ends, &elem(&1, 0))}
        Watch.pass(state.watch, {state.actor, "end_owed"}, present)
        for {_, id} <- ends, is_integer(id), do: id

      _unread ->
        []
    end
  end

  defp end_one(state, o, key, sym, actor) do
    with {:ok, id} <- claim(state, actor, o.socket, key, :end) do
      case Holder.Process.end_held(state.procs, o.socket, o.record, state.end_grace) do
        {:ok, :ended} ->
          Acts.settle(state.acts, id, :recovered, answer: "ended", acted: true)

        {:unknown, why} ->
          Acts.settle(state.acts, id, :unknown, reason: why, answer: "unknown", acted: true)
          ask(state.watch, sym, {:unknown, why})
      end

      id
    end
  end

  # Heal.tla's Detect, then its Claim or its Ask: the symptom recorded first, whatever happens
  # next; a state with a row in `Acts` already is decided by that row's outcome; a remedy only
  # on the list and under its cap, else the state waits on a person. `act` claims as the actor
  # it is given and acts, and answers the row's id: the healer's, or for a state a person
  # answered `act` (F-189's new-7), that person's, once.
  defp heal(state, sym, remedy, act) do
    sym = Map.merge(sym, %{source: state.actor, since: Map.get(sym, :since, now(state))})

    case Watch.acting(Watch.record(state.watch, sym), state.actor) do
      nil -> nil
      by when by != state.actor -> act.(by)
      _healer -> heal_open(state, sym, remedy, act)
    end
  end

  defp heal_open(state, sym, remedy, act) do
    with {:ok, rows} <-
           Acts.rows(state.acts, actor: state.actor, target: sym.target, state: sym.state) do
      # A skipped row (a sample too old) is no claim: one taken now takes it over.
      case Enum.reject(rows, &(&1.status == "skipped")) do
        [] ->
          case may_act(state, remedy) do
            :ok -> act.(state.actor)
            :shown -> nil
            {:ask, why} -> ask(state.watch, sym, why) && nil
          end

        # Heal.tla's Ended: a claim that ended with no good outcome is a person's, however it
        # ended (the healer's own ask may have been cut).
        claimed ->
          if fault = Enum.find(claimed, &Acts.fault?/1),
            do: ask(state.watch, sym, {:ended, fault.outcome || fault.status})

          nil
      end
    else
      _unread -> nil
    end
  end

  # The allow-list's entry for `remedy`'s kind, and the cap: the remedies of that kind this
  # healer claimed in the bound, a fold of its rows in `Acts`, so a restart keeps the count.
  defp may_act(state, remedy) do
    case state.list[@kinds[remedy]] do
      %{remedy: ^remedy, allowed: true, cap: cap, bound: bound} ->
        from = now(state) - bound

        case Acts.rows(state.acts, actor: state.actor, act: remedy, since: from) do
          {:ok, rows} ->
            n = Enum.count(rows, &(&1.status != "skipped" and &1.claimed_at >= from))
            if n < cap, do: :ok, else: {:ask, {:cap, cap, bound}}

          _unread ->
            :shown
        end

      %{remedy: ^remedy} ->
        {:ask, :not_on_list}

      _none ->
        :shown
    end
  end

  # A symptom state the healer leaves to a person: its remedy prompt, once per state. A row of
  # `Acts` names its symptom by its act's kind, its target and its state.
  defp ask(watch, %{act: act, target: target, state: key}, why),
    do: ask(watch, %{kind: @kinds[act], target: target, state: key}, why)

  defp ask(watch, sym, why) do
    Watch.ask(watch, Map.take(sym, [:kind, :target, :state]), why)
    true
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

  defp check_viewers(state, open, repeating) do
    case TmuxSampler.rows(state.sampler) do
      {:ok, %{failed_at: at}} when is_integer(at) ->
        {{:refused, :sample_failed}, state}

      {:ok, read} ->
        at = now(state)
        age = at - read.read_at

        with {:ok, rows} <- lost_rows(state, read, repeating, at - state.window) do
          lost =
            for l <- lost_viewers(read, last_opened(rows)), l.socket not in repeating, do: l

          if age > state.max_age,
            do: skip(state, lost, age),
            else: act_on(state, read, lost, open, rows)
        else
          other -> {other, state}
        end

      other ->
        {other, state}
    end
  end

  # The rows of the sockets the sample reads lost, since the window's start or the time their
  # sample row took its status, whichever is earlier: an open or a clear before both changes no
  # state's key (`lost_viewers/2` takes the later of the two) and no count (`losses/3`).
  defp lost_rows(state, read, repeating, window_start) do
    lost =
      for %{kind: :held, socket: :live, status: s, name: n} = row <- read.rows,
          s in @lost,
          n not in repeating,
          do: row

    case lost do
      [] ->
        {:ok, []}

      lost ->
        since = Enum.min([window_start | Enum.map(lost, & &1.written_at)])
        sockets = Enum.map(lost, & &1.name)
        Acts.rows(state.acts, actor: state.actor, act: "reopen", target: sockets, since: since)
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

  defp act_on(state, read, lost, open, rows) do
    ended = verify(state, read, open)
    state = remember(state, read.read_at, MapSet.new(lost, & &1.key))
    agreed = for l <- lost, state.before && MapSet.member?(state.before.keys, l.key), do: l

    claimed =
      for l <- agreed,
          key = scoped(state, l.key),
          sym = %{
            kind: "lost_viewer",
            target: l.socket,
            state: key,
            since: l.since,
            evidence: %{generation: l.generation, read_at: read.read_at}
          },
          id = heal(state, sym, "reopen", &reopen(state, l, sym, rows, &1)),
          is_integer(id),
          do: id

    pass_viewers(state, read, lost)
    {{:ok, %{claimed: claimed, ended: ended}}, state}
  end

  # A person's act (F-189's new-7) is theirs once, whatever the losses counted before it.
  defp reopen(state, l, sym, rows, actor) do
    prior = if actor == state.actor, do: losses(state, rows, l.socket), else: 0

    with {:ok, id} <- claim(state, actor, l.socket, sym.state, :reopen),
         do: act(state, id, sym, prior)
  end

  # The lost viewers recorded that this sample no longer reads pass: a viewer since, or a new
  # loss under a new key. A state that waits on a person stays while its socket is lost at all.
  defp pass_viewers(state, read, lost) do
    targets =
      for %{kind: :held, socket: :live, status: s, name: n} <- read.rows, s in @lost, do: n

    present = %{targets: targets, states: Enum.map(lost, &scoped(state, &1.key))}
    Watch.pass(state.watch, {state.actor, "lost_viewer"}, present)
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

  # A person's claim names this healer, whose restart closes it if cut (F-192).
  defp claim(%{actor: actor} = state, actor, target, key, act),
    do: Acts.claim(state.acts, actor, target, key, act)

  defp claim(state, person, target, key, act),
    do: Acts.claim(state.acts, person, target, key, act, healer: state.actor)

  @doc """
  The rows of `act` that are `acted` and wait for `actor`'s verify: the healer's own, and those
  a person's answer `act` took on a symptom of `actor`'s (F-189's new-7), found by their
  symptom's row in the `Watch`. `StuckBackgrounds` reads its own the same way. Answers
  `{:ok, rows}` or `Acts`' refusal or unknown.
  """
  @spec acted(GenServer.server(), GenServer.server(), String.t(), String.t()) ::
          {:ok, [map]} | {:refused, term} | {:unknown, term}
  def acted(acts, watch, actor, act) do
    with {:ok, rows} <- Acts.rows(acts, status: "acted", act: act) do
      {:ok, Enum.filter(rows, &(&1.actor == actor or answered_act?(watch, actor, &1)))}
    end
  end

  defp answered_act?(watch, actor, %{actor: by} = row) do
    match?(
      {:ok, [%{answer: "act", answered_by: ^by}]},
      Watch.read(watch, source: actor, target: row.target, state: row.state)
    )
  end

  # The third loss in the window: the row says so, nothing is opened, and a person is asked.
  defp act(state, id, sym, prior) when prior >= 2 do
    Acts.settle(state.acts, id, :failed, reason: :repeating)
    ask(state.watch, sym, :repeating)
    id
  end

  defp act(state, id, %{target: name} = sym, _prior) do
    answer =
      case Sessions.viewer_argv(state.sessions, name) do
        {:ok, argv} -> Sessions.viewer(state.tmux, name, argv, state.size)
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
        ask(state.watch, sym, {:refused, why})

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
      judge(state, row, outcome, reason)
      row.id
    end
  end

  # Heal.tla's Verify: a remedy that answered ok and did not help leaves the allow-list at once,
  # with its reason (decision 11), and its state is asked; one whose outcome is unknown is asked
  # and never tried again in its state.
  defp judge(_state, _row, :recovered, _reason), do: :ok

  defp judge(state, row, :failed, reason) do
    Watch.remedies(state.watch, {:drop, @kinds[row.act], {:verify_failed, row.id, reason}})
    ask(state.watch, row, {:verify_failed, reason})
  end

  defp judge(state, row, :unknown, reason), do: ask(state.watch, row, {:unknown, reason})

  defp outcome(_row, %{status: :viewed}), do: {:recovered, nil}
  defp outcome(_row, nil), do: {:unknown, :agent_gone}
  defp outcome(_row, %{status: :stale}), do: {:unknown, :stale}
  defp outcome(%{answer: "ok"}, _), do: {:failed, :not_viewed}
  defp outcome(%{answer: answer}, _), do: {:unknown, {:open, answer}}

  defp now(state), do: state.clock.()
end
