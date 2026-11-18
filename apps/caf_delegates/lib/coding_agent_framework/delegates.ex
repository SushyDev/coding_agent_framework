defmodule CodingAgentFramework.Delegates do
  @moduledoc """
  The delegate protocol (`docs/design.md`, "The delegate protocol"; `model/tla/Delegate.tla`):
  a start, a finish or a kill, one resume, and the report handed to `Mailbox` as the reply to
  the brief. What goes into a delegate, its brief included, is `Mailbox`'s rows; the agent
  itself (its parent, project, account, session and whether it has ended) is its agent row in
  `Sessions`, read only through `Sessions.Agents`. `Delegates`' own table keeps the protocol's
  facts: its calls' marks, the branch, the brief's uuid, the resume, and whether the report was
  taken.

  The caller's supervision tree starts one per host, with no name, and gives it the host's
  `Sessions`, `Stream`, `Transcripts` and `Mailbox`, the instance's `Usage` and `Accounts`, the
  projects as data, and what every launch shares:

      {:ok, delegates} = Delegates.start_link(host: "laptop", db: db, sessions_db: db,
        sessions: sessions, stream: stream, usage: usage, accounts: accounts,
        transcripts: transcripts, mailbox: mailbox,
        launch: [claude: claude, env: env, tool_timeout: 3_600_000],
        projects: %{"app" => %{name: "app", repo: "/src/app", trunk: "main", setup: [],
          setup_timeout: 60_000, env: %{}, branches: ~r/\\Aunit\\//, cap: 3}})
      Delegates.start_delegate(delegates, "app-main", "app", "unit/review", "opus", "Review it.")
      #=> {:ok, %{id: 1, name: "app-unit-review", session_id: "…", account: "work",
      #=>   brief_uuid: "…"}}

  **A start** checks the project, the branch against the project's pattern and the parent's cap
  (`Delegates.Turn`): the parent's delegates the tree holds (`Sessions.Agents.children/3`) and
  its starts under way here; a parent a move drains is refused `{:moving, parent}`. While a
  move of a delegate is under way (`Sessions.Agents.moving?/1`), its end is the move's, not a
  kill, and its row waits for the move. It picks the account with the most allowance left
  (`Usage.pick/2`), and writes its row first, as `starting`, with the uuid its brief will go in
  under. With a `scheduler:`, it then asks for a lease, class `:builder`, its module the
  project, on that account, naming the row as the lease's holder (`Delegates.Work` answers
  whether its work ended): granted, the start goes on; queued, it waits in this process for the
  one more answer, the caller with it; refused, the row is `refused` with reason `{:lease,
  {reason, retry_at}}`, which is never a failed run. The brief is then stored in `Mailbox` under
  that uuid, before anything of the delegate exists, so it is the first row to it. A task starts the session through `Sessions`, role
  `:delegate`, with its parent, in the project's worktree, and its answer moves the row:
  `running` (`Mailbox` then delivers the brief into the session's first ended turn), or
  `refused`, and `Mailbox` ends the rows to it. A row a restart left `starting` is settled by
  the agent row of its call, once that row is settled; with no such row by the row's deadline,
  the call never reached `Sessions`, and the row is refused as `interrupted`.

  **A running delegate** is read from its `Stream` row at each cue: once the turn's message is
  delivered and a `result` names it, the row is `finished` with that result as its report.
  When its process is gone first, the transcript says whether it had given its last reply: if
  so it finished with that reply. Otherwise it is resumed once, after its agent row is free (no
  process of it may live): the row counts the resume first, as `resuming`, then
  `Sessions.resume/6` follows it again, with the agent row's own options. When the brief had
  gone in, `Mailbox` is first given the word to go on (`go_on/4`, under the row's
  `resume_uuid`), which goes before any other row to it; when it had not, `Mailbox` sends the
  brief again itself. A second such kill, or a refused resume, is `failed`, and that is the
  report, a notice from `framework`. A row leaves `running` once.

  **An interactive delegate** (`interactive: true`, F-137; `docs/design.md`, "Interactive
  delegates") runs Claude Code's terminal interface: role `:parent`, kind `:delegate`. Its brief
  is marked by `Mailbox.launch/4` and carried by its start as the prompt; its report is the
  reply of the turn its brief (or its word to go on) began, read from its transcript
  (`Transcripts.Fold.reply_to/2`) once that turn has ended: closed by a later turn, or its
  session file read ended through `registry:`. Its resume carries the word to go on by launch.

  **The report** is handed to `Mailbox` (`Mailbox.report/5`) under the brief's uuid, to the
  agent row's parent, and the row's `report` is then `taken`; until `Mailbox` takes it, it is
  `held`, with its text, and handed again at each cue.

  **An ended delegate**: once no process of it may live, a failed one at once (it is never
  resumed again) and a finished one once its report was delivered (only then is it stopped, by
  `stop` or `end_session`), a cue asks `Sessions.ended/3`, and its agent row is `ended`: it
  frees its parent's cap, and what it owns ends (what it kept goes to its parent, its edge in
  the tree staying). Its report stays its parent's.

  **A parent's fix** (`fix_state/3`, `fix/5`; `Team.tla`'s `FixActs`) is checked and claimed
  by its caller (`MCP`); here it acts only while the state it claimed is still the delegate's,
  read again in the same step, and through the part that owns the act: `Stream` for an
  interrupt or an answer, the resume path above for a resume, `Sessions.stop/3` for a stop.

  Only each name's latest row moves; an older one is history. It reads every row again when it
  starts and at each `cue/2`: `Cues` hands it the topics `reads/0` declares. After each write `notify` gets `%{topic:
  "delegates:<host>", ids: [id]}`.

  **Migration** (F-129): a table an earlier build made holds each delegate's parent and
  project; at its start `Delegates` hands them to `Sessions` (`Sessions.adopt_tree/3`), then
  rebuilds its table (`Delegates.Table`).
  """

  use GenServer

  alias CodingAgentFramework.{Accounts, Acts, ClaudeCLI, Inlet, Intake, Mailbox, Registry}
  alias CodingAgentFramework.Scheduler
  alias CodingAgentFramework.Intake.Table, as: IntakeTable
  alias CodingAgentFramework.{Sessions, Stream, Transcripts, Usage}
  alias CodingAgentFramework.Mailbox.Transport.Waiter
  alias CodingAgentFramework.Sessions.Turn, as: SessionsTurn
  alias CodingAgentFramework.Transcripts.Fold
  alias CodingAgentFramework.ClaudeCLI.Options
  alias CodingAgentFramework.Delegates.{Table, Turn, Work}
  alias CodingAgentFramework.Sessions.Agents

  # Sessions' own timeout for a start or a resume; its git bounds and slack come on top.
  @call 30_000
  @slack 120_000
  @step 5_000
  @twice "The delegate was killed twice before its last reply; it is not resumed again."

  @doc """
  Starts a `Delegates`. Options: `host:` (the name of the host `sessions:` and `stream:` run
  on), `db:`, `sessions_db:` (the file `Sessions`' table is in, read through
  `Sessions.Agents`), `usage:`, `accounts:`, `transcripts:` (the host's `Transcripts`),
  `mailbox:` (the host's `Mailbox`), `projects:` (name to a project as
  `Sessions.Worktree.project/1` reads it, with `branches:` and `cap:`), `launch:` (`claude:`,
  `env:` and `tool_timeout:` for `ClaudeCLI`), and optionally `notify:`, `clock:` (wall-clock
  ms) and `mcp:`, a function of the delegate's name that answers `{:ok, path}`, its own MCP
  config (the embedding app gives `MCP.issue/2`), or a refusal. Each start and resume calls it
  just before its launch and adds the path as `ClaudeCLI`'s `mcp:`; its refusal refuses the
  start, and with no `mcp:` a delegate runs without the framework's tools. With `acts:` (the
  instance's `Acts`), its own resume after a first kill is a row there, actor
  `delegates:<host>`, state the delegate's row and resumes, claimed before the row counts it
  and settled by `Sessions`' answer (`Acts.answered/4`); a claim not taken resumes nothing.
  With `scheduler:` (the instance's `Scheduler`), each start asks it for a lease first, of the
  units `lease:` names (default `%{"seat" => 1}`); a resume runs under the start's lease.
  With `registry:` (the host's `Registry`), it starts interactive delegates, whose turn's end
  it reads from their session files. With `inlet:` (the host's `Inlet`), `intake:` (the host's
  `Intake`) and `intake_db:` (its file), a parent's fixes reach an interactive delegate as they
  reach a main session (F-137's new-3): its interrupt is Escape through the `Inlet`, and its
  answer goes to the `PermissionRequest` `Intake` holds for it.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Starts a delegate of `parent` (a main session's name) on `branch` of `project`, with `model`,
  and `brief` as its first message, stored in `Mailbox`. Answers `{:ok, %{id, name,
  session_id, account, brief_uuid}}`, the report being the reply to `brief_uuid`; `{:refused,
  reason}`; or `{:unknown, reason}`, when its row stays `starting` for a later read to settle.
  Options: `:timeout`, what the caller waits (default 300 000 ms; the start goes on past it),
  and `:options` (`ClaudeCLI.Options`), checked before the row and kept on the agent row,
  which its resume takes again; and `interactive: true` for the terminal interface, refused
  `:no_registry` by a `Delegates` given no `registry:`, and `{:too_long, max}` for a brief a
  launch cannot carry.
  """
  def start_delegate(delegates, parent, project, branch, model, brief, opts \\ []) do
    how = if Keyword.get(opts, :interactive, false), do: :interactive, else: :headless
    start = {:start, parent, project, branch, model, brief, Keyword.get(opts, :options), how}
    call(delegates, start, opts, 300_000)
  end

  @doc """
  The state of `parent`'s delegate `name` that a fix claims (`Team.tla`'s `epoch`), read after
  a read of `Stream`: the row's `id`, `status`, `resumes` and `report`, and from `Stream`'s row
  of its process the log's `offset` (each event read moves it), `gone`, `ending`, and the ids
  of the requests `held`; and whether its agent row is free of a process (`ended`). For an
  interactive delegate, which has no `Stream` row, `offset` is the id of the newest hook event
  `Intake` stored for its session, `held` the ids of the `PermissionRequest` rows it holds, and
  `gone` whether its agent row is not running. A fix of one state acts once; any event, exit,
  end, answer, resume or report moves it. The latest row of that name is the delegate. Answers
  `{:ok, state}`, or `{:refused, {:no_delegate, name}}`, `{:refused, {:not_started, status}}`,
  `{:unknown, :no_intake}` for an interactive one with no `intake:`, or `Stream`'s.

      Delegates.fix_state(delegates, "app-main", "app-unit-review")
      #=> {:ok, %{id: 1, status: "running", resumes: 0, report: "none", offset: 812,
      #=>   gone: false, ending: false, held: ["req-…"], ended: false}}
  """
  def fix_state(delegates, parent, name),
    do: call(delegates, {:fix_state, parent, name}, [], 3 * @step)

  @doc """
  Fixes `parent`'s delegate `name`, only while `state` (`fix_state/3`'s, which the caller
  claimed) is still its state, read again here; else `{:refused, {:moved, now}}` and nothing
  acts. `fix` is:

  - `:interrupt`: `Stream.interrupt/3`; for an interactive delegate, `Inlet.interrupt/3`
    (Escape, once its screen shows a turn running, until it shows the turn ended);
  - `{:answer, request_id, label}`: `Stream.answer/5`, through the request the delegate holds;
    for an interactive delegate, `Intake.answer/4` on its held `PermissionRequest` row, whose
    id is the request's (`allow`, or a deny with a reason);
  - `:resume`: a dead delegate (its process gone, the row `running`) goes down the resume path
    a cue takes, which counts its one resume first: `{:ok, :resuming}`. A live one is refused
    as `:live`, one already resumed as `:resumed_once`, one whose agent row may still hold a
    process as `:session_running`, and one the path finished instead (its transcript ends with
    its last reply) with its status;
  - `:stop`: `Sessions.stop/3`, which writes `end_session` through
    `Stream`, only once `Mailbox` has the report delivered and no row to the delegate still
    `queued` or `sending`; else `{:refused, {:report, status}}` or `{:refused, {:open, ids}}`.
  """
  def fix(delegates, parent, name, fix, state),
    do: call(delegates, {:fix, parent, name, fix, state}, [], 2 * @call)

  @doc "Hands it a reader's cue: every row is read again. Answers `:ok` at once."
  def cue(delegates, %{topic: _}), do: GenServer.cast(delegates, :cue)

  @doc """
  The launch of delegate `name`'s next process, for a resume another part makes (`Mover`'s, on
  another account): its role, its worktree in its project, its model and what every launch
  shares, as its own resume has them. Not its options, which its agent row keeps and a resume
  takes again, nor its MCP config, which the caller issues. Answers `{:ok, launch}`,
  `{:refused, {:no_delegate, name}}` or `{:refused, {:unknown_project, project}}`.

      Delegates.launch(delegates, "app-unit-review")
      #=> {:ok, [role: :delegate, worktree: %{project: p, branch: "unit/review"}, model: "opus",
      #=>   claude: claude, env: env, tool_timeout: 3_600_000]}
  """
  def launch(delegates, name), do: call(delegates, {:launch, name}, [], @step)

  @doc """
  What `Delegates` reads, for `Cues`: a stream's events and a transcript's lines (a turn's end
  and its report), the agent rows (a start or an end) and `Mailbox`'s rows (a report taken).
  """
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(stream transcripts sessions mailbox), cue: &cue/2}

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
    keys = ~w(host sessions stream usage accounts transcripts mailbox projects launch)a
    s = Map.new(keys, &{&1, Keyword.fetch!(opts, &1)})

    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         {:ok, agents} <- Agents.open(Keyword.fetch!(opts, :sessions_db), s.host),
         {:ok, _} <- hand_over(s.sessions, Table.old_tree(db)),
         :ok <- Table.rebuild(db),
         {:ok, intake} <- Intake.reader(opts) do
      s =
        Map.merge(s, %{
          db: db,
          agents: agents,
          notify: Keyword.get(opts, :notify, fn _ -> :ok end),
          clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
          mcp: Keyword.get(opts, :mcp, fn _ -> {:ok, nil} end),
          acts: Keyword.get(opts, :acts),
          scheduler: Keyword.get(opts, :scheduler),
          lease: Keyword.get(opts, :lease, %{"seat" => 1}),
          registry: Keyword.get(opts, :registry),
          # An interactive delegate's fixes: Escape through the Inlet, and its held
          # PermissionRequests answered through Intake (F-137's new-3).
          inlet: Keyword.get(opts, :inlet),
          intake: intake,
          pending: %{},
          # An interactive delegate's marked lines found: {session id, uuid} to its byte offset.
          marks: %{}
        })

      # A start waiting for its lease when the Scheduler ends is refused: its queue is gone.
      s = Map.put(s, :scheduler_ref, s.scheduler && Process.monitor(s.scheduler))

      {:ok, s, {:continue, :settle}}
    else
      {_, reason} -> {:stop, reason}
    end
  end

  # The migration's hand-over: what `Sessions` takes before the old columns go.
  defp hand_over(_sessions, []), do: {:ok, 0}
  defp hand_over(sessions, entries), do: Sessions.adopt_tree(sessions, entries)

  @impl true
  def handle_continue(:settle, s) do
    # A resume this process's last life claimed and never saw answered ended with its call.
    if s.acts, do: Acts.interrupt(s.acts, actor(s))
    Stream.read(s.stream, timeout: @step)
    for row <- Table.with_status(s.db, s.host, Table.calling()), do: wake(s, row)

    {:noreply, settle(s)}
  end

  @impl true
  def handle_cast(:cue, s), do: {:noreply, settle(s)}

  @impl true
  def handle_call({:start, parent, project, branch, model, brief, options, how}, from, s) do
    with true <-
           Enum.all?([parent, model, brief], &(is_binary(&1) and &1 != "")) or
             {:refused, {:bad, :start}},
         :ok <- interactive_ok(s, how, brief),
         {:ok, options} <- Options.check(options),
         {:ok, p} <- Turn.check(s.projects, project, branch),
         # Move.tla's NoStartWhileDraining: no delegate starts under a parent a move drains.
         false <- Agents.moving?(Agents.get(s.agents, parent)) and {:refused, {:moving, parent}},
         true <- holding(s, parent) < p.cap or {:refused, {:cap, p.cap}},
         {:ok, account} <- pick(s) do
      # StartAsked: the row first, as starting, with its brief's uuid; then the brief's row.
      row = %{host: s.host, name: Turn.name(p, branch), branch: branch, model: model}
      row = Map.merge(row, %{brief_uuid: Stream.uuid(), deadline: deadline(s, p)})
      id = Table.starting(s.db, row)
      announce(s, id)
      row = Table.get(s.db, id)
      start = %{p: p, account: account, parent: parent, options: options, brief: brief, how: how}

      # Schedule.tla: the row is the lease's holder, written before the lease is asked for.
      case lease(s, row, project, account) do
        {:ok, _lease} ->
          begin(s, row, start, from)

        {:queued, %{id: request}} ->
          waiting = %{id: row.id, from: from, parent: parent, name: row.name, start: start}
          {:noreply, put_in(s.pending[request], waiting)}

        not_granted ->
          reply(answered(s, row, {:refused, {:lease, lease_refusal(not_granted)}}))
      end
    else
      refused -> {:reply, refused, s}
    end
  end

  def handle_call({:launch, name}, _from, s) do
    reply =
      with %{} = row <- Enum.find(Table.latest(s.db, s.host), &(&1.name == name)),
           %{project: project} <- agent(s, row),
           {:ok, p} <- Map.fetch(s.projects, project) |> known(project) do
        {:ok, launch(s, row, p, how(agent(s, row)))}
      else
        {:refused, _} = refused -> refused
        _ -> {:refused, {:no_delegate, name}}
      end

    {:reply, reply, s}
  end

  def handle_call({:fix_state, parent, name}, _from, s) do
    reply =
      with {:ok, row, agent, fold} <- child(s, parent, name),
           do: {:ok, claimed(row, agent, fold)}

    {:reply, reply, s}
  end

  # The act only while the claimed state is the delegate's, read again in this step.
  def handle_call({:fix, parent, name, fix, state}, from, s) do
    with {:ok, row, agent, fold} <- child(s, parent, name),
         now = claimed(row, agent, fold),
         true <- now == state or {:refused, {:moved, now}} do
      act(s, row, agent, fold, fix, from)
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

      {%{id: id, from: from} = call, pending} ->
        s = %{s | pending: pending}
        if call[:act], do: Acts.answered(s.acts, call.act, answer)
        {reply, s} = answered(s, Table.get(s.db, id), answer)
        if from, do: GenServer.reply(from, reply)
        {:noreply, s}
    end
  end

  def handle_info(:deadline, s), do: {:noreply, settle(s)}

  # The one more answer to a queued lease: the start goes on, or is refused.
  def handle_info({:lease, request, answer}, s) do
    case Map.pop(s.pending, request) do
      {%{start: start, from: from, id: id}, pending} ->
        s = %{s | pending: pending}
        row = Table.get(s.db, id)

        case answer do
          {:ok, _lease} ->
            # The call of Sessions starts now: its agent row is told from an earlier one by it.
            write(s, row, called_at: s.clock.(), deadline: deadline(s, start.p))
            began(begin(s, Table.get(s.db, id), start, from), from)

          {:refused, why} ->
            began(reply(answered(s, row, {:refused, {:lease, why}})), from)
        end

      {nil, _} ->
        {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{scheduler_ref: ref} = s) do
    waiting = for {request, %{start: _}} <- s.pending, do: request

    s =
      Enum.reduce(waiting, s, fn request, s ->
        {:noreply, s} = handle_info({:lease, request, {:refused, :scheduler_ended}}, s)
        s
      end)

    {:noreply, s}
  end

  # A start with its lease: the brief is stored, then Sessions is called. An interactive
  # delegate's brief goes in as its start's prompt: marked by launch first.
  defp begin(s, row, start, from) do
    with {:ok, _} <-
           Mailbox.brief(s.mailbox, start.parent, row.name, start.brief, row.brief_uuid)
           |> stored(),
         {:ok, launched} <- launch_first(s, row, start.how) do
      call = {start.parent, start.options}
      {:noreply, call_sessions(s, row, start.p, start.account, call, from, launched)}
    else
      not_started -> reply(answered(s, row, {:refused, not_started}))
    end
  end

  # What `begin/4` or a refusal answers, handed to a caller that waited for a queued lease.
  defp began({:noreply, s}, _from), do: {:noreply, s}

  defp began({:reply, reply, s}, from) do
    GenServer.reply(from, reply)
    {:noreply, s}
  end

  defp lease(%{scheduler: nil}, _row, _p, _account), do: {:ok, nil}

  defp lease(s, row, project, account) do
    key = Work.key(s.host, row.id)

    Scheduler.request(s.scheduler, %{
      # The row's start time too: a table made anew numbers its rows from 1 again.
      id: "delegate:#{key}:#{row.created_at}",
      class: :builder,
      module: project,
      account: account.name,
      units: s.lease,
      holder: {"delegate", key}
    })
  end

  defp lease_refusal({:refused, why}), do: why
  defp lease_refusal({:unknown, why}), do: {:unknown, why}

  # The parent's cap: its delegates the tree holds, and its starts under way here, whose agent
  # row may not be written yet. A start a restart cut before it reached `Sessions` never will.
  defp holding(s, parent) do
    starting = for {_, %{parent: ^parent, name: name}} <- s.pending, do: name
    Agents.children(s.agents, parent, starting)
  end

  # Called: Sessions writes its own row first and runs on through a restart of this process.
  # A start names the parent and the options; a resume takes the agent row's. An interactive
  # one carries the row `launch_first/3` marked as its prompt, and `Mailbox` is told the answer.
  defp call_sessions(s, row, p, account, start, from, launched) do
    launch = launch(s, row, p, if(launched, do: :interactive, else: :headless))
    launch = if launched, do: launch ++ [prompt: launched.text], else: launch
    mailbox = s.mailbox

    # The config is made in the task: the embedding app's `issue` may call a part that waits.
    task =
      Task.async(fn ->
        answer =
          with {:ok, mcp} <- s.mcp.(row.name) do
            launch = if mcp, do: launch ++ [mcp: mcp], else: launch

            case start do
              {:resume, session_id} ->
                Sessions.resume(s.sessions, row.name, account, session_id, launch, timeout: @call)

              {parent, options} ->
                launch = launch ++ [parent: parent, options: options]
                Sessions.start(s.sessions, row.name, account, launch, timeout: @call)
            end
          end

        if launched, do: Mailbox.launched(mailbox, launched.id, answer)
        answer
      end)

    parent = with {parent, _} when is_binary(parent) <- start, do: parent, else: (_ -> nil)
    put_in(s.pending[task.ref], %{id: row.id, from: from, parent: parent, name: row.name})
  end

  # An interactive delegate runs Claude Code's terminal interface, as a main session does: role
  # `:parent`, kind `:delegate`.
  defp launch(s, row, p, how) do
    role = if how == :interactive, do: :parent, else: :delegate
    tree = %{project: p, branch: row.branch}
    [role: role, kind: :delegate, worktree: tree, model: row.model] ++ s.launch
  end

  defp how(agent), do: if(agent && not Agents.headless?(agent), do: :interactive, else: :headless)

  # An interactive start needs the turn's reader and a brief its argument can carry.
  defp interactive_ok(_s, :headless, _brief), do: :ok
  defp interactive_ok(%{registry: nil}, :interactive, _brief), do: {:refused, :no_registry}

  defp interactive_ok(_s, :interactive, brief) do
    max = ClaudeCLI.prompt_max() - 200
    if byte_size(brief) <= max, do: :ok, else: {:refused, {:too_long, max}}
  end

  defp stored({:ok, _} = ok), do: ok
  defp stored(other), do: {:brief, other}

  # The first row due to an interactive delegate, marked by launch for the start the caller
  # makes next, by the row's deadline. A headless one's goes by its stream after the start.
  defp launch_first(_s, _row, :headless), do: {:ok, nil}

  defp launch_first(s, row, :interactive) do
    case Mailbox.launch(s.mailbox, row.name, row.deadline) do
      {:ok, %{id: _, text: _} = launched} -> {:ok, launched}
      other -> {:launch, other}
    end
  end

  # CallAnswered and Settled: a start or resume runs, and Mailbox delivers its turn's message; a
  # refused start is refused, and the rows to it end; a refused resume is the report. An
  # unknown answer leaves the row as it is, for Settled to decide.
  defp answered(s, row, {:ok, %{session_id: sid}}) do
    write(s, row, status: "running", reason: nil)
    agent = agent(s, row)
    answer = Map.take(row, [:id, :name, :brief_uuid])
    {{:ok, Map.merge(answer, %{session_id: sid, account: agent && agent.account})}, s}
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

  # Each name's latest row that may still move, with no call under way, read again.
  defp settle(s) do
    busy = MapSet.new(Map.values(s.pending), & &1.id)

    Table.latest(s.db, s.host)
    |> Enum.filter(&(&1.status in Table.open()))
    |> Enum.reject(&MapSet.member?(busy, &1.id))
    |> Enum.reduce(s, &settle_row(&2, &1, agent(&2, &1)))
  end

  # Settled: by the agent row of this call (written at or after the call) once that row is
  # settled; with none past the deadline, the call never reached Sessions and is not made again.
  defp settle_row(s, %{status: status} = row, agent) when status in ~w(starting resuming) do
    cond do
      Agents.since?(agent, row.called_at) and Agents.running?(agent) ->
        elem(answered(s, row, {:ok, agent}), 1)

      Agents.since?(agent, row.called_at) and Agents.free?(agent) ->
        elem(answered(s, row, {:refused, agent.reason || agent.status}), 1)

      Agents.since?(agent, row.called_at) ->
        s

      s.clock.() >= row.deadline ->
        elem(answered(s, row, {:refused, "interrupted"}), 1)

      true ->
        s
    end
  end

  # A report: handed again while Mailbox has not taken it. The agent ends once no process of it
  # may live: a failed one at once, as it is never resumed again; a finished one once its report
  # was delivered to its parent, since only then is it stopped (`stop`, `end_session`). It frees
  # its parent's cap, and no process of it runs again. Its report stays the parent's row.
  defp settle_row(s, %{status: status} = row, agent) when status in ~w(finished failed) do
    s = if row.report == "held", do: hand(s, row, answer(row)), else: s

    cond do
      Agents.ended?(agent) or not Agents.free?(agent) or Agents.moving?(agent) -> s
      status == "failed" or delivered?(s, row) -> ended(s, row)
      true -> s
    end
  end

  # A move under way ends the process and resumes it on another account itself: its end is not
  # a kill, and nothing of the row moves until the move is done.
  defp settle_row(s, row, agent) do
    with false <- Agents.moving?(agent),
         :headless <- how(agent),
         {:ok, fold} <- followed(s, agent) do
      case Turn.next(row, fold) do
        {:finished, r} -> finish(s, row, "finished", {:reply, r.text, r})
        :exited -> exited(s, row, agent, fold)
        :waiting -> s
      end
    else
      :interactive -> settle_interactive(s, row, agent)
      _unread -> s
    end
  end

  # An interactive delegate's report (F-137, `Delegate.tla`'s ReportAnswersTheBrief): the reply
  # of the turn its brief, or its word to go on, began, read from its transcript, once that
  # turn has ended: a later turn closed it, or its session reads its turn ended. Never the
  # transcript's last reply, which a person's later turn gives. Its process gone with no such
  # reply, it is resumed once, as a headless one is. A read that fails decides nothing.
  defp settle_interactive(s, row, agent) do
    {brief, s} = turn_of(s, agent, row.brief_uuid)

    {turn, s} =
      if row.resume_uuid && match?({:ok, _}, brief),
        do: turn_of(s, agent, row.resume_uuid),
        else: {brief, s}

    with {:ok, brief} <- brief,
         {:ok, turn} <- turn do
      reply = with {:ok, %{reply: text}} when is_binary(text) <- turn, do: text, else: (_ -> nil)

      cond do
        reply && Agents.free?(agent) ->
          finish(s, row, "finished", {:reply, reply, %{}})

        Agents.free?(agent) and row.resumes > 0 ->
          finish(s, row, "failed", {:notice, @twice})

        Agents.free?(agent) ->
          resume(s, row, agent, brief != :absent)

        reply && (match?({:ok, %{closed: true}}, turn) or turn_ended?(s, agent)) ->
          finish(s, row, "finished", {:reply, reply, %{}})

        true ->
          s
      end
    else
      _unread -> s
    end
  end

  # What the transcript holds of the turn the row `uuid` began (`Transcripts.Fold.reply_to/2`),
  # read from its marked line once that is found (F-137's new-4): the transcript is read from
  # byte 0 only until then. A mark no longer at its offset (a file rewritten) is looked for again.
  defp turn_of(s, %{session_id: sid} = agent, uuid) when is_binary(sid) do
    key = {sid, uuid}
    from = Map.get(s.marks, key, 0)

    case turn_from(s, agent, uuid, from) do
      {:ok, :absent} when from > 0 -> turn_of(%{s | marks: Map.delete(s.marks, key)}, agent, uuid)
      {:ok, turn, at} -> {{:ok, turn}, put_in(s.marks[key], at)}
      other -> {other, s}
    end
  end

  defp turn_of(s, _agent, _uuid), do: {{:unread, :no_session}, s}

  defp turn_from(s, agent, uuid, from) do
    t = s.transcripts
    sid = agent.session_id

    with {:ok, dir} <- Accounts.config_dir(s.accounts, agent.account),
         {:ok, path} <- Transcripts.path(dir, agent.cwd, sid),
         {:ok, %{failed: []}} <- Transcripts.read(t, [{agent.account, sid, path}], timeout: @step),
         {:ok, %{bytes: bytes, from: start}} <-
           Transcripts.text(t, agent.account, sid, from, timeout: @step) do
      mark = Waiter.mark(uuid)

      case Fold.marked_at(bytes, mark) do
        nil ->
          {:ok, :absent}

        at ->
          {:ok, Fold.reply_to(binary_part(bytes, at, byte_size(bytes) - at), mark), start + at}
      end
    else
      {:refused, :no_file} -> {:ok, :absent}
      other -> {:unread, other}
    end
  end

  # The session file of its process reads its turn ended (`Sessions.Turn.interactive/3`).
  defp turn_ended?(s, agent) do
    with {:ok, _} <- Registry.read(s.registry, timeout: @step),
         {:ok, %{rows: files}} <- Registry.rows(s.registry, agent.account, timeout: @step) do
      SessionsTurn.interactive(agent, files, false) in [:idle, :ended]
    else
      _ -> false
    end
  end

  defp ended(s, row) do
    Sessions.ended(s.sessions, row.name)
    s
  end

  defp delivered?(s, row),
    do: match?({:ok, %{status: "delivered"}}, Mailbox.answer_to(s.mailbox, row.brief_uuid))

  # Its process is gone with no result of its turn. TranscriptRead: a last reply is a finish.
  # KillSeen: a second kill is the report; a first is resumed once the agent row is free, which
  # Sessions' settle and cue bring (Sessions refuses to start a name whose process may live). A
  # read that fails decides nothing.
  defp exited(s, row, agent, fold) do
    t = s.transcripts
    session = {agent.account, agent.session_id, fold.transcript}

    with {:ok, %{failed: []}} <- Transcripts.read(t, [session], timeout: @step),
         {:ok, tr} <- Transcripts.session(t, agent.account, agent.session_id, timeout: @step) do
      cond do
        tr.ends_with_reply -> finish(s, row, "finished", {:reply, tr.last_reply.text, %{}})
        row.resumes > 0 -> finish(s, row, "failed", {:notice, @twice})
        Agents.free?(agent) -> resume(s, row, agent, went_in?(row, fold))
        true -> s
      end
    else
      _ -> s
    end
  end

  defp went_in?(row, fold), do: match?(%{state: :delivered}, fold.messages[row.brief_uuid])

  # The row counts the resume before Sessions is asked: a restart never asks it twice. When the
  # brief had gone in, Mailbox takes the word to go on first, under the row's new uuid; when it
  # had not, Mailbox has the brief due again. A word Mailbox did not take leaves the row
  # running, for the next cue.
  # An interactive delegate's resume carries the first row due to it as its prompt (the word
  # to go on, or the brief again), marked by launch after the claim; a mark refused answers the
  # claim and leaves the row running for the next cue.
  defp resume(s, row, agent, went_in?) do
    uuid = if went_in?, do: Stream.uuid()
    deadline = with {:ok, p} <- Map.fetch(s.projects, agent.project), do: deadline(s, p)

    with {:ok, p} <- Map.fetch(s.projects, agent.project) |> known(agent.project),
         {:ok, account} <- Accounts.ready(s.accounts, agent.account),
         {:ok, _} <-
           if(uuid,
             do: Mailbox.go_on(s.mailbox, row.name, Turn.resumed(), uuid),
             else: {:ok, nil}
           ),
         {:ok, act} <- claim_resume(s, row),
         {:ok, launched} <-
           launch_first(s, %{row | deadline: deadline}, how(agent)) |> told(s, act) do
      at = System.os_time(:millisecond)
      fields = [status: "resuming", resumes: 1, called_at: at, deadline: deadline]
      write(s, row, fields ++ [resume_uuid: uuid])
      start = {:resume, agent.session_id}
      s = call_sessions(s, Table.get(s.db, row.id), p, account, start, nil, launched)
      if act, do: put_in(s.pending, Map.new(s.pending, &with_act(&1, row.id, act))), else: s
    else
      {:refused, _} = refused -> elem(answered(s, row, refused), 1)
      _not_taken -> s
    end
  end

  defp told({:ok, _} = ok, _s, _act), do: ok

  defp told(not_marked, s, act) do
    if act, do: Acts.answered(s.acts, act, {:refused, not_marked})
    {:not_launched, not_marked}
  end

  # The resume's row in `Acts`, before the row counts it: its state is the delegate's row and
  # its resumes, so a state is resumed once, by the ledger as by the count. A claim refused
  # or unanswered resumes nothing now; the row stays for the next cue.
  defp claim_resume(%{acts: nil}, _row), do: {:ok, nil}

  defp claim_resume(s, row) do
    state = %{delegate: row.id, resumes: row.resumes}

    case Acts.claim(s.acts, actor(s), row.name, state, :resume) do
      {:ok, id} -> {:ok, id}
      other -> {:not_claimed, other}
    end
  end

  defp with_act({ref, %{id: id} = call}, id, act), do: {ref, Map.put(call, :act, act)}
  defp with_act(entry, _id, _act), do: entry

  defp actor(s), do: "delegates:" <> s.host

  defp known(:error, project), do: {:refused, {:unknown_project, project}}
  defp known(ok, _project), do: ok

  # The report's text is kept until Mailbox takes it.
  defp finish(s, row, status, answer) do
    write(s, row, status: status, report: "held", text: elem(answer, 1))
    hand(s, Table.get(s.db, row.id), answer)
  end

  defp answer(%{status: "finished"} = row), do: {:reply, row.text, %{}}
  defp answer(row), do: {:notice, row.text}

  # To the agent row's parent: a resume or a report comes only after a start reached Sessions.
  defp hand(s, row, answer) do
    with %{parent: parent} when is_binary(parent) <- agent(s, row),
         {:ok, _} <- Mailbox.report(s.mailbox, row.name, parent, row.brief_uuid, answer) do
      write(s, row, report: "taken")
    end

    s
  end

  defp reply({reply, s}), do: {:reply, reply, s}

  # The latest row of `name`, when its agent row of this start is `parent`'s, with Stream's
  # row of its process, just read. A start not yet in `Sessions` is not started.
  defp child(s, parent, name) do
    row = Enum.find(Table.latest(s.db, s.host), &(&1.name == name))
    agent = row && agent(s, row)
    own? = agent != nil and agent.parent == parent and Agents.since?(agent, row.created_at)

    cond do
      row == nil ->
        {:refused, {:no_delegate, name}}

      row.status in ~w(starting refused) and (own? or pending_parent(s, row) == parent) ->
        {:refused, {:not_started, row.status}}

      own? ->
        with {:ok, _} <- Stream.read(s.stream, timeout: @step),
             {:ok, fold} <- followed(s, agent),
             do: {:ok, row, agent, fold}

      true ->
        {:refused, {:no_delegate, name}}
    end
  end

  defp pending_parent(s, row),
    do: Enum.find_value(Map.values(s.pending), &(&1.id == row.id && &1.parent))

  defp claimed(row, agent, fold) do
    held = Enum.sort(for {id, %{state: :held}} <- fold.requests, do: id)
    state = Map.take(row, [:id, :status, :resumes, :report])

    Map.merge(state, %{offset: fold.offset, gone: fold.gone, ending: fold.ending, held: held})
    |> Map.put(:ended, Agents.free?(agent))
  end

  # An interactive delegate has no Stream: Escape through the Inlet, checked on its screen.
  defp act(s, row, agent, _fold, :interrupt, _from) do
    cond do
      Agents.headless?(agent) ->
        {:reply, Stream.interrupt(s.stream, row_session(s, row), timeout: @step), s}

      s.inlet == nil ->
        {:reply, {:refused, :no_inlet}, s}

      true ->
        {:reply, Inlet.interrupt(s.inlet, row.name, release: agent.release, timeout: @call), s}
    end
  end

  # An interactive delegate's request is Intake's held PermissionRequest, as a main session's.
  defp act(s, row, agent, fold, {:answer, request, label}, _from) do
    cond do
      Agents.headless?(agent) ->
        answer = Stream.answer(s.stream, row_session(s, row), request, label, timeout: @step)
        {:reply, answer, s}

      not Map.has_key?(fold.requests, request) ->
        {:reply, {:refused, {:not_held, request}}, s}

      true ->
        decision = if label == "allow", do: :allow, else: {:deny, "Denied by its parent."}
        id = String.to_integer(request)
        {:reply, Intake.answer(s.intake.pid, id, decision, timeout: @step), s}
    end
  end

  # The resume path a cue takes once the process is gone and the agent row is free. A wedged
  # delegate, alive but stuck, is not stopped first: F-100's build note, new-1.
  defp act(s, row, agent, fold, :resume, _from) do
    cond do
      row.resumes > 0 ->
        {:reply, {:refused, :resumed_once}, s}

      not fold.gone ->
        {:reply, {:refused, :live}, s}

      row.status != "running" ->
        {:reply, {:refused, {:status, row.status}}, s}

      not Agents.free?(agent) ->
        {:reply, {:refused, :session_running}, s}

      true ->
        resumed(exited(s, row, agent, fold), row.id)
    end
  end

  # The report delivered and nothing open to it, by Mailbox; Sessions waits for the exit, and
  # this process does not wait with it. An ended delegate has nothing left to stop.
  defp act(s, row, agent, _fold, :stop, from) do
    with true <- not Agents.ended?(agent) or {:refused, {:status, "ended"}},
         {:ok, %{status: "delivered"}} <- report(s, row),
         {:ok, []} <- Mailbox.open_to(s.mailbox, row.name) |> open() do
      me = self()

      Task.start(fn ->
        reply = Sessions.stop(s.sessions, row.name, timeout: @call)
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

  defp row_session(s, row), do: agent(s, row).session_id

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

  defp agent(s, row), do: Agents.get(s.agents, row.name)

  # What a fix reads of a delegate: Stream's row of a headless one's process; for an
  # interactive one, what Intake holds of its session: the newest hook event's id (any event
  # moves it, as each read event moves a log's offset), the PermissionRequests it holds, and
  # whether its process runs.
  defp followed(s, agent) do
    if Agents.headless?(agent), do: streamed(s, agent), else: hooked(s, agent)
  end

  defp hooked(%{intake: nil}, _agent), do: {:unknown, :no_intake}

  defp hooked(s, %{session_id: sid} = agent) when is_binary(sid) do
    case IntakeTable.session(s.intake.db, s.host, agent.account, sid) do
      {:ok, %{last: last, held: held}} ->
        requests = Map.new(held, &{Integer.to_string(&1), %{state: :held}})
        gone = not Agents.running?(agent)
        {:ok, %{offset: last, gone: gone, ending: false, requests: requests}}

      :unread ->
        {:unknown, :intake_unread}
    end
  end

  defp hooked(_s, _agent), do: {:unknown, :no_session}

  defp streamed(s, %{session_id: sid}) when is_binary(sid) do
    case Stream.rows(s.stream, timeout: @step) do
      {:ok, %{rows: rows}} ->
        found = Enum.find(rows, &(&1.session == sid))
        if found, do: {:ok, found}, else: {:unknown, :not_followed}

      unread_or_failed ->
        unread_or_failed
    end
  end

  defp streamed(_s, _agent), do: {:unknown, :no_session}

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
