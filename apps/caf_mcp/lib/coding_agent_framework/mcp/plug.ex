defmodule CodingAgentFramework.MCP.Plug do
  @moduledoc """
  The endpoint of `CodingAgentFramework.MCP`: MCP's HTTP transport, with no session, at
  `POST /mcp` from 127.0.0.1. Option: `mcp:` (the `MCP`). The embedding app serves it on
  127.0.0.1 at the port it gave `MCP`, with a server of its choice, as it serves `Intake`:

      {Bandit, ip: {127, 0, 0, 1}, port: 4791, plug: {CodingAgentFramework.MCP.Plug, mcp: mcp}}

  The caller is the agent of the `x-caf-token` header, and only that. A missing or unknown
  token gets 403 before the body is read, and writes no row; 403 too from another address, 404
  for another path, 405 for another method (there is no stream to `GET`). A request is one
  JSON-RPC message: `initialize`, `ping`, `tools/list` and `tools/call` get a JSON answer; a
  notification gets 202. A tool's outcome is its result's text, as JSON (`MCP.json/1`), with
  `isError` unless it is `ok`. `reload`'s answer is an event stream that sends
  `notifications/tools/list_changed` before the result, and `initialize` says the server sends
  it (`listChanged`).

      iex> plug = CodingAgentFramework.MCP.Plug
      iex> conn = Plug.Test.conn(:post, "/mcp", "{}") |> plug.call(plug.init(mcp: self()))
      iex> conn.status
      403
  """

  @behaviour Plug

  import Plug.Conn

  alias CodingAgentFramework.MCP

  @header "x-caf-token"
  @max_body 8_000_000
  @protocol "2025-06-18"

  @impl true
  def init(opts), do: %{mcp: Keyword.fetch!(opts, :mcp)}

  @impl true
  def call(conn, %{mcp: mcp}) do
    given = get_req_header(conn, @header)

    with {:path, ["mcp"]} <- {:path, conn.path_info},
         {:from, {127, 0, 0, 1}} <- {:from, conn.remote_ip},
         {:token, [token]} <- {:token, given},
         {:ok, agent} <- MCP.who(mcp, token),
         {:method, "POST"} <- {:method, conn.method},
         {:ok, body, conn} <- read_body(conn, length: @max_body),
         {:ok, %{"jsonrpc" => "2.0", "method" => method} = msg} <- JSON.decode(body) do
      answer(conn, mcp, agent, method, msg)
    else
      {:path, _} -> send_resp(conn, 404, "")
      {:method, _} -> send_resp(conn, 405, "")
      {:from, _} -> send_resp(conn, 403, "")
      {:token, _} -> send_resp(conn, 403, "")
      {:refused, :unknown_token} -> send_resp(conn, 403, "")
      {:more, _, conn} -> send_resp(conn, 413, "")
      {:unknown, _} -> send_resp(conn, 503, "")
      _ -> send_resp(conn, 400, "")
    end
  end

  # A notification has no id and gets no answer.
  defp answer(conn, _mcp, _agent, _method, msg) when not is_map_key(msg, "id"),
    do: send_resp(conn, 202, "")

  defp answer(conn, _mcp, _agent, "initialize", %{"id" => id} = msg) do
    result = %{
      protocolVersion: get_in(msg, ["params", "protocolVersion"]) || @protocol,
      capabilities: %{tools: %{listChanged: true}},
      serverInfo: %{name: "caf", version: "0.1.0"}
    }

    reply(conn, id, result)
  end

  defp answer(conn, _mcp, _agent, "ping", %{"id" => id}), do: reply(conn, id, %{})

  # The caller's own list: the framework's tools and the app's its scope holds.
  defp answer(conn, mcp, agent, "tools/list", %{"id" => id}) do
    case MCP.tools(mcp, agent) do
      tools when is_list(tools) -> reply(conn, id, %{tools: tools})
      _not_read -> send_resp(conn, 503, "")
    end
  end

  # The answer is written through `MCP.answer/5`, so a report `run_delegate` took is answered
  # only once the write returned, and held again when it raised. The adapter's write returns
  # once the socket took every byte (Bandit: `:gen_tcp.send/2` answered `:ok`), and raises when
  # the socket refuses it; it cannot tell whether the client read the bytes. The exception is
  # raised again after `MCP` has heard of it, so the server sees what it would have seen.
  defp answer(conn, mcp, agent, "tools/call", %{"id" => id, "params" => %{"name" => tool} = p}) do
    args = Map.get(p, "arguments") || %{}

    write = &write(conn, id, tool, &1)

    written =
      if is_map(args),
        do: MCP.answer(mcp, agent, tool, args, write),
        else: write.({:refused, {:bad, :args}})

    case written do
      {:ok, conn} -> conn
      {:failed, e, stacktrace} -> reraise e, stacktrace
    end
  end

  defp answer(conn, _mcp, _agent, _method, %{"id" => id}) do
    send_json(conn, %{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "Method not found"}})
  end

  defp write(conn, id, tool, outcome) do
    {:ok, outcome(conn, id, tool, outcome)}
  rescue
    e -> {:failed, e, __STACKTRACE__}
  end

  defp outcome(conn, id, tool, outcome) do
    result = %{
      content: [%{type: "text", text: JSON.encode!(MCP.json(outcome))}],
      isError: elem(outcome, 0) != :ok
    }

    if tool == "reload" and elem(outcome, 0) == :ok do
      note = %{jsonrpc: "2.0", method: "notifications/tools/list_changed"}
      stream(conn, [note, rpc(id, result)])
    else
      reply(conn, id, result)
    end
  end

  defp rpc(id, result), do: %{jsonrpc: "2.0", id: id, result: result}
  defp reply(conn, id, result), do: send_json(conn, rpc(id, result))

  defp send_json(conn, value),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(value))

  # MCP's HTTP transport lets a POST answer with an event stream, which may carry messages to the
  # client before the response; the stream ends after it.
  defp stream(conn, messages) do
    body = Enum.map_join(messages, &"event: message\ndata: #{JSON.encode!(&1)}\n\n")
    conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)
  end
end
