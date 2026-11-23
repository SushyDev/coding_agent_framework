# The end-to-end run

The design's readiness step: the example app runs every part in one supervision tree against
the real Claude Code, once, with a person watching, first on macOS and then on Linux. A person
and a main session (the agent that supervises the run) follow these steps together. The person
types into the console and answers what only a person may answer; the main session reads each
reading against "Passed when" and writes down what it saw.

Steps 1, 2, 3, 5 and 14 run as a test against the real Claude Code: `CAF_REAL_SETUP=<home>
mix test.real`, where `<home>` is one `bin/caf-login --setup <home> one two` set up (F-223,
`apps/caf_real`). It needs no person. The other steps stay here until they are tests too.

Each step says what to **type** at the console, what to **watch**, what counts as **passed**,
and what to **record**: a reading only a real run can give, kept as a file under the records
folder (step 0) by the name the step gives it. A step that does not pass is a finding: write
down the readings, the screens and the time, and go on only if the next step does not depend on
it.

The console is `CodingAgentFramework.Example.Console`; `h CodingAgentFramework.Example.Console`
in the shell lists it. Every function takes `caf`, the running app, and prints a short reading.
`attach(caf, name)` prints the command that opens an agent's viewer in another terminal: a main
session's or an interactive delegate's own screen, or a headless delegate's event log. Leave a
viewer with tmux's prefix and `d`; the agent runs on. A person may type into a main session's
or an interactive delegate's screen; never into a headless delegate's.

**The inbox.** Everything that waits on a person is a prompt, read with the console's
`prompts(caf, filter)` and answered once with `answer(caf, id, choice)`, as the config's
operator (`operator`): the app's `prompts/2` and `answer/4` (F-179; the console's calls,
F-190). Each prompt below is answered so wherever the inbox lists it, a headless delegate's
permission request among them (F-190). `symptoms(caf, filter)`, `limited(caf)`, `acts(caf,
filter)`, `usage(caf)` and `groups(caf, agent)` read the `Watch`, its digest of the accounts
at a limit, the ledger, the usage readings and a delegate's process groups the same way.

Never interrupt the console's shell (Ctrl+C, or Ctrl+G and a new shell) to get past a slow
call: wait for it, or run a long one as a task (`Task.async(fn -> checkout(caf) end)`). A new
shell gets the app the first one started, as `caf`, and starts nothing again; the first run met
a shell that started the app a second time, failed on its ports and stopped the VM (F-153).

