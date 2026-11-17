defmodule CodingAgentFramework.UsageSourceTest do
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost
  import CodingAgentFramework.UsageSetup

  alias CodingAgentFramework.{Accounts, Usage, UsageSetup}
  alias CodingAgentFramework.Tracker.TableSource

  @now UsageSetup.now()

  test "the status line command keeps a text with the weekly window, and Usage reads it" do
    %{accounts: accounts, usage: usage, db: db} = start(["work"])
    {:ok, account} = Accounts.prepare(accounts, "work", %{programs: programs()})

    for role <- [:parent, :delegate] do
      %{"statusLine" => %{"type" => "command", "command" => command}} =
        JSON.decode!(File.read!(account.settings[role]))

      assert command =~ "statusline.sh"
    end

    %{"statusLine" => %{"command" => command}} =
      JSON.decode!(File.read!(account.settings.parent))

    # Claude Code runs the command through a shell with the JSON on its input.
    run = fn json ->
      input = Path.join(test_dir(), "input.json")
      File.write!(input, JSON.encode!(json))
      assert {"", 0} = System.cmd(program!(:sh), ["-c", command <> " < '#{input}'"])
    end

    assert Usage.readings(usage) == :unread
    run.(Map.merge(week(41.5, @now), %{"session_id" => "s1", "model" => %{"id" => "m"}}))
    assert {:ok, %{readings: 1, problems: 0, ids: [{"work", id}]}} = Usage.read(usage)
    assert_received %{topic: "usage:h:work", ids: [^id]}

    {:ok, %{readings: %{"work" => reading}}} = Usage.readings(usage)
    assert %{used: 41.5, resets_at: @now, problem: nil, seen_at: seen} = reading
    assert is_integer(seen) and seen <= System.os_time(:millisecond)
    assert Usage.pick(%{"work" => reading}, ["work"], div(seen, 1000)) == {:ok, "work"}

    # A text before the first answer from the API has no weekly window: the reading stays.
    run.(%{"session_id" => "s2", "rate_limits" => %{"five_hour" => %{"used_percentage" => 3}}})
    assert {:ok, %{ids: []}} = Usage.read(usage)
    refute_received %{topic: _}

    # A half-written file keeps the last good reading and names the problem.
    {:ok, file} = Accounts.usage_file(accounts, "work")
    File.write!(file, ~s({"rate_limits": {"seven))
    assert {:ok, %{problems: 1}} = Usage.read(usage)
    {:ok, %{readings: %{"work" => kept}}} = Usage.readings(usage)
    assert %{kept | problem: nil} == reading and kept.problem == ":not_json"

    {:ok, source} =
      TableSource.open(
        table: Usage.Table,
        db: db,
        account: "work",
        clock: fn -> div(seen, 1000) end
      )

    assert {:ok, %{rows: [%{account: "work", used: 41.5, assumed: false}]}} =
             TableSource.read(source, :all)

    # Once its reset has passed, the source marks the reading assumed.
    File.write!(file, JSON.encode!(week(41.5, 1)))
    assert {:ok, %{ids: [_]}} = Usage.read(usage)
    assert {:ok, %{rows: [%{assumed: true}]}} = TableSource.read(source, :all)
    assert {:ok, %{rows: []}} = TableSource.read(source, [id + 1])
  end
end
