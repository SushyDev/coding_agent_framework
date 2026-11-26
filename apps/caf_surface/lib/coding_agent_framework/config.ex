defmodule CodingAgentFramework.Config do
  @moduledoc """
  What the framework runs with, as data: the embedding app's whole configuration, read by no
  part from the environment, and checked whole by `new/1` before anything starts, each refusal
  naming its key.

  - `home`: the framework home, an absolute path. Every file the app writes is under it:
    `caf.db` (the readers' and writers' tables, `Acts`' among them), `claims.db` (the claims
    an older build kept, which `Acts` takes once and empties), `accounts/`, `d/` (the dtach
    directory, kept short for macOS's 104-byte socket paths), `tmux.sock` (its own tmux
    server), `streams/`, `checkouts/` (each project's checkout), `worktrees/`, `parts/` (the
    tables of `Copies`, `Jobs`, `Services` and `MCP`) and `ws/` (the workstation's copies and
    service logs). It may hold a space, as macOS's `~/Library/Application Support/<app>` does
    (F-169). Its sockets (`tmux.sock`, `d/<agent>.sock`, `ws/jobs/<job>.sock`,
    `ws/services/<key>.sock`) must fit macOS's 103 bytes. A home longer than 93 bytes, where
    `tmux.sock` does not fit, is refused, `{:bad, :home, {:longer_than, 93}}`. So is one longer
    than 69 bytes in a tree that runs services (`agents` is not `false`), `{:bad, :home,
    {:longer_than, 69}}` (F-207): a service's socket is named by a key of fixed length
    (`CodingAgentFramework.Services.socket_key/1`, F-205), so its name needs no room, but the
    socket is 34 bytes after the home, and in a longer home every service start would be
    refused `socket_path_too_long`. The room the home leaves for an agent's name is
    `name_room/1`'s: a delegate's or a main session's start refuses a longer name before any
    row, `{:bad, :name, {:longer_than, n}}` (a 42-byte home leaves an agent 53 bytes; F-169's
    new-2, F-172);
  - `instance`: this framework instance's name, the name the app finds it by
    (`CodingAgentFramework.subscribe/2`), and so unique in the app (a second start of a running
    name is refused): 1 to 100 bytes, no control character;
  - `workstation`: the workstation's host name, and `programs`, the absolute path of each
    program there (`CodingAgentFramework.Programs`);
  - `scope`: the workstation's launcher for what outlives the app (`CodingAgentFramework.Host`,
    F-274): `:none` by default, or `:systemd_user`, where each `dtach -n` holder and the tmux
    server start in a `systemd-run --user --scope` unit of their own, so a stop of the app's
    systemd unit ends neither. It needs `programs` to name `systemd_run`, the host's own
    `systemd-run`: `{:bad, :scope, {:no_program, :systemd_run}}` without it. A remote host
    names its own, in its `Host`;

        iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
        ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
        ...>   env: %{path: "/bin"}, user: "me", scope: :systemd_user)
        {:refused, {:bad, :scope, {:no_program, :systemd_run}}}

  - `hosts`: the other hosts, name to `%{programs: programs, dir: dir}` as `Jobs` and `Services`
    read them, each host reached by `Host.ssh/5` with the home's `ToolHome.ssh_options/1`;
    none by default;
  - `accounts`: the Claude accounts' names; required, as `ports` and `claude` are, unless
    `agents: false` (below);
  - `projects`: name to the project, as `CodingAgentFramework.Mains` takes it: its `origin`
    (the repository its stacks land on, which its checkout is cloned from), `trunk`, `setup`,
    `setup_timeout`, `env`, `branches`, `cap` and `dir` (its checkout's directory, by default
    the repository's name, F-156). Its `name`, `dir` and `repo`, the checkout
    `<home>/checkouts/<dir>`, are filled in, so `Sessions` and `Delegates` read it as
    `Mains.project/3` answers it; two projects naming one directory are refused, `{:bad,
    :projects, {:same_dir, dir, names}}`;
  - `mains`: the main sessions the app declares, name to project, through `Mains`: the tree
    holds each as a root (no parent), so it can start its first delegate. A project may have
    several. None by default;
  - `main_model`: the model a main session `Mains` starts runs (`--model`); `"opus"` by
    default. A move's resume takes the agent row's;
  - `permission_modes`: each role's `--permission-mode` (F-227), a map of `main`,
    `interactive` and `headless` to modes `ClaudeCLI.permission_modes/0` lists; a role left out
    keeps its default, `auto` for a main session and an interactive delegate, `manual` for a
    headless one, whose requests then reach the inbox;
  - `operator`: the name the operator acts under (`CodingAgentFramework.Operator`), a person or
    this app acting from outside the tree; `"operator"` by default. It is no agent's name, nor
    `framework`;
  - `ports`: `%{intake: port, mcp: port}` on 127.0.0.1;
  - `git`: `%{author: author, projects: %{project => override}}`, the author every agent
    commits as and signs with, and a project's own (`CodingAgentFramework.ToolHome.prepare/2`,
    F-155); no author by default, when git refuses an agent's commit;
  - `claude` and `env`: what every agent's launch shares (`CodingAgentFramework.ClaudeCLI`); at
    its start the app adds `env`'s `:tools`, where gh, git and ssh keep their state in the home
    (`ToolHome.env/2`), to every launch, every project's `env` and the workstation's jobs and
    services. `env` has a `path` (the `PATH` jobs and launches run with) for every tree, one
    that runs agents too (F-203): `{:bad, :env}` without it;
    `tool_timeout` and `margin`, Claude Code's MCP tool timeout and what `run_delegate` keeps
    under it;
  - `user`: the OS user's name, which every launch passes as `USER` (the app gives it; no part
    reads it from the environment). Required on macOS, where Claude Code finds the login's
    Keychain item, whose account is the OS user, by `USER` alone: `{:refused, {:bad, :user}}`
    when it is missing there. Optional elsewhere, and for a tree with `agents: false`. It is
    added to `env` as `:user`;
  - `interval`: ms between the reads of the readers that read on a timer.
  - `resources`: each resource the `Scheduler` leases, name to capacity; by default
    `%{"seat" => 4, "slot" => 2}`, an agent's seat and a heavy run's slot. Placeholders until
    they are measured on the workstation;
  - `lease`: the units a delegate's start asks for; `%{"seat" => 1}` by default;
  - `job_lease`: the units a job asks for, by the class its caller names (`heavy`, `builder`,
    `landing`); a heavy slot each by default. A landing also takes its project's landing lock,
    `land:<project>`, which the app declares with capacity one for each project, in the same
    gang lease;
  - `pressure`: how the `Scheduler` reads the host's pressure (`Scheduler.Pressure`), as its
    `pressure:` option; nil by default, which reads stall times where the host has them
    (`/proc/pressure`) and nothing elsewhere;
  - `tool_hooks`: the app's hook callbacks as data, `{module, opts}` (F-195): the module
    implements `CodingAgentFramework.ToolHooks`' callback for each hook it takes,
    `pre_tool_use/3`, `post_tool_use/3` and `stop/3`, each given the event, `opts` and the
    same live `part` lookup an extension's tool has. `opts` is data, as an extension's is. Every
    account's settings name the `PreToolUse` hook, since the framework's own callback
    (`Mover.pre_tool_use/2`, a move's drain) decides first and hands any other call to the
    app's; `post_tool_use` adds its hook when the module has it, and may replace what the
    model reads of a call's output (`{:replace, response}`, F-197); `stop` holds each turn's end
    for the app (the `Stop` hold, with its cap and pauses). None by default. A callback may
    correct a call rather than refuse it (`Intake`'s `{:allow, updated_input: map,
    additional_context: text}`). Whatever it answers, a background `Bash` command it lets run
    runs with its stdin at end of file (`Intake.Background`, always on). The old form, a map of
    functions, is refused, `{:refused, {:bad, :tool_hooks, {:not_tool_hooks, value}}}`, as a
    module with none of the callbacks is; options that hold a function, pid, port or reference
    `{:not_data, module}`, and options that hold a struct (this config among them: the hooks
    reach the instance by its name, as `CodingAgentFramework.agent_rows/1` takes it) `{:not_data,
    module, {:struct, struct}}`;

        Config.new(..., tool_hooks: {App.Hooks, proxy: "the board"})
        #=> {:ok, %Config{tool_hooks: {App.Hooks, [proxy: "the board"]}}}
        Config.new(..., tool_hooks: %{pre_tool_use: fn _ -> :pass end})
        #=> {:refused, {:bad, :tool_hooks, {:not_tool_hooks, %{pre_tool_use: #Function<…>}}}}

  - `usable`: which accounts the app lets a start or a resume use, as data, `{module, opts}`
    (F-207, `CodingAgentFramework.Usable`): the module's `usable?(account, opts, part)` answers `true`
    or `{false, reason}`, and the tree hands it to every part that picks an account (`Delegates`,
    `Mains` and the `Mover`) beside the framework's own check (prepared, logged in): an account
    is usable only if both say so. A refused account reads in the pick's refusal as
    `{:refused, {:app, reason}}`. `opts` is data, as `tool_hooks`' are. None by default: the
    framework's check alone. A function in its place is refused, `{:refused, {:bad, :usable,
    {:not_usable, value}}}`, as is a module without `usable?/3`; options that hold a function,
    pid, port or reference `{:not_data, module}`, and a struct `{:not_data, module, {:struct,
    struct}}`;

        Config.new(..., usable: {App.Accounts, flagged: ["side"]})
        #=> {:ok, %Config{usable: {App.Accounts, [flagged: ["side"]]}}}
        Config.new(..., usable: fn account -> account != "side" end)
        #=> {:refused, {:bad, :usable, {:not_usable, #Function<…>}}}

  - `heavy`: the app's heavy commands (F-171), each `%{match: regex_or_string, class: class}`
    as `CodingAgentFramework.Runs` takes them: an agent's `Bash` call whose command matches
    runs under the wrapper `<home>/bin/caf-run`, which takes a lease of that class (`heavy`,
    `builder` or `landing`, its units the `job_lease` of the class) before it runs. None by
    default;
  - `extensions`: the app's bundles as data, each `{module, opts}` (F-188): the tree calls the
    module's `bundle(opts, part)` (`CodingAgentFramework.Extension`'s callback) and serves the
    bundle, `%{name, scope, tools}`, on the agents' MCP endpoint beside the framework's tools.
    `part` answers a part's process by its key (`CodingAgentFramework.parts/1`'s), looked up
    when it is called, so a tool reaches the live part after a restart. `opts` is data: a
    function, pid, port or reference in it is refused. Checked here, the bundles made with a
    `part` that answers nil, with `MCP.extensions/3`, so a clash or a slow tool refuses the
    config, `{:refused, {:bad, :extensions, reason}}`. None by default;

        defmodule App.Board do
          @behaviour CodingAgentFramework.Extension

          @impl true
          def bundle(opts, part) do
            tool = %{name: "board_cards", description: "The board's cards.",
              schema: %{type: "object"},
              call: fn caller, _args -> App.cards(part.(:mailbox), opts[:board], caller) end}

            %{name: "board", scope: %{roles: [:main]}, tools: [tool]}
          end
        end

        Config.new(..., extensions: [{App.Board, board: "web"}])
        #=> {:ok, %Config{extensions: [{App.Board, [board: "web"]}]}}
        Config.new(..., extensions: [{App.Board, board: fn -> "web" end}])
        #=> {:refused, {:bad, :extensions, {:not_data, App.Board}}}

  - `dialogs`: how a startup dialog is answered (F-140, `Sessions`' `dialog:`), its kind
    (`:trust`, `:imports`) to the label of the option to press; a kind not named, or a label
    the dialog does not show, waits on a person (the `dialog` prompt). None by default: every
    dialog waits. A start's menu (`:start_menu`, F-203) has no default and is refused here.
    `dialog/3` is the answer the tree hands `Sessions`;

        iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
        ...>   programs: %{}, accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
        ...>   env: %{path: "/bin"}, user: "me", dialogs: %{trust: "Yes, I trust this folder"})
        iex> CodingAgentFramework.Config.dialog(c, :trust, ["No, exit", "Yes, I trust this folder"])
        {:answer, "Yes, I trust this folder"}
        iex> CodingAgentFramework.Config.dialog(c, :imports, ["Yes", "No"])
        :ask

  - `secret_file`: the absolute path of the file that keeps the hooks' secret, which every
    hook, the waiter hook (`Sessions`' `waiter:`, on `ports.intake`) and the heavy commands'
    wrapper post with (`Intake.secret/1`, made at the first start with no access for others).
    The secret itself is never in the config. `<home>/intake.secret` by default;

        iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
        ...>   programs: %{}, accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
        ...>   env: %{path: "/bin"}, user: "me")
        iex> c.secret_file
        "/srv/caf/intake.secret"

  - `restarts`: the tree's restart budget, `%{max_restarts: n, max_seconds: s}` as OTP's
    supervisor takes it: more than `n` restarts in `s` seconds end the tree, and the app's
    supervisor decides. `%{max_restarts: 3, max_seconds: 5}`, OTP's own, by default;

        iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
        ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
        ...>   env: %{path: "/bin"},
        ...>   user: "me", restarts: %{max_restarts: -1})
        {:refused, {:bad, :restarts}}

  - `parts`: each part's own options, as data, by the part's key in the tree (and `holder`,
    the process holder every part that holds a session shares): the bounds and deadlines the
    parts set by default, which the tree passes over its own wiring. Each is `parts/0`'s:
    `acts` `claims` (the old claims file `Acts` takes once, `<home>/claims.db` by default);
    `holder` `timeout`; `sampler` `interval` (the config's `interval` by default); `intake`
    `deadline`, `tool_deadline`, `waiter_deadline` and `stop_deadline` (each under its hook's
    timeout less the margin `Intake.Plug` waits past it), `beat` and `stop_cap`; `sessions`
    `look` and `poll`; `recoveries` `max_age`, `window` and `end_grace`; `scheduler`
    `queue_bound` and `max_wait` (a count, or a map with every class), and `age` (or nil);
    `logins` `max_age`; `mailbox` `take_bound`; `mains` `clone_timeout`; `delegates`
    `idle_bound` (none by default: an idle delegate is not told to its parent); `mover`
    `timeout`, `stop` and `resume_wait`; `limits` `margin`, `credits` and `bound`;
    `stuck_backgrounds` `quiet`; `hooks_silent` `bound` and `slack`; `interventions` `person` (the actor of a
    person's interventions, `"person"` by default), `settle` and `slack`; `registry`,
    `transcripts` and `stream` `timeout`; `stream` `wake`; `mcp` `cap`. Each is ms but for a count and a name. An option not named is the part's own
    default. A part or option it does not know, or a value out of shape, is refused naming
    both, `{:refused, {:bad, :parts, {part, option}}}`.

        iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
        ...>   programs: %{}, accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
        ...>   env: %{path: "/bin"}, user: "me", parts: %{delegates: %{idle_bound: 600_000}})
        iex> CodingAgentFramework.Config.options(c, :delegates, host: "ws")
        [host: "ws", idle_bound: 600_000]
        iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
        ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
        ...>   env: %{path: "/bin"},
        ...>   user: "me", parts: %{intake: %{tool_deadline: 9_000}})
        {:refused, {:bad, :parts, {:intake, :tool_deadline}}}

  - `remedies`: the healer's allow-list (F-182, `CodingAgentFramework.Watch`), symptom kind to
    `%{remedy: remedy | nil, cap: count}`: the one remedy the healer may take for that kind
    (nil for a symptom only shown), and how many of them in one `remedy_bound` (ms, an hour by
    default). By default `Watch.default_remedies/0`, the healer's two acts. The list narrows
    alone (a remedy whose verify failed is dropped) and widens only by the operator, each act a
    row, so a restart never reads this again over them;
  - `viewer`: the size every viewer opens at, `{columns, rows}`: the one the tree hands both
    `Sessions` (a viewer's first open) and `Recoveries` (a lost one reopened), so the two never
    draw at different sizes (F-188's new-2). `{200, 50}` by default;

        iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
        ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
        ...>   env: %{path: "/bin"},
        ...>   user: "me", viewer: {0, 50})
        {:refused, {:bad, :viewer}}

  - `press_see`: ms a press of a dialog's option, or a typed write, waits for the screen to
    show its keys, each read of it (F-242, from F-238's new-1): the `see:` the tree's `Inlet`
    starts with, and only that: `Sessions` asks the `Inlet` its press bound, and each caller of
    a press asks `Sessions` its own (`Inlet.press_bound/1`, `Sessions.press_call/2`, F-245).
    The program redraws on the host's loaded
    cores, and a press whose read back passes this is unknown, for a person to press again.
    10 000 by default: five times the 2 s that the real program passed at load 30 on 15 cores,
    and four times the longest whole press the stand-in took at load 50 (F-242's note). A read
    ends as soon as the screen shows the keys, so the bound costs only a press that fails;

        iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
        ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
        ...>   env: %{path: "/bin"},
        ...>   user: "me", press_see: 0)
        {:refused, {:bad, :press_see}}

  - `agents`: `false` for a tree that runs no agent (F-195): it starts only the parts a lease
    needs, `agentless/0`'s, the reaper, the instance's `Registry`, `Cues`, `Acts`, the
    `Scheduler`, the `Tracker`, `Copies` and `Jobs`, and none that runs or reads an agent: no
    tmux server, no account's settings, no hooks, no endpoints, and no tool home
    (`ToolHome.prepare/2` is not run, so its jobs run with `env`'s `path` alone). Its
    `Scheduler` asks only a job's owner, `Jobs`, about a lease. A home keeps this kind for its
    life (F-214): the first start records it, and `start_link/1` of the other kind on that home
    answers `{:refused, {:home_kind, recorded}}` (`CodingAgentFramework.home_kind/1` reads it).
    `true` by default. Such a config
    needs only what that tree reads (F-201): `home`, `instance`, `programs` and `env` with its
    `path`, which `Jobs` reads (`{:bad, :env}` without it). `accounts`, `ports`, `claude` and
    `user`, which only the agents' parts read, may be left out there, on macOS too. A key only
    an agent's part reads, `usable`, `tool_hooks`, `extensions` or `dialogs`, is refused there
    if it is given at all, empty or not, `{:bad, key}` (F-209): no part would read it, and an app
    that sets `usable` would believe a start is guarded;

        iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
        ...>   programs: %{}, env: %{path: "/bin"}, agents: false)
        iex> {c.accounts, c.ports, c.claude}
        {[], nil, nil}
        iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
        ...>   env: %{path: "/bin"}, agents: false, usable: {App.Accounts, []})
        {:refused, {:bad, :usable}}
        iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
        ...>   env: %{}, agents: false)
        {:refused, {:bad, :env}}

  - `restart_wait`: ms a start waits for an instance of its name that is still exiting
    (`CodingAgentFramework.start_link/1`), so a parent's restart of a tree just killed is not
    refused while the old one ends; 5,000 by default, and never `:infinity`;

        iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
        ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
        ...>   env: %{path: "/bin"},
        ...>   user: "me", restart_wait: :infinity)
        {:refused, {:bad, :restart_wait}}

  - `undeclared_cues`: what becomes of a cue whose topic no part declares it writes
    (`CodingAgentFramework.Cues.notify/3`): `:route` by default, handed on as any other, or
    `:raise`, which the framework's own tests set, so a part that writes such a topic fails
    them.

      iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
      ...>   programs: %{kill: "/bin/kill"}, accounts: ["work"], ports: %{intake: 4790, mcp: 4791},
      ...>   claude: "/bin/claude", env: %{home: "/srv/caf", path: "/bin"}, user: "me")
      iex> {c.workstation, c.hosts, c.projects}
      {"ws", %{}, %{}}
      iex> CodingAgentFramework.Config.new(home: "caf")
      {:refused, {:bad, :home}}
  """

  alias CodingAgentFramework.{
    ClaudeCLI,
    Host,
    Mains,
    MCP,
    Runs,
    Services,
    ToolHooks,
    Usable,
    Watch
  }

  alias CodingAgentFramework.Mains.Checkout
  alias CodingAgentFramework.Scheduler.Queue
  alias CodingAgentFramework.Sessions.Dialog

  @enforce_keys [:home, :instance, :programs, :env]
  # What only a tree that runs agents reads, so a config with `agents: false` may leave it out
  # (F-201).
  @agent_keys [:accounts, :ports, :claude]
  # What only an agent's part reads, so a config with `agents: false` that sets it is refused
  # (F-209): an app that sets `usable` there would believe a start is guarded.
  @agent_only [:usable, :tool_hooks, :extensions, :dialogs, :permission_modes]
  defstruct [
    :home,
    :instance,
    :programs,
    :env,
    accounts: [],
    ports: nil,
    claude: nil,
    user: nil,
    workstation: "ws",
    scope: :none,
    hosts: %{},
    projects: %{},
    mains: %{},
    git: %{author: nil, projects: %{}},
    main_model: "opus",
    permission_modes: %{},
    operator: "operator",
    tool_timeout: 3_600_000,
    margin: 60_000,
    interval: 2_000,
    resources: %{"seat" => 4, "slot" => 2},
    lease: %{"seat" => 1},
    job_lease: %{heavy: %{"slot" => 1}, builder: %{"slot" => 1}, landing: %{"slot" => 1}},
    pressure: nil,
    tool_hooks: nil,
    usable: nil,
    heavy: [],
    extensions: [],
    dialogs: %{},
    secret_file: nil,
    restarts: %{max_restarts: 3, max_seconds: 5},
    parts: %{},
    remedies: Watch.default_remedies(),
    remedy_bound: 3_600_000,
    viewer: {200, 50},
    press_see: 10_000,
    agents: true,
    restart_wait: 5_000,
    undeclared_cues: :route
  ]

  @type t :: %__MODULE__{}

  # The parts a lease needs (F-195): the reaper every command runs under, the instance's
  # `Registry` and `Cues`, `Acts` (where a part's crash is recorded), the `Tracker`, the
  # `Scheduler`, and `Copies` and `Jobs`, whose jobs take its leases.
  @agentless [:reaper, :names, :cues, :acts, :tracker, :scheduler, :copies, :jobs]

  # macOS cuts a unix socket path at 103 bytes (`Holder`). The tmux server's socket,
  # `<home>/tmux.sock`, is the one whose name is fixed, and tmux would fail on it only at its
  # first command: 103 - 10.
  @max_home 93
  # What a socket path holds beside the home and the name: `/d/<agent>.sock`.
  @socket 103
  @agent_around byte_size("/d/.sock")
  # A service's socket, `<home>/ws/services/<key>.sock` (F-205), 34 bytes after the home: the
  # key's length is `Services.socket_key/1`'s, taken from it so the two never drift.
  @services_around byte_size("/ws/services/.sock") + byte_size(Services.socket_key(""))

  @doc """
  A config from a keyword list or map, checked whole: answers `{:ok, config}`, or
  `{:refused, {:bad, key}}` for the first key out of shape (a key it does not know included),
  `{:refused, {:bad, :home, {:longer_than, 69}}}` (93 for a tree with `agents: false`),
  `{:refused, {:bad, :usable, reason}}` or `{:refused, {:bad, :extensions, reason}}` with the
  extensions' own refusal.

      iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
      ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude", user: "me",
      ...>   env: %{path: "/bin"},
      ...>   tool_hooks: {Enum, []})
      {:refused, {:bad, :tool_hooks, {:not_tool_hooks, {Enum, []}}}}
      iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
      ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude", user: "me",
      ...>   env: %{path: "/bin"},
      ...>   usable: {Enum, []})
      {:refused, {:bad, :usable, {:not_usable, {Enum, []}}}}
      iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
      ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude", user: "me",
      ...>   env: %{path: "/bin"},
      ...>   extensions: [%{name: "board"}])
      {:refused, {:bad, :extensions, {:not_an_extension, %{name: "board"}}}}
      iex> CodingAgentFramework.Config.new(home: "/" <> String.duplicate("a", 69))
      {:refused, {:bad, :home, {:longer_than, 69}}}
      iex> CodingAgentFramework.Config.new(home: "/" <> String.duplicate("a", 93), agents: false)
      {:refused, {:bad, :home, {:longer_than, 93}}}
  """
  @spec new(keyword | map) :: {:ok, t} | {:refused, {:bad, atom} | {:bad, atom, term}}
  def new(fields) do
    fields = Map.new(fields)
    agents? = Map.get(fields, :agents, true) != false
    required = if agents?, do: @enforce_keys ++ @agent_keys, else: @enforce_keys
    missing = Enum.find(required, &(not Map.has_key?(fields, &1)))
    unknown = Enum.find(Map.keys(fields), &(not Map.has_key?(__MODULE__.__struct__(), &1)))
    unread = if agents?, do: nil, else: Enum.find(@agent_only, &Map.has_key?(fields, &1))

    cond do
      not (is_binary(fields[:home]) and Path.type(fields[:home]) == :absolute) ->
        {:refused, {:bad, :home}}

      # The tree's own bound, the nearer of its sockets (F-207): a home that no service can start
      # in is refused here, not at each service's start.
      byte_size(fields.home) > max_home(agents?) ->
        {:refused, {:bad, :home, {:longer_than, max_home(agents?)}}}

      missing ->
        {:refused, {:bad, missing}}

      unknown ->
        {:refused, {:bad, unknown}}

      unread ->
        {:refused, {:bad, unread}}

      agents? and
          not match?(%{intake: i, mcp: m} when is_integer(i) and is_integer(m), fields.ports) ->
        {:refused, {:bad, :ports}}

      # Every tree runs jobs with the PATH of `env` (F-201), and one that runs agents reads it
      # in its supervisor's `init` too (F-203).
      not match?(%{path: path} when is_binary(path), fields.env) ->
        {:refused, {:bad, :env}}

      not instance?(fields.instance) ->
        {:refused, {:bad, :instance}}

      not operator?(fields) ->
        {:refused, {:bad, :operator}}

      (bad = bad_tool_hooks(Map.get(fields, :tool_hooks))) != nil ->
        {:refused, {:bad, :tool_hooks, bad}}

      (bad = bad_usable(Map.get(fields, :usable))) != nil ->
        {:refused, {:bad, :usable, bad}}

      not permission_modes?(Map.get(fields, :permission_modes, %{})) ->
        {:refused, {:bad, :permission_modes}}

      not is_boolean(Map.get(fields, :agents, true)) ->
        {:refused, {:bad, :agents}}

      not match?(n when is_integer(n) and n > 0, Map.get(fields, :restart_wait, 5_000)) ->
        {:refused, {:bad, :restart_wait}}

      not user?(fields, agents?) ->
        {:refused, {:bad, :user}}

      not match?({:ok, _}, Runs.heavy(Map.get(fields, :heavy, []))) ->
        {:refused, {:bad, :heavy}}

      Map.get(fields, :undeclared_cues, :route) not in [:route, :raise] ->
        {:refused, {:bad, :undeclared_cues}}

      Map.get(fields, :scope, :none) not in Host.scopes() ->
        {:refused, {:bad, :scope}}

      Map.get(fields, :scope) == :systemd_user and not is_map_key(fields.programs, :systemd_run) ->
        {:refused, {:bad, :scope, {:no_program, :systemd_run}}}

      Watch.check_remedies(Map.get(fields, :remedies, %{})) != :ok ->
        {:refused, {:bad, :remedies}}

      not match?(n when is_integer(n) and n > 0, Map.get(fields, :remedy_bound, 1)) ->
        {:refused, {:bad, :remedy_bound}}

      not match?(
        {c, r} when is_integer(c) and c > 0 and is_integer(r) and r > 0,
        Map.get(fields, :viewer, {200, 50})
      ) ->
        {:refused, {:bad, :viewer}}

      not match?(n when is_integer(n) and n > 0, Map.get(fields, :press_see, 1)) ->
        {:refused, {:bad, :press_see}}

      not dialogs?(Map.get(fields, :dialogs, %{})) ->
        {:refused, {:bad, :dialogs}}

      not secret_file?(Map.get(fields, :secret_file)) ->
        {:refused, {:bad, :secret_file}}

      not restarts?(Map.get(fields, :restarts, %{max_restarts: 3, max_seconds: 5})) ->
        {:refused, {:bad, :restarts}}

      not is_map(Map.get(fields, :parts, %{})) ->
        {:refused, {:bad, :parts}}

      (bad = bad_part(Map.get(fields, :parts, %{}))) != nil ->
        {:refused, {:bad, :parts, bad}}

      true ->
        c = struct!(__MODULE__, fields)
        c = if c.user && is_map(c.env), do: %{c | env: Map.put(c.env, :user, c.user)}, else: c
        c = %{c | secret_file: c.secret_file || path(c, "intake.secret")}

        with {:ok, _} <- extensions(c, fn _key -> nil end) do
          projects = Map.new(c.projects, fn {n, p} -> {n, Mains.project(c.home, n, p)} end)

          # Two projects in one checkout directory (F-156).
          case Checkout.same_dir(projects) do
            nil -> {:ok, %{c | projects: projects}}
            {dir, names} -> {:refused, {:bad, :projects, {:same_dir, dir, names}}}
          end
        end
    end
  end

  @doc """
  The bundles the config's `extensions` make, in order: each module's `bundle(opts, part)`,
  checked whole with `MCP.extensions/3`. `part` answers a part's process by its key, or nil.
  The tree hands it the live lookup when `MCP` starts; `new/1` checks with one that answers
  nil. Answers `{:ok, bundles}` or `{:refused, {:bad, :extensions, reason}}`: `{:not_an_extension,
  entry}` (not a `{module, opts}` whose module has `bundle/2`), `{:not_data, module}` (a
  function, pid, port or reference in its options), `{:raised, module, message}`, or the
  bundles' own refusal.
  """
  @spec extensions(t, (atom -> pid | nil)) :: {:ok, [map]} | {:refused, {:bad, :extensions, term}}
  def extensions(%__MODULE__{} = c, part) do
    with {:ok, bundles} <- bundles(c.extensions, part),
         {:ok, _tools} <- MCP.extensions(bundles, c.tool_timeout, c.margin) do
      {:ok, bundles}
    else
      {:refused, why} -> {:refused, {:bad, :extensions, why}}
    end
  end

  defp bundles(entries, part) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case bundle(entry, part) do
        {:ok, b} -> {:cont, {:ok, acc ++ [b]}}
        refused -> {:halt, refused}
      end
    end)
  end

  defp bundles(entries, _part), do: {:refused, {:not_an_extension, entries}}

  defp bundle({module, opts} = entry, part) when is_atom(module) do
    cond do
      not (Code.ensure_loaded?(module) and function_exported?(module, :bundle, 2)) ->
        {:refused, {:not_an_extension, entry}}

      (bad = not_data(opts)) != nil ->
        {:refused, bad_data(module, bad)}

      true ->
        try do
          {:ok, module.bundle(opts, part)}
        rescue
          e -> {:refused, {:raised, module, Exception.message(e)}}
        end
    end
  end

  defp bundle(entry, _part), do: {:refused, {:not_an_extension, entry}}

  # Plain data, what a config file could hold: the first value in `v` that is not, or nil. A
  # struct is not (a `Config` handed as an option, F-201), and is named by its module.
  defp not_data(v) when is_function(v) or is_pid(v) or is_port(v) or is_reference(v), do: v
  defp not_data(%s{}) when is_atom(s), do: {:struct, s}
  defp not_data([h | t]), do: not_data(h) || not_data(t)
  defp not_data(v) when is_tuple(v), do: not_data(Tuple.to_list(v))
  defp not_data(%{} = v), do: Enum.find_value(v, fn {k, x} -> not_data(k) || not_data(x) end)
  defp not_data(_v), do: nil

  defp bad_data(module, {:struct, s}), do: {:not_data, module, {:struct, s}}
  defp bad_data(module, _v), do: {:not_data, module}

  @doc """
  The answer the config's `dialogs` gives startup dialog `kind` showing `options`, as
  `Sessions`' `dialog:` callback answers: `{:answer, label}` for the label it names when the
  dialog shows it, else `:ask` (a person answers).
  """
  @spec dialog(t, Dialog.kind(), [String.t()]) :: {:answer, String.t()} | :ask
  def dialog(%__MODULE__{dialogs: dialogs}, kind, options) do
    label = Map.get(dialogs, kind)
    if label in options, do: {:answer, label}, else: :ask
  end

  defp dialogs?(d) do
    is_map(d) and
      Enum.all?(d, fn {kind, label} ->
        kind in Dialog.preset_kinds() and is_binary(label) and label != "" and
          not (label =~ ~r/[[:cntrl:]]/)
      end)
  end

  defp secret_file?(nil), do: true
  defp secret_file?(path), do: path?(path)

  defp path?(path), do: is_binary(path) and Path.type(path) == :absolute

  defp restarts?(%{max_restarts: n, max_seconds: s} = r) when map_size(r) == 2,
    do: is_integer(n) and n >= 0 and is_integer(s) and s > 0

  defp restarts?(_r), do: false

  # Each part's own options an app may set, by type: ms (a positive integer, `{:ms, below}`
  # under a bound), a count, a path, or one by class. `Intake`'s deadlines stay under each
  # hook's timeout (600 s and 10 s, `Intake.hooks/4`; `Intake.waiter_hook/5`'s 7,200 s) less
  # the margin `Intake.Plug` waits past them (5 s, 1.5 s, 5 s, 5 s).
  @parts %{
    acts: [claims: :path],
    holder: [timeout: :ms],
    sampler: [interval: :ms],
    intake: [
      deadline: {:ms, 595_000},
      tool_deadline: {:ms, 8_500},
      waiter_deadline: {:ms, 7_195_000},
      stop_deadline: {:ms, 595_000},
      beat: :ms,
      stop_cap: :count
    ],
    sessions: [look: :ms, poll: :ms],
    recoveries: [max_age: :ms, window: :ms, end_grace: :ms],
    scheduler: [queue_bound: :by_class, max_wait: :by_class, age: :ms_or_nil],
    logins: [max_age: :ms],
    mailbox: [take_bound: :ms],
    mains: [clone_timeout: :ms],
    delegates: [idle_bound: :ms],
    mover: [timeout: :ms, stop: :ms, resume_wait: :ms],
    limits: [margin: :ms, credits: :ms, bound: :count, move_after: :ms],
    stuck_backgrounds: [quiet: :ms],
    hooks_silent: [bound: :ms, slack: :ms],
    interventions: [person: :name, settle: :ms, slack: :ms],
    registry: [timeout: :ms],
    transcripts: [timeout: :ms],
    stream: [timeout: :ms, wake: :ms],
    mcp: [cap: :ms]
  }

  @doc """
  Each part's options the config's `parts` may set, by the part's key, each with its type.

      iex> CodingAgentFramework.Config.parts()[:holder]
      [timeout: :ms]
  """
  @spec parts() :: %{atom => keyword}
  def parts, do: @parts

  @doc """
  The options the tree starts part `key` with: its own wiring `opts`, and over it the
  config's `parts` for that key.

      iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
      ...>   programs: %{}, accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
      ...>   env: %{path: "/bin"}, user: "me", parts: %{sampler: %{interval: 500}})
      iex> CodingAgentFramework.Config.options(c, :sampler, db: "caf.db", interval: 2_000)
      [db: "caf.db", interval: 500]
  """
  @spec options(t, atom, keyword) :: keyword
  def options(%__MODULE__{parts: parts}, key, opts),
    do: Keyword.merge(opts, Map.to_list(Map.get(parts, key, %{})))

  # The first part or `{part, option}` out of shape, or nil.
  defp bad_part(parts) do
    Enum.find_value(parts, fn {part, opts} ->
      allowed = Map.get(@parts, part)

      cond do
        allowed == nil or not is_map(opts) ->
          part

        bad = Enum.find(opts, fn {k, v} -> not typed?(Keyword.get(allowed, k), v) end) ->
          {part, elem(bad, 0)}

        true ->
          nil
      end
    end)
  end

  defp typed?(:ms, v), do: is_integer(v) and v > 0
  defp typed?({:ms, below}, v), do: typed?(:ms, v) and v < below
  defp typed?(:count, v), do: is_integer(v) and v > 0
  defp typed?(:path, v), do: path?(v)
  defp typed?(:name, v), do: is_binary(v) and String.trim(v) != ""
  defp typed?(:ms_or_nil, v), do: v == nil or typed?(:ms, v)

  defp typed?(:by_class, %{} = v),
    do:
      Enum.sort(Map.keys(v)) == Enum.sort(Queue.classes()) and
        Enum.all?(v, &typed?(:ms, elem(&1, 1)))

  defp typed?(:by_class, v), do: typed?(:ms, v)
  defp typed?(nil, _v), do: false

  # Why `tool_hooks` is out of shape, or nil: a `{module, opts}` whose module has a hook's
  # callback and whose options are data, as an extension's are.
  defp bad_tool_hooks(nil), do: nil

  defp bad_tool_hooks({module, opts} = entry) when is_atom(module) do
    cond do
      ToolHooks.implemented(module) == [] -> {:not_tool_hooks, entry}
      (bad = not_data(opts)) != nil -> bad_data(module, bad)
      true -> nil
    end
  end

  defp bad_tool_hooks(other), do: {:not_tool_hooks, other}

  # Why `usable` is out of shape, or nil: a `{module, opts}` whose module has `usable?/3` and
  # whose options are data, as `tool_hooks`' are. A function in its place is no module.
  defp bad_usable(nil), do: nil

  defp bad_usable({module, opts} = entry) when is_atom(module) do
    cond do
      not Usable.implemented?(module) -> {:not_usable, entry}
      (bad = not_data(opts)) != nil -> bad_data(module, bad)
      true -> nil
    end
  end

  defp bad_usable(other), do: {:not_usable, other}

  # The longest home a tree's sockets fit in: a tree that runs agents runs `Services` too.
  defp max_home(true), do: min(@max_home, @socket - @services_around)
  defp max_home(false), do: @max_home

  @doc """
  The hooks the config's `tool_hooks` take, the ones the accounts' settings name beside the
  framework's `PreToolUse`.

      iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a",
      ...>   programs: %{}, accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude",
      ...>   env: %{path: "/bin"}, user: "me")
      iex> CodingAgentFramework.Config.hooks(c)
      []
  """
  @spec hooks(t) :: [:pre_tool_use | :post_tool_use | :stop | :session_start]
  def hooks(%__MODULE__{tool_hooks: nil}), do: []
  def hooks(%__MODULE__{tool_hooks: {module, _opts}}), do: ToolHooks.implemented(module)

  @doc """
  The parts a tree with `agents: false` starts, by their keys, in the tree's order: what a
  lease needs, and nothing that runs or reads an agent.

      iex> CodingAgentFramework.Config.agentless()
      [:reaper, :names, :cues, :acts, :tracker, :scheduler, :copies, :jobs]
  """
  @spec agentless() :: [atom]
  def agentless, do: @agentless

  # A name with no control character; on macOS a tree that runs agents must have it (see `user`
  # above).
  defp user?(fields, agents?) do
    case Map.get(fields, :user) do
      nil -> not agents? or :os.type() != {:unix, :darwin}
      name -> is_binary(name) and name != "" and not (name =~ ~r/[[:cntrl:]]/)
    end
  end

  defp instance?(name),
    do: is_binary(name) and byte_size(name) in 1..100 and not (name =~ ~r/[[:cntrl:]]/)

  # A map of roles to the modes the pinned Claude Code takes (F-227).
  defp permission_modes?(modes) when is_map(modes) do
    Enum.all?(modes, fn {role, mode} ->
      role in [:main, :interactive, :headless] and mode in ClaudeCLI.permission_modes()
    end)
  end

  defp permission_modes?(_), do: false

  defp operator?(fields) do
    op = Map.get(fields, :operator, "operator")
    is_binary(op) and op not in ["", "framework" | Map.keys(Map.get(fields, :mains, %{}))]
  end

  @doc """
  The room the home leaves for an agent's name, in bytes, so its socket,
  `<home>/d/<agent>.sock`, fits macOS's 103 (F-172). The tree hands it to the parts that start
  agents, `Delegates` and `Mains` (`name_room:`), which refuse a longer name before any row. A
  service's socket is named by a key of fixed length, not its name (F-205).

      iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/" <> String.duplicate("h", 41),
      ...>   instance: "a", programs: %{}, accounts: [], ports: %{intake: 1, mcp: 2},
      ...>   claude: "/bin/claude", env: %{path: "/bin"}, user: "me")
      iex> CodingAgentFramework.Config.name_room(c)
      %{agent: 53}
  """
  @spec name_room(t) :: %{agent: non_neg_integer}
  def name_room(%__MODULE__{home: home}),
    do: %{agent: max(@socket - byte_size(home) - @agent_around, 0)}

  @doc "A path under the home."
  @spec path(t, String.t()) :: String.t()
  def path(%__MODULE__{home: home}, rest), do: Path.join(home, rest)
end
