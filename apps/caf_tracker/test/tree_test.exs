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

    assert %{agents: [%{name: "m"}, %{name: "a-x", state: "starting"}, %{name: "a-y"} = y]} =
             Tree.agents(%{{"h", "agents"} => %{agents: rows}})

    assert y.state == "ended"
  end
end
