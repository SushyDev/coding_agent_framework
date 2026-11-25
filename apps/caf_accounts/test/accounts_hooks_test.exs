defmodule CodingAgentFramework.AccountsHooksTest do
  @moduledoc "The http hooks `Accounts` writes for `Intake`, one for each of its events."
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Accounts
  alias CodingAgentFramework.Intake.Event

  @secret "s3cr3t"

  test "Accounts writes the http hooks into both role settings" do
    {:ok, accounts} = Accounts.new(test_dir(), ["work"])
    own = %{"Stop" => [%{"hooks" => [%{"type" => "command", "command" => "true"}]}]}

    {:ok, account} =
      Accounts.prepare(accounts, "work", %{hooks: own, intake: %{port: 4790, secret: @secret}})

    for role <- [:parent, :delegate] do
      hooks = JSON.decode!(File.read!(account.settings[role]))["hooks"]
      assert Map.keys(hooks) == Enum.sort(Event.names())
      assert [%{"hooks" => [%{"type" => "command"}]}, %{"hooks" => [stop]}] = hooks["Stop"]
      assert %{"url" => "http://127.0.0.1:4790/hooks/work", "timeout" => 10} = stop
      assert stop["headers"] == %{"x-caf-secret" => @secret}
      refute Map.has_key?(stop, "onFailure")
      assert [%{"hooks" => [%{"timeout" => 600}]}] = hooks["PermissionRequest"]
    end
  end

  # Claude Code 2.1.322 runs no http hook on SessionStart (F-236): the start's hook is a command,
  # and an app without the callback has none, so no SessionStart hook at all.
  test "a session's start is a command hook, written only for the app's callback" do
    {:ok, accounts} = Accounts.new(test_dir(), ["work"])
    programs = programs()

    for tools <- [[], [:pre_tool_use], [:post_tool_use, :stop]] do
      intake = %{port: 4790, secret: @secret, tools: tools}
      {:ok, account} = Accounts.prepare(accounts, "work", %{intake: intake, programs: programs})

      refute Map.has_key?(
               JSON.decode!(File.read!(account.settings[:parent]))["hooks"],
               "SessionStart"
             )
    end

    intake = %{port: 4790, secret: @secret, tools: [:pre_tool_use, :session_start]}
    {:ok, account} = Accounts.prepare(accounts, "work", %{intake: intake, programs: programs})

    for role <- [:parent, :delegate] do
      hooks = JSON.decode!(File.read!(account.settings[role]))["hooks"]
      assert [%{"hooks" => [start]}] = hooks["SessionStart"]
      assert %{"type" => "command", "timeout" => 10, "command" => command} = start
      assert command =~ "caf-start" and command =~ "http://127.0.0.1:4790/hooks/work"
      assert [%{"hooks" => [%{"type" => "http"}]}] = hooks["PreToolUse"]
    end

    assert Accounts.prepare(accounts, "work", %{intake: intake}) ==
             {:refused, {:no_program, [:sh, :curl]}}
  end

  test "a tool hook is written only for a callback the app gives Intake" do
    {:ok, accounts} = Accounts.new(test_dir(), ["work"])

    for tools <- [[], [:pre_tool_use], [:post_tool_use], [:pre_tool_use, :post_tool_use]] do
      intake = %{port: 4790, secret: @secret, tools: tools}
      {:ok, account} = Accounts.prepare(accounts, "work", %{intake: intake})
      hooks = JSON.decode!(File.read!(account.settings[:parent]))["hooks"]
      named = Enum.map(tools, &%{pre_tool_use: "PreToolUse", post_tool_use: "PostToolUse"}[&1])
      assert Map.keys(hooks) == Enum.sort(Enum.uniq(Event.names() ++ named))

      for event <- named do
        assert [%{"hooks" => [%{"type" => "http", "timeout" => 10} = hook]}] = hooks[event]
        refute Map.has_key?(hook, "onFailure")
      end
    end
  end
end
