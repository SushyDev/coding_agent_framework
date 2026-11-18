defmodule CodingAgentFramework.Mains do
  @moduledoc """
  Each project's main sessions and its checkout (`docs/design.md`, "Main sessions";
  `model/tla/Checkout.tla`). One process per host, with no name, started by the embedding app;
  the one writer of `Mains.Table` (the checkouts' readings) and `Mains.Starts` (its starts).

      {:ok, mains} = Mains.start_link(host: "ws", home: "/srv/caf", db: db, sessions_db: db,
        programs: programs, reaper: reaper, sessions: sessions, mailbox: mailbox,
        usage: usage, accounts: accounts, launch: [claude: claude, env: env],
        projects: %{"app" => %{origin: "git@host:app.git", trunk: "main", setup: [],
          setup_timeout: 60_000, env: %{"HOME" => "/home/me"}}},
        mains: %{"app-main" => "app"})
      Mains.start_main(mains, "app", "app-epic", "Plan the epic.", from: "app-main")
      #=> {:ok, %{name: "app-epic", account: "work", session_id: "…"}}

  **The projects** are data: each names its `origin` (the repository its stacks land on, which
  the checkout is cloned from) and what `Sessions` reads of a project (`Sessions.Worktree`)
  but its `repo`, which is the checkout: `project/3` answers a project as `Sessions` and
  `Delegates` take it.

  **The checkout** (`Mains.Checkout`) of each project is made once, at its start when it has
  none: cloned on trunk under a temporary name, then renamed into place, so a restart in the
  middle of a clone leaves only the temporary directory, which the next start removes. Its
  reading (branch, clean, ahead and behind `origin/<trunk>`) is written to `Mains.Table` at each
  read, every `interval:` ms, for a view. **The pull** is owed after a landing (`landed/2`) and
  at each start of `Mains`, since a landing while it was down told nobody: cleared before its
  fetch, so a landing during the pull owes the next; then `git merge --ff-only`, only from a
  clean checkout on trunk that is not ahead. Any other reading holds the pull back, owed, and
  is a state a view shows; the read after a person cleans the checkout pulls. A clone that
  failed is made again only at the next `landed/2` or start.

  **Main sessions** are agent rows of kind `main` in `Sessions`. The ones the app names
  (`mains:`, name to project) are declared there before `start_link/1` returns, so the tree
  holds them and each can start its first delegate. `start_main/5` starts one.

  **A start** (`start_main/5`; the design's `start_main(project, name, brief)`) checks the
  project and its checkout, and that the name is free: no agent row, or a declared main session
  of that project; any other name, and the reserved names `framework` and the operator's, is
  refused `{:running, name}`. It picks the account with the most allowance left, declares the
  agent row, and writes its own row `starting`, the lease's holder; with a `scheduler:` it asks
  for a lease, class `:main` (a person's main session, always admitted), module the project,
  holder `{"main", key}` (`Mains.Work`). Granted, the brief is stored in `Mailbox` from the
  caller, marked by `launch`, and carried by the start as its first message; `Sessions` starts
  the session interactively in the checkout, with the app's MCP config, through its startup
  dialogs (F-140): a dialog that waits on a person answers `{:unknown, {:dialog, kind}}`, and
  the row stays `starting` until the agent row runs or is free. A restart that cut the call
  settles the row by the agent row of its call, or refuses it `interrupted` at its deadline.

  After each write `notify` gets `%{topic: "mains:<host>", ids: [id]}`.
  """

  use GenServer

  alias CodingAgentFramework.{Accounts, Intake, Mailbox, Programs, Scheduler}
  alias CodingAgentFramework.{Sessions, Shell, Store, Stream, Usage}
  alias CodingAgentFramework.Intake.Table, as: IntakeTable
  alias CodingAgentFramework.Mains.{Checkout, Starts, Table, Work}
  alias CodingAgentFramework.Sessions.{Agents, Worktree}

  # Sessions' own timeout for a start; its hold's and its viewer's bounds come on top.
  @call 30_000
  @slack 60_000
  @step 5_000
  @git 10_000
  @fetch 120_000
  @framework "framework"

  @type outcome(ok) :: {:ok, ok} | {:refused, term} | {:unknown, term}

  @doc """
  Starts `Mains`. Options: `host:` (the name of the host `sessions:` runs on), `home:` (the
  framework home), `db:` (its file), `sessions_db:` (`Sessions`' file, read through
  `Sessions.Agents`), `programs:` (naming git and env), `reaper:` (the host's `Shell.Reaper`),
  `sessions:`, `mailbox:`, `usage:` and `accounts:`, `projects:` (as the module doc says), and
  optionally `mains:` (`%{name => project}`, the main sessions the app declares), `launch:`
  (what every main session's launch shares: `claude:`, `env:`, `tool_timeout:`, `model:`),
  `mcp:` (a function of a main session's name answering `{:ok, path}`, its MCP config, as
  `Delegates` takes it), `scheduler:` and `lease:` (the units a start asks for, default
  `%{"seat" => 1}`), `operator:` (a name no main session may take), `interval:` (ms between the
  checkouts' reads, default 5 000), `clone_timeout:` (ms, default 600 000), `intake:` (the
  host's `Intake`) and `intake_db:` (its file), through which the operator answers a main
  session's held permission request (`answer/5`), `notify:` and `clock:` (wall-clock ms).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Project `name` as `Sessions` and `Delegates` read it: `data` with its `name` and its `repo`,
  the checkout under `home`.

      iex> CodingAgentFramework.Mains.project("/srv/caf", "app", %{origin: "/src/app", trunk: "main"})
      %{name: "app", origin: "/src/app", repo: "/srv/caf/checkouts/app", trunk: "main"}
  """
  @spec project(String.t(), String.t(), map) :: map
  def project(home, name, data),
    do: data |> Map.put(:name, name) |> Map.put(:repo, Checkout.path(home, name))

  @doc """
  Starts main session `name` of `project`, with `brief` (a string, or nil for none) as its
  first message (see the module doc). Options: `from:` (the brief's sender: a main session's
  name, or the operator's; the operator's by default), `model:` (the model it runs, else the
  app's launch's, F-141's new-8), `meta:` (a map of the app's own keys kept on the agent row,
  `Sessions.start/5`, F-154; refused `{:bad, :meta}` when not a map), `timeout:` (what the
  caller waits,
  default 300 000 ms; the start goes on past it). Answers `{:ok, %{name, account,
  session_id}}`; `{:refused, reason}`: `{:running, name}`, `{:unknown_project, project}`,
  `{:checkout, state}` while the checkout is not made, `{:lease, why}`, or `Sessions`' refusal
  (a brief longer than a launch's argument carries goes as a pointer to its file,
  `Mailbox.launch/4`, F-155); or `{:unknown, reason}` while its row
  waits, as on a startup dialog (`{:dialog, kind}`).
  """
  @spec start_main(GenServer.server(), String.t(), String.t(), String.t() | nil, keyword) ::
          outcome(map)
  def start_main(mains, project, name, brief, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    start = {:start_main, project, name, brief, opts[:from], opts[:model], opts[:meta]}
    call(mains, start, timeout)
  end

  @doc """
  Resumes main session `name`, whose process ended (its agent row `stopped`), in its checkout
  with its session id (F-141's new-5): new work, so it writes a start's row and asks the
  `Scheduler` for a lease of its own, class main session, as `start_main/5` does, and then
  `Sessions.resume/6` on the account with the most allowance left. Options: `model:` (else the
  model its row keeps), `state:` (the operator's fix, F-144: the state its claim in `Acts`
  holds, `fix_state/3`'s; the resume is refused `{:moved, state}` when the row's is another
  now) and `timeout:`. Answers as `start_main/5` does; refused also `:no_session`, `{:not_main,
  kind}`, `{:not_stopped, status}` and `{:running, name}` while a start of it is under way.

      Mains.resume_main(mains, "app-epic")
      #=> {:ok, %{name: "app-epic", account: "home", session_id: "…"}}
  """
  @spec resume_main(GenServer.server(), String.t(), keyword) :: outcome(map)
  def resume_main(mains, name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    call(mains, {:resume_main, name, opts[:model], Keyword.get(opts, :state, :any)}, timeout)
  end

  @doc """
  The state of main session `name` a fix claims in `Acts` (F-143's new-1): its agent row's
  status, session id and last process (pid and start time), so a resume after another resume
  and stop is a new state, and `held`, the ids of the `PermissionRequest` rows `Intake` holds
  for its session (none without `intake:`), so an answer moves it. The operator's `resume` and
  `answer` tools claim it, then call `resume_main/3` or `answer/5` with it. Answers `{:ok,
  state}`, or refused `:no_session` or `{:not_main, kind}`. Option: `:timeout`.

      Mains.fix_state(mains, "app-epic")
      #=> {:ok, %{status: "stopped", session_id: "…", pid: 4242, proc_start: "…", held: []}}
  """
  @spec fix_state(GenServer.server(), String.t(), keyword) :: outcome(map)
  def fix_state(mains, name, opts \\ []),
    do: call(mains, {:fix_state, name}, Keyword.get(opts, :timeout, @step))

  @doc """
  What the operator's fix needs of `state` (`fix_state/3`'s), read from that state alone, so
  its caller checks it before it claims the state (`Team.tla`'s Needed, F-149) and a fix the
  state refuses takes no claim: a `:resume` is refused `{:not_stopped, status}` unless the
  session's process ended (`stopped`) with a session id to take up, as `resume_main/3` refuses
  it. A start under way or a move is the resume's to meet when it acts. An answer's request is
  checked against `held` by its caller.

      Mains.fix_check(:resume, %{status: "declared", session_id: nil})
      #=> {:refused, {:not_stopped, "declared"}}
  """
  @spec fix_check(atom | tuple, map) :: :ok | {:refused, term}
  def fix_check(:resume, %{status: "stopped", session_id: sid}) when is_binary(sid), do: :ok
  def fix_check(:resume, %{status: status}), do: {:refused, {:not_stopped, status}}
  def fix_check(_fix, _state), do: :ok

  @doc """
  Answers main session `name`'s held permission request `request` (the id of its
  `PermissionRequest` row, as `fix_state/3`'s `held` names it) with `label`, `allow` or
  `deny`, through `Intake.answer/4`, as an interactive delegate's is answered (F-146's new-5):
  the operator's act, since a main session has no parent. Only while `state:` (the state the
  caller claimed, `fix_state/3`'s) is still the session's; else `{:refused, {:moved, now}}`
  and nothing is sent. Refused `{:not_held, request}` for a request it does not hold,
  `:no_intake` without `intake:`, and as `fix_state/3`. Answers `Intake.answer/4`'s answer:
  `{:ok, :sent}`; the dialog may have taken a person's answer first.

      Mains.answer(mains, "app-epic", "41", "allow", state: state)
      #=> {:ok, :sent}
  """
  @spec answer(GenServer.server(), String.t(), String.t(), String.t(), keyword) ::
          outcome(:sent)
  def answer(mains, name, request, label, opts \\ []) do
    claimed = Keyword.get(opts, :state, :any)
    call(mains, {:answer, name, request, label, claimed}, Keyword.get(opts, :timeout, 2 * @step))
  end

  @doc """
  Ends main session `name` for good (F-143; `Team.tla`'s `MainEnds`): the operator's act
  alone, which the app or the operator's tool `end_main` calls. Refused `{:starting, name}`
  while a start of it is under way here; then `Sessions.end_main/3` refuses it while any of its
  delegates has not ended (`{:delegates, names}`), stops it once idle, and marks its agent row
  `ended`, so the app's end of an owner's services ends every one it owns, kept ones too. Its
  name never starts again. Answers `{:ok, :ended}` or what `Sessions.end_main/3` answers.

      Mains.end_main(mains, "app-epic")
      #=> {:ok, :ended}
      #=> {:refused, {:delegates, ["app-epic-api"]}}
  """
  @spec end_main(GenServer.server(), String.t(), keyword) :: outcome(:ended)
  def end_main(mains, name, opts \\ []),
    do: call(mains, {:end_main, name}, Keyword.get(opts, :timeout, @call + @slack))

  @doc """
  Something landed in `project`'s trunk: a pull of its checkout is owed, and goes as soon as no
  read or pull of it is under way. For a project with no checkout yet, its clone is made.
  Answers `:ok` at once, or `{:refused, {:unknown_project, project}}`.
  """
  @spec landed(GenServer.server(), String.t()) :: :ok | {:refused, term} | {:unknown, term}
  def landed(mains, project), do: call(mains, {:landed, project}, @step)

  @doc """
  The reading of `project`'s checkout, as `Mains.Table` keeps it: `{:ok, row}`, or `{:refused,
  {:unknown_project, project}}`. Option: `:timeout`.
  """
  @spec checkout(GenServer.server(), String.t(), keyword) :: outcome(map)
  def checkout(mains, project, opts \\ []),
    do: call(mains, {:checkout, project}, Keyword.get(opts, :timeout, @step))

  @doc "Hands it a cue of the agent rows: its starts are settled again. Answers `:ok` at once."
  @spec cue(GenServer.server(), map) :: :ok
  def cue(mains, %{topic: _}), do: GenServer.cast(mains, :settle)

  @doc "What `Mains` reads, for `Cues`: the agent rows (a start that runs, or is refused)."
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(sessions), cue: &cue/2}

  defp call(mains, request, timeout) do
    GenServer.call(mains, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_mains}
    :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    keys = ~w(host home sessions mailbox usage accounts projects programs reaper)a
    s = Map.new(keys, &{&1, Keyword.fetch!(opts, &1)})

    with {:ok, run} <- Programs.take(s.programs, [:git, :env]),
         {:ok, intake} <- Intake.reader(opts),
         {:ok, projects} <- projects(s.home, s.projects),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         {:ok, starts} <- Starts.open(Keyword.fetch!(opts, :db)),
         {:ok, agents} <- Agents.open(Keyword.fetch!(opts, :sessions_db), s.host) do
      s =
        Map.merge(s, %{
          projects: projects,
          intake: intake,
          db: db,
          starts: starts,
          agents: agents,
          run: %{host: s.programs.host, git: run.git, env: run.env, reaper: s.reaper},
          launch: Keyword.get(opts, :launch, []),
          mcp: Keyword.get(opts, :mcp, fn _ -> {:ok, nil} end),
          scheduler: Keyword.get(opts, :scheduler),
          lease: Keyword.get(opts, :lease, %{"seat" => 1}),
          reserved: [@framework | List.wrap(Keyword.get(opts, :operator))],
          operator: Keyword.get(opts, :operator),
          interval: Keyword.get(opts, :interval, 5_000),
          clone_timeout: Keyword.get(opts, :clone_timeout, 600_000),
          notify: Keyword.get(opts, :notify, fn _ -> :ok end),
          clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
          # Per project: the task under way, and whether a pull is owed.
          checkouts:
            Map.new(projects, fn {name, _} ->
              {name, %{task: nil, owed: false, pulling: false}}
            end),
          calls: %{},
          ends: %{},
          waiting: %{}
        })

      # A start waiting for its lease when the Scheduler ends is refused: its queue is gone.
      s = Map.put(s, :scheduler_ref, s.scheduler && Process.monitor(s.scheduler))

      # The declared main sessions are rows before `start_link` returns: a tool call the app
      # sends right after its start may name one, and `Grants` reads the tree from the rows.
      case declare(s, Keyword.get(opts, :mains, %{})) do
        :ok -> {:ok, s, {:continue, :start}}
        {_, reason} -> {:stop, reason}
      end
    else
      {_, reason} -> {:stop, reason}
    end
  end

  defp projects(home, projects) do
    Enum.reduce_while(projects, {:ok, %{}}, fn {name, data}, {:ok, acc} ->
      p = project(home, name, data)

      with true <- (is_binary(p[:origin]) and p.origin != "") or {:refused, {:bad, :origin}},
           {:ok, checked} <- Worktree.project(p) do
        {:cont, {:ok, Map.put(acc, name, Map.merge(p, checked))}}
      else
        {:refused, why} -> {:halt, {:refused, {:project, name, why}}}
      end
    end)
  end

  defp declare(s, mains) do
    Enum.reduce_while(mains, :ok, fn {name, project}, :ok ->
      cond do
        not Map.has_key?(s.projects, project) -> {:halt, {:refused, {:unknown_project, project}}}
        name in s.reserved -> {:halt, {:refused, {:reserved, name}}}
        true -> declared(Sessions.declare(s.sessions, name, project))
      end
    end)
  end

  defp declared({:ok, _}), do: {:cont, :ok}
  defp declared(other), do: {:halt, other}

  @impl true
  def handle_continue(:start, s) do
    # Checkout.tla's Recover: a clone a restart cut is removed; every checkout owes a pull.
    s =
      Enum.reduce(Map.keys(s.projects), s, fn name, s ->
        File.rm_rf(Checkout.clone_path(s.home, name))
        s = put_in(s.checkouts[name].owed, true)
        step(s, name)
      end)

    for row <- Starts.starting_rows(s.starts, s.host), do: wake(s, row)
    Process.send_after(self(), :read, s.interval)
    {:noreply, settle(s)}
  end

  @impl true
  def handle_cast(:settle, s), do: {:noreply, settle(s)}

  @impl true
  def handle_call({:landed, project}, _from, s) do
    if Map.has_key?(s.projects, project) do
      s = put_in(s.checkouts[project].owed, true)
      {:reply, :ok, step(s, project)}
    else
      {:reply, {:refused, {:unknown_project, project}}, s}
    end
  end

  def handle_call({:checkout, project}, _from, s) do
    reply =
      case Map.has_key?(s.projects, project) && Table.get(s.db, s.host, project) do
        false -> {:refused, {:unknown_project, project}}
        nil -> {:ok, %{project: project, state: "absent"}}
        row -> {:ok, row}
      end

    {:reply, reply, s}
  end

  def handle_call({:start_main, project, name, brief, from_name, model, meta}, from, s) do
    with :ok <- name_ok(s, name),
         {:ok, p} <- Map.fetch(s.projects, project) |> known(project),
         :ok <- made(s, project),
         :ok <- free(s, project, name),
         :ok <- brief_ok(brief),
         :ok <- model_ok(model),
         true <- meta == nil or is_map(meta) or {:refused, {:bad, :meta}},
         {:ok, account} <- pick(s),
         {:ok, _} <- Sessions.declare(s.sessions, name, project) do
      uuid = if brief, do: Stream.uuid()
      row = starting(s, project, name, account, uuid)
      start = %{p: p, account: account, brief: brief, from: from_name || s.operator}
      leased(s, row, Map.merge(start, %{model: model, meta: meta, resume: nil}), from)
    else
      refused -> {:reply, refused, s}
    end
  end

  # F-141's new-5: a resume is new work, so it asks for a lease of its own, as a start does.
  # A fix's resume acts only on the state its claim holds (Team.tla's CanAct).
  def handle_call({:resume_main, name, model, claimed}, from, s) do
    agent = Agents.get(s.agents, name)

    with :ok <- resumable(s, agent),
         :ok <- claimed(s, agent, claimed),
         {:ok, p} <- Map.fetch(s.projects, agent.project) |> known(agent.project),
         :ok <- made(s, agent.project),
         :ok <- model_ok(model),
         {:ok, account} <- pick(s) do
      row = starting(s, agent.project, name, account, nil, agent.session_id)
      start = %{p: p, account: account, brief: nil, from: nil, model: model}
      leased(s, row, Map.put(start, :resume, agent.session_id), from)
    else
      refused -> {:reply, refused, s}
    end
  end

  def handle_call({:fix_state, name}, _from, s) do
    {:reply, with({:ok, agent} <- main_agent(s, name), do: fix_state_of(s, agent)), s}
  end

  # Team.tla's CanAct: the answer goes out only on the state its claim holds. The hold's one
  # response is Intake's (Hold.tla), as for an interactive delegate's request.
  def handle_call({:answer, name, request, label, claimed}, _from, s) do
    reply =
      with true <- label in ~w(allow deny) or {:refused, {:bad, :label}},
           true <- s.intake != nil or {:refused, :no_intake},
           {:ok, agent} <- main_agent(s, name),
           :ok <- claimed(s, agent, claimed),
           {:ok, %{held: held}} <- fix_state_of(s, agent),
           true <- request in held or {:refused, {:not_held, request}} do
        decision = if label == "allow", do: :allow, else: {:deny, "Denied by the operator."}
        Intake.answer(s.intake.pid, String.to_integer(request), decision, timeout: @step)
      end

    {:reply, reply, s}
  end

  # A start of the name under way would run a second process; Sessions refuses the rest.
  def handle_call({:end_main, name}, from, s) do
    if Enum.any?(Starts.starting_rows(s.starts, s.host), &(&1.name == name)) do
      {:reply, {:refused, {:starting, name}}, s}
    else
      sessions = s.sessions
      task = Task.async(fn -> Sessions.end_main(sessions, name, timeout: @call) end)
      {:noreply, put_in(s.ends[task.ref], from)}
    end
  end

  defp main_agent(s, name) do
    case Agents.get(s.agents, name) do
      nil -> {:refused, :no_session}
      %{kind: "main"} = agent -> {:ok, agent}
      %{kind: kind} -> {:refused, {:not_main, kind}}
    end
  end

  defp fix_state_of(s, agent) do
    state = Map.take(agent, [:status, :session_id, :pid, :proc_start])
    {:ok, Map.put(state, :held, held(s, agent))}
  end

  # The session's held PermissionRequests, as Intake keeps them. An Intake that never started
  # on this host holds none.
  defp held(%{intake: nil}, _agent), do: []

  defp held(s, %{session_id: sid, account: account}) when is_binary(sid) and is_binary(account) do
    case IntakeTable.session(s.intake.db, s.host, account, sid) do
      {:ok, %{held: held}} -> Enum.map(held, &Integer.to_string/1)
      :unread -> []
    end
  end

  defp held(_s, _agent), do: []

  defp claimed(_s, _agent, :any), do: :ok

  defp claimed(s, agent, state) do
    {:ok, now} = fix_state_of(s, agent)
    if now == state, do: :ok, else: {:refused, {:moved, now}}
  end

  # `resume` is the session id a resume takes up, nil for a start (F-143's new-5).
  defp starting(s, project, name, account, uuid, resume \\ nil) do
    start = %{host: s.host, project: project, name: name, account: account.name, resume: resume}
    row = Starts.starting(s.starts, Map.merge(start, %{brief_uuid: uuid, deadline: deadline(s)}))
    announce(s, row.id)
    row
  end

  # Schedule.tla: the row is the lease's holder, written before the lease is asked for.
  defp leased(s, row, start, from) do
    case lease(s, row, start.account) do
      {:ok, _lease} ->
        begin(s, row, start, from)

      {:queued, %{id: request}} ->
        {:noreply, put_in(s.waiting[request], %{id: row.id, from: from, start: start})}

      not_granted ->
        {:reply, refuse(s, row, {:lease, lease_refusal(not_granted)}), s}
    end
  end

  @impl true
  def handle_info(:read, s) do
    Process.send_after(self(), :read, s.interval)
    {:noreply, Enum.reduce(Map.keys(s.projects), s, &step(&2, &1))}
  end

  def handle_info(:deadline, s), do: {:noreply, settle(s)}

  # The one more answer to a queued lease: the start goes on, or is refused.
  def handle_info({:lease, request, answer}, s) do
    case Map.pop(s.waiting, request) do
      {%{id: id, from: from, start: start}, waiting} ->
        s = %{s | waiting: waiting}

        case answer do
          {:ok, _lease} ->
            # The call of Sessions starts now: its agent row is told from an earlier one by it.
            Starts.update(s.starts, id, called_at: s.clock.(), deadline: deadline(s))

            case begin(s, Starts.get(s.starts, id), start, from) do
              {:noreply, s} -> {:noreply, s}
              {:reply, reply, s} -> {:noreply, reply_to(from, reply, s)}
            end

          {:refused, why} ->
            {:noreply, reply_to(from, refuse(s, Starts.get(s.starts, id), {:lease, why}), s)}
        end

      {nil, _} ->
        {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{scheduler_ref: ref} = s) do
    s =
      Enum.reduce(Map.keys(s.waiting), s, fn request, s ->
        {:noreply, s} = handle_info({:lease, request, {:refused, :scheduler_ended}}, s)
        s
      end)

    {:noreply, s}
  end

  def handle_info({ref, answer}, s) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    cond do
      Map.has_key?(s.calls, ref) ->
        {%{id: id, from: from}, calls} = Map.pop(s.calls, ref)
        s = %{s | calls: calls}
        {:noreply, reply_to(from, answered(s, Starts.get(s.starts, id), answer), s)}

      Map.has_key?(s.ends, ref) ->
        {from, ends} = Map.pop(s.ends, ref)
        {:noreply, reply_to(from, answer, %{s | ends: ends})}

      project = Enum.find_value(s.checkouts, fn {p, c} -> if c.task == ref, do: p end) ->
        {:noreply, checked(s, project, answer)}

      true ->
        {:noreply, s}
    end
  end

  defp reply_to(nil, _reply, s), do: s

  defp reply_to(from, reply, s) do
    GenServer.reply(from, reply)
    s
  end

  # -- The checkout ----------------------------------------------------------------------------

  # One task per project at a time: the clone when there is no checkout, else a read, which is
  # a pull when one is owed. The owed pull is cleared as its task starts (Checkout.tla's Fetch),
  # so a landing while it runs owes the next one.
  defp step(s, name) do
    c = s.checkouts[name]
    p = s.projects[name]

    cond do
      c.task != nil ->
        s

      not File.dir?(p.repo) and not c.owed ->
        s

      not File.dir?(p.repo) ->
        s
        |> put(name, state: "cloning", owed: true, reason: nil)
        |> run_task(name, false, fn -> clone(s, p) end)

      true ->
        run_task(s, name, c.owed, fn -> read(s, p, c.owed) end)
    end
  end

  # A task linked to Mains, as a worktree's in `Sessions`: its git commands run with the host's
  # reaper, so Mains' death ends them, and a restart finds only what is on disk.
  defp run_task(s, name, pulling?, fun) do
    task = Task.async(fun)
    put_in(s.checkouts[name], %{task: task.ref, owed: false, pulling: pulling?})
  end

  # A task's answer: the reading written, and the pull owed again when a reading held it back,
  # for the read after a person cleans the checkout. One a landing owed while the task ran goes
  # now. A clone or a pull that failed is a state a view shows: the next landing owes it again.
  defp checked(s, name, answer) do
    landed? = s.checkouts[name].owed
    s = put_in(s.checkouts[name].task, nil)

    s =
      case answer do
        # The read that follows at once says what the new checkout is.
        {:cloned, :ok} ->
          put_in(s.checkouts[name].owed, true)

        {:read, reading, pulled} ->
          held? = pulled not in [:none, :pulled]
          fields = [state: reading.state, branch: reading.branch, clean: reading.clean]
          fields = fields ++ [ahead: reading.ahead, behind: reading.behind, read_at: s.clock.()]
          fields = if pulled == :pulled, do: fields ++ [pulled_at: s.clock.()], else: fields
          reason = if held?, do: Store.text(pulled), else: nil
          s = put_in(s.checkouts[name].owed, landed? or held?)
          put(s, name, fields ++ [reason: reason, owed: landed? or held?])

        # A lock is a person's to clear: the pull stays owed, as one a reading held back does,
        # and the read after they clear it pulls (F-143). Nothing here removes it.
        {:failed, reason} ->
          state =
            if File.dir?(s.projects[name].repo),
              do: Checkout.failed_state(reason),
              else: "absent"

          owed? = landed? or (state == "locked" and s.checkouts[name].pulling)
          s = put_in(s.checkouts[name].owed, owed?)
          put(s, name, state: state, reason: Store.text(reason), owed: owed?)
      end

    # A new checkout is read, and pulled, at once.
    if landed? or match?({:cloned, _}, answer), do: step(s, name), else: s
  end

  defp put(s, name, fields) do
    p = s.projects[name]
    id = Table.put(s.db, s.host, name, [path: p.repo, trunk: p.trunk] ++ fields)
    announce(s, id)
    s
  end

  # Checkout.tla's CloneStart, CloneDone and Rename: under a temporary name, then renamed whole.
  defp clone(s, p) do
    tmp = Checkout.clone_path(s.home, p.name)

    with :ok <- File.mkdir_p(Path.dirname(tmp)) |> io(:mkdir),
         {:ok, _} <- File.rm_rf(tmp) |> io(:rm),
         {:ok, _} <- git(s, p, {:clone, p.origin, p.trunk, tmp}, s.clone_timeout),
         {:ok, _} <- git(s, p, {:head, tmp, p.trunk}, @git),
         :ok <- File.rename(tmp, p.repo) |> io(:rename) do
      {:cloned, :ok}
    else
      {_, reason} -> {:failed, {:clone, reason}}
    end
  end

  defp io(:ok, _what), do: :ok
  defp io({:ok, _} = ok, _what), do: ok
  defp io({:error, reason}, what), do: {:refused, {what, reason}}
  defp io({:error, reason, _file}, what), do: {:refused, {what, reason}}

  # A read, and when a pull is owed (Fetch, Check, Merge): only from a clean checkout on trunk
  # that is not ahead, read before the fetch and again after it; git's `--ff-only` refuses a
  # local commit, and an edit made since that it would overwrite, and carries any other.
  defp read(s, p, owed?) do
    with {:ok, first} <- reading(s, p) do
      cond do
        not owed? ->
          {:read, first, :none}

        not Checkout.pullable?(first) ->
          {:read, first, {:held, first.state}}

        true ->
          with {:ok, _} <- git(s, p, {:fetch, p.repo, p.trunk}, @fetch),
               {:ok, fetched} <- reading(s, p),
               {:ok, pulled} <- merge(s, p, fetched) do
            pulled
          else
            {_, reason} -> {:failed, {:pull, reason}}
          end
      end
    end
  end

  defp merge(_s, _p, %{state: "ready"} = r), do: {:ok, {:read, r, :pulled}}

  defp merge(_s, _p, %{state: state} = r) when state != "behind",
    do: {:ok, {:read, r, {:held, state}}}

  defp merge(s, p, _behind) do
    merged = git(s, p, {:merge, p.repo, p.trunk}, @git)

    with {:ok, after_merge} <- reading(s, p) do
      case merged do
        {:ok, _} -> {:ok, {:read, after_merge, :pulled}}
        {_, reason} -> {:ok, {:read, after_merge, {:merge, reason}}}
      end
    end
  end

  defp reading(s, p) do
    branch =
      case git(s, p, {:branch, p.repo}, @git) do
        {:ok, out} -> out
        {:refused, {:git, 1, _}} -> nil
        other -> other
      end

    with b when is_binary(b) or is_nil(b) <- branch,
         {:ok, status} <- git(s, p, {:status, p.repo}, @git),
         {:ok, counts} <- git(s, p, {:counts, p.repo, p.trunk}, @git),
         %{} = r <- Checkout.reading(p.trunk, b, status, counts) do
      # git's own lock, which a cut command leaves: a read may still pass, a merge never does.
      # Read, never removed: a person clears it (F-143).
      if File.exists?(Checkout.lock_path(p.repo)),
        do: {:ok, %{r | state: "locked"}},
        else: {:ok, r}
    else
      {_, reason} -> {:failed, {:read, reason}}
    end
  end

  # git under `env -i` with the project's environment, so nothing of the framework's own
  # environment reaches the repository; with the host's reaper.
  defp git(s, p, command, timeout) do
    args = Worktree.env_args(p) ++ [s.run.git | Checkout.git(command)]

    case Shell.run(s.run.host, s.run.env, args, timeout: timeout, reaper: s.run.reaper) do
      {:ok, %{status: 0, output: out}} -> {:ok, out}
      {:ok, %{status: status, output: out}} -> {:refused, {:git, status, tail(out)}}
      other -> other
    end
  end

  defp tail(out), do: String.slice(out, -min(String.length(out), 200), 200)

  # -- A start ---------------------------------------------------------------------------------

  defp name_ok(s, name) do
    cond do
      name in s.reserved -> {:refused, {:running, name}}
      not Worktree.name?(name) -> {:refused, {:bad, :name}}
      true -> :ok
    end
  end

  defp known(:error, project), do: {:refused, {:unknown_project, project}}
  defp known(ok, _project), do: ok

  # Only the rename puts a checkout at its path, so one there is whole (`WholeCheckout`).
  defp made(s, project) do
    cond do
      File.dir?(s.projects[project].repo) -> :ok
      row = Table.get(s.db, s.host, project) -> {:refused, {:checkout, row.state}}
      true -> {:refused, {:checkout, "absent"}}
    end
  end

  # A name is free for a new main session when no agent row has it, or a declared one of this
  # project never started since, or one of this project whose start never ran (stopped or
  # refused with no session id: nothing to resume, F-151), and no start of it is under way here.
  defp free(s, project, name) do
    agent = Agents.get(s.agents, name)
    starting = Enum.any?(Starts.starting_rows(s.starts, s.host), &(&1.name == name))

    cond do
      starting -> {:refused, {:running, name}}
      agent == nil -> :ok
      agent.project != project -> {:refused, {:running, name}}
      Agents.declared?(agent) -> :ok
      agent.status in ["stopped", "refused"] and not is_binary(agent.session_id) -> :ok
      true -> {:refused, {:running, name}}
    end
  end

  defp brief_ok(nil), do: :ok

  defp brief_ok(brief) when is_binary(brief) and brief != "", do: :ok

  defp brief_ok(_brief), do: {:refused, {:bad, :brief}}

  defp model_ok(nil), do: :ok
  defp model_ok(model) when is_binary(model) and model != "", do: :ok
  defp model_ok(_model), do: {:refused, {:bad, :model}}

  # A main session whose process ended, with a session to resume (fix_check/2, what its fix
  # state says), not moving, and no start of it under way.
  defp resumable(_s, nil), do: {:refused, :no_session}
  defp resumable(_s, %{kind: kind}) when kind != "main", do: {:refused, {:not_main, kind}}

  defp resumable(s, agent) do
    cond do
      Enum.any?(Starts.starting_rows(s.starts, s.host), &(&1.name == agent.name)) ->
        {:refused, {:running, agent.name}}

      Agents.moving?(agent) ->
        {:refused, {:not_stopped, agent.status}}

      true ->
        fix_check(:resume, agent)
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

  defp lease(%{scheduler: nil}, _row, _account), do: {:ok, nil}

  defp lease(s, row, account) do
    key = Work.key(s.host, row.id)

    Scheduler.request(s.scheduler, %{
      # The row's start time too: a table made anew numbers its rows from 1 again.
      id: "main:#{key}:#{row.created_at}",
      class: :main,
      module: row.project,
      account: account.name,
      units: s.lease,
      holder: {"main", key}
    })
  end

  defp lease_refusal({:refused, why}), do: why
  defp lease_refusal({:unknown, why}), do: {:unknown, why}

  # With its lease: the brief stored from its sender, marked by launch, and carried by the
  # start as its first message; Sessions starts the session in the checkout.
  defp begin(s, row, start, from) do
    with :ok <- brief(s, row, start),
         {:ok, launched} <- launch_first(s, row, start) do
      launch = [role: :parent, kind: :main, cwd: start.p.repo, project: row.project]
      launch = launch ++ launch_model(s.launch, start)
      launch = if launched, do: launch ++ [prompt: launched.text], else: launch
      # A start that names no metadata, and a resume, keep the row's (`Sessions.start/5`).
      launch = if start[:meta], do: launch ++ [meta: start.meta], else: launch
      {sessions, mailbox, mcp} = {s.sessions, s.mailbox, s.mcp}

      # The config is made in the task: the embedding app's `issue` may call a part that waits.
      task =
        Task.async(fn ->
          answer =
            with {:ok, config} <- mcp.(row.name) do
              launch = if config, do: launch ++ [mcp: config], else: launch
              session(sessions, row.name, start, launch)
            end

          if launched, do: Mailbox.launched(mailbox, launched.id, answer)
          answer
        end)

      {:noreply, put_in(s.calls[task.ref], %{id: row.id, from: from})}
    else
      not_started -> {:reply, refuse(s, row, not_started), s}
    end
  end

  defp brief(_s, %{brief_uuid: nil}, _start), do: :ok

  defp brief(s, row, start) do
    case Mailbox.brief(s.mailbox, start.from, row.name, start.brief, row.brief_uuid) do
      {:ok, _} -> :ok
      other -> {:brief, other}
    end
  end

  defp session(sessions, name, %{resume: nil} = start, launch),
    do: Sessions.start(sessions, name, start.account, launch, timeout: @call)

  defp session(sessions, name, start, launch),
    do: Sessions.resume(sessions, name, start.account, start.resume, launch, timeout: @call)

  # The model the caller names (F-141's new-8), else the app's; a resume that names none runs
  # the one its row keeps, as a move's resume does.
  defp launch_model(launch, %{model: model}) when is_binary(model),
    do: Keyword.put(launch, :model, model)

  defp launch_model(launch, %{resume: resume}) when is_binary(resume),
    do: Keyword.delete(launch, :model)

  defp launch_model(launch, _start), do: launch

  # A resume carries no brief: what is queued to it goes in by its waiter once it runs.
  defp launch_first(_s, _row, %{resume: resume}) when is_binary(resume), do: {:ok, nil}

  defp launch_first(s, row, _start) do
    case Mailbox.launch(s.mailbox, row.name, row.deadline) do
      {:ok, %{id: _, text: _} = launched} -> {:ok, launched}
      {:ok, :none} -> {:ok, nil}
      other -> {:launch, other}
    end
  end

  # The call's answer moves the row once: running, or refused; an unknown one (a dialog that
  # waits on a person) leaves it starting for the agent row to settle.
  defp answered(s, row, {:ok, %{session_id: sid}}) do
    write(s, row, status: "running", reason: nil)
    {:ok, %{name: row.name, account: row.account, session_id: sid}}
  end

  defp answered(s, row, {:refused, why}), do: refuse(s, row, why)

  defp answered(s, row, {:unknown, why} = unknown) do
    write(s, row, reason: why)
    wake(s, row)
    unknown
  end

  # A refused start's brief never goes in (F-141's new-4): its one row is settled, and other
  # rows to the name stay queued for its next start.
  defp refuse(s, row, why) do
    write(s, row, status: "refused", reason: why)
    drop_brief(s, row)
    {:refused, why}
  end

  defp drop_brief(_s, %{brief_uuid: nil}), do: :ok
  defp drop_brief(s, row), do: Mailbox.settle_row(s.mailbox, row.brief_uuid)

  # A start with no call under way here, read again: by the agent row of its call once that row
  # is settled; with none by its deadline, the call never reached Sessions.
  defp settle(s) do
    busy = MapSet.new(Map.values(s.calls) ++ Map.values(s.waiting), & &1.id)

    for row <- Starts.starting_rows(s.starts, s.host), not MapSet.member?(busy, row.id) do
      agent = Agents.get(s.agents, row.name)
      since? = Agents.since?(agent, row.called_at) and not Agents.declared?(agent)

      cond do
        since? and Agents.running?(agent) ->
          write(s, row, status: "running", reason: nil)

        since? and Agents.free?(agent) ->
          write(s, row, status: "refused", reason: agent.status)
          drop_brief(s, row)

        not since? and s.clock.() >= row.deadline ->
          write(s, row, status: "refused", reason: :interrupted)
          drop_brief(s, row)

        true ->
          :ok
      end
    end

    s
  end

  defp deadline(s), do: s.clock.() + @call + @slack

  # One wake at a start's deadline, when a cut call may be settled; not a poll.
  defp wake(s, row),
    do: Process.send_after(self(), :deadline, max(row.deadline - s.clock.(), 0))

  defp write(s, row, fields) do
    Starts.update(s.starts, row.id, fields)
    announce(s, row.id)
  end

  defp announce(s, id), do: s.notify.(%{topic: "mains:#{s.host}", ids: [id]})
end
