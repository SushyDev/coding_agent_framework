defmodule CodingAgentFramework.Sessions do
  @moduledoc """
  One host's session lifecycle: starts, resumes and stops Claude Code sessions, each held by
  dtach with a viewer pane, and keeps a row for each in `CodingAgentFramework.Sessions.Table`,
  which it alone writes. Worktrees are a later unit: a session runs in the directory it is given.

  The caller's supervision tree starts one `Sessions` per host, with no name, and gives it the
  host's `Programs`, its dtach directory, its `Control`, a `Registry` per account and the SQLite
  path:

      {:ok, sessions} = Sessions.start_link(programs: programs, dir: "/srv/caf/dtach",
        control: control, registries: %{"work" => registry}, db: "/srv/caf/caf.db")
      {:ok, account} = Accounts.ready(accounts, "work")
      Sessions.start(sessions, "main", account,
        role: :parent, cwd: "/src/app", claude: claude, model: "opus", env: env)
      #=> {:ok, %{name: "main", pid: 4242, session_id: "…"}}

  A host that runs delegates also gives it its `Stream` and the framework home (`stream:`,
  `home:`).

  **A start** (`docs/design.md`, "The delegate protocol") writes its row first, as `starting`,
  with the socket name and the session's name, which are one name. Then it holds
  `ClaudeCLI.session/3`'s argv and environment through `Holder.hold/4`, in the given directory,
  and opens a viewer pane (`dtach -a`) through `Control`, tagged with the session as it opens:
  one row short, then grown, since Claude Code does not redraw for a viewer that attaches at its
  own size. A viewer that fails leaves the session running; its row's `viewer` says why. The
  start is confirmed when the account's `Registry` reads a session file with the session's name
  (`--name`) whose pid lives, and the socket is live. The pid comes from that file, since dtach
  does not report it. **A resume** is the same with `--resume <id>`.

  **A delegate** (role `:delegate`) runs headless ("Headless delegates"): after its row, which
  keeps the session id the framework chose, `Stream.follow/5` makes its directory and FIFO under
  `<home>/streams/<session id>/`, then `ClaudeCLI.headless/2`'s argv is held inside
  `ClaudeCLI.wrapper/3`, and its viewer is a pane running `tail -F` of its event log (the
  renderer is a later unit; `-F` waits for a log the wrapper has not opened yet). Its start is
  confirmed when `Stream` has read a `system`/`init` naming the session id, the pid the wrapper
  recorded lives with the start time `ps` gives, and the socket is still live after that `ps`.
  The init comes after the wrapper wrote the pid, so that pid is this process's. A resume
  follows the same log again, from the offset `Stream` saved. A delegate's first message is a
  `Stream` write, not part of the start: `prompt:` is not read.

  **A stop** types `/exit` through `Control`'s checked write, then waits until the process the
  row names exits, judged by `{pid, procStart}` (`Registry.Liveness`), never by name. `/exit`
  must be typed only when the turn has ended and the input box is empty. Reading that from the
  screen is `Screen`'s job, which is not built: the caller says the turn has ended, and any
  other answer is refused. A delegate's stop writes `end_session` through `Stream` instead, and
  its turn is `Stream`'s row's, not the caller's: `Stream` refuses the end while a turn runs.

  Each call answers `{:ok, …}`, `{:refused, reason}` or `{:unknown, reason}` within its
  `:timeout` (30 s by default, plus the hold's and the viewer's own bounds). Nothing is retried:
  a start that is not confirmed in time answers `{:unknown, :no_session_file}` (a delegate's,
  `{:unknown, :no_first_event}`), and its row says `unknown` with that reason. A hold that answers unknown still waits for the file. A stop whose
  process is alive at its deadline answers `{:unknown, {:no_exit, typed}}` and leaves the row
  `stopping` with reason `no_exit`: `Recoveries` ends that process by its pid and start time.
  `Sessions` itself never kills. The row keeps the start's or stop's deadline in wall-clock time
  (the `clock:` option), so a restart does not move it.

  **Rows with no call under way** are settled as `model/tla/Start.tla` does, when `Sessions`
  starts, at a starting row's deadline, and at each `Registry` or `Stream` read that `cue/2`
  hands it. "Confirmed" is a delegate's first event and recorded pid, as above:

  - `starting` (left by a restart): `running` when confirmed; past its deadline, `orphan` for a
    live socket and `refused{interrupted}` for a dead one;
  - `unknown`: `running` when confirmed, `stopped` when its socket is dead;
  - `stopping`: `stopped` when its process is gone by pid and start time; when it lives,
    `running` after a restart, but a late stop (`no_exit`) stays for `Recoveries`.

  A read that fails decides nothing; the row waits for the next read. A name whose row is
  `unknown`, `orphan`, `starting` or `stopping` is refused to a new start: its process may live.

  After each write it calls `notify` with `%{topic: "sessions:<host>:<account>", ids: [id]}`, a
  cue that names rows, never their data (`CodingAgentFramework.Tracker.SessionsSource`).
  """

  use GenServer

  alias CodingAgentFramework.{ClaudeCLI, Control, Holder, Programs, Registry, Shell, Stream}
  alias CodingAgentFramework.Transcripts
  alias CodingAgentFramework.Registry.Liveness
  alias CodingAgentFramework.Sessions.Table

  @timeout 30_000
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
  and `home:` (the host's `Stream` and the framework home, for delegates), `notify:`, `size:`
  (the viewer's `{columns, rows}`, default `{200, 50}`), `poll:` (ms between reads while a call
  waits, default 200) and `clock:` (a function answering wall-clock ms, for the deadlines).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Starts session `name` on `account` (from `Accounts.ready/2`). `launch` holds `role:` and
  `cwd:` (an absolute path), and `ClaudeCLI.session/3`'s `claude:`, `model:`, `env:` and
  `prompt:`. Option: `:timeout`.
  """
  @spec start(GenServer.server(), String.t(), struct, keyword, keyword) :: outcome(map)
  def start(sessions, name, account, launch, opts \\ []),
    do: request(sessions, {:start, name, account, launch, nil}, opts)

  @doc "As `start/5`, resuming Claude Code's session `session_id` (`--resume`)."
  @spec resume(GenServer.server(), String.t(), struct, String.t(), keyword, keyword) ::
          outcome(map)
  def resume(sessions, name, account, session_id, launch, opts \\ []),
    do: request(sessions, {:start, name, account, launch, session_id}, opts)

  @doc """
  Ends running session `name` with `/exit` and waits for its process to exit. `turn` is the
  caller's reading of the session's screen: only `:ended` (the turn has ended and the input box
  is empty) types; any other is refused as `{:turn, turn}`. A delegate's `turn` is not read:
  `Stream`'s row says whether its turn has ended, and `Stream` refuses the end with
  `:turn_running` while it runs. Option: `:timeout`.
  """
  @spec stop(GenServer.server(), String.t(), atom, keyword) :: outcome(:stopped)
  def stop(sessions, name, turn, opts \\ []), do: request(sessions, {:stop, name, turn}, opts)

  @doc """
  Hands `Sessions` a `Registry`'s cue (`%{topic: "registry:<host>:<account>", ids: ids}`): the
  rows of that account with no call under way are read again from the `Registry`'s rows. The
  host app wires the `Registry`'s `notify` here, for example through PubSub. A `Stream`'s cue
  (`stream:<host>`) does the same for the host's delegates. Answers `:ok` at once; what it
  settles shows in the rows and their cues.

      Sessions.cue(sessions, %{topic: "registry:laptop:work", ids: [3]})
      #=> :ok
  """
  @spec cue(GenServer.server(), map) :: :ok
  def cue(sessions, %{topic: topic}), do: GenServer.cast(sessions, {:cue, topic})

  defp request(sessions, request, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    try do
      GenServer.call(sessions, {request, timeout}, timeout + @slack)
    catch
      :exit, {:noproc, _} -> {:refused, :no_sessions}
      :exit, {:timeout, _} -> {:unknown, {:timeout, timeout + @slack}}
      :exit, {reason, _} -> {:unknown, {:exit, reason}}
    end
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

  def handle_cast({:cue, _topic}, state), do: {:noreply, state}

  @impl true
  def handle_call({{:start, name, account, launch, resume}, timeout}, from, state) do
    deadline = state.clock.() + timeout

    with :ok <- free(state, name),
         {:ok, viewer} <- Holder.viewer_argv(state.holder, name),
         {:ok, cwd} <- cwd(launch),
         {:ok, role} <- Keyword.fetch(launch, :role) |> required(:role),
         {:ok, way} <- way(state, role, account, name, cwd, resume, launch) do
      row = %{host: state.host.name, name: name, socket: name, account: account.name}
      row = Map.merge(row, %{role: Atom.to_string(role), cwd: cwd, resume: resume})
      # RowWritten: the row first, as starting, with the start's wall-clock deadline.
      row = Map.merge(row, %{deadline: deadline, session_id: way[:session_id]})
      row = Map.put(row, :id, Table.starting(state.db, row))
      announce(state, row)

      # Held: held, or unknown (a process may have started), and the start waits for the file
      # either way; ViewerOpened then leaves the call waiting. Only a refusal ends it here.
      case hold(state, way, name, cwd, viewer) do
        {:refused, reason} = refused ->
          write(state, row, status: "refused", reason: reason)
          {:reply, refused, state}

        {:held, viewer} ->
          write(state, row, viewer: open_viewer(state, name, viewer))
          send(self(), {:check, name})
          pending = %{kind: :start, from: from, row: row, deadline: deadline}
          {:noreply, put_in(state.pending[name], pending)}
      end
    else
      failed -> {:reply, failed, state}
    end
  end

  def handle_call({{:stop, name, turn}, timeout}, from, state) do
    deadline = state.clock.() + timeout

    case Table.get(state.db, state.host.name, name) do
      row when turn != :ended and (row == nil or row.role != "delegate") ->
        {:reply, {:refused, {:turn, turn}}, state}

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

  # StopSettled within the call; StopTimedOut leaves the row stopping, late, for Recoveries.
  defp check(state, name, %{kind: :stop, row: row} = pending) do
    if liveness(state, row) in [:gone, :replaced] do
      write(state, row, status: "stopped")
      done(state, name, pending, {:ok, :stopped})
    else
      wait(state, name, pending, fn ->
        write(state, row, reason: "no_exit")
        {:unknown, {:no_exit, pending.typed}}
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
        row <- Table.with_status(state.db, state.host.name, status),
        which in [:all, {:account, row.account}] or (which == :delegates and delegate?(row)),
        not Map.has_key?(state.pending, row.name),
        do: settle_row(state, row, read?)

    :ok
  end

  defp delegate?(row), do: row.role == "delegate"

  # Adopt: a starting row waits for its deadline before it is given up, and a failed read
  # decides nothing.
  defp settle_row(state, %{status: "starting"} = row, read?) do
    past? = state.clock.() >= (row.deadline || 0)

    case confirm(state, row, read?) do
      {:ok, file} -> running(state, row, file)
      {:live, why} when past? -> write(state, row, status: "orphan", reason: why)
      {:dead, _} when past? -> write(state, row, status: "refused", reason: "interrupted")
      _unknown_or_early -> :ok
    end
  end

  # ReRead: an unknown row is running once its file names its live process, stopped once its
  # socket is dead.
  defp settle_row(state, %{status: "unknown"} = row, read?) do
    case confirm(state, row, read?) do
      {:ok, file} -> running(state, row, file)
      {:dead, _} -> write(state, row, status: "stopped")
      _ -> :ok
    end
  end

  # StopSettled with no stop under way, by pid and start time. A late stop stays stopping.
  defp settle_row(state, %{status: "stopping"} = row, _read?) do
    case liveness(state, row) do
      gone when gone in [:gone, :replaced] -> write(state, row, status: "stopped")
      :live when row.reason != "no_exit" -> write(state, row, status: "running")
      _late_or_unknown -> :ok
    end
  end

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
      {:ok, dead} when dead in [:absent, :stale] -> {:dead, dead}
      {:live, _} = live -> live
      :unread -> {:unknown, :unread}
      {_, reason} -> {:unknown, reason}
    end
  end

  # Confirms: the session file of a live process with the session's name, while its socket is
  # live. `{:dead, _}` only for a socket read as dead; any read that fails is `{:unknown, _}`.
  defp confirm(state, row, read?) do
    with {:ok, :live} <- Holder.state(state.holder, row.socket),
         {:ok, registry} <- Map.fetch(state.registries, row.account),
         {:ok, _} <- if(read?, do: Registry.read(registry), else: {:ok, :cued}),
         {:ok, %{rows: files}} <- Registry.rows(registry) do
      named = Enum.filter(files, &(&1.name == row.name))

      cond do
        file = Enum.find(named, &(&1.alive == :live)) -> {:ok, file}
        Enum.any?(named, &(&1.alive == :unknown)) -> {:unknown, :liveness}
        true -> {:live, :no_session_file}
      end
    else
      {:ok, dead} when dead in [:absent, :stale] -> {:dead, dead}
      :error -> {:unknown, :no_registry}
      :unread -> {:unknown, :unread}
      {_, reason} -> {:unknown, reason}
    end
  end

  # A pid that `ps` lists with another start time was reused: the held process exited.
  defp liveness(state, row) do
    proc = {row.pid, row.proc_start}
    opts = [env: state.ps.env, ps: state.ps.ps, timeout: 5_000]
    Liveness.check(state.host, [proc], opts)[proc]
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
    opts = Keyword.take(launch, [:claude, :model, :env, :prompt]) ++ [name: name]
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
           ClaudeCLI.headless(account, Keyword.take(launch, [:claude, :model, :env]) ++ start),
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

  # A delegate's directory and FIFO come before its hold: a follow that fails holds nothing.
  defp hold(state, way, name, cwd, viewer) do
    with {:ok, argv, viewer} <- prepare(state, way, name, viewer) do
      argv = [state.holder.sh, "-c", @cd, cwd | argv]

      case Holder.hold(state.holder, name, argv, env: way.cli.env) do
        {:refused, _} = refused -> refused
        _held_or_unknown -> {:held, viewer}
      end
    end
  end

  defp prepare(state, %{stream: stream} = way, name, _viewer) do
    case Stream.follow(stream, way.session_id, name, way.transcript, timeout: @stream) do
      {:ok, dir} ->
        log = Path.join(dir, "events.jsonl")
        {:ok, ClaudeCLI.wrapper(state.holder.sh, dir, way.cli.argv), [state.ps.tail, "-F", log]}

      {_, reason} ->
        {:refused, {:follow, reason}}
    end
  end

  defp prepare(_state, way, _name, viewer), do: {:ok, way.cli.argv, viewer}

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
  `argv` (`Holder.viewer_argv/2`), tagged as it opens, one row short of `{columns, rows}`, then
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
