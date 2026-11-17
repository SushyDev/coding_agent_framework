defmodule CodingAgentFramework.MailboxTest do
  @moduledoc """
  `Mailbox` over a real `Sessions` and `Stream`, real dtach and tmux in this test's own
  directory, and the headless stand-in for Claude Code. Each test starts a delegate's session
  through `Sessions` as `Delegates` would, stores its brief, cues as the embedding app would,
  and names the `Delivery.tla` property it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Grants, HeadlessStandIn, Mailbox, Sessions, SessionsSetup, Stream}
  alias CodingAgentFramework.Mailbox.{Table, Transport}

  doctest Transport
  doctest Transport.Stream
  doctest Transport.Call

  setup {SessionsSetup, :sessions}

  setup ctx do
    tree = [
      %{name: "main", project: "app", parent: nil},
      %{name: "d1", project: "app", parent: "main"}
    ]

    grants = Grants.new(fn -> tree end)
    db = Path.join(ctx.dir, "caf.db")
    mopts = [db: db, grants: grants, stream: ctx.stream, sessions_db: db, host: "test"]
    {:ok, mtable} = Table.open(db)
    {:ok, mopts: mopts, mtable: mtable, mailbox: restart(mopts)}
  end

  test "only along an edge: a message off one is refused, and no row is stored", ctx do
    m = ctx.mailbox
    assert {:refused, {:unknown_agent, "nobody"}} = Mailbox.message(m, "main", "nobody", "hi")
    assert {:refused, :along_edges} = Mailbox.message(m, "d1", "d1", "hi")
    assert {:refused, {:bad, :message}} = Mailbox.message(m, "main", "d1", "")
    assert Table.open_rows(ctx.mtable) == []
    assert {:refused, :no_message} = Mailbox.status(m, 1)

    # With no `intake:` a main session has no transport: the row stays queued, with why.
    assert {:ok, {:queued, id}} = Mailbox.message(m, "d1", "main", "report")
    assert {:ok, %{status: "queued", attempt: "no_delivery"}} = until(ctx, id, & &1.attempt)
  end

  # OnlyIntoEndedTurn, InOrder, AtMostOnce: the brief first, then each message once its turn
  # ended, in the order stored.
  test "stored before delivered, only into an ended turn, once, in order", ctx do
    hold = Path.join(ctx.dir, "hold")
    File.write!(hold, "")
    {sid, brief} = started(ctx, "d1")
    {:ok, _} = await(fn -> fold(ctx, sid).requests |> Map.fetch("req-#{brief}") end)

    assert {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "main", "d1", "first")
    assert {:ok, {:queued, two}} = Mailbox.message(ctx.mailbox, "main", "d1", "second")
    cue(ctx)
    assert [%{status: "queued"}, %{status: "queued"}] = open_to(ctx, "d1")

    File.rm!(hold)
    {:ok, _} = Stream.write(ctx.stream, sid, {:answer, "req-#{brief}", :allow})
    assert {:ok, %{uuid: u1, via: "stream"}} = until(ctx, one, &(&1.status == "delivered"))
    assert {:ok, %{uuid: u2}} = until(ctx, two, &(&1.status == "delivered"))
    assert {:ok, %{status: "delivered", kind: "msg"}} = Mailbox.status(mailbox(ctx), two)

    assert HeadlessStandIn.taken(ctx.dir) ==
             ["message #{brief}", "answer req-#{brief}", "message #{u1}", "message #{u2}"]
  end

  # EndedFirst, EndedNotDelivered: a session that ended for good, or a start that was refused.
  test "a delegate that ended takes nothing: its queued rows are settled ended", ctx do
    {sid, brief} = started(ctx, "d1")
    until_taken(ctx, ["message #{brief}"])
    {:ok, _} = Stream.end_session(ctx.stream, sid)
    {:ok, _} = await(fn -> if fold(ctx, sid).gone, do: {:ok, 1} end)

    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "main", "d1", "late")
    {:ok, _} = until(ctx, id, &(&1.status == "ended"))
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{brief}", "end"]

    # A start that was refused: Delegates says so, and its brief never goes.
    {:ok, {:queued, b}} = Mailbox.brief(mailbox(ctx), "main", "d2", "Go.", Stream.uuid())
    assert {:ok, [^b]} = Mailbox.ended(mailbox(ctx), "d2")
    assert %{status: "ended"} = Table.get(ctx.mtable, b)

    # An agent row `ended` (Delegates asked Sessions): a message is settled ended, but a later
    # start's brief, stored before that start's row, waits for it.
    {:ok, _} =
      await(fn ->
        Sessions.cue(ctx.sessions, %{topic: "stream:test", ids: []})
        ok_ended(Sessions.ended(ctx.sessions, "d1"))
      end)

    assert {:ok, {:queued, m}} = Mailbox.message(ctx.mailbox, "main", "d1", "later")
    {:ok, _} = until(ctx, m, &(&1.status == "ended"))
    {:ok, {:queued, next}} = Mailbox.brief(mailbox(ctx), "main", "d1", "Again.", Stream.uuid())
    cue(ctx)
    assert %{status: "queued"} = Table.get(ctx.mtable, next)
  end

  # Sessions settles the stopped row at a cue; until then the end is refused.
  defp ok_ended({:ok, :ended} = ok), do: ok
  defp ok_ended(_), do: nil

  # SettleReplay, and a row marked whose line Stream never marked: due again, then once.
  test "a restart settles a marked row: from the replay, or due again under its uuid", ctx do
    {sid, brief} = started(ctx, "d1")
    until_taken(ctx, ["message #{brief}"])
    GenServer.stop(ctx.mailbox)

    # One the restart cut off after the write: the replay settles it delivered, not resent.
    {:ok, %{uuid: went}} = Stream.write(ctx.stream, sid, {:message, Stream.uuid(), "went"})
    {:ok, _} = await(fn -> if fold(ctx, sid).idle, do: {:ok, 1} end)
    a = Table.store(ctx.mtable, %{from: "main", to: "d1", text: "went", uuid: went, kind: "msg"})
    Table.update(ctx.mtable, a, status: "sending", via: "stream", session_id: sid, at: 0)

    # One cut off between its mark and the write: due again, first, then written once.
    b = row(ctx, "cut")
    c = row(ctx, "after")
    Table.update(ctx.mtable, b, status: "sending", via: "stream", session_id: sid, at: 0)

    Process.put(:mailbox, restart(ctx.mopts))
    assert {:ok, _} = until(ctx, a, &(&1.status == "delivered"))
    assert {:ok, %{uuid: cut, again: 1}} = until(ctx, b, &(&1.status == "delivered"))
    assert {:ok, %{uuid: after_}} = until(ctx, c, &(&1.status == "delivered"))

    assert HeadlessStandIn.taken(ctx.dir) ==
             Enum.map([brief, went, cut, after_], &"message #{&1}")
  end

  # SettleExit: undelivered is final; due again first, under its same uuid, to the resumed
  # process only, before a row stored later; a resumed delegate's word to go on goes first too.
  test "a line its process never read is undelivered, and goes first, same uuid, to the next",
       ctx do
    {sid, brief} = started(ctx, "d1")
    until_taken(ctx, ["message #{brief}"])
    {:ok, _} = await(fn -> if fold(ctx, sid).idle, do: {:ok, 1} end)

    # The process stops reading: the line is claimed into its FIFO and never taken.
    [pid] = File.ls!(Path.join(ctx.dir, "pids"))
    signal("STOP", pid)
    assert {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "main", "d1", "first")
    assert {:ok, %{uuid: u1}} = until(ctx, one, &(&1.status == "sending"))
    {:ok, _} = await(fn -> if fold(ctx, sid).lines == %{}, do: {:ok, 1} end)
    signal("KILL", pid)

    assert {:ok, %{uuid: ^u1, again: 1, via: nil}} =
             until(ctx, one, &(&1.status == "queued" and &1.again == 1))

    assert {:ok, {:queued, two}} = Mailbox.message(mailbox(ctx), "main", "d1", "second")
    go = Stream.uuid()
    {:ok, {:queued, _}} = Mailbox.go_on(mailbox(ctx), "d1", "Go on.", go)
    resume(ctx, "d1", sid)

    assert {:ok, %{uuid: ^u1}} = until(ctx, one, &(&1.status == "delivered"))
    assert {:ok, %{uuid: u2}} = until(ctx, two, &(&1.status == "delivered"))

    assert HeadlessStandIn.taken(ctx.dir) ==
             ["message #{brief}", "message #{u1}", "message #{go}", "message #{u2}"]
  end

  # ReplyOnce, ReplyNamesItsRow: a delivered message's result, once, to its sender.
  test "a reply: a delivered message's result is stored once, to its sender, naming it", ctx do
    {_sid, brief} = started(ctx, "d1")
    until_taken(ctx, ["message #{brief}"])
    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "main", "d1", "why?")
    assert {:ok, %{uuid: u}} = until(ctx, id, &(&1.status == "delivered"))

    {:ok, _} = await(fn -> cue(ctx) && match?([_], answers(ctx, u)) && {:ok, 1} end, 10_000)
    [r] = answers(ctx, u)
    assert %{from_agent: "d1", to_agent: "main", text: "done " <> ^u, kind: "reply"} = r
    assert {:ok, %{subtype: "success", is_error: false}} = Mailbox.status(mailbox(ctx), r.id)

    # Once: repeated cues and a restart, which reads each log again, store no second one.
    GenServer.stop(mailbox(ctx))
    Process.put(:mailbox, restart(ctx.mopts))
    cue(ctx)
    cue(ctx)
    assert [%{id: same}] = answers(ctx, u)
    assert same == r.id
    # The brief's answer is Delegates': Mailbox stores none of its own.
    assert answers(ctx, brief) == []

    # The app's word is answered to the delegate's parent, the sender of its brief.
    {:ok, {:queued, w}} = Mailbox.notify(mailbox(ctx), "d1", "A job ended.")
    assert {:ok, %{uuid: wu}} = until(ctx, w, &(&1.status == "delivered"))
    {:ok, _} = await(fn -> cue(ctx) && match?([_], answers(ctx, wu)) && {:ok, 1} end, 10_000)
    assert [%{from_agent: "d1", to_agent: "main"}] = answers(ctx, wu)
  end

  # ReplyOrNotice, AnswerComes: the process ends in the message's turn.
  test "the notice: a turn the process's end cut gets one notice, never a reply", ctx do
    {sid, brief} = started(ctx, "d1")
    until_taken(ctx, ["message #{brief}"])
    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "main", "d1", "ask it")
    assert {:ok, %{uuid: u}} = until(ctx, id, &(&1.status == "delivered"))
    {:ok, _} = await(fn -> fold(ctx, sid).requests |> Map.fetch("req-#{u}") end)

    HeadlessStandIn.kill_all(ctx.dir)
    {:ok, _} = await(fn -> cue(ctx) && match?([_], answers(ctx, u)) && {:ok, 1} end, 10_000)
    [n] = answers(ctx, u)
    assert %{from_agent: "framework", to_agent: "main", kind: "notice"} = n
    assert n.text =~ "ended before it answered"

    GenServer.stop(mailbox(ctx))
    Process.put(:mailbox, restart(ctx.mopts))
    cue(ctx)
    assert [%{id: same, from_agent: "framework"}] = answers(ctx, u)
    assert same == n.id
  end

  # ReplyNamesItsRow: the fold keeps the message's result, so the turn the delegate starts
  # right after it neither replaces the reply nor becomes one.
  test "a self-started turn's result is never taken as a reply", ctx do
    {sid, brief} = started(ctx, "d1")
    until_taken(ctx, ["message #{brief}"])
    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "main", "d1", "self go")
    %{uuid: u} = Table.get(ctx.mtable, id)

    {:ok, _} =
      await(fn ->
        f = fold(ctx, sid)
        unless f.messages[u], do: cue(ctx)
        if f.messages[u] && f.last_result.user_message_uuids == [], do: {:ok, f}
      end)

    {:ok, _} = await(fn -> cue(ctx) && match?([_], answers(ctx, u)) && {:ok, 1} end, 10_000)
    assert [%{from_agent: "d1", text: "done " <> ^u}] = answers(ctx, u)
  end

  test "a reply's subtype is kept: an interrupted turn's reply says error_during_execution",
       ctx do
    {sid, brief} = started(ctx, "d1")
    until_taken(ctx, ["message #{brief}"])
    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "main", "d1", "ask it")
    assert {:ok, %{uuid: u}} = until(ctx, id, &(&1.status == "delivered"))
    {:ok, _} = await(fn -> fold(ctx, sid).requests |> Map.fetch("req-#{u}") end)
    {:ok, _} = Stream.interrupt(ctx.stream, sid)

    {:ok, _} = await(fn -> cue(ctx) && match?([_], answers(ctx, u)) && {:ok, 1} end, 10_000)
    [r] = answers(ctx, u)

    assert {:ok, %{reply_to: ^u, subtype: "error_during_execution"}} =
             Mailbox.status(mailbox(ctx), r.id)
  end

  # The call transport: Told, DeliveredWasTaken; AnsweredOnFailure; TakeAfterDeadline.
  test "a waiting call takes the report when it comes, and the caller's word settles it", ctx do
    m = ctx.mailbox
    key = Stream.uuid()
    wait = caller(m, key, 10_000)

    # Under load the caller may reach Mailbox late: the wait is as long as the caller's.
    {:ok, _} =
      await(
        fn -> if Mailbox.await(m, "main", key, 0) == {:refused, :awaited}, do: {:ok, 1} end,
        10_000
      )

    {:ok, {:queued, id}} = Mailbox.report(m, "d1", "main", key, {:reply, "Done.", %{}})
    assert_receive {:took, {:ok, %{id: ^id, kind: "reply", text: "Done."}}}, 5_000
    assert %{status: "sending", via: "call"} = Table.get(ctx.mtable, id)
    assert {:refused, {:status, "sending"}} = Mailbox.await(m, "main", key, 1)
    assert {:ok, :delivered} = settle(wait, :written)
    assert {:ok, %{status: "delivered", reply_to: ^key}} = Mailbox.answer_to(m, key)
    assert {:refused, {:not_taken, "delivered"}} = Mailbox.told(m, id, :written)
    # One answer per key: a second report under the same key is not stored.
    assert {:ok, :stored_before} = Mailbox.report(m, "d1", "main", key, {:notice, "again"})

    # A write that failed: due again, first.
    key = Stream.uuid()
    {:ok, {:queued, id}} = Mailbox.report(m, "d1", "main", key, {:notice, "Killed twice."})
    wait = caller(m, key, 10_000)
    assert_receive {:took, {:ok, %{id: ^id, kind: "notice", text: "Killed twice."}}}, 5_000
    assert {:ok, :queued} = settle(wait, :failed)
    assert %{status: "queued", again: 1, via: nil} = Table.get(ctx.mtable, id)

    # Past its deadline, a call takes nothing: the row stays due for another transport.
    key = Stream.uuid()
    assert {:unknown, :timeout} = Mailbox.await(m, "main", key, 50)
    {:ok, {:queued, id}} = Mailbox.report(m, "d1", "main", key, {:reply, "Late.", %{}})
    cue(ctx)
    assert %{status: "queued"} = Table.get(ctx.mtable, id)
  end

  # CallerSeen and SettleCut: the process that waits ends, or a restart ends the call.
  test "a row a call took is due again when the caller ends, and after a restart", ctx do
    m = ctx.mailbox
    key = Stream.uuid()
    {:ok, {:queued, id}} = Mailbox.report(m, "d1", "main", key, {:reply, "Done.", %{}})
    wait = caller(m, key, 10_000)
    assert_receive {:took, {:ok, %{id: ^id}}}, 5_000
    assert :ended = settle(wait, nil)
    {:ok, _} = until(ctx, id, &(&1.status == "queued" and &1.again == 1))

    wait = caller(m, key, 10_000)
    assert_receive {:took, {:ok, %{id: ^id}}}, 5_000
    GenServer.stop(m)
    Process.put(:mailbox, restart(ctx.mopts))
    assert {:ok, %{again: 1}} = until(ctx, id, &(&1.status == "queued"))
    assert {:refused, :no_mailbox} = settle(wait, :written)
  end

  defp answers(ctx, uuid),
    do: Enum.filter(all(ctx), &(&1.reply_to == uuid))

  defp all(ctx), do: Enum.map(1..200, &Table.get(ctx.mtable, &1)) |> Enum.reject(&is_nil/1)

  defp open_to(ctx, to), do: Enum.filter(Table.open_rows(ctx.mtable), &(&1.to_agent == to))

  defp row(ctx, text),
    do:
      Table.store(ctx.mtable, %{
        from: "main",
        to: "d1",
        text: text,
        uuid: Stream.uuid(),
        kind: "msg"
      })

  # A caller as MCP's: one process waits on the row, sends what it took, then says how its
  # write went and ends.
  defp caller(mailbox, key, timeout) do
    test = self()

    Task.async(fn ->
      took = Mailbox.await(mailbox, "main", key, timeout)
      send(test, {:took, took})

      receive do
        {:settle, nil} -> :ended
        {:settle, said} -> Mailbox.told(mailbox, elem(took, 1).id, said)
      end
    end)
  end

  defp settle(wait, said) do
    send(wait.pid, {:settle, said})
    Task.await(wait)
  end

  defp restart(mopts) do
    spec = Supervisor.child_spec({Mailbox, mopts}, id: make_ref(), restart: :temporary)
    start_supervised!(spec)
  end

  defp mailbox(ctx), do: Process.get(:mailbox, ctx.mailbox)

  # A delegate's session, started as Delegates starts one, and its brief stored first.
  defp started(ctx, name) do
    brief = Stream.uuid()
    {:ok, {:queued, _}} = Mailbox.brief(mailbox(ctx), "main", name, "Review it.", brief)
    launch = SessionsSetup.headless(ctx, :at_start)
    {:ok, %{session_id: sid}} = Sessions.start(ctx.sessions, name, ctx.account, launch)
    {sid, brief}
  end

  # Resumes `name` once Sessions has settled its killed process's row, as Delegates does.
  defp resume(ctx, name, sid) do
    {:ok, _} =
      await(
        fn ->
          Sessions.cue(ctx.sessions, %{topic: "stream:test", ids: []})
          Sessions.viewer_argv(ctx.sessions, name)
          row = Sessions.Table.get(ctx.table, "test", name)
          if row.status == "stopped", do: {:ok, row}, else: row
        end,
        10_000
      )

    launch = SessionsSetup.headless(ctx, :at_start)
    {:ok, _} = Sessions.resume(ctx.sessions, name, ctx.account, sid, launch)
  end

  defp signal(sig, pid), do: {_, 0} = System.cmd(program!(:kill), ["-" <> sig, pid])

  # Until the stand-in has taken these lines and the turn they started has ended: its result is
  # read, so every followed session is idle.
  defp until_taken(ctx, taken) do
    idle? = fn ->
      {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
      Enum.all?(rows, & &1.idle)
    end

    {:ok, _} =
      await(
        fn -> cue(ctx) && HeadlessStandIn.taken(ctx.dir) == taken && idle?.() && {:ok, 1} end,
        10_000
      )
  end

  # Reads Stream, then cues Mailbox as the embedding app's wiring would; a call after the cast
  # answers once it is handled.
  defp cue(ctx) do
    {:ok, _} = Stream.read(ctx.stream)
    Mailbox.cue(mailbox(ctx), %{topic: "stream:test", ids: []})
    Mailbox.status(mailbox(ctx), 0)
  end

  defp until(ctx, id, ready?) do
    check = fn row -> if ready?.(row), do: {:ok, row}, else: row end
    await(fn -> cue(ctx) && check.(Table.get(ctx.mtable, id)) end, 10_000)
  end

  # Cues as `cue/1` does, so a row due goes in while the test waits on the fold.
  defp fold(ctx, sid) do
    cue(ctx)
    {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
    Enum.find(rows, &(&1.session == sid))
  end
end
