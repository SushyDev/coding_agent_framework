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
- **Main session**: a top agent of a project, named by the app that starts it; a project may
  have several, one per piece of work the app runs (an epic, say). It runs Claude Code's terminal
  interface with Remote Control, because a person works in it. It sits on the project's trunk
  and does no work there itself: work happens in worktrees, and once merged, the main session
  pulls trunk, so it always holds the project's latest trunk. It is never archived.
- **Delegate**: an agent a main session starts through the framework, on any account, in its
  own worktree. By default it runs headless: it reads JSON messages on stdin and writes JSON
  events on stdout, and nothing reads its screen. Started `interactive: true`, it runs Claude
  Code's terminal interface as a main session does, held the same way, so a person can attach
  and type, and what the framework hands it goes in as a main session's does. It acts like a subagent
  of its main session: it gets a brief and gives its reports.
- **Operator**: a person or the app acting on agents from outside the tree (from a view, say).
  It acts through the same checks and claims as a parent, as a parent of every main session and
  so of every agent, and every act names it as the actor.
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
- **Claim**: an actor's hold on one of its targets (a child, a service, a broken state), in one
  state, taken before an act, so that only one act on that state runs. Every claim is a row in
  `Acts`, whoever the actor: an agent's fix, the operator's act, a recovery.
