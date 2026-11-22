defmodule CodingAgentFramework.IntakeStopTest do
  @moduledoc """
  The `Stop` hold (F-157): the app's callback, the count of blocks in a row and Claude Code's
  cap, the `stop_cap` row a person answers, a tool call's reset, and a pause.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.IntakeSetup

  alias CodingAgentFramework.Intake
  alias CodingAgentFramework.Intake.Table

  setup {CodingAgentFramework.IntakeSetup, :intake}

  @stop body("Stop", %{"stop_hook_active" => false})
  @tool body("PostToolUse", %{"tool_use_id" => "t1", "tool_name" => "Bash", "tool_input" => %{}})

  defp start_with(start, answer, opts \\ []) do
    me = self()

    stop = fn event ->
      send(me, {:asked, event})
      answer.(event)
    end

    start.(
      [stop: stop, agent: fn "work", "s1" -> "builder-1" end, project: fn _ -> "web" end] ++
        opts
    )
  end

  defp blocked?(conn), do: conn.status == 200 and conn.resp_body != ""
  defp reason(conn), do: JSON.decode!(conn.resp_body)["reason"]

  defp blocks(db) do
    {:ok, db} = Table.open(db)
    Table.blocks(db, "h", "work", "s1")
  end

  test "the callback decides each turn's end: a block with its reason, or a pass",
       %{db: db, start: start} do
    intake =
      start_with(start, fn %{blocks: n} ->
        if n == 0, do: {:block, "run the tests"}, else: :pass
      end)

    conn = post(intake, @stop)
    assert JSON.decode!(conn.resp_body) == %{"decision" => "block", "reason" => "run the tests"}
    assert_received {:asked, event}

    assert %{agent: "builder-1", project: "web", account: "work", session_id: "s1", blocks: 0} =
             event

    assert event.input["hook_event_name"] == "Stop"

    # The same body again is a Stop of its own, never taken for a second post of the first.
    assert %{status: 200, resp_body: ""} = post(intake, @stop)
    assert [%{hold: "answered", actor: "app"}, %{hold: "passed", actor: "app"}] = rows(db)
    # The pass ended the turn, and the count with it.
    assert blocks(db) == 0
  end

  test "a Stop passed resets the count: the next turn has the whole cap again",
       %{db: db, start: start} do
    {:ok, answers} = Agent.start_link(fn -> [:block, :block, :pass, :block, :block] end)
    next = fn _ -> Agent.get_and_update(answers, fn [a | rest] -> {a, rest} end) end

    intake =
      start_with(start, &if(next.(&1) == :pass, do: :pass, else: {:block, "on"}), stop_cap: 3)

    assert blocked?(post(intake, @stop))
    assert blocked?(post(intake, @stop))
    assert %{resp_body: ""} = post(intake, @stop)
    assert blocks(db) == 0

    # Below the cap's last again: neither waits on a person.
    assert blocked?(post(intake, @stop))
    assert blocked?(post(intake, @stop))
    assert blocks(db) == 2
    refute Enum.any?(rows(db), &(&1.prompt == "stop_cap"))
  end

  test "at the cap's last block a person decides; past it the turn ends, capped",
       %{db: db, start: start} do
    intake = start_with(start, fn _ -> {:block, "keep going"} end, stop_cap: 3)

    assert blocked?(post(intake, @stop))
    assert blocked?(post(intake, @stop))

    # The third would be the last Claude Code honors: it waits on a person.
    task = Task.async(fn -> post(intake, @stop) end)
    [_, _, %{id: id}] = await(fn -> cap_row(db) end)
    assert {:refused, {:not_held, _}} = Intake.answer(intake, id, :allow)
    assert {:ok, :sent} = Intake.answer(intake, id, :go_on)
    conn = Task.await(task)
    assert reason(conn) == "keep going"
    assert blocks(db) == 3

    # Past the cap the hold passes at once, whatever the callback says.
    assert %{status: 200, resp_body: ""} = post(intake, @stop)
    assert %{hold: "passed", actor: "capped"} = List.last(rows(db))
    assert blocks(db) == 0
    assert [_, _, %{actor: "person", prompt: "stop_cap", hold: "answered"} | _] = rows(db)
  end

  test "a person's end at the cap lets the turn end", %{db: db, start: start} do
    intake = start_with(start, fn _ -> {:block, "more"} end, stop_cap: 1)
    task = Task.async(fn -> post(intake, @stop) end)
    [%{id: id}] = await(fn -> cap_row(db) end)
    assert {:ok, :sent} = Intake.answer(intake, id, :end)
    assert %{status: 200, resp_body: ""} = Task.await(task)
    assert [%{hold: "passed", actor: "person"}] = rows(db)
    assert blocks(db) == 0
  end

  test "a tool call resets the count, and a restart keeps it", %{db: db, start: start} do
    intake = start_with(start, fn _ -> {:block, "again"} end, stop_cap: 3)
    assert blocked?(post(intake, @stop))
    assert blocked?(post(intake, @stop))
    assert blocks(db) == 2
    assert post(intake, @tool).status == 200
    assert blocks(db) == 0
    assert blocked?(post(intake, @stop))

    stop_supervised!(Intake)
    intake = start_with(start, fn _ -> {:block, "again"} end, stop_cap: 3)
    assert blocked?(post(intake, @stop))
    assert blocks(db) == 2
  end

  test "the Stop hold's settings post PostToolUse for the reset alone: answered at once, no row",
       %{db: db, start: start} do
    hooks = Intake.hooks(4790, "work", "s3", [:stop])
    assert [%{"hooks" => [%{"timeout" => 10}]}] = hooks["PostToolUse"]
    refute Map.has_key?(hooks, "PreToolUse")

    intake = start_with(start, fn _ -> :pass end)
    assert {:ok, :not_read} = Intake.post(intake, "work", @tool)
    assert rows(db) == []
  end

  test "a pause holds the turn's end until it is lifted, then the callback decides",
       %{db: db, start: start} do
    intake = start_with(start, fn _ -> {:block, "go on"} end)
    assert {:ok, :paused} = Intake.pause(intake, {:project, "web"}, :hold, "operator")
    task = Task.async(fn -> post(intake, @stop) end)
    await(fn -> if match?([%{hold: "held"}], rows(db)), do: {:ok, :held}, else: :not_yet end)
    refute_received {:asked, _}
    assert {:refused, :not_paused} = Intake.lift(intake, {:agent, "builder-1"})
    assert {:ok, :lifted} = Intake.lift(intake, {:project, "web"})
    assert reason(Task.await(task)) == "go on"
    assert_received {:asked, _}
  end

  test "a pause's own word answers at once, and an agent's goes before its project's",
       %{db: db, start: start} do
    intake = start_with(start, fn _ -> {:block, "from the app"} end)
    assert {:ok, :paused} = Intake.pause(intake, {:project, "web"}, :hold, "app")
    assert {:ok, :paused} = Intake.pause(intake, {:agent, "builder-1"}, {:block, "wait"}, "app")
    assert reason(post(intake, @stop)) == "wait"
    assert {:ok, :paused} = Intake.pause(intake, {:agent, "builder-1"}, :pass, "app")
    assert %{resp_body: ""} = post(intake, @stop)
    assert [%{actor: "pause"}, %{actor: "pause", hold: "passed"}] = rows(db)
    refute_received {:asked, _}
    assert {:refused, {:bad_pause, :later}} = Intake.pause(intake, {:agent, "a"}, :later, "app")
    assert {:refused, {:bad_scope, _}} = Intake.pause(intake, {:host, "a"}, :hold, "app")

    # A pause is a row: a restart keeps it.
    stop_supervised!(Intake)
    intake = start_with(start, fn _ -> {:block, "from the app"} end)
    assert %{resp_body: ""} = post(intake, @stop)
  end

  @tag capture_log: true
  test "at its deadline the Stop passes; a crashed callback passes", %{db: db, start: start} do
    intake = start_with(start, fn _ -> Process.sleep(60_000) end, stop_deadline: 50)
    assert %{status: 200, resp_body: ""} = post(intake, @stop)
    stop_supervised!(Intake)
    intake = start_with(start, fn _ -> raise "boom" end)
    assert %{status: 200, resp_body: ""} = post(intake, @stop)
    assert [%{hold: "expired"}, %{hold: "passed"}] = rows(db)
  end

  test "without a stop callback a Stop is stored and answered at once", %{db: db, start: start} do
    intake = start.([])
    assert %{status: 200, resp_body: ""} = post(intake, @stop)
    assert [%{event: "Stop", hold: nil}] = rows(db)
  end

  defp cap_row(db) do
    rows = rows(db)
    if Enum.any?(rows, &(&1.prompt == "stop_cap")), do: {:ok, rows}, else: :not_yet
  end

  defp await(fun) do
    case CodingAgentFramework.TestHost.await(fun) do
      {:ok, value} -> value
      other -> flunk("not reached: #{inspect(other)}")
    end
  end
end
