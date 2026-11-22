defmodule CodingAgentFramework.MCPTest do
  # No Claude Code: the test is the MCP client, speaking JSON-RPC to the endpoint with a token,
  # as an agent's `http` server entry would. The mailbox is a stand-in that tells the test what
  # reached it.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.MCP.Table
  doctest CodingAgentFramework.MCP.Plug
  doctest CodingAgentFramework.MCP, only: [extensions: 3]

  import CodingAgentFramework.TestHost, only: [test_dir: 0]

  alias CodingAgentFramework.{Acts, Grants, MCP, Operator}

  defmodule StandIn do
    @moduledoc false
    # A message `hold` waits for the test's go, so the test reads the call's row while it acts.
    def message(test, from, to, text, _opts) do
      send(test, {:message, self(), from, to, text})
      if text == "hold", do: receive(do: (:go -> :ok))
      {:ok, {:queued, 7}}
    end

    # A `Delegates` whose every start answers at once, and a `Mailbox` whose every report is
    # ready at once; each tells the test what it was told.
    # A start of `unit/queued` that does not wait answers its place in the queue (F-170).
    def start_delegate(test, parent, _project, branch, _model, _brief, opts) do
      send(test, {:start, parent, branch})
      send(test, {:start_opts, branch, opts})
      answer = %{id: 9, name: "app-" <> String.replace(branch, "/", "-"), brief_uuid: "b9"}

      # A start of `unit/limited` waits for a usage limit's reset, whatever `wait` (F-196).
      cond do
        branch == "unit/queued" and opts[:wait] == false -> {:ok, Map.put(answer, :queued, 2)}
        branch == "unit/limited" -> {:ok, Map.put(answer, :waiting, 1_800_000_000)}
        true -> {:ok, answer}
      end
    end

    # A `Mains` whose every end ends, and a `Mailbox` with two rows in flight to its session.
    def end_main(test, name, opts \\ []) do
      send(test, {:end_main, name, opts})
      {:ok, :ended}
    end

    def ended_while_sending(test, agent, _opts) do
      send(test, {:ended_while_sending, agent})
      {:ok, [5, 6]}
    end

    def await(test, _to, key, left) do
      send(test, {:await, key, left})
      {:ok, %{id: 4, from: "app-unit-one", kind: "reply", text: "done"}}
    end

    def told(test, id, written) do
      send(test, {:told, id, written})
      {:ok, if(written == :written, do: :delivered, else: :queued)}
    end

    # A `Prompts` that takes every answer (F-179): the operator's withdrawal of an ask and its
    # answer of a startup dialog go through it.
    def answer(test, id, choice, who) do
      send(test, {:prompt_answer, id, choice, who})
      {:ok, {:queued, 13}}
    end

    def answer_startup(test, agent, kind, label, who) do
      send(test, {:answer_startup, agent, kind, label, who})
      {:ok, :sent}
    end

    # A `Mailbox` that stores every well-formed ask as ask 12.

    def ask(test, from, questions, _opts) do
      send(test, {:ask, from, questions})
      if is_list(questions), do: {:ok, {:asked, 12}}, else: {:refused, {:bad, :questions}}
    end

    # A `Mover` that begins every move at once.
    def move(test, actor, agent, opts) do
      send(test, {:move, actor, agent, opts})
      {:ok, %{act: 3, to: opts[:to]}}
    end
  end

  defmodule BrokenSocket do
    @moduledoc false
    # A connection whose client is gone: the request reads as in `Plug.Test`, and the answer's
    # write raises, as Bandit's does when the socket refuses it.
    defdelegate read_req_body(payload, opts), to: Plug.Adapters.Test.Conn
    def send_resp(_payload, _status, _headers, _body), do: raise(ArgumentError, "closed")
  end

  setup do
    tree = fn ->
      [
        %{name: "app-main", project: "app", parent: nil},
        %{name: "app-fix", project: "app", parent: "app-main"},
        %{name: "app-other", project: "app", parent: "app-main"}
      ]
    end

    dir = test_dir()
    place = fn agent -> {:ok, %{project: "app", name: agent, worktree: dir}} end

    mcp =
      start_supervised!(
        {MCP,
         dir: dir,
         port: 4791,
         grants: Grants.new(tree),
         acts: :unused,
         mailbox: {StandIn, self()},
         delegates: {StandIn, self()},
         services: {StandIn, self()},
         workstation: "ws",
         tracker: {StandIn, self()},
         stream: {StandIn, self()},
         transcripts: nil,
         place: place,
         tool_timeout: 600_000,
         margin: 60_000}
      )

    tokens = for a <- ~w(app-main app-fix stray), into: %{}, do: {a, token(mcp, a)}
    %{mcp: mcp, tokens: tokens}
  end

  defp token(mcp, agent) do
    {:ok, path} = MCP.issue(mcp, agent)
    %{"mcpServers" => %{"caf" => server}} = path |> File.read!() |> JSON.decode!()
    assert %{"type" => "http", "url" => "http://127.0.0.1:4791/mcp"} = server
    server["headers"]["x-caf-token"]
  end

  defp token(path) do
    %{"mcpServers" => %{"caf" => server}} = path |> File.read!() |> JSON.decode!()
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
             ~w(message start_delegate run_delegate start_main) ++
               ~w(service_start services service_logs service_send service_wait) ++
               ~w(service_restart service_stop service_hand agents look transcript) ++
               ~w(interrupt answer resume stop move ask reload)
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

    assert tool(mcp, t["app-fix"], "start_main", %{}) == %{"refused" => ["bad", "args"]}

    # A delegate starts no main session (`Grants.may_start_main?/2`).
    start = %{"project" => "app", "name" => "app-b", "brief" => "Go."}
    assert tool(mcp, t["app-fix"], "start_main", start) == %{"refused" => "main_session_only"}

    # A main session's end is the operator's alone (F-143): no agent ends one, its own included.
    assert tool(mcp, t["app-fix"], "end_main", %{}) == %{"refused" => ["bad", "args"]}

    for caller <- ~w(app-fix app-main) do
      assert tool(mcp, t[caller], "end_main", %{"name" => "app-main"}) ==
               %{"refused" => "operator_only"}
    end
  end

  defp mcp_opts(name) do
    tree = fn ->
      [
        %{name: "app-main", project: "app", parent: nil},
        %{name: "app-fix", project: "app", parent: "app-main"}
      ]
    end

    place = fn agent -> {:ok, %{project: "app", name: agent, worktree: "/nowhere"}} end

    [
      dir: Path.join(test_dir(), name),
      port: 4791,
      grants: Grants.new(tree),
      acts: :unused,
      mailbox: {StandIn, self()},
      delegates: {StandIn, self()},
      services: {StandIn, self()},
      workstation: "ws",
      tracker: {StandIn, self()},
      stream: {StandIn, self()},
      transcripts: nil,
      place: place,
      tool_timeout: 600_000,
      margin: 60_000
    ]
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
    # A caller in this process has the answer in hand: the report is told written at once.
    assert_received {:told, 4, :written}

    for {opts, name} <- [{[margin: 0], "m0"}, {[margin: 600_000], "m1"}, {[tool_timeout: 1], "t"}] do
      assert {:error, {{:bad, :tool_timeout}, _}} =
               start_supervised({MCP, Keyword.merge(mcp_opts(name), opts)}, id: name)
    end
  end

  # F-203, from F-196's new-3: no report comes before the reset, so none is awaited.
  test "run_delegate of a start that waits at a limit answers its name and reset at once",
       %{mcp: mcp} do
    args = %{run_delegate(10_000) | "branch" => "unit/limited"}

    assert MCP.call(mcp, "app-main", "run_delegate", args) ==
             {:ok, %{delegate: "app-unit-limited", waiting: 1_800_000_000}}

    refute_received {:await, _, _}
  end

  test "a call's timeout is at most the cap, an option" do
    short = start_supervised!({MCP, mcp_opts("short") ++ [cap: 5_000]}, id: "short")

    assert MCP.call(short, "app-main", "run_delegate", run_delegate(5_001)) ==
             {:refused, {:bad, :args}}

    assert {:ok, %{report: "done"}} =
             MCP.call(short, "app-main", "run_delegate", run_delegate(5_000))
  end

  test "a report written to the agent is delivered; one whose write fails is due again",
       %{mcp: mcp, tokens: t} do
    params = %{name: "run_delegate", arguments: run_delegate(10_000)}

    assert %{"ok" => %{"report" => "done"}} =
             tool(mcp, t["app-main"], "run_delegate", params.arguments)

    assert_received {:told, 4, :written}
    refute_received {:told, _, :failed}

    body = JSON.encode!(%{jsonrpc: "2.0", id: 2, method: "tools/call", params: params})

    conn =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("x-caf-token", t["app-main"])

    conn = %{conn | adapter: {BrokenSocket, elem(conn.adapter, 1)}}

    # The server sees the write's own error, after the report is made due again.
    assert_raise ArgumentError, "closed", fn -> MCP.Plug.call(conn, MCP.Plug.init(mcp: mcp)) end
    assert_received {:told, 4, :failed}
    refute_received {:told, _, :written}
    assert [%{state: "answered"}, %{state: "answered"}] = Enum.take(MCP.calls(mcp), -2)
  end

  # F-170: an agent's start keeps working while no seat is free; the operator's waits unless it
  # says not to, and names the tool's options as an Elixir call's.
  test "a start's wait: an agent's by default no, the operator's by default yes", ctx do
    %{mcp: mcp, tokens: t} = ctx
    args = %{"project" => "app", "model" => "opus", "brief" => "Go."}

    assert tool(mcp, t["app-main"], "start_delegate", Map.put(args, "branch", "unit/queued")) ==
             %{"ok" => %{"delegate" => "app-unit-queued", "queued" => 2}}

    assert_received {:start_opts, "unit/queued", opts}
    assert opts[:wait] == false

    waits = Map.merge(args, %{"branch" => "unit/one", "wait" => true})

    assert %{"ok" => %{"delegate" => "app-unit-one"}} =
             tool(mcp, t["app-main"], "start_delegate", waits)

    assert_received {:start_opts, "unit/one", [_ | _] = opts}
    assert opts[:wait] == true

    bad = Map.merge(args, %{"branch" => "unit/one", "wait" => "no"})
    assert tool(mcp, t["app-main"], "start_delegate", bad) == %{"refused" => ["bad", "args"]}

    operator = operating(ctx)

    assert {:ok, %{delegate: "app-unit-one"}} =
             Operator.start_delegate(operator, "app-main", "app", "unit/one", "opus", "Go.",
               interactive: true,
               meta: %{"card" => 41},
               options: %{"env" => %{"APP_MODE" => "review"}}
             )

    assert_received {:start_opts, "unit/one", opts}
    assert opts[:wait] == true and opts[:interactive] == true
    assert opts[:meta] == %{"card" => 41}
    assert opts[:options] == %{"env" => %{"APP_MODE" => "review"}}
    assert opts[:effort] == nil

    # F-200: the surface's `effort:` is the tool's `effort`, and an agent's call carries it too.
    assert {:ok, %{delegate: "app-unit-one"}} =
             Operator.start_delegate(operator, "app-main", "app", "unit/one", "opus", "Go.",
               effort: "xhigh"
             )

    assert_received {:start_opts, "unit/one", opts}
    assert opts[:effort] == "xhigh"

    with_effort = Map.merge(args, %{"branch" => "unit/one", "effort" => "max"})
    tool(mcp, t["app-main"], "start_delegate", with_effort)
    assert_received {:start_opts, "unit/one", opts}
    assert opts[:effort] == "max"

    assert {:ok, %{delegate: "app-unit-queued", queued: 2}} =
             Operator.start_delegate(operator, "app-main", "app", "unit/queued", "opus", "Go.",
               wait: false
             )

    assert Operator.start_delegate(operator, "app-main", "app", "unit/one", "opus", "Go.",
             model: "haiku"
           ) == {:refused, {:bad, {:option, :model}}}
  end

  # F-170, Team.tla's ForcedByOperator: the forced end is the operator's alone, a row in Acts
  # before it acts, and each row left sending settles unknown, a row in Acts each.
  test "a forced end: the operator's, the act and each row's settle in the ledger", ctx do
    operator = operating(ctx)
    t = ctx.tokens

    for caller <- ~w(app-fix app-main) do
      assert tool(ctx.mcp, t[caller], "end_main", %{"name" => "app-main", "force" => true}) ==
               %{"refused" => "operator_only"}
    end

    assert {:ok, %{done: :ended, act: act, unknown: [5, 6]}} =
             Operator.end_main(operator, "app-main", force: true)

    assert_received {:end_main, "app-main", [force: true]}
    assert_received {:ended_while_sending, "app-main"}
    acts = Process.get(:acts)

    assert {:ok, %{actor: "op", target: "app-main", act: "end_main", outcome: "verified"}} =
             Acts.get(acts, act)

    assert {:ok, settles} = Acts.rows(acts, act: "settle")
    assert [~s({"row":5}), ~s({"row":6})] = Enum.map(settles, & &1.detail)
    assert Enum.all?(settles, &(&1.reason == "ended_while_sending" and &1.outcome == "unknown"))

    # Unforced, it is the end as before, and settles nothing.
    assert Operator.end_main(operator, "app-main") == {:ok, :ended}
    assert_received {:end_main, "app-main", []}
    refute_received {:ended_while_sending, _}

    assert MCP.operate(operator, "end_main", %{"name" => "app-main", "force" => "yes"}) ==
             {:refused, {:bad, :args}}

    # The forced act says so on its claim, before it acts: `Mailbox`'s own evidence (F-172).
    assert {:ok, %{detail: ~s({"force":true})}} = Acts.get(acts, act)

    # An ask's withdrawal is the operator's alone (F-172).
    assert tool(ctx.mcp, t["app-main"], "withdraw", %{"ask" => 12, "reason" => "no"}) ==
             %{"refused" => "operator_only"}

    assert {:ok, {:queued, 13}} = Operator.withdraw(operator, 12, "Dismissed.")
    assert_received {:prompt_answer, "ask:12", {:withdraw, "Dismissed."}, "op"}

    # So is a startup dialog's answer, through the inbox, as the operator.
    assert tool(ctx.mcp, t["app-main"], "answer_startup", %{
             "agent" => "app-main",
             "kind" => "trust",
             "label" => "Yes"
           }) == %{"refused" => "operator_only"}

    assert {:ok, :sent} = Operator.answer_startup(operator, "app-main", "trust", "Yes")
    assert_received {:answer_startup, "app-main", "trust", "Yes", "op"}

    # The operator's own tools are in its list alone (F-172's new-5).
    own = ~w(answer_startup end_main withdraw)
    assert own -- Enum.map(MCP.tools(operator, "op"), & &1.name) == []
    assert own -- Enum.map(MCP.tools(operator, "app-main"), & &1.name) == own

    # An agent's stop is never forced.
    assert tool(ctx.mcp, t["app-main"], "stop", %{"agent" => "app-fix", "force" => true}) ==
             %{"refused" => ["operator_only", "force"]}
  end

  # An `MCP` with an operator, real `Acts` and the stand-in `Mains`, beside the setup's.
  defp operating(ctx) do
    tree = fn -> [%{name: "app-main", parent: nil}, %{name: "app-fix", parent: "app-main"}] end
    stand_in = {StandIn, self()}
    dir = Path.join(ctx[:dir] || test_dir(), "operating")
    File.mkdir_p!(dir)

    acts =
      start_supervised!(
        {Acts, db: Path.join(dir, "acts.db"), start_id: "s1", host: "t", instance: "o"}
      )

    Process.put(:acts, acts)

    opts =
      [dir: dir, port: 4793, grants: Grants.new(tree, operator: "op"), acts: acts] ++
        Enum.map(~w(mailbox delegates services tracker stream mains prompts)a, &{&1, stand_in}) ++
        [workstation: "ws", transcripts: nil, place: fn _ -> {:refused, :no_worktree} end] ++
        [tool_timeout: 600_000, margin: 60_000]

    start_supervised!(Supervisor.child_spec({MCP, opts}, id: :operating))
  end

  # A move is a fix's act: a parent's of its delegate, never an agent's of a main session or of
  # itself; the mover claims and settles it.
  test "move reaches the mover only by Grants' fix check", %{mcp: mcp, tokens: t} do
    assert tool(mcp, t["app-main"], "move", %{agent: "app-fix"}) == %{"refused" => "no_mover"}

    tree = [%{name: "app-main", parent: nil}, %{name: "app-fix", parent: "app-main"}]
    stand_in = {StandIn, self()}

    opts =
      [dir: test_dir(), port: 4792, grants: Grants.new(fn -> tree end), acts: :unused] ++
        Enum.map(~w(mailbox delegates services tracker stream mover)a, &{&1, stand_in}) ++
        [workstation: "ws", transcripts: nil, place: fn _ -> {:refused, :no_worktree} end] ++
        [tool_timeout: 600_000, margin: 60_000]

    moving = start_supervised!(Supervisor.child_spec({MCP, opts}, id: :moving))
    [main, fix] = for a <- ~w(app-main app-fix), do: token(elem(MCP.issue(moving, a), 1))

    assert tool(moving, main, "move", %{agent: "app-fix", to: "spare"}) ==
             %{"ok" => %{"act" => 3, "to" => "spare"}}

    assert_received {:move, "app-main", "app-fix", [to: "spare"]}

    assert tool(moving, fix, "move", %{agent: "app-main"}) ==
             %{"refused" => "main_fixed_by_operator_only"}

    assert tool(moving, fix, "move", %{agent: "app-fix"}) == %{"refused" => "no_self_fix"}

    assert tool(moving, main, "move", %{agent: "app-fix", to: 3}) == %{
             "refused" => ["bad", "args"]
           }

    refute_received {:move, _, _, _}
  end

  # The tool answers the ask's id at once; `Mailbox` checks the questions and stores the ask.
  test "ask hands the caller's questions to the mailbox and answers its id", %{
    mcp: mcp,
    tokens: t
  } do
    questions = [
      %{"header" => "Base", "question" => "Which?", "options" => [], "multiSelect" => false}
    ]

    assert tool(mcp, t["app-fix"], "ask", %{questions: questions}) == %{"ok" => %{"ask" => 12}}
    assert_received {:ask, "app-fix", ^questions}

    assert tool(mcp, t["app-fix"], "ask", %{questions: "no"}) == %{
             "refused" => ["bad", "questions"]
           }

    assert tool(mcp, t["app-fix"], "ask", %{}) == %{"refused" => ["bad", "args"]}
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
                 ~w(message start_delegate run_delegate start_main) ++
                   ~w(service_start services service_logs service_send service_wait) ++
                   ~w(service_restart service_stop service_hand agents look transcript) ++
                   ~w(interrupt answer resume stop move ask reload)
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
