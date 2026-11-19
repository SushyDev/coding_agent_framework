defmodule CodingAgentFramework.ClaudeCLITest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.ClaudeCLI
  alias CodingAgentFramework.Accounts.Account

  doctest ClaudeCLI
  doctest Account

  @dir "/caf/accounts/work/claude"
  @env %{home: "/h", path: "/bin", term: "xterm-256color", lang: "C.UTF-8", user: "me"}

  # `more` comes first, so its values win `Keyword.get/2`.
  defp opts(more),
    do:
      more ++
        [claude: "/run/claude", model: "opus", name: "unit-7", env: @env, tool_timeout: 600_000]

  defp account, do: Account.at("work", @dir)

  test "a parent has Remote Control on with its name, and its own settings" do
    assert {:ok, %{argv: argv}} =
             ClaudeCLI.session(:parent, account(), opts(resume: "s-1", prompt: "go on"))

    assert argv ==
             ["/run/claude", "--model", "opus", "--name", "unit-7"] ++
               ["--settings", @dir <> "/framework/parent.settings.json"] ++
               ["--mcp-config", @dir <> "/framework/mcp.json", "--strict-mcp-config"] ++
               ["--remote-control", "unit-7", "--resume", "s-1", "--", "go on"]
  end

  test "a delegate has Remote Control off and its brief as the first prompt" do
    brief = "-- fix the build\nthen report"
    assert {:ok, %{argv: argv}} = ClaudeCLI.session(:delegate, account(), opts(prompt: brief))

    refute "--remote-control" in argv
    assert Enum.take(argv, -2) == ["--", brief]
    assert "#{@dir}/framework/delegate.settings.json" in argv
    refute "--bg" in argv
  end

  test "the agent's own MCP config follows the account's, before the strict flag" do
    mine = "/caf/mcp/agents/unit-7.json"
    servers = ["--mcp-config", @dir <> "/framework/mcp.json", mine, "--strict-mcp-config"]

    assert {:ok, %{argv: a}} =
             ClaudeCLI.session(:delegate, account(), opts(mcp: mine, prompt: "x"))

    assert Enum.chunk_every(a, 4, 1) |> Enum.member?(servers)

    assert {:ok, %{argv: h}} =
             ClaudeCLI.headless(
               account(),
               Keyword.delete(opts(mcp: mine, session_id: "s"), :name)
             )

    assert Enum.chunk_every(h, 4, 1) |> Enum.member?(servers)

    assert ClaudeCLI.session(:parent, account(), opts(mcp: "agents/x.json")) ==
             {:refused, {:bad, :mcp}}
  end

  test "a delegate needs a brief unless it resumes" do
    assert ClaudeCLI.session(:delegate, account(), opts([])) ==
             {:refused, :delegate_without_brief}

    assert {:ok, %{argv: argv}} = ClaudeCLI.session(:delegate, account(), opts(resume: "s-2"))
    assert Enum.take(argv, -2) == ["--resume", "s-2"]
  end

  test "the environment is the account's directory, the four a session needs, the tool timeout and the auto-updater off, nothing else" do
    expected = [
      {"CLAUDE_CONFIG_DIR", @dir},
      {"HOME", "/h"},
      {"PATH", "/bin"},
      {"TERM", "xterm-256color"},
      {"LANG", "C.UTF-8"},
      {"USER", "me"},
      {"MCP_TOOL_TIMEOUT", "600000"},
      {"CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT", "600000"},
      {"DISABLE_AUTOUPDATER", "1"}
    ]

    for role <- [:parent, :delegate] do
      assert {:ok, %{env: env}} = ClaudeCLI.session(role, account(), opts(prompt: "p"))
      assert env == expected
    end

    assert {:ok, %{env: env}} = ClaudeCLI.headless(account(), opts(resume: "s-1"))
    assert env == expected
  end

  # F-173: Claude Code finds the Keychain item by USER alone.
  test "USER is the app's, after LANG; a bad one is refused, and none is left out" do
    assert {:ok, %{env: env}} = ClaudeCLI.session(:parent, account(), opts(prompt: "p"))
    assert Enum.slice(env, 4, 2) == [{"LANG", "C.UTF-8"}, {"USER", "me"}]

    none = Map.delete(@env, :user)

    assert {:ok, %{env: env}} =
             ClaudeCLI.session(:parent, account(), opts(env: none, prompt: "p"))

    refute List.keymember?(env, "USER", 0)

    for bad <- ["", "a\nb", :me] do
      assert ClaudeCLI.session(:parent, account(), opts(env: Map.put(@env, :user, bad))) ==
               {:refused, {:bad, :user}}
    end

    assert ClaudeCLI.session(
             :parent,
             account(),
             opts(env: Map.put(@env, :tools, [{"USER", "x"}]))
           ) == {:refused, {:bad, :tools}}
  end

  # F-151: Claude Code's Node finds devenv's certificates only through these variables.
  test "the CA bundle the app gives is passed on after the four, sorted; a bad one is refused" do
    ca = %{"SSL_CERT_FILE" => "/etc/ca.crt", "NODE_EXTRA_CA_CERTS" => "/etc/ca.crt"}
    env = Map.put(@env, :ca, ca)

    for role <- [:parent, :delegate] do
      assert {:ok, %{env: got}} =
               ClaudeCLI.session(role, account(), opts(env: env, prompt: "p"))

      assert Enum.slice(got, 6, 2) ==
               [{"NODE_EXTRA_CA_CERTS", "/etc/ca.crt"}, {"SSL_CERT_FILE", "/etc/ca.crt"}]
    end

    for bad <- [%{"NODE_EXTRA_CA_CERTS" => "ca.crt"}, %{"lower" => "/x"}, :none] do
      assert ClaudeCLI.session(:parent, account(), opts(env: Map.put(@env, :ca, bad))) ==
               {:refused, {:bad, :ca}}
    end
  end

  # F-155: gh, git and ssh keep their state in the framework home, by these variables.
  test "the tools' state the app gives is passed on after the CA bundle, in order" do
    tools = CodingAgentFramework.ToolHome.env("/caf", "/run/bin/ssh")
    env = Map.merge(@env, %{ca: %{"SSL_CERT_FILE" => "/etc/ca.crt"}, tools: tools})

    for role <- [:parent, :delegate] do
      assert {:ok, %{env: got}} = ClaudeCLI.session(role, account(), opts(env: env, prompt: "p"))
      assert Enum.slice(got, 7, length(tools)) == tools
      assert {"GH_CONFIG_DIR", "/caf/gh"} in got
    end

    for bad <- [[{"HOME", "/x"}], [{"lower", "/x"}], [{"GH_CONFIG_DIR", "a\nb"}], :none] do
      assert ClaudeCLI.session(:parent, account(), opts(env: Map.put(@env, :tools, bad))) ==
               {:refused, {:bad, :tools}}
    end
  end

  test "a launch with no account directory is refused, never falling back" do
    for account <- [nil, "work", %{config_dir: @dir}, %{account() | config_dir: "rel/claude"}] do
      assert ClaudeCLI.session(:parent, account, opts([])) == {:refused, :no_account_dir}
    end
  end

  test "values a flag would misread are refused" do
    assert ClaudeCLI.session(:parent, account(), opts(name: "--bg")) == {:refused, {:bad, :name}}
    assert ClaudeCLI.session(:parent, account(), opts(model: "")) == {:refused, {:bad, :model}}

    assert ClaudeCLI.session(:parent, account(), opts(resume: "a\nb")) ==
             {:refused, {:bad, :resume}}

    assert ClaudeCLI.session(:parent, account(), opts(claude: "claude")) ==
             {:refused, {:bad, :claude}}

    assert ClaudeCLI.session(:parent, account(), opts(env: Map.delete(@env, :term))) ==
             {:refused, {:missing, {:env, [:term]}}}

    assert ClaudeCLI.session(:other, account(), opts([])) == {:refused, {:bad_role, :other}}
  end

  test "the tool timeout is required, in the range Claude Code reads" do
    missing = Keyword.delete(opts(prompt: "p"), :tool_timeout)
    assert ClaudeCLI.session(:parent, account(), missing) == {:refused, {:missing, :tool_timeout}}

    assert ClaudeCLI.headless(account(), Keyword.delete(opts(resume: "s"), :tool_timeout)) ==
             {:refused, {:missing, :tool_timeout}}

    for bad <- [999, 2_147_483_648, "600000", 1.5e6] do
      assert ClaudeCLI.session(:parent, account(), opts(tool_timeout: bad)) ==
               {:refused, {:bad, :tool_timeout}}
    end

    assert {:ok, %{env: env}} = ClaudeCLI.session(:parent, account(), opts(tool_timeout: 1_000))
    assert {"MCP_TOOL_TIMEOUT", "1000"} in env
  end
end
