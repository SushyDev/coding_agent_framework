defmodule CodingAgentFramework.StreamFoldTest do
  @moduledoc "Properties of `Stream.Line`, the one encoder, and `Stream.Fold`, the event fold."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CodingAgentFramework.Stream.{Fold, Line}

  property "every message is one whole JSON line that decodes to its text" do
    check all(
            text <- one_of([string(:utf8), string(:printable), string([0..0x1F, 0x2028, 0x2029])])
          ) do
      {:ok, line} = Line.encode({:message, "u", text})
      assert one_line?(line)
      assert {:ok, %{"message" => %{"content" => ^text}, "uuid" => "u"}} = JSON.decode(line)
    end
  end

  property "an answer fits the pipe's atomic size, its message cut to fit" do
    check all(
            id <- string(:alphanumeric, max_length: 40),
            message <- string(:utf8, max_length: 700)
          ) do
      {:ok, line} = Line.encode({:answer, id, {:deny, message}})
      assert byte_size(line) <= Line.atomic() and one_line?(line)
      {:ok, %{"response" => %{"request_id" => ^id, "response" => r}}} = JSON.decode(line)
      assert String.starts_with?(message, r["message"])
    end
  end

  @empty %{text: "", subtype: nil, is_error: nil}

  test "a message's outcome: its result only once delivered and named by a result" do
    fold = Fold.mark(Fold.new(), {:message, "m1", "hi"}, "", 0)
    assert Fold.outcome(fold, "m2") == :none
    # A result before the replay: the message is not delivered yet, so no result is its.
    assert Fold.outcome(named(fold, ["m1"]), "m1") == :writing
    fold = Fold.event(fold, %{"type" => "user", "isReplay" => true, "uuid" => "m1"})
    assert Fold.outcome(named(fold, ["s1"]), "m1") == :delivered
    assert Fold.outcome(named(fold, ["s1", "m1"]), "m1") == {:result, @empty}
    gone = Fold.exit_seen(Fold.mark(Fold.new(), {:message, "m1", "hi"}, "", 0), fn _ -> false end)
    assert Fold.outcome(gone, "m1") == :undelivered
  end

  # Team.tla's ReplyNamesMessage: the fold keeps each result on the messages it names.
  test "a later result, a self-started turn's or the next message's, never replaces one" do
    fold =
      Fold.mark(Fold.new(), {:message, "m1", "hi"}, "", 0)
      |> Fold.event(%{"type" => "user", "isReplay" => true, "uuid" => "m1"})
      |> named(["m1"], %{"result" => "yes", "subtype" => "success", "is_error" => false})
      |> named([], %{"result" => "a turn of its own"})
      |> named(["m1"], %{"result" => "again"})
      |> Fold.mark({:message, "m2", "x"}, "", 0)
      |> Fold.event(%{"type" => "user", "isReplay" => true, "uuid" => "m2"})
      |> named(["m2"], %{"subtype" => "error_during_execution", "is_error" => true})

    assert Fold.outcome(fold, "m1") ==
             {:result, %{text: "yes", subtype: "success", is_error: false}}

    assert Fold.outcome(fold, "m2") ==
             {:result, %{text: "", subtype: "error_during_execution", is_error: true}}

    assert fold.last_result.subtype == "error_during_execution"
  end

  # Remedies.tla's BriefResult, TaskEnds, OwnInit and OwnResult, in the order measured on Claude
  # Code 2.1.322 (F-184): the result comes while the background command runs; its end starts a
  # turn of Claude Code's own with a new init, whose result is never the brief's. Between the
  # end and the init the fold is waking: nothing is written (F-204, NoMessageIntoOwnTurn).
  test "a background command's end starts a turn of its own, which is never the brief's" do
    task = %{"task_id" => "t1", "run_id" => "r1", "task_type" => "local_bash"}
    changed = &%{"type" => "system", "subtype" => "background_tasks_changed", "tasks" => &1}
    init = %{"type" => "system", "subtype" => "init", "session_id" => "s1"}

    fold =
      Fold.mark(Fold.new(), {:message, "b1", "brief"}, "", 0)
      |> Fold.event(init)
      |> Fold.event(%{"type" => "user", "isReplay" => true, "uuid" => "b1"})
      |> Fold.event(Map.merge(%{"type" => "system", "subtype" => "task_started"}, task))
      |> Fold.event(changed.([task]))
      |> named(["b1"], %{"result" => "report", "uuid" => "r-b1"})

    assert {fold.idle, Map.keys(fold.tasks), fold.background} ==
             {true, ["t1"], %{tasks: ["t1"], changes: 1}}

    ended =
      fold
      |> Fold.event(%{"type" => "system", "subtype" => "task_updated", "task_id" => "t1"})
      |> Fold.event(%{"type" => "system", "subtype" => "task_notification", "task_id" => "t1"})
      |> Fold.event(changed.([]))

    assert {ended.idle, ended.waking, ended.tasks, ended.background} ==
             {false, %{at: nil}, %{}, %{tasks: [], changes: 2}}

    assert Fold.check(ended, {:message, "m1", "hi"}) == {:refused, :turn_running}
    # The read that saw the end stamps it; a later read keeps that time.
    assert Fold.stamp(Fold.stamp(ended, 5), 9).waking == %{at: 5}

    # Its init: a turn runs, so nothing is written into it until its result.
    own = Fold.event(Fold.stamp(ended, 5), init)

    assert {own.idle, own.waking, Fold.check(own, {:message, "m1", "hi"})} ==
             {false, nil, {:refused, :turn_running}}

    # Past the bound, a fold whose init came is not changed.
    assert Fold.unwake(own, 1_000_000, 1) == own

    own = named(own, [], %{"result" => "the command ended", "uuid" => "r-own"})
    assert own.idle
    assert Fold.outcome(own, "b1") == {:result, %{text: "report", subtype: nil, is_error: nil}}
    assert [%{uuid: "r-own", text: "the command ended"}] = own.own
  end

  # Remedies.tla's CommandEnds and Unwake (F-204): an end while a turn runs joins it; an end
  # with no init after it reads the turn ended again past the bound, counted in `unwoken`.
  test "a command's end waits for its init only while the turn reads ended, and for a bound" do
    init = %{"type" => "system", "subtype" => "init", "session_id" => "s1"}
    note = %{"type" => "system", "subtype" => "task_notification", "task_id" => "t1"}

    running =
      Fold.mark(Fold.new(), {:message, "b1", "brief"}, "", 0)
      |> Fold.event(init)
      |> Fold.event(%{"type" => "user", "isReplay" => true, "uuid" => "b1"})

    # Into a running turn: no turn of its own is coming, and its result ends the turn.
    joined = Fold.event(running, note)
    assert {joined.idle, joined.waking} == {false, nil}
    assert named(joined, ["b1"], %{"result" => "r"}).idle

    # Before any init, no process has started a turn: nothing is waking.
    assert Fold.event(Fold.new(), note).waking == nil

    waking = running |> named(["b1"], %{"result" => "r"}) |> Fold.event(note) |> Fold.stamp(100)
    assert Fold.unwake(waking, 1_099, 1_000) == waking
    unwoken = Fold.unwake(waking, 1_100, 1_000)
    assert {unwoken.idle, unwoken.waking, unwoken.unwoken} == {true, nil, 1}
    assert Fold.check(unwoken, {:message, "m1", "hi"}) == :ok

    # An exit or a follow again ends the wait.
    assert Fold.exit_seen(waking, fn _ -> false end).waking == nil
    assert Fold.again(waking).waking == nil
  end

  # Team.tla's fold[i] = "exited": delivered, its turn begun, the process gone with no result.
  test "a delivered message no result named is exited at the exit; one answered is not" do
    fold =
      Fold.mark(Fold.new(), {:message, "m1", "hi"}, "", 0)
      |> Fold.event(%{"type" => "user", "isReplay" => true, "uuid" => "m1"})
      |> named(["m1"])
      |> Fold.mark({:message, "m2", "x"}, "", 0)

    assert Fold.outcome(fold, "m2") == :writing
    # The transcript holds m2: it went in, and the process ended during its turn.
    gone = Fold.exit_seen(fold, &(&1 == "m2"))
    assert {Fold.outcome(gone, "m1"), Fold.outcome(gone, "m2")} == {{:result, @empty}, :exited}
    # A resume keeps it, and a second settle of the exit changes nothing.
    again = Fold.again(gone)
    assert Fold.outcome(again, "m2") == :exited
    assert Fold.exit_seen(gone, fn _ -> false end).messages == gone.messages
    assert :ok = Fold.check(again, {:message, "m3", ""})
  end

  defp named(fold, uuids, fields \\ %{}),
    do: Fold.event(fold, Map.merge(%{"type" => "result", "user_message_uuids" => uuids}, fields))

  test "a line that is not text, or not a line, is refused" do
    assert {:refused, :not_utf8} = Line.encode({:message, "u", <<0xFF>>})
    assert {:refused, :bad_line} = Line.encode({:message, "u", 7})
  end

  property "reads at any cut points fold each whole line once, as one read does" do
    check all(events <- list_of(event(), max_length: 30), cuts <- list_of(integer(0..2_000))) do
      log = Enum.map_join(events, &(JSON.encode!(&1) <> "\n"))
      sizes = cuts |> Enum.map(&min(&1, byte_size(log))) |> Enum.sort()

      folded =
        Enum.reduce(sizes ++ [byte_size(log)], marked(), fn size, fold ->
          Fold.take(fold, binary_part(log, fold.offset, max(size - fold.offset, 0)))
        end)

      assert folded == Fold.take(marked(), log)

      assert {folded.offset, folded.events, folded.problems} ==
               {byte_size(log), length(events), 0}
    end
  end

  property "a row moves only along the spec's arrows" do
    check all(events <- list_of(event(), max_length: 40)) do
      fold = Enum.reduce(events, marked(), &Fold.event(&2, &1))
      replayed = for %{"isReplay" => true, "uuid" => u} <- events, do: u

      for {u, m} <- fold.messages,
          do: assert(m.state == if(u in replayed, do: :delivered, else: :writing))

      for {id, r} <- fold.requests do
        canceled? =
          Enum.any?(events, &(&1["type"] == "control_cancel_request" and &1["request_id"] == id))

        assert r.state == :held or (r.state == :canceled and canceled?)
      end

      gone = Fold.exit_seen(fold, &(&1 == "m1"))
      assert Enum.all?(gone.requests, fn {_, r} -> r.state in [:canceled, :lost] end)
      assert Enum.all?(gone.messages, fn {_, m} -> m.state in [:delivered, :undelivered] end)
    end
  end

  test "an answer's replay answers only a request being answered, by its id" do
    fold =
      Fold.new()
      |> Fold.event(request("r1"))
      |> Fold.event(request("r2"))
      |> Fold.mark({:answer, "r2", :allow}, "x\n", 0)
      |> Fold.event(%{
        "type" => "control_response",
        "isReplay" => true,
        "response" => %{"request_id" => "r2"}
      })

    assert {fold.requests["r1"].state, fold.requests["r2"].state} == {:held, :answered}
    assert {:refused, {:request, :answered}} = Fold.check(fold, {:answer, "r2", :allow})
  end

  test "a follow again ends the turn, names the next FIFO and clears an end" do
    fold =
      Fold.new()
      |> Fold.mark({:message, "m1", ""}, "x\n", 0)
      |> Fold.exit_seen(fn _ -> true end)

    # Mark: the write's live check saw the process; the exit left the turn running (new-6).
    assert %{live_seen: true, idle: false, gone: true} = fold
    again = Fold.again(fold)
    assert {Fold.fifo(fold), Fold.fifo(again)} == {"in.0", "in.1"}
    assert %{idle: true, gone: false, live_seen: false, session_id: nil} = again
    assert :ok = Fold.check(again, {:message, "m2", ""})

    ended = Fold.mark(again, {:end_session, "e1"}, "x\n", 0)
    assert {:refused, :ending} = Fold.check(ended, {:message, "m2", ""})
    assert {:refused, :ending} = Fold.check(ended, {:end_session, "e2"})
    assert :ok = Fold.check(Fold.again(%{ended | gone: true}), {:message, "m2", ""})
  end

  test "an end waits for a message under way or found undelivered; a used uuid is refused" do
    writing = Fold.mark(Fold.new(), {:message, "m1", ""}, "x\n", 0) |> Map.put(:idle, true)
    assert {:refused, :message_waiting} = Fold.check(writing, {:end_session, "e1"})
    assert {:refused, :duplicate_uuid} = Fold.check(writing, {:message, "m1", ""})

    lost = writing |> Fold.exit_seen(fn _ -> false end) |> Fold.again()
    assert {:refused, {:undelivered, "m1"}} = Fold.check(lost, {:end_session, "e1"})
    resent = Fold.mark(lost, {:message, "m1", ""}, "x\n", 0)
    assert resent.messages["m1"].state == :writing
  end

  test "a told hold sees the process, unless its exit is already seen" do
    assert Fold.held(Fold.new()).live_seen
    refute Fold.held(%{Fold.new() | gone: true}).live_seen
  end

  # Two messages marked as writing, so replays have rows to settle.
  defp marked do
    Fold.new()
    |> Fold.mark({:message, "m1", ""}, "x\n", 0)
    |> Map.put(:idle, true)
    |> Fold.mark({:message, "m2", ""}, "x\n", 0)
  end

  defp request(id),
    do: %{
      "type" => "control_request",
      "request_id" => id,
      "request" => %{"subtype" => "can_use_tool"}
    }

  defp event do
    id = member_of(["m1", "m2", "r1", "r2"])

    one_of([
      map(id, &%{"type" => "user", "isReplay" => true, "uuid" => &1}),
      constant(%{"type" => "result", "user_message_uuids" => ["m1"]}),
      map(id, &request/1),
      map(id, &%{"type" => "control_cancel_request", "request_id" => &1}),
      map(
        id,
        &%{"type" => "control_response", "response" => %{"request_id" => &1}}
      ),
      constant(%{
        "type" => "assistant",
        "message" => %{"content" => "line\nbreak " <> <<0x2028::utf8>> <> ""}
      }),
      constant(%{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => "allowed"}})
    ])
  end

  defp one_line?(line) do
    String.ends_with?(line, "\n") and
      not String.contains?(binary_part(line, 0, byte_size(line) - 1), ["\n", "\r"]) and
      not String.contains?(line, [<<0x2028::utf8>>, <<0x2029::utf8>>]) and
      not Enum.any?(:binary.bin_to_list(line, 0, byte_size(line) - 1), &(&1 < 0x20))
  end
end
