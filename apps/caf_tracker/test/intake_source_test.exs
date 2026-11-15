defmodule CodingAgentFramework.IntakeSourceTest do
  use ExUnit.Case, async: true

  import CodingAgentFramework.IntakeSetup

  alias CodingAgentFramework.IntakeSetup
  alias CodingAgentFramework.Tracker.IntakeSource

  setup {IntakeSetup, :intake}

  test "a second post of one event writes no second row", %{db: db, start: start} do
    intake = start.([])
    assert %{status: 200, resp_body: ""} = post(intake, body("SessionStart", %{"source" => "x"}))
    assert %{status: 200} = post(intake, body("SessionStart", %{"source" => "x"}))
    assert [%{key: "SessionStart:s1:x"}] = rows(db)

    {:ok, source} = IntakeSource.open(db: db, host: "h", account: "work")
    assert {:ok, %{rows: [_]}} = IntakeSource.read(source, :all)
  end
end
