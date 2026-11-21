defmodule CodingAgentFramework.LoginsTest do
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Logins}
  alias CodingAgentFramework.Logins.{Status, Table}

  doctest Status
  doctest Table

  @logged_in ~s({"loggedIn": true, "authMethod": "claude.ai", "loginExpiresAt": null})
  @logged_out ~s({"loggedIn": false, "authMethod": "none", "loginExpiresAt": null})

  # A stand-in of the app's run: it answers what the test put for each account, and counts runs.
  defp start(answers, opts \\ []) do
    {:ok, accounts} = Accounts.new(Path.join(test_dir(), "home"), ~w(work home))
    {:ok, said} = Agent.start_link(fn -> answers end)
    me = self()

    run = fn name ->
      send(me, {:ran, name})
      Agent.get(said, & &1[name])
    end

    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)
    db = Path.join(test_dir(), "logins.db")

    {:ok, logins} =
      Logins.start_link(
        [
          accounts: accounts,
          host: "h",
          db: db,
          run: run,
          notify: &send(me, &1),
          clock: fn -> Agent.get(clock, & &1) end
        ] ++ opts
      )

    %{logins: logins, said: said, clock: clock, accounts: accounts, db: db}
  end

  test "a check runs once, is kept for max_age, and runs again after it" do
    %{logins: logins, clock: clock} = start(%{"work" => {:ok, %{status: 0, output: @logged_in}}})
    assert Logins.check(logins, "work") == :ok
    assert_receive {:ran, "work"}
    assert_receive %{topic: "logins:h", ids: [_]}
    assert Logins.check(logins, "work") == :ok
    refute_received {:ran, _}
    Agent.update(clock, &(&1 + 10 * 60 * 1000))
    assert Logins.check(logins, "work") == :ok
    assert_receive {:ran, "work"}
    # The state did not change: no cue.
    refute_received %{topic: "logins:h"}
  end

  test "a refused login is kept as a row Prompts reads until a check finds it logged in" do
    %{logins: logins, said: said, db: db} =
      start(%{"home" => {:ok, %{status: 1, output: @logged_out}}})

    {:ok, conn} = Table.open(db)
    assert Logins.check(logins, "home") == {:refused, {:login, :logged_out}}
    assert [%{account: "home", state: "logged_out", refused_at: at}] = Table.refused(conn)
    assert is_integer(at)
    # Kept: no run until a recheck, the prompt's answer.
    assert Logins.check(logins, "home") == {:refused, {:login, :logged_out}}
    assert_receive {:ran, "home"}
    refute_received {:ran, _}
    Agent.update(said, &Map.put(&1, "home", {:ok, %{status: 0, output: @logged_in}}))
    assert Logins.recheck(logins, "home") == :ok
    assert Table.refused(conn) == []
  end

  test "a check that cannot tell is never kept, and says why" do
    %{logins: logins} =
      start(%{
        "work" => {:unknown, {:timeout, 15_000}},
        "home" => {:ok, %{status: 0, output: "not json"}}
      })

    assert {:unknown, {:login_check, _}} = Logins.check(logins, "work")
    assert {:unknown, {:login_check, _}} = Logins.check(logins, "work")
    assert_receive {:ran, "work"}
    assert_receive {:ran, "work"}
    assert {:unknown, {:login_check, problem}} = Logins.check(logins, "home")
    assert problem =~ "not_json"
    assert Logins.check(logins, "nope") == {:refused, {:unknown_account, "nope"}}
  end

  test "usable is prepared and logged in, in that order" do
    %{logins: logins, accounts: accounts} =
      start(%{"work" => {:ok, %{status: 0, output: @logged_in}}})

    assert Logins.usable(logins, accounts, "work") == {:refused, {:not_prepared, "work"}}
    refute_received {:ran, _}
    {:ok, account} = Accounts.prepare(accounts, "work", %{})
    assert Logins.usable(logins, accounts, "work") == {:ok, account}
  end
end
