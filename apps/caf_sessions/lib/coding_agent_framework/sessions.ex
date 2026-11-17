defmodule CodingAgentFramework.Sessions do
  @moduledoc """
  One host's session lifecycle: starts, resumes and stops Claude Code sessions, each held by
  dtach with a viewer pane, and keeps a row for each in `CodingAgentFramework.Sessions.Table`,
  which it alone writes. A session runs in the directory it is given, or in a worktree of a
  project that its start checks, adds and sets up.

  The caller's supervision tree starts one `Sessions` per host, with no name, and gives it the
  host's `Programs`, its dtach directory, its tmux server, the host's `Registry` (one over every
  account) and the SQLite path:

      {:ok, sessions} = Sessions.start_link(programs: programs, dir: "/srv/caf/dtach",
        tmux: tmux, registry: registry, db: "/srv/caf/caf.db")
      {:ok, account} = Accounts.ready(accounts, "work")
      Sessions.start(sessions, "main", account,
        role: :parent, cwd: "/src/app", claude: claude, model: "opus", env: env,
        tool_timeout: 3_600_000)
      #=> {:ok, %{name: "main", pid: 4242, session_id: "…"}}

  A host that runs delegates also gives it its `Stream` and the framework home (`stream:`,
  `home:`).

  **A start** (`docs/design.md`, "The delegate protocol") writes its row first, as `starting`,
  with the socket name and the session's name, which are one name. Then it holds
  `ClaudeCLI.session/3`'s argv and environment through `Holder.Process.hold/4`, which writes the
  held program's record (its pid and start time) before it execs it, in the given directory,
  and opens a viewer pane (`dtach -a`, as `viewer_argv/3` answers) on the tmux server, tagged
  with the session as it opens: one row short, then grown, since Claude Code does not redraw
  for a viewer that attaches at its own size. A viewer that fails leaves the session running;
  its row's `viewer` says why. The start is confirmed when the account's `Registry` reads a
  session file with the session's name (`--name`) whose pid lives, and the socket is live. The
  pid comes from that file, since dtach does not report it. **A resume** is the same with
  `--resume <id>`.

  **The release.** An interactive start records, on its row (`release`), the Claude Code release
  its program is: what `<claude> --version` prints first, as in `2.1.322 (Claude Code)`, read
  before the row is written (F-113's new-4). `Screen` reads the session's screen as that
  release draws it, and the `Inlet` refuses a typed write to a session whose release is nil (not
  read) or has no reading. A headless session's is not read: nothing reads its screen.

  **An interactive start's prompt** (`prompt:`, F-137: `Mailbox`'s `launch` transport) is
  written to `<dtach dir>/<name>.prompt`, and the hold runs `ClaudeCLI.prompted/5`, which reads
  it into the last argument, after `--`, and removes it; a prompt over `ClaudeCLI.prompt_max/0`
  bytes is refused. Claude Code runs it as the session's first turn.

  **A startup dialog** (F-140, `model/tla/Dialog.tla`). Before its first turn an interactive
  session may show the folder trust dialog, then the external imports dialog; neither sends a
  hook event, and no session file exists while one is shown. With `inlet:`, an interactive
  start reads its pane (`Inlet.look/4`) at each check while it has no session file. A startup
  dialog makes the row `dialog`, with the dialog (`Sessions.Dialog`), and a cue. The app's
  `dialog:` callback is asked once per kind: `{:answer, label}` presses that option, and
  `:ask`, the default, leaves it to a person: the start answers `{:unknown, {:dialog, kind}}`
  at once, and the row waits, through the start's deadline and a restart, until
  `answer_dialog/5` presses an option. Each press is marked on the row before it goes, checked
  by the `Inlet` (`Inlet.choose/5`), and never made twice. While a row waits, its pane is read
  every `look:` ms and at each cue: the next dialog becomes the row's, and once the session
  file names the process the row is `running`, as a start's confirm makes it. A start whose
  process exits on a dialog ("No, exit") is `stopped`.

  **A delegate** (role `:delegate`) runs headless ("Headless delegates"): after its row, which
  keeps the session id the framework chose, `Stream.follow/5` makes its directory and FIFO under
  `<home>/streams/<session id>/`, then `ClaudeCLI.headless/2`'s argv is held inside
  `ClaudeCLI.wrapper/4` on the FIFO the follow answered, `Stream.held/3` tells `Stream` the
  process was held, and its viewer is a pane running `tail -F` of its event log (the
  renderer is a later unit; `-F` waits for a log the wrapper has not opened yet; again
  `viewer_argv/3`'s answer). Its start is confirmed when `Stream` has read a `system`/`init`
  naming the session id while the socket is live and the held program's record names a
  process that runs with its pid and start time. The record is written before the program
  starts, so the init comes after it. A resume
  follows the same log again, from the offset `Stream` saved. A delegate's first message is a
  `Stream` write, not part of the start: `prompt:` is not read.

  **A worktree** (`docs/design.md`, "The worktree"; `Start.tla`'s `Checked`, `Added`,
  `SetupStarts` and `SetupEnds`): a launch with `worktree: %{project: project, branch: branch}`
  runs at `<home>/worktrees/<project>/<name>`, which its row keeps as `cwd`. A start whose path
  another row that has not ended holds is refused before its row is written. After the row, a
  task linked to `Sessions` reads `git worktree list` and `git status` (`Sessions.Worktree`),
  adds the tree when the path is free, reads the list again (it, not the add's exit status,
  says what the add did), and runs the project's setup in it, each command through `Shell` with
  the host's reaper, so `Sessions`' death ends them. Then the start holds and waits as above.
  The row's deadline covers the setup's. git runs with an empty environment, the setup with the
  project's. After a restart, a row refused as interrupted has its worktree removed when it is
  on the branch, clean and held by no other row; the row's `worktree` says what was done.

  **A stop** (`docs/design.md`, "Ending a session"; `Start.tla`'s `StopAsked`) of an interactive
  session reads the account's `Registry` and sends SIGTERM to the process the row names, by its
  pid and start time (`Holder.Process.signal/4`), only once the session file of that process
  says `status: "idle"`; any other status is refused as `{:not_idle, status}`. Claude Code then
  keeps its transcript, fires `SessionEnd` with reason `other`, and exits 143 (F-114). A process
  already gone is sent nothing. Then the stop waits until that process is gone, judged by
  `{pid, procStart}` (`Holder.Process.liveness/3`), never by name, and its socket is dead, so a
  resume after the answer is never refused `{:live, name}`. The idle read waits, in the same
  step, until no `Mailbox` row to the session is `sending` (`open_to:`). A delegate's stop
  writes `end_session` through `Stream` instead, once no `Mailbox` row to it is open, and its
  turn is `Stream`'s row's, not the caller's: `Stream` refuses the end while a turn runs or a
  message has not gone in. An interactive session's start puts `Intake`'s waiter hook into its
  launch overlay (`waiter:`).

  Each call answers `{:ok, …}`, `{:refused, reason}` or `{:unknown, reason}` within its
  `:timeout` (30 s by default, plus the hold's and the viewer's own bounds). Nothing is retried:
  a start that is not confirmed in time answers `{:unknown, :no_session_file}` (a delegate's,
  `{:unknown, :no_first_event}`), and its row says `unknown` with that reason. A hold that answers unknown still waits for the file. A stop whose
  process is alive at its deadline answers `{:unknown, {:no_exit, sent}}` and leaves the row
  `stopping` with reason `no_exit`: `Recoveries` ends that process by its pid and start time
  (`ends_owed/2`). One whose process is gone while its socket is still live answers
  `{:unknown, {:socket_live, sent}}`, and the row, reason `socket_live`, waits for the next
  settle. `sent` is what the end's TERM or `end_session` answered.
  `Sessions` itself never kills: its one signal is the stop's TERM. The row keeps the start's or stop's deadline in wall-clock time
  (the `clock:` option), so a restart does not move it.

  **Rows with no call under way** are settled as `model/tla/Start.tla` does, when `Sessions`
  starts, at a starting row's deadline, and at each `Registry`, `Stream` or `TmuxSampler` cue
  that `cue/2` hands it. A socket ends apart from its process: dtach removes it a moment after
  the process exits, and a dtach killed hard leaves it stale while the process may run on.
  "Confirmed" is a delegate's first event and recorded pid, as above; "unheld" is a dead socket
  while the session file (a delegate's recorded pid) names a live process:

  - `starting` (left by a restart): `running` when confirmed; past its deadline, `orphan` for a
    live socket (with the held program's record) or an unheld process (reason `unheld`, with
    the file's pid and start time, or a delegate's record), and `refused{interrupted}` for a
    dead socket otherwise;
  - `unknown`: `running` when confirmed, `orphan` when unheld, `stopped` when its socket is
    dead otherwise;
  - `stopping`: `stopped` when its process is gone by pid and start time and its socket is
    dead; when it lives, `running` after a restart, but a late stop (`no_exit`) stays for
    `Recoveries`;
  - `running` (its process exited by itself, a crash or a kill): `stopped` with reason
    `exited` once its process is gone by pid and start time and its socket is dead, so its
    name can be resumed. A pid another program took counts as gone;
  - `orphan` (F-118): `stopped` with reason `ended` the same way, once `Recoveries` ended its
    process or it exited, so its name is free again.

  A read that fails decides nothing; the row waits for the next read. A settle of a `running`
  row that decides nothing for that reason (the `ps` or the socket read failed, or the socket
  lives although the process is gone) says so in one `Logger.debug` line naming the row and
  what it saw, so a row that stays `running` shows why. A name whose row is
  `unknown`, `orphan`, `starting` or `stopping` is refused to a new start: its process may live.

  **The agent row** (`docs/design.md`, "The parts"): each row is one agent of the tree, of kind
  `main` or `delegate` (a launch's `kind:`, by default `:delegate` for role `:delegate` and
  `:main` otherwise), with its `parent:` (a delegate's main session, which it must name; a main
  session names none) and its `project:` (a worktree's, or the launch's). A resume keeps the
  row's. Until `Mains`, the embedding app names its main sessions (`mains:`), each written
  `declared` when it has no row. A delegate that is done for good is `ended` (`ended/3`, which
  `Delegates` asks once its report went in). Other parts read the rows only through
  `CodingAgentFramework.Sessions.Agents`: the tree, and what each status means.

  After each write it calls `notify` with `%{topic: "sessions:<host>", ids: [id]}`, a cue that
  names rows, never their data; the `Tracker` reads the rows by `Sessions.Table.meta/0`.
  """

  use GenServer

  require Logger

  alias CodingAgentFramework.{ClaudeCLI, Holder, Programs, Registry, Shell, Stream, Tmux}
  alias CodingAgentFramework.{Accounts, Acts, ClaudeCLI.Options, Inlet, Intake, Store}
  alias CodingAgentFramework.Transcripts
  alias CodingAgentFramework.Sessions.{Agents, Dialog, Table, Turn, Worktree}

  @timeout 30_000
  # Each git command of a worktree, and the checks and the add before a setup: three lists or
  # reads and the add.
  @git 10_000
  @tree 4 * @git
  # The physical path of the worktrees' root, made first; `$2` is mkdir.
  @root ~S("$2" -p -- "$1" && cd -- "$1" && pwd -P)
  # A read of a row, which waits only for a start's own steps ahead of it in the queue.
  @read 5_000
  # The hold's, the follow's and the viewer's own bounds, past the confirmation's.
  @slack 30_000
  # Each call to Stream, within a call of Sessions.
  @stream 5_000
  # `claude --version` at an interactive start.
  @version 5_000
  # The held program starts in the session's directory; `$0` is the directory.
  @cd ~S(cd -- "$0" && exec "$@")
  # A checked press of a dialog's option: the Inlet's keys, its two screen reads and Enter.
  @press 20_000

  @type outcome(ok) :: {:ok, ok} | {:refused, term} | {:unknown, term}

  @doc """
  Starts a `Sessions` and adopts or ends the rows a previous one left `starting`. Options:
  `programs:` (naming dtach, sh, env, rm, ps, kill, sleep and tail), `dir:` (the dtach directory),
  `tmux:` (the host's tmux server, for the viewers), `registry:` (the host's `Registry`), `db:`, and optionally `stream:`
  and `home:` (the host's `Stream` and the framework home, for delegates and worktrees),
  `reaper:` (the host's `Shell.Reaper`, for worktrees; `programs:` then names git and mkdir),
  `inlet:` (the host's `Inlet`, which reads an interactive start's pane and presses an answer
  to its startup dialog; `programs:` names cat for an interactive start's prompt), `dialog:`
  (the app's callback for a startup dialog, `fn kind, options -> {:answer, label} | :ask end`,
  by default `Sessions.Dialog.ask/2`: ask a person), `look:` (ms between reads of a pane that
  waits on a person, default 5 000),
  `notify:`, `size:`
  (the viewer's `{columns, rows}`, default `{200, 50}`), `poll:` (ms between reads while a call
  waits, default 200), `clock:` (a function answering wall-clock ms, for the deadlines), and,
  `mains:` (until `Mains`: `%{name => project}`, each main session the app declares, written
  as a row of kind `main` when it has none), `acts:` (the instance's `Acts`: each start and
  resume is a row there, actor `sessions:<host>`, written before the agent row and settled by
  the call's answer, `Acts.answered/4`; a start whose row cannot be written is refused
  `{:acts, answer}`), and, where the app runs `Mailbox` and `Intake`:

  - `open_to:`, `fn name, :open | :sending -> {:ok, ids} end`, the ids of the `Mailbox` rows to
    `name` that are open, or only `sending`, as `Mailbox.open_to/3` answers them; a stop reads
    it (`stop/3`);
  - `waiter:`, `%{port: port, secret: secret}`, `Intake`'s: an interactive session's start
    puts the waiter hook (`Intake.waiter_hook/5`, with the host's sh and curl) into its launch
    overlay, beside the account's hooks, so `Mailbox` delivers to it ("Delivery into a main
    session"). `programs:` then names curl.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Starts session `name` on `account` (from `Accounts.ready/2`). `launch` holds `role:` and
  `cwd:` (an absolute path) or `worktree:` (`%{project: project, branch: branch}`, with the
  project as `Sessions.Worktree.project/1` reads it; `cwd:` is then not read); the agent row's
  `kind:`, `parent:` and `project:` (the module doc's "The agent row"; a delegate with no parent
  is refused `{:missing, :parent}`, a main session with one `{:bad, :parent}`); and
  `ClaudeCLI.session/3`'s `claude:`, `model:`, `env:`, `tool_timeout:`, `prompt:` and `mcp:` (the agent's own MCP config),
  and `options:`, kept on the row with the model, each of which a resume that names none takes
  again. Option:
  `:timeout`, to which a worktree's start adds its setup's deadline and its git commands'
  bounds.

      Sessions.start(sessions, "reviewer", account,
        role: :delegate, parent: "app-main", worktree: %{project: project, branch: "unit/review"},
        claude: claude)
      #=> {:ok, %{name: "reviewer", pid: 4243, session_id: "…"}}
      #=> {:refused, {:worktree, :dirty}}
  """
  @spec start(GenServer.server(), String.t(), struct, keyword, keyword) :: outcome(map)
  def start(sessions, name, account, launch, opts \\ []),
    do: request(sessions, {:start, name, account, launch, nil}, opts)

  @doc """
  As `start/5`, resuming Claude Code's session `session_id` (`--resume`). A resume in a
  worktree takes the name's worktree as it is, changes and all, refuses one that is not there,
  and runs the setup.
  """
  @spec resume(GenServer.server(), String.t(), struct, String.t(), keyword, keyword) ::
          outcome(map)
  def resume(sessions, name, account, session_id, launch, opts \\ []),
    do: request(sessions, {:start, name, account, launch, session_id}, opts)

  @doc """
  Ends running session `name` and waits for its process to exit. Its row is `stopping` first,
  so `Mailbox` marks no row to it from then on. An interactive session gets SIGTERM once its
  session file says `idle` and, read in the same step through `open_to:`, no `Mailbox` row to it
  is `sending`: a row marked before the stop is waited for until the stop's deadline, then
  refused as `{:sending, ids}` (F-122's new-1). Another status is refused as
  `{:not_idle, status}`. A delegate gets `end_session` through `Stream` only when no row to it
  is open (`{:refused, {:open, ids}}`), since the end cuts a turn and drops what has not gone
  in; its caller, `Delegates`, checks its report delivered before it asks. `Stream` then refuses
  the end while its row's turn runs (`:turn_running`) or a message is under way or found
  undelivered. A refusal puts the row back to `running`. Options: `:timeout`, and `for: :move`
  (`Mover`'s): a delegate is then ended as an interactive session is, by SIGTERM to its process
  by pid and start time once `Stream`'s fold reads its turn ended (`Sessions.Turn.stream/1`) and
  no row to it is `sending`, since a move keeps what is still `queued` for the next process
  (an `end_session` would end those rows); a turn that runs is refused `{:not_idle, turn}`.

      Sessions.stop(sessions, "main")
      #=> {:ok, :stopped}
      #=> {:refused, {:not_idle, "busy"}}
  """
  @spec stop(GenServer.server(), String.t(), keyword) :: outcome(:stopped)
  def stop(sessions, name, opts \\ []),
    do: request(sessions, {:stop, name, Keyword.get(opts, :for, :end)}, opts)

  @doc """
  Answers the startup dialog agent `name`'s start waits on (its row `dialog`) by the option
  labeled `label`: a person's answer, from the app's view or the operator's tool. `kind` is the
  dialog's (`:trust` or `:imports`, or its name), so an answer meant for one dialog never
  presses another. The answer is marked on the row, then the `Inlet`'s checked press goes
  (`Inlet.choose/5`); the start then goes on as before.

  Answers `{:ok, :sent}` once the dialog has left the pane. Refused, with nothing pressed:
  `:no_session`, `{:not_on_dialog, status}`, `{:bad, :kind}`, `{:shown, kind}` (the row shows
  another dialog, or none), `{:no_option, label}`, `{:answered, mark}` (an answer to that
  dialog was already marked: never pressed twice), `:no_inlet`, or the `Inlet`'s refusal.
  Unknown: the `Inlet`'s, once a key may have gone; that answer is never pressed again. Option:
  `:timeout` (ms, default 25 000).

      Sessions.answer_dialog(sessions, "app-main", :trust, "Yes, I trust this folder")
      #=> {:ok, :sent}
      #=> {:refused, {:answered, "sent"}}
  """
  @spec answer_dialog(GenServer.server(), String.t(), atom | String.t(), String.t(), keyword) ::
          outcome(:sent)
  def answer_dialog(sessions, name, kind, label, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @press + @read)

    case Dialog.kind(kind) do
      nil -> {:refused, {:bad, :kind}}
      kind -> call(sessions, {:answer_dialog, name, kind, label}, timeout)
    end
  end

  @doc """
  Begins a move of running agent `name` (`Mover`'s, F-133): its row takes the move's phase,
  `draining`, with `move` (`%{to: account, act: id, deadline: ms}`) and `move_from` its account,
  in one write, so no two moves of one agent begin. Refused `{:moving, phase}` while one is under
  way, `{:not_running, status}`, `{:same_account, to}`, or `:no_session`. Answers `{:ok, row}`.
  Option: `:timeout` (ms, default 5 000).
  """
  @spec begin_move(GenServer.server(), String.t(), map, keyword) :: outcome(map)
  def begin_move(sessions, name, %{to: _, act: _, deadline: _} = move, opts \\ []),
    do: call(sessions, {:begin_move, name, move}, Keyword.get(opts, :timeout, @read))

  @doc """
  Sets the phase of agent `name`'s move under way (`"stopping"`, `"copying"`, `"resuming"`), with
  `fields` (`to:`, `act:`), or ends it with `nil`, which clears every move field. `Mover` is its
  one caller. Refused `:no_move` for a row with no move under way, or `:no_session`.
  """
  @spec move_phase(GenServer.server(), String.t(), String.t() | nil, keyword, keyword) ::
          outcome(:ok)
  def move_phase(sessions, name, phase, fields \\ [], opts \\ []),
    do: call(sessions, {:move_phase, name, phase, fields}, Keyword.get(opts, :timeout, @read))

  @doc """
  Delegate `name` is done for good: its report went in and no process of it may live. Its row
  becomes `ended`, so it frees its parent's cap and what it owns ends with it; it keeps its
  place in the tree, so what it kept goes to its parent.
  `Delegates` asks it. Answers `{:ok, :ended}` (also for a row already `ended`), `{:refused,
  :no_session}`, `{:refused, :main}` for a main session, which never ends, `{:refused,
  {:moving, phase}}` while a move resumes it, or `{:refused, {:not_free, status}}` while its
  process may live. Option: `:timeout` (ms, default 5 000).

      Sessions.ended(sessions, "app-unit-review")
      #=> {:ok, :ended}
  """
  @spec ended(GenServer.server(), String.t(), keyword) :: outcome(:ended)
  def ended(sessions, name, opts \\ []),
    do: call(sessions, {:ended, name}, Keyword.get(opts, :timeout, @read))

  @doc """
  A migration step (F-129): the parent and project of each delegate that an earlier build kept
  only in `Delegates`' table, which `Delegates` hands over once, before it drops them. Each
  entry is `%{name, parent, project, ended}`; a delegate row of that name with no parent takes
  them, and with `ended: true` is `ended` when no process of it may live. Answers `{:ok,
  count}`, the rows that took something. Option: `:timeout`.
  """
  @spec adopt_tree(GenServer.server(), [map], keyword) :: outcome(non_neg_integer)
  def adopt_tree(sessions, entries, opts \\ []),
    do: call(sessions, {:adopt_tree, entries}, Keyword.get(opts, :timeout, @read))

  @doc """
  Hands `Sessions` a `Registry`'s cue (`%{topic: "registry:<host>:<account>", ids: ids}`): the
  rows of that account with no call under way are read again from the `Registry`'s rows.
  `Cues` hands it the topics `reads/0` declares. A `Stream`'s cue
  (`stream:<host>`) does the same for the host's delegates, and a `TmuxSampler`'s
  (`tmux:<host>:<server>`, sent when its rows change, as when a held socket goes away) for every
  row of the host, so a settle that met a socket dtach had not removed yet is taken again. Answers
  `:ok` at once; what it settles shows in the rows and their cues.

      Sessions.cue(sessions, %{topic: "registry:laptop:work", ids: [3]})
      #=> :ok
      Sessions.cue(sessions, %{topic: "tmux:laptop:caf", ids: [7]})
      #=> :ok
  """
  @spec cue(GenServer.server(), map) :: :ok
  def cue(sessions, %{topic: topic}), do: GenServer.cast(sessions, {:cue, topic})

  @doc "What `Sessions` reads, for `Cues`: the registries', the streams' and the samplers' cues."
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(registry stream tmux), cue: &cue/2}

  @doc """
  The command of the viewer of session `name`, from its row: `dtach -a` of its socket
  (`Holder.viewer_argv/2`) for an interactive session, and `tail -F` of its event log for a
  headless delegate. `start` opens a viewer with this command, and `Recoveries` reopens a lost
  one with it, so the two never differ. Answers `{:ok, argv}`, `{:refused, :no_session}` when the
  host has no row of that name, or the refusal of the row's own command. A read: nothing is
  opened. Option: `:timeout` (ms, default 5 000).

      Sessions.viewer_argv(sessions, "main")
      #=> {:ok, ["/usr/bin/dtach", "-a", "/srv/caf/dtach/main.sock", "-E", "-z", "-r", "winch"]}
      Sessions.viewer_argv(sessions, "reviewer")
      #=> {:ok, ["/usr/bin/tail", "-F", "/srv/caf/home/streams/6f1c…/events.jsonl"]}
      Sessions.viewer_argv(sessions, "nobody")
      #=> {:refused, :no_session}
  """
  @spec viewer_argv(GenServer.server(), String.t(), keyword) :: outcome([String.t()])
  def viewer_argv(sessions, name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @read)
    call(sessions, {:viewer_argv, name}, timeout)
  end

  defp request(sessions, request, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    budget =
      with {:start, _, _, launch, _} <- request, do: budget(launch[:worktree]), else: (_ -> 0)

    call(sessions, {request, timeout}, timeout + budget + @slack)
  end

  # A worktree start's time before its hold: its setup's deadline and its git commands' bounds.
  defp budget(%{project: %{setup_timeout: t}}) when is_integer(t) and t > 0, do: t + @tree
  defp budget(_), do: 0

  defp call(sessions, message, wait) do
    GenServer.call(sessions, message, wait)
  catch
    :exit, {:noproc, _} -> {:refused, :no_sessions}
    :exit, {:timeout, _} -> {:unknown, {:timeout, wait}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    %Programs{host: host} = programs = Keyword.fetch!(opts, :programs)

    with {:ok, holder} <- Holder.new(programs, Keyword.fetch!(opts, :dir)),
         {:ok, procs} <- Holder.Process.new(programs, holder),
         {:ok, ps} <- Programs.take(programs, [:env, :ps, :tail]),
         {:ok, waiter} <- waiter(programs, Keyword.get(opts, :waiter)),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      state = %{
        host: host,
        holder: holder,
        procs: procs,
        ps: ps,
        db: db,
        tmux: Keyword.fetch!(opts, :tmux),
        registry: Keyword.get(opts, :registry),
        stream: Keyword.get(opts, :stream),
        home: Keyword.get(opts, :home),
        notify: Keyword.get(opts, :notify, fn _ -> :ok end),
        size: Keyword.get(opts, :size, {200, 50}),
        poll: Keyword.get(opts, :poll, 200),
        clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
        reaper: Keyword.get(opts, :reaper),
        open_to: Keyword.get(opts, :open_to),
        acts: Keyword.get(opts, :acts),
        mains: Keyword.get(opts, :mains, %{}),
        waiter: waiter,
        git: Programs.fetch(programs, :git),
        cat: Programs.fetch(programs, :cat),
        inlet: Keyword.get(opts, :inlet),
        dialog: Keyword.get(opts, :dialog, &Dialog.ask/2),
        look: Keyword.get(opts, :look, 5_000),
        looking: false,
        worktrees: root(host, holder.sh, programs, Keyword.get(opts, :home)),
        pending: %{}
      }

      {:ok, state, {:continue, :adopt}}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:adopt, state) do
    # A start this process's last life claimed and never answered: its call ended with it.
    if state.acts, do: Acts.interrupt(state.acts, actor(state))

    for {name, project} <- state.mains do
      id = Table.declare(state.db, state.host.name, name, project)
      state.notify.(%{topic: topic(state), ids: [id]})
    end

    # A press marked before this process's last life ended may have gone: never pressed again.
    for row <- Table.with_status(state.db, state.host.name, "dialog"),
        answers = Dialog.after_restart(row),
        do: write(state, row, answers: answers)

    settle(state, :all, true)

    # One wake at each starting row's deadline, when Adopt may decide; not a poll.
    for row <- Table.with_status(state.db, state.host.name, "starting") do
      Process.send_after(self(), :deadline, max((row.deadline || 0) - state.clock.(), 0))
    end

    {:noreply, look_later(state)}
  end

  @impl true
  def handle_cast({:cue, "registry:" <> rest}, state) do
    case String.split(rest, ":", parts: 2) do
      [host, account] when host == state.host.name -> settle(state, {:account, account}, false)
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:cue, "stream:" <> host}, state) do
    if host == state.host.name, do: settle(state, :delegates, false)
    {:noreply, state}
  end

  # The sampler's: a held socket went away or went stale, among other changes of its rows.
  def handle_cast({:cue, "tmux:" <> rest}, state) do
    case String.split(rest, ":", parts: 2) do
      [host, _server] when host == state.host.name -> settle(state, :all, false)
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:cue, _topic}, state), do: {:noreply, state}

  @impl true
  def handle_call({{:start, name, account, launch, resume}, timeout}, from, state) do
    launch = model(state, name, resume, launch)

    with :ok <- free(state, name),
         {:ok, place} <- place(state, name, launch),
         {:ok, role} <- Keyword.fetch(launch, :role) |> required(:role),
         {:ok, agent} <- agent(state, name, role, launch, place, resume),
         {:ok, way} <- way(state, role, account, name, place.cwd, resume, launch),
         deadline = state.clock.() + timeout + budget(place.tree),
         row = new_row(state, name, account, role, place, resume, way, deadline, launch),
         row = Map.merge(row, agent),
         row = Map.put(row, :release, release(state, role, launch)),
         {:ok, viewer} <- viewer_command(state, row),
         {:ok, act} <- claim(state, name, resume) do
      # RowWritten: the row first, as starting, with the start's wall-clock deadline.
      row = Map.put(row, :id, Table.starting(state.db, row))
      announce(state, row)

      pending = %{
        kind: :start,
        from: from,
        row: row,
        deadline: deadline,
        way: way,
        viewer: viewer,
        act: act
      }

      case place.tree do
        nil ->
          {:noreply, hold_and_view(state, name, pending)}

        # Checked, Added and the setup, in a task: a setup may take minutes, and other calls
        # go on meanwhile. The task is linked, so Sessions' death ends it, and the reaper its
        # commands' groups.
        tree ->
          run = runner(state)
          task = Task.async(fn -> prepare(run, tree, place.cwd, resume != nil) end)

          {:noreply,
           put_in(state.pending[name], %{pending | kind: :tree} |> Map.put(:task, task.ref))}
      end
    else
      failed -> {:reply, failed, state}
    end
  end

  def handle_call({:answer_dialog, name, kind, label}, _from, state) do
    with %{} = row <- Table.get(state.db, state.host.name, name) || {:refused, :no_session},
         "dialog" <- row.status,
         :ok <- Dialog.check(row, kind, label) do
      answer = press(state, row, kind, label)
      # The next screen, a dialog or the start going on, is the row's now, not at the next look.
      if answer != {:refused, :no_inlet}, do: look_at(state, Table.get(state.db, row.host, name))
      {:reply, answer, look_later(state)}
    else
      status when is_binary(status) -> {:reply, {:refused, {:not_on_dialog, status}}, state}
      refused -> {:reply, refused, state}
    end
  end

  def handle_call(:ends_owed, _from, state) do
    rows =
      Table.with_status(state.db, state.host.name, "orphan") ++
        for(
          %{reason: "no_exit"} = row <- Table.with_status(state.db, state.host.name, "stopping"),
          not Map.has_key?(state.pending, row.name),
          do: row
        )

    owed =
      for %{pid: pid, proc_start: start} = row <- rows, is_integer(pid) and is_binary(start) do
        %{
          name: row.name,
          socket: row.socket,
          status: row.status,
          record: %{pid: pid, start: start}
        }
      end

    {:reply, {:ok, owed}, state}
  end

  def handle_call({:ended, name}, _from, state) do
    reply =
      case Table.get(state.db, state.host.name, name) do
        nil ->
          {:refused, :no_session}

        %{kind: "main"} ->
          {:refused, :main}

        %{status: "ended"} ->
          {:ok, :ended}

        # A move resumes it: its process may live again.
        %{move: phase} when is_binary(phase) ->
          {:refused, {:moving, phase}}

        row ->
          if Agents.free?(row) and not Map.has_key?(state.pending, name) do
            write(state, row, status: "ended")
            {:ok, :ended}
          else
            {:refused, {:not_free, row.status}}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:adopt_tree, entries}, _from, state) do
    taken =
      for %{name: name, parent: parent} = e <- entries,
          is_binary(parent),
          %{kind: "delegate", parent: nil} = row <- [Table.get(state.db, state.host.name, name)] do
        ended = if e[:ended] && Agents.free?(row), do: [status: "ended"], else: []
        write(state, row, [parent: parent, project: e[:project]] ++ ended)
      end

    {:reply, {:ok, length(taken)}, state}
  end

  def handle_call({:viewer_argv, name}, _from, state) do
    reply =
      case Table.get(state.db, state.host.name, name) do
        nil -> {:refused, :no_session}
        row -> viewer_command(state, row)
      end

    {:reply, reply, state}
  end

  def handle_call({:begin_move, name, move}, _from, state) do
    reply =
      case Table.get(state.db, state.host.name, name) do
        nil ->
          {:refused, :no_session}

        %{move: phase} when is_binary(phase) ->
          {:refused, {:moving, phase}}

        %{account: account} when account == move.to ->
          {:refused, {:same_account, move.to}}

        %{status: "running", pid: pid} = row when is_integer(pid) ->
          if Map.has_key?(state.pending, name) do
            {:refused, {:not_running, "calling"}}
          else
            fields = [move: "draining", move_from: row.account, move_to: move.to]
            write(state, row, fields ++ [move_act: move.act, move_deadline: move.deadline])
            {:ok, Table.get(state.db, state.host.name, name)}
          end

        row ->
          {:refused, {:not_running, row.status}}
      end

    {:reply, reply, state}
  end

  def handle_call({:move_phase, name, phase, fields}, _from, state) do
    reply =
      case Table.get(state.db, state.host.name, name) do
        nil ->
          {:refused, :no_session}

        %{move: nil} ->
          {:refused, :no_move}

        row when is_nil(phase) ->
          clear = [move: nil, move_from: nil, move_to: nil, move_act: nil, move_deadline: nil]
          write(state, row, clear)
          {:ok, :ok}

        row when phase in ~w(stopping copying resuming) ->
          extra = for {k, v} <- fields, k in [:to, :act], do: {:"move_#{k}", v}
          write(state, row, [move: phase] ++ extra)
          {:ok, :ok}

        _row ->
          {:refused, {:bad, :phase}}
      end

    {:reply, reply, state}
  end

  def handle_call({{:stop, name, how}, timeout}, from, state) do
    deadline = state.clock.() + timeout

    case Table.get(state.db, state.host.name, name) do
      %{status: "running", pid: pid} = row when is_integer(pid) ->
        # StopAsked, with the stop's own deadline in the row: from here `Mailbox` marks no row
        # to the session, so a row it marked before is the only one the idle read waits for.
        write(state, row, status: "stopping", reason: nil, deadline: deadline)
        pending = %{kind: :ask, from: from, row: row, deadline: deadline, how: how}
        {:noreply, ask(state, name, pending)}

      nil ->
        {:reply, {:refused, :no_session}, state}

      row ->
        {:reply, {:refused, {:not_running, row.status}}, state}
    end
  end

  # The end asked, or waited for: a row `Mailbox` still has `sending` to an interactive session
  # holds the SIGTERM until it settles or the stop's deadline passes (F-122's new-1). A refusal
  # sends nothing and puts the row back to running.
  defp ask(state, name, %{row: row} = pending) do
    case ask_end(state, row, pending.how) do
      {:refused, {:sending, _}} = refused ->
        state = put_in(state.pending[name], pending)

        wait(state, name, pending, fn ->
          write(state, row, status: "running")
          refused
        end)

      {:refused, _} = refused ->
        write(state, row, status: "running")
        done(state, name, pending, refused)

      # An unknown end may have gone out: the exit is waited for, and never sent again.
      sent ->
        send(self(), {:check, name})
        put_in(state.pending[name], Map.merge(pending, %{kind: :stop, sent: sent}))
    end
  end

  # A delegate's `end_session` line through Stream, once no row to it is open in `Mailbox`:
  # `Delegates` checked its report delivered before it asked.
  defp ask_end(state, %{role: "delegate"} = row, :end) do
    with :ok <- open(state, row.name, :open) do
      if state.stream,
        do: Stream.end_session(state.stream, row.session_id, timeout: @stream),
        else: {:refused, :no_stream}
    end
  end

  # A move's end of a delegate (`Move.tla`'s IdleRead and Term): SIGTERM by its record, once
  # Stream's fold, read now, says its turn ended and no row to it is `sending`. Its `queued` rows
  # stay for the process the move resumes; an `end_session` would have them settled ended.
  defp ask_end(state, %{role: "delegate"} = row, :move) do
    with {:ok, fold} <- followed(state, row, true) |> unread(),
         :ended <- Turn.stream(fold),
         :ok <- open(state, row.name, :sending) do
      Holder.Process.signal(state.procs, %{pid: row.pid, start: row.proc_start}, "TERM")
    else
      :gone -> {:ok, :gone}
      turn when is_atom(turn) -> {:refused, {:not_idle, turn}}
      refused -> refused
    end
  end

  # StopAsked: SIGTERM by the row's pid and start time, once the session file of that process
  # reads idle and, in the same step, no `Mailbox` row to it is `sending`. A refusal sends
  # nothing; a process already gone is sent nothing and settles.
  defp ask_end(state, row, _how) do
    case end_reading(state, row) do
      {:idle, record} ->
        with :ok <- open(state, row.name, :sending),
             do: Holder.Process.signal(state.procs, record, "TERM")

      :gone ->
        {:ok, :gone}

      {:not_idle, _} = busy ->
        {:refused, busy}

      {:unread, _} = unread ->
        {:refused, unread}
    end
  end

  # A start's or a resume's row in `Acts`, written before the agent row, with no state to claim:
  # each call is an act of its own. A row that cannot be written starts nothing.
  defp claim(%{acts: nil}, _name, _resume), do: {:ok, nil}

  defp claim(state, name, resume) do
    case Acts.claim(state.acts, actor(state), name, nil, if(resume, do: :resume, else: :start)) do
      {:ok, id} -> {:ok, id}
      other -> {:refused, {:acts, other}}
    end
  end

  defp actor(state), do: "sessions:" <> state.host.name

  defp unread({:ok, _} = ok), do: ok
  defp unread(other), do: {:refused, {:unread, other}}

  # The embedding app's read of `Mailbox` (`open_to:`): the ids of the rows to `name` that are
  # open (`queued` or `sending`), or only `sending`. With no `open_to:` the app runs no
  # `Mailbox`, and nothing is delivered to wait for.
  defp open(%{open_to: nil}, _name, _which), do: :ok

  defp open(state, name, which) do
    case state.open_to.(name, which) do
      {:ok, []} -> :ok
      {:ok, ids} when which == :sending -> {:refused, {:sending, ids}}
      {:ok, ids} -> {:refused, {:open, ids}}
      other -> {:refused, {:unread, {:mailbox, other}}}
    end
  end

  defp end_reading(state, row) do
    record = %{pid: row.pid, start: row.proc_start}

    with {:ok, registry} <- registry(state),
         {:ok, _} <- Registry.read(registry),
         {:ok, %{rows: files}} <- Registry.rows(registry, row.account) do
      case Turn.file(row, files) do
        %{alive: :live, status: "idle"} -> {:idle, record}
        %{alive: :live, status: status} -> {:not_idle, status}
        _ -> gone_or_not_idle(state, row)
      end
    else
      :error -> {:unread, :no_registry}
      other -> {:unread, other}
    end
  end

  # No live file names the process: it is gone, or runs with no file to read idle from.
  defp gone_or_not_idle(state, row) do
    case liveness(state, row) do
      gone when gone in [:gone, :replaced] -> :gone
      :live -> {:not_idle, nil}
      other -> {:unread, {:liveness, other}}
    end
  end

  @doc """
  The processes this host's rows owe an end that `Sessions` does not send: an `orphan` row's,
  and a stop's whose deadline passed with its process alive (`stopping` with reason `no_exit`),
  each with a pid and start time. `Recoveries` ends each by that record (`Start.tla`'s
  `Kill`). Answers `{:ok, [%{name: name, socket: socket, status: status, record: %{pid: pid,
  start: start}}]}`. A read; nothing is sent. Option: `:timeout` (ms, default 5 000).

      Sessions.ends_owed(sessions)
      #=> {:ok, [%{name: "reviewer", socket: "reviewer", status: "orphan",
      #=>          record: %{pid: 4243, start: "Tue Nov 17 09:00:00 2026"}}]}
  """
  @spec ends_owed(GenServer.server(), keyword) :: outcome([map])
  def ends_owed(sessions, opts \\ []),
    do: call(sessions, :ends_owed, Keyword.get(opts, :timeout, @read))

  @impl true
  def handle_info({:check, name}, state) do
    case state.pending[name] do
      nil -> {:noreply, state}
      pending -> {:noreply, check(state, name, pending)}
    end
  end

  def handle_info(:deadline, state) do
    settle(state, :all, true)
    {:noreply, look_later(state)}
  end

  # The rows that wait on a person: each pane read again, and each row settled.
  def handle_info(:look, state) do
    state = %{state | looking: false}
    for row <- settling(state, :all, "dialog"), do: settle_row(state, row, false)
    {:noreply, look_later(state)}
  end

  # A worktree's task answered: the start goes on to the hold, or is refused with nothing held.
  def handle_info({ref, prepared}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Enum.find(state.pending, fn {_, pending} -> pending[:task] == ref end) do
      nil ->
        {:noreply, state}

      {name, pending} ->
        pending = Map.delete(pending, :task)

        case prepared do
          {how, :ok} ->
            write(state, pending.row, worktree: how)
            {:noreply, hold_and_view(state, name, %{pending | kind: :start})}

          {how, {_, reason}} ->
            write(state, pending.row, status: "refused", reason: reason, worktree: how)
            {:noreply, done(state, name, pending, {:refused, reason})}
        end
    end
  end

  # Held: held, or unknown (a process may have started), and the start waits for the file
  # either way; ViewerOpened then leaves the call waiting. Only a refusal ends it here.
  defp hold_and_view(state, name, %{row: row} = pending) do
    case hold(state, pending.way, name, row.cwd) do
      {:refused, reason} = refused ->
        write(state, row, status: "refused", reason: reason)
        done(state, name, pending, refused)

      :held ->
        write(state, row, viewer: open_viewer(state, name, pending.viewer))
        send(self(), {:check, name})
        put_in(state.pending[name], pending)
    end
  end

  # StartDecided: running when the file names the live process. With no file yet, an
  # interactive start's pane is read: a startup dialog the app's callback leaves to a person
  # answers the call at once, and the row waits (Dialog.tla's Read and Callback). Past the
  # deadline, a dialog on the pane, read in the same step, keeps the row waiting (Deadline);
  # anything else is unknown.
  defp check(state, name, %{kind: :start, row: row} = pending) do
    case confirm(state, row, true) do
      {:ok, file} ->
        running(state, row, file)
        answer = %{name: name, pid: file.pid, session_id: file.session_id}
        done(state, name, pending, {:ok, answer})

      _ ->
        case look_at(state, row) do
          {:ask, kind} ->
            state |> done(name, pending, {:unknown, {:dialog, kind}}) |> look_later()

          _ ->
            wait(state, name, pending, fn -> late(state, row) end)
        end
    end
  end

  # StopSettled within the call: stopped once the process is gone and its socket is dead, as
  # dtach removes it a moment after the exit, so a resume after the answer is not refused
  # `{:live, name}`. StopTimedOut leaves the row stopping: late (no_exit) for Recoveries when
  # the process lives; with it gone and the socket not read as dead, for the next settle.
  defp check(state, name, %{kind: :stop, row: row} = pending) do
    gone? = liveness(state, row) in [:gone, :replaced]

    if gone? and dead?(state, row) do
      write(state, row, status: "stopped")
      done(state, name, pending, {:ok, :stopped})
    else
      wait(state, name, pending, fn ->
        why = if gone?, do: :socket_live, else: :no_exit
        write(state, row, reason: Atom.to_string(why))
        {:unknown, {why, pending.sent}}
      end)
    end
  end

  defp check(state, name, %{kind: :ask} = pending), do: ask(state, name, pending)

  # The start's deadline with no session file: a row on a dialog waits on a person.
  defp late(state, row) do
    look_at(state, row)

    case Table.get(state.db, row.host, row.name) do
      %{status: "dialog"} = now ->
        {:unknown, {:dialog, Dialog.shown(now).kind}}

      _ ->
        why = unconfirmed(row)
        write(state, row, status: "unknown", reason: why)
        {:unknown, why}
    end
  end

  # Reads an interactive start's pane (Dialog.tla's Read): a startup dialog becomes the row's,
  # with a cue, and the app's callback is asked once for its kind. Answers `{:ask, kind}` when
  # the dialog waits on a person, `:pressed` when an answer to it went or was tried, or `:none`.
  defp look_at(%{inlet: nil}, _row), do: :none
  defp look_at(_state, %{role: role}) when role != "parent", do: :none

  defp look_at(state, row) do
    with {:ok, screen} <- Inlet.look(state.inlet, row.name, row.release, timeout: @read),
         true <- Dialog.startup?(screen) do
      now = Table.get(state.db, row.host, row.name) || row
      shown = Dialog.encode(screen)

      if now.status != "dialog" or Dialog.shown(now) != shown,
        do: write(state, now, status: "dialog", reason: nil, dialog: shown)

      now = Table.get(state.db, row.host, row.name)
      decide(state, now, screen)
    else
      _ -> :none
    end
  end

  # The app's callback, for a dialog no answer has been marked for: an answer it gives is
  # pressed, as a person's is; anything else leaves the dialog to a person.
  defp decide(state, row, %{kind: kind, options: options}) do
    if Dialog.answers(row)[kind] do
      :pressed
    else
      with {:answer, label} <- state.dialog.(kind, options),
           :ok <- Dialog.check(row, kind, label) do
        press(state, row, kind, label)
        :pressed
      else
        _ -> {:ask, kind}
      end
    end
  end

  # Dialog.tla's Take and Press: the answer marked pressing on the row first, then the Inlet's
  # checked press; sent or unknown stays marked, and only a refusal, which pressed nothing,
  # takes the mark away.
  defp press(%{inlet: nil}, _row, _kind, _label), do: {:refused, :no_inlet}

  defp press(state, row, kind, label) do
    write(state, row, answers: Dialog.mark(row, kind, label, "pressing"))
    row = Table.get(state.db, row.host, row.name)

    answer =
      Inlet.choose(state.inlet, row.name, kind, label, release: row.release, timeout: @press)

    mark =
      case answer do
        {:ok, :sent} -> "sent"
        {:refused, _} -> nil
        {:unknown, _} -> "unknown"
      end

    write(state, row, answers: Dialog.mark(row, kind, label, mark))
    answer
  end

  # One read of the waiting rows' panes `look` ms from now, while any row waits on a person.
  defp look_later(%{looking: true} = state), do: state

  defp look_later(state) do
    if Table.with_status(state.db, state.host.name, "dialog") == [] do
      state
    else
      Process.send_after(self(), :look, state.look)
      %{state | looking: true}
    end
  end

  defp unconfirmed(%{role: "delegate"}), do: :no_first_event
  defp unconfirmed(_row), do: :no_session_file

  defp wait(state, name, pending, late) do
    if state.clock.() >= pending.deadline do
      done(state, name, pending, late.())
    else
      Process.send_after(self(), {:check, name}, state.poll)
      state
    end
  end

  defp done(state, name, pending, answer) do
    if pending[:act], do: Acts.answered(state.acts, pending.act, answer)
    GenServer.reply(pending.from, answer)
    %{state | pending: Map.delete(state.pending, name)}
  end

  # Settles each row of `which` (`:all`, `{:account, name}` or `:delegates`) with no call under
  # way. `read?` reads the Registry or Stream first; on a reader's cue its rows are fresh.
  defp settle(state, which, read?) do
    for status <- ~w(starting dialog unknown stopping orphan),
        row <- settling(state, which, status),
        do: settle_row(state, row, read?)

    settle_running(state, settling(state, which, "running"))
  end

  defp settling(state, which, status) do
    for row <- Table.with_status(state.db, state.host.name, status),
        which in [:all, {:account, row.account}] or (which == :delegates and delegate?(row)),
        not Map.has_key?(state.pending, row.name),
        do: row
  end

  defp delegate?(row), do: row.role == "delegate"

  # Adopt: a starting row waits for its deadline before it is given up, and a failed read
  # decides nothing.
  defp settle_row(state, %{status: "starting"} = row, read?) do
    past? = state.clock.() >= (row.deadline || 0)

    case confirm(state, row, read?) do
      {:ok, file} ->
        running(state, row, file)

      # A pane on a startup dialog waits on a person, never an orphan (Dialog.tla's Deadline).
      {:live, why} when past? ->
        if look_at(state, row) == :none, do: orphan_held(state, row, why)

      {:unheld, file} when past? ->
        orphan(state, row, file)

      # Remove first: a restart in between leaves the row starting, decided again.
      {:dead, _} when past? ->
        worktree = remove(state, row)
        write(state, row, status: "refused", reason: "interrupted", worktree: worktree)

      _unknown_or_early ->
        :ok
    end
  end

  # A row on a startup dialog: running once its file names its live process, as a start's
  # confirm makes it; stopped once its socket is dead with no such file ("No, exit"); else its
  # pane is read again, and the next dialog becomes the row's.
  defp settle_row(state, %{status: "dialog"} = row, read?) do
    case confirm(state, row, read?) do
      {:ok, file} -> running(state, row, file)
      {:unheld, file} -> orphan(state, row, file)
      {:dead, _} -> write(state, row, status: "stopped")
      _ -> look_at(state, row)
    end
  end

  # ReRead: an unknown row is running once its file names its live process, an orphan while
  # that process runs on a dead socket, and stopped once its socket is dead with no such file.
  defp settle_row(state, %{status: "unknown"} = row, read?) do
    case confirm(state, row, read?) do
      {:ok, file} -> running(state, row, file)
      {:unheld, file} -> orphan(state, row, file)
      {:dead, _} -> write(state, row, status: "stopped")
      _ -> :ok
    end
  end

  # StopSettled with no stop under way: stopped once its process is gone by pid and start time
  # and its socket is dead; running while it lives, unless the stop was late (no_exit).
  defp settle_row(state, %{status: "stopping"} = row, _read?) do
    case liveness(state, row) do
      gone when gone in [:gone, :replaced] ->
        if dead?(state, row), do: write(state, row, status: "stopped")

      :live when row.reason != "no_exit" ->
        write(state, row, status: "running")

      _late_or_unknown ->
        :ok
    end
  end

  # An orphan whose process exited or Recoveries ended: stopped (reason ended) once that
  # process is gone by its pid and start time and its socket is dead, so its name is free. One
  # with no pid is judged by the held program's record alone.
  defp settle_row(state, %{status: "orphan", pid: pid} = row, _read?) when is_integer(pid) do
    if liveness(state, row) in [:gone, :replaced] and dead?(state, row),
      do: write(state, row, status: "stopped", reason: "ended")
  end

  defp settle_row(state, %{status: "orphan"} = row, _read?) do
    case held(state, row) do
      {:ok, reading} ->
        if Holder.Process.dead?(reading),
          do: write(state, row, status: "stopped", reason: "ended")

      _ ->
        :ok
    end
  end

  # RunningSettled: a running row whose process exited by itself is stopped, with reason
  # exited, once that process is gone by pid and start time and its socket is read as dead; a
  # pid another program took counts as gone. One ps for every row, and a socket read only for
  # a row whose process is gone. A read that fails, or a socket dtach has not removed yet,
  # decides nothing: the sampler's cue when the socket goes reads again. A row it decides
  # nothing for, because a read failed or the socket lives, is said once in a debug line, so a
  # test (or a person) reads why a row stayed running.
  defp settle_running(state, rows) do
    {rows, unnamed} = Enum.split_with(rows, &(is_integer(&1.pid) and is_binary(&1.proc_start)))
    Enum.each(unnamed, &undecided(&1, "the row has no pid and start time"))
    alive = alive(state, rows)

    for row <- rows do
      case alive[{row.pid, row.proc_start}] do
        gone when gone in [:gone, :replaced] ->
          socket = Holder.state(state.holder, row.socket)

          if dead?(socket),
            do: write(state, row, status: "stopped", reason: "exited"),
            else: undecided(row, "process #{gone}, socket #{inspect(socket)}")

        :live ->
          :ok

        other ->
          undecided(row, "process #{inspect(other)}")
      end
    end

    :ok
  end

  defp undecided(row, why),
    do: Logger.debug("sessions: settle of running #{row.name} decided nothing: #{why}")

  # A socket read as dead: absent, or stale once dtach was killed. A read that fails is not.
  defp dead?(state, row), do: dead?(Holder.state(state.holder, row.socket))
  defp dead?({:ok, dead}) when dead in [:absent, :stale], do: true
  defp dead?(_), do: false

  # A live socket past its start's deadline: an orphan with the held program's record, for
  # Recoveries. A record that is not read leaves the row with no pid: nothing ends it by one.
  defp orphan_held(state, row, why) do
    case held(state, row) do
      {:ok, %{process: :live, record: record}} ->
        write(state, row,
          status: "orphan",
          reason: why,
          pid: record.pid,
          proc_start: record.start
        )

      _ ->
        write(state, row, status: "orphan", reason: why)
    end
  end

  # A process that runs on a dead socket, with the pid and start time of the file (or a
  # delegate's record) that names it, for Recoveries.
  defp orphan(state, row, file),
    do:
      write(state, row,
        status: "orphan",
        reason: "unheld",
        pid: file.pid,
        proc_start: file.proc_start
      )

  # Confirms a delegate: its socket is live and its record names a process that runs with its
  # pid and start time, and Stream has read the init naming its session id. The record is
  # written before claude starts, so it is this process's. A dead socket while that process
  # runs on is `{:unheld, record}`: its dtach was killed hard.
  defp confirm(state, %{role: "delegate"} = row, read?) do
    case held(state, row) do
      {:ok, %{socket: :live, process: :live, record: record}} ->
        case followed(state, row, read?) do
          {:ok, %{session_id: id}} when id == row.session_id -> {:ok, file_of(row, record)}
          {:ok, _} -> {:live, :no_first_event}
          :unread -> {:unknown, :unread}
          {_, reason} -> {:unknown, reason}
        end

      {:ok, %{socket: :live}} ->
        {:live, :no_first_event}

      {:ok, %{socket: dead, process: :live, record: record}} when dead in [:absent, :stale] ->
        {:unheld, file_of(row, record)}

      {:ok, %{socket: dead} = reading} when dead in [:absent, :stale] ->
        if Holder.Process.dead?(reading), do: {:dead, dead}, else: {:unknown, {:held, reading}}

      {:ok, reading} ->
        {:unknown, {:held, reading}}

      other ->
        other
    end
  end

  # Confirms: the session file of a live process with the session's name, while its socket is
  # live. A dead socket while that file names a live process is `{:unheld, file}`: its dtach
  # was killed hard and the process runs on. `{:dead, _}` only for a dead socket with no such
  # file; any read that fails is `{:unknown, _}`.
  defp confirm(state, row, read?) do
    with {:ok, socket} <- Holder.state(state.holder, row.socket),
         {:ok, registry} <- registry(state),
         {:ok, _} <- if(read?, do: Registry.read(registry), else: {:ok, :cued}),
         {:ok, %{rows: files}} <- Registry.rows(registry, row.account) do
      named = Enum.filter(files, &(&1.name == row.name))
      file = Enum.find(named, &(&1.alive == :live))

      cond do
        file && socket == :live -> {:ok, file}
        file -> {:unheld, file}
        Enum.any?(named, &(&1.alive == :unknown)) -> {:unknown, :liveness}
        socket == :live -> {:live, :no_session_file}
        true -> {:dead, socket}
      end
    else
      :error -> {:unknown, :no_registry}
      :unread -> {:unknown, :unread}
      {_, reason} -> {:unknown, reason}
    end
  end

  defp file_of(row, record),
    do: %{pid: record.pid, proc_start: record.start, session_id: row.session_id}

  defp registry(%{registry: nil}), do: :error
  defp registry(%{registry: registry}), do: {:ok, registry}

  # A pid that `ps` lists with another start time was reused: the held process exited.
  defp liveness(state, row), do: alive(state, [row])[{row.pid, row.proc_start}]

  defp alive(state, rows) do
    opts = [env: state.ps.env, ps: state.ps.ps, timeout: 5_000]
    Holder.Process.liveness(state.host, Enum.map(rows, &{&1.pid, &1.proc_start}), opts)
  end

  defp running(state, row, file) do
    fields = [pid: file.pid, session_id: file.session_id, proc_start: file.proc_start]
    write(state, row, [status: "running", reason: nil] ++ fields)
  end

  defp free(state, name) do
    case Table.get(state.db, state.host.name, name) do
      nil ->
        :ok

      %{status: status} = row ->
        if Agents.free?(row), do: :ok, else: {:refused, {:exists, status}}
    end
  end

  # The agent row's kind, parent and project, checked before the row: a resume keeps the row's
  # unless the launch names them, and any start keeps a project the row has (a declared main).
  defp agent(state, name, role, launch, place, resume) do
    row = Table.get(state.db, state.host.name, name)
    kind = launch[:kind] || (resume && kind_of(row)) || default_kind(role)
    parent = Keyword.get(launch, :parent, resume && row && row.parent)
    tree_project = place.tree && place.tree.project.name
    project = launch[:project] || tree_project || (row && row.project)

    case {kind, parent} do
      {:delegate, p} when is_binary(p) and p != "" ->
        {:ok, %{kind: "delegate", parent: p, project: project}}

      {:delegate, _} ->
        {:refused, {:missing, :parent}}

      {:main, nil} ->
        {:ok, %{kind: "main", parent: nil, project: project}}

      {:main, _} ->
        {:refused, {:bad, :parent}}

      _ ->
        {:refused, {:bad, :kind}}
    end
  end

  defp kind_of(%{kind: "main"}), do: :main
  defp kind_of(%{kind: "delegate"}), do: :delegate
  defp kind_of(_), do: nil

  defp default_kind(:delegate), do: :delegate
  defp default_kind(_role), do: :main

  # Where a start runs: the directory it is given, or its worktree's path, which RowWritten
  # first checks no other row that has not ended holds.
  defp place(state, name, launch) do
    case Keyword.fetch(launch, :worktree) do
      :error ->
        with {:ok, cwd} <- cwd(launch), do: {:ok, %{cwd: cwd, tree: nil}}

      {:ok, %{project: project, branch: branch}} ->
        with {:ok, project} <- Worktree.project(project),
             :ok <- Worktree.branch(branch),
             true <- Worktree.name?(name) or {:refused, {:bad, :name}},
             {:ok, root} <- state.worktrees,
             {:ok, _} <- state.git,
             true <- state.reaper != nil or {:refused, :no_reaper},
             path = Worktree.path(root, project, name),
             [] <- Table.holding(state.db, state.host.name, path, name) do
          {:ok, %{cwd: path, tree: %{project: project, branch: branch}}}
        else
          [_ | _] = rows -> {:refused, {:held, Enum.map(rows, & &1.name)}}
          failed -> failed
        end

      {:ok, _} ->
        {:refused, {:bad, :worktree}}
    end
  end

  defp cwd(launch) do
    case Keyword.get(launch, :cwd) do
      "/" <> _ = cwd -> {:ok, cwd}
      nil -> {:refused, {:missing, :cwd}}
      _ -> {:refused, {:bad, :cwd}}
    end
  end

  defp required(:error, key), do: {:refused, {:missing, key}}
  defp required(ok, _key), do: ok

  # The release the start launches, or nil when it cannot be read: no typed write then goes in.
  defp release(state, :parent, launch) do
    with "/" <> _ = claude <- launch[:claude],
         {:ok, %{status: 0, output: out}} <-
           Shell.run(state.host, claude, ["--version"], timeout: @version),
         [_, release] <- Regex.run(~r/\A(\d+\.\d+\.\d+) /, out) do
      release
    else
      _ -> nil
    end
  end

  defp release(_state, _role, _launch), do: nil

  defp cli(role, account, name, resume, launch, own) do
    opts = Keyword.take(launch, [:claude, :model, :env, :tool_timeout, :prompt, :mcp])
    opts = opts ++ [name: name] ++ own
    opts = if resume, do: opts ++ [resume: resume], else: opts
    ClaudeCLI.session(role, account, opts)
  end

  # The model a start launches: the launch's, or on a resume that names none, its row's (F-133's
  # new-3), so a resume another part makes needs not know it.
  defp model(state, name, resume, launch) do
    with true <- resume != nil and launch[:model] == nil,
         %{model: model} when is_binary(model) <- Table.get(state.db, state.host.name, name) do
      Keyword.put(launch, :model, model)
    else
      _ -> launch
    end
  end

  # The agent's own options, before its row: the launch's, or on a resume that names none, its
  # row's. A start refused after the overlay's write leaves the file for the next to rewrite.
  # An interactive session's waiter hook goes into its overlay beside the agent's own settings;
  # the row keeps only the agent's own options, so a resume adds the hook again.
  defp own(state, role, account, name, resume, launch, hooks \\ nil) do
    row =
      resume && not Keyword.has_key?(launch, :options) &&
        Table.get(state.db, state.host.name, name)

    given = if row, do: Options.decode(row.options), else: Options.check(launch[:options])

    with {:ok, options} <- given,
         s = with_hooks(options[:settings], hooks),
         {:ok, file} <- if(s, do: Accounts.overlay(account, role, name, s), else: {:ok, nil}),
         do: {:ok, options, [options: options] ++ if(file, do: [settings: file], else: [])}
  end

  defp with_hooks(settings, nil), do: settings
  defp with_hooks(settings, hooks), do: Map.put(settings || %{}, "hooks", hooks)

  defp waiter(_programs, nil), do: {:ok, nil}

  defp waiter(programs, %{port: port, secret: secret}) do
    with {:ok, paths} <- Programs.take(programs, [:sh, :curl]),
         do: {:ok, %{port: port, secret: secret, paths: paths}}
  end

  defp waiter(_programs, other), do: {:refused, {:bad, {:waiter, other}}}

  defp waiter_hooks(%{waiter: nil}, _account), do: {:ok, nil}

  defp waiter_hooks(%{waiter: w}, account),
    do: Intake.waiter_hook(w.port, account.name, w.secret, w.paths)

  # What a start holds, checked before its row is written: an interactive session's own
  # command, or a headless delegate's with the session id the framework chose ("Headless
  # delegates"), which a resume keeps.
  defp way(state, :delegate, account, name, cwd, resume, launch) do
    id = resume || Stream.uuid()
    start = if resume, do: [resume: id], else: [session_id: id]
    keys = [:claude, :model, :env, :tool_timeout, :mcp]

    # The id names the delegate's directory, so a resume's is a plain id, never a path.
    with {:ok, stream} <- if(state.stream && state.home, do: {:ok, state.stream}, else: :error),
         true <- id =~ ~r/\A[A-Za-z0-9_-]{1,64}\z/ or {:refused, {:bad, :session_id}},
         {:ok, options, own} <- own(state, :delegate, account, name, resume, launch),
         {:ok, cli} <- ClaudeCLI.headless(account, Keyword.take(launch, keys) ++ start ++ own),
         {:ok, transcript} <- Transcripts.path(account.config_dir, cwd, id) do
      {:ok, %{stream: stream, session_id: id, cli: cli, transcript: transcript, options: options}}
    else
      :error -> {:refused, :no_stream}
      refused -> refused
    end
  end

  # An interactive session's first prompt (Delivery's launch transport) is not in its argv: the
  # hold's wrapper reads it from a file into the last argument (`ClaudeCLI.prompted/5`).
  defp way(state, role, account, name, _cwd, resume, launch) do
    with {:ok, prompt} <- prompt(state, launch[:prompt]),
         {:ok, hooks} <- waiter_hooks(state, account),
         {:ok, options, own} <- own(state, role, account, name, resume, launch, hooks),
         {:ok, cli} <- cli(role, account, name, resume, Keyword.delete(launch, :prompt), own),
         do: {:ok, %{cli: cli, options: options, prompt: prompt}}
  end

  defp prompt(_state, nil), do: {:ok, nil}

  defp prompt(state, prompt) when is_binary(prompt) and prompt != "" do
    cond do
      byte_size(prompt) > ClaudeCLI.prompt_max() -> {:refused, {:too_long, :prompt}}
      not String.valid?(prompt) -> {:refused, {:bad, :prompt}}
      not match?({:ok, _}, state.cat) -> {:refused, {:no_program, :cat}}
      true -> {:ok, prompt}
    end
  end

  defp prompt(_state, _prompt), do: {:refused, {:bad, :prompt}}

  # The start's row before it has an id.
  defp new_row(state, name, account, role, place, resume, way, deadline, launch) do
    %{
      host: state.host.name,
      name: name,
      socket: name,
      account: account.name,
      role: Atom.to_string(role),
      cwd: place.cwd,
      resume: resume,
      deadline: deadline,
      session_id: way[:session_id],
      options: Options.encode(way.options),
      model: launch[:model],
      repo: place.tree && place.tree.project.repo,
      branch: place.tree && place.tree.branch
    }
  end

  # What a worktree's commands run with, handed to its task.
  defp runner(state) do
    {:ok, git} = state.git
    %{host: state.host, env: state.ps.env, git: git, sh: state.holder.sh, reaper: state.reaper}
  end

  # Checked, Added and the setup (SetupStarts, SetupEnds). Runs in the start's task. Answers
  # what the start did with the tree (nil before it had one) and the setup's outcome.
  defp prepare(run, %{project: project, branch: branch}, path, resume?) do
    with {:ok, list} <- git(run, project, :list),
         listed = Worktree.listed(list, path),
         {:ok, status} <- status(run, project, listed, branch, path),
         how when how in [:add, :reuse] <- Worktree.decide(listed, status, branch, resume?),
         :ok <- add(run, project, how, path, branch) do
      {if(how == :add, do: "added", else: "reused"), setup(run, project, path)}
    else
      failed -> {nil, failed}
    end
  end

  # `git status` only of a tree listed on the branch: nothing else is reused or removed.
  defp status(run, project, {:branch, branch}, branch, path),
    do: git(run, project, {:status, path})

  defp status(_run, _project, _listed, _branch, _path), do: {:ok, nil}

  # The list read again, not the add's exit status or the branch, says what the add did: a
  # failing post-checkout hook makes the add exit 1 with the tree in place, and `-b` at a taken
  # path fails and still leaves its branch behind.
  defp add(_run, _project, :reuse, _path, _branch), do: :ok

  defp add(run, project, :add, path, branch) do
    with {:ok, exists?} <- branch?(run, project, branch) do
      added = git(run, project, {:add, path, branch, exists?})

      with {:ok, list} <- git(run, project, :list) do
        cond do
          Worktree.listed(list, path) == {:branch, branch} -> :ok
          match?({:ok, _}, added) -> {:refused, {:worktree, :not_listed}}
          true -> {:refused, {:worktree, {:add, elem(added, 1)}}}
        end
      end
    end
  end

  defp branch?(run, project, branch) do
    case shell(run, ["-i", run.git | Worktree.git(project, {:branch?, branch})], @git) do
      {:ok, %{status: 0}} -> {:ok, true}
      {:ok, %{status: 1}} -> {:ok, false}
      {:ok, %{status: status, output: out}} -> {:refused, {:git, :branch?, status, tail(out)}}
      other -> other
    end
  end

  # Each command in the tree, under one deadline for the whole setup; a timeout ends its group.
  defp setup(run, project, path) do
    deadline = System.monotonic_time(:millisecond) + project.setup_timeout

    Enum.reduce_while(project.setup, :ok, fn [program | _] = command, :ok ->
      left = deadline - System.monotonic_time(:millisecond)
      args = Worktree.env_args(project) ++ [run.sh, "-c", @cd, path | command]

      case left > 0 && shell(run, args, left) do
        {:ok, %{status: 0}} -> {:cont, :ok}
        {:ok, %{status: s, output: out}} -> {:halt, {:refused, {:setup, program, s, tail(out)}}}
        false -> {:halt, {:refused, {:setup, :timeout}}}
        {:unknown, {:timeout, _}} -> {:halt, {:refused, {:setup, :timeout}}}
        {_, reason} -> {:halt, {:refused, {:setup, reason}}}
      end
    end)
  end

  # Remove, after a restart: the tree of a row refused as interrupted, when it is listed on the
  # row's branch, clean and held by no other row. `git worktree remove` without --force refuses
  # a dirty tree itself. Any read that fails keeps the tree. Answers what the row says of it.
  defp remove(state, %{branch: branch, repo: repo, cwd: path} = row) when is_binary(branch) do
    project = %{repo: repo}

    with {:ok, _} <- state.git,
         run = runner(state),
         {:ok, list} <- git(run, project, :list),
         listed = Worktree.listed(list, path),
         {:ok, status} <- status(run, project, listed, branch, path),
         held? = Table.holding(state.db, state.host.name, path, row.name) != [],
         :remove <- Worktree.removal(listed, status, branch, held?),
         {:ok, _} <- git(run, project, {:remove, path}) do
      "removed"
    else
      {:keep, why} -> "kept: #{why}"
      {_, reason} -> "kept: " <> Store.text(reason)
    end
  end

  defp remove(_state, _row), do: nil

  defp git(run, project, command) do
    case shell(run, ["-i", run.git | Worktree.git(project, command)], @git) do
      {:ok, %{status: 0, output: out}} ->
        {:ok, out}

      {:ok, %{status: status, output: out}} ->
        name = if is_tuple(command), do: elem(command, 0), else: command
        {:refused, {:git, name, status, tail(out)}}

      other ->
        other
    end
  end

  # Through the host's env, so git and the setup start from an empty environment.
  defp shell(run, args, timeout),
    do: Shell.run(run.host, run.env, args, timeout: timeout, reaper: run.reaper)

  defp tail(out), do: String.slice(out, -min(String.length(out), 200), 200)

  # The worktrees' root, made, as a physical path; a failure refuses worktree starts only.
  defp root(_host, _sh, _programs, nil), do: {:refused, :no_home}

  defp root(host, sh, programs, home) do
    args = ["-c", @root, "sh", Path.join(home, "worktrees")]

    with {:ok, mkdir} <- Programs.fetch(programs, :mkdir),
         {:ok, %{status: 0, output: "/" <> _ = out}} <-
           Shell.run(host, sh, args ++ [mkdir], timeout: @git) do
      {:ok, String.trim_trailing(out, "\n")}
    else
      {:ok, %{status: status, output: out}} -> {:refused, {:worktrees, status, tail(out)}}
      other -> other
    end
  end

  # The command of a row's viewer, the one `viewer_argv/3` answers: a delegate's follows its
  # event log (`-F`, since the wrapper has not opened it yet when the viewer starts), any other
  # session's is `dtach -a` of its socket.
  defp viewer_command(state, %{role: "delegate", session_id: id}) when is_binary(id) do
    if state.home,
      do: {:ok, [state.ps.tail, "-F", Path.join(Stream.dir(state.home, id), "events.jsonl")]},
      else: {:refused, :no_stream}
  end

  defp viewer_command(_state, %{role: "delegate"}), do: {:refused, {:missing, :session_id}}
  defp viewer_command(state, %{socket: socket}), do: Holder.viewer_argv(state.holder, socket)

  # A delegate's directory and FIFO come before its hold: a follow that fails holds nothing.
  defp hold(state, way, name, cwd) do
    with {:ok, argv} <- prepare(state, way, name) do
      argv = [state.holder.sh, "-c", @cd, cwd | argv]

      case Holder.Process.hold(state.procs, name, argv, env: way.cli.env) do
        {:refused, _} = refused ->
          refused

        {:ok, _} ->
          told(way)
          :held

        _unknown ->
          :held
      end
    end
  end

  # HeldTold: a delegate's exit is seen from now on, even before a read finds it live. Only a
  # hold that answered held tells: after an unknown one, a process may start later, and Stream
  # waits to see it live. A tell that fails leaves that to the read as well.
  defp told(%{stream: stream, session_id: id}), do: Stream.held(stream, id, timeout: @stream)
  defp told(_way), do: :ok

  defp prepare(state, %{stream: stream} = way, name) do
    case Stream.follow(stream, way.session_id, name, way.transcript, timeout: @stream) do
      {:ok, %{dir: dir, fifo: fifo}} ->
        {:ok, ClaudeCLI.wrapper(state.holder.sh, dir, fifo, way.cli.argv)}

      {_, reason} ->
        {:refused, {:follow, reason}}
    end
  end

  # The prompt's file, beside the dtach socket and owned by this user alone; the wrapper removes
  # it once read. A file a hold that failed left is written over by the next start of the name.
  defp prepare(state, %{prompt: prompt} = way, name) when is_binary(prompt) do
    file = Path.join(state.holder.dir, name <> ".prompt")
    {:ok, cat} = state.cat

    with :ok <- File.write(file, prompt),
         :ok <- File.chmod(file, 0o600) do
      {:ok, ClaudeCLI.prompted(state.holder.sh, cat, state.holder.rm, file, way.cli.argv)}
    else
      {:error, reason} -> {:refused, {:prompt_file, reason}}
    end
  end

  defp prepare(_state, way, _name), do: {:ok, way.cli.argv}

  # Stream's row of the delegate, read first when `read?`.
  defp followed(state, row, read?) do
    with true <- state.stream != nil or {:unknown, :no_stream},
         {:ok, _} <-
           if(read?, do: Stream.read(state.stream, timeout: @stream), else: {:ok, :cued}),
         {:ok, %{rows: rows}} <- Stream.rows(state.stream, timeout: @stream) do
      case Enum.find(rows, &(&1.session == row.session_id)) do
        nil -> {:unknown, :not_followed}
        followed -> {:ok, followed}
      end
    end
  end

  # The held program's record and its socket, read together (`Holder.Process.read/3`).
  defp held(state, row) do
    socket = row.socket

    case Holder.Process.read(state.procs, [socket]) do
      {:ok, %{^socket => reading}} -> {:ok, reading}
      other -> other
    end
  end

  defp open_viewer(state, name, argv) do
    case viewer(state.tmux, name, argv, state.size) do
      {:ok, _pane} -> "open"
      failed -> failed
    end
  end

  @doc """
  Opens a viewer of held session `name` on tmux server `tmux`: a tmux session of that name running
  `argv` (`viewer_argv/3`'s answer), tagged as it opens, one row short of `{columns, rows}`, then
  grown, since Claude Code redraws only when its size changes. tmux starts its server when it is
  down. `Recoveries` reopens a lost viewer with it. Answers `{:ok, pane}`, or `Tmux`'s
  refusal or unknown; a pane that opened and was not grown is `{:unknown, {:resize, pane, why}}`.
  """
  @spec viewer(Tmux.server(), String.t(), [String.t()], {pos_integer, pos_integer}) ::
          outcome(String.t())
  def viewer(tmux, name, argv, {columns, rows}) do
    with {:ok, pane} <- Tmux.new_session(tmux, name, argv, size: {columns, rows - 1}) do
      case Tmux.resize_pane(tmux, pane, name, {columns, rows}) do
        {:ok, :resized} -> {:ok, pane}
        failed -> {:unknown, {:resize, pane, failed}}
      end
    end
  end

  defp write(state, row, fields) do
    Table.update(state.db, row.id, fields)
    announce(state, row)
  end

  defp announce(state, row), do: state.notify.(%{topic: topic(state), ids: [row.id]})

  defp topic(state), do: "sessions:#{state.host.name}"
end
