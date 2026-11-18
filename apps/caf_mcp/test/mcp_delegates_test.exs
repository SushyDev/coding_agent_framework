defmodule CodingAgentFramework.MCPDelegatesTest do
  # `start_delegate`, `run_delegate`, `agents`, `look` and `transcript` over a real `Delegates`,
  # `Sessions`, `Stream`, `Transcripts` and `Tracker`, real dtach and tmux, a git repository in
  # this test's own directory (two projects share it), and the headless stand-in for Claude Code.
  # The test is the MCP client, with a token, and cues as the embedding app's wiring would.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Delegates, Grants, Mailbox, MCP, Sessions, SessionsSetup}
  alias CodingAgentFramework.Stream
  alias CodingAgentFramework.{Tracker, Transcripts, Usage}
  alias CodingAgentFramework.Delegates.Table
  alias CodingAgentFramework.Acts
  alias CodingAgentFramework.{HeadlessStandIn, Operator}

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

    transcripts =
      start_supervised!({Transcripts, programs: programs(), accounts: ["work"], db: db})

    project = %{name: "app", repo: repo, trunk: "main", setup: [], setup_timeout: 10_000}
    project = Map.merge(project, %{env: %{"HOME" => ctx.dir}, branches: ~r/\Aunit\//, cap: 2})

    {:ok, dtable} = Table.open(db)

    # The main sessions are agent rows, declared as the embedding app declares them until
    # `Mains`; `app-old` and `lib-old` stand for earlier delegates of `main` and `lmain`.
    for {name, project} <- [{"main", "app"}, {"lmain", "lib"}],
        do: Sessions.Table.declare(ctx.table, "test", name, project)

    {:ok, agents} = Sessions.Agents.open(db, "test")
    old = [%{name: "app-old", parent: "main"}, %{name: "lib-old", parent: "lmain"}]
    tree = fn -> old ++ Sessions.Agents.read_tree(agents) end

    grants = Grants.new(tree, operator: "op")

    mailbox =
      start_supervised!(
        {Mailbox, db: db, grants: grants, stream: ctx.stream, sessions_db: db, host: "test"}
      )

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
         transcripts: transcripts,
         mailbox: mailbox,
         launch:
           SessionsSetup.headless(ctx, :on_message)
           |> Keyword.take([:claude, :env, :tool_timeout]),
         projects: %{"app" => project, "lib" => %{project | name: "lib"}}}
      )

    sources = [
      {Tracker.TableSource, table: Transcripts.Table, db: db, host: "test", account: "work"},
      {Tracker.TableSource, table: Sessions.Table, db: db, host: "test"},
      {Tracker.TableSource, table: Stream.Table, db: db, host: "test"}
    ]

    tracker = start_supervised!({Tracker, sources: sources, timer: false})

    acts =
      start_supervised!(
        {Acts, db: Path.join(ctx.dir, "acts.db"), start_id: "s1", host: "test", instance: "d"}
      )

    mcp =
      start_supervised!(
        {MCP,
         dir: Path.join(ctx.dir, "mcp"),
         port: 4791,
         grants: grants,
         acts: acts,
         mailbox: {Mailbox, mailbox},
         jobs: {__MODULE__, :unused},
         delegates: {Delegates, delegates},
         services: {__MODULE__, :unused},
         workstation: "ws",
         tracker: {Tracker, tracker},
         stream: {Stream, ctx.stream},
         transcripts: {Transcripts, transcripts},
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

    %{mcp: mcp, tokens: tokens, delegates: delegates, dtable: dtable, mailbox: mailbox}
    |> Map.put(:table, ctx.table)
    |> Map.merge(%{tracker: tracker, transcripts: transcripts})
    |> Map.put(:acts, acts)
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

  test "start_delegate takes the delegate's own launch options, which Delegates checks", ctx do
    args = &Map.put(start_args("unit/one"), "options", &1)
    bad = %{"refused" => ["bad_option", "env", ["reserved", "HOME"]]}
    assert tool(ctx, "main", "start_delegate", args.(%{"env" => %{"HOME" => "/x"}})) == bad
    options = %{"add_dirs" => ["/srv/docs"], "allowed_tools" => ["Read"]}
    assert %{"ok" => _} = tool(ctx, "main", "start_delegate", args.(options))
    assert [%{name: name}] = Table.with_status(ctx.dtable, "test", ~w(running finished))
    assert JSON.decode!(agent(ctx, name).options) == options
  end

  test "start_delegate is the main session's, by its token, and answers the name at once", ctx do
    args = Map.put(start_args("unit/one"), "parent", "app-old")
    assert tool(ctx, "main", "start_delegate", args) == %{"ok" => %{"delegate" => "app-unit-one"}}

    assert [%{name: "app-unit-one"}] = Table.with_status(ctx.dtable, "test", ~w(running finished))
    assert %{parent: "main"} = agent(ctx, "app-unit-one")

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

    {:ok, row} = cue_until(ctx, &(&1.report == "taken"))

    assert %{"ok" => %{"delegate" => "app-unit-one", "status" => "finished", "report" => text}} =
             Task.await(call)

    assert text == "done #{row.brief_uuid}" and text == row.text

    assert {:ok, %{status: "delivered", via: "call"}} =
             Mailbox.answer_to(ctx.mailbox, row.brief_uuid)
  end

  test "a run_delegate answer whose write fails makes the report due again, first", ctx do
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

    assert %{report: "taken", brief_uuid: u} =
             List.first(Table.with_status(ctx.dtable, "test", ~w(finished)))

    # Due again, for its parent's next transport, which is a later unit's.
    assert {:ok, %{status: "queued", via: nil, kind: "reply"}} = Mailbox.answer_to(ctx.mailbox, u)
  end

  test "run_delegate at its timeout answers unknown with the name; the report stays due", ctx do
    # While the file is there, the stand-in's turn waits on a permission request.
    File.write!(Path.join(ctx.dir, "hold"), "")
    args = Map.put(start_args("unit/one"), "timeout", 10_000)

    assert tool(ctx, "main", "run_delegate", args) ==
             %{"unknown" => %{"delegate" => "app-unit-one", "reason" => "timeout"}}

    [%{name: name, brief_uuid: u}] = Table.with_status(ctx.dtable, "test", ~w(running finished))
    %{session_id: sid} = agent(ctx, name)

    {:ok, _} = await(fn -> requested(ctx, sid, "req-" <> u) end, 10_000)
    {:ok, _} = Stream.write(ctx.stream, sid, {:answer, "req-" <> u, :allow})

    {:ok, _} = cue_until(ctx, &(&1.status == "finished" and &1.report == "taken"))
    assert {:ok, %{status: "queued", from: "app-unit-one"}} = Mailbox.answer_to(ctx.mailbox, u)
  end

  test "a fix is the parent's, once per state, and never acts on a state that moved", ctx do
    File.write!(Path.join(ctx.dir, "hold"), "")
    {req_one, _} = stuck(ctx, "unit/one")
    {req_two, _} = stuck(ctx, "unit/two")
    one = %{"agent" => "app-unit-one"}
    two = %{"agent" => "app-unit-two"}

    assert tool(ctx, "app-old", "interrupt", one) == %{"refused" => "only_parent_fixes"}

    assert tool(ctx, "app-old", "stop", %{"agent" => "main"}) == %{
             "refused" => "main_fixed_by_operator_only"
           }

    assert tool(ctx, "stray", "resume", one) == %{"refused" => ["unknown_agent", "stray"]}
    answer = Map.merge(one, %{"dialog" => req_one, "label" => "maybe"})
    assert tool(ctx, "main", "answer", answer) == %{"refused" => ["bad", "args"]}
    assert {:ok, []} = Acts.rows(ctx.acts)

    # The act reads the state again: one that moved since the claim is not acted on.
    {:ok, state} = Delegates.fix_state(ctx.delegates, "main", "app-unit-one")
    stored = CodingAgentFramework.Store.text(state)
    stale = %{state | offset: state.offset - 1}

    assert {:refused, {:moved, ^state}} =
             Delegates.fix(ctx.delegates, "main", "app-unit-one", :interrupt, stale)

    # What a fix needs of the state is checked before the claim (F-149): a fix the state refuses
    # takes no claim, so the next fix of that state is taken.
    assert tool(ctx, "main", "resume", one) == %{"refused" => "live"}
    assert tool(ctx, "main", "stop", one) == %{"refused" => ["report", "none"]}
    assert {:ok, []} = Acts.rows(ctx.acts)

    # An answer moves the state at once: its request is no longer held.
    for {agent, req} <- [{one, req_one}, {two, req_two}] do
      assert %{"ok" => %{"settled" => %{"ok" => "verified"}}} =
               tool(
                 ctx,
                 "main",
                 "answer",
                 Map.merge(agent, %{"dialog" => req, "label" => "allow"})
               )
    end

    # A claim still open on a state refuses a second fix as claimed.
    {:ok, _} = cue_until(ctx, &(&1.name == "app-unit-two" and &1.status == "finished"))
    {:ok, now} = Delegates.fix_state(ctx.delegates, "main", "app-unit-two")
    {:ok, id} = Acts.claim(ctx.acts, "main", "app-unit-two", now, :stop)
    assert tool(ctx, "main", "stop", two) == %{"refused" => ["claimed", "main"]}

    assert {:ok, [%{state: ^stored} = r1, %{target: "app-unit-two"} = r2, %{id: ^id} = r3]} =
             Acts.rows(ctx.acts)

    assert {r1.outcome, r2.outcome, r3.status} == {"verified", "verified", "claimed"}
    refute "interrupt" in HeadlessStandIn.taken(ctx.dir)
    assert "answer #{req_one}" in HeadlessStandIn.taken(ctx.dir)
    assert "answer #{req_two}" in HeadlessStandIn.taken(ctx.dir)
  end

  # F-147's new-1: a claim settled refused kept its state, so the answer with the right id
  # waited for the state to move. The id is now checked before the claim, as the label is.
  test "an answer's request is checked before its claim, so a wrong id takes nothing", ctx do
    File.write!(Path.join(ctx.dir, "hold"), "")
    {req, _} = stuck(ctx, "unit/one")
    answer = &%{"agent" => "app-unit-one", "dialog" => &1, "label" => "allow"}
    unheld = req <> "-nope"

    assert tool(ctx, "main", "answer", answer.(unheld)) == %{"refused" => ["not_held", unheld]}
    assert tool(ctx, "main", "answer", answer.("")) == %{"refused" => ["not_held", ""]}
    assert {:ok, []} = Acts.rows(ctx.acts)

    # The state was never claimed: the answer with the right id is taken, and moves it.
    assert %{"ok" => %{"claim" => claim, "settled" => %{"ok" => "verified"}}} =
             tool(ctx, "main", "answer", answer.(req))

    assert {:ok, [%{id: ^claim, act: "answer", outcome: "verified"}]} = Acts.rows(ctx.acts)
    assert "answer #{req}" in HeadlessStandIn.taken(ctx.dir)

    # The request is answered, so it is held no more: refused again, with no second claim.
    assert tool(ctx, "main", "answer", answer.(req)) == %{"refused" => ["not_held", req]}
    assert {:ok, [_]} = Acts.rows(ctx.acts)

    # Each call is written and answered, a refused one too.
    assert for(%{tool: "answer", state: state} <- MCP.calls(ctx.mcp), do: state) ==
             List.duplicate("answered", 4)
  end

  test "an interrupt goes in under a claim; a stop only once the report is delivered", ctx do
    args = Map.put(start_args("unit/one"), "timeout", 60_000)
    call = Task.async(fn -> tool(ctx, "main", "run_delegate", args) end)
    {:ok, _} = cue_until(ctx, &(&1.report == "taken"))
    assert %{"ok" => %{"status" => "finished"}} = Task.await(call)

    File.write!(Path.join(ctx.dir, "hold"), "")
    {req, _} = stuck(ctx, "unit/two")
    two = %{"agent" => "app-unit-two"}

    # Whether its result is read before the state is read again is the stand-in's timing.
    assert %{"ok" => %{"settled" => %{"ok" => settled}}} = tool(ctx, "main", "interrupt", two)
    assert settled in ~w(verified not_verified)

    {:ok, row} = cue_until(ctx, &(&1.name == "app-unit-two" and &1.status == "finished"))
    assert {:ok, %{held: []}} = Delegates.fix_state(ctx.delegates, "main", "app-unit-two")
    refute "answer #{req}" in HeadlessStandIn.taken(ctx.dir)

    # run_delegate's report reached its caller; the other one is due for its parent's waiter.
    assert row.report == "taken"
    assert tool(ctx, "main", "stop", two) == %{"refused" => ["report", "queued"]}

    # Its report handed but not delivered is what the stop meets when it acts, after its claim:
    # the claim settles not verified, and the state stays claimed.
    assert tool(ctx, "main", "stop", two) == %{"refused" => ["already_claimed", "main"]}

    assert %{"ok" => %{"done" => "stopped", "settled" => %{"ok" => "verified"}}} =
             tool(ctx, "main", "stop", %{"agent" => "app-unit-one"})

    assert {:ok, [_, %{outcome: "not_verified"}, %{target: "app-unit-one", outcome: "verified"}]} =
             Acts.rows(ctx.acts)

    assert "interrupt" in HeadlessStandIn.taken(ctx.dir)
    assert "end" in HeadlessStandIn.taken(ctx.dir)
  end

  test "resume starts a dead delegate again through Delegates' resume path, once", ctx do
    File.write!(Path.join(ctx.dir, "hold"), "")
    stuck(ctx, "unit/one")
    one = %{"agent" => "app-unit-one"}
    [pid] = File.ls!(Path.join(ctx.dir, "pids"))
    kill(pid)

    # Nothing cues Delegates here, so its own resume does not come first. Sessions sees the
    # exit at its cues; a read of it after each cue answers once the cue is handled.
    {:ok, _} =
      await(
        fn ->
          Sessions.cue(ctx.sessions, %{topic: "stream:test", ids: []})
          Sessions.viewer_argv(ctx.sessions, "app-unit-one")

          case Delegates.fix_state(ctx.delegates, "main", "app-unit-one") do
            {:ok, %{gone: true, ended: true}} = ok -> ok
            other -> other
          end
        end,
        10_000
      )

    File.rm!(Path.join(ctx.dir, "hold"))

    assert %{"ok" => %{"done" => "resuming", "settled" => %{"ok" => "verified"}}} =
             tool(ctx, "main", "resume", one)

    # Once the resumed process has finished, its state holds still for the next claim.
    assert {:ok, %{resumes: 1}} = cue_until(ctx, &(&1.status == "finished"))
    # A second resume is refused by the state it would claim, so it takes no claim (F-149).
    assert tool(ctx, "main", "resume", one) == %{"refused" => "resumed_once"}
    assert {:ok, [%{outcome: "verified"}]} = Acts.rows(ctx.acts)
  end

  test "the operator acts as a parent of every main session, under its own name", ctx do
    File.write!(Path.join(ctx.dir, "hold"), "")
    start = &Operator.start_delegate(ctx.mcp, &1, "app", "unit/one", "opus", "Review it.")

    # It starts a delegate under a main session it names, which must be one.
    assert {:refused, :main_session_only} = start.("app-old")
    assert {:ok, %{delegate: "app-unit-one"}} = start.("main")
    {:ok, %{session_id: sid, brief_uuid: u}} = await(fn -> running(ctx, "app-unit-one") end)
    {:ok, _} = await(fn -> requested(ctx, sid, "req-" <> u) end, 10_000)

    # Its fix acts as the delegate's parent would, and the claim is under its own name.
    assert {:ok, %{claim: claim, settled: {:ok, _}}} =
             Operator.answer(ctx.mcp, "app-unit-one", "req-" <> u, "deny")

    assert {:ok, %{actor: "op", target: "app-unit-one", act: "answer"}} =
             Acts.get(ctx.acts, claim)

    assert "answer req-#{u}" in HeadlessStandIn.taken(ctx.dir)

    # A main session's own fixes wait for `Mains`, and no agent fixes one. A service's fix goes
    # to `Services` as the operator's. No token calls as the operator.
    assert Operator.interrupt(ctx.mcp, "main") == {:refused, {:not_built, :main_fix}}

    assert tool(ctx, "lmain", "interrupt", %{"agent" => "main"}) == %{
             "refused" => "main_fixed_by_operator_only"
           }

    assert Operator.service_restart(ctx.mcp, "web") == {:unknown, {:unused, "op", "web"}}
    assert MCP.issue(ctx.mcp, "op") == {:refused, {:reserved, "op"}}

    assert for(%{agent: "op", tool: t} <- MCP.calls(ctx.mcp), do: t) ==
             ~w(start_delegate start_delegate answer interrupt service_restart)
  end

  # `Services`, which this test does not run: it says who asked.
  def restart(:unused, caller, name, _opts), do: {:unknown, {:unused, caller, name}}

  defp running(ctx, name) do
    case Enum.find(Table.with_status(ctx.dtable, "test", ~w(running)), &(&1.name == name)) do
      nil -> nil
      row -> {:ok, Map.put(row, :session_id, agent(ctx, name).session_id)}
    end
  end

  # The delegate's agent row, `Sessions`' own.
  defp agent(ctx, name), do: Sessions.Table.get(ctx.table, "test", name)

  # Starts a delegate whose brief waits on a permission request, and answers the request's id
  # once Stream has read it.
  defp stuck(ctx, branch) do
    {:ok, _} = MCP.call(ctx.mcp, "main", "start_delegate", start_args(branch))
    name = "app-" <> String.replace(branch, "/", "-")
    rows = Table.with_status(ctx.dtable, "test", ~w(running))
    %{brief_uuid: u} = Enum.find(rows, &(&1.name == name))
    %{session_id: sid} = agent(ctx, name)
    {:ok, _} = await(fn -> requested(ctx, sid, "req-" <> u) end, 10_000)
    {"req-" <> u, sid}
  end

  # Mailbox is cued too: the brief is its row.
  defp requested(ctx, sid, req) do
    {:ok, _} = Stream.read(ctx.stream)
    Mailbox.cue(ctx.mailbox, %{topic: "stream:test", ids: []})
    Mailbox.status(ctx.mailbox, 0)
    {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
    row = Enum.find(rows, &(&1.session == sid))
    if row && row.requests[req], do: {:ok, row}
  end

  # Reads Stream and cues Delegates until a delegate's row satisfies `ready?`, and answers it.
  defp cue_until(ctx, ready?) do
    await(
      fn ->
        {:ok, _} = Stream.read(ctx.stream)
        Delegates.cue(ctx.delegates, %{topic: "stream:test", ids: []})
        Mailbox.cue(ctx.mailbox, %{topic: "stream:test", ids: []})
        Mailbox.status(ctx.mailbox, 0)
        :sys.get_state(ctx.delegates)
        row = Enum.find(Table.with_status(ctx.dtable, "test", ~w(running finished)), ready?)
        if row, do: {:ok, row}
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
        Mailbox.cue(ctx.mailbox, %{topic: "stream:test", ids: []})
        Mailbox.status(ctx.mailbox, 0)
        :sys.get_state(ctx.delegates)

        for t <- ~w(sessions:test stream:test transcripts:test:work),
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
    # A main session's state is its session file's (R9 part 2); this one has no process.
    assert %{"state" => "gone", "waits_on" => [], "subagents" => []} = main

    # The transcript, written as Claude Code would, with a last line not yet whole.
    {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
    %{session_id: sid} = Enum.at(tree.agents, 1)
    %{transcript: path} = Enum.find(rows, &(&1.session == sid))
    [one, two] = for p <- ~w(p1 p2), do: ~s({"type":"user","promptId":"#{p}","message":{}}\n)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, one <> two <> ~s({"type":"us))
    {:ok, %{failed: []}} = Transcripts.read(ctx.transcripts, [{"work", sid, path}])
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
