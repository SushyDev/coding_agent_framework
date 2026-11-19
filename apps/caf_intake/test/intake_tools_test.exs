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

    # Each call's row is its hold's: a decision's names the app as its actor; a pass has none.
    assert [r1, r2, r3, r4] = rows(db)

    assert Enum.map([r1, r2, r3, r4], &{&1.key, &1.actor, &1.hold}) == [
             {"PreToolUse:s1:t1", "app", "answered"},
             {"PreToolUse:s1:t2", "app", "answered"},
             {"PreToolUse:s1:t3", "app", "answered"},
             {"PreToolUse:s1:t4", nil, "passed"}
           ]

    assert JSON.decode!(r2.decision)["hookSpecificOutput"]["permissionDecisionReason"] ==
             "not here"

    # A row keeps the tool's input only once a decision is taken (F-121's new-4).
    assert JSON.decode!(r1.data)["tool_input"] == %{"x" => 1}
    assert r4.data == nil
  end

  test "a correction: the input and the context go out, and the row keeps both",
       %{db: db, start: start} do
    answers = %{
      "t1" => {:allow, updated_input: %{"x" => 2}, additional_context: "`land` runs the gates."},
      "t2" => {:deny, "use land", additional_context: "Landing is `land`'s."},
      "t3" => {:allow, additional_context: "The tests take a minute."}
    }

    intake = start.(pre_tool_use: &answers[&1.tool_use_id])

    assert decision(post(intake, tool("PreToolUse", "t1"))) == %{
             "hookEventName" => "PreToolUse",
             "permissionDecision" => "allow",
             "updatedInput" => %{"x" => 2},
             "additionalContext" => "`land` runs the gates."
           }

    assert decision(post(intake, tool("PreToolUse", "t2"))) == %{
             "hookEventName" => "PreToolUse",
             "permissionDecision" => "deny",
             "permissionDecisionReason" => "use land",
             "additionalContext" => "Landing is `land`'s."
           }

    t3 = decision(post(intake, tool("PreToolUse", "t3")))
    assert t3["additionalContext"] == "The tests take a minute."
    refute Map.has_key?(t3, "updatedInput")

    assert [r1, r2, r3] = rows(db)
    assert Enum.map([r1, r2, r3], &{&1.actor, &1.hold}) == List.duplicate({"app", "answered"}, 3)
    # The row keeps what the agent asked and what the app sent in its place.
    assert JSON.decode!(r1.data)["tool_input"] == %{"x" => 1}
    assert JSON.decode!(r1.decision)["hookSpecificOutput"]["updatedInput"] == %{"x" => 2}
  end

  test "an answer out of shape is a pass, and its row names why", %{db: db, start: start} do
    long = String.duplicate("é", 10_001)

    answers = %{
      "t1" => {:allow, additional_context: long},
      "t2" => {:allow, updated_input: "x"},
      "t3" => {:deny, "no", updated_input: %{}},
      "t4" => {:allow, nope: 1},
      "t5" => {:allow, additional_context: String.duplicate("é", 10_000)}
    }

    intake = start.(pre_tool_use: &answers[&1.tool_use_id])

    for id <- ~w(t1 t2 t3 t4),
        do: assert(%{status: 200, resp_body: ""} = post(intake, tool("PreToolUse", id)))

    assert %{"additionalContext" => _} = decision(post(intake, tool("PreToolUse", "t5")))

    assert Enum.map(rows(db), &{&1.hold, &1.problem}) == [
             {"passed", ~s(["context_too_long",10001])},
             {"passed", ~s(["bad_answer","updated_input"])},
             {"passed", ~s(["bad_answer","updated_input"])},
             {"passed", ~s(["bad_answer","nope"])},
             {"answered", nil}
           ]
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

  test "a second post of a call that passed is answered empty, and asks no one",
       %{db: db, start: start} do
    intake = start.(pre_tool_use: telling(self(), fn _ -> :pass end))
    assert %{status: 200, resp_body: ""} = post(intake, tool("PreToolUse", "t1"))
    assert %{status: 200, resp_body: ""} = post(intake, tool("PreToolUse", "t1"))
    assert_received {:asked, _}
    refute_received {:asked, _}
    assert [%{hold: "passed"}] = rows(db)
  end

  test "the row says deciding before the decision is handed out", %{db: db, start: start} do
    # The decision's response is written by a stand-in for the plug, which reads the row first.
    intake = start.(pre_tool_use: fn _ -> :allow end)
    assert {:ok, {:held, id, ref, _}} = Intake.post(intake, "work", tool("PreToolUse", "t1"))
    assert_receive {^ref, {:decision, _}}, 5_000
    assert [%{id: ^id, hold: "deciding", actor: "app"}] = rows(db)
    Intake.written(intake, id, ref)
    :sys.get_state(intake)
    assert [%{hold: "answered"}] = rows(db)
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
    # The late answer reached the Intake before this call: it changed nothing and still serves.
    :sys.get_state(intake)
    assert [%{hold: "expired", decision: nil}] = rows(db)
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
    assert [%{hold: "passed"}, %{hold: "passed"}] = rows(db)
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

  test "a restart ends the open request with no decision, and its row is lost",
       %{db: db, start: start} do
    intake = start.(pre_tool_use: waiting(self()))
    task = Task.async(fn -> post(intake, tool("PreToolUse", "t1")) end)
    assert_receive {:asked, _, _}, 5_000
    stop_supervised!(Intake)
    assert %{status: 200, resp_body: ""} = Task.await(task)
    start.([])
    assert_receive %{topic: "intake:h:work", ids: [_]}, 5_000
    assert [%{hold: "lost"}] = rows(db)
  end

  test "a request that closes while held is lost, and the late decision dropped",
       %{db: db, start: start} do
    intake = start.(pre_tool_use: waiting(self()))
    # A stand-in for the plug that posts and goes, as a request cut while held does.
    spawn(fn -> Intake.post(intake, "work", tool("PreToolUse", "t1")) end)
    assert_receive {:asked, worker, _}, 5_000
    assert_receive %{topic: "intake:h:work"}, 5_000
    assert_receive %{topic: "intake:h:work"}, 5_000
    mon = Process.monitor(worker)
    send(worker, {:answer, :allow})
    assert_receive {:DOWN, ^mon, :process, _, :normal}, 5_000
    :sys.get_state(intake)
    assert [%{hold: "lost", decision: nil}] = rows(db)
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
