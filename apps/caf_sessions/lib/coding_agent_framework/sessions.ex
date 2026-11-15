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
      Sessions.start(sessions, "fix-login", account,
        role: :delegate, cwd: "/src/app", claude: claude, model: "opus", env: env, prompt: brief)
      #=> {:ok, %{name: "fix-login", pid: 4242, session_id: "…"}}

  **A start** (`docs/design.md`, "The delegate protocol") writes its row first, as `starting`,
  with the socket name and the session's name, which are one name. Then it holds
  `ClaudeCLI.session/3`'s argv and environment through `Holder.hold/4`, in the given directory,
  and opens a viewer pane (`dtach -a`) through `Control`, tagged with the session as it opens:
  one row short, then grown, since Claude Code does not redraw for a viewer that attaches at its
  own size. A viewer that fails leaves the session running; its row's `viewer` says why. The
  start is confirmed when the account's `Registry` reads a session file with the session's name
  (`--name`) whose pid lives, and the socket is live. The pid comes from that file, since dtach
  does not report it. **A resume** is the same with `--resume <id>`.

  **A stop** types `/exit` through `Control`'s checked write, then waits until the process the
  row names exits, judged by `{pid, procStart}` (`Registry.Liveness`), never by name. `/exit`
  must be typed only when the turn has ended and the input box is empty. Reading that from the
  screen is `Screen`'s job, which is not built: the caller says the turn has ended, and any
  other answer is refused.

  Each call answers `{:ok, …}`, `{:refused, reason}` or `{:unknown, reason}` within its
  `:timeout` (30 s by default, plus the hold's and the viewer's own bounds). Nothing is retried:
  a start that is not confirmed in time answers `{:unknown, :no_session_file}`, and its row says
  `unknown` with that reason. A hold that answers unknown still waits for the file. A stop whose
  process is alive at its deadline answers `{:unknown, {:no_exit, typed}}` and leaves the row
  `stopping` with reason `no_exit`: `Recoveries` ends that process by its pid and start time.
  `Sessions` itself never kills. The row keeps the start's or stop's deadline in wall-clock time
  (the `clock:` option), so a restart does not move it.

  **Rows with no call under way** are settled as `model/tla/Start.tla` does, when `Sessions`
  starts, at a starting row's deadline, and at each `Registry` read that `cue/2` hands it:

  - `starting` (left by a restart): `running` when its file names its live process; past its
    deadline, `orphan` for a live socket and `refused{interrupted}` for a dead one;
  - `unknown`: `running` when its file names its live process, `stopped` when its socket is dead;
  - `stopping`: `stopped` when its process is gone by pid and start time; when it lives,
    `running` after a restart, but a late stop (`no_exit`) stays for `Recoveries`.

  A read that fails decides nothing; the row waits for the next read. A name whose row is
  `unknown`, `orphan`, `starting` or `stopping` is refused to a new start: its process may live.

  After each write it calls `notify` with `%{topic: "sessions:<host>:<account>", ids: [id]}`, a
  cue that names rows, never their data (`CodingAgentFramework.Tracker.SessionsSource`).
  """

  use GenServer

  alias CodingAgentFramework.{ClaudeCLI, Control, Holder, Programs, Registry}
  alias CodingAgentFramework.Registry.Liveness
  alias CodingAgentFramework.Sessions.Table

  @timeout 30_000
  # The hold's and the viewer's own bounds, past the confirmation's.
  @slack 25_000
  # A name is free only when no process of its row may live: Start.tla's `Ended`.
  @ended ~w(stopped refused)
  # The held program starts in the session's directory; `$0` is the directory.
  @cd ~S(cd -- "$0" && exec "$@")

  @type outcome(ok) :: {:ok, ok} | {:refused, term} | {:unknown, term}

  @doc """
  Starts a `Sessions` and adopts or ends the rows a previous one left `starting`. Options:
  `programs:` (naming dtach, sh, env, rm and ps), `dir:` (the dtach directory), `control:`,
  `registries:` (account name to its `Registry`), `db:`, and optionally `notify:`, `size:`
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
  is empty) types; any other is refused as `{:turn, turn}`. Option: `:timeout`.
  """
  @spec stop(GenServer.server(), String.t(), atom, keyword) :: outcome(:stopped)
  def stop(sessions, name, turn, opts \\ []), do: request(sessions, {:stop, name, turn}, opts)

  @doc """
  Hands `Sessions` a `Registry`'s cue (`%{topic: "registry:<host>:<account>", ids: ids}`): the
  rows of that account with no call under way are read again from the `Registry`'s rows. The
  host app wires the `Registry`'s `notify` here, for example through PubSub. Answers `:ok` at
  once; what it settles shows in the rows and their cues.

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
         {:ok, ps} <- Programs.take(programs, [:env, :ps]),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      state = %{
        host: host,
        holder: holder,
        ps: ps,
        db: db,
        control: Keyword.fetch!(opts, :control),
        registries: Keyword.fetch!(opts, :registries),
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
      [host, account] when host == state.host.name -> settle(state, account, false)
      _ -> :ok
    end

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
         {:ok, cli} <- cli(role, account, name, resume, launch) do
      row = %{host: state.host.name, name: name, socket: name, account: account.name}
      row = Map.merge(row, %{role: Atom.to_string(role), cwd: cwd, resume: resume})
      # RowWritten: the row first, as starting, with the start's wall-clock deadline.
      row = Map.put(row, :deadline, deadline)
      row = Map.put(row, :id, Table.starting(state.db, row))
      announce(state, row)
      argv = [state.holder.sh, "-c", @cd, cwd | cli.argv]

      # Held: held, or unknown (a process may have started), and the start waits for the file
      # either way; ViewerOpened then leaves the call waiting. Only a refusal ends it here.
      case Holder.hold(state.holder, name, argv, env: cli.env) do
        {:refused, reason} = refused ->
          write(state, row, status: "refused", reason: reason)
          {:reply, refused, state}

        _held_or_unknown ->
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
      _ when turn != :ended ->
        {:reply, {:refused, {:turn, turn}}, state}

      %{status: "running", pid: pid} = row when is_integer(pid) ->
        # StopAsked, with the stop's own deadline in the row.
        write(state, row, status: "stopping", reason: nil, deadline: deadline)

        case Control.send(state.control, name, "/exit") do
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
          write(state, row, status: "unknown", reason: "no_session_file")
          {:unknown, :no_session_file}
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

  # Settles each row of `account` (or `:all`) with no call under way. `read?` reads the
  # Registry first; on a Registry's cue its rows are already fresh.
  defp settle(state, account, read?) do
    for status <- ~w(starting unknown stopping),
        row <- Table.with_status(state.db, state.host.name, status),
        account in [:all, row.account],
        not Map.has_key?(state.pending, row.name),
        do: settle_row(state, row, read?)

    :ok
  end

  # Adopt: a starting row waits for its deadline before it is given up, and a failed read
  # decides nothing.
  defp settle_row(state, %{status: "starting"} = row, read?) do
    past? = state.clock.() >= (row.deadline || 0)

    case confirm(state, row, read?) do
      {:ok, file} -> running(state, row, file)
      {:live, _} when past? -> write(state, row, status: "orphan", reason: "no_session_file")
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
