# coding_agent_framework: design

This is the plan the framework is built from. The order of its units is at the end; each unit
built so far has a build note in `docs/build-notes/`.

## What it is

A framework for running and supervising a tree of Claude Code agents on one workstation, spread
across several Claude accounts, with jobs and services on any number of hosts. It gives each
project:

- **a main session**: the chat a person works in, on the project's trunk. It moves from one
  account to another with one press, or on its own before a limit, and keeps its name and Remote
  Control. Main sessions of different projects talk to each other, and one can start a main
  session for a project that has none;
- **delegates**: real Claude Code sessions a main session starts through the framework, on the
  account with the most allowance left, each in its own worktree. To the main session a delegate
  acts like a subagent: a brief goes in, a report comes back. Inside it, Claude Code's own
  subagents delegate further, on the delegate's account;
- **a tree that talks along its edges**: an agent talks to its parent and its children, and main
  sessions to each other, all through one strict set of tools; any agent can see the whole tree
  and each agent's state;
- **jobs and services on hosts**: a main session or a delegate runs a test, a build or a kept
  program on the workstation or on another machine, on an exact copy of its worktree;
- **tmux, dtach and git worktrees** working together on the workstation;
- **stacked pull requests** (`gh stack`) for a main session's work, merged into trunk, which the
  main session then pulls;
- **state for LiveView frontends** that never lags, drifts or shows what is not so;
- **a TLA+ model**, checked with TLC, of how tmux, dtach, Claude Code, worktrees, stacks, jobs
  and services fit together, written before the code it models.

A project declares itself as data: its repository, trunk, branch pattern, setup commands and the
checks its stacks must pass. The framework holds no project's policy.

## Concepts

Each word below names one thing, and the design, the code and the views use it only for that.

**Agents**

- **Agent**: a Claude Code session the framework runs and holds: a main session or a delegate.
  Every agent runs on the workstation, held by dtach.
- **Main session**: a project's top agent, one per project. It runs Claude Code's terminal
  interface with Remote Control, because a person works in it. It sits on the project's trunk
  and does no work there itself: work happens in worktrees, and once merged, the main session
  pulls trunk, so it always holds the project's latest trunk. It is never archived.
- **Delegate**: an agent a main session starts through the framework, on any account, in its
  own worktree. It runs headless: it reads JSON messages on stdin and writes JSON events on
  stdout, and nothing reads its screen. It acts like a subagent of its main session: it gets a
  brief and gives one report.
- **Subagent**: Claude Code's own subagent, run inside an agent by Claude Code, on that agent's
  account. The framework does not start subagents; it reads and counts them.
- **Parent** and **child**: the link between two levels. A main session is the parent of its
  delegates, and a delegate the parent of its subagents. Neither word names a kind of agent.
- **The tree**: every project's main session, its delegates and their subagents. Main sessions
  are its roots.
- **Brief** and **report**: the first message a delegate is given, and its last reply, which
  goes to its parent.

**Machines and work**

- **Workstation**: the person's computer. Every agent, the framework, its tmux server, its
  dtach directory, every checkout and every worktree are on it.
- **Host**: a machine that runs jobs and services for agents, reached over ssh, or the
  workstation itself. No agent ever runs on a host other than the workstation.
- **Job**: a one-off command an agent runs on a host, on a copy of its worktree, ending with an
  exit code and a log, such as a test run or a build.
- **Service**: a program an agent starts on a host and keeps running, such as a dev server or a
  database, held by dtach, owned by one agent at a time, with a log.
- **Copy**: a host's copy of one worktree, kept in step by rsync before each job or service
  starts: every file git does not ignore, edits not yet committed included. Build outputs stay
  in the copy between runs. Nothing comes back from a copy but the paths a job names to fetch.

**Accounts**

- **Account**: a Claude account, known by its own config directory under the framework home.
- **Allowance**: an account's weekly share of use. Agents are balanced across accounts by it: a
  main session on one account starts a delegate on another. A subagent runs on its agent's
  account.
- **Move**: ending a main session on one account and resuming it on another.

**Code**

- **Project**: a repository and its trunk, declared as data.
- **Trunk**: the project's main branch, such as `main`.
- **Checkout**: the framework's own clone of a project's repository, on the workstation, at
  `<home>/checkouts/<project>`, made once from the project's repository. A project's
  repository is the remote its stacks land on (its `origin`), never the person's own clone, so
  the pull after a landing pulls what landed. The main session runs
  there on trunk, and every worktree of the project is made from it. The framework never runs
  git in the person's own clone.
- **Worktree**: a git worktree of the project's checkout, on one branch, on the workstation,
  under the framework home; each delegate has its own.
- **Stack**: a chain of branches and pull requests (`gh stack`) that lands into trunk.

**Holding and viewing**

- **Embedding app**: the Elixir application that runs the framework's parts in its supervision
  tree and hands them their settings. The framework is a set of libraries; it starts nothing of
  its own.
- **Framework home**: one directory per framework instance, on the workstation, given by the
  embedding app. It holds each account's Claude config directory, the dtach directory, the checkouts,
  the worktrees and the SQLite files. The framework never reads or writes `~/.claude` or any config directory
  outside it.
- **Server**: a tmux server, `tmux -L <name>`. Pane ids are unique only within one server, and a
  restarted server counts from `%0` again.
- **Viewer**: the tmux pane that shows a held agent: a main session's own screen (`dtach -a`),
  or a readable rendering of a delegate's event log. It can die, be reopened or be opened twice;
  the agent runs on.
- **Claim**: an agent's hold on one of its children, or a service, in one state, taken before a
  fix, so that only one fix of that state runs.

## The parts

Each part is one OTP process or one pure module, with one job.

The repository is a Mix umbrella with one OTP application per part (or per small set of parts
that only make sense together), under `apps/`. An app declares, directly, every app it uses and only those; `gate-deps` checks it
(Elixir alone accepts a module from any app in the dependency tree), a use outside the tree does
not compile, and the layers stay one way: base (`caf_shell`,
`caf_tmux`, `caf_holder`), then readers and writers (`caf_registry`, `caf_transcripts`,
`caf_usage`, `caf_accounts`, `caf_cli`, `caf_control`, `caf_stream`, `caf_intake`,
`caf_sampler`), then `caf_sessions`, then `caf_tracker` (with each source next to it) and
`caf_recoveries`, then the parts built later. Shared test aids that use no part above `caf_shell` live in `caf_test`,
used only in tests; setup a part's tests share with a higher app's tests lives in that part's
`test/support/`, compiled only for tests. Module names stay `CodingAgentFramework.*`. Each app
has its own tests and docs; a test of a Tracker source, or of two parts together, belongs to the
higher app; the
model (`model/tla/`), `bin/check-model`, devenv and the design stay at the root, and the gates
run across every app. No app starts a process of its own: the embedding app's supervision tree
starts each part.

| Part | Job |
|---|---|
| `Hosts` | the workstation and the other hosts, how each is reached, and its shell |
| `Shell` | the only module that starts programs, locally or over ssh, each leading a process group of its own, which a timeout ends |
| `Shell.Reaper` | one per host: ends a running command's group when its caller dies first or the VM dies |
| `Programs` | the absolute path of tmux, dtach, claude, git, gh, rsync, ssh, flock, sh, sleep, rm, kill, env, ps, cat and tail on each host; no other part names a fixed path |
| `Accounts` | the Claude accounts, each with its own config directory `<home>/accounts/<account>/claude` |
| `Usage` | each account's weekly allowance, from what Claude Code hands its status line; picks the account with the most left ("Allowance") |
| `Tmux` | sessions, panes, tags, keys and viewers on one server; a contract with a CLI and a fake |
| `TmuxSampler` | samples each server's panes and each host's held sockets, reports a held agent with no viewer, and cues `Sessions` when a held socket goes away |
| `Holder` | dtach: hold a process in a clean environment, open a viewer, list sockets and whether each lives |
| `ClaudeCLI` | the command line and environment of a session, per role and account |
| `Registry` | reads Claude Code's `<config>/sessions/*.json` per account, and so each held agent's pid |
| `Transcripts` | a session's transcript tail, its chats and its subagents |
| `Screen` | a main session's screen and dialogs, per Claude Code release, from real fixtures a person captures with a script |
| `Stream` | a headless delegate's stdin and event log: writes messages, reads events from an offset |
| `Intake` | hook events in; holds `PermissionRequest` hooks until answered |
| `Control` | the one writer per host: send, answer, interrupt, stop, respawn |
| `Sessions` | start, resume and stop held agents on the workstation, with their viewers, rows and worktrees |
| `Mover` | drains a session and moves it between accounts |
| `Mains` | each project's main session, what it holds, and the start of one for a project that has none |
| `Delegates` | the delegate protocol: start, report, resume, end |
| `Stacks` | the worktrees and `gh stack` chains of a main session's work |
| `Copies` | a host's copy of each worktree, brought in step by rsync before each job or service, and removed with the worktree |
| `Jobs` | one-off commands on a host, in a copy: held, logged, ended by their exit or their timeout |
| `Tracker` | the state views read: the fold of every reader |
| `Recoveries` | detect a broken state, act once per state, verify; reopens a lost viewer, and so starts a host's tmux server again after it dies; ends an orphan's process, or one that did not exit after `/exit` within its stop's deadline, and only by the row's pid and start time (`Sessions` itself never kills) |
| `Mailbox` | messages along the tree's edges and between main sessions: stored, delivered once, in order per sender and addressee |
| `Services` | programs agents start and keep on a host, in a copy: held, owned, read, written to, restarted, with ports forwarded to the workstation |
| `Grants` | decides whether a caller may act on a target, by the tree's edges; holds a fix's claim on it |
| `MCP` | the agent tools ("Agents working together"); each call is checked by `Grants` |
| `Ghostty` | opens or focuses a session's terminal window |

