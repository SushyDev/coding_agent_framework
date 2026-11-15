defmodule CodingAgentFramework.AccountsTest do
  @moduledoc """
  `Accounts` on disk. Its setup sets variables in this VM's own environment, so it runs alone
  (`async: false`) and puts them back after.
  """
  use ExUnit.Case, async: false

  alias CodingAgentFramework.{Accounts, AccountsSetup}

  doctest Accounts

  setup {AccountsSetup, :accounts}

  test "prepare writes only the framework's own files, and nothing outside the home", ctx do
    data = %{
      settings: %{"model" => "opus"},
      hooks: %{"Stop" => [%{"hooks" => [%{"type" => "command", "command" => "/bin/true"}]}]},
      mcp_servers: %{"caf" => %{"command" => "/bin/caf-mcp"}}
    }

    assert {:ok, account} = Accounts.prepare(ctx.accounts, "work", data)
    assert account.config_dir == Path.join(ctx.home, "accounts/work/claude")

    parent = JSON.decode!(File.read!(account.settings.parent))
    delegate = JSON.decode!(File.read!(account.settings.delegate))

    assert parent ==
             Map.merge(data.settings, %{"hooks" => data.hooks, "remoteControlAtStartup" => true})

    assert delegate == %{parent | "remoteControlAtStartup" => false}
    assert JSON.decode!(File.read!(account.mcp_config)) == %{"mcpServers" => data.mcp_servers}

    written = Path.wildcard(Path.join(ctx.dir, "**/*"), match_dot: true)

    assert Enum.all?(
             written,
             &(&1 in [ctx.fake_home, ctx.home] or String.starts_with?(&1, ctx.home <> "/"))
           )

    for file <- ["settings.json", ".claude.json", ".credentials.json"],
        do: refute(File.exists?(Path.join(account.config_dir, file)))

    assert Accounts.ready(ctx.accounts, "work") == {:ok, account}
  end

  test "an account not prepared is refused, and its login is read from file names only", ctx do
    assert Accounts.ready(ctx.accounts, "spare") == {:refused, {:not_prepared, "spare"}}
    assert Accounts.login(ctx.accounts, "spare") == {:refused, {:no_config_dir, "spare"}}

    assert Accounts.prepare(ctx.accounts, "nobody", %{}) ==
             {:refused, {:unknown_account, "nobody"}}

    {:ok, account} = Accounts.prepare(ctx.accounts, "spare", %{})
    assert Accounts.login(ctx.accounts, "spare") == {:ok, :logged_out}
    File.write!(Path.join(account.config_dir, ".claude.json"), "")
    assert Accounts.login(ctx.accounts, "spare") == {:unknown, :login_not_readable}
    # The stand-in credential is not JSON: login/2 must not open it.
    File.write!(Path.join(account.config_dir, ".credentials.json"), "not read")
    assert Accounts.login(ctx.accounts, "spare") == {:ok, :looks_logged_in}
  end
end
