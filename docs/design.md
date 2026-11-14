# coding_agent_framework: design

This is the plan the framework is built from. The order of its units is at the end; each unit
built so far has a build note in `docs/build-notes/`.

## What it is

A framework for running and supervising Claude Code agents on one or more machines and Claude
accounts. It gives a project:

- **parent sessions**: the main chats, one per project, which move from one account to another
  with one press, or on their own before a limit, and keep their name and Remote Control;
- **delegates**: full Claude Code sessions a parent starts through the framework, on the account
  with the most allowance left, each in its own git worktree and tmux session, which report back
  to their parent and may use Claude Code's own subagents to delegate further;
- **agents that work together**: any agent of a project can message the others, look at them,
  unstick them, and start, use and fix services, all through one strict set of tools;
- **tmux, dtach and git worktrees** working together, with every tmux object keyed by its host
  and server;
- **stacked pull requests** (`gh stack`) for the work of a parent and its delegates;
- **state for LiveView frontends** that never lags, drifts or shows what is not so;
- **a TLA+ model**, checked with TLC, of how tmux, dtach, Claude Code, worktrees and stacks fit
  together, written before the code it models.

A project declares itself as data: its repository, trunk, branch pattern, setup commands and the
checks its stacks must pass. The framework holds no project's policy.

## The words

- **Host**: a machine agents run on, reached locally or over ssh. Each host has one tmux server
  of the framework's, one dtach directory and one writer.
- **Server**: a tmux server, `tmux -L <name>`, always named with its host, `{host, server}`.
  Pane ids are unique only within one server, and a restarted server counts from `%0` again.
- **Account**: a Claude account, known by its own config directory under the framework's home.
- **Framework home**: one directory per framework instance, given by the host app, that holds
  everything the framework keeps on a host: each account's Claude config directory, the dtach
  directory and the SQLite files. The framework never reads or writes `~/.claude` or any config
  directory outside it.
- **Project**: a repository and its trunk, declared as data.
- **Parent session**: a project's main chat. It has Remote Control, keeps its name, is never
  archived, and moves between accounts with one press.
- **Delegate**: a Claude Code session a parent starts through the framework, held by dtach, with
  Remote Control off, in its own worktree. Inside it, Claude Code's own subagents delegate
  further; the framework counts them.
- **Service**: a program an agent starts through the framework and keeps running, such as a
  dev server or a database, held by dtach and owned by one agent at a time.
- **Claim**: an agent's hold on another agent or a service in one state, taken before a fix, so
  that only one fix of that state runs.
- **Viewer**: the tmux pane that shows a held agent (`dtach -a`). It can die, be reopened or be
  opened twice; the agent runs on.

## The parts

Each part is one OTP process or one pure module, with one job.

| Part | Job |
|---|---|
| `Hosts` | the hosts, how each is reached, and its shell |
| `Shell` | the only module that starts programs, locally or over ssh |
| `Programs` | the absolute path of tmux, dtach, claude, git, gh, sh, rm, kill, env, ps and cat on each host; no other part names a fixed path |
| `Accounts` | the Claude accounts, each with its own config directory `<home>/accounts/<account>/claude` |
| `Usage` | each account's weekly allowance, from what Claude Code hands its status line; picks the account with the most left ("Allowance") |
| `Tmux` | sessions, panes, tags, keys and viewers on one server; a contract with a CLI and a fake |
| `TmuxSampler` | samples each server's panes and each host's held sockets, and reports a held agent with no viewer |
| `Holder` | dtach: hold a process in a clean environment, open a viewer, list sockets and whether each lives |
| `ClaudeCLI` | the command line and environment of a session, per role and account |
| `Registry` | reads Claude Code's `<config>/sessions/*.json` per account and host, and so each held agent's pid |
| `Transcripts` | a session's transcript tail, its chats and its subagents |
| `Screen` | Claude Code's screen and dialogs, per Claude Code release, from real fixtures |
| `Intake` | hook events in; holds `PermissionRequest` hooks until answered |
| `Control` | the one writer per host: send, answer, interrupt, stop, respawn |
| `Sessions` | start, resume and stop held sessions on one host, with their viewers and rows; worktrees are a later part of it |
| `Mover` | drains a session and moves it between accounts |
| `Parents` | each project's parent session, and what it holds |
| `Delegates` | the delegate protocol: start, report, resume, end |
| `Stacks` | the worktrees and `gh stack` chains of a parent's work |
| `Tracker` | the state views read: the fold of every reader |
| `Recoveries` | detect a broken state, act once per state, verify; reopens a lost viewer, and so starts a host's tmux server again after it dies; ends an orphan's process, or one that did not exit after `/exit` within its stop's deadline, and only by the row's pid and start time (`Sessions` itself never kills) |
| `Mailbox` | messages between agents: stored, delivered once, in order per sender |
| `Services` | programs agents start and keep: held, owned, read, written to, restarted |
| `Grants` | decides whether a caller may act on a target; holds a fix's claim on it |
| `MCP` | the agent tools ("Agents working together"); each call is checked by `Grants` |
| `Ghostty` | opens or focuses a session's terminal window |

