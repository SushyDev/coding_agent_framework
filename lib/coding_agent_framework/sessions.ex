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
  `unknown` with that reason.

  **After a restart** of `Sessions`, a row still `starting` is adopted (`running`) when its
  socket is live and its session file names a live pid; otherwise it ends as `refused` with the
  reason `interrupted`. Nothing else is changed or removed by a restart.

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
  @ended ~w(stopped refused unknown)
  # The held program starts in the session's directory; `$0` is the directory.
  @cd ~S(cd -- "$0" && exec "$@")

  @type outcome(ok) :: {:ok, ok} | {:refused, term} | {:unknown, term}

  @doc """
  Starts a `Sessions` and adopts or ends the rows a previous one left `starting`. Options:
  `programs:` (naming dtach, sh, env, rm and ps), `dir:` (the dtach directory), `control:`,
  `registries:` (account name to its `Registry`), `db:`, and optionally `notify:`, `size:`
  (the viewer's `{columns, rows}`, default `{200, 50}`) and `poll:` (ms between reads while a
  call waits, default 200).
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
        pending: %{}
      }

      {:ok, state, {:continue, :adopt}}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:adopt, state) do
    for row <- Table.with_status(state.db, state.host.name, "starting") do
      case confirm(state, row) do
        {:ok, file} -> running(state, row, file)
        _ -> write(state, row, status: "refused", reason: "interrupted")
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({{:start, name, account, launch, resume}, timeout}, from, state) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with :ok <- free(state, name),
         {:ok, viewer} <- Holder.viewer_argv(state.holder, name),
         {:ok, cwd} <- cwd(launch),
         {:ok, role} <- Keyword.fetch(launch, :role) |> required(:role),
         {:ok, cli} <- cli(role, account, name, resume, launch) do
      row = %{host: state.host.name, name: name, socket: name, account: account.name}
      row = Map.merge(row, %{role: Atom.to_string(role), cwd: cwd, resume: resume})
      row = Map.put(row, :id, Table.starting(state.db, row))
      cue(state, row)
      argv = [state.holder.sh, "-c", @cd, cwd | cli.argv]

      case Holder.hold(state.holder, name, argv, env: cli.env) do
        {:ok, _socket} ->
          write(state, row, viewer: open_viewer(state, name, viewer))
          send(self(), {:check, name})
          pending = %{kind: :start, from: from, row: row, deadline: deadline}
          {:noreply, put_in(state.pending[name], pending)}

        {kind, reason} = failed ->
          write(state, row, status: Atom.to_string(kind), reason: reason)
          {:reply, failed, state}
      end
    else
      failed -> {:reply, failed, state}
    end
  end

  def handle_call({{:stop, name, turn}, timeout}, from, state) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case Table.get(state.db, state.host.name, name) do
      _ when turn != :ended ->
        {:reply, {:refused, {:turn, turn}}, state}

      %{status: "running", pid: pid} = row when is_integer(pid) ->
        write(state, row, status: "stopping")

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

  defp check(state, name, %{kind: :start, row: row} = pending) do
    case confirm(state, row) do
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

  defp check(state, name, %{kind: :stop, row: row} = pending) do
    opts = [env: state.ps.env, ps: state.ps.ps, timeout: 5_000]
    proc = {row.pid, row.proc_start}

    # A pid that `ps` lists with another start time was reused: the held process exited.
    if Liveness.check(state.host, [proc], opts)[proc] in [:gone, :replaced] do
      write(state, row, status: "stopped")
      done(state, name, pending, {:ok, :stopped})
    else
      wait(state, name, pending, fn ->
        write(state, row, status: "unknown", reason: {:no_exit, pending.typed})
        {:unknown, {:no_exit, pending.typed}}
      end)
    end
  end

  defp wait(state, name, pending, late) do
    if System.monotonic_time(:millisecond) >= pending.deadline do
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

  # The session file of a live process with the session's name, while its socket is live.
  defp confirm(state, row) do
    with {:ok, registry} <- Map.fetch(state.registries, row.account),
         {:ok, :live} <- Holder.state(state.holder, row.socket),
         {:ok, _} <- Registry.read(registry),
         {:ok, %{rows: files}} <- Registry.rows(registry),
         %{} = file <- Enum.find(files, &(&1.name == row.name and &1.alive == :live)) do
      {:ok, file}
    else
      # `{:ok, :absent}` and the like fall here, never through as a file.
      other -> {:not_yet, other}
    end
  end

  defp running(state, row, file) do
    fields = [pid: file.pid, session_id: file.session_id, proc_start: file.proc_start]
    write(state, row, [status: "running"] ++ fields)
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

  # One row short, then grown: Claude Code redraws only when its size changes.
  defp open_viewer(state, name, argv) do
    {columns, rows} = state.size

    with {:ok, _pane} <- Control.open(state.control, name, argv, size: {columns, rows - 1}),
         {:ok, :resized} <- Control.resize(state.control, name, {columns, rows}) do
      "open"
    else
      failed -> inspect(failed)
    end
  end

  defp write(state, row, fields) do
    Table.update(state.db, row.id, fields)
    cue(state, row)
  end

  defp cue(state, row),
    do: state.notify.(%{topic: "sessions:#{state.host.name}:#{row.account}", ids: [row.id]})
end
