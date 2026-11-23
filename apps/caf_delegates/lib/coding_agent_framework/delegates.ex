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
  kill, and its row waits for the move. It picks the usable account with the most room
  (`Usage.pick/4`: by `usable:`, the most room in the tighter window), and writes its row first, as `starting`, with the uuid its brief will go in
  under. With a `scheduler:`, it then asks for a lease, class `:builder`, its module the
  project, on that account, naming the row as the lease's holder (`Delegates.Work` answers
  whether its work ended): granted, the start goes on; queued, it waits in this process for the
  one more answer, the caller with it; refused, the row is `refused` with reason `{:lease,
  {reason, retry_at}}`, which is never a failed run. The brief is then stored in `Mailbox` under
  that uuid, before anything of the delegate exists, so it is the first row to it, and marked
  `sending` by `stream` for the start (`Mailbox.launch/4`, `via: :stream`; F-152): a headless
  process writes its `system`/`init` only after it read a line, so `Sessions` writes the brief
  (`first:`) right after the hold, before it waits for that init. A task starts the session
  through `Sessions`, role `:delegate`, with its parent, in the project's worktree, and its
  answer moves the row, and is told to `Mailbox` (`launched/3`): `running` (the brief's replay
  then settles its row), or `refused`, and `Mailbox` ends the rows to it. A row a restart left
  `starting` is settled by the agent row of its call, once that row is settled; with no such
  row by the row's deadline, the call never reached `Sessions`, and the row is refused as
  `interrupted`. That reading holds because the call carries a caller's deadline before the
  row's (`Sessions.start/5`'s `:caller_deadline`, the row's deadline less the slack): a call
  still in `Sessions`' mailbox past it, after its task gave up or this process restarted, is
  refused there `caller_gone` and makes nothing (F-166). A row still `starting` takes one fix, `:stop` (`Sessions.stop/3` ends its held
  program by its record), and its start then settles refused.

  **A running delegate** is read from its `Stream` row at each cue: once the turn's message is
  delivered and a `result` names it, the row is `finished` with that result as its report.
  When its process is gone first, the transcript says whether it had given its last reply: if
  so it finished with that reply. Otherwise it is resumed once, after its agent row is free (no
  process of it may live): the row counts the resume first, as `resuming`, then
  `Sessions.resume/6` follows it again, with the agent row's own options. It resumes on its
  agent row's account, where its conversation is, while `usable:` takes that account; refused
  there (the app flags it, F-209), on the account `Usage.pick/4` finds among the others, the
  conversation copied there first (`Transcripts.Copy`, the `Mover`'s, an act `copy`), as a main
  session's resume does; with none usable the resume is refused with its own account's reason,
  `{:app, reason}` for the app's, and never runs on a refused account. When the brief had
  gone in, `Mailbox` is first given the word to go on (`go_on/4`, under the row's
  `resume_uuid`), which goes before any other row to it; when it had not, `Mailbox` has the
  brief due again itself. That first row is marked and carried as the start's is; with none due
  yet, the resume waits for the next cue. A second such kill, or a refused resume, is `failed`,
  and that is the report, a notice from `framework`. A row leaves `running` once.

  **A turn at a usage limit** (F-186's new-1, `Limit.tla`'s `Report`): a headless turn that
  ends with a `result` whose `api_error` is `usage_limit_reached` is not finished, and its
  process's exit (Claude Code exits at once) is not a kill: the row stays `running`, with no
  report, and waits. At the reset the limit's healer calls `go_on/5`: the word to go on is
  stored first and the turn is its from then; a gone process is resumed with it as `going_on`,
  which `resumes` does not count. An interactive delegate's turn whose transcript ends with the
  limit's line is read the same way (F-187's new-2): neither a finish nor a kill, its word
  `go_on/5`'s, its report the reply of the word's turn. Before a move of the limit, the healer
  stores the word with no resume (`resume: false`), and the move's resume carries it (F-191).

  **An interactive delegate** (`interactive: true`, F-137; `docs/design.md`, "Interactive
  delegates") runs Claude Code's terminal interface: role `:parent`, kind `:delegate`. Its brief
  is marked by `Mailbox.launch/4` and carried by its start as the prompt; its report is the
  reply of the turn its brief (or its word to go on) began, read from its transcript
  (`Transcripts.Fold.reply_to/2`) once that turn has ended: closed by a later turn, or its
  session file read ended through `registry:`. Its resume carries the word to go on by launch.

  **A delegate idle with no report** (F-150, `Delegate.tla`'s `IdleNoticed`): a running row
  whose turn has ended by its kind's rule (`Sessions.Turn`; an interactive one's session file),
  with no row to it open in `Mailbox`, for longer than the app's `idle_bound:`, is told to its
  parent once per idle state, by `Mailbox.notify/4` under the state's key. Never a kill or a
  nudge into the delegate. The state ends when a turn starts, a report is taken, or it ends.

  **A turn of its own after its report** (F-155, `Delegate.tla`'s TurnToldOnce, TurnNotReport
  and TurnNoticed): a background command of the delegate's own wakes it, and the turn answers
  no message. Once its report is taken, each such turn that has ended is told to its parent as
  a `notice` (`Mailbox.notify/4`) with its last reply, under `turn:<host>:<uuid>`, its
  result's uuid (a headless one's `Stream` fold keeps them in `own`) or its reply line's (an
  interactive one's, read from its transcript after the report's turn, the turn begun by a
  `<task-notification>` that carries no delivery mark). Never as the report.

  **The report** is handed to `Mailbox` (`Mailbox.report/5`) under the brief's uuid, to the
  agent row's parent, and the row's `report` is then `taken`; until `Mailbox` takes it, it is
  `held`, with its text, and handed again at each cue. The row keeps how the report was taken
  (`taken_by`, F-202): `result`, `transcript` (its process gone first) or `turn_end`.

  **An ended delegate**: once no process of it may live, a failed one at once (it is never
  resumed again), one whose start was refused after its call reached `Sessions` at once too
  (its process ran and was stopped, and it has no report; F-153's new-7), and a finished one
  once its report was delivered (only then is it stopped, by `stop` or `end_session`), a cue
  asks `Sessions.ended/3`, and its agent row is `ended`: it
  frees its parent's cap, and what it owns ends (what it kept goes to its parent, its edge in
  the tree staying). Its report stays its parent's.

  **A parent's fix** (`fix_state/3`, `fix_check/2`, `fix/5`; `Team.tla`'s `Needed` and
  `FixActs`) is checked against the state and claimed by its caller (`MCP`); here it acts only
  while the state it claimed is still the delegate's,
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

  alias CodingAgentFramework.{Accounts, Acts, Inlet, Intake, Mailbox, Registry}
  alias CodingAgentFramework.Scheduler
  alias CodingAgentFramework.Intake.Table, as: IntakeTable
  alias CodingAgentFramework.{Sessions, Stream, Transcripts, Usage}
  alias CodingAgentFramework.Mailbox.Transport.Waiter
  alias CodingAgentFramework.Sessions.Turn, as: SessionsTurn
  alias CodingAgentFramework.Transcripts.Fold
  alias CodingAgentFramework.ClaudeCLI
  alias CodingAgentFramework.ClaudeCLI.Options
  alias CodingAgentFramework.Delegates.{Table, Turn, Work}
  alias CodingAgentFramework.Sessions.Agents

  # Sessions' own timeout for a start or a resume; its git bounds and slack come on top.
  @call 30_000
  @slack 120_000
  @step 5_000
  # After a usage limit's reset, before a waiting start picks again (F-196), as the healer's.
  @margin 120_000
  @twice "The delegate was killed twice before its last reply; it is not resumed again."

  @doc """
  Starts a `Delegates`. Options: `host:` (the name of the host `sessions:` and `stream:` run
  on), `db:`, `sessions_db:` (the file `Sessions`' table is in, read through
  `Sessions.Agents`), `usage:`, `accounts:`, `transcripts:` (the host's `Transcripts`),
  `mailbox:` (the host's `Mailbox`), `projects:` (name to a project as
  `Sessions.Worktree.project/1` reads it, with `branches:` and `cap:`), `launch:` (`claude:`,
  `env:` and `tool_timeout:` for `ClaudeCLI`), and optionally `notify:`, `clock:` (wall-clock
  ms), `usable:` (a function of an account answering `{:ok, account}` for one a launch may
  run on now, else why not: `CodingAgentFramework.Logins.usable/3`; by default
  `Accounts.ready/2`) and `mcp:`, a function of the delegate's name that answers `{:ok, path}`, its own MCP
  config (the embedding app gives `MCP.issue/2`), or a refusal. Each start and resume calls it
  just before its launch and adds the path as `ClaudeCLI`'s `mcp:`; its refusal refuses the
  start, and with no `mcp:` a delegate runs without the framework's tools. With `acts:` (the
  instance's `Acts`), its own resume after a first kill is a row there, actor
  `delegates:<host>`, state the delegate's row and resumes, claimed before the row counts it
  and settled by `Sessions`' answer (`Acts.answered/4`); a claim not taken resumes nothing.
  Each kill it sees is a row there first (F-202), act `killed`, keyed
  `killed:<host>:<row id>:<resumes>`, written before the row decides between a resume and a
  failure, so the metrics count a kill whatever followed it.
  With `scheduler:` (the instance's `Scheduler`), each start asks it for a lease first, of the
  units `lease:` names (default `%{"seat" => 1}`); a resume runs under the start's lease.
  With `registry:` (the host's `Registry`), it starts interactive delegates, whose turn's end
  it reads from their session files. With `inlet:` (the host's `Inlet`), `intake:` (the host's
  `Intake`) and `intake_db:` (its file), a parent's fixes reach an interactive delegate as they
  reach a main session (F-137's new-3): its interrupt is Escape through the `Inlet`, and its
  answer goes to the `PermissionRequest` `Intake` holds for it. With `idle_bound:` (ms), a
  delegate idle with no report for longer than it is told to its parent, once per idle state;
  an interactive one's needs `registry:` and `intake:`. With `name_room:` (bytes, the room the
  home leaves for an agent's socket, `Config.name_room/1`), a start whose delegate's name is
  longer is refused `{:bad, :name, {:longer_than, n}}` before any row (F-172). With
  `limit_margin:` (ms, default 120 000), a start that waits at a usage limit picks again that
  long after its reset (F-196).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The topics of the cues it writes, each as its whole shape, `*` for a word it fills in
  (`CodingAgentFramework.Cues`): `delegates:<host>`.
  """
  @spec writes() :: [String.t()]
  def writes, do: ~w(delegates:*)

  @doc """
  Starts a delegate of `parent` (a main session's name) on `branch` of `project`, with `model`,
  and `brief` as its first message, stored in `Mailbox`. Answers `{:ok, %{id, name,
  session_id, account, brief_uuid}}`, the report being the reply to `brief_uuid`; `{:refused,
  reason}`; or `{:unknown, reason}`, when its row stays `starting` for a later read to settle.

  A start is idempotent per branch (`Delegates.Turn.again/3`): while the branch's delegate of
  `parent` has a live session, a second start answers that delegate, with `already: true`, and
  writes nothing (its brief and options are not used). A row with no report whose process is
  gone does not count as running: the start goes on as a new row, the old one is never resumed,
  and its brief and word to go on are settled `ended` in `Mailbox` first (`{:refused,
  {:in_flight, name}}` while one is still in flight). It refuses `{:starting, name}` while a
  start or resume of the name is under way, `{:other_parent, name}` for another parent's
  delegate, and `{:delegate, %{name, status, session}}` for one neither live nor gone.
  Options: `:timeout`, what the caller waits (default 300 000 ms; the start goes on past it),
  and `:options` (`ClaudeCLI.Options`), checked before the row and kept on the agent row,
  which its resume takes again; `:effort`, how hard the model thinks, one of
  `ClaudeCLI.efforts/0` (`low`, `medium`, `high`, `xhigh`, `max`), launched as `--effort <level>`
  and kept on the delegate's row, which its resume launches with again (F-200), and refused
  `{:effort, value}` for any other value, before any row, with none meaning no flag;
  `:meta`, a map of the app's own keys kept on the agent row
  (`Sessions.start/5`; refused `{:bad, :meta}` when not a map), never read by the framework;
  and `interactive: true` for the terminal interface, refused
  `:no_registry` by a `Delegates` given no `registry:`. A brief longer than a launch's argument
  carries goes as a pointer to its file (`Mailbox.launch/4`, F-155).

  A delegate's settings default `includeGitInstructions` to false, so it starts without Claude
  Code's built-in git instructions; a main session keeps them. An app that wants a delegate's
  back sets it true in that delegate's `:options` settings, which wins over the default (F-200).

  `wait: false` (F-170; `Delegate.tla`'s Queued): a start whose lease is queued answers at
  once, `{:ok, %{id, name, brief_uuid, session_id: nil, account, queued: position}}`, and goes
  on. Its row says first that its parent is owed the outcome; once the row leaves `starting`
  (running, or refused with its reason: a lease refused with its retry time, or a start a
  restart cut, at its deadline) the parent is told by a notice from `framework`
  (`Mailbox.notify/4`, `kind: :notice`) stored under the row's key, which `Mailbox` takes once,
  across restarts. By default (`wait: true`) the caller waits for the lease, as before.

  **At a usage limit** (F-196; `Limit.tla`'s StartRefusedAtLimit): when every usable account is
  limited, the pick refuses `{:allowance, until}`, and the start writes its row `waiting` for
  that soonest reset, its request kept on the row and its parent owed the outcome, and answers
  at once, whatever `wait:`, `{:ok, %{id, name, brief_uuid, session_id: nil, account: nil,
  waiting: until}}`. The row is a `limit` prompt (`answer_wait/4`). At the reset plus
  `limit_margin:` it picks its account again and asks for its lease under its own request id
  (StartAtReset); a newer limit makes it wait for that reset. Once it leaves `waiting` its
  parent is told as above. A second start of its name is refused `{:waiting, name}`.
  """
  def start_delegate(delegates, parent, project, branch, model, brief, opts \\ []) do
    how = if Keyword.get(opts, :interactive, false), do: :interactive, else: :headless
    meta = Keyword.get(opts, :meta)
    wait = Keyword.get(opts, :wait, true)
    own = {Keyword.get(opts, :options), meta, wait, Keyword.get(opts, :effort)}
    call(delegates, {:start, parent, project, branch, model, brief, own, how}, opts, 300_000)
  end

  @doc """
  The state of `parent`'s delegate `name` that a fix claims (`Team.tla`'s `epoch`), read after
  a read of `Stream`: the row's `id`, `status`, `resumes` and `report`, and from `Stream`'s row
  of its process the log's `offset` (each event read moves it), `gone`, `ending`, and the ids
  of the requests `held`; and whether its agent row is free of a process (`ended`). For an
  interactive delegate, which has no `Stream` row, `offset` is the id of the newest hook event
  `Intake` stored for its session, `held` the ids of the `PermissionRequest` rows it holds, and
  `gone` whether its agent row is not running. A fix of one state acts once; any event, exit,
  end, answer, resume or report moves it. The latest row of that name is the delegate. A row
  still `starting` has no process read yet: its state is its row's, with `offset` nil, and it
  takes only `:stop` (F-152). Answers `{:ok, state}`, or `{:refused, {:no_delegate, name}}`,
  `{:refused, {:not_started, "refused"}}`, `{:unknown, :no_intake}` for an interactive one with
  no `intake:`, or `Stream`'s.

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
    Of a row still `starting` (F-152): `Sessions.stop/3` ends its held program by SIGTERM to
    its record, `{:ok, :stopped}` once it is gone, and the start settles refused. Any other fix
    of such a row is `{:refused, {:not_started, "starting"}}`.
  """
  def fix(delegates, parent, name, fix, state),
    do: call(delegates, {:fix, parent, name, fix, state}, [], 2 * @call)

  @doc """
  What `fix` needs of `state` (`fix_state/3`'s), read from that state alone, so a caller checks
  it before it claims the state (`Team.tla`'s Needed, F-149) and a fix the state refuses takes no
  claim. `fix/5` checks it again on the state it acts on. A `:resume` is refused as `fix/5`
  refuses it: `:resumed_once`, `:live` (its process not gone), `{:status, status}` and
  `:session_running` (its agent row not free); a `:stop` `{:report, report}` while its report is
  not handed to `Mailbox`; an `:interrupt` `:gone` once its process is. What only the act meets
  is checked then: a stop's report not yet delivered, an interactive turn not on the screen.

      Delegates.fix_check(:resume, %{resumes: 0, gone: false, status: "running", ended: false})
      #=> {:refused, :live}
  """
  def fix_check(:resume, state) do
    cond do
      state.resumes > 0 -> {:refused, :resumed_once}
      not state.gone -> {:refused, :live}
      state.status != "running" -> {:refused, {:status, state.status}}
      not state.ended -> {:refused, :session_running}
      true -> :ok
    end
  end

  def fix_check({:stop, :force}, state), do: fix_check(:stop, state)
  def fix_check(:stop, %{report: "taken"}), do: :ok
  def fix_check(:stop, %{report: report}), do: {:refused, {:report, report}}
  def fix_check(:interrupt, %{gone: true}), do: {:refused, :gone}
  def fix_check(_fix, _state), do: :ok

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
  Goes on with delegate `name`'s turn after a usage limit, for the limit's healer at the reset
  (F-186's new-1; `Limit.tla`'s `Report` and `Deliver`): its turn at the limit was not its
  report, so the turn its brief began is still open. A headless one's turn is read from its
  stream (`Delegates.Turn.next/2`'s `:limited`), an interactive one's from its transcript,
  whose last limit line no turn followed (F-187's new-2). `text` is stored as its word to go on
  (`Mailbox.go_on/4`, which goes before every other row to it) under a uuid of `key`
  (`Delegates.Turn.word_uuid/1`), so it is stored once per limit, and the row's turn is that
  word's from then: its report is that turn's reply. A live process takes it into its ended
  turn, by its stream or typed: `{:ok, :live}`. A gone one is resumed with it as its first line
  (an interactive one's prompt, by launch), under its start's lease, as `going_on`: not counted
  as the resume after a kill, and a refusal leaves the row `running`, still limited. Its account
  is chosen as a resume after a kill chooses it (F-209): its own while `usable:` takes it, else
  the one the pick finds, its conversation copied there first, else refused. The answer
  is `Sessions`'. With `resume: false` (before a move, F-191) the word is stored and nothing
  resumes: `{:ok, :stored}`, the move's resume carrying it.

  Refused with nothing written: `{:no_delegate, name}`, `{:status, status}` for a row not
  `running`, `{:not_limited, what}` for a turn not at a limit, and `:session_running` for a
  process gone whose agent row is not yet free.

      Delegates.go_on(delegates, "app-unit-review", "Go on.", "limit:app-unit-review:1800000000")
      #=> {:ok, %{id: 1, name: "app-unit-review", session_id: "…", account: "work", …}}
  """
  def go_on(delegates, name, text, key, opts \\ []),
    do:
      call(delegates, {:go_on, name, text, key, Keyword.get(opts, :resume, true)}, opts, 300_000)

  @doc """
  Answers the `limit` prompt of start row `id`, which waits at a usage limit (F-196;
  `Limit.tla`'s AnswerWait and AnswerLeave), as `who`, once per reset: `"wait"` keeps it waiting
  for its reset, as its default at its deadline would (`waited` names `who`, and the prompt
  leaves the inbox); `"leave"` refuses the row with reason `left`, and its parent is told.
  Answers `{:ok, :waiting}` or `{:ok, :left}`; `{:refused, :settled}` for a row no longer
  waiting or answered for this reset; `{:refused, :no_start}`; `{:refused, {:bad, :choice}}`.

      Delegates.answer_wait(delegates, 7, "leave", "sam")
      #=> {:ok, :left}
  """
  def answer_wait(delegates, id, choice, who),
    do: call(delegates, {:answer_wait, id, choice, who}, [], @step)

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
          usable: Keyword.get(opts, :usable, &Accounts.ready(s.accounts, &1)),
          acts: Keyword.get(opts, :acts),
          scheduler: Keyword.get(opts, :scheduler),
          lease: Keyword.get(opts, :lease, %{"seat" => 1}),
          margin: Keyword.get(opts, :limit_margin, @margin),
          registry: Keyword.get(opts, :registry),
          # An interactive delegate's fixes: Escape through the Inlet, and its held
          # PermissionRequests answered through Intake (F-137's new-3).
          inlet: Keyword.get(opts, :inlet),
          intake: intake,
          pending: %{},
          # An interactive delegate's marked lines found: {session id, uuid} to its byte offset.
          marks: %{},
          # The delegates idle with no report: row id to its idle state's key, when this
          # process first read it, and whether its parent was told.
          idle_bound: Keyword.get(opts, :idle_bound),
          name_room: Keyword.get(opts, :name_room),
          idle: %{},
          # The turns of a delegate's own told to its parent: row id to their keys. Mailbox
          # holds the keys; this only spares it a repeat at each cue.
          turns: %{}
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
    for row <- Table.with_status(s.db, s.host, ["waiting" | Table.calling()]), do: wake(s, row)

    {:noreply, settle(s)}
  end

  @impl true
  def handle_cast(:cue, s), do: {:noreply, settle(s)}

  # The room the home leaves for the delegate's socket (`Config.name_room/1`, F-172), checked
  # before any row.
  defp fits(%{name_room: room}, name) when is_integer(room) and byte_size(name) > room,
    do: {:refused, {:bad, :name, {:longer_than, room}}}

  defp fits(_s, _name), do: :ok

  # The effort a start names (F-200): one of the levels `claude --effort` takes, or none. Checked
  # before any row, so a bad one writes nothing.
  defp effort_ok(nil), do: :ok

  defp effort_ok(effort),
    do: if(effort in ClaudeCLI.efforts(), do: :ok, else: {:refused, {:effort, effort}})

  @impl true
  def handle_call(
        {:start, parent, project, branch, model, brief, {options, meta, wait, effort}, how},
        from,
        s
      ) do
    with true <-
           Enum.all?([parent, model, brief], &(is_binary(&1) and &1 != "")) or
             {:refused, {:bad, :start}},
         :ok <- interactive_ok(s, how),
         {:ok, options} <- Options.check(options),
         :ok <- effort_ok(effort),
         true <- meta == nil or is_map(meta) or {:refused, {:bad, :meta}},
         {:ok, p} <- Turn.check(s.projects, project, branch),
         name = Turn.name(p, branch),
         :ok <- fits(s, name),
         old = Enum.find(Table.latest(s.db, s.host), &(&1.name == name)),
         {:go, again} <- again(s, old, parent),
         # Move.tla's NoStartWhileDraining: no delegate starts under a parent a move drains.
         false <- Agents.moving?(Agents.get(s.agents, parent)) and {:refused, {:moving, parent}},
         true <- holding(s, parent, name) <= p.cap or {:refused, {:cap, p.cap}},
         picked = pick(s),
         :ok <- picked_or_limited(picked),
         :ok <- if(again, do: replaced(s, old), else: :ok) do
      row = %{host: s.host, name: name, branch: branch, model: model, effort: effort}
      row = Map.put(row, :brief_uuid, Stream.uuid())
      start = %{p: p, parent: parent, options: options, brief: brief, how: how, meta: meta}

      case picked do
        {:ok, account} ->
          # StartAsked: the row first, as starting, with its brief's uuid; then the brief's row.
          id = Table.starting(s.db, Map.put(row, :deadline, deadline(s, p)))
          announce(s, id)
          # StartAgain: the old row is history now, never resumed; it says why.
          if again, do: write(s, old, reason: "replaced")
          leased(s, Table.get(s.db, id), Map.put(start, :account, account), from, wait)

        # Limit.tla's StartRefusedAtLimit (F-196): every usable account is limited, so the row
        # waits for the soonest reset, its parent owed the outcome, and the caller is answered.
        {:refused, {:allowance, until}} ->
          kept = Map.put(Map.delete(start, :p), :project, project)
          fields = %{until: until, deadline: until + s.margin, tell: parent, start: kept}
          id = Table.waiting(s.db, Map.merge(row, fields))
          announce(s, id)
          if again, do: write(s, old, reason: "replaced")
          row = Table.get(s.db, id)
          wake(s, row)
          answer = %{started(row, nil) | account: nil}
          {:reply, {:ok, Map.put(answer, :waiting, until)}, s}
      end
    else
      # A refusal, or the answer of the delegate already there.
      answer -> {:reply, answer, s}
    end
  end

  def handle_call({:answer_wait, id, choice, who}, _from, s) do
    reply =
      case Table.get(s.db, id) do
        %{host: host, status: "waiting"} = row when host == s.host ->
          wait_answer(s, row, choice, who)

        %{host: host} when host == s.host ->
          {:refused, :settled}

        _ ->
          {:refused, :no_start}
      end

    {:reply, reply, s}
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

  def handle_call({:go_on, name, text, key, resume?}, from, s) do
    row = Enum.find(Table.latest(s.db, s.host), &(&1.name == name))
    agent = row && agent(s, row)

    with %{} <- agent || {:refused, {:no_delegate, name}},
         true <- row.status == "running" or {:refused, {:status, row.status}},
         {:ok, live?} <- limited_turn(s, row, agent),
         uuid = Turn.word_uuid(key),
         {:ok, _} <- Mailbox.go_on(s.mailbox, row.name, text, uuid) do
      if row.resume_uuid != uuid, do: write(s, row, resume_uuid: uuid)
      row = Table.get(s.db, row.id)

      cond do
        # Before a move (F-191): the word is held, and the move's resume carries it.
        not resume? -> {:reply, {:ok, :stored}, s}
        live? and Agents.running?(agent) -> {:reply, {:ok, :live}, s}
        Agents.free?(agent) -> went_on(s, row, agent, from)
        true -> {:reply, {:refused, :session_running}, s}
      end
    else
      other -> {:reply, other, s}
    end
  end

  def handle_call({:fix_state, parent, name}, _from, s) do
    reply =
      case child(s, parent, name) do
        {:ok, row, agent, fold} -> {:ok, claimed(row, agent, fold)}
        {:starting, row} -> {:ok, starting(row)}
        refused -> refused
      end

    {:reply, reply, s}
  end

  # The act only while the claimed state is the delegate's, read again in this step, and needs
  # the fix, for a caller that did not check it before its claim (F-149). A row still starting
  # takes only a stop (F-152).
  def handle_call({:fix, parent, name, fix, state}, from, s) do
    case child(s, parent, name) do
      {:ok, row, agent, fold} ->
        now = claimed(row, agent, fold)

        cond do
          now != state -> moved(now, s)
          (checked = fix_check(fix, now)) != :ok -> {:reply, checked, s}
          true -> act(s, row, agent, fold, fix, from)
        end

      {:starting, row} ->
        now = starting(row)

        cond do
          now != state -> moved(now, s)
          fix in [:stop, {:stop, :force}] -> stop_starting(s, row, from)
          true -> {:reply, {:refused, {:not_started, "starting"}}, s}
        end

      refused ->
        {:reply, refused, s}
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
        {:noreply, tell_starts(s)}
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
            {:noreply, s} = began(begin(s, Table.get(s.db, id), start, from), from)
            {:noreply, tell_starts(s)}

          {:refused, why} ->
            {:noreply, s} = began(reply(answered(s, row, {:refused, {:lease, why}})), from)
            {:noreply, tell_starts(s)}
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

  # A start with its lease: the brief is stored and marked for the start (`launch_first/3`),
  # then Sessions is called, which carries it: an interactive one's as its prompt, a headless
  # one's as the line it writes right after the hold.
  defp begin(s, row, start, from) do
    with {:ok, _} <-
           Mailbox.brief(s.mailbox, start.parent, row.name, start.brief, row.brief_uuid)
           |> stored(),
         {:ok, launched} <- launch_first(s, row, start.how) do
      call = {start.parent, start.options, start.meta}
      {:noreply, call_sessions(s, row, start.p, start.account, call, from, launched)}
    else
      not_started -> reply(answered(s, row, {:refused, not_started}))
    end
  end

  # What `begin/4` or a refusal answers, handed to a caller that waited for a queued lease.
  defp began({:noreply, s}, _from), do: {:noreply, s}
  defp began({:reply, _reply, s}, nil), do: {:noreply, s}

  defp began({:reply, reply, s}, from) do
    GenServer.reply(from, reply)
    {:noreply, s}
  end

  # A pick that found an account, or refused at a limit (the start waits); any other refusal
  # refuses the start.
  defp picked_or_limited({:ok, _}), do: :ok
  defp picked_or_limited({:refused, {:allowance, _}}), do: :ok
  defp picked_or_limited(other), do: other

  # Schedule.tla: the row is the lease's holder, written before the lease is asked for. `from`
  # is nil for a start that picked again at its reset (F-196): its caller was answered.
  defp leased(s, row, start, from, wait) do
    case lease(s, row, start.p.name, start.account) do
      {:ok, _lease} ->
        begin(s, row, start, from)

      {:queued, %{id: request}} when wait and from != nil ->
        waiting = %{id: row.id, from: from, parent: start.parent, name: row.name, start: start}
        {:noreply, put_in(s.pending[request], waiting)}

      # Delegate.tla's Queued: the row says first that its parent is owed the outcome, then
      # the caller is answered; the one more answer of the lease comes to no caller.
      {:queued, %{id: request} = queued} ->
        write(s, row, tell: start.parent)
        waiting = %{id: row.id, from: nil, parent: start.parent, name: row.name, start: start}
        answer = %{started(row, nil) | account: start.account.name}
        answer = Map.put(answer, :queued, queued[:position])
        {:reply, {:ok, answer}, put_in(s.pending[request], waiting)}

      not_granted ->
        reply(answered(s, row, {:refused, {:lease, lease_refusal(not_granted)}}))
    end
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

  # The parent's cap, with the start of `name` in it: its delegates the tree holds, and its
  # starts under way here, whose agent row may not be written yet (a start a restart cut before
  # it reached `Sessions` never will). A name started again is counted once (StartAgain).
  defp holding(s, parent, name) do
    starting = for {_, %{parent: ^parent, name: n}} <- s.pending, do: n
    # A start that waits at a usage limit holds its place too (F-196).
    waiting = for %{tell: ^parent, name: n} <- Table.with_status(s.db, s.host, ["waiting"]), do: n
    Agents.children(s.agents, parent, [name | starting ++ waiting])
  end

  # A start idempotent per branch (`Delegates.Turn.again/3`): `{:go, false}` for a new start,
  # `{:go, true}` to start a name whose row has no report and whose process is gone, the
  # running delegate's answer, or a refusal.
  defp again(s, old, parent) do
    agent = old && agent(s, old)

    case Turn.again(old, agent, parent) do
      :new -> {:go, false}
      :again -> {:go, true}
      :already -> {:ok, Map.put(started(old, agent), :already, true)}
      refused -> refused
    end
  end

  # The start's answer, from its row and its agent row.
  defp started(row, agent) do
    answer = Map.take(row, [:id, :name, :brief_uuid])
    Map.merge(answer, %{session_id: agent && agent.session_id, account: agent && agent.account})
  end

  # A start of a name again: the old start's brief and word to go on never go in, so the new
  # process takes only its own. One in flight to the gone process settles first, from the
  # exit's evidence, and the start is refused until then.
  defp replaced(s, old) do
    Enum.reduce_while([old.brief_uuid, old.resume_uuid], :ok, fn
      nil, :ok ->
        {:cont, :ok}

      uuid, :ok ->
        case Mailbox.settle_row(s.mailbox, uuid) do
          {:ok, _} -> {:cont, :ok}
          {:refused, :no_message} -> {:cont, :ok}
          {:refused, {:not_queued, _sending}} -> {:halt, {:refused, {:in_flight, old.name}}}
          other -> {:halt, other}
        end
    end)
  end

  # Called: Sessions writes its own row first and runs on through a restart of this process.
  # A start names the parent and the options; a resume takes the agent row's. It carries the
  # row `launch_first/3` marked: an interactive one as its prompt, a headless one as the line
  # it writes right after the hold (F-152). `Mailbox` is told the answer.
  defp call_sessions(s, row, p, account, start, from, {how, launched}) do
    launch = launch(s, row, p, how)

    launch =
      case how do
        _ when launched == nil -> launch
        :interactive -> launch ++ [prompt: launched.text]
        :headless -> launch ++ [first: Map.take(launched, [:uuid, :text])]
      end

    mailbox = s.mailbox

    # Sessions takes the call only by the row's deadline less the slack (F-166): one taken in
    # time has written its agent row long before the row's deadline, at which Settled reads no
    # such row as a call that never reached Sessions; one taken later makes nothing.
    opts = [timeout: @call, caller_deadline: row.deadline - @slack]

    # The config is made in the task: the embedding app's `issue` may call a part that waits.
    task =
      Task.async(fn ->
        answer =
          with {:ok, mcp} <- s.mcp.(row.name) do
            launch = if mcp, do: launch ++ [mcp: mcp], else: launch

            case start do
              # A resume on another account than its agent row's copies the conversation first.
              {:resume, session_id, copy} ->
                with :ok <- copy.(),
                     do: Sessions.resume(s.sessions, row.name, account, session_id, launch, opts)

              # A start that names no metadata keeps the row's (`Sessions.start/5`).
              {parent, options, meta} ->
                launch = launch ++ [parent: parent, options: options]
                launch = if meta, do: launch ++ [meta: meta], else: launch
                Sessions.start(s.sessions, row.name, account, launch, opts)
            end
          end

        if launched, do: Mailbox.launched(mailbox, launched.id, answer)
        answer
      end)

    parent = with {parent, _} when is_binary(parent) <- start, do: parent, else: (_ -> nil)
    put_in(s.pending[task.ref], %{id: row.id, from: from, parent: parent, name: row.name})
  end

  # An interactive delegate runs Claude Code's terminal interface, as a main session does: role
  # `:parent`, kind `:delegate`. The row's effort goes in at every launch, a resume's too, and
  # none is no flag.
  defp launch(s, row, p, how) do
    role = if how == :interactive, do: :parent, else: :delegate
    tree = %{project: p, branch: row.branch}
    effort = if row[:effort], do: [effort: row.effort], else: []
    [role: role, kind: :delegate, worktree: tree, model: row.model] ++ effort ++ s.launch
  end

  defp how(agent), do: if(agent && not Agents.headless?(agent), do: :interactive, else: :headless)

  # An interactive start needs the turn's reader. A brief of any length goes: one longer than
  # the launch's argument carries goes as a pointer to its file (F-155).
  defp interactive_ok(_s, :headless), do: :ok
  defp interactive_ok(%{registry: nil}, :interactive), do: {:refused, :no_registry}
  defp interactive_ok(_s, :interactive), do: :ok

  defp stored({:ok, _} = ok), do: ok
  defp stored(other), do: {:brief, other}

  # The first row due to the delegate, marked for the start the caller makes next, by the
  # row's deadline: by launch for an interactive one, and by stream for a headless one, which
  # writes its system/init only after it read a line (F-152; Delivery.tla's stream row for a
  # start). An interactive start may go with no row; a headless one would never be confirmed.
  defp launch_first(s, row, how) do
    via = if how == :interactive, do: :launch, else: :stream

    case Mailbox.launch(s.mailbox, row.name, row.deadline, via: via) do
      {:ok, %{id: _, text: _} = launched} -> {:ok, {how, launched}}
      {:ok, :none} when how == :interactive -> {:ok, {how, nil}}
      other -> {:launch, other}
    end
  end

  # CallAnswered and Settled: a start or resume runs, and Mailbox delivers its turn's message; a
  # refused start is refused, and the rows to it end; a refused resume is the report. An
  # unknown answer leaves the row as it is, for Settled to decide.
  defp answered(s, row, {:ok, %{session_id: sid}}) do
    write(s, row, status: "running", reason: nil)
    {{:ok, %{started(row, agent(s, row)) | session_id: sid}}, s}
  end

  defp answered(s, %{status: "starting"} = row, {:refused, why} = refused) do
    write(s, row, status: "refused", reason: why)
    Mailbox.ended(s.mailbox, row.name)
    {refused, settle_row(s, Table.get(s.db, row.id), agent(s, row))}
  end

  # The word's resume after a usage limit, refused: no report, and the row runs on, still at
  # its limit (`Delegates.Turn.next/2`), for the limit's healer to ask a person.
  defp answered(s, %{status: "going_on"} = row, {:refused, why} = refused) do
    write(s, row, status: "running", reason: why)
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

  # Each name's latest row that may still move, with no call under way, read again; then the
  # running ones idle with no report.
  defp settle(s) do
    s = waits(s)
    s = Enum.reduce(movable(s), s, &settle_row(&2, &1, agent(&2, &1)))
    s = idle(s, Enum.filter(movable(s), &(&1.status == "running")))
    tell_starts(s)
  end

  # Limit.tla's StartAtReset (F-196): a waiting start, at its deadline (the reset plus the
  # margin), whether a person answered `wait` or not, picks its account again (Pick) and asks
  # for its lease under the row's own request id. A newer limit makes it wait for that reset.
  # A pick refused otherwise refuses the row; one that read no reading decides nothing.
  defp waits(s) do
    now = s.clock.()

    Table.with_status(s.db, s.host, ["waiting"])
    |> Enum.filter(&(&1.deadline <= now))
    |> Enum.reduce(s, &repick(&2, &1))
  end

  defp repick(s, row) do
    start = request(row)

    with {:ok, p} <- Map.fetch(s.projects, start.project) |> known(start.project),
         {:ok, account} <- pick(s) do
      # The call's time as `Table.starting/2` stamps it, which the agent row's start is read by.
      now = System.os_time(:millisecond)
      write(s, row, status: "starting", called_at: now, deadline: deadline(s, p))
      start = Map.merge(start, %{p: p, account: account})
      {:noreply, s} = began(leased(s, Table.get(s.db, row.id), start, nil, false), nil)
      s
    else
      {:refused, {:allowance, until}} ->
        write(s, row, until: until, deadline: until + s.margin, waited: nil)
        wake(s, Table.get(s.db, row.id))
        s

      {:refused, {:usage, :unread}} ->
        s

      {:refused, why} ->
        write(s, row, status: "refused", reason: why)
        s

      {:unknown, _} ->
        s
    end
  end

  defp wait_answer(_s, %{waited: by}, _choice, _who) when is_binary(by), do: {:refused, :settled}

  defp wait_answer(s, row, "wait", who) do
    write(s, row, waited: who)
    {:ok, :waiting}
  end

  defp wait_answer(s, row, "leave", who) do
    write(s, row, status: "refused", reason: "left", waited: who)
    tell_starts(s)
    {:ok, :left}
  end

  defp wait_answer(_s, _row, _choice, _who), do: {:refused, {:bad, :choice}}

  defp request(row), do: Table.request(row)

  # Delegate.tla's StartTold and StartCleared (F-170): a start that answered queued at once,
  # once its row has left starting with no call under way, is told to the parent its row names,
  # by a notice under the row's key, which Mailbox takes once; the row's mark is cleared after,
  # so a restart between the two tells nothing twice. A notice not taken stays owed for the
  # next settle.
  defp tell_starts(s) do
    busy = MapSet.new(Map.values(s.pending), & &1.id)

    for row <- Table.owed(s.db, s.host),
        row.status not in ["waiting" | Table.calling()],
        not MapSet.member?(busy, row.id),
        match?({:ok, _}, tell_start(s, row)),
        do: write(s, row, tell: nil)

    s
  end

  defp tell_start(s, row) do
    key = "start:#{s.host}:#{row.id}:#{row.created_at}"
    Mailbox.notify(s.mailbox, row.tell, start_text(row), key: key, kind: :notice)
  end

  defp start_text(%{status: "refused"} = row) do
    "Your delegate #{row.name}, #{queued(row)}, did not start: " <> refusal(row.reason) <> "."
  end

  defp start_text(row),
    do: "Your delegate #{row.name}, #{queued(row)}, has started. Its report comes as a message."

  # A row that waited at a usage limit keeps the reset it waited for (F-196).
  defp queued(%{until: until}) when is_integer(until),
    do: "which waited for a usage limit's reset at #{iso(until)}"

  defp queued(_row), do: "queued for a seat"

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  # The reason as `Store.text/1` kept it; a lease's refusal names its retry time.
  defp refusal(reason) when is_binary(reason) do
    case JSON.decode(reason) do
      {:ok, ["lease", [why, at]]} when is_integer(at) ->
        "the Scheduler refused its lease (#{why}); ask again after #{iso(at)}"

      {:ok, ["lease", why]} ->
        "the Scheduler refused its lease (#{JSON.encode!(why)})"

      _ ->
        reason
    end
  end

  defp refusal(nil), do: "no reason was kept"
  defp refusal(reason), do: to_string(reason)

  defp movable(s) do
    busy = MapSet.new(Map.values(s.pending), & &1.id)

    Table.latest(s.db, s.host)
    |> Enum.filter(&(&1.status in Table.open() or &1.status == "refused"))
    |> Enum.reject(&MapSet.member?(busy, &1.id))
  end

  # A delegate idle with no report (`Delegate.tla`'s BoundPasses and IdleTold): its row running
  # with no call under way, its turn ended by its kind's rule, and no row to it open in
  # `Mailbox`. Its idle state is the row with its fix state's offset, which any event of the
  # delegate moves, so a turn that starts ends the state. Past `idle_bound:`, from when this
  # process first read the state (a restart starts it again), the parent is told by a notice
  # stored under the state's key, which `Mailbox` takes once, so no restart tells it twice.
  # Nothing is done to the delegate. A read that fails decides nothing.
  defp idle(%{idle_bound: nil} = s, _rows), do: s

  defp idle(s, rows) do
    now = s.clock.()

    seen =
      Enum.reduce(rows, %{}, fn row, seen ->
        agent = agent(s, row)

        case idle_entry(s, row, agent, idle_state(s, row, agent), now) do
          nil -> seen
          entry -> Map.put(seen, row.id, entry)
        end
      end)

    %{s | idle: seen}
  end

  defp idle_entry(s, row, agent, {:idle, key}, now) do
    {since, told} =
      case s.idle[row.id] do
        %{key: ^key} = entry ->
          {entry.since, entry.told}

        _ ->
          # One wake at the bound, when the notice may go; not a poll.
          Process.send_after(self(), :deadline, s.idle_bound)
          {now, false}
      end

    told = told or (now - since >= s.idle_bound and tell_idle(s, row, agent, key, now - since))
    %{key: key, since: since, told: told}
  end

  defp idle_entry(s, row, _agent, :unread, _now), do: s.idle[row.id]
  defp idle_entry(_s, _row, _agent, :busy, _now), do: nil

  # `{:idle, key}`, `:busy`, or `:unread` when a read failed.
  defp idle_state(s, row, agent) do
    with false <- Agents.moving?(agent) and :busy,
         {:ok, fold} <- followed(s, agent),
         true <- ended_turn?(s, agent, fold) or :busy,
         {:ok, []} <- Mailbox.open_to(s.mailbox, row.name) do
      {:idle, fold.offset}
    else
      :busy -> :busy
      {:ok, [_ | _]} -> :busy
      _unread -> :unread
    end
  end

  # The turn has ended, by `Sessions.Turn`'s rule for its kind: a headless delegate's `Stream`
  # fold, an interactive one's session file (`turn_ended?/2`).
  defp ended_turn?(s, agent, fold) do
    if Agents.headless?(agent),
      do: SessionsTurn.headless(agent, fold) == :ended,
      else: turn_ended?(s, agent)
  end

  defp tell_idle(s, row, agent, key, ms) do
    text =
      "Delegate #{row.name} is idle with no report: its turn ended at least " <>
        "#{div(ms, 1000)} s ago and nothing is due to it."

    match?(
      {:ok, _},
      Mailbox.notify(s.mailbox, agent.parent, text, key: "idle:#{s.host}:#{row.id}:#{key}")
    )
  end

  # Settled: by the agent row of this call (written at or after the call) once that row is
  # settled; with none past the deadline, the call never reached Sessions and is not made again.
  defp settle_row(s, %{status: status} = row, agent)
       when status in ~w(starting resuming going_on) do
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
    s = own_turns(s, row, agent)

    cond do
      Agents.ended?(agent) or not Agents.free?(agent) or Agents.moving?(agent) -> s
      status == "failed" or delivered?(s, row) -> ended(s, row)
      true -> s
    end
  end

  # A start refused after its call reached Sessions, its process gone (its init never came, and
  # Sessions stopped it): no process of it runs again, as of a failed one, so its agent row is
  # ended once free, and it no longer holds its parent's end or cap (F-153's new-7, `Team.tla`'s
  # RefusedEnded). A row Sessions itself refused is ended already; one whose call never reached
  # Sessions has no agent row of its own.
  defp settle_row(s, %{status: "refused"} = row, agent) do
    own? = is_integer(row.called_at) and Agents.since?(agent, row.called_at)

    if own? and Agents.free?(agent) and not Agents.ended?(agent) and not Agents.moving?(agent),
      do: ended(s, row),
      else: s
  end

  # A move under way ends the process and resumes it on another account itself: its end is not
  # a kill, and nothing of the row moves until the move is done.
  defp settle_row(s, row, agent) do
    with false <- Agents.moving?(agent),
         :headless <- how(agent),
         {:ok, fold} <- followed(s, agent) do
      case Turn.next(row, fold) do
        {:finished, r} -> finish(s, row, "finished", {:reply, r.text, r}, "result")
        :exited -> exited(s, row, agent, fold)
        # Its turn is at a usage limit: no report and no resume here; the healer goes on.
        :limited -> s
        :waiting -> s
      end
    else
      :interactive -> settle_interactive(s, row, agent)
      _unread -> s
    end
  end

  # A turn of the delegate's own after its report (F-155, `Delegate.tla`'s TurnTold): a
  # background command of its own woke it, and the turn answers no message. Once its report is
  # taken, each such turn that has ended is told to its parent as a notice, under its result's
  # uuid, which Mailbox takes once, so no restart tells it twice; never as the report. A
  # headless one's turns are its `Stream` fold's `own`; an interactive one's are read from its
  # transcript after the report's turn, the last only once its session reads the turn ended or
  # its process is gone. A turn with no reply text tells nothing. A read that fails decides
  # nothing.
  defp own_turns(s, %{status: "finished", report: "taken"} = row, agent) do
    if Agents.ended?(agent), do: s, else: tell_turns(s, row, agent, ended_own(s, row, agent))
  end

  defp own_turns(s, _row, _agent), do: s

  defp ended_own(s, row, agent) do
    case how(agent) do
      :headless ->
        case followed(s, agent) do
          {:ok, fold} -> {Map.get(fold, :own, []), s}
          _unread -> {[], s}
        end

      :interactive ->
        uuid = row.resume_uuid || row.brief_uuid
        {turn, s} = turn_of(s, agent, uuid)

        with {:ok, {:ok, %{}}} <- turn,
             {:ok, bytes} <- report_turn(s, agent, uuid) do
          turns = Fold.own_turns(bytes, &Waiter.marked?/1)
          ended? = Agents.free?(agent) or turn_ended?(s, agent)
          {Enum.filter(turns, &(&1.closed or ended?)), s}
        else
          _unread -> {[], s}
        end
    end
  end

  # The transcript from the report's turn's marked line, which `turn_of/3` found.
  defp report_turn(s, agent, uuid) do
    with at when is_integer(at) <- Map.get(s.marks, {agent.session_id, uuid}),
         {:ok, %{bytes: bytes}} <-
           Transcripts.text(s.transcripts, agent.account, agent.session_id, at, timeout: @step),
         do: {:ok, bytes}
  end

  # The state is the read's own, which a transcript read may have changed (its marks, F-222).
  defp tell_turns(_before, row, agent, {turns, s}) do
    told =
      Enum.reduce(turns, Map.get(s.turns, row.id, MapSet.new()), fn t, told ->
        if t.text == "" or MapSet.member?(told, t.uuid) or not tell_turn(s, row, agent, t),
          do: told,
          else: MapSet.put(told, t.uuid)
      end)

    put_in(s.turns[row.id], told)
  end

  defp tell_turn(s, row, agent, %{uuid: uuid, text: text}) do
    text = "Delegate #{row.name}, in a turn of its own after its report:\n\n" <> text
    key = "turn:#{s.host}:#{uuid}"
    match?({:ok, _}, Mailbox.notify(s.mailbox, agent.parent, text, key: key, kind: :notice))
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
         {:ok, turn} <- turn,
         # A turn that ended at a usage limit (F-187's new-2): neither a finish nor a kill. Its
         # reply is the limit's line, and its process may be gone at the limit; the healer's
         # word goes on with the turn (`go_on/5`), whose reply is the report.
         false <- acts?(agent, turn) and interactive_limit(s, agent) != :none do
      reply = with {:ok, %{reply: text}} when is_binary(text) <- turn, do: text, else: (_ -> nil)

      cond do
        reply && Agents.free?(agent) ->
          finish(s, row, "finished", {:reply, reply, %{}}, "transcript")

        Agents.free?(agent) and kill_seen(s, row) != :ok ->
          s

        Agents.free?(agent) and row.resumes > 0 ->
          finish(s, row, "failed", {:notice, @twice})

        Agents.free?(agent) ->
          resume(s, row, agent, brief != :absent)

        reply && (match?({:ok, %{closed: true}}, turn) or turn_ended?(s, agent)) ->
          finish(s, row, "finished", {:reply, reply, %{}}, "turn_end")

        true ->
          s
      end
    else
      _unread -> s
    end
  end

  # Whether settle_interactive would act on the turn now: its process gone, or a reply.
  defp acts?(agent, turn),
    do: Agents.free?(agent) or match?({:ok, %{reply: text}} when is_binary(text), turn)

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
  # read that fails decides nothing, and so does a kill not yet recorded (`kill_seen/2`).
  defp exited(s, row, agent, fold) do
    t = s.transcripts
    session = {agent.account, agent.session_id, fold.transcript}
    decides? = row.resumes > 0 or Agents.free?(agent)

    with {:ok, %{failed: []}} <- Transcripts.read(t, [session], timeout: @step),
         {:ok, tr} <- Transcripts.session(t, agent.account, agent.session_id, timeout: @step) do
      cond do
        tr.ends_with_reply ->
          finish(s, row, "finished", {:reply, tr.last_reply.text, %{}}, "transcript")

        decides? and kill_seen(s, row) != :ok ->
          s

        row.resumes > 0 ->
          finish(s, row, "failed", {:notice, @twice})

        Agents.free?(agent) ->
          resume(s, row, agent, went_in?(row, fold))

        true ->
          s
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
         {:ok, account, moved} <- resume_account(s, agent.account),
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
      start = {:resume, agent.session_id, copy(s, agent, account.name, moved)}
      s = call_sessions(s, Table.get(s.db, row.id), p, account, start, nil, launched)
      if act, do: put_in(s.pending, Map.new(s.pending, &with_act(&1, row.id, act))), else: s
    else
      {:refused, _} = refused -> elem(answered(s, row, refused), 1)
      _not_taken -> s
    end
  end

  # Whether the delegate's turn is at a usage limit, and its process lives: a headless one's by
  # its stream (`Delegates.Turn.next/2`'s `:limited`), an interactive one's by its transcript,
  # whose last limit line no turn followed (F-187's new-2).
  defp limited_turn(s, row, agent) do
    case how(agent) do
      :headless ->
        with {:ok, fold} <- followed(s, agent) do
          case Turn.next(row, fold) do
            :limited -> {:ok, not fold.gone}
            other -> {:refused, {:not_limited, other}}
          end
        end

      :interactive ->
        case interactive_limit(s, agent) do
          :limited -> {:ok, Agents.running?(agent)}
          other -> {:refused, {:not_limited, other}}
        end
    end
  end

  # An interactive delegate's transcript, read now: `:limited` while its last limit line is the
  # last turn's end (no turn followed it), `:none` otherwise; a read that fails, `:unread`.
  defp interactive_limit(s, %{session_id: sid} = agent) when is_binary(sid) do
    t = s.transcripts

    with {:ok, dir} <- Accounts.config_dir(s.accounts, agent.account),
         {:ok, path} <- Transcripts.path(dir, agent.cwd, sid),
         {:ok, %{failed: []}} <- Transcripts.read(t, [{agent.account, sid, path}], timeout: @step),
         {:ok, tr} <- Transcripts.session(t, agent.account, sid, timeout: @step) do
      if match?(%{followed: false}, tr[:limit]), do: :limited, else: :none
    else
      _ -> :unread
    end
  end

  defp interactive_limit(_s, _agent), do: :unread

  # The word to go on after a usage limit, as the resume's first line (F-152), or an
  # interactive one's prompt by launch (F-191), under the start's lease (no claim of its own:
  # the limit's healer claimed the act). It is not the resume after a kill, so `resumes` stays
  # as it was. The caller waits for Sessions' answer.
  defp went_on(s, row, agent, from) do
    with {:ok, p} <- Map.fetch(s.projects, agent.project) |> known(agent.project),
         deadline = deadline(s, p),
         {:ok, account, moved} <- resume_account(s, agent.account),
         {:ok, launched} <- launch_first(s, %{row | deadline: deadline}, how(agent)) do
      at = System.os_time(:millisecond)
      write(s, row, status: "going_on", called_at: at, deadline: deadline)
      start = {:resume, agent.session_id, copy(s, agent, account.name, moved)}
      {:noreply, call_sessions(s, Table.get(s.db, row.id), p, account, start, from, launched)}
    else
      {:refused, _} = refused -> {:reply, refused, s}
      {:unknown, _} = unknown -> {:reply, unknown, s}
      not_launched -> {:reply, {:refused, not_launched}, s}
    end
  end

  # F-209 (F-207's new-2; `Move.tla`'s ResumeHere, CopyAsked and NoResumeOnRefused): a resume
  # runs on its agent row's account, where its conversation is, while `usable:` takes that
  # account. Refused there (the app flags it, or its login is gone), it runs on the account the
  # pick finds among the others, its conversation copied there first, as a main session's resume
  # does (F-177); with none usable it is refused with its own account's reason, and never runs
  # on a refused account. A check that could not tell decides nothing: the next cue asks again.
  # The windows are not read here: a resumed turn at a limit is the limit's (`Limit.tla`).
  defp resume_account(s, own) do
    case s.usable.(own) do
      {:ok, account} ->
        {:ok, account, nil}

      {:refused, why} ->
        case pick(s, s.accounts.names -- [own]) do
          {:ok, account} -> {:ok, account, %{from: own, why: why}}
          {:refused, {:usage, :unread}} -> {:unknown, {:usage, :unread}}
          {:refused, {:allowance, _}} = limited -> limited
          {:refused, _none_usable} -> {:refused, why}
          unknown -> unknown
        end

      {:unknown, why} ->
        {:unknown, {:account, own, why}}
    end
  end

  # The conversation, from the agent row's account to the one the resume runs on, as the
  # `Mover` copies a move's and `Mains` a resume's (`Transcripts.Copy`, `Move.tla`'s
  # ResumeCopy): its process is gone, so the transcript is final. Run in the resume's task, an
  # act `copy` in `Acts` (with `acts:`); refused, the resume is refused `{:copy, reason}`, as any
  # refused resume, and `Sessions` is not called.
  defp copy(_s, _agent, _to, nil), do: fn -> :ok end

  defp copy(s, agent, to, %{from: from, why: why}) do
    {accounts, acts, actor} = {s.accounts, s.acts, actor(s)}
    detail = %{from: from, to: to, session_id: agent.session_id, because: why}

    fn ->
      copied =
        with {:ok, source} <- Accounts.config_dir(accounts, from),
             {:ok, target} <- Accounts.config_dir(accounts, to),
             do: Transcripts.Copy.copy(source, target, agent.cwd, agent.session_id)

      case copied do
        :ok ->
          if acts,
            do: Acts.record(acts, actor, "agent:" <> agent.name, :copy, :verified, detail: detail)

          :ok

        {:refused, reason} ->
          fields = [detail: detail, reason: reason]
          if acts, do: Acts.record(acts, actor, "agent:" <> agent.name, :copy, :failed, fields)
          {:refused, {:copy, reason}}
      end
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

  # The report's text is kept until Mailbox takes it, with how it was taken (`taken_by`, F-202):
  # `result`, `transcript` or `turn_end`; nil for a failure's notice.
  defp finish(s, row, status, answer, taken_by \\ nil) do
    write(s, row, status: status, report: "held", text: elem(answer, 1), taken_by: taken_by)
    hand(s, Table.get(s.db, row.id), answer)
  end

  # KillSeen as a fact (F-202, from F-199's new-6): the kill is one row in `Acts`, act `killed`,
  # actor `delegates:<host>`, keyed by the delegate's row and its resumes, recorded before the
  # row decides between a resume and a failure. So a kill whose resume is refused before its
  # claim is still counted, and a second kill is a row of its own. `:ok` once it is recorded,
  # now or before; anything else decides nothing now, and the next cue reads the kill again.
  defp kill_seen(%{acts: nil}, _row), do: :ok

  defp kill_seen(s, row) do
    key = "killed:#{s.host}:#{row.id}:#{row.resumes}"
    detail = [detail: %{delegate: row.id, resumes: row.resumes}]

    case Acts.record(s.acts, actor(s), row.name, :killed, :verified, detail, state: key) do
      {:ok, _} -> :ok
      {:refused, {:already_claimed, _}} -> :ok
      other -> other
    end
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

    mine? = own? or (row != nil and pending_parent(s, row) == parent)

    cond do
      row == nil ->
        {:refused, {:no_delegate, name}}

      row.status == "starting" and mine? ->
        {:starting, row}

      row.status == "refused" and mine? ->
        {:refused, {:not_started, row.status}}

      # A start that waits at a usage limit has nothing to fix yet (F-196).
      row.status == "waiting" and row.tell == parent ->
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

  # The resume path a cue takes once the process is gone and the agent row is free (fix_check/2,
  # on the state read in this step). A wedged delegate, alive but stuck, is not stopped first:
  # F-100's build note, new-1.
  defp act(s, row, agent, fold, :resume, _from),
    do: resumed(exited(s, row, agent, fold), row.id)

  # The operator's forced stop (F-170): the report delivered as for any stop, and no wait for
  # the rows to it; its caller settles each one left sending (`Mailbox.ended_while_sending/3`).
  defp act(s, row, agent, fold, {:stop, :force}, from),
    do: act(s, row, agent, fold, :stop, from, true)

  defp act(s, row, agent, fold, :stop, from), do: act(s, row, agent, fold, :stop, from, false)

  # The report delivered and nothing open to it, by Mailbox; Sessions waits for the exit, and
  # this process does not wait with it. An ended delegate has nothing left to stop.

  defp act(s, row, agent, _fold, :stop, from, force) do
    with true <- not Agents.ended?(agent) or {:refused, {:status, "ended"}},
         {:ok, %{status: "delivered"}} <- report(s, row),
         {:ok, []} <-
           if(force, do: {:ok, []}, else: Mailbox.open_to(s.mailbox, row.name)) |> open() do
      me = self()

      Task.start(fn ->
        reply = Sessions.stop(s.sessions, row.name, timeout: @call, force: force)
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

  # A row still starting: nothing of its process is read yet, and only its row moves it.
  defp starting(row) do
    state = Map.take(row, [:id, :status, :resumes, :report])
    Map.merge(state, %{offset: nil, gone: false, ending: false, held: [], ended: false})
  end

  defp moved(now, s), do: {:reply, {:refused, {:moved, now}}, s}

  # A start stuck before its confirm (a headless process whose init never came, F-152): its
  # held program ends by SIGTERM to its record, through `Sessions.stop/3`, and the start's own
  # answer, or the settle of its agent row, makes the row refused. This process does not wait.
  defp stop_starting(s, row, from) do
    Task.start(fn ->
      GenServer.reply(from, Sessions.stop(s.sessions, row.name, timeout: @call))
    end)

    {:noreply, s}
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

  defp pick(s, among \\ nil) do
    with {:ok, %{readings: readings}} <- Usage.readings(s.usage, timeout: @step),
         # F-181: among the usable accounts (prepared, logged in), the one with the most room.
         {:ok, name} <-
           Usage.pick(readings, among || s.accounts.names, div(s.clock.(), 1000),
             usable: s.usable
           ) do
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