The LiveView side is a library of components over the `Tracker`, with one example app.

## Hosts

Agents run only on the workstation; other hosts run jobs and services, the way an editor that
edits files over ssh keeps the editor local and runs commands remotely. Every key still carries
its host, as it has since the first part built, so the workstation is one host among them:

- the workstation has the framework's node, its one tmux server, its dtach directory for agents,
  one `Registry` reader per account and its `Control`; every agent's row, pane and socket is on
  it;
- a pane is `{host, server, server_start, pane_id}`, a held process `{host, socket}`; the
  server's start (its start time and pid) is part of a pane's key, so a pane id never matches
  across a restart;
- another host is reached over ssh through `Shell`, one connection per host, and has a
  directory of the framework's own (its copies, its dtach directory for services, and its
  logs). Nothing of Claude Code runs there, so no hook, session file or transcript is read from
  it;
- a job or service runs in a copy of the worktree it names. Before a job or a service starts,
  `Copies` brings the copy in step with the worktree by rsync, over every file git does not
  ignore, edits not yet committed included; build outputs stay in the copy between runs. The
  workstation runs jobs and services in a copy too, under the framework home, so build outputs
  and a service's files stay apart from the agent's edits on every host, by one path of code.
  Two runs on one copy take turns at the sync, so neither starts on half of the other's files;
  a later run's sync does change files under a job or service still running in the copy, as an
  edit in the worktree changes them under a program on the workstation, so a test can run
  beside its server. A sync is not a snapshot: a file edited while the sync runs comes in
  either version. On the host, a sync holds a lock of its copy for its whole life, and the next
  sync takes that lock under its deadline, so the host's side of a cut sync never writes under
  the next one. A host's side may still be waiting for the lock when its sync is cut, and may
  take it later, so a cut sync gives the copy's turn back only once its host side can no longer
  take the lock: it holds it, has exited, or its lock deadline has passed (the rule the turn
  keeps for a cut start). The refusal is answered at once; only the turn waits. The host side
  takes the lock before rsync's server starts (the server runs under it, as rsync's
  `--rsync-path`), since that server deletes files from the file list before any data arrives.
  The workstation's sync goes through the same host side, by a local stand-in for ssh, so its
  copy has the lock too. A sync deletes only what an earlier sync sent and the worktree no
  longer has, never what was made in the copy, since git's ignore rules cannot tell a build
  output from a file the worktree removed (F-74).
  A copy is removed with its worktree;
- a host that restarts ends every held job, sync and lock on it; a job it ended has no exit
  file, so its end is unknown (`{:unknown, :no_exit}`), never an exit code;
- a job is held by dtach on its host, so a dropped ssh connection does not end it; its output
  goes to a log on the host, read back from an offset, and it ends with its exit code or its
  timeout, which ends its process group. The job runs in its wrapper's own process group, led
  by the wrapper, so the group's id stays the wrapper's while it lives and cannot have been
  reused (the rule `Shell` keeps). When the command exits, or at the timeout, the wrapper writes
  the exit file, then ends the group with itself in it, so no child of the job is left to write
  in the copy; the fetch begins only once the job's socket reads dead, after that end. A kill of
  the group from outside ends the wrapper and the job together, and no group outlives a wrapper
  that was killed (F-76);
- a job can bring files back: `run`'s `fetch: [paths]` names paths that rsync copies from the
  host's copy into the worktree after the job ends. Nothing comes back unless named, and nothing
  is written over blind: the sync records each named path's size, time and hash, and the fetch
  writes a path only while the worktree's file is still what the sync sent; it answers the
  others as a conflict and leaves the copy's version on the host. Each path comes in under a
  temporary name, is compared after that write and before its rename into place, so the only
  window left for an edit to be lost is between that compare and the rename;
- `run` answers `{:ok, %{exit: code, log: tail, fetch: :done | :none | {:conflict, paths} |
  {:unknown, reason}}}`; `{:unknown, {:timeout, %{fetch: f}}}` once the host ended the job at
  its timeout, with the fetch's outcome; `{:unknown, :dropped}` at the call's deadline with the connection
  down; `{:unknown, :no_exit}` for a dead socket with no exit file; `{:refused, {:sync,
  reason}}` for a cut sync, when nothing ran. An unknown answer names the job, and once the
  job's end is read it arrives to the caller as a message, as a delegate's report does after
  `run_delegate`'s timeout, saying that nothing was fetched; a later `run` fetches nothing for
  an earlier job. A late end is handed to the embedding app at least once, never lost: a
  repeat after a crash carries the same job id, so the receiver drops it. A job a restart left
  before anything was sent to the host is handed on once as interrupted, never retried. A
  job's row keeps its worktree's path, so a fetch a restart cut leaves no temporary folder past
  the next start (F-78);
- a service on another host is held the same way, and a port it listens on is forwarded to the
  workstation over the host's ssh connection when the service asks for it, so tests on the
  workstation reach it at `127.0.0.1:<port>`;
- a reader of a whole host (held sockets, the `TmuxSampler`) has the `Tracker` scope
  `{host, :host}`, beside the `{host, account}` of a reader of one account;
- the `TmuxSampler` reads a host's panes and then its sockets, not in one instant, so a viewer
  opened between the two reads can show as lost for one sample. A recovery acts on a lost viewer
  only when two samples in a row agree. A pane with no tag, or one whose tag names another
  session than its own, is a broken state the sampler reports and `Recoveries` handles;
