defmodule CodingAgentFramework.PromptsTest do
  @moduledoc """
  The inbox (F-179, `Prompt.tla`) over its real owners: an `Intake` that holds a permission
  request and a `Stop` at the cap, a `Mailbox` that keeps an ask, and a `Sessions` whose start
  waits on a startup dialog drawn by the screen stand-in, on a real tmux server and real dtach
  sockets. Each kind opens a prompt, is listed and cued, and is answered once; a delegate's
  parent is told once. The test hands `Prompts` each owner's cue, as `Cues` does in the tree.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Grants, Inlet, Intake, Mailbox, Prompts, ScreenStandIn, Sessions}
  alias CodingAgentFramework.{SessionsSetup, Stream}

  @trust "Yes, I trust this folder"

  setup {SessionsSetup, :sessions}

  setup ctx do
    me = self()
    db = Path.join(ctx.dir, "caf.db")
    cue = &send(me, {:cue, &1})

    # A Stop the app's callback blocks is held for a person at once: the cap's last honored
    # block is the first.
    intake =
      start_supervised!(
        {Intake,
         db: db, host: "test", notify: cue, stop: fn _ -> {:block, "Go on."} end, stop_cap: 1}
      )

    tree = [
      %{name: "main", project: "app", parent: nil},
      %{name: "d1", project: "app", parent: "main"},
      %{name: "alpha", project: "app", parent: nil}
    ]

    grants = Grants.new(fn -> tree end, operator: "operator")

    mopts = [
      db: db,
      grants: grants,
      stream: ctx.stream,
      sessions_db: db,
      host: "test",
      notify: cue
    ]

    mailbox = start_supervised!({Mailbox, mopts})
    {:ok, mtable} = Mailbox.Table.open(db)

    inlet = start_supervised!({Inlet, tmux: ctx.server})
    opts = Keyword.merge(ctx.opts, inlet: inlet, look: 50)
    spec = Supervisor.child_spec({Sessions, opts}, id: :dialogs, restart: :temporary)
    sessions = start_supervised!(spec)

    popts = [host: "test", intake: intake, intake_db: db, sessions: sessions, sessions_db: db]
    popts = popts ++ [mailbox: mailbox, notify: &send(me, {:prompts, &1})]

    {:ok,
     intake: intake,
     mailbox: mailbox,
     mtable: mtable,
     sessions: sessions,
     popts: popts,
     prompts: start_supervised!({Prompts, popts})}
  end

  # A hook's post held by `Intake`, as its plug holds it: the decision it gets back is written.
  defp held(ctx, event, sid, fields) do
    body = JSON.encode!(Map.merge(%{"hook_event_name" => event, "session_id" => sid}, fields))

    Task.async(fn ->
      {:ok, {:held, id, ref, wait}} = Intake.post(ctx.intake, "work", body)

      receive do
        {^ref, {:decision, decision}} ->
          Intake.written(ctx.intake, id, ref)
          {:decision, decision}

        {^ref, :release} ->
          :released
      after
        wait -> :timeout
      end
    end)
  end

  # The owners' cues, handed on as `Cues` would, until the inbox's cue that one of them makes:
  # a write that opens no prompt (a Stop's hold before the callback answers it) cues none.
  defp cued(ctx) do
    receive do
      {:cue, cue} ->
        Prompts.cue(ctx.prompts, cue)
        cued(ctx)

      {:prompts, %{topic: "prompts", ids: ids}} ->
        ids
    after
      5_000 -> flunk("no prompts cue")
    end
  end

  defp notices(ctx, to),
    do: for(%{to_agent: ^to, kind: "prompt"} = m <- Mailbox.Table.open_rows(ctx.mtable), do: m)

  # A headless delegate of `main` started as `Delegates` starts one (F-152): its row names its
  # account's session, which the hooks name.
  defp started(ctx, name) do
    {:ok, {:queued, _}} = Mailbox.brief(ctx.mailbox, "main", name, "Review it.", Stream.uuid())

    {:ok, first} =
      Mailbox.launch(ctx.mailbox, name, System.os_time(:millisecond) + 60_000, via: :stream)

    launch =
      Keyword.put(
        SessionsSetup.headless(ctx, :on_message),
        :first,
        Map.take(first, [:uuid, :text])
      )

    answer = Sessions.start(ctx.sessions, name, ctx.account, launch)
    {:ok, _} = Mailbox.launched(ctx.mailbox, first.id, answer)
    {:ok, %{session_id: sid}} = answer
    flush_cues()
    sid
  end

  defp flush_cues do
    receive do
      {:cue, _} -> flush_cues()
    after
      0 -> :ok
    end
  end

  # Prompt.tla's Open, Answer and OneAnswer, and ParentToldOnce: a delegate's held permission
  # request is one prompt, its parent is told once across a restart of the inbox, and the
  # first answer is the only one.
  test "a delegate's permission request: listed, cued, its parent told once, answered once",
       ctx do
    sid = started(ctx, "d1")
    input = %{"command" => "git push"}
    fields = %{"tool_use_id" => "t1", "tool_name" => "Bash", "tool_input" => input}
    holder = held(ctx, "PermissionRequest", sid, fields)
    [id] = cued(ctx)

    assert {:ok, [p]} = Prompts.read(ctx.prompts)

    assert %{id: ^id, kind: "permission", status: "open", agent: "d1", parent: "main"} = p
    assert %{text: "Bash git push", options: ["allow", "deny"], subagent: nil} = p
    assert is_integer(p.opened_at) and p.deadline > p.opened_at

    # The filters: by agent, by subtree, by kind.
    assert {:ok, [^p]} = Prompts.read(ctx.prompts, subtree: "main")
    assert {:ok, [^p]} = Prompts.read(ctx.prompts, agent: "d1", kind: "permission")
    assert {:ok, []} = Prompts.read(ctx.prompts, subtree: "alpha")
    assert {:ok, []} = Prompts.read(ctx.prompts, kind: "ask")
    assert {:refused, {:bad, :filter}} = Prompts.read(ctx.prompts, kind: "other")

    # The parent is told once, from its delegate, under the prompt's id: again after a cue and
    # after the inbox's restart, nothing more.
    assert [%{from_agent: "d1", text: text}] = notices(ctx, "main")
    assert text == "waiting on permission: Bash git push (prompt #{id})"
    Prompts.cue(ctx.prompts, %{topic: "mailbox"})
    :ok = stop_supervised(Prompts)
    prompts = start_supervised!({Prompts, ctx.popts})
    assert {:ok, [%{id: ^id}]} = Prompts.read(prompts)
    assert [_one] = notices(ctx, "main")

    # A choice it does not offer, or no answerer, hands nothing on.
    assert {:refused, {:bad, :choice}} = Prompts.answer(prompts, id, "maybe", "sam")
    assert {:refused, {:bad, :who}} = Prompts.answer(prompts, id, "allow", "")
    assert {:refused, :no_prompt} = Prompts.answer(prompts, "permission:999", "allow", "sam")

    assert {:ok, :sent} = Prompts.answer(prompts, id, "allow", "sam")
    assert {:decision, decision} = Task.await(holder)

    assert %{"hookSpecificOutput" => %{"decision" => %{"behavior" => "allow"}}} =
             JSON.decode!(decision)

    assert [%{actor: "sam", hold: "answered"}] =
             Intake.Table.rows_by_id(Intake.Table.open(Path.join(ctx.dir, "caf.db")) |> elem(1), [
               int(id)
             ])

    # A second answer, and a late one, are refused: the first settled it.
    assert {:refused, :settled} = Prompts.answer(prompts, id, "deny", "sam")
    assert {:ok, []} = Prompts.read(prompts)
  end

  defp int("permission:" <> n), do: String.to_integer(n)

  # Prompt.tla's cap prompt: the Stop hold at Claude Code's cap waits on a person, whose "go on"
  # is the last block it honors; the second answer is refused.
  test "a Stop held at the cap is a stop_cap prompt, answered once", ctx do
    sid = started(ctx, "d1")
    holder = held(ctx, "Stop", sid, %{"stop_hook_active" => false})
    [id] = cued(ctx)

    assert {:ok, [%{kind: "stop_cap", id: ^id, agent: "d1", options: ["go_on", "end"]}]} =
             Prompts.read(ctx.prompts)

    assert {:ok, :sent} = Prompts.answer(ctx.prompts, id, "go_on", "sam")
    assert {:decision, block} = Task.await(holder)
    assert %{"decision" => "block", "reason" => "Go on."} = JSON.decode!(block)
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, id, "end", "sam")
  end

  # Prompt.tla's AnswerNow and WithdrawNow: an ask is answered or withdrawn, once.
  test "an ask is answered once, or withdrawn once", ctx do
    q = %{
      "header" => "Base",
      "question" => "Rebase or merge?",
      "multiSelect" => false,
      "options" => [
        %{"label" => "Rebase", "description" => "a straight history"},
        %{"label" => "Merge", "description" => "keeps the merge"}
      ]
    }

    {:ok, {:asked, one}} = Mailbox.ask(ctx.mailbox, "d1", [q])
    assert cued(ctx) == ["ask:#{one}"]
    {:ok, {:asked, two}} = Mailbox.ask(ctx.mailbox, "d1", [q])
    assert cued(ctx) == ["ask:#{two}"]

    assert {:ok, [a, _]} = Prompts.read(ctx.prompts, kind: "ask")
    assert %{id: "ask:" <> _, agent: "d1", text: "Base: Rebase or merge?", options: [^q]} = a

    answer = [%{"labels" => ["Rebase"], "text" => ""}]
    assert {:ok, {:queued, _}} = Prompts.answer(ctx.prompts, "ask:#{one}", answer, "sam")
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, "ask:#{one}", answer, "sam")

    withdraw = {:withdraw, "Dismissed."}
    assert {:ok, {:queued, _}} = Prompts.answer(ctx.prompts, "ask:#{two}", withdraw, "sam")
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, "ask:#{two}", answer, "sam")
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, "ask:#{two}", withdraw, "sam")
    assert {:ok, []} = Prompts.read(ctx.prompts)
  end

  # Dialog.tla's answer through the inbox: the dialog the pane shows is a prompt with its
  # options, pressed once.
  test "a startup dialog is a prompt, answered once by its label", ctx do
    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), dialogs: [:trust])
    launch = SessionsSetup.launch(ctx, :at_start) |> Keyword.put(:claude, claude)

    assert {:unknown, {:dialog, :trust}} =
             Sessions.start(ctx.sessions, "alpha", ctx.account, launch)

    Prompts.cue(ctx.prompts, %{topic: "sessions:test"})
    assert_receive {:prompts, %{topic: "prompts", ids: ["dialog:alpha:" <> _ = id]}}

    assert {:ok, [%{id: ^id, kind: "dialog", agent: "alpha", parent: nil} = p]} =
             Prompts.read(ctx.prompts)

    assert %{text: "trust dialog", options: ["No, exit", @trust], deadline: nil} = p
    # No delegate asked: no one is told.
    assert notices(ctx, "main") == []

    assert {:refused, {:bad, :choice}} = Prompts.answer(ctx.prompts, id, "Yes", "sam")
    assert {:ok, :sent} = Prompts.answer_startup(ctx.prompts, "alpha", "trust", @trust, "sam")
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, id, @trust, "sam")

    assert {:refused, :settled} =
             Prompts.answer_startup(ctx.prompts, "alpha", "trust", @trust, "sam")

    assert {:refused, :no_prompt} =
             Prompts.answer_startup(ctx.prompts, "nobody", "trust", @trust, "sam")
  end
end
