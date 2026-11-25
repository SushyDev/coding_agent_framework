defmodule CodingAgentFramework.HooksSilent do
  @moduledoc """
  The detector of `hooks_silent` (F-184; `docs/design.md`, "Metrics and healing"): an agent's
  tool call its transcript shows with no `Intake` row of its session within a bound. A symptom
  only: it is recorded in the `Watch` and shown, and its kind has no remedy on the list, so it
  is never asked and nothing acts on it.

  **The reading.** The embedding app's tree always hooks `PreToolUse`, so each tool call posts a
  row before it runs. For each running agent with a session, the newest tool call in the last
  part of its transcript (`Transcripts.Fold.tool_calls/1`) is silent when it is older than
  `bound:` ms and the session's newest `Intake` row was written before it, less `slack:` ms for
  the two clocks (Claude Code's timestamp and the framework's). A tool call with no timestamp,
  a transcript or an `Intake` not read yet, decides nothing. One state per call:
  `hooks_silent:<name>:<tool use id>`; one no longer read silent passes.

  The embedding app's tree starts one per host, given the host's `Sessions.Agents` reader and
  `Transcripts`, the file of `Intake`'s table, and the instance's `Watch`. It checks at start,
  at each cue of `transcripts` or `intake` (`reads/0`), every `interval:` ms when given (a
  silence sends no cue), or by `check/2`.

      iex> call = %{id: "tu-1", name: "Bash", at: 10_000}
      iex> CodingAgentFramework.HooksSilent.silent?(call, {:ok, 4_000}, 70_000, %{bound: 60_000, slack: 5_000})
      true
      iex> CodingAgentFramework.HooksSilent.silent?(call, {:ok, 9_000}, 70_000, %{bound: 60_000, slack: 5_000})
      false
  """

  use GenServer

  alias CodingAgentFramework.{Sessions, Transcripts, Watch}
  alias CodingAgentFramework.Intake.Table, as: IntakeTable
  alias CodingAgentFramework.Transcripts.Fold

  @kind "hooks_silent"
  @bound 120_000
  @slack 5_000
  # The last part of a transcript read: its newest tool calls are there.
  @tail 65_536
  @timeout 30_000

  @doc """
  Starts the detector. Options: `agents:` (a `Sessions.Agents` reader), `transcripts:`,
  `intake_db:` (the file of `Intake`'s table), `watch:`, `host:` (for its source,
  `hooks_silent:<host>`), and optionally `bound:` (ms, default two minutes), `slack:` (ms,
  default 5 s), `interval:` (ms) and `clock:` (wall-clock ms).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Reads every running agent now. Answers `{:ok, %{silent: states}}`, or the `Watch`'s answer."
  @spec check(GenServer.server(), keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def check(detector, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    GenServer.call(detector, :check, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_detector}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @timeout)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @doc "Asks for a check without waiting for it. Answers `:ok` at once."
  @spec cue(pid, map) :: :ok
  def cue(detector, _cue \\ %{}) do
    send(detector, :check)
    :ok
  end

  @doc "What it reads, for `Cues`: the transcripts and `Intake`'s rows."
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(transcripts intake), cue: &cue/2}

  @doc """
  Whether tool call `call` is silent at `now`: older than the bound, and the session's newest
  `Intake` row (`newest`, `Intake.Table.newest/4`'s answer) written before it, less the slack.
  Pure.
  """
  @spec silent?(map, term, integer, %{bound: integer, slack: integer}) :: boolean
  def silent?(%{at: at}, {:ok, newest}, now, %{bound: bound, slack: slack}) when is_integer(at),
    do: now - at >= bound and (newest == nil or newest < at - slack)

  def silent?(_call, _newest, _now, _s), do: false

  @impl true
  def init(opts) do
    with {:ok, db} <- IntakeTable.open(Keyword.fetch!(opts, :intake_db)) do
      s = %{
        agents: Keyword.fetch!(opts, :agents),
        transcripts: Keyword.fetch!(opts, :transcripts),
        intake: db,
        watch: Keyword.fetch!(opts, :watch),
        host: Keyword.fetch!(opts, :host),
        source: "hooks_silent:#{Keyword.fetch!(opts, :host)}",
        bound: Keyword.get(opts, :bound, @bound),
        slack: Keyword.get(opts, :slack, @slack),
        interval: Keyword.get(opts, :interval),
        clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end)
      }

      send(self(), :tick)
      {:ok, s}
    else
      {_, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:check, _from, s), do: {:reply, check_now(s), s}

  @impl true
  def handle_info(:check, s) do
    drain_checks()
    check_now(s)
    {:noreply, s}
  end

  def handle_info(:tick, s) do
    check_now(s)
    if s.interval, do: Process.send_after(self(), :tick, s.interval)
    {:noreply, s}
  end

  # F-261: on a busy host cues come faster than a check ends; one check answers every cue
  # queued before it, since it reads afresh.
  defp drain_checks do
    receive do
      :check -> drain_checks()
    after
      0 -> :ok
    end
  end

  defp check_now(s) do
    now = s.clock.()
    silent = for r <- Sessions.Agents.rows(s.agents), sym = silent(s, r, now), sym, do: sym

    with :ok <- record(s, silent) do
      present = %{targets: Enum.map(silent, & &1.target), states: Enum.map(silent, & &1.state)}
      Watch.pass(s.watch, {s.source, @kind}, present)
      {:ok, %{silent: Enum.map(silent, & &1.state)}}
    end
  end

  defp silent(s, %{status: "running", session_id: sid, account: account} = r, now)
       when is_binary(sid) and is_binary(account) do
    with {:ok, %{bytes: bytes}} <-
           Transcripts.text(s.transcripts, account, sid, {:last, @tail}, max: @tail),
         call when call != nil <- List.last(Fold.tool_calls(bytes)),
         newest = IntakeTable.newest(s.intake, s.host, account, sid),
         true <- silent?(call, newest, now, s) do
      %{
        kind: @kind,
        target: r.name,
        state: "#{@kind}:#{r.name}:#{call.id}",
        source: s.source,
        since: call.at,
        evidence: %{tool: call.name, tool_use_id: call.id, newest_hook: elem(newest, 1)}
      }
    else
      _ -> nil
    end
  end

  defp silent(_s, _row, _now), do: nil

  defp record(s, silent) do
    Enum.reduce_while(silent, :ok, fn sym, :ok ->
      case Watch.record(s.watch, sym) do
        {:ok, _} -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end
end
