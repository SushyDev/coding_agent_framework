defmodule CodingAgentFramework.Tracker.ToolsTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Tracker
  alias CodingAgentFramework.Tracker.Tree
  alias CodingAgentFramework.Transcripts.Fold

  # Lines of the shape Claude Code 2.1.322 writes for a tool call (recorded in F-235, with the
  # session's own fields cut): the assistant line with the `tool_use` block, and the user line
  # with its `tool_result`. A subagent's lines carry `isSidechain: true` and its `agentId`.
  defp use_line(id, name, at, side \\ %{}) do
    JSON.encode!(
      Map.merge(
        %{
          type: "assistant",
          isSidechain: false,
          timestamp: at,
          message: %{
            id: "msg-" <> id,
            role: "assistant",
            stop_reason: "tool_use",
            content: [%{type: "tool_use", id: id, name: name, input: %{}, caller: %{}}]
          }
        },
        side
      )
    ) <> "\n"
  end

  defp result_line(id, at, side \\ %{}) do
    JSON.encode!(
      Map.merge(
        %{
          type: "user",
          isSidechain: false,
          timestamp: at,
          toolUseResult: %{},
          message: %{
            role: "user",
            content: [%{type: "tool_result", tool_use_id: id, content: "ok", is_error: false}]
          }
        },
        side
      )
    ) <> "\n"
  end

  defp sub(agent), do: %{isSidechain: true, agentId: agent}

  # Folds a subagent's whole `file` as a read from where its fold stopped gives it.
  defp more(fold, agent, file) do
    from = Fold.file_read_from(fold, agent)
    {:ok, fold} = Fold.take_file(fold, agent, binary_part(file, from, byte_size(file) - from))
    fold
  end

  defp fold(bytes) do
    {:ok, fold} = Fold.take(Fold.new(), bytes)
    fold
  end

  # The transcript's row as `Transcripts.Table` loads it: its fold's fields beside its own.
  defp transcript(fold),
    do: Map.merge(%{id: 1, account: "w", session_id: "s"}, Map.drop(fold, [:seam, :message]))

  @agent %{
    id: 2,
    host: "h",
    name: "a-x",
    kind: "delegate",
    role: "delegate",
    parent: "m",
    project: "a",
    account: "w",
    status: "running",
    session_id: "s"
  }

  defp view(fold, opts \\ []) do
    stream = %{session: "s", gone: false, idle: Keyword.get(opts, :idle, false), requests: %{}}
    hook = %{id: 9, account: "w", session_id: "s", written_at: Keyword.get(opts, :hook, 0)}

    %{
      {"h", "agents"} => %{agents: [%{key: 2, row: @agent}]},
      {"h", "stream"} => %{stream: [%{key: 1, row: stream}]},
      {"h", "w"} => %{
        transcripts: [%{key: 1, row: transcript(fold)}],
        events: [%{key: 9, row: hook}]
      }
    }
  end

  @t0 "2026-11-23T09:00:00.000Z"
  @t1 "2026-11-23T09:00:02.500Z"
  @t2 "2026-11-23T09:00:03.000Z"
  @t3 "2026-11-23T09:00:04.000Z"

  defp ms(stamp),
    do: stamp |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix(:millisecond)

  test "a call that starts and ends has its time; one still running is the agent's tool" do
    bytes =
      use_line("tu-1", "Bash", @t0) <> result_line("tu-1", @t1) <> use_line("tu-2", "Read", @t2)

    fold = fold(bytes)

    assert [read, bash] = fold.tools
    assert %{id: "tu-1", name: "Bash", ended_at: ended, ms: 2500} = bash
    assert ended == ms(@t1)
    assert %{id: "tu-2", name: "Read", ended_at: nil, ms: nil} = read

    assert %{agents: [row]} = Tree.agents(view(fold, hook: 0))
    assert row.state == "working"
    assert row.tool == %{id: "tu-2", name: "Read", started_at: ms(@t2)}
    assert row.last_event_at == ms(@t2)

    # A newer hook event is the agent's last; an agent that is not working runs no tool.
    assert %{agents: [%{last_event_at: 99_999_999_999_999}]} =
             Tree.agents(view(fold, hook: 99_999_999_999_999))

    assert %{agents: [%{state: "idle", tool: nil}]} = Tree.agents(view(fold, idle: true))

    # Once it ends, the agent runs none.
    fold = fold(bytes <> result_line("tu-2", @t3))
    assert %{agents: [%{tool: nil, last_event_at: last}]} = Tree.agents(view(fold))
    assert last == ms(@t3)
    assert {:ok, [%{id: "tu-2", ms: 1000}, %{id: "tu-1"}]} = Tree.tool_calls(view(fold), "a-x")
  end

  test "a subagent's calls are its own, under its agent id, never the parent's" do
    bytes =
      use_line("tu-1", "Agent", @t0) <>
        use_line("tu-9", "Grep", @t1, sub("ag-1")) <>
        result_line("tu-9", @t2, sub("ag-1")) <>
        use_line("tu-8", "Read", @t2, sub("ag-1"))

    fold = fold(bytes)

    assert [%{id: "tu-1", name: "Agent"}] = fold.tools
    assert %{"ag-1" => [%{id: "tu-8", ended_at: nil}, %{id: "tu-9", ms: 500}]} = fold.agent_tools
    # The subagent's entries do not move the parent's last event.
    assert fold.last_event_at == ms(@t0)

    view = view(fold)
    assert %{agents: [%{tool: %{name: "Agent"}}]} = Tree.agents(view)
    assert {:ok, [%{name: "Agent"}]} = Tree.tool_calls(view, "a-x")
    assert {:ok, [%{id: "tu-8"}, %{id: "tu-9"}]} = Tree.tool_calls(view, "ag-1")
    assert {:refused, :unknown_agent} = Tree.tool_calls(view, "nobody")
  end

  test "a running subagent from its own file: its agent id, its tool, and its calls (F-237)" do
    # The parent's foreground `Agent` call, as 2.1.322 writes it, with no result yet.
    agent_call =
      JSON.encode!(%{
        type: "assistant",
        timestamp: @t0,
        message: %{
          id: "msg-a",
          content: [
            %{
              type: "tool_use",
              id: "tu-1",
              name: "Agent",
              input: %{subagent_type: "Explore", description: "look"}
            }
          ]
        }
      }) <> "\n"

    own = use_line("tu-9", "Grep", @t1, sub("ag-1"))
    {:ok, fold} = Fold.take_file(fold(agent_call), "ag-1", own)
    {:ok, fold} = Fold.file_meta(fold, "ag-1", ~s({"toolUseId":"tu-1","agentType":"Explore"}))

    view = view(fold)
    assert %{agents: [%{tool: %{name: "Agent"}, subagents: [s]}]} = Tree.agents(view)

    assert %{agent_id: "ag-1", type: "Explore", description: "look", state: :open} = s
    assert s.tool == %{id: "tu-9", name: "Grep", started_at: ms(@t1)}
    assert {:ok, [%{id: "tu-9"}]} = Tree.tool_calls(view, "ag-1")
    assert {:ok, [%{id: "tu-1", name: "Agent"}]} = Tree.tool_calls(view, "a-x")

    # Once its call ends it runs none; once the subagent ends, neither.
    file = own <> result_line("tu-9", @t2, sub("ag-1"))
    fold = more(fold, "ag-1", file)
    assert %{agents: [%{subagents: [%{tool: nil}]}]} = Tree.agents(view(fold))

    fold = more(fold, "ag-1", file <> use_line("tu-7", "Read", @t3, sub("ag-1")))
    ended = put_in(fold, [:subagents, "tu-1", :state], :ended)
    assert %{agents: [%{subagents: [%{tool: nil}]}]} = Tree.agents(view(ended))
    assert %{agents: [%{subagents: [%{tool: %{id: "tu-7"}}]}]} = Tree.agents(view(fold))
  end

  test "a subagent whose file was not read, it having finished first, says so (F-237)" do
    call =
      JSON.encode!(%{
        type: "assistant",
        timestamp: @t0,
        message: %{
          id: "msg-a",
          content: [%{type: "tool_use", id: "tu-1", name: "Agent", input: %{}}]
        }
      }) <> "\n"

    {:ok, fold} = Fold.file_meta(fold(call), "ag-1", ~s({"toolUseId":"tu-1","finished":true}))
    fold = Fold.skip_file(fold, "ag-1", 5_000_000)
    view = view(fold)

    assert %{agents: [%{subagents: [s]}]} = Tree.agents(view)
    assert %{agent_id: "ag-1", not_read: :finished, partial: false, tool: nil} = s
    assert {:refused, {:not_read, :finished}} = Tree.tool_calls(view, "ag-1")
  end

  test "a partial first read shows the call it runs now, and a subagent started before the cut (F-244)" do
    # The `Agent` call is before the cut; only the last call and its subagent's file are read.
    before = use_line("tu-a", "Agent", @t0) <> use_line("tu-1", "Bash", @t1)
    file = before <> result_line("tu-1", @t2) <> use_line("tu-2", "Read", @t3)
    at = byte_size(before) + 3
    {:ok, fold} = Fold.take_from(at, binary_part(file, at, byte_size(file) - at))
    meta = ~s({"toolUseId":"tu-a","agentType":"Explore","description":"look"})
    {:ok, fold} = Fold.file_meta(fold, "ag-1", meta)
    fold = more(fold, "ag-1", use_line("tu-7", "Grep", @t3, sub("ag-1")))

    assert %{agents: [row]} = Tree.agents(view(fold))
    assert %{partial: true, tool: %{id: "tu-2", name: "Read"}} = row

    assert [%{agent_id: "ag-1", type: "Explore", description: "look", tool: %{id: "tu-7"}}] =
             row.subagents

    assert %{"tu-a" => %{started_at: nil}} = fold.subagents
    assert {:ok, [%{id: "tu-2"}]} = Tree.tool_calls(view(fold), "a-x")

    # A whole read is not partial.
    assert %{agents: [%{partial: false}]} = Tree.agents(view(fold(file)))
  end

  test "the bound holds: at most 200 calls per agent, and limit: answers fewer" do
    bytes =
      for i <- 1..250, into: "" do
        use_line("tu-#{i}", "Bash", @t0) <> result_line("tu-#{i}", @t1)
      end

    fold = fold(bytes)
    assert length(fold.tools) == 200
    assert hd(fold.tools).id == "tu-250"
    assert Enum.all?(fold.tools, &(&1.ms == 2500))

    view = view(fold)
    assert {:ok, calls} = Tree.tool_calls(view, "a-x")
    assert length(calls) == 50
    assert {:ok, [%{id: "tu-250"}, %{id: "tu-249"}]} = Tree.tool_calls(view, "a-x", limit: 2)
    assert {:ok, all} = Tree.tool_calls(view, "a-x", limit: 1000)
    assert length(all) == 200

    subagents =
      for i <- 1..60, into: "", do: use_line("tu-s#{i}", "Read", @t0, sub("ag-#{i}"))

    assert map_size(fold(subagents).agent_tools) == 50
  end

  defmodule Rows do
    @moduledoc "A source that answers the rows it was given, for one kind."
    @behaviour CodingAgentFramework.Tracker.Source
    @impl true
    def open(opts), do: {:ok, opts}
    @impl true
    def describe(opts), do: %{topic: opts[:topic], scope: opts[:scope], kind: opts[:kind]}
    @impl true
    def read(opts, _ids), do: {:ok, %{read_at: 1, rows: opts[:rows]}}
  end

  test "Tracker.tool_calls/3 answers from the view" do
    fold = fold(use_line("tu-1", "Bash", @t0))
    stream = %{id: 1, session: "s", gone: false, idle: false, requests: %{}}

    sources = [
      {Rows, topic: "sessions:h", scope: {"h", "agents"}, kind: :agents, rows: [@agent]},
      {Rows, topic: "stream:h", scope: {"h", "stream"}, kind: :stream, rows: [stream]},
      {Rows,
       topic: "transcripts:h:w", scope: {"h", "w"}, kind: :transcripts, rows: [transcript(fold)]}
    ]

    {:ok, tracker} = Tracker.start_link(sources: sources, timer: false)

    assert {:ok, [%{id: "tu-1", name: "Bash", ended_at: nil}]} =
             Tracker.tool_calls(tracker, "a-x")

    assert {:ok, %{agents: [%{tool: %{id: "tu-1"}}]}} = Tracker.agents(tracker)
    assert {:refused, :unknown_agent} = Tracker.tool_calls(tracker, "nobody")
  end
end
