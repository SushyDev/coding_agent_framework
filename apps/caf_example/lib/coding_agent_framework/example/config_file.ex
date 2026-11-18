defmodule CodingAgentFramework.Example.ConfigFile do
  @moduledoc """
  The file the example app starts from (`bin/caf-example <config>`): one JSON object, read and
  checked whole before anything starts, into a `CodingAgentFramework.Example.Config`. A key it
  does not know is refused, so a misspelled key never falls back to a default.

      {
        "home": "/Users/me/caf-e2e",
        "instance": "e2e",
        "accounts": ["one", "two"],
        "ports": {"intake": 4790, "mcp": 4791},
        "projects": {
          "demo": {
            "origin": "/Users/me/caf-e2e-origin/demo.git",
            "trunk": "main",
            "mains": ["demo-main"],
            "branches": "^unit/",
            "cap": 2
          }
        },
        "scheduler": {"resources": {"seat": 4, "slot": 2}},
        "git": {"name": "Demo Bot", "email": "1234+me@users.noreply.github.com"}
      }

  - `home` (required): the framework home, an absolute path. Each account's Claude config
    directory is `<home>/accounts/<account>/claude`; `bin/caf-login` logs one in.
  - `accounts` (required): the accounts' names, at least one, each `[a-z0-9][a-z0-9_-]*`.
  - `ports` (required): `intake` and `mcp`, two different ports on 127.0.0.1.
  - `projects`: name to project. A project names its `origin` (the repository its checkout is
    cloned from, never the person's own clone), its `trunk`, the `branches` a delegate's branch
    must match (a regular expression) and `cap` (how many of one parent's delegates at once),
    and optionally `mains` (the main session names it declares), `setup` (argvs, each program
    an absolute path; none by default), `setup_timeout` (ms, 600 000 by default), `env` (the
    environment git and the setup run in, built from nothing, beside the home's tool state; by
    default `HOME` from the environment and `PATH` devenv's programs' directories, then
    `/usr/bin:/bin`) and `git`, an override of the home's `git` author: any of `name`, `email`
    and `signing_key`.
  - `git`: the author every agent commits as (F-155), `name` and `email`, distinct from the
    person, who pushes with their own GitHub login (`bin/caf-login --gh`); and `signing_key`,
    the file name of the key in `<home>/git/` its commits are signed with (`signing_key` by
    default, which `bin/caf-login --git` makes). GitHub shows a commit Verified when that key
    is a signing key of the account and `email` one of its verified emails. Without it, git
    refuses an agent's commit.
  - `scheduler`: `resources` (name to capacity, `seat` 4 and `slot` 2 by default), `lease` (a
    delegate's start, `{"seat": 1}`), `job_lease` (by class `heavy`, `builder`, `landing`, a
    slot each). A landing's lock `land:<project>` is the app's, so no resource may take that name.
  - `launch`: what every agent's launch shares: `claude` (by default devenv's, `CAF_CLAUDE`),
    `model` (a main session's, `opus`), and its environment, `home` (`HOME`), `path` (devenv's
    programs' directories, then `/usr/bin:/bin:/usr/sbin:/sbin`, so a session's tools are
    devenv's and Claude Code still finds macOS's `security` for its Keychain),
    `term` (`xterm-256color`) and `lang` (`en_US.UTF-8`).
  - `instance` (`example`), `operator` (`operator`) and `interval` (ms, 2 000).

  Every other program is devenv's, from its `CAF_<NAME>` variable in `env`, the environment the
  caller hands in (`System.get_env/0`).

  Every refusal names the key: `{:refused, {key, why}}`, `key` a dotted path such as
  `"projects.demo.cap"`; or `{:refused, {:file, reason}}`, `{:refused, {:json, detail}}`, and
  `{:refused, {:programs, {:unset, variables}}}`.

      iex> alias CodingAgentFramework.Example.ConfigFile
      iex> env = %{"HOME" => "/home/me", "CAF_CLAUDE" => "/bin/claude"}
      iex> ConfigFile.parse(~s({"home": "caf"}), env)
      {:refused, {"home", :not_absolute}}
      iex> ConfigFile.parse(~s({"home": "/caf", "accounts": ["one"], "port": {}}), env)
      {:refused, {"port", :unknown_key}}
      iex> ConfigFile.parse(~s({"home": "/caf", "accounts": [], "ports": {}}), env)
      {:refused, {"accounts", :empty}}
      iex> ConfigFile.parse(~s({"home": "/caf", "accounts": ["one"], "ports": {"intake": 1, "mcp": 1}}), env)
      {:refused, {"ports", :same}}
      iex> ConfigFile.parse("{", env)
      {:refused, {:json, {:unexpected_end, 1}}}
  """

  alias CodingAgentFramework.Example.Config
  alias CodingAgentFramework.{Programs, ToolHome}

  @top ~w(home instance accounts ports projects scheduler launch operator interval git)
  @project ~w(origin trunk mains branches cap setup setup_timeout env git)
  @git ~w(name email signing_key)
  @launch ~w(claude model home path term lang)
  @scheduler ~w(resources lease job_lease)
  @classes %{"heavy" => :heavy, "builder" => :builder, "landing" => :landing}
  @short ~r/\A[a-z0-9][a-z0-9_-]{0,31}\z/
  @agent ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @type refusal :: {:refused, term}

  @doc "Reads the file at `path`, then `parse/2`."
  @spec read(String.t(), %{String.t() => String.t()}) :: {:ok, Config.t()} | refusal
  def read(path, env) do
    case File.read(path) do
      {:ok, text} -> parse(text, env)
      {:error, reason} -> {:refused, {:file, {path, reason}}}
    end
  end

  @doc "Checks the JSON text `text` and answers the config it names, or the first refusal."
  @spec parse(String.t(), %{String.t() => String.t()}) :: {:ok, Config.t()} | refusal
  def parse(text, env) do
    case JSON.decode(text) do
      {:ok, %{} = data} -> from_map(data, env)
      {:ok, _} -> {:refused, {:json, :not_an_object}}
      {:error, detail} -> {:refused, {:json, detail}}
    end
  end

  defp from_map(data, env) do
    with :ok <- known(data, @top, ""),
         {:ok, home} <- absolute(data, "home", nil),
         {:ok, accounts} <- accounts(data["accounts"]),
         {:ok, ports} <- ports(data["ports"]),
         {:ok, launch} <- launch(Map.get(data, "launch", %{}), env),
         {:ok, scheduler} <- scheduler(Map.get(data, "scheduler", %{})),
         {:ok, instance} <- name(data, "instance", "example", @short),
         {:ok, operator} <- name(data, "operator", "operator", @agent),
         {:ok, interval} <- positive(data, "interval", 2_000),
         {:ok, projects} <- projects(Map.get(data, "projects", %{}), env, home),
         {:ok, mains} <- mains(projects, operator),
         :ok <- reserved(scheduler.resources),
         {:ok, author} <- git(Map.get(data, "git"), home, "git", true),
         {:ok, programs} <- programs(env) do
      git = %{author: author, projects: for({n, %{git: g}} <- projects, g, into: %{}, do: {n, g})}
      projects = Map.new(projects, fn {n, p} -> {n, Map.drop(p, [:mains, :git])} end)

      Config.new(
        home: home,
        instance: instance,
        programs: programs,
        accounts: accounts,
        ports: ports,
        claude: launch.claude,
        env: Map.put(Map.take(launch, [:home, :path, :term, :lang]), :ca, ca_bundle(env)),
        main_model: launch.model,
        projects: projects,
        mains: mains,
        git: git,
        operator: operator,
        interval: interval,
        resources: scheduler.resources,
        lease: scheduler.lease,
        job_lease: scheduler.job_lease
      )
    end
  end

  defp known(map, keys, at) when is_map(map) do
    case Enum.sort(Map.keys(map) -- keys) do
      [] -> :ok
      [key | _] -> {:refused, {at <> key, :unknown_key}}
    end
  end

  defp known(_, _, at), do: {:refused, {String.trim_trailing(at, "."), :not_an_object}}

  defp accounts(nil), do: {:refused, {"accounts", :missing}}
  defp accounts([]), do: {:refused, {"accounts", :empty}}

  defp accounts(names) when is_list(names) do
    cond do
      (bad = Enum.find(names, &(not (is_binary(&1) and &1 =~ @short)))) != nil ->
        {:refused, {"accounts", {:not_a_name, bad}}}

      Enum.uniq(names) != names ->
        {:refused, {"accounts", {:twice, names -- Enum.uniq(names)}}}

      true ->
        {:ok, names}
    end
  end

  defp accounts(_), do: {:refused, {"accounts", :not_a_list}}

  defp ports(nil), do: {:refused, {"ports", :missing}}

  defp ports(ports) do
    with :ok <- known(ports, ~w(intake mcp), "ports."),
         {:ok, intake} <- port(ports, "intake"),
         {:ok, mcp} <- port(ports, "mcp") do
      if intake == mcp,
        do: {:refused, {"ports", :same}},
        else: {:ok, %{intake: intake, mcp: mcp}}
    end
  end

  defp port(ports, key) do
    case ports[key] do
      nil -> {:refused, {"ports." <> key, :missing}}
      p when is_integer(p) and p in 1..65_535 -> {:ok, p}
      _ -> {:refused, {"ports." <> key, :not_a_port}}
    end
  end

  defp launch(launch, env) do
    defaults = %{
      "claude" => env["CAF_CLAUDE"],
      "model" => "opus",
      "home" => env["HOME"],
      "path" => devenv_path(env, ~w(/usr/bin /bin /usr/sbin /sbin)),
      "term" => "xterm-256color",
      "lang" => "en_US.UTF-8"
    }

    with :ok <- known(launch, @launch, "launch."),
         launch = Map.merge(defaults, launch),
         {:ok, claude} <- absolute(launch, "claude", "launch."),
         {:ok, home} <- absolute(launch, "home", "launch.") do
      case Enum.find(~w(model path term lang), &(not text?(launch[&1]))) do
        nil ->
          {:ok,
           %{
             claude: claude,
             model: launch["model"],
             home: home,
             path: launch["path"],
             term: launch["term"],
             lang: launch["lang"]
           }}

        key ->
          {:refused, {"launch." <> key, :not_a_string}}
      end
    end
  end

  defp scheduler(s) do
    default = %{"seat" => 4, "slot" => 2}
    jobs = %{"heavy" => %{"slot" => 1}, "builder" => %{"slot" => 1}, "landing" => %{"slot" => 1}}

    with :ok <- known(s, @scheduler, "scheduler."),
         {:ok, resources} <- units(Map.get(s, "resources", default), "scheduler.resources"),
         {:ok, lease} <- units(Map.get(s, "lease", %{"seat" => 1}), "scheduler.lease"),
         :ok <- within(lease, resources, "scheduler.lease"),
         {:ok, job_lease} <- job_lease(Map.get(s, "job_lease", jobs), resources) do
      {:ok, %{resources: resources, lease: lease, job_lease: job_lease}}
    end
  end

  defp job_lease(classes, resources) do
    with :ok <- known(classes, Map.keys(@classes), "scheduler.job_lease.") do
      Enum.reduce_while(@classes, {:ok, %{}}, fn {key, class}, {:ok, acc} ->
        at = "scheduler.job_lease." <> key

        with {:ok, units} <- units(Map.get(classes, key, %{"slot" => 1}), at),
             :ok <- within(units, resources, at) do
          {:cont, {:ok, Map.put(acc, class, units)}}
        else
          refused -> {:halt, refused}
        end
      end)
    end
  end

  defp units(units, at) when is_map(units) do
    case Enum.find(units, fn {_, n} -> not (is_integer(n) and n > 0) end) do
      nil -> {:ok, units}
      {name, _} -> {:refused, {at <> "." <> name, :not_positive}}
    end
  end

  defp units(_, at), do: {:refused, {at, :not_an_object}}

  defp within(units, resources, at) do
    case Map.keys(units) -- Map.keys(resources) do
      [] -> :ok
      [name | _] -> {:refused, {at <> "." <> name, :no_such_resource}}
    end
  end

  defp reserved(resources) do
    case Enum.find(Map.keys(resources), &String.starts_with?(&1, "land:")) do
      nil -> :ok
      name -> {:refused, {"scheduler.resources." <> name, :reserved}}
    end
  end

  defp projects(projects, env, home) when is_map(projects) do
    Enum.reduce_while(Enum.sort(projects), {:ok, %{}}, fn {name, p}, {:ok, acc} ->
      case project(name, p, env, home) do
        {:ok, p} -> {:cont, {:ok, Map.put(acc, name, p)}}
        refused -> {:halt, refused}
      end
    end)
  end

  defp projects(_, _env, _home), do: {:refused, {"projects", :not_an_object}}

  defp project(name, p, env, home) do
    at = "projects.#{name}."
    default_env = %{"HOME" => env["HOME"], "PATH" => devenv_path(env, ~w(/usr/bin /bin))}

    with true <- name =~ @short or {:refused, {"projects." <> name, :not_a_name}},
         :ok <- known(p, @project, at),
         {:ok, origin} <- text(p, "origin", at),
         {:ok, trunk} <- text(p, "trunk", at),
         {:ok, branches} <- branches(p["branches"], at),
         {:ok, cap} <- positive(p, "cap", nil, at),
         {:ok, setup} <- setup(Map.get(p, "setup", []), at),
         {:ok, timeout} <- positive(p, "setup_timeout", 600_000, at),
         {:ok, project_env} <- project_env(Map.get(p, "env", default_env), at),
         {:ok, git} <- git(p["git"], home, at <> "git", false),
         {:ok, mains} <- names(Map.get(p, "mains", []), at <> "mains") do
      {:ok,
       %{
         origin: origin,
         trunk: trunk,
         branches: branches,
         cap: cap,
         setup: setup,
         setup_timeout: timeout,
         env: project_env,
         mains: mains,
         git: git
       }}
    end
  end

  defp branches(nil, at), do: {:refused, {at <> "branches", :missing}}

  defp branches(pattern, at) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> {:refused, {at <> "branches", :not_a_pattern}}
    end
  end

  defp branches(_, at), do: {:refused, {at <> "branches", :not_a_string}}

  defp setup(argvs, at) when is_list(argvs) do
    ok? = fn
      [program | args] -> absolute?(program) and Enum.all?(args, &is_binary/1)
      _ -> false
    end

    case Enum.find_index(argvs, &(not ok?.(&1))) do
      nil -> {:ok, argvs}
      i -> {:refused, {at <> "setup.#{i}", :not_an_argv}}
    end
  end

  defp setup(_, at), do: {:refused, {at <> "setup", :not_a_list}}

  defp project_env(env, at) when is_map(env) do
    case Enum.find(env, fn {_, v} -> not is_binary(v) end) do
      nil -> {:ok, env}
      {k, _} -> {:refused, {at <> "env." <> k, :not_a_string}}
    end
  end

  defp project_env(_, at), do: {:refused, {at <> "env", :not_an_object}}

  defp names(names, at) when is_list(names) do
    case Enum.find(names, &(not (is_binary(&1) and &1 =~ @agent))) do
      nil -> {:ok, names}
      bad -> {:refused, {at, {:not_a_name, bad}}}
    end
  end

  defp names(_, at), do: {:refused, {at, :not_a_list}}

  # Each main session name once across every project, and never a reserved name.
  defp mains(projects, operator) do
    all =
      for {project, %{mains: names}} <- Enum.sort(projects), name <- names, do: {name, project}

    names = Enum.map(all, &elem(&1, 0))

    cond do
      (taken = Enum.find(names, &(&1 in ["framework", operator]))) != nil ->
        {:refused, {"projects.#{project_of(all, taken)}.mains", {:reserved, taken}}}

      (twice = names -- Enum.uniq(names)) != [] ->
        {:refused, {"projects.#{project_of(all, hd(twice))}.mains", {:twice, hd(twice)}}}

      true ->
        {:ok, Map.new(all)}
    end
  end

  # The project that names `name` last, where the refusal points.
  defp project_of(all, name), do: all |> Enum.reverse() |> List.keyfind(name, 0) |> elem(1)

  # The author agents commit as (F-155): the home's, whole, or a project's override of any of
  # its fields. A signing key is a file name in `<home>/git/`, `signing_key` for the home's.
  defp git(nil, _home, _at, _whole), do: {:ok, nil}

  defp git(git, home, at, whole) do
    defaults = if whole, do: %{"signing_key" => "signing_key"}, else: %{}

    with :ok <- known(git, @git, at <> "."),
         git = Map.merge(defaults, git),
         true <-
           (whole and Map.has_key?(git, "name")) or not whole or
             {:refused, {at <> ".name", :missing}},
         true <-
           (whole and Map.has_key?(git, "email")) or not whole or
             {:refused, {at <> ".email", :missing}} do
      Enum.reduce_while(git, {:ok, %{}}, fn {key, v}, {:ok, acc} ->
        case {key, v} do
          {"signing_key", v} when is_binary(v) ->
            if v =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/,
              do: {:cont, {:ok, Map.put(acc, :signing_key, ToolHome.signing_key(home, v))}},
              else: {:halt, {:refused, {at <> ".signing_key", :not_a_file_name}}}

          {"email", v} when is_binary(v) ->
            if v =~ ~r/\A[^\s<>@]+@[^\s<>@]+\z/,
              do: {:cont, {:ok, Map.put(acc, :email, v)}},
              else: {:halt, {:refused, {at <> ".email", :not_an_email}}}

          {"name", v} ->
            if text?(v),
              do: {:cont, {:ok, Map.put(acc, :name, v)}},
              else: {:halt, {:refused, {at <> ".name", :not_a_string}}}

          {key, _} ->
            {:halt, {:refused, {at <> "." <> key, :not_a_string}}}
        end
      end)
    end
  end

  # The directories of devenv's programs, first on a launch's and a project's `PATH`, so a
  # session's Bash tool, git and the setup run devenv's programs, never the system's (F-155).
  # The system's own directories come last: macOS's `security`, which Claude Code reads its
  # login with, is in none of devenv's.
  defp devenv_path(env, system) do
    Programs.names()
    |> Enum.map(&env["CAF_" <> String.upcase(to_string(&1))])
    |> Enum.filter(&absolute?/1)
    |> Enum.map(&Path.dirname/1)
    |> Kernel.++(system)
    |> Enum.uniq()
    |> Enum.join(":")
  end

  # The CA bundle every launch passes on (F-151): what devenv sets in the app's own environment,
  # since Claude Code's Node finds devenv's certificates in none of its own places.
  @ca_names ~w(NODE_EXTRA_CA_CERTS NIX_SSL_CERT_FILE SSL_CERT_FILE)
  defp ca_bundle(env),
    do: for(name <- @ca_names, absolute?(env[name]), into: %{}, do: {name, env[name]})

  defp programs(env) do
    vars = for name <- Programs.names(), do: {name, "CAF_" <> String.upcase(to_string(name))}

    case for({_, var} <- vars, not absolute?(env[var]), do: var) do
      [] -> {:ok, Map.new(vars, fn {name, var} -> {name, env[var]} end)}
      unset -> {:refused, {:programs, {:unset, unset}}}
    end
  end

  defp absolute(map, key, at) do
    at = to_string(at) <> key

    case map[key] do
      nil -> {:refused, {at, :missing}}
      v when is_binary(v) -> if absolute?(v), do: {:ok, v}, else: {:refused, {at, :not_absolute}}
      _ -> {:refused, {at, :not_a_string}}
    end
  end

  defp text(map, key, at) do
    case map[key] do
      nil -> {:refused, {at <> key, :missing}}
      v -> if text?(v), do: {:ok, v}, else: {:refused, {at <> key, :not_a_string}}
    end
  end

  defp name(map, key, default, pattern) do
    case Map.get(map, key, default) do
      v when is_binary(v) -> if v =~ pattern, do: {:ok, v}, else: {:refused, {key, :not_a_name}}
      _ -> {:refused, {key, :not_a_name}}
    end
  end

  defp positive(map, key, default, at \\ "") do
    case Map.get(map, key, default) do
      nil -> {:refused, {at <> key, :missing}}
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:refused, {at <> key, :not_positive}}
    end
  end

  defp text?(v), do: is_binary(v) and v != ""
  defp absolute?(v), do: is_binary(v) and Path.type(v) == :absolute
end
