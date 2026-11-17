defmodule CodingAgentFramework.MCPTest do
  # No Claude Code: the test is the MCP client, speaking JSON-RPC to the endpoint with a token,
  # as an agent's `http` server entry would. The mailbox is a stand-in that tells the test what
  # reached it. `run` reaches a real `Jobs` whose one host is this workstation.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.MCP.Table
  doctest CodingAgentFramework.MCP.Plug

  import CodingAgentFramework.TestHost, only: [test_dir: 0, program!: 1, programs: 0]

  alias CodingAgentFramework.{Copies, Grants, Jobs, MCP}

  defmodule StandIn do
    @moduledoc false
    # A message `hold` waits for the test's go, so the test reads the call's row while it acts.
    def message(test, from, to, text, _opts) do
      send(test, {:message, self(), from, to, text})
      if text == "hold", do: receive(do: (:go -> :ok))
      {:ok, {:queued, 7}}
    end

    # A `Delegates` whose every report is ready at once; it tells the test what it was told.
    def start_delegate(test, parent, _project, branch, _model, _brief, _opts) do
      send(test, {:start, parent, branch})
      {:ok, %{id: 9, name: "app-" <> String.replace(branch, "/", "-")}}
    end

    def await_report(test, _parent, id, left) do
      send(test, {:await, id, left})
      {:ok, %{id: id, name: "app-unit-one", status: "finished", text: "done"}}
    end

    def answered(test, id) do
      send(test, {:answered, id})
      {:ok, :answered}
    end

    def release(test, id) do
      send(test, {:release, id})
      {:ok, :held}
    end
  end

  defmodule BrokenSocket do
    @moduledoc false
    # A connection whose client is gone: the request reads as in `Plug.Test`, and the answer's
    # write raises, as Bandit's does when the socket refuses it.
    defdelegate read_req_body(payload, opts), to: Plug.Adapters.Test.Conn
    def send_resp(_payload, _status, _headers, _body), do: raise(ArgumentError, "closed")
  end

  defmodule UnknownJobs do
    @moduledoc false
    # A `Jobs` whose `run` is unknown, as it is when its owner drops or the exit is not read.
    def run(test, job, _where, _worktree, _argv, opts) do
      send(test, {:run, job, opts[:timeout]})
      {:unknown, :dropped}
    end
  end

  setup do
    tree = fn ->
      [
        %{name: "app-fix", project: "app", parent: "app-main"},
        %{name: "app-other", project: "app", parent: "app-main"}
      ]
    end

    dir = test_dir()
    wt = Path.join(dir, "wt")
    File.mkdir_p!(wt)
    git = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    {_, 0} = System.cmd(program!(:git), ["-C", wt, "init", "-q"], env: git)
    copies = start_supervised!({Copies, dir: Path.join(dir, "copies"), programs: programs()})
    hosts = %{"ws" => %{programs: programs(), dir: Path.join(dir, "ws")}}

    jobs =
      start_supervised!(
        {Jobs, dir: Path.join(dir, "jobs"), copies: copies, hosts: hosts, on_late_end: & &1}
      )

    place = fn agent -> {:ok, %{project: "app", name: agent, worktree: wt}} end

    mcp =
      start_supervised!(
        {MCP,
         dir: dir,
         port: 4791,
         grants: Grants.new(tree),
         claims: :unused,
         start_id: "t",
         mailbox: {StandIn, self()},
         delegates: {StandIn, self()},
         services: {StandIn, self()},
         workstation: "ws",
         jobs: {Jobs, jobs},
         tracker: {StandIn, self()},
         stream: {StandIn, self()},
         transcripts: nil,
         place: place,
         instance: "one",
         tool_timeout: 600_000,
         margin: 60_000}
      )

    tokens = for a <- ~w(app-main app-fix stray), into: %{}, do: {a, token(mcp, a)}
    %{mcp: mcp, tokens: tokens, jobs: jobs, wt: wt}
  end

  # The stand-in job: it writes a file in the copy, prints a line and exits 3.
  defp job, do: [program!(:bash), "-c", "echo made > out.txt; echo ran; exit 3"]

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

    assert rpc.("tools/list")["tools"] |> Enum.map(& &1["name"]) ==
             ~w(message run start_delegate run_delegate) ++
               ~w(service_start services service_logs service_send service_wait) ++
               ~w(service_restart service_stop service_hand agents look transcript) ++
               ~w(interrupt answer resume stop reload)
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

    assert tool(mcp, t["app-fix"], "start_main", %{}) == %{
             "refused" => ["unknown_tool", "start_main"]
           }
  end

  test "run is the caller's job, named for the call, and answers as Jobs does",
       %{mcp: mcp, tokens: t, jobs: jobs, wt: wt} do
    args = %{
      "host" => "ws",
      "argv" => job(),
      "timeout" => 20_000,
      "opts" => %{"fetch" => ["out.txt"]}
    }

    answer = tool(mcp, t["app-fix"], "run", Map.put(args, "from", "app-main"))
    assert answer == %{"ok" => %{"exit" => 3, "log" => "ran\n", "fetch" => "done"}}
    assert File.read!(Path.join(wt, "out.txt")) == "made\n"

    assert [%{id: id, agent: "app-fix", tool: "run", state: "answered"}] = MCP.calls(mcp)
    assert [%{id: job, name: "app-fix", host: "ws"}] = Jobs.rows(jobs)
    assert job == "mcp-one-#{id}"

    where = %{host: "ws", project: "app", name: "app-fix"}
    direct = Jobs.run(jobs, "direct", where, wt, job(), timeout: 20_000, fetch: ["out.txt"])
    assert MCP.json(direct) == answer
  end

  test "run is refused off the tree, and its timeout is capped at a day",
       %{mcp: mcp, tokens: t, jobs: jobs} do
    args = %{"host" => "ws", "argv" => job(), "timeout" => 20_000}
    assert tool(mcp, t["stray"], "run", args) == %{"refused" => ["unknown_agent", "stray"]}

    for timeout <- [86_400_001, 0, "1000", nil] do
      bad = Map.put(args, "timeout", timeout)
      assert tool(mcp, t["app-fix"], "run", bad) == %{"refused" => ["bad", "args"]}
    end

    bad = Map.put(args, "opts", %{"fetch" => "out.txt"})
    assert tool(mcp, t["app-fix"], "run", bad) == %{"refused" => ["bad", "args"]}
    assert Jobs.rows(jobs) == []
    assert length(MCP.calls(mcp)) == 6
  end

  # An MCP over a `Jobs` stand-in whose `run` is always unknown.
  defp unknown_mcp(name, extra) do
    mcp = start_supervised!({MCP, mcp_opts(name) ++ extra}, id: name)
    {:ok, _} = MCP.issue(mcp, "app-fix")
    mcp
  end

  defp mcp_opts(name) do
    tree = fn -> [%{name: "app-fix", project: "app", parent: "app-main"}] end
    place = fn agent -> {:ok, %{project: "app", name: agent, worktree: "/nowhere"}} end

    [
      dir: Path.join(test_dir(), name),
      port: 4791,
      grants: Grants.new(tree),
      claims: :unused,
      start_id: "t",
      mailbox: {StandIn, self()},
      delegates: {StandIn, self()},
      services: {StandIn, self()},
      workstation: "ws",
      jobs: {UnknownJobs, self()},
      tracker: {StandIn, self()},
      stream: {StandIn, self()},
      transcripts: nil,
      place: place,
      instance: name,
      tool_timeout: 600_000,
      margin: 60_000
    ]
  end

  defp run_call(mcp, timeout) do
    MCP.call(mcp, "app-fix", "run", %{"host" => "ws", "argv" => ["x"], "timeout" => timeout})
  end

  test "an unknown run answer names its job, in the JSON too" do
    mcp = unknown_mcp("u", [])
    assert run_call(mcp, 1000) == {:unknown, %{job: "mcp-u-1", reason: :dropped}}
    assert_received {:run, "mcp-u-1", 1000}

    assert MCP.json(run_call(mcp, 1000)) ==
             %{"unknown" => %{"job" => "mcp-u-2", "reason" => "dropped"}}

    assert [%{outcome: ~s({"unknown":{"job":"mcp-u-1","reason":"dropped"}})} | _] =
             MCP.calls(mcp)
  end

  test "the cap is an option, a day by default, and the job id names the instance" do
    short = unknown_mcp("short", cap: 5_000)
    long = unknown_mcp("long", [])

    assert run_call(short, 5_001) == {:refused, {:bad, :args}}
    assert {:unknown, _} = run_call(short, 5_000)
    assert {:unknown, _} = run_call(long, 86_400_000)
    assert run_call(long, 86_400_001) == {:refused, {:bad, :args}}

    # A refused call has an id too, so the short one's run is its second call.
    assert_received {:run, "mcp-short-2", 5_000}
    assert_received {:run, "mcp-long-1", 86_400_000}
  end

  defp run_delegate(timeout) do
    %{
      "project" => "app",
      "branch" => "unit/one",
      "model" => "opus",
      "brief" => "b",
      "timeout" => timeout
    }
  end

  test "run_delegate's timeout stays under the tool timeout less the margin", %{mcp: mcp} do
    # 600 000 less 60 000: a wait of 540 000 ms or more could outlast the client's.
    for t <- [540_000, 600_000, 86_400_000] do
      assert MCP.call(mcp, "app-main", "run_delegate", run_delegate(t)) ==
               {:refused, {:timeout, {:under, 540_000}}}
    end

    refute_received {:start, _, _}

    assert {:ok, %{delegate: "app-unit-one", report: "done"}} =
             MCP.call(mcp, "app-main", "run_delegate", run_delegate(539_999))

    assert_received {:start, "app-main", "unit/one"}
    # A caller in this process has the answer in hand: the report is answered at once.
    assert_received {:answered, 9}

    for {opts, name} <- [{[margin: 0], "m0"}, {[margin: 600_000], "m1"}, {[tool_timeout: 1], "t"}] do
      assert {:error, {{:bad, :tool_timeout}, _}} =
               start_supervised({MCP, Keyword.merge(mcp_opts(name), opts)}, id: name)
    end
  end

  test "a report written to the agent is answered; one whose write fails is held again",
       %{mcp: mcp, tokens: t} do
    params = %{name: "run_delegate", arguments: run_delegate(10_000)}

    assert %{"ok" => %{"report" => "done"}} =
             tool(mcp, t["app-main"], "run_delegate", params.arguments)

    assert_received {:answered, 9}
    refute_received {:release, _}

    body = JSON.encode!(%{jsonrpc: "2.0", id: 2, method: "tools/call", params: params})

    conn =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("x-caf-token", t["app-main"])

    conn = %{conn | adapter: {BrokenSocket, elem(conn.adapter, 1)}}

    # The server sees the write's own error, after the report is held again.
    assert_raise ArgumentError, "closed", fn -> MCP.Plug.call(conn, MCP.Plug.init(mcp: mcp)) end
    assert_received {:release, 9}
    refute_received {:answered, _}
    assert [%{state: "answered"}, %{state: "answered"}] = Enum.take(MCP.calls(mcp), -2)
  end

  test "reload tells the client its tools changed, then answers", %{mcp: mcp, tokens: t} do
    conn = post(mcp, t["app-main"], "tools/call", %{name: "reload"})
    assert ["text/event-stream" <> _] = Plug.Conn.get_resp_header(conn, "content-type")

    assert [note, result] =
             for("data: " <> d <- String.split(conn.resp_body, "\n"), do: JSON.decode!(d))

    assert note == %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

    assert %{"id" => 1, "result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
             result

    assert JSON.decode!(text) == %{
             "ok" => %{
               "tools" =>
                 ~w(message run start_delegate run_delegate) ++
                   ~w(service_start services service_logs service_send service_wait) ++
                   ~w(service_restart service_stop service_hand agents look transcript) ++
                   ~w(interrupt answer resume stop reload)
             }
           }

    # Off the tree, it is a plain refusal: nothing changed for the client.
    assert tool(mcp, t["stray"], "reload", %{}) == %{"refused" => ["unknown_agent", "stray"]}
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
