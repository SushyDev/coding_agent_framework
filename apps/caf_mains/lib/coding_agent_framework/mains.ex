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

  **A checkout's directory has one owner on a home** (F-229; `Checkout.tla`'s `OwnCheckout`).
  A start of `Mains` is refused `{:checkout_taken, path, other_project}` when a row of
  `Mains.Table` of another project, from an earlier config on this home, holds a project's
  path; the project's own row is its own. A directory at the path is taken as the checkout only
  when its `origin` is the project's: each read, and each start in it, reads it first, and
  another one reads `failed` with reason `{:origin_mismatch, path, found}`, refuses a start so,
  and is never cloned over, pulled or changed. A person decides. A project's `dir:` gives two
  origins of one name a directory each.

  **Main sessions** are agent rows of kind `main` in `Sessions`. The ones the app names
  (`mains:`, name to project) are declared there before `start_link/1` returns, so the tree
  holds them and each can start its first delegate. `start_main/5` starts one.

  **A start** (`start_main/5`; the design's `start_main(project, name, brief)`) checks the
  project and its checkout, and that the name is free: no agent row, or a declared main session
  of that project; any other name, and the reserved names `framework` and the operator's, is
  refused `{:running, name}`. It picks the usable account with the most room (`Usage.pick/4`:
  by `usable:`, and the most room in the tighter window), declares the
  agent row, and writes its own row `starting`, the lease's holder; with a `scheduler:` it asks
  for a lease, class `:main` (a person's main session, always admitted), module the project,
  holder `{"main", key}` (`Mains.Work`). Granted, the brief is stored in `Mailbox` from the
  caller, marked by `launch`, and carried by the start as its first message; `Sessions` starts
  the session interactively in the checkout, with the app's MCP config, through its startup
  dialogs (F-140): a dialog that waits on a person answers `{:unknown, {:dialog, kind}}`, and
  the row stays `starting` until the agent row runs or is free. A restart that cut the call
  settles the row by the agent row of its call, or refuses it `interrupted` at its deadline.

  **A checkout under the project's name** (F-156), which an earlier build made, is renamed to
  its directory once no agent row of the project may hold a process, with each account's
  conversations and the home's memory of it (`Mains.Rename`); before that its state is `old`,
  its reason the sessions that hold it, and no clone is made beside it. Each read links again
  a worktree whose checkout moved (`git worktree repair`).

  **Imported conversations** (F-156): at its start, before it declares the app's main
  sessions, `Mains` has `Sessions` write each one `bin/caf-import` copied with a name as a
  stopped main session in its project's checkout (`Mains.Import.manifest/1`,
  `Sessions.import_main/4`), which `resume_main/3` takes up.

  **A resume** (`resume_main/3`, F-177; `Move.tla`'s Resume) runs on the account its row
  names, where its conversation is: a conversation lives only in the account it ran on or was
  imported into. Only when that account is refused (not prepared, logged out, or its windows
  spent by `allowance:`) does it go to the one with the most room among the others that are
  not (`Usage.pick/4`), which first takes a copy of the conversation (`Transcripts.Copy`, the `Mover`'s
  copy), an act `copy` in `Acts`, then resumes there under the same session id. A copy refused
  leaves the row on its own account, the start refused `{:copy, reason}`.

  **At a usage limit** (F-196; `Limit.tla`'s StartRefusedAtLimit): a start or a resume that
  finds every usable account limited writes its row `waiting` for the soonest reset, its
  request kept on it, and answers at once `{:ok, %{id, name, account: nil, session_id: nil,
  waiting: until}}`. The row is a `limit` prompt (`answer_wait/4`). At the reset plus
  `limit_margin:` (default 120 000 ms) it picks its account again and asks for its lease under
  its own row (StartAtReset); a newer limit makes it wait for that reset. A start's sender is
  told its outcome once by a notice; a resume's has its prompt and its act. While it waits,
  a start, resume or end of the name is refused `{:waiting, name}`.

  After each write `notify` gets `%{topic: "mains:<host>", ids: [id]}`.
  """

  use GenServer

  alias CodingAgentFramework.{Accounts, Acts, Intake, Mailbox, Programs, Scheduler}
  alias CodingAgentFramework.{Sessions, Shell, Store, Stream, Transcripts, Usage}
  alias CodingAgentFramework.Intake.Table, as: IntakeTable
  alias CodingAgentFramework.Mains.{Checkout, Import, Rename, Starts, Table, Work}
  alias CodingAgentFramework.Sessions.{Agents, Worktree}

  # Sessions' own timeout for a start; its hold's and its viewer's bounds come on top.
  @call 30_000
  @slack 60_000
  @step 5_000
  @git 10_000
  @fetch 120_000
  @framework "framework"
  # After a usage limit's reset, before a waiting start picks again (F-196), as the healer's.
  @margin 120_000

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
  session's held permission request (`answer/5`), `acts:` (the instance's `Acts`, where a
  checkout's rename, an import's rows and a resume's copy are recorded, F-156, F-177),
  `allowance:` (a function of an account answering `:room` or `{:spent, retry_at}`, the
  `Scheduler`'s own, `Usage.Allowance.check/3`; without it every account has room: a resume
  leaves its row's account only when it is refused, F-177), `usable:` (a function of an account
  answering `{:ok, account}` for one a launch may run on now, else why not:
  `CodingAgentFramework.Logins.usable/3`, prepared and logged in, F-181; by default
  `Accounts.ready/2`), `notify:`, `clock:` (wall-clock ms), and
  `name_room:` (bytes, the room the home leaves for an agent's socket, `Config.name_room/1`): a
  start of a longer name is refused `{:bad, :name, {:longer_than, n}}` before any row (F-172).
  A start's call of `Sessions` carries the caller's deadline, the row's less its slack, so a
  request still queued there when `settle` reads the absent agent row at the row's deadline is
  refused `:caller_gone` and makes nothing (F-166's new-1).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The topics of the cues it writes, each as its whole shape, `*` for a word it fills in
  (`CodingAgentFramework.Cues`): `mains:<host>`.
  """
  @spec writes() :: [String.t()]
  def writes, do: ~w(mains:*)

  @doc """
  Project `name` as `Sessions` and `Delegates` read it: `data` with its `name`, its `dir` (the
  checkout's directory: `data`'s `dir:`, by default the repository's name,
  `Checkout.dir_name/1`, F-156) and its `repo`, the checkout under `home`.

      iex> CodingAgentFramework.Mains.project("/srv/caf", "app", %{origin: "/src/app_repo", trunk: "main"})
      %{name: "app", dir: "app_repo", origin: "/src/app_repo", repo: "/srv/caf/checkouts/app_repo", trunk: "main"}
  """
  @spec project(String.t(), String.t(), map) :: map
  def project(home, name, data) do
    dir = data[:dir] || Checkout.dir_name(data[:origin])
    repo = if Checkout.dir?(dir), do: Checkout.path(home, dir)
    data |> Map.put(:name, name) |> Map.put(:dir, dir) |> Map.put(:repo, repo)
  end

  @doc """
  Starts main session `name` of `project`, with `brief` (a string, or nil for none) as its
  first message (see the module doc). Options: `from:` (the brief's sender: a main session's
  name, or the operator's; the operator's by default), `model:` (the model it runs, else the
  app's launch's, F-141's new-8), `meta:` (a map of the app's own keys kept on the agent row,
  `Sessions.start/5`, F-154; refused `{:bad, :meta}` when not a map), `timeout:` (what the
  caller waits,
  default 300 000 ms; the start goes on past it). Answers `{:ok, %{name, account,
  session_id}}`; `{:refused, reason}`: `{:running, name}`, `{:unknown_project, project}`,
  `{:checkout, state}` while the checkout is not made, `{:origin_mismatch, path, found}` when
  the directory there is a clone of another origin (F-229), `{:lease, why}`, or `Sessions`' refusal
  (a brief longer than a launch's argument carries goes as a pointer to its file,
  `Mailbox.launch/4`, F-155); or `{:unknown, reason}` while its row
  waits, as on a startup dialog (`{:dialog, kind}`). Every usable account limited, it answers
  `{:ok, %{id, name, account: nil, session_id: nil, waiting: until}}` (the module doc's "At a
  usage limit").
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
  `Sessions.resume/6` on the account its row names, where its conversation is (F-177). When
  that account is refused (`{:not_prepared, account}`, `{:login, :logged_out}`, `{:allowance,
  retry_at}`), the conversation is first copied to the account `Usage.pick/4` finds among the
  others not refused (the most room), and resumed there; with none, the resume is refused
  `{:account, account, reason}`, or waits as a start does when every usable account is
  limited (`waiting: until`), and a copy refused `{:copy, reason}`, the row left on its
  account. Options: `model:` (else the model its row keeps), `state:` (the operator's fix,
  F-144: the state its claim in `Acts` holds, `fix_state/3`'s; the resume is refused `{:moved,
  state}` when the row's is another now) and `timeout:`. Answers as `start_main/5` does;
  refused also `:no_session`, `{:not_main, kind}`, `{:not_stopped, status}` and `{:running,
  name}` while a start of it is under way.

      Mains.resume_main(mains, "app-epic")
      #=> {:ok, %{name: "app-epic", account: "home", session_id: "…"}}
  """
  @spec resume_main(GenServer.server(), String.t(), keyword) :: outcome(map)
  def resume_main(mains, name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    call(mains, {:resume_main, name, opts[:model], Keyword.get(opts, :state, :any)}, timeout)
  end

  @doc """
  Answers the `limit` prompt of start row `id`, a start or resume that waits at a usage limit
  (F-196; `Limit.tla`'s AnswerWait and AnswerLeave), as `who`, once per reset: `"wait"` keeps
  it waiting for its reset, as its default at its deadline would, and the prompt leaves the
  inbox; `"leave"` refuses the row with reason `left`, its brief settled, and its sender told.
  Answers `{:ok, :waiting}` or `{:ok, :left}`; `{:refused, :settled}` for a row no longer
  waiting or answered for this reset; `{:refused, :no_start}`; `{:refused, {:bad, :choice}}`.

      Mains.answer_wait(mains, 3, "wait", "sam")
      #=> {:ok, :waiting}
  """
  @spec answer_wait(GenServer.server(), integer, String.t(), String.t()) :: outcome(atom)
  def answer_wait(mains, id, choice, who), do: call(mains, {:answer_wait, id, choice, who}, @step)

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
  Options: `:timeout`, and `force: true` (F-170), the operator's forced end, whose stop does not
  wait for the rows to the session (`Sessions.stop/3`).

      Mains.end_main(mains, "app-epic")
      #=> {:ok, :ended}
      #=> {:refused, {:delegates, ["app-epic-api"]}}
  """
  @spec end_main(GenServer.server(), String.t(), keyword) :: outcome(:ended)
  def end_main(mains, name, opts \\ []),
    do:
      call(
        mains,
        {:end_main, name, Keyword.get(opts, :force, false)},
        Keyword.get(opts, :timeout, @call + @slack)
      )

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
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         {:ok, projects} <- projects(s.home, s.projects, Table.rows(db, s.host)),
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
          name_room: Keyword.get(opts, :name_room),
          operator: Keyword.get(opts, :operator),
          interval: Keyword.get(opts, :interval, 5_000),
          clone_timeout: Keyword.get(opts, :clone_timeout, 600_000),
          notify: Keyword.get(opts, :notify, fn _ -> :ok end),
          clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
          acts: Keyword.get(opts, :acts),
          allowance: Keyword.get(opts, :allowance, fn _account -> :room end),
          margin: Keyword.get(opts, :limit_margin, @margin),
          usable: Keyword.get(opts, :usable, &Accounts.ready(s.accounts, &1)),
          # Per project: the task under way, whether a pull is owed, and the last reason a
          # rename of its old checkout was held back for (recorded once in `Acts`).
          checkouts:
            Map.new(projects, fn {name, _} ->
              {name, %{task: nil, owed: false, pulling: false, held: nil}}
            end),
          calls: %{},
          ends: %{},
          waiting: %{}
        })

      # A start waiting for its lease when the Scheduler ends is refused: its queue is gone.
      s = Map.put(s, :scheduler_ref, s.scheduler && Process.monitor(s.scheduler))

      # The declared main sessions are rows before `start_link` returns: a tool call the app
      # sends right after its start may name one, and `Grants` reads the tree from the rows.
      # An imported conversation's row first (F-156), so a declared name it takes is stopped,
      # with its session to resume, not declared.
      imported(s)

      case declare(s, Keyword.get(opts, :mains, %{})) do
        :ok -> {:ok, s, {:continue, :start}}
        {_, reason} -> {:stop, reason}
      end
    else
      {_, reason} -> {:stop, reason}
    end
  end

  defp projects(home, projects, rows) do
    checked =
      Enum.reduce_while(projects, {:ok, %{}}, fn {name, data}, {:ok, acc} ->
        p = project(home, name, data)

        with true <- (is_binary(p[:origin]) and p.origin != "") or {:refused, {:bad, :origin}},
             true <- Checkout.dir?(p.dir) or {:refused, {:bad, :dir}},
             {:ok, checked} <- Worktree.project(p) do
          {:cont, {:ok, Map.put(acc, name, Map.merge(p, checked))}}
        else
          {:refused, why} -> {:halt, {:refused, {:project, name, why}}}
        end
      end)

    # Two projects in one directory would share a checkout (F-156), and so would a project and
    # the one of an earlier config on this home whose row holds its path (F-229).
    with {:ok, projects} <- checked,
         nil <- Checkout.same_dir(projects) |> same_dir(),
         nil <- Enum.find_value(Enum.sort(projects), &taken(rows, &1)) do
      {:ok, projects}
    end
  end

  defp same_dir(nil), do: nil
  defp same_dir({dir, names}), do: {:refused, {:same_dir, dir, names}}

  defp taken(rows, {name, p}) do
    if other = Checkout.owner(rows, name, p.repo),
      do: {:refused, {:checkout_taken, p.repo, other}}
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

  # Each conversation `bin/caf-import` copied with a name becomes a main session's row,
  # stopped, with its session to resume, written by `Sessions` (F-156). Every start reads the
  # manifests again: a row written before answers `:already`, and a refusal (a name another
  # agent holds, a project the config lost) is an act in `Acts` for a person, each start.
  defp imported(s) do
    for %{name: name} = entry <- Import.manifest(s.home), is_binary(name) do
      answer =
        case Map.fetch(s.projects, entry.project) do
          {:ok, p} -> Sessions.import_main(s.sessions, name, %{entry | cwd: p.repo})
          :error -> {:refused, {:unknown_project, entry.project}}
        end

      case answer do
        {:ok, :already} -> :ok
        {:ok, _} -> record(s, "agent:" <> name, :import, :verified, detail: entry.session_id)
        other -> record(s, "agent:" <> name, :import, :failed, reason: other)
      end
    end

    :ok
  end

  defp record(%{acts: nil}, _target, _act, _outcome, _fields), do: :ok

  defp record(s, target, act, outcome, fields),
    do: Acts.record(s.acts, "mains:#{s.host}", target, act, outcome, fields)

  @impl true
  def handle_continue(:start, s) do
    # Checkout.tla's Recover: a clone a restart cut is removed; every checkout owes a pull.
    s =
      Enum.reduce(Map.keys(s.projects), s, fn name, s ->
        File.rm_rf(Checkout.clone_path(s.home, s.projects[name].dir))
        s = put_in(s.checkouts[name].owed, true)
        step(s, name)
      end)

    for row <- Starts.starting_rows(s.starts, s.host), do: wake(s, row)
    for row <- Starts.with_status(s.starts, s.host, "waiting"), do: wake(s, row)
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
         :ok <- not_waiting(s, name),
         :ok <- brief_ok(brief),
         :ok <- model_ok(model),
         true <- meta == nil or is_map(meta) or {:refused, {:bad, :meta}},
         picked = pick(s),
         :ok <- picked_or_limited(picked) do
      uuid = if brief, do: Stream.uuid()
      start = %{p: p, brief: brief, from: from_name || s.operator, model: model, meta: meta}
      start = Map.put(start, :resume, nil)

      case picked do
        {:ok, account} -> begin_start(s, {project, name, uuid}, start, account, from)
        {:refused, {:allowance, until}} -> wait(s, {project, name, uuid}, start, until)
      end
    else
      refused -> {:reply, refused, s}
    end
  end

  # F-141's new-5: a resume is new work, so it asks for a lease of its own, as a start does.
  # A fix's resume acts only on the state its claim holds (Team.tla's CanAct).
  def handle_call({:resume_main, name, model, claimed}, from, s) do
    agent = Agents.get(s.agents, name)

    with :ok <- resumable(s, agent),
         :ok <- not_waiting(s, name),
         :ok <- claimed(s, agent, claimed),
         {:ok, p} <- Map.fetch(s.projects, agent.project) |> known(agent.project),
         :ok <- made(s, agent.project),
         :ok <- model_ok(model) do
      start = %{p: p, brief: nil, from: nil, model: model, kept: agent.model}
      start = Map.put(start, :resume, agent.session_id)

      case resume_account(s, agent) do
        {:ok, account, copy} ->
          row = starting(s, agent.project, name, account, nil, agent.session_id)
          leased(s, row, Map.merge(start, %{account: account, copy: copy}), from)

        # Limit.tla's StartRefusedAtLimit (F-196): no usable account has room.
        {:refused, {:allowance, until}} ->
          wait(s, {agent.project, name, nil}, start, until)

        refused ->
          {:reply, refused, s}
      end
    else
      refused -> {:reply, refused, s}
    end
  end

  def handle_call({:answer_wait, id, choice, who}, _from, s) do
    reply =
      case Starts.get(s.starts, id) do
        %{host: host, status: "waiting"} = row when host == s.host ->
          wait_answer(s, row, choice, who)

        %{host: host} when host == s.host ->
          {:refused, :settled}

        _ ->
          {:refused, :no_start}
      end

    {:reply, reply, s}
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
  def handle_call({:end_main, name, force}, from, s) do
    cond do
      Enum.any?(Starts.starting_rows(s.starts, s.host), &(&1.name == name)) ->
        {:reply, {:refused, {:starting, name}}, s}

      not_waiting(s, name) != :ok ->
        {:reply, not_waiting(s, name), s}

      true ->
        sessions = s.sessions

        task =
          Task.async(fn -> Sessions.end_main(sessions, name, timeout: @call, force: force) end)

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

  # A start with its account: its agent row declared, then its own row, the lease's holder.
  defp begin_start(s, {project, name, uuid}, start, account, from) do
    case Sessions.declare(s.sessions, name, project) do
      {:ok, _} ->
        row = starting(s, project, name, account, uuid)
        leased(s, row, Map.put(start, :account, account), from)

      refused ->
        {:reply, refused, s}
    end
  end

  defp picked_or_limited({:ok, _}), do: :ok
  defp picked_or_limited({:refused, {:allowance, _}}), do: :ok
  defp picked_or_limited(other), do: other

  # One start or resume of a name at a time: one that waits at a limit holds it (F-196).
  defp not_waiting(s, name) do
    if Enum.any?(Starts.with_status(s.starts, s.host, "waiting"), &(&1.name == name)),
      do: {:refused, {:waiting, name}},
      else: :ok
  end

  # Limit.tla's StartRefusedAtLimit (F-196): every usable account is limited, so the start's
  # row waits for the soonest reset, its request kept on it and its sender owed the outcome;
  # the caller is answered at once.
  defp wait(s, {project, name, uuid}, start, until) do
    kept = Map.put(Map.delete(start, :p), :project, project)
    fields = %{host: s.host, project: project, name: name, brief_uuid: uuid, resume: start.resume}
    fields = Map.merge(fields, %{until: until, deadline: until + s.margin, start: kept})
    row = Starts.waiting(s.starts, Map.put(fields, :tell, start.from))
    announce(s, row.id)
    wake(s, row)
    answer = %{name: name, account: nil, session_id: nil, waiting: until}
    {:reply, {:ok, Map.put(answer, :id, row.id)}, s}
  end

  defp wait_answer(_s, %{waited: by}, _choice, _who) when is_binary(by), do: {:refused, :settled}

  defp wait_answer(s, row, "wait", who) do
    write(s, row, waited: who)
    {:ok, :waiting}
  end

  defp wait_answer(s, row, "leave", who) do
    write(s, row, status: "refused", reason: "left", waited: who)
    drop_brief(s, row)
    tell_starts(s)
    {:ok, :left}
  end

  defp wait_answer(_s, _row, _choice, _who), do: {:refused, {:bad, :choice}}

  # Limit.tla's StartAtReset (F-196): a waiting row, at its deadline (the reset plus the margin),
  # whether a person answered `wait` or not, picks its account again and asks for its lease
  # under its own request id; a newer limit makes it wait for that reset. Any other refusal
  # refuses the row; a read that failed decides nothing.
  defp waits(s) do
    now = s.clock.()

    Starts.with_status(s.starts, s.host, "waiting")
    |> Enum.filter(&(&1.deadline <= now))
    |> Enum.reduce(s, &repick(&2, &1))
  end

  defp repick(s, row) do
    start = Starts.request(row)

    with {:ok, p} <- Map.fetch(s.projects, start.project) |> known(start.project),
         start = Map.put(start, :p, p),
         {:ok, account, copy} <- again_account(s, row, start) do
      # The call's time as `Starts.starting/2` stamps it, which the agent row's start is read by.
      now = System.os_time(:millisecond)
      fields = [status: "starting", account: account.name, called_at: now]
      write(s, row, fields ++ [deadline: deadline(s), waited: nil])
      start = Map.merge(start, %{account: account, copy: copy})

      case leased(s, Starts.get(s.starts, row.id), start, nil) do
        {:noreply, s} -> s
        {:reply, _reply, s} -> s
      end
    else
      {:refused, {:allowance, until}} ->
        write(s, row, until: until, deadline: until + s.margin, waited: nil)
        wake(s, Starts.get(s.starts, row.id))
        s

      {:refused, {:usage, :unread}} ->
        s

      {:refused, why} ->
        write(s, row, status: "refused", reason: why)
        drop_brief(s, row)
        s

      {:unknown, _} ->
        s
    end
  end

  # A start picks again and declares its agent row; a resume takes its row's account first, as
  # `resume_main/3` does, the agent row read now.
  defp again_account(s, row, %{resume: nil}) do
    with {:ok, account} <- pick(s),
         {:ok, _} <- Sessions.declare(s.sessions, row.name, row.project),
         do: {:ok, account, nil}
  end

  defp again_account(s, row, start) do
    agent = Agents.get(s.agents, row.name)

    with :ok <- resumable(s, agent),
         true <- agent.session_id == start.resume or {:refused, {:moved, agent.session_id}},
         do: resume_account(s, agent)
  end

  # Delegate.tla's StartTold, for a main start that waited at a limit: once its row leaves
  # `waiting` and its call, its sender is told by a notice under the row's key, which `Mailbox`
  # takes once; the mark is cleared after.
  defp tell_starts(s) do
    busy = MapSet.new(Map.values(s.calls) ++ Map.values(s.waiting), & &1.id)

    for row <- Starts.owed(s.starts, s.host),
        row.status not in ["waiting", "starting"],
        not MapSet.member?(busy, row.id),
        match?({:ok, _}, tell_start(s, row)),
        do: write(s, row, tell: nil)

    s
  end

  defp tell_start(s, row) do
    at = row.until |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    how = if row.resume, do: "resume", else: "start"

    head =
      "The #{how} of main session #{row.name}, which waited for a usage limit's reset at #{at}"

    text =
      if row.status == "running",
        do: head <> ", has started on #{row.account}.",
        else: head <> ", did not start: #{row.reason}."

    key = "start:main:#{s.host}:#{row.id}:#{row.created_at}"
    Mailbox.notify(s.mailbox, row.tell, text, key: key, kind: :notice)
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
        s = reply_to(from, answered(s, Starts.get(s.starts, id), answer), s)
        {:noreply, tell_starts(s)}

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

      # Checkout.tla's RenameOld: a checkout an earlier build made under the project's name
      # goes to its directory before anything clones one there (OneCheckout).
      old = old_checkout(s, p) ->
        case running_in(s, p, old) do
          [] ->
            s
            |> put(name, state: "renaming", reason: nil)
            |> run_task(name, false, fn -> rename(s, p, old) end)

          names ->
            held_rename(s, name, {:running, names})
        end

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

    put_in(s.checkouts[name], %{
      s.checkouts[name]
      | task: task.ref,
        owed: false,
        pulling: pulling?
    })
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

        {:renamed, old} ->
          detail = %{from: old, to: s.projects[name].repo}
          record(s, "checkout:" <> name, :rename, :verified, detail: detail)
          put_in(s.checkouts[name], %{s.checkouts[name] | owed: true, held: nil})

        # The old checkout stays where it was, and the next read tries again.
        {:failed, {:rename, _} = reason} ->
          held_rename(s, name, reason)

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
    if landed? or match?({tag, _} when tag in [:cloned, :renamed], answer),
      do: step(s, name),
      else: s
  end

  # -- A checkout an earlier build named by its project (F-156) ---------------------------------

  # Its path, when the project's checkout is not made yet and a checkout under the project's
  # name is, which is no other project's directory.
  defp old_checkout(s, p) do
    old = Checkout.path(s.home, p.name)
    others = for {_, q} <- s.projects, do: q.repo

    if p.name != p.dir and old not in others and File.dir?(old) and not File.exists?(p.repo),
      do: old
  end

  # The agents whose process may live in the project's checkout or its worktrees: a rename
  # under them would move their files away (Checkout.tla's RenameOld guard).
  defp running_in(s, p, old) do
    for row <- Agents.rows(s.agents),
        row.project == p.name or row.cwd == old,
        not Agents.free?(row),
        do: row.name
  end

  defp held_rename(s, name, reason) do
    s = put(s, name, state: "old", reason: Store.text(reason))

    if s.checkouts[name].held == reason do
      s
    else
      record(s, "checkout:" <> name, :rename, :failed, reason: reason)
      put_in(s.checkouts[name].held, reason)
    end
  end

  # Each account's conversations and the home's memory of the old path go to the new one's,
  # entry by entry and never over one, then the checkout itself, last, so a restart part way
  # finds it still at its old path and does the rest; then its worktrees' links.
  defp rename(s, p, old) do
    with {:ok, moves} <- Rename.moves(s.home, account_dirs(s), old, p.repo),
         :ok <- Rename.move_all(moves),
         :ok <- File.rename(old, p.repo) |> io(:rename),
         :ok <- repair(s, p) do
      {:renamed, old}
    else
      {_, reason} -> {:failed, {:rename, reason}}
    end
  end

  defp account_dirs(s) do
    for name <- s.accounts.names, {:ok, dir} <- [Accounts.config_dir(s.accounts, name)], do: dir
  end

  # A worktree whose `.git` names the checkout's git directory at a path gone (a rename, or one
  # a restart cut before its repair) is linked again (`Checkout.tla`'s Repair).
  defp repair(s, p) do
    case Rename.stale_worktrees(p.repo) do
      [] ->
        :ok

      paths ->
        case git(s, p, {:repair, p.repo, paths}, @git) do
          {:ok, _} -> :ok
          other -> other
        end
    end
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
  # First of all, its origin: a directory of another origin is never repaired, read or pulled.
  defp read(s, p, owed?) do
    with :ok <- origin(s, p) |> failed_as_is(),
         :ok <- repair(s, p) |> failed(:repair),
         {:ok, first} <- reading(s, p) do
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

  defp failed(:ok, _what), do: :ok
  defp failed({_, reason}, what), do: {:failed, {what, reason}}

  defp failed_as_is(:ok), do: :ok
  defp failed_as_is({_, reason}), do: {:failed, reason}

  # F-229 (`Checkout.tla`'s OriginOK): the directory at the project's path is taken as its
  # checkout only when its `origin` is the project's. Another is a person's to decide: the
  # framework never clones over it or changes it. `{:origin_mismatch, path, found}`, `found`
  # nil when it names no origin.
  defp origin(s, p) do
    found =
      case git(s, p, {:origin, p.repo}, @git) do
        {:ok, out} -> {:ok, String.trim(out)}
        {:refused, {:git, 1, _}} -> {:ok, nil}
        other -> other
      end

    case found do
      {:ok, url} ->
        if Checkout.same_origin?(p.origin, url),
          do: :ok,
          else: {:refused, {:origin_mismatch, p.repo, url}}

      {_, reason} ->
        {:refused, {:origin, reason}}
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
      name in s.reserved ->
        {:refused, {:running, name}}

      # The room the home leaves for its socket (`Config.name_room/1`, F-172).
      (is_binary(name) and s.name_room) && byte_size(name) > s.name_room ->
        {:refused, {:bad, :name, {:longer_than, s.name_room}}}

      not Worktree.name?(name) ->
        {:refused, {:bad, :name}}

      true ->
        :ok
    end
  end

  defp known(:error, project), do: {:refused, {:unknown_project, project}}
  defp known(ok, _project), do: ok

  # Only the rename puts a checkout at its path, so one there is whole (`WholeCheckout`); and
  # it is the project's own only when its origin is (F-229), read now, not from the last read,
  # so a start right after Mains' own start never runs in another origin's clone.
  defp made(s, project) do
    p = s.projects[project]

    cond do
      File.dir?(p.repo) -> origin(s, p)
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

  # F-177: a conversation lives only in the account it ran on or was imported into, so a
  # resume runs on its row's account (`Move.tla`'s ResumeHere); only one refused there goes to
  # the picked account among those not refused, with a copy first (CopyAsked).
  defp resume_account(s, %{account: own}) do
    case usable(s, own) do
      {:ok, account} ->
        {:ok, account, nil}

      # Every usable account limited is a wait for the soonest reset (F-196), its own among them.
      {:refused, why} ->
        case for(n <- s.accounts.names, n != own, match?({:ok, _}, usable(s, n)), do: n) do
          [] ->
            no_other(own, why)

          others ->
            case pick(s, others) do
              {:ok, account} -> {:ok, account, %{from: own, why: why}}
              {:refused, {:allowance, at}} -> {:refused, {:allowance, soonest(at, why)}}
              refused -> refused
            end
        end

      # A login check that could not tell is no refusal: the conversation stays where it is,
      # and the resume says why it did not go (F-181).
      {:unknown, why} ->
        {:unknown, {:account, own, why}}
    end
  end

  defp no_other(_own, {:allowance, _} = why), do: {:refused, why}
  defp no_other(own, why), do: {:refused, {:account, own, why}}

  defp soonest(at, {:allowance, own_at}), do: min(at, own_at)
  defp soonest(at, _why), do: at

  # An account a launch may run on now: prepared, logged in (`claude auth status`, by
  # `usable:`), and with room in both windows and no limit, as the Scheduler's gate reads them.
  defp usable(s, name) do
    with {:ok, account} <- launchable(s, name),
         :room <- s.allowance.(name) do
      {:ok, account}
    else
      {:spent, retry_at} -> {:refused, {:allowance, retry_at}}
      refused -> refused
    end
  end

  defp launchable(s, name), do: s.usable.(name)

  # F-181: new work picks among the usable accounts, the one with the most room.
  defp pick(s, among \\ nil) do
    with {:ok, %{readings: readings}} <- Usage.readings(s.usage, timeout: @step),
         {:ok, name} <-
           Usage.pick(readings, among || s.accounts.names, div(s.clock.(), 1000),
             usable: &launchable(s, &1)
           ) do
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
      copy = copy(s, row, start)

      # The config is made in the task: the embedding app's `issue` may call a part that waits.
      # A resume on another account than its row's copies the conversation there first.
      task =
        Task.async(fn ->
          answer =
            with :ok <- copy.(),
                 {:ok, config} <- mcp.(row.name) do
              launch = if config, do: launch ++ [mcp: config], else: launch
              session(sessions, row, start, launch)
            end

          if launched, do: Mailbox.launched(mailbox, launched.id, answer)
          answer
        end)

      {:noreply, put_in(s.calls[task.ref], %{id: row.id, from: from})}
    else
      not_started -> {:reply, refuse(s, row, not_started), s}
    end
  end

  # The resume's conversation, from its row's account to the one it resumes on, as the Mover
  # copies a move's (`Move.tla`'s ResumeCopy): the row's process is gone, so it is final. The
  # copy is an act in `Acts`; refused, the row stays on its account (CopyRefused).
  defp copy(s, row, %{copy: %{from: from, why: why}} = start) do
    {accounts, rec, to} = {s.accounts, Map.take(s, [:acts, :host]), start.account.name}

    fn ->
      copied =
        with {:ok, source} <- Accounts.config_dir(accounts, from),
             {:ok, target} <- Accounts.config_dir(accounts, to),
             do: Transcripts.Copy.copy(source, target, start.p.repo, start.resume)

      detail = %{from: from, to: to, session_id: start.resume, because: why}

      case copied do
        :ok ->
          record(rec, "agent:" <> row.name, :copy, :verified, detail: detail)
          :ok

        {:refused, reason} ->
          record(rec, "agent:" <> row.name, :copy, :failed, detail: detail, reason: reason)
          {:refused, {:copy, reason}}
      end
    end
  end

  defp copy(_s, _row, _start), do: fn -> :ok end

  defp brief(_s, %{brief_uuid: nil}, _start), do: :ok

  defp brief(s, row, start) do
    case Mailbox.brief(s.mailbox, start.from, row.name, start.brief, row.brief_uuid) do
      {:ok, _} -> :ok
      other -> {:brief, other}
    end
  end

  # The call carries the caller's deadline, the row's less the slack (F-166's new-1, F-172), as
  # `Delegates`' does (`Delegate.tla`'s Called, CallerLate, TakeStale): `settle/1` reads an
  # absent agent row at the row's deadline as a call that never reached `Sessions`, so a
  # request still in `Sessions`' queue by then must be refused there, not started under a row
  # `Mains` refused.
  defp session(sessions, row, %{resume: nil} = start, launch) do
    opts = [timeout: @call, caller_deadline: row.deadline - @slack]
    Sessions.start(sessions, row.name, start.account, launch, opts)
  end

  defp session(sessions, row, start, launch) do
    opts = [timeout: @call, caller_deadline: row.deadline - @slack]
    Sessions.resume(sessions, row.name, start.account, start.resume, launch, opts)
  end

  # The model the caller names (F-141's new-8), else the app's; a resume that names none runs
  # the one its row keeps, as a move's resume does; a row that keeps none (an imported
  # conversation's, F-156) runs the app's.
  defp launch_model(launch, %{model: model}) when is_binary(model),
    do: Keyword.put(launch, :model, model)

  defp launch_model(launch, %{resume: resume, kept: kept})
       when is_binary(resume) and is_binary(kept),
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
    s = waits(s)
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

    tell_starts(s)
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
