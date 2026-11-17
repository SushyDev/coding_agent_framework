defmodule CodingAgentFramework.Tracker.TreeTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Tracker.Tree

  doctest Tree

  @main %{id: 1, host: "h", name: "m", kind: "main", parent: nil, project: "a", account: "w"}

  test "a row of the wrong shape is named, and the others still show" do
    m = Map.merge(@main, %{status: "running", session_id: nil})
    d = %{id: 2, host: "h", name: "a-x", kind: "delegate", parent: "m", project: "a"}
    d = Map.merge(d, %{account: "w", status: "running", session_id: "s"})
    rows = [%{key: 1, row: m}, %{key: 2, row: d}, %{key: 3, row: %{d | id: "two"}}]
    rows = rows ++ [%{key: 4, row: :j}, :j]
    stream = [%{key: 1, row: %{session: "s", requests: :junk, idle: true}}]
    stream = %{stream: stream, sources: %{"stream:h" => %{age: :unread}}}
    view = %{{"h", "agents"} => %{agents: rows}, {"h", "stream"} => stream, :j => :j}

    assert %{agents: [_, %{state: "idle"}], problems: [%{key: 3}], sources: s} = Tree.agents(view)
    assert s == %{"stream:h" => :unread}
  end

  test "a delegate that ended keeps its place, as ended; a starting one says so" do
    m = Map.merge(@main, %{status: "declared", session_id: nil})
    d = %{id: 2, host: "h", name: "a-x", kind: "delegate", parent: "m", project: "a"}
    d = Map.merge(d, %{account: "w", status: "starting", session_id: "s"})
    gone = %{d | id: 3, name: "a-y", status: "ended"}
    rows = for {r, k} <- Enum.with_index([m, d, gone]), do: %{key: k, row: r}

    view = %{{"h", "agents"} => %{agents: rows}}

    assert %{agents: [%{name: "m", state: "gone"}, %{name: "a-x", state: "starting"}]} =
             Tree.agents(view)

    assert %{agents: [%{name: "m"}, %{name: "a-x"}, %{name: "a-y"} = y]} =
             Tree.agents(view, all: true)

    assert y.state == "ended"
  end

  # One read of the session file, for a person to see; the view holds no waiter.
  test "a main session's state is its session file's, by its pid and start time" do
    start = "Tue Nov 17 09:00:00 2026"
    m = Map.merge(@main, %{status: "running", session_id: "s0", pid: 7, proc_start: start})
    file = %{account: "w", host: "h", pid: 7, proc_start: start, alive: :live, status: "busy"}
    other = %{file | pid: 8, status: "idle"}
    files = %{sessions: [%{key: 1, row: other}, %{key: 2, row: file}]}
    view = %{{"h", "agents"} => %{agents: [%{key: 1, row: m}]}, {"h", "w"} => files}

    assert %{agents: [%{name: "m", state: "working", subagents: []}]} = Tree.agents(view)

    idle = put_in(view, [{"h", "w"}, :sessions], [%{key: 2, row: %{file | status: "idle"}}])
    assert %{agents: [%{state: "idle"}]} = Tree.agents(idle)

    assert %{agents: [%{state: "unread"}]} = Tree.agents(Map.delete(view, {"h", "w"}))
  end
end
