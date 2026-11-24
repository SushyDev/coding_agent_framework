defmodule CodingAgentFramework.MailboxReloadTest.StuckIntake do
  @moduledoc false
  # Plays `Intake` for one test: the session's waiter is always held, a pass is answered and
  # changes nothing, and a delivery's answer waits for the test.
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call({:waiter?, _account, _session}, _from, test), do: {:reply, {:ok, true}, test}

  def handle_call({:pass_waiter, _account, _session}, _from, test) do
    send(test, :passed)
    {:reply, {:ok, :passed}, test}
  end

  def handle_call({:deliver, _account, _session, text}, from, test) do
    send(test, {:held, from, text})
    {:noreply, test}
  end
end

defmodule CodingAgentFramework.MailboxReloadTest do
  @moduledoc """
  F-241: the operator's reload into an idle session whose waiter holds its turn, as every idle
  session the framework delivers to by the waiter has. A real `Sessions` that puts the waiter
  hook into a main session's overlay, `Intake` behind Bandit, `Registry`, `Transcripts` and
  `Inlet`, real dtach and tmux in this test's own directory, `ScreenStandIn` in place of Claude
  Code's screen and `WaiterStandIn` for its side of the waiter. Two tests put a stand-in in
  `Intake`'s place, whose waiter never goes. Each test names the `Reload.tla` property it
  checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Grants, Inlet, Intake, Mailbox, ScreenStandIn}
  alias CodingAgentFramework.{Sessions, SessionsSetup, Transcripts, WaiterStandIn}
  alias CodingAgentFramework.Mailbox.Table
  alias CodingAgentFramework.MailboxReloadTest.StuckIntake

  setup {SessionsSetup, :sessions}

  setup ctx do
    tree = [
      %{name: "main", project: "app", parent: nil},
      %{name: "d1", project: "app", parent: "main"}
    ]

    db = Path.join(ctx.dir, "caf.db")
    # As `Cues` routes them: Intake's cues go to the Mailbox.
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
    opts = ctx.opts ++ [waiter: %{port: port, secret: secret}]
    waiting = start_supervised!(Supervisor.child_spec({Sessions, opts}, id: :waiting))
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
      inlet: start_supervised!({Inlet, tmux: ctx.server}),
      registry: ctx.registry,
      transcripts: transcripts,
      accounts: accounts,
      take_bound: 1_000,
      home: ctx.dir
    ]

    {:ok, mtable} = Table.open(db)
    {:ok, route: route, mopts: mopts, mtable: mtable, intake: intake, waiting: waiting}
  end

  # IntoIdleTurn, OneWriteInBox, ReloadAnswered: the reload passes the waiter, whose program
  # exits 0 and wakes nothing, and is typed once. No waiter holds after it, so the next row is
  # typed, not handed to a waiter, and is delivered by its user line.
  test "a reload ends the waiter's hold and is typed once; the next row is typed", ctx do
    main = main(ctx, ctx.waiting)
    m = mailbox(ctx, ctx.mopts)

    hook = WaiterStandIn.turn_end(main.settings, main.sid, main.transcript, :idle)
    assert {:ok, true} = await_waiter(ctx, main, true)

    assert {:ok, :reloaded} = Mailbox.reload_plugins(m, "main")
    assert {0, ""} = Task.await(hook, 10_000)
    assert ScreenStandIn.submitted(ctx.dir) == ["/reload-plugins"]
    assert {:ok, false} = Intake.waiter?(ctx.intake, "work", main.sid)

    {:ok, {:queued, one}} = Mailbox.message(m, "d1", "main", "after")
    %{uuid: u1} = Table.get(ctx.mtable, one)
    line = "From d1 (message): after [delivery #{u1}]"
    assert {:ok, ["/reload-plugins", ^line]} = submitted(ctx, 2)
    assert %{via: "typed"} = Table.get(ctx.mtable, one)
    user_line(main, line)
    assert {:ok, %{status: "delivered"}} = until(m, ctx, one, &(&1.status == "delivered"))
  end

  # DueFirst: a row in flight to the waiter goes first; the reload is refused, nothing typed.
  test "a row due to the waiter refuses the reload", ctx do
    main(ctx, ctx.sessions)
    m = mailbox(ctx, Keyword.put(ctx.mopts, :intake, start_supervised!({StuckIntake, self()})))
    {:ok, {:queued, one}} = Mailbox.message(m, "d1", "main", "due")
    assert_receive {:held, from, _text}, 5_000

    assert {:refused, :message_due} = Mailbox.reload_plugins(m, "main")
    refute_received :passed
    assert ScreenStandIn.submitted(ctx.dir) == []

    GenServer.reply(from, {:ok, :sent})
    assert {:ok, %{status: "sending", via: "waiter"}} = Mailbox.status(m, one)
  end

  # ReloadAnswered, ReloadBound: a waiter whose hold never ends after the pass leaves the
  # reload unknown at the bound, with nothing typed.
  test "a waiter that never ends its hold leaves the reload unknown at the bound", ctx do
    main(ctx, ctx.sessions)
    m = mailbox(ctx, Keyword.put(ctx.mopts, :intake, start_supervised!({StuckIntake, self()})))

    assert {:unknown, {:held, {:turn, :waiter}}} = Mailbox.reload_plugins(m, "main", hold: 500)
    assert_received :passed
    assert ScreenStandIn.submitted(ctx.dir) == []
  end

  defp main(ctx, sessions) do
    launch =
      Keyword.put(SessionsSetup.launch(ctx, :at_start), :claude, ScreenStandIn.write!(ctx.dir))

    {:ok, %{pid: pid, session_id: sid}} = Sessions.start(sessions, "main", ctx.account, launch)
    settings = Path.join(ctx.account.config_dir, "framework/agents/main.settings.json")
    {:ok, transcript} = Transcripts.path(ctx.account.config_dir, ctx.dir, sid)
    %{pid: pid, sid: sid, settings: settings, transcript: transcript}
  end

  defp mailbox(ctx, mopts) do
    pid = start_supervised!({Mailbox, mopts})
    Agent.update(ctx.route, fn _ -> pid end)
    pid
  end

  defp await_waiter(ctx, main, want) do
    await(fn ->
      if Intake.waiter?(ctx.intake, "work", main.sid) == {:ok, want}, do: {:ok, want}
    end)
  end

  # The user line Claude Code writes for a prompt typed into an ended turn.
  defp user_line(main, text) do
    File.mkdir_p!(Path.dirname(main.transcript))
    line = JSON.encode!(%{type: "user", message: %{role: "user", content: text}})
    File.write!(main.transcript, line <> "\n", [:append])
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

  defp until(m, ctx, id, ready?) do
    await(
      fn ->
        Mailbox.cue(m, %{topic: "sessions:test:work", ids: []})
        Mailbox.status(m, 0)
        row = Table.get(ctx.mtable, id)
        if ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end
end
