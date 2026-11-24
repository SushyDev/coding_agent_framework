defmodule CodingAgentFramework.SessionsDialogTest do
  @moduledoc """
  A start that stops on Claude Code's startup dialogs (F-140), over a real `Sessions`, `Inlet`,
  `Registry`, dtach and tmux, with the screen stand-in drawing 2.1.322's trust dialog and then
  its imports dialog, and writing no session file until both are answered. Each test names the
  `Dialog.tla` property it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Acts, Inlet, Registry, ScreenStandIn, Sessions, SessionsSetup}
  alias CodingAgentFramework.Sessions.{Agents, Dialog, Table}

  @trust "Yes, I trust this folder"
  @no_imports "No, disable external imports"

  setup {SessionsSetup, :sessions}

  setup ctx do
    # A press reads back the stand-in's redraw within `see:`. A loaded host redraws late, and
    # a late read back is an unknown press that leaves the start on its dialog (F-238).
    # `Sessions` presses with its own `press_see:`, the same bound.
    see = scaled(2_000)
    inlet = start_supervised!({Inlet, tmux: ctx.server, see: see})

    claude =
      ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), dialogs: [:trust, :imports])

    launch = SessionsSetup.launch(ctx, :at_start) |> Keyword.put(:claude, claude)
    {:ok, agents} = Agents.open(Path.join(ctx.dir, "caf.db"), "test")

    {:ok,
     inlet: inlet,
     launch: launch,
     agents: agents,
     opts: ctx.opts ++ [inlet: inlet, look: 50, press_see: see]}
  end

  defp sessions(ctx, extra \\ []) do
    spec =
      Supervisor.child_spec({Sessions, Keyword.merge(ctx.opts, extra)},
        id: make_ref(),
        restart: :temporary
      )

    start_supervised!(spec)
  end

  # OnlyAsked and DialogShown: nothing answers by default; the start answers at once, the row
  # shows each dialog in turn, with a cue, and the start goes on once a person answered both.
  test "a start on a dialog waits on a person, who answers each one by label", ctx do
    sessions = sessions(ctx)

    assert {:unknown, {:dialog, :trust}} =
             Sessions.start(sessions, "alpha", ctx.account, ctx.launch)

    row = Agents.get(ctx.agents, "alpha")
    assert row.status == "dialog"
    assert_received {:cue, %{topic: "sessions:" <> _, ids: [id]}} when id == row.id

    assert %{kind: :trust, options: ["No, exit", @trust], selected: "No, exit", answers: %{}} =
             Agents.dialog(row)

    refute File.exists?(Path.join(ctx.dir, "trusted"))

    # An answer for another dialog, or with a label it does not show, presses nothing.
    assert {:refused, {:shown, :trust}} =
             Sessions.answer_dialog(sessions, "alpha", :imports, @no_imports)

    assert {:refused, {:no_option, "Yes"}} =
             Sessions.answer_dialog(sessions, "alpha", :trust, "Yes")

    assert {:refused, {:bad, :kind}} =
             Sessions.answer_dialog(sessions, "alpha", "permission", "Yes")

    assert {:ok, :sent} = Sessions.answer_dialog(sessions, "alpha", "trust", @trust)
    assert File.exists?(Path.join(ctx.dir, "trusted"))

    # The next dialog is the row's; the trust dialog's answer is never pressed again.
    assert {:ok, %{kind: :imports, paths: ["/work/outside.md"]} = shown} =
             await(fn -> shown(ctx, "alpha", :imports) end)

    assert shown.answers == %{trust: %{label: @trust, mark: "sent"}}

    assert {:refused, {:shown, :imports}} =
             Sessions.answer_dialog(sessions, "alpha", :trust, @trust)

    assert {:ok, :sent} = Sessions.answer_dialog(sessions, "alpha", :imports, @no_imports)
    assert File.read!(Path.join(ctx.dir, "imports")) == "no"

    # Past the dialogs the session file names the process: the row runs, and the prompt went.
    assert {:ok, %{status: "running", pid: pid}} =
             await(fn -> running(ctx, sessions, "alpha") end)

    assert is_integer(pid)
    assert {:ok, ["brief"]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    assert Agents.dialog(Agents.get(ctx.agents, "alpha")) == nil
  end

  # NotEndedOnDialog and LeaseWhileLive: past the start's deadline the row still waits, not
  # free, so its name is not started again and nothing ends it as an orphan.
  test "the start's deadline does not end a row on a dialog", ctx do
    sessions = sessions(ctx)

    assert {:unknown, {:dialog, :trust}} =
             Sessions.start(sessions, "alpha", ctx.account, ctx.launch)

    Agent.update(ctx.clock, &(&1 + 3_600_000))
    send(sessions, :deadline)
    {:ok, []} = Sessions.ends_owed(sessions)

    row = Agents.get(ctx.agents, "alpha")
    assert row.status == "dialog"
    refute Agents.free?(row)

    assert {:refused, {:exists, "dialog"}} =
             Sessions.start(sessions, "alpha", ctx.account, ctx.launch)
  end

  # AtMostOnce across a restart, and Clear (F-144): the row waits through it, an answer marked
  # pressing when the process ended is cut and not pressed again until a person who sees the
  # dialog unmoved clears it, once; then it may be answered once more.
  test "a restart keeps the row waiting, and a press it cut goes again only after a clear", ctx do
    first = sessions(ctx)
    assert {:unknown, {:dialog, :trust}} = Sessions.start(first, "alpha", ctx.account, ctx.launch)
    GenServer.stop(first)

    # A press marked before the restart, as if the process ended before its answer was known.
    row = Agents.get(ctx.agents, "alpha")
    Table.update(ctx.table, row.id, answers: %{trust: %{label: @trust, mark: "pressing"}})

    second = sessions(ctx)

    assert {:ok, %{answers: %{trust: %{mark: "cut"}}}} = await(fn -> marked(ctx, "cut") end)

    assert {:refused, {:answered, "cut"}} =
             Sessions.answer_dialog(second, "alpha", :trust, @trust)

    refute File.exists?(Path.join(ctx.dir, "trusted"))
    assert Agents.get(ctx.agents, "alpha").status == "dialog"

    # The person's clear, once: the pane still shows the trust dialog, its first option selected.
    assert {:refused, :no_answer} = Sessions.clear_dialog(second, "alpha", :imports)
    assert {:ok, :cleared} = Sessions.clear_dialog(second, "alpha", "trust")
    assert {:refused, {:not_cut, "cleared"}} = Sessions.clear_dialog(second, "alpha", :trust)
    assert {:ok, :sent} = Sessions.answer_dialog(second, "alpha", :trust, @trust)
    assert File.exists?(Path.join(ctx.dir, "trusted"))

    assert {:ok, %{answers: %{trust: %{mark: "sent", cleared: true}}}} =
             await(fn -> marked(ctx, "sent") end)
  end

  # Dialog.tla's Stop (F-144) and EndPress (F-231): a person gives up a start without answering;
  # the trust dialog's exit option is pressed, and the row is stopped and its name free.
  test "a stop of a row on a dialog ends its process", ctx do
    sessions = sessions(ctx)

    assert {:unknown, {:dialog, :trust}} =
             Sessions.start(sessions, "alpha", ctx.account, ctx.launch)

    assert {:ok, :stopped} = Sessions.stop(sessions, "alpha")
    row = Agents.get(ctx.agents, "alpha")
    assert row.status == "stopped"
    assert Agents.free?(row)
    refute File.exists?(Path.join(ctx.dir, "trusted"))
  end

  # Dialog.tla's AskEnd, EndPress and EndDone (F-231's new-3): the operator's end of a main
  # session waiting on its trust dialog presses the dialog's exit option, an act in Acts by the
  # operator, and the row is ended once its process is gone; it never ran a turn.
  test "an end of a main session on its trust dialog presses its exit and ends it", ctx do
    acts =
      start_supervised!(
        {Acts, db: Path.join(ctx.dir, "acts.db"), start_id: "t", host: "test", instance: "a"}
      )

    sessions = sessions(ctx, acts: acts)
    launch = Keyword.put(ctx.launch, :kind, :main)
    assert {:unknown, {:dialog, :trust}} = Sessions.start(sessions, "alpha", ctx.account, launch)

    assert {:ok, :ended} = Sessions.end_main(sessions, "alpha", force: true, timeout: 30_000)
    row = Agents.get(ctx.agents, "alpha")
    assert row.status == "ended"
    assert Agents.ended?(row)
    refute File.exists?(Path.join(ctx.dir, "trusted"))
    assert ScreenStandIn.prompts(ctx.dir) == []

    # The press of "No, exit" is the operator's act: it went, and the pane gone with the
    # process is the dialog left (F-242).
    assert {:ok, [%{actor: "operator", target: "alpha", status: "settled"} = press]} =
             Acts.rows(acts, act: "answer_startup")

    assert press.outcome == "verified"
    assert %{trust: %{label: "No, exit", mark: "sent"}} = Dialog.answers(row)
    assert {:refused, {:ended, "alpha"}} = Sessions.start(sessions, "alpha", ctx.account, launch)
  end

  # Dialog.tla's EndTerm (F-231): the imports dialog has no exit option, so the end sends SIGTERM
  # to the held program's record, and the row is ended; the dialog is never answered.
  test "an end of a main session on a dialog with no exit option sends SIGTERM", ctx do
    dialog = fn kind, _options -> if kind == :trust, do: {:answer, @trust}, else: :ask end
    sessions = sessions(ctx, dialog: dialog)
    launch = Keyword.put(ctx.launch, :kind, :main)

    assert {:unknown, {:dialog, :imports}} =
             Sessions.start(sessions, "alpha", ctx.account, launch)

    assert {:ok, :ended} = Sessions.end_main(sessions, "alpha", timeout: 30_000)
    assert %{status: "ended"} = row = Agents.get(ctx.agents, "alpha")
    refute Map.has_key?(Dialog.answers(row), :imports)
    refute File.exists?(Path.join(ctx.dir, "imports"))
  end

  # The press goes in a task (F-144): while the Inlet is held up, the row is marked pressing and
  # Sessions answers other calls; each answer is a row in Acts, actor the person or the app.
  test "a press runs in a task, and each answer is an act in Acts", ctx do
    acts =
      start_supervised!(
        {Acts, db: Path.join(ctx.dir, "acts.db"), start_id: "t", host: "test", instance: "a"}
      )

    dialog = fn kind, _options -> if kind == :trust, do: {:answer, @trust}, else: :ask end
    # No periodic look while the Inlet is held up: one would wait on it (F-144's new-2).
    sessions = sessions(ctx, acts: acts, dialog: dialog, look: 600_000)

    assert {:unknown, {:dialog, :imports}} =
             Sessions.start(sessions, "alpha", ctx.account, ctx.launch)

    :sys.suspend(ctx.inlet)

    answer =
      Task.async(fn ->
        Sessions.answer_dialog(sessions, "alpha", :imports, @no_imports, by: "operator")
      end)

    # A look a cue started before the mark may wait on the held Inlet first, up to 5 s.
    assert {:ok, %{answers: %{imports: %{mark: "pressing"}}}} =
             await(fn -> marked(ctx, "pressing", :imports) end, 30_000)

    assert {:ok, []} = Sessions.ends_owed(sessions)
    :sys.resume(ctx.inlet)
    assert {:ok, :sent} = Task.await(answer, 30_000)

    assert {:ok, [trust, imports]} = Acts.rows(acts, act: "answer_startup")
    assert %{actor: "app", target: "alpha", status: "settled", outcome: "verified"} = trust
    assert %{actor: "operator", status: "settled", outcome: "verified"} = imports
    assert imports.state =~ "imports"

    # A second answer of the same state is refused, by the mark and by the act.
    assert {:refused, _} =
             Sessions.answer_dialog(sessions, "alpha", :imports, @no_imports, by: "operator")
  end

  # An unknown main session's pane is read in a task (F-151's look, F-153): while the Inlet is
  # held up, Sessions answers other calls, and the dialog the look finds becomes the row's.
  test "an unknown row's look runs in a task, and its dialog becomes the row's", ctx do
    sessions = sessions(ctx, look: 600_000)

    assert {:unknown, {:dialog, :trust}} =
             Sessions.start(sessions, "alpha", ctx.account, ctx.launch)

    # As a start that met a screen `Screen` does not read: unknown, no dialog shown.
    row = Agents.get(ctx.agents, "alpha")
    Table.update(ctx.table, row.id, status: "unknown", dialog: nil)

    :sys.suspend(ctx.inlet)
    send(sessions, :look)

    assert {:ok, _} =
             await(fn ->
               peeking = :sys.get_state(sessions).peeking
               if Map.has_key?(peeking, "alpha"), do: {:ok, peeking}, else: :none
             end)

    assert {:ok, []} = Sessions.ends_owed(sessions, timeout: 1_000)
    assert Agents.get(ctx.agents, "alpha").status == "unknown"

    :sys.resume(ctx.inlet)
    assert {:ok, %{kind: :trust, answers: %{}}} = await(fn -> shown(ctx, "alpha", :trust) end)
    assert Agents.get(ctx.agents, "alpha").status == "dialog"
  end

  # The app's choice: a callback that answers the trust dialog presses it, marked first, and
  # leaves the imports dialog to a person.
  test "the app's callback answers the kinds it chooses, and asks for the rest", ctx do
    me = self()

    dialog = fn kind, options ->
      send(me, {:asked, kind, options})
      if kind == :trust, do: {:answer, @trust}, else: :ask
    end

    sessions = sessions(ctx, dialog: dialog)

    assert {:unknown, {:dialog, :imports}} =
             Sessions.start(sessions, "alpha", ctx.account, ctx.launch)

    assert_received {:asked, :trust, ["No, exit", @trust]}
    assert_received {:asked, :imports, [@no_imports, "Yes, allow external imports"]}
    assert File.exists?(Path.join(ctx.dir, "trusted"))

    assert %{kind: :imports, answers: %{trust: %{mark: "sent"}}} =
             Agents.dialog(Agents.get(ctx.agents, "alpha"))
  end

  # "No, exit": the process ends on the dialog, and the row is stopped, its name free.
  test "an answer that exits stops the row", ctx do
    sessions = sessions(ctx)

    assert {:unknown, {:dialog, :trust}} =
             Sessions.start(sessions, "alpha", ctx.account, ctx.launch)

    # The pane closes with the process: answered then, not at the end of its read (F-242).
    {took, answer} =
      :timer.tc(
        fn -> Sessions.answer_dialog(sessions, "alpha", :trust, "No, exit") end,
        :millisecond
      )

    assert {{:ok, :sent}, true} = {answer, took < scaled(2_000)}

    assert {:ok, "stopped"} =
             await(fn ->
               case Agents.get(ctx.agents, "alpha").status do
                 "stopped" -> {:ok, "stopped"}
                 other -> other
               end
             end)
  end

  # F-242: `Sessions` presses with its own `press_see:`, and bounds the press by it
  # (`Inlet.press_bound/1`), over an `Inlet` whose own `see:` is the library's 2 s. The held
  # program stopped (SIGSTOP) for 3 s as the press goes redraws past 2 s, and is answered.
  test "a press reads back at the instance's press_see, past the Inlet's own see", ctx do
    inlet = start_supervised!({Inlet, tmux: ctx.server}, id: :two_seconds)
    sessions = sessions(ctx, inlet: inlet, press_see: 10_000)

    assert {:unknown, {:dialog, :trust}} =
             Sessions.start(sessions, "alpha", ctx.account, ctx.launch)

    [pid] = File.ls!(Path.join(ctx.dir, "pids"))
    {:ok, %{status: 0}} = kill(pid, "-STOP")
    spawn(fn -> receive after: (3_000 -> kill(pid, "-CONT")) end)

    {took, answer} =
      :timer.tc(
        fn ->
          Sessions.answer_dialog(sessions, "alpha", :trust, @trust,
            timeout: Sessions.press_call(10_000)
          )
        end,
        :millisecond
      )

    assert {{:ok, :sent}, true} = {answer, took >= 3_000}
    assert File.exists?(Path.join(ctx.dir, "trusted"))
  end

  # Move.tla's IdleRead of a limited turn (F-191): Claude Code's own wait is a `limited` turn,
  # which only a move's stop takes as ended, read from the screen through the Inlet; its session
  # file says busy. A stop that is no move, or of a row with no limit, is refused.
  test "a move's stop ends Claude Code's own wait, read from the screen", ctx do
    sessions = sessions(ctx)
    claude = ScreenStandIn.write!(ctx.dir)
    wrapper = Path.join(ctx.dir, "claude-limit-wait")
    File.write!(wrapper, "#!#{program!(:bash)}\nexec #{claude} --screen limit_wait \"$@\"\n")
    File.chmod!(wrapper, 0o755)
    launch = ctx.launch |> Keyword.put(:claude, wrapper) |> Keyword.delete(:prompt)

    assert {:ok, %{pid: pid}} = Sessions.start(sessions, "alpha", ctx.account, launch)
    assert {:refused, {:not_idle, "busy"}} = Sessions.stop(sessions, "alpha", for: :move)

    limit = %{"until" => System.os_time(:second) + 3600, "step" => "own", "line" => "l1"}
    assert {:ok, _} = Sessions.put_limit(sessions, "alpha", limit, from: nil)
    assert {:refused, {:not_idle, "busy"}} = Sessions.stop(sessions, "alpha")
    assert {:ok, :stopped} = Sessions.stop(sessions, "alpha", for: :move)
    refute alive?(pid)
  end

  # F-203, from F-198's new-4: a numbered menu no rule names before the session file (an
  # onboarding menu on a new account, say) is a startup dialog with no default: the app's
  # callback is never asked, and a person's press is the Inlet's read back of the menu.
  test "a start's menu is a startup dialog that only a person answers", ctx do
    me = self()
    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), dialogs: [:menu])
    launch = Keyword.put(ctx.launch, :claude, claude)

    dialog = fn kind, options ->
      send(me, {:asked, kind})
      {:answer, hd(options)}
    end

    sessions = sessions(ctx, dialog: dialog)

    assert {:unknown, {:dialog, :start_menu}} =
             Sessions.start(sessions, "alpha", ctx.account, launch)

    refute_received {:asked, _}
    options = ScreenStandIn.menu()

    assert %{kind: :start_menu, title: title, options: ^options, answers: %{}} =
             Agents.dialog(Agents.get(ctx.agents, "alpha"))

    assert is_binary(title)
    assert {:ok, :sent} = Sessions.answer_dialog(sessions, "alpha", "start_menu", "Not now")
    assert ScreenStandIn.menu_answer(ctx.dir) == "Not now"
    assert {:ok, %{status: "running"}} = await(fn -> running(ctx, sessions, "alpha") end)
  end

  # F-206 (F-203's new-2), Dialog.tla's reads (Dialog_Menus): a start that shows two menus no
  # rule names one after the other asks a person each, as its own read. The first's answer is
  # none to the second, an answer naming the first's read presses nothing on the second, each
  # is pressed once under its own act, and the start goes on after the second.
  test "each menu of one start is its own read, answered in turn", ctx do
    acts =
      start_supervised!(
        {Acts, db: Path.join(ctx.dir, "acts.db"), start_id: "t", host: "test", instance: "a"}
      )

    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), dialogs: [:menu, :menu2])
    launch = Keyword.put(ctx.launch, :claude, claude)
    sessions = sessions(ctx, acts: acts)
    [title, next] = ScreenStandIn.menu_titles()

    assert {:unknown, {:dialog, :start_menu}} =
             Sessions.start(sessions, "alpha", ctx.account, launch)

    assert %{title: ^title, at: first, answers: %{}} =
             Agents.dialog(Agents.get(ctx.agents, "alpha"))

    assert {:ok, :sent} =
             Sessions.answer_dialog(sessions, "alpha", :start_menu, "Not now", at: first)

    # The second menu is a new read, open: the first's answer is not its answer.
    assert {:ok, %{at: second, answers: answers}} = await(fn -> titled(ctx, next) end)
    assert second > first and answers == %{}

    assert {:refused, {:read, ^second}} =
             Sessions.answer_dialog(sessions, "alpha", :start_menu, "Yes", at: first)

    assert {:ok, :sent} =
             Sessions.answer_dialog(sessions, "alpha", :start_menu, "Yes", at: second)

    assert ScreenStandIn.menu_answers(ctx.dir) == ["Not now", "Yes"]
    assert {:ok, %{status: "running"}} = await(fn -> running(ctx, sessions, "alpha") end)

    assert {:ok, [one, two]} = Acts.rows(acts, act: "answer_startup")
    assert %{status: "settled", outcome: "verified"} = one
    assert %{status: "settled", outcome: "verified"} = two
    assert one.state =~ "#{first}" and two.state =~ "#{second}"
  end

  defp titled(ctx, title) do
    case Agents.dialog(Agents.get(ctx.agents, "alpha")) do
      %{title: ^title} = d -> {:ok, d}
      other -> other
    end
  end

  defp marked(ctx, mark, kind \\ :trust) do
    case Agents.dialog(Agents.get(ctx.agents, "alpha")) do
      %{answers: %{^kind => %{mark: ^mark}}} = d -> {:ok, d}
      other -> other
    end
  end

  defp nonempty([]), do: :none
  defp nonempty(list), do: {:ok, list}

  defp shown(ctx, name, kind) do
    case Agents.dialog(Agents.get(ctx.agents, name)) do
      %{kind: ^kind} = d -> {:ok, d}
      other -> other
    end
  end

  # The session file is read on the Registry's cue, as the app's Cues hands it.
  defp running(ctx, sessions, name) do
    {:ok, _} = Registry.read(ctx.registry)
    Sessions.cue(sessions, %{topic: "registry:test:work", ids: []})

    case Agents.get(ctx.agents, name) do
      %{status: "running"} = row -> {:ok, row}
      row -> row.status
    end
  end
end
