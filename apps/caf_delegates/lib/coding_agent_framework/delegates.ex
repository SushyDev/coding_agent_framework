defmodule CodingAgentFramework.Delegates do
  @moduledoc """
  The delegate protocol (`docs/design.md`, "The delegate protocol"; `model/tla/Delegate.tla`),
  up to a held report: a start, the brief, a finish or a kill, one resume, and the report held
  durably. Delivering a report into its parent needs `Screen`, which is not built:
  `deliver/2` is refused as `:no_delivery`.

  The caller's supervision tree starts one per host, with no name, and gives it the host's
  `Sessions`, `Stream` and a `Transcripts` per account, the instance's `Usage` and `Accounts`,
  the projects as data, and what every launch shares:

      {:ok, delegates} = Delegates.start_link(host: "laptop", db: db, sessions_db: db,
        sessions: sessions, stream: stream, usage: usage, accounts: accounts,
        transcripts: %{"work" => transcripts}, launch: [claude: claude, env: env, tool_timeout: 3_600_000],
        projects: %{"app" => %{name: "app", repo: "/src/app", trunk: "main", setup: [],
          setup_timeout: 60_000, env: %{}, branches: ~r/\\Aunit\\//, cap: 3}})
      Delegates.start_delegate(delegates, "main", "app", "unit/review", "opus", "Review it.")
      #=> {:ok, %{id: 1, name: "app-unit-review", session_id: "…", account: "work",
      #=>   brief: {:ok, %{uuid: "…"}}}}

  **A start** checks the project, the branch against the project's pattern and the parent's cap
  (`Delegates.Turn`), picks the account with the most allowance left (`Usage.pick/2`), and
  writes its row first, as `starting`, with the uuid its brief will go in under. A task then
  starts the session through `Sessions`, role `:delegate` in the project's worktree, and its
  answer moves the row: `running`, then the brief through `Stream` under that uuid, which
  `Stream` refuses a second time; or `refused`. A row a restart left `starting` is settled by
  `Sessions`' row of its call, once that row is settled; with no such row by the row's deadline,
  the call never reached `Sessions`, and the row is refused as `interrupted`.

  **A running delegate** is read from its `Stream` row at each cue: once the turn's message is
  delivered and a `result` came after it, the row is `finished` with that result's text as its
  report. When its process is gone first, the transcript says whether it had given its last
  reply: if so it finished with that reply. Otherwise it is resumed once, after `Sessions`' row
  of it has ended: the row counts the resume first, as `resuming`, then `Sessions.resume/6`
  follows it again and the resumed process takes the brief again (when it had not gone in) or
  `Turn.resumed/0`. A second such kill, or a refused resume, is `failed`, and that is the
  report. A row leaves `running` once.

  Each report is `held` in the table, with a mark of its own, and survives restarts. A call that
  waits on it (`await_report/4`) takes it as it is held: it is then `answering`, never held,
  until the caller says its answer reached the agent (`answered/2`) or did not (`release/2`,
  which holds it again). `Delegates` watches the process that waited: when it ends first, the
  report is held again, as a release holds it. A restart holds every `answering` report again,
  so a report is never lost to an answer that did not arrive: it is delivered as a message, at
  least once.

  **A parent's fix** (`fix_state/3`, `fix/5`; `Team.tla`'s `FixActs`) is checked and claimed
  by its caller (`MCP`); here it acts only while the state it claimed is still the delegate's,
  read again in the same step, and through the part that owns the act: `Stream` for an
  interrupt or an answer, the resume path above for a resume, `Sessions.stop/4` for a stop.

  It reads every row again when it starts and at each `cue/2`; the embedding app wires the cues of
  `Sessions`, `Stream` and `Transcripts` to it. After each write `notify` gets `%{topic:
  "delegates:<host>", ids: [id]}`.
  """

  use GenServer

  alias CodingAgentFramework.{Accounts, Sessions, Stream, Transcripts, Usage}
  alias CodingAgentFramework.Delegates.{Table, Turn}

  # Sessions' own timeout for a start or a resume; its git bounds and slack come on top.
  @call 30_000
  @slack 120_000
  @step 5_000
  @twice "The delegate was killed twice before its last reply; it is not resumed again."

  @doc """
  Starts a `Delegates`. Options: `host:` (the name of the host `sessions:` and `stream:` run
  on), `db:`, `sessions_db:` (the file `Sessions`' table is in), `usage:`, `accounts:`,
  `transcripts:` (account to its `Transcripts`), `projects:` (name to a project as
  `Sessions.Worktree.project/1` reads it, with `branches:` and `cap:`), `launch:` (`claude:`,
  `env:` and `tool_timeout:` for `ClaudeCLI`), and optionally `notify:`, `clock:` (wall-clock
  ms) and `mcp:`, a function of the delegate's name that answers `{:ok, path}`, its own MCP
  config (the embedding app gives `MCP.issue/2`), or a refusal. Each start and resume calls it
  just before its launch and adds the path as `ClaudeCLI`'s `mcp:`; its refusal refuses the
  start, and with no `mcp:` a delegate runs without the framework's tools.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Starts a delegate of `parent` (the main session's name, which the caller states until
  `Mains` exists) on `branch` of `project`, with `model`, and writes `brief` as its first
  message. Answers `{:ok, %{id, name, session_id, account, brief}}`, `brief` being `Stream`'s
  answer to that write; `{:refused, reason}`; or `{:unknown, reason}`, when its row stays
  `starting` for a later read to settle. Option `:timeout`: what the caller waits (default
  300 000 ms); the start goes on past it.
  """
  def start_delegate(delegates, parent, project, branch, model, brief, opts \\ []),
    do: call(delegates, {:start, parent, project, branch, model, brief}, opts, 300_000)

  @doc "The reports `parent` holds: `{:ok, [%{id, name, branch, status, text, mark}]}`."
  def held(delegates, parent, opts \\ []), do: call(delegates, {:held, parent}, opts, @step)

  @doc """
  Waits up to `timeout` ms for the report of `parent`'s delegate `id` and takes it, for a call
  that answers with it (`run_delegate`). Once the report is held, and only before the deadline,
  `Delegates` marks it `answering` in the same step, so it is not also delivered as a message;
  the caller then says `answered/2` or `release/2`, from the process that waited: when that
  process ends before it says either, the report is held again. Answers `{:ok, %{id, name, status, text}}`;
  `{:unknown, :timeout}` at the deadline, the report then held as any other; or `{:refused,
  reason}`: `{:no_delegate, id}`, `:answering`, `:answered`, `:awaited` (another call waits on
  it), or `{:refused, reason}` for a start that was refused.

      Delegates.await_report(delegates, "main", 1, 60_000)
      #=> {:ok, %{id: 1, name: "app-unit-review", status: "finished", text: "Done."}}
  """
  def await_report(delegates, parent, id, timeout) when is_integer(timeout) and timeout >= 0 do
    # The deadline is the caller's, on the node's clock: a request that waits in the queue does
    # not move it, so the report is never taken after the caller stopped waiting.
    deadline = System.monotonic_time(:millisecond) + timeout
    call(delegates, {:await, parent, id, deadline}, [timeout: timeout + @step], @step)
  end

  @doc """
  The answer with report `id` that `await_report/4` took has reached the agent: the report is
  `answered`, and never delivered as a message. Answers `{:ok, :answered}`; `{:refused,
  {:not_answering, report}}` when the report is not `answering`; or `{:refused, {:no_delegate,
  id}}`.

      Delegates.answered(delegates, 1)
      #=> {:ok, :answered}
  """
  def answered(delegates, id), do: call(delegates, {:answered, id}, [], @step)

  @doc """
  The answer with report `id` did not reach the agent (its write failed): the report is `held`
  again, with its mark, for a message. Answers `{:ok, :held}`, or a refusal as `answered/2`.
  """
  def release(delegates, id), do: call(delegates, {:release, id}, [], @step)

  @doc """
  Will deliver held report `id`: mark it sending, then type it with its mark through
  `Control`'s checked write once the parent's turn has ended, and settle it from the parent's
  transcript after a restart. Refused until `Screen` is built.
  """
  def deliver(_delegates, _id), do: {:refused, :no_delivery}

  @doc """
  The state of `parent`'s delegate `name` that a fix claims (`Team.tla`'s `epoch`), read after
  a read of `Stream`: the row's `id`, `status`, `resumes` and `report`, and from `Stream`'s row
  of its process the log's `offset` (each event read moves it), `gone`, `ending`, and the ids
  of the requests `held`; and whether `Sessions`' row of it has `ended`. A fix of one state acts once; any event, exit, end, answer, resume or
  report moves it. The latest row of that name is the delegate. Answers `{:ok, state}`, or
  `{:refused, {:no_delegate, name}}`, `{:refused, {:not_started, status}}`, or `Stream`'s.

      Delegates.fix_state(delegates, "main", "app-unit-review")
      #=> {:ok, %{id: 1, status: "running", resumes: 0, report: "none", offset: 812,
      #=>   gone: false, ending: false, held: ["req-…"], ended: false}}
  """
  def fix_state(delegates, parent, name),
    do: call(delegates, {:fix_state, parent, name}, [], 3 * @step)

  @doc """
  Fixes `parent`'s delegate `name`, only while `state` (`fix_state/3`'s, which the caller
  claimed) is still its state, read again here; else `{:refused, {:moved, now}}` and nothing
  acts. `fix` is:

  - `:interrupt`: `Stream.interrupt/3`;
  - `{:answer, request_id, label}`: `Stream.answer/5`, through the request the delegate holds;
  - `:resume`: a dead delegate (its process gone, the row `running`) goes down the resume path
    a cue takes, which counts its one resume first: `{:ok, :resuming}`. A live one is refused
    as `:live`, one already resumed as `:resumed_once`, one whose `Sessions` row has not ended
    as `:session_running`, and one the path finished instead (its transcript ends with its
    last reply) with its status;
  - `:stop`: `Sessions.stop/4` with `:report_delivered`, which writes `end_session` through
    `Stream`, only once the report is `answered` (or, once delivery is built, `delivered`); else `{:refused, {:report, report}}`.
  """
  def fix(delegates, parent, name, fix, state),
    do: call(delegates, {:fix, parent, name, fix, state}, [], 2 * @call)

  @doc "Hands it a reader's cue: every row is read again. Answers `:ok` at once."
  def cue(delegates, %{topic: _}), do: GenServer.cast(delegates, :cue)

  defp call(delegates, request, opts, default) do
    timeout = Keyword.get(opts, :timeout, default)
    GenServer.call(delegates, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_delegates}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, default)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         {:ok, sdb} <- Sessions.Table.open(Keyword.fetch!(opts, :sessions_db)) do
      keys = ~w(host sessions stream usage accounts transcripts projects launch)a
      s = Map.new(keys, &{&1, Keyword.fetch!(opts, &1)})

      s =
        Map.merge(s, %{
          db: db,
          sdb: sdb,
          notify: Keyword.get(opts, :notify, fn _ -> :ok end),
          clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
          mcp: Keyword.get(opts, :mcp, fn _ -> {:ok, nil} end),
          pending: %{},
          waiters: %{},
          # The monitor of each process that took a report, to the report's id.
          watched: %{}
        })

      {:ok, s, {:continue, :settle}}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:settle, s) do
    # An answer under way when the last process ended may not have reached its agent.
    for row <- Table.with_report(s.db, s.host, "answering"), do: write(s, row, report: "held")
    Stream.read(s.stream, timeout: @step)
    for row <- Table.with_status(s.db, s.host, ~w(starting resuming)), do: wake(s, row)

    {:noreply, settle(s)}
  end

  @impl true
  def handle_cast(:cue, s), do: {:noreply, settle(s)}

  @impl true
  def handle_call({:start, parent, project, branch, model, brief}, from, s) do
    with true <-
           Enum.all?([parent, model, brief], &(is_binary(&1) and &1 != "")) or
             {:refused, {:bad, :start}},
         {:ok, p} <- Turn.check(s.projects, project, branch),
         true <- Table.active(s.db, s.host, parent) < p.cap or {:refused, {:cap, p.cap}},
         {:ok, account} <- pick(s) do
      # StartAsked: the row first, as starting, with its brief's uuid.
      row = %{host: s.host, parent: parent, project: project, branch: branch, model: model}
      row = Map.merge(row, %{name: Turn.name(p, branch), account: account.name, brief: brief})
      row = Map.merge(row, %{brief_uuid: Stream.uuid(), deadline: deadline(s, p)})
      id = Table.starting(s.db, row)
      announce(s, id)
      {:noreply, call_sessions(s, Table.get(s.db, id), p, account, from)}
    else
      refused -> {:reply, refused, s}
    end
  end

  def handle_call({:held, parent}, _from, s) do
    keys = [:id, :name, :branch, :status, :text, :mark]
    {:reply, {:ok, Enum.map(Table.held(s.db, s.host, parent), &Map.take(&1, keys))}, s}
  end

  def handle_call({:await, parent, id, deadline}, from, s) do
    row = Table.get(s.db, id)
    left = deadline - System.monotonic_time(:millisecond)

    cond do
      row == nil or row.parent != parent -> {:reply, {:refused, {:no_delegate, id}}, s}
      row.report == "held" -> reply(take(s, row, from))
      row.report == "answering" -> {:reply, {:refused, :answering}, s}
      row.report == "answered" -> {:reply, {:refused, :answered}, s}
      row.status == "refused" -> {:reply, {:refused, {:refused, row.reason}}, s}
      Map.has_key?(s.waiters, id) -> {:reply, {:refused, :awaited}, s}
      left <= 0 -> {:reply, {:unknown, :timeout}, s}
      true -> {:noreply, put_in(s.waiters[id], {from, deadline, waited(id, left)})}
    end
  end

  def handle_call({:fix_state, parent, name}, _from, s) do
    {:reply, with({:ok, row, fold} <- child(s, parent, name), do: {:ok, claimed(s, row, fold)}),
     s}
  end

  # The act only while the claimed state is the delegate's, read again in this step.
  def handle_call({:fix, parent, name, fix, state}, from, s) do
    with {:ok, row, fold} <- child(s, parent, name),
         now = claimed(s, row, fold),
         true <- now == state or {:refused, {:moved, now}} do
      act(s, row, fold, fix, from)
    else
      refused -> {:reply, refused, s}
    end
  end

  def handle_call({settled, id}, _from, s) when settled in [:answered, :release] do
    {report, reply} = if settled == :answered, do: {"answered", :answered}, else: {"held", :held}

    case Table.get(s.db, id) do
      nil ->
        {:reply, {:refused, {:no_delegate, id}}, s}

      %{report: "answering"} = row ->
        write(s, row, report: report)
        {:reply, {:ok, reply}, unwatch(s, id)}

      %{report: other} ->
        {:reply, {:refused, {:not_answering, other}}, s}
    end
  end

  @impl true
  def handle_info({:waited, id}, s) do
    {waiter, waiters} = Map.pop(s.waiters, id)
    with {from, _, _} <- waiter, do: GenServer.reply(from, {:unknown, :timeout})
    {:noreply, %{s | waiters: waiters}}
  end

  # CallerSeen: the process that took a report ended before it said how its answer went. The
  # answer may not have reached the agent, so the report is held again, as release/2 holds it.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) when is_map_key(s.watched, ref) do
    {id, watched} = Map.pop(s.watched, ref)

    case Table.get(s.db, id) do
      %{report: "answering"} = row -> write(s, row, report: "held")
      _ -> :ok
    end

    {:noreply, %{s | watched: watched}}
  end

  def handle_info({ref, answer}, s) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(s.pending, ref) do
      {nil, _} ->
        {:noreply, s}

      {%{id: id, from: from}, pending} ->
        s = %{s | pending: pending}
        {reply, s} = answered(s, Table.get(s.db, id), answer)
        if from, do: GenServer.reply(from, reply)
        {:noreply, s}
    end
  end

  def handle_info(:deadline, s), do: {:noreply, settle(s)}

  # Called: Sessions writes its own row first and runs on through a restart of this process.
  defp call_sessions(s, row, p, account, from) do
    launch = [role: :delegate, worktree: %{project: p, branch: row.branch}, model: row.model]
    launch = launch ++ s.launch

    # The config is made in the task: the embedding app's `issue` may call a part that waits.
    task =
      Task.async(fn ->
        with {:ok, mcp} <- s.mcp.(row.name) do
          launch = if mcp, do: launch ++ [mcp: mcp], else: launch

          if row.status == "starting",
            do: Sessions.start(s.sessions, row.name, account, launch, timeout: @call),
            else:
              Sessions.resume(s.sessions, row.name, account, row.session_id, launch,
                timeout: @call
              )
        end
      end)

    put_in(s.pending[task.ref], %{id: row.id, from: from})
  end

  # CallAnswered and Settled: a start or resume runs, then its turn's message goes in; a refused
  # start is refused; a refused resume is the report. An unknown answer leaves the row as it is,
  # for Settled to decide.
  defp answered(s, row, {:ok, %{session_id: sid}}) do
    write(s, row, status: "running", session_id: sid, reason: nil)
    row = Table.get(s.db, row.id)
    {brief, s} = running(s, row)
    {{:ok, Map.put(Map.take(row, [:id, :name, :session_id, :account]), :brief, brief)}, s}
  end

  defp answered(s, %{status: "starting"} = row, {:refused, why} = refused) do
    write(s, row, status: "refused", reason: why)
    {refused, s}
  end

  defp answered(s, row, {:refused, why} = refused) do
    text = "The delegate was killed before its last reply, and its resume was refused: "
    {refused, hold(s, row, "failed", text <> inspect(why))}
  end

  defp answered(s, row, {:unknown, why} = unknown) do
    write(s, row, reason: why)
    wake(s, row)
    {unknown, s}
  end

  # Every row with no call under way, read again.
  defp settle(s) do
    busy = MapSet.new(Map.values(s.pending), & &1.id)

    Table.with_status(s.db, s.host, ~w(starting resuming running))
    |> Enum.reject(&MapSet.member?(busy, &1.id))
    |> Enum.reduce(s, &settle_row(&2, &1))
  end

  # Settled: by Sessions' row of this call (written at or after the call) once that row is
  # settled; with none past the deadline, the call never reached Sessions and is not made again.
  defp settle_row(s, %{status: status} = row) when status in ~w(starting resuming) do
    case Sessions.Table.get(s.sdb, s.host, row.name) do
      %{started_at: at, status: "running"} = srow when at >= row.called_at ->
        elem(answered(s, row, {:ok, srow}), 1)

      %{started_at: at, status: done} = srow
      when at >= row.called_at and done in ~w(refused stopped) ->
        elem(answered(s, row, {:refused, srow.reason || done}), 1)

      %{started_at: at} when at >= row.called_at ->
        s

      _ ->
        if s.clock.() >= row.deadline,
          do: elem(answered(s, row, {:refused, "interrupted"}), 1),
          else: s
    end
  end

  defp settle_row(s, row), do: elem(running(s, row), 1)

  # What a running row's Stream row says, and what it did: StopHandled, InputWritten under the
  # row's uuid (answering Stream's answer), or the exit.
  defp running(s, row) do
    with {:ok, fold} <- followed(s, row) do
      case Turn.next(row, fold) do
        {:finished, text} ->
          {:finished, hold(s, row, "finished", text)}

        {:write, uuid, text} ->
          {Stream.write(s.stream, row.session_id, {:message, uuid, text}), s}

        :exited ->
          {:exited, exited(s, row, fold)}

        :waiting ->
          {:waiting, s}
      end
    else
      unread -> {unread, s}
    end
  end

  # Its process is gone with no result of its turn. TranscriptRead: a last reply is a finish.
  # KillSeen: a second kill is the report; a first is resumed once Sessions' row has ended,
  # which its settle and cue bring (Sessions refuses to start a name whose row runs). A read
  # that fails decides nothing.
  defp exited(s, row, fold) do
    with {:ok, t} <- Map.fetch(s.transcripts, row.account),
         {:ok, %{failed: []}} <-
           Transcripts.read(t, [{row.session_id, fold.transcript}], timeout: @step),
         {:ok, tr} <- Transcripts.session(t, row.session_id, timeout: @step) do
      cond do
        tr.ends_with_reply -> hold(s, row, "finished", tr.last_reply.text)
        row.resumes > 0 -> hold(s, row, "failed", @twice)
        ended?(Sessions.Table.get(s.sdb, s.host, row.name)) -> resume(s, row, fold)
        true -> s
      end
    else
      _ -> s
    end
  end

  defp ended?(srow), do: srow == nil or srow.status in ~w(stopped refused)

  # The row counts the resume, with the uuid of the resumed process's message when the brief
  # had gone in, before Sessions is asked: a restart never asks it twice.
  defp resume(s, row, fold) do
    with {:ok, p} <- Map.fetch(s.projects, row.project),
         {:ok, account} <- Accounts.ready(s.accounts, row.account) do
      went_in? = match?(%{state: :delivered}, fold.messages[row.brief_uuid])
      at = System.os_time(:millisecond)
      fields = [status: "resuming", resumes: 1, called_at: at, deadline: deadline(s, p)]
      write(s, row, fields ++ [resume_uuid: if(went_in?, do: Stream.uuid())])
      call_sessions(s, Table.get(s.db, row.id), p, account, nil)
    else
      :error -> elem(answered(s, row, {:refused, {:unknown_project, row.project}}), 1)
      refused -> elem(answered(s, row, refused), 1)
    end
  end

  defp hold(s, row, status, text) do
    mark = "[report #{Stream.uuid()}]"
    write(s, row, status: status, report: "held", text: text, mark: mark)
    answer_waiter(s, Table.get(s.db, row.id))
  end

  # A call waits on this report: it takes it now, while its deadline has not passed.
  defp answer_waiter(s, row) do
    case Map.pop(s.waiters, row.id) do
      {nil, _} ->
        s

      {{from, deadline, timer}, waiters} ->
        Process.cancel_timer(timer)
        s = %{s | waiters: waiters}

        if System.monotonic_time(:millisecond) < deadline do
          {reply, s} = take(s, row, from)
          GenServer.reply(from, reply)
          s
        else
          GenServer.reply(from, {:unknown, :timeout})
          s
        end
    end
  end

  # Taken: answering, and its caller watched from this step. A caller already gone is seen at
  # once, since a monitor of a dead process answers :noproc.
  defp take(s, row, {pid, _tag}) do
    write(s, row, report: "answering")
    ref = Process.monitor(pid)
    {{:ok, Map.take(row, [:id, :name, :status, :text])}, put_in(s.watched[ref], row.id)}
  end

  defp unwatch(s, id) do
    {gone, kept} = Map.split_with(s.watched, fn {_ref, of} -> of == id end)
    for {ref, _} <- gone, do: Process.demonitor(ref, [:flush])
    %{s | watched: kept}
  end

  defp reply({reply, s}), do: {:reply, reply, s}

  # The latest row of `name` that is `parent`'s, with Stream's row of its process, just read.
  defp child(s, parent, name) do
    rows = Table.with_status(s.db, s.host, ~w(starting resuming running finished failed refused))

    case rows |> Enum.filter(&(&1.name == name)) |> List.last() do
      %{parent: ^parent, session_id: sid} = row when is_binary(sid) ->
        with {:ok, _} <- Stream.read(s.stream, timeout: @step),
             {:ok, fold} <- followed(s, row),
             do: {:ok, row, fold}

      %{parent: ^parent, status: status} ->
        {:refused, {:not_started, status}}

      _ ->
        {:refused, {:no_delegate, name}}
    end
  end

  defp claimed(s, row, fold) do
    held = Enum.sort(for {id, %{state: :held}} <- fold.requests, do: id)
    ended = ended?(Sessions.Table.get(s.sdb, s.host, row.name))
    state = Map.take(row, [:id, :status, :resumes, :report])

    Map.merge(state, %{offset: fold.offset, gone: fold.gone, ending: fold.ending, held: held})
    |> Map.put(:ended, ended)
  end

  defp act(s, row, _fold, :interrupt, _from),
    do: {:reply, Stream.interrupt(s.stream, row.session_id, timeout: @step), s}

  defp act(s, row, _fold, {:answer, request, label}, _from),
    do: {:reply, Stream.answer(s.stream, row.session_id, request, label, timeout: @step), s}

  # The resume path a cue takes once the process is gone and Sessions' row has ended. A wedged
  # delegate, alive but stuck, is not stopped first: F-100's build note, new-1.
  defp act(s, row, fold, :resume, _from) do
    cond do
      row.resumes > 0 ->
        {:reply, {:refused, :resumed_once}, s}

      not fold.gone ->
        {:reply, {:refused, :live}, s}

      row.status != "running" ->
        {:reply, {:refused, {:status, row.status}}, s}

      not ended?(Sessions.Table.get(s.sdb, s.host, row.name)) ->
        {:reply, {:refused, :session_running}, s}

      true ->
        resumed(exited(s, row, fold), row.id)
    end
  end

  # Sessions waits for the exit; this process does not wait with it.
  defp act(s, %{report: report} = row, _fold, :stop, from)
       when report in ~w(answered delivered) do
    Task.start(fn ->
      reply = Sessions.stop(s.sessions, row.name, :report_delivered, timeout: @call)
      GenServer.reply(from, reply)
    end)

    {:noreply, s}
  end

  defp act(s, row, _fold, :stop, _from), do: {:reply, {:refused, {:report, row.report}}, s}

  # The transcript's last reply makes it a finish, not a resume.
  defp resumed(s, id) do
    case Table.get(s.db, id) do
      %{status: "resuming"} -> {:reply, {:ok, :resuming}, s}
      %{status: status} -> {:reply, {:refused, {:status, status}}, s}
    end
  end

  defp waited(id, left), do: Process.send_after(self(), {:waited, id}, left)

  defp followed(s, row) do
    case Stream.rows(s.stream, timeout: @step) do
      {:ok, %{rows: rows}} ->
        found = Enum.find(rows, &(&1.session == row.session_id))
        if found, do: {:ok, found}, else: {:unknown, :not_followed}

      unread_or_failed ->
        unread_or_failed
    end
  end

  defp pick(s) do
    with {:ok, %{readings: readings}} <- Usage.readings(s.usage, timeout: @step),
         {:ok, name} <- Usage.pick(readings, s.accounts.names) do
      Accounts.ready(s.accounts, name)
    else
      :unread -> {:refused, {:usage, :unread}}
      other -> other
    end
  end

  # A call's wall-clock deadline: Sessions' own timeout, the setup's and Sessions' slack.
  defp deadline(s, p), do: s.clock.() + @call + p.setup_timeout + @slack

  # One wake at a cut-off call's deadline, when Settled may decide; not a poll.
  defp wake(s, row), do: Process.send_after(self(), :deadline, max(row.deadline - s.clock.(), 0))

  defp write(s, row, fields) do
    Table.update(s.db, row.id, fields)
    announce(s, row.id)
  end

  defp announce(s, id), do: s.notify.(%{topic: "delegates:#{s.host}", ids: [id]})
end
