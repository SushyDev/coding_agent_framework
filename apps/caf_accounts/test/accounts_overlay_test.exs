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

  # F-200: a default is only what nobody said; the account's file and then the agent's win.
  test "an overlay's defaults sit under the account's file and the agent's own settings" do
    home = Path.join(TestHost.test_dir(), "overlay-#{System.unique_integer([:positive])}")
    {:ok, accounts} = Accounts.new(home, ["work"])
    {:ok, account} = Accounts.prepare(accounts, "work", %{settings: %{"theme" => "dark"}})
    defaults = %{"includeGitInstructions" => false, "theme" => "light"}
    written = &JSON.decode!(File.read!(elem(&1, 1)))

    # Nobody said: the default stands. The account's file wins over a default it names.
    assert %{"includeGitInstructions" => false, "theme" => "dark"} =
             written.(Accounts.overlay(account, :delegate, "d-1", %{}, defaults))

    # The agent's own value wins over both.
    own = %{"includeGitInstructions" => true, "theme" => "own"}

    assert %{"includeGitInstructions" => true, "theme" => "own"} =
             written.(Accounts.overlay(account, :delegate, "d-2", own, defaults))

    # No defaults, as before: nothing is added.
    refute Map.has_key?(
             written.(Accounts.overlay(account, :delegate, "d-3", %{})),
             "includeGitInstructions"
           )

    assert Accounts.overlay(account, :delegate, "d-4", %{}, :none) == {:refused, {:bad, :overlay}}
  end

  # F-285: the offer to set up auto mode is off in every file; the app's other entries are kept.
  test "skill overrides merge per entry, and the framework's auto-mode-setup entry wins" do
    home = Path.join(TestHost.test_dir(), "overlay-#{System.unique_integer([:positive])}")
    {:ok, accounts} = Accounts.new(home, ["work"])
    app = %{"auto-mode-setup" => "on", "review" => "off", "notes" => "user-invocable-only"}

    {:ok, account} =
      Accounts.prepare(accounts, "work", %{settings: %{"skillOverrides" => app}})

    account_wide = %{
      "auto-mode-setup" => "off",
      "review" => "off",
      "notes" => "user-invocable-only"
    }

    for file <- [account.settings.parent, account.settings.delegate],
        do: assert(JSON.decode!(File.read!(file))["skillOverrides"] == account_wide)

    own = %{"skillOverrides" => %{"notes" => "off", "draw" => "name-only"}}
    assert {:ok, path} = Accounts.overlay(account, :delegate, "d-1", own)

    assert JSON.decode!(File.read!(path))["skillOverrides"] ==
             %{
               "auto-mode-setup" => "off",
               "review" => "off",
               "notes" => "off",
               "draw" => "name-only"
             }

    # Even an overlay given the framework's own entry keeps it off.
    off = %{"skillOverrides" => %{"auto-mode-setup" => "on"}}
    assert {:ok, path} = Accounts.overlay(account, :parent, "main", off)
    assert JSON.decode!(File.read!(path))["skillOverrides"] == account_wide

    # An account file written before F-285 has no entry; its overlay gets one.
    File.write!(account.settings.delegate, JSON.encode!(%{"theme" => "dark"}))
    assert {:ok, path} = Accounts.overlay(account, :delegate, "d-2", %{})
    assert JSON.decode!(File.read!(path))["skillOverrides"] == %{"auto-mode-setup" => "off"}

    assert Accounts.prepare(accounts, "work", %{settings: %{"skillOverrides" => ["x"]}}) ==
             {:refused, {:bad, {:skillOverrides, ["x"]}}}
  end

  test "an overlay's hooks add to the account's per event; they never replace them" do
    home = Path.join(TestHost.test_dir(), "overlay-#{System.unique_integer([:positive])}")
    {:ok, accounts} = Accounts.new(home, ["work"])
    stop = %{"hooks" => [%{"type" => "command", "command" => "own-stop"}]}
    intake = %{port: 4790, secret: "s3"}

    {:ok, account} =
      Accounts.prepare(accounts, "work", %{hooks: %{"Stop" => [stop]}, intake: intake})

    base = JSON.decode!(File.read!(account.settings.parent))["hooks"]
    waiter = %{"hooks" => [%{"type" => "command", "command" => "waiter", "asyncRewake" => true}]}

    assert {:ok, path} =
             Accounts.overlay(account, :parent, "main", %{"hooks" => %{"Stop" => [waiter]}})

    hooks = JSON.decode!(File.read!(path))["hooks"]
    # The account's own Stop and Intake's, then the overlay's; every other event as it was.
    assert hooks["Stop"] == base["Stop"] ++ [waiter]
    assert [^stop, %{"hooks" => [%{"type" => "http"}]}, ^waiter] = hooks["Stop"]
    assert Map.delete(hooks, "Stop") == Map.delete(base, "Stop")
  end
end