The LiveView side is a library of components over the `Tracker`, with one example app.

## Multiple hosts

Every key carries its host from the first part built:

- one tmux server, one dtach directory, one `Registry` reader and one `Control` per host, under
  a supervisor per host;
- a pane is `{host, server, server_start, pane_id}`, a held agent `{host, socket}`; the server's
  start (its start time and pid) is part of a pane's key, so a pane id never matches across a
  restart;
- a remote host is reached over ssh through `Shell`. The framework's node runs on one host and
  reads the others; a node per host is not needed for the first version;
- the framework keeps one ssh connection per remote host, and it also forwards that host's
  `127.0.0.1:<port>` back to the node's `Intake` (a reverse forward), so a remote session's hooks
  reach the node as a local one's do. While that connection is down, a remote host's hook events
  are lost, as during a restart, and the readers that stand in for them cover it;
- a reader of a whole host (held sockets, the `TmuxSampler`) has the `Tracker` scope
  `{host, :host}`, beside the `{host, account}` of a reader of one account;
- the `TmuxSampler` reads a host's panes and then its sockets, not in one instant, so a viewer
  opened between the two reads can show as lost for one sample. A recovery acts on a lost viewer
  only when two samples in a row agree. A pane with no tag, or one whose tag names another
  session than its own, is a broken state the sampler reports and `Recoveries` handles.

## Parent sessions

A parent holds, and a view shows:

- its account, host, tmux session and pane, and whether its MCP tools are connected;
- its worktrees, its own and each delegate's: branch, ahead and behind its trunk, unpushed
  commits, uncommitted files, and the pull request and stack each is part of;
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

Running delegates do not hold a move: each runs in its own process and survives the parent's
end. A delegate's report is held by the parent's session until a parent process runs whose turn
has ended, and the hold survives restarts of the framework.

Its chat is never archived.

## The delegate protocol

A parent calls `start_delegate(project, branch, model, brief)`. The framework:

1. checks the project, the branch name, the cap of delegates, and any worktree already at the
   path (reused only when clean, on the branch, and held by no live agent);
2. picks the account with the most allowance left;
3. adds the worktree and runs the project's declared setup in it, so a fresh worktree has its
   dependencies and build state before the first command;
4. starts `claude` held by dtach, with Remote Control off and the brief as its first prompt,
   tags its pane with the session, project and unit, and confirms it started;
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

A start writes its row first, as starting, with its worktree path and socket name, before it
acts. After a restart, a row still starting is adopted when its held process lives and its
session file names it; otherwise its worktree is removed when clean and held by no agent, and
the start answers `refused{interrupted}`. The adoption waits for the start's own deadline
before it decides, since a held process may only be slow to write its file; one with a live
socket and still no file then is kept as an orphan row for `Recoveries`, never left without a
row. The row keeps the start's deadline in wall-clock time, so a restart does not move it. A
read that fails decides nothing: the row stays as it was for the next read, and only a socket
read as dead makes it refused. A hold that answers unknown waits for the session file like any
other start. After a restart, a row still stopping is settled by its pid and start time: stopped
when gone, running otherwise. A stop whose deadline passes with its process alive leaves the row
stopping, with its deadline, and a restart does not set it back to running. `Recoveries` ends an
orphan's process, or one that did not exit after `/exit` within its stop's deadline, and only by
the row's pid and start time; `Sessions` itself never kills. A row whose start answered unknown
is read again at each `Registry` read until it is running or gone. A name whose row is unknown,
orphan, starting or stopping is not free for a new start: its process may live. A start is confirmed by the session file's `name`, which
`--name` sets; a check against each pinned Claude Code release confirms it, with the Remote
Control check. `Start.tla` models the start and its adoption, for every session's start and
resume; `Delegate.tla` leaves the start abstract and relies on it.

A part that waits on a reader within a call (a start waiting for its session file) reads it
again at a fixed interval until the call's deadline. That wait is part of the call's answer and
its timeout, not a hidden one. Everything else follows the reader's cue.

