defmodule CodingAgentFramework.AbsentMains do
  @moduledoc """
  The healer of `absent_main` (F-183; `docs/design.md`, "Metrics and healing";
  `model/tla/Remedies.tla`): a declared main session whose process is gone while the
  framework runs, resumed once per absence through `Mains`, under the `Scheduler`'s lease that
  `Mains.resume_main/3` takes.

  **The symptom.** A main session's agent row `stopped` with reason `exited`: its process ended
  by itself (a crash, a kill, a person's `/exit`), as `Sessions` settles it once the process is
  gone by its pid and start time and its socket is dead. A main the operator ended is `ended`,
  one imported is `stopped` with reason `imported`, and one moving is not `stopped`: none of them
  is absent. One absence is one state, keyed by the name and the row's `started_at` (the start
  of the process that went), so a main resumed and gone again is a new state.

  **On the one shape** (F-182), as `CodingAgentFramework.Recoveries` is: each absence is
  recorded in the `Watch` first; a state with a row in `Acts` is decided by that row; a kind off
  the list, past its cap, or a main already resumed within the bound (a second absence in it,
  `Remedies.tla`'s `ResumeOncePerBound`) is asked; else the resume is claimed in `Acts` under
  this healer's actor and its state, and made once. A state asked for its bound that a person
  answered `act` (F-189's new-7) is resumed once at the next check, under a claim whose actor is
  that person, which no cap of this healer counts. An answer of ok is verified at once from
  the agent row (running or starting is recovered; anything else drops the remedy from the list
  and asks); refused and unknown are asked, never tried again in that state. A claim a restart
  cut is asked at `init`. Each check passes the absences it no longer reads.

  **A resume that waits** (F-203, `Remedies.tla`'s ActWaits and SettleWait): every usable
  account limited, `Mains` keeps the resume as its own row, `waiting` for the reset, and answers
  `waiting` at once. The claim is then `acted`, its detail naming that row (`start`), and stays
  open until the row ends: `running` settles it `verified`; `refused` (a person answered its
  `limit` prompt `leave`, or its pick at the reset was refused) settles it `failed`, a fault,
  and asks, since the main is still absent.

  The embedding app's tree starts one per instance, after `Mains`, given the host's
  `Sessions.Agents` reader, the instance's `Acts` and `Watch`, and `resume:`, the function that
  resumes a main by name (`&Mains.resume_main(mains, &1)`). It checks at start and at each cue
  of `sessions` or `watch` (`reads/0`), or by `check/2`.

      iex> row = %{kind: "main", name: "app-epic", status: "stopped", reason: "exited",
      ...>   started_at: 7, updated_at: 9, pid: 41, proc_start: "x"}
      iex> CodingAgentFramework.AbsentMains.absences([row, %{row | reason: "imported"}])
      [%{key: "absent_main:app-epic:7", name: "app-epic", since: 9, evidence: %{pid: 41, proc_start: "x"}}]
  """

  use GenServer

  alias CodingAgentFramework.{Acts, Sessions, Watch}
  alias CodingAgentFramework.Mains.Starts

  @kind "absent_main"
  @remedy "resume"
  @timeout 330_000

  @doc """
  Starts the healer. Options: `agents:` (a `Sessions.Agents` reader), `acts:`, `watch:`,
  `mains_db:` (`Mains`' file, whose start rows a waited resume is read from), `resume:` (name
  -> `{:ok, _} | {:refused, _} | {:unknown, _}`), `host:` (for its actor,
  `absent_mains:<host>`) and optionally `clock:` (ms). Fails to start with `Acts`' answer when
  it cannot close the rows a restart cut, or the file's refusal.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Reads the main sessions' rows and heals each absence. Answers `{:ok, %{resumed: ids}}`, the
  rows in `Acts` it claimed, or the `Watch`'s or `Acts`' refusal or unknown. Option `:timeout`
  (a resume may wait for its lease and its start).
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

  @doc """
  What it reads, for `Cues`: `Sessions`' rows, the `Watch`'s answers, and `Mains`' start rows,
  where a resume that waits ends.
  """
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(sessions watch mains), cue: &cue/2}

  @doc "The absences in agent rows: main sessions whose process exited by itself. Pure."
  @spec absences([map]) :: [map]
  def absences(rows) do
    for %{kind: "main", status: "stopped", reason: "exited"} = r <- rows do
      %{
        key: "#{@kind}:#{r.name}:#{r.started_at}",
        name: r.name,
        since: r.updated_at,
        evidence: %{pid: r.pid, proc_start: r.proc_start}
      }
    end
  end

  @impl true
  def init(opts) do
    with {:ok, starts} <- Starts.open(Keyword.fetch!(opts, :mains_db)) do
      s = %{
        agents: Keyword.fetch!(opts, :agents),
        acts: Keyword.fetch!(opts, :acts),
        watch: Keyword.fetch!(opts, :watch),
        starts: starts,
        resume: Keyword.fetch!(opts, :resume),
        actor: "absent_mains:#{Keyword.fetch!(opts, :host)}",
        clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end)
      }

      # A claim this actor wrote, or a person's it took (F-192), and did not act on: never
      # acted on; its state is a person's.
      case Acts.interrupt(s.acts, s.actor) do
        {:ok, cut} ->
          for id <- cut, {:ok, row} <- [Acts.get(s.acts, id)], do: ask(s, row, :interrupted)
          send(self(), :check)
          {:ok, s}

        {_, reason} ->
          {:stop, reason}
      end
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:check, _from, s), do: {:reply, check_now(s), s}

  @impl true
  def handle_info(:check, s) do
    check_now(s)
    {:noreply, s}
  end

  defp check_now(s) do
    with :ok <- waited(s),
         {:ok, list} <- Watch.remedies(s.watch, :list) do
      absent = absences(Sessions.Agents.rows(s.agents))
      resumed = for a <- absent, id = heal(s, list, a), is_integer(id), do: id
      present = %{targets: Enum.map(absent, & &1.name), states: Enum.map(absent, & &1.key)}
      Watch.pass(s.watch, {s.actor, @kind}, present)
      {:ok, %{resumed: resumed}}
    end
  end

  # Heal.tla's Detect, then its Claim or its Ask, as `Recoveries`' own.
  defp heal(s, list, a) do
    sym = %{
      kind: @kind,
      target: a.name,
      state: a.key,
      source: s.actor,
      since: a.since,
      evidence: a.evidence
    }

    case Watch.acting(Watch.record(s.watch, sym), s.actor) do
      nil -> nil
      # A person's answer "act" (F-189's new-7): the resume once, under their claim.
      by when by != s.actor -> resume(s, sym, by)
      _healer -> heal_open(s, list, a, sym)
    end
  end

  defp heal_open(s, list, a, sym) do
    with {:ok, rows} <- Acts.rows(s.acts, actor: s.actor, target: a.name, state: a.key) do
      case rows do
        [] ->
          case may_act(s, list[@kind], a.name) do
            :ok -> resume(s, sym)
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

  # The list's entry and its cap, and the main's own bound: a resume of it within the bound
  # already makes this absence a second one, a person's. Both are folds of this healer's rows.
  defp may_act(s, entry, name) do
    case entry do
      %{remedy: @remedy, allowed: true, cap: cap, bound: bound} ->
        from = now(s) - bound

        case Acts.rows(s.acts, actor: s.actor, act: @remedy, since: from) do
          {:ok, rows} ->
            rows = Enum.filter(rows, &(&1.claimed_at >= from))

            cond do
              length(rows) >= cap -> {:ask, {:cap, cap, bound}}
              Enum.any?(rows, &(&1.target == name)) -> {:ask, {:again_within, bound}}
              true -> :ok
            end

          _unread ->
            :shown
        end

      %{remedy: @remedy} ->
        {:ask, :not_on_list}

      _none ->
        :shown
    end
  end

  defp resume(s, sym, actor \\ nil) do
    detail = [detail: %{symptom: sym.state}]

    with {:ok, id} <-
           Acts.claim(
             s.acts,
             actor || s.actor,
             sym.target,
             sym.state,
             :resume,
             detail ++ healer(s, actor)
           ) do
      case s.resume.(sym.target) do
        # Every usable account limited (F-196): the resume waits as its own row in `Mains`, a
        # prompt, and goes on at the reset. Its outcome is that row's end (F-203).
        {:ok, %{waiting: until, id: start}} ->
          Acts.acted(s.acts, id, answer: {:waiting, until}, detail: %{start: start})

        {:ok, _} ->
          verify(s, id, sym)

        {:refused, why} ->
          settle(s, id, sym, :failed, {:refused, why}, acted: false)

        {:unknown, why} ->
          settle(s, id, sym, :unknown, {:unknown, why}, acted: true)
      end

      id
    else
      _claimed_elsewhere -> nil
    end
  end

  # Remedies.tla's SettleWait (F-203): a resume of this healer's, or a person's it took, that
  # waited at a usage limit is settled from its row in `Mains` once that row has ended. A row
  # still waiting or starting, or not read, decides nothing.
  defp waited(s) do
    with {:ok, rows} <- Acts.rows(s.acts, act: "resume", status: "acted") do
      for r <- rows,
          detail = decode(r.detail),
          r.actor == s.actor or detail["healer"] == s.actor,
          is_integer(detail["start"]),
          %{status: status} = start when status in ["running", "refused"] <-
            [Starts.get(s.starts, detail["start"])],
          do: settle_wait(s, r, start)

      :ok
    end
  end

  defp settle_wait(s, r, %{status: "running", account: account}),
    do: Acts.settle(s.acts, r.id, :verified, answer: {:resumed, account})

  # Left by a person or its pick refused at the reset: the main is still absent, a person's.
  defp settle_wait(s, r, %{reason: reason}) do
    Acts.settle(s.acts, r.id, :failed, reason: {:waited, reason})
    ask(s, r, {:waited, reason})
  end

  defp decode(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = detail} -> detail
      _ -> %{}
    end
  end

  defp decode(_), do: %{}

  # Heal.tla's Verify, read at once: the resume's ok means its start was confirmed, so the row
  # reads running unless the process went again. One that did not help leaves the list.
  defp verify(s, id, sym) do
    case Sessions.Agents.get(s.agents, sym.target) do
      %{status: status} when status in ["running", "starting"] ->
        Acts.settle(s.acts, id, :recovered, answer: "ok", acted: true)

      other ->
        status = other && other.status

        Acts.settle(s.acts, id, :failed,
          reason: {:not_running, status},
          answer: "ok",
          acted: true
        )

        Watch.remedies(s.watch, {:drop, @kind, {:verify_failed, id, status}})
        ask(s, sym, {:verify_failed, status})
    end
  end

  defp settle(s, id, sym, outcome, why, acted: acted) do
    Acts.settle(s.acts, id, outcome, reason: why, acted: acted)
    ask(s, sym, why)
  end

  defp ask(s, %{target: target, state: key}, why) do
    Watch.ask(s.watch, %{kind: @kind, target: target, state: key}, why)
    true
  end

  # A person's claim names this healer, whose restart closes it if cut (F-192).
  defp healer(_s, nil), do: []
  defp healer(s, person), do: if(person == s.actor, do: [], else: [healer: s.actor])

  defp now(s), do: s.clock.()
end