- **Delivery**: text the framework hands an agent (a message, a reply, a notice, a report, the
  app's word), one row in `Mailbox`, marked before it goes and settled from evidence after. How
  it goes in is its **transport**: a `Stream` line, the waiter's answer, the `Inlet`'s checked
  write, or the answer of a waiting `run_delegate`.
- **Hold**: a request held open with a deadline, answered exactly once by a named decider, and
  settled when its holder dies. `Intake` keeps four kinds.

## The parts

Each part is one OTP process or one pure module, with one job, and is the one writer of the
table it owns. A part reads another part's state only through that part's functions, never by
opening its table, and a list of statuses (which statuses hold an agent, which have ended) lives
once, in the part that owns them. So a status renamed in one part fails at compile time there,
not at run time in three others.

**Remodel.** The table below is the target shape F-115 proposed and F-116 took. The code reaches
it through units R1 to R12 ("Order of the first units"); until a unit lands, its part runs in
the shape it was built in (F-115's build note says where each one is today). Each later unit is
built on the target shape: a new hold is a kind of `Intake`'s one hold, a new way into a session
is a transport of `Mailbox`, a new act is a row kind of `Acts`, and a new reading of a session is
a function of `Sessions`.

The repository is a Mix umbrella with one OTP application per part (or per small set of parts
that only make sense together), under `apps/`. An app declares, directly, every app it uses and only those; `gate-deps` checks it
(Elixir alone accepts a module from any app in the dependency tree), a use outside the tree does
not compile, and the layers stay one way: base (`caf_shell`,
`caf_tmux`, `caf_holder` with `Holder.Process`, `caf_store` with `Reader`, `caf_cues`), then
readers and writers (`caf_registry`, `caf_transcripts`, `caf_usage`, `caf_accounts`, `caf_cli`,
`caf_screen`, `caf_inlet`, `caf_stream`, `caf_intake`, `caf_sampler`), then `caf_sessions`,
then `caf_tracker` (its sources made from the readers' table metadata) and `caf_recoveries`,
then the parts built later. The remodel adds `caf_store` (R1) and `caf_cues` (R11), and
`caf_control` becomes `caf_inlet` (R8), which uses `caf_screen`'s pure reading. Shared test aids that use no part above `caf_shell` live in `caf_test`,
used only in tests; setup a part's tests share with a higher app's tests lives in that part's
`test/support/`, compiled only for tests. A test double is a test aid: it lives in
`test/support/` or `caf_test`, never in a library's `lib/` (`Tmux.Fake` moves in R1 or R2). Module names stay `CodingAgentFramework.*`. Each app
has its own tests and docs; a test of a Tracker source, or of two parts together, belongs to the
higher app; the
model (`model/tla/`), `bin/check-model`, devenv and the design stay at the root, and the gates
run across every app. No app starts a process of its own: the embedding app's supervision tree
starts each part.

The umbrella is how the framework is developed: each part's app declares what it uses, and the
gates keep the layers one way. It is used as one package, `coding_agent_framework`: one Mix
project that compiles every part as one OTP app, by a git tag first and from Hex later. It runs
on the Elixir and OTP versions it declares and tests; a version it needs is named with why.

| Part | Job | Owns |
|---|---|---|
| `Hosts` | the workstation and the other hosts, how each is reached, and its shell | — |
| `Shell` | the only module that starts programs, locally or over ssh, each leading a process group of its own, which a timeout ends | — |
| `Shell.Reaper` | one per host: ends a running command's group when its caller dies first or the VM dies | — |
| `Programs` | the absolute path of tmux, dtach, claude, git, gh, rsync, ssh, flock, sh, sleep, rm, kill, env, ps, cat, tail and curl (the waiter hook) on each host, given (from devenv, as the framework's own development and gates use) or looked up on the host's `PATH`, each checked against its supported versions at start with a clear error per one missing or out of range; no other part names a fixed path | — |
| `Store` | a pure module over SQLite: open with WAL and a busy timeout, the schema and its added columns, `query`, `rows_by_id`, `update`, upsert, a reads row, and a load that fills a newer build's fields with their defaults; every table of the framework is opened through it | no table |
| `Reader` | a pure module beside `Store`: the loop every reader runs (read on an interval or a call, diff against what it wrote, write with a reads row, cue), and a `Tracker` source made from the reader's table metadata | no table; each reader its own |
| `Cues` | one per instance: each part declares the topics it reads, and `Cues` hands each cue to the `Tracker` and to every part that declared its topic; the order in which the system settles is the library's, not the app's | no table |
| `Accounts` | the Claude accounts, each with its own config directory `<home>/accounts/<account>/claude` | — |
| `Usage` | each account's weekly allowance, from what Claude Code hands its status line; picks the account with the most left ("Allowance"); a `Reader` | its readings |
| `Tmux` | sessions, panes, tags, keys and viewers on one server, and the one-command check of every write to a pane; a contract with a CLI (its fake is a test aid) | — |
| `TmuxSampler` | samples each server's panes and each host's held sockets, reports a held agent with no viewer, and cues when a held socket goes away; a `Reader` | `tmux_samples` |
| `Holder` | dtach: hold a process in a clean environment, open a viewer, list sockets and whether each lives | — |
| `Holder.Process` | a held program's record: pid, start time and socket, read in one batch; "dead" as the pid gone and the socket absent or stale; an end by TERM, then KILL, only by the record's pid and start time. Every part that holds a program keeps this record on its own row | no table |
| `ClaudeCLI` | the command line and environment of a session, per role and account, and the paths of a headless session's stream directory | — |
| `Registry` | one per host, over every account the framework holds: reads Claude Code's `<config>/sessions/*.json`, and so each held agent's pid and its session file's `status`; a `Reader` | `registry_sessions` |
| `Transcripts` | one per host, over every account: a session's transcript tail, its chats and its subagents, and whether a transcript holds a delivery's line; a `Reader` | `transcripts_sessions` |
| `Screen` | a pure reading of a main session's screen and dialogs, per Claude Code release, from real fixtures captured with a script: the trust dialog, typed commands and their result lines, the box before a typed write | — |
| `Inlet` | the checked typed write into an interactive session with no waiter: `Screen`'s box check, then `Tmux`'s one-command check, one per host; and the typed commands a session's start or a tool needs (the trust dialog, `/mcp reconnect`, the interrupt key). It is one transport of `Mailbox` | no table |
| `Stream` | a headless session's transport: a FIFO per process, a spool removed as the line's claim, the event log read from an offset, and its `can_use_tool` requests. Its fold of the log (each message's replay, each result) is evidence `Mailbox` and `Sessions` read; it keeps no delivery state of its own | `stream_delegates` |
| `Intake` | hook events in; one hold, of four kinds: `permission` (a person's or an agent's `answer`), `tool` (`PreToolUse`, the app's callback), `stop` (`Stop` held for the app's callback) and `waiter` (a main session's waiting Stop hook, answered with `Mailbox`'s due text) | `intake_events` |
| `Sessions` | the agent row: one row per agent, main session or delegate, with its kind, parent, project, account, launch options, held process and status; start, resume, and stop by SIGTERM once idle; the tree as one function of its rows; each session's turn state as one function per kind of session, from its evidence | `agents` |
| `Mover` | drains a session and moves it between accounts; its phase is a field of the agent row | — |
| `Mains` | each project's main sessions, as agent rows of kind `main`; the pull after a landing, and the start of one for a project that has none | — |
| `Delegates` | the delegate protocol only: its checks, the cap, the account pick, resume once, report a second kill; it hands the report to `Mailbox` as the reply to the brief | `delegates`: branch, brief uuid, resumes, whether the report was taken |
| `Mailbox` | every delivery: messages, replies, notices, reports and the app's word, stored, delivered once, in order per sender and addressee; one mark and settle, with the transport the target's kind chooses | `messages` |
| `Acts` | one ledger of acts: an actor's act on a target's state, written before it acts, once per state, settled after, closed as interrupted when a restart cut it, with a cue. Fixes, the operator's acts, recoveries, kills, resumes, starts and raised errors are its rows, and the fault ledger is a query of it | `acts` |
| `Stacks` | the worktrees and `gh stack` chains of a main session's work | — |
| `Copies` | a host's copy of each worktree, brought in step by rsync before each job or service, and removed with the worktree | `copies` |
| `Jobs` | one-off commands on a host, in a copy: held, logged, ended by their exit or their timeout | `jobs` |
| `Services` | programs agents start and keep on a host, in a copy: held, owned, read, written to, restarted, with ports forwarded to the workstation; the forward is a second `Holder.Process` record of the service | `services` |
| `Tracker` | the state views read: the fold of every reader | — |
| `Recoveries` | detect a broken state, take its act in `Acts`, act once per state, verify; reopens a lost viewer, and so starts a host's tmux server again after it dies; ends an orphan's process, or one that did not exit after its end within its stop's deadline, by `Holder.Process` (`Sessions` itself never kills) | no table of its own |
| `Grants` | decides whether a caller may act on a target, by the edges of `Sessions`' tree; a pure module, handed the tree's function | — |
| `MCP` | the agent tools ("Agents working together"); each call is checked by `Grants` once, and each fix takes its act in `Acts` | `mcp_tokens`, `mcp_calls` |
| `Ghostty` | opens or focuses a session's terminal window | — |

The LiveView side is a library of components over the `Tracker`, with one example app.

`caf_example` is the embedding app the example grows from (F-102): its configuration is data
(the framework home, the workstation, other hosts, accounts, projects, ports); one supervision
tree starts every part in the order each needs, the reaper first, and one `Cues` per instance;
it makes the hook secret and the `start_id` of `Acts` once per start. It routes no cue by hand:
each part declares the topics it reads, `Cues` routes them, and `Jobs` and `Services` cue like
every other part, so no ticker sends a made-up topic (R11). It opens no part's table: the tree,
an agent's worktree and the agent a hook names are `Sessions`' functions (R9). What it still
wires that the parts do not offer (F-102's findings): until `Mains`, it declares each project's
main session, written as an agent row of kind `main` with no parent, so a main session can
start its first delegate; `Delegates` launches each delegate with its own MCP config, from a
function of the agent's name the app gives it (`MCP.issue/2`); a job's late end goes to its
caller through `Mailbox` as a message from `framework`, once per job, the caller read from
`MCP`'s call log by the job's id (from the file: `Jobs` hands the ends it owes as it starts,
before `MCP`); and when a delegate's end is seen, `Services.owner_ended/3` runs on the cue of
the agent row's end. `Stream` and `Transcripts` are read on an interval, as `Registry` is, so a
delegate's `result` is read without waiting for another cue; that interval is the `Reader`'s
(R2). A delegate ended after its report (by `stop`) is `ended` on its agent row, so the cue
shows it and its services end (F-103's new-2). `on_late_end` answers `:ok` or `{:unknown,
reason}`, and on the second the job stays owed for the next cue: keeping an end never needs a
crash (new-1). A delegate's reply to a message from `framework` goes to its main session, as
any reply does (new-4).

**How the flows go through the parts** (F-115):

- **A session's life.** `Sessions` writes the agent row first (`starting`), holds the program,
  and settles it by `Holder.Process` and the session file or the stream's init: `running`. Its
  turn state is one function per kind: a headless session's from `Stream`'s fold, an
  interactive one's from the session file's `status` and `Intake`'s waiter. Its end is SIGTERM
  once idle (or `end_session` for a headless one), and it is `stopped` once the process is gone
  and the socket dead. `Recoveries` ends an orphan by the same record, under its act in `Acts`.
  A move is a phase on the same row.
- **A delivery.** Anything for an agent is a row in `Mailbox`. `Mailbox` picks the oldest due
  row per addressee, marks it `sending` with its transport, and hands it on: a `Stream` line
  for a headless session, the waiter's answer for an interactive one with a waiter, the
  `Inlet`'s checked write for one with none, or the answer of a waiting `run_delegate`
  ("Delivery"). Refused undoes the mark; unknown keeps it for the evidence. The row is the only
  mark: `Stream` keeps its line's claim, which is transport, and no message state; `Delegates`
  keeps no delivery state.
- **A hook.** `Intake` writes the event, then answers, as before. A hook that waits is a hold:
  a key, a deadline under the hook's timeout, a named decider, exactly one response, and a
  settle when the holder or its connection dies (`lost` or `unknown` for a hold with a row,
  nothing for the others). The four kinds differ only in their decider, deadline and response.
- **An act.** Every fix, recovery, kill, resume, start and raised error is a row in `Acts`,
  `{actor, target, state, act, start_id, status, outcome}`, written before it acts, refused for
  a state already acted on, and `interrupted` when a restart cut it.

## Hosts

Agents run only on the workstation; other hosts run jobs and services, the way an editor that
edits files over ssh keeps the editor local and runs commands remotely. Every key still carries
its host, as it has since the first part built, so the workstation is one host among them:

- the workstation has the framework's node, its one tmux server, its dtach directory for agents,
  one `Registry` and one `Transcripts` over every account, and its `Inlet`; every agent's row,
  pane and socket is on it;
- a pane is `{host, server, server_start, pane_id}`, a held process `{host, socket}`; the
  server's start (its start time and pid) is part of a pane's key, so a pane id never matches
  across a restart;
- another host is reached over ssh through `Shell`, one connection per host, and has a
  directory of the framework's own (its copies, its dtach directory for services, and its
  logs). Nothing of Claude Code runs there, so no hook, session file or transcript is read from
  it;
- a job or service runs in a copy of the worktree it names. Before a job or a service starts,
  `Copies` brings the copy in step with the worktree by rsync, over every file git does not
  ignore, edits not yet committed included; it compares a file by its size and its modification
  time to the nanosecond, not to the second, because an edit of the same size made in the same
  second as the copy's last sync of that file would otherwise be skipped (F-85, new-1); build
  outputs stay in the copy between runs. The
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
- input reaches a held service by dtach's push mode, `dtach -p <socket>`, run on its host
  through `Shell`, the same on the workstation: the input is an argument of one host shell,
  which reads the program's pid and start time, as an end does, and pushes the input only while
  they are still the row's, so input never reaches a program a restart put in its place. A
  service has no turn and no input box: "checked" means the row is `running`, the caller is its
  owner or the owner's parent, and that pid check. The input is bytes for the program's
  terminal: a newline is Enter, `\x03` is ctrl-C (no NUL, which an argument cannot carry, and at
  most 64 KiB). It answers `sent` once dtach has handed every byte to the terminal; `refused`
  when the row, the pid or the socket says the program is not the one held, and nothing went
  in; `unknown` on a drop or a timeout, when some, all or none of it may have gone in. It is
  never resent: the caller reads the log before it sends again (F-89);
- a wait on a service polls its host until the service's log has a line that matches a
  pattern, or a port listens on the host's `127.0.0.1` (`nc -z`, a program of the host's that
  only a port wait needs), and its exit, the socket read dead, ends every wait: the log is read
  once more after that read, so a line the program wrote before it ended is still found. A read
  that failed is no answer; the next round reads again, and a wait whose last read failed answers
  `{:unknown, :dropped}` at its timeout, as a job does, in place of `{:unknown, :timeout}`;
- a forward is an `ssh -N -L 127.0.0.1:<local>:127.0.0.1:<port>` with `ExitOnForwardFailure`,
  held by dtach on the workstation in the services' directory there, named for its service, so
  a restart of the framework does not drop it and the `TmuxSampler` reads its socket as it reads
  every held socket. `<local>` is the service's `forward:` port unless the caller names another;
  a local port that is taken fails the forward's start, which ends the service's start as
  refused, and the row reports `{port, local}`. The service's end ends its forward first and is
  done only once both sockets read dead; a forward whose socket reads dead while its service
  runs is a loss `Recoveries` opens again once per state, the state being the service's held
  process and the forward's open count. A workstation service needs no forward. `Copy.tla`
  models the forward beside its service (F-91), and settles: a forward is open only when its own
  ssh holds the local port, read from that process, never from a port that listens (another
  program's listener would read the same); the service's start answers only once its forward is
  open, and a forward that fails at its start ends the service, so no service runs without the
  forward it asked for; a reopen acts only while the state it claimed (the service's current
  start and the forward's open count) is still the row's, never on "the service runs"; a reopen
  that fails or that a restart cut off leaves the forward `failed` for a person, and nothing
  opens it again until the service's next start;
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

A project may have several main sessions, each named by the app, with the project as one of
its fields. Each runs in the project's checkout, the framework's own
clone under `<home>/checkouts/<project>`, made once from the project's repository, on trunk. It
changes nothing there: its delegates work in worktrees, their branches land into trunk through
stacks, and after each landing the framework pulls trunk in that checkout (fast-forward only,
and only while the checkout is clean; anything else is a state a person sees). So each main
session always holds the project's latest trunk. Several main sessions of one project share the
checkout and change nothing in it; each delegate's parent says whose work it is. Two main
sessions can still brief work on the same files: their briefs keep apart, and stacks and reviews
catch what does not.

A person or the app starts a main session, and a main session can start one with
`start_main(project, name, brief)` for a declared project; a name in use is refused with
`{:refused, {:running, name}}`, as is the reserved name `framework`. The new main session's
brief is its first message.

A main session holds, and a view shows:

- its account, tmux session and pane, and whether its MCP tools are connected;
- its checkout: trunk, ahead and behind its remote, and whether it is clean;
- each delegate's worktree: branch, ahead and behind trunk, unpushed commits, uncommitted
  files, and the pull request and stack each is part of;
- the statuses of its delegates and their subagents, its open questions and its stack's checks;
- the command that attaches to its tmux session, and Open in Ghostty.

**Moving it** starts on its own when the account reaches 90 % of its weekly allowance, or with
one press at any level. It goes to the account with the most allowance left:
1. Drain: no new delegates, background commands or tool calls start.
2. Wait until no background command runs and no `run_delegate` call of the session is under
   way (its report would otherwise be written to a process the move ends). This is read after
   the drain began, so nothing can start after it; a background command is a child of the session's process and ends with it.
3. End the session by SIGTERM to its pid, by the row's pid and start time, once its session
   file says `idle` (F-114). Claude Code's shutdown keeps the transcript and fires SessionEnd
   with reason `other`. A prompt through Remote Control that starts a turn between the read
   and the signal is cut off, and what it wrote is kept by the copy in step 5; `Move.tla`
   models this before `Mover` is built.
4. Wait for the old process to exit.
5. Copy the transcript to the other account. Copying after the exit keeps a turn that a prompt
   through Remote Control started before the end.
6. Resume it there with `--resume`, its name and Remote Control on.
7. Ignore the old process's `SessionEnd` that arrives after the new one started.

Running delegates, jobs and services do not hold a move: each runs in its own process and
survives the main session's end. A delegate's report is held in `Mailbox` for its main session until a
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
5. hands its last message to `Mailbox` when it stops, as the reply to the brief's uuid. When a
   restart lost the stop event, it hands on the transcript's last reply instead, and ends the
   delegate only after the delivery settled. The delegate's row moves from running to finished
   once, by its Stop event or by its transcript's last reply, whichever comes first; a later
   one is ignored. The report is then a delivery like any other ("Delivery"): to the parent's
   waiting Stop hook, held while no waiter is connected, its row in `Mailbox` marked sending
   before the waiter is answered and, after a restart, settled from the parent's transcript once
   the parent's turn that took it has ended: delivered if the report is there, due again if
   not. Each report carries a mark of its own that the transcript shows. `Delegates` keeps only
   whether the report was taken;
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
- A delegate's life (running, finished, failed, ended) is its agent row's status in `Sessions`,
  and which statuses hold the cap is one function there (R9). `Delegates`' own row keeps the
  marks of its own calls (starting, resuming) and its own facts: branch, brief uuid, resumes,
  and whether the report was taken. It reads `Sessions`' state only through `Sessions`'
  functions.
- A main session is an agent row of kind `main` with no parent, written by the app until
  `Mains`, and the delegate's agent row names its parent. `Grants` reads the tree from those
  rows, so a delegate can name only one parent (F-73's new-3 and new-4 end with R9).
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
- A waiting `run_delegate` is one transport of the report's delivery (R7). The report is taken
  for the call in the same step of `Mailbox` that marks its row, and only before the call's
  deadline (on the node's clock, as the caller set it): the row is then `sending` by the call,
  never due for a waiter, so it is not also delivered another way. Past the deadline the call
  answers `{:unknown, :timeout}` and the report is due as any other (F-92). The row stays
  `sending` by the call until the endpoint has written the answer to the agent, then
  `delivered`; a write that fails makes it due again, a restart finds it `sending` by the call
  and makes it due again, and so does the end of the process that waits for it, which `Mailbox`
  watches, so it is delivered by the parent's waiter instead. This was the report's own
  `answering` mark in `Delegates`' row (F-92 to F-97); the rule is the same, kept once. A write fails only on a
  connection the client reset: one it closed normally still takes the write (F-95's new-1). So
  what keeps the client from giving up first is the cap: `run_delegate`'s `timeout` stays under
  both limits Claude Code keeps for a remote MCP call, the request's (`MCP_TOOL_TIMEOUT`) and the
  idle one for a call with no progress (`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`, 300 s unless set),
  which `ClaudeCLI` sets at launch from one tool timeout (F-92's new-2, F-95's new-2). A report a
  client dropped anyway stays in its row and in the call log, where the read tools find it.
  The client also goes when the main session's process ends during the call, by a move or an
  exit, and a write to it can still succeed (F-97's new-1). So the row is `delivered` only if
  the process that made the call (by pid and start time, as `Sessions` holds it) still runs
  after the write; otherwise it is due again and goes by the parent's waiter. A move's drain waits
  for no `run_delegate` call of the session to be under way.
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
orphan's process, or one that did not exit after its end within its stop's deadline, and only by
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
  line. Its row is marked first (a message's in `Mailbox`, an answer's, an interrupt's or an
  end's in `Stream`), then the line goes to a spool file `out/<uuid>.json`, and the
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
  `--replay-user-messages` it comes back with that uuid and `isReplay`. Its sending mark, the
  row in `Mailbox`, is settled by the replay that `Stream`'s fold reads; `Stream` keeps the
  line's claim and the replay, not a message state of its own (R7). When the delegate exits, a
  message with no replay in the log, read to its end, is delivered if the transcript holds its
  uuid and undelivered otherwise; it is never written again blind. Since no line of an earlier
  process reaches a later one, "undelivered" is final. `Mailbox` makes it due again for the
  resumed process, first, under its same uuid, before any other row to that delegate. Claude Code drops a user line whose uuid its transcript holds; with a FIFO per process
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
  it asks for the end: the report's row in `Mailbox` settled delivered, and no row to the
  delegate sending or due. `Stream` refuses the end while the turn runs, and refuses a line once
  an end is marked; behind the report, its turn check is defense in depth. `Sessions` sees the exit by the pid; one that does not exit within
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

A main session stays interactive. `Screen` reads only a main session's screen: its dialogs by
label, a typed command's result line, and whether its input box is empty before a typed write.
Its fixtures are captured from a real session once per pinned Claude Code release by a script,
run and reviewed, with names and paths scrubbed; no test runs the real Claude Code.

**Delivery into a main session** (a report, a reply, a message) types nothing (F-114). Each
main session's launch overlay (item 11's settings overlay, for the main role) names a `command`
Stop hook with `asyncRewake: true` and a `timeout` of 7,200 s; the account's settings do not,
since a headless delegate's transport is `stream` (F-121's new-3). `Intake.waiter_hook/5` gives
the fragment, as `hooks/4` gives the account's; wiring it into a main session's start is R7's
or `Mains`'. The hook is `sh -c` around `curl` (F-121's new-2): it posts the Stop hook's input
to `/hooks/<account>/waiter` (a path of its own, so the body is not stored as a `Stop` event)
and waits. The secret reaches curl as a config on file descriptor 3, by a here-document
(`-K /dev/fd/3`), and the shell that reads it `exec`s, so the secret is in no process's
arguments while it waits. `Intake` holds it: a hold of kind `waiter`, one per session, whose
decider is `Mailbox`. When a row is due, `Mailbox` marks it sending by the waiter and calls
`Intake.deliver`, which hands the text to the session's waiter: `{:ok, :sent}` once written,
`{:refused, :no_waiter}`, or `{:unknown, reason}` when the connection closed before the write
was confirmed. The program writes a response that is not empty once whitespace is stripped to
stderr and exits 2, and Claude Code starts a turn with it, even when the session is idle;
anything else, a failed post included, exits 0. Each turn's end starts the next waiter. The
transcript holds the text as a user line (`Stop hook blocking error from command "Stop":
<text>` in 2.1.322), which confirms the delivery: `{:ok, :sent}` says the text was written,
not that it was read. A draft a person left in the box is not touched, so the box need not be
empty.

**The waiter's connection** (F-121's new-1). A handler waiting on Bandit is not told that its
client closed; only a write finds it. So the response is chunked from the start: status 200 at
once, a newline every 5 s (the heartbeat), and the text as the last chunk; at `Intake`'s
deadline, 2 minutes under the hook's `timeout`, it ends with no text. A failed write ends the
hold (`Hold`'s cut). A connection can die unseen until a heartbeat fails, and text written to
it in that time is not read; the transcript then has no line, and `Mailbox` makes the row due
again. A second waiter for a session waits behind the first, and the first is sent a heartbeat
at once; the second takes the first's place once the first's hold ends, by a failed write, its
text or its deadline. A waiter is answered empty only at its deadline. `Intake.tla` models the
waiter as `Hold`'s third instance (F-123).

A session with no waiter (before its first turn ends, after a waiter's deadline, or after a
restart cut the waiter's connection) gets nothing that way, and `Intake` knows it
(`Intake.waiter?`), once a heartbeat has found a connection that died. What is due is held until
a waiter connects; a view shows a session idle with no waiter and something due, and the
`Inlet`'s checked write reaches it, as one more transport of the same row.

**Ending a session** is SIGTERM to its pid, by the row's pid and start time, once its session
file says `idle`. It replaces a typed `/exit`. Claude Code's shutdown keeps the transcript and
fires SessionEnd with reason `other`, which `Sessions` and `Recoveries` read as that end. The
session file's `status` (`busy`, `idle`, `waiting` with `waitingFor`) is not documented; it is
checked against each pinned release, as the screen fixtures are.

## Agents working together

Agents talk along the tree's edges: an agent talks to its parent and its children, and main
sessions talk to each other. Any agent can see the whole tree. Each does this only through the
framework's tools, which are strict in how they act and narrow in whom they reach.

**Strict in how:**
- A tool names its target by what the framework holds: an agent's name or a service's name.
  Never a tmux target, a pid, a socket path or a raw command for tmux.
- Each call acts through the part that owns the action: a key goes through the `Inlet`'s checked
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
- A start gives a delegate at most its parent's launch: through the agent tools it may add
  deny rules and disallowed tools, and a start that asks for an allow rule, an allowed tool, a
  folder or an environment variable its parent's launch lacks is refused with
  `{:wider_than_parent, what}` (`Grants`). The app's own code starts an agent with any launch.
- Messages go along the edges only: a main session to its delegates and to other main
  sessions; a delegate to its main session. A delegate has no other agent to message: its
  children are subagents, which Claude Code runs inside it. Two delegates talk through their
  main session.
- A fix (interrupt, answer, resume, stop) is a parent's act on its own child. It takes a claim on
  the child first. The claim is for the child's current state, the way `Recoveries` acts once
  per state, and is a row in `Acts` (the same table `Recoveries` writes its acts in), written
  before the fix acts. A second fix of the
  same state is refused with `{:claimed, by}`. The fix acts only while the claimed state is
  still the child's current one, read again when it acts. A call ends with its fix verified or
  not; the row keeps that state until the child's state moves, and a fix that did not help goes
  to a person. Each claim row carries the id of the framework start that wrote it, a value the
  embedding app makes once per start; a row of an earlier start still claimed is one a restart
  cut off. A claim a restart of the framework cut off is closed as interrupted, never
  retried. A state once claimed stays claimed, whatever the claim's end: a second claim of it
  is refused (`{:already_claimed, by}`), so a fix acts once per state; a unique index on the
  target's state keeps it so, with no scan. A caller whose claim was answered unknown reads the
  act's row before it decides anything (F-75).
- No agent fixes or moves a main session; only a person does, a move with one press.
- An agent may not fix itself. A stuck agent cannot be relied on to see that it is stuck.
- Jobs and services: a main session and its delegates may run jobs and start services on any
  host, in a copy of their own worktree (a main session's is its checkout). A service is fixed
  by its owner, or by the owner's parent.

**The tools:**

| Tool | Who | What it does |
|---|---|---|
| `agents()` | any agent | the tree: each agent's name, kind, project, parent, account, state (working, waiting, idle, stuck, gone; `starting` while a start or resume is under way, `unread` while nothing has read its session yet), what it waits on, and its subagents, read from the `Tracker`'s view, never a copy (F-99) |
| `message(to, text)` | along an edge | stores a message and delivers it to the target when its turn has ended; answers `queued{id}`, then the sender learns `delivered` |
| `look(agent)` | parent, child, main sessions | a main session's screen as text, or a delegate's rendered event log; its open dialog or request; its last transcript lines |
| `transcript(agent, from)` | parent, child, main sessions | the agent's transcript from an offset |
| `interrupt(agent)` | parent | a delegate's stream interrupt, under a claim |
| `answer(agent, dialog, label)` | parent | answers a child's open request through its held hook, by label, under a claim |
| `resume(agent)` | parent | starts a dead or wedged child again with `--resume`, once per state, under a claim |
| `stop(agent)` | parent | ends a delegate after its report is delivered, under a claim |
| `start_delegate(…)` | main session | starts a delegate and answers at once; the report arrives later as a message ("The delegate protocol") |
| `run_delegate(…, timeout)` | main session | starts a delegate and holds the call for its report, up to `timeout`, for short work; at the timeout it answers `{:unknown, :timeout}` with the delegate's name, and the report then arrives as a message, as `start_delegate`'s does |
| `start_main(project, name, brief)` | main session | starts a main session of a project under a name not in use |
| `run(host, argv, timeout, opts)` | main session, delegate | runs a job in a copy of the caller's worktree on `host`, and answers its exit code and the end of its log, or `{:unknown, :timeout}` once it ended it; after the job ends, the paths `fetch:` names, and only those, are copied by rsync from the copy into the caller's worktree |
| `service_start(name, argv, opts)` | main session, delegate | holds `argv` by dtach on a host (`host:`, the workstation by default) in a copy of the caller's worktree, with its output in a log, and a port forwarded to the workstation if `forward:` names one (to the same port unless `local:` names another); `timeout` bounds the whole start, sync and forward included |
| `services()` | any agent | each service: name, host, owner, state, restarts, forwarded port |
| `service_logs(name, from)` | any agent | the service's output from an offset |
| `service_send(name, input)` | owner, owner's parent | text or keys to the service's terminal, by `dtach -p` on its host while its pid is still the row's ("Hosts"); answers `sent`, `refused` or `unknown`, and is never resent |
| `service_wait(name, until, timeout)` | any agent | until a line of the log matches a pattern, a port listens on the host, or the service exits, which ends every wait; answers which, or `{:unknown, :timeout}` (`:dropped` when its last read failed). A line is looked for from the log offset of the service's current start, which its row keeps, so a line an earlier start wrote never answers (F-89) |
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
read the files (F-86). The rule is kept against a caller named wrongly, by mistake or by a
tool's argument, not against an agent that sets out to act as another: every agent runs as the
person's own user, and only an OS user per agent would separate them. The file stays for the
session's life, since a reload or a resume reads it again.

**Messages** are stored before they are sent, so a restart of the framework does not lose
them. Each is a delivery ("Delivery"), the same row a report and a reply are: one goes in only
when the target's turn has ended, marked before it goes, settled from the target's replay or
transcript after a restart, never resent blind. Messages are kept in order per sender and addressee. A message is refused when its addressee is
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

**The operator** acts through these same tools and checks, as the parent of every main session
(F-109). No agent messages the operator: it is no agent's addressee, and an agent reaches a
person through `ask`. A reply to the operator's message, or the notice in its place, is stored
addressed to the operator and never delivered: the app reads it by the message's id
(`Mailbox.reply/2`). The operator's `run_delegate` hands the report to the operator, who
waited for it. Either way the main session sees the act as it sees any act on its child: in the
log, not as a message.

**Services** belong to the agent that started them. When the owner ends, its services end too,
unless it handed them on with `service_hand`, or started them with `keep: true`, which hands them
to the owner's parent when the owner ends. `keep` belongs to the service and stays with it when
it is handed. A service has a name, a host, a copy, a held process and a log. A claim on a
service holds its state as its held process (pid and start time) and its restart count. It
never holds a Claude Code session; agents are started as delegates. Any agent the tree holds may
start one (`Grants.may_start_service?`).

A service's end sends TERM to its process group, while its pid still has its recorded start
time, and KILL to the group after a grace (the call's timeout), as its own step: the end is
done only once the socket reads dead. A group signal that fails while every member of the
group is a zombie not yet reaped, or none is left, reads as gone: macOS answers EPERM for such
a group, and nothing in it runs again; one that fails while a member is not a zombie stays
unknown (F-124). A service runs in the foreground, in its own group: a program that daemonizes
itself into a new session leaves a process no end reaches, so it is started in its foreground
mode (a database with its no-daemon flag, say). A start that settles
after its owner has ended does not stay running: its settle reads the owner's end first, and
ends the service, or hands it to the owner's parent when it has `keep` (F-83).

## Delivery

Everything the framework hands an agent is one row in `Mailbox`: a message, a reply, a notice,
a report (the reply to the brief's uuid) and the app's word (F-115, R7). There is one mark and
one settle, and only the transport differs. `Delivery.tla` models it before `Mailbox` is
changed (R6).

- **One row in flight per addressee.** `Mailbox` picks the oldest due row per addressee, in
  order per sender and addressee, with a row made due again by a settle going first. It marks
  the row `sending` with its transport, then hands it on. Refused undoes the mark; unknown keeps
  it for the evidence. The row is the only mark: no other part keeps a delivery state.
- **Into an ended turn only, to the current process only.** The turn state is `Sessions`'
  function for the target's kind; the process is the agent row's.
- **The transport is the target's**, and each transport names its evidence and what a restart
  does to a row it left `sending`:

| Transport | Target | Settled by | A row left `sending` by a restart |
|---|---|---|---|
| `stream` | a headless session | the replay in `Stream`'s fold; at the exit, the transcript | settled from the same evidence once read; undelivered is final, and the row is due again first, under its same uuid, to the resumed process |
| `waiter` | an interactive session with a waiter | the transcript's `Stop hook blocking error` line, once the turn that took it has ended | settled from the transcript once that turn has ended: delivered if the line is there, due again if not |
| `typed` | an interactive session with no waiter | the `Inlet`'s answer, then the transcript's user line once the turn has ended | as `waiter`; an unknown write is never typed again |
| `call` | a waiting `run_delegate` | the endpoint's write, and the calling process still running after it | due again, for the parent's waiter: the call it answered is gone |

The restart policy lives with the transport, as one module per transport in `Mailbox` beside
the one mark and settle, and `Delivery.tla` models each transport's policy as its own choice.
The common part (the row first, refused undoes, unknown keeps, a settle by evidence at a cue
and after a restart) is written once.

## Intake

Claude Code posts each hook event once and never retries it, and a post that fails loses that
event (Claude Code 2.1.322; sources in `docs/build-notes/F-24.md`). `Intake.tla` models this
section.

- **Transport.** Each account's settings name an `http` hook for each event the framework
  reads: SessionStart, SessionEnd, Stop, StopFailure, SubagentStart, SubagentStop, Notification,
  UserPromptSubmit, PermissionRequest and PermissionDenied. Each hook posts to
  `http://127.0.0.1:<port>/hooks/<account>` on the framework's node, with a secret of the
  instance's in a header, and sets its own `timeout`. No program on the host takes part, so a
  held hook is one open request. PreToolUse and PostToolUse are written only when the app gives
  `Intake` a callback for them, and are not stored as they come: they carry every tool input,
  and `Transcripts` reads those. A main session's waiter is the one `command` hook: it posts to
  `/hooks/<account>/waiter` ("Delivery into a main session").
- **One hold, four kinds** (F-115, R5). A hook that waits is a hold: a key, a deadline under
  the hook's `timeout`, a named decider, exactly one response, a late answer dropped, and a
  settle when the holder or its connection dies (`lost` or `unknown` for a hold with a row,
  nothing for the others). `Intake` keeps one structure of holds, one `:DOWN` lookup and one
  drop; each kind names only its decider, its deadline and its response's encoder:

  | Kind | Hook | Decider | Deadline | Row |
  |---|---|---|---|---|
  | `permission` | `PermissionRequest` | a person, or an agent's `answer` | 570 s of 600 s | yes |
  | `tool` | `PreToolUse` | the app's callback | 5 s of 10 s | yes |
  | `stop` | `Stop` | the app's callback (item 14) | under the hook's | a decision only |
  | `waiter` | the `asyncRewake` Stop hook | `Mailbox`'s due row, by `deliver` | 7,080 s of 7,200 s, with a heartbeat every 5 s | the delivery's, in `Mailbox` |

  `Hold.tla` models the hold once, and `Intake.tla` instances it per kind (R4).
- **A held `PreToolUse`** (F-111). `Intake` asks the app's callback, in a process of its own,
  with a deadline of 5 s under the hook's 10 s timeout, and gives exactly one response: the
  decision (`hookSpecificOutput.permissionDecision` `allow`, `deny` or `ask`, with
  `permissionDecisionReason` beside a deny), or an empty body for a pass, a crash or the
  deadline, so Claude Code goes on as without the hook. A later decision is dropped. Its row,
  keyed by `session_id` and `tool_use_id`, is written "held" when the request is held, as a
  permission's is (F-119's new-3, F-121); a decision moves it "deciding", with the actor `app`,
  before the response, then "answered"; a pass leaves it "passed" and the deadline "expired".
  Its `data`, the tool's input, stays empty until a decision is taken, since `Transcripts`
  holds the input (F-121's new-4).
  A second post of the key answers the row's decision, or an empty body. A PostToolUse is
  answered at once and handed to its callback, with no row.
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
  "deciding" before the decision goes out as the response (`hookSpecificOutput.decision`:
  `{"behavior": "allow"}`, with `updatedPermissions` for "don't ask again", or `{"behavior":
  "deny", "message": …}`), then "answered". An answer to a row that is not "held" is refused. It
  never goes to another dialog of the agent, and never becomes typed keys.
- **Its deadline.** The hook's `timeout` is 600 s, and `Intake` answers an empty body, no
  decision, at 570 s and marks the row "expired". The dialog stays on the screen for a person.
  So no answer goes to a request Claude Code no longer reads.
- **A restart.** The open requests end with the node. Claude Code reads an error, and the dialog
  stays for a person. After the restart a row still "held" is "lost", and one "deciding" is
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
2. **One writer.** One process writes each table, and one `Inlet` per host writes panes. Every
   other part reads a table through its owner's functions.
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
  by hand, each with its time recorded. The gate also parses every slow configuration (TLC's
  parse and its constants, without the search), so a constant a spec declares and a slow
  configuration leaves unset fails in the gate, not on the next run by hand (F-115's new-1);
- a fast configuration finishes within 30 s on an idle workstation. The next unit that changes a
  spec times the whole fast set on an idle machine and records the times in its build note; a
  configuration over the bound moves to `slow/` or gets smaller bounds (F-115's new-13). A spec
  that instances a module compares its state counts before and after;
- each spec's header names the modules it models and what it leaves abstract;
- a mechanism is written once, as a module the specs that need it instance (`Claim`, `Hold`) or
  as a spec whose state the others read (`Delivery`), never encoded again in each spec. A
  property that crosses specs is checked in the spec that owns it, with the other's state, not by
  composing every spec in one run.

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
dialog it names, never after Claude Code's timeout and never by typed keys; and (F-111) a held
`PreToolUse` given exactly one response, the app's decision or an empty body at the deadline,
with a late decision dropped.

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

**The remodel's model** (F-115). Each mechanism is written once, and the specs above are
reshaped around three new ones, in R4 and R6, before the code they describe:

| Spec | What becomes of it | What it checks |
|---|---|---|
| `Shell.tla` | kept as it is | as above |
| `Agent.tla` | kept; instances `Claim` for `Recoveries`; the comments that say `/exit` go | as above |
| `Start.tla` | kept; `StopAsked` is SIGTERM once idle; `Recoveries`' end of an orphan by pid and start time is the same `KillsOwnOnly` (both F-118) | as above, and `TermsOnlyIdle`, `OrphanEnds`, `LateStopEnds` |
| `Copy.tla` | kept; instances `Claim` for the forward's reopen; the forward (about 230 lines) may split into its own spec when it next changes | as above |
| **`Claim.tla`** (new, R4, about 60 lines) | the claim before an act: once per state, acted on only while current, cut by a restart; the rule of `Acts` | `OneClaimPerState`, `OneActPerState`, `NoActOnCutOffClaim` |
| **`Hold.tla`** (new, R4, about 80 lines) | a held request answered once by its named decider, its deadline, its holder's death, a restart | `OneResponse`, `LateDropped`, `OnlyNamed`, `RequestsEnd` |
| `Intake.tla` | the events half kept; the holds become four `Hold` instances: `permission`, `tool`, `stop`, `waiter`; `slow/Intake_Large.cfg` sets `MaxCalls` | as above, and one waiter per session, due text held while none waits |
| **`Delivery.tla`** (new, R6, about 450 lines) | `Mailbox`'s one mark and settle over the transports `stream`, `waiter`, `typed` and `call`, each with its restart policy; restarts; a resume; a move across accounts | at most once; only into an ended turn and to the current process; in order per sender and addressee; a reply or a notice once, never both; a report is the reply to the brief; settled against the copied transcript after a move |
| `Stream.tla` | its transport kept (offset, spool, FIFO per process, requests); its message state becomes the evidence `Delivery` reads | as above, less `IntoEndedTurn` and `ReplayedOrFound`, which move to `Delivery` |
| `Delegate.tla` | shrinks to the protocol: rows first, the cap, resume once, a second kill, the report handed to `Mailbox`; `DeliveryTyped` and the report's `sending` go | the start and resume properties; `ReportArrives` through `Delivery` |
| `Team.tla` | shrinks to `Grants`, the operator and services' owners; claims by `Claim`, messages by `Delivery` | the edges, who fixes, owners |
| `Move.tla` | rewritten (R6): the end by SIGTERM once idle, a restart of the framework, `Delivery`'s waiter across the move | as above, and nothing delivered to the old process, once to the new |

Until R4 and R6 land, the specs above say what they say today; where one still models a typed
delivery or an end by `/exit` (`Delegate.tla`'s `DeliveryTyped`, `Team.tla`'s, `Move.tla`'s
end), "Delivery into a main session" and "Ending a session" are the design, and the spec is
behind it. `Start.tla` took the end by SIGTERM in R3 (F-118). The model stays about 5,400 lines.

**What the code relies on and a spec will own** (F-115, section 3):

| Property | Owner |
|---|---|
| a message or a report in flight during a move across accounts: held while no waiter is connected, delivered only to the new process, once, settled against the copied transcript | `Move.tla`, with `Delivery`'s state (R6) |
| the waiter: one per session, due text held until one connects, answered at most once, its timeout, a restart that cuts it, the typed write when there is none | `Hold.tla` (the `waiter` kind in `Intake.tla`, R4) and `Delivery.tla` (its transports, R6) |
| a report and a reply keyed by uuid across a resume, with the brief, a resume and a message together | `Delivery.tla` (R6) |
| `Mailbox`'s order with a resume: per sender and addressee, an undelivered row resent first under its uuid | `Delivery.tla` (R6) |
| who may answer a dialog: the decider a hold names, under the claim of `Acts` | `Hold.tla` (`OnlyNamed`) with `Claim.tla` in `Team.tla` (R4) |
| the operator answering dialogs or moving a session | `Team.tla` (the operator) and `Move.tla` (R6) |
| launch narrowing across a resume | `Delegate.tla` (the resume gives the same options) |
| the fault ledger: every act a row, once per state, interrupted by a restart | `Claim.tla` (R4) |
| `Move.tla` with a restart of the framework | `Move.tla` (R6) |
| `Stream`'s claim ended by `Recoveries` | `Stream.tla`, with `Claim.tla` (R4) |

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
  (`settings.json`, `.claude.json`, credentials). An agent's settings are one file: its launch
  options' overlay merged over its account's settings, since `--settings` takes one value
  (F-110).
- Check against each pinned Claude Code release what the help leaves open: which settings a
  launch reads, whether `--append-system-prompt` has a file form, and how a tool pattern with a
  comma or a space inside its rule is split (F-110). Until the file form is confirmed, the
  appended prompt goes as one argument, bounded in size.
- An agent's appended system prompt is fixed at its first start: Claude Code records the system
  prompt at a conversation's first request and sends it as it was on every resume. A resume
  gives the same options again; an app cannot change the prompt by resuming with others.
- An app's launch `env` may set Claude Code's own `CLAUDE_CODE_*` names on purpose; only the
  names the framework sets itself (`CLAUDE_CONFIG_DIR`, the MCP timeouts, `CLAUDECODE`, …) are
  refused. What "from nothing" keeps out is what is inherited, not what the app gives.
- A blocking `Stop` hook cannot deliver to an idle main session: it fires only as a turn ends
  (F-107). An `asyncRewake` one can: it runs in the background and its exit 2 starts a turn,
  measured on 2.1.322 after 12 minutes idle (F-114). Each pinned release's check measures a
  waiter through a long idle and a compaction.
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

**Parts**
- Build a mechanism once and give it a home before its second use. A shared SQLite helper
  asked for at the third table was not built, and 15 copies of it followed; one mark and settle
  was written six times, one held request four, one claim three (F-115).
- A part never opens another part's table, and a status list lives once, in its owner. Three
  parts opened others' tables, and the statuses that hold an agent were listed in four apps,
  not all alike, so a rename in one fails only at run time in the others (F-115).
- The order in which parts settle on each other's cues is the library's. Wired by hand in the
  app, two parts got no cue at all and ran on a ticker with a made-up topic, and no test of the
  library could see it (F-115).

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
- A fake is a test aid: it lives in the app's `test/support/` or in `caf_test`, never in a
  library's `lib/`, where it compiles into the package (`Tmux.Fake`, F-115's new-12, moves in R1
  or R2).
- A spec's fast configuration is timed on an idle machine: a time taken under load says nothing
  about its bound (F-115's new-13).
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

4. **`Screen`**, from the fixtures a person captures (built, F-113), then the delivery of a
   report through the waiting Stop hook (F-114), and `run_delegate`: now R5, R7 and R8.
5. **`Mover`**, against `Move.tla`: now R12.
6. **`Mains`** (the agent row of kind `main` is R9; what is left is in item 13): one main session per project, on trunk in the project's checkout (the clone it
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

Items 7 and 8 are built (F-69 to F-104). What an app built on the framework needs, by its own
list of gaps (F-108), comes in this order, blockers first; each protocol is modeled before its
code:

10. **The operator**: a person or the app acting through `Grants` and claims as a parent of every
    main session, recorded as the actor; messages from it through `Mailbox` (F-109). Then a
    reply to its message kept for it (`Mailbox.reply/2`) and its `run_delegate`'s report, as
    "Agents working together" says.
11. **Launch options per agent**: a settings overlay (permission deny rules), extra environment,
    `--add-dir`, `--append-system-prompt`, allowed and disallowed tools, each checked and kept
    on the agent's row (F-110). Then the narrow-only check of a delegate's launch against its
    parent's, in `Grants`.
12. **PreToolUse and PostToolUse hooks**: held like `PermissionRequest`, PreToolUse answered by
    an app callback with a short deadline (allow, deny or ask); then a permission policy asked
    before any request waits for a person, its decision recorded as a person's is.
**The remodel** (F-115, taken in F-116) comes next, before the rest of item 13 and item 14, so
that each later unit is a few lines in one part of one shape rather than one more copy of a
mechanism. Each unit keeps every gate green at its end. Sizes are changed lines apart from
fixtures, estimated by F-115. R1 to R3 change no behavior and may go in any order; R4 and R6
are the model before the code they describe (R5, R7 to R10).

- **R1. `caf_store`**, and the writers' tables on it (`Sessions`, `Delegates`, `Stream`,
  `Mailbox`, `Intake`, `Jobs`, `Services`, `Copies`, `MCP`, `Claims`, `Recoveries`); `Tmux.Fake`
  moves to test support here or in R2. About +250, −700. (F-37's new-3.)
- **R2. `Reader`** on `caf_store`: `Registry`, `Usage`, `Transcripts` and the sampler; the
  `Tracker`'s sources made from table metadata; one `Registry` and one `Transcripts` per host
  over every account, so an agent is found across every account the framework holds and a
  move never hides one. About +200, −650.
- **R3. `Holder.Process`**: `Sessions`, `Jobs`, `Services` and the forward on it; `Sessions`'
  stop of an interactive session by SIGTERM once its session file says `idle`, in place of a
  typed `/exit`; `Recoveries`' end of an orphan and of a late stop, by pid and start time.
  About +200, −300.
- **R4. Model**: `Claim.tla` and `Hold.tla`; `Agent.tla`, `Team.tla`, `Copy.tla` and
  `Intake.tla` instance them; the `/exit` text goes; `slow/Intake_Large.cfg` sets `MaxCalls`,
  and `bin/check-model` parses the slow configurations in the gate. Specs only, about −300 net.
- **R5. `Intake`'s one hold**: `PermissionRequest`'s and `PreToolUse`'s holds become one
  structure, then the `waiter` kind (F-114). About +250, −120. Built: the one hold in F-121,
  the waiter in F-123; wiring the waiter's hook into a main session's start is R7's.
- **R6. Model**: `Delivery.tla`; `Delegate.tla`, `Team.tla` and `Stream.tla` read it; `Move.tla`
  rewritten with the end by SIGTERM, a restart, and a message in flight during a move across
  accounts: held while no waiter is connected, delivered only to the session on the new account,
  and once, settled against the copied transcript. Specs only, about +450, −500.
- **R7. `Mailbox` delivers everything**: the report as the reply to the brief; the transports
  `stream`, `waiter` and `call`; `Mailbox`'s `sending` as the only mark; `Delegates`' report
  reduced to `taken`. About +350, −350. (Item 4's delivery and `run_delegate` on this shape.)
- **R8. `Inlet`**: `Control` with `Screen`'s box check, the checked write for a session with no
  waiter, as the transport `typed`. It records the release each session runs, and never trusts
  one read for a turn's end (F-113's new-2, new-4). About +200, −140.
- **R9. The agent row and the tree**: `Sessions`' row takes kind, parent and project; the tree,
  the statuses that hold an agent and each session's turn state are functions there; `Grants`,
  the `Tracker`, `Mailbox` and the app read them, and no part opens another's table. A main
  session is a row of kind `main` (most of item 6). About +300, −350.
- **R10. `Acts`**: `Claims`' and `Recoveries`' rows in one table with a unique index and a cue;
  the fault ledger of item 14 is its query and its topic. About +250, −300.
- **R11. `Cues`**: each part declares the topics it reads; `Jobs` and `Services` cue; the app's
  routing table and its ticker go. About +200, −200. (F-102's new-3.)
- **R12. `Mover`**, on the agent row and `Delivery`, against the rewritten `Move.tla`, for
  delegates as well as main sessions (item 5).

About 3,100 lines change in all; the library ends about 1,300 lines smaller, and the model about
the same size with each mechanism once. R6 and R7 are the riskiest: `Mailbox`'s `sending` as the
only mark keeps `Stream`'s guarantee that "undelivered" is final and resent first under the same
uuid, and each spec that instances a module compares its state counts before and after.

13. **What is left of the main sessions' work**, on the remodel's shape (`Screen` is built,
    F-113; the waiter is R5 and R7, the checked write R8, the end by SIGTERM R3 and R6, the
    reach across accounts R2, `Mover` R12): **interactive delegates** (`interactive: true`: an
    agent row of kind `delegate` whose turn state and transports are an interactive session's),
    then **`Mains`** (item 6: what R9 leaves, the checkout, the pull after a landing and
    `start_main`; a main session's kept services end with it or go to a person, once one can
    end: F-109's new-4).
14. **Mechanisms an app's policies stand on**, on the remodel's shape, in this order:
    - a delegate idle with no report, a value of `Sessions`' turn function that `Delegates`
      tells its parent, in `Delegate.tla`;
    - admission by measured load and memory, a check in `Delegates` and `Jobs`, whose refusal
      is `{:refused, {:load, …}}`, never a failed run;
    - `Stop` held for an app callback, the hold kind `stop` of `Intake`, so an app's own check
      before a turn ends answers it;
    - copies by the file system's clone where it has one;
    - a start idempotent per branch, a lookup of the agent row: a second start answers the
      running delegate only while its session is live, and a row with no report whose session
      is gone does not count as running.

    The fault ledger is R10. Which tests to rerun on a red, a re-entry brief after a reset, a
    reviewer and its acceptance list, which edits to guard, and a replay suite are an app's
    policies, not the framework's.
15. **Packaging and toolchain**: one `coding_agent_framework` package; `Programs` looked up and
    checked at start, with a Homebrew setup documented; the Elixir and OTP floor tested; a
    library supervisor from a config struct, out of `caf_example`; accounts: how to log one in,
    and Keychain reads for held processes (`USER`, and `security` on the launch's `PATH`).
16. **What the app reads and drives**: structured reports with a schema and several per
    delegate; app metadata and names on agents; status with the last activity, cost and tokens,
    and a needs-input state; one activity feed per agent; an urgent message (interrupt, then
    message, as one checked step); one-off headless turns; the agent's identity for the app's own
    MCP servers; worktree base, reuse and removal; the source checkout's path for setup; a stable
    read API by id and name; a PubSub adapter for cues; a readable rendering of a delegate's log.
17. **`Stacks`**, the LiveView components (unstyled, with class hooks), and Ghostty (with other
    terminals by a callback).

The remote agents of the first plan (a session held on another host, its hooks forwarded back
over ssh, its session files and status line read there) are not built: agents run only on the
workstation. What is built stays keyed by host.
