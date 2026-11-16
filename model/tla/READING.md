# Reading the specs

The specs in this directory are TLA+. This page is enough to read them if you know Elixir.

## What a spec is

A spec describes a system as a **state** and the **steps** that change it. TLC, the model
checker, starts from every initial state and tries every step in every order, up to the bounds a
configuration sets, and checks that nothing it lists goes wrong in any state it reaches.

- `VARIABLES` are the state: like the fields of a GenServer's state, but for the whole system
  (the tmux server, the sockets, the processes), not one process.
- `Init` says what the variables hold at the start.
- An **action** is one step, named after the event: `ServerDies`, `RecoveryActs`. It is a
  formula over the variables now (`panes`) and after the step (`panes'`, read "panes prime"). It
  is like a `handle_info` clause whose guard is its first lines and whose result is the primed
  variables. A step that lists a variable as `UNCHANGED` leaves it as it was.
- `Next` is every action joined with `\/` (or): any enabled step may come next.
- `Spec` is `Init`, then any number of `Next` steps, plus **fairness**: the steps the framework
  itself takes (sampling, claiming, reopening) eventually happen when they stay
  possible. Events from outside (a server dying, a process exiting) may or may not happen.

## Notation

| TLA+ | Elixir, roughly |
|---|---|
| `/\`, `\/`, `~` | `and`, `or`, `not` (a list of `/\` lines is all of them) |
| `x = y`, `x # y` | `x == y`, `x != y` |
| `\A a \in S : P` | `Enum.all?(s, fn a -> p end)` |
| `\E a \in S : P` | `Enum.any?(s, fn a -> p end)`; in an action, "for some `a`, this step" |
| `{a \in S : P}` | `for a <- s, p, into: MapSet.new()` |
| `{f(a) : a \in S}` | `MapSet.new(s, &f/1)` |
| `S \cup T`, `S \ T` | `MapSet.union/2`, `MapSet.difference/2` |
| `[a \in S \|-> e]` | `Map.new(s, fn a -> {a, e} end)`: a function is a map with a fixed key set |
| `f[a]`, `DOMAIN f` | `f[a]`, `Map.keys(f)` |
| `[f EXCEPT ![a] = e]` | `%{f \| a => e}` |
| `[pid \|-> 1, socket \|-> a1]` | `%{pid: 1, socket: :a1}` |
| `r.pid` | `r.pid` |
| `LET x == e IN body` | `x = e` then `body` |
| `IF c THEN a ELSE b` | `if c, do: a, else: b` |
| `CHOOSE x \in S : P` | some fixed `x` in `s` with `p`, the same one every time |
| `x == e` | a definition, like a `defp` |

## Properties

- An **invariant** must be true in every reachable state: `OneProcessPerSocket`.
- `[][A]_vars` says every step satisfies `A`: `AgentOutlivesServer` says the step in which
  the server dies ends no process.
- `P ~> Q`, "P leads to Q": whenever `P` holds, `Q` holds then or later. `LostViewerReopened`
  says a held agent with no viewer later has one, or has ended, or waits for a person.

## Configurations and `Break`

A `.cfg` file gives the constants (`Agents = {a1, a2}`, the `Max*` bounds) and the invariants
and properties to check. `Agent_*.cfg` checks the design. `Break_Agent_<Bug>.cfg` sets the
`Break` constant, which turns off one guard in the spec, and must make TLC report a violation:
it shows the check would catch that bug. When TLC finds one, its output in
`_build/tlc/<name>.out` lists the states, step by step, that lead to it.

Run them with `devenv shell -- bin/check-model` (see its header).

## `Agent.tla`

One host's tmux server, its held agents and their viewers, and the writes to a pane. Read the
recovery of a lost viewer in the order it happens:

- `AgentStarted` holds an agent under dtach, and the start opens its viewer in the same step,
  or, up to `MaxLateViewers` times, later in `StartOpensViewer`.
