defmodule CodingAgentFramework.MailboxRestartTest do
  @moduledoc """
  F-240: messages to an interactive delegate that is idle after the tree restarted. A real
  `Sessions`, `Registry`, `Transcripts`, `Inlet` and `Stream`, real dtach and tmux in this test's
  own directory, and `ScreenStandIn` in place of Claude Code, its pane 200 columns wide as the
  live one was. A restart cut the waiter's connection, and an idle session starts no other until
  a turn of it ends. The `Mailbox` has no framework home, so a row past the paste's bound has
  no file to write and no pointer line to paste (`Delivery.tla`'s `Wide`). Where a waiter
  comes, `Intake` runs behind Bandit and `WaiterStandIn` plays Claude Code's side of it.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Grants, Inlet, Intake, Mailbox, ScreenStandIn, Sessions}
  alias CodingAgentFramework.{SessionsSetup, Stream, Transcripts, WaiterStandIn}
  alias CodingAgentFramework.Mailbox.{Table, Transport}

  @wake "[framework] a message is waiting for you."

  setup {SessionsSetup, :sessions}

  setup ctx do
    tree = [
      %{name: "main", project: "app", parent: nil},
      %{name: "d1", project: "app", parent: "main"}
    ]

    db = Path.join(ctx.dir, "caf.db")
    {:ok, accounts} = Accounts.new(Path.join(ctx.dir, "home"), ["work"])

    transcripts =
      start_supervised!({Transcripts, programs: programs(), accounts: ["work"], db: db})

    mopts = [
      db: db,
      grants: Grants.new(fn -> tree end),
      stream: ctx.stream,
      sessions_db: db,
      host: "test",
      registry: ctx.registry,
      transcripts: transcripts,
      accounts: accounts,
      take_bound: 1_000,
      wait_bound: 1_500
    ]

    {:ok, mtable} = Table.open(db)
    {:ok, mtable: mtable, mopts: mopts, db: db}
  end

  # Arrives, InOrder, Wake, WaitBound, UndeliveredTold: the long row has no pointer line to
  # paste; the wake line goes once in its place; the session ignores it, so no turn
  # ends and no waiter comes. At the bound the row is undelivered, its sender gets a notice, and
  # the row behind it, from the same sender and short enough to type, goes in.
  test "after a restart, a wake line no turn answers: undelivered at the bound, sender told",
       ctx do
    d1 = d1(ctx, ctx.sessions)

    # Stream follows headless delegates only: an interactive one is never followed, before a
    # restart or after it, and nothing in its delivery reads Stream for it.
    assert {:refused, :not_followed} = Stream.log(ctx.stream, d1.sid, {:last, 10})

    # The tree restarts: the Mailbox and the Inlet are new processes; the session runs on.
    first = start_mailbox(ctx, :before)
    stop_supervised!(:before)
    stop_supervised!(:before_inlet)
    assert Process.alive?(ctx.sessions)
    mailbox = start_mailbox(ctx, :after)
    assert {:refused, :not_followed} = Stream.log(ctx.stream, d1.sid, {:last, 10})
    refute Process.alive?(first)

    {:ok, {:queued, one}} =
      Mailbox.message(mailbox, "main", "d1", String.duplicate("x", Transport.Typed.bound()))

    {:ok, {:queued, two}} = Mailbox.message(mailbox, "main", "d1", "hi")

    # Refused: no home to write its file in. The wake line goes in its place, and the row stays
    # due, the one behind it too.
    assert {:ok, [@wake]} = submitted(ctx, 1)

    assert %{status: "queued", attempt: ~s(["too_long","no_home"]), woke_at: at} =
             Table.get(ctx.mtable, one)

    assert is_integer(at)
    assert %{status: "queued"} = Table.get(ctx.mtable, two)

    # The bound: no waiter came, so the long row is undelivered, never typed.
    assert {:ok,
            %{status: "undelivered", attempt: ~s(["wait_bound",["too_long","no_home"]])} = row} =
             until(ctx, mailbox, one, &(&1.status == "undelivered"))

    assert [notice] = for(r <- Table.rows(ctx.mtable), r.kind == "notice", do: r)

    assert %{from_agent: "framework", to_agent: "main", reply_to: reply_to, text: text} = notice
    assert reply_to == row.uuid
    assert text == "undelivered: message #{one} to d1, after 1 s"

    %{uuid: u2} = Table.get(ctx.mtable, two)
    line2 = "From main (message): hi [delivery #{u2}]"
    assert {:ok, [@wake, ^line2]} = submitted(ctx, 2)
    user_line(d1, line2)
    assert {:ok, %{status: "delivered"}} = until(ctx, mailbox, two, &(&1.status == "delivered"))
    assert {:ok, []} = Mailbox.open_to(mailbox, "d1")
  end

  # WakeOnce (Break_Delivery_WakeInMemory): the wake line's mark is in the table, written before
  # its keys, so a Mailbox started between the line and a waiter types no second one. The
  # bound runs from the same mark.
  test "a restart between the wake line and the waiter types no second wake line", ctx do
    d1(ctx, ctx.sessions)
    mailbox = start_mailbox(ctx, :before, wait_bound: 3_000)

    {:ok, {:queued, one}} =
      Mailbox.message(mailbox, "main", "d1", String.duplicate("x", Transport.Typed.bound()))

    assert {:ok, [@wake]} = submitted(ctx, 1)
    %{woke_at: at} = Table.get(ctx.mtable, one)
    stop_supervised!(:before)
    stop_supervised!(:before_inlet)

    mailbox = start_mailbox(ctx, :after, wait_bound: 3_000)

    assert {:ok, %{status: "undelivered", woke_at: ^at}} =
             until(ctx, mailbox, one, &(&1.status == "undelivered"))

    assert ScreenStandIn.submitted(ctx.dir) == [@wake]
  end

  # Wake, then the waiter (SettleSeen): the wake line's turn ends, its waiter comes, and the
  # waiter carries the long row whole, as it carries any row; the short one behind it is typed.
  test "the waiter the wake line's turn brings carries the row", ctx do
    {intake, sessions, route} = waiting(ctx)
    d1 = d1(ctx, sessions)
    settings = Path.join(ctx.account.config_dir, "framework/agents/d1.settings.json")
    assert WaiterStandIn.command(settings) =~ "caf-waiter"

    mailbox = start_mailbox(ctx, :after, intake: intake)
    Agent.update(route, fn _ -> mailbox end)
    long = String.duplicate("x", Transport.Typed.bound())
    {:ok, {:queued, one}} = Mailbox.message(mailbox, "main", "d1", long)
    {:ok, {:queued, two}} = Mailbox.message(mailbox, "main", "d1", "hi")
    assert {:ok, [@wake]} = submitted(ctx, 1)

    # Claude Code takes the line, and the turn it starts ends: the Stop hook's waiter connects.
    user_line(d1, @wake)
    turn = WaiterStandIn.turn_end(settings, d1.sid, d1.transcript, :idle)
    %{uuid: u1} = Table.get(ctx.mtable, one)
    assert {2, text} = Task.await(turn, 10_000)
    assert text == "From main (message): #{long}\n\n[delivery #{u1}]"

    assert {:ok, %{status: "delivered", via: "waiter"}} =
             until(ctx, mailbox, one, &(&1.status == "delivered"))

    %{uuid: u2} = Table.get(ctx.mtable, two)
    assert {:ok, [@wake, "From main (message): hi [delivery " <> rest]} = submitted(ctx, 2)
    assert rest == "#{u2}]"
  end

  # An Intake behind Bandit, its cues to the Mailbox of the moment, and a Sessions that puts the
  # waiter hook into a session's overlay, as `MailboxWaiterTest` sets them up.
  defp waiting(ctx) do
    route = start_supervised!(Supervisor.child_spec({Agent, fn -> nil end}, id: :route))

    notify = fn cue ->
      with pid when is_pid(pid) <- Agent.get(route, & &1), do: Mailbox.cue(pid, cue)
    end

    secret = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    intake = start_supervised!({Intake, db: ctx.db, host: "test", notify: notify})
    plug = {Intake.Plug, intake: intake, secret: secret}

    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    opts = ctx.opts ++ [waiter: %{port: port, secret: secret}]
    sessions = start_supervised!(Supervisor.child_spec({Sessions, opts}, id: :waiting))
    {intake, sessions, route}
  end

  defp start_mailbox(ctx, id, opts \\ []) do
    inlet =
      start_supervised!(Supervisor.child_spec({Inlet, tmux: ctx.server}, id: :"#{id}_inlet"))

    start_supervised!(
      Supervisor.child_spec({Mailbox, [inlet: inlet] ++ Keyword.merge(ctx.mopts, opts)}, id: id)
    )
  end

  defp d1(ctx, sessions) do
    launch =
      Keyword.put(SessionsSetup.launch(ctx, :at_start), :claude, ScreenStandIn.write!(ctx.dir))

    {:ok, %{pid: pid, session_id: sid}} = Sessions.start(sessions, "d1", ctx.account, launch)
    {:ok, transcript} = Transcripts.path(ctx.account.config_dir, ctx.dir, sid)
    %{pid: pid, sid: sid, transcript: transcript}
  end

  # The user line Claude Code writes for a prompt typed into an ended turn.
  defp user_line(d1, text) do
    File.mkdir_p!(Path.dirname(d1.transcript))
    line = JSON.encode!(%{type: "user", message: %{role: "user", content: text}})
    File.write!(d1.transcript, line <> "\n", [:append])
  end

  defp submitted(ctx, n) do
    await(
      fn ->
        lines = ScreenStandIn.submitted(ctx.dir)
        if length(lines) >= n, do: {:ok, lines}, else: lines
      end,
      10_000
    )
  end

  defp until(ctx, mailbox, id, ready?) do
    await(
      fn ->
        Mailbox.cue(mailbox, %{topic: "transcripts:test:work", ids: []})
        Mailbox.status(mailbox, 0)
        row = Table.get(ctx.mtable, id)
        if ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end
end
