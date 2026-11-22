defmodule CodingAgentFramework.Mover do
  @moduledoc """
  Moves a session, a main session or a delegate, from one Claude account to another
  (`docs/design.md`, "Moving it"; `model/tla/Move.tla`). It owns no table: a move's phase is a
  field of the agent row (`Sessions.begin_move/4`, `Sessions.move_phase/5`), so a restart goes
  on from the step the row names. The caller's supervision tree starts one per host, with no
  name, after `Sessions`, `Mailbox`, `Usage` and `Acts`:

      {:ok, mover} = Mover.start_link(host: "laptop", sessions: sessions, sessions_db: db,
        mailbox: mailbox, accounts: accounts, usage: usage, acts: acts, launch: &launch/1)
      Mover.move(mover, "operator", "app-main")
      #=> {:ok, %{act: 12, from: "work", to: "spare"}}

  **A move** is an act in `Acts` (act `move`, by the caller, on the session's current process),
  then these phases on the row:

  1. `draining`: `Mailbox` hands the session no row that would start a turn and `Delegates`
     starts no delegate under it (`Sessions.Agents.moving?/1`). The drain is clear once no
     `Mailbox` row to it is `sending` and no `run_delegate` call of it waits (`Mailbox.awaited/3`).
  2. `stopping`: `Sessions.stop/3` `for: :move`, the SIGTERM by the row's pid and start time
     once the session reads idle (or, at a usage limit, shows Claude Code's own wait or its
     menu: F-191) and no row to it is sending, then the wait for the exit and
     the dead socket. A stop refused (a turn runs) is asked again only on a reader's cue
     (`registry:`, `stream:`), when the evidence of the turn can have changed. An interactive
     session's file says `shell`, not `idle`, while a background command runs after its turn
     ended (Claude Code 2.1.322), so the stop waits for its background commands too.
  3. `copying`: once the row is free (its process gone, by pid and start time, and its socket
     dead), the transcript `<config>/projects/<cwd>/<session id>.jsonl`, the directory beside
     it of that name and `<config>/session-env/<session id>` are copied into the other
     account's config directory, each under a temporary name and renamed into place, and the
     transcript's size checked against the source's.
  4. `resuming`: `usable:` reads the other account again (the app may have flagged it during
     the drain and the stop: F-210), then `Sessions.resume/6` on it with the same session id
     and name, the launch the app gives (`launch:`, without options, so the row's own are taken again),
     and so Remote Control and the waiter's hook of that account. An interactive session's
     first due row goes in as the resume's prompt (`Mailbox.launch/4`, then `launched/3`), since
     the resumed process has no waiter until a turn of it ends. A headless session's goes as
     the first line by its stream, which Claude Code headless needs before it writes its init
     (F-152); with nothing due, the move first stores a word of its own (F-193), a notice under
     `move:<agent>:<deadline>` that says it was moved and to go on. Once the row runs there the
     move is done: its fields are cleared and its act `verified`.

  **How each failure settles**, the session running on one account, never two and never none:

  - a drain or a stop not done by the move's deadline (`timeout:`, while the old process still
    runs): the move is given up, the session runs on on its account, the act `failed`;
  - the old process ending by itself during the move: the move goes on from the copy;
  - a stop whose process outlives its deadline: the row stays `stopping` (`Recoveries` ends it
    by its record), and the move goes on once the row is free;
  - a copy or a resume refused on the other account, `usable:` refusing it at the resume
    included: the act `failed`, and the session is resumed on its own account, where its
    transcript is, once `usable:` takes that one;
  - that resume refused too: the session runs on no account. Its row says why and the fault
    ledger has an act `move` `failed` with reason `stranded`, for a person;
  - an agent at a usage limit (F-191): its copy or resume refused leaves its process gone, the
    act `failed`, never resumed on its own account, which is at its limit; the limit's healer
    asks a person, and its word at the reset resumes it;
  - a restart at any step: the step the row names is taken again. A resume is asked again only
    while the row is free, so `Sessions`, which starts no name whose process may live, never
    runs two.

  `cue/2` takes the cues `reads/0` declares; each answers at once.
  """

  use GenServer

  require Logger

  alias CodingAgentFramework.{Accounts, Acts, Mailbox, Sessions, Transcripts, Usage}
  alias CodingAgentFramework.Sessions.Agents

  @step 5_000
  # The longest a drain and its stop may take before the move is given up.
  @timeout 1_800_000
  # Each stop's own deadline in `Sessions`.
  @stop 30_000
  # A resume's deadline in `Sessions`, which bounds the launch that carries its first row.
  @resume 30_000
  # The word a headless session moved with nothing due goes on with (F-193).
  @moved "This session was moved between Claude accounts. Go on with your task from where it stopped."

  @type outcome(ok) :: {:ok, ok} | {:refused, term} | {:unknown, term}

  @doc """
  Starts a `Mover`. Options: `host:`, `sessions:` (the host's `Sessions`), `sessions_db:` (its
  file, read through `Sessions.Agents`), `mailbox:`, `accounts:` (an `Accounts`), `usage:`,
  `acts:`, and `launch:`, a function of an agent row that answers `{:ok, launch}` for its
  resume on another account (`Sessions.resume/6`'s: its role and its `cwd:` or `worktree:`,
  `claude:`, `env:`, `tool_timeout:`, `mcp:`; with no `model:` the row's is taken), a refusal (the move then goes back, as
  for a refused resume), or `{:unknown, reason}` (asked again at the next cue). Optionally `timeout:`
  (ms, 30 min by default), `stop:` (ms, each stop's own deadline, 30 s by default), `usable:` (a
  function of an account answering `{:ok, account}` (the `Accounts.Account`) for one a launch
  may run on now, else why not: `CodingAgentFramework.Logins.usable/3`, prepared and logged in,
  then the app's own check; read at the pick and again at each resume; by default
  `Accounts.ready/2`) and `clock:`
  (wall-clock ms).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Moves agent `name`, for `actor`, to account `to:` (by default the one `Usage.pick/4` finds
  among the others that are usable: by `usable:`, the most room). Answers once the drain began: `{:ok, %{act,
  from, to}}`, the rest following on the row; or `{:refused, reason}`, with nothing begun:
  `:no_session`, `{:not_running, status}`, `{:moving, phase}`, `{:same_account, to}`,
  `{:unknown_account, to}`, `{:account, to, reason}` for a named account `usable:` refuses (not
  logged in, say: F-189's new-3), `Usage`'s or `Accounts`' refusal, or `Acts`' (`{:claimed, by}` for a
  move of that process already under way). Who may move whom is the caller's check
  (`Grants.may_fix?/3`).

  An agent at a usage limit (its row's `usage_limit`, F-191; `Move.tla`'s LimitMove) moves
  from a running process or from one gone at its limit, whose move skips the drain and the stop.
  `act:` is a claim in `Acts` the caller made already (the limit's healer's, once per limit):
  the move takes it in place of its own, marks it acted, and settles it as its own, a refusal
  before the drain included. The caller reads the move's end from that row.
  """
  @spec move(GenServer.server(), String.t(), String.t(), keyword) :: outcome(map)
  def move(mover, actor, name, opts \\ []),
    do: call(mover, {:move, actor, name, Keyword.get(opts, :to), Keyword.get(opts, :act)})

  @doc """
  The account a move of agent `name` would go to now, by the same pick as `move/4`'s with no
  `to:`, and with nothing begun: `{:ok, account}` or the refusal `move/4` would answer
  (`{:none_usable, reasons}`, `{:allowance, retry_at}`, `{:usage, :unread}`, `:no_session`).
  The limit's healer asks it before it claims a move, so a limit with no other account that has
  room waits for its reset.
  """
  @spec room(GenServer.server(), String.t()) :: outcome(String.t())
  def room(mover, name), do: call(mover, {:room, name})

  @doc """
  The framework's `PreToolUse` callback, for `Intake`'s `pre_tool_use:` (F-142's new-2). The
  drain stops what the framework starts; a background command is the session's own, so while
  the agent's row has a move phase this denies a `Bash` call with `run_in_background` and the
  `Monitor` tool, with a reason the agent reads. Any other call goes to `then`, the app's own
  callback (`:pass` with none). It reads the agent rows through `agents`
  (`Sessions.Agents.open/2`), in the callback's own process.

      Intake.start_link(db: db, host: "laptop", agent: &Agents.by_session(agents, &1, &2),
        pre_tool_use: Mover.pre_tool_use(agents, &MyApp.pre_tool_use/1))
  """
  @spec pre_tool_use(Agents.t(), (map -> term) | nil) :: (map -> term)
  def pre_tool_use(agents, then \\ nil) do
    fn event ->
      row = is_binary(event[:agent]) && Agents.get(agents, event.agent)

      cond do
        row && Agents.moving?(row) && background?(event) ->
          {:deny,
           "This session is moving to another Claude account. Start no background command " <>
             "or monitor now: run it in the foreground, or after the move."}

        then ->
          then.(event)

        true ->
          :pass
      end
    end
  end

  defp background?(%{tool_name: "Bash", tool_input: %{"run_in_background" => true}}), do: true
  defp background?(%{tool_name: "Monitor"}), do: true
  defp background?(_event), do: false

  @doc "Hands it a cue; every move under way on the host takes its next step that can."
  @spec cue(GenServer.server(), map) :: :ok
  def cue(mover, %{topic: topic}), do: GenServer.cast(mover, {:cue, evidence?(topic)})

  @doc """
  What `Mover` reads, for `Cues`: the agent rows (a stop's or a resume's end), `Mailbox`'s rows
  (the drain), and the readers of a turn's end (`registry`, `stream`).
  """
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(sessions mailbox registry stream), cue: &cue/2}

  defp evidence?("registry:" <> _), do: true
  defp evidence?("stream:" <> _), do: true
  defp evidence?(_), do: false

  defp call(mover, request) do
    GenServer.call(mover, request, 3 * @step)
  catch
    :exit, {:noproc, _} -> {:refused, :no_mover}
    :exit, {:timeout, _} -> {:unknown, {:timeout, 3 * @step}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    keys = ~w(host sessions mailbox accounts usage acts launch)a
    s = Map.new(keys, &{&1, Keyword.fetch!(opts, &1)})

    with {:ok, agents} <- Agents.open(Keyword.fetch!(opts, :sessions_db), s.host) do
      s =
        Map.merge(s, %{
          agents: agents,
          timeout: Keyword.get(opts, :timeout, @timeout),
          stop: Keyword.get(opts, :stop, @stop),
          usable: Keyword.get(opts, :usable, &Accounts.ready(s.accounts, &1)),
          clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
          calls: %{}
        })

      {:ok, s, {:continue, :start}}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  # A restart goes on from each row's phase. A move act this host's last life marked acted and
  # never wrote on its row began nothing: it is settled failed.
  @impl true
  def handle_continue(:start, s) do
    with {:ok, open} <- Acts.rows(s.acts, act: "move", status: "acted") do
      for act <- open,
          %{} = row <- [Agents.get(s.agents, act.target)],
          row.move_act != act.id,
          do: Acts.settle(s.acts, act.id, :failed, reason: :interrupted)
    end

    for row <- moving(s), is_integer(row.move_deadline), do: wake(s, row.move_deadline)
    {:noreply, steps(s, :evidence)}
  end

  @impl true
  def handle_cast({:cue, evidence?}, s),
    do: {:noreply, steps(s, if(evidence?, do: :evidence, else: :cue))}

  @impl true
  def handle_call({:move, actor, name, to, given}, _from, s) do
    row = Agents.get(s.agents, name)

    with %{} <- row || {:refused, :no_session},
         false <- Agents.moving?(row) and {:refused, {:moving, row.move}},
         true <- movable?(row) or {:refused, {:not_running, row.status}},
         {:ok, to} <- target(s, row, to),
         {:ok, _} <- Accounts.ready(s.accounts, to),
         {:ok, act} <- claim(s, actor, row, given) do
      deadline = s.clock.() + s.timeout

      case Sessions.begin_move(s.sessions, name, %{to: to, act: act, deadline: deadline}) do
        {:ok, row} ->
          wake(s, deadline)
          {:reply, {:ok, %{act: act, from: row.move_from, to: to}}, step(s, row, :evidence)}

        not_begun ->
          Acts.answered(s.acts, act, not_begun)
          {:reply, not_begun, s}
      end
    else
      refused ->
        # The caller's claim is settled by this move's answer, a refusal as well.
        if given, do: Acts.answered(s.acts, given, refused)
        {:reply, refused, s}
    end
  end

  def handle_call({:room, name}, _from, s) do
    reply =
      case Agents.get(s.agents, name) do
        nil -> {:refused, :no_session}
        row -> target(s, row, nil)
      end

    {:reply, reply, s}
  end

  # A stop or a resume `Sessions` answered.
  @impl true
  def handle_info({ref, answer}, s) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Enum.find(s.calls, fn {_name, call} -> call.ref == ref end) do
      nil ->
        {:noreply, s}

      {name, call} ->
        s = %{s | calls: Map.delete(s.calls, name)}
        {:noreply, answered(s, Agents.get(s.agents, name), call.kind, answer)}
    end
  end

  def handle_info(:deadline, s), do: {:noreply, steps(s, :evidence)}

  # The act, claimed on the session's current process and the moves of it already ended, so a
  # second press while one is under way is refused, and a press after one ended is new. It is
  # acted before the row's phase is written: a cut between the two is settled at the next start.
  # A claim the caller made (the limit's healer's) is marked acted here, as this move's own.
  defp claim(s, _actor, _row, given) when is_integer(given) do
    with {:ok, _} <- Acts.acted(s.acts, given), do: {:ok, given}
  end

  defp claim(s, actor, row, nil) do
    with {:ok, ended} <-
           Acts.rows(s.acts, target: row.name, act: "move", status: ~w(settled interrupted)),
         state = %{
           pid: row.pid,
           start: row.proc_start,
           account: row.account,
           moves: length(ended)
         },
         {:ok, act} <- Acts.claim(s.acts, actor, row.name, state, :move),
         {:ok, _} <- Acts.acted(s.acts, act) do
      {:ok, act}
    end
  end

  defp target(s, row, nil) do
    case Usage.readings(s.usage, timeout: @step) do
      {:ok, %{readings: readings}} ->
        # F-181: among the usable others, the one with the most room.
        Usage.pick(readings, s.accounts.names -- [row.account], System.os_time(:second),
          usable: s.usable
        )

      :unread ->
        {:refused, {:usage, :unread}}

      other ->
        other
    end
  end

  defp target(_s, %{account: to}, to), do: {:refused, {:same_account, to}}

  # F-189's new-3: a named account is read by `usable:` before the claim, as the pick reads each.
  defp target(s, _row, to) do
    with true <- to in s.accounts.names or {:refused, {:unknown_account, to}} do
      case s.usable.(to) do
        {:ok, _} -> {:ok, to}
        {_, reason} -> {:refused, {:account, to, reason}}
      end
    end
  end

  # A running agent, or one at a usage limit whose process is gone (F-191).
  defp movable?(row), do: Agents.running?(row) or limited_gone?(row)

  defp limited_gone?(row), do: Agents.free?(row) and Agents.limit(row) != nil

  defp moving(s), do: Agents.moving(s.agents)

  defp steps(s, why), do: Enum.reduce(moving(s), s, &step(&2, &1, why))

  # One step of a row's move, by its phase; a row with a stop or a resume of its own under way
  # waits for that call's answer.
  defp step(s, row, why) do
    cond do
      Map.has_key?(s.calls, row.name) -> s
      row.move == "draining" -> drain(s, row)
      row.move == "stopping" -> stopping(s, row, why)
      row.move == "copying" -> copy(s, row)
      row.move == "resuming" -> resuming(s, row)
      true -> s
    end
  end

  # Move.tla's Drain and Cleared, then StopAsked.
  defp drain(s, row) do
    cond do
      Agents.free?(row) -> copy(s, row)
      not Agents.running?(row) -> s
      past?(s, row) -> give_up(s, row, {:timeout, :draining})
      clear?(s, row) -> stop(s, phase(s, row, "stopping"))
      true -> s
    end
  end

  # The stop asked, or asked again on a reader's cue while its process still runs. Once the
  # SIGTERM went and the process ends, the move goes on whatever the deadline.
  defp stopping(s, row, why) do
    cond do
      Agents.free?(row) -> copy(s, row)
      not Agents.running?(row) -> s
      past?(s, row) -> give_up(s, row, {:timeout, :stopping})
      why == :evidence and clear?(s, row) -> stop(s, row)
      true -> s
    end
  end

  defp stop(s, row),
    do:
      async(s, row, :stop, fn ->
        Sessions.stop(s.sessions, row.name, for: :move, timeout: s.stop)
      end)

  # Copied: the old process is gone, so its transcript is final.
  defp copy(s, row) do
    row = if row.move == "copying", do: row, else: phase(s, row, "copying")

    case copied(s, row) do
      :ok -> resume(s, phase(s, row, "resuming"))
      {:refused, why} -> back(s, row, {:copy, why})
    end
  end

  # Resumed, or waiting for `Sessions` to settle a resume it answered unknown. A row that runs
  # on the move's account is moved, whether or not this process saw the resume's answer.
  defp resuming(s, row) do
    cond do
      Agents.running?(row) and row.account == row.move_to -> done(s, row)
      Agents.free?(row) -> resume(s, row)
      true -> s
    end
  end

  # F-210 (F-209's new-1; `Move.tla`'s TargetTaken, MoveBack and Stranded): the account is read
  # by `usable:` again at the resume, not only at the pick, since a drain and its stop may take
  # the move's whole timeout and the app may flag the account meanwhile. Refused, the move goes
  # back (`answered/4`): to its own account, read the same way, and with that refused too the
  # row is left down with the reason.
  defp resume(s, row) do
    with {:ok, account} <- s.usable.(row.move_to),
         {:ok, launch} <- s.launch.(row),
         {:ok, launched} <- launch_first(s, row) do
      launch = Keyword.delete(launch, :options)

      launch =
        cond do
          launched == nil -> launch
          Agents.headless?(row) -> launch ++ [first: Map.take(launched, [:uuid, :text])]
          true -> launch ++ [prompt: launched.text]
        end

      mailbox = s.mailbox

      async(s, row, :resume, fn ->
        answer =
          Sessions.resume(s.sessions, row.name, account, row.session_id, launch, timeout: @resume)

        if launched, do: Mailbox.launched(mailbox, launched.id, answer)
        answer
      end)
    else
      # Not known yet (a part the launch needs has not started, or a row to the session is
      # still in flight): the next cue asks again.
      {:unknown, why} ->
        Logger.debug("mover: no resume of #{row.name} yet: #{inspect(why)}")
        s

      refused ->
        answered(s, row, :resume, refused)
    end
  end

  # The first row due to an interactive session goes in as its resume's prompt (F-142, item 3):
  # the resumed process has no waiter until a turn of it ends, and the `Inlet` types no long
  # row, so a report would otherwise wait for a person's prompt. A headless session's first row
  # goes by its stream as the line the resume writes right after the hold, as `Delegates`' does
  # (F-152: Claude Code headless writes its init only after it read a line; F-191, the word to go
  # on of a limited delegate). A row still `sending` (a launch a restart cut, say) settles first.
  # A headless session with nothing due gets the move's own word first (F-193, `Move.tla`'s
  # OwnWord), so its resume always has a first line.
  defp launch_first(s, row) do
    via = if Agents.headless?(row), do: :stream, else: :launch

    case marked(s, row, via) do
      {:ok, :none} when via == :stream ->
        with :ok <- own_word(s, row) do
          case marked(s, row, via) do
            {:ok, :none} -> {:unknown, :no_first_line}
            marked -> marked
          end
        end

      {:ok, :none} ->
        {:ok, nil}

      marked ->
        marked
    end
  end

  defp marked(s, row, via) do
    case Mailbox.launch(s.mailbox, row.name, s.clock.() + @resume + @step, via: via) do
      {:ok, %{id: _, text: _} = launched} -> {:ok, launched}
      {:ok, :none} -> {:ok, :none}
      {:refused, :no_transcripts} -> {:ok, nil}
      {:refused, {:sending, ids}} -> {:unknown, {:sending, ids}}
      {_, why} -> {:unknown, {:launch, why}}
    end
  end

  # A notice no turn answers, under the move's key: one per move, whatever account its resume
  # goes to (the move's deadline stays on the row through a way back, which clears its act).
  defp own_word(s, row) do
    key = "move:#{row.name}:#{row.move_deadline}"

    case Mailbox.notify(s.mailbox, row.name, @moved, key: key, kind: :notice) do
      {:ok, _} -> :ok
      {_, why} -> {:unknown, {:word, why}}
    end
  end

  defp answered(s, nil, _kind, _answer), do: s

  defp answered(s, row, :stop, answer) do
    with {:refused, why} <- answer,
         do: Logger.debug("mover: the stop of #{row.name} was refused: #{inspect(why)}")

    step(s, row, :cue)
  end

  defp answered(s, row, :resume, {:ok, _}), do: done(s, row)

  defp answered(s, %{move_to: to, move_from: to} = row, :resume, {:refused, why}) do
    if Agents.limit(row), do: left_gone(s, row, {:resume, why}), else: stranded(s, row, why)
  end

  defp answered(s, row, :resume, {:refused, why}), do: back(s, row, {:resume, why})
  defp answered(s, row, :resume, _unknown), do: step(s, row, :cue)

  # The move is done: its act settled first, so a restart before the row is cleared finds the
  # row on the new account and only clears it.
  defp done(s, row) do
    if row.move_act, do: Acts.answered(s.acts, row.move_act, {:ok, row.account})
    Sessions.move_phase(s.sessions, row.name, nil)
    s
  end

  # Given up before the SIGTERM: the session runs on on its own account.
  defp give_up(s, row, why) do
    if row.move_act, do: Acts.settle(s.acts, row.move_act, :failed, reason: why)
    Sessions.move_phase(s.sessions, row.name, nil)
    s
  end

  # The other account refused the copy or the resume: the act failed, and the session goes back
  # to its own account, where its transcript is. An agent at a usage limit does not (F-191,
  # `Move.tla`'s Back): its own account is at the limit, so its process stays gone and its row
  # free, and the limit's healer, which reads the act, asks a person.
  defp back(s, row, why) do
    if Agents.limit(row), do: left_gone(s, row, why), else: go_back(s, row, why)
  end

  defp left_gone(s, row, why) do
    Logger.warning("mover: #{row.name} stays gone at its usage limit: #{inspect(why)}")
    if row.move_act, do: Acts.settle(s.acts, row.move_act, :failed, reason: why)
    Sessions.move_phase(s.sessions, row.name, nil)
    s
  end

  defp go_back(s, row, why) do
    Logger.warning("mover: #{row.name} goes back to #{row.move_from}: #{inspect(why)}")
    if row.move_act, do: Acts.settle(s.acts, row.move_act, :failed, reason: why)

    case Sessions.move_phase(s.sessions, row.name, "resuming", to: row.move_from, act: nil) do
      {:ok, _} -> resume(s, Agents.get(s.agents, row.name))
      _ -> s
    end
  end

  # Its own account refused it too: no process of it runs. The fault ledger shows it.
  defp stranded(s, row, why) do
    Logger.warning("mover: #{row.name} runs on no account: #{inspect(why)}")
    Acts.record(s.acts, actor(s), row.name, :move, :failed, reason: {:stranded, why})
    Sessions.move_phase(s.sessions, row.name, nil)
    s
  end

  defp actor(s), do: "mover:" <> s.host

  defp phase(s, row, phase) do
    case Sessions.move_phase(s.sessions, row.name, phase) do
      {:ok, _} -> %{row | move: phase}
      _ -> row
    end
  end

  defp clear?(s, row) do
    Mailbox.open_to(s.mailbox, row.name, status: :sending) == {:ok, []} and
      Mailbox.awaited(s.mailbox, row.name) == {:ok, []}
  end

  defp past?(s, row), do: is_integer(row.move_deadline) and s.clock.() >= row.move_deadline

  defp async(s, row, kind, fun) do
    task = Task.async(fun)
    put_in(s.calls[row.name], %{ref: task.ref, kind: kind})
  end

  defp wake(s, at), do: Process.send_after(self(), :deadline, max(at - s.clock.(), 0) + 1)

  # The conversation, from the account the move leaves to the one it goes to
  # (`Transcripts.Copy`, which `Mains` copies a resume's with too).
  defp copied(s, row) do
    with {:ok, from} <- Accounts.config_dir(s.accounts, row.move_from),
         {:ok, to} <- Accounts.config_dir(s.accounts, row.move_to),
         true <- is_binary(row.session_id) or {:refused, :no_session_id},
         do: Transcripts.Copy.copy(from, to, row.cwd, row.session_id)
  end
end