- `ViewerDies` and `ServerDies` lose a viewer. `Reading` is one sample: the panes, then the
  sockets. `SamplerReads` is a reading with nothing between its two reads;
  `SamplerReadsAround(a)` has a start's viewer of `a` open between them, so the reading is wrong
  for `a`. A reading names a new loss (`new`): an agent not read in the last reading, or one
  `Recoveries` opened a viewer for since. `agreed` holds the losses the last two readings both
  read; `fresh` says `Recoveries` restarted since the last reading and holds none.
- `RecoveryClaims(a)` writes the claim, only on an agreed loss not claimed yet. The third loss
  since a person cleared the agent (`losses`) goes into `repeating` with no act, until
  `PersonClears(a)`.
- `RecoveryActs(c)` opens the viewer, and starts the server when it is down. An act on an agent
  that has a viewer already is refused by tmux, and still counts as an open (`opened`).
- `RecoveriesRestart` drops what `Recoveries` holds in memory (`acting`, `agreed`); its table
  (`claimed`) stays. `cutOff` is a history variable that takes the agents in `claimed` at that
  restart.

`OneReopenPerLoss` says one loss gets at most one reopen. `NoActOnCutOffClaim` is a step property,
like `AgentOutlivesServer`: no `RecoveryActs` step acts on an agent in `cutOff`, the agents whose
claim a restart of `Recoveries` cut off, so that loss is not acted on again. A reading that names
a new loss takes the agent out of `cutOff`, since a claim of that loss is a new claim.
`Agent_Claims` checks it, and `Break_Agent_ClaimTwice` drops `a \notin claimed` from
`RecoveryClaims` and must fail it. `OneReopenPerLoss` does not catch that break: the cut-off claim
was never acted on, so the act of the second claim is the loss's only reopen. `a \notin opened` in
`RecoveryClaims` is defense in depth behind `a \notin claimed`, so it has no `Break` value.
`NoActOnOneWrongReading` says no claim
rests on a single reading that was wrong (`wrongOnce`). `Agent_Viewers` checks the liveness
with two agents; `Agent_LateViewers` with one agent, a late viewer and three losses;
`Agent_Claims` the claims across two restarts of `Recoveries`; `Agent_Writes` the writes. The
slow ones, run by hand, take three starts: `slow/Agent_RestartsWrites` checks the safety over two
server restarts with one write, `slow/Agent_RestartsLiveness` the liveness there with no writes,
and `slow/Agent_WritesLarge` two writes over one restart.

## `Move.tla`

A parent session moves from account `Home` to the other one. Read it in the order of a move:

- `Drain` (a press, or `UsageRises` to 90 %) sets `phase` to `"draining"`. From then on
  `BgStarted` and `DelegateStarted` are refused (`Draining`).
- `Cleared` is the Mover reading that no background command runs. It is a reading, not a lock:
  only the drain keeps it true until the end.
- `EndAsked` ends the process once its turn has ended; `ProcessExits` is the process going, with
  whatever still runs in it, which goes into `lost`. It sends a `SessionEnd`, held in `ends`
  until `SessionEndArrives` handles it, at any later time.
- `Copied` then `Resumed` start a new process on `target` from the copied transcript.
- Delegates outlive the parent's process: `ReportDelivered` waits for a live one.

`procs` holds the session's processes as `[pid, account, ending]`; `turn` is the pid whose turn
runs, or `0`. `NoStartWhileDraining` is a step property, like `AgentOutlivesServer`: no step taken
while the move runs starts anything. `DelegatesStarted'` is that count after the step.

## `Delegate.tla`

A parent, its delegates, and restarts of the framework. Read it in the order of a report's path:

- `StartAsked` is `start_delegate` in a parent's turn: refused by a check, or by the cap
  (`Counted`, which takes starting rows too), or its row written as `"starting"` with the call
  of `Sessions` under way (`call`, in memory). `Called` is `Sessions` taking the call and
  writing its own row (`sess`); `SessionsDecides` holds the process, which waits for its
  message (`"waiting"`), or refuses. `CallAnswered` moves the row by the answer; after a
  restart, `Settled` moves it by `sess` once `Sessions` has decided, and refuses it when the
  call never reached `Sessions`.
