defmodule CodingAgentFramework.ClaudeCLITest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.ClaudeCLI
  alias CodingAgentFramework.Accounts.Account

  doctest ClaudeCLI
  doctest Account

  @dir "/caf/accounts/work/claude"
  @env %{home: "/h", path: "/bin", term: "xterm-256color", lang: "C.UTF-8"}

  # `more` comes first, so its values win `Keyword.get/2`.
  defp opts(more), do: more ++ [claude: "/run/claude", model: "opus", name: "unit-7", env: @env]
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

  test "a delegate needs a brief unless it resumes" do
    assert ClaudeCLI.session(:delegate, account(), opts([])) ==
             {:refused, :delegate_without_brief}

    assert {:ok, %{argv: argv}} = ClaudeCLI.session(:delegate, account(), opts(resume: "s-2"))
    assert Enum.take(argv, -2) == ["--resume", "s-2"]
  end

  test "the environment is the account's directory and the four a session needs, nothing else" do
    for role <- [:parent, :delegate] do
      assert {:ok, %{env: env}} = ClaudeCLI.session(role, account(), opts(prompt: "p"))

      assert env == [
               {"CLAUDE_CONFIG_DIR", @dir},
               {"HOME", "/h"},
               {"PATH", "/bin"},
               {"TERM", "xterm-256color"},
               {"LANG", "C.UTF-8"}
             ]
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
end