The answers are explicit: `started{…}` or `refused{reason}`, then `finished`, `killed` or
`late_report`. A delegate's subagents count for tokens and as work still going for its parent,
and one with no closing event ends after a bound.

## Agents working together

Every agent of a project, parent or delegate, can talk to the others, see how they are doing,
fix one that is stuck, and run services it needs. It does this only through the framework's
tools. The tools are strict in how they act and loose in what they let an agent do.

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
  log, and the target's parent sees every action on its agents.

**Loose in what:**
- Any agent of a project may act on any other agent and any service of the same project. One
  project's agents never reach another project's.
- A service is any program, with any arguments, run in the caller's worktree or another
  worktree of the project.

**Who may act** (`Grants`):
- Reading (look, transcript, logs, lists) is open within the project.
- Messages are open within the project.
- A fix (interrupt, answer, respawn, resume, stop) takes a claim on the target first. The claim
  is for the target's current state, the way `Recoveries` acts once per state. A second fixer
  of the same state is refused with `{:claimed, by}`. Two agents never fight over one stuck
  agent, and a fix that did not help shows as the same state still claimed.
- No agent may stop or move a parent session. Only a person moves a parent, with one press.
- An agent may not fix itself. A stuck agent cannot be relied on to see that it is stuck.

**The tools:**

