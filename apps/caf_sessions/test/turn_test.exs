defmodule CodingAgentFramework.Sessions.TurnTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Sessions.Turn

  doctest Turn

  @start "Tue Nov 17 09:00:00 2026"
  @main %{status: "running", role: "parent", pid: 7, proc_start: @start}
  @session_file %{pid: 7, proc_start: @start, alive: :live, status: "idle"}

  # F-113's new-2: one read is never the only sign that a turn ended, when it decides a write.
  test "an interactive turn has ended only when its file reads idle and its waiter is held" do
    assert Turn.interactive(@main, [@session_file], true) == :ended
    assert Turn.interactive(@main, [@session_file], false) == :idle
    assert Turn.interactive(@main, [@session_file], :unread) == :idle
    assert Turn.interactive(@main, [%{@session_file | status: "busy"}], true) == :running
    # A background command still runs after the turn ended (Claude Code 2.1.322, F-142).
    assert Turn.interactive(@main, [%{@session_file | status: "shell"}], true) == :running
    assert Turn.interactive(@main, [%{@session_file | status: "waiting"}], true) == :waiting
    assert Turn.interactive(@main, [%{@session_file | alive: :gone}], true) == :gone
    assert Turn.interactive(@main, [%{@session_file | status: "new"}], true) == :unread
    # Another process's file, by its pid or its start time, is not this session's.
    assert Turn.interactive(@main, [%{@session_file | pid: 8}], true) == :unread
    assert Turn.interactive(@main, [%{@session_file | proc_start: "Mon"}], true) == :unread
    assert Turn.interactive(%{@main | status: "stopping"}, [@session_file], true) == :not_running
  end

  test "a headless turn is its fold's: ended once the result is read" do
    row = %{status: "running", role: "delegate"}
    fold = %{idle: true, gone: false, ending: false, requests: %{}}
    assert Turn.headless(row, fold) == :ended
    assert Turn.headless(row, %{fold | idle: false}) == :running
    held = %{"r1" => %{state: :held}}
    assert Turn.headless(row, %{fold | idle: false, requests: held}) == :waiting
    assert Turn.headless(row, %{fold | ending: true}) == :ending
    assert Turn.headless(row, %{fold | gone: true}) == :gone
    assert Turn.headless(row, nil) == :unread
    assert Turn.headless(%{row | status: "stopping"}, fold) == :not_running
  end

  test "of/2 takes the function for the row's kind" do
    fold = %{idle: true, gone: false, ending: false}
    assert Turn.of(%{status: "running", role: "delegate"}, %{fold: fold}) == :ended
    assert Turn.of(@main, %{files: [@session_file], waiter: true}) == :ended
    assert Turn.of(@main, %{files: [@session_file]}) == :idle
  end
end
