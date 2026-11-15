# coding_agent_framework

Run and supervise Claude Code agents across Claude accounts and machines.

- **Parent sessions** are a project's main chats. Each moves to another account with one press,
  keeping its name and its Remote Control.
- **Delegates** are full Claude Code sessions a parent starts on the account with the most
  allowance left. Each runs in its own git worktree and tmux session, held by dtach so it outlives
  its terminal, and reports back to its parent.
- **Stacked pull requests** (`gh stack`) carry the work of a parent and its delegates.
- **State for LiveView frontends** follows what really runs, without lag or drift.
- **A TLA+ model**, checked with TLC, describes how tmux, dtach, Claude Code, worktrees and stacks
  fit together. It is written before the code it models.

## How it fits together

```mermaid
flowchart LR
  person([You])

  subgraph host["One host (local or over ssh)"]
    direction TB
    subgraph held["Held by dtach, apart from tmux"]
      parent["Parent session<br/>interactive Claude Code<br/>with Remote Control"]
      delegate["Delegates<br/>headless Claude Code<br/>stream-json in and out"]
    end
    tmux["tmux server of the framework's own<br/>one viewer per session"]
    worktrees[("git worktrees")]
    configs[("one Claude config dir<br/>per account")]
  end

  subgraph framework["The framework (Elixir and OTP)"]
    direction TB
    readers["Readers<br/>Registry · Transcripts · Usage<br/>Stream · Intake · TmuxSampler"]
    writers["Writers<br/>Control · Sessions · Stream"]
    tracker["Tracker<br/>one fold of every reader"]
    recoveries["Recoveries<br/>detect, act once, verify"]
    db[("SQLite tables<br/>the truth")]
  end

  ui["LiveView components"]

  person -->|Remote Control or a viewer| parent
  parent -->|starts and briefs| delegate
  delegate -->|reports| parent
  tmux -.->|views| held
  held --- worktrees
  held --- configs
  held -->|hooks, session files,<br/>transcripts, event logs| readers
  writers -->|one checked write per host| held
  readers --> db
  writers --> db
  db --> tracker
  tracker --> recoveries
  recoveries --> writers
  tracker --> ui
  ui -->|press to move an account,<br/>answer, interrupt| writers
```

- **Held, not hosted.** Every agent runs under `dtach -n`, so it outlives tmux, its terminal and
  the framework. tmux only shows it.
- **Readers, then one writer.** Each reader turns one source (a hook, a session file, a
  transcript, an event log, a tmux sample) into rows. Each host has one writer, and each write is
  checked against the target pane before it is sent.
- **Tables are the truth.** Views read the `Tracker`'s fold of those rows, so they never lag or
  lie. `Recoveries` acts once per broken state and checks that it helped.

## Status

The host layer, the readers, the writer, `Sessions`, the `Tracker` and `Recoveries` are built,
each from a checked model in `model/tla/`. Next are the moves between accounts, the delegate
protocol, the agent tools and the LiveView components. The plan and the order of the units are
in [docs/design.md](docs/design.md); each unit's notes are in `docs/build-notes/`.

## The apps

The code is a Mix umbrella, one OTP app per part under `apps/`. An arrow means "uses"; each app
declares every app it uses, directly, and `gate-deps` checks that.

```mermaid
flowchart BT
  subgraph host_layer["Host"]
    shell[caf_shell]
    tmux[caf_tmux]
    holder[caf_holder]
  end
  subgraph io["Readers and writers"]
    registry[caf_registry]
    transcripts[caf_transcripts]
    intake[caf_intake]
    accounts[caf_accounts]
    usage[caf_usage]
    cli[caf_cli]
    control[caf_control]
    stream[caf_stream]
    sampler[caf_sampler]
  end
  sessions[caf_sessions]
  recoveries[caf_recoveries]
  tracker[caf_tracker]

  tmux --> shell
  holder --> shell
  registry --> shell
  transcripts --> shell
  accounts --> shell
  accounts --> intake
  usage --> accounts
  cli --> accounts
  control --> tmux
  stream --> shell
  stream --> holder
  sampler --> tmux
  sampler --> holder
  sessions --> shell
  sessions --> holder
  sessions --> registry
  sessions --> cli
  sessions --> control
  recoveries --> tmux
  recoveries --> holder
  recoveries --> sampler
  recoveries --> sessions
  tracker --> registry
  tracker --> transcripts
  tracker --> intake
  tracker --> usage
  tracker --> stream
  tracker --> sampler
  tracker --> sessions
  tracker --> recoveries
```

`caf_test` holds the shared test aids and is used only in tests.

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
