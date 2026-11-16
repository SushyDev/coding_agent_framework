defmodule CodingAgentFramework.IntakeToolsTest do
  @moduledoc "PreToolUse and PostToolUse: the app's callbacks, the deadline, and the rows."
  use ExUnit.Case, async: true

  import CodingAgentFramework.IntakeSetup

  alias CodingAgentFramework.Intake

  setup {CodingAgentFramework.IntakeSetup, :intake}

  defp tool(event, id, tool \\ "Bash"),
    do: body(event, %{"tool_use_id" => id, "tool_name" => tool, "tool_input" => %{"x" => 1}})

  defp decision(conn) do
    assert conn.status == 200
    JSON.decode!(conn.resp_body)["hookSpecificOutput"]
  end

  # A callback that tells the test each event it is asked, and answers by `answer`.
  defp telling(me, answer) do
    fn event ->
      send(me, {:asked, event})
      answer.(event)
    end
  end

  # A callback that tells the test it runs, then waits for the test's answer.
  defp waiting(me) do
    fn event ->
      send(me, {:asked, self(), event})

      receive do
        {:answer, answer} -> answer
      end
    end
  end

  test "each answer of the callback, its response, and its row", %{db: db, start: start} do
    answers = %{"t1" => :allow, "t2" => {:deny, "not here"}, "t3" => :ask, "t4" => :pass}
    callback = telling(self(), &answers[&1.tool_use_id])
    intake = start.(pre_tool_use: callback, agent: fn "work", "s1" -> "builder-1" end)

    assert %{"permissionDecision" => "allow"} =
             allow = decision(post(intake, tool("PreToolUse", "t1")))

    refute Map.has_key?(allow, "permissionDecisionReason")

    assert %{"permissionDecision" => "deny", "permissionDecisionReason" => "not here"} =
             decision(post(intake, tool("PreToolUse", "t2")))

    assert %{"permissionDecision" => "ask"} = decision(post(intake, tool("PreToolUse", "t3")))
    assert %{status: 200, resp_body: ""} = post(intake, tool("PreToolUse", "t4"))

    assert_received {:asked, event}

    assert event == %{
             agent: "builder-1",
             account: "work",
             session_id: "s1",
             tool_name: "Bash",
             tool_input: %{"x" => 1},
             tool_use_id: "t1"
           }

    # A pass writes no row; each decision's row names the app as its actor.
    assert [r1, r2, r3] = rows(db)

    assert Enum.map([r1, r2, r3], &{&1.key, &1.actor, &1.hold}) == [
             {"PreToolUse:s1:t1", "app", nil},
             {"PreToolUse:s1:t2", "app", nil},
             {"PreToolUse:s1:t3", "app", nil}
           ]

    assert JSON.decode!(r2.decision)["hookSpecificOutput"]["permissionDecisionReason"] ==
             "not here"
  end

  test "a second post of one call answers the row's decision, and asks no one",
       %{db: db, start: start} do
    intake = start.(pre_tool_use: telling(self(), fn _ -> {:deny, "no"} end))
    first = post(intake, tool("PreToolUse", "t1"))
    assert post(intake, tool("PreToolUse", "t1")).resp_body == first.resp_body
    assert_received {:asked, _}
    refute_received {:asked, _}
    assert [%{actor: "app"}] = rows(db)
  end

  test "at the deadline the response is empty, and a later decision is dropped",
       %{db: db, start: start} do
    intake = start.(pre_tool_use: waiting(self()), tool_deadline: 50)
    task = Task.async(fn -> post(intake, tool("PreToolUse", "t1")) end)
    assert_receive {:asked, worker, _}, 5_000
    assert %{status: 200, resp_body: ""} = Task.await(task)

    mon = Process.monitor(worker)
    send(worker, {:answer, {:deny, "late"}})
    assert_receive {:DOWN, ^mon, :process, _, :normal}, 5_000
    # The late answer reached the Intake before this call: it wrote nothing and still serves.
    :sys.get_state(intake)
    assert rows(db) == []
    assert Process.alive?(intake)
  end

  @tag capture_log: true
  test "a crash or an exit of the callback answers an empty body", %{db: db, start: start} do
    callback = fn
      %{tool_use_id: "t1"} -> raise "boom"
      %{tool_use_id: "t2"} -> exit(:gone)
    end

    intake = start.(pre_tool_use: callback)
    assert %{status: 200, resp_body: ""} = post(intake, tool("PreToolUse", "t1"))
    assert %{status: 200, resp_body: ""} = post(intake, tool("PreToolUse", "t2"))
    assert rows(db) == []
  end

  test "a slow callback blocks neither the Intake nor another call", %{start: start} do
    me = self()
    slow = waiting(me)
    callback = fn e -> if e.tool_use_id == "t1", do: slow.(e), else: :allow end
    intake = start.(pre_tool_use: callback)
    task = Task.async(fn -> post(intake, tool("PreToolUse", "t1")) end)
    assert_receive {:asked, worker, _}, 5_000
    assert %{"permissionDecision" => "allow"} = decision(post(intake, tool("PreToolUse", "t2")))
    assert {:ok, :stored} = Intake.post(intake, "work", body("Stop"))
    send(worker, {:answer, :allow})
    assert %{"permissionDecision" => "allow"} = decision(Task.await(task))
  end

  test "a restart ends the open request with no decision", %{db: db, start: start} do
    intake = start.(pre_tool_use: waiting(self()))
    task = Task.async(fn -> post(intake, tool("PreToolUse", "t1")) end)
    assert_receive {:asked, _, _}, 5_000
    stop_supervised!(Intake)
    assert %{status: 200, resp_body: ""} = Task.await(task)
    assert rows(db) == []
  end

  test "a PostToolUse is answered at once and handed on, with no row", %{db: db, start: start} do
    me = self()
    intake = start.(post_tool_use: &send(me, {:after, &1}))
    body = JSON.encode!(Map.put(JSON.decode!(tool("PostToolUse", "t1")), "tool_response", "ok"))
    assert %{status: 200, resp_body: ""} = post(intake, body)
    assert_receive {:after, %{tool_use_id: "t1", tool_response: "ok", agent: nil}}, 5_000
    assert rows(db) == []
  end

  test "with no callback a tool event is answered empty and stored nowhere",
       %{db: db, start: start} do
    intake = start.([])
    assert %{status: 200, resp_body: ""} = post(intake, tool("PreToolUse", "t1"))
    assert %{status: 200, resp_body: ""} = post(intake, tool("PostToolUse", "t1"))
    assert rows(db) == []
  end
end
