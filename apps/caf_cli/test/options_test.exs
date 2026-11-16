defmodule CodingAgentFramework.ClaudeCLI.OptionsTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.{ClaudeCLI, ClaudeCLI.Options, Accounts.Account}

  doctest Options

  @own "/caf/own.settings.json"
  @options %{
    settings: %{"permissions" => %{"deny" => ["Bash(git push *)"]}},
    env: %{"APP_MODE" => "review", "APP_NOTE" => "two\nlines"},
    add_dirs: ["/srv/docs"],
    append_system_prompt: "- Be brief.",
    allowed_tools: ["Read", "Bash(git log *)"],
    disallowed_tools: ["WebFetch"]
  }

  defp launch(role, more) do
    env = %{home: "/h", path: "/bin", term: "dumb", lang: "C.UTF-8"}

    opts =
      more ++ [claude: "/c", model: "o", name: "u", tool_timeout: 1000, prompt: "p", env: env]

    account = Account.at("work", "/caf/work")

    if role == :headless,
      do: ClaudeCLI.headless(account, [session_id: "s"] ++ opts),
      else: ClaudeCLI.session(role, account, opts)
  end

  test "each option is its flag after the agent's own settings file, and its env is added" do
    own =
      ["--settings", @own, "--add-dir", "/srv/docs", "--allowedTools", "Read", "Bash(git log *)"] ++
        ["--disallowedTools", "WebFetch", "--append-system-prompt=- Be brief.", "--mcp-config"]

    for role <- [:parent, :delegate, :headless] do
      assert {:ok, %{argv: argv, env: env}} = launch(role, options: @options, settings: @own)
      assert Enum.chunk_every(argv, length(own), 1) |> Enum.member?(own)

      assert [{"APP_MODE", _}, {"APP_NOTE", "two\nlines"}, {"DISABLE_AUTOUPDATER", _}] =
               Enum.take(env, -3)
    end

    assert {:ok, %{argv: plain}} = launch(:headless, options: %{})
    assert "/caf/work/framework/delegate.settings.json" in plain
    assert launch(:headless, options: @options) == {:refused, {:missing, :settings}}
    assert Options.decode(Options.encode(@options)) == {:ok, @options}
  end

  test "each bad value is refused before a launch, naming the option" do
    for {options, {option, why}} <- [
          {%{"other" => 1}, {"other", :unknown}},
          {%{settings: %{"hooks" => %{}}}, {:settings, {:reserved, "hooks"}}},
          {%{settings: %{"permissions" => %{"deny" => "Bash"}}},
           {:settings, {:bad_rules, "Bash"}}},
          {%{env: %{"PATH" => "/x"}}, {:env, {:reserved, "PATH"}}},
          {%{env: %{"TMUX_PANE" => "%1"}}, {:env, {:reserved, "TMUX_PANE"}}},
          {%{env: %{"A=B" => "1"}}, {:env, {:bad_name, "A=B"}}},
          {%{add_dirs: ["/srv/../etc"]}, {:add_dirs, {:bad_dir, "/srv/../etc"}}},
          {%{append_system_prompt: String.duplicate("a", 65_537)},
           {:append_system_prompt, {:too_long, 65_536}}},
          {%{allowed_tools: ["--bg"]}, {:allowed_tools, {:bad_pattern, "--bg"}}},
          {%{env: Map.new(1..64, &{"V#{&1}", String.duplicate("v", 5000)})},
           {:options, {:too_long, 262_144}}}
        ] do
      assert launch(:headless, options: options) == {:refused, {:bad_option, option, why}}
    end
  end
end
