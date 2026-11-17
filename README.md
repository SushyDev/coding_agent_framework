# coding_agent_framework

Run and supervise a tree of Claude Code agents on your workstation, balanced across Claude
accounts, with jobs and services on any machine.

- **Main sessions** are the chats you work in, one per project, on its trunk. Each moves to
  another account with one press, keeping its name and Remote Control, and main sessions of
  different projects talk to each other.
- **Delegates** are real Claude Code sessions a main session starts, on the account with the
  most allowance left, each in its own git worktree. To the main session a delegate acts like a
  subagent: a brief goes in, a report comes back. Inside it, Claude Code's own **subagents**
  delegate further, on the delegate's account.
- **Hosts** run jobs (a test run, a build) and services (a dev server, a database) for agents,
  on an exact copy of the agent's worktree. Agents themselves run only on the workstation.
- **The tree talks along its edges**: an agent talks to its parent and its children, and main
  sessions to each other. Any agent can see the whole tree.
- **Stacked pull requests** (`gh stack`) carry the delegates' work into trunk, and the main
  session pulls it.
- **State for LiveView frontends** follows what really runs, without lag or drift.
- **A TLA+ model**, checked with TLC, describes how tmux, dtach, Claude Code, worktrees, stacks,
  jobs and services fit together. It is written before the code it models.