- `InputWritten` is the turn's message through `Stream`, under the uuid the row holds:
  `marked` is `Stream`'s table, which refuses the uuid again. `pipe` holds the lines the
  current process has not taken; `InputTaken` starts its turn.
- `DelegateFinishes` ends the delegate's turn with its last reply (`reply`) and fires its Stop
  hook, which lands in `stops` only while the framework runs. `StopHandled` turns it into a held
  report; when a restart lost it, `TranscriptRead` reads the last reply instead.
- `DelegateKilled` then `KillSeen`: the first kill is resumed, counted in the row first as
  `"resuming"`, with a call of `Sessions` like a start's; the second is the report.
- `DeliveryAsked` marks the row `"sending"` once the parent's turn has ended. `DeliveryTyped`
  is `Control`'s checked write, or `DeliveryRefused` holds the report again. `DeliveryMarked`
  writes `"delivered"`. A restart in between leaves `"sending"` with nothing in memory, and
  `SendingResolved` reads the parent's transcript (`got`) to settle it.
- Or a `run_delegate` call takes the report (for a delegate in `Awaited`). `CallWaits` is the
  call, in a parent's turn; `Taken` takes a held report before the call's `Deadline`, marks it
  `"answering"` and adds it to `watched`. `Written` is the endpoint's write, with three
  outcomes: the agent has it (`heard`), it failed (a reset connection), or it succeeded to a
  client that had gone (`lost`). `Told` is `answered/2` or `release/2`; `TellLost` is the
  caller that cannot reach `Delegates`. `CallerEnds` may come at any step, and `CallerSeen`
  holds an `"answering"` report again once its caller has ended. `FrameworkStarts` holds every
  `"answering"` report again; `unsure` records that a report was held again while its answer
  may have reached the agent.
- `DelegateEnds` waits for `"delivered"` or `"answered"`.

`ReportArrives` allows one exception, `lost`: the write succeeds to a client that is gone, and
no one reads it. A client goes that way when the parent's process ends, or, under
`ClientLeaves`, by its own limit. `Delegate_Cap.cfg` sets `ClientLeaves` false (the cap keeps
`run_delegate`'s timeout under the client's limits) and stops no parent, and checks
`ReportArrivesUnderCap`, which has no exception.

`FrameworkDies` clears what the framework holds in memory (`stops`, `sending`, `call`,
`watched`, and a call still waiting); the
tables (`status`, `report`, `resumes`, `marked`) stay, and so does `Sessions`' row (`sess`),
since `Sessions` runs on. `got` counts the report in the parent's transcript, `wrong` records a
report typed where the check must refuse it, and `taken` and `resumed` count the messages the
delegate's processes took and the resumes `Sessions` made. `SF_vars`, strong fairness, says a
step that is possible again and again, not always, happens: the user's prompts may take the
parent's turn each time a report waits for it.

## `Start.tla`

One host's session starts and stops, with a restart of the framework possible between any two
steps. Read it in the order of a start:

- `RowWritten` writes the row as `"starting"` before anything acts; the call under way lives in
  `call`, in memory, and a restart clears it.
- `Held` is `dtach -n`: a process (`proc`, a pid with its own start time), or a refusal, or an
  unknown answer with nothing held. `ViewerOpened` then leaves the call waiting.
- `FileWritten` is Claude Code writing its session file, at any time, perhaps late. `Tick` is the
  start's deadline passing; it is wall-clock, so it survives a restart.
- `StartDecided` is the call's own answer: running when the file names the live process,
  unknown once the deadline has passed.
- After a restart, `Adopt` takes a `"starting"` row with no call under way: running when the file
  names the live process and the socket is live (`Confirms`); past the deadline, `"orphan"` for
  a live socket, and for a dead one while the file names a live process (`Named`: its dtach was
  killed), with the file's pid and start time; `"refused"` for the rest. `ReRead` reads an
  `"unknown"` row again until it is running or gone, and makes the same orphan.
