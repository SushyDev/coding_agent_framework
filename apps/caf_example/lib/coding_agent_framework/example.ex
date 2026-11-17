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

  **Cues.** It routes no cue itself. One `CodingAgentFramework.Cues` starts after the reaper,
  with each reading part's own declaration (`reads/0`), and every part's `notify:` goes to it.
  Each part is named to `Cues` as it starts, so a part a restart replaced gets the cues from
  then on, and one not started yet misses nothing: every part reads its whole table when it
  starts. `Stream`, `Jobs` and `Services` read on the config's `interval` as the other readers
  do; no ticker sends a made-up topic.

  **The operator.** The app's own acts on agents, from a view say, go through
  `CodingAgentFramework.Operator` with `parts(sup).mcp`, under the config's `operator` name,
  which every part's `Grants` knows: the same checks, claims and call log as an agent's tools.

  **Asks.** An agent asks a person through its `ask` tool, which answers at once. The app shows
  the open asks (`Mailbox.open_asks(parts(sup).mailbox)`, one by id with `Mailbox.asked/3`) as
  dialogs, and answers each once with `Mailbox.answer/4`; the answer goes to the agent that
  asked as a message from the operator, one line per question.

  **The tree.** It opens no part's table: the tree `Grants` reads, an agent's worktree, the
  agent a hook names and whether an agent has ended are `Sessions.Agents`' functions over the
  agent rows. Until `Mains`, it hands `Sessions` the main sessions the config declares.

  **Once per start.** `start_link/1` makes `Acts`' `start_id` and the hooks' secret, and
  writes each account's files with that secret, before any part starts.

  Nothing it starts acts outside the framework home but its own tmux server (whose socket is in
  the home) and its two ports.
  """

  use Supervisor

  alias CodingAgentFramework.{Accounts, Acts, Copies, Delegates, Grants, Holder, Host, Inlet}

  alias CodingAgentFramework.{
    Cues,
    Intake,
    Jobs,
    Mailbox,
    MCP,
    Mover,
    Programs,
    Recoveries,
    Registry,
    Services
  }

  alias CodingAgentFramework.{Scheduler, Sessions, Shell, Stream, Tmux, TmuxSampler, Tracker}
  alias CodingAgentFramework.{Transcripts, Usage}
  alias CodingAgentFramework.Example.{Config, Ends}

  require Logger

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
         {:ok, agents} <- Sessions.Agents.open(Config.path(c, "caf.db"), c.workstation),
         {:ok, work} <-
           Delegates.Work.open(Config.path(c, "caf.db"), Config.path(c, "caf.db"), c.workstation),
         {:ok, allowance} <- Usage.Allowance.open(Config.path(c, "caf.db")),
         secret = token(),
         :ok <- prepare(c, accounts, programs, secret) do
      w = %{c: c, programs: programs, tmux: tmux, accounts: accounts, holder: holder}
      w = Map.merge(w, %{agents: agents, secret: secret, start_id: token()})
      w = Map.merge(w, %{work: work, allowance: allowance})
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

  @doc """
  What each part it starts reads, as the part declares it: the declarations it hands `Cues`,
  and all the routing it does.
  """
  @spec reads() :: [{atom, Cues.declaration()}]
  def reads do
    [
      sessions: Sessions.reads(),
      recoveries: Recoveries.reads(),
      tracker: Tracker.reads(),
      mailbox: Mailbox.reads(),
      delegates: Delegates.reads(),
      mover: Mover.reads(),
      scheduler: Scheduler.reads(),
      ends: Ends.reads()
    ]
  end

  @impl true
  def init(w) do
    tab = :ets.new(__MODULE__, [:public, read_concurrency: true])
    notify = fn cue -> Cues.cue(lookup(tab, :cues), cue) end

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
      Cues.started(lookup(tab, :cues), key, pid)
      watch(tab, key, pid)
      {:ok, pid}
    end
  end

  # A raised error, as the app records it (F-126's new-1): a part's process that ends by a
  # crash, not a `{:unknown, reason}` answer, which its caller already holds and an act's row
  # already settles `unknown`. One unlinked watcher per part's process, which ends with it;
  # `Acts` is looked up when the crash is seen, so a part `rest_for_one` ends with it, or a
  # tree stopped whole, records nothing. A crash of `Acts` itself is not recorded in it.
  defp watch(_tab, :acts, _pid), do: :ok

  defp watch(tab, key, pid) do
    spawn(fn ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _, reason} ->
          if crash?(reason), do: raised(lookup(tab, :acts), key, reason)
      end
    end)
  end

  defp crash?(reason) when reason in [:normal, :shutdown], do: false
  defp crash?({:shutdown, _}), do: false
  defp crash?(_), do: true

  defp raised(nil, _key, _reason), do: :ok

  defp raised(acts, key, reason) do
    text = reason |> Exception.format_exit() |> String.slice(0, 2_000)

    case Acts.record(acts, "app", "part:#{key}", :error, :failed, reason: text) do
      {:ok, _} -> :ok
      other -> Logger.warning("caf: the crash of #{key} has no row in Acts: #{inspect(other)}")
    end
  end

  defp children(w, notify) do
    %{c: c, programs: p, db: db} = w
    grants = Grants.new(fn -> Sessions.Agents.read_tree(w.agents) end, operator: c.operator)
    {host, every} = {c.workstation, c.interval}
    hosts = Map.put(c.hosts, host, %{programs: p, dir: Config.path(c, "ws")})

    # One Registry and one Transcripts on the host, over every account: a move hides no agent.
    dirs =
      for a <- c.accounts,
          {:ok, dir} = Accounts.config_dir(w.accounts, a),
          into: %{},
          do: {a, dir}

    notify_every = [notify: notify, interval: every]
    read = [programs: p, db: db] ++ notify_every

    readers = [
      {:registry, fn _ -> {Registry, [accounts: dirs] ++ read} end},
      {:transcripts, fn _ -> {Transcripts, [accounts: c.accounts] ++ read} end}
    ]

    [
      {:reaper, fn _ -> {Shell.Reaper, programs: p} end},
      {:cues, fn _ -> {Cues, parts: reads()} end},
      # Before every part that writes its acts there.
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
      {:inlet, fn _ -> {Inlet, tmux: w.tmux} end},
      {:usage,
       fn _ ->
         {Usage, accounts: w.accounts, host: host, db: db, notify: notify, interval: every}
       end},
      {:stream,
       fn _ ->
         {Stream, [programs: p, holder: w.holder, home: c.home, db: db] ++ notify_every}
       end},
      {:intake,
       fn _ ->
         tools = Map.to_list(Map.take(c.tool_hooks, [:pre_tool_use, :post_tool_use]))
         agent = &Sessions.Agents.by_session(w.agents, &1, &2)
         {Intake, [db: db, host: host, notify: notify, agent: agent] ++ tools}
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
             # Until `Mains`: each main session the config declares, as an agent row.
             # A startup dialog waits on a person (F-140): the app answers none on its own,
             # and the operator answers through `Operator.answer_startup/4`.
             reaper: pid.(:reaper),
             programs: p,
             dir: Config.path(c, "d"),
             tmux: w.tmux,
             registry: pid.(:registry),
             stream: pid.(:stream),
             home: c.home,
             db: db,
             notify: notify,
             inlet: pid.(:inlet),
             dialog: &Sessions.Dialog.ask/2,
             open_to: &Mailbox.open_to(pid.(:mailbox), &1, status: &2),
             waiter: %{port: c.ports.intake, secret: w.secret},
             acts: pid.(:acts),
             mains: Map.new(c.mains, fn {project, name} -> {name, project} end)
           }
         end},
        {:recoveries,
         fn pid ->
           {Recoveries,
            server: w.tmux,
            holder: w.holder,
            programs: w.programs,
            sampler: pid.(:sampler),
            sessions: pid.(:sessions),
            acts: pid.(:acts)}
         end},
        {:tracker, fn _ -> {Tracker, sources: sources(w)} end},
        # Before `Delegates`, which asks it for a lease before each start. The owners' answers
        # and the allowance are read through connections of its own, never by a call.
        {:scheduler,
         fn _ ->
           {Scheduler,
            db: db,
            host: host,
            resources: c.resources,
            holders: %{"delegate" => &Delegates.Work.state(w.work, &1)},
            allowance: &Usage.Allowance.check(w.allowance, &1),
            pressure: pressure(c),
            interval: every,
            notify: notify}
         end},
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
            inlet: pid.(:inlet),
            registry: pid.(:registry),
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
            registry: pid.(:registry),
            mailbox: pid.(:mailbox),
            launch: [claude: c.claude, env: c.env, tool_timeout: c.tool_timeout],
            projects: c.projects,
            mcp: &issue(pid.(:mcp), &1),
            acts: pid.(:acts),
            scheduler: pid.(:scheduler),
            lease: c.lease,
            notify: notify}
         end},
        # After `Delegates`, whose launch a delegate's move resumes with.
        {:mover,
         fn pid ->
           {Mover,
            host: host,
            sessions: pid.(:sessions),
            sessions_db: db,
            mailbox: pid.(:mailbox),
            accounts: w.accounts,
            usage: pid.(:usage),
            acts: pid.(:acts),
            launch: &launch(c, pid, &1)}
         end},
        {:copies, fn _ -> {Copies, dir: Config.path(c, "parts/copies"), programs: p} end},
        {:jobs,
         fn pid ->
           {Jobs,
            [
              dir: Config.path(c, "parts/jobs"),
              copies: pid.(:copies),
              hosts: hosts,
              on_late_end: &late_end(c, pid, &1)
            ] ++ notify_every}
         end},
        {:services,
         fn pid ->
           {Services,
            [
              dir: Config.path(c, "parts/services"),
              copies: pid.(:copies),
              grants: grants,
              ended: &Sessions.Agents.ended?(Sessions.Agents.get(w.agents, &1)),
              hosts: hosts,
              workstation: host,
              acts: pid.(:acts)
            ] ++ notify_every}
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
            place: &Sessions.Agents.place(w.agents, &1),
            instance: c.instance,
            tool_timeout: c.tool_timeout,
            margin: c.margin,
            acts: pid.(:acts),
            mover: {Mover, pid.(:mover)},
            sessions: {Sessions, pid.(:sessions)}}
         end},
        {:mcp_http,
         fn pid ->
           plug = {MCP.Plug, mcp: pid.(:mcp)}
           {Bandit, plug: plug, ip: @local, port: c.ports.mcp, startup_log: false}
         end},
        {:ends,
         fn pid ->
           ended = &Sessions.Agents.ended_names(w.agents, &1)
           {Ends, ended: ended, act: &owner_ended(pid.(:services), &1)}
         end}
      ]
  end

  defp sources(%{c: c, db: db, tmux: tmux}) do
    {_, server} = Tmux.key(tmux)
    on = [db: db, host: c.workstation]

    kinds = [
      {Tracker.TableSource, table: Registry.Table},
      {Tracker.TableSource, table: Transcripts.Table},
      {Tracker.TableSource, table: Usage.Table},
      {Tracker.TableSource, table: Intake.Table}
    ]

    for(a <- c.accounts, {k, table} <- kinds, do: {k, table ++ on ++ [account: a]}) ++
      [
        {Tracker.TableSource, [table: Stream.Table] ++ on},
        {Tracker.TableSource, [table: Sessions.Table] ++ on},
        {Tracker.TableSource, [table: Delegates.Table] ++ on},
        {Tracker.TableSource, [table: Scheduler.Table] ++ on},
        {Tracker.TableSource, [table: TmuxSampler.Table] ++ on ++ [server: server]},
        {Tracker.TableSource, [table: Acts.Table] ++ on ++ [instance: c.instance]}
      ]
  end

  # A moved agent's launch on its new account: a delegate's as `Delegates` keeps it, a main
  # session's from the config, each with a new MCP config. The row's own options are its own.
  defp launch(c, pid, row) do
    base =
      if row.kind == "delegate",
        do: Delegates.launch(pid.(:delegates), row.name),
        else: {:ok, [role: :parent, cwd: row.cwd, claude: c.claude, env: c.env]}

    # `MCP` starts after `Mover`: a resume a restart left waits for it, and is not refused.
    mcp = if mcp = pid.(:mcp), do: issue(mcp, row.name), else: {:unknown, :no_mcp}

    with {:ok, launch} <- base,
         {:ok, mcp} <- mcp,
         do: {:ok, Keyword.merge(launch, tool_timeout: c.tool_timeout, mcp: mcp)}
  end

  # Stall times where the host has them; elsewhere no pressure gate, only the static capacities.
  defp pressure(%Config{pressure: nil}) do
    if File.dir?("/proc/pressure"), do: [source: :psi], else: [source: :none]
  end

  defp pressure(%Config{pressure: pressure}), do: pressure

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
