defmodule CodingAgentFramework.MCPTest do
  # No Claude Code: the test is the MCP client, speaking JSON-RPC to the endpoint with a token,
  # as an agent's `http` server entry would. The mailbox is a stand-in that tells the test what
  # reached it.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.MCP.Table
  doctest CodingAgentFramework.MCP.Plug

  import CodingAgentFramework.TestHost, only: [test_dir: 0]

  alias CodingAgentFramework.{Grants, MCP}

  defmodule StandIn do
    @moduledoc false
    # A message `hold` waits for the test's go, so the test reads the call's row while it acts.
    def message(test, from, to, text, _opts) do
      send(test, {:message, self(), from, to, text})
      if text == "hold", do: receive(do: (:go -> :ok))
      {:ok, {:queued, 7}}
    end
  end

  setup do
    tree = fn ->
      [
        %{name: "app-fix", project: "app", parent: "app-main"},
        %{name: "app-other", project: "app", parent: "app-main"}
      ]
    end

    mcp =
      start_supervised!(
        {MCP, dir: test_dir(), port: 4791, grants: Grants.new(tree), mailbox: {StandIn, self()}}
      )

    tokens = for a <- ~w(app-main app-fix), into: %{}, do: {a, token(mcp, a)}
    %{mcp: mcp, tokens: tokens}
  end

  defp token(mcp, agent) do
    {:ok, path} = MCP.issue(mcp, agent)
    %{"mcpServers" => %{"caf" => server}} = path |> File.read!() |> JSON.decode!()
    assert %{"type" => "http", "url" => "http://127.0.0.1:4791/mcp"} = server
    server["headers"]["x-caf-token"]
  end

  defp post(mcp, token, method, params) do
    body = JSON.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})
    conn = Plug.Test.conn(:post, "/mcp", body)
    conn = if token, do: Plug.Conn.put_req_header(conn, "x-caf-token", token), else: conn
    MCP.Plug.call(conn, MCP.Plug.init(mcp: mcp))
  end

  defp tool(mcp, token, name, args) do
    %{status: 200, resp_body: body} =
      post(mcp, token, "tools/call", %{name: name, arguments: args})

    %{"result" => %{"content" => [%{"text" => text}]}} = JSON.decode!(body)
    JSON.decode!(text)
  end

  test "served on 127.0.0.1, it answers initialize and lists the tools", %{mcp: mcp, tokens: t} do
    Mix.ensure_application!(:inets)
    {:ok, _} = Application.ensure_all_started(:inets)
    plug = {MCP.Plug, mcp: mcp}

    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    url = ~c"http://127.0.0.1:#{port}/mcp"

    rpc = fn method ->
      body = JSON.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: %{}})
      head = [{~c"x-caf-token", String.to_charlist(t["app-fix"])}]

      {:ok, {{_, 200, _}, _, b}} =
        :httpc.request(:post, {url, head, ~c"application/json", body}, [], [])

      JSON.decode!(to_string(b))["result"]
    end

    assert %{"serverInfo" => %{"name" => "caf"}, "capabilities" => %{"tools" => _}} =
             rpc.("initialize")

    assert rpc.("tools/list")["tools"] |> Enum.map(& &1["name"]) == ["message"]
  end

  test "a call is the agent's whose token it carries, whatever its arguments say",
       %{mcp: mcp, tokens: t} do
    args = %{"to" => "app-main", "text" => "done", "from" => "app-other"}
    assert tool(mcp, t["app-fix"], "message", args) == %{"ok" => ["queued", 7]}
    assert_received {:message, _, "app-fix", "app-main", "done"}
    assert [%{agent: "app-fix", tool: "message", state: "answered"}] = MCP.calls(mcp)
  end

  test "a missing, unknown or replaced token is refused, and writes no row",
       %{mcp: mcp, tokens: t} do
    old = t["app-fix"]
    _new = token(mcp, "app-fix")
    args = %{name: "message", arguments: %{"to" => "app-main", "text" => "x"}}

    for token <- [nil, "made-up", old] do
      assert post(mcp, token, "tools/call", args).status == 403
    end

    assert MCP.calls(mcp) == []
    refute_received {:message, _, _, _, _}
    assert MCP.issue(mcp, "../app-fix") == {:refused, {:bad, :agent}}
  end

  test "a call is written before it acts and again with its outcome", %{mcp: mcp, tokens: t} do
    args = %{"to" => "app-fix", "text" => "hold"}
    call = Task.async(fn -> tool(mcp, t["app-main"], "message", args) end)

    assert_receive {:message, mailbox, "app-main", "app-fix", "hold"}
    assert [%{agent: "app-main", state: "called", outcome: nil, args: logged}] = MCP.calls(mcp)
    assert JSON.decode!(logged) == args

    send(mailbox, :go)
    assert Task.await(call) == %{"ok" => ["queued", 7]}
    assert [%{state: "answered", outcome: ~s({"ok":["queued",7]})}] = MCP.calls(mcp)
  end

  test "message is refused off an edge, and the refusal is logged", %{mcp: mcp, tokens: t} do
    args = %{"to" => "app-other", "text" => "hi"}
    assert tool(mcp, t["app-fix"], "message", args) == %{"refused" => "along_edges"}
    refute_received {:message, _, _, _, _}
    assert [%{state: "answered", outcome: ~s({"refused":"along_edges"})}] = MCP.calls(mcp)

    assert tool(mcp, t["app-fix"], "message", %{"to" => 1}) == %{"refused" => ["bad", "args"]}
    assert tool(mcp, t["app-fix"], "look", %{}) == %{"refused" => ["unknown_tool", "look"]}
  end

  test "a row a restart left called reads cut" do
    path = Path.join([test_dir(), "cut", "mcp.db"])
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = MCP.Table.open(path)
    MCP.Table.called(db, "app-fix", "message", "{}")
    {:ok, db} = MCP.Table.open(path)
    assert [%{state: "cut"}] = MCP.Table.calls(db)
  end
end
