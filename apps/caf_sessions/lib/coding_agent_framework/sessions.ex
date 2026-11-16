defmodule CodingAgentFramework.Sessions do
  @moduledoc """
  One host's session lifecycle: starts, resumes and stops Claude Code sessions, each held by
  dtach with a viewer pane, and keeps a row for each in `CodingAgentFramework.Sessions.Table`,
  which it alone writes. A session runs in the directory it is given, or in a worktree of a
  project that its start checks, adds and sets up.

  The caller's supervision tree starts one `Sessions` per host, with no name, and gives it the
  host's `Programs`, its dtach directory, its `Control`, a `Registry` per account and the SQLite
  path:

      {:ok, sessions} = Sessions.start_link(programs: programs, dir: "/srv/caf/dtach",
        control: control, registries: %{"work" => registry}, db: "/srv/caf/caf.db")
      {:ok, account} = Accounts.ready(accounts, "work")
      Sessions.start(sessions, "main", account,
        role: :parent, cwd: "/src/app", claude: claude, model: "opus", env: env,
        tool_timeout: 3_600_000)
      #=> {:ok, %{name: "main", pid: 4242, session_id: "…"}}

  A host that runs delegates also gives it its `Stream` and the framework home (`stream:`,
  `home:`).

  **A start** (`docs/design.md`, "The delegate protocol") writes its row first, as `starting`,
  with the socket name and the session's name, which are one name. Then it holds
  `ClaudeCLI.session/3`'s argv and environment through `Holder.hold/4`, in the given directory,
  and opens a viewer pane (`dtach -a`, as `viewer_argv/3` answers) through `Control`, tagged
  with the session as it opens: one row short, then grown, since Claude Code does not redraw
  for a viewer that attaches at its own size. A viewer that fails leaves the session running;
  its row's `viewer` says why. The start is confirmed when the account's `Registry` reads a
  session file with the session's name (`--name`) whose pid lives, and the socket is live. The
  pid comes from that file, since dtach does not report it. **A resume** is the same with
  `--resume <id>`.

  **A delegate** (role `:delegate`) runs headless ("Headless delegates"): after its row, which
  keeps the session id the framework chose, `Stream.follow/5` makes its directory and FIFO under
  `<home>/streams/<session id>/`, then `ClaudeCLI.headless/2`'s argv is held inside
  `ClaudeCLI.wrapper/4` on the FIFO the follow answered, `Stream.held/3` tells `Stream` the
  process was held, and its viewer is a pane running `tail -F` of its event log (the
  renderer is a later unit; `-F` waits for a log the wrapper has not opened yet; again
  `viewer_argv/3`'s answer). Its start is confirmed when `Stream` has read a `system`/`init`
  naming the session id, the pid the wrapper recorded lives with the start time `ps` gives, and
  the socket is still live after that `ps`.
  The init comes after the wrapper wrote the pid, so that pid is this process's. A resume
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

  **A stop** types `/exit` through `Control`'s checked write, then waits until the process the
  row names exits, judged by `{pid, procStart}` (`Registry.Liveness`), never by name, and its
  socket is dead, so a resume after the answer is never refused `{:live, name}`. `/exit`
  must be typed only when the turn has ended and the input box is empty. Reading that from the
  screen is `Screen`'s job, which is not built: the caller says the turn has ended, and any
  other answer is refused. A delegate's stop writes `end_session` through `Stream` instead, once
  the caller says its report is delivered, and its turn is `Stream`'s row's, not the caller's:
  `Stream` refuses the end while a turn runs or a message has not gone in.

  Each call answers `{:ok, …}`, `{:refused, reason}` or `{:unknown, reason}` within its
  `:timeout` (30 s by default, plus the hold's and the viewer's own bounds). Nothing is retried:
  a start that is not confirmed in time answers `{:unknown, :no_session_file}` (a delegate's,
  `{:unknown, :no_first_event}`), and its row says `unknown` with that reason. A hold that answers unknown still waits for the file. A stop whose
  process is alive at its deadline answers `{:unknown, {:no_exit, typed}}` and leaves the row
  `stopping` with reason `no_exit`: `Recoveries` ends that process by its pid and start time.
  One whose process is gone while its socket is still live answers
  `{:unknown, {:socket_live, typed}}`, and the row, reason `socket_live`, waits for the next
  settle.
  `Sessions` itself never kills. The row keeps the start's or stop's deadline in wall-clock time
  (the `clock:` option), so a restart does not move it.

  **Rows with no call under way** are settled as `model/tla/Start.tla` does, when `Sessions`
  starts, at a starting row's deadline, and at each `Registry`, `Stream` or `TmuxSampler` cue
  that `cue/2` hands it. A socket ends apart from its process: dtach removes it a moment after
  the process exits, and a dtach killed hard leaves it stale while the process may run on.
  "Confirmed" is a delegate's first event and recorded pid, as above; "unheld" is a dead socket
  while the session file (a delegate's recorded pid) names a live process:

  - `starting` (left by a restart): `running` when confirmed; past its deadline, `orphan` for a
    live socket or an unheld process (reason `unheld`, with the file's pid and start time), and
    `refused{interrupted}` for a dead socket otherwise;
  - `unknown`: `running` when confirmed, `orphan` when unheld, `stopped` when its socket is
    dead otherwise;
  - `stopping`: `stopped` when its process is gone by pid and start time and its socket is
    dead; when it lives, `running` after a restart, but a late stop (`no_exit`) stays for
    `Recoveries`;
  - `running` (its process exited by itself, a crash or a kill): `stopped` with reason
    `exited` once its process is gone by pid and start time and its socket is dead, so its
    name can be resumed. A pid another program took counts as gone.

  A read that fails decides nothing; the row waits for the next read. A settle of a `running`
  row that decides nothing for that reason (the `ps` or the socket read failed, or the socket
  lives although the process is gone) says so in one `Logger.debug` line naming the row and
  what it saw, so a row that stays `running` shows why. A name whose row is
  `unknown`, `orphan`, `starting` or `stopping` is refused to a new start: its process may live.

  After each write it calls `notify` with `%{topic: "sessions:<host>:<account>", ids: [id]}`, a
  cue that names rows, never their data (`CodingAgentFramework.Tracker.SessionsSource`).
  """

  use GenServer

  require Logger

  alias CodingAgentFramework.{ClaudeCLI, Control, Holder, Programs, Registry, Shell, Stream}
  alias CodingAgentFramework.Transcripts
  alias CodingAgentFramework.Registry.Liveness
  alias CodingAgentFramework.Sessions.{Table, Worktree}

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
  # The pid the wrapper recorded ($1) and its start time as Registry.Liveness reads it; ps
  # exits 1 when the pid is gone.
  @held ~S"""
  [ -f "$1" ] || { printf 'nofile'; exit 0; }
  read -r pid < "$1" || exit 3
  case $pid in ''|*[!0-9]*) exit 4 ;; esac
  printf '%s ' "$pid"
  exec "$2" LC_ALL=C TZ=UTC "$3" -o lstart= -p "$pid"
  """
  # A name is free only when no process of its row may live: Start.tla's `Ended`.
  @ended ~w(stopped refused)
  # The held program starts in the session's directory; `$0` is the directory.
  @cd ~S(cd -- "$0" && exec "$@")

  @type outcome(ok) :: {:ok, ok} | {:refused, term} | {:unknown, term}

  @doc """
  Starts a `Sessions` and adopts or ends the rows a previous one left `starting`. Options:
  `programs:` (naming dtach, sh, env, rm, ps and tail), `dir:` (the dtach directory),
  `control:`, `registries:` (account name to its `Registry`), `db:`, and optionally `stream:`
  and `home:` (the host's `Stream` and the framework home, for delegates and worktrees),
  `reaper:` (the host's `Shell.Reaper`, for worktrees; `programs:` then names git and mkdir),
  `notify:`, `size:`
  (the viewer's `{columns, rows}`, default `{200, 50}`), `poll:` (ms between reads while a call
  waits, default 200) and `clock:` (a function answering wall-clock ms, for the deadlines).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Starts session `name` on `account` (from `Accounts.ready/2`). `launch` holds `role:` and
  `cwd:` (an absolute path) or `worktree:` (`%{project: project, branch: branch}`, with the
  project as `Sessions.Worktree.project/1` reads it; `cwd:` is then not read), and
  `ClaudeCLI.session/3`'s `claude:`, `model:`, `env:`, `tool_timeout:`, `prompt:` and `mcp:` (the agent's own MCP config). Option:
  `:timeout`, to which a worktree's start adds its setup's deadline and its git commands'
  bounds.

      Sessions.start(sessions, "reviewer", account,
        role: :delegate, worktree: %{project: project, branch: "unit/review"}, claude: claude)
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
  Ends running session `name` with `/exit` and waits for its process to exit. `turn` is the
  caller's reading of the session's screen: only `:ended` (the turn has ended and the input box
  is empty) types; any other is refused as `{:turn, turn}`. For a delegate it is the caller's
  word on its report instead: only `:report_delivered` writes the end, any other is refused as
  `{:report, turn}`, since the end cuts a turn and drops what has not gone in. `Stream` then
  refuses the end while its row's turn runs (`:turn_running`) or a message is under way or
  found undelivered. Option: `:timeout`.
  """
  @spec stop(GenServer.server(), String.t(), atom, keyword) :: outcome(:stopped)
  def stop(sessions, name, turn, opts \\ []), do: request(sessions, {:stop, name, turn}, opts)

  @doc """
  Hands `Sessions` a `Registry`'s cue (`%{topic: "registry:<host>:<account>", ids: ids}`): the
  rows of that account with no call under way are read again from the `Registry`'s rows. The
  embedding app wires the `Registry`'s `notify` here, for example through PubSub. A `Stream`'s cue
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
         {:ok, ps} <- Programs.take(programs, [:env, :ps, :tail]),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      state = %{
        host: host,
        holder: holder,
        ps: ps,
        db: db,
        control: Keyword.fetch!(opts, :control),
        registries: Keyword.fetch!(opts, :registries),
        stream: Keyword.get(opts, :stream),
        home: Keyword.get(opts, :home),
        notify: Keyword.get(opts, :notify, fn _ -> :ok end),
        size: Keyword.get(opts, :size, {200, 50}),
        poll: Keyword.get(opts, :poll, 200),
        clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
        reaper: Keyword.get(opts, :reaper),
        git: Programs.fetch(programs, :git),
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
    settle(state, :all, true)

    # One wake at each starting row's deadline, when Adopt may decide; not a poll.
    for row <- Table.with_status(state.db, state.host.name, "starting") do
      Process.send_after(self(), :deadline, max((row.deadline || 0) - state.clock.(), 0))
    end

    {:noreply, state}
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
    with :ok <- free(state, name),
         {:ok, place} <- place(state, name, launch),
         {:ok, role} <- Keyword.fetch(launch, :role) |> required(:role),
         {:ok, way} <- way(state, role, account, name, place.cwd, resume, launch),
         deadline = state.clock.() + timeout + budget(place.tree),
         row = new_row(state, name, account, role, place, resume, way, deadline),
         {:ok, viewer} <- viewer_command(state, row) do
      # RowWritten: the row first, as starting, with the start's wall-clock deadline.
      row = Map.put(row, :id, Table.starting(state.db, row))
      announce(state, row)

      pending = %{
        kind: :start,
        from: from,
        row: row,
        deadline: deadline,
        way: way,
        viewer: viewer
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

  def handle_call({:viewer_argv, name}, _from, state) do
    reply =
      case Table.get(state.db, state.host.name, name) do
        nil -> {:refused, :no_session}
        row -> viewer_command(state, row)
      end

    {:reply, reply, state}
  end

  def handle_call({{:stop, name, turn}, timeout}, from, state) do
    deadline = state.clock.() + timeout

    case Table.get(state.db, state.host.name, name) do
      row when turn != :ended and (row == nil or row.role != "delegate") ->
        {:reply, {:refused, {:turn, turn}}, state}

      # The report before the end: the caller's word until `Delegates` holds the parent's row.
      %{role: "delegate"} when turn != :report_delivered ->
        {:reply, {:refused, {:report, turn}}, state}

      %{status: "running", pid: pid} = row when is_integer(pid) ->
        # StopAsked, with the stop's own deadline in the row.
        write(state, row, status: "stopping", reason: nil, deadline: deadline)

        case ask_end(state, row) do
          {:refused, _} = refused ->
            write(state, row, status: "running")
            {:reply, refused, state}

          # An unknown write may have typed: the exit is waited for, and never typed again.
          typed ->
            send(self(), {:check, name})
            pending = %{kind: :stop, from: from, row: row, deadline: deadline, typed: typed}
            {:noreply, put_in(state.pending[name], pending)}
        end

      nil ->
        {:reply, {:refused, :no_session}, state}

      row ->
        {:reply, {:refused, {:not_running, row.status}}, state}
    end
  end

  # `/exit` through Control's checked write; a delegate's `end_session` line through Stream.
  defp ask_end(state, %{role: "delegate"} = row) do
    if state.stream,
      do: Stream.end_session(state.stream, row.session_id, timeout: @stream),
      else: {:refused, :no_stream}
  end

  defp ask_end(state, row), do: Control.send(state.control, row.name, "/exit")

  @impl true
  def handle_info({:check, name}, state) do
    case state.pending[name] do
      nil -> {:noreply, state}
      pending -> {:noreply, check(state, name, pending)}
    end
  end

  def handle_info(:deadline, state) do
    settle(state, :all, true)
    {:noreply, state}
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

  # StartDecided: running when the file names the live process, unknown past the deadline.
  defp check(state, name, %{kind: :start, row: row} = pending) do
    case confirm(state, row, true) do
      {:ok, file} ->
        running(state, row, file)
        answer = %{name: name, pid: file.pid, session_id: file.session_id}
        done(state, name, pending, {:ok, answer})

      _ ->
        wait(state, name, pending, fn ->
          why = unconfirmed(row)
          write(state, row, status: "unknown", reason: why)
          {:unknown, why}
        end)
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
        {:unknown, {why, pending.typed}}
      end)
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
    GenServer.reply(pending.from, answer)
    %{state | pending: Map.delete(state.pending, name)}
  end

  # Settles each row of `which` (`:all`, `{:account, name}` or `:delegates`) with no call under
  # way. `read?` reads the Registry or Stream first; on a reader's cue its rows are fresh.
  defp settle(state, which, read?) do
    for status <- ~w(starting unknown stopping),
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

      {:live, why} when past? ->
        write(state, row, status: "orphan", reason: why)

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

  # A process that runs on a dead socket, with the pid and start time of the file that names
  # it, for Recoveries; a delegate's has none (`unheld/3`).
  defp orphan(state, row, nil), do: write(state, row, status: "orphan", reason: "unheld")

  defp orphan(state, row, file),
    do:
      write(state, row,
        status: "orphan",
        reason: "unheld",
        pid: file.pid,
        proc_start: file.proc_start
      )

  # Confirms a delegate: Stream has read the init naming its session id, and so the wrapper had
  # recorded its pid before; that pid lives with the start time ps gives, and the socket is
  # live after that ps, so the pid was not reused in between.
  defp confirm(state, %{role: "delegate"} = row, read?) do
    with {:ok, :live} <- Holder.state(state.holder, row.socket),
         {:ok, followed} <- followed(state, row, read?),
         true <- followed.session_id == row.session_id or {:live, :no_first_event},
         {:ok, pid, start} <- held(state, row),
         {:ok, :live} <- Holder.state(state.holder, row.socket) do
      {:ok, %{pid: pid, proc_start: start, session_id: row.session_id}}
    else
      {:ok, dead} when dead in [:absent, :stale] -> unheld(state, row, dead)
      {:live, _} = live -> live
      :unread -> {:unknown, :unread}
      {_, reason} -> {:unknown, reason}
    end
  end

  # Confirms: the session file of a live process with the session's name, while its socket is
  # live. A dead socket while that file names a live process is `{:unheld, file}`: its dtach
  # was killed hard and the process runs on. `{:dead, _}` only for a dead socket with no such
  # file; any read that fails is `{:unknown, _}`.
  defp confirm(state, row, read?) do
    with {:ok, socket} <- Holder.state(state.holder, row.socket),
         {:ok, registry} <- Map.fetch(state.registries, row.account),
         {:ok, _} <- if(read?, do: Registry.read(registry), else: {:ok, :cued}),
         {:ok, %{rows: files}} <- Registry.rows(registry) do
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

  # A delegate's dead socket: the pid its wrapper recorded may run on, unheld. That file names
  # no start time, so a pid ps lists may be another program's: the orphan keeps no pid (F-64's
  # build note, new-3). No file, or a pid ps does not list, is dead.
  defp unheld(state, row, dead) do
    case held(state, row) do
      {:ok, _pid, _start} -> {:unheld, nil}
      {:unknown, gone} when gone in [:no_pid, :exited] -> {:dead, dead}
      other -> other
    end
  end

  # A pid that `ps` lists with another start time was reused: the held process exited.
  defp liveness(state, row), do: alive(state, [row])[{row.pid, row.proc_start}]

  defp alive(state, rows) do
    opts = [env: state.ps.env, ps: state.ps.ps, timeout: 5_000]
    Liveness.check(state.host, Enum.map(rows, &{&1.pid, &1.proc_start}), opts)
  end

  defp running(state, row, file) do
    fields = [pid: file.pid, session_id: file.session_id, proc_start: file.proc_start]
    write(state, row, [status: "running", reason: nil] ++ fields)
  end

  defp free(state, name) do
    case Table.get(state.db, state.host.name, name) do
      nil -> :ok
      %{status: status} when status in @ended -> :ok
      %{status: status} -> {:refused, {:exists, status}}
    end
  end

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

  defp cli(role, account, name, resume, launch) do
    opts = Keyword.take(launch, [:claude, :model, :env, :tool_timeout, :prompt, :mcp])
    opts = opts ++ [name: name]
    opts = if resume, do: opts ++ [resume: resume], else: opts
    ClaudeCLI.session(role, account, opts)
  end

  # What a start holds, checked before its row is written: an interactive session's own
  # command, or a headless delegate's with the session id the framework chose ("Headless
  # delegates"), which a resume keeps.
  defp way(state, :delegate, account, _name, cwd, resume, launch) do
    id = resume || Stream.uuid()
    start = if resume, do: [resume: id], else: [session_id: id]

    # The id names the delegate's directory, so a resume's is a plain id, never a path.
    with {:ok, stream} <- if(state.stream && state.home, do: {:ok, state.stream}, else: :error),
         true <- id =~ ~r/\A[A-Za-z0-9_-]{1,64}\z/ or {:refused, {:bad, :session_id}},
         {:ok, cli} <-
           ClaudeCLI.headless(
             account,
             Keyword.take(launch, [:claude, :model, :env, :tool_timeout, :mcp]) ++ start
           ),
         {:ok, transcript} <- Transcripts.path(account.config_dir, cwd, id) do
      {:ok, %{stream: stream, session_id: id, cli: cli, transcript: transcript}}
    else
      :error -> {:refused, :no_stream}
      refused -> refused
    end
  end

  defp way(_state, role, account, name, _cwd, resume, launch) do
    with {:ok, cli} <- cli(role, account, name, resume, launch), do: {:ok, %{cli: cli}}
  end

  # The start's row before it has an id.
  defp new_row(state, name, account, role, place, resume, way, deadline) do
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
      {_, reason} -> "kept: " <> inspect(reason)
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

      case Holder.hold(state.holder, name, argv, env: way.cli.env) do
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

  # The pid the wrapper recorded, and its start time.
  defp held(state, row) do
    pid_file = Path.join(Stream.dir(state.home, row.session_id), "pid")
    args = ["-c", @held, "sh", pid_file, state.ps.env, state.ps.ps]

    case Shell.run(state.host, state.holder.sh, args, timeout: @stream) do
      {:ok, %{status: 0, output: "nofile"}} ->
        {:unknown, :no_pid}

      {:ok, %{status: 0, output: out}} ->
        with [pid, start] <- String.split(out, " ", parts: 2),
             {pid, ""} <- Integer.parse(pid),
             start when start != "" <- String.trim(start) do
          {:ok, pid, start}
        else
          _ -> {:unknown, {:held, 0, String.slice(out, 0, 200)}}
        end

      {:ok, %{status: 1}} ->
        {:unknown, :exited}

      {:ok, %{status: status, output: out}} ->
        {:unknown, {:held, status, String.slice(out, 0, 200)}}

      other ->
        other
    end
  end

  defp open_viewer(state, name, argv) do
    case viewer(state.control, name, argv, state.size) do
      {:ok, _pane} -> "open"
      failed -> inspect(failed)
    end
  end

  @doc """
  Opens a viewer of held session `name` through `control`: a tmux session of that name running
  `argv` (`viewer_argv/3`'s answer), tagged as it opens, one row short of `{columns, rows}`, then
  grown, since Claude Code redraws only when its size changes. tmux starts its server when it is
  down. `Recoveries` reopens a lost viewer with it. Answers `{:ok, pane}`, or `Control`'s
  refusal or unknown; a pane that opened and was not grown is `{:unknown, {:resize, pane, why}}`.
  """
  @spec viewer(GenServer.server(), String.t(), [String.t()], {pos_integer, pos_integer}) ::
          outcome(String.t())
  def viewer(control, name, argv, {columns, rows}) do
    with {:ok, pane} <- Control.open(control, name, argv, size: {columns, rows - 1}) do
      case Control.resize(control, name, {columns, rows}) do
        {:ok, :resized} -> {:ok, pane}
        failed -> {:unknown, {:resize, pane, failed}}
      end
    end
  end

  defp write(state, row, fields) do
    Table.update(state.db, row.id, fields)
    announce(state, row)
  end

  defp announce(state, row),
    do: state.notify.(%{topic: "sessions:#{state.host.name}:#{row.account}", ids: [row.id]})
end
