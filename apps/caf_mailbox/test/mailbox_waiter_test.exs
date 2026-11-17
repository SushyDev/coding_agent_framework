defmodule CodingAgentFramework.MailboxWaiterTest do
  @moduledoc """
  The `waiter` transport over a real `Sessions`, `Intake` behind Bandit, `Transcripts`, real
  dtach and tmux in this test's own directory, the interactive stand-in for Claude Code, and
  `WaiterStandIn` for Claude Code's side of the waiter: the hook the start put into the
  session's overlay, run at each turn's end, and the transcript lines it makes. `Intake`'s
  waiter cue reaches `Mailbox` as `Cues` routes it. Each test names the
  `Delivery.tla` property it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Grants, Intake, Mailbox, Sessions, SessionsSetup}
  alias CodingAgentFramework.{Transcripts, WaiterStandIn}
  alias CodingAgentFramework.Mailbox.{Table, Transport}

  doctest Transport.Waiter

  setup {SessionsSetup, :sessions}

  setup ctx do
    tree = [
      %{name: "main", project: "app", parent: nil},
      %{name: "d1", project: "app", parent: "main"}
    ]

    db = Path.join(ctx.dir, "caf.db")
    # As `Cues` routes them: Intake's cues go to the Mailbox of the moment.
    route = start_supervised!(Supervisor.child_spec({Agent, fn -> nil end}, id: :route))

    notify = fn cue ->
      with pid when is_pid(pid) <- Agent.get(route, & &1), do: Mailbox.cue(pid, cue)
    end

    secret = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    intake = start_supervised!({Intake, db: db, host: "test", notify: notify})
    plug = {Intake.Plug, intake: intake, secret: secret}

    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    # A Sessions that puts the waiter hook into a main session's overlay.
    opts = ctx.opts ++ [waiter: %{port: port, secret: secret}]
    sessions = start_supervised!(Supervisor.child_spec({Sessions, opts}, id: :waiting))

    {:ok, accounts} = Accounts.new(Path.join(ctx.dir, "home"), ["work"])

    transcripts =
      start_supervised!({Transcripts, programs: programs(), accounts: ["work"], db: db})

    mopts = [
      db: db,
      grants: Grants.new(fn -> tree end),
      stream: ctx.stream,
      sessions_db: db,
      host: "test",
      intake: intake,
      transcripts: transcripts,
      accounts: accounts,
      take_bound: 1_000
    ]

    {:ok, mtable} = Table.open(db)
    ctx = Map.merge(ctx, %{route: route, mopts: mopts})

    {:ok,
     route: route,
     mopts: mopts,
     mtable: mtable,
     intake: intake,
     waiting: sessions,
     mailbox: restart(ctx)}
  end

  # OnlyIntoEndedTurn (the waiter's: into an ended turn, or queued into the running one),
  # InOrder, AtMostOnce, SettleSeen: each row goes to a waiter only, one at a time, and is
  # delivered by its own lines in the transcript, whichever shape Claude Code took it in.
  test "into the waiter only, one at a time, settled by the transcript's lines", ctx do
    main = main(ctx)
    m = mailbox(ctx)
    {:ok, {:queued, one}} = Mailbox.message(m, "d1", "main", "report one")
    {:ok, {:queued, two}} = Mailbox.message(m, "d1", "main", "report two")

    # No waiter yet (no turn has ended): the rows stay due, and say why.
    assert {:ok, %{status: "queued", attempt: "no_waiter"}} = until(ctx, one, & &1.attempt)

    # The first turn ends; its waiter comes, and the first row goes to it.
    turn = WaiterStandIn.turn_end(main.settings, main.sid, main.transcript, :idle)
    assert {2, text} = Task.await(turn, 10_000)
    %{uuid: u1} = Table.get(ctx.mtable, one)
    assert text == "report one\n\n[delivery #{u1}]"
    assert %{status: "sending", via: "waiter", at: pid} = Table.get(ctx.mtable, one)
    assert pid == main.pid
    assert %{status: "queued"} = Table.get(ctx.mtable, two)

    # The turn it started ends: the next waiter's cue settles the first from its lines, and the
    # second goes, this time queued by Claude Code into a person's running turn.
    turn = WaiterStandIn.turn_end(main.settings, main.sid, main.transcript, :busy)
    assert {2, "report two\n\n[delivery " <> _} = Task.await(turn, 10_000)
    assert %{status: "delivered", attempt: nil} = Table.get(ctx.mtable, one)
    assert {:ok, %{status: "delivered"}} = until(ctx, two, &(&1.status == "delivered"))
    assert %{via: "waiter", again: 0} = Table.get(ctx.mtable, two)
  end

  # Break_Delivery_SettleEarly's guard, the take bound (F-122's new-2): with no line of the row
  # past it, the row is due again, first, under its same uuid; an enqueued row is not, until
  # its process is gone with no take. A restart settles from the same evidence.
  test "due again only past the take bound with no line, or with its process gone", ctx do
    main = main(ctx)
    {:ok, {:queued, one}} = Mailbox.message(mailbox(ctx), "d1", "main", "lost one")
    {:ok, {:queued, two}} = Mailbox.message(mailbox(ctx), "d1", "main", "after it")

    # Written to a connection that had died unseen: no line, so past the bound it is due again.
    turn = WaiterStandIn.turn_end(main.settings, main.sid, main.transcript, :lost)
    assert {2, _} = Task.await(turn, 10_000)
    %{uuid: u1} = Table.get(ctx.mtable, one)
    assert %{status: "sending"} = Table.get(ctx.mtable, one)

    assert {:ok, %{uuid: ^u1, again: 1, via: nil}} =
             until(ctx, one, &(&1.status == "queued" and &1.again == 1))

    # It goes again first, before the row stored after it, under its same uuid. Enqueued, it
    # waits past the bound for its take, across a restart of Mailbox.
    turn = WaiterStandIn.turn_end(main.settings, main.sid, main.transcript, :enqueued)
    assert {2, "lost one\n\n[delivery " <> rest} = Task.await(turn, 10_000)
    assert rest == u1 <> "]"
    GenServer.stop(mailbox(ctx))
    %{sent_at: sent_at} = Table.get(ctx.mtable, one)
    Process.put(:mailbox, restart(ctx))

    # The wall clock past the bound, then a settle: still sending, waiting for its take.
    {:ok, _} =
      await(fn -> if System.os_time(:millisecond) > sent_at + 1_100, do: {:ok, 1} end)

    cue(ctx)
    assert %{status: "sending"} = Table.get(ctx.mtable, one)
    assert %{status: "queued"} = Table.get(ctx.mtable, two)

    # Its process ends before the take: due again, first.
    [pid] = File.ls!(Path.join(ctx.dir, "pids"))
    {_, 0} = System.cmd(program!(:kill), ["-KILL", pid])

    {:ok, _} =
      await(
        fn ->
          Sessions.cue(ctx.waiting, %{topic: "tmux:test:caf", ids: []})
          Sessions.viewer_argv(ctx.waiting, "main")
          until_now(ctx, one, &(&1.status == "queued" and &1.again == 1))
        end,
        10_000
      )
  end

  # The waiter's hook in a main session's start: the overlay carries it beside the account's.
  defp main(ctx) do
    {:ok, %{pid: pid, session_id: sid}} =
      Sessions.start(ctx.waiting, "main", ctx.account, SessionsSetup.launch(ctx, :at_start))

    settings = Path.join(ctx.account.config_dir, "framework/agents/main.settings.json")
    assert WaiterStandIn.command(settings) =~ "caf-waiter"
    {:ok, transcript} = Transcripts.path(ctx.account.config_dir, ctx.dir, sid)
    %{pid: pid, sid: sid, settings: settings, transcript: transcript}
  end

  defp restart(ctx) do
    spec = Supervisor.child_spec({Mailbox, ctx.mopts}, id: make_ref(), restart: :temporary)
    pid = start_supervised!(spec)
    Agent.update(ctx.route, fn _ -> pid end)
    pid
  end

  defp mailbox(ctx), do: Process.get(:mailbox, ctx.mailbox)

  # Cues Mailbox as `Cues` would on a transcript's cue, the one a waiter row's lines are read
  # on; a call after the cast answers once it is handled.
  defp cue(ctx) do
    Mailbox.cue(mailbox(ctx), %{topic: "transcripts:test:work", ids: []})
    Mailbox.status(mailbox(ctx), 0)
  end

  defp until(ctx, id, ready?), do: await(fn -> until_now(ctx, id, ready?) end, 10_000)

  defp until_now(ctx, id, ready?) do
    cue(ctx)
    row = Table.get(ctx.mtable, id)
    if ready?.(row), do: {:ok, row}, else: row
  end
end
