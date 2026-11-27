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
      %{name: "d1", project: "app", parent: "main"},
      %{name: "operator", project: "app", parent: "main"}
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
      take_bound: 1_000,
      home: ctx.dir
    ]

    {:ok, mtable} = Table.open(db)
    {:ok, mailbox: start_supervised!({Mailbox, mopts}), mtable: mtable, mopts: mopts}
  end

  # OnlyIntoEndedTurn, InOrder, SettleSeen: each row is typed on one line with its uuid, one at
  # a time, into an ended turn with an empty box, and is delivered by its user line once the
  # turn it started has ended. The start recorded the release the screen is read by.
  test "typed one at a time into an ended turn, settled by the transcript's user line", ctx do
    main = main(ctx)
    assert %{release: "2.1.322"} = Sessions.Table.get(ctx.table, "test", "main")
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "d1", "main", "one")
    {:ok, {:queued, two}} = Mailbox.message(ctx.mailbox, "d1", "main", "two")

    %{uuid: u1} = Table.get(ctx.mtable, one)
    line1 = "From d1 (message): one [delivery #{u1}]"
    assert {:ok, [^line1]} = submitted(ctx, 1)
    assert %{status: "sending", via: "typed", at: pid} = Table.get(ctx.mtable, one)
    assert pid == main.pid
    assert %{status: "queued"} = Table.get(ctx.mtable, two)

    user_line(main, line1)
    assert {:ok, %{status: "delivered"}} = until(ctx, one, &(&1.status == "delivered"))

    %{uuid: u2} = Table.get(ctx.mtable, two)
    line2 = "From d1 (message): two [delivery #{u2}]"
    assert {:ok, [^line1, ^line2]} = submitted(ctx, 2)
    user_line(main, line2)
    assert {:ok, %{via: "typed", again: 0}} = until(ctx, two, &(&1.status == "delivered"))
  end

  # F-188's new-3: the framework's own frame names the sender's account, read from the sender's
  # agent row, so an app passes no frame of its own for it.
  test "the frame names the sender's account from its agent row", ctx do
    main(ctx)
    d1 = %{host: "test", name: "d1", socket: "d1", account: "other", cwd: ctx.dir}
    Sessions.Table.starting(ctx.table, Map.merge(d1, %{role: "delegate", resume: nil}))
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "d1", "main", "one")

    # Typed whole or by its pointer line, the frame is the same.
    %{uuid: u1} = Table.get(ctx.mtable, one)
    assert {:ok, ["From d1 on other (message): " <> rest]} = submitted(ctx, 1)
    assert String.ends_with?(rest, "[delivery #{u1}]")
  end

  # NoLongTyped, Arrives (F-142, F-279): a row past the paste's bound is written whole to the
  # session's due directory, which its start may read by `--add-dir`, and the line pasted names
  # that file; its user line settles it. Rows keep their order.
  test "a row past the paste's bound is written to a file the pasted line names", ctx do
    main = main(ctx)
    {args, 0} = System.cmd(program!(:ps), ["-ww", "-o", "args=", "-p", "#{main.pid}"])
    due = Sessions.due_dir(ctx.dir, "main")
    assert args =~ "--add-dir #{due}"

    long = String.duplicate("x", Transport.Typed.bound())
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "d1", "main", long)
    {:ok, {:queued, two}} = Mailbox.message(ctx.mailbox, "d1", "main", "#{long}\nline two")

    file = Path.join(due, "#{one}.md")
    %{uuid: u1} = Table.get(ctx.mtable, one)
    line1 = "From d1 (message): a message for you is in `#{file}`; read it. [delivery #{u1}]"
    assert {:ok, [^line1]} = submitted(ctx, 1)
    assert File.read!(file) == "From d1 (message): " <> long
    assert %{status: "sending", via: "typed"} = Table.get(ctx.mtable, one)

    user_line(main, line1)
    assert {:ok, %{status: "delivered"}} = until(ctx, one, &(&1.status == "delivered"))
    # The file stays after delivery: the agent reads it in the turn the line starts.
    assert File.read!(file) == "From d1 (message): " <> long

    %{uuid: u2} = Table.get(ctx.mtable, two)
    file2 = Path.join(due, "#{two}.md")

    assert {:ok, [^line1, "From d1 (message): a message for you is in `" <> _ = line2]} =
             submitted(ctx, 2)

    assert line2 =~ "[delivery #{u2}]"
    assert File.read!(file2) == "From d1 (message):\n\n#{long}\nline two"
  end

  # With no framework home there is nowhere to write the file: the row is not typed, and waits
  # for a waiter, which the wake line, typed once in its place, may bring (F-240).
  test "a row too long to type, with no home, waits", ctx do
    main(ctx)
    stop_supervised!(Mailbox)
    spec = Supervisor.child_spec({Mailbox, Keyword.delete(ctx.mopts, :home)}, id: :no_home)
    mailbox = start_supervised!(spec)
    text = String.duplicate("x", Transport.Typed.bound())
    {:ok, {:queued, long}} = Mailbox.message(mailbox, "d1", "main", text)

    assert {:ok, %{status: "queued", attempt: ~s(["too_long","no_home"])}} =
             await(fn ->
               Mailbox.status(mailbox, 0)
               row = Table.get(ctx.mtable, long)
               if row.attempt, do: {:ok, row}, else: row
             end)

    assert {:ok, ["[framework] a message is waiting for you."]} = submitted(ctx, 1)
    assert %{status: "queued"} = Table.get(ctx.mtable, long)
  end

  # Break_Delivery_SettleEarly's guard (the take bound): with no user line past it, the row is
  # due again, first, under its same uuid, and typed again. The row behind it waits only that
  # long, and goes once the retry is delivered (F-277).
  test "a typed row with no user line past the take bound is due again", ctx do
    main = main(ctx)
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "d1", "main", "lost one")
    {:ok, {:queued, two}} = Mailbox.message(ctx.mailbox, "d1", "main", "two")
    %{uuid: u1} = Table.get(ctx.mtable, one)
    assert {:ok, ["From d1 (message): lost one [delivery " <> _]} = submitted(ctx, 1)
    assert {:ok, %{uuid: ^u1, again: 1}} = until(ctx, one, &(&1.again == 1))
    assert %{status: "queued"} = Table.get(ctx.mtable, two)

    assert {:ok, [line, line]} = submitted(ctx, 2)
    user_line(main, line)
    assert {:ok, %{status: "delivered"}} = until(ctx, one, &(&1.status == "delivered"))

    assert {:ok, [_, _, "From d1 (message): two [delivery " <> _ = line2]} = submitted(ctx, 3)
    user_line(main, line2)
    assert {:ok, %{status: "delivered"}} = until(ctx, two, &(&1.status == "delivered"))
  end

  # F-277, F-279: a short text goes whole, with its 25 characters of frame and 48 of mark.
  test "a 4-character message is pasted whole and settles by its line", ctx do
    main = main(ctx)
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "operator", "main", "test")
    %{uuid: u1} = Table.get(ctx.mtable, one)
    line1 = "From operator (message): test [delivery #{u1}]"
    assert String.length(line1) > 76
    assert {:ok, [^line1]} = submitted(ctx, 1)

    user_line(main, line1)
    assert {:ok, %{status: "delivered"}} = until(ctx, one, &(&1.status == "delivered"))
    refute File.exists?(Path.join(Sessions.due_dir(ctx.dir, "main"), "#{one}.md"))
  end

  # F-279: a row of any length within the bound, and of any number of lines, is pasted whole
  # into the default 200-column pane, not as a file. Its user line carries the whole text and
  # its mark, and settles it. F-287: this stand-in asks for bracketed paste only at its start,
  # before its pane attaches under dtach, so the pane never sees it; the paste's own markers
  # keep its newlines from submitting.
  test "a 300-character and a 5-line message each go pasted and settle by their line", ctx do
    main = main(ctx, paste_mode: :once)
    wide = String.duplicate("y", 300)
    lines = Enum.map_join(1..5, "\n", &"line #{&1}")
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "operator", "main", wide)
    {:ok, {:queued, two}} = Mailbox.message(ctx.mailbox, "operator", "main", lines)

    %{uuid: u1} = Table.get(ctx.mtable, one)
    text1 = "From operator (message): #{wide} [delivery #{u1}]"
    assert {:ok, [^text1]} = submitted(ctx, 1)
    user_line(main, text1)
    assert {:ok, %{status: "delivered"}} = until(ctx, one, &(&1.status == "delivered"))

    %{uuid: u2} = Table.get(ctx.mtable, two)
    text2 = "From operator (message):\n\n#{lines} [delivery #{u2}]"
    assert {:ok, [^text1, line2]} = submitted(ctx, 2)
    assert line2 == String.replace(text2, "\n", "\\n")
    user_line(main, text2)
    assert {:ok, %{status: "delivered"}} = until(ctx, two, &(&1.status == "delivered"))

    due = Sessions.due_dir(ctx.dir, "main")
    refute File.exists?(Path.join(due, "#{one}.md")) or File.exists?(Path.join(due, "#{two}.md"))
  end

  # SettleSeen, Break_Delivery_SettleAtIdle (F-277): a typed row's line delivers it while the
  # turn it started still runs. The app may answer each turn's end itself, so no settle reads an
  # ended turn; a row waiting for one stayed sending, and every row behind it waited. Here the
  # pointer's line is in the transcript, the session file reads busy, and the row is delivered;
  # the row behind it goes once the turn ends.
  test "a typed pointer's line delivers its row while the turn runs", ctx do
    main = main(ctx)
    since = since(ctx, main)
    long = String.duplicate("x", Transport.Typed.bound())
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "d1", "main", long)
    {:ok, {:queued, two}} = Mailbox.message(ctx.mailbox, "d1", "main", "two")

    %{uuid: u1} = Table.get(ctx.mtable, one)
    assert {:ok, [line1]} = submitted(ctx, 1)
    assert line1 =~ "a message for you is in `" and line1 =~ "[delivery #{u1}]"
    running(ctx, main, since)

    user_line(main, line1)
    assert {:ok, %{status: "delivered"}} = until(ctx, one, &(&1.status == "delivered"))
    assert %{status: "queued"} = Table.get(ctx.mtable, two)

    set_turn(ctx, main, "idle")
    assert {:ok, [^line1, "From d1 (message): two [delivery " <> _ = line2]} = submitted(ctx, 2)
    user_line(main, line2)
    assert {:ok, %{status: "delivered"}} = until(ctx, two, &(&1.status == "delivered"))
  end

  # RedeliverAfterRestart's guard (F-277): a row a restart left sending is settled by the same
  # evidence, its turn running or not, never typed again; the row behind it then goes.
  test "a typed row left sending by a restart is settled by its line", ctx do
    main = main(ctx)
    since = since(ctx, main)
    {:ok, {:queued, one}} = Mailbox.message(ctx.mailbox, "d1", "main", "one")
    {:ok, {:queued, two}} = Mailbox.message(ctx.mailbox, "d1", "main", "two")
    assert {:ok, [line1]} = submitted(ctx, 1)
    running(ctx, main, since)

    # The Inlet's answer is in (its own time replaces the mark's later one), so no hand-on runs.
    assert {:ok, _} = until(ctx, one, &(&1.sent_at <= System.os_time(:millisecond)))
    stop_supervised!(Mailbox)

    ctx = %{
      ctx
      | mailbox: start_supervised!(Supervisor.child_spec({Mailbox, ctx.mopts}, id: :again))
    }

    assert %{status: "sending", via: "typed"} = Table.get(ctx.mtable, one)

    user_line(main, line1)
    assert {:ok, %{again: 0}} = until(ctx, one, &(&1.status == "delivered"))
    assert ScreenStandIn.submitted(ctx.dir) == [line1]

    set_turn(ctx, main, "idle")
    assert {:ok, [^line1, "From d1 (message): two [delivery " <> _]} = submitted(ctx, 2)
    assert %{status: "sending"} = Table.get(ctx.mtable, two)
  end

  # F-233: the operator's reload goes in as a typed row does, its turn read in the write's step;
  # a headless delegate, or a name with no row, takes nothing.
  test "reloads an idle main session's plugins, and refuses a headless delegate", ctx do
    main(ctx)
    assert {:ok, :reloaded} = Mailbox.reload_plugins(ctx.mailbox, "main")
    assert ScreenStandIn.submitted(ctx.dir) == ["/reload-plugins"]

    d1 = %{host: "test", name: "d1", socket: "d1", account: "work", cwd: ctx.dir}
    Sessions.Table.starting(ctx.table, Map.merge(d1, %{role: "delegate", resume: nil}))
    assert {:refused, :headless} = Mailbox.reload_plugins(ctx.mailbox, "d1")
    assert {:refused, {:no_agent, "d9"}} = Mailbox.reload_plugins(ctx.mailbox, "d9")
    assert ScreenStandIn.submitted(ctx.dir) == ["/reload-plugins"]
  end

  defp main(ctx, stand_in \\ []) do
    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), stand_in)
    launch = Keyword.put(SessionsSetup.launch(ctx, :at_start), :claude, claude)

    {:ok, %{pid: pid, session_id: sid}} =
      Sessions.start(ctx.sessions, "main", ctx.account, launch)

    {:ok, transcript} = Transcripts.path(ctx.account.config_dir, ctx.dir, sid)
    %{pid: pid, transcript: transcript}
  end

  # Once the stand-in has run the typed line's turn, the turn reads running, as when an app's
  # answer to the Stop hook goes on with it. The stand-in's last write for the Enter is its
  # session file saying idle, newer than `since`. Its screen is no sign: it draws once a burst
  # of keys is in, so the empty box from before the line can still show.
  defp running(ctx, main, since) do
    assert {:ok, _} =
             await(fn ->
               case session_file(ctx, main) do
                 %{"status" => "idle", "updatedAt" => at} = file when at > since -> {:ok, file}
                 other -> other
               end
             end)

    set_turn(ctx, main, "busy")
  end

  # The time of the session file's last write, before any line is typed.
  defp since(ctx, main), do: session_file(ctx, main)["updatedAt"]

  defp session_file(ctx, main) do
    path = Path.join([ctx.account.config_dir, "sessions", "#{main.pid}.json"])
    {:ok, json} = path |> File.read!() |> JSON.decode()
    json
  end

  defp set_turn(ctx, main, status) do
    path = Path.join([ctx.account.config_dir, "sessions", "#{main.pid}.json"])
    json = session_file(ctx, main)
    json = %{json | "status" => status, "updatedAt" => System.os_time(:millisecond)}
    File.write!(path <> ".tmp", JSON.encode!(json))
    File.rename!(path <> ".tmp", path)
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
    cued(ctx.mailbox, %{topic: "sessions:test:work", ids: []})
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

  # A cue's pass reads in a task and applies its answer after later calls have answered
  # (F-289), so no call after the cue shows its effect. The cue is handled once the Mailbox
  # runs no pass: a cue that came during one starts the next before this one ends.
  defp cued(mailbox, cue) do
    Mailbox.cue(mailbox, cue)
    {:ok, _} = await(fn -> if passed?(mailbox), do: {:ok, :passed} end, 10_000)
  end

  # A Mailbox the test stopped or restarted runs no pass of this cue: its successor settles on
  # its own start.
  defp passed?(mailbox) do
    :sys.get_state(mailbox).pass == nil
  catch
    :exit, {:noproc, _} -> true
  end
end
