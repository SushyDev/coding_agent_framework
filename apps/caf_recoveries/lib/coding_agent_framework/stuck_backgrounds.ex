defmodule CodingAgentFramework.StuckBackgrounds do
  @moduledoc """
  The healer of `stuck_background` (F-184; `docs/design.md`, "Metrics and healing";
  `model/tla/Remedies.tla`): a headless delegate whose report was taken while a background
  command of it runs and has used no CPU time for a bound. Its remedy ends that command's
  process group by its record, once per state. No partial report goes: the report was taken.

  **The symptom.** Claude Code writes the turn's `result` while its background command runs
  (measured on 2.1.322), and `Delegates` takes the report at that result. So the state read is
  a running delegate's `Stream` fold whose turn ended with a result (`idle`, `last_result`)
  while Claude Code's own list (`background`, its last `background_tasks_changed`) still names a
  task, and a process group of the delegate's process (`StuckBackgrounds.Groups`) whose CPU
  time has not moved for `quiet:` ms. The time runs from this process's first read of that CPU
  time, in memory, so a restart starts it again; on a host with no `/proc` (macOS) the groups
  read `unknown`, and nothing is ever stuck. One state per group: `stuck_background:<name>:<the
  leader's pid>:<its start time>`. No event of Claude Code names a task's pid, so a group is
  any the delegate's process started that leads its own: Claude Code spawns each command so.

  **On the one shape** (F-182), as `AbsentMains` is: each state is recorded in the `Watch`
  first; a state with a row in `Acts` is decided by that row; a kind off the list or past its
  cap is asked (a state asked for its bound and answered `act` is ended once at the next check,
  under a claim whose actor is the person, F-189's new-7); else the end is claimed in `Acts`
  under this healer's actor and its state, and
  TERM goes to the group, only while its leader still has the record's pid and start time
  (`Holder.Process.signal/4`, `group: true`). A group already gone is refused, nothing sent.
  The row is then `acted`, with the tasks the fold named and how many lists had come; its
  outcome is read from the next `background_tasks_changed`: a list without one of those tasks
  is recovered, one that still names them all fails the verify (the remedy leaves the list, and
  the state is asked). A delegate gone first is unknown, asked. A claim a restart cut is asked
  at `init`.

  The embedding app's tree starts one per host, given the host's `Sessions.Agents` reader,
  `folds:` (a function answering `{:ok, rows}`, `Stream.rows/1`'s rows), its `Holder` and
  `Programs` (ps and kill, for the records), and the instance's `Acts` and `Watch`. It checks
  at start, at each cue of `stream` or `watch` (`reads/0`), every `interval:` ms when given, or
  by `check/2`. A hung command writes nothing to the stream, so no cue comes while its group
  stays quiet: the interval is what reads it again (F-189's new-4), as `HooksSilent` does.

      iex> fold = %{session: "s1", gone: false, idle: true, last_result: %{},
      ...>   background: %{tasks: ["t1"], changes: 1}}
      iex> row = %{kind: "delegate", role: "delegate", status: "running", name: "app-fix",
      ...>   session_id: "s1", pid: 7, proc_start: "x"}
      iex> [%{name: "app-fix", tasks: ["t1"]}] = CodingAgentFramework.StuckBackgrounds.owed([row], [fold])
  """

  use GenServer

  alias CodingAgentFramework.{Acts, Holder, Recoveries, Sessions, Watch}
  alias CodingAgentFramework.StuckBackgrounds.Groups

  @kind "stuck_background"
  @remedy "end"
  @quiet 600_000
  @timeout 30_000

  @doc """
  Starts the healer. Options: `agents:` (a `Sessions.Agents` reader), `folds:`, `acts:`,
  `watch:`, `host:` (for its actor, `stuck_backgrounds:<host>`), and either `holder:` and
  `programs:` or the functions they make: `groups:` (a record to `Groups.read/3`'s answer) and
  `signal:` (a group's record to `Holder.Process.signal/4`'s). Optionally `quiet:` (ms with no
  CPU time, default ten minutes), `interval:` (ms between checks; without it, only at cues)
  and `clock:` (ms). Fails to start with `Acts`' answer when it
  cannot close the rows a restart cut, or with the programs a record needs.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Reads the delegates and heals each stuck group. Answers `{:ok, %{ended: ids}}`, the rows in
  `Acts` it claimed, or the `Watch`'s or `Acts`' refusal or unknown.
  """
  @spec check(GenServer.server(), keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def check(healer, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    GenServer.call(healer, :check, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_healer}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @timeout)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @doc "Asks for a check without waiting for it. Answers `:ok` at once."
  @spec cue(pid, map) :: :ok
  def cue(healer, _cue \\ %{}) do
    send(healer, :check)
    :ok
  end

  @doc "What it reads, for `Cues`: `Stream`'s folds, and the `Watch`'s answers."
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(stream watch), cue: &cue/2}

  @doc """
  The delegates whose report was taken while Claude Code still lists a background task of
  theirs: running headless agent rows with a record, whose fold's turn ended with a result.
  Pure.
  """
  @spec owed([map], [map]) :: [map]
  def owed(rows, folds) do
    by_session = Map.new(folds, &{&1.session, &1})

    for %{status: "running", pid: pid, proc_start: start} = r <- rows,
        Sessions.Agents.headless?(r),
        is_integer(pid) and is_binary(start),
        f = by_session[r.session_id],
        f != nil and f.gone == false and f.idle == true and f.last_result != nil,
        tasks = get_in(f, [:background, :tasks]) || [],
        tasks != [] do
      %{
        name: r.name,
        record: %{pid: pid, start: start},
        tasks: tasks,
        changes: f.background.changes
      }
    end
  end

  @impl true
  def init(opts) do
    with {:ok, groups, signal} <- readers(opts) do
      s = %{
        agents: Keyword.fetch!(opts, :agents),
        folds: Keyword.fetch!(opts, :folds),
        acts: Keyword.fetch!(opts, :acts),
        watch: Keyword.fetch!(opts, :watch),
        groups: groups,
        signal: signal,
        quiet: Keyword.get(opts, :quiet, @quiet),
        interval: Keyword.get(opts, :interval),
        actor: "stuck_backgrounds:#{Keyword.fetch!(opts, :host)}",
        clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
        seen: %{}
      }

      # A claim this actor wrote and did not act on: never acted on; its state is a person's.
      case Acts.interrupt(s.acts, s.actor) do
        {:ok, cut} ->
          for id <- cut, {:ok, row} <- [Acts.get(s.acts, id)], do: ask(s, row, :interrupted)
          send(self(), :tick)
          {:ok, s}

        {_, reason} ->
          {:stop, reason}
      end
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  # Each reader given, or made from the host's records.
  defp readers(opts) do
    {groups, signal} = {opts[:groups], opts[:signal]}

    if is_function(groups, 1) and is_function(signal, 1) do
      {:ok, groups, signal}
    else
      with {:ok, procs} <-
             Holder.Process.new(Keyword.fetch!(opts, :programs), Keyword.fetch!(opts, :holder)) do
        {:ok, groups || (&Groups.read(procs, &1)),
         signal || (&Holder.Process.signal(procs, &1, "TERM", group: true))}
      end
    end
  end

  @impl true
  def handle_call(:check, _from, s) do
    {reply, s} = check_now(s)
    {:reply, reply, s}
  end

  @impl true
  def handle_info(:check, s), do: {:noreply, elem(check_now(s), 1)}

  def handle_info(:tick, s) do
    if s.interval, do: Process.send_after(self(), :tick, s.interval)
    {:noreply, elem(check_now(s), 1)}
  end

  defp check_now(s) do
    with {:ok, list} <- Watch.remedies(s.watch, :list),
         {:ok, folds} <- s.folds.() do
      owed = owed(Sessions.Agents.rows(s.agents), folds)
      verify(s, folds)
      {stuck, s} = stuck(s, owed)
      ended = for g <- stuck, id = heal(s, list, g), is_integer(id), do: id
      present = %{targets: Enum.map(stuck, & &1.name), states: Enum.map(stuck, & &1.key)}
      Watch.pass(s.watch, {s.actor, @kind}, present)
      {{:ok, %{ended: ended}}, s}
    else
      other -> {other, s}
    end
  end

  # Each owed delegate's groups, against the CPU time first read of each: one quiet for the
  # bound is stuck. A group read again with more time starts again; one gone is forgotten.
  defp stuck(s, owed) do
    now = now(s)

    read =
      for o <- owed, {:ok, groups} <- [s.groups.(o.record)], g <- groups do
        {"#{@kind}:#{o.name}:#{g.pid}:#{g.start}", o, g}
      end

    seen =
      Map.new(read, fn {key, _o, g} ->
        case s.seen[key] do
          %{cpu: cpu} = first when cpu == g.cpu -> {key, first}
          _ -> {key, %{cpu: g.cpu, since: now}}
        end
      end)

    stuck =
      for {key, o, g} <- read, now - seen[key].since >= s.quiet do
        Map.merge(o, %{key: key, group: %{pid: g.pid, start: g.start}, since: seen[key].since})
      end

    {stuck, %{s | seen: seen}}
  end

  # Heal.tla's Detect, then its Claim or its Ask, as `AbsentMains`' own.
  defp heal(s, list, g) do
    evidence = %{group: g.group, tasks: g.tasks, cpu_since: g.since, quiet: s.quiet}
    sym = %{kind: @kind, target: g.name, state: g.key, source: s.actor, since: g.since}

    case Watch.acting(Watch.record(s.watch, Map.put(sym, :evidence, evidence)), s.actor) do
      nil -> nil
      # A person's answer "act" (F-189's new-7): the end once, under their claim.
      by when by != s.actor -> end_group(s, sym, g, by)
      _healer -> heal_open(s, list, g, sym)
    end
  end

  defp heal_open(s, list, g, sym) do
    with {:ok, rows} <- Acts.rows(s.acts, actor: s.actor, target: g.name, state: g.key) do
      case rows do
        [] ->
          case may_act(s, list[@kind]) do
            :ok -> end_group(s, sym, g)
            :shown -> nil
            {:ask, why} -> ask(s, sym, why)
          end

        claimed ->
          if fault = Enum.find(claimed, &Acts.fault?/1),
            do: ask(s, sym, {:ended, fault.outcome || fault.status})

          nil
      end
    else
      _unread -> nil
    end
  end

  defp may_act(s, entry) do
    case entry do
      %{remedy: @remedy, allowed: true, cap: cap, bound: bound} ->
        from = now(s) - bound

        case Acts.rows(s.acts, actor: s.actor, act: @remedy, since: from) do
          {:ok, rows} ->
            if Enum.count(rows, &(&1.claimed_at >= from)) >= cap,
              do: {:ask, {:cap, cap, bound}},
              else: :ok

          _unread ->
            :shown
        end

      %{remedy: @remedy} ->
        {:ask, :not_on_list}

      _none ->
        :shown
    end
  end

  defp end_group(s, sym, g, actor \\ nil) do
    with {:ok, id} <- Acts.claim(s.acts, actor || s.actor, sym.target, sym.state, :end) do
      case s.signal.(g.group) do
        {:ok, :sent} ->
          detail = %{tasks: g.tasks, changes: g.changes, group: g.group}
          Acts.acted(s.acts, id, answer: "sent", detail: detail)

        # Its leader is gone or another process has its pid: nothing was sent.
        {:ok, :gone} ->
          Acts.settle(s.acts, id, :failed, reason: :group_gone)
          ask(s, sym, {:refused, :group_gone})

        {:unknown, why} ->
          Acts.settle(s.acts, id, :unknown, reason: why, acted: true)
          ask(s, sym, {:unknown, why})
      end

      id
    else
      _claimed_elsewhere -> nil
    end
  end

  # Heal.tla's Verify, at the first list Claude Code wrote after the end: a task it named then
  # no longer listed is the command's end.
  defp verify(s, folds) do
    with {:ok, rows} <- Recoveries.acted(s.acts, s.watch, s.actor, @remedy) do
      for row <- rows, {:ok, %{"tasks" => tasks, "changes" => changes}} <- [decode(row.detail)] do
        fold = Enum.find(folds, &(&1.session == session(s, row.target)))
        judge(s, row, fold, tasks, changes)
      end
    end
  end

  defp judge(s, row, fold, tasks, changes) do
    cond do
      fold == nil or fold.gone ->
        Acts.settle(s.acts, row.id, :unknown, reason: :agent_gone)
        ask(s, row, {:unknown, :agent_gone})

      fold.background.changes <= changes ->
        :waiting

      Enum.all?(tasks, &(&1 in fold.background.tasks)) ->
        Acts.settle(s.acts, row.id, :failed, reason: :still_listed)
        Watch.remedies(s.watch, {:drop, @kind, {:verify_failed, row.id, :still_listed}})
        ask(s, row, {:verify_failed, :still_listed})

      true ->
        Acts.settle(s.acts, row.id, :recovered)
    end
  end

  defp session(s, name), do: (Sessions.Agents.get(s.agents, name) || %{})[:session_id]

  defp decode(text) when is_binary(text), do: JSON.decode(text)
  defp decode(_), do: :none

  defp ask(s, %{target: target, state: key}, why) do
    Watch.ask(s.watch, %{kind: @kind, target: target, state: key}, why)
    true
  end

  defp now(s), do: s.clock.()
end
