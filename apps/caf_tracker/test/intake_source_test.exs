defmodule CodingAgentFramework.IntakeSourceTest do
  use ExUnit.Case, async: true

  import CodingAgentFramework.IntakeSetup

  alias CodingAgentFramework.Intake
  alias CodingAgentFramework.IntakeSetup
  alias CodingAgentFramework.Tracker.TableSource

  setup {IntakeSetup, :intake}

  # Intake's table as a source made from its metadata (F-120's new-2): unread until the host's
  # Intake started, then each account's rows only, read now.
  test "Intake's source is made from its table's metadata", %{db: db, start: start} do
    opts = [table: Intake.Table, db: db, host: "h", account: "work"]
    {:ok, source} = TableSource.open(opts)
    assert TableSource.read(source, :all) == :unread

    assert %{topic: "intake:h:work", scope: {"h", "work"}, kind: :events} =
             TableSource.describe(opts)

    intake = start.([])
    assert %{status: 200, resp_body: ""} = post(intake, body("SessionStart", %{"source" => "x"}))
    assert %{status: 200} = post(intake, body("SessionStart", %{"source" => "x"}))
    assert [%{id: id, key: "SessionStart:s1:x"}] = rows(db)

    assert {:ok, %{rows: [%{id: ^id}], read_at: at}} = TableSource.read(source, :all)
    assert is_integer(at)
    assert {:ok, %{rows: [%{id: ^id}]}} = TableSource.read(source, [id])

    {:ok, other} = TableSource.open(Keyword.put(opts, :account, "home"))
    assert {:ok, %{rows: []}} = TableSource.read(other, [id])
  end
end