**If a usage limit comes** in any step (an agent `limited` in `agents(caf)`, or Claude Code's
limit text on a screen), press nothing on the screen. Record `usage-limit`: the screen
(`attach`), `prompts(caf)` (a `limit` or `usage_credits` prompt), `symptoms(caf,
kind: ["limited", "limit_menu", "limit_reset", "limit_far"])`, `limited(caf)` (each account's
limit, its agents and how long each has waited, F-193), `usage(caf)` and the time. While a main
session shows Claude Code's own wait ("Continuing automatically at … · Esc to cancel"), also
record what its session file says, whole: `ls -t
/Users/me/caf-e2e/accounts/<account>/claude/sessions/`, then `cat` the newest, its `status`
read at the time the screen shows the wait (F-191's new-4: the move's stop reads the screen
only when the file does not say `idle`). The healer (`Limits`) presses the menu's stop and goes
on at the reset by itself; a real limit is a reading no test has.

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
   mkdir -p /Users/me/caf-e2e-records
   ```

   `/Users/me/caf-e2e-records` is the records folder: each step's record is a text file there,
   named as the step says (`usage.txt` for the record `usage`).

2. **The config file**, `/Users/me/caf-e2e.json` (every key is in
   `CodingAgentFramework.Example.ConfigFile`'s doc):

   ```json
   {
     "home": "/Users/me/caf-e2e",
     "instance": "e2e",
     "accounts": ["one", "two", "three"],
     "ports": {"intake": 4790, "mcp": 4791},
     "projects": {
       "demo": {
         "origin": "/Users/me/caf-e2e-origin/demo.git",
         "trunk": "main",
         "mains": ["demo-main"],
         "branches": "^unit/",
         "cap": 6
       }
     },
     "git": {"name": "Demo Bot", "email": "you@example.com"},
     "scheduler": {
       "resources": {"seat": 8, "slot": 2},
       "heavy": [{"match": "^sleep 30", "class": "heavy"}]
     }
   }
   ```

   `git` is the author every agent commits as, distinct from you. For GitHub to show its
   commits Verified, `email` must be one of your GitHub account's verified emails (its noreply
   address works); the name may be anything. `scheduler.heavy` names the one heavy command
   step 6 runs under a lease. The run keeps up to six delegates of `demo-main` at once until
   step 14 ends them, so `cap` is 6 and `seat` 8 (a delegate holds a seat while its process
   lives). `three` is an account never logged in: step 11 checks that the login check refuses
   it, and no start goes to it.

3. **Set up the logins**, with one command (F-220): two accounts, the GitHub CLI and the
   home's commit signing key. `three` is not named, so it stays logged out:

   ```sh
   bin/caf-login --setup /Users/me/caf-e2e.json one two
   ```

   It reads the home from the config and runs each step in order, each ending with its own
   check: for `one`, then `two`, Claude Code's login and its first run; then the GitHub CLI's
   login; then the signing key. What you do on screen, and nothing else:

   - **Each account's login**: Claude Code's login opens your browser. Log in there with the
     account you mean for it.
   - **Each account's first run**: Claude Code's onboarding (a theme picker, then more
     screens), then the scratch folder's trust dialog. Pass each; Claude Code then runs
     `/exit`, its first prompt, and ends by itself. No session the framework starts reads those
     screens, so they are passed here, once.
   - **The GitHub CLI's login**: gh's own questions, then its browser login, which asks for
     the scope `admin:ssh_signing_key` (the signing key needs it). A login that lacks only that
     scope gets it with one browser step (`gh auth refresh`), not a new login.

   Everything else runs by itself: the checks, the key (made once in
   `/Users/me/caf-e2e/git/signing_key`, the home's own, never one of yours) and adding it to
   your GitHub account as a signing key. A step already done (an account logged in, an
   onboarding passed, gh logged in with the scope, the key made and on GitHub) is checked, said
   and skipped, so after a step fails, running the same command again goes on where it stopped.

   Every tool's state lives in the home (F-155): gh's login in `/Users/me/caf-e2e/gh`, git's
   config and the key in `/Users/me/caf-e2e/git/`, ssh's config and known hosts in
   `/Users/me/caf-e2e/ssh/`. Agents push with your own GitHub login and commit as the config's
   `git` author. gh logs in with `--insecure-storage`, so its token is a file in the home
   (`/Users/me/caf-e2e/gh/hosts.yml`, mode 600), not an entry in macOS's Keychain, gh's default.

   Passed when the setup ends with `setup of /Users/me/caf-e2e done: account one, account two,
   gh, git, each checked`, and status 0. On the way, each account's check names the account
   you logged in with and reads `Claude Code's first-run onboarding: passed`; gh's check names
   your GitHub account and reads `the token is in the home: a file` and `the token has the
   scope admin:ssh_signing_key` (gh's own line may label the token `(keyring)`: caf-login reads
   the file, and its line is the one that counts); and the key's check reads `GitHub lists
   /Users/me/caf-e2e/git/signing_key.pub as a signing key`. A step that fails stops the setup
   with status 1 and says what to do. Each step also runs alone: `bin/caf-login /Users/me/caf-e2e
   one`, `bin/caf-login --gh /Users/me/caf-e2e` and `bin/caf-login --git /Users/me/caf-e2e`;
   `bin/caf-login --check /Users/me/caf-e2e one` and `bin/caf-login --check --gh
   /Users/me/caf-e2e` read a check again. The app refuses to start with a `git` author whose key is missing
   (`{:no_signing_key, path}`).

No reading of any account's allowance is written by hand. New work goes to the usable account
(prepared and logged in, by `claude auth status`) with the most room in the tighter of its two
windows, the first named at the same room; an account with no reading has the whole room
(F-181). So the first start goes to `one`, the first name, its status line gives the first
real reading, and `three` is never picked.

## 1. The app starts, and the project is cloned

- **Type** in a terminal: `bin/caf-example /Users/me/caf-e2e.json`. The first run compiles;
  when `deps/` does not match `mix.lock`, it runs `mix deps.get` first and says so (F-220).
  Then at the console: `checkout(caf)`, again until it is ready, and the inbox, `prompts(caf)`.
  The console sets the aliases of the two readers no console call makes, `Logins` and `Agents`
  (an agent row's record, steps 12 and 13; the login check, step 11), and `Run` (F-226).

- **Watch** the banner: the home, the three accounts' directories, the two ports.
- **Passed when** `checkout(caf)` reads `demo: ready, on main, clean true, ahead 0, behind 0`
  with the path `/Users/me/caf-e2e/checkouts/demo`, `git -C /Users/me/caf-e2e/checkouts/demo
  log --oneline` shows the seed commit, and `agents(caf)` shows `demo-main: main of demo, on no
  account, gone (row declared)`. `ls -l /Users/me/caf-e2e/intake.secret` shows the hooks'
  secret, readable and writable by you alone (`-rw-------`): the first start made it, and every
  later start reads it. `prompts(caf)` reads `{:ok, []}`: nothing waits yet. A start
  refused because of `three` is a finding: record the refusal, take `three` out of the config,
  and leave out step 11's login part.

## 2. A main session starts, and the person answers its trust dialog

- **Type**:

  ```elixir
  start_main(caf, "demo", "demo-main", "You are the main session of the demo project, in the framework's end-to-end run. Your framework tools are on the caf MCP server. Reply in one line, then wait for messages.")
  ```

  It reads `unknown: {:dialog, :trust}`: the checkout is a folder Claude Code has not seen.
  Then `prompts(caf, kind: "dialog")`: one prompt, id
  `dialog:demo-main:<start>:trust`, its options the dialog's labels. Answer with the label that
  trusts the folder, exactly: `answer(caf, "<that id>", "<the label>")`.
- **Watch** `attach(caf, "demo-main")` in a second terminal: the trust dialog, then the brief's
  turn. Do not press anything on the dialog there: the inbox answers it. Claude Code may ask to
  allow a `caf` tool or `Bash` later: each request is a prompt `permission:<n>` in
  `prompts(caf, agent: "demo-main")`, its text the tool and its input, and
  `answer(caf, "permission:<n>", "allow")` answers it (the console's
  `requests(caf, "demo-main")` lists the same request as `request <n>`). The dialog stays on
  this screen meanwhile, and a person may answer it there first; the inbox's answer is then
  refused `{:refused, :settled}` and changes nothing.
- **Passed when** the dialog leaves the screen after the inbox's answer (and not before), the
  brief runs as the first turn, `agents(caf)` shows `demo-main` on account `one`, `idle`, and
  `look(caf, "demo-main")` shows the brief and its one-line reply. `prompts(caf)` then
  lists no dialog, and `answer` of the same dialog's id again reads `{:refused, :settled}`.
  It lists `login:three` (the start's pick checked `three` and found it logged out); leave it
  until step 11. `leases(caf)` shows the main session's lease, class `main`, held by it. A
  request the inbox answered (if one came) leaves the screen once `answer` reads `{:ok, _}`,
  and the inbox then lists it no more.

## 3. A headless delegate's report goes into the idle main session by the waiter

- **Type** while `demo-main` is idle:

  ```elixir
  start_delegate(caf, "demo-main", "demo", "unit/hello", "Create hello.txt with the line hello, commit it on your branch, and report the commit's hash in one line.")
  ```

  The delegate is `demo-unit-hello`. Its tools wait on a permission: when `agents(caf)` shows
  it `waits on Write (req-…)` or `Bash`, `prompts(caf, agent: "demo-unit-hello")` lists it as
  `permission:stream:<session>:<req-…>`, its text the tool and its input, no deadline: Claude
  Code's own `can_use_tool` over the stream, held in its fold (F-190). Answer each with
  `answer(caf, "<that id>", "allow")`. The console's `answer_request(caf, "demo-unit-hello",
  "<req-…>", "allow")`, the parent's way, is refused once the inbox answered.
- **Watch** `attach(caf, "demo-unit-hello")` (its event log) and `demo-main`'s screen.
- **Passed when** the report wakes `demo-main` with no typing: its transcript (`look(caf,
  "demo-main")`) has a user line that begins `Stop hook blocking error from command`, whose text
  begins `From demo-unit-hello on <its account> (report):`, holds the report and ends with a line `[delivery
  <uuid>]`, and the main session answers it. The commit is on `unit/hello` in
  `/Users/me/caf-e2e/worktrees/demo/demo-unit-hello`. `agents(caf)` shows the delegate `idle`;
  the account it ran on is the usable one with the most room: `two`, which has no reading and
  so has the whole room, unless `one`'s reading leaves the whole room too (0 % used in both
  windows), when `one`, named first, wins. `demo-main` got one `prompt` notice per request,
  `From demo-unit-hello on <its account> (prompt): waiting on permission: …`, and each
  request's second answer read `{:refused, :settled}`.
- **Record** `headless-permission`: what `prompts(caf, agent: "demo-unit-hello")` read
  while the request waited, whole, and the notices `demo-main` got. A second prompt for the same
  request, `permission:<n>`, means Claude Code also sent a `PermissionRequest` hook from a
  headless session: a finding.

## 4. An interactive delegate

- **Type**:

  ```elixir
  start_delegate(caf, "demo-main", "demo", "unit/notes", "Write NOTES.md with three lines about this repository, commit it on your branch, and report the commit's hash in one line.", interactive: true)
  ```

  Its new worktree meets the trust dialog: `prompts(caf, subtree: "demo-main")` lists
  `dialog:demo-unit-notes:<start>:trust`, its `parent` `demo-main`; answer it with
  `answer` as in step 2. Its permission requests are prompts `permission:<n>` with agent
  `demo-unit-notes`; answer each the same way.
- **Watch** `attach(caf, "demo-unit-notes")`: its own screen, where its permission requests
  show and a person may answer them, or type. After it reports, type a short turn of your own
  there ("Say hi."). Watch `demo-main`'s screen too.
- **Passed when** the brief went in as its first turn with no typing, its report reaches
  `demo-main` as in step 3, and the report is the reply to the brief, not to the turn you typed
  after it. `demo-main` was told once of each prompt of its delegate, by a line that begins
  `From demo-unit-notes on <its account> (prompt): waiting on dialog: trust dialog` (or `waiting on
  permission: <tool> <input>`) and ends `(prompt <id>)`: one per prompt, none twice.

## 5. An ask, answered

- **Type**:

  ```elixir
  message(caf, "demo-main", "Use your ask tool to ask me which name to give a new file, a.txt or b.txt. Then wait for my answer and create nothing.")
  ```

  then `prompts(caf, kind: "ask")` until it lists the ask, `ask:<n>`, its options the
  ask's questions. Answer it:

  ```elixir
  answer(caf, "ask:<n>", [%{"labels" => ["b.txt"], "text" => ""}])
  ```

  Then the same `answer` once more, and the console's `answer_ask(caf, <n>, ["b.txt"])`.
- **Watch** `demo-main`'s screen.
- **Passed when** the inbox shows one ask from `demo-main` with both options, and `asks(caf)`
  the same ask; the answer reads `{:ok, {:queued, <m>}}` and is delivered (`status(caf, <m>)`),
  and `demo-main` wakes to it and names `b.txt`; the second `answer` is refused
  `{:refused, :settled}` and the console's `answer_ask` is refused too; `asks(caf)` then shows
  none.

## 6. A job under a lease

- **Type**:

  ```elixir
  message(caf, "demo-main", "Run this with your Bash tool, in the foreground: sleep 30; echo job done. Then report its exit code and its output in one line.")
  ```

  and `leases(caf)` while it runs, `leases(caf, true)` after it.
- **Watch** `demo-main`'s screen. If Claude Code asks to allow the command, answer it from the
  inbox (`prompts(caf, agent: "demo-main")`, then `answer`); its text shows the
  command as the hook rewrote it.
- **Passed when**, while it runs, `leases(caf)` shows a lease of class `heavy` with a slot,
  held by `run <pid> <start>`, the wrapper `<home>/bin/caf-run` the hook rewrote the command
  into (F-171); after it, the same lease reads `released by monitor`, and `demo-main` reports
  exit 0 and `job done`. There is no `run` tool (F-176): an agent's heavy command is its own
  `Bash` under a lease.

## 7. A move to the second account and back

- **Type** while `demo-main` is idle and no delegate's turn runs: `move(caf, "demo-main",
  "two")`, then `agents(caf)` again and again. The resume on `two` is a new account for the
  checkout, so it meets the trust dialog: answer it from the inbox as in step 2. Then, once it
  is idle on `two`, `move(caf, "demo-main", "one")`.
- **Watch** `agents(caf)`: `moving: draining`, then the copy and the resume. The viewer ends
  with the old process; `attach(caf, "demo-main")` again for the new one.
- **Passed when** `demo-main` runs on `two`, then on `one`, under the same name and session:
  `look(caf, "demo-main")` still shows the earlier turns, and a message sent after each move
  (`message(caf, "demo-main", "Which account are you on? One word.")`) is delivered once, and
  `status(caf, <its id>)` shows the reply's text under the reply. `faults(caf)` shows no `move`
  failed. The move back meets no dialog: `one` trusted the folder.

## 8. A framework restart in the middle of a delegate's run, settled after

- **Type**:

  ```elixir
  start_delegate(caf, "demo-main", "demo", "unit/slow", "Run the shell command sleep 240, then report the word slept.")
  ```

  and allow its `Bash` request from the inbox, as in step 3. When `agents(caf)` shows
  `demo-unit-slow` `working`, type `System.halt()`: the framework's node ends at once. Wait
  half a minute; then start it again, `bin/caf-example /Users/me/caf-e2e.json`; its aliases come back with it.
- **Watch** `attach(caf, "demo-unit-slow")`, opened before the halt: the viewer and the
  delegate run on while the framework is down, since tmux and dtach hold them, not the node.
- **Passed when** after the restart `agents(caf)` shows `demo-unit-slow` still `working`, the
  same process (its viewer never ended); when it ends, its report reaches `demo-main` once;
  `leases(caf)` shows its lease held until then and released after; `faults(caf)` shows only
  rows the restart cut, as `interrupted`, and nothing `failed`. `intake.secret` is the file the
  first start wrote, unchanged, so the held sessions' hooks are still taken. `prompts(caf)`
  lists what it listed before the halt (`login:three`), and `symptoms(caf)` shows no
  `absent_main`: the restart ended no session.

## 9. A message too long to type goes in by its pointer

The restart cut `demo-main`'s waiter, so until a turn of it ends, a row for it is typed.

- **Type** right after the restart, before `demo-unit-slow` reports:

  ```elixir
  message(caf, "demo-main", "This message is longer than one typed line holds, so the framework writes it to a file and types a pointer to it. Read it, then reply with the word pointer.")
  ```

  then `status(caf, <id>)`.
- **Watch** `demo-main`'s screen: one typed line, ``From operator (message): a message for you
  is in `/Users/me/caf-e2e/due/demo-main/<id>.md`; read it.``, then a turn that reads the
  file.
- **Passed when** `status(caf, <id>)` reads `delivered by typed` and `typed as a pointer to
  /Users/me/caf-e2e/due/demo-main/<id>.md`, and `demo-main` replies `pointer`, which
  `status(caf, <id>)` shows as the reply's text. A waiter comes back after that turn, since the
  session's hooks post with the home's secret, kept across the restart: `demo-unit-slow`'s
  report then comes by the waiter (a `Stop hook blocking error` line), not typed.

## 10. The one inbox: a request, a dialog and an ask at once

- **Type**, each once the one before is shown:

  ```elixir
  message(caf, "demo-main", "Use your ask tool to ask me one question: go on, yes or no. Then wait for my answer.")
  message(caf, "demo-main", "Run this with your Bash tool: touch /Users/me/caf-e2e-origin/inbox-check. Then wait.")
  start_delegate(caf, "demo-main", "demo", "unit/inbox", "Reply with the word inbox in one line.", interactive: true)
  prompts(caf)
  prompts(caf, subtree: "demo-main")
  prompts(caf, kind: "permission")
  ```

  Then answer the three, each once: the permission `allow`, the dialog by its trusting label,
  the ask with its label for yes, as its options name it (`[%{"labels" => ["<label>"],
  "text" => ""}]`); then each id again; then `prompts(caf)`.
- **Watch** `demo-main`'s screen and `attach(caf, "demo-unit-inbox")`.
- **Passed when** one read of `prompts(caf)` lists the three, oldest first: `ask:<n>`
  (agent `demo-main`), `permission:<n>` (agent `demo-main`, its text `Bash touch
  /Users/me/caf-e2e-origin/inbox-check`, options `allow` and `deny`, a deadline) and
  `dialog:demo-unit-inbox:<start>:trust` (agent `demo-unit-inbox`, parent `demo-main`), beside
  `login:three`; `subtree: "demo-main"` lists the three without `login:three`; `kind:
  "permission"` the one. `demo-main` is told once of its delegate's dialog (`From
  demo-unit-inbox on <its account> (prompt): …`); a main session's own prompts are told to no one. Each answer
  reads `{:ok, _}` and each second one `{:refused, :settled}`; the last read lists only
  `login:three`. The command ran, the ask's
  answer reached `demo-main`, and `demo-unit-inbox`'s report reaches `demo-main` once.
- **Record** `inbox`: the three-prompt read, whole.

## 11. Usage: the two windows, and the login check

- **Type** while `demo-main` is idle: `usage(caf)`, and `cat
  /Users/me/caf-e2e/usage/one.json` in another terminal. Then, on `demo-main`'s screen, type
  `/usage`, read it, and press Esc. Then `message(caf, "demo-main", "Reply with one word.")`,
  and once it replied, both readings again. Then the login check:

  ```elixir
  Logins.check(Run.parts(caf).logins, "three")
  prompts(caf, kind: "login")
  answer(caf, "login:three", "check")
  ```

  Then `move(caf, "demo-main", "three")` once: a move to an account it names reads that the
  account is logged in before anything begins (F-190, from F-189's new-3).
- **Watch** `demo-main`'s screen.
- **Passed when** the reading of `one` has both windows, `used` and `resets_at` (the week),
  `five_used` and `five_resets_at` (five hours), `source` `status_line`, and they agree with
  `usage/one.json`'s `rate_limits` and with what `/usage` shows, to the percent. After the turn,
  `seen_at` is later, and each `used` the same or higher, unless its window reset between.
  `two` has a reading from step 7's turns on it. `three` has none. `Logins.check` of `three`
  reads `{:refused, {:login, :logged_out}}`; the inbox shows `login:three`, no agent, its one
  option `check`; the `check` answer is refused the same, and `login:three` stays open. The
  move reads `refused: {:account, "three", {:login, :logged_out}}` and `agents(caf)` still
  shows `demo-main` idle on its account, with no `moving`. No agent of the run has run on
  `three` (`agents(caf, true)`).
- **Record** `usage`: both readings of every account, whole, the file's `rate_limits` before
  and after, and the percentages `/usage` showed, with the times.

## 12. A headless delegate with one background command

- **Type**:

  ```elixir
  start_delegate(caf, "demo-main", "demo", "unit/bg", "Use the Bash tool with run_in_background set to true to run exactly this command and nothing else: sleep 120; echo bg done. Do not wait for it. Then report the words started in background in one line.")
  ```

  Allow its `Bash` request from the inbox, as in step 3. Then, for `bg.session_id` and
  `bg.account`:

  ```elixir
  bg = Agents.get(Run.info(caf).agents, "demo-unit-bg")
  ```

- **Watch** `attach(caf, "demo-unit-bg")` and `demo-main`'s screen, for two minutes and a half.
- **Passed when** the request's command, as its event log shows it, begins `exec </dev/null; `
  (the framework's correction of a background command's stdin, F-180); the report reaches
  `demo-main` within seconds, while the command still runs, once; when the command ends, `demo-main` gets one `notice` that begins
  `From demo-unit-bg on <bg.account> (notice): Delegate demo-unit-bg, in a turn of its own after its report:`,
  and no second report. While Claude Code's own turn runs, `agents(caf)` reads the delegate
  working, not idle. The event log, `/Users/me/caf-e2e/streams/<bg.session_id>/events.jsonl`,
  holds `system`/`init` twice and `result` twice: one of each per turn.
- **Record** `background`: the event log's lines in order, by `type` and `subtype`, and the
  time of each of the two results:

  ```elixir
  log = "/Users/me/caf-e2e/streams/#{bg.session_id}/events.jsonl"
  for l <- File.stream!(log), e = JSON.decode!(l), do: {e["type"], e["subtype"]}
  ```

  and `usage(caf)`'s reading of `bg.account` after the report (a headless session's windows come
  from its stream: `source` `stream`, if no status line read is newer).

## 13. An absent main, resumed once

- **Type** while `demo-main` is idle and every delegate's report is delivered:

  ```elixir
  row = Agents.get(Run.info(caf).agents, "demo-main"); {row.pid, row.proc_start, row.session_id, row.account}
  ```

  The pid is Claude Code's own process, the one the agent row names. In another terminal check
  it before you end it: `ps -o pid,lstart,args -p <pid>` shows Claude Code started at
  `proc_start`, and `/Users/me/caf-e2e/accounts/<account>/claude/sessions/<pid>.json` names the
  row's session id. Then end that process, by that pid alone: `kill <pid>`.
- **Watch** `agents(caf)` again and again, and `symptoms(caf, kind: "absent_main")`.
- **Passed when** `demo-main` reads stopped, then starting, then idle on `one`, under the same
  session (`look` shows the earlier turns): resumed once, by the healer, with no typing and no
  dialog. `acts(caf, act: "resume", target: "demo-main")` shows one row,
  its actor `absent_mains:<host>`, its state `absent_main:demo-main:<start>`, settled
  `recovered`; the symptom has that state.
- **Then** end it again within the hour (the bound, `remedy_bound`): read the row again for
  the new pid and `kill` it as above.
- **Passed when** no second resume runs: `demo-main` stays stopped, `acts(caf, act: "resume",
  target: "demo-main")` still shows one row, and `prompts(caf, kind: "remedy")` lists
  `remedy:<n>` with agent `demo-main`, its text naming `absent_main`, its reason the bound
  (`again_within`) and the remedy `resume`, options `act` and `leave` (F-190: the kind is on
  the list, so `approve` would widen nothing). Then answer it `answer(caf, "remedy:<n>",
  "act")`: it reads `{:ok, :answered}` and the prompt goes; a second answer reads `{:refused,
  :settled}`.
- **Passed when** the healer resumes it once more by itself at its next check, and it runs
  again, idle: `acts(caf, act: "resume", target: "demo-main")` shows a second row, its actor
  `operator` (the person who answered, never the healer), its state the second absence's,
  settled `recovered`; `symptoms(caf, kind: "absent_main")` shows that state `answered act by
  operator`. No third row comes.
- **Record** `absent-main`: both reads of the row, the two `ps` lines, the session file, the
  `Acts` rows, the symptoms and the prompt, whole, with the times.

## 14. The main session's end

- **Type**: first `end_main(caf, "demo-main")`, which is refused while any delegate of it has
  not ended. Then end each delegate whose report was delivered: `stop_delegate(caf,
  "demo-unit-hello")`, and the same for `demo-unit-notes`, `demo-unit-slow`, `demo-unit-inbox`
  and `demo-unit-bg`. Then `end_main(caf, "demo-main")` again, and `start_main(caf, "demo",
  "demo-main", "Again.")`. Then `symptoms(caf)` and `faults(caf)`.
- **Watch** `agents(caf)` and `demo-main`'s screen.
- **Passed when** the first `end_main` is refused `{:delegates, names}`; each stop answers ok;
  the second `end_main` reads `ok: :ended`; `agents(caf)` reads `no agents` and `agents(caf,
  true)` shows all six `ended`; `demo-main`'s process is gone and its viewer closes; the new
  start is refused `{:running, "demo-main"}`; `leases(caf)` holds nothing; `prompts(caf)`
  lists only `login:three`. Then, if you have a login to give it (any of yours), `bin/caf-login
  /Users/me/caf-e2e three` and `answer(caf, "login:three", "check")`: it reads
  `{:ok, :logged_in}` and the inbox is empty.
- **Record** `symptoms`: `symptoms(caf)` and `faults(caf)`, whole. A symptom no step made
  (`hooks_silent`, `lost_viewer`, `end_owed`) is a finding.

## 15. The exit dialog's capture

The screens of Claude Code's dialog at `/exit` while a background command runs, for `Screen`'s
fixtures (F-180's new-2). It runs Claude Code outside the framework, on one account's own
directory, so quit the app first: `System.halt()`.

- **Type** in a terminal at least 120x40:

  ```sh
  devenv shell -- bin/capture-screen --out /Users/me/caf-e2e-capture /Users/me/caf-e2e/accounts/two/claude
  ```

  with `--name '<text>'` for each name of yours the screens may show (your name, your email).
  Attach a second terminal with the command it prints, and follow its ten states. At
  `turn-ended-background` and again at `exit-dialog`, before you press Enter, read the session
  file in a third terminal: `ls -t /Users/me/caf-e2e/accounts/two/claude/sessions/`, then `cat`
  the newest, `<pid>.json`.
- **Watch** the attached pane: at `exit-dialog`, Claude Code's dialog about the background
  work; answer it with the option that exits and stops the command only when the script asks.
- **Passed when** the script writes `/Users/me/caf-e2e-capture/2.1.322/` (the pinned
  release's version; the paths below name it as it is now) with ten states and
  `manifest.json` (or names a state the release did not show, `"shown": false`), and refuses
  nothing. Read every file for a name of yours before it goes anywhere: only the names the
  script knows are scrubbed.
- **Then**, on the branch the main session names, the four new files go beside the pinned
  release's fixtures, with their four entries from the new `manifest.json` added to the one
  there by hand; the release's `exited.*` is compared, not replaced:

  ```sh
  cp /Users/me/caf-e2e-capture/2.1.322/{turn-ended-background,exit-dialog}.{txt,ansi} apps/caf_screen/test/fixtures/2.1.322/
  diff /Users/me/caf-e2e-capture/2.1.322/exited.txt apps/caf_screen/test/fixtures/2.1.322/exited.txt
  ```

- **Record** `exit-dialog`: both session files, whole, with the state each was read at (its
  `status`, `shell` or `idle` or another, decides how `Sessions` reads the dialog), the diff,
  and the dialog's options as the screen shows them.

## On Linux

The same run on Linux (NixOS), then the checks only Linux can make. The paths use `/home/me`,
and the checkout of this repository is `/home/me/coding_agent_framework`. Linux cuts a socket
path at 108 bytes, so the home stays short there too.

- **The whole run again**: steps 0 to 14, as on macOS, with `/home/me` for `/Users/me`. Step 15
  is per release, not per system: run it to `/home/me/caf-e2e-capture` and record the diff of
  every state against the release's fixtures, copying nothing. What differs on Linux:
  - Claude Code keeps an account's login in its directory, not a Keychain: after step 0's
    logins, `ls -l /home/me/caf-e2e/accounts/*/claude/.credentials.json` (each mode 600, and
    none for `three`). gh has no keyring to choose; its check still reads `the token is in the
    home: a file`.
  - A session's `PATH` is devenv's programs, then `/usr/bin:/bin:/usr/sbin:/sbin`, which hold
    almost nothing on NixOS. In step 2, have `demo-main` run `command -v git gh make sh env` with
    its `Bash`, and record which it finds.
  - Before step 1, `touch /home/me/caf-e2e-stamp`; after step 14, `find /home/me -newer
    /home/me/caf-e2e-stamp -not -path '/home/me/caf-e2e/*' -not -path
    '/home/me/coding_agent_framework/*' 2>/dev/null`: what Claude Code wrote outside the home
    (F-155's new-2). Leave out what you changed yourself.
- **Record** `linux-paths`: the credentials' listing, what `command -v` found, `getconf
  ARG_MAX`, and the `find`'s list.

### L1. The process tree of a headless session with a background command and an MCP server

Whether `stuck_background`'s remedy goes on by default (F-184's new-1): a background command
leads a process group of its own, a descendant of the delegate's process, and the healer reads
every such group. If Claude Code spawns a stdio MCP server the same way, a quiet server reads as
stuck. No stdio MCP server reaches a delegate as built (every launch takes `--strict-mcp-config`
and the account's `mcp.json` names none), so this check adds one by hand, `bin/quiet-mcp`.

- **Type**, in step 12, before its `start_delegate`: check that each account's MCP file is the
  framework's empty one, then name the quiet server in it (the next start of the app writes the
  file again):

  ```sh
  cat /home/me/caf-e2e/accounts/{one,two}/claude/framework/mcp.json
  for a in one two; do printf '{"mcpServers":{"quiet":{"command":"%s"}}}\n' /home/me/coding_agent_framework/bin/quiet-mcp > /home/me/caf-e2e/accounts/$a/claude/framework/mcp.json; done
  ```

  Then step 12's start with this command in the brief, which uses some CPU and then none for
  fifteen minutes: `i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done; sleep 900; echo bg done`.
  Once it reported, `bg = Agents.get(Run.info(caf).agents, "demo-unit-bg")`, and:

  ```sh
  ps -e -o pid,pgid,sid,ppid,etimes,args --forest
  ```

- **Passed when** the tree under the delegate's dtach shows Claude Code (`bg.pid`, whose args
  are Claude Code's, not dtach's), the background command's shell, and `quiet-mcp`. Read off
  each one's group: the shell leads its own (its `pgid` is its `pid`), a descendant of
  `bg.pid`. Then the decision: if `quiet-mcp`'s `pgid` is Claude Code's, the remedy may go on by
  default; if it leads a group of its own, it stays off.
- **Record** `linux-process-tree`: the lines of the delegate's tree, whole, with `bg.pid` and
  `bg.proc_start`, and the decision as read.

### L2. The CPU time the healer reads, against ps

- **Type**, while L1's command sleeps, the healer's own read of the delegate's groups
  (`StuckBackgrounds.Groups.read/3` by the agent row's record and the tree's holder, F-190),
  then the same groups by `ps` in another terminal; again a minute later:

  ```elixir
  groups(caf, "demo-unit-bg")
  ```

  ```sh
  getconf CLK_TCK
  ps -e -o pgid=,pid=,time=,args= | grep -E '^ *<each group pid> '
  ```

  (procps's `-g` selects a session, not a group, so the group is read off its column.)

- **Passed when** `groups` prints the background command's group (and `quiet-mcp`'s if L1
  found it leads one), each one's CPU time in clock ticks; that time divided by
  `CLK_TCK` is the sum of `ps`'s `TIME` over the group's members, give or take a second (the
  healer also counts the CPU time of children already reaped, which `ps` does not show); and
  neither moves in the minute between.
- **Then**, eleven minutes after the report, `symptoms(caf, kind: "stuck_background")`.
  The healer reads at the tree's `interval` as well as at its cues (F-190), so a quiet command,
  which sends none, is read by itself.
- **Passed when** it shows one symptom per quiet group, its state naming the group's pid,
  shown only: nothing is ended, since the default list has no remedy for it.
- **Record** `linux-cpu`: both reads of `groups` and of `ps`, `CLK_TCK`, and the symptoms.

### L3. One `system`/`init` per turn Claude Code starts on its own

- **Type** nothing new: L1's delegate runs Claude Code's own turn when its command ends.
- **Passed when** its event log holds `system`/`init` twice and `result` twice, the second
  init after `task_notification` and the last `background_tasks_changed` (no task), as on macOS
  (F-184's new-2); `demo-main` gets one notice of the turn and no second report.
- **Record** `linux-background`: as step 12's `background`.

### L4. The argument cap

A launch's prompt is one argument, and Linux caps an argument at 131,072 bytes
(`MAX_ARG_STRLEN`); the framework's cap there is 126,976 bytes, and a longer first row goes by
a pointer (F-155). A headless brief goes in on the stream, not as an argument, so this check
uses an interactive delegate.

- **Type** after step 13, before step 14:

  ```elixir
  long = "Reply with the word long in one line, and do nothing else. " <> String.duplicate("This sentence pads the brief past the argument cap. ", 2_600)
  byte_size(long)
  start_delegate(caf, "demo-main", "demo", "unit/long", long, interactive: true)
  ```

  Answer its trust dialog from the inbox. Then its pid, `Agents.get(Run.info(caf).agents,
  "demo-unit-long").pid`, and in another terminal `ps -o args= -p <pid> | wc -c` and `ls -l
  /home/me/caf-e2e/due/demo-unit-long/`.
- **Passed when** `byte_size(long)` is past 131,072; the start is not refused; Claude Code's
  arguments are a few hundred bytes, its prompt one line naming
  `/home/me/caf-e2e/due/demo-unit-long/<row id>.md`, which holds the whole brief; the delegate
  reports `long`. Step 14 then stops `demo-unit-long` too, and `agents(caf, true)` shows seven
  ended.
- **Record** `linux-cap`: `byte_size(long)`, the `ps` line's length and its prompt, and the
  file's size.

## After the run

Quit the shell (`System.halt()`). The framework's tmux server outlives it: end it with `tmux -S
/Users/me/caf-e2e/tmux.sock kill-server`. Remove the home only once `agents(caf, true)` showed
every agent ended. Each account's login stays in its config directory (and on macOS the
Keychain) until `claude auth logout` with that directory
(`CLAUDE_CONFIG_DIR=/Users/me/caf-e2e/accounts/one/claude`).

Send the main session the records folder, `/Users/me/caf-e2e-records/`, and the capture
folder, `/Users/me/caf-e2e-capture/2.1.322/`, once you read each file for names of yours. This
repository is public: a record names no person, account email, organization or host of yours;
write `/Users/me` (or `/home/me`) for your home and `me` for your name. The records, by step:

| Record | Step | What it settles |
|---|---|---|
| `headless-permission` | 3 | a headless delegate's request in the inbox, and whether a hook comes too |
| `inbox` | 10 | the inbox's read of three kinds at once |
| `usage` | 11 | `Usage`'s windows against the status line and `/usage` |
| `background` | 12 | the order of a headless background command's events |
| `absent-main` | 13 | one resume per absence, a prompt past it, and its act once |
| `symptoms` | 14 | what the `Watch` recorded in a whole run |
| `exit-dialog` | 15 | what the session file says while the exit dialog shows |
| `usage-limit` | any | a real limit, if one came, and what the session file says during Claude Code's own wait |
| `linux-paths` | On Linux | the login's file, the session's `PATH`, writes outside the home |
| `linux-process-tree` | L1 | whether `stuck_background`'s remedy goes on by default |
| `linux-cpu` | L2 | the healer's CPU time against `ps`, and its symptom of a quiet group |
| `linux-background` | L3 | one `system`/`init` per turn of Claude Code's own |
| `linux-cap` | L4 | a brief past Linux's argument cap |

The main session writes the run up as a build note, one per system: each step's readings,
passed or not, each record, and each surprise as a finding. The capture's four files go into
`apps/caf_screen/test/fixtures/2.1.322/` on the branch of the unit that builds the exit dialog's
reading (step 15).
