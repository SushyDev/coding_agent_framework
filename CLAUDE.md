# Instructions for agents working on coding_agent_framework

Read `docs/design.md` first. It names the parts, the rules learned from running agents this way,
and the order of the units. Do not re-decide what it decides: when something in it is unclear,
contradicts itself, or meets a problem it did not foresee, stop and report it with a concrete
recommendation.

## Constraints

- Elixir and OTP, and SQLite for the framework's own tables. LiveView for the components.
- Tools come from devenv (`devenv.nix`): Erlang, Elixir, tmux, dtach, Claude Code, git, gh, and
  the TLA+ tools with a JDK. Run commands with `devenv shell -- <command>`.
- Each part is one process or one pure module with one job. A library starts no processes; the
  embedding app's supervision tree does.
- The repository is a Mix umbrella with one OTP app per part under `apps/` (`caf_shell`,
  `caf_tmux`, … `caf_tracker`), and the shared test aids in `caf_test`. A new part is a new app
  that declares only the apps (`in_umbrella: true`) and Hex packages it uses; what only its tests
  use is `only: :test`. The model, `bin/check-model`, devenv and `docs/` stay at the root, and
  the gates run there across every app.
- No global state: no named singletons and no `Application.get_env` for behavior inside the
  library. Everything is per instance, so two instances run in one app and in one test VM.
- Every outcome is explicit and pattern-matchable: `{:ok, …}`, `{:refused, reason}`,
  `{:unknown, reason}`. No hidden fallback, retry or wait, and no `:infinity` timeout.
- The model comes first. A protocol (anything over time: tmux, dtach, processes, moves,
  delegates, stacks) is written and checked in `model/tla/` before the code it describes. Each
  spec's header names the modules it models.
- This repository is public. It never names any other company's or project's systems, records
  or people. A lesson is stated in this repository's own words.

## How to work

- **One branch is one reviewable unit**: one concern, its tests and its docs, ideally under 500
  changed lines apart from fixtures. `main` changes only by a squash merge of a pull request.
- **Branches** are named `framework/f-<number>-<topic>`; each has a build note,
  `docs/build-notes/F-<number>.md`: what was built, what was measured, what you ran into, and
  `## Findings` as `### new-1. …` entries (what happened, why, what you did, what the design
  should change). A builder never builds a mechanism a finding suggests: it reports it.
- **Tests**: contract tests run on a real tmux server and real dtach sockets per test VM, under
  the VM's own temporary directory. Tests wait on announced events, never on fixed sleeps. No
  test starts the real Claude Code; a stand-in plays it.
- **Gates** before a unit is done: `mix format --check-formatted`, `mix compile
  --warnings-as-errors` (and the same with `MIX_ENV=test`), `mix test --warnings-as-errors`,
  `MIX_ENV=test mix caf.deps` (each app declares, directly,
  every umbrella app it uses, and uses every one it declares), and `bin/check-model` for the
  fast configurations.
- **After merging or rebasing `main`**, run `mix compile --force` and `MIX_ENV=test mix compile
  --force` before the gates. `_build` can keep a struct's old type, and the warning it gives is
  fatal under `--warnings-as-errors`.
- **Never** kill a process by pattern, use `git stash`, push, or touch a tmux server, dtach socket
  or Claude config directory that is not your own test's.

## Writing

Plain, short sentences in American English. Name things by what they are. Code comments say why,
not what. Every module and public function has a `@moduledoc` or `@doc` with an example where it
helps.
