defmodule CodingAgentFramework.Delegates do
  @moduledoc """
  The delegate protocol (`docs/design.md`, "The delegate protocol"; `model/tla/Delegate.tla`),
  up to a held report: a start, the brief, a finish by its turn's `result`, and the report held
  durably. Delivering a report into its parent needs `Screen`, which is not built:
  `deliver/2` is refused as `:no_delivery`. A kill, and its one resume, are a later unit.

  The caller's supervision tree starts one per host, with no name, and gives it the host's
  `Sessions` and `Stream`, the instance's `Usage` and `Accounts`, the projects as data, and what
  every launch shares:

      {:ok, delegates} = Delegates.start_link(host: "laptop", db: db, sessions_db: db,
        sessions: sessions, stream: stream, usage: usage, accounts: accounts,
        launch: [claude: claude, env: env],
        projects: %{"app" => %{name: "app", repo: "/src/app", trunk: "main", setup: [],
          setup_timeout: 60_000, env: %{}, branches: ~r/\\Aunit\\//, cap: 3}})
      Delegates.start_delegate(delegates, "main", "app", "unit/review", "opus", "Review it.")
      #=> {:ok, %{id: 1, name: "app-unit-review", session_id: "…", account: "work",
      #=>   brief: {:ok, %{uuid: "…"}}}}

  **A start** checks the project, the branch against the project's pattern and the parent's cap
  (`Delegates.Turn`), picks the account with the most allowance left (`Usage.pick/2`), and
  writes its row first, as `starting`, with the uuid its brief will go in under. A task then
  starts the session through `Sessions`, role `:delegate` in the project's worktree, and its
  answer moves the row: `running`, then the brief through `Stream` under that uuid, which
  `Stream` refuses a second time; or `refused`. A row a restart left `starting` is settled by
  `Sessions`' row of its call, once that row is settled; with no such row by the row's deadline,
  the call never reached `Sessions`, and the row is refused as `interrupted`.

  **A running delegate** is read from its `Stream` row at each cue: once the turn's message is
  delivered and a `result` came after it, the row is `finished` with that result's text as its
  report. A row leaves `running` once. When its process is gone first, the row stays `running`:
  the kill path (the transcript's last reply, one resume, a second kill) is a later unit.

  Each report is `held` in the table, with a mark of its own, and survives restarts.

  It reads every row again when it starts and at each `cue/2`; the host app wires the cues of
  `Sessions` and `Stream` to it. After each write `notify` gets `%{topic:
  "delegates:<host>", ids: [id]}`.
  """

  use GenServer

  alias CodingAgentFramework.{Accounts, Sessions, Stream, Usage}
  alias CodingAgentFramework.Delegates.{Table, Turn}

  # Sessions' own timeout for a start; its git bounds and slack come on top.
  @call 30_000
  @slack 120_000
  @step 5_000

  @doc """
  Starts a `Delegates`. Options: `host:` (the name of the host `sessions:` and `stream:` run
  on), `db:`, `sessions_db:` (the file `Sessions`' table is in), `usage:`, `accounts:`,
  `projects:` (name to a project as `Sessions.Worktree.project/1` reads it, with `branches:`
  and `cap:`), `launch:` (`claude:` and `env:` for `ClaudeCLI`), and optionally `notify:` and
  `clock:` (wall-clock ms).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Starts a delegate of `parent` (the parent session's name, which the caller states until
  `Parents` exists) on `branch` of `project`, with `model`, and writes `brief` as its first
  message. Answers `{:ok, %{id, name, session_id, account, brief}}`, `brief` being `Stream`'s
  answer to that write; `{:refused, reason}`; or `{:unknown, reason}`, when its row stays
  `starting` for a later read to settle. Option `:timeout`: what the caller waits (default
  300 000 ms); the start goes on past it.
  """
  def start_delegate(delegates, parent, project, branch, model, brief, opts \\ []),
    do: call(delegates, {:start, parent, project, branch, model, brief}, opts, 300_000)

  @doc "The reports `parent` holds: `{:ok, [%{id, name, branch, status, text, mark}]}`."
  def held(delegates, parent, opts \\ []), do: call(delegates, {:held, parent}, opts, @step)

  @doc """
  Will deliver held report `id`: mark it sending, then type it with its mark through
  `Control`'s checked write once the parent's turn has ended, and settle it from the parent's
  transcript after a restart. Refused until `Screen` is built.
  """
  def deliver(_delegates, _id), do: {:refused, :no_delivery}

  @doc "Hands it a reader's cue: every row is read again. Answers `:ok` at once."
  def cue(delegates, %{topic: _}), do: GenServer.cast(delegates, :cue)

  defp call(delegates, request, opts, default) do
    timeout = Keyword.get(opts, :timeout, default)
    GenServer.call(delegates, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_delegates}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, default)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         {:ok, sdb} <- Sessions.Table.open(Keyword.fetch!(opts, :sessions_db)) do
      keys = ~w(host sessions stream usage accounts projects launch)a
      s = Map.new(keys, &{&1, Keyword.fetch!(opts, &1)})

      s =
        Map.merge(s, %{
          db: db,
          sdb: sdb,
          notify: Keyword.get(opts, :notify, fn _ -> :ok end),
          clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
          pending: %{}
        })

      {:ok, s, {:continue, :settle}}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:settle, s) do
    Stream.read(s.stream, timeout: @step)
    for row <- Table.with_status(s.db, s.host, ~w(starting)), do: wake(s, row)

    {:noreply, settle(s)}
  end

  @impl true
  def handle_cast(:cue, s), do: {:noreply, settle(s)}

  @impl true
  def handle_call({:start, parent, project, branch, model, brief}, from, s) do
    with true <-
           Enum.all?([parent, model, brief], &(is_binary(&1) and &1 != "")) or
             {:refused, {:bad, :start}},
         {:ok, p} <- Turn.check(s.projects, project, branch),
         true <- Table.active(s.db, s.host, parent) < p.cap or {:refused, {:cap, p.cap}},
         {:ok, account} <- pick(s) do
      # StartAsked: the row first, as starting, with its brief's uuid.
      row = %{host: s.host, parent: parent, project: project, branch: branch, model: model}
      row = Map.merge(row, %{name: Turn.name(p, branch), account: account.name, brief: brief})
      row = Map.merge(row, %{brief_uuid: Stream.uuid(), deadline: deadline(s, p)})
      id = Table.starting(s.db, row)
      announce(s, id)
      {:noreply, call_sessions(s, Table.get(s.db, id), p, account, from)}
    else
      refused -> {:reply, refused, s}
    end
  end

  def handle_call({:held, parent}, _from, s) do
    keys = [:id, :name, :branch, :status, :text, :mark]
    {:reply, {:ok, Enum.map(Table.held(s.db, s.host, parent), &Map.take(&1, keys))}, s}
  end

  @impl true
  def handle_info({ref, answer}, s) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(s.pending, ref) do
      {nil, _} ->
        {:noreply, s}

      {%{id: id, from: from}, pending} ->
        s = %{s | pending: pending}
        {reply, s} = answered(s, Table.get(s.db, id), answer)
        if from, do: GenServer.reply(from, reply)
        {:noreply, s}
    end
  end

  def handle_info(:deadline, s), do: {:noreply, settle(s)}

  # Called: Sessions writes its own row first and runs on through a restart of this process.
  defp call_sessions(s, row, p, account, from) do
    launch = [role: :delegate, worktree: %{project: p, branch: row.branch}, model: row.model]
    launch = launch ++ s.launch

    task =
      Task.async(fn -> Sessions.start(s.sessions, row.name, account, launch, timeout: @call) end)

    put_in(s.pending[task.ref], %{id: row.id, from: from})
  end

  # CallAnswered and Settled: a start runs, then its brief goes in; or it is refused. An unknown
  # answer leaves the row as it is, for Settled to decide.
  defp answered(s, row, {:ok, %{session_id: sid}}) do
    write(s, row, status: "running", session_id: sid, reason: nil)
    row = Table.get(s.db, row.id)
    {brief, s} = running(s, row)
    {{:ok, Map.put(Map.take(row, [:id, :name, :session_id, :account]), :brief, brief)}, s}
  end

  defp answered(s, row, {:refused, why} = refused) do
    write(s, row, status: "refused", reason: why)
    {refused, s}
  end

  defp answered(s, row, {:unknown, why} = unknown) do
    write(s, row, reason: why)
    wake(s, row)
    {unknown, s}
  end

  # Every row with no call under way, read again.
  defp settle(s) do
    busy = MapSet.new(Map.values(s.pending), & &1.id)

    Table.with_status(s.db, s.host, ~w(starting running))
    |> Enum.reject(&MapSet.member?(busy, &1.id))
    |> Enum.reduce(s, &settle_row(&2, &1))
  end

  # Settled: by Sessions' row of this call (written at or after the call) once that row is
  # settled; with none past the deadline, the call never reached Sessions and is not made again.
  defp settle_row(s, %{status: "starting"} = row) do
    case Sessions.Table.get(s.sdb, s.host, row.name) do
      %{started_at: at, status: "running"} = srow when at >= row.called_at ->
        elem(answered(s, row, {:ok, srow}), 1)

      %{started_at: at, status: done} = srow
      when at >= row.called_at and done in ~w(refused stopped) ->
        elem(answered(s, row, {:refused, srow.reason || done}), 1)

      %{started_at: at} when at >= row.called_at ->
        s

      _ ->
        if s.clock.() >= row.deadline,
          do: elem(answered(s, row, {:refused, "interrupted"}), 1),
          else: s
    end
  end

  defp settle_row(s, row), do: elem(running(s, row), 1)

  # What a running row's Stream row says, and what it did: StopHandled, or InputWritten under
  # the row's uuid (answering Stream's answer).
  defp running(s, row) do
    with {:ok, fold} <- followed(s, row) do
      case Turn.next(row, fold) do
        {:finished, text} ->
          {:finished, hold(s, row, "finished", text)}

        {:write, uuid, text} ->
          {Stream.write(s.stream, row.session_id, {:message, uuid, text}), s}

        :exited ->
          # The kill path, a later unit (F-59 new-9, part 3), reads the transcript's last reply
          # and resumes once. Until then the row stays running and holds no report.
          {:exited, s}

        :waiting ->
          {:waiting, s}
      end
    else
      unread -> {unread, s}
    end
  end

  defp hold(s, row, status, text) do
    mark = "[report #{Stream.uuid()}]"
    write(s, row, status: status, report: "held", text: text, mark: mark)
    s
  end

  defp followed(s, row) do
    case Stream.rows(s.stream, timeout: @step) do
      {:ok, %{rows: rows}} ->
        found = Enum.find(rows, &(&1.session == row.session_id))
        if found, do: {:ok, found}, else: {:unknown, :not_followed}

      unread_or_failed ->
        unread_or_failed
    end
  end

  defp pick(s) do
    with {:ok, %{readings: readings}} <- Usage.readings(s.usage, timeout: @step),
         {:ok, name} <- Usage.pick(readings, s.accounts.names) do
      Accounts.ready(s.accounts, name)
    else
      :unread -> {:refused, {:usage, :unread}}
      other -> other
    end
  end

  # A call's wall-clock deadline: Sessions' own timeout, the setup's and Sessions' slack.
  defp deadline(s, p), do: s.clock.() + @call + p.setup_timeout + @slack

  # One wake at a cut-off call's deadline, when Settled may decide; not a poll.
  defp wake(s, row), do: Process.send_after(self(), :deadline, max(row.deadline - s.clock.(), 0))

  defp write(s, row, fields) do
    Table.update(s.db, row.id, fields)
    announce(s, row.id)
  end

  defp announce(s, id), do: s.notify.(%{topic: "delegates:#{s.host}", ids: [id]})
end
