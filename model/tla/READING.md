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
  (`claimed`) stays.

`OneReopenPerLoss` says one loss gets at most one reopen. `NoActOnOneWrongReading` says no claim
rests on a single reading that was wrong (`wrongOnce`). `Agent_Viewers` checks the liveness
with two agents; `Agent_LateViewers` with one agent, a late viewer and three losses;
`Agent_Claims` the claims across two restarts of `Recoveries`; `Agent_Writes` the writes.

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

- `StartAsked` is `start_delegate` in a parent's turn: refused by a check, or by the cap, or
  started.
- `DelegateFinishes` ends the delegate's turn with its last reply (`reply`) and fires its Stop
  hook, which lands in `stops` only while the framework runs. `StopHandled` turns it into a held
  report; when a restart lost it, `TranscriptRead` reads the last reply instead.
- `DelegateKilled` then `KillSeen`: the first kill is resumed, the second is the report.
- `DeliveryAsked` marks the row `"sending"` once the parent's turn has ended. `DeliveryTyped`
  is `Control`'s checked write, or `DeliveryRefused` holds the report again. `DeliveryMarked`
  writes `"delivered"`. A restart in between leaves `"sending"` with nothing in memory, and
  `SendingResolved` reads the parent's transcript (`got`) to settle it.
- `DelegateEnds` waits for `"delivered"`.

`FrameworkDies` clears what the framework holds in memory (`stops`, `sending`); the tables
(`status`, `report`, `resumes`) stay. `got` counts the report in the parent's transcript, and
`wrong` records a report typed where the check must refuse it. `SF_vars`, strong fairness, says a
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
  names the live process; past the deadline, `"orphan"` for a live socket, `"refused"` for a
  dead one. `ReRead` reads an `"unknown"` row again until it is running or gone.
- `StopAsked`, `StopSettled`, `StopTimedOut` and `Kill` are a stop, judged by the row's pid and
  start time. `StopTimedOut` leaves the row `"stopping"` and marks it `late`; a late row is not
  set back to running after a restart, and only it may be killed (`Kill`, `Recoveries`' step).
  `ForeignStarts` is another program taking a freed pid, which is why the start time counts.

`onTime`, `ends` and `wrongKills` are ghosts: they record what happened, for the invariants, and
the framework never reads them. `RunningOnlyIfLive` is a step property: the step that writes
`"running"` writes it only for a live process its file names.

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
  writing stays `Cut`.
- A message's write: `Mark` writes the row `"writing"` once the turn has ended (`idle`, set by
  a handled `result`). `Claim` spools the line and starts its claim command (`spool` is
  `"claimed"`: the spool file is gone). `CatWrites` is that command writing the whole line; a
  restart does not stop it. `WriteBegins` and `WriteEnds` are the framework writing a line
  itself, under `WriteInFramework` only.
- `Read` handles the next whole event and saves `offset` in one step; the two Offset Breaks
  split it, with `ReadFinished` as the second half. `Handle` says what each event writes:
  a replay delivers its message, a `result` sets `idle`, a request is held, an answer's replay
  answers it, a cancel cancels it.
- `AnswerAsked(a, h)` is an answer meant for request `a` taking hold `h`; the design needs
  `h = a`. `AnswerClaimed` writes the answer's line, which fits the pipe's atomic size.
- `ExitSeen` is the framework finding the pid gone. With the log read to its end, a message
  still `"writing"` is settled by the transcript, and a held request is lost.

`mine`, `begun`, `wmem` and `reading` are memory, cleared by `FrameworkDies`; the tables and the
disk stay. `handled`, `written`, `awritten`, `partialRead`, `malformed`, `intoRunning` and
`wrong` are ghosts for the invariants.

## `Team.tla`

The agents of one project: `Parent` and its delegates in `Agents`, and `Foreign`, agents of a
second project that call in and must be refused. It has three halves that share the agents and
the restarts.

- Agents: `proc` is each agent's state (`"working"`, `"idle"`, `"stuck"`, `"dead"`, `"ended"`),
  and `epoch` numbers it: it moves when the agent sticks, dies, is fixed or ends, so a claim
  names a state as `<<target, epoch>>`. `Faults` sticks or kills an agent; `DelegateEnds` is a
  delegate's own end once its report is delivered.
- Messages, read in the order of one message: `Send` stores the row as `"queued"`, refused
  across projects. `DeliveryAsked` marks it `"sending"` once the target's turn has ended and every
  earlier message from the same sender to the same addressee is delivered. `DeliveryTyped` is
  `Control`'s checked write, which appends the id to the target's transcript (`inbox`), or
  `DeliveryRefused` queues it again. `DeliveryMarked` writes `"delivered"`; after a restart,
  `SendingSettled` reads the transcript instead, as `Delegate.tla` settles a report.
  `Redirected` sends a settled row whose addressee has ended to the parent (`dest`).
- Claims: `ClaimTaken(c, t)` is `Grants`: no self, no stop of the parent, the same project, and
  no claim yet on the target's state. It writes the row (`claims`) and starts the call (`calls`,
  in memory). `FixActs` acts only while the claimed state is current, and may not help;
  `FixRefused` ends the call when it is not. A call cut off by a restart is closed by
  `ClaimSettled` and never sent again. A row in `done` still holds its state, so a fix that did
  not help leaves the state claimed.
- Services: `ServiceStarts` with or without `keep`, `ServiceHanded` to another agent, and
  `ServiceOwnerEnded`: a kept service goes to the parent, any other ends.

`fixed` and `wrong` are ghosts. `MessageDelivered` reads "a message whose recipient's turn ends
again and again is delivered"; its recipient is the addressee, or the parent once the addressee
has ended.

## `Shell.tla`

One command `Shell` runs and how its process group ends. The port's `sh` leads the group, with
the watcher and the command in it.

- `CmdStartsChild` adds a child to the group; it ignores TERM, so only a KILL ends it.
  `CmdHolds` is `dtach -n`: the held process leaves the group by `setsid`.
- `PortCloses` stands for a timeout, the owner's death and the VM's death alike: each closes
  the port's stdin.
- `WatchTerms` is the watcher reading end of file and sending TERM to the group; `WatchKills`
  is the KILL after the grace, which ends the watcher too.
- `ShStandsDown` is the `sh` seeing the command exit on its own: it kills the watcher by its
  pid and exits.
- `ForeignTakesId` is another program taking the group's id, possible only once the `sh` is
  gone and the group is empty.

`hit` is a ghost: the processes a kill reached that it must not reach.
