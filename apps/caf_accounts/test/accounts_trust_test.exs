defmodule CodingAgentFramework.AccountsTrustTest do
  @moduledoc """
  `Accounts.trust/3` on disk (F-255, `model/tla/Trust.tla`): the mark goes into `.claude.json`
  under Claude Code's own lock, inside the worktrees' root only, and every refusal writes
  nothing.
  """
  use ExUnit.Case, async: true

  alias CodingAgentFramework.{Accounts, TestHost}

  @state %{
    "hasCompletedOnboarding" => true,
    "numStartups" => 7,
    "oauthAccount" => %{"emailAddress" => "a@example.org"},
    "projects" => %{"/srv/w/app/one" => %{"allowedTools" => ["Read"]}}
  }

  setup do
    home = Path.join(TestHost.test_dir(), "trust-#{System.unique_integer([:positive])}")
    {:ok, accounts} = Accounts.new(home, ["work"])
    {:ok, account} = Accounts.prepare(accounts, "work", %{})
    file = Path.join(account.config_dir, ".claude.json")
    File.write!(file, JSON.encode!(@state))
    File.chmod!(file, 0o600)
    {:ok, account: account, state_file: file, lock: file <> ".lock"}
  end

  # MarkKept, NoKeyLost: the mark over the path's own entry, every other key as it was.
  test "the mark is added over the path's entry, keeping every key and the file's mode", ctx do
    assert {:ok, :trusted} = Accounts.trust(ctx.account, "/srv/w", "/srv/w/app/one")
    assert {:ok, :trusted} = Accounts.trust(ctx.account, "/srv/w/", "/srv/w/app/two")

    state = JSON.decode!(File.read!(ctx.state_file))
    assert Map.delete(state, "projects") == Map.delete(@state, "projects")

    assert state["projects"] == %{
             "/srv/w/app/one" => %{"allowedTools" => ["Read"], "hasTrustDialogAccepted" => true},
             "/srv/w/app/two" => %{"hasTrustDialogAccepted" => true}
           }

    assert Bitwise.band(File.stat!(ctx.state_file).mode, 0o777) == 0o600
    refute File.exists?(ctx.lock)
    refute File.exists?(ctx.state_file <> ".framework.tmp")

    # There already: nothing is written.
    before = File.stat!(ctx.state_file, time: :posix)
    assert {:ok, :already} = Accounts.trust(ctx.account, "/srv/w", "/srv/w/app/one")
    assert File.stat!(ctx.state_file, time: :posix).inode == before.inode
  end

  # Only inside the worktrees' root: never the root itself, a project's checkout, a path
  # outside, or one that climbs out with `..`.
  test "a path not inside the root is refused, and nothing is written", ctx do
    for path <- ["/srv/w", "/srv/app", "/srv/w/../app", "/srv/wx/app", "app/one"] do
      assert {:refused, {:outside, ^path}} = Accounts.trust(ctx.account, "/srv/w", path)
    end

    assert {:refused, {:outside, "/srv/w/a"}} = Accounts.trust(ctx.account, "srv/w", "/srv/w/a")
    assert JSON.decode!(File.read!(ctx.state_file)) == @state
    refute File.exists?(ctx.lock)
  end

  # RefusedWroteNothing: a lock another writer holds refuses at once; the lock stays its own.
  test "a held lock refuses at once and is left as it was", ctx do
    File.mkdir!(ctx.lock)
    assert {:refused, :locked} = Accounts.trust(ctx.account, "/srv/w", "/srv/w/app/two")
    assert File.dir?(ctx.lock)
    assert JSON.decode!(File.read!(ctx.state_file)) == @state
  end

  test "no file, or a file that is not a JSON object, is refused and the lock let go", ctx do
    File.write!(ctx.state_file, "[1]")
    assert {:refused, {:not_json, file}} = Accounts.trust(ctx.account, "/srv/w", "/srv/w/a/b")
    assert file == ctx.state_file and File.read!(ctx.state_file) == "[1]"

    File.write!(ctx.state_file, ~s({"projects": 3}))
    assert {:refused, {:not_json, _}} = Accounts.trust(ctx.account, "/srv/w", "/srv/w/a/b")

    # Claude Code never ran on the account: the file its first start makes is not made here.
    File.rm!(ctx.state_file)
    assert {:refused, {:no_state, _}} = Accounts.trust(ctx.account, "/srv/w", "/srv/w/a/b")
    refute File.exists?(ctx.state_file)
    refute File.exists?(ctx.lock)
  end
end
