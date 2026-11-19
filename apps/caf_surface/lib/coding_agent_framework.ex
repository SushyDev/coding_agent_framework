defmodule CodingAgentFramework do
  @moduledoc """
  Runs and supervises Claude Code agents across Claude accounts and machines: the app's
  surface ("The app's surface" in `docs/design.md`, B3's start, F-169). One config in, checked
  whole (`CodingAgentFramework.Config.new/1`, each refusal naming its key, the app's extensions
  and tool callbacks among them), and one supervisor that starts every built part on the
  workstation in order and wires each part's cues and callbacks. The other apps are libraries
  that start nothing; this supervisor is where they are started, and the embedding app wires
  nothing else.

      {:ok, config} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", ...)
      children = [{CodingAgentFramework, config}]
      Supervisor.start_link(children, strategy: :one_for_one)

  or `CodingAgentFramework.start_link(config)`, and then `parts(sup).mcp` for the operator's
  calls. The protocols the parts follow are written and checked first, as TLA+ specs in
  `model/tla/` (`bin/check-model`). Two instances, each with its own home, ports and instance
  name, run in one app: nothing in it is named globally.

  **Order.** The tree is `:rest_for_one`, and the host's `Shell.Reaper` is its first child, so
  every process that runs commands with it starts after it and is restarted with it (the
  reaper's death ends every group it held). Each part starts after the parts it is given. The
  two HTTP endpoints start after the part they serve, on 127.0.0.1.

  **Cues.** It routes no cue itself. One `CodingAgentFramework.Cues` starts after the reaper,
  with each reading part's own declaration (`reads/0`), and every part's `notify:` goes to it.
  Each part is named to `Cues` as it starts, so a part a restart replaced gets the cues from
  then on, and one not started yet misses nothing: every part reads its whole table when it
  starts. `Stream`, `Jobs` and `Services` read on the config's `interval` as the other readers
  do; no ticker sends a made-up topic. The app's own processes get the cues too, by
  `subscribe/2`: the instance is found by its name in its own `Registry`, never a global name.

  **The operator.** The app's own acts on agents, from a view say, go through
  `CodingAgentFramework.Operator` with `parts(sup).mcp`, under the config's `operator` name,
  which every part's `Grants` knows: the same checks, claims and call log as an agent's tools.

  **Asks.** An agent asks a person through its `ask` tool, which answers at once. The app shows
  the open asks (`Mailbox.open_asks(parts(sup).mailbox)`, one by id with `Mailbox.asked/3`) as
  dialogs, and answers each once with `Mailbox.answer/4`; the answer goes to the agent that
  asked as a message from the operator, one line per question. An ask a person dismisses in the
  app is withdrawn (`Mailbox.withdraw/4`, or the operator's `Operator.withdraw/3`): the agent
  reads the reason in the answer's place, and the first of the two settles the ask (F-172).

  **The tree.** It opens no part's table: the tree `Grants` reads, an agent's worktree, the
  agent a hook names and whether an agent has ended are `Sessions.Agents`' functions over the
  agent rows. `Mains` declares the main sessions the config names, holds each project's
  checkout and its pull, and starts a main session (`start_main`): the app calls
  `Mains.landed/2` when something landed in a project's trunk.

  **Once per start.** `start_link/1` makes `Acts`' `start_id`, reads the hooks' secret, kept
  per home (`Intake.secret/1` on `<home>/intake.secret`, made at the first start), and writes
  each account's files with that secret, before any part starts. A session held across a
  restart keeps its hooks: its settings name the same secret.

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
    Mains,
    MCP,
    Mover,
    Programs,
    Recoveries,
    Registry,
    Services
  }

  alias CodingAgentFramework.{Runs, Scheduler, Sessions, Shell, Stream, Tmux, TmuxSampler}
  alias CodingAgentFramework.Tracker
  alias CodingAgentFramework.{ToolHome, Transcripts, Usage}
  alias CodingAgentFramework.{Config, Endpoint, Ends}

  require Logger

  @local {127, 0, 0, 1}
  @names "Elixir.CodingAgentFramework.Instance."

  @doc """
  The tree as one child of the app's own supervisor, by the instance's name, so two instances
  are two children. A start that `start_link/1` refuses or cannot settle fails the app's start
  with `{:refused, reason}` or `{:unknown, reason}` as its error.

      iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
      ...>   programs: %{}, accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
      ...>   env: %{}, user: "me")
      iex> %{id: id, type: :supervisor} = CodingAgentFramework.child_spec(c)
      iex> id
      {CodingAgentFramework, "a"}
  """
  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = c) do
    %{id: {__MODULE__, c.instance}, start: {__MODULE__, :start_child, [c]}, type: :supervisor}
  end

  @doc false
  # A supervisor takes `{:ok, pid}` or `{:error, reason}`; the explicit outcomes become the
  # error, unchanged.
  def start_child(c) do
    case start_link(c) do
      {:ok, pid} -> {:ok, pid}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  @doc """
  Starts the tree from a config `Config.new/1` checked. Answers `{:ok, pid}`, `{:refused,
  reason}` when the config's programs, accounts or home cannot be used or an instance of its
  name already runs in this app (`{:instance_running, name}`), or `{:unknown,
  reason}` when a write under the home fails.
  """
  @spec start_link(Config.t()) :: Supervisor.on_start() | {:refused, term} | {:unknown, term}
  def start_link(%Config{} = c) do
    with :ok <- unique(c),
         :ok <- mkdirs(c),
         {:ok, programs} <- programs(c),
         {:ok, c} <- tools(c, programs),
         {:ok, tmux} <- server(c),
         {:ok, accounts} <- Accounts.new(c.home, c.accounts),
         {:ok, holder} <- Holder.new(programs, Config.path(c, "d")),
         {:ok, agents} <- Sessions.Agents.open(Config.path(c, "caf.db"), c.workstation),
         {:ok, work} <-
           Delegates.Work.open(Config.path(c, "caf.db"), Config.path(c, "caf.db"), c.workstation),
         {:ok, allowance} <- Usage.Allowance.open(Config.path(c, "caf.db")),
         {:ok, jobs_work} <- Jobs.Work.open(Config.path(c, "parts/jobs")),
         {:ok, mains_work} <-
           Mains.Work.open(Config.path(c, "caf.db"), Config.path(c, "caf.db"), c.workstation),
         {:ok, secret} <- Intake.secret(Config.path(c, "intake.secret")),
         :ok <- prepare(c, accounts, programs, secret),
         {:ok, runs} <- Runs.new(c.home, programs, c.heavy),
         :ok <- Runs.prepare(runs, programs, c.ports.intake, secret) do
      w = %{c: c, programs: programs, tmux: tmux, accounts: accounts, holder: holder}
      w = Map.merge(w, %{agents: agents, secret: secret, start_id: token()})
      w = Map.merge(w, %{work: work, allowance: allowance, jobs_work: jobs_work})
      w = Map.merge(w, %{mains_work: mains_work, runs: runs})
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
  The calling process gets each later cue on `topics` as a message `{:caf_cue, cue}`, for as
  long as it lives, from the instance the config named `instance`. Delivery is a plain `send`
  after the parts got the cue, so a slow or crashed subscriber touches nothing in the tree; a
  subscriber is monitored and removed when it exits. It survives a restart of `Cues`.

  A topic is a pattern of words joined by `:`, `*` for any one word, matching each topic that
  begins with its words: `"sessions"` matches `"sessions:ws"`, and `"sessions:"` is the same.
  The topics an app may name are the ones the parts declare (`topics/1`); any other is refused.
  Answers `{:ok, ref}` for `unsubscribe/2`, `{:refused, :no_instance}`, `{:refused, {:bad,
  :topics}}`, `{:refused, {:undeclared, topic}}`, or `{:unknown, reason}` when the instance's
  `Cues` did not answer (a restart under way).

  **A cue** is `%{topic: topic, ids: ids}`: a hint to read rows again by their ids, never the
  data. Each topic's last words name where the rows are (`<host>` the workstation's name, as the
  config gives it, and `<account>` a Claude account), and `ids` are:

  | topic | `ids` |
  | --- | --- |
  | `sessions:<host>` | the agent rows' ids (`Sessions.Table`) |
  | `delegates:<host>` | the delegate rows' ids (`Delegates.Table`) |
  | `mains:<host>` | the project checkouts' row ids (`Mains.Table`) |
  | `mailbox` | the message rows' ids (`Mailbox`) |
  | `jobs` | the job ids (`Jobs`) |
  | `stream:<host>` | the stream rows' ids (`Stream.Table`) |
  | `registry:<host>:<account>` | Claude Code's session rows' ids (`Registry.Table`) |
  | `transcripts:<host>:<account>` | the transcript rows' ids (`Transcripts.Table`) |
  | `usage:<host>:<account>` | the usage rows' ids (`Usage.Table`) |
  | `tmux:<host>:<server>` | the tmux sampler's row ids, `[]` for a failed sample |
  | `intake:<host>:<account>:waiters` | the session id whose waiter came or went |

      {:ok, ref} = CodingAgentFramework.subscribe("a", ["sessions", "mailbox"])
      receive do
        {:caf_cue, %{topic: "sessions:" <> _host, ids: ids}} -> reread_agents(ids)
      end
      :ok = CodingAgentFramework.unsubscribe("a", ref)
  """
  @spec subscribe(String.t(), [String.t()]) ::
          {:ok, reference} | {:refused, term} | {:unknown, term}
  def subscribe(instance, topics) do
    with {:ok, cues} <- cues(instance), do: Cues.subscribe(cues, self(), topics)
  end

  @doc """
  Ends a subscription `subscribe/2` made. Answers `:ok`, `{:refused, :no_instance}`,
  `{:refused, :no_subscription}`, or `{:unknown, reason}`.
  """
  @spec unsubscribe(String.t(), reference) :: :ok | {:refused, term} | {:unknown, term}
  def unsubscribe(instance, ref) do
    with {:ok, cues} <- cues(instance), do: Cues.unsubscribe(cues, ref)
  end

  @doc """
  The topics an app may subscribe to: the ones the parts declare. Answers `{:ok, topics}` or
  `{:refused, :no_instance}`.

      {:ok, topics} = CodingAgentFramework.topics("a")
      "sessions" in topics
      #=> true
  """
  @spec topics(String.t()) :: {:ok, [String.t()]} | {:refused, :no_instance}
  def topics(instance) do
    with {:ok, _name} <- registry(instance), do: {:ok, Cues.topics(reads())}
  end

  # The instance's `Registry` is named from its name, so two instances in one app have two;
  # the atom is made only at a start, and an app's lookup never makes one.
  defp names(instance), do: String.to_atom(@names <> instance)

  defp registry(instance) when is_binary(instance) do
    name = String.to_existing_atom(@names <> instance)
    if Process.whereis(name), do: {:ok, name}, else: {:refused, :no_instance}
  rescue
    ArgumentError -> {:refused, :no_instance}
  end

  defp registry(_instance), do: {:refused, :no_instance}

  defp cues(instance) do
    with {:ok, name} <- registry(instance) do
      case Elixir.Registry.lookup(name, :cues) do
        [{pid, _}] -> {:ok, pid}
        [] -> {:unknown, :no_cues}
      end
    end
  rescue
    # The registry ended between the two looks.
    ArgumentError -> {:refused, :no_instance}
  end

  # Two instances of one name in one app would share a name to find them by.
  defp unique(c) do
    case registry(c.instance) do
      {:ok, _} -> {:refused, {:instance_running, c.instance}}
      {:refused, :no_instance} -> :ok
    end
  end

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
      mains: Mains.reads(),
      ends: Ends.reads()
    ]
  end

  @impl true
  def init(w) do
    tab = :ets.new(__MODULE__, [:public, read_concurrency: true])
    notify = fn cue -> Cues.cue(lookup(tab, :cues), cue) end
    # The app's subscriptions, owned by this supervisor so a restarted `Cues` keeps them.
    w = Map.put(w, :subscriptions, :ets.new(Cues, [:public]))

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
    # A job or service on the workstation runs with the home's tool state and devenv's PATH.
    held_env = c.env.tools ++ [{"PATH", c.env.path}]
    hosts = Map.put(c.hosts, host, %{programs: p, dir: Config.path(c, "ws"), env: held_env})

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
      # The instance's own `Registry`, named from its name: how the app finds it.
      {:names, fn _ -> {Elixir.Registry, keys: :unique, name: names(c.instance)} end},
      {:cues,
       fn _ ->
         {Cues,
          parts: reads(), subscriptions: w.subscriptions, registry: {names(c.instance), :cues}}
       end},
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
         # The framework's PreToolUse callback first (a move's drain), then the app's, whose
         # answer a heavy command's wrapper corrects.
         heavy = Runs.pre_tool_use(w.runs, c.tool_hooks[:pre_tool_use])
         pre = Mover.pre_tool_use(w.agents, heavy)

         tools =
           [pre_tool_use: pre] ++ Map.to_list(Map.take(c.tool_hooks, [:post_tool_use, :stop]))

         agent = &Sessions.Agents.by_session(w.agents, &1, &2)
         # A pause per project reads the agent row's project.
         project = fn name -> Map.get(Sessions.Agents.get(w.agents, name) || %{}, :project) end
         {Intake, [db: db, host: host, notify: notify, agent: agent, project: project] ++ tools}
       end},
      # The hooks, and the heavy commands' wrapper, which asks the `Scheduler` started later:
      # it is looked up at each request.
      {:intake_http,
       fn pid ->
         runs = [scheduler: fn -> pid.(:scheduler) end, units: &run_units(c, w, &1, &2)]
         opts = [intake: pid.(:intake), secret: w.secret, runs: runs]
         {Bandit, plug: {Endpoint, opts}, ip: @local, port: c.ports.intake, startup_log: false}
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
             # `Mains` declares the main sessions the config names, as agent rows.
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
             acts: pid.(:acts)
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
        # Before `Delegates` and `Jobs`, which ask it for a lease before each start. The owners'
        # answers and the allowance are read through connections of its own, never by a call.
        {:scheduler,
         fn _ ->
           {Scheduler,
            db: db,
            host: host,
            resources: resources(c),
            holders: %{
              "delegate" => &Delegates.Work.state(w.work, &1),
              "job" => &Jobs.Work.state(w.jobs_work, &1),
              "main" => &Mains.Work.state(w.mains_work, &1),
              "run" => &Runs.state(w.runs, &1)
            },
            allowance: &Usage.Allowance.check(w.allowance, &1),
            pressure: pressure(c, p),
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
            home: c.home,
            os: Programs.os(p),
            acts: pid.(:acts),
            notify: notify}
         end},
        {:delegates,
         fn pid ->
           {Delegates,
            host: host,
            name_room: Config.name_room(c).agent,
            db: db,
            sessions_db: db,
            sessions: pid.(:sessions),
            stream: pid.(:stream),
            usage: pid.(:usage),
            accounts: w.accounts,
            transcripts: pid.(:transcripts),
            registry: pid.(:registry),
            inlet: pid.(:inlet),
            intake: pid.(:intake),
            intake_db: db,
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
        # After `Sessions`, `Mailbox` and the `Scheduler`, and before `MCP`, whose `start_main`
        # it serves: it declares the config's main sessions before it answers its start.
        {:mains,
         fn pid ->
           {
             Mains,
             # The operator answers a main session's held permission request through it.
             host: host,
             home: c.home,
             name_room: Config.name_room(c).agent,
             db: db,
             sessions_db: db,
             programs: p,
             reaper: pid.(:reaper),
             sessions: pid.(:sessions),
             mailbox: pid.(:mailbox),
             usage: pid.(:usage),
             accounts: w.accounts,
             projects: c.projects,
             mains: c.mains,
             launch: [
               claude: c.claude,
               env: c.env,
               tool_timeout: c.tool_timeout,
               model: c.main_model
             ],
             mcp: &issue(pid.(:mcp), &1),
             scheduler: pid.(:scheduler),
             lease: c.lease,
             operator: c.operator,
             intake: pid.(:intake),
             intake_db: db,
             interval: every,
             notify: notify
           }
         end},
        {:copies,
         fn _ -> {Copies, dir: Config.path(c, "parts/copies"), programs: p, notify: notify} end},
        {:jobs,
         fn pid ->
           {Jobs,
            [
              dir: Config.path(c, "parts/jobs"),
              copies: pid.(:copies),
              hosts: hosts,
              on_late_end: &late_end(c, pid, &1),
              scheduler: pid.(:scheduler)
            ] ++ notify_every}
         end},
        {:services,
         fn pid ->
           {Services,
            [
              dir: Config.path(c, "parts/services"),
              name_room: Config.name_room(c).service,
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
            sessions: {Sessions, pid.(:sessions)},
            mains: {Mains, pid.(:mains)},
            lease: &job_units(c, &1, &2),
            extensions: c.extensions}
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
        {Tracker.TableSource, [table: Mains.Table] ++ on},
        {Tracker.TableSource, [table: TmuxSampler.Table] ++ on ++ [server: server]},
        {Tracker.TableSource, [table: Acts.Table] ++ on ++ [instance: c.instance]},
        {Tracker.TableSource,
         table: Jobs.Table, db: Config.path(c, "parts/jobs/jobs.db"), host: c.workstation},
        {Tracker.TableSource,
         table: Copies.Table, db: Config.path(c, "parts/copies/copies.db"), host: c.workstation}
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

  @doc """
  What the `Scheduler` leases: the config's `resources` (an agent's seat, a heavy run's slot),
  and each project's landing lock, `land:<project>`, one at a time.

      iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
      ...>   programs: %{}, accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
      ...>   env: %{}, user: "me", projects: %{"web" => %{}})
      iex> CodingAgentFramework.resources(c)
      %{"land:web" => 1, "seat" => 4, "slot" => 2}
  """
  @spec resources(Config.t()) :: %{String.t() => pos_integer}
  def resources(%Config{} = c),
    do: Map.merge(Map.new(Map.keys(c.projects), &{"land:" <> &1, 1}), c.resources)

  @doc """
  The units a job asks for, by the class its caller names: the config's `job_lease` for the
  class, and for a landing also its project's landing lock, all in one gang lease.

      iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
      ...>   programs: %{}, accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
      ...>   env: %{}, user: "me", projects: %{"web" => %{}})
      iex> CodingAgentFramework.job_units(c, :landing, "web")
      {:ok, %{"land:web" => 1, "slot" => 1}}
      iex> CodingAgentFramework.job_units(c, :heavy, "web")
      {:ok, %{"slot" => 1}}
      iex> CodingAgentFramework.job_units(c, :landing, "mobile")
      {:refused, {:no_project, "mobile"}}
  """
  @spec job_units(Config.t(), atom, String.t()) :: {:ok, map} | {:refused, term}
  def job_units(%Config{} = c, class, project) do
    units = Map.fetch!(c.job_lease, class)

    cond do
      class != :landing -> {:ok, units}
      Map.has_key?(c.projects, project) -> {:ok, Map.put(units, "land:" <> project, 1)}
      true -> {:refused, {:no_project, project}}
    end
  end

  # A heavy command's units, by its class and its agent's project, as a job's are.
  defp run_units(c, w, class, agent) do
    project = Map.get(Sessions.Agents.get(w.agents, agent) || %{}, :project)
    job_units(c, class, project)
  end

  # Stall times where the host has them, the kernel's memory-pressure level on macOS; elsewhere
  # no pressure gate, only the static capacities.
  defp pressure(%Config{pressure: nil}, p) do
    cond do
      File.dir?("/proc/pressure") ->
        [source: :psi]

      Programs.os(p) == :darwin and match?({:ok, _}, Programs.fetch(p, :sysctl)) ->
        {:ok, sysctl} = Programs.fetch(p, :sysctl)
        args = ["-n", "kern.memorystatus_vm_pressure_level"]

        read = fn ->
          Scheduler.Pressure.sysctl(Shell.run(p.host, sysctl, args, timeout: 5_000))
        end

        [source: {:level, read}, name: "sysctl kern.memorystatus_vm_pressure_level"]

      true ->
        [source: :none]
    end
  end

  defp pressure(%Config{pressure: pressure}, _p), do: pressure

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
    tools = [:pre_tool_use | Map.keys(Map.take(c.tool_hooks, [:post_tool_use, :stop]))]
    data = %{programs: programs, intake: %{port: c.ports.intake, secret: secret, tools: tools}}

    Enum.reduce_while(c.accounts, :ok, fn a, :ok ->
      case Accounts.prepare(accounts, a, data) do
        {:ok, _} -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  # Every tool's state lives in the home (F-155): its git config with the author and signing,
  # its ssh files, then the variables that point gh, git, ssh and the XDG directories there, in
  # every launch and every project's environment (git and the setup).
  defp tools(c, programs) do
    projects =
      for {name, git} <- c.git.projects, into: %{} do
        {name, Map.put(git, :checkout, Map.fetch!(c.projects, name).repo)}
      end

    with {:ok, %{ssh: ssh, gh: gh, ssh_keygen: keygen}} <-
           Programs.take(programs, [:ssh, :gh, :ssh_keygen]),
         :ok <-
           ToolHome.prepare(c.home,
             author: c.git.author,
             projects: projects,
             gh: gh,
             ssh_keygen: keygen
           ) do
      tools = ToolHome.env(c.home, ssh)
      named = Map.new(tools)
      projects = Map.new(c.projects, fn {n, p} -> {n, %{p | env: Map.merge(named, p.env)}} end)
      {:ok, %{c | env: Map.put(c.env, :tools, tools), projects: projects}}
    end
  end

  defp programs(c) do
    case Map.fetch(c.programs, :kill) do
      {:ok, kill} -> Programs.new(Host.local(c.workstation, kill), c.programs)
      :error -> {:refused, {:no_program, :kill}}
    end
  end

  defp mkdirs(c) do
    Enum.reduce_while(["d", "parts/jobs", "parts/copies", "ws"], :ok, fn dir, :ok ->
      case File.mkdir_p(Config.path(c, dir)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:unknown, {Config.path(c, dir), reason}}}
      end
    end)
  end

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
