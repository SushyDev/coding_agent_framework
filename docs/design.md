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
  usable account with the most room, each in its own worktree. To the main session a delegate
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
  pulls trunk, so it always holds the project's latest trunk. It is never archived; the
  operator alone ends one, once its delegates have ended (`end_main`, F-143).
- **Delegate**: an agent a main session starts through the framework, on any account, in its
  own worktree. By default it runs headless: it reads JSON messages on stdin and writes JSON
  events on stdout, and nothing reads its screen. Started `interactive: true`, it runs Claude
  Code's terminal interface as a main session does, held the same way, so a person can attach
  and type, and what the framework hands it goes in as a main session's does, but it never has
  Remote Control (F-275): a person looks at it through the app's panel. It acts like a subagent
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
  `<home>/checkouts/<dir>`, `dir` being the project's `dir:` or by default its repository's
  name (F-156), so a `CLAUDE.md` that imports a sibling repository's file by relative path
  finds it among the checkouts as among the person's own clones; made once from the project's
  repository. Two projects never name one directory, and a directory has one owner on a home
  (F-229): a project whose path a checkout row of another project holds, from an earlier
  config, is refused, and a directory there whose `origin` is not the project's is never taken,
  but reads `failed` for a person to decide. `dir:` is how two origins of one name get a
  directory each. A project's
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
  outside it. Every tool the framework runs keeps its state there too (F-155, the operator's
  rule: the framework needs only a system with nix; devenv brings every program, and every
  program's data stays in the home, never in the person's own folders): the GitHub CLI's login
  (`<home>/gh`, its token a file there and never the OS keyring), git's global config with the author agents commit as and its signing key
  (`<home>/git/`), ssh's config and known hosts (`<home>/ssh/`), the XDG directories
  (`<home>/xdg/`), and each checkout's agent memory (`<home>/memory/`). `ToolHome` names them.
- **Server**: a tmux server, `tmux -L <name>`. Pane ids are unique only within one server, and a
  restarted server counts from `%0` again.
- **Viewer**: the tmux pane that shows a held agent: a main session's own screen (`dtach -a`),
  or a readable rendering of a delegate's event log. It can die, be reopened or be opened twice;
  the agent runs on.
- **Claim**: an actor's hold on one of its targets (a child, a service, a broken state), in one
  state, taken before an act, so that only one act on that state runs. Every claim is a row in
  `Acts`, whoever the actor: an agent's fix, the operator's act, a recovery.
