defmodule CodingAgentFramework.AccountsSetup do
  @moduledoc """
  The setup `AccountsTest` and `ClaudeCLIHeldTest` share: two `Accounts` in the test's own
  directory, with the VM's environment set as Claude Code would leave it, under a home of the
  test's own. It sets variables in this VM's own environment, so a test that uses it runs alone
  (`async: false`); it puts them back when the test ends.

  It compiles only for tests. It lives in `caf_accounts`, not `caf_test`, because it uses
  `Accounts`, and `caf_test` may not use an app above it.

      setup {CodingAgentFramework.AccountsSetup, :accounts}
  """

  import CodingAgentFramework.TestHost
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias CodingAgentFramework.Accounts

  @vm_env %{
    "CLAUDE_CONFIG_DIR" => "/elsewhere/claude",
    "CLAUDECODE" => "1",
    "CLAUDE_CODE_ENTRYPOINT" => "cli"
  }

  @doc """
  An ExUnit setup: the test's `dir`, the `fake_home` its `HOME` names, and `accounts`, with
  `work` and `spare`, at `home`.
  """
  def accounts(_context) do
    dir = test_dir()
    fake_home = Path.join(dir, "person")
    File.mkdir_p!(fake_home)
    vars = Map.put(@vm_env, "HOME", fake_home)
    before = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    System.put_env(vars)

    on_exit(fn ->
      Enum.each(before, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    home = Path.join(dir, "caf")
    {:ok, accounts} = Accounts.new(home, ["work", "spare"])
    {:ok, dir: dir, home: home, fake_home: fake_home, accounts: accounts}
  end
end
