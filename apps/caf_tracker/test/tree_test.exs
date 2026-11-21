defmodule CodingAgentFramework.Tracker.TreeTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Tracker.{Fold, Tree}

  doctest Tree

  @main %{id: 1, host: "h", name: "m", kind: "main", parent: nil, project: "a", account: "w"}

  test "a row of the wrong shape is named, and the others still show" do
    m = Map.merge(@main, %{status: "running", session_id: nil})

    d = %{
      id: 2,
      host: "h",
      name: "a-x",
      kind: "delegate",
      role: "delegate",
      parent: "m",
      project: "a"
    }

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

    d = %{
      id: 2,
      host: "h",
      name: "a-x",
      kind: "delegate",
      role: "delegate",
      parent: "m",
      project: "a"
    }

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

  # One read of the session file, for a person to see; the view holds no waiter. The files are
  # the `Registry` rows as the fold shows them (F-153's new-6: a view drawn in another shape
  # read every main session `unread` in the first end-to-end run). An interactive delegate is
  # read by its file too, as it has no `Stream` row.
  test "a main session's and an interactive delegate's state is their session file's" do
    start = "Tue Nov 17 09:00:00 2026"
    m = Map.merge(@main, %{status: "running", session_id: "s0", pid: 7, proc_start: start})
    d = %{id: 2, host: "h", name: "a-x", kind: "delegate", role: "parent", parent: "m"}
    d = Map.merge(d, %{project: "a", account: "w", status: "running", session_id: "s1"})
    d = Map.merge(d, %{pid: 9, proc_start: "Tue Nov 17 09:05:00 2026"})
    file = %{id: 1, host: "h", account: "w", pid: 7, proc_start: start, alive: :live}

    files = [
      %{file | id: 2, pid: 8},
      %{file | id: 1},
      %{file | id: 3, pid: 9, proc_start: d.proc_start}
    ]

    agents = %{agents: [%{key: 1, row: m}, %{key: 2, row: d}]}

    view = fn statuses ->
      rows = Enum.zip_with(files, statuses, &Map.put(&1, :status, &2))

      {fold, _} =
        Fold.new()
        |> Fold.source("registry:h:w", {"h", "w"}, :sessions)
        |> Fold.read("registry:h:w", :all, {:ok, %{read_at: 1, rows: rows}})

      Map.put(Fold.view(fold, 2), {"h", "agents"}, agents)
    end

    assert %{
             agents: [
               %{name: "m", state: "working", subagents: []},
               %{name: "a-x", state: "idle"}
             ]
           } =
             Tree.agents(view.(["idle", "busy", "idle"]))

    assert %{agents: [%{state: "idle"}, %{state: "waiting"}]} =
             Tree.agents(view.(["busy", "idle", "waiting"]))

    assert %{agents: [%{state: "unread"}, %{state: "unread"}]} =
             Tree.agents(%{{"h", "agents"} => agents})
  end

  # F-180: no session file exists while a startup dialog is shown, so a builder on one read as
  # `unread`; its row says `dialog`, and the view says so, with the dialog it waits on.
  test "a session on a startup dialog is `dialog`, never idle, and names the dialog" do
    m = Map.merge(@main, %{status: "running", session_id: "s0"})
    d = %{id: 2, host: "h", name: "a-x", kind: "delegate", role: "parent", parent: "m"}

    shown =
      ~s({"kind":"trust","options":["No, exit","Yes, I trust this folder"],"selected":"No, exit"})

    d = Map.merge(d, %{project: "a", account: "w", status: "dialog", session_id: nil})
    d = Map.merge(d, %{dialog: shown, answers: nil})
    view = %{{"h", "agents"} => %{agents: [%{key: 1, row: m}, %{key: 2, row: d}]}}

    assert %{agents: [_, %{name: "a-x", state: "dialog", waits_on: [waits]}]} = Tree.agents(view)
    assert waits == %{dialog: :trust, options: ["No, exit", "Yes, I trust this folder"]}

    # A row whose dialog cannot be read still says `dialog`.
    rows = [%{key: 1, row: m}, %{key: 2, row: %{d | dialog: "x"}}]
    view = put_in(view, [{"h", "agents"}, :agents], rows)
    assert %{agents: [_, %{state: "dialog", waits_on: []}]} = Tree.agents(view)
  end
end
