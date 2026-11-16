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

  test "a tool hook is written only for a callback the app gives Intake" do
    {:ok, accounts} = Accounts.new(test_dir(), ["work"])

    for tools <- [[], [:pre_tool_use], [:post_tool_use], [:pre_tool_use, :post_tool_use]] do
      intake = %{port: 4790, secret: @secret, tools: tools}
      {:ok, account} = Accounts.prepare(accounts, "work", %{intake: intake})
      hooks = JSON.decode!(File.read!(account.settings[:parent]))["hooks"]
      named = Enum.map(tools, &%{pre_tool_use: "PreToolUse", post_tool_use: "PostToolUse"}[&1])
      assert Map.keys(hooks) == Enum.sort(Event.names() ++ named)

      for event <- named do
        assert [%{"hooks" => [%{"type" => "http", "timeout" => 10} = hook]}] = hooks[event]
        refute Map.has_key?(hook, "onFailure")
      end
    end
  end
end