- **Delivery**: text the framework hands an agent (a message, a reply, a notice, a report, a
  delegate's brief and its word to go on after a resume, the app's word), one row in `Mailbox`,
  marked before it goes and settled from evidence after (F-122's new-4). How
  it goes in is its **transport**: a `Stream` line, the waiter's answer, the `Inlet`'s checked
  write, the prompt argument of an interactive session's start (`launch`), or the answer of a
  waiting `run_delegate`.
- **Hold**: a request held open with a deadline, answered exactly once by a named decider, and
  settled when its holder dies. `Intake` keeps six kinds.

**Boxes and verbs** (F-162)

- **Box**: one of the seven single-purpose parts the framework is seen as from outside ("The
  boxes"), with a handful of public functions, the tables it owns and the spec that is its
  contract. The parts below are inside the boxes, and no box reaches into another but through
  its interface.
- **Verb**: one of the seven tools an agent sees beside native Claude Code ("The agent's
  surface"): `delegate`, `message`, `ask`, `look`, `steer`, `wait_for` and `serve`. A verb takes
  options rather than becoming more tools.
- **Intercept**: the framework's answer to a native tool call by a hook (`PreToolUse`'s
  decision or `updatedInput`, `additionalContext`), so the agent goes on with the tool it
  already knows.
- **Fact**: a recorded thing that happened, never changed: a row's status written, kept in its
  table's history by the row's writer, or an outside event, kept in the `Ledger`'s `facts`. An
  **act** is the `Ledger`'s other kind of row ("An act").
- **Prompt**: anything waiting on a person or on an agent's parent, at any depth of the tree (a
  permission request, a question, a startup dialog, a plan to approve, a remedy not on the
  allow-list), one row in `Prompts`, answered once from one place.
- **Agent process**: the one BEAM process that owns one agent's row and life, under a dynamic
  supervisor; the agent itself, Claude Code, runs outside the BEAM under dtach.
- **Subscription**: an agent's `wait_for` on an event, one row in `Mailbox`, fired once and
  delivered as any row is.
- **Symptom**: a named bad state the `Watch` reads from facts and acts (an idle delegate its
  parent was not told of, a session stuck on a dialog), with its evidence.
- **Remedy**: an act on a symptom's target that a person approved for that symptom, taken once
  per state, verified after, and capped per hour.
- **Extension**: a bundle an app registers to give agents a power of its own (a knowledge base,
  an issue tracker): at most one verb, a skill, context at the right moment, events in and
  guards, scoped per role and project.

## The parts

### Principles

Every part follows these, and a unit that cannot is a finding, not an exception.

1. **An agent sees native Claude Code and seven verbs, and every tool call is checked before it
   runs.** What it already does (its own Bash, background commands, subagents) is intercepted,
   not replaced, by policies that are the app's data, correcting a call rather than refusing it
   where they can; what is not its to do is not on its list.
2. **Every act is a row before it acts, and the `Ledger` is the only truth**: a claim, a
   delivery, a lease, a remedy, a tool call's decision, written first, settled by evidence
   after; recorded real runs are replayed against new code in the gates.
3. **Every protocol is modeled before it is built, and enforced as modeled**: one mechanism is
   one spec that others instance or read, and each verb is legal only where the spec's
   transitions allow it, refused with a reason elsewhere.
4. **One writer per row, one interface per box.** Each row has one process that writes it (a
   table's part, or an agent's own process for its row); a box is read and driven only through
   its interface, and what is inside may change without its users knowing.
5. **Every outcome is explicit**: `{:ok, …}`, `{:refused, reason}` or `{:unknown, reason}`, with
   a finite timeout. No hidden retry, wait or fallback. A stated bound is a bound by the clock:
   a wait takes its deadline once (`System.monotonic_time`, or one sleep of the whole bound in a
   host's shell) and checks it, and never counts tries or sleeps, which wake late under load
   (F-216, F-217). A deadline that lives only inside one call is on `System.monotonic_time`, so
   a step of the OS clock does not move it; one a row keeps (`start_until`, `deadline`,
   `end_until`) is on OS time, or a part's `clock:`, since it must outlive a restart (F-218).
6. **Nothing by guesswork.** Work is placed by a lease, acted on by a claim, ended by its pid and
   start time, and answered by its named decider or a person; never by a pattern, a timer alone
   or a screen read once.
7. **Metrics are folds of what is recorded, and healing is bounded.** Every symptom is detected
   and kept with its evidence; a crash of the framework's own code is restarted by OTP within a
   budget; a bad state outside is acted on only by a remedy a person approved, once per state,
   capped; everything else is a prompt to a person.
8. **Nothing global, and a crash stays local.** Every box is per instance, started by one
   supervisor from one config; each agent, host and account has its own processes, and a
   restart re-adopts from the row, never relaunches.

### The boxes

Seven boxes, each named by what it does for its user. Each is a small interface over a
reliable, modeled inside. The columns say what is public; everything else in the box's apps is
internal: still `def` where Elixir needs it, but `@moduledoc false`, and the boundary gate
(`mix caf.deps`, B2 below) refuses a call into it from outside the box.

| Box | Does, for whom | Interface | Owns | Contract | Holds today's apps |
|---|---|---|---|---|---|
| **`Sessions`** | runs a Claude Code session and reaches into it, one agent process per agent: start, resume, stop, move, a dialog's press, a held hook's answer, a line into its turn; for `Team`, `Mailbox`, `Prompts` and `Watch` | `start/2`, `steer/3`, `read/2`, `hand/3` | `agents` (each row written by its agent process), `intake_events`, `stream_delegates`, the readers' tables | `Start`, `Agent`, `Move`, `Dialog`, `Stream`, `Intake` with `Hold` | `caf_sessions`, `caf_mover`, `caf_stream`, `caf_inlet`, `caf_screen`, `caf_intake`, `caf_registry`, `caf_transcripts`, `caf_sampler`, `caf_cli`, `caf_accounts`, `caf_tmux` |
| **`Mailbox`** | hands an agent text once, in order, into an ended turn, and fires what it waits for; for `Team`, `Prompts` and `Watch` | `send/3`, `subscribe/3`, `read/2` | `messages`, `subscriptions` | `Delivery` | `caf_mailbox` |
| **`Prompts`** | everything waiting on a person or a parent, at any depth, answered once from one place; for the app and `steer` | `open/2`, `answer/3`, `read/2` | `prompts` | `Prompt` (new, B1), instancing `Hold` and `Claim` | `Mailbox`'s asks, `Sessions.Dialog`'s answers, `Intake`'s permission answers (their mechanisms stay where they are) |
| **`Team`** | the tree: who works for whom, what each may do, and the verbs; for agents and the app | `operate/4`, `tree/2`, `tools/2` | `delegates`, `checkouts`, `main_starts`, `mcp_tokens`, `mcp_calls`, `extensions` | `Delegate`, `Team`, `Checkout` (`Stack` when built) | `caf_delegates`, `caf_mains`, `caf_grants`, `caf_mcp` |
| **`Scheduler`** | admits work in order, within capacity and allowance, on an account; for `Team` and `Hosts` | `request/2`, `read/2` | `leases` | `Schedule` | `caf_scheduler`, `caf_usage` |
| **`Hosts`** | runs commands and services on any host, in a copy of the worktree; for `Team` | `run/3`, `serve/3`, `steer/3`, `read/2` | `copies`, `jobs`, `services` | `Copy`, `Shell` | `caf_copies`, `caf_jobs`, `caf_services`, `caf_runs` |
| **`Watch`** | shows what runs, measures it, and heals only as approved; for the app and `look` | `view/2`, `metrics/2`, `digest/2`, `remedies/3`, `clear/3` | `remedies` | `Heal` (new, B1) | `caf_tracker`, `caf_recoveries` |

Under the boxes is a base every box stands on: `caf_shell` (`Shell`, `Programs`,
`Shell.Reaper`), `caf_tool_home` (`ToolHome`: where every tool the framework runs keeps its
state, in the home; pure, using only `caf_shell`), `caf_holder` (`Holder`, `Holder.Process`),
`caf_store` (`Store`, `Reader`) and the **`Ledger`** (`caf_acts` and `caf_cues`): every act and
fact a row, and a cue per write.
It is the floor, not a box: no agent sees it, and the app reads it only through its own surface
(`query/2`, `subscribe/2`). Its contract is `Claim.tla`.

What each interface does:

- **`Ledger`** (the base). `claim(ledger, %{actor, target, state, act})` answers `{:ok, id}` or
  `{:refused, {:claimed, by}}`; `settle(ledger, id, outcome)` by `Acts.answered/4`'s one rule;
  `record(ledger, fact)` writes a fact from outside (an extension's event) with a cue;
  `query(ledger, filter)` reads acts and facts; `subscribe(ledger, topics)` sends the caller a
  cue per write, `{topic, ids}`, never the data. A status fact is written by the table's own
  writer: `Store` appends it to that table's history (`<table>_facts`) in the transaction of
  each status column it changes, so a table that keeps one row per thing still has its history
  and every table keeps one writer; `query` reads the histories through their owners'
  metadata, as the `Tracker`'s sources do (F-162's new-5).
- **`Sessions`.** `start(sessions, spec)` starts or adopts a session by its spec (kind, name,
  parent, project, account, launch, first row); `steer(sessions, name, act)`, `act` one of
  `:resume`, `:stop`, `{:move, to}`, `{:answer, hold, label}` (a held permission or a startup
  dialog), `:interrupt`, `{:clear, dialog}`, each under the claim its caller took;
  `read(sessions, name_or_filter)` the agent row, its turn state, its screen or rendered log,
  its transcript from an offset, and the evidence a delivery settles by; `hand(sessions, name,
  row)` hands one marked row to the session by the transport its kind chooses, and answers
  sent, refused or unknown. Hooks come in here, and the policies other boxes give at start (the
  app's `PreToolUse`, a move's drain, a budget, an extension's guard) decide them. Whatever
  waits on a person (a held permission request, a startup dialog) is opened in `Prompts`, and
  its answer comes back as a `steer`.
- **`Mailbox`.** `send(mailbox, %{from, to, kind, text, key})` stores a row (a message, a
  reply, a notice, a brief, a report, a word to go on, a prompt's answer to an agent that
  asked); `subscribe(mailbox, agent, event)` stores a subscription; `read` is a row's status, a
  reply's text and the open subscriptions. It marks, hands through `Sessions.hand/3` and
  settles by `Sessions.read/2`'s evidence.
- **`Prompts`.** `open(prompts, prompt)` stores a prompt under its owner's key, so one state is
  opened once: the asker's path in the tree (main session, delegate, its Claude Code
  subagent), the kind, the question, the options, a default, a deadline and the owner (the box
  whose mechanism applies the answer); `answer(prompts, id, %{by, choice, text})` is the one
  answer function, for a person through the app, or a parent through `steer`; `read` the open
  prompts by path, kind or age. Every write cues the topic `prompts`, so an app renders one
  inbox ("Prompts" below).
- **`Team`.** `operate(team, actor, verb, args)` is the one entry for every verb, whoever the
  actor: an agent (by its token), the operator, the app, or the `Watch`'s healer. It checks the
  edge (`Grants`), takes the claim, asks the `Scheduler`, and drives the other boxes.
  `tree(team, opts)` is the tree; `tools(team, agent)` is the verbs and extension verbs that
  agent sees, for its MCP endpoint.
- **`Scheduler`.** `request(scheduler, request)` as "A lease" says; `read` the leases, the
  queue and the gates. A release is internal: the owner's row ending, read from the `Ledger`'s
  facts.
- **`Hosts`.** `run(hosts, owner, %{host, argv, timeout, class, fetch})` a job under a lease;
  `serve(hosts, owner, %{name, argv, host, forward, keep})` a service; `steer(hosts, name, act)`,
  `act` one of `{:send, input}`, `:restart`, `:stop`, `{:hand, to}`; `read(hosts, name, what)` a
  log from an offset or the rows. A wait on a service is a subscription in `Mailbox`, fed by its
  facts (B9).
- **`Watch`.** `view(watch, scope)` the `Tracker`'s fold for a view and for `look`;
  `metrics(watch, query)` a named metric over a window; `digest(watch, window)` the symptoms and
  their counts, worst first; `remedies(watch, :list | {:approve, symptom, remedy, cap} |
  {:revoke, …})` the allow-list, widened only by the operator and narrowed on its own when a
  remedy fails; `clear(watch, symptom, by)` a person's clear of a symptom that waits on one.

**Measured today** (F-162): 29 library apps and `caf_example`; 577 public functions in the
libraries (OTP callbacks left out), from 3 in `caf_screen` to 79 in `caf_sessions` and 53 in
`caf_mailbox`; 142 pairs of apps that call each other, by about 770 call sites; 25 MCP tools,
two of them the operator's alone; an embedding app that wires 25 children by hand in a 612-line
supervisor module, 1,766 lines in all; 15 specs, 8,935 lines; one `Sessions` process for every
agent. The seven boxes' interfaces are 26 functions, and the `Ledger`'s 5 in the base. What
becomes internal: every function of `Stream`, `Inlet`, `Screen`, `Intake`,
`Registry`, `Transcripts`, `TmuxSampler`, `Tmux`, `ClaudeCLI`, `Accounts`, `Mover`,
`Delegates`, `Mains`, `Grants`, `MCP`, `Jobs`, `Copies`, `Services`, `Usage`, `Recoveries` and
the `Tracker` but through their box's interface; `Sessions`' 79 become 4, `Mailbox`'s 53
become 3.

The boxes call each other along few arrows: `Team` drives `Sessions`, `Mailbox`, the
`Scheduler` and `Hosts`; `Mailbox` hands rows through `Sessions`; `Hosts` asks the
`Scheduler`; `Sessions`, `Mailbox` and the `Watch` open prompts, and `Prompts` hands each
answer to its owner through `Team.operate/4`; every box records in the `Ledger`; the `Watch`
reads the `Ledger` and acts only through `Team.operate/4`, as an actor with the same checks and
claims as the operator.

**Contracts and one composed spec** (decided). Each box's spec states its contract: what the box
promises at its interface (a row delivered at most once and only into an ended turn; a lease
within capacity; a prompt answered once by its rightful answerer) and what it assumes of the
boxes it calls. One composed spec, `Boxes.tla`, checks the boxes together through those
contracts, not their insides: a delivery during a move, a lease held across a dialog, a prompt
across an agent's restart, a remedy racing a parent's fix, and restarts of one agent and of the
whole. Faults that show only when protocols meet are checked there, and because it composes
contracts rather than whole specs, it stays small enough for TLC.

### The agent's surface

Small is not weak. An agent keeps full control of its own subtree: it starts, briefs, messages,
interrupts, answers, resumes, stops and moves its own delegates, runs and holds services, and
sees the whole tree. What leaves its list is only what is not its to do (another subtree's acts,
the operator's) and what the framework already does for it deterministically (a lease, a
resume after a kill, a reconnect, a placement).

**The seven verbs**, each one obvious job with options, served by `Team.operate/4`:

| Verb | Job | Options | Replaces today's tools |
|---|---|---|---|
| `delegate(brief, opts)` | hand off work and get the report | `project`, `branch`, `model`, `effort` (`low`, `medium`, `high`, `xhigh` or `max`, as `claude --effort`; built, F-200), `interactive`, `wait` (seconds to hold the call for the report), `review: true` (decided: a fresh-context reviewer, read-only by its launch's settings, not by its brief, checks the work against the brief's objective and an acceptance list stored as data the builder cannot edit, runs the checks itself, and its verdict goes up with the report; a builder's "tests pass" is a claim, not a verdict), `variants: n` with `select:` (decided: `:review`, `:gates` or an app's check, and `take: :first_passing \| :compare`; refused `{:refused, :no_selector}` without one; all variants under one shared budget), `budget` and `steps` (decided: tokens, cost, time and a cap on tool calls; reaching one is told to the parent and counted, never a kill), `fresh` (decided: a context reset of the branch's delegate, whose new session's first prompt is the brief, the progress note the agent keeps in its worktree, the branch and its last results, all recorded in the `Ledger`; not a prose summary), `main: name` (a main session of a project, no report) | `start_delegate`, `run_delegate`, `start_main` |
| `message(to, text, key)` | say something along an edge; a `key` (at most 128 bytes, scoped to the sender) makes a send again after `unknown` safe | `urgent` (a nudge: interrupt, then this message ahead of every due row, as one checked step) | `message` |
| `ask(questions)` | ask a person; opens a prompt, and the answer comes as a message | as today | `ask` |
| `look(target, opts)` | see the tree, an agent, a service | `what`: `tree`, `state`, `screen`, `transcript`, `diff`, `cost`, `leases`, `stuck`, `logs`, `services`; `from` an offset; `all` | `agents`, `look`, `transcript`, `services`, `service_logs` |
| `steer(target, act)` | act on its own subtree or its services | `act`: `interrupt` (a pause: the turn ends, and the agent waits for its next row), `fresh` (the same reset as `delegate`'s option, decided), `answer` (a child's open prompt by id and label, through `Prompts`), `resume`, `stop`, `move`, and for a service `send`, `restart`, `stop`, `hand` | `interrupt`, `answer`, `resume`, `stop`, `move`, `service_send`, `service_restart`, `service_stop`, `service_hand` |
| `wait_for(event, opts)` | be told when something happens, never poll | `event`: a delegate idle or its report, a job done, a service's line, port or exit, an answer, and an extension's events (a CI run, a review, a merge) | `service_wait` |
| `serve(name, argv, opts)` | hold a program that outlives a turn | `host`, `forward`, `local`, `keep`, `timeout` | `service_start` |

`wait_for` answers at once with the subscription's id; when the event fires, the agent gets one
message, so an idle agent wakes to it and no agent ever polls. An event that already happened
since the moment the call names fires at once.

**The verbs are the model's monitor** (decided). Each verb's act is legal only in the states the
spec's transitions allow it from: a `steer(:resume)` of a delegate that is running, a `message`
along no edge, a `stop` before the report is handed, a `delegate` under a parent that ended.
`Team.operate/4` checks the act against the target's state, read before the claim, and refuses
anything else with `{:refused, {:not_legal, state, act}}`, so the protocol checked in TLC is the
one enforced at run time. The table of legal acts per state is written once beside the spec it
comes from, and a test checks it against the spec's actions, so the two cannot drift. Today's
`fix_check/2` and `Grants` checks are its first rows.

**Every tool call is checked before it runs** (decided). The framework's `PreToolUse` hook sees
every call of every agent and answers by policy: allow, correct (`updatedInput`), deny with a
reason that names what to do instead, or hold for a decider. Policies are the app's data, per
role and project, beside the extensions' guards; the framework's own (a move's drain, a budget,
a heavy command's wrapper) are policies too. Each decision is a row, written before the
answer, so every check is counted and replayed. A rule that must never be broken is a
permission deny rule in each agent's Claude Code settings, from the app's config, which Claude
Code enforces itself and which holds while the framework is down (decided, F-162's new-9);
hooks keep the soft and helpful work (corrections, context, counts, leases) and fail open. No
supervised session is launched with `--bare`, which skips hooks.

**Intercepted, not added.** Native Claude Code goes on as the agent knows it, with the
framework's hooks deciding:

- a heavy `Bash` command is rewritten (`updatedInput`) into a wrapper that takes a lease, runs
  where the `Scheduler` places it, streams its output and exits with its code (F-157), so the
  `run` tool goes once that is built. Built in F-171 on the workstation (`Runs`): the app's
  list of heavy commands (a pattern and a class each) rewrites a matching call, after the app's
  own callback lets it run, into `'<home>/bin/caf-run' <class> <tool_use_id> <agent> --
  '<command>'`; the wrapper asks for the lease over the intake's port under the tool call's id,
  prints one `queued` line while it waits, then `exec`s the command, so its output and exit
  code are the command's and the lease's holder is that process (`{"run", "<pid> <start>"}`),
  released once on any end, a kill included, read by `ps` (`Schedule.tla`'s shape `Native`);
  a refusal prints one line with its reason and retry time and exits 75; with no answer it
  asks again once a second until 30 s by the clock have passed since its first ask with none
  (F-217), then runs without a lease and says so, as a hook fails open; one ask is bound by
  curl's `--max-time`, the plug's `:wait` and 5 s, and an ask cut there is no answer (F-218).
  The `run` tool, its late end and `MCP.caller/3` were removed in F-176 (F-171's new-3); the
  operator keeps no
  `run`, since a landing is the app's own `Jobs.run/6`;
- `run_in_background` and `Monitor` stay native; during a move's drain they are denied with a
  reason (as today). Claude Code gives a background command a stdin that never closes, so a
  program that reads it waits for ever and holds a delegate's report; every background `Bash`
  command the app's callback lets run runs as `exec </dev/null; <command>`, a correction of the
  framework's own, always on (built in F-180, `Intake.Background`). A pass carries it with no
  decision, so Claude Code's own permission rules still decide (measured on 2.1.322); an ask
  carries it beside the ask, whose prompt shows the corrected command, and a corrected pass
  still meets the prompt (both measured on 2.1.322 in the default permission mode; F-182);
- Claude Code's own question tool (`AskUserQuestion`), in a session no person attends, opens a
  prompt as `ask` does and is denied with a reason that says the answer comes as a message, so
  the agent asks with its natural tool. Until B10 builds this, its dialog is read off the screen
  as a menu (F-230, below): the stopgap that keeps a main session's question from waiting
  unseen while a delegate's report queues behind it (F-223's new-5). It stays right after B10:
  where a person attends, or runs a session by hand, the dialog is drawn and nothing intercepts
  it, and the screen is then the only place it shows;
- Claude Code's `Agent` tool stays native, its subagents read and counted; for subagent types
  the app names, the hook denies with a reason that names the `delegate` call to make, since
  `updatedInput` can change a call's input but not the tool (F-162's new-4);
- a budget or step cap reached denies the next tool call with a reason, and the parent is told
  once; the same calls repeated with the same input are raised by the framework itself as a
  `stuck` event, told to the parent with the calls as its facts (decided); neither ever ends the
  agent.

A hook that corrects a call (`updatedInput`, or a deny whose reason names the call to make)
is preferred to a bare deny, and context a hook adds states facts ("the parent sent …"), never
orders, and stays under Claude Code's limit for added context (a longer text goes as a
pointer to its file). Claude Code's hooks fail open: a hook that times out or errs lets the
call go on, and the design keeps `onFailure` at "continue" so a framework that is down never
refuses a tool call. So an intercept is enforced only while the framework answers; what must
hold regardless is a deny rule in the launch settings, never a hook alone, and a call that went
on unanswered is a fact the `Watch` counts (F-162's new-9).

**Off the agents' list**, to the app's surface: `answer_startup` (a prompt the app answers),
`end_main`, `withdraw` (built: since F-176 `MCP.tools/2` lists these operator-only tools to the
operator alone, and `MCP.operate/3` serves them; F-172's new-5), a main session's
move and resume (the operator's alone, as decided), the leases (asked by `Team` for every
start, `Hosts` for every job), and `reload` (the framework reconnects an agent's tools when its
list changes; F-162's new-2 says what must be measured first). From 25 tools to 7, and at most
one verb per extension.

### Metrics and healing

Both are folds of what is already recorded: every act a row in the `Ledger`, every status write
a fact, nothing pruned. No metric is counted by code sprinkled through the parts.

**Metrics** are named folds, each with its evidence (the rows it counted), queried by
`Watch.metrics/2` over a window (built in F-199 as `CodingAgentFramework.metrics/2` over
`Watch.Metrics.fold/2`, below) and summed by `Watch.digest/2`. The first named symptoms:

| Symptom | Evidence |
|---|---|
| `idle_untold` | a delegate idle with no report, and the time until its parent was told (F-150's notice) or acted |
| `stuck_dialog` | a session on a startup dialog, a held permission request or a screen `Screen` cannot read, and how long |
| `start_failed` | a start or resume refused or unknown, by reason |
| `resent` | a row made due again, a row settled unknown, a row nearly delivered twice (two marks of one key) |
| `waiter_lost` | a waiter cut with a row due, and the time the row waited |
| `typed_refused` | a typed write refused or unknown |
| `lease_wait` | each grant's wait, each refusal by reason, by class and module |
| `ended_hard` | kills, ends by `Recoveries`, restarts of the framework, raised errors |
| `guard_fired` | an extension's guard that denied or corrected a call, by guard |
| `stuck` | one agent's same tool call with the same input, or the same result, many times in a row, from the hooks' rows; told to its parent as an event |
| `capped` | a budget or step cap reached, and a `Stop` hold at Claude Code's cap of blocks |
| `unenforced` | a held hook that went on unanswered (the framework down or past its deadline) |
| `restarted` | an agent's, host's or account's process restarted by its supervisor, and one whose restart budget ran out |
| `prompt_wait` | each prompt's time open, by kind and depth, and the ones past their deadline |
| `limited` | each usage limit of an account: its window and reset, the agents it ended, the time each waited and the remedy taken ("Usage limits") |

**Every answer and a person's interventions are rows** (F-194, from F-179's new-4, so the
metrics read who did what and when from the ledger, never from a guess). Each answer through
`answer/4`, of every kind, is one row in `Acts`, claimed before its owner takes it and settled
by the owner's answer (`Prompts.answering/4`): actor who answered, target the prompt's agent,
act `answer`, and in its detail the prompt's id and kind, the choice and when the prompt
opened; the row's `claimed_at` is when it was answered. A person's intervention is one row of
actor `person` (or the name an app gives, `parts: %{interventions: %{person: …}}`), target the
agent, written once per fact by `Interventions` (one per host, in `caf_recoveries`):

- `typed`: a `UserPromptSubmit` of an interactive agent's session whose prompt carries no mark
  of a row `Mailbox` handed that agent (every text the framework puts into a session carries
  `[delivery <uuid>]`);
- `interrupt`: Claude Code's interrupt line in an interactive agent's transcript (`[Request
  interrupted by user]`, or `… for tool use]`, both checked by name in the 2.1.322 binary) on a
  turn no `interrupt` act of the framework's was claimed in.

- `attach` (F-199, from F-194's new-2): a viewer attached, written by `TmuxSampler`, which reads
  the server's clients (`list-clients`) at each sample: a client not there at the last sample
  is one row, target the agent whose tagged pane its session shows, under its key
  `attach:<host>:<server>:<tty>:<created>`, so a restart writes none twice. No hook is set: a
  framework that was down reads the attach at its next sample.

**One reading of the metrics** (F-199, from F-194's new-1): `CodingAgentFramework.metrics(config,
since:, until:, by:)`, the `Watch` box's `metrics/2`, reads the rows once, in one read-only
snapshot of the instance's store, and folds them (`Watch.Metrics.fold/2`, a pure module with no
table of its own). The rules are those of the baseline an app measured itself by before it
moved onto the framework, so the two compare (decided in F-199's brief):

- **Cuts** are UTC: `by: :day`, `:week` (ISO, Monday to Sunday) or `:all`. A delegate counts in
  the period it started, a recovery in the period it acted, a prompt in the period it opened, a
  person's act in the period it was claimed, a usage limit in the period it began (the last two
  confirmed in F-202, from F-199's new-4).
- **Stalled**: a delegate on which a stall's symptom fired, once, by its own row, the bound the
  symptom's own; a stall that cleared before any symptom fired is not counted. Its other
  symptom is a `Stop` that never came, its report taken from the transcript by a recovery.
- **Late**: a report that reached the parent by a recovery's path: (a) its `Stop` lost and the
  report taken from the transcript by a recovery, (b) held behind a background command and
  released by its healer, (c) relayed more than 60 s after it was taken. Each says which.
- **Killed**: a kill of a delegate's process with no act of the framework's, a crash included,
  a delegate killed twice counted twice; restarted by a recovery, the resumes after such a kill.

| Metric | Rows | Rule |
|---|---|---|
| `started` | `delegates` | each row, by its `created_at` |
| `reported` | `delegates`; `messages` | the reply or notice to the row's `brief_uuid`; its time, that row's `created_at` less the delegate's |
| `stalled` | `delegates`; `symptoms` | `stuck_background` on the delegate's name while the row is the name's latest; or a `Stop` that never came, the row's `taken_by` `transcript` |
| `late` | `delegates`; `messages`; `acts` | (a) the row's `taken_by` `transcript`; (b) the report stored after the `stuck_backgrounds` healer's `end` on its delegate; (c) the report's `delivered_at` more than 60 s after it was stored |
| `killed`, `restarted` | `delegates`; `acts` | each `killed` record of `Delegates`, keyed by the row and its resumes, and no `stop`, `end`, `end_main` or `move` claimed on its name since the kill before it (or its start); each resume after such a kill by its outcome |
| `dropped` | `messages` | a report settled `unknown`, or made due again |
| `limited`, `moves` | `symptoms`; `acts` | each `limited` symptom, its account and window, and its time from the reset to its pass; each `move` of `Limits`, by outcome |
| `prompts` | `messages`; `symptoms`; `holds`; `acts` | each ask, remedy prompt, hold (by its `held_at`), open `Prompts` recorded (act `opened`) and prompt an answer row names, opened and answered, by kind, with who answered and the time to answer; a hold settled by an actor was answered by it |
| `recoveries` | `acts`; `symptoms` | each act of a healer (`recoveries:`, `absent_mains:`, `stuck_backgrounds:`, `limits:`, `delegates:`) or a person's remedy, by outcome; and each symptom asked of a person |
| `interventions` | `acts` | each answer of `answer/4`, each `typed`, `interrupt` and `attach` fact under its own key, and the operator's `stop`, `end` and `end_main`, by act and by actor |

A rule whose fact no row holds yet counts nothing, and its metric names it in `unread`, so a
zero is never read as measured; since F-202 no rule has one. Each metric carries its evidence,
the rows it counted.

**The facts the rules read** (F-202, from F-199's new-1, 2, 3, 5 and 6 and F-194's new-4), each
written once, when it happens: `Delegates` writes `taken_by` on the row with its report
(`result`, `transcript` once its process was gone, `turn_end` for an interactive turn read
ended) and records each kill it sees in `Acts` (act `killed`, keyed
`killed:<host>:<row>:<resumes>`) before it decides between a resume and a failure; `Intake`
writes a hold's `held_at` with its row, never moved by its settle; `Mailbox` writes
`delivered_at` with `delivered`; `Prompts` records each prompt's open in `Acts` the first time it
lists it (act `opened`, keyed `opened:<host>:<prompt id>`, its kind, agent and `opened_at`). A
row written before F-202 has none of them, and is read as F-199 read it.

Time in each state (per agent, per status) is a fold of the status facts. `look(what: :stuck)`
is the agent-facing view of the same folds for its own subtree.

**Healing**, in three tiers:

1. **Detect and record, always.** A symptom found is a fact with its evidence, shown in the
   digest, whatever happens next.
2. **Act only by an approved remedy**, triggered only by facts in the `Ledger` (a fold, never a
   model's reading of a log). The allow-list is rows the operator writes: a symptom, a
   remedy (an act of `Team.operate/4`, such as reopening a lost viewer, ending an orphan by its
   record, telling a parent of an idle child), and a cap per hour. A remedy is claimed in the
   `Ledger` on the symptom's state, so it acts once per state; its precondition is checked
   against the state read before the claim (`Team.tla`'s `Needed`); it is verified after; when
   the cap trips, the healer stops acting on that symptom and opens a prompt.
3. **Prompt for everything else**: a prompt of kind `remedy` with the evidence and a proposed
   remedy, whose answers are "act once", "add to the allow-list" and "leave it".

The list narrows on its own and widens only by the operator (decided): a remedy whose verify
fails is dropped from its symptom's list at once, with a note to the operator saying why, and
comes back only by the operator's approval.

This tier is for the world outside the BEAM (a lost viewer, an orphan, an idle child). A crash
of the framework's own code is OTP's to heal, within its restart budget ("Processes and
restarts"); the two meet at the top, where a budget run out is a prompt too.

The healer never ends a working agent (a remedy whose target's turn runs is refused before the
claim), never changes code, and never retries: a remedy that did not help is a new symptom for a
person. Today's `Recoveries` (detect, act once, verify) is the healer, and its acts are the
default allow-list the app may narrow. `Heal.tla` (F-182) is its contract: it instances `Claim`,
and checks `OncePerState`, `RecordedFirst` (the remedy's row before its act),
`UnknownNotRetried` (an unknown outcome is a prompt, never tried again), `CapToPrompt` (no kind
passes its cap in a bound, and the next is asked), `NarrowsAlone` (no widening but the
operator's, and a remedy whose verify failed is off the list), `OnlyApproved`, `OnlyOnSymptom`
(`Boxes.tla`'s `NeverWorking`) and, as liveness, that every symptom state is acted on or asked
(`ActedOrAsked`), each with a `Break_Heal_*` configuration. `Boxes.tla` instances it with the
stuck turn as its one kind, so the parent's fix and the healer's remedy race on one `Ledger`.

**One shape for every remedy** (F-182). A remedy is never a mechanism of its own: it is an
entry on the allow-list (a symptom kind, its one remedy, its cap per bound), and the healer
takes it in one order. The symptom's state is recorded in `Watch` first; a state with a row in
`Acts` is decided by that row's outcome; a kind off the list, or past its cap, is asked; else
the remedy is claimed in `Acts` on the symptom's state (its key the symptom's), acts, and its
answer is read: ok is verified after, and a failed verify drops the kind from the list and asks;
refused, unknown or cut by a restart is asked. A kind whose remedy is nil is shown, never asked.
The cap's count is a fold of the healer's rows in `Acts` within the bound, so a restart keeps
it. A `remedy` prompt's answers are "approve" (the kind back on the list, the operator's
widening) and "leave". A prompt asked for its bound (the cap reached, or a main absent again
within it) offers "act" and "leave" instead (F-190, from F-189's new-7), since its kind is on
the list and "approve" would widen nothing: "act" is the person's act, the remedy once, which
the healer takes at its next check while the state is still read, under a claim in `Acts` whose
actor is the person, never counted in the healer's cap (`Heal.tla`'s `AnswerAct` and
`ActOnlyForBound`, `Break_Heal_ActAnyPrompt`, `Break_Heal_ActAsHealer`). A prompt stays while
its target shows the kind at all, and passes with it.

**A person's act, read** (decided in F-192, from F-190's new-1, new-2 and new-4). The answer
"act" is `{:ok, :answered}` before the act runs: the act's outcome is its row in `Acts`, the
person's claim and then how it ended, and the inbox shows the prompt answered and, once the act
settles, the act's row. A person's claim names its healer in its `detail` (`healer`, the
healer's actor, `Acts.claim/6`'s `healer:`), and each healer's `init` closes, through
`Acts.interrupt/2`, the claims its restart cut whose actor is its own or whose `detail` names
it. So a healer cut between a person's claim and its act leaves the row `interrupted`, never
acted on, not `claimed` until the framework's next start (`Heal.tla`'s `SettleCut`, which
settles any claim; `Break_Heal_CutOwnOnly` settles only the healer's own and fails
`ClaimsEnd`). A person's act is verified as the healer's is, and one that fails its verify
narrows the list as the healer's does, since narrowing is always safe; only the operator's
approve widens it again. Built in F-192: the claim's `healer` and its close. Not built: the
inbox's reading of the act, which is not yet one function of the rows (F-192's new-1); until
then the act's row is read with the console's `acts(caf, …)`.

Built so far (F-182): `Heal.tla`; `Watch` (`caf_watch`) with the record, the list from the
config's `remedies` and `remedy_bound`, and the cue `watch`; `Recoveries` as the healer of its
two acts (`lost_viewer` by `reopen`, `end_owed` by `end`, the default list, 10 per hour); the
`remedy` kind in `Prompts`; the app's `symptoms/2` and `remedies/2`.

**One clear** (F-182's new-2, built in F-183). A `remedy` prompt's answer is the person's clear
of its state (`Watch.clear/3` is the answer "leave"), and `Recoveries.clear/2` is gone: a viewer
lost a third time within its window, or an end whose outcome is unknown, is acted on again from
the answer's time, which the healer copies onto its own row in `Acts` (`cleared_at`), where its
keys and counts read it. A prompt that passed with its target clears its state the same way,
since no answer can come to it (F-183's new-3). A claim of the healer's that ended badly with
its state still open is asked (`Heal.tla`'s `Ended`), so a cut ask is not lost. A person's
answer elsewhere that already decided the state is its clear too (F-206): an absent main's
resume that waited at a limit and that a person left (`leave` on its `limit` prompt) is
asked and cleared at once as that person (`Heal.tla`'s SettledLeft), so no `remedy` prompt asks
them again.

Built in F-183: `absent_main` (`AbsentMains`, in `caf_recoveries`, after `Mains` in the tree),
modeled with `stuck_background` in `Remedies.tla`, which instances `Heal.tla` beside
`Boxes.tla`'s stuck turn, with `ResumeOncePerBound` and every property of `Heal.tla` through
it. An absence is a main's agent row `stopped` with reason `exited`, one state per process
that went (its `started_at`); its resume is `Mains.resume_main/3`, which takes the
`Scheduler`'s lease; an ok is verified from the row at once.

**A background command outlives its report** (measured on Claude Code 2.1.322, F-184): a
headless turn that starts a background `Bash` command writes its `result` while the command
runs, so `Delegates` takes the report then, never held up. The command's end
(`task_notification`, and `background_tasks_changed` listing none) starts a turn of Claude
Code's own, which opens with a new `system`/`init` and ends with a `result` that names no
message: `Stream.Fold` reads that init as a turn running, so nothing is written into it, and
its result is told to the parent as a turn of its own (F-155), never as a second report or a
reply (`Remedies.tla`'s `OneReport`, `Break_Remedies_LastResult`). The process meanwhile holds
its cap and lease, and `Sessions.stop/2` refuses it `turn_running`.

**When a delegate reads idle after a background command** (F-204, from F-196's new-6). The
command's end and the init of the turn it begins are two events in the log, and a read can
fall between them. So a command's end read while the turn reads ended makes the fold
`waking`, stamped with that read's time: busy, not idle, until that turn's init begins it and
its `result` ends it. Only then does the delegate read idle again, and `Mailbox` hands a
parent's message on only on an idle read, so none goes into that turn (`Remedies.tla`'s
`NoMessageIntoOwnTurn`, `Break_Remedies_IdleAtEnd`). An end during a running turn joins that
turn and changes nothing. A release that starts no turn at the end would leave the delegate
busy for ever, so the wait is bounded: past `Stream`'s `wake:` (30 s by default, the config's
`parts` `stream` `wake`) with no init read, the delegate reads idle again and the fold counts
it in `unwoken` (`ReadsIdleAgain`, `Break_Remedies_NoBound`). The model takes the bound as
longer than the gap between an end and its init, so it passes only where no init comes; the
release check records that gap with the background command.

**An agent's background commands in the tree** (F-259, `Background.tla`). `Tracker.agents/2`
gives each agent `background`: `%{count, since, source, groups}`, or `{:unknown, reason}` where
no source can know, never a count of 0. A headless delegate's is its `Stream` fold's `tasks`, each
stamped with the read that saw it start (`source` `stream`). An interactive session's comes from
two sources, measured on Claude Code 2.1.322's bundle. The `Stop` input's `background_tasks`
lists each task in flight; a command is one of type `shell`. The session file says `shell` while
a `local_bash` task is not finished after the turn, and `idle` once none is, and stamps
`statusUpdatedAt` at each write. No hook fires when a command ends between turns. So a file
whose status was written after the newest `Stop` row says the count now (`session_file`):
`idle` is 0, `shell` at least 1. Otherwise the newest `Stop` says it (`stop`). With no `Stop`
row and no such file, it is `{:unknown, :no_stop}`. A `busy` file says nothing of commands
from before its turn, and an older file never empties a newer `Stop`
(`Break_Background_StaleFile`). An agent with no process has none (`process`). `groups` is a
host's read of the process's groups (`StuckBackgrounds.Groups`), asked with `agents/2`'s
`groups:` option: a count on Linux, `{:unknown, :no_proc}` on macOS, nil when not asked. It
decides nothing, since a group may be an MCP server (F-259's new-1).

Built in F-184: `stuck_background` (`StuckBackgrounds`, in `caf_recoveries`, one per host):
a running headless delegate whose fold's turn ended with a result while Claude Code still
lists a task (`Stream.Fold`'s `background`), and a process group its process started that has
used no CPU time for `quiet:` (ten minutes), read from `/proc/<pid>/stat` of the group's
members on Linux (`StuckBackgrounds.Groups`) and `unknown` on macOS, never stuck. Claude Code
spawns each shell command detached, its own group, and no event names its pid, so a group is
any led by a descendant of the delegate's process outside its own group (F-184's new-1). One
state per group (its leader's pid and start time); the remedy is TERM to the group by that
record, once per state; its outcome is read from the next `background_tasks_changed`: a task
gone from it is recovered, all still listed fails the verify. No partial report goes
(`StuckAfterReport`). And `hooks_silent` (`HooksSilent`): the newest tool call in an agent's
transcript older than a bound with no `Intake` row of its session written since, shown only.
Both read at the tree's `interval` as well as at their cues (F-190): a hung command writes
nothing to the stream, so no cue would read its group again. Not built: `mcp_dropped` (F-183's
new-2).

The first remedies on this shape, decided (F-180's new-6), each a small unit:

| Symptom | Read from | Remedy | Its bound |
|---|---|---|---|
| `stuck_background` | a delegate whose report was taken while Claude Code still lists a background task of it, and a process group of its process used no CPU time for a bound, read from `/proc` on Linux; on macOS it reads `unknown`, never stuck (F-184) | end that group by its record (its leader's pid and start time); its outcome read from the next `background_tasks_changed`; no partial report; off by default (shown only) until a run on Linux records the group's shape, since a quiet stdio MCP server spawned the same way would read as stuck; an operator turns it on with `remedies:` | once per state |
| `absent_main` | a declared main session whose process is gone while the tree runs | one resume through `Mains` under the `Scheduler` | once per absence; a second absence within a bound is a `remedy` prompt |
| `hooks_silent` | a tool call the transcript shows with no `Intake` row of its session within a bound (F-184) | none: shown only | — |
| `mcp_dropped` | an agent's MCP connection gone | none yet: shown only | — |
| `limited` | an account's usage limit ("Usage limits", F-181) | `press_stop`, `go_on`, `move` | as "Usage limits" says |

A usage-limit remedy is an instance of this healer: its symptom `limited`, its remedies
`press_stop`, `go_on` and `move`, each an entry on the list with its cap, recorded, claimed,
verified and asked as every other; `Limit.tla` says when each is legal. A limit kind's ask is
its `limit` prompt on the agent row where `Limit.tla` names one (a press whose outcome is
unknown, a word or a move refused or unknown, a claim a restart cut), never a `remedy` prompt
beside it, so a person is asked about one wait once (F-186's new-4); only a kind off the list
or past its cap is asked in the `Watch`.

### Extensions

An app brings its own powers (a knowledge base, connectors to issue trackers, pull requests and
project boards) as extensions. An extension is a bundle the app registers in its config, built
on what Claude Code already understands, so the agent is told enough every time and never
flooded:

- **one verb at most**, its acts as an option (`issues(act: :comment, …)`), served by
  `Team.operate/4` with the same checks, rows and timeouts as the seven;
- **a skill** that teaches it: Claude Code shows its one-line description always and reads the
  body when the work calls for it, so the bundle's long text costs nothing until it is needed;
  the framework writes it into the agent's launch, never copied into a repository;
- **context at the right moment**, by the framework: entries relevant to a brief attached to it
  as `delegate` stores it, and entries relevant to a prompt or a tool call given by the hook's
  `additionalContext`, each a short pointer with its id, never a whole record;
- **events in**: an outside event (a CI run ended, a review, a merge) recorded as a fact in the
  `Ledger`, which fires the subscriptions of `wait_for`;
- **guards**: a rule that exists to catch a repeated mistake becomes a `PreToolUse` match that
  corrects the call or denies it with a reason naming the right verb, counted as `guard_fired`
  so a guard that keeps firing is a symptom, not a longer prose rule;
- **scope**: roles (main session, delegate, reviewer) and projects, so an agent sees only the
  verbs, skills and context its work needs.

Built so far (F-154): the bundle in the config as `CodingAgentFramework.Extension` (a name,
a scope, and its tools, each a name under the bundle's, a schema, a description and a function
of the caller and the arguments), served on the agents' MCP endpoint beside the framework's
tools, listed and called only where its scope holds the agent (`Grants.may_call?/3`), each call
a row in `mcp_calls`, its crash and its deadline answered `unknown`. The config names each
bundle as data, `{module, opts}` (F-188): the tree makes it with the module's `bundle/2`, given
a lookup of the parts that a tool calls when it runs, so the config holds no function. Several tools per bundle
stand until B5 makes the verbs (F-154's new-1). The app's `PreToolUse` callback corrects a
call (F-169): `{:allow, updated_input: map, additional_context: text}` and `{:deny, reason,
additional_context: text}`, written as Claude Code's `updatedInput` and `additionalContext`
(at most 10,000 characters; a longer one, or any answer out of shape, a value that does not
encode as JSON among them (F-201), is a pass whose row's `problem` names why, never a crash).

An extension adds no protocol of its own: its events go through `Mailbox`'s subscriptions, its
acts through `Team`'s claims, its questions to a person through `Prompts`, and its context is a
pure function of the brief or the prompt. One that needs a protocol over time models it first,
as any part does.

Where a rule goes is decided by what it is: always true and short, the root instructions; needed
for a kind of work, a skill or the brief; needed at a known event, a hook's context; with no
exception, a guard, not text.

### Processes and restarts

The framework is an OTP application in shape as well as in name: what can fail alone runs alone,
and a crash is healed by its supervisor, deterministically, from the rows.

- **One agent process per agent.** `Sessions` keeps a `DynamicSupervisor` of agent processes,
  each a small `GenServer` found by the agent's name in a `Registry` of the instance's own (named
  from the app's instance name, never a fixed atom). It owns its agent's row and life: the start
  and its settle, the stop, the move's phase, its startup dialogs, its idle bound, its turn
  state, the reads of its pane. It is the one writer of its row. The real agent, Claude Code,
  stays outside the BEAM under dtach, so no crash of the framework ends it. Today one `Sessions`
  process serves every agent, and one slow pane read or one stuck agent delays the rest (as
  F-153's run showed); after B4 one agent's trouble stays its own.
- **A restart re-adopts, never relaunches.** An agent process's `init` reads its row and its
  `Holder.Process` record and settles by `Start.tla`'s adoption, as a whole restart of the
  framework does today: a live process is adopted, a gone one settled, a start under way
  settled at its deadline. Nothing is started again because a process restarted. A call to it
  that a crash cut answers `{:unknown, :restarted}` to its caller.
- **A held process leaves the app's cgroup where the host says so** (F-274). On Linux, an app run
  as a systemd user unit with `KillMode=control-group` keeps every process it starts in that
  unit's cgroup, and each stop or restart of the unit sends them TERM, then KILL: every `dtach -n`
  holder, and so every agent and service, ended with the app. A host whose `scope` is
  `:systemd_user` (`Host`; the config's `scope` for the workstation) starts each holder through
  `systemd-run --user --scope --collect --expand-environment=no --unit=caf-<key>-<name>`, `<key>`
  from the holder's directory so two instances never share a unit, and each tmux client that may
  start the server through a scope of its own. A `systemd-run` that fails (no user bus, no
  lingering, a unit of that name still running) refuses the start, `{:refused, {:scope,
  output}}`; it never starts the holder without a scope. `:none` is the default, and macOS has no
  cgroup to leave. `KillMode=process` on the app's unit is not the fix: it leaves the app's own
  child watchers behind, and it is the app's choice, not the library's.
  - The scope changes nothing for a stop by the framework: `Holder.Process` still signals the
    held program's process group by its record, and the scope, empty, is collected.
  - On the app's restart, the holders, their sessions and the tmux server live on in their
    scopes, and the app re-adopts them by their records and sockets, as above. A viewer pane is
    the tmux server's child, so it lives on too.
  - `systemd-run` is the host's own program, found on its `PATH` with the rest, never one devenv
    brings: it is a client of the running user manager, which only the host's own systemd is, and
    a host without systemd has none.
- **The restart budget is the healing budget.** Each agent process runs under its own small
  supervisor with an intensity (`max_restarts` in `max_seconds`, the app's, three in a minute by
  default). Past it, that supervisor gives up; the dynamic supervisor does not restart it
  (`:temporary`), and `Sessions` records the fact and opens a prompt of kind `restarts` for a
  person, with the crashes' reasons. The agent runs on under dtach meanwhile, unsupervised, which
  the view shows; the person's answer starts its process again, which re-adopts.
- **The same per host and per account.** Each host has a supervisor of its own (its reaper, its
  connection, its sampler, its copies' and jobs' and services' readers), and each account its
  readers (`Registry`, `Transcripts`, `Usage`), so a host that drops or an account whose files
  cannot be read restarts alone. Each has an intensity, and past it a prompt.
- **The top.** The instance's supervisor is `:rest_for_one` in the order each box needs, the
  base first. Escalation goes up the tree as OTP's does; a restart of the whole instance is the
  restart every spec already models, and past the top's intensity the app's own supervisor
  decides, which for the example is a person.

**How the specs meet OTP.** Every spec already has a restart of the framework: all memory lost,
the rows kept, every row re-read. A crash of one agent process is the same step for one agent:
its in-memory state (monitors, calls under way, timers, a press's task) lost, its row kept, and
the others untouched. B1 makes the restart in `Start.tla`, `Delegate.tla`, `Dialog.tla` and
`Move.tla` a step per agent (`Restart(a)`, named `RestartAgent` as in `Boxes.tla`; built in
F-164) beside the whole one, and checks every invariant under any interleaving of them, bounded
by `MaxRestarts`, which counts both. The budget is a bound, not fairness: a
`gave_up` agent leaves the liveness properties, which then require a prompt (`Prompt.tla`'s
`Escalated`). `Delivery.tla` keeps `Mailbox` one process: its one row in flight per addressee is
its state, and a restart of it is the whole one already checked; the addressee's own restart
cuts the hand under way in its agent process (`AgentCut`), and the mark is kept for the
evidence (F-163's new-2). So the specs say what a crash may do, and OTP only decides when.

### Prompts

Everything that waits on a person, or on an agent's parent, is one prompt in one inbox,
answered from one place, whatever asked and however deep in the tree. Today an ask, a held
permission request and a startup dialog are three mechanisms with three answer functions; each
keeps its mechanism (the `Mailbox` row, `Intake`'s hold, `Sessions`' checked press), and
`Prompts` is the one front of all three and of every kind after them.

A prompt is a row: its owner's key (so one state opens one prompt), the asker's path (main
session, delegate, the delegate's own Claude Code subagent), its kind, the question, the options
by label, a default, a deadline, its owner and its status (`open`, `answering`, `answered`,
`expired`, `withdrawn`, `lost`). Its kinds and owners:

| Kind | Opened by | Its answer goes to |
|---|---|---|
| `permission` | `Sessions`, from a held `PermissionRequest`, a subagent's included (the hook names it); a headless delegate's `can_use_tool` request held in its `Stream` fold (F-190) | `Intake`'s hold; `Stream.answer/5` |
| `question` | `ask`, and Claude Code's question tool intercepted | `Mailbox`, a row to the agent |
| `startup` | `Sessions`, from a dialog read on the pane: trust, imports, and a numbered menu no rule names before the session file, an onboarding menu say (`start_menu`, F-203, its options, no default); and any numbered menu no rule names on a running interactive session's screen (F-198), its options and `esc`, with no default and no deadline | `Sessions`' checked press; a menu's read back, the marker on the label before Enter |
| `plan` | `Sessions`, from a held call of Claude Code's plan exit | `Intake`'s hold |
| `elicitation` | `Sessions`, from an MCP server's request for input, held by its hook | `Intake`'s hold |
| `limit` | the start's owner (`Delegates`, `Mains`), for a start or resume every usable account refuses at a usage limit: its row `waiting` for the soonest reset, `wait` (its default at its deadline, the reset plus a margin) or `leave` (F-196); `Sessions`, with no deadline, for a `limited` agent past its bound of go-ons, a menu still shown after a press whose outcome is unknown, or a wait still shown past its reset ("Usage limits"); for a main session limited past `move_after` with another account that has room, offering "move to <account>" beside "wait" (F-181) | the owner's row: it waits and picks its account again at its deadline, or is refused `left`; `Sessions`: go on now (the press cleared, the bound started again), move (a main's, only by this answer), or leave it |
| `usage_credits` | `Sessions`, at Claude Code's limit menu, only where the account's record allows credits | `Sessions`' checked press of the label answered: "stop and wait" (its default at the deadline) or the credits |
| `login` | `Logins`, from an account whose `claude auth status`, read before a start or a resume, says it is not logged in (F-181) | a person, at `bin/caf-login`, then `check`: the login is checked again, and the prompt closes once a check finds it logged in |
| `exit` | `Sessions`, from Claude Code's own exit prompt read on the pane | `Sessions`' checked press |
| `remedy` | the `Watch`, for a symptom state its healer leaves to a person (F-182) | the `Watch`: "approve" puts the kind's remedy back on the allow-list; "leave"; for a state asked for its bound, "act" (the remedy once, under the person's claim, F-190) in place of "approve" |
| `restarts` | a supervisor whose budget ran out | its process started again |
| `stop_cap` | the `Stop` hold, at Claude Code's cap of 8 blocks in a row, in place of being overridden (decided) | `Intake`'s hold: go on, or let the turn end |
| `policy` | the app (confirm a landing, say) | the app's callback |

**The rules.** A prompt is answered once, by its rightful answerer: a person, through the app,
for every kind; the asker's parent, through `steer`, for `permission`, `plan` and
`elicitation`, as a fix under a claim (`Grants`). An answer is checked against the prompt read
before its claim (a label it offers, a prompt still `open`), marked `answering`, handed to its
owner, and settled by the owner's answer: answered, refused (back to `open`), or unknown (kept,
never sent again). A person who answers on the pane first makes it `withdrawn`, read by its
owner. At its deadline a prompt whose kind declares a safe default (a `limit`'s wait) takes it,
recorded as the framework's; any other is `expired` and stays shown, since Claude Code no
longer reads the hold. A restart keeps every `open` row and settles an `answering` one by its
owner's evidence, as a dialog's press is settled today. Every write cues `prompts`.

**When an answered prompt leaves** (F-196, from F-192's new-1 and F-193's new-2): once its
owner's row no longer waits on the answer, the same read that showed it. A hold leaves once it
is not `held`, a dialog once its press was sent, an ask once its answer or withdrawal is
stored, a start's wait once it is answered for this reset (and opens again at a newer limit),
a login once a check finds it logged in. A `remedy` answered `act` is the healer's to take at
its next check: it stays, `answering`, while the person's act has no row in `Acts` or that
row is open, and leaves once the row has ended; its outcome is that row, a fault in the fault
ledger when it failed, interrupted or was not verified. A state the healer no longer reads
before it takes the act (the viewer came back, the main resumed by itself) passes, by the
`open` row's rule (`Watch.pass/4`, F-203), and its prompt leaves then with no row in `Acts`,
its outcome "passed before its act". Any other `remedy` answer leaves at once, its act the
`Watch`'s own.

Built so far (F-179, B6's first part, `caf_prompts`): `Prompts` keeps no table. A prompt is
its owner's row read by one function: `Intake`'s hold of a `PermissionRequest` (kind
`permission`, a subagent's named) or of a `Stop` at the cap (`stop_cap`), `Sessions`' agent
row on a startup dialog (`dialog`), and `Mailbox`'s ask (`ask`); each names its agent, the
agent's parent and project, its text and options, when it opened and its deadline (`Intake`
keeps a hold's on its row). `CodingAgentFramework.prompts/2` reads them (filters `agent`,
`subtree`, `kind`), every read that opens, moves or closes one cues `prompts`, and
`CodingAgentFramework.answer/4` (instance, id, choice, who) checks the prompt read now and hands
the choice to its owner, whose own guard lets one answer in (a hold moves only from `held`, an
ask's answer and withdrawal share a key, a dialog's press is marked first); a late or second
answer is refused `{:refused, :settled}`, and `{:withdraw, reason}` withdraws an ask. When a
delegate's prompt opens, its parent gets one notice through `Mailbox` (kind `prompt`, from the
delegate, keyed by the prompt). The operator's `answer_startup` and `withdraw` go through it.
F-182 added the `remedy` kind: the `Watch`'s symptom row the healer asked, open while it is
`asked`, answered by `Watch.answer/5`; it is not told to the agent's parent, since it is the
`Watch`'s wait, not the agent's. F-181 added the `login` kind: `Logins`' row of an account a
check found not logged in, id `login:<account>:<the refused check's time>`, as a menu's id names the
read that found it, so an account refused again after a login is a new prompt with its own id
(F-205), no agent, answered `check` (`Logins.recheck/3`).
F-186 added the `limit` and `usage_credits` kinds from the agent row's usage limit, opened by
its healer (`Limits`, not `Sessions` as the table says: `Sessions` is the row's writer), ids
`limit:<agent>:<until>` and `usage_credits:<agent>:<until>`, answered through
`Sessions.answer_limit/6`. F-196 added a start's `limit` prompt: the row of a start or resume
that every usable account refused at a usage limit, `Delegates`' `waiting` row (id
`limit:start:delegate:<row>`, its parent the start's) or `Mains`' (`limit:start:main:<row>`),
open until answered for this reset, its deadline the row's, answered `wait` or `leave` through
the owner's `answer_wait/4`; and a `remedy` answered `act` kept `answering` until its act's row
ends, read from `Acts`' file (`acts_db:`). F-190 added a headless delegate's permission request: `Prompts` reads each `Stream`
fold's held `can_use_tool` request as kind `permission`, id
`permission:stream:<session>:<request id>`, no deadline (Claude Code waits on the stream),
answered once through `Stream.answer/5` (the fold marks it answering before its line goes, so
a second answer, the parent's through `answer` among them, is refused `settled`), and told to
the parent once as any delegate's prompt. `Prompt.tla`'s header says why no property changes. F-194 made each answer through `answer/4`
a row in `Acts` ("Metrics and healing"). F-198 added any numbered menu on a running interactive session's screen (`Menu.tla`): a menu
`Screen` reads by its shape (kind `menu`) is the agent row's `menu`, which `Sessions` writes
from a read of the pane every `look:` ms; the inbox shows it as kind `dialog`, id
`dialog:<agent>:<at>:menu` (`at` the read that found it), its options' labels and `esc`, no
default and no deadline, open until a press of it is sent, and gone once a read finds no menu,
whoever answered it. `answer/4` hands a label to `Sessions.answer_menu/5`: an act in `Acts`,
the mark `pressing`, then the `Inlet`'s checked press, the marker moved and read back on the
label before Enter (`esc` is Escape); sent or unknown, never pressed again. F-203 (F-198's new-4) added
such a menu that a start meets before its session file as a startup dialog, kind `start_menu`
(`Sessions.Dialog`), its options with no
`esc`, no default (the app's `dialog:` callback is never asked, and `dialogs:` refuses the
kind) and no deadline, pressed by `answer_dialog/5` as the `Inlet`'s read back of a menu.
F-206 (F-203's new-2) keys a start's menu by its read, as a running one is: its `at` is the
read that found it, kept while the pane shows that menu (its title and options) and its answer
is not sent, so a start that shows several menus one after another asks a person each, its
prompt `dialog:<agent>:<at>:start_menu`, its answer naming that read (`answer_dialog/5`'s
`at:`) and its act's state the read too; each is pressed at most once. F-254 reads closed
prompts and keeps a hidden mark, still with no row of its own. `answered/3` pages the prompts
that closed, newest open first and at most 200 a page, from the ledger alone: each prompt's
`opened` fact (now with its text, options, parent and project, and written by the read before
an answer too) and its `answer` row (choice, who, when; an ask's withdrawal and its reason).
One that left with no answer through the inbox reads `closed`, with no one named. `hide/3` and
`unhide/3` write a fact in `Acts` (act `hide` or `unhide`, target the prompt's id); `read/3`
shows the latest as `hidden: nil | %{by, at}` and filters on `hidden:`. Nothing that answers
reads the mark, so it cannot change what an answer presses, and a closed prompt's marks are
ignored, since they are read only for prompts open now. Not yet: the parent's answer through `steer` (still `answer` under `Grants`' claim), the
`expired` prompts kept shown, and the kinds that need a reading first.

`Prompt.tla` (B1) is its contract: it instances `Hold` (one response, its deadline, its holder's
death) and `Claim` (once per state), and checks `OneAnswer`, `OnlyRightful`, `NotAfterDeadline`,
`DefaultOnlyDeclared`, `KeptAcrossRestart` and `Escalated` (a budget run out is a prompt), with
liveness that every prompt is answered, expired or withdrawn; `Dialog.tla`'s answer and
`Team.tla`'s `Ask` and `AnswerClaimed` become its instances.

### The app's surface

One config and one supervisor in; a few calls and one stream of cues out.

- **In.** `CodingAgentFramework.child_spec(config)`: one config, checked whole at start with each
  refusal naming its key (the home, hosts, accounts, projects, ports, capacities, the
  dialogs' answers, the callbacks for `PreToolUse` and `Stop`, the idle bound, the restart
  budget, the remedies' allow-list and the extensions; the table below). One supervisor starts every box in its order; the
  app wires nothing else. The config's `instance` names the tree: it is unique per app (a
  second start of a running name is refused `{:instance_running, name}`) and 1 to 100 bytes
  with no control character, as `Config.new/1` checks it (F-174's new-3). A start while a tree
  of that name still exits (its parent's restart of a tree just killed) waits for its named
  `Registry` to end, up to `restart_wait`, so the restart is not refused (F-195).
  A home belongs to one tree at a time (F-215, `HomeLock.tla`): two trees on one home would
  share its `caf.db`, its tmux and dtach sockets, its leases and its tool home. A tree takes the
  home before it opens anything in it and holds it for its whole life; a start on a home
  another tree holds, in this VM or another, is refused `{:home_held, holder}` at once and
  touches nothing. The take is one try that gets the lock or is refused, and the lock is one
  the operating system gives back when its holder dies, so a death leaves nothing a person
  must clear, and the next start takes the home.
- **Calls.** `operate(caf, actor, verb, args)`: the seven verbs as the operator, and the
  operator's own: `end_main`, a main session's `move` and `resume`, a remedy's `approve` and
  `revoke`, a symptom's `clear`. `answer(caf, prompt, choice)` answers any prompt, in place of
  `answer_startup`, an ask's answer and a request's answer. `hide(caf, prompt, who)` and
  `unhide(caf, prompt, who)` set an open prompt aside for a person's console and bring it back
  (F-254). `prompts(caf, filter)`, `answered(caf, page)` (the prompts that closed, F-254),
  `view(caf, scope)`, `metrics(caf, query)`, `digest(caf, window)`, `query(caf, filter)` and
  `holds(caf, opts)` (the leases, their jobs, the copies and the pressure, F-266) read.
- **Cues.** `subscribe(caf, topics)`: one stream of `{topic, ids}` for every write, from the
  `Ledger`. The app re-reads by id, as every view does; `prompts` is the inbox's topic. Every
  topic a part writes is subscribable (each part's `writes/0`). A subscription lives and dies
  with the tree: `subscribe/2` answers `{:ok, %{ref: ref, tree: pid}}`, the tree's supervisor,
  which the app monitors, and on its exit it subscribes again once the tree is back and
  re-reads; nothing claims to keep a subscription across a restart of the whole tree (F-176).

Built so far (F-169, B3's start): `CodingAgentFramework.child_spec/1` and `start_link/1` in
`caf_surface`, from one `CodingAgentFramework.Config` checked whole by `Config.new/1` (a key
it does not know, the tool callbacks, the extensions by `MCP.extensions/3`, and a home too long
for its tmux socket are each refused by name); the supervisor is the tree `caf_example` used
to wire, `Ends` included, since an app that left it out would keep an ended owner's services
(F-169's new-1). `caf_example` keeps its config file, its console and `Run`. F-174 built the
cues: `subscribe/2`, `unsubscribe/2` and `topics/1`, the instance found by its name in its own
`Registry` (the tree's `:names` child, after the reaper), the subscriptions held by `Cues` in a
table the tree's supervisor owns, and a topic no part declares refused. F-176 made every
written topic subscribable (`writes/0`, the cue table in `subscribe/2`'s doc), named the tree
in `subscribe/2`'s answer, listed the operator's own tools to the operator alone, and removed
`run`. F-179 built `prompts/2` and `answer/4`, whose fourth argument names who answers
("Prompts"), and the `prompts` topic. F-182 added `symptoms/2` (the `Watch`'s record), `remedies/2`
(the allow-list, and the operator's `approve` and `revoke`), the config's `remedies` and
`remedy_bound`, and the topic `watch`. F-195 added a tree with no agents (`agents: false`:
the reaper, the instance's `Registry`, `Cues`, `Acts`, the `Tracker`, the `Scheduler`,
`Copies` and `Jobs`, the `Scheduler` asking only `Jobs` about a lease), `agent_rows/1` (the
agent and delegate rows read once through a read-only connection to the store the config
names, as `processes/1` reads the holder's records), the tool hooks as `{module, opts}`
(`CodingAgentFramework.ToolHooks`, each callback given the live `part` lookup), and the
restart that waits for the old tree's `Registry`. F-197 made `post_tool_use/3`'s answer a
replacement of the call's output (`{:replace, response}`, "A held `PostToolUse`"). F-201, from
an app's first run on the tree: each tool hook's event carries the `cwd` Claude Code posted (nil
without one, never guessed), so a rewrite of a command that depends on where it runs can apply;
a config with `agents: false` needs only the keys that tree reads (the table below) and makes
no tool home; `agent_rows/1` also takes the instance's name, read from the config its running
tree keeps in its `Registry`, since a hook's `opts` are plain data and a struct there, the
config among them, is refused by name (`{:not_data, module, {:struct, struct}}`); and
`post_tool_use/3` may answer `{:context, text}`. F-265 added `agent_rows/2`, for an app that
keeps its records by Claude Code's session id or by a key in an agent's `meta`: `session_id: id`
or `meta: {key, value}` (a string or an integer, of JSON's same type), filtered in the store's
query (`Sessions.Table.by/3`; the session id by the index `agents_session`, a `meta` key with
no index), each row with its `turn`, the tree's state as `Tracker.agents/2` reads it, from the
`Tracker` the tree registers in the instance's `Registry`. A row resumed into a new session id
is found by its current id only. F-236 added `session_start/3`, answering
`{:context, text}` for a session's start, carried by a `command` hook since Claude Code runs no
`http` hook there ("A held `SessionStart`"). F-214 made the rule F-195's new-2 asked for
a check: a home is agentful or agentless for its whole life, since an agentless tree asks no
owner of a delegate's, main's or run's lease and would leave an agentful tree's unreclaimed.
`CodingAgentFramework.Home` keeps one row in the home's own database (`home`, in `caf.db`),
written by the first start on the home before any part starts and read by every later one: a
home with no mark and no agent, delegate or main rows takes the kind of the tree that starts
on it, one with such rows (it ran before the mark) is marked `agents`, and `start_link/1` of
the other kind than the mark answers `{:refused, {:home_kind, recorded}}` with nothing
started and no row of the tree's own written. `home_kind/1` reads the kind (`:agents`,
`:agentless` or `:new`) with no process started, since `agent_rows/1` answers no rows for an
agentless home and for a new one alike. The kind is judged by rows, not by the tables an
agentful tree made, because a lease follows its owner's row: a delegate's lease names its row
in `delegates`, written before the lease is asked for, and a main's names its start over the
main's agent row, so a home whose tables hold no row has no lease an agentless tree would leave
unasked (F-214's new-3). F-215 made a home one tree's at a time (`HomeLock.tla`):
`CodingAgentFramework.Home.Lock`, the tree's first child and so its last to stop, takes
SQLite's write lock on `<home>/home.lock`, an empty file of its own, by an immediate
transaction it never commits (`Store.hold/1`, one try with no busy wait), before `Home.mark/1`
or any other open under the home, and keeps it for the tree's life. The OS gives that lock
back when the VM dies, and the holder's connection is closed when it ends; the tree ends when
its holder does. A refusal names the holder's record, `<home>/home.holder` (its instance, its
VM's OS pid, its node and when it took the home), which a normal stop removes. A start of the
same name waits for the old holder to end within `restart_wait`, as it waits for the old
`Registry`. `home_kind/1` takes no lock. F-260 added `conversation/3`: an agent's
conversation as entries (`prompt`, `assistant`, `tool_call`, `notice`, `interrupt`, `system`),
each read by the fold's own rules (`Transcripts.Fold.entries/2`), a delivered message's entry
with its row's uuid, an opaque cursor for what came since, and the rows still queued for the
agent. The read runs in the host's `Transcripts` (`Transcripts.conversation/3`), through that
host's shell, at most `limit` entries and `max_bytes` per file, so no call reads a whole
transcript again; a cursor whose bytes changed, or of another file, starts that file again
from its end and says so (`reset`). F-267 made a read with no cursor read the file's last
`max_bytes` and answer the newest entries, with a `next` cursor that reads forward and an
`older` one that reads back one block a call (`before:`), its edge at a whole line's start;
and `queued` adds Claude Code's own queue (its `queue-operation` lines enqueued and not yet
taken, read by the one parser `Fold.queue_operation/1`), each entry with its `source`. The
agent's row and the rows queued for it are one `Store.snapshot/2`: a read-only reader of the
WAL file reads the last commit while a writer holds the lock, and only a lock that shuts
readers out makes it wait, at most `busy_bound`, before `{:refused, {:sqlite, :busy}}`. The
agent's row names its host; only the workstation has a `Transcripts`
today, so a session on another host answers `{:unknown, {:host, {:no_reader, host}}}`. F-266
added `holds/2`, an app's panel of what holds the machine: every unreleased lease and the last
`ended:` released ones (at most 200), each with its class, module, holder, units, grant and
release times, and for a job's lease the job's command, copy, log path (both on its host),
state and exit code; the first 200 copies with their paths and turns; each resource's capacity
and held units; and `Scheduler.pressure/2`. The leases, the jobs and the copies are read once
each, read-only, from their parts' files, leases first, and the pressure from the running
`Scheduler`. A job's row keeps its command (`argv`) from its ask. A heavy command's lease
(`caf-run`) shows its agent, its tool call's id, its process and its release; its command and
log are kept nowhere (F-266's new-1). The other calls are B3's rest.
The config answers the room the home leaves for an agent's name (`Config.name_room/1`, F-172), and the tree hands it to `Delegates` and
`Mains`, which refuse a longer name `{:bad, :name, {:longer_than, n}}` before any row;
sockets stay in the home. A service's socket is named by the first 16 hex digits of the SHA-256
of its name (`Services.socket_key/1`, F-205), not by the name, so its path is 31 bytes after its
host's directory whatever the name (the workstation's is `<home>/ws`): a name has no room to
keep, and only a directory longer than 72 bytes refuses a service's start, `{:refused,
{:socket_path_too_long, path}}`. A home longer than 69 is that for the workstation, so
`Config.new/1` refuses it for a tree that runs services, `{:bad, :home, {:longer_than, 69}}`
(F-207), not at the first service's start. The name stays in the row and the log.

**The config** (`CodingAgentFramework.Config`, whose module doc gives each key's example).
Every setting the tree reads is a key here, checked once by `Config.new/1`; a value out of
shape is refused `{:bad, key}`, or `{:bad, key, reason}` where the reason says more. The tree
takes nothing else from the app (F-188): a part's process is never handed in, only options.

| key | what | default |
| --- | --- | --- |
| `home` | the framework home, absolute, at most 69 bytes (93 with `agents: false`, which runs no service, F-207) | required |
| `instance` | the tree's name in the app, unique, 1 to 100 bytes | required |
| `programs`, `workstation` | the workstation's programs, and its host name | required, `"ws"` |
| `hosts` | the other hosts, name to `%{host, dir}`, each found when work is placed there (`Hosts`, F-280) | none |
| `accounts` | the Claude accounts' names | required, unless `agents: false` |
| `projects`, `mains` | the projects, and the main sessions declared on them | none |
| `main_model`, `operator` | a main session's model; the operator's name | `"opus"`, `"operator"` |
| `permission_modes` | each role's `--permission-mode` (`main`, `interactive`, `headless`), pinned, not the account's own default; `manual` asks before a tool runs, so the request reaches the inbox (F-227) | `auto`, `auto`, `manual` |
| `ports` | `%{intake, mcp}` on 127.0.0.1 | required, unless `agents: false` |
| `git` | the author agents commit as, and each project's override | no author |
| `claude`, `env`, `user` | what every launch shares; the OS user (required on macOS) | required, `env` with its `path` for every tree (F-203); with `agents: false` only `env` (F-201) |
| `tool_timeout`, `margin` | Claude Code's MCP tool timeout, and what `run_delegate` keeps under it | 1 h, 1 min |
| `interval` | ms between the timed readers' reads | 2 s |
| `resources`, `lease`, `job_lease` | the `Scheduler`'s capacities and the units each start asks for | seat 4, slot 2 |
| `pressure` | how the host's pressure is read | the host's own |
| `tool_hooks` | the app's `pre_tool_use`, `post_tool_use`, `stop` and `session_start` (F-236) callbacks, as `{module, opts}` (`ToolHooks`, F-195) | none |
| `usable` | which accounts the app lets a start or a resume use, as `{module, opts}`: `usable?(account, opts, part)` answers `true` or `{false, reason}`, and the tree hands it to `Mains`, `Delegates` and the `Mover` beside `Logins.usable/3`, an account usable only if both say so (`Usable`, F-207) | none: the framework's check alone |
| `heavy` | the app's heavy commands, run under a lease | none |
| `extensions` | the app's bundles, each `{module, opts}`, made by the module's `bundle/2` | none |
| `dialogs` | a startup dialog's kind to the label pressed; any other waits on a person | none |
| `secret_file` | the file of the hooks' secret, never the secret itself | `<home>/intake.secret` |
| `restarts` | the tree's `%{max_restarts, max_seconds}` | 3 in 5 s |
| `parts` | each part's own bounds and deadlines, by its key (`Config.parts/0`) | each part's |
| `remedies`, `remedy_bound` | the healer's allow-list and its caps' window | the healer's acts, 1 h |
| `viewer` | every viewer's `{columns, rows}`, handed to `Sessions` and `Recoveries` alike (F-190) | `{200, 50}` |
| `press_see` | ms each read of a dialog press or a typed write waits for the screen to show its keys: the tree's `Inlet`'s `see:`, set there alone: every bound that waits on a press is derived from the `Inlet`'s (F-242, F-245) | 10 s |
| `undeclared_cues` | `:route` or `:raise` a cue on a topic no part declares | `:route` |
| `agents` | `false` starts only the parts a lease needs (`Config.agentless/0`), none that runs or reads an agent (F-195), and no tool home, so its config needs only `home`, `instance`, `programs` and `env`'s `path` (F-201), and refuses `usable`, `tool_hooks`, `extensions` and `dialogs`, which no part of it reads, `{:bad, key}` (F-209); a home keeps its kind for its life, the first start records it and `start_link/1` of the other kind is refused `{:home_kind, recorded}` (F-214) | `true` |
| `restart_wait` | ms a start waits for an instance of its name still exiting, before it is refused `{:instance_running, name}` (F-195) | 5 s |

An app like a development loop's (views, builders, gates, landings) needs nothing more: a
builder is a `delegate` with `review`, a gate is a heavy command or a job, a landing a job of
class landing that opens a `policy` prompt where the app wants a person to confirm, the inbox
`prompts` re-read on its cue, and each view a `view` or a `digest` re-read on a cue.

### Inside the boxes

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
`caf_tmux`, `caf_holder` with `Holder.Process`, `caf_store` with `Reader`, `caf_cues`,
`caf_tool_home`), then
readers and writers (`caf_registry`, `caf_transcripts`, `caf_usage`, `caf_accounts`, `caf_cli`,
`caf_screen`, `caf_inlet`, `caf_stream`, `caf_intake`, `caf_sampler`, `caf_acts`,
`caf_scheduler`, which uses only `caf_store`: the owners' answers and the allowance are
functions the embedding app hands it), then
`caf_sessions`, then `caf_tracker` (its sources made from the tables' metadata: the readers',
`Acts`', `Sessions`' and `Delegates`') and `caf_recoveries`, then the parts built later. The remodel adds `caf_store` (R1),
`caf_acts` (R10, in place of `Grants.Claims` and `Recoveries`' table) and `caf_cues` (R11), and
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
| `Programs` | the absolute path of tmux, dtach, claude, git, gh, rsync, ssh, flock, sh, sleep, rm, kill, env, ps, cat, tail, curl (the waiter hook and a heavy command's wrapper), ssh-keygen (git's signing) and sysctl (macOS's memory-pressure level) on each host, given (from devenv, as the framework's own development and gates use) or looked up on the host's `PATH`, each checked against its supported versions at start with a clear error per one missing or out of range; no other part names a fixed path. It also names the host's operating system (`uname -s` beside the lookup, the VM's own for a local host), which bounds a launch's argument (F-155) | — |
| `ToolHome` | where every tool the framework runs keeps its state, in the home (F-155): the environment every launch, job and service sets (`GH_CONFIG_DIR`, `GIT_CONFIG_GLOBAL` with `GIT_CONFIG_NOSYSTEM`, the four `XDG_*_HOME`, `GIT_SSH_COMMAND`), the options every ssh to a host takes (`-F <home>/ssh/config -o UserKnownHostsFile=<home>/ssh/known_hosts`), and the git config it writes at the app's start: the author it is given, SSH signing with the home's own key, `gh` as GitHub's credential helper, and each project's override for every repository under its checkout. A pure module | — |
| `Store` | a pure module over SQLite: open with WAL and a busy wait bounded by the monotonic clock (2 s, `Store.busy_bound/0`; then `{:refused, {:sqlite, :busy}}` from `open`, `write` and the reads, or `Store.Busy` raised by a statement, within 500 ms of the bound on a loaded host, F-216, F-224), the schema and its added columns, `query`, `rows_by_id`, `update`, upsert, a reads row, and a load that fills a newer build's fields with their defaults; every table of the framework is opened through it. A term in a column is stored by one rule (`Store.text/1`): an atom as its name, any other term as canonical JSON, never `inspect` text; a writer converts what an earlier build stored when it opens its file (`Store.convert/3`) | no table |
| `Reader` | a pure module beside `Store`: the loop every reader runs (read on an interval or a call, diff against what it wrote, write with a reads row, cue), and a `Tracker` source made from the reader's table metadata | no table; each reader its own |
| `Cues` | one per instance: each part declares the topics it reads and the ones it writes, and `Cues` hands each cue to the `Tracker`, to every part that declared its topic, and to each of the app's processes that subscribed to it (`subscribe/2`, by a plain send, monitored); the order in which the system settles is the library's, not the app's | no table |
| `Accounts` | the Claude accounts, each with its own config directory `<home>/accounts/<account>/claude` | — |
| `Usage` | each account's allowance, its weekly and five-hour windows, from what Claude Code hands its status line and a headless session's `rate_limit_event`, the newer of the two, never stale (a window past its reset is whole again); the account limited until its reset, from any agent's limit record ("Usage limits"); `Usage.Room`, the one rule of an account's room (the tighter window, none while limited), which `Usage.pick/4` (the usable account with the most room, F-181) and `Usage.Allowance` (the `Scheduler`'s gate) share; a `Reader` | its readings, with the limit's `limited_until`, window, `can_spend` and evidence |
| `Logins` | each account's login, read with `claude auth status` under the launch's own environment and kept 10 minutes (F-181): `Logins.usable/3` (prepared and logged in) is what `Mains`, `Delegates` and the `Mover` give `Usage.pick/4`, with the app's own check after it when the config has a `usable` (`Usable`, F-207; a refusal reads `{:app, reason}`), and what the `Mover` reads of a named `to:` before its claim, refusing `{:account, to, reason}` with nothing begun (F-190); a refused login is a `login` prompt until a check finds it logged in | `logins` |
| `Tmux` | sessions, panes, tags, keys and viewers on one server, and the one-command check of every write to a pane; a contract with a CLI (its fake is a test aid) | — |
| `TmuxSampler` | samples each server's panes and each host's held sockets, reports a held agent with no viewer, and cues when a held socket goes away; a `Reader` | `tmux_samples` |
| `Holder` | dtach: hold a process in a clean environment, open a viewer, list sockets and whether each lives | — |
| `Holder.Process` | a held program's record: pid, start time (always as `LC_ALL=C TZ=UTC ps -o lstart=` prints it, its runs of spaces made one) and socket, read in one batch; "dead" as the pid gone and the socket absent or stale; an end by TERM, then KILL, only by the record's pid and start time. Every part that holds a program keeps this record on its own row | no table |
| `ClaudeCLI` | the command line and environment of a session, per role and account, and the paths of a headless session's stream directory | — |
| `Registry` | one per host, over every account the framework holds: reads Claude Code's `<config>/sessions/*.json`, and so each held agent's pid and its session file's `status`, each file live by its pid and its `procStart`, written as `ps -o lstart=` in UTC (macOS) or as a bare integer, the start in clock ticks (Linux, F-246); a start in ticks is turned into the `ps` form as it is read, the `ps` text taken between two reads of `/proc/<pid>/stat` that both hold those ticks, else the file is `replaced` and its row has no start (F-252), so every row's start is in the one form every check and signal compares; a `Reader` | `registry_sessions` |
| `Transcripts` | one per host, over every account: a session's transcript tail, its chats, its subagents and its tool calls (a sidechain's under its agent id, F-235; on 2.1.322 read from each subagent's own file in `<session id>/subagents/`, found by listing it on each read; a file never read whose meta says the subagent finished is not read, and a running one's first read takes at most its last 1 MB, F-237; a main transcript with no stored fold is read the first time from its last 1 MB too, its fold `partial`, F-244), and whether a transcript holds a delivery's line; a `Reader` | `transcripts_sessions` |
| `Screen` | a pure reading of a main session's screen and dialogs, per Claude Code release, from real fixtures captured with a script: the startup dialogs (trust, and external imports with the paths it lists), any numbered menu by its shape (F-198), typed commands and their result lines, the box before a typed write, a dim prompt suggestion in it read as no text | — |
| `Inlet` | the checked typed write into an interactive session with no waiter: `Screen`'s box check, then a paste into a buffer named for the write, under `Tmux`'s one-command check (F-279), one per host; and the typed commands a session's start or a tool needs (a startup dialog's checked press, `/mcp reconnect`, the interrupt key, and the operator's `/reload-plugins`, whose result line it reads outside its write's step, F-233), and a read of a pane for `Sessions`. It is one transport of `Mailbox` | no table |
| `Stream` | a headless session's transport: a FIFO per process, a spool removed as the line's claim, the event log read from an offset, and its `can_use_tool` requests. Its fold of the log (each message's replay, each result) is evidence `Mailbox` and `Sessions` read; it keeps no delivery state of its own | `stream_delegates` |
| `Intake` | hook events in; one hold, of six kinds: `permission` (a person's or an agent's `answer`), `tool` (`PreToolUse`, the app's callback), `post_tool` (`PostToolUse`, the app's callback), `start` (`SessionStart`, the app's callback, from a command hook), `stop` (`Stop` held for the app's callback) and `waiter` (a main session's waiting Stop hook, answered with `Mailbox`'s due text) | `intake_events` |
| `Sessions` | the agent row: one row per agent, main session or delegate, with its kind, parent, project, account, launch options and model, held process and status; start, resume, and stop by SIGTERM once idle; the tree as one function of its rows; each session's turn state as one function per kind of session, from its evidence. Other parts read its rows only through `Sessions.Agents`, a pure module over a reader's own connection, which answers what each status means | `agents` |
| `Mover` | drains a session, a main session or a delegate, and moves it between accounts; its phase is a field of the agent row (`move`, with the accounts, its act and its deadline), which `Sessions` writes for it | — |
| `Mains` | each project's main sessions, as agent rows of kind `main` it declares in `Sessions`; the project's checkout, made once, and the pull after a landing; the start of one (`start_main`), through the `Scheduler` and the startup dialogs (F-141, `Checkout.tla`); its resume under a lease of its own, and its end, the operator's (`end_main`, F-143, `Team.tla`) | `checkouts`: each checkout's reading, for a view; `main_starts`: each start, the holder of its lease |
| `Delegates` | the delegate protocol only: its checks, the cap, the account pick, resume once, report a second kill, a turn at a usage limit no report and its word's resume (F-187); it hands the report to `Mailbox` as the reply to the brief | `delegates`: branch, brief uuid, resumes, whether the report was taken |
| `Mailbox` | every delivery: messages, replies, notices, reports, briefs, the words to go on and the app's word, stored, delivered once, in order per sender and addressee; one mark and settle, with the transport the target's kind chooses | `messages` |
| `Acts` | one ledger of acts: an actor's act on a target's state, written before it acts, once per state, settled after, closed as interrupted when a restart cut it, with a cue. Fixes, the operator's acts, recoveries, kills, resumes, starts and raised errors are its rows, and the fault ledger is a query of it | `acts` |
| `Scheduler` | one per instance, against `Schedule.tla`: every agent start, heavy run and landing asks it for a lease first ("A lease" below). A grant is one write transaction that checks each resource's capacity and inserts the row, with all of a landing's resources in one lease; a release is a compare-and-set on the lease id, so it happens once; a lease names the row of the work it admits, and is released only when that row's owner says the work ended (by its `Holder.Process` record; a row still starting is live), never because time passed. It reads pressure and each account's budget, never the load average | `leases`: id (the fencing token), request id, outcome (granted or refused), class, module, account, the units of each resource, the holder (the work's row), asked, decided and released times, and a refusal's reason and retry time |
| `Stacks` | the worktrees and `gh stack` chains of a main session's work | — |
| `Hosts` | one per instance, against `Host.tla` (F-280): what is known of each other host, `unknown`, `ready`, `away` or `lacking`. Each placement of new work there (a job's run, a service's start or restart) finds the host's programs over ssh within the placement's start timeout, with an rsync of 3.1.3 or later (the copy's times to the nanosecond), and keeps them for the reads of work already placed | no table: memory, found again after a restart |
| `Copies` | a host's copy of each worktree, brought in step by rsync before each job or service, and removed with the worktree | `copies` |
| `Jobs` | one-off commands on a host, in a copy: held, logged, ended by their exit or their timeout; each asks the `Scheduler` for a lease first, in the class its caller names, its row the holder (`Jobs.Work` answers for it), and its wrapper runs only under the fence of that lease ("A lease") | `jobs`, with each row's lease id and a lease refusal's reason and retry time |
| `Runs` | a heavy native `Bash` command under a lease (F-171): the `PreToolUse` policy that rewrites a call the app lists as heavy into the wrapper `<home>/bin/caf-run`, the wrapper itself, its endpoint on the intake's port (`Runs.Plug`), and the lease's owner, the wrapper's own process read by `ps` | no table: the lease is the row |
| `Services` | programs agents start and keep on a host, in a copy: held, owned, read, written to, restarted, with ports forwarded to the workstation; the forward is a second `Holder.Process` record of the service | `services` |
| `Tracker` | the state views read: the fold of every reader | — |
| `Watch` | the symptom record and the healer's allow-list (F-182, `Heal.tla`): each symptom state a fact (kind, target, state, since, evidence, source), recorded before anything acts on it and passed when no longer read; the list's acts (the healer's drop, the operator's revoke and approve), so a restart reads it as left; a state the healer leaves to a person is `asked`, the `remedy` prompt `Prompts` reads | `symptoms`, `remedy_acts` |
| `Recoveries` | the healer (F-182): records each broken state in `Watch`, acts only by the allow-list's remedy for its kind and under its cap, takes its act in `Acts`, acts once per state, verifies, drops a remedy whose verify failed, and asks for the rest; reopens a lost viewer, and so starts a host's tmux server again after it dies; ends an orphan's process, or one that did not exit after its end within its stop's deadline, by `Holder.Process` (`Sessions` itself never kills). Two states wait for a person, whose clear (the `remedy` prompt's answer, F-183) makes the next one new: a viewer lost a third time within a window, and an end whose process outlived the KILL (`unknown`, F-118's new-5); the fault ledger shows both | no table of its own |
| `AbsentMains` | the healer of `absent_main` (F-183, `Remedies.tla`): a main session whose process exited by itself, resumed once per absence through `Mains` under the `Scheduler`'s lease, on the same shape as `Recoveries`; a second absence of one main within the bound is asked | no table of its own |
| `Limits` | the healer of a usage limit (F-186, `Limit.tla`): each agent's limit record read onto its row, and each phase's remedy (`press_stop`, `go_on`, and F-191's `move` of a limit far from its reset through the `Mover`) on the same shape, written through `Sessions`, pressed through its checked press, the word stored through `Mailbox` or `Delegates` ("Usage limits") | no table of its own: the phase is the agent row's `usage_limit` |
| `Grants` | decides whether a caller may act on a target, by the edges of `Sessions`' tree; a pure module, handed the tree's function | — |
| `MCP` | the agent tools ("Agents working together"); each call is checked by `Grants` once, and each fix takes its act in `Acts` | `mcp_tokens`, `mcp_calls` |
| `Ghostty` | opens or focuses a session's terminal window | — |

**The order in which the system settles** (R11, F-131) is what each part reads. Each part that
settles on another's rows declares it as data, its `reads/0`: the topics (a cue's first word,
or a pattern of words with `*` for any one) and its own `cue/2`. Each part that cues declares
what it writes the same way, its `writes/0`: each topic's whole shape, `*` for each word it
fills in (`acts:*:*`), F-176. The embedding app hands the declarations to `Cues`, and names
each part's process to it as it starts; no part uses `caf_cues`. What an app may subscribe to
is the union of the two. In the framework's own tests (`undeclared_cues: :raise`) a cue on a
topic no part declares it writes raises in the part that wrote it, so a part's undeclared
write fails its tests; an app's default routes it as any other. A cue of each topic reaches:

| Topic | Sent by | Reaches, beside the `Tracker` (which reads every topic) |
|---|---|---|
| `registry:<host>:<account>` | `Registry` | `Sessions`, `Mover` (a move's stop is asked again only on this cue and the stream's) |
| `stream:<host>` | `Stream` | `Sessions`, `Delegates`, `Mailbox`, `Mover`, `Usage` (a headless session's windows and limit), `Limits` (a headless agent's limit) |
| `logins:<host>` | `Logins` | `Prompts` (a `login` prompt opened or closed) |
| `tmux:<host>:<server>` | `TmuxSampler` | `Sessions`, `Recoveries` |
| `watch` | `Watch` | `Prompts` (a `remedy` prompt opened or closed), the healers (`Recoveries`, `AbsentMains`, `StuckBackgrounds`, `Limits`: an answer is their clear) |
| `sessions:<host>` | `Sessions` | `Delegates`, `Mailbox`, `Mover`, `Scheduler`, `Mains` (a start that runs or is refused), `Prompts`, `AbsentMains`, `Limits` (a limit's phase moved, or a person's answer), the app's end of an owner's services |
| `mains:<host>` | `Mains` | `Scheduler` (a main session's start ended) |
| `transcripts:<host>:<account>` | `Transcripts` | `Delegates`, `Mailbox` (a waiter row's lines are read only on this cue, the waiters' and the take bound), `Usage` (a transcript's limit line, F-185), `Limits` (an agent's limit line, and a turn after it), `Interventions` (an interrupt line, F-194) |
| `delegates:<host>` | `Delegates` | `Mailbox`, `Scheduler` (a delegate's work ended) |
| `mailbox` | `Mailbox` | `Delegates`, `Mover` |
| `intake:<host>:<account>:waiters` | `Intake` | `Mailbox`, `Limits` (a turn ended: its screen read again) |
| `usage:<host>:<account>` | `Usage` | `Scheduler` (a queued request's window ran out) |
| `jobs` | `Jobs` | `Scheduler` (a job's work ended) |
| `intake:<host>:<account>` | `Intake` | `Prompts`, `HooksSilent`, `Limits` (a `StopFailure` or a `quota_auto_resume_*`: the screen read again, F-186), `Interventions` (a prompt a person typed, F-194) |
| `acts:…`, `services`, `copies`, `scheduler:<host>` (a lease's row, or `pressure: level` at each change of the level) | their parts | none |

No cue says that a host's job or service changed, so `Jobs` and `Services` settle their rows on
their own interval, as a reader reads, and `Stream` reads its logs on one; each of the three
cues its writes like every other part.

The LiveView side is a library of components over the `Tracker`, with one example app.

`caf_example` is the embedding app the example grows from (F-102): its configuration is data
(the framework home, the workstation, other hosts, accounts, projects, ports), read from a
JSON file checked whole at start with each refusal named, and `bin/caf-example` runs it with
the operator's console in IEx (F-146; the end-to-end run is `docs/e2e.md`); one supervision
tree starts every part in the order each needs, the reaper first, and one `Cues` per instance;
it makes the `start_id` of `Acts` once per start, and reads the hook secret, kept per home
(`Intake.secret/1`: made at the first start, readable only by its user, changed only by a
person, F-146's new-2, built in F-147), so a session held across a restart keeps its hooks. It
routes no cue by hand:
each part declares the topics it reads, `Cues` routes them, and `Jobs` and `Services` cue like
every other part, so no ticker sends a made-up topic (R11). It opens no part's table: the tree,
an agent's worktree and the agent a hook names are `Sessions`' functions (R9). What it still
wires that the parts do not offer (F-102's findings): it hands `Mains` its projects, each
naming its repository (`origin`), and the main sessions it declares, which `Mains` writes as
agent rows of kind `main` with no parent, so a main session can start its first delegate, and
the projects' `repo` is their checkout (F-141); `Delegates` launches each delegate with its own MCP config, from a
function of the agent's name the app gives it (`MCP.issue/2`); a job's late end is kept in its
job's row, which `Jobs` marks told and cues on `jobs`, for the app that ran the job to read (no
agent's tool runs a job since F-176: an agent's heavy command is its own `Bash` under a lease,
and a landing is the app's `Jobs.run/6`); and when a delegate's end is seen, `Services.owner_ended/3` runs on the cue of
the agent row's end. `Stream` and `Transcripts` are read on an interval, as `Registry` is, so a
delegate's `result` is read without waiting for another cue; that interval is the `Reader`'s
(R2). `Registry` also follows a turn in flight (F-281): a read that leaves a live session file
`busy`, `shell` or `waiting` reads again within `follow` (1 s, never later than the interval), so
the tree shows a turn's end within that and one read's time of the file, whatever the interval
and whichever part read last. A delegate ended after its report (by `stop`) is `ended` on its agent row, so the cue
shows it and its services end (F-103's new-2). `on_late_end` answers `:ok` or `{:unknown,
reason}`, and on the second the job stays owed for the next cue: keeping an end never needs a
crash (new-1). A delegate's reply to a message from `framework` goes to its main session, as
any reply does (new-4).

**How the flows go through the parts** (F-115):

- **A session's life.** `Sessions` writes the agent row first (`starting`), holds the program,
  and settles it by `Holder.Process` and the session file or the stream's init: `running`. Its
  turn state is one function per kind (`Sessions.Turn`): a headless session's from `Stream`'s
  fold, an interactive one's from the session file's `status` and `Intake`'s waiter. Only both
  together say an interactive turn `ended`; the file alone that reads idle is `idle`, which a
  write must check again (R8's box check), and the `Tracker`, which holds no waiter, shows that
  one read for a person, never to decide a write (F-113's new-2). Its end is SIGTERM
  once idle (or `end_session` for a headless one), and it is `stopped` once the process is gone
  and the socket dead. `Recoveries` ends an orphan by the same record, under its act in `Acts`.
  A move is a phase on the same row. A main session the app declares is a row `declared`
  until it starts; a delegate done for good is `ended`. The tree is every row of kind `main`
  and every delegate's row with its parent (`Sessions.Agents.tree/1`): an ended delegate
  keeps its edge, so what it kept goes to its parent and a message to it is settled ended,
  but no longer holds its parent's cap. `Grants` reads the tree from the table, and the
  `Tracker` folds its view's rows by the same function.
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
  nothing for the others). The six kinds differ only in their decider, deadline and response.
- **An act.** Every fix, recovery, kill, resume, start and raised error is a row in `Acts`,
  `{actor, target, state, act, start_id, status, outcome}`, written before it acts, refused for
  a state already acted on, and `interrupted` when a restart cut it. A start or a resume by
  `Sessions` has no state to claim (each call is an act); `Delegates`' own resume claims the
  delegate's row and resumes; a service's stop or restart claims its running process (pid,
  start time, restarts). Each is settled by its call's answer, by one rule
  (`Acts.answered/4`): ok `verified`, refused `failed`, unknown `unknown`. A raised error is a
  part's process that crashes, as the app sees it, recorded settled `failed`; a part's
  `{:unknown, reason}` is not, since its caller holds it and an act's row settles `unknown`.
- **A lease** (F-134, `Schedule.tla`; built in F-135). Nothing starts an agent, a heavy run or a landing
  without a lease from the `Scheduler`; it reads the host's own signals, so work it did not
  start still counts. A request names its request id, class, module, account and the units of
  each resource it needs (an agent's seat, a heavy slot, a lock); every lockable thing is a
  resource with a capacity. The account is read once, by the grant's budget gate
  (`Schedule.tla`'s `NoStartWithoutBudget`): no part reads a running lease's account after it
  (what the leases hold is counted per resource, not per account), so a delegate that a resume
  or a move puts on another account keeps its start's lease, whose row names the account the
  grant was read against, not the one it runs on now; the agent row names that (F-210). So the
  example's console says `lease 3: builder for app asked on work, …` (F-211).
  A request also names its holder: the row of the work the lease
  admits (an agent row, a job row), which its owner writes `starting` before it asks (F-134's
  new-1). The answer comes at once: `{:ok, lease}`; `{:queued, %{id: request_id, position:
  n}}`, its place when it was queued, after which exactly one more answer comes, the lease or a
  refusal, as a message, and no position updates (each message to an idle session costs its
  whole context); or `{:refused, {reason, retry_at}}`, `reason` one of `queue_full`,
  `deadline`, `{:pressure, level, reading}`, `allowance`. A refusal is final for its request
  id, holds nothing, is a row the `Tracker` shows, and is never a failed run. Requests are
  idempotent by request id: the lease is looked up before any refusal is decided, so a second
  request answers the lease already granted.
  - **Classes**, four and fixed, in this order: a person's main session, a landing's gates,
    builders, heavy runs. A class is served only when no waiting request of a higher class can
    be granted, a grant takes no unit a waiting request of a higher class needs (a waiting
    landing holds the next free unit of each resource it needs, F-134's new-2), and no class
    takes back another's lease. Inside a class the modules that ask take turns (an explicit
    rotation), and aging reorders only inside a class: a request that waited past the age goes
    first in its class, so it never passes the next. A landing takes all its resources as one
    gang lease, in one step, never one at a time.
  - **Gates.** Pressure has three states, read from the host (pressure stall time where the
    host has it, a memory-pressure level where it does not): `ok`; `high`, which admits no new
    heavy run; `severe`, which admits nothing new but a person's main session, which is always
    admitted (decided). Each account's budget is two fixed-reset windows, the five-hour and the
    weekly, from `Usage`'s readings; a request is admitted only while both have room. A spent
    budget is refused at once with `retry_at` the window's reset, never queued, and a queued
    request whose budget runs out is refused then; pressure that bars a class refuses its
    request at once too. An account with no reading, or a window its reading lacks, has room:
    an account has no reading until a session on it draws its status line. `severe` is taken at
    once; `high` only once each sample of a whole window asked for it (F-135); a lower state
    once no sample of a whole window asked for the current one or above, and then the highest
    any of them asked, so samples that flip between `ok` and `high` take `severe` down to
    `high` (F-273). With stall times, each level is a share of the span between two samples
    (2 s): `severe` is memory `full` (every task waiting on memory) over 1% of it; `high` is a
    `some` line over its share, cpu 25%, memory 10% or io 20%; `ok` is neither. Measured on
    the Linux workstation, memory `full` grew by under 0.001% of any span at rest or under the
    test suite, so 1% reads only a real stall (F-273). A sample at or before the last (a clock
    set back) only starts the next span. A pressure refusal carries the reading that set the
    level, `{:pressure, level, %{file, line, share, threshold, at}}`, in the answer and in the
    lease row's `reason`.
    On macOS the level is `sysctl -n kern.memorystatus_vm_pressure_level`: 1 (normal) `ok`, 2
    (warn) `high`, 4 (critical) `severe`, and any other value unknown, never `ok`: a sample
    that cannot be read changes nothing and is named in `Scheduler.pressure/2`, beside the
    level's source and its last sample's time; each change of the level is cued (F-171).
    Gates stop new starts only: an admitted session is never shed. Thresholds, reserves and
    the windows' figures are measured on the workstation, not modeled: each is an option with a
    default, a placeholder until it is measured (memory `full`'s is, F-273).
  - **The queue** is bounded per class and in memory (decided): a restart loses it, and a
    requester told `queued` asks again under its request id, which answers its lease if the
    grant was written before the restart. A queued request is refused at its deadline.
  - **A queued start that does not wait** (F-170; `Delegate.tla`'s `Queued`, `StartTold`,
    `StartToldOnce`, `StartNoticed`). `start_delegate` with `wait: false`, an agent's default
    on the tool (an agent that waits for a seat does no other work meanwhile), answers a queued
    lease at once with `{:ok, %{delegate: name, queued: position}}` and goes on. The operator's
    start waits by default (`Operator.start_delegate/7`'s `wait:`). The parent is owed the
    start's outcome, a mark on the delegate's row (`tell`) written before the answer, so a
    restart keeps it. Once the start has an outcome, started or refused with its reason and the
    time to ask again, `Delegates` tells the parent once, as a notice stored in `Mailbox` under
    a key of the row's own (`start:<host>:<id>:<created>`), then clears the mark: a restart
    between the two stores nothing twice (`Break_Delegate_StartNoKey`), and a mark kept in
    memory only would leave the parent never told (`Break_Delegate_StartOwedInMemory`).
  - **The end.** The lease lasts as long as its work. The `Scheduler` asks the owner of the
    work's row whether the work ended, which the owner answers by the row and its
    `Holder.Process` record (`Delegates.Work` for a delegate's row: live while it may still
    start, run or be resumed; ended once refused or done and its agent row free, which the
    row's status alone does not say; `Delegate.tla`'s `WorkEndedIsFree`, F-164; a start that
    reaches `Sessions` after its caller's deadline makes nothing, F-166); a row still starting
    is live until its owner settles it. While it runs it monitors each lease it holds
    and asks at each cue of the owner's rows; after a restart it asks about every unreleased
    row, releases it if the work ended and monitors it again if not. Both release by
    `UPDATE … WHERE id = ? AND
    released_at IS NULL`, so exactly one succeeds. A resource the lease guards (a heavy slot's
    script, a lock file) carries the lease id and refuses a holder whose id is not current.
    The first is a heavy run's slot (F-139): `Jobs` writes the lease id beside the job on its
    host before it sends the start; the job's wrapper takes that fence (`mkdir`) before it
    runs anything and runs only with its own id, and a start whose reply was cut is settled as
    never run only once `Jobs` took the fence itself. So a start that lands after its lease was
    released runs nothing, which `Copy.tla` had assumed never happens.
  - **Jobs and landings** (F-139). A job asks in the class its caller names: a landing's
    gates, a builder's suite, or a heavy run (the default); its row, written `asked` first, is
    the holder. A landing's job asks for every resource the landing needs in one request, the
    app's declaration: in the example a heavy slot and its project's landing lock
    (`land:<project>`, capacity one), so it is one gang lease. The app names the class in its
    `Jobs.run/6` (`CodingAgentFramework.job_units/3`); an agent's heavy command takes its class
    from the app's list of heavy commands (F-171). A refused job's row says why and when to
    retry, under a new job id.
  - **Accounts.** Holding several Claude accounts and moving work between them is allowed
    (decided), so the account is a resource with several entries; a start's account is
    chosen when it is admitted, and `Mover` moves a session later.

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
- another host may be away (asleep, off the network) and may lack programs, so nothing of it is
  read at the tree's start (F-280, `Host.tla`). Each placement of new work there finds its
  programs over ssh with `Programs.find/3`, bounded by the placement's start timeout, and
  answers at once: placed; `{:refused, {:no_program, host, names}}`, naming every program
  missing; `{:refused, {:old_rsync, host, line}}`, an rsync older than 3.1.3 (`line` its
  `--version`'s first); or `{:refused, {:host_away, host}}`, no answer within the bound. A
  refused placement writes no job row and marks a service's row `refused`. The next placement
  finds the host again, so it joins without a restart. A placement finds a ready host again
  too, since only a find shows that it still answers: one ssh per placement, and one more
  for the version of an rsync not yet checked. A read of work
  already placed (a log, a settle, a service's end) takes the programs kept, and a host not
  ready is found again for such reads at most once each `retry` (30 s), since they run in a
  part's own process on its interval;
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
- a job can bring files back: `Jobs.run/6`'s `fetch: [paths]` names paths that rsync copies from the
  host's copy into the worktree after the job ends. Nothing comes back unless named, and nothing
  is written over blind: the sync records each named path's size, time and hash, and the fetch
  writes a path only while the worktree's file is still what the sync sent; it answers the
  others as a conflict and leaves the copy's version on the host. Each path comes in under a
  temporary name, is compared after that write and before its rename into place, so the only
  window left for an edit to be lost is between that compare and the rename;
- `Jobs.run/6` answers `{:ok, %{exit: code, log: tail, fetch: :done | :none | {:conflict, paths} |
  {:unknown, reason}}}`; `{:unknown, {:timeout, %{fetch: f}}}` once the host ended the job at
  its timeout, with the fetch's outcome; `{:unknown, :dropped}` at the call's deadline with the connection
  down; `{:unknown, :no_exit}` for a dead socket with no exit file; `{:refused, {:sync,
  reason}}` for a cut sync, when nothing ran. Once an unknown job's end is read it is handed to
  the embedding app (`on_late_end`), saying that nothing was fetched; a later run fetches
  nothing for an earlier job. The tree keeps it in the job's row, marked told and cued on
  `jobs`, for the app that ran the job to read (F-176). A late end is handed on at least once,
  never lost: a repeat after a crash carries the same job id, so the receiver drops it. A job a restart left
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
clone under `<home>/checkouts/<dir>` (its repository's name, or its `dir:`), made once from the project's repository, on trunk. It
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

**How `Mains` does it** (F-141, `Checkout.tla`). The app hands `Mains` its projects, each
naming its repository (`origin`), and the main sessions it declares (name to project), which
`Mains` declares in `Sessions` before it answers its start. A project's checkout is cloned on
trunk under `<home>/checkouts/.<dir>.clone` and renamed into place once whole, so a
checkout at its path is always whole, and a start of `Mains` removes a clone a restart cut. A
pull is owed after a landing (`Mains.landed/2`, which the app calls until `Stacks` is built;
then `Stacks` calls it once it has seen a stack's layer merged into trunk, F-141's new-3) and at each
start of `Mains`, since a landing while it was down told nobody. It is cleared before its
fetch, so a landing during the pull owes the next; it goes only from a reading on trunk, clean
and not ahead, and is `git merge --ff-only`, which refuses a local commit and an edit it would
overwrite and carries any other, so an edit made between the check and the merge is never lost.
Any other reading holds the pull back, still owed, and the read after a person cleans the
checkout pulls; a clone or a fetch that failed waits for the next landing or start. The reading
(trunk, branch, clean, ahead and behind `origin/<trunk>` as the last fetch left it, and a state
word) is a row of `checkouts`, read on an interval and at each pull, which the `Tracker` shows.
`start_main` refuses a name any agent row holds but a declared main session of that project, a
start of that name under way, and the reserved names (`framework`, the operator's), all as
`{:running, name}`, and a project whose checkout is not made yet (`{:checkout, state}`). It
picks the account with the most allowance left, declares the agent row, writes its own row
(`main_starts`) `starting`, asks the `Scheduler` for a lease of class main session with that
row as its holder (`Mains.Work`: live while the start is under way and while its agent row may
hold a process or a move of it is under way), stores the brief from the caller, marks it by
`launch` and starts the session interactively in the checkout with the app's MCP config. A new
checkout is a folder Claude Code has not seen, so the trust dialog waits on a person ("Startup
dialogs"): the start answers `{:unknown, {:dialog, kind}}`, and its row runs once the agent row
does. A row a restart left `starting` is settled by the agent row of its call, or refused
`interrupted` at its deadline. A start refused once its brief was stored settles that one row
`ended` (`Mailbox.settle_row/3`, by its uuid), so it never goes in with a later start, while
other rows to the name stay queued (F-141's new-4). The app names a main session's model (its
launch's `model:`), and `start_main` takes an optional `model` that overrides it (new-8).

A stale `index.lock` in the checkout (a git command a restart cut) or a fetch that failed is a
state a view shows (`locked`, `failed`, with its reason); the framework never removes a file in
the checkout it did not write, and a person clears it. A pull a lock held back stays owed, and
the read after the person clears it pulls (F-141's new-6).

**A checkout under the project's name** (F-156, `Checkout.tla`'s `RenameOld` and `Repair`),
which a build before the directory names made, goes to `<home>/checkouts/<dir>` once, before
anything clones one there (`OneCheckout`), and only while no agent row of the project, nor
any whose cwd is the old checkout, may hold a process (`NoSessionMoved`). Until then the
checkout reads `old`, with the sessions that hold it as its reason, a start in it is refused
`{:checkout, "old"}`, and each read tries again. Claude Code keys what it keeps of a working
directory by its path, so the rename first moves each account's `projects/<encoded old
cwd>/` and the home's memory folder of it to the new path's, entry by entry and never over
one (refused `{:both, path}`), dropping the account's memory link for the next start to make
again, then renames the checkout last, so a restart part way finds it at its old path and
does the rest. Each worktree made from it still names the git directory at the old path:
every read runs `git worktree repair` while one does. The rename is an act in `Acts`
(`rename`, verified with its paths, or failed with each new reason it waited for).

**An import** (F-156): `bin/caf-import <home> <account> <source config dir> [--map <old
cwd>=<project>]... [--name <session id>=<name>]... [--meta <session id>=<json>]... [--db
<path>]` moves an
app's existing Claude Code conversations onto a new host's framework at once
(`Mains.Import`). It copies, never moves, each conversation of a mapped cwd into the
account's `projects/<encoded checkout>/`, with the directory and `session-env` entry beside it,
so `--resume <id>` in the checkout finds it; that cwd's memory into the home's memory folder
of the checkout; and `settings.json`, `CLAUDE.md`, `agents/`, `commands/` and `skills/` where the
account has none. A setting of a copied `settings.json` that names an absolute path this host
lacks (a hook's command, an additional directory) is kept as it is, never rewritten, and the
report names each, its key and the path (F-177). The login stays the account's own. The
checkouts' paths are read from `Mains`' rows in the app's tables (`--db`, by default
`<home>/caf.db`, F-177), so the app starts once on the host first. It is refused while any
agent row of the account may hold a process (`{:running, names}`), and while a Claude Code a
person runs by hand on the account's or the source's config directory may (F-177): their
`sessions/<pid>.json` are read as the `Registry` reads them (`Registry.running/3`), each pid
checked by its start time, never by its name, `{:running, pids}`, and one `ps` lists whose
start time is not known (a file half written) `{:may_run, pids}`. And it is refused with
nothing copied for a file that is there and differs.
Each conversation copied is a manifest file, `<home>/imports/<account>/<session id>.json`,
written last, so a second run says it was imported already. At each start `Mains` has
`Sessions` write each named one as a main session's row, `stopped`, reason `imported`, with
its project, session id, account, checkout and `meta` (`Sessions.import_main/4`), before it
declares the config's main sessions, so the app's start-or-resume finds a session to resume
(`start_main` refuses `{:running, name}`) and `resume_main` takes it up through the
`Scheduler` and the startup dialogs as any resume, with the app's model the first time. The rows go
through `Sessions` at the start, not by a call into the running app: the app runs no named
node, and an import on a new host comes before its sessions ever run.

**A resume** of a main session whose process ended (`Mains.resume_main/3`) is new work: it
writes a start's row and asks the `Scheduler` for a lease of its own, class main session
(always admitted), as a start does, then resumes it in the checkout with its session id and the
model its row keeps (F-141's new-5); its row in `main_starts` names the session id it resumed
(`resume`, F-143's new-5). It runs on the account its agent row names (F-177, `Move.tla`'s
`ResumeHere`, with `Resumes`): a conversation lives only in the account it ran on or was
imported into, and `--resume <id>` on another finds none (`Break_Move_ResumeOnPicked` fails
`TranscriptKept`). Only when that account is refused, not prepared, logged out
(`Accounts.login/2`: Claude Code never ran there) or with a window spent (`allowance:`, the
`Scheduler`'s own gate), does the resume go to the account with the most allowance left among
the others not refused, in one act: the conversation copied there as the `Mover` copies a
move's (`Transcripts.Copy`: the transcript, the directory beside it and `session-env`, each
whole), an act `copy` in `Acts`, then the resume under the same session id. A copy refused
leaves the agent row stopped on its own account, the start refused `{:copy, reason}`; with no
other account, the resume is refused `{:account, account, reason}`. A delegate's resume, after a
kill and with its word to go on after a limit, chooses its account the same way by `usable`
alone, the app's flag among it (F-209): a flagged own account moves the delegate, its
conversation copied to the account the pick finds; with none usable the resume is refused with
its own account's reason, `{:app, reason}` for the app's. No resume runs on an account the app
flags (`Move.tla`'s `NoResumeOnRefused`). The operator's `resume` tool of a main session claims its state in
`Acts` (`Mains.fix_state/3`: its status, session id and last process) and calls `resume_main`
with it, which acts only while that state is still the row's (F-144). A state not `stopped` is
refused `{:not_stopped, status}` before the claim (F-149), and leaves it unclaimed. A move's resume needs
none: the start's lease lives while a move of its session is under way.

**A permission request** of a main session is the `PermissionRequest` `Intake` holds for its
session, as an interactive delegate's is (F-146's new-5, built in F-147). The operator's
`answer` of one claims its state (`Mains.fix_state/3`, which also names the requests held) and
calls `Mains.answer/5` with it, which goes to `Intake.answer/4` only while that state is still
the session's and the request is held. `MCP` checks the id against that state's `held` before
the claim (F-148), so an id the session does not hold is refused `{:not_held, id}` and leaves
its state unclaimed. A person may answer the dialog on its screen first.

**An interrupt** of a main session's turn (F-258) is the operator's alone, as a delegate's is its
parent's (`Team.tla`'s `MainInterruptedByOperatorOnly`). The operator's `interrupt` claims the
state an interrupt reads (`Mains.fix_state/3` with `fix: :interrupt`), which also names
`offset`, the newest hook event `Intake` stored for the session, so each turn is a new state. An
answer's or a resume's state has no `offset`: a main session writes many hook events, and none
of them should refuse a person's answer as moved. It calls `Mains.interrupt/3` with it, which presses Escape through
`Inlet.interrupt/3` only while that state is still the session's, as an interactive delegate's
interrupt does. It answers what the screen shows after the press: `{:ok, :sent}` once the turn
ended, else `{:unknown, reason}`. With no turn running no key goes, and it is refused
`{:screen, reading}`, as a delegate's is. A session whose agent row is not `running` is refused
`:gone` before the claim.

**Its end** (F-143, `Team.tla`'s `MainEnds`) is the operator's act alone: `end_main(name)`, the
operator's tool, `Mains.end_main/3`, which `Sessions.end_main/3` does. It is refused while a
start of the name is under way, but for a start whose call answered and whose agent row waits
on a startup dialog (F-231, `Dialog.tla`'s AskEnd): that one is ended as a stop of a row on a
dialog ends it (below), and the start is refused, `ended`. It is refused while any delegate of
it has not ended (`{:delegates,
names}`), so no delegate is left with no parent; `Sessions` checks that and moves the row in one
step, and refuses a delegate's start under an ended main session (`{:parent_ended, name}`). A
running session is stopped by SIGTERM once idle, as any stop; a row with no process is ended at
once. The row keeps the end asked (`end_asked`, F-144, `Team.tla`'s `EndSettled`): a stop that
answered unknown, its process outliving the stop's deadline, leaves the row `stopping` with the
mark, and the settle ends it once the process is gone, with no second call; a stop refused, or
cut by a restart, takes the mark away with it, and no resume takes a row with it. Its agent row is then `ended` (`Sessions.Agents.ended?/1` holds for it), so the app's end
of an owner's services ends every service it owns, kept ones too: a kept service goes to its
owner's parent, a main session has none, and the operator owns nothing. Rows to it are settled
ended, as to any agent that ended. Its name never starts again.

A main session holds, and a view shows:

- its account, tmux session and pane, and whether its MCP tools are connected;
- its checkout: trunk, ahead and behind its remote, and whether it is clean;
- each delegate's worktree: branch, ahead and behind trunk, unpushed commits, uncommitted
  files, and the pull request and stack each is part of;
- the statuses of its delegates and their subagents, its open questions and its stack's checks;
- the command that attaches to its tmux session, and Open in Ghostty.

**Moving it** starts on its own when the account reaches 90 % of its weekly allowance, or with
one press at any level. It goes to the account with the most allowance left:
1. Drain: no new delegates, background commands or tool calls start. The drain stops what the
   framework starts (decided, F-142's new-2): `Mailbox` and `Delegates` start nothing, and while
   the agent row has a move phase the framework's `PreToolUse` callback (`Mover.pre_tool_use/2`,
   ahead of the app's own) denies a `Bash` call with `run_in_background` and the `Monitor`
   tool, with a reason that says a move is under way. Every account's settings therefore name
   the `PreToolUse` hook.
2. Wait until no background command runs and no `run_delegate` call of the session is under
   way (its report would otherwise be written to a process the move ends). This is read after
   the drain began, so nothing can start after it; a background command is a child of the session's process and ends with it.
   The session file says `shell`, not `idle`, while a background command runs after the turn
   ended, and `idle` once it ends (measured on 2.1.322, F-142), so the idle read of step 3 is
   this wait.
3. End the session by SIGTERM to its pid, by the row's pid and start time, once its session
   file says `idle` (F-114) and no `Mailbox` row to it is `sending`; once the row is `stopping`,
   `Mailbox` neither marks nor hands on a row to it (F-122's new-1: a row marked before the
   stop and handed on after it would start a turn the SIGTERM cuts). Claude Code's shutdown keeps the transcript and fires SessionEnd
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

**How `Mover` does it** (F-133, `Move.tla`). A move is an act in `Acts` (act `move`, by the
operator or a delegate's parent, as a fix is, `Grants.may_fix?`), claimed on the session's
state, then marked acted, then the phase written on the agent row, `draining`, with the
accounts, the act and a deadline; a restart goes on from the phase. A move's state is the
process (its pid, start time and account) and the count of its moves already ended (decided,
F-133's new-5): a second press while a move runs is refused (`{:moving, phase}` by the row, or
`{:claimed, by}`), and a press after a move that was given up is a new state, not a second
claim of the first. While the row has a phase, `Mailbox` marks no row to the session by the
stream or the waiter, `Delegates` starts no delegate under it and takes a delegate's end for the
move's, not a kill, and `Sessions` does not end it. "No new deliveries" means no row that
would start a turn: a `run_delegate` call already waiting still takes its answer, inside the
turn that called, since the drain waits for that call (decided, F-133's new-8). The drain is
clear once no `Mailbox` row to it is `sending` and no `run_delegate` call of it waits
(`Mailbox.awaited/3`). `stopping` is `Sessions.stop` `for: :move`: an interactive session's
SIGTERM as above; a delegate's is SIGTERM too, by its record, once `Stream`'s fold reads its
turn ended and no row to it is sending, since an `end_session` would settle its queued rows
ended. A stop refused while a turn runs is asked again only on a `registry:` or `stream:` cue.
`copying` copies `<config>/projects/<cwd>/<session id>.jsonl`, the directory of that name
beside it and `<config>/session-env/<session id>` (the one other per-session file 2.1.322
keeps, F-133's new-4), each whole under a temporary name and renamed, once the row is free (its process
gone by pid and start time and its socket dead); `resuming` reads the other account by
`usable:` again (F-210: the app may flag it while the drain and the stop take up to the move's
deadline). An unknown (`claude auth status` cannot tell, say) decides nothing: it is asked
again at the `Mover`'s step (5 s) and each cue, up to the resume's own deadline (`resume_wait:`,
5 minutes by default; F-211), which the row's `move_deadline` holds from the phase `resuming`
on, so a restart reads it and a way back keeps it. The same deadline bounds every other
unknown of the resume (F-212): the app's launch (a part it needs has not started),
`Mailbox.launch/4`'s mark, the own word's store, and no first line for a headless resume. A
row still `sending` is asked again but never taken as a refusal: `Mailbox` settles it once the
row is free. Then the resume is `Sessions.resume` on it
with the same session id and the app's launch for the agent (a delegate's from
`Delegates.launch/2`), the row's own options and model taken again. An interactive session's
first due row goes in as the resume's prompt (`launch`, "Delivery"; F-137's new-1), since the
resumed process has no waiter until a turn of it ends; a row still `sending` settles first. A
headless one's goes as its first line by stream, which Claude Code headless needs before it
writes its init (F-152); with no row due, the move first stores a word of its own, a notice
from `framework` under `move:<agent>:<deadline>` ("This session was moved between Claude
accounts. Go on with your task from where it stopped."), so every headless resume has a first
line (F-193, `Move.tla`'s `Headless`). The key is the row's `move_deadline`, the resume's
deadline, which the row keeps on a way back, so one move stores one word whichever account its
resume goes to.
The copy leaves the memory: Claude Code keeps a working directory's agent memory once per
account, in `<config>/projects/<cwd>/memory/`, and a move would leave it behind. So the memory
lives once per checkout or worktree in the home, `<home>/memory/<cwd as Claude Code names
it>/`, and before every start or resume on an account `Sessions` makes that account's `memory`
a symlink to it (`Sessions.Memory.link/3`, F-155): a folder already there is moved in once
when the home's holds nothing, never written over, and a start whose account and home both
hold files is refused `{:memory, {:both, …}}` for a person to merge; a file or a link elsewhere
is refused and left as it is.
Each failure settles on one account:

- the drain or the stop not done by the move's deadline while the old process runs: given up,
  the session runs on on its account, the act `failed`;
- the old process ending by itself during the move: the move goes on from the copy;
- a stop whose process outlives its deadline: the row stays `stopping` for `Recoveries`, and
  the move goes on once it is free, whatever the deadline;
- the copy or the resume refused on the other account, `usable:` refusing it at the resume
  included (the app's flag, `{:app, reason}`), or an unknown of the resume past its deadline
  (taken as a refusal, `{:unknown_past_deadline, reason}`, F-211; `reason` names the unknown
  that ran out, `{:usable, _}`, `{:app_launch, _}`, `{:launch, _}`, `{:word, _}` or
  `:no_first_line`, F-212): the act `failed`, and the
  session is resumed on its own account, where its transcript is, once `usable:` takes that one
  too, an unknown of it past the same deadline a refusal as well;
- that resume refused too: no process of it runs; its row says why, and the fault ledger has an
  act `move` `failed`, reason `stranded`, for a person;
- an agent at a usage limit (F-191, "Usage limits"): its copy or resume refused leaves its
  process gone, never resumed on its own account, which is at its limit; the act `failed` is
  the limit's healer's `limit` prompt, and at the reset its word resumes it.

A resume is asked again only while the row is free, and `Sessions` starts no name whose process
may live, so a restart never runs two. Background commands (step 2) are read by the stop's idle
read, through the session file (F-133's new-1); a move whose background command outlives its
deadline is given up.

Its chat is never archived.

**Startup dialogs** (F-140, `Dialog.tla`). Any session the framework starts interactively, a
main session, an interactive delegate or a move's resume, may stop before its first turn on
Claude Code's own dialogs: the folder trust dialog, then "Allow external CLAUDE.md file
imports?" when the project's `CLAUDE.md` imports a file outside its folder. Neither sends a hook
event, and on 2.1.322 no session file exists while one is shown, so `Registry` sees nothing.
While an interactive start has no session file, `Sessions` reads its pane through the `Inlet`;
`Screen` reads each dialog's kind, its options by label, the selected one, and the imports
dialog's external paths. On 2.1.322 a path wider than the pane is shortened in its middle with
`…` on one line, never wrapped; `Screen` reads it as one path and names it among `shortened`
(F-144's capture). A dialog makes the agent row `dialog`, with the dialog on the row and
a cue: not started, not idle, and not free, so the `Scheduler` counts its lease held and a view
shows why (`Sessions.Agents.dialog/1`). The start's deadline does not end it, and a restart
leaves it waiting.

Nothing answers a startup dialog on its own. The app may give `Sessions` a callback, `fn kind,
options -> {:answer, label} | :ask end`, asked once per kind; its default asks, and the example
app asks. On `:ask` the start answers `{:unknown, {:dialog, kind}}` at once and the row waits.
The answer comes from outside, by the option's label: `Sessions.answer_dialog/5`, which the app
calls and the operator's tool `answer_startup` calls (the operator's alone). It is marked on
the row before its press, and the `Inlet` presses it checked: the pane still shows that dialog,
the press lands on the chosen option, and the dialog leaves; otherwise refused (nothing went)
or unknown. No key goes until the dialog has read the same for `Inlet.settle/0` (1 s, F-246,
`Press.tla`): Claude Code draws a dialog again about 150 ms after its first draw and sets its
selection back, which the screen does not show when no key came, and a press before then is
lost and its Enter may confirm the first option. A dialog that never reads the same that long
within `see:` past the settle is refused `unsettled`: no key went. Then each of its two reads,
the marker on the option before Enter and the dialog's leaving after it, waits up to the
`Inlet`'s `see:`, the config's `press_see` (F-242). That
`see:` has one owner, the `Inlet` (F-245), and each bound that waits on a press is the one
below it plus a stated margin: a tmux command's (`Shell.bound/1` of the server's timeout:
the timeout, the wait between TERM and KILL, and the wait for the exit), the `Inlet`'s
(`Inlet.press_bound/1`: the settle (F-246), three reads, the seven tmux commands a press runs, and 1 s), which
`Sessions` asks once as it starts and the `Inlet` answers outside its queue, the press's
`timeout:` (`Inlet.press_timeout/1`, and 10 s in the `Inlet`'s queue and 1 s for the answer),
and `Sessions`' call (`Sessions.press_call/2`, and 5 s), which each caller asks first and
names no bound of its own. The inbox, the app's `CodingAgentFramework.answer/4` and the
operator's `answer_startup` run in the caller's process and add none, so a press past every
bound answers the `Inlet`'s unknown. A stop's exit press (F-231) is bounded the same way
(F-248): the stop's own steps plus `Sessions.press_call/2` (`Sessions.stop_bound/2`), so no
caller of a stop names a number shorter than that; a caller's own deadline (`within:`, the
operator's end of a main session, a move's stop) wins, and a press it cuts answers
`{:unknown, {:cut, :end_press}}`. The `Inlet` runs one call at a time, each in a task, so it
answers the others meanwhile (F-249, `Inlet.tla`). Each call carries its deadline, the
caller's timeout less the 1 s for the answer. A press starts only while its bound fits before
its deadline; one still queued past that is answered `{:refused, :busy}` at once and never
made. A pane gone after the Enter, as "No, exit" leaves it, is the dialog left, answered at
once. The press runs in a task whose answer comes back as a message, as `Mailbox`'s
hand-on does, so `Sessions` answers other calls meanwhile, the mark `pressing`; a row whose
press is under way is not read again until it answers (F-144). Each answer is an act in `Acts`
(F-144): actor the person (the operator's tool names the operator) or the app (its callback,
actor `app`), target the agent, state the row's start, the dialog and the mark the answer is
taken from, so each is answered once. A kind with any mark is never pressed again, and a mark a
restart finds `pressing` is `cut`, its act settled unknown. A person who sees the pane still
show that dialog with its first option selected clears a cut press once
(`Sessions.clear_dialog/4`, which reads the pane again and clears the cut act in `Acts`): it is
`cleared` and may be answered once more, checked as any press, and a press of it cut again is
`unknown`. While the row waits its pane is read again on an interval and at each cue, so the
next dialog becomes the row's; past the dialogs the session file names the process and the row
runs, as a start's confirm makes it. "No, exit" ends the process, and the row is `stopped`. A
person may give up a start without answering: `Sessions.stop/3` of a row on a dialog, or the
operator's `end_main` of a main session on one, presses the trust dialog's exit option, `No,
exit`, as a person's answer, checked, an act in `Acts` (F-231, `Dialog.tla`'s EndPress). A
dialog with no exit option (the imports dialog, a start's menu), one whose answer is marked, or
a press that did not end the process, gets SIGTERM to its held program's record
(`Holder.Process`, F-144; EndTerm). The row is `stopped` once its process is gone, or `ended`
for an end, and from the ask on it is never confirmed running: a session asked to end runs no
later turn (NoTurnAfterEnd), and an asked end ends or answers unknown (EndEnds).

**A worktree the framework made is trusted before the start** (F-255, `Trust.tla`). Claude
Code 2.1.322 shows no trust dialog in a folder whose real path its account's `.claude.json`
marks `projects[<path>].hasTrustDialogAccepted: true` (a symlinked form of the path is not
read; a folder above a git root does not count; a subfolder of a marked one does). It has no
launch flag or setting for an interactive session's trust. So an interactive start in a
worktree under `<home>/worktrees` writes that mark on its account (`Accounts.trust/3`) once the
tree is set up and before the hold, at every start and resume there, so a move's resume marks it
on the new account; the row's `worktree` says `trusted`, `trusted already`, or why not. Never
for a project's own checkout or any path outside the worktrees, and not for a headless start,
which meets no dialog. Claude Code rewrites the whole file from a read made just before each
write, under the lock `.claude.json.lock` (a directory made by mkdir), and writes without the
lock after about 1.4 s of waiting on it; a plain read-modify-write loses its keys or the mark
(`Break_Trust_Plain`). So the mark takes the same lock, never waits on it, and holds it for one
read and one write: `{:refused, :locked}` while it is held, and refused, writing nothing, when
the file is not there or not JSON. A mark not written leaves the trust dialog to the press
above.

A numbered menu no rule names that a start meets before its session file (an onboarding menu
on a new account, F-203) is a startup dialog too, kind `start_menu`, which no callback answers.
A new account's onboarding may show several such menus in one start, so a start's menu is
keyed by its read, not its kind (F-206, `Dialog.tla`'s reads): the row keeps the read that
found it (`at`) while the pane shows that menu, by its title and options, and its answer is not
sent; any other menu, or one read after its answer was sent, is a new read. Each read is its
own prompt and its own act, answered by a person and pressed at most once; an answer names its
read (`answer_dialog/5`'s `at:`), so one meant for a menu that has gone never presses the next.
The trust and imports dialogs show once a start, so for them a read and a kind are one key.

## The delegate protocol

A main session calls `start_delegate(project, branch, model, brief)`. The framework:

1. checks the project, the branch name, the cap of delegates, and any worktree already at the
   path (reused only when clean, on the branch, and held by no live agent);
2. picks the account with the most allowance left;
3. adds the worktree and runs the project's declared setup in it, so a fresh worktree has its
   dependencies and build state before the first command;
4. stores the brief as a row in `Mailbox` under a uuid it chose, from the parent, before the
   session exists, so it is the first row to it, and has `Mailbox` mark it `sending` by
   `stream` for the start; starts `claude` headless, held by dtach, with `--session-id` set to
   an id the framework chose, writes the brief into its stdin right after the hold, opens a
   viewer of its event log tagged with the session, project and unit, and confirms the start
   by its first event naming that id, which Claude Code writes only after it read that line
   (F-152); the brief's row settles by its replay, as any `stream` row;
5. hands its last message to `Mailbox` when it stops, as the reply to the brief's uuid. When a
   restart lost the stop event, it hands on the transcript's last reply instead, and ends the
   delegate only after the delivery settled. The delegate's row moves from running to finished
   once, by its Stop event or by its transcript's last reply, whichever comes first; a later
   one is ignored. The report is then a delivery like any other ("Delivery"): to the parent's
   waiting Stop hook, held while no waiter is connected, its row in `Mailbox` marked sending
   before the waiter is answered and, after a restart, settled from the parent's transcript once
   the parent's turn that took it has ended: delivered if the report is there, due again if
   not. The row's uuid is the mark the transcript shows. `Delegates` keeps only whether
   `Mailbox` took the report (`held` with its text until it does, then `taken`), and hands it
   again at each cue until then;
6. resumes it once when it is killed before its last reply, and reports a second such kill
   instead of retrying. That report is held and delivered like a finish. A kill after the last
   reply is a finish, read from the transcript.

**A turn at a usage limit is not the report** (F-186's new-1, built in F-187; `Limit.tla`'s
`Report`). Claude Code headless ends a turn at a limit with a `result` whose `api_error` is
`usage_limit_reached`, and exits 1 at once (F-181). `Delegates.Turn.next/2` reads it as
`:limited`: no report, the brief's turn still open, and the exit no kill. At the reset the
limit's healer (`Limits`) hands the word to go on to `Delegates.go_on/5`, which stores it as the
delegate's word to go on (`Mailbox.go_on/4`, first of its rows) under a uuid of the word's key
`limit:<agent>:<until>`, so once per limit, and makes the row's turn that word's; a gone process
is resumed with it as the first line, under the start's lease, as the row's `going_on`, which
`resumes` does not count. A refused one leaves the row `running`, still at its limit, and the
healer asks a person. The word's turn's result is the report, the reply to the brief. An
interactive delegate's turn whose transcript ends with the limit's line, no turn after it, is
read the same way (F-187's new-2, built in F-191): neither a finish nor a kill, whether its
process lives or not; `go_on/5` stores its word, a gone process is resumed with it by launch as
its prompt, and its report is the reply of the word's turn. Before the limit's move the healer
stores the word with no resume (`resume: false`), and the move's resume carries it.

**No `partial` report** (F-184; F-182 had decided one). Claude Code writes a turn's `result`
while a background command of it runs (measured on 2.1.322), so a delegate's report is never
owed behind a hung command, and the healer hands no partial one: `stuck_background` only ends
the hung group ("Metrics and healing"). The turn the command's end begins is Claude Code's own,
told as such, never a second report (`Remedies.tla`'s `OneReport`).

**A second start of a branch** (F-150, `Delegate.tla`'s `StartAgain`) looks up the name's
latest row and its agent row before anything is written. While the parent's delegate of that
branch has a live session, the start answers that delegate with `already: true`, and its brief
is not used. A row with no report whose process is gone does not count as running: the start
goes on as a new row, under the cap that already counts the name, and the old row is history,
never resumed (its `reason` says `replaced`); its brief and word to go on are settled `ended`
in `Mailbox` first, so the new process takes only its own, and the start is refused `in_flight`
while one is still in flight. A start or resume under way refuses it (`starting`), as does
another parent's delegate (`other_parent`) and one neither live nor gone (a report on its way,
a stop or a move under way).

**A delegate idle with no report** (F-150, `Delegate.tla`'s `IdleToldOnce` and `IdleNoticed`):
a running row with no call under way, whose turn has ended by its kind's rule (a headless
one's `Stream` fold; an interactive one's session file, as its report's read takes it), with
no row to it queued or sending in `Mailbox`, for longer than the app's bound (`idle_bound:`),
is told to its parent by a notice from `framework` (`Mailbox.notify/4`). Never a kill, never a
nudge into the delegate. Its idle state is the row with its fix state's offset, which any event
of the delegate moves, so a turn that starts ends it, as a report taken or the delegate's end
does. The bound runs from when `Delegates` first read the state, in memory, so a restart starts
it again; the notice is stored under the state's key, which `Mailbox` takes once, so the parent
is told at most once per idle state across restarts.

**What `Delegates` holds** (`Delegate.tla`; F-59's build note):

- The embedding app hands `Delegates` its projects as data when it starts it, each as `Sessions`
  reads it ("The worktree") with two more fields: `branches`, the pattern a delegate's branch
  must match, and `cap`, how many of one parent's delegates may hold it at once. There is no
  table of projects and no default cap. A delegate holds its parent's cap from its row's
  start until it ends: starting, running, resuming, going_on, finished or failed, since a finished one
  still holds its worktree and its report.
- A delegate's life is its agent row in `Sessions`: whether its process may live, and whether
  it has `ended`, which `Sessions` writes when `Delegates` asks (`Sessions.ended/3`) once no
  process of it may live: a failed one at once, since it is never resumed again, one whose
  start was refused after its call reached `Sessions` at once too (its process ran and was
  stopped, as a headless start whose init never came; it has no report and no process, so a
  stop refuses it, and with its agent row left `stopped` its parent's `end_main` waited on it
  forever: F-153's new-7, `Team.tla`'s `RefusedEnds`), and a finished one once its report was
  delivered, since only then is it stopped. Which rows hold
  an agent, and so the cap, is one function there (`Sessions.Agents.holds?/1`, R9): a
  delegate holds its parent's cap from its start (its call under way in `Delegates`, then its
  agent row) until it has ended or its start was refused. `Delegates`' own row keeps the marks
  of its own calls (starting, resuming, going_on), the protocol's outcome (running, finished with a
  reply, failed with a notice, refused) and its own facts: branch, model, effort, brief uuid,
  resume uuid, resumes, and whether the report was taken. It reads `Sessions`' state only
  through `Sessions.Agents`.
- A delegate's start names how hard its model thinks, `effort`: optional, one of `low`,
  `medium`, `high`, `xhigh` and `max`, the levels `claude --effort` lists on the pinned release
  (`ClaudeCLI.efforts/0` is the one list). `start_delegate` and `run_delegate` take it, and so
  does `Operator.start_delegate`; any other value is refused `{:effort, value}` before any
  row. It goes to the launch as `--effort <level>` and is kept on `Delegates`' row (a column
  added to a file made before it), and a resume, its own or a move's (`Delegates.launch/2`),
  launches with the row's again. With none there is no flag, and Claude Code uses its own. The
  tools' schema offers the levels as an `enum`, so a client picks and checks one before the call
  (F-219): `caf_mcp` does not use `caf_cli`, so `MCP.start_link/1` takes `efforts:` (a required
  list of strings, refused `{:bad, :efforts}` when missing, empty or not all strings) and the
  surface hands it `ClaudeCLI.efforts/0`; no other part copies the list, and `Delegates` still
  checks the value.
- A delegate starts without Claude Code's built-in git instructions, which a main session
  keeps. Claude Code reads the setting as `includeGitInstructions ?? true`, so every delegate's
  settings overlay (`Accounts.overlay/5`, written by `Sessions` at each start and resume, an
  interactive delegate's too, though it runs in the main role) has `includeGitInstructions:
  false` as a default under the account's settings file and the delegate's own options. An app
  that wants them back sets `includeGitInstructions` to true in that delegate's `options`
  settings, which wins; a main session's settings say nothing of it.
- A main session is an agent row of kind `main` with no parent, declared by `Mains`, and the
  delegate's agent row names its parent. `Grants` reads the tree from those
  rows, so a delegate can name only one parent (F-73's new-3 and new-4 end with R9).
- A delegate's session is named `<project>-<branch>`, each character of the branch other than
  a letter, a digit, `_` or `-` written as `-`, so a later start of the branch finds its
  worktree.
- `Delegates`' row is written first, as starting, with the uuid its brief will go in under,
  then the brief's row in `Mailbox` under that uuid, before `Sessions` is called. A resume is
  counted in the row first, as resuming, before `Sessions.resume` is asked; when the brief had
  gone in, the row takes a uuid of its own for the resumed process's word to go on, which is
  stored in `Mailbox` first. `Mailbox` takes one row per uuid and `Stream` refuses a uuid a
  second time (unless found undelivered), so a restart never writes a turn's message twice. The resume is asked only once `Sessions`' row of the killed
  process has ended (`stopped`, by its settle of a running row whose process is gone), since
  `Sessions` starts a name only then; until it has, the delegate stays running.
- A row a restart left starting, resuming or going_on is settled by `Sessions`' row of its call (one
  written at or after the call), once that row is settled: running, or refused. With no such
  row by the row's deadline, the call never reached `Sessions`, and the row is refused (a
  start), failed (a resume) or running again (a word's `going_on`) as interrupted. A call is never
  made again. That reading is true
  because the call carries a caller's deadline, the row's less its slack (F-166, F-164's
  new-1): a call may wait in `Sessions`' mailbox after its task gave up or `Delegates`
  restarted, and `Sessions` takes one past that deadline only to answer it
  `{:refused, :caller_gone}`, writing nothing, so no process runs under a row already refused
  (`Delegate.tla`'s `Called`, `RefusedHoldsNothing`, `Break_Delegate_TakeStale`). One taken in
  time writes its agent row within seconds, long before the row's deadline. A refused resume is
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
  the brief had not gone in (`Mailbox` makes the brief's row due again itself, "undelivered" being
  final), and otherwise a fixed message to go on with its brief: a `Mailbox` row from
  `framework`, stored before the resume, which goes before every other row due to the delegate,
  as a resend does (F-122's new-3), so the resumed process first goes on with its brief. Its
  turn's result is the report, the reply to the brief's uuid, across the resume. That row is
  the resume's first line, marked and written as the start's brief is (F-152).
- **The first line** (F-152; `Delivery.tla`'s stream row for a start, `Delegate.tla`'s
  `Confirmed`, `Break_*_BriefAfterInit`). A headless process writes its `system`/`init` only
  after it read a line, and `Sessions` confirms the start only by that init, while `Mailbox`
  hands a row by `stream` only to a running row: each would wait on the other. So the first
  row due to the delegate (the brief, the word to go on, or the brief again) is marked
  `sending` by `stream` before `Sessions` is called (`Mailbox.launch/4`, `via: :stream`), by the
  start's deadline, and carried to `Sessions` (`first:`), which writes it through `Stream`
  under the row's uuid right after the hold, before it waits for the init. The start's answer
  is told to `Mailbox` (`launched/3`), and from then the session's fold settles the row as any
  `stream` row's: its replay, at the exit the transcript, and no line of it at all makes it due
  again (a start refused before its hold wrote nothing); before the answer, a fold with no line
  of it decides nothing until the start's deadline. The write is made once: one refused leaves the start to its deadline. A
  start or resume with no row due is not made, since it would never be confirmed.
- **A start that is never confirmed can be stopped** (F-152). `stop_delegate` of a row still
  starting goes to `Sessions.stop/3`, which ends the held program by SIGTERM to its record, as
  a start on a dialog is given up (F-144), once the start is past its hold; the start then
  answers `refused{stopped}` once the process is gone and its socket dead, and `Sessions`' row,
  and so `Delegates`' row, is refused. A start still in its worktree or setup holds nothing yet,
  and the stop is refused. With no start under way (a restart, or an unknown answer), the stop
  writes the row refused the same way.

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

**Interactive delegates** (F-137; `Delegate.tla` with `Interactive`). `start_delegate` with
`interactive: true` runs Claude Code's terminal interface, as a main session does, held the
same way, so a person can attach and type: its agent row is of kind `delegate`, role `parent`,
and `Sessions.Agents.headless?/1` is false for it, so `Mailbox` gives it a main session's
transports. `Delegates` needs the host's `Registry` for it. A brief longer than a launch
carries goes as a pointer to its file (F-155, "The launch").

- Its brief is stored first, as any delegate's, then marked by `launch`, and the start carries
  it as its prompt. Its worktree is marked trusted on its account before the start, so no
  trust dialog shows ("Startup dialogs", F-255). A startup dialog its start still meets (the
  trust dialog when the mark was refused, the imports dialog) waits on a person, as any
  interactive start's does, unless the app's callback chose to answer that kind. Its settings carry the waiter
  hook in its launch overlay.
- Its report is the reply to the brief's uuid, read from its transcript: the last reply that
  ended a message of the turn whose user line holds the brief's mark (or, after a resume, the
  word to go on's), once that turn has ended: a later user entry began another turn, or its
  session file reads its turn ended. Never the transcript's last reply: a person may have
  typed a turn of their own since (`Delegate.tla`'s `ReportAnswersTheBrief`,
  `Break_Delegate_LastReply`). Once its marked line is found, `Delegates` keeps that line's
  byte offset in memory and reads the transcript from it (F-137's new-4, F-142); a restart reads
  from byte 0 once, and a mark no longer at its offset is looked for again.
- Its process gone with no such reply, it is resumed once, as a headless one is, and the
  resume carries the word to go on (or the brief again) by `launch`.
- Its stop is a main session's: SIGTERM after an `idle` read. `Mover` moves it as it moves a
  main session (`Delegates.launch/2` answers role `parent` for it).
- A parent's fixes reach it as they reach a main session (F-137's new-3, built in F-142). Its
  interrupt is Escape through the `Inlet` (`Inlet.interrupt/3`), checked: the screen shows a
  turn running, the press lands as its own tmux command, and the screen then shows the turn
  ended. Its permission request is the `PermissionRequest` `Intake` holds for its session, and
  the answer goes there (`Intake.answer/4`), never as keys. The state a fix claims is read from
  `Intake`'s rows of its session in place of a `Stream` row: the newest event's id (any hook
  event moves it), the held requests' ids, and whether its process runs.

## Headless delegates

A delegate runs `claude -p --verbose --input-format stream-json --output-format stream-json
--replay-user-messages --permission-prompts host --permission-prompt-tool stdio --session-id <id>`
(without the prompt tool the pinned Claude Code denies what would prompt, `permission_denied`,
and sends no `can_use_tool`, F-221), and a resume names
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
  exec 3<>"$f"
  exec "$@" <&3 3<&- >>"$d/events.jsonl" 2>>"$d/stderr.log"
  ```

  The delegate's stdin is the FIFO opened read-write, so it holds a writer itself and its stdin
  never reaches end of file: the framework's restarts and its writers' exits never end it.
  `exec` makes `claude` the held process, with the pid `Holder.Process`'s record of the hold
  holds, with its start time (F-118's new-4; the wrapper's own `pid` file went in R7). That
  record, not a session file, gives a delegate's pid: nothing shows that `-p` writes one, and a
  headless session has no `--name` to match. `Sessions` reads it only after `Stream` has read
  the `system`/`init` naming the session id, and checks the socket again. That init, with the
  pid alive, confirms the start; with the pid gone after it, it confirms the start too, since
  the hold removes an earlier hold's record and so the record is this start's (F-187's new-4,
  built in F-191: a first turn at a usage limit exits at once), and the row is then a running
  one that exited, settled as any exit. `Stream` sees an exit only of a
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
  replay. The fold reads such a turn busy from the command's end, before its init, so
  `Mailbox` hands nothing into it ("When a delegate reads idle after a background command").
- **Delivered once, seen.** A message carries a uuid of the framework's, and with
  `--replay-user-messages` it comes back with that uuid and `isReplay`. Its sending mark, the
  row in `Mailbox`, is settled by the replay that `Stream`'s fold reads; `Stream` keeps the
  line's claim and the replay, not a message state of its own (R7). The fold's record per
  uuid (`writing`, `delivered`, `undelivered` at the exit, the result, `exited`) stays as the
  claim's evidence, which `Mailbox` settles by, and as the claim's guard: `Fold.check/2`
  refuses a uuid used before, and a message while another is `writing` or found
  `undelivered`, as defense in depth behind `Mailbox`'s one row in flight (F-125's new-3). When the delegate exits, a
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
  only after the report is delivered and the turn has ended. `Delegates` checks the report
  before it asks for the stop: the report's row in `Mailbox` settled delivered. `Sessions`
  then reads, through the `open_to:` function the app hands it (`Mailbox.open_to/3`), that no
  row to the delegate is sending or due (F-125's new-2): `caf_sessions` does not use
  `caf_mailbox`, which reads `Sessions`' rows. `Stream` refuses the end while the turn runs, and refuses a line once
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
  (which could stand in for `pid`), and the init's order: whether `system`/`init` comes before
  the first line is read. Claude Code 2.1.322 writes it only after it read its first line (the
  end-to-end run of 18 November: no event in 3 minutes with nothing on its stdin), so the start
  writes its first line through `Stream` right after the hold, before it waits for the init
  ("The first line"); the tests' stand-in runs in that shape (`:on_message`), and a release
  that writes it at once needs no change. And the drop of a user line whose uuid the
  transcript holds, with a turn cut off at the exit: 2.1.322 may run such a line again
  (F-51's build note, new-4). The framework does not rely on the drop.

A main session stays interactive. `Screen` reads only a main session's screen: its dialogs by
label, a typed command's result line, and whether its input box is empty before a typed write.
A dialog no rule names is still read when it is a numbered menu (F-198): two or more options
numbered from 1 in a row, the marker on one, under a title and a rule, and one of Claude Code's
menu footers, "Enter to confirm · Esc to cancel" or a permission dialog's "Esc to cancel · Tab
to amend" (F-228), drawn in place of the box or above it; drawn in its place, the box's named rule
may be all that follows it, and the `╌` rules inside it are no text. So a permission dialog no
reading names (a read outside the working directories, F-228) reaches a person as a menu, not an
unread screen that leaves the agent idle. Claude Code's own question (`AskUserQuestion`,
F-230) is one too, by its footer "Enter to select · ↑/↓ to navigate · Esc to cancel": under
its rule a header (`☐ <header>`), the question, its numbered options each with a description
line, a rule inside the dialog and "Chat about this" after it. The inbox shows the question and
the labels; the descriptions go in the detail. Its free-text option, "Type something.", is left
out, since Enter on it opens a field in the same dialog and no press answers it; a person who
wants their own words picks "Chat about this" or `esc` and sends a message. A press counts the
rows as drawn, the one left out too. A form of several questions, or one that takes more than
one answer, is not read. Only with such a footer is it a menu, so a
numbered list in the agent's own output never reads as one; a dialog a rule names (trust,
imports, the usage limit's menu) keeps its rule. A run drawn dim on the
input box's line (`ESC[2m` up to the reset) is a prompt suggestion, never typed text: a box
holding only a suggestion is empty, so the pane is captured with its escapes
(`capture-pane -e`). Only the screen sees a suggestion; what a person types and sends reaches
the framework from `UserPromptSubmit` (F-194).
Its fixtures are captured from a real session once per pinned Claude Code release by a script,
run and reviewed, with names and paths scrubbed; no test runs the real Claude Code. They include
a session launched as the framework launches a main session (`--name`, `--remote-control`),
whose name 2.1.322 draws inside the rule above the box, at 120 and 400 columns. Nothing `Screen`
reads depends on the width: a viewer's window takes the size of whoever attaches, so a person's
attach redraws the screen at their width (F-153's new-2).

**Delivery into a main session** (a report, a reply, a message) types nothing (F-114). Each
main session's launch overlay (item 11's settings overlay, for the main role) names a `command`
Stop hook with `asyncRewake: true` and a `timeout` of 7,200 s; the account's settings do not,
since a headless delegate's transport is `stream` (F-121's new-3). `Intake.waiter_hook/5` gives
the fragment, as `hooks/4` gives the account's; `Sessions` puts it into an interactive
session's overlay at its start when the app gives it `Intake`'s port and secret (`waiter:`,
R7). An overlay's `hooks` add to the account's per event, the account's first, so the waiter
never drops `Intake`'s own `Stop` hook (F-123's new-2). The hook is `sh -c` around `curl` (F-121's new-2): it posts the Stop hook's input
to `/hooks/<account>/waiter` (a path of its own, so the body is not stored as a `Stop` event)
and waits. The secret reaches curl as a config on file descriptor 3, by a here-document
(`-K /dev/fd/3`), and the shell that reads it `exec`s, so the secret is in no process's
arguments while it waits. `Intake` holds it: a hold of kind `waiter`, one per session, whose
decider is `Mailbox`. When a row is due, `Mailbox` marks it sending by the waiter and calls
`Intake.deliver`, which hands the text to the session's waiter: `{:ok, :sent}` once written,
`{:refused, :no_waiter}`, or `{:unknown, reason}` when the connection closed before the write
was confirmed. The program writes a response that is not empty once whitespace is stripped to
stderr and exits 2, and Claude Code starts a turn with it, even when the session is idle;
anything else, a failed post included, exits 0. Each turn's end starts the next waiter, and
the last turn's waiter still waits while a person's prompt runs a turn. The text carries the
row's uuid on a last line of its own (`[delivery <uuid>]`), which the transcript keeps, so
the settle finds that row's lines and never a look-alike (F-125's new-4). Claude Code
2.1.322 queues the text: within about a second a `queue-operation` line `enqueue` holds it;
then an idle session takes it with a `dequeue` and a user line (`Stop hook blocking error
from command "Stop": <text>`, inside a `task-notification` and a `system-reminder`), and a
running turn takes it at its next tool boundary with a `remove` and an `attachment` of type
`queued_command`, with no new user line and no new turn. The take confirms the delivery:
`{:ok, :sent}` says the text was written, not that it was read, so the row stays `sending`
until the transcript's take settles it, or the bound in "Delivery" passes with no line
(F-123's new-1). `Mailbox` reads the session's transcript through `Transcripts`, from the
offset read before the mark. A draft a person left in the box is not touched, so the box need
not be empty.

**The waiter's connection** (F-121's new-1). A handler waiting on Bandit is not told that its
client closed; only a write finds it. So the response is chunked from the start: status 200 at
once, a newline every 5 s (the heartbeat), and the text as the last chunk; at `Intake`'s
deadline, 2 minutes under the hook's `timeout`, it ends with no text. A failed write ends the
hold (`Hold`'s cut). A connection can die unseen until a heartbeat fails, and text written to
it in that time is not read; the transcript then has no line, and `Mailbox` makes the row due
again. Every `Stop` event starts a waiter, a blocked one too (measured on 2.1.322: nine
blocked `Stop`s left nine live waiters, F-157), so a session has several live connections. The
newest is the session's waiter, and each older one still held is answered empty at once: its
program exits 0 and wakes nothing. A waiter whose text is in flight is not replaced: a newer
one waits behind it and takes its place once its hold ends. A waiter is answered empty only at
its deadline or once a newer one is live, or when its decider passes it
(`Intake.pass_waiter/4`, F-241): a reload does, so no waiter's text can wake the session
between the reload's keys and its Enter. `Intake.tla` models the waiter as `Hold`'s third
instance (F-123), and the newest kept as `Superseded` (F-157); `Reload.tla` models the pass.

A session with no waiter (before its first turn ends, after a waiter's deadline, or after a
restart cut the waiter's connection) gets nothing that way, and `Intake` knows it
(`Intake.waiter?`), once a heartbeat has found a connection that died. A start that carries
the first row as its prompt (`launch`, "Delivery") needs none. What is due is held until
a waiter connects; a view shows a session idle with no waiter and something due, and the
`Inlet`'s checked write reaches it, as one more transport of the same row. It **pastes** the
row (F-279, decided), any number of lines, the row's uuid at its end, only when the session
file reads idle with no waiter held and the screen shows an empty box, both read again in the
write's own step. The text goes to a tmux buffer named for the row's uuid, from stdin, never
on a command line (`load-buffer -b <name> -`); the buffer is pasted bracketed, its newlines
kept, and dropped, under the pane's tag check in one command (`paste-buffer -p -r -d`); and
Enter goes as its own command once the box no longer reads empty. A buffer named per write
holds that write's text whatever another writer loads between the load and the paste
(`Agent.tla`'s `PastesItsOwnText`, `Break_Agent_OneBuffer`). Claude Code draws a long paste
folded, `[Pasted text #1 +N lines]`, and submits all of it; the screen is not read back as
text, and the transcript's user line, which carries the whole text and its mark, settles the
row. A text with a control character other than newline and tab is refused, since an escape
could end the paste's bracket early. A row past the paste's bound
(`Transport.Typed.bound/0`, 8 000 bytes, set low and not measured) goes as a pointer (F-142):
`Mailbox` writes its whole text to `<home>/due/<agent>/<row id>.md` (`Sessions.due_dir/2`), and
pastes one line, "A message for you is in <path>; read it.", with the row's uuid at its end.
Each interactive start of the agent passes that directory by `--add-dir`, so reading the file
never asks permission, and it holds only the agent's due texts. The file stays after its row
is delivered: the line is taken before the agent reads the file, in the turn it starts, and
the framework keeps its data. The transcript's user line settles it as any typed row, and its
turn's end brings the next waiter, so no row waits for a person's prompt. A row past the bound
with no home to write its file in is refused, and waits for a waiter (F-240, `Delivery.tla`'s
`Wake` and `WaitBound`). An idle session with no waiter starts none until a turn of it ends,
and a restart cuts the one it had, so the `Inlet` types **the wake line** once in the row's
place, with the session idle and no waiter held: `[framework] a message is waiting for you.`
Its turn ends at once, the Stop hook's waiter connects, and the waiter carries the row whole,
as any row. The wake line is its own act, once per row: its mark (`woke_at`) is written before
its keys go, so a restart never types it again (`WakeOnce`, `Break_Delivery_WakeInMemory`).
Past `Mailbox`'s `wait_bound:` (10 minutes from the wake line's mark, not measured) with the
turn still ended and no waiter held, the row is `undelivered`, `attempt` `["wait_bound",
refusal]`: never typed or read, never sent (`UnknownWhy`, `Break_Delivery_WaitForever`). Its
sender gets a notice of its own, under the row's key, by the normal path: ``undelivered:
message <id> to <agent>, after <n> s`` (`UndeliveredTold`). Rows go in order per sender and
addressee, and `Mailbox` keeps one queue per addressee with one row in flight, so the rows
behind it wait as long and no longer. A box wrapped over two lines would carry the pointer
itself; it needs a captured fixture first (F-240's new-1). `Intake` cues a
session's waiter coming and going on a topic of its own (`intake:<host>:<account>:waiters`, with
the session ids), and `Mailbox` tries a due row on that cue, not on a timer (F-123's new-3).
The cue also settles a row `sending` by the last waiter: a turn's end starts the next waiter,
so the transcript then holds the take. `Mailbox`'s one timer is the take bound's, per row.

**Ending a session** is SIGTERM to its pid, by the row's pid and start time, once its session
file says `idle` and no `Mailbox` row to the session is `sending`; once its row is `stopping`,
`Mailbox` neither marks nor hands on a row to it (F-122's new-1; `Delivery.tla`'s `IdleRead`,
`Open`). The mark and the hand-on are two steps, and an answer takes a moment to become a turn,
so refusing a new mark alone lets a row marked before the stop start a turn the SIGTERM cuts.
`Sessions` reads the rows through the `open_to:` function the app hands it, in the same step as
the idle read, and waits for a `sending` one to settle until the stop's deadline, then refuses
with `{:sending, ids}`; a row still `queued` is not waited for (F-125's new-2). It
replaces a typed `/exit`. Claude Code's shutdown keeps the transcript and
fires SessionEnd with reason `other`, which `Sessions` and `Recoveries` read as that end. The
session file's `status` (`busy`, `idle`, `waiting` with `waitingFor`, and `shell` while a
background command runs after the turn ended) is not documented; its shape is checked against
each pinned release, as the screen fixtures are, and with it which per-session files a
`--resume` reads (2.1.322: the transcript, its directory and `session-env/<session id>`).

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
  target's state keeps it so, with no scan. One end frees it (F-231, `Claim.tla`'s Free): a fix
  refused when it acts acted on nothing, so the MCP settles its claim with `free: true` and the
  state takes the next fix. A refusal that waits on a person keeps its state. A caller whose
  claim was answered unknown reads the
  act's row before it decides anything (F-75). What a fix's arguments name is checked against
  the state read before the claim, never after it, since a claim refused later keeps its state
  unless its fix was refused when it acted: an answer's label, and the request id it names,
  which the state must hold (`Team.tla`'s
  `AnswerClaimed`, F-148); an id it does not hold is refused `{:not_held, id}` and takes no claim,
  so the next answer, with the right id, is taken. So is what each fix needs of the state it
  claims, by the part that acts (`Delegates.fix_check/2`, `Mains.fix_check/2`; `Team.tla`'s
  `Needed`, F-149): a resume of a delegate whose process is not gone (`:live`), already resumed,
  not running or whose agent row is not free, or of a main session not `stopped` (`{:not_stopped,
  status}`); a stop whose report is not handed to `Mailbox` (`{:report, status}`); an interrupt of
  a process that is gone. A fix refused that way takes no claim, so the next fix of that state is
  taken. A fix refused by what it meets only when it acts (a stop whose report is handed but not
  delivered, or with a row to it still open; an interactive delegate's interrupt with no turn on
  its screen) still settles its claim and keeps the state.
- No agent fixes or moves a main session; only a person does, a move with one press.
- An agent may not fix itself. A stuck agent cannot be relied on to see that it is stuck.
- Jobs and services: a main session and its delegates may run jobs and start services on any
  host, in a copy of their own worktree (a main session's is its checkout). A service is fixed
  by its owner, or by the owner's parent.

**The tools** as built. B5 serves them as the seven verbs of "The agent's surface", each
mechanism below unchanged; the operator's tools move to the app's surface:

| Tool | Who | What it does |
|---|---|---|
| `agents(all)` | any agent | the tree: each agent's name, kind, project, parent, account, state (working, waiting, idle, stuck, gone; `starting` while a start or resume is under way, `unread` while nothing has read its session yet; a main session's and an interactive delegate's from its session file alone, the one its pid and start time name, F-153's new-6), what it waits on, its transcript's path (nil until the transcripts' source has read one, never built from the cwd), its subagents (each with Claude Code's `agent_id` from its start, from its file's meta, and the call it runs now, F-237), its background commands (`background`, a count with its `since` and `source`, or `{:unknown, reason}`, F-259), the tool call it runs now (`tool`) and when it last did anything (`last_event_at`), both from its transcript, never a hook (F-235; `Tracker.tool_calls/3` answers its recent calls, a subagent's under its `agent_id`, each with two times: `ms`, the transcript's result less its call, which for calls sent in one batch is the batch's wait, and `duration_ms`, the call's own time from the `PostToolUse` or `PostToolUseFailure` hook's row (F-253), nil for a call with no row or one swept after 7 days, never filled from `ms`), read from the `Tracker`'s view, never a copy (F-99). A delegate that ended keeps its place but shows only with `all: true` (F-129's new-5) |
| `message(to, text, key)` | along an edge | stores a message and delivers it to the target when its turn has ended; answers `queued{id}`, then the sender learns `delivered`. With a `key`, a send again stores no second row and answers the first `queued{id}`; an `unknown` answer names the key. A key over 128 bytes, or empty, is refused `bad_key` |
| `look(agent)` | parent, child, main sessions | a main session's screen as text, or a delegate's rendered event log; its open dialog or request; its last transcript lines |
| `transcript(agent, from)` | parent, child, main sessions | the agent's transcript from an offset |
| `interrupt(agent)` | parent | a delegate's stream interrupt, under a claim |
| `answer(agent, dialog, label)` | parent | answers a child's open request through its held hook, by label, under a claim |
| `resume(agent)` | parent | starts a dead or wedged child again with `--resume`, once per state, under a claim |
| `stop(agent)` | parent | ends a delegate after its report is delivered, under a claim |
| `move(agent, to)` | parent | moves a delegate to account `to`, or the one with the most allowance left, as an act in `Acts` ("Moving it"); a main session is moved by the operator only |
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
| `ask(questions)` | any agent | asks a person one to four questions, each with a header, its text and two to four options (a label and a description each, and whether several may be chosen), so an app can show it as a dialog; answers the ask's id at once and never waits. The person's answer comes later as a message from the operator, one line per question (F-138) |
| `reload()` | any agent | reloads the caller's own tools |
| `reload_plugins(agent)` | the operator | types `/reload-plugins` into an interactive agent's idle session with an empty box, checked as a typed message is, and reads its result line (F-233); each call is an act in `Acts` with no state claimed, since a reload moves none and may be made again. A headless delegate is refused `headless`: it has no screen, and loads its plugins at its next start. An idle session the framework delivers to by the waiter has one holding its turn (F-241, `Reload.tla`): with a row to it open the row goes first by that waiter and the reload is refused `message_due`, else the waiter is passed (it exits 0 and wakes nothing) and the reload is typed once the turn reads idle with no waiter, within 5 s, else it is `unknown` with nothing typed. No waiter holds after it until a turn ends, so the next row is typed |

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
its row is stored and settled `ended` (its name keeps its place in the tree, so the message is
not refused as an unknown agent), and the sender (the delegate's main session, its only
sender) learns that in place of `delivered`, from a settled row. Ended rows are kept; no
retention rule drops them yet.

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

An interactive delegate's turn writes no `result`, so its reply is read from its transcript
(F-257, `Reply.tla`): `Delegates` reads its turns from the report's turn
(`Transcripts.Fold.turns/2`), and each turn that has ended (a later turn began, its session
reads idle, or its process is gone) answers every message whose mark is in it. The mark is in
the user line the waiter's text began a turn with, or, for a message handed to the waiter while
a turn ran, in the `queued_command` attachment that joined that turn. `Mailbox.answered/4`
stores the turn's last reply as the reply, or with the process gone in that turn and no reply,
the notice, under the message's uuid, so one goes in per message as for a headless delegate. A
turn a later one closed with no reply answers nothing.

That turn of its own (a background command of the delegate's own woke it, and it answers no
message) is told to its parent once its report is taken (F-155, `Delegate.tla`'s TurnToldOnce,
TurnNotReport, TurnNoticed): `Delegates` stores its last reply as a `notice` from `framework`
(`Mailbox.notify/4` with `kind: :notice`, a word no turn answers), keyed `turn:<host>:<uuid>`
by the turn's result uuid, which `Mailbox` takes once, so no restart tells it twice; a
headless delegate's `Stream` fold keeps each such result in `own`, and an interactive one's is
the turn its transcript shows begun by a `<task-notification>` with no delivery mark in it,
keyed by its reply line's uuid. A turn a message was queued into is that message's, never its
own (`Reply.tla`'s NotToldAsOwn). A person's turn in an interactive delegate is not told. A
turn with no reply text tells nothing. An interactive delegate's turns, its own and those that
answer messages, are read again only once its transcript's reader (`Transcripts.offset/4`) has
moved since the last read; between, that read stands. Cues queued while `Delegates` settles
are answered by one settle, as `Interventions`' and `HooksSilent`'s queued checks are by one
check (F-261): each reads afresh, so a fix's call never waits behind a backlog of reads.

**The operator** acts through these same tools and checks, as the parent of every main session
(F-109). No agent messages the operator: it is no agent's addressee, and an agent reaches a
person through `ask`. A reply to the operator's message, or the notice in its place, is stored
addressed to the operator, `kept` from its store (F-138's new-1, as `Delivery.tla`'s `StoreRow`
keeps a row to no session), so no settle reads it again, and never delivered: the app reads it
by the message's id (`Mailbox.reply/2`, built in F-142), which answers the reply's text with
its status (F-146's new-4, built in F-147). The operator's `run_delegate` hands the report to the operator, who
waited for it. Either way the main session sees the act as it sees any act on its child: in the
log, not as a message.

**An ask** (F-138; `Team.tla`'s `Ask`, `Answers`) is a row from the agent to the operator, kept
for the app as a reply to the operator is: stored, never delivered. The app reads the open asks
and one by id (`Mailbox.open_asks/2`, `Mailbox.asked/3`) and answers through one function,
`Mailbox.answer/4`, each answer the label or labels the person chose and the person's own text.
Those answers are kept as JSON beside the text the agent gets, and `asked/3` shows them
(F-138's new-3).
The answer is a row from the operator to the agent that asked, keyed by the ask's uuid, so the
table's unique key keeps the first answer and refuses a second (`:settled`). It is delivered
as any row is, by the agent's transport, one line per question, so an idle agent wakes to it;
with no waiter, its several lines go as the typed pointer to its file (F-138's new-2, F-142).
To an agent that ended first it is stored and settled `ended`, never delivered.

**An ask withdrawn** (F-172; `Prompt.tla`'s `WithdrawNow`, `AnsweredOnce`, `Prompt_Asks`). An
app that shows the open asks in its own inbox lets a person dismiss one there. The app says so
with `Mailbox.withdraw/4` (the operator's `withdraw` tool, `Operator.withdraw/3`): a row from
the operator to the asking agent under the ask's uuid, kind `withdrawn`, its text `Ask <id>
was withdrawn: <reason>`, delivered once as an answer is. The withdrawal takes the answer's
key, so an answer and a withdrawal race to one settle: the first is stored, the second refused
`:settled`. `asked/3` shows the settle, its `kind` `answer` or `withdrawn`.

**Services** belong to the agent that started them. When the owner ends, its services end too,
unless it handed them on with `service_hand`, or started them with `keep: true`, which hands them
to the owner's parent when the owner ends: a delegate's main session. A main session has no
parent and the operator owns nothing, so what a main session kept ends with it (F-143). `keep`
belongs to the service and stays with it when it is handed. A service has a name, a host, a copy, a held process and a log. A claim on a
service holds its state as its held process (pid and start time) and its restart count. It
never holds a Claude Code session; agents are started as delegates. Any agent the tree holds may
start one (`Grants.may_start_service?`).

A service's end sends TERM to its process group, while its pid still has its recorded start
time, and KILL to the group after a grace (the call's timeout), as its own step: the end is
done only once the socket reads dead. A group signal that fails while every member of the
group is a zombie not yet reaped, or none is left, reads as gone: macOS answers EPERM for such
a group, and nothing in it runs again; one that fails while a member is not a zombie stays
unknown (F-124). Linux sends the signal to a group of zombies and `kill` succeeds, so there it
reads as sent (F-272). A service runs in the foreground, in its own group: a program that
daemonizes itself into a new session leaves a process no end reaches, so it is started in its
foreground mode (a database with its no-daemon flag, say). A start that settles
after its owner has ended does not stay running: its settle reads the owner's end first, and
ends the service, or hands it to the owner's parent when it has `keep` (F-83).

## Delivery

Everything the framework hands an agent is one row in `Mailbox`: a message, a reply, a notice,
a report (the reply to the brief's uuid), a delegate's brief and its word to go on after a
resume, and the app's word (F-115, R7; F-122's new-4). There is one mark and
one settle, and only the transport differs. `Delivery.tla` models it before `Mailbox` is
changed (R6).

- **One row in flight per addressee.** `Mailbox` picks the oldest due row per addressee, in
  order per sender and addressee, with a row made due again by a settle going first, and a
  resumed delegate's word to go on with them (F-122's new-3). It marks
  the row `sending` with its transport, then hands it on. Refused undoes the mark; unknown keeps
  it for the evidence. The row is the only mark: no other part keeps a delivery state. The
  hand-on never blocks `Mailbox`: it runs in a task whose answer comes back as a message, the
  row `sending` meanwhile and settled by no evidence until the answer is in (`Delivery.tla`'s
  `hand`), so its calls answer while a typed write runs (F-132's new-2).
- **Into an ended turn only, to the current process only.** The turn state is `Sessions`'
  function for the target's kind; the process is the agent row's. The waiter's row is the one
  exception: Claude Code queues a waiter's answer and takes it into a person's turn still
  running, at its next tool boundary, and nothing is typed, so it goes into an ended turn or
  is queued into the running one (measured for F-127; `Delivery.tla`'s `OnlyIntoEndedTurn`).
- **The transport is the target's**, and each transport names its evidence and what a restart
  does to a row it left `sending`:

| Transport | Target | Settled by | A row left `sending` by a restart |
|---|---|---|---|
| `stream` | a headless session | the replay in `Stream`'s fold; at the exit, the transcript. Its first row to a new process is marked before the start and written right after the hold (F-152) | settled from the same evidence once read; undelivered is final, and the row is due again first, under its same uuid, to the resumed process; a start's first row with no line in the fold waits for the start's deadline |
| `waiter` | an interactive session with a waiter | the transcript's lines carrying the row's uuid: the `queue-operation` `enqueue` (it reached Claude Code's queue), then its take, a `dequeue` and the user line `Stop hook blocking error …` into an ended turn, or a `remove` and a `queued_command` attachment into a running one; delivered at the take; due again once the take bound past its hand-on has passed with no line, or its process is gone with no take | settled from the same lines: delivered if the take is there, kept while only the `enqueue` is, due again if no line is there and the take bound has passed |
| `typed` | an interactive session with no waiter | the `Inlet`'s answer, then the transcript's user line, its own or its pointer's, delivered at once whether its turn has ended or not: `Mailbox` settles at its cues, and an app's own answer to a waiter may start the next turn before any cue reads the last one ended (F-277, `Break_Delivery_SettleAtIdle`); due again as `waiter` | as `waiter`; an unknown write is never typed again |
| `launch` | the first row to an interactive session's new process | its start: the text is the start's prompt argument, read from a file into the last argument (`ClaudeCLI.prompted/5`, at most `ClaudeCLI.prompt_max/1` for the host's operating system; a longer row's text is written to the agent's due directory and the prompt is one line naming it, with the row's uuid, F-155); then the transcript's first user line whose text is the prompt, its mark last (the launch's own line, never a waiter's), delivered at it, read in the session the start made: from the mark's offset when it is the session the agent row named at the mark (a resume), else from the transcript's first byte (a new start, F-282, `Break_Delivery_OldWindow`); a start refused makes it due again; with no line, due again only once no process of the start runs: a startup dialog holds the first turn for as long as a person takes, so no take bound stands for it, and the row is handed to no other transport while its process lives (F-153's new-1, `Break_Delivery_LaunchBound`) | settled from the same evidence; with the start's answer lost, in the session the agent row names now, which the start wrote (F-282) |
| `call` | a waiting `run_delegate` | the endpoint's write, and the calling process still running after it | due again, for the parent's waiter: the call it answered is gone |

**The launch** (F-137). A waiter connects only once a turn of its process has ended, and the
`Inlet` types only a short line, so neither carries a delegate's brief into a new interactive
session but as the typed pointer to its file (F-142), which needs the screen idle with an empty
box. The launch needs no screen: since the pointer it is the quicker path, not the only one, and
`Delivery.tla` has no Break for it. Claude Code takes an initial prompt as its last argument, at a start and with
`--resume`, and runs it as the first turn. So the first row to an interactive session (a
delegate's brief, or its word to go on, or the brief again, at a resume; the first row due at a
move's resume, F-142) is marked `sending`
by `launch` before the start (`Mailbox.launch/4`, by the part that starts it, by the start's
deadline), and the start's answer is told to `Mailbox` (`launched/3`). Every later row goes by
the waiter, or by `typed` when no waiter is connected: a row within the paste's bound pasted
whole, a longer one as a pointer to the file that holds it ("A session with no waiter",
F-142), so no row waits for a person's prompt after a bare resume, a restart that cut the
waiter, or the waiter's deadline (`Delivery.tla`'s `NoPointer`). An argument of about 900 000 bytes passed and one of 1
100 000 did not on macOS (`getconf ARG_MAX` 1 048 576 for arguments and environment together),
so a launch there carries at most 512 KiB. Linux refuses any one argument over 131 072 bytes
(`MAX_ARG_STRLEN`, with its closing NUL), whatever room is left in all, so a launch there
carries at most 124 KiB, 4 KiB under it. The cap is the host's operating system's
(`Programs.os/1`, `ClaudeCLI.prompt_max/1`; an operating system never measured has none, and its
launch with a prompt is refused). A first row longer than the cap goes as the typed transport's
long rows do (F-155): `Mailbox.launch/4` writes its text to `<home>/due/<agent>/<row id>.md`,
which every interactive start may read by `--add-dir`, and the prompt is one line naming it,
with the row's uuid on its last line, settled as any launch by the transcript's user line. The
line names the path in backticks, so a home with a space reads as one path, and carries the
sender as the text does: ``From <name> (<kind>): a message for you is in `<path>`; read it.``,
or for a brief or a word to go on, which are not framed, ``A message for you is in `<path>`;
read it.`` (F-172; the typed pointer is the same line). With no home it is refused, and nothing is marked. So neither
`Delegates` nor `Mains` refuses a long brief.

**The take bound** (F-122's new-2): the time after a waiter's answer, or a typed write, by which
Claude Code has started the turn with it or never will. Between the hand-on and the transcript's
line nothing the framework reads tells "not yet" from "never", so a `waiter` or `typed` row is
due again only past it (`Delivery.tla`'s `wire`, `Break_Delivery_SettleEarly`). Its value is
checked against each pinned Claude Code release, with the transcript line's text, as the screen
fixtures are. For the waiter it is `Mailbox`'s `take_bound:`, 10 s by default: Claude Code
2.1.322 writes the `enqueue` line within about a second of the hook's exit, whether the session
is idle or a turn runs (measured for F-127). The bound runs from the hand-on's wall-clock time,
kept on the row, so a restart keeps it.

**The sender** (F-170). An agent reads who a row is from in its text, since a turn's input
names no sender of its own. Every row but a brief and a word to go on (both the parent's, and
both read as the delegate's own task) goes with a first line in one fixed form, `From <name>
(<kind>):`, then the text: on the same line when the text has one line, after a blank line
when it has several. The kind is `message`, `report` (a reply or notice to a brief, whoever
sent it), `notice` (the framework's, naming the agent it is about), or the row's own kind
(`ask`, `answer`, `reply`). When the sender has an agent row, the frame names its account too,
`From <name> on <account> (<kind>):` (F-190, from F-188's new-3), so an app whose agents run on
several accounts needs no frame of its own. The frame is put on at the hand-on, not in the stored text, so a
row due again goes with the same frame, and the uuid mark still comes last: the settle finds
each row by its own uuid line, as before. An app may give `Mailbox` a `frame:` function of the
row's sender, kind and text that answers the text to hand on; one that answers no text hands
nothing on, and the row stays due, its `attempt` `{:bad, :frame}`. The `call` transport's
answer is not framed: its JSON names the delegate.

**A forced end** (F-170; `Delivery.tla`'s `ForcedEnd` and `ForceSettled`, `Team.tla`'s
`ForcedByOperator`). An end waits for every row in flight to the session to settle (`{:sending,
ids}`), and a session that never takes a turn (one not logged in, say) never settles one. The
operator's `end_main` and `stop` take `force: true`: the session is ended as usual, SIGTERM once
its file reads idle, but whatever row to it is in flight. Once its process is gone, each row
still `sending` to it settles `unknown` with reason `ended_while_sending`
(`Mailbox.ended_while_sending/3`, and `Mailbox`'s own settle, F-172): never resent, never
counted delivered, and no later evidence
changes it (`UnknownStays`). The forced end is the operator's alone; an agent's is refused
`{:operator_only, :force}`. The act is a row in `Acts` before it acts, and each row's settle is
a row of its own (`settle`, outcome `unknown`, detail the row's id). A forced stop of a delegate
still needs its report delivered, as any stop does (`EndsAfterDelivery`).

The settle is `Mailbox`'s own step too (F-172, `Delivery.tla`'s `ForcedSettles`,
`Break_Delivery_SettleInCall`): the forced act's claim in `Acts` carries `detail` `{"force":
true}`, written before the act, and `Mailbox`, given `acts:`, settles at each of its settles,
before any transport reads its evidence, every row `sending` to an agent whose row ended, with
no process left, after such a claim. So a restart between the end and the operator's call
leaves no row `sending`, and none is made due again by its process's end and then `ended`,
which would say it never went in. Each of those settles is a row in `Acts` as the call's are.

The restart policy lives with the transport, as one module per transport in `Mailbox` beside
the one mark and settle, and `Delivery.tla` models each transport's policy as its own choice.
The common part (the row first, refused undoes, unknown keeps, a settle by evidence at a cue
and after a restart) is written once.

## Intake

Claude Code posts each hook event once and never retries it, and a post that fails loses that
event (Claude Code 2.1.322; sources in `docs/build-notes/F-24.md`). `Intake.tla` models this
section.

- **Transport.** Each account's settings name an `http` hook for each event the framework
  reads: SessionEnd, Stop, StopFailure, SubagentStart, SubagentStop, Notification,
  UserPromptSubmit, PermissionRequest and PermissionDenied. Claude Code 2.1.322 runs no `http`
  hook on `SessionStart` (or `Setup`): it skips it and logs "HTTP hooks are not supported for
  SessionStart" (F-236), so the framework writes none, and a start is known by its session file. Each hook posts to
  `http://127.0.0.1:<port>/hooks/<account>` on the framework's node, with the home's secret
  (kept per home, so it outlives a restart) in a header, and sets its own `timeout`. No program
  on the host takes part, so a held hook is one open request. PreToolUse and PostToolUse are
  written only when the app gives `Intake` a callback for them, and are not stored as they come:
  they carry every tool input and output, and `Transcripts` reads those. `PostToolUse` and
  `PostToolUseFailure` are always written (F-253), and their rows keep only `tool_name`,
  `tool_use_id` and `duration_ms`, the call's own time. They are kept `tool_rows_keep:` (7 days) and then swept, at a post and at most once a minute; an older call shows `duration_ms` nil. A main session's waiter is the one `command` hook: it
  posts to `/hooks/<account>/waiter` ("Delivery into a main session").
- **One hold, six kinds** (F-115, R5). A hook that waits is a hold: a key, a deadline under
  the hook's `timeout`, a named decider, exactly one response, a late answer dropped, and a
  settle when the holder or its connection dies (`lost` or `unknown` for a hold with a row,
  nothing for the others). `Intake` keeps one structure of holds, one `:DOWN` lookup and one
  drop; each kind names only its decider, its deadline and its response's encoder:

  | Kind | Hook | Decider | Deadline | Row |
  |---|---|---|---|---|
  | `permission` | `PermissionRequest` | a person, or an agent's or the operator's `answer` | 570 s of 600 s | yes |
  | `tool` | `PreToolUse` | the app's callback | 5 s of 10 s | yes |
| `post_tool` | `PostToolUse` | the app's callback (F-197) | 5 s of 10 s, the same `tool_deadline` | yes |
  | `start` | `SessionStart`, a command hook | the app's callback (F-236) | 5 s of 10 s, the same `tool_deadline` | yes |
  | `stop` | `Stop` | the app's callback (item 14), a pause's word, or a person at the cap | 570 s of 600 s | yes |
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
  A second post of the key answers the row's decision, or an empty body.
- **A held `PostToolUse`** (F-197). With the app's `post_tool_use` callback, the post is a hold
  of its own kind, asked as a `PreToolUse` is, under the same `tool_deadline` and 10 s timeout.
  The call has already run; the answer changes what the model reads of it. `{:replace,
  response}`, `response` a map of the tool's own response shape (the event's `tool_response`),
  goes out as `hookSpecificOutput.updatedToolOutput`. `:pass`, any other value, a crash and
  the deadline are an empty body, and the output stays as the tool gave it; a replacement that
  is not a map, or not JSON, is a pass whose row names it (`["bad_answer", "replace"]`). The
  row is the hold's, as a `PreToolUse`'s: "answered" with the actor `app`, the response it
  sent and, as `data`, the tool's name and `tool_use_id` (never the output, which
  `Transcripts` has); "passed" for a pass; "expired" at the deadline. Measured on Claude Code
  2.1.322, headless, a `Bash` call of `echo ORIGINAL-OUTPUT` and a prompt asking the model to
  quote what it read:

  | hook | answer | the model read |
  |---|---|---|
  | command | `updatedToolOutput` as a string | the original: ignored |
  | command | `updatedToolOutput` as an object of the tool's response shape (`stdout`, `stderr`, `interrupted`, `isImage`) | the replacement |
  | `http` | the same object, as the body | the replacement |
  | `http`, `timeout` 5 | the same object, after 12 s | the original; the turn went on at about 5 s |

  Not measured: `updatedMCPToolOutput`, an MCP tool's output, and an `Edit`'s. F-201 added
  `{:context, text}`, sent as `hookSpecificOutput.additionalContext` under `PreToolUse`'s bound
  of 10,000 characters, so a note goes on the call it is about; `{:replace, response, context:
  text}` sends both. Measured by the main session on 2.1.322, headless, a `Bash` call and the
  model asked to quote any note with the result: from a command hook and from an `http` hook
  alike the model read the text on that call, shown as "PostToolUse:Bash hook additional
  context: <text>", and the tool's result was unchanged. Without the
  callback a `PostToolUse` post is answered at once and kept as a row, not held (F-253). `Intake.tla`'s `HT` models both tool kinds.
- **A held `SessionStart`** (F-236). With the app's `session_start` callback, each account's
  settings have a `command` `SessionStart` hook (`Intake.start_hook/4`), the waiter's shape:
  `sh -c` around `curl`, the secret on file descriptor 3, a `timeout` of 10 s. It posts the
  hook's input to `/hooks/<account>` and prints the response on stdout; it always exits 0.
  `Intake` holds the start as a `PostToolUse` is held, under the same `tool_deadline`, and the
  callback gets the agent, account, session, `cwd` and `source` (`startup`, `resume`, `clear`
  or `compact`). `{:context, text}` goes out as `hookSpecificOutput.additionalContext`, under
  `PreToolUse`'s bound of 10,000 characters; `:pass`, any other value, a crash and the deadline
  are an empty body, which prints nothing. A session starts again at each resume, clear and
  compact under one session id, so each start is a hold of its own key. Without the callback
  there is no `SessionStart` hook. Measured by the main session on Claude Code 2.1.322, a
  command hook whose context named a code word: headless (`-p`) and in an interactive start in
  a trusted folder the model answered the code word; in an interactive first start that showed
  the trust dialog it did not. A session whose start waited on the trust dialog starts without
  the context. `Intake.tla`'s `HT` models this hold too: a post, a callback's answer or a pass,
  one response.
- **A held `Stop`** (F-157, decision 10). With the app's `stop:` callback, the `Stop` hook
  waits 600 s and each turn's end is a hold whose row is written "held". The callback gets the
  agent, its project, the session, its count of blocks and the hook's input, and answers
  `:pass` (the turn ends) or `{:block, reason}` (`{"decision": "block", "reason": …}`: the
  agent goes on). Claude Code 2.1.322 honors 8 blocks in a row with no tool call between and
  overrides the 9th (measured, F-157), so `Intake` keeps each session's count in its table
  (`intake_stops`), written before a block goes out and reset by a `PostToolUse` post, which
  the `Stop` hold's settings add, and by a `Stop` it passes (at its deadline too): the turn
  ends, and Claude Code gives the next turn, a person's prompt's or a wake's, the full 8 again
  (measured on 2.1.322, F-171; `Intake.tla`'s `NewTurn`). It may count more than Claude Code
  while a turn runs, never fewer: a post lost while the framework is down, or a turn that
  ended while it was down, leave it high. The 8th block in a row is not sent: the row waits on a person
  (its `prompt` is `stop_cap`), whose `:go_on` is that block and whose `:end` lets the turn
  end; past it the hold passes at once, its actor `capped`. A pause per agent or per project
  (`intake_pauses`, set by the app or the operator, a pause per agent before one per project)
  holds each `Stop` until it is lifted, when the callback is asked, or answers it with the
  pause's own word, counted as the callback's is. At the deadline, a pass. A crash of the
  callback is a pass. `Intake.tla`'s `HS` models it, and `Prompt.tla` the `stop_cap` prompt.
- **Stored, then acknowledged.** `Intake` writes the event's row, then answers 200 with an empty
  body. A row is keyed by Claude Code's own ids where the event has them (`session_id` with
  `tool_use_id`, `prompt_id` or the start's `source`), and a second post of one key writes no
  second row. A part that reads rows moves its own row forward once, as `Delegates` does.
- **Duplicates.** Stop, Notification and SessionEnd carry no id of their own, so two identical
  posts read as two rows. No part counts those rows; each moves its own state forward once, so a
  duplicate is harmless.
- **Lost events.** A post while the framework is down is refused and lost. Each event a part
  needs has a reader that stands in: a Stop by the transcript's last reply, a SessionEnd by the
  pid, a start by the session file, which is the only reader of a start (no `http` hook posts
  one, F-236).
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
2. **One writer.** One process writes each table, and one `Inlet` per host types into panes;
   `Sessions` and `Recoveries` open and size the viewers, each through `Tmux`'s one-command check.
   Every other part reads a table through its owner's functions.
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
   - The spec settles (F-177, `Resumes`, `Move_Resume`): a resume of the session once its
     process ended by itself runs on the account its row names, and on another only after a
     copy there, in one act; a copy refused or cut leaves the row stopped on its own account.
     `TranscriptKept` is an action property: each new process, a move's or a resume's, starts
     from the whole transcript of the account the row named.
   - The spec settles (F-209, `Flags`, `Move_Flags`): the app's `usable` flags an account and
     lifts the flag at any time; a resume, a main session's or a delegate's, never runs on an
     account it is refused on when it chooses one (`NoResumeOnRefused`, an action property;
     `Break_Move_ResumeInPlace` resumes in place and fails it): its own while usable, else the
     one it copies the conversation to, else refused, the row staying down.
   - The spec settles (F-210, `Move_Flags`, `Move_LimitFlags`): a move's resume reads the flag on its target
     again, not only at the pick, since the app may flag it during the drain; flagged, the move
     goes back to its own account (`MoveBack`), and with that one flagged too the row is left
     down (`Stranded`); a limited session's stays gone (`Back`). `NoResumeOnRefused` covers a
     move's resume too, by the flag (a move's windows are read at its pick);
     `Break_Move_PickOnly` reads the flag at the pick alone and fails it.
   - The spec settles (F-211, `Unsure`, `Move_Unsure`): the check a move's resume reads may
     answer unknown at any time, and never answer again; the resume's deadline passes
     (`ResumeWaitEnds`) and an unknown is then taken as a refusal (`MoveBack`, `Stranded`).
     `ResumeEnds` is liveness: a move's resume ends, moved, back or left down;
     `Break_Move_NoResumeWait` has no deadline and fails it. The resume's launch may answer
     unknown too (F-212, `LaunchUnsure`), under the same deadline (`ResumeRefused`);
     `Break_Move_FlagOnlyWait` bounds the check's unknown alone and fails `ResumeEnds`.
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
   - The spec settles (F-170): a start in `Queued` answers at once and leaves the parent owed
     its outcome on the row; once it has one, the parent is told once, by a key `Mailbox`
     keeps, across restarts (`StartToldOnce`, `StartNoticed`; Breaks `StartNoKey`,
     `StartOwedInMemory`).
4. **`Team.tla`**: two main sessions and their delegates, their messages, claims and
   services, and restarts of the framework. Events: a message is sent, a turn ends, an agent
   sticks, dies or ends, two fixes of one child, a service's owner ends.
   - Invariants: a message is delivered at most once and in order per sender, only into an
     ended turn, and only along an edge of the tree; at most one claim holds a child's state;
     only a parent fixes, and no agent fixes itself or stops a main session; a service has one
     owner, or none once it ended; every row to the operator is kept for the app, an ask or an
     answer to its own message, and no message goes to it; an ask has at most one answer, the
     operator's, to the agent that asked (F-138); a main session ends only by the operator's
     `end_main`, idle or with its process gone, and never while a delegate of it has not ended
     (F-143); a forced end is the operator's only, and each row it leaves in flight settles
     `unknown`, never delivered or resent (F-170, `ForcedByOperator`, `Delivery.tla`'s
     `ForceSettled` and `UnknownStays`; Breaks `Team_ForceByAgent`, `Delivery_ForceEnded`).
   - Liveness: a message to a live agent is delivered; a claim is released or its fix verified;
     a service whose owner ended without keeping it ends, and one an ended main session owned,
     kept or not.
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

`Dialog.tla` (F-140) models a startup dialog: the pane read while a start has no session
file, the row `dialog` waiting on a person through its deadline and a restart, the app's
callback for the kinds it chose, an answer marked before its checked press, the press in a task
whose answer comes back as a message, a person's clear of a press a restart cut and a person's
stop (F-144), and the start going on past the dialogs. Invariants: `OnlyAsked` (nothing presses
a dialog no one asked to answer), `OnNamed` (a press lands only on the dialog it names),
`AtMostOnce` (an answer whose press is unknown is never pressed again, and one cut by a restart
only once more, after a person's clear), `NotEndedOnDialog` (a row on a
dialog is never an orphan), `LeaseWhileLive`; liveness `DialogShown` (the next dialog becomes
the row's after an answer) and `GoesOn`. Each has a `Break_Dialog_*` configuration. F-206
keys each answer by its read, not its kind, so `Dialog_Menus` (the trust dialog, then two
menus one after another; with restarts in `slow/Dialog_MenusRestarts`) asks a person each menu
and presses each at most once, and `Break_Dialog_ByKind` (answers kept by kind, F-203's)
breaks `KeptAcrossRestart`: the second menu has no prompt waiting. F-231's `Dialog_Ends` (the
trust dialog, a restart), `Dialog_EndsTerm` (both dialogs, none) and `slow/Dialog_EndsLarge`
(both, a restart) add an end asked while the row waits (`Ends`): the exit press, or SIGTERM,
then the row ended, with the
invariant `NoTurnAfterEnd` and the liveness `EndEnds`, which `Break_Dialog_EndRefused` (the end
refused, as before) breaks. `Claim.tla`'s `Free` lets a claim let go with no act free its state,
and `Break_Claim_FreeActed` (a row that acted freed too) breaks `OneActPerState`.

`Menu.tla` (F-198) models a numbered menu no rule names on a running interactive session's
screen: the pane read into the row's menu, a person's answer by a label or `esc` marked before
its press in a task, the press checked (the pane shows that menu), the marker moved and read
back on the label before Enter, Escape for `esc`, a key that lands or not, a person at the
viewer who moves the marker or answers first, and a restart that makes a press under way
unknown. Invariants: `OnlyAsked` (no default: every key that answers a menu comes from a
person's answer), `OnNamed` (a press lands only on the menu it names, and Enter confirms only
the label answered), `AtMostOnce` (a menu drawn is pressed at most once); liveness
`LeavesWhenGone` (the row's menu, and so its prompt, goes once the pane shows none) and
`MenuShown`. Each has a `Break_Menu_*` configuration.

`Checkout.tla` (F-141) models a project's checkout ("Main sessions"): the clone made once under
a temporary name and renamed whole, the pull owed after a landing and at each start of `Mains`,
cleared before its fetch, held back while the checkout is not clean and owed still, and git's
`merge --ff-only` against an edit or a commit a person makes at any step, with restarts in the
middle of a clone or a pull. Invariants: `NoLostEdit` (a pull discards nothing a person left),
`WholeCheckout` (nothing uses a cut clone), `Forward` (trunk only fast-forwards); liveness
`Made` and `CaughtUp` (once landings stop and the checkout stays clean, it holds the remote's
trunk). Each has a `Break_Checkout_*` configuration: `CloneInPlace`, `ResetHard`, `ClearAfter`
(a landing during a pull lost), `NoPullAtStart`, `ClearOnDirty`.

`Schedule.tla` (F-134, F-135) models the `Scheduler` ("A lease"): durable lease rows, an
in-memory queue, rotation, deadlines (tick-down timers) and owed answers, monitors lost at a
restart, the owner's row of each lease's work (`starting`, `live`, `ended`, outliving a
restart), pressure and budgets as the environment, and bounded restarts that are never fair.
Its grant (`Insert`) and the answer reaching the requester (`Tell`) are two steps, so a
restart between them is checked. Invariants: `CapacityHolds`, `NoDoubleGrant` (across
restarts), `ReleaseOnce` (and only after the work ended), `GangAtomic`, `AnsweredByDeadline`,
`RefusedIsNotFailed`; action properties `ClassOrder` (with the hold, checked by `Hold`'s
configuration: two landings and a heavy run on two slots and one lock), `NoStartUnderSevere`,
`NoHeavyUnderHigh`, `NoStartWithoutBudget`; liveness
`QueuedIsAnswered` and `EndedIsReleased`. Its `Fence` shape (F-139: two heavy runs on one
slot) adds the host: a start sent may land at any later step, the wrapper takes the fence
before it runs, and the owner settles a start never run only once it took the fence;
`NoRunUnleased` (a job runs only under its unreleased lease) and `HostCapacity` (the running
jobs never pass a capacity), with Break `NoFence`. Its `Native` shape (F-171: two heavy
`Bash` commands under the wrapper on one slot) makes the requester the work: the wrapper's
own process asks, becomes the command once granted, exits after a refusal, and ends at any
step, waiting or running, by an exit or a kill; the owner reads that end from the process, so
`GoneIsReleased` (every end releases the lease) and `NoRunUnleased` hold, with Break
`EndByPost` (an end read from the wrapper's own post, which a kill never sends, holds the
lease past the command's end). It instances neither `Claim` nor `Hold`: a lease is
units counted against a capacity for a process's life, not one act per state, and a queued
request has no row, may be answered twice (queued, then once more) and is asked again after a
restart rather than settled; the spec's header says so.

`Boxes.tla` (F-163) composes the seven boxes by their contracts ("Contracts and one composed
spec"). Each box is only what it promises and what it assumes: `Sessions`' agent row, its
process outside the BEAM, its turn, its stop, its `hand` and its press, and the agent process's
memory and budget; `Mailbox`'s mark and settle by evidence; `Prompts`' row of a dialog's
prompt and of a `restarts` prompt; the `Scheduler`'s seats; the `Ledger` as `Claim.tla`,
instanced whole; a parent's fix through `Team`, and the `Watch`'s healer through the same
claim. `Hosts` adds nothing to the interactions named, and is left out. One addressee lives the
whole life; any other agent only takes a seat, runs and ends, and shares nothing else. It
checks a delivery during a move (`NotCutByStop`, `OnlyToItsProcess`), a lease across a dialog
(`LeaseWhileLive`, `SeatsHold`), a prompt across a restart (`OneAnswer`, `KeptAcrossRestart`),
a remedy racing a fix (`OneActPerState`, `NeverWorking`), and one agent's restart and the whole
one (`OneProcess`, `AtMostOnce`, `OwnBudget`; liveness `Escalated`), each with a
`Break_Boxes_*` configuration, and liveness that a dialog passes, an ended lease is released,
a row in flight settles and every claim ends. Each contract spec's header names the
properties it exports as its box's contract and how they imply what `Boxes.tla` assumes, or
where they do not (F-163's findings). Its prompts and its healer are the seams of B1's later
parts.

The restart per agent (F-164). `Start.tla`, `Delegate.tla`, `Dialog.tla` and `Move.tla` each
gain `RestartAgent`, one agent process's crash and its supervisor's restart in one step,
beside the whole restart and bounded with it by `MaxRestarts`: that agent's memory goes (its
calls under way, a setup its reaper ends, its cue, its press tasks, its stop's idle read, the
hand of a row under way), and its row, its process outside, `Recoveries`' claims, the other
boxes and the other agents run on; its init re-adopts by the steps the whole restart's does.
`Delivery.tla`'s `AgentCut` is that cut of a hand, its write gone or not, with the mark kept
(Break `AgentCutUndoes`); `Move.tla` and `Delegate.tla` cut a hand to the session and to the
parent by it. In `Delegate.tla` a delegate's restart also cuts `Sessions`' start under way,
whose row is adopted, an orphan for `Recoveries` when the crash fell between the hold and the
line. There too the owner's promise behind every lease is a property, `WorkEndedIsFree`:
work `Delegates.Work` says ended has no process (Break `StatusEndsWork`). `Boxes.tla`'s
header maps each effect of its `RestartAgent` to the step that checks it. With one agent,
`Start.tla` and `Dialog.tla` reach the same states as before; the build note has the counts.

`Prompt.tla` (F-167) is the `Prompts` box's contract ("Prompts"): a row opened once per owner
state, answered once by its rightful answerer (a person, the app's decider for its kinds, the
asker's parent for `permission`, `plan` and `elicitation`), the answer checked on the row read
before its claim (`Claim`), marked `answering`, handed to its owner and settled by the owner's
answer or, after a restart, its evidence; a deadline that takes a declared default or expires
the row; a held request's owner as `Hold` (one response, its deadline, its holder's death);
the `stop_cap` hold at Claude Code's cap with the override as the environment's act; and a
`restarts` prompt past an agent process's budget. Invariants `OneAnswer`, `OnlyRightful`,
`NotAfterDeadline`, `DefaultOnlyDeclared`, `KeptAcrossRestart`, `NeverOverridden`; liveness
`PromptsEnd` and `Escalated`; each with a `Break_Prompt_*` configuration. `Dialog.tla`'s answer
and `Team.tla`'s ask are its instances: the dialog's mark is the prompt's row, and an ask opens
one and is answered by `AnswerNow`. Its header says how it implies `Boxes.tla`'s `pr` and `rp`.
F-179 added the parent's notice: when the asker is a delegate, one notice to its parent under
the prompt's key (`Notice`; `ParentToldOnce`, liveness `ParentTold`, Break `NoticeUnkeyed`),
also in `Boxes.tla` across both restarts on its dialog's prompt (`Boxes_Notice`, the constant
`Delegated`), and its header says that the code's prompt is its owner's row read by one
function, so the row's status here is that function's value.

`Limit.tla` (F-178) models an account's usage limit ("Usage limits"): the window that closes
and resets, agents interactive or headless whose turns end at it, Claude Code's own wait and its
menu, a person at the viewer, and the framework's record, gate, checked press, prompts and word
to go on, with a restart. Invariants `NeverSpends`, `GoOnOnce`, `MenuPressedOnce`,
`BoundedRetries`, `NoResumeOnLimited`; the action property `NoStartOnLimited`; liveness
`NoAgentLeftLimited` and `RecordRead`; each with a `Break_Limit_*` configuration. F-181 adds
the move: another account that has room or not, a delegate moved once per limit before a
reset more than `move_after` away (its claim on the row first), a main session only by a
person's answer of its `limit` prompt, and a move refused, failed, unknown or cut by a restart
left to that prompt; invariants `NeverMovesMain` and `MoveOnce`, with `Break_Limit_MoveMain`
and `Break_Limit_MoveTwice`, in `Limit_Move`, `Limit_MoveMain`, `Limit_MoveHeadless` and
`slow/Limit_MoveLarge`. Every earlier configuration sets `Others = FALSE` and keeps its state
space. F-187 adds `Delegates`' report of a headless delegate (`Report`): a result at a limit is
never one (`LimitNotReport`, `Break_Limit_LimitReport`, in `Limit_Headless` and
`Limit_MoveHeadless`); and `Read` keeps a `prompt` as it keeps an `unknown`, as the code does.
F-196 adds a start of new work (constant `Starts`): its owner picks its account on the
record, another with room taking it; refused at a limit, its row waits for the soonest reset
as a `limit` prompt, answered `wait` or `leave` or its default taken at the reset, then picked
again under the same row, waiting again for a newer limit; a restart keeps the row. Invariant
`StartPromptIsRow`, liveness `StartWaitEnds` (a waiting start is granted, here or on another
account, or left), and `NoStartOnLimited` still holds, in `Limit_Start` and
`Limit_StartMove`; `Break_Limit_NoRepick` (the start goes at its reset on the pick it was
refused by, so a newer limit read meanwhile does not hold it) fails `NoStartOnLimited`. Every
earlier configuration sets `Starts = FALSE` and keeps its state space.
F-191 models the move's own steps for a limited agent in `Move.tla` (`Limited`): a turn ended
at the limit (`HitLimit`, its rows given the limit's result), held by `Mailbox` as a stopping
row is and read as ended by the move's stop alone (`NoRowIntoLimit`,
`Break_Move_LimitIdleForAll`); the word stored first (`WordStored`), and a resume at the limit
carrying a row as its first (`LimitResumeCarriesRow`, `Break_Move_WordAfter`); a process gone
at its limit moved with no drain and no stop (`LimitMove`); a copy or resume refused leaving it
gone (`Back`), never resumed on the account at its limit (`NoResumeIntoLimit`,
`Break_Move_BackIntoLimit`); in `Move_Limit` and `Move_LimitLiveness` (`LimitMoveSettles`).
Every earlier `Move_*` configuration sets `Limited = FALSE` and keeps its state space.
F-193 models a headless session's move (`Headless`): with no row due or in flight at the
resume, the `Mover` stores a word of its own first (`OwnWord`), so every headless resume
carries a first line (`HeadlessResumeHasLine`, `Break_Move_BareHeadless`, in `Move_Headless`
and `Move_HeadlessLiveness`, with `DrainedParentMoves` and `RowsArrive`); every other `Move_*`
configuration sets `Headless = FALSE` and keeps its state space.
`Boxes.tla` composes its contracts (`MaxLimits` above 0 only in `Boxes_Limit`): the
`Scheduler`'s gate and `Mailbox`'s mark against a `limited` turn, with a dialog, a stop and the
restarts, as `NoStartOnLimited` and `NoRowIntoLimit`.
`Inlet.tla` (F-249) models the `Inlet`'s queue: two callers, each call with its deadline and
its own bound. A call starts only while its bound fits before its deadline
(`StartsInTime`, `Break_Inlet_StartLate`), and one still queued at its last start is answered
busy while another runs, so every caller has its answer by its deadline
(`AnsweredByDeadline`, `Break_Inlet_InProcess`).

**The remodel's model** (F-115). Each mechanism is written once, and the specs above are
reshaped around three new ones, in R4 and R6, before the code they describe:

| Spec | What becomes of it | What it checks |
|---|---|---|
| `Shell.tla` | kept as it is | as above |
| `Agent.tla` | kept; instances `Claim` for `Recoveries`; the comments that say `/exit` go | as above |
| `Start.tla` | kept; `StopAsked` is SIGTERM once idle; `Recoveries`' end of an orphan by pid and start time is the same `KillsOwnOnly` (both F-118); the end instances `Claim`, its state the row's record and a person's clears, and a KILL may fail: the row then waits for a person, whose clear lets the end run once more (F-128) | as above, and `TermsOnlyIdle`, `OrphanEnds`, `LateStopEnds`, `OneEndPerState`, `NoEndOnCutOffClaim` |
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

## Usage limits

An account, not an agent, reaches a usage limit, and the framework takes it as the account's
state with bounded remedies (F-178, `Limit.tla`). Limits are routine: 170 hits in one
workstation's transcripts, 94 of the five-hour window and 76 of the weekly one. Once, two
builders sat at Claude Code's limit menu for two days: nothing read the limit, nothing told a
person, nothing went on at the reset, and the app started more agents on the same account into
the same wall.

**What Claude Code does** (2.1.322; measured, or documented with its names checked in the
pinned binary):

- A turn that hits a limit writes one transcript line: `type: assistant`, `isApiErrorMessage:
  true`, `error: "rate_limit"`, `apiError: "usage_limit_reached"`, `apiErrorStatus: 429`, and
  `quotaLimits` (`status: "rejected"`, `resetsAt` in epoch seconds, `rateLimitType`
  `five_hour` or `seven_day`, `overageStatus`, `overageDisabledReason`, `isUsingOverage`), the
  same under `apiErrorParams.rate_limit_info`. A `turn_duration` line follows. Only a rejection
  writes `quotaLimits`. The `StopFailure` hook fires at a turn an API error ended, matcher
  `rate_limit`, with `error`, `error_details` and `last_assistant_message`.
- Interactive, with the setting `autoContinueAtUsageLimit` on and the reset under 24 hours
  away, the session waits ("Continuing automatically at … · Esc to cancel") and at the reset
  goes on with the same turn, no message resent; at most three automatic continuations, then
  the menu. Esc or an exit ends the wait, and a resume does not start it again. The Notification
  hook's `quota_auto_resume_fired`, `_stale` and `_disabled` fire at the wait's end. Otherwise
  (the setting off, the reset 24 hours away or more, as a weekly limit's usually is, or a model
  family's limit) the menu shows: "Stop and wait for limit to reset" (the session idles until a
  prompt), "Wait here, then continue automatically", and usage credits, which spend money where
  the account allows them.
- Headless, there is no wait: the turn ends with the limit, or a request blocks up to
  `CLAUDE_CODE_RETRY_WATCHDOG_MAX_USAGE_LIMIT_WAIT_MS`. The stream carries a `rate_limit_event`
  whose shape is not documented.
- The status line's JSON has `rate_limits.five_hour` and `.seven_day`, each `used_percentage`
  and `resets_at`. Usage credits are turned on per account or per organization on the web; no
  setting of Claude Code forbids them, and the record's `overageStatus` says whether this
  account may spend.

**The evidence and its one reader.** `Usage` is the one reader of an account's limit. It takes
the record from any agent on the account: the transcript line (`Transcripts`, every mode), a
headless stream's `rate_limit_event` (`Stream`), and the status line's numbers, a window at
100 % with its `resets_at`. The `StopFailure` hook's input carries no reset and fires at most
sometimes headless (F-181's new-1, decided): it is evidence of the agent's turn only, as the
stream's `result` with `api_error: "usage_limit_reached"` is, never of the account's reset. Its reading per account gains
`limited_until` (the reset), the window, `can_spend` (from `overageStatus`: true only for a
value that says credits are on) and the evidence it came from (the agent, the line or the
event). A later reset or a newer record replaces it; each record is a fact in the `Ledger`.
`Usage` cues `usage:<host>:<account>` as before, which now reaches `Sessions` and `Mailbox`
beside the `Scheduler`.

**The account's state.** Limited until `limited_until`. The `Scheduler`'s budget gate already
refuses a spent window at once with `retry_at` its reset ("A lease"); the record is that spent
window, exact where the status line's reading may be hours old, so no start, resume or heavy
lease is granted on the account until then, in any class, and a refusal is `{:refused,
{:allowance, retry_at}}` (`NoStartOnLimited`). New work (a start, a resume that must leave its
account) picks among the usable accounts only, prepared, logged in (`Logins`) and not limited,
the one with the most room in the tighter of its two windows (`Usage.pick/4`, decided by the
operator, F-181); a running agent moves only as "The move" below says.

**The agent's state.** `Sessions`' turn function answers `limited` (the window and the reset)
for an agent whose turn ended at a limit, until a turn of it runs after the record: never idle,
never stuck, and `limited` is not an ended turn. The remedy's phase is a field of the agent row,
as a move's is, so a restart reads it again. `Mailbox` hands no row to a `limited` agent before
the reset (`Boxes.tla`'s `NoRowIntoLimit`): a row would start a turn that hits the limit again.
Every action below is decided on the newest record and the screen read before it
(`Limit.tla`'s `Current`): a record read late never makes a press or a word go.

**The remedies**, each a row before it acts, once per limit:

| The agent shows | The framework | Its bound |
|---|---|---|
| Claude Code's own wait | watches: a turn after the reset clears `limited`; the wait ended with no turn (Esc, an exit, `_disabled`) is taken as the menu's stop; the wait still shown at the reset plus a margin (`_stale`, or nothing) is a `limit` prompt | sends nothing into the wait |
| the menu, the account unable to spend | presses "Stop and wait for limit to reset" at once, found by its label, checked on the screen in the same step (`Inlet`'s checked press, as a startup dialog's) | once per menu shown; a press whose outcome is unknown is never sent again, and the menu still shown after it is a `limit` prompt, whose answer clears that press once (`MenuPressedOnce`) |
| the menu, the account able to spend | opens a `usage_credits` prompt: "stop and wait" or "use credits"; its default at its deadline is the stop; the answer is pressed as above | credits only by a person's answer (`NeverSpends`) |
| a headless turn ended | nothing until the reset; a delegate's limited result is not its report, and its exit is not a kill (F-187) | — |
| a delegate's turn ended at a limit whose reset is more than `move_after` away (default 2 hours, the config's), another usable account with room | one move through the `Mover` ("The move" below) | once per limit, its claim in `Acts` first (`MoveOnce`); refused, failed or unknown, a `limit` prompt |
| at the reset, for each `limited` agent whose own wait did not go on | writes on its row that a word is owed, then stores one word to go on in `Mailbox` under the key `limit:<agent>:<resets_at>`; `Mailbox` hands it into an ended turn, or by `launch` as the prompt of a resume when the process is gone, under a lease the gate grants | at most one word per agent per limit, none to an agent whose own wait went on (`GoOnOnce`); past three go-ons in a row that each hit a limit again, a `limit` prompt in place of the fourth (`BoundedRetries`) |

The go-ons in a row are counted on the agent row and start again when a turn ends by itself or
a person answers. A delegate's resume that carries the word is not the resume after a kill:
it does not count toward `Delegates`' one. After a reset every `limited` agent goes on or is a
person's prompt (`NoAgentLeftLimited`).

**What is a person's**: usage credits, only by the `usage_credits` prompt's answer and only
where the account allows them; the `limit` prompt's answer (go on now, move to another account,
or leave it), opened on the agent row by the healer (`Limits`) with no deadline, so it
waits for a person; and anything a
person does at the viewer first (an Esc, a menu's option, a prompt typed), which the next screen
read takes as it finds it and which withdraws the prompt it answered. The `limit` prompt of a
start refused at a limit, its owner's row (F-196), keeps its deadline and its default, the
wait; its answers are `wait` and `leave`.

**The move** (decided by the operator, 21 Nov; `Limit.tla`'s `Away` and `MoveAct`, F-181). A
limited delegate moves on its own: when its account's reset is more than `move_after` away and
another usable account has room, the remedy is one move through the `Mover` (drained, ended,
the conversation copied, resumed on the other account under its name and session id),
recorded in `Acts` before it acts, at most once per limit. A move refused or failed leaves it
limited on its own account, waiting, with a `limit` prompt; one whose outcome is unknown, or
whose claim a restart cut, is that prompt too, never a second move. An account able to spend
credits is never counted as having room by its credits. A main session never moves on its
own: its `limit` prompt offers "move to <account>" beside "wait", and only a person's answer
moves it (`NeverMovesMain`). The move is a remedy on the healer's allow-list (`move`), as
`press_stop` and `go_on` are.

How a limited agent's move goes (F-187's new-1, decided; `Move.tla`'s `Limited`, built in
F-191). The healer stores the word to go on first, under the limit's key, held while the agent
is `limited` (a delegate's through `Delegates.go_on/5` with no resume of its own, a main's as
the notice it gets at a reset); the word says only that the turn stopped at a usage limit and
to go on, true whether the agent moved or waited (F-187's new-3), so a failed move's word at the
reset is the same row. Then the `Mover`, which takes the healer's claim as its own act:

- for `for: :move` alone, a `limited` turn is ended. An interactive session whose file does not
  read idle is read from its screen in its place (Claude Code's own wait or its menu, through
  the `Inlet`), and the SIGTERM ends the wait (F-181); a headless one's stream reads its turn
  ended;
- a row whose process is gone at its limit (a headless delegate exits at once) skips the drain
  and the stop;
- the resume carries the first row due, the word, as an interactive session's prompt by launch
  or a headless one's first line by stream (as `Delegates`' does, F-152);
- a copy or a resume refused on the other account leaves its process gone, never resumed on its
  own account, which is at its limit: the act failed, a `limit` prompt, and at the reset the
  word resumes it.

**The code unit's list** (one unit after this one, against `Limit.tla` and `Boxes.tla`):

1. **Settings per account**, written where the status line command is written today, in each
   account's framework settings: `autoContinueAtUsageLimit: true`, whatever the app's settings
   say. The hooks need no matcher of their own: `Intake`'s post every `StopFailure` and
   `Notification`, `quota_auto_resume_*` among them. A launch sets no
   `CLAUDE_CODE_RETRY_WATCHDOG_MAX_USAGE_LIMIT_WAIT_MS` (F-181's new-2, decided): unset, a
   request at a limit already fails at once, and the bound acts only under
   `CLAUDE_CODE_RETRY_WATCHDOG`, with which a request retries for hours and reads as a turn
   still running. `ClaudeCLI`'s `env -i` keeps both out, as every `CLAUDE_CODE_*` a launch does
   not name.
2. **What each reader parses.** `Transcripts`: the assistant line with `isApiErrorMessage:
   true` and `apiError: "usage_limit_reached"`, its `quotaLimits` (`resetsAt`,
   `rateLimitType`, `overageStatus`), and whether a turn followed it. `Intake`: the
   `StopFailure` event and the three Notification matchers, each a fact of the agent's turn.
   `Stream`: the result that ends a turn at a limit and the `rate_limit_event`, by the shape
   measured. `Usage`: the fields above on its reading, from the transcript's line, the stream's
   event and the status line.
3. **`Screen`'s kinds** `usage_limit_menu` (its options by label, the selected one; the third
   is what the account allows, F-181's new-4) and `usage_limit_wait` (the time its notice
   names, "Continuing automatically at … · Esc to cancel"; a screen with it is never an ended
   turn, so no text is typed into the wait, F-181's new-3), from fixtures captured on 2.1.322,
   and `Inlet`'s checked press of the menu's option by label ("Stop and wait for limit to
   reset", checked after).
4. **`Sessions`**: the turn state `limited`, the phase on the agent row, the timer to the
   record's reset plus the margin, after which it reads the turn and the screen and acts only on
   what it reads; the `limit` and `usage_credits` prompts opened through `Prompts`.
5. **`Mailbox`**: the word's kind `go_on` and its key, rows held from a `limited` agent until
   its reset, and the word handed by `launch` to a gone process under a lease.
6. **The `Scheduler`**: `limited_until` read as a spent window by the budget gate.
7. **The `Watch`**: a symptom `limited`, each limit with its window, its agents, the time each
   waited and the remedy taken. Each remedy above is an instance of the healer ("Metrics and
   healing", F-182): the symptom `limited`, its remedies `press_stop`, `go_on` and `move` as
   entries on the allow-list, never a mechanism of their own.

Built in F-181: the model of the move; `Usage`'s part of item 2 (the stream's `rate_limit_event`
read, a limit record taken by `Usage.take/4`, `limited_until` on the reading) and item 6 (the
gate reads `limited_until` through `Usage.Room`); picking and `Logins`.

Built in F-185: item 1; item 2's readers (the transcript fold's `limit`, which `Usage` takes on
each `transcripts:` cue; the stream's `result` keeps its `api_error`); item 3's two kinds, their
fixtures F-181's captures, scrubbed; item 4's turn state `limited` (`Sessions.Turn`, from the
agent row's `usage_limit`, written by `Sessions.put_limit/4`); and item 5's held rows: `Mailbox`
hands no row to a `limited` agent before its reset, and reads its turn as any row's after it
(`Sessions.Agents.unheld/2`).

Built in F-186 (F-185's new-1 and new-2, decided): one healer, `Limits`, in `caf_recoveries`
after `Sessions`, `Mailbox`, the `Watch` and `Mains` in the tree, reading the `sessions`,
`transcripts`, `stream`, `intake` and `watch` cues and a timer of its own to each row's reset
plus a margin (2 min) or the `usage_credits` prompt's deadline (10 min). Per agent, against
`Limit.tla`: the newest record read onto the row (`Read`; a transcript's line, or a headless
stream's limited result with its `rate_limit_event`), the limit cleared once a turn ran after
it (`Continued`, its count of go-ons kept until a turn ends by itself, `Ended`), and each
phase: the screen read (`look`), Claude Code's own wait watched (`own`), the menu's stop
pressed (`press`, through `Sessions.press_limit/3`, the `Inlet`'s checked press of kind
`usage_limit_menu`), a `usage_credits` prompt where the account can spend, and at the reset
the word (`send`, `Mailbox.notify/4` kind `notice` under `limit:<agent>:<until>`), a gone
main resumed with it through `Mains`. The row's field is `Sessions.Limit`'s; `Sessions` writes
each phase from the step the healer read (`put_limit/4`'s `from:`), and a person's answer
through `Sessions.answer_limit/6`, so one answer gets in. On the allow-list: `limited` shown
only (state `limited:<agent>:<until>`), `limit_menu` by `press_stop` and `limit_reset` by
`go_on`, each state `<kind>:<agent>:<until>`, 20 per bound. `Prompts` shows the `limit` prompt
(answers `go_on` and `leave`, `Limit.tla`'s `AnswerLimit` and `Leave`) and the
`usage_credits` prompt (the menu's stop or its credits, by label) from the row's step. The
move and a delegate's word by `launch` came after: F-187 and F-191 below.

Built in F-187 (F-186's new-1, decided): a headless delegate's limited turn is not its report
("The delegate protocol"). At the reset `Limits` hands a headless delegate's word to
`Delegates.go_on/5` (`go_on:`) in place of `Mailbox.notify/4` and a resume of its own: stored
as the delegate's word to go on under a uuid of its key, the row's turn that word's, a gone
process resumed with it under its start's lease as `going_on`, not counted as the resume after
a kill. `Limit.tla`'s `Read` keeps a `prompt` as the code does (F-186's new-3), and "Metrics and
healing" says a limit kind's ask is its `limit` prompt (new-4).

Built in F-191 (F-187's new-1 to new-4, decided, and the operator's move): before the reset, a
row at `idle` or `own` whose reset is more than `move_after` away (the config's `limits`
option, 2 h by default) and for which `Mover.room/2` finds another usable account with room is
moved once per limit (the row's `away`): a delegate by `Limits`' remedy `move` of kind
`limit_far` (20 per bound), claimed, the step `move` with its act on the row, the word stored
and held, then `Mover.move/4` with `act:` that claim; a main by its `limit` prompt, which
offers `move` (to `move_to`) beside `go_on` (the wait) and `leave`, and only that answer
moves it, a claim of its own naming the person. The move's row in `Acts`, read once the row no
longer moves, makes the step `moved`; any other end is the `limit` prompt. The `Mover` moves a
gone limited row (`Sessions.begin_move/4` takes one), resumes a headless delegate with its
first due row by stream, and leaves a limited row gone when its copy or resume is refused.
`Sessions.stop/3` `for: :move` reads a limited interactive session's screen. An interactive
delegate's word is `Delegates.go_on/5`'s too, and its limited turn neither a finish nor a kill.
One text for every word. And a delegate's start is confirmed by the init naming its session id
whether its process still lives or not (F-187's new-4): the hold removes an earlier hold's
record, so a record there is this start's, and a process gone after its init is a running row
that exited.

Built in F-193 (F-191's new-2 and new-4, F-186's leftover, F-192's new-1 and new-2, decided): a
headless move with nothing due carries the `Mover`'s own word ("How `Mover` does it");
`Watch.limited/2` (`Watch.Limited`, the app's `limited/1`, the console's `limited(caf)`), the
digest of `limited` by account: one reading per account limited now, its newest reset and its
window, and its agents, each with its own reset and how long it has waited since its limit was
read; each healer's claim keeps its symptom's state in its `detail` as `symptom`, and
`Acts.acted/4` merges an act's `detail` into the claim's, never over it (a `Recoveries` reopen's
pane is its `pane`), so a person's answered prompt can be read with its act's row; and a press
a person's `act` took is `by` that person. The runbook's `usage-limit` record takes the session
file during Claude Code's own wait. Not built: the `Scheduler`'s `limit` prompt for a start
refused at a limit, and the inbox's reading of a person's act (F-193's new-1 and new-2).

Built in F-196 (F-193's new-1 and new-2, decided: the prompt is the start's owner's row,
answered `wait` or `leave`; `Limit.tla`'s StartRefusedAtLimit, AnswerWait, AnswerLeave,
WaitDefault and StartAtReset). New work picks its account inside its owner; when every
usable account is limited, `Usage.pick/4` refuses `{:allowance, until}`, the soonest reset,
before anything is written. Now the owner writes its row first: a delegate's start as
`Delegates`' row `waiting` (the start's request kept on it, its parent owed the outcome as a
queued start's is, F-170), a main's start or resume as `Mains`' start row `waiting` (its
sender owed the outcome). The start answers at once with `waiting: until`, whatever its
`wait:`. At the reset plus the owner's margin (`limit_margin:`, 2 min) the owner picks again
and asks for its lease under the row's own request id; a newer limit makes it wait for that
reset, and its prompt opens again. A restart keeps the row and sets its timer from it. The
pick reads the owner's clock, as the row's deadline does. While it waits, a second start of
the name is refused `{:waiting, name}`, and the row holds its place in its parent's cap. The
inbox's part is in "Prompts".

Built in F-203 (F-196's new-3 and new-4): `run_delegate` of a start that waits answers
`%{delegate: name, waiting: until}` at once, as `start_delegate` does, since a reset hours away
outlasts any await; the report comes later as a message. An absent main's resume that waits
(`AbsentMains`) leaves the healer's claim `acted`, its detail naming the `Mains` row, and the
claim is settled from that row's end: `verified` when it ran, `failed` when a person left it
or its pick was refused, so the fault ledger shows it and the absence is asked
(`Remedies.tla`'s ActWaits, SettleWait, WaitedEnd and WaitSettled, `Break_Remedies_SettleAtWait`;
`Heal.tla`'s act whose outcome comes later). F-206 (F-203's new-3): a person's `leave` of the
wait is their answer to the absence too, so the same person is not asked the same thing twice.
The settle of a wait left by a person (its row `refused`, reason `left`, `waited` the person)
asks the absence and clears it at once, `Watch.clear/3` as that person, as `Recoveries` copies
a `remedy` prompt's answer; a pick refused at the reset is still asked. `Heal.tla`'s
SettledLeft takes the state as asked and closed in one step, `Remedies.tla`'s `LeftNotAsked`
checks no prompt of it is open, and `Break_Remedies_AskLeft` (the leave not copied) breaks it.

**Measured** (F-181, by hand on 2.1.322, against a local endpoint at `ANTHROPIC_BASE_URL` that
answers 429 with the unified rate-limit headers the pinned binary reads, a dummy subscriber's
token, and a scratch config directory; `docs/build-notes/F-181.md` keeps each line):

- Headless: one `rate_limit_event` (`rate_limit_info`: `status: "rejected"`, `resetsAt`,
  `rateLimitType`, `overageStatus`, `overageDisabledReason`, `isUsingOverage`, and
  `unifiedWindows` with the closed window's `utilization` and `resetsAt`), an assistant line
  with `error: "rate_limit"`, `is_api_error_message: true`, `api_error: "usage_limit_reached"`
  and `api_error_params.rate_limit_info`, then a `result` with `is_error: true`, `api_error:
  "usage_limit_reached"`, `api_error_status: 429`, `terminal_reason: "api_error"` and the
  limit's text; exit 1, at once. The transcript line is the interactive one. After an answer
  that was not limited, the stream's `rate_limit_event` carries both windows' `utilization` and
  `resetsAt`: a headless session's reading, as the status line is an interactive one's.
- `CLAUDE_CODE_RETRY_WATCHDOG_MAX_USAGE_LIMIT_WAIT_MS` changes nothing on its own: unset, 0 or
  20 000, the request fails at once. It bounds a wait only under `CLAUDE_CODE_RETRY_WATCHDOG`,
  with which the request retries (`system` lines `api_retry`, up to 300) and the turn reads as
  running; the launch's `env -i` keeps both out.
- `StopFailure` (matcher `rate_limit`) has `error: "rate_limit"` and `last_assistant_message`
  (the limit's text), and no reset and no `error_details`. It fired at each interactive hit,
  and at one headless run in nine. `quota_auto_resume_fired` came as a `Notification` with
  `notification_type` and `message` when the wait went on.
- Claude Code's own wait shows "Usage limit reached · continuing automatically at <time> · esc
  to cancel" in the turn and "⚠ Usage limit reached · limit resets <time>" and "Continuing
  automatically at <time> · Esc to cancel" below the input box, which stays shown and empty. It
  went on 50 s after the reset ("Usage limit reset · Continuing automatically").
- The menu: "What do you want to do?", "1. Stop and wait for limit to reset", "2. Wait here,
  then continue automatically at <time>", and, where credits are off, "3. Upgrade your plan".
  Esc leaves the screen the stop leaves: the limit's text and an empty input box.

**Still to measure**: whether the three automatic continuations are counted in a row or per
session; the credits' option's label where an account can spend; and whether the 94 five-hour
hits waited and went on by themselves (a fold of the transcripts after each hit).

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
  (`settings.json`, `.claude.json`, credentials), with one exception: the trust mark of a
  worktree it made ("Startup dialogs", F-255), one key of `.claude.json` written under Claude
  Code's own lock. An agent's settings are one file: its launch
  options' overlay merged over its account's settings, since `--settings` takes one value
  (F-110).
- Every settings file the framework writes, a main's and a delegate's, carries
  `skillOverrides` with `"auto-mode-setup": "off"` (F-285): Claude Code 2.1.322 otherwise
  offers "Teach auto mode about your environment?" at a turn's end once auto mode has blocked a
  few actions and no `autoMode.environment` entry exists, and on a delegate the offer came back
  every turn and held its messages. The framework owns that one entry, not the key: an
  account's `skillOverrides` entries are kept, with the framework's over its own for the same
  skill, as `autoContinueAtUsageLimit` is; an agent's launch options merge theirs one by one
  over the account's and are refused `{:reserved_skill, "auto-mode-setup"}` for the
  framework's. The offer, if it ever shows (a managed setting over `--settings`, or a release
  that reads the entry otherwise), is a menu no
  rule names, read with its title, and a person answers it ("A menu on a running screen").
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
- Remote Control is for main sessions only, never for a delegate: it follows the kind, not the
  role (decided, F-275). A main session launches with `--remote-control` and the main
  session's settings file, `remoteControlAtStartup` true. Every delegate, headless or
  interactive, launches with no flag and the delegate's file, or its overlay of it, with
  `remoteControlAtStartup` false, since no flag turns Remote Control off. An interactive
  delegate still runs in the main role, Claude Code's terminal interface, but it is not in a
  person's Remote Control list: a person looks at it, or steers it, through the app's panel.
  Remote Control starts only with an interactive session, and a check against each pinned
  Claude Code release confirms a headless delegate starts with it off.
- A main session shows under a title the app gives (`title:` at its start and resume, such as
  `"<org> - <project>"`), which its launch passes to `--name` and `--remote-control`; with
  none, its agent name. The agent name stays the address other agents message. A resume that
  names no title keeps the row's, so the app changes a stopped main's title at its resume.
  The start is confirmed by the session file that carries the title (F-275).
- An interactive session in a new directory meets the workspace trust dialog first, and until it
  is trusted Claude Code runs no status line; a project whose `CLAUDE.md` imports a file outside
  its folder meets the imports dialog next. Neither sends a hook event, and no session file
  exists while one is shown, so a start that nothing answers sat on one for hours, holding its
  slot, with nothing to see it. `Sessions` reads the pane, the row says `dialog`, and a person
  answers it by label ("Startup dialogs"); nothing answers one on its own unless the app chose
  to. The settings never set `disableAllHooks`. A headless delegate skips both.
- A headless session draws no status line; its event log's `rate_limit_event` stands in
  ("Headless delegates").
- Every launch sets `DISABLE_AUTOUPDATER=1`, because devenv pins Claude Code and a session that
  updates itself runs a version the lock does not name.
- Every launch, job and service sets `ToolHome`'s environment, and every ssh to a host takes
  its options (F-155): an agent's git, gh and ssh then read and write only the home, not the
  person's `~/.gitconfig`, `~/.config/gh` or `~/.ssh`, so a home moves whole to another machine.
  Its `PATH` puts devenv's programs first, so a session's own Bash tool runs devenv's git, not
  the system's; macOS's `/usr/bin` comes after, for `security`. Agents commit as the app's
  author (`git.name`, `git.email`, per home with an override per project), distinct from the
  person, and sign with the home's own key, never one of the person's; `gh` pushes with the
  person's own login, kept in the home (`bin/caf-login --gh`). GitHub shows such a commit
  Verified when the key is a signing key of the person's account (`bin/caf-login --git` offers
  to add it) and the commit's email is one of that account's verified emails, its noreply
  address included, whatever the name.

## Allowance

`Usage` reads each account's two windows from the JSON Claude Code hands the status line
command the framework writes into each account's settings (`rate_limits.seven_day` and
`.five_hour`: the share used and when it resets), and from a headless session's
`rate_limit_event`, the newer of the two. It reads no credential and calls no API.

- A reading never goes stale (decided by the operator, F-181): an idle account's share does not
  grow, so its old reading is still right, and a view shows its age. Until F-181 a reading
  older than 6 hours counted as unknown, and an idle account dropped out of every pick.
- A window past its `resets_at` has its whole room again, with no session needed to say so; a
  view shows the weekly one as assumed until a session's first answer on that account gives a
  real reading.
- An account with no reading counts as 0 % used, assumed, as a reset week does (F-146's new-1,
  built in F-147): nothing on it has run, and an account has no reading until a session on it
  draws its status line, so a new home could otherwise start no session. The first status line
  replaces it.
- `pick` answers, among the usable accounts (prepared, logged in, and any the app's `usable`
  lets), the one with the most room
  in the tighter of its two windows, the first named at the same room; a spent one, by a window
  or by its limit, never, and credits never count as room. With none it refuses, saying why
  (`none_usable` with each account's reason, or `allowance` with the earliest reset).
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
- No test the gates run reaches the real Claude Code. `caf_real`'s tests do, only under
  `mix test.real` with `CAF_REAL_SETUP` set: the end-to-end run's steps as tests (F-223).
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
- A stand-in does what the real program does that the framework reads, with nothing a test
  setup does for it: the interactive one makes its own `sessions/`, answers `auth status`, and
  writes 2.1.322's session file as its screen changes (F-232). Its tests' setups had made the
  directory, so no whole tree with it ever reached running.
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
    parent's, in `Grants`. Then a delegate's `effort` (`--effort`) and its default
    `includeGitInstructions: false` (F-200; "What `Delegates` holds").
12. **PreToolUse and PostToolUse hooks**: held like `PermissionRequest`, PreToolUse answered by
    an app callback with a short deadline (allow, deny or ask), PostToolUse by a replacement
    of the call's output (F-197); then a permission policy asked
    before any request waits for a person, its decision recorded as a person's is.
**The remodel** (F-115, taken in F-116) comes next, before the rest of item 13 and item 14, so
that each later unit is a few lines in one part of one shape rather than one more copy of a
mechanism. Each unit keeps every gate green at its end. Sizes are changed lines apart from
fixtures, estimated by F-115. R1 to R3 change no behavior and may go in any order; R4 and R6
are the model before the code they describe (R5, R7 to R10). R9 goes before R8: R8's typed
write needs R9's turn function for an interactive session, never one read alone (F-127's
new-2, F-113's new-2).

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
  In two parts (F-125's new-1). Part 1, built in F-125: the brief, the word to go on and the
  report as rows, the transports `stream` and `call`, `Delegates`' report reduced to `taken`.
  Part 2, built in F-127: the transport `waiter` with its take bound and `Intake`'s waiter cue,
  the waiter's hook in a main session's start, and `Sessions`' idle read and delegate stop
  reading `Mailbox` (`open_to:`) in place of `stop/4`'s word.
- **R8. `Inlet`**: `Control` with `Screen`'s box check, the checked write for a session with no
  waiter, as the transport `typed`. It records the release each session runs, and never trusts
  one read for a turn's end (F-113's new-2, new-4). About +200, −140. Built in F-132: `caf_control`
  became `caf_inlet`, whose `Inlet.type/4` is the transport `typed` in `Mailbox`
  (`Transport.Typed`); `Tmux.capture/3` reads a pane under the tag check; `Sessions` records an
  interactive start's release (`claude --version`) on the agent row; the viewers' tmux use moved
  to `Sessions` and `Recoveries`, and `Control`'s uncalled `interrupt`, `stop` and `respawn` went.
- **R9. The agent row and the tree**: `Sessions`' row takes kind, parent and project; the tree,
  the statuses that hold an agent and each session's turn state are functions there; `Grants`,
  the `Tracker`, `Mailbox` and the app read them, and no part opens another's table. A main
  session is a row of kind `main` (most of item 6). About +300, −350. Goes before R8. In two
  parts (F-129's new-1). Part 1, built in F-129: `Sessions`' `agents` table (from
  `held_sessions`) with kind, parent and project, a main session the app declares written
  `declared`, a delegate done for good `ended`; `Sessions.Agents`, the read side every other
  part uses, with the tree as one function of the rows and each status's meaning once, checked
  when it compiles; `Delegates`' table cut to its own facts; `Grants`, the `Tracker`, `Mailbox`,
  `Delegates` and the app reading through it; `Sessions`' and `Delegates`' `Tracker` sources
  made from their tables' metadata (`TableSource`). Part 2, built in F-130: the turn state per
  kind of session (`Sessions.Turn`, which `Mailbox`'s stream transport and the `Tracker`'s tree
  read), the `Acts` rows (a start, `Delegates`' resume, a service's restart and stop, a part's
  crash), `Store.update/4`'s one rule for a term in a column with the stored values converted
  on open, `Stream`'s and `Intake`'s sources as `TableSource`, and `agents()` without the
  delegates that ended unless asked (`all: true`).
- **R10. `Acts`**: `Claims`' and `Recoveries`' rows in one table with a unique index and a cue;
  the fault ledger of item 14 is its query and its topic. About +250, −300. Built in F-126:
  `Acts` writes the rows; R9's part 2 (F-130) wires starts, resumes, a service's fixes and
  raised errors into it (F-126's new-1, new-4).
- **R11. `Cues`**: each part declares the topics it reads; `Jobs` and `Services` cue; the app's
  routing table and its ticker go. About +200, −200. (F-102's new-3.) Built in F-131: the
  graph is in "The parts".
- **R12. `Mover`**, on the agent row and `Delivery`, against the rewritten `Move.tla`, for
  delegates as well as main sessions (item 5). Built in F-133 ("How `Mover` does it"); the
  move at 90 % of an account's allowance is not (F-133's new-2).
- **Cleanups the remodel left** (F-136): `Mailbox`'s hand-on in a task (F-132's new-2); the
  readers' problems by `Store.text/1`, converted on open (F-130's new-2); an owner's end that
  ends its services an `Acts` row, actor `app` (F-130's new-3); the model on the agent row
  (F-133's new-3); the indexed reads a ledger that keeps every row needs, `Recoveries` by
  actor, target and time (F-126's new-5, F-129's new-5).
- **After R12: `Scheduler`**, against `Schedule.tla` (modeled in F-134): the `leases` table
  on `Store`, the grant transaction, the compare-and-set release, the monitor and the
  reclaimer by the owner of the work's row, the queue with its classes, the hold, rotation,
  aging and deadlines, the pressure and budget gates, and its telemetry (each grant's wait,
  refusals per class and module), shipped together so the thresholds are set from the
  workstation's own readings. `Usage` reads the five-hour window beside the weekly one. Every
  start, heavy run and landing asks it first; item 14's admission is this unit. Built in
  F-135 with `Delegates`' start; `Jobs`' start (its job row the holder), the heavy slot's
  fence and a landing's gang lease in F-139; a main session's start by `Mains`, class main
  session, in F-141.

About 3,100 lines change in all; the library ends about 1,300 lines smaller, and the model about
the same size with each mechanism once. R6 and R7 are the riskiest: `Mailbox`'s `sending` as the
only mark keeps `Stream`'s guarantee that "undelivered" is final and resent first under the same
uuid, and each spec that instances a module compares its state counts before and after.

13. **What is left of the main sessions' work**, on the remodel's shape (`Screen` is built,
    F-113; the waiter is R5 and R7, the checked write R8, the end by SIGTERM R3 and R6, the
    reach across accounts R2, `Mover` R12): **interactive delegates** (`interactive: true`: an
    agent row of kind `delegate` whose turn state and transports are an interactive session's;
    built in F-137, with the `launch` transport, "Interactive delegates"),
    then **`Mains`** (item 6: what R9 leaves, the checkout, the pull after a landing and
    `start_main`; built in F-141, against `Checkout.tla`), then a main session's end, the
    operator's `end_main`, with its kept services (F-109's new-4) ending with it, and F-141's
    follow-ups (`resume_main` under its own lease, a refused start's brief settled, a locked
    checkout shown; built in F-143, against `Team.tla`). F-140's follow-ups (the dialog's press
    in a task, a person's clear of a cut press, the stop of a row on a dialog, a shortened
    imports path, the answer as an `Acts` row) and F-143's (the operator's resume of a main
    session, the end kept on the row, `main_starts`' `resume`) are built in F-144, against
    `Dialog.tla` and `Team.tla`.
14. **Mechanisms an app's policies stand on**, on the remodel's shape, in this order:
    - a delegate idle with no report, a value of `Sessions`' turn function that `Delegates`
      tells its parent, in `Delegate.tla` (built in F-150, "The delegate protocol");
    - admission is the `Scheduler`'s lease ("A lease"; its code after R12), asked by
      `Sessions`' start, `Delegates`, `Jobs` and a landing, in place of a check of its own in
      each; its refusal is `{:refused, {reason, retry_at}}`, never a failed run;
    - `Stop` held for an app callback, the hold kind `stop` of `Intake`, so an app's own check
      before a turn ends answers it;
    - copies by the file system's clone where it has one;
    - a start idempotent per branch, a lookup of the agent row: a second start answers the
      running delegate only while its session is live, and a row with no report whose session
      is gone does not count as running (built in F-150, `Delegate.tla`'s `StartAgain`).

    The fault ledger is R10. Which tests to rerun on a red, which edits to guard, and a replay
    suite are an app's policies, not the framework's. A re-entry brief after a reset and a
    reviewer with its acceptance list were too, until F-162 made them `delegate`'s `fresh` and
    `review` options (B11 below): the mechanism is the framework's, what the list says is the
    app's.

**The boxes** (F-162) come next, before the rest of item 14 and items 15 to 17, so that each
later unit is built behind one box's interface and the agents' seven verbs. Item 14's `Stop`
held for the app is a `Hold` kind and may go in beside them; it counts its blocks per agent,
since Claude Code overrides a `Stop` hook's block past 8 in a row with no tool call between, and
at the cap it hands the agent to a person as a `stop_cap` prompt in place of being overridden
(decided); the override is an action of the environment in its spec, and whether the waiter's
wakes count toward the cap is measured per release (F-162's new-11; on 2.1.322 a turn's end
resets the count, whether a person's prompt or a wake starts the next, F-171). The `stop_cap` prompt is
the hold of the cap's last honored block: a person's "go on" is that block, and past it the
hold passes and the turn ends, recorded `capped`; a person who wants more sends a message
(F-167's new-1). Built in F-157 with a pause per agent and per project ("Intake"); until B6
the `stop_cap` row is `Intake`'s, answered by `Intake.answer/4`.

Skipped, decided by the operator (F-162): forcing a model to be deterministic, debate between
agents, outside record and replay libraries (the `Ledger`'s replay covers it), Claude Code's
checkpoints for rollback (worktrees stay the unit), and post-mortems written by a model (the
`Ledger`'s facts instead). Each unit keeps
every gate green. Sizes are changed lines apart from fixtures, estimated by F-162. B1 is the
model before the code it describes (B4, B6, B8, B9, B11); B2 and B3 change no behavior.

- **B1. Model**, specs only, in five parts that may land apart. First each box's contract
  stated in its spec's header and as the properties it exports, and `Boxes.tla` (about +400),
  composing the boxes by their contracts: a delivery during a move, a lease across a dialog, a
  prompt across a restart, a remedy racing a fix, one agent's restart and the whole one
  (decided; built in F-163, "The model"). Then the restart as a step per agent
  (`Restart(a)`) beside the whole one in `Start.tla`, `Delegate.tla`, `Dialog.tla` and
  `Move.tla`, bounded by `MaxRestarts`, with state counts compared before and after (about
  +200; built in F-164, with `Delivery.tla`'s cut of a hand by its addressee's restart and
  `Delegate.tla`'s `WorkEndedIsFree`); `Prompt.tla` (about +300), instancing `Hold` and `Claim`, with `Dialog.tla`'s answer and
  `Team.tla`'s ask as its instances (built in F-167; `Team.tla`'s `AnswerClaimed` is left, its
  new-5); `Heal.tla` (about +250), instancing `Claim`: a symptom, the
  allow-list, a remedy claimed once per state, its precondition read before the claim, verified
  after, a cap per window that turns acting into a prompt; and `Delivery.tla`'s subscription
  (about +150): a row stored waiting on an event key, fired once by the event's fact (one
  recorded before the subscription since the moment it names too), then delivered as any row,
  with a restart between the fact and the fire.
- **B2. Box facades and the boundary gate**: one public module per box (`Sessions`, `Mailbox`,
  `Prompts`, `Team`, `Scheduler`, `Hosts`, `Watch`) and the `Ledger`'s in the base, with the
  interface above, every other module
  `@moduledoc false`, and `mix caf.deps` taught the box of each app so a call from outside a box
  goes only through its facade. No apps merge: the umbrella's layers and the gate already earn
  their keep, and merging buys only fewer `mix.exs` files (F-162's new-7). About +500, −150.
- **B3. The app's surface**: `CodingAgentFramework.child_spec/1` from one config struct checked
  whole, one supervisor of the boxes in order, `operate/4`, `view/2`, `query/2` and
  `subscribe/2`; `caf_example` keeps its config file and its console, and loses its
  supervisor's wiring. The ends (an ended agent's services ended) are the library's, since
  every app needs them (F-169's new-1); F-169 built `child_spec/1` and moved them. This is item 15's library supervisor, with the instance's name every
  per-instance `Registry` is named from. About +500, −800.
- **B4. One agent process per agent**, against B1's `Restart(a)`: `Sessions` becomes a
  `DynamicSupervisor` of agent processes, each under its own small supervisor with the app's
  restart budget, each the writer of its agent's row, re-adopting from the row at every
  `init`; the per-host and per-account supervisors; a budget run out recorded, for B6 to turn
  into a prompt. The largest unit of the path, since `Sessions` is the largest part: about
  +900, −700, and it may split by kind (a main session's, then a delegate's).
- **B5. The seven verbs**: `Team.operate/4` and the MCP endpoint serve `delegate`, `message`,
  `ask`, `look`, `steer`, `wait_for` (answering `refused{not_built}` until B9) and `serve` over
  today's mechanisms; `end_main` and a main session's move and resume go to the app's surface;
  `reload` stays hidden until F-162's new-2 is measured; `run` is gone (F-176).
  About +600, −700, most of it tool schemas and their tests.
- **B6. `Prompts`**, against `Prompt.tla` (its first part built in F-179: "Prompts" says what,
  with no table of its own): the `prompts` table, `open/2`, `answer/3`, `read/2`
  and the `prompts` cue; an ask, a held permission request (a subagent's included) and a startup
  dialog opened as prompts and answered through it; `answer_startup`, `Mailbox.answer/4` and the
  operator's request answer become the app's one `answer/3`; the `restarts` kind from B4. Then,
  one small unit each, the kinds that need a reading first: `plan`, `elicitation`, `limit` and
  `usage_credits` ("Usage limits", F-178), `login`, `exit` and onboarding, each checked against
  the pinned release (F-162's new-10).
  About +600, −300, then +150 to +250 per kind.
- **B7. Facts and metrics**: `Store` appends a status fact to the table's own history in the
  transaction of each status write; the `Watch`'s named folds, `metrics/2` and `digest/2`;
  `look(what: :stuck)`. Detect and record only. About +600. Started in F-182: the `Watch`'s
  symptom record.
- **B8. Healing on an allow-list**, against `Heal.tla`: `Recoveries` becomes the `Watch`'s
  healer acting through `Team.operate/4`, its acts the default allow-list, the cap, and the
  `remedy` prompt. About +400, −250. Built in F-182 but the acts through `Team.operate/4`,
  which B5 makes; then each remedy of "One shape for every remedy" as its own small unit
  (`absent_main` and one clear built in F-183; `stuck_background` and `hooks_silent` in F-184).
- **B9. `wait_for`**, against `Delivery.tla`'s subscription: `Mailbox`'s `subscriptions`, fired
  by facts; a job's end, a service's line, port and exit, a delegate's idle and report, an
  answer. `service_wait`'s poll becomes a fact `Hosts` records. About +400, −150.
- **F-157**, as decided: the heavy `Bash` command rewritten into a wrapper under a lease; then
  `run` leaves the agents' list (about −200). Built in F-171 ("Intercepted, not added"); `run`,
  its late end and `MCP.caller/3` removed in F-176 (F-171's new-3).
- **B10. The intercepts**: `AskUserQuestion` opened as a prompt where no person attends; the
  `Agent` tool's named types answered with the `delegate` call to make; the `unenforced` fact
  and the `stuck` event raised from the hooks' rows and told to the parent. About +300.
- **B11. `delegate`'s options**, the model first: `Delegate.tla` gains `review` (the acceptance
  list fixed before the builder starts, a reviewer with a fresh context, read-only by its
  launch, that is not the builder, the report carrying the verdict), `variants` (each counted
  against the cap, refused `no_selector` without `select:`, one shared budget, at most one taken
  under `first_passing`, the others stopped by their parent's claim), `budget` and `steps` (a
  `tool` hold's deny past either, told to the parent once, never a kill) and `fresh` (F-150's
  start again, also `steer(:fresh)`, its first prompt the brief, the agent's progress note, the
  branch and its last results, recorded in the `Ledger`). Then each as its own unit. About +300
  of spec, then +300 to +400 each.
- **B12. Extensions**: the bundle in the config, its verb through `operate/4`, its skill in the
  launch, its context at a brief and by `additionalContext`, its events as facts, its guards and
  their counts, scoped per role and project. About +600.

The operator's decisions on the research survey (F-162) place three more pieces in these units:
the check of every tool call by the app's policies, each decision a row, goes in with B10 (the
held `PreToolUse` is built; what is new is the policy data per role, the correction before the
deny, and the deny rules beside each must-never policy, about +300 more); the legal acts per
state, written beside each spec and tested against it, go in with B5 (about +300); and the
reviewer, read-only by its launch, is B11's `review`. The fourth is its own unit:

- **B13. Replay in the gates** (decided): a real run's `Ledger` (acts, facts and each table's
  history) recorded whole, scrubbed of paths and names as `Screen`'s fixtures are, and kept per
  release; a gate replays each recorded run through the folds, the legal-acts table and the
  settle rules of new code, and fails on any act the run took that the code would now refuse or
  settle otherwise. It goes after B7, which makes the histories. About +500, plus fixtures.

About 9,000 lines added and 3,500 removed in all, over about twenty units counting B1's parts,
B6's kinds and B11's options. What it buys: an agent's list from 25 tools to 7 verbs; a library
seen through 26 functions in seven boxes and the `Ledger`'s 5, instead of 577 in 29 apps; an
embedding app that hands one config to one supervisor; one process per agent, so one agent's
trouble stays its own and OTP heals the framework's own crashes within a budget; one inbox for
everything that waits on a person; and metrics, bounded healing, `wait_for`, review, variants,
budgets and extensions built once, each behind one interface. What stays as it is: every
mechanism inside the boxes, every spec but the additions of B1, the umbrella and its gates. The
cost is mostly B2, B3 and B5, which move no behavior and touch most apps' docs and many tests'
calls, and B4, which reshapes the largest part; the rest is new work that would cost more
without them.
15. **Packaging and toolchain**: one `coding_agent_framework` package; `Programs` looked up and
    checked at start, with a Homebrew setup documented; the Elixir and OTP floor tested; a
    library supervisor from a config struct, out of `caf_example`; accounts: how to log one in
    (`bin/caf-login`, built in F-146), and Keychain reads for held processes (`security` on the
    launch's `PATH`, and `USER`, the OS user's name the app gives: the Keychain item is named by
    `USER` alone, with no fallback to `LOGNAME` or the OS user name, F-146's new-3 as F-173 corrected it). Each
    pinned release's check confirms both from a held session's login.
16. **What the app reads and drives**: structured reports with a schema and several per
    delegate; app metadata and names on agents (the metadata built in F-154: `meta:` at a
    start, `Sessions.put_meta/4` after, `Sessions.Agents.meta/1` to read); status with the
    last activity, cost and tokens,
    and a needs-input state; one activity feed per agent; an urgent message (interrupt, then
    message, as one checked step); one-off headless turns; the agent's identity for the app's own
    MCP servers; worktree base, reuse and removal; the source checkout's path for setup; a stable
    read API by id and name; a PubSub adapter for cues; a readable rendering of a delegate's log.
17. **`Stacks`**, the LiveView components (unstyled, with class hooks), and Ghostty (with other
    terminals by a callback).

The remote agents of the first plan (a session held on another host, its hooks forwarded back
over ssh, its session files and status line read there) are not built: agents run only on the
workstation. What is built stays keyed by host.
