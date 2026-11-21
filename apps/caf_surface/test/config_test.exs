defmodule CodingAgentFramework.ConfigTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Config

  @fields [
    home: "/srv/caf",
    instance: "a",
    programs: %{},
    accounts: [],
    ports: %{intake: 1, mcp: 2},
    claude: "/bin/claude",
    env: %{home: "/srv/caf", path: "/bin", term: "dumb", lang: "C.UTF-8"}
  ]

  # F-173
  test "the user is passed on in the launch env, and on macOS it is required" do
    assert {:ok, %Config{user: "me", env: %{user: "me"}}} = Config.new([user: "me"] ++ @fields)

    for bad <- ["", "a\nb", :me],
        do: assert(Config.new([user: bad] ++ @fields) == {:refused, {:bad, :user}})

    case :os.type() do
      {:unix, :darwin} -> assert Config.new(@fields) == {:refused, {:bad, :user}}
      _ -> assert {:ok, %Config{user: nil}} = Config.new(@fields)
    end
  end

  # F-156: a checkout's directory is its repository's name, or the project's `dir:`, and two
  # projects never share one.
  test "each project's checkout has a directory of its own" do
    project = %{origin: "git@github.com:me/app_repo.git", trunk: "main"}
    fields = [user: "me"] ++ @fields

    assert {:ok, %Config{projects: %{"app" => %{dir: "app_repo", repo: repo}}}} =
             Config.new([projects: %{"app" => project}] ++ fields)

    assert repo == "/srv/caf/checkouts/app_repo"

    twice = %{"app" => project, "web" => Map.put(project, :dir, "app_repo")}

    assert Config.new([projects: twice] ++ fields) ==
             {:refused, {:bad, :projects, {:same_dir, "app_repo", ["app", "web"]}}}

    apart = %{"app" => project, "web" => Map.put(project, :dir, "web")}

    assert {:ok, %Config{projects: %{"web" => %{dir: "web"}}}} =
             Config.new([projects: apart] ++ fields)
  end

  # F-188: every setting the tree reads is a key, checked here, each refusal naming it.
  defmodule Board do
    @behaviour CodingAgentFramework.Extension

    @impl true
    def bundle(opts, part) do
      tool = %{
        name: "board_cards",
        description: "The board's cards.",
        schema: %{type: "object"},
        call: fn caller, _args ->
          {:ok, %{caller: caller, board: opts[:board], mcp: part.(:mcp)}}
        end
      }

      %{name: Keyword.get(opts, :name, "board"), tools: [tool]}
    end
  end

  defmodule Raising do
    @behaviour CodingAgentFramework.Extension

    @impl true
    def bundle(_opts, _part), do: raise("no board")
  end

  defp new(more), do: Config.new([user: "me"] ++ @fields ++ more)

  test "dialogs: a kind's label is pressed when the dialog shows it, else a person answers" do
    trust = "Yes, I trust this folder"
    assert {:ok, c} = new(dialogs: %{trust: trust})
    assert Config.dialog(c, :trust, ["No, exit", trust]) == {:answer, trust}
    assert Config.dialog(c, :trust, ["No, exit", "Yes"]) == :ask
    assert Config.dialog(c, :imports, ["Yes", "No"]) == :ask

    assert {:ok, %Config{dialogs: %{}} = c} = new([])
    assert Config.dialog(c, :trust, ["No, exit", trust]) == :ask

    for bad <- [[], %{permission: "Yes"}, %{trust: ""}, %{trust: "a\nb"}, %{trust: :yes}],
        do: assert(new(dialogs: bad) == {:refused, {:bad, :dialogs}})
  end

  test "secret_file: an absolute path, by default in the home" do
    assert {:ok, %Config{secret_file: "/run/caf/secret"}} = new(secret_file: "/run/caf/secret")
    assert {:ok, %Config{secret_file: "/srv/caf/intake.secret"}} = new([])

    for bad <- ["secret", "", :secret, ~c"/run/caf/secret"],
        do: assert(new(secret_file: bad) == {:refused, {:bad, :secret_file}})
  end

  # F-195: the tool hooks as data, a module and its options, as an extension is.
  defmodule Hooks do
    @behaviour CodingAgentFramework.ToolHooks

    @impl true
    def pre_tool_use(_event, opts, part), do: {:deny, "#{opts[:why]} #{inspect(part.(:mcp))}"}

    @impl true
    def stop(_event, _opts, _part), do: :pass
  end

  test "tool_hooks: a module's hooks with plain options; the old functions refused" do
    assert {:ok, %Config{tool_hooks: {Hooks, [why: "no"]}} = c} =
             new(tool_hooks: {Hooks, why: "no"})

    # The settings name the hooks the module has; each gets its options and the lookup.
    assert Config.hooks(c) == [:pre_tool_use, :stop]
    hooks = CodingAgentFramework.ToolHooks.callbacks(c.tool_hooks, fn :mcp -> :live end)
    assert Enum.sort(Map.keys(hooks)) == [:pre_tool_use, :stop]
    assert hooks.pre_tool_use.(%{tool_name: "Read"}) == {:deny, "no :live"}

    assert {:ok, %Config{tool_hooks: nil} = none} = new([])
    assert Config.hooks(none) == []

    old = %{pre_tool_use: fn _ -> :pass end}

    for {bad, why} <- [
          {old, {:not_tool_hooks, old}},
          {{Enum, []}, {:not_tool_hooks, {Enum, []}}},
          {{NoSuchModule, []}, {:not_tool_hooks, {NoSuchModule, []}}},
          {{Hooks, to: self()}, {:not_data, Hooks}},
          {Hooks, {:not_tool_hooks, Hooks}}
        ],
        do: assert(new(tool_hooks: bad) == {:refused, {:bad, :tool_hooks, why}})
  end

  test "agents and restart_wait: an agentless tree on request; a bounded wait" do
    assert {:ok, %Config{agents: true, restart_wait: 5_000}} = new([])

    assert {:ok, %Config{agents: false, restart_wait: 200}} =
             new(agents: false, restart_wait: 200)

    for bad <- [nil, "false", 0], do: assert(new(agents: bad) == {:refused, {:bad, :agents}})

    for bad <- [:infinity, 0, -1, 1.5, nil],
        do: assert(new(restart_wait: bad) == {:refused, {:bad, :restart_wait}})
  end

  test "viewer: one size for every viewer, {200, 50} by default" do
    assert {:ok, %Config{viewer: {120, 40}}} = new(viewer: {120, 40})
    assert {:ok, %Config{viewer: {200, 50}}} = new([])

    for bad <- [{0, 50}, {200, -1}, [200, 50], {200.0, 50}, nil],
        do: assert(new(viewer: bad) == {:refused, {:bad, :viewer}})
  end

  test "restarts: the tree's budget, OTP's by default" do
    assert {:ok, %Config{restarts: %{max_restarts: 0, max_seconds: 60}}} =
             new(restarts: %{max_restarts: 0, max_seconds: 60})

    assert {:ok, %Config{restarts: %{max_restarts: 3, max_seconds: 5}}} = new([])

    for bad <- [
          %{max_restarts: 3},
          %{max_restarts: -1, max_seconds: 5},
          %{max_restarts: 3, max_seconds: 0},
          %{max_restarts: 3, max_seconds: 5, period: 1},
          [max_restarts: 3, max_seconds: 5]
        ],
        do: assert(new(restarts: bad) == {:refused, {:bad, :restarts}})
  end

  test "extensions: a module and its options as data, made into its bundle" do
    assert {:ok, c} = new(extensions: [{Board, board: "web"}])
    assert c.extensions == [{Board, [board: "web"]}]
    assert {:ok, [%{name: "board", tools: [tool]}]} = Config.extensions(c, fn :mcp -> :live end)
    # The part is looked up when the tool is called.
    assert tool.call.("app-main", %{}) == {:ok, %{caller: "app-main", board: "web", mcp: :live}}

    assert {:ok, %Config{extensions: []}} = new([])

    refusals = [
      {[%{name: "board", tools: []}], {:not_an_extension, %{name: "board", tools: []}}},
      {[{Enum, []}], {:not_an_extension, {Enum, []}}},
      {[{Board, board: fn -> "web" end}], {:not_data, Board}},
      {[{Board, board: self()}], {:not_data, Board}},
      {[{Raising, []}], {:raised, Raising, "no board"}},
      {[{Board, name: "message"}], {:extension, "message", :clashes}},
      {[{Board, []}, {Board, []}], {:extensions, :names_twice}},
      {Board, {:not_an_extension, Board}}
    ]

    for {bad, why} <- refusals,
        do: assert(new(extensions: bad) == {:refused, {:bad, :extensions, why}})
  end

  # Each option of each part: a value of its type is passed over the tree's wiring, none
  # leaves the part's default, and one out of shape is refused naming the part and option.
  test "parts: each part's own options, accepted, defaulted and refused by name" do
    good = %{
      :ms => 1_000,
      :count => 2,
      :path => "/srv/caf/old.db",
      :name => "sam",
      :ms_or_nil => nil,
      :by_class => %{main: 1, landing: 2, builder: 3, heavy: 4}
    }

    bad = %{:ms => 0, :count => -1, :path => "old.db", :ms_or_nil => "1", :name => " "}
    bad = Map.put(bad, :by_class, %{main: 1})

    for {part, options} <- Config.parts(), {option, type} <- options do
      {kind, value} =
        case type do
          {:ms, below} -> {{:ms, below}, below - 1}
          kind -> {kind, good[kind]}
        end

      refused = if match?({:ms, _}, kind), do: elem(kind, 1), else: bad[kind]

      assert {:ok, c} = new(parts: %{part => %{option => value}})
      assert Config.options(c, part, wired: 1) == [{:wired, 1}, {option, value}]

      assert {:ok, c} = new([])
      assert Config.options(c, part, wired: 1) == [wired: 1]

      assert new(parts: %{part => %{option => refused}}) ==
               {:refused, {:bad, :parts, {part, option}}}
    end

    assert new(parts: %{tmux: %{}}) == {:refused, {:bad, :parts, :tmux}}
    assert new(parts: %{intake: [beat: 1]}) == {:refused, {:bad, :parts, :intake}}
    assert new(parts: %{intake: %{db: "/x"}}) == {:refused, {:bad, :parts, {:intake, :db}}}
    assert new(parts: []) == {:refused, {:bad, :parts}}
  end
end
