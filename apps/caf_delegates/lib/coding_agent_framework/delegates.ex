defmodule CodingAgentFramework.Delegates do
  @moduledoc """
  The delegate protocol (`docs/design.md`, "The delegate protocol"; `model/tla/Delegate.tla`):
  a start, a finish or a kill, one resume, and the report handed to `Mailbox` as the reply to
  the brief. What goes into a delegate, its brief included, is `Mailbox`'s rows; `Delegates`
  keeps only whether its report was taken.

  The caller's supervision tree starts one per host, with no name, and gives it the host's
  `Sessions`, `Stream`, `Transcripts` and `Mailbox`, the instance's `Usage` and `Accounts`, the
  projects as data, and what every launch shares:

      {:ok, delegates} = Delegates.start_link(host: "laptop", db: db, sessions_db: db,
        sessions: sessions, stream: stream, usage: usage, accounts: accounts,
        transcripts: transcripts, mailbox: mailbox,
        launch: [claude: claude, env: env, tool_timeout: 3_600_000],
        projects: %{"app" => %{name: "app", repo: "/src/app", trunk: "main", setup: [],
          setup_timeout: 60_000, env: %{}, branches: ~r/\\Aunit\\//, cap: 3}})
      Delegates.start_delegate(delegates, "main", "app", "unit/review", "opus", "Review it.")
      #=> {:ok, %{id: 1, name: "app-unit-review", session_id: "…", account: "work",
      #=>   brief_uuid: "…"}}

  **A start** checks the project, the branch against the project's pattern and the parent's cap
  (`Delegates.Turn`), picks the account with the most allowance left (`Usage.pick/2`), and
  writes its row first, as `starting`, with the uuid its brief will go in under. The brief is
  then stored in `Mailbox` under that uuid, before anything of the delegate exists, so it is
  the first row to it. A task starts the session through `Sessions`, role `:delegate` in the
  project's worktree, and its answer moves the row: `running` (`Mailbox` then delivers the
  brief into the session's first ended turn), or `refused`, and `Mailbox` ends the rows to it.
  A row a restart left `starting` is settled by `Sessions`' row of its call, once that row is
  settled; with no such row by the row's deadline, the call never reached `Sessions`, and the
  row is refused as `interrupted`.

  **A running delegate** is read from its `Stream` row at each cue: once the turn's message is
  delivered and a `result` names it, the row is `finished` with that result as its report.
  When its process is gone first, the transcript says whether it had given its last reply: if
  so it finished with that reply. Otherwise it is resumed once, after `Sessions`' row of it has
  ended: the row counts the resume first, as `resuming`, then `Sessions.resume/6` follows it
  again. When the brief had gone in, `Mailbox` is first given the word to go on (`go_on/4`,
  under the row's `resume_uuid`), which goes before any other row to it; when it had not,
  `Mailbox` sends the brief again itself. A second such kill, or a refused resume, is `failed`,
  and that is the report, a notice from `framework`. A row leaves `running` once.

  **The report** is handed to `Mailbox` (`Mailbox.report/5`) under the brief's uuid, which takes
  one answer per key, and the row's `report` is then `taken`; until `Mailbox` takes it, it is
  `held`, with its text, and handed again at each cue. How it reaches the parent (a waiting
  `run_delegate`, or later the parent's waiter) is `Mailbox`'s.

  **An ended delegate**: once its report is delivered and its process is gone, as `stop` or
  `end_session` leave it, a cue writes its row `ended` (and notifies). The row leaves the
  parent's cap, and the app's end rules read `ended` as an end.

  **A parent's fix** (`fix_state/3`, `fix/5`; `Team.tla`'s `FixActs`) is checked and claimed
  by its caller (`MCP`); here it acts only while the state it claimed is still the delegate's,
  read again in the same step, and through the part that owns the act: `Stream` for an
  interrupt or an answer, the resume path above for a resume, `Sessions.stop/4` for a stop.

  It reads every row again when it starts and at each `cue/2`; the embedding app wires the cues of
  `Sessions`, `Stream`, `Transcripts` and `Mailbox` to it. After each write `notify` gets
  `%{topic: "delegates:<host>", ids: [id]}`.
  """

  use GenServer

  alias CodingAgentFramework.{Accounts, Mailbox, Sessions, Stream, Transcripts, Usage}
  alias CodingAgentFramework.ClaudeCLI.Options
  alias CodingAgentFramework.Delegates.{Table, Turn}

  # Sessions' own timeout for a start or a resume; its git bounds and slack come on top.
  @call 30_000
  @slack 120_000
  @step 5_000
  @twice "The delegate was killed twice before its last reply; it is not resumed again."

  @doc """
  Starts a `Delegates`. Options: `host:` (the name of the host `sessions:` and `stream:` run
  on), `db:`, `sessions_db:` (the file `Sessions`' table is in), `usage:`, `accounts:`,
  `transcripts:` (the host's `Transcripts`), `mailbox:` (the host's `Mailbox`), `projects:`
  (name to a project as `Sessions.Worktree.project/1` reads it, with `branches:` and `cap:`),
  `launch:` (`claude:`, `env:` and `tool_timeout:` for `ClaudeCLI`), and optionally `notify:`,
  `clock:` (wall-clock ms) and `mcp:`, a function of the delegate's name that answers `{:ok,
  path}`, its own MCP config (the embedding app gives `MCP.issue/2`), or a refusal. Each start
  and resume calls it just before its launch and adds the path as `ClaudeCLI`'s `mcp:`; its
  refusal refuses the start, and with no `mcp:` a delegate runs without the framework's tools.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Starts a delegate of `parent` (the main session's name, which the caller states until
  `Mains` exists) on `branch` of `project`, with `model`, and `brief` as its first message,
  stored in `Mailbox`. Answers `{:ok, %{id, name, session_id, account, brief_uuid}}`, the
  report being the reply to `brief_uuid`; `{:refused, reason}`; or `{:unknown, reason}`, when
  its row stays `starting` for a later read to settle. Options: `:timeout`, what the caller
  waits (default 300 000 ms; the start goes on past it), and `:options` (`ClaudeCLI.Options`),
  checked before the row, kept on it, and given to `Sessions` at the start and the resume.
  """
  def start_delegate(delegates, parent, project, branch, model, brief, opts \\ []) do
    start = {:start, parent, project, branch, model, brief, Keyword.get(opts, :options)}
    call(delegates, start, opts, 300_000)
  end

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
    `Stream`, only once `Mailbox` has the report delivered and no row to the delegate still
    `queued` or `sending`; else `{:refused, {:report, status}}` or `{:refused, {:open, ids}}`.
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
      keys = ~w(host sessions stream usage accounts transcripts mailbox projects launch)a
      s = Map.new(keys, &{&1, Keyword.fetch!(opts, &1)})

      s =
        Map.merge(s, %{
          db: db,
          sdb: sdb,
          notify: Keyword.get(opts, :notify, fn _ -> :ok end),
          clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
          mcp: Keyword.get(opts, :mcp, fn _ -> {:ok, nil} end),
          pending: %{}
        })

      {:ok, s, {:continue, :settle}}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:settle, s) do
    Stream.read(s.stream, timeout: @step)
    for row <- Table.with_status(s.db, s.host, ~w(starting resuming)), do: wake(s, row)

    {:noreply, settle(s)}
  end

  @impl true
  def handle_cast(:cue, s), do: {:noreply, settle(s)}

  @impl true
  def handle_call({:start, parent, project, branch, model, brief, options}, from, s) do
    with true <-
           Enum.all?([parent, model, brief], &(is_binary(&1) and &1 != "")) or
             {:refused, {:bad, :start}},
         {:ok, options} <- Options.check(options),
         {:ok, p} <- Turn.check(s.projects, project, branch),
         true <- Table.active(s.db, s.host, parent) < p.cap or {:refused, {:cap, p.cap}},
         {:ok, account} <- pick(s) do
      # StartAsked: the row first, as starting, with its brief's uuid; then the brief's row.
      row = %{host: s.host, parent: parent, project: project, branch: branch, model: model}
      row = Map.merge(row, %{name: Turn.name(p, branch), account: account.name, brief: brief})
      row = Map.merge(row, %{brief_uuid: Stream.uuid(), deadline: deadline(s, p)})
      row = Map.put(row, :options, Options.encode(options))
      id = Table.starting(s.db, row)
      announce(s, id)
      row = Table.get(s.db, id)

      case Mailbox.brief(s.mailbox, parent, row.name, brief, row.brief_uuid) do
        {:ok, _} -> {:noreply, call_sessions(s, row, p, account, from)}
        not_stored -> reply(answered(s, row, {:refused, {:brief, not_stored}}))
      end
    else
      refused -> {:reply, refused, s}
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

  @impl true
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
    # The row's options are given again on a resume.
    task =
      Task.async(fn ->
        with {:ok, options} <- Options.decode(row.options),
             launch = launch ++ [options: options],
             {:ok, mcp} <- s.mcp.(row.name) do
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

  # CallAnswered and Settled: a start or resume runs, and Mailbox delivers its turn's message; a
  # refused start is refused, and the rows to it end; a refused resume is the report. An
  # unknown answer leaves the row as it is, for Settled to decide.
  defp answered(s, row, {:ok, %{session_id: sid}}) do
    write(s, row, status: "running", session_id: sid, reason: nil)
    row = Table.get(s.db, row.id)
    keys = [:id, :name, :session_id, :account, :brief_uuid]
    {{:ok, Map.take(row, keys)}, s}
  end

  defp answered(s, %{status: "starting"} = row, {:refused, why} = refused) do
    write(s, row, status: "refused", reason: why)
    Mailbox.ended(s.mailbox, row.name)
    {refused, s}
  end

  defp answered(s, row, {:refused, why} = refused) do
    text = "The delegate was killed before its last reply, and its resume was refused: "
    {refused, finish(s, row, "failed", {:notice, text <> inspect(why)})}
  end

  defp answered(s, row, {:unknown, why} = unknown) do
    write(s, row, reason: why)
    wake(s, row)
    {unknown, s}
  end

  # Every row with no call under way, read again.
  defp settle(s) do
    busy = MapSet.new(Map.values(s.pending), & &1.id)

    Table.with_status(s.db, s.host, ~w(starting resuming running finished failed))
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

  # A report Mailbox has not taken yet is handed again.
  defp settle_row(s, %{status: status, report: "held"} = row) when status in ~w(finished failed),
    do: hand(s, row, answer(row))

  # Ended: a finished delegate whose report reached its parent and whose process is gone, since
  # `Sessions` stopped it (`stop`, `end_session`). It frees its parent's cap, and no process of it
  # runs again. A report not yet delivered keeps the row `finished`.
  defp settle_row(s, %{status: "finished"} = row) do
    if ended?(Sessions.Table.get(s.sdb, s.host, row.name)) and delivered?(s, row),
      do: write(s, row, status: "ended")

    s
  end

  defp settle_row(s, %{status: "failed"}), do: s

  defp settle_row(s, row) do
    with {:ok, fold} <- followed(s, row) do
      case Turn.next(row, fold) do
        {:finished, r} -> finish(s, row, "finished", {:reply, r.text, r})
        :exited -> exited(s, row, fold)
        :waiting -> s
      end
    else
      _unread -> s
    end
  end

  defp delivered?(s, row),
    do: match?({:ok, %{status: "delivered"}}, Mailbox.answer_to(s.mailbox, row.brief_uuid))

  # Its process is gone with no result of its turn. TranscriptRead: a last reply is a finish.
  # KillSeen: a second kill is the report; a first is resumed once Sessions' row has ended,
  # which its settle and cue bring (Sessions refuses to start a name whose row runs). A read
  # that fails decides nothing.
  defp exited(s, row, fold) do
    t = s.transcripts
    session = {row.account, row.session_id, fold.transcript}

    with {:ok, %{failed: []}} <- Transcripts.read(t, [session], timeout: @step),
         {:ok, tr} <- Transcripts.session(t, row.account, row.session_id, timeout: @step) do
      cond do
        tr.ends_with_reply -> finish(s, row, "finished", {:reply, tr.last_reply.text, %{}})
        row.resumes > 0 -> finish(s, row, "failed", {:notice, @twice})
        ended?(Sessions.Table.get(s.sdb, s.host, row.name)) -> resume(s, row, fold)
        true -> s
      end
    else
      _ -> s
    end
  end

  defp ended?(srow), do: srow == nil or srow.status in ~w(stopped refused)

  # The row counts the resume before Sessions is asked: a restart never asks it twice. When the
  # brief had gone in, Mailbox takes the word to go on first, under the row's new uuid; when it
  # had not, Mailbox has the brief due again. A word Mailbox did not take leaves the row
  # running, for the next cue.
  defp resume(s, row, fold) do
    went_in? = match?(%{state: :delivered}, fold.messages[row.brief_uuid])
    uuid = if went_in?, do: Stream.uuid()

    with {:ok, p} <- Map.fetch(s.projects, row.project) |> known(row.project),
         {:ok, account} <- Accounts.ready(s.accounts, row.account),
         {:ok, _} <-
           if(uuid,
             do: Mailbox.go_on(s.mailbox, row.name, Turn.resumed(), uuid),
             else: {:ok, nil}
           ) do
      at = System.os_time(:millisecond)
      fields = [status: "resuming", resumes: 1, called_at: at, deadline: deadline(s, p)]
      write(s, row, fields ++ [resume_uuid: uuid])
      call_sessions(s, Table.get(s.db, row.id), p, account, nil)
    else
      {:refused, _} = refused -> elem(answered(s, row, refused), 1)
      _not_taken -> s
    end
  end

  defp known(:error, project), do: {:refused, {:unknown_project, project}}
  defp known(ok, _project), do: ok

  # The report's text is kept until Mailbox takes it.
  defp finish(s, row, status, answer) do
    write(s, row, status: status, report: "held", text: elem(answer, 1))
    hand(s, Table.get(s.db, row.id), answer)
  end

  defp answer(%{status: "finished"} = row), do: {:reply, row.text, %{}}
  defp answer(row), do: {:notice, row.text}

  defp hand(s, row, answer) do
    case Mailbox.report(s.mailbox, row.name, row.parent, row.brief_uuid, answer) do
      {:ok, _} -> write(s, row, report: "taken")
      _not_taken -> :ok
    end

    s
  end

  defp reply({reply, s}), do: {:reply, reply, s}

  # The latest row of `name` that is `parent`'s, with Stream's row of its process, just read.
  defp child(s, parent, name) do
    rows =
      Table.with_status(s.db, s.host, ~w(starting resuming running finished failed ended refused))

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

  defp act(s, %{status: "ended"}, _fold, :stop, _from),
    do: {:reply, {:refused, {:status, "ended"}}, s}

  # The report delivered and nothing open to it, by Mailbox; Sessions waits for the exit, and
  # this process does not wait with it.
  defp act(s, row, _fold, :stop, from) do
    with {:ok, %{status: "delivered"}} <- report(s, row),
         {:ok, []} <- Mailbox.open_to(s.mailbox, row.name) |> open() do
      me = self()

      Task.start(fn ->
        reply = Sessions.stop(s.sessions, row.name, :report_delivered, timeout: @call)
        GenServer.reply(from, reply)
        # The process is gone once Sessions answers: the row is read again for its end.
        GenServer.cast(me, :cue)
      end)

      {:noreply, s}
    else
      {:ok, %{status: status}} -> {:reply, {:refused, {:report, status}}, s}
      other -> {:reply, other, s}
    end
  end

  defp report(s, row) do
    case Mailbox.answer_to(s.mailbox, row.brief_uuid) do
      {:refused, :no_answer} -> {:ok, %{status: row.report}}
      found -> found
    end
  end

  defp open({:ok, []}), do: {:ok, []}
  defp open({:ok, ids}), do: {:refused, {:open, ids}}
  defp open(other), do: other

  # The transcript's last reply makes it a finish, not a resume.
  defp resumed(s, id) do
    case Table.get(s.db, id) do
      %{status: "resuming"} -> {:reply, {:ok, :resuming}, s}
      %{status: status} -> {:reply, {:refused, {:status, status}}, s}
    end
  end

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
