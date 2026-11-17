defmodule CodingAgentFramework.SessionsDialogTest do
  @moduledoc """
  A start that stops on Claude Code's startup dialogs (F-140), over a real `Sessions`, `Inlet`,
  `Registry`, dtach and tmux, with the screen stand-in drawing 2.1.322's trust dialog and then
  its imports dialog, and writing no session file until both are answered. Each test names the
  `Dialog.tla` property it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Inlet, Registry, ScreenStandIn, Sessions, SessionsSetup}
  alias CodingAgentFramework.Sessions.{Agents, Table}

  @trust "Yes, I trust this folder"
  @no_imports "No, disable external imports"

  setup {SessionsSetup, :sessions}

  setup ctx do
    inlet = start_supervised!({Inlet, tmux: ctx.server})

    claude =
      ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), dialogs: [:trust, :imports])

    launch = SessionsSetup.launch(ctx, :at_start) |> Keyword.put(:claude, claude)
    {:ok, agents} = Agents.open(Path.join(ctx.dir, "caf.db"), "test")

    {:ok,
     inlet: inlet, launch: launch, agents: agents, opts: ctx.opts ++ [inlet: inlet, look: 50]}
  end

  defp sessions(ctx, extra \\ []) do
    spec =
      Supervisor.child_spec({Sessions, ctx.opts ++ extra}, id: make_ref(), restart: :temporary)

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

  # AtMostOnce across a restart: the row waits through it, an answer marked pressing when the
  # process ended is unknown and never pressed, and another answer goes as before.
  test "a restart keeps the row waiting, and a press it cut is never made again", ctx do
    first = sessions(ctx)
    assert {:unknown, {:dialog, :trust}} = Sessions.start(first, "alpha", ctx.account, ctx.launch)
    GenServer.stop(first)

    # A press marked before the restart, as if the process ended before its answer was known.
    row = Agents.get(ctx.agents, "alpha")
    Table.update(ctx.table, row.id, answers: %{trust: %{label: @trust, mark: "pressing"}})

    second = sessions(ctx)

    assert {:ok, %{answers: %{trust: %{mark: "unknown"}}}} =
             await(fn ->
               case Agents.dialog(Agents.get(ctx.agents, "alpha")) do
                 %{answers: %{trust: %{mark: "unknown"}}} = d -> {:ok, d}
                 other -> other
               end
             end)

    assert {:refused, {:answered, "unknown"}} =
             Sessions.answer_dialog(second, "alpha", :trust, @trust)

    refute File.exists?(Path.join(ctx.dir, "trusted"))
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

    assert {_, _} = Sessions.answer_dialog(sessions, "alpha", :trust, "No, exit")

    assert {:ok, "stopped"} =
             await(fn ->
               case Agents.get(ctx.agents, "alpha").status do
                 "stopped" -> {:ok, "stopped"}
                 other -> other
               end
             end)
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