| Tool | What it does |
|---|---|
| `agents()` | the project's agents: name, role, parent, state (working, waiting, idle, stuck, gone), and what it waits on |
| `message(to, text)` | stores a message and delivers it to the target when its turn has ended; answers `queued{id}`, then the sender learns `delivered` |
| `look(agent)` | the agent's screen as text, its dialog if one is open, and its last transcript lines |
| `transcript(agent, from)` | the agent's transcript from an offset |
| `interrupt(agent)` | one `C-c` to the agent's pane, under a claim |
| `answer(agent, dialog, label)` | answers an open dialog through its held hook, by label, under a claim |
| `respawn(agent)` / `resume(agent)` | starts a dead or wedged agent again with `--resume`, once per state, under a claim |
| `stop(agent)` | ends a delegate after its report is delivered, under a claim |
| `service_start(name, argv, opts)` | holds `argv` by dtach in a worktree, with a viewer in a tmux session (the caller's own or a named one) and its output in a log |
| `services()` | the project's services: name, owner, state, viewer, restarts |
| `service_logs(name, from)` | the service's output from an offset |
| `service_send(name, input)` | text or keys to the service, through `Control`'s checked write |
| `service_wait(name, until, timeout)` | waits for a line matching a pattern, a port that listens, or an exit; answers which, or `{:unknown, :timeout}` |
| `service_restart(name)` / `service_stop(name)` | restarts or ends a service, under a claim |
| `ask(question)` | asks a person, without blocking |
| `start_delegate(…)` | as in "The delegate protocol" |
| `reload()` | reloads the caller's own tools |

**Messages** are stored before they are sent, so a restart of the framework does not lose
them. One goes in as a turn only when the target's turn has ended and its input box is empty,
the same rule as any write. A message to a busy agent waits in order. A message to a gone agent
is refused. A message to a delegate that has ended goes to its parent instead, and says so.

**Services** belong to the agent that started them. When the owner ends, its services end too,
unless it handed them to another agent with `service_start(…, keep: true)` or to its parent. Any
agent of the project may read, wait on, write to and fix a service. A service has a name, a
worktree, a held process and a log. It never holds a Claude Code session; agents are started as
delegates.

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
row written first, the held process, the session file that may come late, and the adoption
after a restart (no held process without a row; a row ends at most once; a process is ended
only by its own pid and start time; every starting row settles).

1. **`Agent.tla`**: one host's tmux server, sessions, panes, dtach sockets, Claude Code processes
   and viewers. Events: the server dies and restarts, so pane ids restart at `%0`; a viewer dies
   or is reopened; a process exits or is killed; a socket goes stale; a write is asked.
   - Invariants: a write reaches only the pane of the session it names; an agent outlives its tmux
     server; a pane id kept from before a restart never reaches another agent's pane; no two
     processes hold one socket.
   - Liveness: a lost viewer is reopened; a held agent with no viewer is seen.
2. **`Move.tla`**: two accounts, a parent with background commands and delegates, a limit.
   Events: drain, turn end, copy, respawn, a late `SessionEnd`, the limit reached.
   - Invariants: a session runs on one account at a time; nothing that runs is lost; a late
     `SessionEnd` never ends the moved session.
   - Liveness: a drained parent moves.
   - The spec settles (F-5): the move also waits until no background command runs, since they
     end with the process; the transcript is copied after the old process exited; running
     delegates do not hold a move, and their reports wait for a live parent process; a
     `SessionEnd` ends the session only when it names the session's current process.
3. **`Delegate.tla`**: a parent, its delegates and restarts of the framework.
   - Invariants: each report is delivered once, and only to a running parent process whose
     turn has ended; a delegate ends only after its report is delivered; a report held while
     the parent moves survives a restart of the framework.
   - Liveness: every finished delegate's report arrives.
   - The spec settles (F-14): the row says "sending" before the report is typed, and after a
     restart a "sending" row is settled by reading the parent's transcript, never resent blind;
     a delegate's row leaves "running" once, by its Stop event or, when a restart lost it, its
     transcript's last reply; a kill after the last reply is a finish, not a kill; a second
     kill's report takes the same path as a finished delegate's.
4. **`Team.tla`**: agents of one project, their messages, claims and services, and restarts of
   the framework. Events: a message is sent, a turn ends, an agent sticks, dies or ends, two
   agents try to fix one target, a service's owner ends.
   - Invariants: a message is delivered at most once and in order per sender, and only into an
     ended turn; at most one claim holds a target's state; no agent fixes itself or stops a
     parent; no call reaches another project; a service has one owner, or none once it ended.
   - Liveness: a message to a live agent is delivered; a claim is released or its fix verified.
5. **`Stack.tla`**: worktrees, branches, a `gh stack` chain, rebases and squash merges.
   - Invariants: a worktree is on one branch; a layer lands only on its own checks; a rebase never
     loses a commit.

`Intake.tla` (F-24) models "Intake": events stored before they are acknowledged, a duplicate
stored once, and a held `PermissionRequest` answered at most once, by its hook, only on the
dialog it names, never after Claude Code's timeout and never by typed keys.

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
with. A session on another host opens as `ssh -t <host> tmux -L <server> attach -t =<session>`.

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
  locally and over ssh, and nothing leaks in: an inherited `CLAUDECODE`, `CLAUDE_CODE_*` or
  `TMUX` made the agent act as if it ran inside another session, and over ssh the remote names
  cannot be listed ahead to remove one by one.
- dtach does not report the pid of the process it holds. A held agent's pid comes from its
  session file, which `Registry` reads; whatever ends an agent by pid gets it there.
- Open a viewer one row short and then grow it: Claude Code doesn't redraw for a viewer that
  attaches at the same size.
- Reopen a lost viewer once per loss. A viewer that fails leaves the agent running.
- Keep each host's dtach directory short, and bound the length of a session id used as a socket
  name: macOS cuts a socket path at 104 bytes, and a long temporary directory plus a session id
  can pass it.

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
  directory itself, from data, so what an agent runs with is the framework's and is the same on
  every host. It writes only files of its own that each launch names by flag, never a file
  Claude Code rewrites (`settings.json`, `.claude.json`, credentials). On a remote host it
  writes them through `Shell`.
- Claude Code has no flag that turns Remote Control off; a delegate's settings file sets
  `remoteControlAtStartup` to false. A check against each pinned Claude Code release confirms a
  delegate starts with it off.
- A session in a new worktree meets the workspace trust dialog first, and until it is trusted
  Claude Code runs no status line. `Screen` answers that dialog by its label at a start, and the
  settings never set `disableAllHooks`.

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
- On a remote host, the status line's file is read through `Shell`, as `Registry` reads.
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
- At a hard limit, only the parent's own state counts: its turn and its background commands,
  not its delegates.
- Never edit a file Claude Code rewrites from memory: its next write erases the change.
- Stop background sessions by id with `claude stop`.

**Delegates**
- A report survives restarts, and a delegate ends only after its report is delivered.
- Resume a killed delegate once, and report a second kill.
- Count a parent's delegates as work still going for it.
- Never kill by pattern. Kill only processes you started, by pid.
- `git stash` is shared by every worktree of a repository, so delegates never use it.
- `git worktree add -b` at a taken path fails but leaves the new branch behind.

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
2. **The host layer.** `Shell`, `Programs`, `Tmux` (contract, CLI and fake) and `Holder`, keyed by
   `{host, server}`, built against the model, with contract tests on a real tmux server per test
   VM.
3. **One host's agents.** `Registry`, `Control` and the `Tracker`'s core, with the state rules as
   property tests. `Control` came first, as its own unit.

Then `Move.tla` and `Mover`, `Delegate.tla` and `Delegates`, `Team.tla` with `Grants`,
`Mailbox`, `Services` and the agent tools, `Stack.tla` and `Stacks`, the LiveView components,
and Ghostty.
