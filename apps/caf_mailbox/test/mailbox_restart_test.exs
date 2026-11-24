defmodule CodingAgentFramework.MailboxRestartTest do
  @moduledoc """
  F-240: messages to an interactive delegate that is idle after the tree restarted. A real
  `Sessions`, `Registry`, `Transcripts`, `Inlet` and `Stream`, real dtach and tmux in this test's
  own directory, and `ScreenStandIn` in place of Claude Code, its pane 200 columns wide as the
  live one was. No `Intake` runs: a restart cut the waiter's connection, and an idle session
  starts no other until a turn of it ends. The framework home is long, so the typed pointer
  line of a long row is wider than the box (`Delivery.tla`'s `Wide`).
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Grants, Inlet, Mailbox, ScreenStandIn, Sessions}
  alias CodingAgentFramework.{SessionsSetup, Store, Stream, Transcripts}
  alias CodingAgentFramework.Mailbox.Table

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

    # A home as long as a live one under an application-support directory.
    home = Path.join(ctx.dir, String.duplicate("h", 100))

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
      wait_bound: 1_500,
      home: home
    ]

    {:ok, mtable} = Table.open(db)
    {:ok, mtable: mtable, mopts: mopts, home: home}
  end

  # Arrives, InOrder, WaitBound: the long row's pointer line is refused as wider than the box;
  # it waits for a waiter, which never comes, for the wait bound only, and is then settled
  # `unknown`. The row behind it, from the same sender and short enough to type, is then typed and delivered.
  test "after a restart, a row too wide to type is settled at the bound, and the next goes in",
       ctx do
    d1 = d1(ctx)

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

    long = String.duplicate("x", 860)
    {:ok, {:queued, one}} = Mailbox.message(mailbox, "main", "d1", long)
    {:ok, {:queued, two}} = Mailbox.message(mailbox, "main", "d1", "hi")

    # Refused by the Inlet: its pointer line is wider than the 196 columns the box holds.
    assert {:ok, %{status: "queued", attempt: ~s(["too_long",196])}} =
             until(ctx, mailbox, one, &(&1.attempt != nil and &1.attempt =~ "too_long"))

    assert %{status: "queued"} = Table.get(ctx.mtable, two)
    assert ScreenStandIn.submitted(ctx.dir) == []

    # The bound: no waiter came, so the long row is answered, never typed.
    assert {:ok, %{status: "unknown", attempt: ~s(["wait_bound",["too_long",196]])}} =
             until(ctx, mailbox, one, &(&1.status == "unknown"))

    %{uuid: u2} = Table.get(ctx.mtable, two)
    line2 = "From main (message): hi [delivery #{u2}]"
    assert {:ok, [^line2]} = submitted(ctx, 1)
    user_line(d1, line2)
    assert {:ok, %{status: "delivered"}} = until(ctx, mailbox, two, &(&1.status == "delivered"))
    assert {:ok, []} = Mailbox.open_to(mailbox, "d1")
  end

  # The bound runs from the refusal, which the row keeps: a Mailbox started after it, by a
  # restart, answers the row at once rather than waiting the bound again.
  test "a restart past the bound answers a refused row at once", ctx do
    d1(ctx)
    mailbox = start_mailbox(ctx, :before, wait_bound: 60_000)
    {:ok, {:queued, one}} = Mailbox.message(mailbox, "main", "d1", String.duplicate("x", 860))
    assert {:ok, _} = until(ctx, mailbox, one, &(&1.attempt != nil))
    stop_supervised!(:before)

    # The refusal was two minutes ago: its time is the row's last write.
    Store.update(ctx.mtable, "messages", one, updated_at: System.os_time(:millisecond) - 120_000)
    mailbox = start_mailbox(ctx, :after, wait_bound: 60_000)

    # A call is answered after the start's own settle, which needs no cue.
    Mailbox.status(mailbox, 0)
    assert %{status: "unknown"} = Table.get(ctx.mtable, one)
    assert {:ok, []} = Mailbox.open_to(mailbox, "d1")
  end

  defp start_mailbox(ctx, id, opts \\ []) do
    inlet =
      start_supervised!(Supervisor.child_spec({Inlet, tmux: ctx.server}, id: :"#{id}_inlet"))

    start_supervised!(
      Supervisor.child_spec({Mailbox, [inlet: inlet] ++ Keyword.merge(ctx.mopts, opts)}, id: id)
    )
  end

  defp d1(ctx) do
    launch =
      Keyword.put(SessionsSetup.launch(ctx, :at_start), :claude, ScreenStandIn.write!(ctx.dir))

    {:ok, %{pid: pid, session_id: sid}} = Sessions.start(ctx.sessions, "d1", ctx.account, launch)
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
        Mailbox.cue(mailbox, %{topic: "sessions:test:work", ids: []})
        Mailbox.status(mailbox, 0)
        row = Table.get(ctx.mtable, id)
        if ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end
end
