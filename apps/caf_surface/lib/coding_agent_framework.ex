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
  with each reading part's own declaration (`reads/0`) and the topics each writing part
  declares (`writes/0`), and every part's `notify:` goes to it (`Cues.notify/3`, with the
  config's `undeclared_cues`).
  Each part is named to `Cues` as it starts, so a part a restart replaced gets the cues from
  then on, and one not started yet misses nothing: every part reads its whole table when it
  starts. `Stream`, `Jobs` and `Services` read on the config's `interval` as the other readers
  do; no ticker sends a made-up topic. The app's own processes get the cues too, by
  `subscribe/2`: the instance is found by its name in its own `Registry`, never a global name.

  **The operator.** The app's own acts on agents, from a view say, go through
  `CodingAgentFramework.Operator` with `parts(sup).mcp`, under the config's `operator` name,
  which every part's `Grants` knows: the same checks, claims and call log as an agent's tools.

  **The inbox** (F-179, `CodingAgentFramework.Prompts`). Everything that waits on a person is a
  prompt: a held permission request, a startup dialog, an agent's ask, a `Stop` held at Claude
  Code's cap. The app reads them with `prompts/2`, re-reads on the `prompts` cue, and answers
  each once with `answer/4`, which hands the choice to the part that owns it. An ask a person
  dismisses is withdrawn by `answer/4` with `{:withdraw, reason}`: the agent reads the reason in
  the answer's place, and the first of the two settles the ask (F-172). A delegate's parent is
  told once that its delegate waits.

  **The tree.** It opens no part's table: the tree `Grants` reads, an agent's worktree, the
  agent a hook names and whether an agent has ended are `Sessions.Agents`' functions over the
  agent rows. `Mains` declares the main sessions the config names, holds each project's
  checkout and its pull, and starts a main session (`start_main`): the app calls
  `Mains.landed/2` when something landed in a project's trunk.

  **Once per start.** `start_link/1` makes `Acts`' `start_id`, reads the hooks' secret from the
  config's `secret_file` (`Intake.secret/1`, `<home>/intake.secret` by default, made at the
  first start), and writes each account's files with that secret, before any part starts. A
  session held across a restart keeps its hooks: its settings name the same secret.

  **The config's keys** (F-188). The tree reads nothing but the config: each part's own
  options in its `parts` go over the tree's wiring (`Config.options/3`), the holder's too; a
  startup dialog is answered by its `dialogs` (`Config.dialog/3`); the extensions are made
  from their modules when `MCP` starts (`Config.extensions/2`), and one that refuses then
  fails the start with its refusal; and the tree's restart budget is its `restarts`.

  Nothing it starts acts outside the framework home but its own tmux server (whose socket is in
  the home) and its two ports.
  """

  use Supervisor

  alias CodingAgentFramework.{AbsentMains, Accounts, Acts, ClaudeCLI, Copies, Delegates, Grants}
  alias CodingAgentFramework.{Holder, HooksSilent, Host, Inlet, Limits, Logins}

  alias CodingAgentFramework.{
    Cues,
    Intake,
    Jobs,
    Mailbox,
    Mains,
    MCP,
    Mover,
    Programs,
    Prompts,
    Recoveries,
    Registry,
    Services,
    Watch
  }

  alias CodingAgentFramework.{Runs, Scheduler, Sessions, Shell, Stream, StuckBackgrounds}
  alias CodingAgentFramework.{Tmux, TmuxSampler}
  alias CodingAgentFramework.Tracker
  alias CodingAgentFramework.{ToolHome, ToolHooks, Transcripts, Usage}
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

  **A restart at once.** An instance of the same name that is still exiting (a tree its
  parent just killed, whose named `Registry` still ends) is waited for: the start monitors
  that `Registry` and goes on at its `:DOWN`, up to the config's `restart_wait` (5 s by
  default), so the parent's restart is not refused and its restart budget is not spent on it.
  Past the bound the start is refused `{:instance_running, name}`, as it is for an instance
  that runs on; so a second start of a running name answers only after `restart_wait`.

  **No agents.** With the config's `agents: false` the tree starts only the parts a lease
  needs, `Config.agentless/0`'s: no tmux server, no account's settings, no hooks' secret and
  no endpoint. `parts/1` then names only those.
  """
  @spec start_link(Config.t()) :: Supervisor.on_start() | {:refused, term} | {:unknown, term}
  def start_link(%Config{} = c) do
    with :ok <- unique(c),
         :ok <- mkdirs(c),
         {:ok, programs} <- programs(c),
         {:ok, c} <- tools(c, programs),
         {:ok, jobs_work} <- Jobs.Work.open(Config.path(c, "parts/jobs")),
         {:ok, w} <- agents_wiring(c, programs) do
      w = Map.merge(w, %{c: c, programs: programs, jobs_work: jobs_work, start_id: token()})
      Supervisor.start_link(__MODULE__, Map.put(w, :db, Config.path(c, "caf.db")))
    end
  end

  # What only the parts that run or read an agent take; a tree with `agents: false` makes none
  # of it, so it writes no account's settings and opens no agent's table (F-195).
  defp agents_wiring(%Config{agents: false}, _programs), do: {:ok, %{}}

  defp agents_wiring(c, programs) do
    db = Config.path(c, "caf.db")

    with {:ok, tmux} <- server(c),
         {:ok, accounts} <- Accounts.new(c.home, c.accounts),
         {:ok, holder} <-
           Holder.new(programs, Config.path(c, "d"), Config.options(c, :holder, [])),
         {:ok, agents} <- Sessions.Agents.open(db, c.workstation),
         {:ok, work} <- Delegates.Work.open(db, db, c.workstation),
         {:ok, allowance} <- Usage.Allowance.open(db),
         {:ok, mains_allowance} <- Usage.Allowance.open(db),
         {:ok, mains_work} <- Mains.Work.open(db, db, c.workstation),
         {:ok, secret} <- Intake.secret(c.secret_file),
         :ok <- prepare(c, accounts, programs, secret),
         {:ok, runs} <- Runs.new(c.home, programs, c.heavy),
         :ok <- Runs.prepare(runs, programs, c.ports.intake, secret) do
      w = %{tmux: tmux, accounts: accounts, holder: holder, agents: agents, secret: secret}
      w = Map.merge(w, %{work: work, allowance: allowance, mains_allowance: mains_allowance})
      {:ok, Map.merge(w, %{mains_work: mains_work, runs: runs})}
    end
  end

  @doc "The framework's own tmux server: a socket in the home."
  @spec server(Config.t()) :: {:ok, Tmux.t()} | {:refused, term}
  def server(%Config{} = c) do
    with {:ok, programs} <- programs(c),
         do: Tmux.CLI.new(programs, {:socket, Config.path(c, "tmux.sock")})
  end

  @doc """
  The holder of processes the tree makes from `config` (`Holder.Process` over `<home>/d`): what
  reads an agent's process by its record (pid and start time), for a reader outside the tree,
  such as the example console's `groups/2` (F-189's new-6).
  """
  @spec processes(Config.t()) :: {:ok, Holder.Process.t()} | {:refused, term}
  def processes(%Config{} = c) do
    with {:ok, programs} <- programs(c),
         {:ok, holder} <-
           Holder.new(programs, Config.path(c, "d"), Config.options(c, :holder, [])),
         do: Holder.Process.new(programs, holder)
  end

  @doc """
  The agent rows and the delegate rows of the instance `config` names, on its workstation, read
  now (F-195), as `processes/1` is the holder's reader: one call that opens the instance's
  store read-only by its config, reads, and closes it, so an app never names the framework's
  file and never takes a writer's lock. Whether the tree runs does not matter. `agents` are
  `Sessions`' rows (`Sessions.Agents` says what a status means), `delegates` each start of a
  delegate (`Delegates.Table`), each oldest first; both are empty before the tree made its
  tables, or for a tree with `agents: false`. Answers `{:ok, %{agents: rows, delegates:
  rows}}`, or `{:refused, {:sqlite, reason}}` when the store cannot be opened (no tree ever
  started on the home, say).

      {:ok, %{agents: [%{name: "app-main", kind: "main", status: "running"} | _],
              delegates: delegates}} = CodingAgentFramework.agent_rows(config)
  """
  @spec agent_rows(Config.t()) ::
          {:ok, %{agents: [map], delegates: [map]}} | {:refused, term}
  def agent_rows(%Config{} = c) do
    path = Config.path(c, "caf.db")

    with {:ok, agents} <- Sessions.Agents.read_only(path, c.workstation),
         {:ok, delegates} <- Delegates.Table.read_only(path, c.workstation),
         do: {:ok, %{agents: agents, delegates: delegates}}
  end

  @doc "Each part's process, by its key (`:sessions`, `:registry`, …)."
  @spec parts(Supervisor.supervisor()) :: %{term => pid}
  def parts(sup), do: Map.new(Supervisor.which_children(sup), fn {k, pid, _, _} -> {k, pid} end)

  @doc """
  The calling process gets each later cue on `topics` as a message `{:caf_cue, cue}`, for as
  long as it lives, from the instance the config named `instance`. Delivery is a plain `send`
  after the parts got the cue, so a slow or crashed subscriber touches nothing in the tree; a
  subscriber is monitored and removed when it exits.

  A topic is a pattern of words joined by `:`, `*` for any one word, matching each topic that
  begins with its words: `"sessions"` matches `"sessions:ws"`, and `"sessions:"` is the same.
  The topics an app may name are the ones the parts declare they read or write (`topics/1`);
  any other is refused. Answers `{:ok, %{ref: ref, tree: pid}}`, `{:refused, :no_instance}`,
  `{:refused, {:bad, :topics}}`, `{:refused, {:undeclared, topic}}`, or `{:unknown, reason}`
  when the instance's `Cues` did not answer (a restart under way).

  **The tree.** A subscription lives as long as the tree it was made in: it survives a restart
  of `Cues`, whose table the tree's supervisor owns, and ends with that supervisor. `tree` is
  that supervisor's pid. The app monitors it, and when it exits subscribes again once the tree
  is back (until then `subscribe/2` answers `{:refused, :no_instance}`), and re-reads what it
  shows, since the cues in between went to no one. Nothing claims to keep a subscription across
  a restart of the whole tree; `ref` is for `unsubscribe/2`.

  **A cue** is a hint to read rows again by their ids, never the data. Each topic's last words
  name where the rows are (`<host>` the workstation's name, as the config gives it, `<account>`
  a Claude account, `<instance>` the config's `instance`, `<server>` the tmux server's name):

  | topic | the cue |
  | --- | --- |
  | `sessions:<host>` | `ids`: the agent rows' ids (`Sessions.Table`) |
  | `delegates:<host>` | `ids`: the delegate rows' ids (`Delegates.Table`) |
  | `mains:<host>` | `ids`: the project checkouts' row ids (`Mains.Table`) |
  | `mailbox` | `ids`: the message rows' ids (`Mailbox`) |
  | `jobs` | `ids`: the job ids (`Jobs`); a late end is in its job's row |
  | `services` | `ids`: the services' names (`Services`) |
  | `copies` | no `ids`: a copy's key is three columns, so the app re-reads the copies (`Copies`) |
  | `acts:<host>:<instance>` | `ids`: the act rows' ids, the fault ledger (`Acts.Table`) |
  | `scheduler:<host>` | `ids`: the lease rows' ids (`Scheduler.Table`); or no `ids`, and `pressure:` the host's new level |
  | `stream:<host>` | `ids`: the stream rows' ids (`Stream.Table`) |
  | `registry:<host>:<account>` | `ids`: Claude Code's session rows' ids (`Registry.Table`) |
  | `transcripts:<host>:<account>` | `ids`: the transcript rows' ids (`Transcripts.Table`) |
  | `usage:<host>:<account>` | `ids`: the usage rows' ids (`Usage.Table`) |
  | `tmux:<host>:<server>` | `ids`: the tmux sampler's row ids, `[]` for a failed sample |
  | `intake:<host>:<account>` | `ids`: the hooks' rows' ids (`Intake.Table`) |
  | `intake:<host>:<account>:waiters` | `ids`: the session id whose waiter came or went |
  | `prompts` | `ids`: the prompts that opened, moved or closed (`prompts/2`, `Prompts`) |
  | `watch` | `ids`: the symptom rows' ids (`symptoms/2`, `Watch`); none for an act on the allow-list |
  | `logins:<host>` | `ids`: the login rows' ids (`Logins.Table`), at a change of an account's login state |

  An app's process that subscribes again whenever its tree comes back:

      def init(instance), do: {:ok, subscribe(%{instance: instance, tree: nil})}

      def handle_info({:caf_cue, %{topic: "sessions:" <> _host, ids: ids}}, s),
        do: {:noreply, reread_agents(s, ids)}

      def handle_info({:DOWN, _, :process, tree, _}, %{tree: tree} = s),
        do: {:noreply, subscribe(%{s | tree: nil})}

      def handle_info(:subscribe, s), do: {:noreply, subscribe(s)}

      defp subscribe(s) do
        case CodingAgentFramework.subscribe(s.instance, ["sessions", "acts"]) do
          {:ok, %{tree: tree}} ->
            Process.monitor(tree)
            reread_all(%{s | tree: tree})

          _not_back ->
            Process.send_after(self(), :subscribe, 1_000)
            s
        end
      end
  """
  @spec subscribe(String.t(), [String.t()]) ::
          {:ok, %{ref: reference, tree: pid}} | {:refused, term} | {:unknown, term}
  def subscribe(instance, topics) do
    with {:ok, cues} <- cues(instance),
         {:ok, tree} <- tree(instance),
         {:ok, ref} <- Cues.subscribe(cues, self(), topics),
         do: {:ok, %{ref: ref, tree: tree}}
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
    with {:ok, _name} <- registry(instance), do: {:ok, Cues.topics(reads(), writes())}
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

  @doc """
  The prompts open now in the instance the config named `instance`, oldest first: everything
  that waits on a person (`CodingAgentFramework.Prompts`, its module doc says each kind and
  field). `filter` narrows them: `agent:` (that agent's), `subtree:` (that agent's and its
  delegates', at any depth), `kind:` (`"permission"`, `"stop_cap"`, `"dialog"`, `"ask"`). Each
  write that opens, moves or closes one is cued on `prompts` (`subscribe/2`). Answers `{:ok,
  prompts}`, `{:refused, :no_instance}`, `{:refused, {:bad, :filter}}`, or `{:unknown, reason}`.

      {:ok, [%{id: id, kind: "permission", agent: "app-unit", options: ["allow", "deny"]}]} =
        CodingAgentFramework.prompts("a", subtree: "app-main")
  """
  @spec prompts(String.t(), keyword) ::
          {:ok, [Prompts.prompt()]} | {:refused, term} | {:unknown, term}
  def prompts(instance, filter \\ []) do
    with {:ok, prompts} <- part(instance, :prompts), do: Prompts.read(prompts, filter)
  end

  @doc """
  Answers prompt `id` with `choice`, as `who` (a person's name), once, through the part that owns
  it (`Prompts.answer/5` says each kind's choices): a held request's `Intake`, a dialog's
  `Sessions`, an ask's `Mailbox`; `{:withdraw, reason}` withdraws an ask. A late or second
  answer is refused `{:refused, :settled}`. Answers the owner's `{:ok, value}`, `{:refused,
  :no_instance}`, or as `Prompts.answer/5` does.

      CodingAgentFramework.answer("a", id, "allow", "sam")
      #=> {:ok, :sent}
      CodingAgentFramework.answer("a", id, "deny", "sam")
      #=> {:refused, :settled}
  """
  @spec answer(String.t(), String.t(), term, String.t()) ::
          {:ok, term} | {:refused, term} | {:unknown, term}
  def answer(instance, id, choice, who) do
    with {:ok, prompts} <- part(instance, :prompts), do: Prompts.answer(prompts, id, choice, who)
  end

  @doc """
  The symptoms the `Watch` keeps in the instance the config named `instance` (F-182,
  `CodingAgentFramework.Watch`), oldest first: each `%{kind, target, state, since, evidence,
  status, remedy, reason, …}`, its status `open`, `asked` (a `remedy` prompt waits on a person),
  `answered` or `passed`. `filter` narrows them: `kind:`, `target:`, `source:`, `status:`, each a
  value or a list. Each write is cued on `watch`. Answers `{:ok, symptoms}`, `{:refused,
  :no_instance}`, `{:refused, {:bad, :filter}}`, or `{:unknown, reason}`.

      {:ok, [%{kind: "lost_viewer", target: "app-main", status: "asked"}]} =
        CodingAgentFramework.symptoms("a", status: ["open", "asked"])
  """
  @spec symptoms(String.t(), keyword) :: {:ok, [map]} | {:refused, term} | {:unknown, term}
  def symptoms(instance, filter \\ []) do
    with {:ok, watch} <- part(instance, :watch), do: Watch.read(watch, filter)
  end

  @doc """
  The accounts at a usage limit now in the instance the config named `instance`, from the
  `Watch`'s symptom `limited` (F-193, `Watch.limited/2`): one reading per account, its window,
  its reset (Unix seconds) and its agents, each with how long it has waited (ms). Each write is
  cued on `watch`. Answers `{:ok, readings}`, `{:refused, :no_instance}`, or `{:unknown, reason}`.

      {:ok, [%{account: "work", window: "five_hour", until: 1_800_000_000,
               agents: [%{agent: "app-unit", waited: 540_000}]}]} =
        CodingAgentFramework.limited("a")
  """
  @spec limited(String.t()) :: {:ok, [map]} | {:refused, term} | {:unknown, term}
  def limited(instance) do
    with {:ok, watch} <- part(instance, :watch), do: Watch.limited(watch)
  end

  @doc """
  The healer's allow-list in the instance the config named `instance`, and the operator's acts
  on it (`Watch.remedies/3`): `:list`, `{:approve, kind, who}` (the only widening) or
  `{:revoke, kind, who}`.

      {:ok, %{"lost_viewer" => %{remedy: "reopen", cap: 10, allowed: true}}} =
        CodingAgentFramework.remedies("a", :list)
  """
  @spec remedies(String.t(), term) :: {:ok, term} | {:refused, term} | {:unknown, term}
  def remedies(instance, request) do
    with {:ok, watch} <- part(instance, :watch) do
      case request do
        {:drop, _, _} -> {:refused, {:bad, :request}}
        request -> Watch.remedies(watch, request)
      end
    end
  end

  defp cues(instance), do: part(instance, :cues)

  # A part the tree registered in the instance's own `Registry` (`Cues`, `Prompts`, `Watch`).
  defp part(instance, key) do
    with {:ok, name} <- registry(instance) do
      case Elixir.Registry.lookup(name, key) do
        [{pid, _}] -> {:ok, pid}
        [] -> {:unknown, {:no_part, key}}
      end
    end
  rescue
    # The registry ended between the two looks.
    ArgumentError -> {:refused, :no_instance}
  end

  # The tree's supervisor, as the `Registry` it started keeps it.
  defp tree(instance) do
    with {:ok, name} <- registry(instance) do
      case Elixir.Registry.meta(name, :tree) do
        {:ok, pid} -> {:ok, pid}
        :error -> {:unknown, :no_tree}
      end
    end
  rescue
    ArgumentError -> {:refused, :no_instance}
  end

  # Two instances of one name in one app would share a name to find them by. A tree just killed
  # still holds its name while its `Registry` exits, so a parent's restart at once would be
  # refused and spend its budget (F-195): the start waits for that `Registry` to end, up to the
  # config's `restart_wait`.
  defp unique(c) do
    with {:ok, name} <- registry(c.instance),
         pid when is_pid(pid) <- Process.whereis(name) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        c.restart_wait ->
          Process.demonitor(ref, [:flush])
          {:refused, {:instance_running, c.instance}}
      end
    else
      {:refused, :no_instance} -> :ok
      nil -> :ok
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
      usage: Usage.reads(),
      recoveries: Recoveries.reads(),
      tracker: Tracker.reads(),
      mailbox: Mailbox.reads(),
      delegates: Delegates.reads(),
      mover: Mover.reads(),
      scheduler: Scheduler.reads(),
      mains: Mains.reads(),
      absent_mains: AbsentMains.reads(),
      limits: Limits.reads(),
      stuck_backgrounds: StuckBackgrounds.reads(),
      hooks_silent: HooksSilent.reads(),
      prompts: Prompts.reads(),
      ends: Ends.reads()
    ]
  end

  @doc """
  What each part it starts writes, as the part declares it (`writes/0`): the topics of the
  cues the parts send, which an app may subscribe to beside the ones they read.
  """
  @spec writes() :: [{atom, [String.t()]}]
  def writes do
    [
      acts: Acts.writes(),
      usage: Usage.writes(),
      stream: Stream.writes(),
      intake: Intake.writes(),
      sampler: TmuxSampler.writes(),
      registry: Registry.writes(),
      transcripts: Transcripts.writes(),
      sessions: Sessions.writes(),
      scheduler: Scheduler.writes(),
      mailbox: Mailbox.writes(),
      delegates: Delegates.writes(),
      mains: Mains.writes(),
      copies: Copies.writes(),
      jobs: Jobs.writes(),
      services: Services.writes(),
      prompts: Prompts.writes(),
      watch: Watch.writes(),
      logins: Logins.writes()
    ]
  end

  @impl true
  def init(w) do
    tab = :ets.new(__MODULE__, [:public, read_concurrency: true])
    notify = Cues.notify(fn -> lookup(tab, :cues) end, writes(), w.c.undeclared_cues)
    # The app's subscriptions, owned by this supervisor so a restarted `Cues` keeps them.
    w = Map.put(w, :subscriptions, :ets.new(Cues, [:public]))

    # A tree that runs no agent starts only what a lease needs (`Config.agentless/0`).
    started = fn key -> w.c.agents or key in Config.agentless() end

    children =
      for {key, build} <- children(w, notify),
          started.(key),
          do: %{id: key, start: {__MODULE__, :start_part, [tab, key, build, w.c]}}

    %{max_restarts: n, max_seconds: s} = w.c.restarts
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: n, max_seconds: s)
  end

  @doc false
  # Runs in the supervisor: `build` gets the current process of each part started before it,
  # and the config's `parts` for this key go over its wiring. A build that cannot be made
  # (an extension that refuses now) fails the start with its refusal.
  def start_part(tab, key, build, c) do
    case build.(&lookup(tab, &1)) do
      {:refused, _} = refused ->
        {:error, refused}

      {module, opts} ->
        with {:ok, pid} <- module.start_link(Config.options(c, key, opts)) do
          :ets.insert(tab, {key, pid})
          Cues.started(lookup(tab, :cues), key, pid)
          watch(tab, key, pid)
          {:ok, pid}
        end
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

    notify_every = [notify: notify, interval: every]
    read = [programs: p, db: db] ++ notify_every

    # One Registry and one Transcripts on the host, over every account: a move hides no agent.
    dirs = fn ->
      for a <- c.accounts,
          {:ok, dir} = Accounts.config_dir(w.accounts, a),
          into: %{},
          do: {a, dir}
    end

    readers = [
      {:registry, fn _ -> {Registry, [accounts: dirs.()] ++ read} end},
      {:transcripts, fn _ -> {Transcripts, [accounts: c.accounts] ++ read} end}
    ]

    [
      {:reaper, fn _ -> {Shell.Reaper, programs: p} end},
      # The instance's own `Registry`, named from its name: how the app finds it, and the
      # tree's supervisor, in which this runs, for a subscriber to watch.
      {:names,
       fn _ ->
         {Elixir.Registry, keys: :unique, name: names(c.instance), meta: [tree: self()]}
       end},
      {:cues,
       fn _ ->
         {Cues,
          parts: reads(),
          writes: writes(),
          subscriptions: w.subscriptions,
          registry: {names(c.instance), :cues}}
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
      {:stream,
       fn _ ->
         {Stream, [programs: p, holder: w.holder, home: c.home, db: db] ++ notify_every}
       end},
      # After `Stream`, whose rows give a headless session's readings and limit; a transcript's
      # limit it reads from `Transcripts`' table, on that reader's cues.
      {:usage,
       fn pid ->
         {Usage,
          accounts: w.accounts,
          host: host,
          db: db,
          stream: {Stream, pid.(:stream)},
          transcripts_db: db,
          notify: notify,
          interval: every}
       end},
      # Before every part that starts or resumes on an account, which reads its login first.
      {:logins,
       fn _ ->
         {Logins,
          accounts: w.accounts, host: host, db: db, run: &auth_status(c, w, &1), notify: notify}
       end},
      {:intake,
       fn pid ->
         # The framework's PreToolUse callback first (a move's drain), then the app's, whose
         # answer a heavy command's wrapper corrects, and a background command's stdin closed
         # in what that answer runs. The app's hooks get the live lookup of the parts, as an
         # extension's tools do (F-195).
         hooks = ToolHooks.callbacks(c.tool_hooks, pid)
         heavy = Runs.pre_tool_use(w.runs, hooks[:pre_tool_use])
         pre = Mover.pre_tool_use(w.agents, Intake.Background.pre_tool_use(heavy))

         tools = [pre_tool_use: pre] ++ Map.to_list(Map.take(hooks, [:post_tool_use, :stop]))

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
             # A startup dialog the config's `dialogs` does not answer waits on a person
             # (F-140), who answers it through the inbox (`answer/4`).
             # One viewer size for the first open and the healer's reopen (F-188's new-2).
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
             dialog: &Config.dialog(c, &1, &2),
             open_to: &Mailbox.open_to(pid.(:mailbox), &1, status: &2),
             waiter: %{port: c.ports.intake, secret: w.secret},
             acts: pid.(:acts),
             size: c.viewer
           }
         end},
        # Before the healer, which records each symptom in it and reads its allow-list; the app
        # finds it in the instance's `Registry`.
        {:watch,
         fn _ ->
           {Watch,
            db: db,
            remedies: c.remedies,
            bound: c.remedy_bound,
            notify: notify,
            name: {:via, Elixir.Registry, {names(c.instance), :watch}}}
         end},
        {:recoveries,
         fn pid ->
           {Recoveries,
            watch: pid.(:watch),
            server: w.tmux,
            holder: w.holder,
            programs: w.programs,
            sampler: pid.(:sampler),
            sessions: pid.(:sessions),
            acts: pid.(:acts),
            size: c.viewer}
         end},
        {:tracker, fn _ -> {Tracker, sources: sources(w)} end},
        # Before `Delegates` and `Jobs`, which ask it for a lease before each start. The owners'
        # answers and the allowance are read through connections of its own, never by a call.
        {:scheduler,
         fn _ ->
           {Scheduler,
            [
              db: db,
              host: host,
              resources: resources(c),
              holders: holders(w),
              pressure: pressure(c, p),
              interval: every,
              notify: notify
            ] ++ allowance(w)}
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
        # After every owner of a prompt; the app finds it in the instance's `Registry`.
        {:prompts,
         fn pid ->
           {
             Prompts,
             # A headless delegate's permission request is its fold's (F-189's new-2).
             host: host,
             intake: pid.(:intake),
             intake_db: db,
             sessions: pid.(:sessions),
             sessions_db: db,
             mailbox: pid.(:mailbox),
             watch: pid.(:watch),
             watch_db: db,
             logins: pid.(:logins),
             logins_db: db,
             stream: pid.(:stream),
             stream_db: db,
             notify: notify,
             name: {:via, Elixir.Registry, {names(c.instance), :prompts}}
           }
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
            usable: &Logins.usable(pid.(:logins), w.accounts, &1),
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
            usable: &Logins.usable(pid.(:logins), w.accounts, &1),
            launch: &launch(c, pid, &1)}
         end},
        # After `Sessions`, `Mailbox` and the `Scheduler`, and before `MCP`, whose `start_main`
        # it serves: it declares the config's main sessions before it answers its start.
        {:mains,
         fn pid ->
           {
             Mains,
             # The operator answers a main session's held permission request through it.
             # A checkout's rename and an import's rows are acts (F-156). A resume reads its
             # row's account's windows as the Scheduler does, through a connection of its own.
             host: host,
             home: c.home,
             name_room: Config.name_room(c).agent,
             db: db,
             sessions_db: db,
             acts: pid.(:acts),
             programs: p,
             reaper: pid.(:reaper),
             sessions: pid.(:sessions),
             mailbox: pid.(:mailbox),
             usage: pid.(:usage),
             allowance: &Usage.Allowance.check(w.mains_allowance, &1),
             usable: &Logins.usable(pid.(:logins), w.accounts, &1),
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
        # After `Mains`, whose resume it makes: the healer of an absent main (F-183). A restart
        # of `Mains` restarts it, so the pid it holds is the live one.
        {:absent_mains,
         fn pid ->
           mains = pid.(:mains)

           {AbsentMains,
            agents: w.agents,
            acts: pid.(:acts),
            watch: pid.(:watch),
            host: host,
            resume: &Mains.resume_main(mains, &1)}
         end},
        # The healer of a usage limit (F-186): after `Sessions`, which writes its phases and
        # presses the menu, `Mailbox`, which stores its word, the `Watch`, `Mains`, which
        # resumes a gone main with the word under its lease, `Delegates`, whose delegate's word
        # it is (F-187), and the `Mover`, which moves a limit far from its reset (F-191).
        {:limits,
         fn pid ->
           {inlet, mailbox, mains} = {pid.(:inlet), pid.(:mailbox), pid.(:mains)}
           {delegates, mover} = {pid.(:delegates), pid.(:mover)}
           {transcripts, stream} = {pid.(:transcripts), pid.(:stream)}

           {Limits,
            agents: w.agents,
            sessions: pid.(:sessions),
            acts: pid.(:acts),
            watch: pid.(:watch),
            host: host,
            transcripts: &Transcripts.rows(transcripts, &1),
            folds: fn -> Stream.rows(stream) end,
            look: &Inlet.look(inlet, &1.name, &1.release),
            word: &Mailbox.notify(mailbox, &1, &2, key: &3, kind: :notice),
            resume: &resume_limited(mains, &1),
            go_on: &Delegates.go_on(delegates, &1, &2, &3, &4),
            room: &Mover.room(mover, &1.name),
            move: &Mover.move(mover, &1, &2, to: &3, act: &4)}
         end},
        # The healer of a background command that hangs after its delegate's report (F-184):
        # it reads `Stream`'s folds and ends a group by its record. A hung command writes
        # nothing, so no cue comes: it reads at the interval too (F-189's new-4).
        {:stuck_backgrounds,
         fn pid ->
           stream = pid.(:stream)

           {StuckBackgrounds,
            agents: w.agents,
            folds: fn -> with {:ok, %{rows: rows}} <- Stream.rows(stream), do: {:ok, rows} end,
            acts: pid.(:acts),
            watch: pid.(:watch),
            host: host,
            holder: w.holder,
            programs: w.programs,
            interval: every}
         end},
        # The detector of an agent's hooks gone quiet (F-184): shown only, with no remedy. A
        # silence sends no cue, so it reads at the interval too.
        {:hooks_silent,
         fn pid ->
           {HooksSilent,
            agents: w.agents,
            transcripts: pid.(:transcripts),
            intake_db: db,
            watch: pid.(:watch),
            host: host,
            interval: every}
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
              # A late end is stored in its job's row, which `Jobs` marks told: the app's own
              # caller of the run reads it there, on the `jobs` cue.
              on_late_end: fn _late -> :ok end,
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
        # The app's extensions are made here, from the config's modules, each given the live
        # lookup of the parts.
        {:mcp,
         fn pid ->
           with {:ok, extensions} <- Config.extensions(c, pid) do
             {MCP,
              dir: Config.path(c, "parts/mcp"),
              port: c.ports.mcp,
              grants: grants,
              mailbox: {Mailbox, pid.(:mailbox)},
              delegates: {Delegates, pid.(:delegates)},
              services: {Services, pid.(:services)},
              workstation: host,
              tracker: {Tracker, pid.(:tracker)},
              stream: {Stream, pid.(:stream)},
              transcripts: {Transcripts, pid.(:transcripts)},
              place: &Sessions.Agents.place(w.agents, &1),
              tool_timeout: c.tool_timeout,
              margin: c.margin,
              acts: pid.(:acts),
              mover: {Mover, pid.(:mover)},
              prompts: {Prompts, pid.(:prompts)},
              mains: {Mains, pid.(:mains)},
              extensions: extensions}
           end
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

  # The tables the `Tracker` reads: the lease parts' always, the agents' parts' when they run.
  defp sources(%{c: c, db: db} = w) do
    on = [db: db, host: c.workstation]

    [
      {Tracker.TableSource, [table: Scheduler.Table] ++ on},
      {Tracker.TableSource, [table: Acts.Table] ++ on ++ [instance: c.instance]},
      {Tracker.TableSource,
       table: Jobs.Table, db: Config.path(c, "parts/jobs/jobs.db"), host: c.workstation},
      {Tracker.TableSource,
       table: Copies.Table, db: Config.path(c, "parts/copies/copies.db"), host: c.workstation}
    ] ++ if(c.agents, do: agent_sources(w, on), else: [])
  end

  defp agent_sources(%{c: c, tmux: tmux}, on) do
    {_, server} = Tmux.key(tmux)

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
        {Tracker.TableSource, [table: Mains.Table] ++ on},
        {Tracker.TableSource, [table: TmuxSampler.Table] ++ on ++ [server: server]}
      ]
  end

  # Who the `Scheduler` asks whether a lease's work ended, by the holder's kind. A tree that
  # runs no agent has only jobs: a delegate's, a main's or a run's lease a home kept from an
  # earlier tree is asked of no one, so its answer stays unknown and nothing is reclaimed.
  defp holders(%{c: %Config{agents: false}} = w),
    do: %{"job" => &Jobs.Work.state(w.jobs_work, &1)}

  defp holders(w) do
    %{
      "delegate" => &Delegates.Work.state(w.work, &1),
      "job" => &Jobs.Work.state(w.jobs_work, &1),
      "main" => &Mains.Work.state(w.mains_work, &1),
      "run" => &Runs.state(w.runs, &1)
    }
  end

  # An account's usage, read before a start on it; a tree with no agent starts on none.
  defp allowance(%{c: %Config{agents: false}}), do: []
  defp allowance(w), do: [allowance: &Usage.Allowance.check(w.allowance, &1)]

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

  # A limited agent whose process is gone, at its reset (F-186): a main is resumed through
  # `Mains`, under its lease, its word the resume's first row. A delegate's word and resume are
  # `Delegates.go_on/5`'s (`go_on:`).
  defp resume_limited(mains, %{kind: "main", name: name}), do: Mains.resume_main(mains, name)
  defp resume_limited(_mains, _row), do: :none

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

  # `claude auth status` on an account, with the launch's own environment (F-181): what
  # `Logins` checks before a start or a resume. Bounded, as every run is.
  defp auth_status(c, w, name) do
    with {:ok, account} <- Accounts.ready(w.accounts, name),
         {:ok, %{argv: argv, env: env}} <-
           ClaudeCLI.auth_status(account,
             claude: c.claude,
             env: c.env,
             tool_timeout: c.tool_timeout
           ),
         {:ok, %{env: env_program}} <- Programs.take(w.programs, [:env]) do
      vars = Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)
      Shell.run(w.programs.host, env_program, ["-i" | vars] ++ argv, timeout: 30_000)
    end
  end

  defp issue(nil, _agent), do: {:refused, :no_mcp}
  defp issue(mcp, agent), do: MCP.issue(mcp, agent)

  defp owner_ended(services, owner) do
    case Services.owner_ended(services, owner) do
      {:ok, _} -> :ok
      other -> Logger.warning("caf: services of #{owner}, who ended: #{inspect(other)}")
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
    tools = [:pre_tool_use | Config.hooks(c) -- [:pre_tool_use]]
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
