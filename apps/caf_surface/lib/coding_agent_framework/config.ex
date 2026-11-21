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
    `ws/services/<service>.sock`) must fit macOS's 103 bytes: a home longer than 93 bytes,
    where `tmux.sock` does not fit, is refused, `{:bad, :home, {:longer_than, 93}}`. The room
    it leaves for a name is `name_room/1`'s: a delegate's or a main session's start, and a
    service's, refuse a longer name before any row, `{:bad, :name, {:longer_than, n}}` (a
    42-byte home leaves an agent 53 bytes, a service 43; F-169's new-2, F-172);
  - `instance`: this framework instance's name, the name the app finds it by
    (`CodingAgentFramework.subscribe/2`), and so unique in the app (a second start of a running
    name is refused): 1 to 100 bytes, no control character;
  - `workstation`: the workstation's host name, and `programs`, the absolute path of each
    program there (`CodingAgentFramework.Programs`);
  - `hosts`: the other hosts, name to `%{programs: programs, dir: dir}` as `Jobs` and `Services`
    read them, each host reached by `Host.ssh/5` with the home's `ToolHome.ssh_options/1`;
    none by default;
  - `accounts`: the Claude accounts' names;
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
    services;
    `tool_timeout` and `margin`, Claude Code's MCP tool timeout and what `run_delegate` keeps
    under it;
  - `user`: the OS user's name, which every launch passes as `USER` (the app gives it; no part
    reads it from the environment). Required on macOS, where Claude Code finds the login's
    Keychain item, whose account is the OS user, by `USER` alone: `{:refused, {:bad, :user}}`
    when it is missing there. Optional elsewhere. It is added to `env` as `:user`;
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
  - `tool_hooks`: the app's hook callbacks, `%{pre_tool_use: fun, post_tool_use: fun, stop:
    fun}`, each optional, as `CodingAgentFramework.Intake` takes them. Every account's settings
    name the `PreToolUse` hook, since the framework's own callback (`Mover.pre_tool_use/2`, a
    move's drain) decides first and hands any other call to the app's; `post_tool_use` adds its
    hook when given; `stop` holds each turn's end for the app (the `Stop` hold, with its cap
    and pauses). None by default. A callback may correct a call rather than refuse it
    (`Intake`'s `{:allow, updated_input: map, additional_context: text}`);
  - `heavy`: the app's heavy commands (F-171), each `%{match: regex_or_string, class: class}`
    as `CodingAgentFramework.Runs` takes them: an agent's `Bash` call whose command matches
    runs under the wrapper `<home>/bin/caf-run`, which takes a lease of that class (`heavy`,
    `builder` or `landing`, its units the `job_lease` of the class) before it runs. None by
    default;
  - `extensions`: the app's bundles, each `%{name, scope, tools}` as
    `CodingAgentFramework.Extension` takes them, served on the agents' MCP endpoint beside the
    framework's tools; checked here with `MCP.extensions/3`, so a clash or a slow tool refuses
    the config, `{:refused, {:bad, :extensions, reason}}`. None by default;
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

  alias CodingAgentFramework.{Mains, MCP, Runs}
  alias CodingAgentFramework.Mains.Checkout

  @enforce_keys [:home, :instance, :programs, :accounts, :ports, :claude, :env]
  defstruct [
    :home,
    :instance,
    :programs,
    :accounts,
    :ports,
    :claude,
    :env,
    user: nil,
    workstation: "ws",
    hosts: %{},
    projects: %{},
    mains: %{},
    git: %{author: nil, projects: %{}},
    main_model: "opus",
    operator: "operator",
    tool_timeout: 3_600_000,
    margin: 60_000,
    interval: 2_000,
    resources: %{"seat" => 4, "slot" => 2},
    lease: %{"seat" => 1},
    job_lease: %{heavy: %{"slot" => 1}, builder: %{"slot" => 1}, landing: %{"slot" => 1}},
    pressure: nil,
    tool_hooks: %{},
    heavy: [],
    extensions: [],
    undeclared_cues: :route
  ]

  @type t :: %__MODULE__{}

  # macOS cuts a unix socket path at 103 bytes (`Holder`). The tmux server's socket,
  # `<home>/tmux.sock`, is the one whose name is fixed, and tmux would fail on it only at its
  # first command: 103 - 10.
  @max_home 93
  # What a socket path holds beside the home and the name: `/d/<agent>.sock` and
  # `/ws/services/<service>.sock`.
  @socket 103
  @agent_around byte_size("/d/.sock")
  @service_around byte_size("/ws/services/.sock")

  @doc """
  A config from a keyword list or map, checked whole: answers `{:ok, config}`, or
  `{:refused, {:bad, key}}` for the first key out of shape (a key it does not know included),
  `{:refused, {:bad, :home, {:longer_than, 93}}}`, or `{:refused, {:bad, :extensions, reason}}`
  with the extensions' own refusal.

      iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
      ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude", env: %{}, user: "me",
      ...>   tool_hooks: %{pre_tool_use: fn _, _ -> :allow end})
      {:refused, {:bad, :tool_hooks}}
      iex> CodingAgentFramework.Config.new(home: "/srv/caf", instance: "a", programs: %{},
      ...>   accounts: [], ports: %{intake: 1, mcp: 2}, claude: "/bin/claude", env: %{}, user: "me",
      ...>   extensions: [%{name: "message"}])
      {:refused, {:bad, :extensions, {:extension, "message", :clashes}}}
      iex> CodingAgentFramework.Config.new(home: "/" <> String.duplicate("a", 93))
      {:refused, {:bad, :home, {:longer_than, 93}}}
  """
  @spec new(keyword | map) :: {:ok, t} | {:refused, {:bad, atom} | {:bad, atom, term}}
  def new(fields) do
    fields = Map.new(fields)
    missing = Enum.find(@enforce_keys, &(not Map.has_key?(fields, &1)))
    unknown = Enum.find(Map.keys(fields), &(not Map.has_key?(__MODULE__.__struct__(), &1)))

    cond do
      not (is_binary(fields[:home]) and Path.type(fields[:home]) == :absolute) ->
        {:refused, {:bad, :home}}

      byte_size(fields.home) > @max_home ->
        {:refused, {:bad, :home, {:longer_than, @max_home}}}

      missing ->
        {:refused, {:bad, missing}}

      unknown ->
        {:refused, {:bad, unknown}}

      not match?(%{intake: i, mcp: m} when is_integer(i) and is_integer(m), fields.ports) ->
        {:refused, {:bad, :ports}}

      not instance?(fields.instance) ->
        {:refused, {:bad, :instance}}

      not operator?(fields) ->
        {:refused, {:bad, :operator}}

      not tool_hooks?(Map.get(fields, :tool_hooks, %{})) ->
        {:refused, {:bad, :tool_hooks}}

      not user?(fields) ->
        {:refused, {:bad, :user}}

      not match?({:ok, _}, Runs.heavy(Map.get(fields, :heavy, []))) ->
        {:refused, {:bad, :heavy}}

      Map.get(fields, :undeclared_cues, :route) not in [:route, :raise] ->
        {:refused, {:bad, :undeclared_cues}}

      true ->
        c = struct!(__MODULE__, fields)
        c = if c.user && is_map(c.env), do: %{c | env: Map.put(c.env, :user, c.user)}, else: c

        with {:ok, _} <- extensions(c) do
          projects = Map.new(c.projects, fn {n, p} -> {n, Mains.project(c.home, n, p)} end)

          # Two projects in one checkout directory (F-156).
          case Checkout.same_dir(projects) do
            nil -> {:ok, %{c | projects: projects}}
            {dir, names} -> {:refused, {:bad, :projects, {:same_dir, dir, names}}}
          end
        end
    end
  end

  defp extensions(c) do
    with {:refused, why} <- MCP.extensions(c.extensions, c.tool_timeout, c.margin),
         do: {:refused, {:bad, :extensions, why}}
  end

  defp tool_hooks?(hooks) do
    is_map(hooks) and
      Enum.all?(hooks, fn {k, f} ->
        k in [:pre_tool_use, :post_tool_use, :stop] and is_function(f, 1)
      end)
  end

  # A name with no control character; on macOS it must be there (see `user` above).
  defp user?(fields) do
    case Map.get(fields, :user) do
      nil -> :os.type() != {:unix, :darwin}
      name -> is_binary(name) and name != "" and not (name =~ ~r/[[:cntrl:]]/)
    end
  end

  defp instance?(name),
    do: is_binary(name) and byte_size(name) in 1..100 and not (name =~ ~r/[[:cntrl:]]/)

  defp operator?(fields) do
    op = Map.get(fields, :operator, "operator")
    is_binary(op) and op not in ["", "framework" | Map.keys(Map.get(fields, :mains, %{}))]
  end

  @doc """
  The room the home leaves for a name, in bytes, so its socket fits macOS's 103 (F-172): an
  agent's, `<home>/d/<agent>.sock`, and a workstation service's,
  `<home>/ws/services/<service>.sock`. The tree hands each to the parts that start them,
  `Delegates`, `Mains` and `Services` (`name_room:`), which refuse a longer name before any row.

      iex> {:ok, c} = CodingAgentFramework.Config.new(home: "/" <> String.duplicate("h", 41),
      ...>   instance: "a", programs: %{}, accounts: [], ports: %{intake: 1, mcp: 2},
      ...>   claude: "/bin/claude", env: %{}, user: "me")
      iex> CodingAgentFramework.Config.name_room(c)
      %{agent: 53, service: 43}
  """
  @spec name_room(t) :: %{agent: non_neg_integer, service: non_neg_integer}
  def name_room(%__MODULE__{home: home}) do
    left = @socket - byte_size(home)
    %{agent: max(left - @agent_around, 0), service: max(left - @service_around, 0)}
  end

  @doc "A path under the home."
  @spec path(t, String.t()) :: String.t()
  def path(%__MODULE__{home: home}, rest), do: Path.join(home, rest)
end
