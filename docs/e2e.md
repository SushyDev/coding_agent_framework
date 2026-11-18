# The end-to-end run

The design's readiness step: the example app runs every part in one supervision tree against
the real Claude Code, once, with a person watching. A person and a main session (the agent that
supervises the run) follow these steps together. The person types into the console and answers
what only a person may answer; the main session reads each reading against "Passed when" and
writes down what it saw. No test does this: every test uses a stand-in.

Each step says what to **type** at the console, what to **watch**, and what counts as
**passed**. A step that does not pass is a finding: write down the readings, the screens and
the time, and go on only if the next step does not depend on it.

The console is `CodingAgentFramework.Example.Console`; `h CodingAgentFramework.Example.Console`
in the shell lists it. Every function takes `caf`, the running app, and prints a short reading.
`attach(caf, name)` prints the command that opens an agent's viewer in another terminal: a main
session's or an interactive delegate's own screen, or a headless delegate's event log. Leave a
viewer with tmux's prefix and `d`; the agent runs on. A person may type into a main session's
or an interactive delegate's screen; never into a headless delegate's.

## 0. Before the run

The paths below use `/Users/me`; use your own home directory, spelled the same way everywhere.
The framework home must be short: macOS cuts a socket path at 104 bytes.

1. **An origin for the project.** The checkout is cloned from the project's repository, never
   from your own clone. A bare repository on disk will do:

   ```sh
   git init -q -b main /Users/me/caf-e2e-origin/seed
   cd /Users/me/caf-e2e-origin/seed
   printf '# demo\n\nA scratch project for the framework.\n' > README.md
   git add README.md && git commit -qm "Seed the demo project"
   git clone -q --bare . /Users/me/caf-e2e-origin/demo.git
   ```

