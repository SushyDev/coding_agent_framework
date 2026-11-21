defmodule CodingAgentFramework.UsageSetup do
  @moduledoc """
  The setup `UsageTest` and `UsageSourceTest` share: a `Usage` over `Accounts` in the test's own
  directory, the test's "now", and the weekly window Claude Code hands its status line.

  It compiles only for tests. It lives in `caf_usage`, not `caf_test`, because it uses `Usage`,
  and `caf_test` may not use an app above it.

      %{accounts: accounts, usage: usage, db: db} = UsageSetup.start(["work"])
  """

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Usage}

  @doc "The tests' fixed now, in Unix seconds."
  def now, do: 1_800_000_000

  @doc "The status line's JSON for a weekly window `used` percent full that resets at `resets_at`."
  def week(used, resets_at),
    do: %{
      "rate_limits" => %{"seven_day" => %{"used_percentage" => used, "resets_at" => resets_at}}
    }

  @doc "`Accounts` of `names` and a `Usage` over them on host `h`; its cues come to the caller."
  def start(names, opts \\ []) do
    # A quote in the home's path shows the status line command quotes its words.
    {:ok, accounts} = Accounts.new(Path.join(test_dir(), "caf o'home"), names)
    me = self()
    db = Path.join(test_dir(), "usage.db")

    {:ok, usage} =
      Usage.start_link([accounts: accounts, host: "h", db: db, notify: &send(me, &1)] ++ opts)

    %{accounts: accounts, usage: usage, db: db}
  end
end
