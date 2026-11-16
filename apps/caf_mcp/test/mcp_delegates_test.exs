defmodule CodingAgentFramework.MCPDelegatesTest do
  # `start_delegate`, `run_delegate`, `agents`, `look` and `transcript` over a real `Delegates`,
  # `Sessions`, `Stream`, `Transcripts` and `Tracker`, real dtach and tmux, a git repository in
  # this test's own directory (two projects share it), and the headless stand-in for Claude Code.
  # The test is the MCP client, with a token, and cues as the embedding app's wiring would.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Delegates, Grants, MCP, SessionsSetup, Stream}
  alias CodingAgentFramework.{Tracker, Transcripts, Usage}
  alias CodingAgentFramework.Delegates.Table

  setup {SessionsSetup, :sessions}

  setup ctx do
    repo = Path.join(ctx.dir, "repo")
    git = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    {_, 0} = System.cmd(program!(:git), ["init", "-q", "-b", "main", repo], env: git)
    commit = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "i"]
    {_, 0} = System.cmd(program!(:git), commit ++ ["--allow-empty"], env: git)

    {:ok, accounts} = Accounts.new(Path.join(ctx.dir, "home"), ["work"])
    {:ok, file} = Accounts.usage_file(accounts, "work")
    File.mkdir_p!(Path.dirname(file))
    week = %{"seven_day" => %{"used_percentage" => 25, "resets_at" => 4_000_000_000}}
    File.write!(file, JSON.encode!(%{"rate_limits" => week}))
    db = Path.join(ctx.dir, "caf.db")
    usage = start_supervised!({Usage, accounts: accounts, host: "test", db: db})
    {:ok, _} = Usage.read(usage)
    transcripts = start_supervised!({Transcripts, programs: programs(), account: "work", db: db})

    project = %{name: "app", repo: repo, trunk: "main", setup: [], setup_timeout: 10_000}
    project = Map.merge(project, %{env: %{"HOME" => ctx.dir}, branches: ~r/\Aunit\//, cap: 2})

    delegates =
      start_supervised!(
        {Delegates,
         host: "test",
         db: db,
         sessions_db: db,
         sessions: ctx.sessions,
         stream: ctx.stream,
         usage: usage,
         accounts: accounts,
         transcripts: %{"work" => transcripts},
         launch:
           SessionsSetup.headless(ctx, :at_start) |> Keyword.take([:claude, :env, :tool_timeout]),
         projects: %{"app" => project, "lib" => %{project | name: "lib"}}}
      )

    {:ok, dtable} = Table.open(db)

    sources = [
      {Tracker.DelegatesSource, db: db, host: "test"},
      {Tracker.StreamSource, db: db, host: "test"}
    ]

    sources = [{Tracker.TranscriptsSource, db: db, host: "test", account: "work"} | sources]
    tracker = start_supervised!({Tracker, sources: sources, timer: false})

    # Until `Mains` exists, a main session is known as a parent a delegate's row names: `app-old`
    # and `lib-old` stand for earlier delegates of `main` and `lmain`.
    tree = fn ->
      rows = Table.with_status(dtable, "test", ~w(starting running resuming finished failed))
      [%{name: "app-old", parent: "main"}, %{name: "lib-old", parent: "lmain"} | rows]
    end

    mcp =
      start_supervised!(
        {MCP,
         dir: Path.join(ctx.dir, "mcp"),
         port: 4791,
         grants: Grants.new(tree),
         mailbox: {__MODULE__, :unused},
         jobs: {__MODULE__, :unused},
         delegates: {Delegates, delegates},
         services: {__MODULE__, :unused},
         workstation: "ws",
         tracker: {Tracker, tracker},
         stream: {Stream, ctx.stream},
         transcripts: %{"work" => {Transcripts, transcripts}},
         place: fn _ -> {:refused, :none} end,
         instance: "d",
         tool_timeout: 600_000,
         margin: 60_000}
      )

    tokens =
      for a <- ~w(main lmain app-old app-unit-one stray), into: %{} do
        {:ok, path} = MCP.issue(mcp, a)
        {a, JSON.decode!(File.read!(path))["mcpServers"]["caf"]["headers"]["x-caf-token"]}
      end

    %{mcp: mcp, tokens: tokens, delegates: delegates, dtable: dtable}
    |> Map.merge(%{tracker: tracker, transcripts: transcripts})
  end

  defmodule BrokenSocket do
    @moduledoc false
    # A connection whose client is gone: the request reads as in `Plug.Test`, and the answer's
    # write raises, as Bandit's does when the socket refuses it.
    defdelegate read_req_body(payload, opts), to: Plug.Adapters.Test.Conn
    def send_resp(_payload, _status, _headers, _body), do: raise(ArgumentError, "closed")
  end

  defp request(ctx, agent, name, args) do
    body = %{jsonrpc: "2.0", id: 1, method: "tools/call", params: %{name: name, arguments: args}}

    Plug.Test.conn(:post, "/mcp", JSON.encode!(body))
    |> Plug.Conn.put_req_header("x-caf-token", ctx.tokens[agent])
  end

  defp tool(ctx, agent, name, args) do
    conn = request(ctx, agent, name, args) |> MCP.Plug.call(MCP.Plug.init(mcp: ctx.mcp))
    %{"result" => %{"content" => [%{"text" => text}]}} = JSON.decode!(conn.resp_body)
    JSON.decode!(text)
  end

  defp start_args(branch),
    do: %{"project" => "app", "branch" => branch, "model" => "opus", "brief" => "Review it."}

  test "start_delegate is the main session's, by its token, and answers the name at once", ctx do
    args = Map.put(start_args("unit/one"), "parent", "app-old")
    assert tool(ctx, "main", "start_delegate", args) == %{"ok" => %{"delegate" => "app-unit-one"}}

    assert [%{parent: "main", name: "app-unit-one"}] =
             Table.with_status(ctx.dtable, "test", ~w(running finished))

    assert tool(ctx, "app-old", "start_delegate", start_args("unit/two")) ==
             %{"refused" => "main_session_only"}

    assert tool(ctx, "stray", "run_delegate", Map.put(start_args("unit/two"), "timeout", 1000)) ==
             %{"refused" => ["unknown_agent", "stray"]}

    assert tool(ctx, "main", "start_delegate", %{start_args("x") | "brief" => 1}) ==
             %{"refused" => ["bad", "args"]}

    assert tool(ctx, "main", "start_delegate", start_args("main")) ==
             %{"refused" => ["bad", "branch"]}

    assert tool(
             ctx,
             "main",
             "run_delegate",
             Map.put(start_args("unit/two"), "timeout", 86_400_001)
           ) ==
             %{"refused" => ["bad", "args"]}

    assert length(Table.with_status(ctx.dtable, "test", ~w(starting running finished))) == 1
    assert [%{agent: "main", state: "answered"} | _] = MCP.calls(ctx.mcp)
  end

  test "run_delegate answers the report, which is then never held for a message", ctx do
    args = Map.put(start_args("unit/one"), "timeout", 60_000)
    call = Task.async(fn -> tool(ctx, "main", "run_delegate", args) end)

    {:ok, row} = cue_until(ctx, &(&1.report == "answered"))

    assert %{"ok" => %{"delegate" => "app-unit-one", "status" => "finished", "report" => text}} =
             Task.await(call)

    assert text == "done #{row.brief_uuid}" and text == row.text
    assert {:ok, []} = Delegates.held(ctx.delegates, "main")
  end

  test "a run_delegate answer whose write fails holds the report again, for a message", ctx do
    args = Map.put(start_args("unit/one"), "timeout", 60_000)
    conn = request(ctx, "main", "run_delegate", args)
    conn = %{conn | adapter: {BrokenSocket, elem(conn.adapter, 1)}}

    call =
      Task.async(fn ->
        try do
          MCP.Plug.call(conn, MCP.Plug.init(mcp: ctx.mcp))
        rescue
          e -> e
        end
      end)

    {:ok, _} = cue_until(ctx, &(&1.status == "finished"))
    assert %ArgumentError{message: "closed"} = Task.await(call, 20_000)

    assert %{report: "held", text: "done " <> _ = text, mark: "[report " <> _} =
             List.first(Table.with_status(ctx.dtable, "test", ~w(finished)))

    assert {:ok, [%{text: ^text}]} = Delegates.held(ctx.delegates, "main")
  end

  test "run_delegate at its timeout answers unknown with the name; the report is held", ctx do
    # While the file is there, the stand-in's turn waits on a permission request.
    File.write!(Path.join(ctx.dir, "hold"), "")
    args = Map.put(start_args("unit/one"), "timeout", 10_000)

    assert tool(ctx, "main", "run_delegate", args) ==
             %{"unknown" => %{"delegate" => "app-unit-one", "reason" => "timeout"}}

    [%{session_id: sid, brief_uuid: u}] =
      Table.with_status(ctx.dtable, "test", ~w(running finished))

    {:ok, _} = await(fn -> requested(ctx, sid, "req-" <> u) end, 10_000)
    {:ok, _} = Stream.write(ctx.stream, sid, {:answer, "req-" <> u, :allow})

    {:ok, %{id: id}} = cue_until(ctx, &(&1.status == "finished"))
    assert {:ok, [%{id: ^id, text: "done " <> ^u}]} = Delegates.held(ctx.delegates, "main")
  end

  defp requested(ctx, sid, req) do
    {:ok, _} = Stream.read(ctx.stream)
    {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
    row = Enum.find(rows, &(&1.session == sid))
    if row && row.requests[req], do: {:ok, row}
  end

  # Reads Stream and cues Delegates until the one delegate's row satisfies `ready?`.
  defp cue_until(ctx, ready?) do
    await(
      fn ->
        {:ok, _} = Stream.read(ctx.stream)
        Delegates.cue(ctx.delegates, %{topic: "stream:test", ids: []})
        Delegates.held(ctx.delegates, "main")
        row = List.first(Table.with_status(ctx.dtable, "test", ~w(running finished)))
        if row && ready?.(row), do: {:ok, row}
      end,
      20_000
    )
  end

  defp start(ctx, main, project, branch) do
    args = %{"project" => project, "branch" => branch, "model" => "opus", "brief" => "Go."}
    %{"ok" => %{"delegate" => name}} = tool(ctx, main, "start_delegate", args)
    name
  end

  # Reads `Stream`, cues `Delegates` and the `Tracker` (every topic, as a cue with no ids) until
  # the tree's delegates all satisfy `ready?`.
  defp settle(ctx, count, ready?) do
    await(
      fn ->
        {:ok, _} = Stream.read(ctx.stream)
        Delegates.cue(ctx.delegates, %{topic: "stream:test", ids: []})
        Delegates.held(ctx.delegates, "main")

        for t <- ~w(delegates:test stream:test transcripts:test:work),
            do: Tracker.cue(ctx.tracker, %{topic: t})

        {:ok, tree} = Tracker.agents(ctx.tracker)
        delegates = Enum.filter(tree.agents, &(&1.kind == "delegate"))
        if length(delegates) == count and Enum.all?(delegates, ready?), do: {:ok, tree}
      end,
      20_000
    )
  end

  test "agents() is the Tracker's tree, for two projects; transcript reads from an offset", ctx do
    start(ctx, "main", "app", "unit/one")
    start(ctx, "lmain", "lib", "unit/two")
    {:ok, tree} = settle(ctx, 2, &(&1.state == "idle"))

    answer = tool(ctx, "app-unit-one", "agents", %{})
    # The same tree; only the sources' ages move between the two reads.
    expected =
      MCP.json(%{tree | agents: Enum.map(tree.agents, &Map.drop(&1, [:session_id, :host]))})

    assert Map.delete(answer["ok"], "sources") == Map.delete(expected, "sources")
    assert Map.keys(answer["ok"]["sources"]) == Map.keys(expected["sources"])

    assert [
             %{"name" => "main", "kind" => "main", "project" => "app", "parent" => nil} = main,
             %{"name" => "app-unit-one", "kind" => "delegate", "parent" => "main"} = one,
             %{"name" => "lmain", "kind" => "main", "project" => "lib"},
             %{"name" => "lib-unit-two", "project" => "lib", "parent" => "lmain"}
           ] = answer["ok"]["agents"]

    assert %{"account" => "work", "state" => "idle", "waits_on" => [], "subagents" => []} = one
    refute Map.has_key?(main, "state")

    # The transcript, written as Claude Code would, with a last line not yet whole.
    {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
    %{session_id: sid} = Enum.at(tree.agents, 1)
    %{transcript: path} = Enum.find(rows, &(&1.session == sid))
    [one, two] = for p <- ~w(p1 p2), do: ~s({"type":"user","promptId":"#{p}","message":{}}\n)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, one <> two <> ~s({"type":"us))
    {:ok, %{failed: []}} = Transcripts.read(ctx.transcripts, [{sid, path}])
    {args, size} = {%{"agent" => "app-unit-one", "from" => 0}, byte_size(one <> two)}

    assert tool(ctx, "main", "transcript", args) ==
             %{"ok" => %{"text" => one <> two, "from" => 0, "next" => size}}

    assert tool(ctx, "main", "transcript", %{args | "from" => byte_size(one)}) ==
             %{"ok" => %{"text" => two, "from" => byte_size(one), "next" => size}}

    assert %{"ok" => %{"transcript" => text}} =
             tool(ctx, "main", "look", %{"agent" => "app-unit-one"})

    assert text == one <> two

    assert tool(ctx, "lmain", "transcript", %{args | "agent" => "main"}) == %{
             "refused" => "no_session"
           }
  end

  test "look shows a held request and the log's end; a close read is refused off the edges",
       ctx do
    # While the file is there, the stand-in's turn waits on a permission request.
    File.write!(Path.join(ctx.dir, "hold"), "")
    start(ctx, "main", "app", "unit/one")
    {:ok, _} = settle(ctx, 1, &(&1.state == "waiting"))

    assert %{"ok" => look} = tool(ctx, "main", "look", %{"agent" => "app-unit-one"})
    assert %{"state" => "waiting", "requests" => [%{"request" => "req-" <> _}]} = look
    assert look["events"] =~ ~s("control_request")
    assert look["transcript"] == %{"refused" => "unknown_session"}
    assert {:ok, _} = MCP.call(ctx.mcp, "app-unit-one", "look", %{"agent" => "app-unit-one"})

    refused = %{"refused" => "close_read_along_edges"}
    assert tool(ctx, "lmain", "look", %{"agent" => "app-unit-one"}) == refused

    assert tool(ctx, "app-old", "transcript", %{"agent" => "app-unit-one", "from" => 0}) ==
             refused

    assert tool(ctx, "lmain", "look", %{"agent" => "main"}) == %{"refused" => "no_screen"}
    assert tool(ctx, "app-unit-one", "look", %{"agent" => "main"}) == %{"refused" => "no_screen"}
  end
end
