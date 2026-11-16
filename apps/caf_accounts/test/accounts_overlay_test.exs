defmodule CodingAgentFramework.AccountsOverlayTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.{Accounts, TestHost}

  test "an agent's rules add to the account's; its other settings replace them; bad is refused" do
    home = Path.join(TestHost.test_dir(), "overlay-#{System.unique_integer([:positive])}")
    {:ok, accounts} = Accounts.new(home, ["work"])
    rules = %{"deny" => ["Bash(rm *)"], "allow" => ["Read"], "defaultMode" => "default"}
    data = %{settings: %{"permissions" => rules, "model" => "opus", "theme" => "dark"}}
    {:ok, account} = Accounts.prepare(accounts, "work", data)
    own = %{"permissions" => %{"deny" => ["Bash(x *)", "Bash(rm *)"], "defaultMode" => "plan"}}

    assert {:ok, path} = Accounts.overlay(account, :delegate, "a-1", Map.put(own, "model", "m"))
    assert path == Path.join(account.config_dir, "framework/agents/a-1.settings.json")
    deny = ["Bash(rm *)", "Bash(x *)"]

    assert %{"permissions" => %{"deny" => ^deny, "allow" => ["Read"], "defaultMode" => "plan"}} =
             %{"model" => "m", "theme" => "dark", "remoteControlAtStartup" => false} =
             JSON.decode!(File.read!(path))

    # The role's file is the base, and it stays as it was.
    assert {:ok, main} = Accounts.overlay(account, :parent, "main", %{})
    assert %{"remoteControlAtStartup" => true} = JSON.decode!(File.read!(main))
    assert JSON.decode!(File.read!(account.settings.delegate))["model"] == "opus"
    assert Accounts.overlay(account, :delegate, "../x", %{}) == {:refused, {:bad, :name}}
    gone = %{account | name: "gone", settings: %{delegate: Path.join(home, "none.json")}}
    assert Accounts.overlay(gone, :delegate, "a", %{}) == {:refused, {:not_prepared, "gone"}}
  end
end