2. **The config file**, `/Users/me/caf-e2e.json` (every key is in
   `CodingAgentFramework.Example.ConfigFile`'s doc):

   ```json
   {
     "home": "/Users/me/caf-e2e",
     "instance": "e2e",
     "accounts": ["one", "two"],
     "ports": {"intake": 4790, "mcp": 4791},
     "projects": {
       "demo": {
         "origin": "/Users/me/caf-e2e-origin/demo.git",
         "trunk": "main",
         "mains": ["demo-main"],
         "branches": "^unit/",
         "cap": 3
       }
     }
   }
   ```

3. **Log both accounts in**, each with its own config directory under the home:

   ```sh
   bin/caf-login /Users/me/caf-e2e one
   bin/caf-login /Users/me/caf-e2e two
   bin/caf-login --check /Users/me/caf-e2e one
   bin/caf-login --check /Users/me/caf-e2e two
   ```

   Passed when each check names the account you logged in with.

No reading of either account's allowance is written by hand. A start picks the account with
the most allowance left, and an account with no reading counts as 0 % used, assumed, as a reset
week does, after any account at the same share with a current reading. So the first start goes
to `one`, the first name, and its status line gives the first real reading.

## 1. The app starts, and the project is cloned

- **Type** in a terminal: `bin/caf-example /Users/me/caf-e2e.json`. The first run compiles.
  Then at the console: `checkout(caf)`, again until it is ready.
- **Watch** the banner: the home, both accounts' directories, the two ports.
- **Passed when** `checkout(caf)` reads `demo: ready, on main, clean true, ahead 0, behind 0`
  with the path `/Users/me/caf-e2e/checkouts/demo`, `git -C /Users/me/caf-e2e/checkouts/demo
  log --oneline` shows the seed commit, and `agents(caf)` shows `demo-main: main of demo, on no
  account, gone (row declared)`. `ls -l /Users/me/caf-e2e/intake.secret` shows the hooks'
  secret, readable and writable by you alone (`-rw-------`): the first start made it, and every
  later start reads it.

## 2. A main session starts, and the person answers its trust dialog

- **Type**:

  ```elixir
  start_main(caf, "demo", "demo-main", "You are the main session of the demo project, in the framework's end-to-end run. Your framework tools are on the caf MCP server. Reply in one line, then wait for messages.")
  ```

  It reads `unknown: {:dialog, :trust}`: the checkout is a folder Claude Code has not seen.
  Then `dialogs(caf)`, and answer with the label it prints, exactly:
  `answer_dialog(caf, "demo-main", "trust", "<the label that trusts the folder>")`.
- **Watch** `attach(caf, "demo-main")` in a second terminal: the trust dialog, then the brief's
  turn. Do not press anything on the dialog there: the console answers it. Claude Code may ask
  to allow a `caf` tool or `Bash` later. The console answers such a request: `requests(caf,
  "demo-main")` lists each held request with its tool, and `answer_request(caf, "demo-main",
  "<id>", "allow")` answers one. The dialog stays on this screen meanwhile, and a person may
  answer it there first; the console's answer then changes nothing. Copy the id `requests`
  prints: an answer refused for a wrong id keeps that state claimed, and the next answer of it
  is refused `already_claimed` until the state moves (F-147's finding new-1); answer it on the
  screen then.
- **Passed when** the dialog leaves the screen after the console's answer (and not before),
  the brief runs as the first turn, `agents(caf)` shows `demo-main` on account `one`, `idle`,
  `dialogs(caf)` shows none, and `look(caf, "demo-main")` shows the brief and its one-line reply.
  `leases(caf)` shows the main session's lease, class `main`, held by it. A request the console
  answered (if one came) leaves the screen once `answer_request` reads `ok`, and `requests(caf,
  "demo-main")` then lists it no more.

## 3. A headless delegate's report goes into the idle main session by the waiter

- **Type** while `demo-main` is idle:

  ```elixir
  start_delegate(caf, "demo-main", "demo", "unit/hello", "Create hello.txt with the line hello, commit it on your branch, and report the commit's hash in one line.")
  ```

  The delegate is `demo-unit-hello`. Its tools wait on a permission: when `agents(caf)` shows
  it `waits on Write (req-…)` or `Bash`, answer each: `answer_request(caf, "demo-unit-hello",
  "<req-…>", "allow")`.
- **Watch** `attach(caf, "demo-unit-hello")` (its event log) and `demo-main`'s screen.
- **Passed when** the report wakes `demo-main` with no typing: its transcript (`look(caf,
  "demo-main")`) has a user line that begins `Stop hook blocking error from command` and holds
  the report and a last line `[delivery <uuid>]`, and the main session answers it. The commit
  is on `unit/hello` in `/Users/me/caf-e2e/worktrees/demo/demo-unit-hello`. `agents(caf)` shows
  the delegate `idle`; the session it ran on is the account with the most allowance left:
  `two`, which has no reading yet and counts as 0 %, unless `one`'s first reading is 0 % too,
  which wins as current.

## 4. An interactive delegate

- **Type**:

  ```elixir
  start_delegate(caf, "demo-main", "demo", "unit/notes", "Write NOTES.md with three lines about this repository, commit it on your branch, and report the commit's hash in one line.", interactive: true)
  ```

  Its new worktree meets the trust dialog: `dialogs(caf)`, then `answer_dialog(caf,
  "demo-unit-notes", "trust", "<label>")`.
- **Watch** `attach(caf, "demo-unit-notes")`: its own screen, where its permission requests
  show and a person may answer them, or type. After it reports, type a short turn of your own
  there ("Say hi.").
- **Passed when** the brief went in as its first turn with no typing, its report reaches
  `demo-main` as in step 3, and the report is the reply to the brief, not to the turn you typed
  after it.

## 5. An ask, answered

- **Type**:

  ```elixir
  message(caf, "demo-main", "Use your ask tool to ask me which name to give a new file, a.txt or b.txt. Then wait for my answer and create nothing.")
  ```

  then `asks(caf)` until it lists the ask, and `answer_ask(caf, <id>, ["b.txt"])`. Then the
  same `answer_ask` once more.
- **Watch** `demo-main`'s screen.
- **Passed when** `asks(caf)` shows one ask from `demo-main` with both options; the answer is
  delivered (`status(caf, <its message id>)`), `demo-main` wakes to it and names `b.txt`; the
  second answer is refused `:answered`; `asks(caf)` then shows none.

## 6. A job under a lease

- **Type**:

  ```elixir
  message(caf, "demo-main", "Use your run tool: host ws, argv [\"/bin/sh\", \"-c\", \"sleep 30; echo job done\"], timeout 120000. Then report its exit code and its log in one line.")
  ```

  and `leases(caf)` while the job runs, `leases(caf, true)` after it.
- **Watch** `demo-main`'s screen. If Claude Code asks to allow the `run` tool, answer from the
  console: `requests(caf, "demo-main")`, then `answer_request(caf, "demo-main", "<id>",
  "allow")`.
- **Passed when**, while it runs, `leases(caf)` shows a lease of class `heavy` with a slot,
  held by `job mcp-e2e-<n>`; after it, the same lease reads `released by monitor`, and
  `demo-main` reports exit 0 and `job done`. The job ran in a copy under
  `/Users/me/caf-e2e/ws/`, not in the checkout.

## 7. A move to the second account and back

- **Type** while `demo-main` is idle and no delegate's turn runs: `move(caf, "demo-main",
  "two")`, then `agents(caf)` again and again. The resume on `two` is a new account for the
  checkout, so it meets the trust dialog: `dialogs(caf)`, `answer_dialog(…)`. Then, once it is
  idle on `two`, `move(caf, "demo-main", "one")`.
- **Watch** `agents(caf)`: `moving: draining`, then the copy and the resume. The viewer ends
  with the old process; `attach(caf, "demo-main")` again for the new one.
- **Passed when** `demo-main` runs on `two`, then on `one`, under the same name and session:
  `look(caf, "demo-main")` still shows the earlier turns, and a message sent after each move
  (`message(caf, "demo-main", "Which account are you on? One word.")`) is delivered once, and
  `status(caf, <its id>)` shows the reply's text under the reply.
  `faults(caf)` shows no `move` failed. The move back meets no dialog: `one` trusted the folder.

## 8. A framework restart in the middle of a delegate's run, settled after

- **Type**:

  ```elixir
  start_delegate(caf, "demo-main", "demo", "unit/slow", "Run the shell command sleep 240, then report the word slept.")
  ```

  and allow its `Bash` request. When `agents(caf)` shows `demo-unit-slow` `working`, type
  `System.halt()`: the framework's node ends at once. Wait half a minute; then start it again,
  `bin/caf-example /Users/me/caf-e2e.json`.
- **Watch** `attach(caf, "demo-unit-slow")`, opened before the halt: the viewer and the
  delegate run on while the framework is down, since tmux and dtach hold them, not the node.
- **Passed when** after the restart `agents(caf)` shows `demo-unit-slow` still `working`, the
  same process (its viewer never ended); when it ends, its report reaches `demo-main` once;
  `leases(caf)` shows its lease held until then and released after; `faults(caf)` shows only
  rows the restart cut, as `interrupted`, and nothing `failed`. `intake.secret` is the file the
  first start wrote, unchanged, so the held sessions' hooks are still taken.

## 9. A message too long to type goes in by its pointer

The restart cut `demo-main`'s waiter, so until a turn of it ends, a row for it is typed.

- **Type** right after the restart, before `demo-unit-slow` reports:

  ```elixir
  message(caf, "demo-main", "This message is longer than one typed line holds, so the framework writes it to a file and types a pointer to it. Read it, then reply with the word pointer.")
  ```

  then `status(caf, <id>)`.
- **Watch** `demo-main`'s screen: one typed line, `A message for you is in …; read it.`, then
  a turn that reads the file.
- **Passed when** `status(caf, <id>)` reads `delivered by typed` and `typed as a pointer to
  /Users/me/caf-e2e/due/demo-main/<id>.md`, and `demo-main` replies `pointer`, which
  `status(caf, <id>)` shows as the reply's text. A waiter comes back after that turn, since the
  session's hooks post with the home's secret, kept across the restart: `demo-unit-slow`'s
  report then comes by the waiter (a `Stop hook blocking error` line), not typed.

## 10. The main session's end

- **Type**: first `end_main(caf, "demo-main")`, which is refused while any delegate of it has
  not ended. Then end each delegate whose report was delivered: `stop_delegate(caf,
  "demo-unit-hello")`, and the same for `demo-unit-notes` and `demo-unit-slow`. Then
  `end_main(caf, "demo-main")` again, and `start_main(caf, "demo", "demo-main", "Again.")`.
- **Watch** `agents(caf)` and `demo-main`'s screen.
- **Passed when** the first `end_main` is refused `{:delegates, names}`; each stop answers ok;
  the second `end_main` reads `ok: :ended`; `agents(caf)` reads `no agents` and `agents(caf,
  true)` shows all four `ended`; `demo-main`'s process is gone and its viewer closes; the new
  start is refused `{:running, "demo-main"}`; `leases(caf)` holds nothing.

## After the run

Quit the shell (`System.halt()`). The framework's tmux server outlives it: end it with `tmux -S
/Users/me/caf-e2e/tmux.sock kill-server`. Remove the home only once `agents(caf, true)` showed
every agent ended. Each account's login stays in its config directory and the Keychain until
`claude auth logout` with that directory (`CLAUDE_CONFIG_DIR=/Users/me/caf-e2e/accounts/one/claude`).

Write the run up as a build note: each step's readings, passed or not, and each surprise as a
finding.