- a loss is named by its socket, from the sample where its row took that status, or from
  `Recoveries`' last open of that socket's viewer (answered with a pane, or refused because the
  session exists), or a person's clear, whichever is later. A sample older than a maximum age
  (the caller's, 30 s by default) is not acted on, and the loss's row says why. A third loss of
  one socket within a window (the caller's, 60 s by default) ends `failed{repeating}`, and that
  socket is not reopened until a person clears it.

`Copy.tla` models a copy's sync, a job's run and a service's hold on a host, with a dropped
connection at any step, before `Copies`, `Jobs` and remote `Services` are built. The spec
settles (F-70):

- the copy's turn is a row in `Copies`' table, taken before the sync begins and given back only
  once the run's start is settled: by dtach's reply over the connection that sent it, or, after
  a drop or a restart cut that reply, by a read of the host once the start's deadline has
  passed. A start still in flight to the host never lands under the next run's sync;
- a sync that a drop or a restart cut refuses its run, which never started, and leaves the copy
  partly synced for the next run's sync;
- a job's timeout is kept on the host: the wrapper dtach holds ends the job's process group at
  the timeout, so a job ends on time with the connection down and the framework stopped. The
  wrapper writes the job's exit code, or that it timed out, to a file before it exits, and the
  framework reads the job's socket dead first and that file after it. A dead socket with no
  file is a job whose end is unknown, never an exit code;
- a run's call has a deadline of its own, the job's timeout, and at it, with the connection down,
  answers unknown, or the end it read with its fetch as cut. A restart ends every call under
  way, and the job's row is still settled from the host once the connection is back;
- the fetch begins only after the job's end was read, and copies only the paths `fetch:` names;
- a service's end is written to its row before it is sent, and is done only when the service's
  socket is read dead; a restart of a service is such an end, then a start with its own sync.

The spec settles (F-72):

- the sync's record of the named paths is taken before it sends, not once it completes: a record
  taken after takes an edit made during the sync as sent, and the fetch writes over it;
- the fetch compares each named path with the record and writes it in one step per path, and a
  write by one job's fetch makes that path stale for every other job's record;
- a cut sync answers its refusal at once and keeps the copy's turn until its host side can no
  longer take the lock; a turn given back at the cut lets that host side take the lock later and
  write under the next run's sync, which then starts on a copy not whole;
- a job's end is read only once its group is gone: the wrapper ends the group when the command
  exits, at the timeout, and when it is itself killed (assumed of the host, not built).

## Main sessions

A project has at most one main session. It runs in the project's checkout, the framework's own
clone under `<home>/checkouts/<project>`, made once from the project's repository, on trunk. It
changes nothing there: its delegates work in worktrees, their branches land into trunk through
stacks, and after each landing the framework pulls trunk in that checkout (fast-forward only,
and only while the checkout is clean; anything else is a state a person sees). So the main
session always holds the project's latest trunk.

A person starts a main session from the views, and a main session can start one with
`start_main(project, brief)` for a declared project that has none; a project that has one
refuses it with `{:refused, {:running, name}}`. The new main session's brief is its first
message.

A main session holds, and a view shows:

- its account, tmux session and pane, and whether its MCP tools are connected;
- its checkout: trunk, ahead and behind its remote, and whether it is clean;
- each delegate's worktree: branch, ahead and behind trunk, unpushed commits, uncommitted
  files, and the pull request and stack each is part of;
- the statuses of its delegates and their subagents, its open questions and its stack's checks;
- the command that attaches to its tmux session, and Open in Ghostty.

**Moving it** starts on its own when the account reaches 90 % of its weekly allowance, or with
one press at any level. It goes to the account with the most allowance left:
1. Drain: no new delegates or background commands start.
2. Wait until no background command runs. This is read after the drain began, so nothing can
   start after it; a background command is a child of the session's process and ends with it.
3. End the session through `Control`'s checked write: `/exit`, typed only when the turn has
   ended and the input box is empty, in the same step as that check, so a prompt that arrives
   in between is not cut off.
4. Wait for the old process to exit.
5. Copy the transcript to the other account. Copying after the exit keeps a turn that a prompt
   through Remote Control started before the end.
6. Resume it there with `--resume`, its name and Remote Control on.
7. Ignore the old process's `SessionEnd` that arrives after the new one started.

Running delegates, jobs and services do not hold a move: each runs in its own process and
survives the main session's end. A delegate's report is held by its main session until a
process of it runs whose turn has ended, and the hold survives restarts of the framework.

Its chat is never archived.

## The delegate protocol

A main session calls `start_delegate(project, branch, model, brief)`. The framework:

1. checks the project, the branch name, the cap of delegates, and any worktree already at the
   path (reused only when clean, on the branch, and held by no live agent);
2. picks the account with the most allowance left;
3. adds the worktree and runs the project's declared setup in it, so a fresh worktree has its
   dependencies and build state before the first command;
4. starts `claude` headless, held by dtach, with `--session-id` set to an id the framework
   chose and the brief as its first message, opens a viewer of its event log tagged with the
   session, project and unit, and confirms the start by its first event naming that id;
5. delivers its last message to the parent when it stops. When a restart lost the stop event,
   it delivers the transcript's last reply instead, and ends the delegate only after delivery.
   The delegate's row moves from running to finished once, by its Stop event or by its
   transcript's last reply, whichever comes first; a later one is ignored. A report is tried at
   each of the parent's turn ends, through `Control`'s checked write, and a refused write holds
   it again. The row is marked sending before the write; after a restart, a row still marked
   sending is settled from the parent's transcript, once the parent's turn that took it has
   ended: delivered if the report is there, held again if not. Each report carries a mark of
   its own that the transcript shows;
6. resumes it once when it is killed before its last reply, and reports a second such kill
   instead of retrying. That report is held and delivered like a finish. A kill after the last
   reply is a finish, read from the transcript.

**What `Delegates` holds** (`Delegate.tla`; F-59's build note):

- The embedding app hands `Delegates` its projects as data when it starts it, each as `Sessions`
  reads it ("The worktree") with two more fields: `branches`, the pattern a delegate's branch
  must match, and `cap`, how many of one parent's delegates may hold it at once. There is no
  table of projects and no default cap. A delegate holds its parent's cap from its row's
  start until it ends: starting, running, resuming, finished or failed, since a finished one
  still holds its worktree and its report.
- Until `Mains` exists, the caller names the main session, and the row keeps that name. Until
  then `Grants` knows a main session only as a parent a delegate's row names, and refuses every
  check on a delegate whose rows name two parents (F-73's new-3 and new-4); `Mains` ends both.
- A delegate's session is named `<project>-<branch>`, each character of the branch other than
  a letter, a digit, `_` or `-` written as `-`, so a later start of the branch finds its
  worktree.
- `Delegates`' row is written first, as starting, with the uuid its brief will go in under,
  before `Sessions` is called. A resume is counted in the row first, as resuming, before
  `Sessions.resume` is asked; when the brief had gone in, the row takes a uuid of its own for
  the resumed process's message. `Stream` refuses a uuid a second time, so a restart never
  writes a turn's message twice. The resume is asked only once `Sessions`' row of the killed
  process has ended (`stopped`, by its settle of a running row whose process is gone), since
  `Sessions` starts a name only then; until it has, the delegate stays running.
- A row a restart left starting or resuming is settled by `Sessions`' row of its call (one
  written at or after the call), once that row is settled: running, or refused. With no such
  row by the row's deadline, the call never reached `Sessions`, and the row is refused (a
  start) or failed (a resume) as interrupted. A call is never made again. A refused resume is
  failed, and the refusal is its report.
- A headless delegate's Stop is the `result` that ends the turn its message began, read from
  its event log; its text is the report. The log's offset persists, so a restart does not lose
  it; a kill before its line is written does, and the transcript's last reply stands in.
- A resumed process takes no turn of its own. It is given the brief again, under its uuid, when
  the brief had not gone in, and otherwise a fixed message to go on with its brief.

A start writes its row first, as starting, with its worktree path and socket name, before it
acts. After a restart, a row still starting is adopted when its held process lives and its
session file names it; otherwise its worktree is removed when clean and held by no agent, and
the start answers `refused{interrupted}`. The adoption waits for the start's own deadline
before it decides, since a held process may only be slow to write its file; one with a live
socket and still no file then is kept as an orphan row for `Recoveries`, never left without a
row. A socket and its process end apart (`Start.tla`, F-64): dtach removes its socket a moment
after its process exits, and a dtach killed hard leaves a stale socket while its process may run
on, unheld. So a dead socket whose session file names a live process is an orphan too, at the
start's deadline, with reason `unheld` and the file's pid and start time, so `Recoveries` can end
it by them; a headless delegate's `pid` file names no start time, so its orphan keeps no pid
(F-64's build note, new-3). The row keeps the start's deadline in wall-clock time, so a restart
does not move it. A read that fails decides nothing: the row stays as it was for the next read,
and only a socket read as dead, with no file that names a live process, makes it refused. A hold
that answers unknown waits for the session file like any other start, and its row keeps the
unknown answer's reason, so a refused row tells a hold that failed (dtach finding no pty) from a
program that exited at once. A stop is done, and a row still stopping after a restart is settled
stopped, only when its process is gone by pid and start time and its socket is read as dead, so
a resume right after the stop's answer never meets a live socket; after a restart, one whose
process lives is running again. A stop whose deadline passes with its process alive leaves the
row stopping, with its deadline, and a restart does not set it back to running. One whose
deadline passes with its process gone and its socket still live answers
`unknown{socket_live}` and leaves the row stopping for the next settle. `Recoveries` ends an
orphan's process, or one that did not exit after `/exit` within its stop's deadline, and only by
the row's pid and start time; `Sessions` itself never kills. A running row with no call under
way whose process exited by itself (a crash, or a kill) is settled stopped, with reason
`exited`, once its process is gone by pid and start time and its socket is read as dead, so a
delegate killed before its last reply can be resumed; a pid another program took does not keep
it running, a process whose dtach was killed keeps it running, and a read that fails decides
nothing. `Sessions` settles running and stopping rows with no call under way only at a cue: a
`Registry` or `Stream` cue, when a process is gone, and the `TmuxSampler`'s cue
(`tmux:<host>:<server>`, which it sends when its rows change, as when a held socket goes away
or goes stale), so a settle that met a socket dtach had not removed yet is taken again when the
socket goes. A row whose start answered unknown is read again at each `Registry` read until it
is running or gone, and is an orphan, as above, when its socket is dead while its file names a
live process. A name whose row is unknown,
orphan, starting or stopping is not free for a new start: its process may live. A start is confirmed by the session file's `name`, which
`--name` sets; a check against each pinned Claude Code release confirms it, with the Remote
Control check. `Start.tla` models the start and its adoption, for every session's start and
resume, with its worktree and setup; `Delegate.tla` leaves the start abstract and relies on it.

**The worktree** of a start (`Start.tla` with `Worktrees`; F-55's build note):

- It lives at `<home>/worktrees/<project>/<name>`, by the session's name, under the framework
  home's physical path (git prints worktree paths with symlinks resolved). The row's `cwd` is
  that path, with the project's checkout and the branch.
- `Sessions` reads a project as `%{name, repo, trunk, setup, setup_timeout, env}`: the absolute
  path of the project's checkout ("Concepts"), where its worktrees are made and never the
  person's own clone, the trunk a new branch starts from, the setup as a list of commands (each an argv whose program is an absolute path), one deadline for the whole setup,
  and the environment that git and the setup run in, built from nothing (`env -i`), so nothing
  of the framework's own environment, such as a `GIT_DIR`, reaches the repository. The branch
  pattern and the cap are `Delegates`' checks; `Sessions` checks that the branch is a plain ref
  name.
- A path is held by an agent when a row that has not ended has it as its `cwd`. A start whose
  path another row holds is refused before its row is written.
- "On the branch" is read from `git worktree list --porcelain` of the checkout: the path with
  `branch refs/heads/<branch>`. Never from whether the branch exists: an add that fails leaves
  its branch behind. "Clean" is `git status --porcelain --untracked-files=all` listing nothing:
  no change to a tracked file and no untracked file that is not ignored. Ignored files, such as
  the build state the setup made, do not count, and `git worktree remove` deletes them.
- A free path is added with `git worktree add <path> <branch>` when the branch exists, and with
  `-b <branch> <path> <trunk>` when it does not. A path that holds anything else is refused.
- Every start runs the setup, in a reused worktree too, so a project's setup must be safe to run
  again: a setup that failed or passed its deadline leaves the worktree as it is, and the start
  answers `refused{setup, …}`; the next start of the name reuses it when clean and runs the
  setup again. The setup runs with the host's `Shell.Reaper`, so a restart of the framework
  ends it with the call. The row's deadline covers the setup's.
- A resume takes its name's worktree as it is, changes and all (the work of the delegate that
  was killed), refuses one that is not there, and runs the setup.
- After a restart, the worktree of a row refused as interrupted is removed when it is on the
  branch, clean and held by no other row, with `git worktree remove` without `--force`, which
  refuses a dirty one itself. The branch stays. An orphan's worktree stays with its process.

A part that waits on a reader within a call (a start waiting for its session file) reads it
again at a fixed interval until the call's deadline. That wait is part of the call's answer and
its timeout, not a hidden one. Everything else follows the reader's cue.

The answers are explicit: `started{…}` or `refused{reason}`, then `finished`, `killed` or
`late_report`. A delegate's subagents count for tokens and as work still going for its parent,
and one with no closing event ends after a bound.

## Headless delegates

A delegate runs `claude -p --verbose --input-format stream-json --output-format stream-json
--replay-user-messages --permission-prompts host --session-id <id>`, and a resume names
`--resume <id>` in place of `--session-id`, which Claude Code refuses beside it (Claude Code
2.1.322; each flag checked against each pinned release; without `--verbose` it exits at once;
sources in `docs/build-notes/F-31.md`). `Stream.tla` models this section. This removes screen
reading for delegates:

- **Held, apart from the framework.** Each delegate has a directory
  `<home>/streams/<session id>/`. It is named by the session id, which a resume keeps and a new
  start does not, so a new start of a name that ended never reads the old log. Each process has
  its own FIFO `in.<n>`, with `n` the row's resume count, made with `mkfifo` by the follow
  before the process starts; an old one stays, unread. dtach holds this wrapper, run by `sh` in
  the clean environment, with the directory, the FIFO and the command:

  ```sh
  d=$1 f=$2; shift 2
  printf '%s\n' "$$" > "$d/pid"
  exec 3<>"$f"
  exec "$@" <&3 3<&- >>"$d/events.jsonl" 2>>"$d/stderr.log"
  ```

  The delegate's stdin is the FIFO opened read-write, so it holds a writer itself and its stdin
  never reaches end of file: the framework's restarts and its writers' exits never end it.
  `exec` makes `claude` the held process, with the pid the wrapper wrote to `pid`. That file,
  not a session file, gives a delegate's pid: nothing shows that `-p` writes one, and a headless
  session has no `--name` to match. `Sessions` reads it only after `Stream` has read the
  `system`/`init` naming the session id, takes its start time from `ps`, and checks the socket
  again. That init, with the pid alive, confirms the start. `Stream` sees an exit only of a
  process it knows was started: `Sessions` tells it once it held the process, and a read or a
  write's check that finds the socket live tells it too; without that, the socket a resume
  has not yet replaced would read as the new process's exit.
- **Events are read from an offset.** `Stream` reads only whole lines of `events.jsonl` (a line
  without its newline is still being written), and handles each event and saves the offset in
  one transaction, so no event is handled twice or skipped across restarts. A resume appends to
  the same log. A death can leave a last line without its newline; the follow again ends it with
  one before the new process starts (the old one is gone, so no one else writes the log), so it
  is one line that does not parse and the next event is whole. The follow again also sets the
  turn ended: a process that exited during a turn ran no `result`, and the resumed one starts
  none of its own.
- **Writes are lines, claimed once.** A message, an answer, an interrupt or an end is one JSON
  line. Its row is marked first, then the line goes to a spool file `out/<uuid>.json`, and the
  host's one writer starts `sh -c 'exec 3<"$1" && rm "$1" && exec cat <&3 >"$2"' sh <spool>
  <fifo>`, with the FIFO of the process the write was checked live for. Removing the spool is the
  claim: once it is gone, the line goes in whole, by a process that does not end with the
  framework (it runs with no reaper); while it is there, nothing of it went in, and after a
  restart the writer starts it again. So a line is never written twice and never cut, whatever
  its length. A claim names one process's FIFO, so a line waiting at that process's exit never
  reaches the next process beside its resend (F-51's build note, new-1). One message line is in
  flight per delegate at a time, and every other line is kept
  within the pipe's atomic size (512 bytes on macOS; a deny's message is cut to fit), so lines
  written together never mix. A line that does not parse ends the session, so each is built by
  one encoder.
- **Turns are events.** A turn ends with exactly one `result`, whose `user_message_uuids` name
  the messages it took. A message goes in only after its delegate's turn has ended: one written
  during a turn joins it. A delegate can start a turn by itself (a background task that ends
  wakes it); a message that joins such a turn is accepted, and is still delivered once, by its
  replay.
- **Delivered once, seen.** A message carries a uuid of the framework's, and with
  `--replay-user-messages` it comes back with that uuid and `isReplay`. Its sending mark is
  settled by the replay. When the delegate exits, a message with no replay in the log, read to
  its end, is delivered if the transcript holds its uuid and undelivered otherwise; it is never
  written again blind. Since no line of an earlier process reaches a later one, "undelivered" is
  final. It goes to the resumed process again, first, under its same uuid, before any other
  message. Claude Code drops a user line whose uuid its transcript holds; with a FIFO per process
  the framework does not rely on that, and the same uuid is defense in depth.
- **A claim needs a reader.** Opening the pipe for writing waits while no process reads it, so
  the writer starts a claim only for a live delegate, under the write's deadline, and
  `Recoveries` ends a claim command still waiting past it, by its pid and start time. One left
  waiting at an exit waits on a FIFO no process reads until then. The
  wrapper's pipe is made with `mkfifo`, which `Programs` names.
- **Permissions.** A request is a `control_request` with `subtype` `can_use_tool`, its
  `request_id`, `tool_name`, `input` and `tool_use_id`. Its row is held, then answering, then
  answered when the answer's replay is in the log; a `control_cancel_request` with its id
  cancels it, and the delegate's exit loses it. Unlike a hook, it waits in Claude Code through a
  restart of the framework, so a held row stays answerable, with no deadline of its own: a view
  flags a request held longer than 10 minutes, and nothing answers it but a person, an agent's
  `answer`, a cancel or the exit. A delegate's hooks are not needed for its own turns; its
  events are the log.
- **Ending.** An `end_session` request ends the session and cuts a running turn, so it goes in
  only after the report is delivered and the turn has ended. `Sessions` checks the report before
  it asks for the end: against the parent's row once `Delegates` exists, and until then by the
  caller's statement. `Stream` refuses the end while the turn runs or a message is under way or
  found undelivered, and refuses a message once an end is marked; behind the report, its turn
  check is defense in depth. `Sessions` sees the exit by the pid; one that does not exit within
  the stop's deadline is ended by `Recoveries`.
- **Rate limits.** A `rate_limit_event` carries the account's windows, among them
  `seven_day.utilization` (0 to 1) and `resetsAt`, as the status line does. `Usage` reads the
  latest one of each delegate's log as it reads a status line. The field is marked internal, so
  the check against each pinned release covers it.
- **No trust dialog.** A headless session skips the workspace trust dialog.
- **Its viewer** is a tmux pane that renders the event log as readable text, opened and
  reopened like any viewer, with the command `Sessions` answers for the row. It waits for a log
  that is not there yet (`tail -F` until the renderer exists). It writes nothing.
- **A stop ends with the socket.** `ps` stops listing the process a moment before dtach removes
  its socket, so a stop is done only when the pid is gone and the socket has ended; a resume
  before that is refused, and the caller resumes after the stop's answer.
- **Checked against each pinned release**, with the flags: whether `-p` writes a session file
  (which could stand in for `pid`), and whether `system`/`init` comes before the first line is
  read. If the init comes only with the first turn, the start writes the brief through `Stream`
  right after the hold, before it waits for the init. And the drop of a user line whose uuid the
  transcript holds, with a turn cut off at the exit: 2.1.322 may run such a line again
  (F-51's build note, new-4). The framework does not rely on the drop.

A main session stays interactive. `Screen` reads only a main session's screen: whether its input box is
empty before a write, and its dialogs by label. Its fixtures are captured from a real session
once per pinned Claude Code release by a script a person runs and reviews, with names and paths
scrubbed; no test runs the real Claude Code.

## Agents working together

Agents talk along the tree's edges: an agent talks to its parent and its children, and main
sessions talk to each other. Any agent can see the whole tree. Each does this only through the
framework's tools, which are strict in how they act and narrow in whom they reach.

**Strict in how:**
- A tool names its target by what the framework holds: an agent's name or a service's name.
  Never a tmux target, a pid, a socket path or a raw command for tmux.
- Each call acts through the part that owns the action: a key goes through `Control`'s checked
  write, a held process through `Holder`, a dialog through the hook `Intake` holds.
- Each call answers `{:ok, …}`, `{:refused, reason}` or `{:unknown, reason}`, with a finite
  timeout. A tool never retries, and never waits longer than the timeout it was given.
- The framework knows who calls. Each agent's MCP server starts with that agent's identity, and
  the agent cannot choose it.
- Every call is written to a table before it acts and again with its outcome. A view shows the
  log, and an agent's parent sees every action on it.

**Who may act** (`Grants`):
- Reading the tree (`agents()`: every agent of every project, its parent and its state) is open
  to every agent. Reading one agent closely (`look`, `transcript`) is open to the agent itself,
  its parent, its children and, for a main session, the other main sessions.
- Messages go along the edges only: a main session to its delegates and to other main
  sessions; a delegate to its main session. A delegate has no other agent to message: its
  children are subagents, which Claude Code runs inside it. Two delegates talk through their
  main session.
- A fix (interrupt, answer, resume, stop) is a parent's act on its own child. It takes a claim on
  the child first. The claim is for the child's current state, the way `Recoveries` acts once
  per state, and is a row in `Grants`' table, written before the fix acts. A second fix of the
  same state is refused with `{:claimed, by}`. The fix acts only while the claimed state is
  still the child's current one, read again when it acts. A call ends with its fix verified or
  not; the row keeps that state until the child's state moves, and a fix that did not help goes
  to a person. Each claim row carries the id of the framework start that wrote it, a value the
  embedding app makes once per start; a row of an earlier start still claimed is one a restart
  cut off. A claim a restart of the framework cut off is closed as interrupted, never
  retried. A state once claimed stays claimed, whatever the claim's end: a second claim of it
  is refused (`{:already_claimed, by}`), so a fix acts once per state. A caller whose claim was
  answered unknown reads the claims' rows before it decides anything (F-75).
- No agent fixes or moves a main session; only a person does, a move with one press.
- An agent may not fix itself. A stuck agent cannot be relied on to see that it is stuck.
- Jobs and services: a main session and its delegates may run jobs and start services on any
  host, in a copy of their own worktree (a main session's is its checkout). A service is fixed
  by its owner, or by the owner's parent.

**The tools:**

| Tool | Who | What it does |
|---|---|---|
| `agents()` | any agent | the tree: each agent's name, kind, project, parent, account, state (working, waiting, idle, stuck, gone), what it waits on, and its subagents |
| `message(to, text)` | along an edge | stores a message and delivers it to the target when its turn has ended; answers `queued{id}`, then the sender learns `delivered` |
| `look(agent)` | parent, child, main sessions | a main session's screen as text, or a delegate's rendered event log; its open dialog or request; its last transcript lines |
| `transcript(agent, from)` | parent, child, main sessions | the agent's transcript from an offset |
| `interrupt(agent)` | parent | a delegate's stream interrupt, under a claim |
| `answer(agent, dialog, label)` | parent | answers a child's open request through its held hook, by label, under a claim |
| `resume(agent)` | parent | starts a dead or wedged child again with `--resume`, once per state, under a claim |
| `stop(agent)` | parent | ends a delegate after its report is delivered, under a claim |
| `start_delegate(…)` | main session | starts a delegate and answers at once; the report arrives later as a message ("The delegate protocol") |
| `run_delegate(…, timeout)` | main session | starts a delegate and holds the call for its report, up to `timeout`, for short work; at the timeout it answers `{:unknown, :timeout}` with the delegate's name, and the report then arrives as a message, as `start_delegate`'s does |
| `start_main(project, brief)` | main session | starts the main session of a project that has none |
| `run(host, argv, timeout, opts)` | main session, delegate | runs a job in a copy of the caller's worktree on `host`, and answers its exit code and the end of its log, or `{:unknown, :timeout}` once it ended it; after the job ends, the paths `fetch:` names, and only those, are copied by rsync from the copy into the caller's worktree |
| `service_start(name, argv, opts)` | main session, delegate | holds `argv` by dtach on a host (`host:`, the workstation by default) in a copy of the caller's worktree, with its output in a log, and a port forwarded to the workstation if `forward:` names one |
| `services()` | any agent | each service: name, host, owner, state, restarts, forwarded port |
| `service_logs(name, from)` | any agent | the service's output from an offset |
| `service_send(name, input)` | owner, owner's parent | text or keys to the service, through `Control`'s checked write |
| `service_wait(name, until, timeout)` | any agent | until a line matches a pattern, a port listens, or the service exits; answers which, or `{:unknown, :timeout}` |
| `service_restart(name)` / `service_stop(name)` | owner, owner's parent | restarts or ends a service, under a claim |
| `service_hand(name, to)` | owner | hands a service to its parent or one of its children |
| `ask(question)` | any agent | asks a person, without blocking |
| `reload()` | any agent | reloads the caller's own tools |

**Who calls.** The tools are served over MCP's HTTP transport from the framework's node, at
`http://127.0.0.1:<port>/mcp`, with no program between. `MCP` makes each agent a token and
writes, before the agent's launch, a config of the framework's own (`<home>/mcp/agents/<agent>.json`)
with one `http` server entry that carries the token in a header; `ClaudeCLI` names that file by
`--mcp-config` next to the account's own, under `--strict-mcp-config`. The endpoint maps the
header's token to the agent, and no argument of a call names the caller, so nothing the agent
sends changes who it is. A missing or unknown token is refused before any row is written. The
endpoint keeps no MCP session: each request stands alone, so a restart of the framework leaves
an agent nothing to reconnect. This is simpler than a stdio bridge with the token in its
arguments: there is no program to start per agent, nor one whose stdin could break on a byte,
nor one that must reconnect by itself, so the bridge rule ("Rules learned") has nothing to
apply to. A token is only as private as the workstation's user: any process of that user can
read the files (F-86).

**Messages** are stored before they are sent, so a restart of the framework does not lose
them. One goes in only when the target's turn has ended (and, for a main session, its input box
is empty), the same rule as any write, with a report's sending mark and settle: marked before the
write, settled from the target's replay or transcript after a restart, never resent blind.
Messages are kept in order per sender and addressee. A message is refused when its addressee is
not along an edge of the sender, or is a name the framework does not hold; one to a dead agent
is held until it is resumed or ends. A message to a delegate that has ended is not delivered:
its row says the delegate ended before it went in, and the sender (the delegate's main
session, its only sender) learns that in place of `delivered`, from a settled row.

A message into a delegate starts a turn of its own after its report; that turn's `result` is
the delegate's reply. `Mailbox` stores it as a message from the delegate to its main session,
and delivers it as it delivers any message, so a reply never goes unread (F-77). A delegate's
turn has ended once the `result` that names its message's uuid is read: its report is the
result that names the brief's (or a resume's) uuid, its reply the result that names the
message's (F-79). A reply carries its result's subtype, so the main session can tell a turn
that failed (`error_during_execution`, `is_error`) from an answer. When the delegate's process
ends during a message's turn with no result, `Mailbox` stores a notice from the framework to
the main session in place of the reply: the message went in, and the delegate ended before it
answered. The notice is stored under the reply's key (the answered message), so one of a reply
or a notice goes in, never both. Its sender is `framework`, a name reserved for the framework
itself: no agent may hold it (F-81). `Stream`'s fold keeps each result on the messages it names, so a turn the delegate
starts by itself never replaces a reply or a report.

**Services** belong to the agent that started them. When the owner ends, its services end too,
unless it handed them on with `service_hand`, or started them with `keep: true`, which hands them
to the owner's parent when the owner ends. `keep` belongs to the service and stays with it when
it is handed. A service has a name, a host, a copy, a held process and a log. A claim on a
service holds its state as its held process (pid and start time) and its restart count. It
never holds a Claude Code session; agents are started as delegates. Any agent the tree holds may
start one (`Grants.may_start_service?`).

A service's end sends TERM to its process group, while its pid still has its recorded start
time, and KILL to the group after a grace (the call's timeout), as its own step: the end is
done only once the socket reads dead. A service runs in the foreground, in its own group: a
program that daemonizes itself into a new session leaves a process no end reaches, so it is
started in its foreground mode (a database with its no-daemon flag, say). A start that settles
after its owner has ended does not stay running: its settle reads the owner's end first, and
ends the service, or hands it to the owner's parent when it has `keep` (F-83).

## Intake

Claude Code posts each hook event once and never retries it, and a post that fails loses that
event (Claude Code 2.1.322; sources in `docs/build-notes/F-24.md`). `Intake.tla` models this
section.

- **Transport.** Each account's settings name an `http` hook for each event the framework
  reads: SessionStart, SessionEnd, Stop, StopFailure, SubagentStart, SubagentStop, Notification,
  UserPromptSubmit, PermissionRequest and PermissionDenied. Each hook posts to
  `http://127.0.0.1:<port>/hooks/<account>` on the framework's node, with a secret of the
  instance's in a header, and sets its own `timeout`. No program on the host takes part, so a
  held hook is one open request. PreToolUse and PostToolUse are not read: they carry every tool
  input, and `Transcripts` reads those.
- **Stored, then acknowledged.** `Intake` writes the event's row, then answers 200 with an empty
  body. A row is keyed by Claude Code's own ids where the event has them (`session_id` with
  `tool_use_id`, `prompt_id` or the start's `source`), and a second post of one key writes no
  second row. A part that reads rows moves its own row forward once, as `Delegates` does.
- **Duplicates.** Stop, Notification and SessionEnd carry no id of their own, so two identical
  posts read as two rows. No part counts those rows; each moves its own state forward once, so a
  duplicate is harmless.
- **Lost events.** A post while the framework is down is refused and lost. Each event a part
  needs has a reader that stands in: a Stop by the transcript's last reply, a SessionEnd by the
  pid, a SessionStart by the session file.
- **A held `PermissionRequest`.** `Intake` writes its row "held", with the request's id, and
  keeps the request open. `answer(agent, dialog, label)` names that id. The row says
  "answering" before the decision goes out as the response (`hookSpecificOutput.decision`:
  `{"behavior": "allow"}`, with `updatedPermissions` for "don't ask again", or `{"behavior":
  "deny", "message": …}`), then "answered". An answer to a row that is not "held" is refused. It
  never goes to another dialog of the agent, and never becomes typed keys.
- **Its deadline.** The hook's `timeout` is 600 s, and `Intake` answers an empty body, no
  decision, at 570 s and marks the row "expired". The dialog stays on the screen for a person.
  So no answer goes to a request Claude Code no longer reads.
- **A restart.** The open requests end with the node. Claude Code reads an error, and the dialog
  stays for a person. After the restart a row still "held" is "lost", and one "answering" is
  "unknown", since its answer may not have gone out; a view shows both. A dialog whose hold is
  lost is answered by a person, on the screen or through Remote Control.
- **A person first.** Claude Code shows the dialog while the hook runs, the first answer closes
  it, and a person's answer does not end the hook. An answer the hook carries after that is
  dropped. So `answer` returns `{:ok, :sent}`, and whether the dialog took it is read later: the
  tool ran, or the transcript shows the refusal.
- The hooks keep `onFailure` at "continue": a framework that is down never refuses a tool call.
  SessionEnd hooks share a budget of 1.5 s unless a hook's own `timeout` raises it, so that hook
  sets 10 s.

## State that never lags or lies

1. **Tables are the truth.** A PubSub message is a cue to re-read rows by id, never the data.
2. **One writer.** One process writes each table, and one `Control` per host writes panes.
3. **Unread is not empty.** A reader that has not read yet answers `:unread`, and a view says so,
   rather than "nothing runs".
4. **Total folds.** A source answers its rows and its problems together, so a read with one bad
   row still shows the others. Sorts and folds take nil timestamps and unknown shapes; one malformed row
   never crashes the tracker. A tracker that crashes at boot takes every view down with it.
   A stored row's shape changes across builds: a load fills a field a newer build added with
   its default and answers a field it does not know as a problem, so a row an earlier build
   wrote is never taken for a new one (a fold loaded as new would read its log again from the
   start).
5. **Liveness from hooks and processes**, never from what a pane shows. A process that left with
   no `SessionEnd` is found by its pid.
6. **Topics.** Each message names its topic, and a view reloads only what it reads, at most once a
   second.
7. **Offsets persist.** Each reader resumes where it stopped, rather than reading every log again
   at boot.
8. **Freshness is measured.** Each view shows the age of what it shows, and a check flags a
   reader that falls behind.

Each is a property test over generated event sequences: cues before, after and without their
rows, malformed rows, and restarts of readers. The `Tracker`'s fold is a pure function, so no
spec models it; one is written when a bug shows that an order of events needs it.

## The model

Specs live in `model/tla/`, checked with TLC:

- configurations are named `<Spec>_<Scenario>.cfg`;
- small constant sets and `Max*` counters bound the search;
- a `Break` constant's every value other than `"none"` is a named deliberate bug, and a `Break_*`
  configuration must find it (TLC exits 12 or 13), so each check is shown to catch something;
- a guard that cannot fail on its own, because another guard refuses the same steps, is defense
  in depth: it has no `Break` value, and the spec's header names it and the guard behind it;
- `bin/check-model` runs them; the fast configurations run in the test gate, and the slow ones
  by hand, each with its time recorded;
- each spec's header names the modules it models and what it leaves abstract.

Five specs, in this order, and beside them `Start.tla`: every session's start and resume, the
row written first, the worktree and its setup, the held process, the session file that may come
late, a socket that ends apart from its process, and the adoption after a restart (no held
process and no live socket without a row; a row ends at most once; a process is ended only by
its own pid and start time; every starting row settles, and so do a running or stopping row
whose process is gone, at the cues of the readers and the sampler; a busy
worktree is never reused or removed, a removed one was clean, and a process runs only in a
worktree on its branch whose setup finished).

1. **`Agent.tla`**: one host's tmux server, sessions, panes, dtach sockets, Claude Code processes
   and viewers. Events: the server dies and restarts, so pane ids restart at `%0`; a viewer dies
   or is reopened; a process exits or is killed; a socket goes stale; a write is asked.
   - Invariants: a write reaches only the pane of the session it names; an agent outlives its tmux
     server; a pane id kept from before a restart never reaches another agent's pane; no two
     processes hold one socket.
   - Liveness: a lost viewer is reopened; a held agent with no viewer is seen.
2. **`Move.tla`**: two accounts, a main session with background commands and delegates, a limit.
   Events: drain, turn end, copy, respawn, a late `SessionEnd`, the limit reached.
   - Invariants: a session runs on one account at a time; nothing that runs is lost; a late
     `SessionEnd` never ends the moved session.
   - Liveness: a drained main session moves.
   - The spec settles (F-5): the move also waits until no background command runs, since they
     end with the process; the transcript is copied after the old process exited; running
     delegates do not hold a move, and their reports wait for a live process of the main session; a
     `SessionEnd` ends the session only when it names the session's current process.
3. **`Delegate.tla`**: a main session, its delegates and restarts of the framework.
   - Invariants: each report is delivered once, and only to a running process of the main
     session whose turn has ended; a delegate ends only after its report is delivered; a report
     held while the main session moves survives a restart of the framework.
   - Liveness: every finished delegate's report arrives.
   - The spec settles (F-14): the row says "sending" before the report is typed, and after a
     restart a "sending" row is settled by reading the main session's transcript, never resent blind;
     a delegate's row leaves "running" once, by its Stop event or, when a restart lost it, its
     transcript's last reply; a kill after the last reply is a finish, not a kill; a second
     kill's report takes the same path as a finished delegate's.
   - The spec settles (F-59): the row is written before `Sessions` is called, and a start
     under way counts against the cap; after a restart a starting or resuming row is settled
     by `Sessions`' row of its call, never while that call runs; a resume is counted before it
     is asked; each process takes one turn's message, under the uuid the row holds.
4. **`Team.tla`**: two main sessions and their delegates, their messages, claims and
   services, and restarts of the framework. Events: a message is sent, a turn ends, an agent
   sticks, dies or ends, two fixes of one child, a service's owner ends.
   - Invariants: a message is delivered at most once and in order per sender, only into an
     ended turn, and only along an edge of the tree; at most one claim holds a child's state;
     only a parent fixes, and no agent fixes itself or stops a main session; a service has one
     owner, or none once it ended.
   - Liveness: a message to a live agent is delivered; a claim is released or its fix verified.
5. **`Stack.tla`**: worktrees, branches, a `gh stack` chain, rebases and squash merges.
   - Invariants: a worktree is on one branch; a layer lands only on its own checks; a rebase never
     loses a commit.

`Intake.tla` (F-24) models "Intake": events stored before they are acknowledged, a duplicate
stored once, and a held `PermissionRequest` answered at most once, by its hook, only on the
dialog it names, never after Claude Code's timeout and never by typed keys.

`Shell.tla` (F-35) models how a command's process group ends: a timeout, the caller's death
and the VM's death each end it (the last two with a reaper), a held process is never reached,
and a kill never reaches a reused id.

`Copy.tla` (F-70) models "Hosts"' copies, jobs and services: a job or service starts only on a
copy whose last sync completed after the run asked and that no sync has written since; a job's
answer is its real exit code or unknown, never a code it did not have; a fetch writes only the
paths it names, and only after the job ended; a job never runs past its timeout, and a service
whose owner ended without `keep` is ended; every call answers, and every job's row gets its end
from the host once the connection comes back. Its second part (F-72) adds the fetch's check
against edits made during the job, the host side of a sync under the copy's lock, and the
wrapper's end of a job's group: no edit is lost, one sync writes the copy at a time, and nothing
of a job writes in the copy once its end is read.

Code emits traces where it can, and a trace spec checks them; a trace cannot show a missing
guard, so the specs are also reviewed against the code.

## Open in Ghostty

It works like a link with a target, and the framework keeps no state for it. It uses Ghostty's
AppleScript (Ghostty 1.4.0, macOS):

1. Find the session's tmux clients: `tmux -L <server> list-clients -t =<session> -F
   '#{client_tty}'`.
2. If a Ghostty terminal has one of those ttys (Ghostty 1.4.0 terminals expose `tty`), `focus` it
   and `activate`: the press reuses that window.
3. Otherwise run `new window with configuration`, whose `command` is `tmux -L <server> attach -t
   =<session>`. This is the first press, or the first after the window closed, since closing it
   ends that tmux client.

Two other ways don't work:
- `ghostty +new-window` is not supported on macOS.
- `open -na Ghostty.app --args -e …` starts a separate Ghostty app, whose windows AppleScript
  cannot see.

Each failure is its own answer, and none falls back to another way:
- Automation not granted (Apple Events error -1743): a one-time macOS prompt for the
  framework's process.
- More than one Ghostty instance running.
- The session missing (`has-session` is checked first).
- A press from a phone, which opens the window on the Mac.

Ghostty's AppleScript is a preview, so the framework pins the Ghostty version it was tested
with. Every agent's session is on the workstation, so a window always attaches locally.

## Rules learned from running such a system

These come from running agents this way for weeks. Each states the rule and what went wrong
without it.

**tmux**
- Use a tmux server of the framework's own on each host, and never write to, kill or respawn on
  any other. Pane ids repeat between servers, so a stray server's `%3` can reach a real pane.
- Accept a pane target only in the form `%<n>`. tmux reads an empty target as the current pane:
  an empty lookup once typed a message into the supervising agent's own input box.
- Escape every argument: one ending in `;` ends the tmux command, and the next runs as a new one.
  Put a backslash before an argument's trailing `;`; tmux reads `\;` at the end as `;` and
  changes nothing else in the argument.
- Remove the socket file after `kill-server`. Name test servers with the test VM's pid, and remove
  a dead VM's servers by their exact socket path, never by a pattern.
- Claim per pane, not per session: one session can hold several Claude Code panes.
- Never find a process by its name. macOS cuts command names to 15 characters, and packagers
  rename binaries.
- Unset `window-size` after `resize-window`, or the window stays fixed.

**dtach**
- Run the agent under `dtach -n`, apart from tmux. When tmux died with the agents inside it,
  every agent ended mid-turn with its background commands.
- Build a held process's environment from nothing: `env -i` with an explicit list of what it
  keeps (such as `HOME`, `PATH`, `LANG`, and the account's settings). The same command works
  for an agent on the workstation and a job or service on any host, and nothing leaks in: an
  inherited `CLAUDECODE`, `CLAUDE_CODE_*` or `TMUX` made the agent act as if it ran inside
  another session, and over ssh the remote names cannot be listed ahead to remove one by one.
- dtach does not report the pid of the process it holds. A held main session's pid comes from its
  session file, which `Registry` reads, and a headless delegate's from the `pid` its wrapper
  writes before `exec`; whatever ends an agent by pid gets it there.
- Open a viewer one row short and then grow it: Claude Code doesn't redraw for a viewer that
  attaches at the same size.
- Reopen a lost viewer once per loss. A viewer that fails leaves the agent running.
- Reopen a lost viewer with the command of the part that holds its program, never a plain
  `dtach -a`: a headless delegate's viewer is a `tail -F` of its log, and attaching to its socket
  would show the wrong program. `Recoveries` asks `Sessions` (`viewer_argv/3`), and a socket with
  no row ends `failed{no_session}`. Each part that holds programs answers its own viewers'
  commands; when `Services` is built, the sampler's held row names the part that owns a socket,
  and `Recoveries` asks that part.
- Keep each host's dtach directory short, and bound the length of a session id used as a socket
  name: macOS cuts a socket path at 104 bytes, and a long temporary directory plus a session id
  can pass it.
- Every command `Shell` runs leads a process group of its own (OTP starts each port program with
  `setsid`). A timeout ends the group; with a `Shell.Reaper`, so do the caller's death and the
  VM's (`Shell.tla`). No process waits beside each command: the reaper's one watcher serves the
  whole VM. A process that must outlive the framework is held by `dtach -n`, whose `setsid`
  takes it out of the group. Without the group, a command's own children outlived its timeout
  and the VM. A wrapper per command cost 6.5 to 14 ms each (F-35). Never run a hold under
  anything that ends what a program leaves behind more widely than its group, such as a cgroup:
  it would end the held agent.
- A group is signaled only while the framework holds its command as running: `Shell` until it
  takes the exit, the reaper until `Shell` drops the group or the reaper's own KILL is sent. So a
  kill never reaches a reused id, with one assumption: within the half second between the
  reaper's TERM and KILL after a caller's death, the id is not reused. macOS and Linux hand out
  pids in order, so a reuse takes tens of thousands of forks. On a host with a small `pid_max`,
  the reaper sends TERM only.
- A child that ignores TERM and outlives its command (one that exited on its own, or on TERM
  within the grace) keeps running: once the exit is taken, nothing may signal the group. A
  program that must not leave such children is held as a service, not run.
- The embedding app starts each host's reaper before every process that runs commands with it, under
  one supervisor that restarts them together: the reaper's death ends every group it holds.
- A command that must outlive the framework but is not held, such as a delegate's claim
  ("Headless delegates"), runs with no reaper. Given one, it would end with the VM.

**Claude Code**
- Give each account a config directory of the framework's own, `<home>/accounts/<account>/claude`,
  and set `CLAUDE_CONFIG_DIR` to it at every launch, with every per-account setting. A session
  never falls back to `~/.claude`: a launch without an account's directory is refused. The
  person's own sessions, settings, hooks and plugins in `~/.claude` then never mix with the
  framework's, and two framework instances never share an account's state. Each account is
  logged in once in its own directory, by a person running `claude` with that directory; the
  framework shows the command. It never reads a credential, so whether an account is logged in
  is unknown until a session on it starts or fails. Setting `CLAUDE_CONFIG_DIR` to the default directory
  logs Claude Code out, and Remote Control otherwise follows each account's own default.
- The framework writes each account's settings, hooks and MCP servers into that account's
  directory itself, from data, so what an agent runs with is the framework's. It writes only
  files of its own that each launch names by flag, never a file Claude Code rewrites
  (`settings.json`, `.claude.json`, credentials).
- Remote Control starts only with an interactive session, so a headless delegate never has it;
  its settings still set `remoteControlAtStartup` to false, and a check against each pinned
  Claude Code release confirms a delegate starts with it off.
- An interactive session in a new directory meets the workspace trust dialog first, and until it
  is trusted Claude Code runs no status line. `Screen` answers that dialog by its label at a
  main session's start, and the settings never set `disableAllHooks`. A headless delegate skips it.
- A headless session draws no status line; its event log's `rate_limit_event` stands in
  ("Headless delegates").
- Every launch sets `DISABLE_AUTOUPDATER=1`, because devenv pins Claude Code and a session that
  updates itself runs a version the lock does not name.

## Allowance

`Usage` reads each account's weekly allowance from the JSON Claude Code hands the status line
command the framework writes into each account's settings (`rate_limits.seven_day`: the share
used and when it resets). It reads no credential and calls no API.

- A reading is current for 6 hours from when it was written. An older one counts as unknown for
  `pick` and for the move at 90 %, and a view shows its age. The reset rule below comes first:
  an idle account's reading is always old.
- A reading past its `resets_at` counts as 0 % used, marked as assumed, since the week started
  anew. A view shows it as assumed until a session's first answer on that account gives a real
  reading.
- `pick` answers the account with the most left among current and assumed readings, preferring a
  current one at the same share, or `refused{none_known}`. It never guesses past that.
- A check flags an account whose sessions have run past their first answer with no new reading.
- Answer dialogs through the held `PermissionRequest` hook, not by typing keys. Confirm a typed
  answer by its label, never by its position in the menu.
- Keep real screen fixtures for each Claude Code release, and fail with a named reason.
- Make every reader total over the shapes it reads: a prompt holding an image is a list, not a
  string.
- Don't trust `background_tasks`: it listed shells as running a day after they ended.
- Hooks are not a complete event stream: a refused permission fires no hook, and a hook's `cwd`
  doesn't follow `cd`.
- The MCP bridge reads stdin as binary and reconnects by itself: one character above code point
  255 once killed it silently.
- Don't use `--bg` sessions: they die with their daemon and fork on resume.

**Writes to panes**
- Each write ends sent, refused or unknown, and an unknown write is never resent: tmux exits 0
  for a key that reached nothing.
- A write checks that the pane's tag names the session the write names, and sends, in one tmux
  command: `if-shell -F -t <pane> '#{&&:#{==:#{pane_id},<pane>},#{==:#{@<tag>},<session>}}'
  'send-keys …'`. tmux checks the very pane it sends to, and a server that died in between sends
  nothing; a check followed by a separate send can reach another agent's pane that took the id
  after a restart. The check compares `#{pane_id}` with the target as well as the tag: for a
  pane id that does not exist, `if-shell` still runs, with an empty `#{pane_id}`, so the target
  alone does not prove the pane is there.
- Every tmux command that acts on a kept pane id, a key, a kill or a respawn, goes through that
  same one-command check, and a send's text and its Enter go out in one command, so the Enter
  never reaches a pane the text did not.
- Every pane the framework writes to is tagged with its session as it opens, in the command that
  opens it. An untagged pane is refused, not checked some other way: a check of the pane's
  process cannot run inside the tmux command that sends.
- Type only when the turn has ended and the input box is empty: two Ctrl-C presses exit Claude
  Code.
- An answer a hook holds goes to the hook, so a pane check that fails under load never stands in
  its way.

**Moves and limits**
- Drain before a limit, not after it: a move after the limit lost eleven background commands.
- At a hard limit, only the main session's own state counts: its turn and its background commands,
  not its delegates.
- Never edit a file Claude Code rewrites from memory: its next write erases the change.
- Stop background sessions by id with `claude stop`.

**Delegates**
- A report survives restarts, and a delegate ends only after its report is delivered.
- Resume a killed delegate once, and report a second kill.
- Count a main session's delegates as work still going for it.
- Never kill by pattern. Kill only processes you started, by pid.
- `git stash` is shared by every worktree of a repository, so delegates never use it.
- `git worktree add -b` at a taken path fails but leaves the new branch behind.
- A repository's hook can make `git worktree add` exit non-zero with the worktree added: read
  the worktree list for what an add did, never its exit status or the branch's existence.

**State for views**
- One malformed row (a nil timestamp) once crashed the tracker at every boot and took every
  view down: folds must be total.
- Liveness from hooks and pids: an agent waiting two hours on its subagents read idle on its
  screen.

**Tests**
- Keep command lookups and file calls off the VM's one file server. Looking up programs through
  a long `PATH` slowed every file call many times over and caused most suite timeouts under load.
- Wait on announced events, never fixed sleeps.
- Give each checkout its own database and each test VM its own temporary directory:
  `System.unique_integer/1` is unique only inside one VM.
- Liveness checks fail safe: a `ps` that fails to start under load must not count a live VM as
  dead.
- A test of a cleanup cleans only a directory of its own: one that swept the real tmux socket
  directory with fake liveness ended every other suite's servers.
- No test reaches the real Claude Code.
- A stand-in that starts processes writes their pids and sleeps a bounded time, so a failed run
  leaves nothing for long; a test ends what is left by those pids alone. Every process a test
  holds is such a stand-in, never a bare program, whose command line names no test directory.
  Leftover stand-ins once held every pseudo-terminal on the machine, and every `dtach` start
  failed in this repository and in other programs.
- A test's end seals what its stand-ins record before it ends them, so a stand-in that starts
  later exits at once: a start that answers before its stand-in records otherwise leaves one
  reading forever. A pid is signaled only while its command line names the directory it was
  recorded under, since pids wrap within minutes on a busy machine. The VM ends every recorded
  pid before it removes its directory, and `gate-test` fails, naming each, on any process still
  naming that directory.
- A file a started process may read (a script, a config, a fixture) is written whole and
  renamed into place, never rewritten in place: a stand-in rewritten while a start ran it was
  read empty, and the start exited at once.
- A test of what a viewer runs reads the pane's start command from its own tmux server: the
  `Tmux` contract answers what a pane is, not what it runs.

**Stacks and queues**
- Store the landing queue durably.
- Calibrate load gates on the machine that runs them.
- Judge each layer of a stack on its own checks, not only the top's.
- Never run monitoring code on the service's node, and make a restarted step adopt or end the
  work it started.

**Tokens**
- Enforce model routing: a large model reading logs is the most common waste.
- Never block on a question to the user.
- Find a red run's cause before running it again.
- Count delegates' tokens; the session cache doesn't include them.

## Order of the first units

1. **The repository and `Agent.tla`.** The project skeleton (Elixir, OTP, SQLite, devenv with
   tmux, dtach, claude, gh and the TLA+ tools), `bin/check-model`, and `Agent.tla` with its
   `Break_*` configurations, before any code it models.
2. **The base layer.** `Shell`, `Programs`, `Tmux` (contract, CLI and fake) and `Holder`, keyed by
   `{host, server}`, built against the model, with contract tests on a real tmux server per test
   VM.
3. **The workstation's agents.** `Registry`, `Control` and the `Tracker`'s core, with the state rules as
   property tests. `Control` came first, as its own unit.

Then `Delegate.tla` and `Delegates` (its start, finish and kill path are built). What is left:

4. **`Screen`**, from the fixtures a person captures, then `Delegates`' delivery of a report
   through `Control`'s checked write, and `run_delegate`.
5. **`Mover`**, against `Move.tla`.
6. **`Mains`**: one main session per project, on trunk in the project's checkout (the clone it
   makes once under the framework home), the pull
   after a landing, and `start_main`.
7. **`Team.tla`** (F-69; its message to an ended delegate becomes an answer to the sender, as
   "Agents working together" now says, before `Mailbox` is built), then `Grants`, `Mailbox` and
   the agent tools, by the tree's edges, with
   `agents()` read from the `Tracker`. Before the reply's next part: `Team.tla` models a
   delegate's reply and the notice of a turn with no result (F-79's new-1), then the fold's
   result per message, the reply's subtype and the notice (new-2, new-3, new-5).
8. **`Copy.tla`** (F-70), then its second part: the fetch's check against edits made during the
   job, the host-side lock of a sync, and the wrapper's end of a job's group (F-70's new-2,
   new-4 and new-7, folded into "Hosts"). Then `Copies`, `Jobs` and `Services` on any host,
   with forwarded ports.
9. **`Stack.tla`** and `Stacks`, then the LiveView components, and Ghostty.

The remote agents of the first plan (a session held on another host, its hooks forwarded back
over ssh, its session files and status line read there) are not built: agents run only on the
workstation. What is built stays keyed by host.
