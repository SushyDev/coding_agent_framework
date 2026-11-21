defmodule CodingAgentFramework.Interventions do
  @moduledoc """
  The reader of a person's interventions (F-194; `docs/design.md`, "Metrics and healing"): each
  is one row in `Acts`, its actor the person (`person:`, `"person"` by default, or the name an
  app gives), its target the agent, read from a fact and never guessed, so the metrics count
  them from the ledger (`CodingAgentFramework.Metrics`). It acts on nothing.

  **Typed input** (act `typed`): a `UserPromptSubmit` that `Intake` posted for an interactive
  agent's session (a main session, or a delegate started `interactive: true`), whose prompt
  carries no mark of a row `Mailbox` handed that agent. Every text the framework puts into a
  session carries its row's mark, `[delivery <uuid>]` (`Mailbox.Transport`): typed by the
  `Inlet`, the prompt of a start, a waiter's text. A headless delegate has no box a person types
  in, so its prompts are never read here. A row whose session no agent row names yet decides
  nothing until `settle:` ms (a minute by default) after it was written, then is passed by.

  **An interrupt** (act `interrupt`): Claude Code's interrupt line in an interactive agent's
  transcript (`Transcripts.Fold`'s `interrupts`: `[Request interrupted by user]`, or `… for
  tool use]`) on a turn the framework did not interrupt: no row in `Acts` of act `interrupt` on
  that agent was claimed between the prompt that opened the turn and the line, each `slack:` ms
  wide (5 s by default) for the two clocks. The framework's own interrupt (a parent's fix) is
  its row there already.

  **A viewer attached** is not read: no part owns a tmux hook to read `client-attached` by
  (F-194's build note says what that needs).

  One fact is one row: each is recorded under its state (`Acts.record/7`'s `state:`),
  `typed:<host>:<intake id>` or `interrupt:<agent>:<line uuid>`, so a read after a restart writes
  none twice. Each row's `detail` says what it was read from.

  The embedding app's tree starts one per host, after `Acts`, `Transcripts` and `Mailbox`. It
  reads at start, at each cue of `intake` or `transcripts` (`reads/0`), and by `check/2`.

      iex> alias CodingAgentFramework.Interventions
      iex> Interventions.marks("Review it. [delivery u-1]")
      ["u-1"]
      iex> Interventions.framework?(%{at: 9_000, turn_at: 1_000}, [%{claimed_at: 8_500}], 5_000)
      true
      iex> Interventions.framework?(%{at: 9_000, turn_at: 1_000}, [%{claimed_at: 500}], 100)
      false
  """

  use GenServer

  alias CodingAgentFramework.{Acts, Sessions, Transcripts}
  alias CodingAgentFramework.Intake.Table, as: IntakeTable
  alias CodingAgentFramework.Mailbox.Table, as: MailboxTable

  @acts ~w(typed interrupt)
  @settle 60_000
  @slack 5_000
  @timeout 30_000

  @doc """
  Starts the reader. Options: `agents:` (a `Sessions.Agents` reader), `transcripts:`,
  `intake_db:` (the file of `Intake`'s table), `mailbox_db:` (the file of `Mailbox`'s), `acts:`,
  `host:`, and optionally `person:` (the actor of its rows, default `"person"`), `settle:` and
  `slack:` (ms), and `clock:` (wall-clock ms).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Reads now. Answers `{:ok, %{recorded: states}}` (the states it wrote rows for), or `Acts`'
  answer when a write did not go.
  """
  @spec check(GenServer.server(), keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def check(reader, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    GenServer.call(reader, :check, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_reader}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @timeout)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @doc "Asks for a read without waiting for it. Answers `:ok` at once."
  @spec cue(pid, map) :: :ok
  def cue(reader, _cue \\ %{}) do
    send(reader, :check)
    :ok
  end

  @doc "What it reads, for `Cues`: `Intake`'s rows and the transcripts."
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(intake transcripts), cue: &cue/2}

  @doc "The uuids of the rows whose marks `text` carries, as `Mailbox.Transport` writes them."
  @spec marks(term) :: [String.t()]
  def marks(text) when is_binary(text),
    do: for([_, uuid] <- Regex.scan(~r/\[delivery ([^\]\s]+)\]/, text), do: uuid)

  def marks(_), do: []

  @doc """
  Whether the framework interrupted the turn an interrupt line `line` ended: one of `acts` (its
  rows of act `interrupt` on that agent) was claimed between the turn's prompt and the line,
  each `slack` ms wide. Pure.
  """
  @spec framework?(map, [map], non_neg_integer) :: boolean
  def framework?(%{at: at} = line, acts, slack) when is_integer(at) do
    from = (line[:turn_at] || 0) - slack
    Enum.any?(acts, &(is_integer(&1.claimed_at) and &1.claimed_at in from..(at + slack)//1))
  end

  def framework?(_line, _acts, _slack), do: false

  @impl true
  def init(opts) do
    acts = Keyword.fetch!(opts, :acts)

    with {:ok, idb} <- IntakeTable.open(Keyword.fetch!(opts, :intake_db)),
         {:ok, mdb} <- MailboxTable.open(Keyword.fetch!(opts, :mailbox_db)),
         {:ok, rows} <- Acts.rows(acts, act: @acts) do
      s = %{
        agents: Keyword.fetch!(opts, :agents),
        transcripts: Keyword.fetch!(opts, :transcripts),
        intake: idb,
        mailbox: mdb,
        acts: acts,
        host: Keyword.fetch!(opts, :host),
        person: Keyword.get(opts, :person, "person"),
        settle: Keyword.get(opts, :settle, @settle),
        slack: Keyword.get(opts, :slack, @slack),
        clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
        # The states already recorded, and the `Intake` row read up to: a restart reads every
        # row again, and the states keep each fact to one row.
        seen: MapSet.new(rows, & &1.state),
        past: 0
      }

      send(self(), :check)
      {:ok, s}
    else
      {_, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:check, _from, s) do
    {reply, s} = check_now(s)
    {:reply, reply, s}
  end

  @impl true
  def handle_info(:check, s), do: {:noreply, elem(check_now(s), 1)}

  defp check_now(s) do
    rows = Sessions.Agents.rows(s.agents)
    interactive = for r <- rows, not Sessions.Agents.headless?(r), into: %{}, do: {r.name, r}
    # A move keeps the session's id on its new account, so the id alone names the agent.
    by_session = for %{session_id: sid} = r <- rows, is_binary(sid), into: %{}, do: {sid, r.name}
    {typed, past} = typed(s, interactive, by_session)
    facts = typed ++ Enum.flat_map(Map.values(interactive), &interrupts(s, &1))

    # A write that did not go keeps the place, so its prompt is read again.
    Enum.reduce_while(facts, {:ok, s, []}, fn fact, {:ok, s, done} ->
      case record(s, fact) do
        {:ok, s, :new} -> {:cont, {:ok, s, done ++ [fact.state]}}
        {:ok, s, :seen} -> {:cont, {:ok, s, done}}
        other -> {:halt, {other, s}}
      end
    end)
    |> case do
      {:ok, s, done} -> {{:ok, %{recorded: done}}, %{s | past: past}}
      {other, s} -> {other, s}
    end
  end

  defp record(s, %{state: state} = fact) do
    if MapSet.member?(s.seen, state) do
      {:ok, s, :seen}
    else
      fields = [detail: fact.detail]

      case Acts.record(s.acts, s.person, fact.agent, fact.act, :verified, fields, state: state) do
        {:ok, _} -> {:ok, %{s | seen: MapSet.put(s.seen, state)}, :new}
        {:refused, {:already_claimed, _}} -> {:ok, %{s | seen: MapSet.put(s.seen, state)}, :seen}
        other -> other
      end
    end
  end

  # The prompts `Intake` posted since the last read: each is the framework's when it carries a
  # mark of a row handed to its agent, else a person's. The place moves past every row decided.
  defp typed(s, interactive, by_session) do
    now = s.clock.()
    rows = IntakeTable.events(s.intake, s.host, "UserPromptSubmit", s.past)

    {facts, past, _open} =
      Enum.reduce(rows, {[], s.past, false}, fn row, {facts, past, open} ->
        name = by_session[row.session_id]

        cond do
          name == nil and now - row.written_at < s.settle ->
            {facts, past, true}

          name == nil or not Map.has_key?(interactive, name) ->
            {facts, if(open, do: past, else: row.id), open}

          true ->
            prompt = decode(row.data)["prompt"]
            framework = Enum.any?(marks(prompt), &handed?(s, &1, name))
            fact = if framework, do: [], else: [typed_fact(s, row, name, prompt)]
            {facts ++ fact, if(open, do: past, else: row.id), open}
        end
      end)

    {facts, past}
  end

  defp typed_fact(s, row, name, prompt) do
    chars = if is_binary(prompt), do: String.length(prompt), else: 0

    %{
      state: "typed:#{s.host}:#{row.id}",
      agent: name,
      act: :typed,
      detail: %{intake: row.id, session_id: row.session_id, at: row.written_at, chars: chars}
    }
  end

  defp handed?(s, uuid, name),
    do: match?(%{to_agent: ^name}, MailboxTable.by_uuid(s.mailbox, uuid))

  # The interrupt lines of an interactive agent's transcript that no act of the framework's
  # explains.
  defp interrupts(s, %{session_id: sid, account: account, name: name})
       when is_binary(sid) and is_binary(account) do
    with {:ok, %{interrupts: lines}} <- Transcripts.session(s.transcripts, account, sid),
         new = Enum.reject(lines, &MapSet.member?(s.seen, interrupt_state(name, &1))),
         true <- new != [],
         {:ok, own} <- Acts.rows(s.acts, act: "interrupt", target: name) do
      own = Enum.reject(own, &(&1.actor == s.person))

      for line <- new, not framework?(line, own, s.slack) do
        %{
          state: interrupt_state(name, line),
          agent: name,
          act: :interrupt,
          detail: %{
            session_id: sid,
            uuid: line.uuid,
            at: line.at,
            turn_at: line.turn_at,
            tool_use: line.tool_use
          }
        }
      end
    else
      _ -> []
    end
  end

  defp interrupts(_s, _row), do: []

  defp interrupt_state(name, line), do: "interrupt:#{name}:#{line.uuid || line.at}"

  defp decode(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = data} -> data
      _ -> %{}
    end
  end

  defp decode(_), do: %{}
end
