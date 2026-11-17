defmodule CodingAgentFramework.MailboxTypedTest do
  @moduledoc """
  The `typed` transport over a real `Sessions`, `Registry`, `Transcripts` and `Inlet`, real
  dtach and tmux in this test's own directory, and `ScreenStandIn` in place of Claude Code: it
  draws 2.1.322's captured screens and takes a line at Enter. No `Intake` runs, so the session
  never has a waiter. The test writes the transcript's user line as Claude Code would. Each test
  names the `Delivery.tla` property it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Grants, Inlet, Mailbox, ScreenStandIn, Sessions}
  alias CodingAgentFramework.{SessionsSetup, Transcripts}
  alias CodingAgentFramework.Mailbox.{Table, Transport}

  doctest Transport.Typed

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
      inlet: start_supervised!({Inlet, tmux: ctx.server}),
      registry: ctx.registry,
      transcripts: transcripts,
      accounts: accounts,
      take_bound: 1_000
    ]

    {:ok, mtable} = Table.open(db)
    {:ok, mailbox: start_supervised!({Mailbox, mopts}), mtable: mtable}
  end

  # OnlyIntoEndedTurn, InOrder, SettleSeen: each row is typed on one line with its uuid, one at
  # a time, into an ended turn with an empty box, and is delivered by its user line once the
  # turn it started has ended. The start recorded the release the screen is read by.
  test "typed one at a time into an ended turn, settled by the transcript's user line", ctx do
    main = main(ctx)
    assert %{release: "2.1.322"} = Sessions.Table.get(ctx.table, "test", "main")
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "d1", "main", "report one")
    {:ok, {:queued, two}} = Mailbox.message(ctx.mailbox, "d1", "main", "report two")

    %{uuid: u1} = Table.get(ctx.mtable, one)
    line1 = "report one [delivery #{u1}]"
    assert {:ok, [^line1]} = submitted(ctx, 1)
    assert %{status: "sending", via: "typed", at: pid} = Table.get(ctx.mtable, one)
    assert pid == main.pid
    assert %{status: "queued"} = Table.get(ctx.mtable, two)

    user_line(main, line1)
    assert {:ok, %{status: "delivered"}} = until(ctx, one, &(&1.status == "delivered"))

    %{uuid: u2} = Table.get(ctx.mtable, two)
    line2 = "report two [delivery #{u2}]"
    assert {:ok, [^line1, ^line2]} = submitted(ctx, 2)
    user_line(main, line2)
    assert {:ok, %{via: "typed", again: 0}} = until(ctx, two, &(&1.status == "delivered"))
  end

  # A text the box cannot hold is never typed, and waits for a waiter, first among its rows
  # (InOrder).
  test "a text too long for the box is not typed, and waits", ctx do
    main(ctx)

    {:ok, {:queued, long}} =
      Mailbox.message(ctx.mailbox, "d1", "main", String.duplicate("x", 300))

    {:ok, {:queued, short}} = Mailbox.message(ctx.mailbox, "d1", "main", "short")

    # The viewer is 200 columns wide: 196 is the longest text the Inlet types.
    assert {:ok, %{status: "queued", attempt: ~s(["too_long",196])}} =
             until(ctx, long, &(&1.attempt != nil))

    cue(ctx)
    assert %{status: "queued", attempt: ~s(["too_long",196])} = Table.get(ctx.mtable, long)
    assert %{status: "queued"} = Table.get(ctx.mtable, short)
    assert ScreenStandIn.submitted(ctx.dir) == []
  end

  # Break_Delivery_SettleEarly's guard (the take bound): with no user line past it, the row is
  # due again, first, under its same uuid, and typed again.
  test "a typed row with no user line past the take bound is due again", ctx do
    main = main(ctx)
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "d1", "main", "lost one")
    %{uuid: u1} = Table.get(ctx.mtable, one)
    assert {:ok, ["lost one [delivery " <> _]} = submitted(ctx, 1)
    assert {:ok, %{uuid: ^u1, again: 1}} = until(ctx, one, &(&1.again == 1))

    assert {:ok, [line, line]} = submitted(ctx, 2)
    user_line(main, line)
    assert {:ok, %{status: "delivered"}} = until(ctx, one, &(&1.status == "delivered"))
  end

  defp main(ctx) do
    launch =
      Keyword.put(SessionsSetup.launch(ctx, :at_start), :claude, ScreenStandIn.write!(ctx.dir))

    {:ok, %{pid: pid, session_id: sid}} =
      Sessions.start(ctx.sessions, "main", ctx.account, launch)

    {:ok, transcript} = Transcripts.path(ctx.account.config_dir, ctx.dir, sid)
    %{pid: pid, transcript: transcript}
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

  # Cues Mailbox as the app would on a reader's cue; a call after the cast answers once it is
  # handled.
  defp cue(ctx) do
    Mailbox.cue(ctx.mailbox, %{topic: "sessions:test:work", ids: []})
    Mailbox.status(ctx.mailbox, 0)
  end

  defp until(ctx, id, ready?) do
    await(
      fn ->
        cue(ctx)
        row = Table.get(ctx.mtable, id)
        if ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end
end
