defmodule CodingAgentFramework.MCPExtensionsTest do
  # The app's own tools on the agents' endpoint (F-154), and the app's metadata a start
  # carries. The test is the MCP client, as in `MCPTest`; the delegates and mains are stand-ins
  # that tell the test what they were given.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost, only: [test_dir: 0]

  alias CodingAgentFramework.{Grants, MCP}

  defmodule StandIn do
    @moduledoc false
    def start_delegate(test, parent, _project, branch, _model, _brief, opts) do
      send(test, {:start, parent, branch, opts[:meta]})
      {:ok, %{id: 9, name: "app-" <> branch, brief_uuid: "b9"}}
    end

    def start_main(test, _project, name, _brief, opts) do
      send(test, {:start_main, name, opts[:meta]})
      {:ok, %{name: name}}
    end
  end

  # A tool that answers what it was given, one that refuses, one that raises, one that answers
  # no outcome, and one that waits past its deadline, telling the test its process first.
  defp extensions(test) do
    [
      %{
        name: "board",
        scope: %{projects: ["app"]},
        tools: [
          tool("board_cards", [:main], fn caller, args -> {:ok, %{for: caller, args: args}} end),
          tool("board_move", [:main, :delegate], fn _, _ -> {:refused, :column_full} end),
          tool("board_boom", [:main, :delegate], fn _, _ -> raise "no board" end),
          tool("board_odd", [:main, :delegate], fn _, _ -> :done end),
          Map.put(
            tool("board_slow", [:delegate], fn _, _ ->
              send(test, {:slow, self()})
              receive(do: (:never -> {:ok, :late}))
            end),
            :timeout,
            200
          )
        ]
      },
      %{name: "kb", scope: %{projects: ["other"]}, tools: [tool("kb_find", [:main], &ok/2)]}
    ]
  end

  defp ok(_caller, _args), do: {:ok, []}

  defp tool(name, roles, call) do
    schema = %{type: "object", properties: %{column: %{type: "string"}}}

    %{
      name: name,
      description: "The app's #{name}.",
      schema: schema,
      call: call,
      scope: %{roles: roles}
    }
  end

  setup do
    tree = fn ->
      [
        %{name: "app-main", project: "app", parent: nil},
        %{name: "app-fix", project: "app", parent: "app-main"}
      ]
    end

    mcp = start_supervised!({MCP, opts(tree) ++ [extensions: extensions(self())]})
    tokens = for a <- ~w(app-main app-fix), into: %{}, do: {a, token(mcp, a)}
    %{mcp: mcp, tokens: tokens, tree: tree}
  end

  defp opts(tree) do
    [
      dir: test_dir(),
      port: 4791,
      grants: Grants.new(tree, operator: "op"),
      acts: :unused,
      mailbox: {StandIn, self()},
      delegates: {StandIn, self()},
      mains: {StandIn, self()},
      services: {StandIn, self()},
      workstation: "ws",
      tracker: {StandIn, self()},
      stream: {StandIn, self()},
      transcripts: nil,
      place: fn _ -> {:refused, :no_worktree} end,
      tool_timeout: 600_000,
      margin: 60_000,
      efforts: ~w(low medium high xhigh max)
    ]
  end

  defp token(mcp, agent) do
    {:ok, path} = MCP.issue(mcp, agent)
    %{"mcpServers" => %{"caf" => server}} = path |> File.read!() |> JSON.decode!()
    server["headers"]["x-caf-token"]
  end

  defp post(mcp, token, method, params) do
    body = JSON.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})
    conn = Plug.Test.conn(:post, "/mcp", body) |> Plug.Conn.put_req_header("x-caf-token", token)
    %{status: 200, resp_body: body} = MCP.Plug.call(conn, MCP.Plug.init(mcp: mcp))
    JSON.decode!(body)["result"]
  end

  defp listed(mcp, token) do
    for %{"name" => name} <- post(mcp, token, "tools/list", %{})["tools"],
        String.starts_with?(name, ["board_", "kb_"]),
        do: name
  end

  defp tool(mcp, token, name, args) do
    %{"content" => [%{"text" => text}]} =
      post(mcp, token, "tools/call", %{name: name, arguments: args})

    JSON.decode!(text)
  end

  test "a tool scoped to one role is listed and callable there, and absent elsewhere",
       %{mcp: mcp, tokens: t} do
    assert listed(mcp, t["app-main"]) == ~w(board_cards board_move board_boom board_odd)
    assert listed(mcp, t["app-fix"]) == ~w(board_move board_boom board_odd board_slow)

    # Its schema is the app's, as the client is given it.
    [cards] =
      Enum.filter(
        post(mcp, t["app-main"], "tools/list", %{})["tools"],
        &(&1["name"] == "board_cards")
      )

    assert cards["inputSchema"] == %{
             "type" => "object",
             "properties" => %{"column" => %{"type" => "string"}}
           }

    # The caller is the token's agent, whatever the arguments say.
    args = %{"column" => "todo", "caller" => "app-fix"}

    assert tool(mcp, t["app-main"], "board_cards", args) ==
             %{"ok" => %{"for" => "app-main", "args" => args}}

    assert tool(mcp, t["app-fix"], "board_cards", args) == %{"refused" => "out_of_scope"}
    # A tool of a project the caller does not work on is neither listed nor callable.
    assert tool(mcp, t["app-main"], "kb_find", %{}) == %{"refused" => "out_of_scope"}

    assert [
             %{
               agent: "app-main",
               tool: "board_cards",
               state: "answered",
               outcome: ~s({"ok") <> _
             },
             %{agent: "app-fix", tool: "board_cards", outcome: ~s({"refused":"out_of_scope"})},
             %{agent: "app-main", tool: "kb_find", outcome: ~s({"refused":"out_of_scope"})}
           ] = MCP.calls(mcp)

    # The operator reaches every tool, as it reaches every agent.
    assert MCP.operate(mcp, "kb_find", %{}) == {:ok, []}
    assert MCP.tools(mcp, "op") |> Enum.map(& &1.name) |> Enum.take(-1) == ["kb_find"]
  end

  test "a tool's refusal, its crash, an answer of no outcome and its deadline are explicit, and logged",
       %{mcp: mcp, tokens: t} do
    assert tool(mcp, t["app-fix"], "board_move", %{}) == %{"refused" => "column_full"}
    assert tool(mcp, t["app-fix"], "board_boom", %{}) == %{"unknown" => ["crashed", "no board"]}
    assert tool(mcp, t["app-fix"], "board_odd", %{}) == %{"unknown" => ["bad_answer", ":done"]}
    assert tool(mcp, t["app-fix"], "board_slow", %{}) == %{"unknown" => ["timeout", 200]}

    # Nothing of a call past its deadline runs on.
    assert_received {:slow, slow}
    refute Process.alive?(slow)

    outcomes = for %{state: "answered", outcome: o} <- MCP.calls(mcp), do: JSON.decode!(o)

    assert outcomes == [
             %{"refused" => "column_full"},
             %{"unknown" => ["crashed", "no board"]},
             %{"unknown" => ["bad_answer", ":done"]},
             %{"unknown" => ["timeout", 200]}
           ]
  end

  test "an extension that clashes with the framework's tools, or is not well formed, is refused",
       %{tree: tree} do
    Process.flag(:trap_exit, true)

    for {bad, why} <- [
          {%{name: "service", tools: []}, {:extension, "service", :clashes}},
          {%{name: "kb", tools: [tool("find", [:main], &ok/2)]},
           {:extension, "kb", {:tool, "find"}}},
          {%{name: "kb", guards: []}, {:extension, "kb", {:unknown_key, :guards}}},
          {%{name: "kb", tools: [Map.put(tool("kb_find", [:main], &ok/2), :timeout, 600_000)]},
           {:extension, "kb", {:timeout, "kb_find"}}}
        ] do
      dir = Path.join(test_dir(), why |> elem(1))
      opts = Keyword.merge(opts(tree), dir: dir, extensions: [bad])
      assert MCP.start_link(opts) == {:error, why}
    end
  end

  test "a start's metadata is the operator's to give, never an agent's", %{mcp: mcp, tokens: t} do
    start = %{"project" => "app", "branch" => "b", "model" => "m", "brief" => "Go."}
    meta = %{"ticket" => 41}

    assert tool(mcp, t["app-main"], "start_delegate", Map.put(start, "meta", meta)) ==
             %{"refused" => ["operator_only", "meta"]}

    assert {:ok, _} =
             MCP.operate(
               mcp,
               "start_delegate",
               Map.merge(start, %{"parent" => "app-main", "meta" => meta})
             )

    assert_received {:start, "app-main", "b", ^meta}

    assert tool(mcp, t["app-main"], "start_delegate", start) == %{
             "ok" => %{"delegate" => "app-b"}
           }

    assert_received {:start, "app-main", "b", nil}

    main = %{"project" => "app", "name" => "app-two", "brief" => "Go.", "meta" => meta}

    assert tool(mcp, t["app-main"], "start_main", main) == %{
             "refused" => ["operator_only", "meta"]
           }

    assert {:ok, %{main: "app-two"}} = MCP.operate(mcp, "start_main", main)
    assert_received {:start_main, "app-two", ^meta}
  end
end
