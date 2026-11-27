defmodule CodingAgentFramework.MailboxWaiterTest.HeldIntake do
  @moduledoc false
  # Plays `Intake` for one test: every session has a waiter, and a delivery's answer waits for
  # the test, which gets the caller to answer it.
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call({:waiter?, _account, _session}, _from, test), do: {:reply, {:ok, true}, test}

  def handle_call({:deliver, _account, _session, text}, from, test) do
    send(test, {:held, from, text})
    {:noreply, test}
  end
end

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

  alias CodingAgentFramework.{Accounts, Acts, Grants, Intake, Mailbox, Sessions, SessionsSetup}
  alias CodingAgentFramework.{Transcripts, WaiterStandIn}
  alias CodingAgentFramework.Mailbox.{Table, Transport}
  alias CodingAgentFramework.MailboxWaiterTest.HeldIntake

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
    assert text == "From d1 (message): report one\n\n[delivery #{u1}]"
    # The waiter's going cue may settle it from the lines before this read: sending or taken.
    assert %{status: status, via: "waiter", at: pid} = Table.get(ctx.mtable, one)
    assert status in ~w(sending delivered) and pid == main.pid
    assert %{status: "queued"} = Table.get(ctx.mtable, two)

    # The turn it started ends: the next waiter's cue settles the first from its lines, and the
    # second goes, this time queued by Claude Code into a person's running turn.
    turn = WaiterStandIn.turn_end(main.settings, main.sid, main.transcript, :busy)
    assert {2, "From d1 (message): report two\n\n[delivery " <> _} = Task.await(turn, 10_000)
    assert %{status: "delivered", attempt: nil, delivered_at: at} = Table.get(ctx.mtable, one)
    assert {:ok, %{status: "delivered"}} = until(ctx, two, &(&1.status == "delivered"))
    assert %{via: "waiter", again: 0} = Table.get(ctx.mtable, two)

    # Its delivery's time is written once, with `delivered` (F-202), and a later write of the
    # row leaves it.
    assert is_integer(at) and at >= Table.get(ctx.mtable, one).created_at
    Table.update(ctx.mtable, one, attempt: "a later write")
    assert %{delivered_at: ^at} = Table.get(ctx.mtable, one)
    assert %{delivered_at: two_at} = Table.get(ctx.mtable, two)
    assert is_integer(two_at)
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
    assert {2, "From d1 (message): lost one\n\n[delivery " <> rest} = Task.await(turn, 10_000)
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

  # F-132's new-2: the hand-on runs in a task. While a stand-in `Intake` holds it, `Mailbox`
  # still answers its calls, the row is `sending`, and no other row to the session is marked.
  test "answers its calls while a hand-on runs, the row sending meanwhile", ctx do
    main(ctx)
    GenServer.stop(ctx.mailbox)
    held = start_supervised!({HeldIntake, self()})
    m = restart(Map.put(ctx, :mopts, Keyword.put(ctx.mopts, :intake, held)))
    {:ok, {:queued, one}} = Mailbox.message(m, "d1", "main", "held one")
    assert_receive {:held, from, text}, 5_000
    assert text =~ "held one"

    {:ok, {:queued, two}} = Mailbox.message(m, "d1", "main", "after it")
    assert {:ok, %{status: "sending", via: "waiter"}} = Mailbox.status(m, one)
    assert {:ok, %{status: "queued"}} = Mailbox.status(m, two)
    assert %{sent_at: nil} = Table.get(ctx.mtable, one)

    # The answer comes back as a message: the take bound starts from it.
    GenServer.reply(from, {:ok, :sent})

    {:ok, _} =
      await(fn ->
        with %{sent_at: at} when is_integer(at) <- Table.get(ctx.mtable, one), do: {:ok, at}
      end)

    assert {:ok, %{status: "queued"}} = Mailbox.status(m, two)
    refute_received {:held, _, _}
  end

  # F-170: an app's frame names the sender in its own words; a frame that answers no text hands
  # nothing on, and the row says why.
  test "an app's frame in place of the framework's, the mark after it", ctx do
    main(ctx)
    GenServer.stop(ctx.mailbox)
    held = start_supervised!({HeldIntake, self()})

    frame = fn
      %{text: "no frame"} -> nil
      %{from: from, kind: kind, text: text} -> "[#{kind} from #{from}] " <> text
    end

    mopts = Keyword.merge(ctx.mopts, intake: held, frame: frame)
    m = restart(Map.put(ctx, :mopts, mopts))
    Process.put(:mailbox, m)
    {:ok, {:queued, one}} = Mailbox.message(m, "d1", "main", "no frame")
    {:ok, {:queued, two}} = Mailbox.message(m, "d1", "main", "framed")

    {:ok, %{attempt: ~s(["bad","frame"])}} = until(ctx, one, &(&1.attempt != nil))
    assert %{status: "queued"} = Table.get(ctx.mtable, one)
    refute_received {:held, _, _}

    # The first row stays due, and holds the rows after it from its sender.
    :ok = Table.update(ctx.mtable, one, status: "ended")
    cue(ctx)
    assert_receive {:held, from, text}, 5_000
    %{uuid: u2} = Table.get(ctx.mtable, two)
    assert text == "[message from d1] framed\n\n[delivery #{u2}]"
    GenServer.reply(from, {:ok, :sent})
  end

  # Delivery.tla's ForceSettled (F-170): once the session is free after a forced end, the row
  # in flight to it is unknown, never due again, and its hand-on's late answer changes nothing.
  test "a row still sending at a forced end settles unknown, never resent", ctx do
    main(ctx)
    GenServer.stop(ctx.mailbox)
    held = start_supervised!({HeldIntake, self()})
    m = restart(Map.put(ctx, :mopts, Keyword.put(ctx.mopts, :intake, held)))
    Process.put(:mailbox, m)
    {:ok, {:queued, one}} = Mailbox.message(m, "d1", "main", "in flight")
    assert_receive {:held, from, _text}, 5_000

    assert {:refused, {:not_free, "running"}} = Mailbox.ended_while_sending(m, "main")

    [pid] = File.ls!(Path.join(ctx.dir, "pids"))
    {_, 0} = System.cmd(program!(:kill), ["-KILL", pid])

    {:ok, _} =
      await(
        fn ->
          Sessions.cue(ctx.waiting, %{topic: "tmux:test:caf", ids: []})
          Sessions.viewer_argv(ctx.waiting, "main")
          if Sessions.Table.get(ctx.table, "test", "main").status != "running", do: {:ok, 1}
        end,
        10_000
      )

    assert {:ok, [^one]} = Mailbox.ended_while_sending(m, "main")
    assert {:ok, %{status: "unknown", attempt: "ended_while_sending"}} = Mailbox.status(m, one)

    GenServer.reply(from, {:refused, :closed})
    cue(ctx)
    assert {:ok, %{status: "unknown"}} = Mailbox.status(m, one)
    assert {:ok, []} = Mailbox.open_to(m, "main")
  end

  # Delivery.tla's ForcedSettles (F-172): `Mailbox` was down between the forced end and the
  # operator's settle; at its own start it reads the end's claim in `Acts` and settles the row.
  test "a forced end's row settles unknown at Mailbox's own settle, across a restart", ctx do
    main(ctx)
    GenServer.stop(ctx.mailbox)
    clock = fn -> Agent.get(ctx.clock, & &1) end
    acts_db = Path.join(ctx.dir, "acts.db")

    acts =
      start_supervised!(
        {Acts, db: acts_db, start_id: "s1", host: "test", instance: "t", clock: clock}
      )

    held = start_supervised!({HeldIntake, self()})
    mopts = Keyword.merge(ctx.mopts, intake: held, acts: acts)
    m = restart(Map.put(ctx, :mopts, mopts))
    Process.put(:mailbox, m)
    {:ok, {:queued, one}} = Mailbox.message(m, "d1", "main", "in flight")
    assert_receive {:held, _from, _text}, 5_000

    # An end not forced is no evidence: the claim must say so.
    {:ok, plain} = Acts.claim(acts, "op", "main", "s0", "stop")
    {:ok, act} = Acts.claim(acts, "op", "main", nil, "end_main", detail: %{force: true})
    GenServer.stop(m)
    assert {:ok, :ended} = Sessions.end_main(ctx.waiting, "main", force: true, timeout: 10_000)
    {:ok, _} = Acts.answered(acts, act, {:ok, :ended})
    {:ok, _} = Acts.answered(acts, plain, {:refused, :not_held})
    assert %{status: "sending"} = Table.get(ctx.mtable, one)

    m = restart(Map.put(ctx, :mopts, mopts))
    Process.put(:mailbox, m)

    # The start's pass reads in a task (F-289): the status call answers before it settles.
    assert {:ok, %{status: "unknown", attempt: "ended_while_sending"}} =
             await(fn ->
               case Mailbox.status(m, one) do
                 {:ok, %{status: "unknown"}} = ok -> ok
                 _ -> nil
               end
             end)

    assert {:ok, [%{actor: "op", target: "main", outcome: "unknown", detail: detail}]} =
             Acts.rows(acts, act: "settle")

    assert detail == ~s({"row":#{one}})
    # Nothing is left for the operator's call to settle.
    assert {:ok, []} = Mailbox.ended_while_sending(m, "main")
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