- `StopAsked`, `StopSettled`, `StopTimedOut` and `Kill` are a stop, judged by the row's pid and
  start time and by the socket: stopped only once both are gone. `StopTimedOut` leaves the row
  `"stopping"`, and marks it `late` when its process is alive; a late row is not set back to
  running after a restart, and only it may be killed (`Kill`, `Recoveries`' step).
  `ForeignStarts` is another program taking a freed pid, which is why the start time counts.
- `ProcExits` is a process ending by itself, at any step. Its socket ends apart (F-64):
  `DtachExits` is dtach ending once its process has, and `DtachKilled` is dtach killed hard,
  which leaves `sock` false while the process runs on. `RunningSettled` (F-61) takes a
  `"running"` row with no call under way to `"stopped"` (the row's reason is `exited`) once its
  process is gone by pid and start time and its socket is dead, so the name can be resumed.
  `RunningSettles` says it always does; under `SettleRunningByPid` a pid another program took
  keeps the row running. `SettleRunningBySocket` and `SettleRunningByLiveness` each drop one half
  of the check, and `NoHeldWithoutRow`, which now covers a live socket too, fails for each.
- Cues (F-64): `cued` is a cue `Sessions` has not handled. `ProcExits` and `Kill` cue for the
  Registry, `DtachExits` and `DtachKilled` for the sampler, and `FrameworkStarts` for every row.
  `RunningSettled` and `StopSettled` with no stop under way need one and handle it; `CueIdle`
  handles one they cannot act on, as a settle that met a live socket. A cue for a row that is
  neither running nor stopping, or that has a call under way, settles nothing and is dropped
  (`Cueable`). `RunningSettles` and `StoppingSettles` hold without fairness on a later cue of
  another kind; under `NoSocketCue` they fail.

With `Worktrees` (F-55), a start runs in a worktree, and three steps come between the row and
the hold:

- `RowWritten` first checks that no other row that has not ended holds the path (`HeldByOther`).
  A later start of a name may be a resume (`resume`).
- `Checked` is `git worktree list` and `git status`: a free path (`wt` is `"none"`) goes on to
  `Added`; a tree on the branch (`"tree"`) is reused when clean (`dirty` is false) or for a
  resume; anything else (`"other"`: a directory, or a worktree on another branch) is refused.
- `Added` is `git worktree add`, with `-b` when the branch does not exist. At a path taken since
  the check (`PathTaken`) it fails, and `branch` is true afterwards either way.
- `SetupStarts` and `SetupEnds` are the project's setup: `ready` is false from its start and
  true only when it finishes; a failed setup refuses the start and leaves the tree. `setupRuns`
  is the setup's processes, which a restart ends (the reaper), except under `SetupOutlives`.
- `Adopt`'s refused branch also removes the tree (`Remove`) when it is clean and no other row
  holds it. `TreeChanged` is anyone changing files in a tree. `Shared` puts every session on one
  path, to check the held path.

`onTime`, `ends`, `wrongKills`, `touched`, `offTree`, `removedDirty` and `reusedDirty` are ghosts:
they record what happened, for the invariants, and the framework never reads them.
`RunningOnlyIfLive` is a step property: the step that writes `"running"` writes it only for a
live process its file names. `cued` is memory, cleared by `FrameworkDies`.

## `Intake.tla`

Hook events into the framework, and a held `PermissionRequest`. It has two halves that share
only the restarts.

- Events: `Posted` is Claude Code's post, refused while the framework is down; posting one id
  twice is a duplicate. `Stored` writes the row (`rows`), then `Acked` answers 200. `AckedFirst`
  and `StoredLate` are the broken order, under `AckBeforeStore` only.
- Dialogs, numbered, open one at a time. `DialogOpens` shows the dialog and posts its hook
  (`hook` is `"waiting"`, and `conn` is the open request). `HoldStored` writes the row `"held"`.
  `AnswerAsked(m, h)` is an answer meant for dialog `m` taking hold `h`; the design needs
  `h = m`. `AnswerWritten` is the response on the request, which a waiting hook reads (`heard`).
  `AnswerMarked` writes `"answered"`. `HoldExpires` is the framework's own deadline.
- `PersonAnswers` closes a dialog and leaves its hook waiting. `HookTimesOut` is Claude Code's
  timeout; its guard says the framework's deadline comes first, so in the design it never
  happens while a hold is open.
- `FrameworkDies` cuts every open request, and `HoldSettled` then marks a `"held"` row `"lost"`
  and an `"answering"` one `"unknown"`.

## `Stream.tla`

A headless delegate's stdin and event log, with restarts of the framework between any two steps.
It has three actors: Claude Code, the claim commands on disk, and the framework.

- Claude Code reads `pipe`, its stdin, a line at a time. `TakeMsg` takes a whole message line,
  starts a turn (`turns` is what the transcript holds) and begins writing its replay; `tail` is
  the event it is writing, and `EventWritten` finishes the line in `log`. `TurnEnds` writes the
  `result`. `RequestOpens` asks a permission during a turn; `TakeAnswer` settles it and replays
  the answer, and `DropAnswer` drops an answer to a request no longer pending. `Malformed` is a
  cut line followed by another: the session ends. `Exit` ends it from outside, and a line it was
  writing stays cut at the log's end (`cutEnd`): the next event written joins it.
- A message's write: `Mark` writes the row `"writing"` once the turn has ended (`idle`, set by
  a handled `result`), every earlier message is delivered and no end is marked. `Claim` spools
  the line and starts its claim command (`spool` is `"claimed"`: the spool file is gone), which
  names the FIFO of the row's resume count (`cfifo`). `WriteBegins` and `WriteEnds` are the
  framework writing a line itself, under `WriteInFramework` only.
- Lines are `<<message, gen>>`. A claim command writes a message line in two parts
  (`CatBegins`, `CatEnds`); a line put between them mixes with it. It writes only while the
  process that reads its FIFO lives (`Reads`): process `n` reads `in.<n-1>`. One left waiting at
  an exit never reaches the next process, and `ClaimTimesOut`.
- `Read` handles the next whole event and saves `offset` in one step; the two Offset Breaks
  split it, with `ReadFinished` as the second half. `Handle` says what each event writes:
  a replay delivers its message, a `result` sets `idle`, a request is held, an answer's replay
  answers it, a cancel cancels it, a `"cut"` line writes nothing.
- `AnswerAsked(a, h)` is an answer meant for request `a` taking hold `h`; the design needs
  `h = a`. `AnswerClaimed` writes the answer's line, which fits the pipe's atomic size.
- `seen` says the framework knows the current process was started: `HeldTold` is Sessions
  telling Stream once it held the process (`telling` is Sessions' memory of that), `LiveSeen` a
  read finding the socket live, and `Mark` a write's check. `ExitSeen` is the framework finding
  the pid gone, once its own claims ended; it needs `seen`. With the log read to its end, a
  message still `"writing"` is settled by the transcript (`heard`, the uuids Claude Code took),
  and a held request is lost.
- A resume (F-51): `FollowAgain` clears `gone` and `seen`, sets `idle`, makes the next FIFO
  (`resumes`) and ends a cut last line with a newline, as one `"cut"` line in `log`; it keeps the
  offset, the messages and the requests. `ProcStarts` is Sessions starting the resumed process
  on the new FIFO and the same log. A message found undelivered is marked again first, as a new
  line `<<m, 2>>` under the same uuid (`gen`, `UuidOf`). `DropMsg` is Claude Code acknowledging
  a user line whose uuid `heard` holds: its replay, and no turn.
- The end: `EndMarked` once the report is delivered (`ReportDelivered`, the parent's part, which
  Sessions checks), the turn ended and no message is under way or found undelivered;
  `EndClaimed` writes it; `TakeEnd` ends the process.

`mine`, `begun`, `wmem`, `reading` and `telling` are memory, cleared by `FrameworkDies`; the
tables and the disk stay. `handled`, `written`, `awritten`, `partialRead`, `malformed`,
`intoRunning`, `wrong`, `endCut`, `endEarly`, `endLost` and `joined` are ghosts for the
invariants. `Unseen` names a process whose tell a restart cut and that exited before any read
saw it live: its exit is never seen (F-51, new-3).

## `Team.tla`

The tree of two projects. `Projects` gives each project's agents, as a set of sets
(`{{p, d1}, {q, e1}}`), and `Mains` its main sessions, one in each; every other agent is a
delegate. `Main(a)` is the main session of `a`'s project, so a delegate's parent. The tree's
edges are `Edge(c, t)`: a main session to its delegates and to the other main session, a
delegate to its main session. Its parts share the agents and the restarts.

- Agents: `proc` is each agent's state (`"working"`, `"idle"`, `"stuck"`, `"dead"`, `"ended"`),
  and `epoch` numbers it: it moves when the agent sticks, dies, is fixed or ends, so a claim
  names a state as `<<target, epoch>>`. `Faults` sticks or kills an agent; `DelegateEnds` is a
  delegate's own end once its report is delivered. A main session never ends.
- Messages, read in the order of one message: `Send` stores the row as `"queued"`, along an
  edge only. `DeliveryAsked` marks it `"sending"` once the target's turn has ended and every
  earlier message from the same sender to the same addressee is delivered. `DeliveryTyped` is
  `Control`'s checked write, which appends the id to the target's transcript (`inbox`), or
  `DeliveryRefused` queues it again. `DeliveryMarked` writes `"delivered"`; after a restart,
  `SendingSettled` reads the transcript instead, as `Delegate.tla` settles a report.
  `EndedFirst` marks a settled row whose addressee has ended `"ended"`: it is not delivered,
  and its sender reads that in place of `"delivered"`.
- Replies, read in the order of one message to a delegate: `DeliveryTyped` starts its turn,
  `fold[i] = "turn"`. `fold` is `Stream`'s fold of the delegate's log, so a restart keeps it.
  `Result(a)` ends the turn with a result that names the message (`TurnEnds`, or an interrupt
  that helps, whose result is `error_during_execution`), `fold[i] = "result"`; a `Faults` that
  kills the process mid-turn makes it `"exited"`. `ReplyStored(i)` is `Mailbox` storing the
  reply to the delegate's main session; `NoticeStored(i)` stores the framework's notice for an
  exited turn. Both need the row `"delivered"` and no answer yet for `i` in `answers`, the
  table's key on `reply_to`. `SelfStarts(d)`, only when `SelfTurns`, is a turn the delegate
  starts by itself: its result names no message (`OwnTurn`), so it changes no `fold` entry.
- Claims: `ClaimTaken(c, t)` is `Grants`: `MayFix(c, t)`, the caller is the target's main
  session, and no claim yet on the target's state. It writes the row (`claims`) and starts the
  call (`calls`, in memory). A row's `n` is 2 for the caller's second call on the same state,
  which a subagent can make at once; only `Break = "TwoClaims"` lets one in. `FixActs` acts
  only while the claimed state is current, and may not help; `FixRefused` ends the call when it
  is not. A call cut off by a restart is closed by `ClaimSettled` and never sent again. A row in
  `done` still holds its state, so a fix that did not help leaves the state claimed.
- Services: `ServiceStarts` with or without `keep`; `ServiceFixed(c, s)`, a restart or a stop,
  by the owner or the owner's parent; `ServiceHanded(c, s, b)`, by the owner `c` to its parent
  or a child `b`; and `ServiceOwnerEnded`: a kept service goes to the owner's parent, any other
  ends.

`fixed` and `wrong` are ghosts. `MayFix`, `MayFixService` and `MayHand` are the guards; each
`Break` that names one widens it by one wrong case. `MessageDelivered` reads "a message whose
addressee's turn ends again and again is delivered", and `EndedMarked` "a message still waiting
when its delegate has ended settles, delivered or `"ended"`". `EndedNotDelivered` says an
`"ended"` row is true: the message is in no transcript.

`ReplyOnce` and `ReplyOrNotice` say a message is answered once, by a reply or a notice, never
both; `ReplyToMain` that the answer goes to the delegate's main session; `ReplyNamesMessage`
that a reply's source (`src`) is the result that names its message. `ReplyOrNoticeComes` reads
"a message to a delegate whose turn ends, with a result or the process's end, is answered".
`rmem` and `last` are only what the wrong readers of `ReplyInMemory` and `SelfReply` hold; the
design leaves them empty. `SelfTurns` is off in the configurations that do not check replies:
`Team_Replies` and `Team_RepliesTwo` check them with it on.

## `Shell.tla`

One command `Shell` runs and how its process group ends. The command leads the group, as every
port program does.

- `CmdStartsChild` adds a child to the group; `CmdHolds` is `dtach -n`: the held process leaves
  the group by `setsid`. `ignores` is chosen at the start: which of the command and its child
  ignore TERM.
- `ShellTimesOut` sends TERM to the group and starts the grace. `ShellTakesExit` is `Shell`
  taking the command's exit, in the wait or the grace, and dropping the group from the reaper;
  `ShellKills` is the KILL when the grace passed with no exit.
- `OwnerDies` closes the port and leaves the command running. `ReaperTerms` and `ReaperKills`
  are the reaper's TERM and, after the grace, its KILL, for a group it still holds.
- `VmDies` ends the owner and the reaper. `WatcherTerms` and `WatcherKills` are the watcher at
  the end of its stdin, for the group if it still holds it.
- `held` is the reaper's and the watcher's hold on the group, one variable. `known` says the
  framework knows the command ended: `ForeignTakesId`, another program taking the group's id,
  waits for it as well as for the group to empty.

`killed` and `hit` are ghosts: a KILL was sent, and the processes a kill reached that it must
not reach.

## `Copy.tla`

A host's copy of one worktree and the runs in it: jobs (`Jobs`) and service starts (`Svcs`),
with the ssh connection dropping (`Drop`) and coming back or not (`Reconnect`), and restarts
of the framework between any two steps. Read it in the order of a job's run:

- `AskJob` is `run` in the agent's turn: the row is `"asked"` and the call `"waiting"`, in
  memory. `SyncBegins` takes the copy's turn (`turn`, durable), records the job's named paths
  (`stale[j]` empty: from now on a change to one is stale) and starts rsync. Its host side
  (`hs`) first waits for the copy's lock (`lock`): `HostLocks` takes it and begins writing, so
  `whole` is false until `SyncCompletes`. `HostGivesUp` is the lock's deadline passing while
  another sync's host side holds it, and `HostSideEnds` a host side that notices its local side
  ended and exits, freeing the lock.
- A drop marks every command in flight `"cut"` (`cmd`). `SyncCut` refuses the run at once and
  leaves the copy partly synced, but gives the turn back only once the sync's host side can no
  longer take the lock: it holds it, has exited, or its lock deadline passed. Until then the
  refused row keeps the turn, and `TurnBack` gives it back later. `SettleUnasked` (a row before
  its start whose call ended, as after a restart) follows the same rule.
- `StartSent` writes the row `"starting"` and sends `dtach -n` over ssh. `inflight` says the host
  may still run it: `Lands` is the host running it, and `NeverLands` a cut command whose deadline
  passed. `StartReplies` is dtach's answer over a connection that held; after a cut or a restart,
  `CutCleared` then `SettleStarting` read the host instead, but only once nothing is in flight.
  Either one gives the turn back.
- On the host: `JobExits` (the command exits; its wrapper ends what is left of the job's process
  group, `grp`, writes the exit file, then the socket goes), `Tick` (the timeout passes) and
  `HostTimesOut` (the wrapper ends the job's group and writes `"timeout"`), and `WrapperLost`
  (the wrapper killed before it writes the file, its group with it).
- `ReadSocket` then `ReadFile` read the end: the socket dead first, then the file, which was
  written before the socket went; the row is `"exited"` with its code, `"timedout"` or
  `"lost"`. `AnswerJob` answers it, or `FetchBegins`, `FetchPath` and `FetchDone` copy the named
  paths back first. `FetchPath` writes one path only if it is not in `stale[j]`, and otherwise
  adds it to `skipped`, which `FetchDone` answers as a conflict. A path the fetch writes is stale
  for every other job. `FetchCut` answers the end with the fetch cut. `GiveUp` is the call's own
  deadline with the connection down: unknown, or the end it read.
- `Edit` is the agent, or a subagent, editing a path of the worktree at any time: the path is
  stale for every job's record.
- Services: `AskService` with `keep` or without, `AskRestart` (the row `"restarting"`, then an
  end, then `"asked"` again for the turn), `OwnerEnds` and `OwnerSeen` (a kept service goes to
  the parent, any other is `"ending"`). `EndSent`, `Lands`, `EndReplies` and, after a cut,
  `EndConfirmed` end the process and confirm it by its socket.
- `FrameworkDies` clears the memory (`call`, `cmd`, `rd`, `fetchLeft`, `skipped`) and the
  connection; every call under way is answered `"restart"`, as the agent's MCP bridge does. The
  rows, the turn, the host (a sync's host side among it) and what is in flight to it stay.

`fresh`, `cover`, `badStart`, `fetched`, `since`, `clobbered` and `answer` are ghosts. `fresh[r]`
says a sync that began after `r` asked has completed (`cover` is who had asked when a sync
began), and `badStart` takes a run whose start landed on a copy not `whole` or not `fresh` for
it. `StartsOnSyncedCopy` is that set empty. `OneSyncWrites` counts the host sides writing,
whatever their local sides did. `AnswerIsReal` compares each answer and row with the host's exit
file. `since[j]` is the paths the agent edited after `j`'s sync began, and `clobbered` the ones a
fetch wrote over: `NoEditLost` is that set empty. `JobGoneAtEnd` says no process of a job's group
is left once its end is read. `ConnectionReturns` (`<>[]up`) is the antecedent of `JobSettles`
and `ServiceEndsWithOwner`: they hold once the connection comes back for good. `RunAnswered` and
`JobEndsAtTimeout` hold whatever the connection does.

`Copy_Jobs` checks one job with a fetch, two drops, a restart, an edit and a lost wrapper;
`Copy_Turns` a job and a service on one copy, with every invariant and `RunAnswered`;
`Copy_Services` a service, its restart and its owner's end. The slow one, run by hand,
`slow/Copy_Large`, checks every property with a job that fetches and a service that restarts on
one copy.

A service in `Fwds` has a forward (F-91): an `ssh -N -L` held by dtach on the workstation.

- `FwdStartSent` runs once the service's row is `"running"`: the row's forward (`frow`) says
  `"starting"`, and a local `dtach -n` is under way (`fcmd`, which holds the start it was sent
  for). `FwdLands` is dtach's answer: the ssh is held (`fproc` `"pending"`). `SshBinds` is the
  ssh listening on the local port (`port`), and `SshFails` its exit when the port is taken
  (`OtherTakes`) or it cannot connect. `FwdDrops` is the forward's own ssh dropping.
- `FwdSettles` reads the forward: open when its own ssh holds the port, and the start's call
  answers `started` then (not at `StartReplies`); dead at the start, and the service's row
  goes `"ending"`, so the call answers `refused` once it is ended. `opens` counts the opens of
  the current start; `gen` counts the row's starts.
- A loss is `FwdLost`: the row runs and says the forward is open, and its socket reads dead.
  `FwdLossClaimed` writes `"reopening"` and keeps the claimed state, `Key` (the start and the
  open count), in `facting`. `FwdReopens` acts only while that state is still the row's;
  `FwdReopenMoot` drops a claim the service's end or restart made stale. A reopen that fails
  makes the row `"failed"`, for a person, as does a claim a restart cut off.
- `FwdEnd` ends the forward when the row is `"ending"` or `"restarting"`; `EndSent` and
  `EndConfirmed` wait for it (`FwdGone`).

`fto`, `reopened`, `twice` and `badReport` are ghosts. `ForwardOnlyToCurrent` says a held
forward was started for the row's current start, whose process is held; `ForwardEndsWithService`
that an ended or refused row has no forward; `PortIsTheForwards` that a row said open only while
its own ssh held the port; `OneReopenPerState` that no state was reopened twice; and
`ForwardReopened` (liveness) that a lost forward is held again, or waits for a person, unless
the service stops first. `Copy_Forward` checks all of them with one service; the other
configurations have no forward (`Fwds = {}`), and their state counts did not change.
