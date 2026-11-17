defmodule CodingAgentFramework.Example do
  @moduledoc """
  The embedding app: one supervision tree that starts every built part on the workstation, in
  order, from one `CodingAgentFramework.Example.Config`, and wires each part's cues and
  callbacks. The libraries start nothing; this is where they are started.

      {:ok, config} = Config.new(home: "/srv/caf", instance: "a", programs: programs, ...)
      {:ok, sup} = CodingAgentFramework.Example.start_link(config)
      CodingAgentFramework.Example.parts(sup).mcp
      #=> #PID<0.321.0>

  **Order.** The tree is `:rest_for_one`, and the host's `Shell.Reaper` is its first child, so
  every process that runs commands with it starts after it and is restarted with it (the
  reaper's death ends every group it held). Each part starts after the parts it is given. The
  two HTTP endpoints start after the part they serve, on 127.0.0.1.

  **Cues.** Each part's `notify:` goes to the `Tracker` and to the parts `@routes` names for its
  topic. A cue is looked up to the current process of each part at the moment it is sent, so a
  part a restart replaced gets the cues from then on, and one not started yet misses nothing:
  every part reads its whole table when it starts.

  **The operator.** The app's own acts on agents, from a view say, go through
  `CodingAgentFramework.Operator` with `parts(sup).mcp`, under the config's `operator` name,
  which every part's `Grants` knows: the same checks, claims and call log as an agent's tools.

  **Once per start.** `start_link/1` makes `Acts`' `start_id` and the hooks' secret, and
  writes each account's files with that secret, before any part starts.

  Nothing it starts acts outside the framework home but its own tmux server (whose socket is in
  the home) and its two ports.
  """

  use Supervisor

  alias CodingAgentFramework.{Accounts, Acts, Control, Copies, Delegates, Grants, Holder, Host}

  alias CodingAgentFramework.{
    Intake,
    Jobs,
    Mailbox,
    MCP,
    Programs,
    Recoveries,
    Registry,
    Services
  }

  alias CodingAgentFramework.{Sessions, Shell, Stream, Tmux, TmuxSampler, Tracker, Transcripts}
  alias CodingAgentFramework.{Usage}
  alias CodingAgentFramework.Example.{Config, Ends, Ticker}

  require Logger

  # The parts each reader's cue reaches besides the Tracker, by the topic's first word.
  @routes %{
    "registry" => [:sessions],
    "stream" => [:sessions, :delegates, :mailbox],
    "tmux" => [:sessions, :recoveries],
    "sessions" => [:delegates, :mailbox],
    "transcripts" => [:delegates],
    "delegates" => [:mailbox, :ends],
    "mailbox" => [:delegates],
    "waiters" => [:mailbox]
  }
  # A delegate that holds its parent's cap, and so is in the tree `Grants` reads.
  @tree ~w(starting running resuming finished failed)
  # The statuses of a delegate that has ended.
  @ended ~w(refused failed ended)
  @local {127, 0, 0, 1}

  @doc """
  Starts the tree. Answers `{:ok, pid}`, `{:refused, reason}` when the config's programs,
  accounts or home cannot be used, or `{:unknown, reason}` when a write under the home fails.
  """
  @spec start_link(Config.t()) :: Supervisor.on_start() | {:refused, term} | {:unknown, term}
  def start_link(%Config{} = c) do
    with :ok <- mkdirs(c),
         {:ok, programs} <- programs(c),
         {:ok, tmux} <- server(c),
         {:ok, accounts} <- Accounts.new(c.home, c.accounts),
         {:ok, holder} <- Holder.new(programs, Config.path(c, "d")),
         {:ok, ddb} <- Delegates.Table.open(Config.path(c, "caf.db")),
         {:ok, sdb} <- Sessions.Table.open(Config.path(c, "caf.db")),
         secret = token(),
         :ok <- prepare(c, accounts, programs, secret) do
      w = %{c: c, programs: programs, tmux: tmux, accounts: accounts, holder: holder}
      w = Map.merge(w, %{ddb: ddb, sdb: sdb, secret: secret, start_id: token()})
      Supervisor.start_link(__MODULE__, Map.put(w, :db, Config.path(c, "caf.db")))
    end
  end

  @doc "The framework's own tmux server: a socket in the home."
  @spec server(Config.t()) :: {:ok, Tmux.t()} | {:refused, term}
  def server(%Config{} = c) do
    with {:ok, programs} <- programs(c),
         do: Tmux.CLI.new(programs, {:socket, Config.path(c, "tmux.sock")})
  end

  @doc "Each part's process, by its key (`:sessions`, `:registry`, …)."
  @spec parts(Supervisor.supervisor()) :: %{term => pid}
  def parts(sup), do: Map.new(Supervisor.which_children(sup), fn {k, pid, _, _} -> {k, pid} end)

  @impl true
  def init(w) do
    tab = :ets.new(__MODULE__, [:public, read_concurrency: true])
    notify = fn cue -> route(tab, cue) end

    children =
      for {key, build} <- children(w, notify),
          do: %{id: key, start: {__MODULE__, :start_part, [tab, key, build]}}

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  # Runs in the supervisor: `build` gets the current process of each part started before it.
  def start_part(tab, key, build) do
    {module, opts} = build.(&lookup(tab, &1))

    with {:ok, pid} <- module.start_link(opts) do
      :ets.insert(tab, {key, pid})
      {:ok, pid}
    end
  end

  defp children(w, notify) do
    %{c: c, programs: p, db: db} = w
    grants = Grants.new(tree(w), operator: c.operator)
    {host, every} = {c.workstation, c.interval}
    hosts = Map.put(c.hosts, host, %{programs: p, dir: Config.path(c, "ws")})

    # One Registry and one Transcripts on the host, over every account: a move hides no agent.
    dirs =
      for a <- c.accounts,
          {:ok, dir} = Accounts.config_dir(w.accounts, a),
          into: %{},
          do: {a, dir}

    read = [programs: p, db: db, notify: notify, interval: every]

    readers = [
      {:registry, fn _ -> {Registry, [accounts: dirs] ++ read} end},
      {:transcripts, fn _ -> {Transcripts, [accounts: c.accounts] ++ read} end}
    ]

    [
      {:reaper, fn _ -> {Shell.Reaper, programs: p} end},
      {:control, fn _ -> {Control, tmux: w.tmux} end},
      {:usage,
       fn _ ->
         {Usage, accounts: w.accounts, host: host, db: db, notify: notify, interval: every}
       end},
      {:stream,
       fn _ -> {Stream, programs: p, holder: w.holder, home: c.home, db: db, notify: notify} end},
      {:intake,
       fn _ ->
         tools = Map.to_list(Map.take(c.tool_hooks, [:pre_tool_use, :post_tool_use]))
         {Intake, [db: db, host: host, notify: notify, agent: agent_of(w)] ++ tools}
       end},
      {:intake_http,
       fn pid ->
         plug = {Intake.Plug, intake: pid.(:intake), secret: w.secret}
         {Bandit, plug: plug, ip: @local, port: c.ports.intake, startup_log: false}
       end},
      {:sampler,
       fn _ ->
         {TmuxSampler, server: w.tmux, holder: w.holder, db: db, notify: notify, interval: every}
       end}
    ] ++
      readers ++
      [
        {:sessions,
         fn pid ->
           {
             Sessions,
             # Mailbox starts after Sessions: it is looked up at each read.
             reaper: pid.(:reaper),
             programs: p,
             dir: Config.path(c, "d"),
             control: pid.(:control),
             registry: pid.(:registry),
             stream: pid.(:stream),
             home: c.home,
             db: db,
             notify: notify,
             open_to: &Mailbox.open_to(pid.(:mailbox), &1, status: &2),
             waiter: %{port: c.ports.intake, secret: w.secret}
           }
         end},
        {:acts,
         fn _ ->
           {Acts,
            db: db,
            start_id: w.start_id,
            host: host,
            instance: c.instance,
            notify: notify,
            claims: Config.path(c, "claims.db")}
         end},
        {:recoveries,
         fn pid ->
           {Recoveries,
            server: w.tmux,
            holder: w.holder,
            programs: w.programs,
            sampler: pid.(:sampler),
            control: pid.(:control),
            sessions: pid.(:sessions),
            acts: pid.(:acts)}
         end},
        {:tracker, fn _ -> {Tracker, sources: sources(w)} end},
        # Before `Delegates`, which stores each brief and report in it.
        {:mailbox,
         fn pid ->
           {Mailbox,
            db: db,
            grants: grants,
            stream: pid.(:stream),
            sessions_db: db,
            host: host,
            intake: pid.(:intake),
            transcripts: pid.(:transcripts),
            accounts: w.accounts,
            notify: notify}
         end},
        {:delegates,
         fn pid ->
           {Delegates,
            host: host,
            db: db,
            sessions_db: db,
            sessions: pid.(:sessions),
            stream: pid.(:stream),
            usage: pid.(:usage),
            accounts: w.accounts,
            transcripts: pid.(:transcripts),
            mailbox: pid.(:mailbox),
            launch: [claude: c.claude, env: c.env, tool_timeout: c.tool_timeout],
            projects: c.projects,
            mcp: &issue(pid.(:mcp), &1),
            notify: notify}
         end},
        {:copies, fn _ -> {Copies, dir: Config.path(c, "parts/copies"), programs: p} end},
        {:jobs,
         fn pid ->
           {Jobs,
            dir: Config.path(c, "parts/jobs"),
            copies: pid.(:copies),
            hosts: hosts,
            on_late_end: &late_end(c, pid, &1)}
         end},
        {:services,
         fn pid ->
           {Services,
            dir: Config.path(c, "parts/services"),
            copies: pid.(:copies),
            grants: grants,
            ended: ended(w),
            hosts: hosts,
            workstation: host}
         end},
        {:mcp,
         fn pid ->
           {MCP,
            dir: Config.path(c, "parts/mcp"),
            port: c.ports.mcp,
            grants: grants,
            mailbox: {Mailbox, pid.(:mailbox)},
            jobs: {Jobs, pid.(:jobs)},
            delegates: {Delegates, pid.(:delegates)},
            services: {Services, pid.(:services)},
            workstation: host,
            tracker: {Tracker, pid.(:tracker)},
            stream: {Stream, pid.(:stream)},
            transcripts: {Transcripts, pid.(:transcripts)},
            place: place(w),
            instance: c.instance,
            tool_timeout: c.tool_timeout,
            margin: c.margin,
            acts: pid.(:acts)}
         end},
        {:mcp_http,
         fn pid ->
           plug = {MCP.Plug, mcp: pid.(:mcp)}
           {Bandit, plug: plug, ip: @local, port: c.ports.mcp, startup_log: false}
         end},
        {:ticker, fn pid -> {Ticker, interval: every, tick: fn -> tick(pid) end} end},
        {:ends,
         fn pid ->
           {Ends, ended: ended_ids(w), act: &owner_ended(pid.(:services), &1)}
         end}
      ]
  end

  # The reader with no timer of its own, and the settles of `Jobs` and `Services`, which
  # wait on hosts rather than on a reader's cue. `pid` looks each part up at the tick.
  defp tick(pid) do
    Stream.read(pid.(:stream))
    Jobs.cue(pid.(:jobs), %{topic: "tick"})
    Services.cue(pid.(:services), %{topic: "tick"})
  end

  defp sources(%{c: c, db: db, tmux: tmux}) do
    {_, server} = Tmux.key(tmux)
    on = [db: db, host: c.workstation]

    kinds = [
      {Tracker.ReaderSource, table: Registry.Table},
      {Tracker.SessionsSource, []},
      {Tracker.ReaderSource, table: Transcripts.Table},
      {Tracker.ReaderSource, table: Usage.Table},
      {Tracker.IntakeSource, []}
    ]

    for(a <- c.accounts, {k, table} <- kinds, do: {k, table ++ on ++ [account: a]}) ++
      [
        {Tracker.StreamSource, on},
        {Tracker.DelegatesSource, on},
        {Tracker.ReaderSource, [table: TmuxSampler.Table] ++ on ++ [server: server]},
        {Tracker.ReaderSource, [table: Acts.Table] ++ on ++ [instance: c.instance]}
      ]
  end

  # Until `Mains`, the tree is each main session the config declares, as a root, and
  # `Delegates`' rows.
  defp tree(%{ddb: ddb, c: c}) do
    mains = for {project, name} <- c.mains, do: %{name: name, project: project, parent: nil}
    fn -> mains ++ Delegates.Table.with_status(ddb, c.workstation, @tree) end
  end

  # The copy an agent's jobs and services run in: its project, its name, and its worktree, the
  # cwd of its `Sessions` row. A main session has none until `Mains`.
  defp place(%{ddb: ddb, sdb: sdb, c: c}) do
    fn agent ->
      with %{project: project} <- latest(ddb, c.workstation, agent),
           %{cwd: cwd} <- Sessions.Table.get(sdb, c.workstation, agent) do
        {:ok, %{project: project, name: agent, worktree: cwd}}
      else
        _ -> {:refused, :no_worktree}
      end
    end
  end

  # The agent a tool call's session is, by its `Sessions` row; nil for a session the framework
  # did not start.
  defp agent_of(%{sdb: sdb, c: c}) do
    fn account, session_id ->
      Enum.find_value(Sessions.Table.rows(sdb, c.workstation, account), fn row ->
        if row.session_id == session_id, do: row.name
      end)
    end
  end

  # An agent has ended once its latest start was refused, it failed, or it was stopped after its
  # report (`ended`): no process of it runs again.
  defp ended(%{ddb: ddb, c: c}),
    do: fn agent ->
      match?(%{status: s} when s in @ended, latest(ddb, c.workstation, agent))
    end

  # The delegates that have ended, by `ended`'s rule, among `ids` (or all), each once.
  defp ended_ids(%{ddb: ddb, c: c}) do
    fn ids ->
      rows = Delegates.Table.rows(ddb, c.workstation)
      latest = Map.new(rows, &{&1.name, &1})

      for {name, %{id: id, status: s}} <- latest,
          s in @ended and (ids == :all or id in ids),
          do: name
    end
  end

  defp latest(ddb, host, agent),
    do: ddb |> Delegates.Table.rows(host) |> Enum.filter(&(&1.name == agent)) |> List.last()

  defp issue(nil, _agent), do: {:refused, :no_mcp}
  defp issue(mcp, agent), do: MCP.issue(mcp, agent)

  defp owner_ended(services, owner) do
    case Services.owner_ended(services, owner) do
      {:ok, _} -> :ok
      other -> Logger.warning("caf: services of #{owner}, who ended: #{inspect(other)}")
    end
  end

  # A job's end that its call did not wait for goes to the job's caller as a message from
  # `framework`, once per job. It runs in `Jobs`' process, which may be starting before `MCP`,
  # so the caller is read from `MCP`'s call log on disk. An end that cannot be stored (`Mailbox`
  # did not answer) is `{:unknown, reason}`: `Jobs` keeps it owed and hands it again at its next
  # cue. One with no caller is logged, and answered `:ok`: nothing will ever store it.
  defp late_end(c, pid, %{job: job, end: e}) do
    text = "Your job #{job} ended after its call answered: #{inspect(e)}. Nothing was fetched."

    with {:ok, agent} <- MCP.caller(Config.path(c, "parts/mcp"), c.instance, job),
         {:ok, _} <- Mailbox.notify(pid.(:mailbox), agent, text, key: "job:" <> job) do
      :ok
    else
      {:refused, reason} when reason != :no_mailbox ->
        Logger.warning("caf: job #{job}'s late end has no caller: #{inspect(reason)}")

      other ->
        {:unknown, {:not_stored, other}}
    end
  end

  defp route(tab, %{topic: topic} = cue) do
    [kind | _] = String.split(topic, ":")
    # A session's waiter coming or going, of Intake's cues, is the one Mailbox tries rows on.
    kind = if kind == "intake" and String.ends_with?(topic, ":waiters"), do: "waiters", else: kind

    for key <- [:tracker | Map.get(@routes, kind, [])], pid = lookup(tab, key) do
      case key do
        :recoveries -> Recoveries.cue(pid)
        :tracker -> Tracker.cue(pid, cue)
        :sessions -> Sessions.cue(pid, cue)
        :delegates -> Delegates.cue(pid, cue)
        :mailbox -> Mailbox.cue(pid, cue)
        :ends -> Ends.cue(pid, cue)
      end
    end

    :ok
  end

  defp route(_tab, _cue), do: :ok

  # A table the supervisor took with it reads as no process: a cue must not raise.
  defp lookup(tab, key) do
    case :ets.lookup(tab, key) do
      [{^key, pid}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp prepare(c, accounts, programs, secret) do
    tools = Map.keys(Map.take(c.tool_hooks, [:pre_tool_use, :post_tool_use]))
    data = %{programs: programs, intake: %{port: c.ports.intake, secret: secret, tools: tools}}

    Enum.reduce_while(c.accounts, :ok, fn a, :ok ->
      case Accounts.prepare(accounts, a, data) do
        {:ok, _} -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp programs(c) do
    case Map.fetch(c.programs, :kill) do
      {:ok, kill} -> Programs.new(Host.local(c.workstation, kill), c.programs)
      :error -> {:refused, {:no_program, :kill}}
    end
  end

  defp mkdirs(c) do
    Enum.reduce_while(["d", "parts", "ws"], :ok, fn dir, :ok ->
      case File.mkdir_p(Config.path(c, dir)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:unknown, {Config.path(c, dir), reason}}}
      end
    end)
  end

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
