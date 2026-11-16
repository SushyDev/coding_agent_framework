defmodule CodingAgentFramework.Tracker.TreeTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Tracker.Tree

  test "a row of the wrong shape is named, and the others still show" do
    d = %{id: 1, host: "h", name: "a-x", parent: "m", project: "a", account: "w"}
    d = Map.merge(d, %{status: "running", session_id: "s"})
    delegates = [%{key: 1, row: d}, %{key: 2, row: %{d | id: "two"}}, %{key: 3, row: :j}, :j]
    stream = [%{key: 1, row: %{session: "s", requests: :junk, idle: true}}]
    stream = %{stream: stream, sources: %{"stream:h" => %{age: :unread}}}
    view = %{{"h", "delegates"} => %{delegates: delegates}, {"h", "stream"} => stream, :j => :j}

    assert %{agents: [_, %{state: "idle"}], problems: [%{key: 2}], sources: s} = Tree.agents(view)
    assert s == %{"stream:h" => :unread}
  end
end
