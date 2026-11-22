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

  alias CodingAgentFramework.{Accounts, Acts, Grants, Inlet, Intake, Logins, Mailbox, Prompts}
  alias CodingAgentFramework.{Delegates, ScreenStandIn, Sessions, Tmux, Transcripts, Usage}
  alias CodingAgentFramework.{SessionsSetup, Stream, Watch}

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

    watch = start_supervised!({Watch, db: db, remedies: Watch.default_remedies(), notify: cue})
    acts = start_supervised!({Acts, db: db, start_id: "s1", host: "test", instance: "t"})
    popts = [host: "test", intake: intake, intake_db: db, sessions: sessions, sessions_db: db]
    popts = popts ++ [mailbox: mailbox, watch: watch, watch_db: db, acts: acts, acts_db: db]
    popts = popts ++ [notify: &send(me, {:prompts, &1})]

    {:ok,
     intake: intake,
     acts: acts,
     watch: watch,
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
  defp started(ctx, name, brief \\ "Review it.") do
    {:ok, {:queued, _}} = Mailbox.brief(ctx.mailbox, "main", name, brief, Stream.uuid())

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

    # Its open is one row in `Acts` (F-202), the first read's, and a restart writes none again.
    key = "opened:test:#{id}"

    assert {:ok, [%{actor: "prompts:test", target: "d1", state: ^key, detail: detail}]} =
             Acts.rows(ctx.acts, act: "opened")

    assert %{"prompt" => ^id, "kind" => "permission", "agent" => "d1", "opened_at" => opened} =
             JSON.decode!(detail)

    assert opened == p.opened_at

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

    # F-194: the one answer that went through is one row, settled by the owner's answer, with
    # who answered, the prompt, its choice and when it opened; no refused one is a row.
    assert {:ok, [row]} = Acts.rows(ctx.acts, act: "answer")
    assert %{actor: "sam", target: "d1", status: "settled", outcome: "verified"} = row

    assert %{"prompt" => ^id, "kind" => "permission", "choice" => "allow", "opened_at" => opened} =
             JSON.decode!(row.detail)

    assert opened == p.opened_at and row.claimed_at >= opened
  end

  defp int("permission:" <> n), do: String.to_integer(n)

  # F-189's new-2: a headless delegate's `can_use_tool` request, held in its `Stream` fold, is
  # a permission prompt as an interactive one's hook is: listed, its parent told once, answered
  # once through `Stream`, whose fold lets one answer in.
  test "a headless delegate's stream request is a permission prompt, answered once", ctx do
    popts = ctx.popts ++ [stream: ctx.stream, stream_db: Path.join(ctx.dir, "caf.db")]
    :ok = stop_supervised(Prompts)
    prompts = start_supervised!({Prompts, popts})
    ctx = %{ctx | prompts: prompts}

    sid = started(ctx, "d1", "ask to run it")

    SessionsSetup.stream_until(
      ctx,
      sid,
      &Enum.any?(&1.requests, fn {_, r} -> r.state == :held end)
    )

    Prompts.cue(prompts, %{topic: "stream:test"})
    [id] = cued(ctx)
    assert "permission:stream:" <> ^sid <> ":" <> request = id

    assert {:ok, [p]} = Prompts.read(prompts, kind: "permission")
    assert %{id: ^id, status: "open", agent: "d1", parent: "main", deadline: nil} = p
    assert %{text: "Bash true", options: ["allow", "deny"]} = p
    assert is_integer(p.opened_at)

    assert [%{from_agent: "d1", text: "waiting on permission: Bash true" <> _}] =
             notices(ctx, "main")

    assert {:ok, %{uuid: ^request}} = Prompts.answer(prompts, id, {"deny", "Not now."}, "sam")
    assert {:refused, :settled} = Prompts.answer(prompts, id, "allow", "sam")
    SessionsSetup.stream_until(ctx, sid, &(&1.requests[request].state == :answered))
    assert {:ok, []} = Prompts.read(prompts, kind: "permission")
    assert {:refused, :settled} = Prompts.answer(prompts, id, "allow", "sam")
  end

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

  # Heal.tla's Ask and Answer (F-182): a symptom the healer left to a person is a remedy prompt,
  # answered once; its approve puts the kind's remedy back on the allow-list.
  test "a remedy prompt is the Watch's asked symptom, answered once", ctx do
    started(ctx, "d1")
    sym = %{kind: "lost_viewer", target: "d1", state: "k1", source: "healer", since: 1}
    {:ok, %{id: sid}} = Watch.record(ctx.watch, sym)
    {:ok, false} = Watch.remedies(ctx.watch, {:drop, "lost_viewer", :not_viewed})
    {:ok, ^sid} = Watch.ask(ctx.watch, sym, :not_on_list)
    id = "remedy:#{sid}"
    assert cued(ctx) == [id]

    assert {:ok, [%{id: ^id, agent: "d1", parent: "main", options: ["approve", "leave"]} = p]} =
             Prompts.read(ctx.prompts, kind: "remedy")

    assert p.text == "lost_viewer of d1: not_on_list; its remedy: reopen"
    # The Watch's prompt about a delegate is not the delegate's own wait: no notice.
    assert notices(ctx, "main") == []

    assert {:refused, {:bad, :choice}} = Prompts.answer(ctx.prompts, id, "act", "sam")
    assert {:ok, :answered} = Prompts.answer(ctx.prompts, id, "approve", "sam")
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, id, "leave", "sam")
    assert {:ok, %{"lost_viewer" => %{allowed: true}}} = Watch.remedies(ctx.watch, :list)
    assert {:refused, :no_prompt} = Prompts.answer(ctx.prompts, "remedy:999", "leave", "sam")

    # Asked for its bound (F-189's new-7): the act once, or leave; approve widens nothing there.
    capped = %{sym | state: "k2"}
    {:ok, %{id: cid}} = Watch.record(ctx.watch, capped)
    {:ok, ^cid} = Watch.ask(ctx.watch, capped, {:cap, 10, 3_600_000})
    id = "remedy:#{cid}"
    # The read that opens it may also be the first's close.
    assert id in cued(ctx)

    assert {:ok, [%{id: ^id, options: ["act", "leave"]}]} =
             Prompts.read(ctx.prompts, kind: "remedy")

    assert {:refused, {:bad, :choice}} = Prompts.answer(ctx.prompts, id, "approve", "sam")
    assert {:ok, :answered} = Prompts.answer(ctx.prompts, id, "act", "sam")
    assert {:ok, [%{answer: "act", answered_by: "sam"}]} = Watch.read(ctx.watch, state: "k2")

    # F-196: answered `act`, it shows `answering` while the act is the healer's to take and while
    # it runs, and leaves once the act's row has ended; its outcome is that row, a fault here.
    assert {:ok, [%{id: ^id, status: "answering", text: text}]} =
             Prompts.read(ctx.prompts, kind: "remedy")

    assert text == "lost_viewer of d1: sam answered act; its healer takes it next"
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, id, "leave", "sam")
    # Another act of the target, or another person's, is not this one.
    {:ok, _} = Acts.claim(ctx.acts, "sam", "d1", "k1", :reopen, detail: %{symptom: "k1"})
    {:ok, act} = Acts.claim(ctx.acts, "sam", "d1", "k2", :reopen, detail: %{symptom: "k2"})

    assert {:ok, [%{id: ^id, status: "answering", text: text}]} =
             Prompts.read(ctx.prompts, kind: "remedy")

    assert text =~ "its reopen is claimed"
    {:ok, :failed} = Acts.settle(ctx.acts, act, :failed, reason: :no_pane)
    assert {:ok, []} = Prompts.read(ctx.prompts, kind: "remedy")
    assert {:ok, [%{id: ^act, outcome: "failed"}]} = Acts.faults(ctx.acts)

    # F-203: a state that passes before its act leaves with it, passed before its act; one whose
    # act is under way stays until that act ends.
    acts =
      for state <- ["k3", "k4"] do
        {:ok, %{id: n}} = Watch.record(ctx.watch, %{sym | state: state})
        {:ok, ^n} = Watch.ask(ctx.watch, %{sym | state: state}, {:cap, 10, 3_600_000})
        {:ok, :answered} = Prompts.answer(ctx.prompts, "remedy:#{n}", "act", "sam")
        "remedy:#{n}"
      end

    {:ok, k4} = Acts.claim(ctx.acts, "sam", "d1", "k4", :reopen, detail: %{symptom: "k4"})
    assert {:ok, [_, _]} = Prompts.read(ctx.prompts, kind: "remedy")

    {:ok, [_, _, _]} =
      Watch.pass(ctx.watch, {"healer", "lost_viewer"}, %{targets: [], states: []})

    assert {:ok, [%{id: id}]} = Prompts.read(ctx.prompts, kind: "remedy")
    assert id == List.last(acts)
    {:ok, :recovered} = Acts.settle(ctx.acts, k4, :recovered)
    assert {:ok, []} = Prompts.read(ctx.prompts, kind: "remedy")
  end

  # Limit.tla's StartRefusedAtLimit and AnswerLeave (F-196): a start that every usable account
  # refuses at a limit is its owner's row, a limit prompt with the row's deadline, its parent's,
  # answered once through `Delegates`.
  test "a start waiting at a usage limit is a limit prompt, its owner's row, answered once",
       ctx do
    db = Path.join(ctx.dir, "caf.db")
    {:ok, accounts} = Accounts.new(Path.join(ctx.dir, "home"), ["work"])
    usage = start_supervised!({Usage, accounts: accounts, host: "test", db: db})
    resets = div(System.os_time(:millisecond), 1000) + 3_600
    limit = %{"status" => "rejected", "resetsAt" => resets, "rateLimitType" => "five_hour"}
    fact = %{at: System.os_time(:millisecond), evidence: %{"source" => "test"}, limit: limit}
    {:ok, _} = Usage.take(usage, "work", fact)
    transcripts = {Transcripts, programs: programs(), accounts: ["work"], db: db}
    project = %{name: "app", repo: ctx.dir, trunk: "main", setup: [], setup_timeout: 1_000}
    project = Map.merge(project, %{env: %{}, branches: ~r/\Aunit\//, cap: 1})

    dopts = [host: "test", db: db, sessions_db: db, sessions: ctx.sessions, stream: ctx.stream]
    dopts = dopts ++ [usage: usage, accounts: accounts, mailbox: ctx.mailbox, launch: []]
    dopts = dopts ++ [transcripts: start_supervised!(transcripts), projects: %{"app" => project}]
    delegates = start_supervised!({Delegates, dopts})
    popts = ctx.popts ++ [delegates: delegates, delegates_db: db]
    prompts = start_supervised!(Supervisor.child_spec({Prompts, popts}, id: :starts))

    assert {:ok, %{id: row, waiting: until}} =
             Delegates.start_delegate(delegates, "main", "app", "unit/one", "opus", "Go.")

    id = "limit:start:delegate:#{row}"
    assert {:ok, [p]} = Prompts.read(prompts, kind: "limit")
    assert %{id: ^id, agent: "app-unit-one", parent: "main", project: "app", status: "open"} = p
    assert p.options == ["wait", "leave"] and p.deadline == until + 120_000
    assert p.text =~ "delegate app-unit-one waits to start until a usage limit's reset"
    # It has no agent row yet: its parent places it in the subtree.
    assert {:ok, [%{id: ^id}]} = Prompts.read(prompts, subtree: "main")

    assert {:refused, {:bad, :choice}} = Prompts.answer(prompts, id, "go_on", "sam")
    assert {:ok, :left} = Prompts.answer(prompts, id, "leave", "sam")
    assert {:refused, :settled} = Prompts.answer(prompts, id, "wait", "sam")
    assert {:ok, []} = Prompts.read(prompts, kind: "limit")

    assert {:ok, [%{act: "answer", target: "app-unit-one", outcome: "verified"}]} =
             Acts.rows(ctx.acts, actor: "sam")
  end

  # F-181: an account whose login a check refused is a login prompt, with no agent, until a
  # check finds it logged in; its answer `check` is that check. F-205: its id names the refusal
  # (`login:<account>:<the refused check's time>`), so the same account refused again after a
  # login is a new prompt with a new id, and the old id stays settled.
  test "a refused login is a login prompt until a check finds it logged in; refused again, a new one",
       ctx do
    me = self()
    db = Path.join(ctx.dir, "caf.db")
    {:ok, accounts} = Accounts.new(Path.join(ctx.dir, "home"), ["work"])
    out = ~s({"loggedIn": false, "authMethod": "none"})
    logged_in = {:ok, %{status: 0, output: ~s({"loggedIn": true})}}

    said =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> {:ok, %{status: 1, output: out}} end}, id: :said)
      )

    # Each check reads the clock once: every refusal has a time of its own.
    ticks = start_supervised!(Supervisor.child_spec({Agent, fn -> 1_000 end}, id: :ticks))

    logins =
      start_supervised!(
        {Logins,
         accounts: accounts,
         host: "test",
         db: db,
         run: fn _ -> Agent.get(said, & &1) end,
         clock: fn -> Agent.get_and_update(ticks, &{&1, &1 + 1_000}) end,
         notify: &send(me, {:cue, &1})}
      )

    :ok = stop_supervised(Prompts)
    prompts = start_supervised!({Prompts, ctx.popts ++ [logins: logins, logins_db: db]})
    ctx = %{ctx | prompts: prompts}
    assert Logins.check(logins, "work") == {:refused, {:login, :logged_out}}
    assert cued(ctx) == ["login:work:1000"]

    assert {:ok, [%{id: "login:work:1000", kind: "login", agent: nil, options: ["check"]} = p]} =
             Prompts.read(prompts, kind: "login")

    assert p.text =~ "account work is not logged in (logged_out)"
    assert p.opened_at == 1_000

    # Still logged out: the check answers so, and the prompt stays, with the same id: a refusal
    # that is kept is the same prompt.
    assert {:refused, {:login, :logged_out}} =
             Prompts.answer(prompts, "login:work:1000", "check", "sam")

    assert {:ok, [%{id: "login:work:1000"}]} = Prompts.read(prompts, kind: "login")

    assert {:refused, {:bad, :choice}} =
             Prompts.answer(prompts, "login:work:1000", "go", "sam")

    # The id before the time is no prompt: the id is the refusal's.
    assert {:refused, :no_prompt} = Prompts.answer(prompts, "login:work", "check", "sam")

    Agent.update(said, fn _ -> logged_in end)
    assert {:ok, :logged_in} = Prompts.answer(prompts, "login:work:1000", "check", "sam")
    assert cued(ctx) == ["login:work:1000"]
    assert {:ok, []} = Prompts.read(prompts, kind: "login")
    assert {:refused, :settled} = Prompts.answer(prompts, "login:work:1000", "check", "sam")

    # Refused again: a new prompt, a new id, its own time. The first id stays settled, though
    # the account's row is refused again.
    Agent.update(said, fn _ -> {:ok, %{status: 1, output: out}} end)
    assert {:refused, {:login, :logged_out}} = Logins.recheck(logins, "work")
    [again] = cued(ctx)
    assert again =~ ~r/\Alogin:work:\d+\z/
    refute again == "login:work:1000"

    assert {:ok, [%{id: ^again, kind: "login", opened_at: opened}]} =
             Prompts.read(prompts, kind: "login")

    assert opened > 1_000 and again == "login:work:#{opened}"
    assert {:refused, :settled} = Prompts.answer(prompts, "login:work:1000", "check", "sam")

    Agent.update(said, fn _ -> logged_in end)
    assert {:ok, :logged_in} = Prompts.answer(prompts, again, "check", "sam")
    assert cued(ctx) == [again]
    assert {:ok, []} = Prompts.read(prompts, kind: "login")

    # Each open stays a row (F-202), its target the prompt's id, which names its refusal (F-205):
    # the second refusal of one account is an open of its own.
    assert {:ok, rows} = Acts.rows(ctx.acts, act: "opened")
    assert Enum.sort(Enum.map(rows, & &1.target)) == Enum.sort(["login:work:1000", again])
    first = Enum.find(rows, &(&1.target == "login:work:1000"))

    assert %{"kind" => "login", "agent" => nil, "opened_at" => 1_000} =
             JSON.decode!(first.detail)

    assert p.opened_at == 1_000
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

    # F-179's new-4: who answered an ask, and who withdrew one, is its row in `Acts`.
    assert {:ok, [answered, withdrawn]} = Acts.rows(ctx.acts, act: "answer")
    assert %{actor: "sam", target: "d1", outcome: "verified"} = answered

    assert %{"kind" => "ask", "choice" => [%{"labels" => ["Rebase"]}]} =
             JSON.decode!(answered.detail)

    assert %{"choice" => ["withdraw", "Dismissed."]} = JSON.decode!(withdrawn.detail)
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

  # F-198, Menu.tla: a numbered menu no rule names, on a running main session's screen, is a
  # dialog prompt with its options and esc, no default and no deadline, pressed once by a
  # person's label with the marker read back, and gone once the screen no longer shows it.
  test "a menu on a running screen is a dialog prompt, answered once by its label", ctx do
    [yes, not_now, _] = ScreenStandIn.menu()
    id = menu_prompt(ctx)

    assert {:ok, [%{id: ^id, kind: "dialog", status: "open", agent: "alpha"} = p]} =
             Prompts.read(ctx.prompts)

    assert %{options: [^yes, ^not_now, "Don't show again", "esc"], deadline: nil} = p
    assert p.text =~ "Teach auto mode about your environment? Auto mode works better"

    assert {:refused, {:bad, :choice}} = Prompts.answer(ctx.prompts, id, "Maybe", "sam")
    assert {:ok, :sent} = Prompts.answer(ctx.prompts, id, not_now, "sam")
    assert ScreenStandIn.menu_answer(ctx.dir) == not_now
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, id, yes, "sam")
    assert {:ok, []} = prompts_until(ctx, &(&1 == []))
  end

  test "a menu answered esc is Escape, and one answered at the viewer leaves the inbox", ctx do
    id = menu_prompt(ctx)
    assert {:ok, :sent} = Prompts.answer(ctx.prompts, id, "esc", "sam")
    assert ScreenStandIn.menu_answer(ctx.dir) == "esc"
    assert {:ok, []} = prompts_until(ctx, &(&1 == []))

    # A second session, whose menu a person answers at its viewer first.
    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), menu: true)
    launch = SessionsSetup.launch(ctx, :at_start) |> Keyword.put(:claude, claude)
    assert {:ok, _} = Sessions.start(ctx.sessions, "main", ctx.account, launch)
    {:ok, [%{id: "dialog:main:" <> _ = other}]} = prompts_until(ctx, &(&1 != []))
    {:ok, panes} = Tmux.list_panes(ctx.server)
    pane = Enum.find_value(panes, &(&1.tag == "main" && &1.pane))
    assert {:ok, :sent} = Tmux.write(ctx.server, pane, "main", {:keys, ["Enter"]})
    assert {:ok, []} = prompts_until(ctx, &(&1 == []))
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, other, "Yes", "sam")
  end

  # F-206: a start that shows two menus no rule names one after the other is two prompts, each
  # keyed by its read; the first's id is settled once the second shows, and the start goes on.
  test "each menu of one start is its own prompt, answered in turn", ctx do
    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), dialogs: [:menu, :menu2])
    launch = SessionsSetup.launch(ctx, :at_start) |> Keyword.put(:claude, claude)

    assert {:unknown, {:dialog, :start_menu}} =
             Sessions.start(ctx.sessions, "alpha", ctx.account, launch)

    {:ok, [%{id: first, status: "open"}]} = prompts_until(ctx, &(&1 != []))
    assert first =~ ~r/^dialog:alpha:\d+:start_menu$/
    assert {:ok, :sent} = Prompts.answer(ctx.prompts, first, "Not now", "sam")

    {:ok, [%{id: second, status: "open", text: text}]} =
      prompts_until(ctx, &match?([%{id: id}] when id != first, &1))

    assert second =~ ~r/^dialog:alpha:\d+:start_menu$/
    assert text =~ Enum.at(ScreenStandIn.menu_titles(), 1)
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, first, "Yes", "sam")
    assert {:ok, :sent} = Prompts.answer(ctx.prompts, second, "Yes", "sam")
    assert ScreenStandIn.menu_answers(ctx.dir) == ["Not now", "Yes"]
    assert {:ok, []} = prompts_until(ctx, &(&1 == []))
  end

  # A main session started on the menu screen: its prompt's id once a read of its pane found it.
  defp menu_prompt(ctx) do
    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), menu: true)
    launch = SessionsSetup.launch(ctx, :at_start) |> Keyword.put(:claude, claude)
    assert {:ok, _} = Sessions.start(ctx.sessions, "alpha", ctx.account, launch)
    {:ok, [%{id: "dialog:alpha:" <> _ = id}]} = prompts_until(ctx, &(&1 != []))
    assert String.ends_with?(id, ":menu")
    id
  end

  # The inbox read at each owner's cue, as `Cues` hands them on, until `done?` holds.
  defp prompts_until(ctx, done?) do
    await(fn ->
      flush_cues()
      Prompts.cue(ctx.prompts, %{topic: "sessions:test"})

      case Prompts.read(ctx.prompts) do
        {:ok, ps} -> if done?.(ps), do: {:ok, ps}, else: ps
        other -> other
      end
    end)
  end

  # F-186: the usage limit's two prompts are the agent row's step, answered once through
  # `Sessions`, its one writer.
  test "a usage limit's limit and usage_credits prompts, each answered once", ctx do
    {:ok, table} = Sessions.Table.open(Path.join(ctx.dir, "caf.db"))
    row = %{host: "test", name: "alpha", socket: "alpha", account: "work", cwd: ctx.dir}
    id = Sessions.Table.starting(table, Map.merge(row, %{role: "parent", resume: nil}))
    Sessions.Table.update(table, id, status: "running")

    stop = "Stop and wait for limit to reset"
    credits = %{"until" => 9, "step" => "credits", "deadline" => 77, "window" => "seven_day"}
    credits = Map.put(credits, "options", [stop, "Wait here", "Use usage credits"])
    assert {:ok, _} = Sessions.put_limit(ctx.sessions, "alpha", credits)
    Prompts.cue(ctx.prompts, %{topic: "sessions:test"})

    assert {:ok, [%{id: "usage_credits:alpha:9" = cid, deadline: 77, options: options}]} =
             Prompts.read(ctx.prompts, kind: "usage_credits")

    assert options == [stop, "Use usage credits"]
    assert {:refused, {:bad, :choice}} = Prompts.answer(ctx.prompts, cid, "Wait here", "sam")
    assert {:ok, _} = Prompts.answer(ctx.prompts, cid, stop, "sam")
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, cid, stop, "sam")

    asked = %{"until" => 9, "step" => "prompt", "why" => "a press whose outcome is unknown"}
    assert {:ok, _} = Sessions.put_limit(ctx.sessions, "alpha", asked)

    assert {:ok, [%{id: lid, kind: "limit", deadline: nil, options: ~w(go_on leave)}]} =
             Prompts.read(ctx.prompts, agent: "alpha", kind: "limit")

    assert {:ok, _} = Prompts.answer(ctx.prompts, lid, "leave", "sam")
    assert {:refused, :settled} = Prompts.answer(ctx.prompts, lid, "go_on", "sam")
    assert {:ok, []} = Prompts.read(ctx.prompts, kind: "limit")
  end
end