The words are defined once, in [docs/design.md](docs/design.md#concepts).

## How it fits together

The chart shows the shape the code is being remodeled into (units R1 to R12 in
[docs/design.md](docs/design.md#order-of-the-first-units)): each mechanism once, in the part
that owns it.

```mermaid
flowchart LR
  person([You])

  subgraph ws["Workstation"]
    direction TB
    subgraph tree["Agents, held by dtach apart from tmux"]
      main["Main session<br/>interactive Claude Code<br/>with Remote Control, on trunk"]
      delegate["Delegates<br/>headless Claude Code<br/>stream-json in and out"]
      sub["Subagents<br/>Claude Code's own,<br/>on the delegate's account"]
    end
    otherMain["Main sessions<br/>of other projects"]
    tmux["tmux server of the framework's own<br/>one viewer per agent"]
    worktrees[("git worktrees")]
    configs[("one Claude config dir<br/>per account")]

    subgraph framework["The framework (Elixir and OTP)"]
      direction TB
      readers["Readers, one loop on Store<br/>Registry · Transcripts · Usage · Sampler<br/>over every account"]
      sessions["Sessions<br/>the agent row and the tree"]
      intake["Intake<br/>hook events; one hold:<br/>permission · tool · stop · waiter"]
      mailbox["Mailbox<br/>every delivery, one mark<br/>stream · waiter · typed · call"]
      inlet["Inlet<br/>the checked typed write"]
      stream["Stream<br/>a headless session's transport"]
      tools["The tree's tools, over MCP<br/>Grants · Delegates"]
      acts["Acts<br/>one ledger of claims,<br/>recoveries and faults"]
      cues["Cues<br/>each cue to the parts<br/>that declared its topic"]
      tracker["Tracker<br/>one fold of every reader"]
      recoveries["Recoveries<br/>detect, act once, verify"]
      db[("SQLite tables<br/>the truth, one writer each")]
    end
  end

  subgraph hosts["Hosts (the workstation, or over ssh)"]
    direction TB
    copies[("copies of worktrees<br/>kept in step by rsync")]
    work["Jobs and services<br/>held by dtach"]
  end

  ui["LiveView components"]

  person -->|Remote Control or a viewer| main
  main <-->|messages| otherMain
  main -->|brief| delegate
  delegate -->|report| main
  delegate -->|Claude Code's Agent tool| sub
  tree -->|run a job, start a service| work
  worktrees -->|rsync| copies
  copies --- work
  tmux -.->|views| tree
  tree --- worktrees
  tree --- configs
  tree -->|session files, transcripts,<br/>tmux samples| readers
  tree -->|hooks| intake
  tree -->|"run_delegate, message,<br/>agents()"| tools
  tools --> sessions
  tools --> mailbox
  tools --> acts
  mailbox -->|line| stream
  mailbox -->|due text| intake
  mailbox -->|no waiter| inlet
  stream --> delegate
  intake -->|wakes a turn,<br/>or joins one| main
  inlet -->|one checked write| main
  readers --> db
  sessions --> db
  mailbox --> db
  acts --> db
  db --> tracker
  db -.->|a cue per write| cues
  cues -.->|re-read by id| tracker
  cues -.-> sessions
  cues -.-> mailbox
  tracker --> recoveries
  recoveries --> acts
  recoveries --> sessions
  tracker --> ui
  tracker -->|"agents(): the tree"| tree
  ui -->|start a main session, move an account,<br/>answer, interrupt| tools
```

- **Held, not hosted.** Every agent runs under `dtach -n` on the workstation, so it outlives
  tmux, its terminal and the framework. tmux only shows it.
- **Readers, then one writer per table.** Each reader turns one source (a hook, a session file,
  a transcript, an event log, a tmux sample, a screen) into rows, with one shared loop. Each
  table has one writer, and a part reads another's state only through that part's functions.
  The one typed write is checked against the target pane before it is sent.
- **Each mechanism once.** Everything handed to an agent is one row in `Mailbox`, with one mark
  and settle whatever the transport; every hook that waits is one hold in `Intake`; every claim,
  recovery and fault is one row in `Acts`; every agent, main session or delegate, is one row in
  `Sessions`, and the tree is a function of those rows.
- **Nothing typed to deliver.** A report or a message reaches a main session through its
  waiting Stop hook, which wakes the idle session with the text, or has Claude Code queue it into
  a turn still running, so a draft in its box is never touched; the transcript confirms it. Only a
  session with no waiter gets a typed line, from the `Inlet`, into an ended turn with an empty
  box. A session ends by SIGTERM once its session file says it is idle.
- **Addressed by name.** Agents are rows with names; the framework finds every session across
  every account it holds, never by a pid or a socket, so a move to another account hides none.
- **Tables are the truth.** Views and the `agents()` tool read the `Tracker`'s fold of those
  rows, so they never lag or lie. `Recoveries` acts once per broken state and checks that it
  helped.

## Status

Built, each from a checked model in `model/tla/`:
- the base layer, the readers, the writer, `Sessions`, the `Tracker` and `Recoveries`;
- `Delegates`: start, report, resume once after a kill, report a second kill;
- the tree's tools: `Grants`, `Mailbox` and the MCP tools, and the operator (a person or the
  app acting as every main session's parent);
- `Copies`, `Jobs` and `Services` on any host;
- launch options per agent (settings, environment, directories, appended prompt, tools);
- `PreToolUse` held while the app decides, and `PostToolUse` handed on;
- `Screen`, reading a main session's screen from a real release's fixtures;
- the remodel's first units: `Store`, the SQLite table code every writer shares (R1), and
  `Reader`, the loop every reader runs, with one `Registry` and one `Transcripts` per host over
  every account (R2), and `Holder.Process`, one record of a held program, with a session ended
  by SIGTERM (R3); `Claim` and `Hold` in the model (R4); one hold in `Intake`, with the waiting
  Stop hook (R5); `Delivery` in the model, and the move rewritten with a message in flight
  (R6); and `Mailbox` delivering everything as rows: a delegate's brief, its word to go on and
  its report, by its stream and to a waiting `run_delegate` (R7, part 1), and to a main session
  by its waiting Stop hook, settled by its transcript (R7, part 2);
- `Acts`, one ledger of claims, recoveries and faults, in place of `Grants.Claims` and
  `Recoveries`' table (R10);
- the agent row and the tree in `Sessions` (R9, part 1): one row per agent, main session or
  delegate, with its parent and project; the tree one function of those rows, which `Grants`
  and the `Tracker` both read; and no part reading another's table but through its functions;
- each session's turn state as one function per kind in `Sessions`, starts, resumes, a
  service's fixes and a part's crash as rows of `Acts`, one rule for a term in a column, and
  every writer's `Tracker` source made from its table's metadata (R9, part 2);
- `Cues`, the library's own routing (R11): each part declares the topics it reads, and the
  embedding app hands the declarations to `Cues`, so the order in which the system settles is
  the library's; `Jobs`, `Services` and `Stream` read on their own interval, and no ticker
  sends a made-up topic;
- the `Inlet`, the checked typed write into a main session with no waiter, as `Mailbox`'s
  `typed` transport: the turn and the screen read again in the write's own step, one line with
  the row's uuid, Enter as its own command, and the release each interactive session runs
  recorded at its start (R8).

Next, the last of the remodel (F-115, taken in F-116): `Mover` (R12). Then
interactive delegates and main sessions, the mechanisms an app's policies stand on (an idle
delegate's watchdog, admission by load, `Stop` held for the app, clone copies, an idempotent
start), packaging, and stacks with the LiveView components. The plan and the order of the units are in
[docs/design.md](docs/design.md); each unit's notes are in `docs/build-notes/`.


## The apps

The code is a Mix umbrella, one OTP app per part under `apps/`. An arrow means "uses"; each app
declares every app it uses, directly, and `gate-deps` checks that. The chart shows the apps as
built; the remodel changes it as R1 to R12 land (`caf_store` added in R1 and holding `Reader`
from R2, `caf_acts` added in R10 in place of `Grants.Claims` and `Recoveries`' table, `caf_cues`
added in R11, `caf_inlet` in place of `caf_control` in R8).

```mermaid
flowchart BT
  subgraph host_layer["Host"]
    shell[caf_shell]
    tmux[caf_tmux]
    holder[caf_holder]
    store[caf_store]
    cues[caf_cues]
  end
  subgraph io["Readers and writers"]
    registry[caf_registry]
    transcripts[caf_transcripts]
    intake[caf_intake]
    accounts[caf_accounts]
    usage[caf_usage]
    cli[caf_cli]
    inlet[caf_inlet]
    stream[caf_stream]
    sampler[caf_sampler]
    screen[caf_screen]
    acts[caf_acts]
  end
  sessions[caf_sessions]
  recoveries[caf_recoveries]
  tracker[caf_tracker]
  delegates[caf_delegates]
  subgraph team["The tree's tools"]
    grants[caf_grants]
    mailbox[caf_mailbox]
    mcp[caf_mcp]
  end
  subgraph hosts["Hosts"]
    copies[caf_copies]
    jobs[caf_jobs]
    services[caf_services]
  end

  tmux --> shell
  holder --> shell
  registry --> shell
  registry --> holder
  transcripts --> shell
  accounts --> shell
  accounts --> intake
  usage --> accounts
  cli --> accounts
  inlet --> tmux
  inlet --> screen
  stream --> shell
  stream --> holder
  sampler --> tmux
  sampler --> holder
  sessions --> shell
  sessions --> holder
  sessions --> registry
  sessions --> accounts
  sessions --> cli
  sessions --> tmux
  sessions --> stream
  sessions --> transcripts
  sessions --> intake
  recoveries --> tmux
  recoveries --> holder
  recoveries --> sampler
  recoveries --> sessions
  recoveries --> acts
  tracker --> store
  tracker --> sessions
  sessions & delegates & services --> acts
  delegates --> accounts
  delegates --> cli
  delegates --> usage
  delegates --> stream
  delegates --> sessions
  delegates --> transcripts
  delegates --> mailbox
  mailbox --> sessions
  mailbox --> grants
  mailbox --> stream
  mailbox --> intake
  mailbox --> transcripts
  mailbox --> accounts
  mailbox --> inlet
  mailbox --> registry
  mcp --> grants
  mcp --> acts
  copies --> shell
  copies --> holder
  jobs --> shell
  jobs --> copies
  jobs --> holder
  services --> shell
  sessions & delegates & stream & mailbox & intake & jobs --> store
  services & copies & mcp & acts --> store
  registry & transcripts & usage & sampler --> store
  services --> holder
  services --> grants
  services --> copies
```

`caf_test` holds the shared test aids and is used only in tests. `caf_example` is an app built
on the others, as an embedding app would be, and uses every one of them. `caf_cues`,
`caf_grants`, `caf_intake` and `caf_screen` use no other app: the embedding app hands `caf_cues`
each part's declaration of what it reads and `caf_grants` the tree as a function, and
`caf_screen` reads a screen's text it is given. `caf_mcp` reaches `Delegates`,
`Mailbox` and the `Tracker` through modules the embedding app names.

## Development

Every tool comes from [devenv](https://devenv.sh) 2.x, pinned by `devenv.lock`: Erlang, Elixir,
tmux, dtach, Claude Code, git, gh, TLC with its JDK, and the POSIX tools the tests call.

- Enter the environment with `devenv shell`, or run one command in it with
  `devenv shell -- <command>`.
- Run all the gates with `devenv test`. It checks the tools' versions, runs the git hooks on
  every file, and then runs the gates.
- Run one gate alone with `gate-format`, `gate-compile`, `gate-deps`, `gate-test` or
  `gate-model`. `gate-deps` checks that each app declares, directly, every app it uses.
  `gate-test` leaves out the TLC test; `gate-model` runs it. `mix test` alone runs both.
- Check the tools against the lock with `check-versions`.

Run every command from the umbrella root; `mix test` there runs each app's tests.

`Screen`'s fixtures are a real Claude Code session's screens, captured once per pinned release
by a person with `devenv shell -- bin/capture-screen <home>/accounts/<account>/claude`. It runs
Claude Code in a 120x40 pane on a tmux server of its own, types into the box itself, and asks
you to answer each dialog in a second terminal it attaches to the pane. It scrubs paths and
names (`--name <text>` adds one), prints each line it changed, and writes the screens with a
manifest to `apps/caf_screen/test/fixtures/<version>/`; read them before committing them.
`--dry-run` runs the same steps against a stand-in. No test runs the real Claude Code.

The shell exports each program's store path as `CAF_<NAME>`: `CAF_TMUX`, `CAF_DTACH`,
`CAF_CLAUDE`, `CAF_GIT`, `CAF_GH`, `CAF_SH`, `CAF_BASH`, `CAF_RM`, `CAF_MV`, `CAF_ENV`,
`CAF_KILL`, `CAF_PS`, `CAF_CAT`, `CAF_ECHO`, `CAF_TLC` and `CAF_JAVA`. Tests and
`bin/check-model` run programs only from these paths, never through `PATH`. `CAF_OTP_VERSION`
and `CAF_ELIXIR_VERSION` name the lock's versions, and the tests stop at once when the VM runs
others.

Mix, Hex, rebar3 and the shell history keep their state in `.devenv/state`, not in your home
directory. Hex and rebar3 come from the lock, so nothing is downloaded into it.

Entering the shell writes this repository's own `pre-commit` hook into the common git directory
(`git rev-parse --git-common-dir`), so every worktree shares it. It checks format and American
spelling (`typos`) on the staged files, by absolute store paths, so a plain `git commit` outside
the shell runs it. If `core.hooksPath` points at a global directory, that directory must hand off
to this file when it exists. A `pre-commit` this repository did not write is never replaced.

## License

Apache-2.0; see [LICENSE](LICENSE).
