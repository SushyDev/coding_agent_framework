defmodule CodingAgentFramework.MailboxTest do
  @moduledoc """
  `Mailbox` over a real `Delegates`, `Sessions` and `Stream`, real dtach and tmux, a real git
  repository in this test's own directory, and the headless stand-in for Claude Code. Each test
  cues as the embedding app would and names the `Team.tla` property it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Delegates, Grants, HeadlessStandIn, Mailbox}
  alias CodingAgentFramework.{SessionsSetup, Stream, Transcripts, Usage}
  alias CodingAgentFramework.Mailbox.Table

  setup {SessionsSetup, :sessions}

  setup ctx do
    repo = Path.join(ctx.dir, "repo")
    git = [program!(:git), "-c", "user.name=t", "-c", "user.email=t@t"]

    for args <- [
          ["init", "-q", "-b", "main", repo],
          ["-C", repo, "commit", "-qm", "i", "--allow-empty"]
        ],
        do: {_, 0} = System.cmd(program!(:env), ["-i", "HOME=#{ctx.dir}" | git] ++ args)

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

    launch =
      SessionsSetup.headless(ctx, :at_start) |> Keyword.take([:claude, :env, :tool_timeout])

    dopts = [host: "test", db: db, sessions_db: db, sessions: ctx.sessions, stream: ctx.stream]
    dopts = dopts ++ [usage: usage, accounts: accounts, transcripts: transcripts]

    delegates =
      start_supervised!({Delegates, dopts ++ [launch: launch, projects: %{"app" => project}]})

    {:ok, dtable} = Delegates.Table.open(db)
    statuses = ~w(starting resuming running finished failed refused)
    grants = Grants.new(fn -> Delegates.Table.with_status(dtable, "test", statuses) end)
    mopts = [db: db, grants: grants, stream: ctx.stream, delegates_db: db, host: "test"]
    {:ok, mtable} = Table.open(db)

    {:ok,
     delegates: delegates, dtable: dtable, mopts: mopts, mtable: mtable, mailbox: restart(mopts)}
  end

  test "only along an edge: a message off one is refused, and no row is stored", ctx do
    # Send's Edge: a delegate messages its main session only; Grants knows no other name.
    starting(ctx, "unit/a")
    m = ctx.mailbox
    assert {:refused, {:unknown_agent, "nobody"}} = Mailbox.message(m, "main", "nobody", "hi")
    assert {:refused, :along_edges} = Mailbox.message(m, "app-unit-a", "app-unit-a", "hi")
    assert {:refused, {:bad, :message}} = Mailbox.message(m, "main", "app-unit-a", "")
    assert Table.open_rows(ctx.mtable) == []
    assert {:refused, :no_message} = Mailbox.status(m, 1)

    # A main session's delivery waits for Screen: the row stays queued, with why.
    assert {:ok, {:queued, id}} = Mailbox.message(m, "app-unit-a", "main", "report")
    {:ok, _} = Stream.read(ctx.stream)
    assert {:ok, %{status: "queued", attempt: ":no_delivery"}} = until(ctx, id, & &1.attempt)
  end

  test "stored before delivered, only into an ended turn, once, in order per sender and addressee",
       ctx do
    # The brief's turn waits on a permission, so the delegate's turn runs.
    hold = Path.join(ctx.dir, "hold")
    File.write!(hold, "")
    {sid, brief} = started(ctx, "unit/a")
    {:ok, %{state: :held}} = await(fn -> fold(ctx, sid).requests |> Map.fetch("req-#{brief}") end)

    assert {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "main", "app-unit-a", "first")
    assert {:ok, {:queued, two}} = Mailbox.message(ctx.mailbox, "main", "app-unit-a", "second")
    cue(ctx)
    assert [%{status: "queued"}, %{status: "queued"}] = Table.open_rows(ctx.mtable)

    # The turn ends; Delegates holds its report; then each message goes in, the first first.
    File.rm!(hold)
    {:ok, _} = Stream.write(ctx.stream, sid, {:answer, "req-#{brief}", :allow})
    assert {:ok, %{status: "delivered", uuid: u1}} = until(ctx, one, &(&1.status == "delivered"))
    assert {:ok, %{status: "delivered", uuid: u2}} = until(ctx, two, &(&1.status == "delivered"))
    assert {:ok, %{status: "delivered"}} = Mailbox.status(ctx.mailbox, two)

    assert HeadlessStandIn.taken(ctx.dir) ==
             ["message #{brief}", "answer req-#{brief}", "message #{u1}", "message #{u2}"]
  end

  test "ended delegate marked: a queued message is settled ended, never written", ctx do
    {sid, brief} = started(ctx, "unit/a")
    finished(ctx)
    {:ok, _} = Stream.end_session(ctx.stream, sid)
    {:ok, _} = await(fn -> if fold(ctx, sid).gone, do: {:ok, 1} end)

    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "main", "app-unit-a", "late")
    {:ok, _} = until(ctx, id, &(&1.status == "ended"))
    assert {:ok, %{status: "ended"}} = Mailbox.status(ctx.mailbox, id)
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{brief}", "end"]
  end

  test "restart settles a marked row: from the replay, or queued again under its uuid", ctx do
    {sid, brief} = started(ctx, "unit/a")
    finished(ctx)
    GenServer.stop(ctx.mailbox)

    # One the restart cut off after the write: the replay settles it delivered, not resent.
    {:ok, %{uuid: went}} = Stream.write(ctx.stream, sid, {:message, Stream.uuid(), "went"})
    {:ok, _} = await(fn -> if fold(ctx, sid).idle, do: {:ok, 1} end)
    a = Table.queued(ctx.mtable, "main", "app-unit-a", "went", went)
    Table.update(ctx.mtable, a, status: "sending", session_id: sid)

    # One cut off between its mark and the write: queued again, then written once.
    b = Table.queued(ctx.mtable, "main", "app-unit-a", "cut", Stream.uuid())
    Table.update(ctx.mtable, b, status: "sending", session_id: sid)

    mailbox = restart(ctx.mopts)
    Process.put(:mailbox, mailbox)
    assert {:ok, _} = until(ctx, a, &(&1.status == "delivered"))
    assert {:ok, %{uuid: cut}} = until(ctx, b, &(&1.status == "delivered"))
    assert HeadlessStandIn.taken(ctx.dir) == Enum.map([brief, went, cut], &"message #{&1}")
  end

  # ReplyOnce, ReplyToMain, ReplyNamesMessage.
  test "a reply: a delivered message's result is stored once, to the main session, naming it",
       ctx do
    {_sid, _brief} = started(ctx, "unit/a")
    finished(ctx)
    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "main", "app-unit-a", "why?")
    assert {:ok, %{uuid: u}} = until(ctx, id, &(&1.status == "delivered"))

    # Its turn's result is the reply; a main session's delivery waits for Screen.
    {:ok, _} = await(fn -> cue(ctx) && match?([_], replies(ctx, u)) && {:ok, 1} end, 10_000)
    [r] = replies(ctx, u)
    assert %{from_agent: "app-unit-a", to_agent: "main", text: "done " <> ^u} = r
    assert {:ok, %{reply_to: ^u, status: "queued"}} = until(ctx, r.id, & &1.attempt)
    assert {:ok, %{subtype: "success", is_error: false}} = Mailbox.status(mailbox(ctx), r.id)
    assert {:ok, %{reply_to: nil}} = Mailbox.status(ctx.mailbox, id)

    # Once: repeated cues and a restart, which reads each log again, store no second one.
    cue(ctx)
    GenServer.stop(ctx.mailbox)
    Process.put(:mailbox, restart(ctx.mopts))
    cue(ctx)
    cue(ctx)
    assert [%{id: same}] = replies(ctx, u)
    assert same == r.id
  end

  # ReplyOrNotice, ReplyOrNoticeComes, ReplyOnce: the delegate killed mid-turn.
  test "the notice: a turn the process's end cut gets one notice, never a reply", ctx do
    {sid, _brief} = started(ctx, "unit/a")
    finished(ctx)
    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "main", "app-unit-a", "ask it")
    assert {:ok, %{uuid: u}} = until(ctx, id, &(&1.status == "delivered"))
    {:ok, _} = await(fn -> fold(ctx, sid).requests |> Map.fetch("req-#{u}") end)

    # The turn waits on a permission; the process ends before any result.
    HeadlessStandIn.kill_all(ctx.dir)
    {:ok, _} = await(fn -> cue(ctx) && match?([_], replies(ctx, u)) && {:ok, 1} end, 10_000)
    [n] = replies(ctx, u)
    assert %{from_agent: "framework", to_agent: "main", subtype: nil} = n
    assert n.text =~ "ended before it answered"
    assert {:ok, %{status: "queued", attempt: ":no_delivery"}} = until(ctx, n.id, & &1.attempt)

    # Once, and never a reply too: repeated cues and a restart store nothing more.
    GenServer.stop(mailbox(ctx))
    Process.put(:mailbox, restart(ctx.mopts))
    cue(ctx)
    cue(ctx)
    assert [%{id: same, from_agent: "framework"}] = replies(ctx, u)
    assert same == n.id
    assert {:ok, %{status: "delivered"}} = Mailbox.status(mailbox(ctx), id)
  end

  # ReplyNamesMessage: the fold keeps the message's result, so the turn the delegate starts
  # right after it neither replaces the reply nor becomes one, nor the report.
  test "a self-started turn's result is never taken as a reply or a report", ctx do
    {sid, brief} = started(ctx, "unit/a")
    finished(ctx)
    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "main", "app-unit-a", "self go")
    %{uuid: u} = Table.get(ctx.mtable, id)

    # Both results are folded before Mailbox reads a reply: the self-started one is the last.
    {:ok, _} =
      await(fn ->
        f = fold(ctx, sid)
        # Only a message not yet written needs Mailbox; once written, no cue reads its reply.
        unless f.messages[u], do: Mailbox.cue(mailbox(ctx), %{topic: "stream:test"})
        if f.messages[u] && f.last_result.user_message_uuids == [], do: {:ok, f}
      end)

    {:ok, _} = await(fn -> cue(ctx) && match?([_], replies(ctx, u)) && {:ok, 1} end, 10_000)
    assert [%{from_agent: "app-unit-a", text: "done " <> ^u}] = replies(ctx, u)
    assert [%{reply_to: ^u}] = Enum.filter(Table.open_rows(ctx.mtable), & &1.reply_to)
    assert {:ok, [%{text: "done " <> ^brief}]} = Delegates.held(ctx.delegates, "main")
  end

  # A reply carries its result's subtype: an interrupted turn is told from an answer.
  test "a reply's subtype is kept: an interrupted turn's reply says error_during_execution",
       ctx do
    {sid, _brief} = started(ctx, "unit/a")
    finished(ctx)
    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "main", "app-unit-a", "ask it")
    assert {:ok, %{uuid: u}} = until(ctx, id, &(&1.status == "delivered"))
    {:ok, _} = await(fn -> fold(ctx, sid).requests |> Map.fetch("req-#{u}") end)
    {:ok, _} = Stream.interrupt(ctx.stream, sid)

    {:ok, _} = await(fn -> cue(ctx) && match?([_], replies(ctx, u)) && {:ok, 1} end, 10_000)
    [r] = replies(ctx, u)

    assert {:ok, %{from: "app-unit-a", reply_to: ^u, subtype: "error_during_execution"}} =
             Mailbox.status(mailbox(ctx), r.id)
  end

  defp replies(ctx, uuid), do: Enum.filter(Table.open_rows(ctx.mtable), &(&1.reply_to == uuid))

  defp restart(mopts) do
    spec = Supervisor.child_spec({Mailbox, mopts}, id: make_ref(), restart: :temporary)
    start_supervised!(spec)
  end

  defp mailbox(ctx), do: Process.get(:mailbox, ctx.mailbox)

  # A delegate's row as a start leaves it before Sessions answers: in the tree, no process yet.
  defp starting(ctx, branch) do
    row = %{host: "test", parent: "main", project: "app", branch: branch, account: "work"}
    row = Map.merge(row, %{model: "opus", brief: "b", brief_uuid: Stream.uuid(), deadline: 0})
    name = "app-" <> String.replace(branch, "/", "-")
    Delegates.Table.starting(ctx.dtable, Map.put(row, :name, name))
  end

  defp started(ctx, branch) do
    {:ok, %{session_id: sid, brief: {:ok, %{uuid: u}}}} =
      Delegates.start_delegate(ctx.delegates, "main", "app", branch, "opus", "Review it.")

    {sid, u}
  end

  # Delegates holds the delegate's report: its brief's turn has ended.
  defp finished(ctx) do
    ready? = fn -> cue(ctx) && match?({:ok, [_]}, Delegates.held(ctx.delegates, "main")) end
    {:ok, _} = await(fn -> if ready?.(), do: {:ok, 1} end, 10_000)
  end

  # Reads Stream, then cues Delegates and Mailbox as the embedding app's wiring would; a call
  # after each cast answers once it is handled.
  defp cue(ctx) do
    {:ok, _} = Stream.read(ctx.stream)
    Delegates.cue(ctx.delegates, %{topic: "stream:test", ids: []})
    Delegates.held(ctx.delegates, "main")
    Mailbox.cue(mailbox(ctx), %{topic: "stream:test", ids: []})
    Mailbox.status(mailbox(ctx), 0)
  end

  defp until(ctx, id, ready?) do
    check = fn row -> if ready?.(row), do: {:ok, row}, else: row end
    await(fn -> cue(ctx) && check.(Table.get(ctx.mtable, id)) end, 10_000)
  end

  defp fold(ctx, sid) do
    {:ok, _} = Stream.read(ctx.stream)
    {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
    Enum.find(rows, &(&1.session == sid))
  end
end
