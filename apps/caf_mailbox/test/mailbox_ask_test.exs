defmodule CodingAgentFramework.MailboxAskTest do
  @moduledoc """
  An agent's ask and the person's answer (`Team.tla`'s `Ask`, `Answers`), over a real
  `Sessions` and `Stream` and the headless stand-in for Claude Code, as `MailboxTest`'s are.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Grants, HeadlessStandIn, Mailbox, Sessions, SessionsSetup, Stream}
  alias CodingAgentFramework.Mailbox.{Ask, Table}

  doctest Ask

  setup {SessionsSetup, :sessions}

  setup ctx do
    tree = [
      %{name: "main", project: "app", parent: nil},
      %{name: "d1", project: "app", parent: "main"}
    ]

    grants = Grants.new(fn -> tree end, operator: "operator")
    db = Path.join(ctx.dir, "caf.db")
    mopts = [db: db, grants: grants, stream: ctx.stream, sessions_db: db, host: "test"]
    {:ok, mtable} = Table.open(db)
    mailbox = start_supervised!({Mailbox, mopts})
    {:ok, mopts: mopts, mtable: mtable, mailbox: mailbox, tree: tree}
  end

  defp question(header, multi \\ false) do
    %{
      "header" => header,
      "question" => "Which way?",
      "multiSelect" => multi,
      "options" => [
        %{"label" => "Rebase", "description" => "a straight history"},
        %{"label" => "Merge", "description" => "keeps the merge commit"},
        %{"label" => "Wait", "description" => "ask again later"}
      ]
    }
  end

  test "an ask is checked, stored for the app at once, and never delivered", ctx do
    m = ctx.mailbox
    one = question("Base")
    assert {:refused, {:bad, :questions}} = Mailbox.ask(m, "d1", [])
    assert {:refused, {:bad, :questions}} = Mailbox.ask(m, "d1", List.duplicate(one, 5))
    two_same = %{one | "options" => [hd(one["options"]), hd(one["options"])]}
    assert {:refused, {:bad, :questions}} = Mailbox.ask(m, "d1", [two_same])
    assert {:refused, {:bad, :questions}} = Mailbox.ask(m, "d1", [%{one | "header" => ""}])
    assert {:refused, {:unknown_agent, "nobody"}} = Mailbox.ask(m, "nobody", [one])
    assert {:refused, {:not_an_agent, "operator"}} = Mailbox.ask(m, "operator", [one])
    assert Table.open_rows(ctx.mtable) == []

    # No operator, no one to ask.
    db = Path.join(ctx.dir, "other.db")
    opts = [db: db, sessions_db: db, grants: Grants.new(fn -> ctx.tree end)]
    other = start_supervised!({Mailbox, Keyword.merge(ctx.mopts, opts)}, id: :other)
    assert {:refused, :no_operator} = Mailbox.ask(other, "d1", [one])

    # Atom keys, as the app's own code may build one, are stored as JSON's.
    atoms = %{header: "Tests", question: "Run all?", options: [], multiSelect: true}
    opts = for l <- ~w(Yes No), do: %{label: l, description: l}

    assert {:ok, {:asked, id}} =
             Mailbox.ask(m, "main", [question("Base"), %{atoms | options: opts}])

    assert {:ok, {:asked, other_id}} = Mailbox.ask(m, "d1", [one])

    assert {:ok, [%{id: ^id, from: "main", answer: nil} = asked, %{id: ^other_id}]} =
             Mailbox.open_asks(m)

    assert [
             _,
             %{"header" => "Tests", "multiSelect" => true, "options" => [%{"label" => "Yes"} | _]}
           ] =
             asked.questions

    # The ask goes to no agent: it is kept for the operator from its store, as a reply to the
    # operator is, and no settle reads it again (F-138's new-1).
    cue(ctx)

    assert %{to_agent: "operator", kind: "ask", status: "kept", attempt: nil} =
             Table.get(ctx.mtable, id)

    assert Table.open_rows(ctx.mtable) == []

    assert {:refused, :no_ask} = Mailbox.asked(m, 999)
  end

  # AnswerToAsker, AnswerOnce, and an idle delegate woken by the answer, one line a question.
  test "the answer goes to the agent that asked, once, as a row it takes", ctx do
    {sid, brief} = started(ctx, "d1")
    until_taken(ctx, ["message #{brief}"])

    {:ok, {:asked, id}} = Mailbox.ask(ctx.mailbox, "d1", [question("Base"), question("Do", true)])

    for bad <- [
          [%{"labels" => ["Rebase"]}],
          [%{"labels" => ["Nope"]}, %{"labels" => ["Merge"]}],
          [%{"labels" => ["Rebase", "Merge"]}, %{"labels" => ["Merge"]}],
          [%{"labels" => ["Rebase"]}, %{"labels" => [], "text" => "  "}]
        ] do
      assert {:refused, {:bad, :answers}} = Mailbox.answer(ctx.mailbox, id, bad)
    end

    answers = [
      %{"labels" => ["Rebase"], "text" => ""},
      %{"labels" => ["Merge", "Wait"], "text" => "after the\nrelease"}
    ]

    assert {:ok, {:queued, a}} = Mailbox.answer(ctx.mailbox, id, answers)
    assert {:refused, :answered} = Mailbox.answer(ctx.mailbox, id, answers)
    assert {:refused, :no_ask} = Mailbox.answer(ctx.mailbox, a, answers)

    assert {:ok, %{uuid: u, from_agent: "operator", to_agent: "d1", text: text}} =
             until(ctx, a, &(&1.status == "delivered"))

    assert text ==
             "Ask #{id}, Base: Rebase\n" <>
               "Ask #{id}, Do: Merge, Wait; the person wrote: after the release"

    until_taken(ctx, ["message #{brief}", "message #{u}"])
    # The labels as the app gave them are kept beside the agent's text (F-138's new-3).
    assert {:ok, %{answer: %{id: ^a, status: "delivered", answers: ^answers}}} =
             Mailbox.asked(ctx.mailbox, id)

    assert {:ok, []} = Mailbox.open_asks(ctx.mailbox)
    assert {:ok, _} = Stream.end_session(ctx.stream, sid)
  end

  # F-138's new-1: the reply to the operator's message is kept for it from its store, out of
  # the open rows, and the app reads it by the message's id (`reply/2`).
  test "a reply to the operator is kept, and read by its message's id", ctx do
    {_sid, brief} = started(ctx, "d1")
    until_taken(ctx, ["message #{brief}"])
    assert {:refused, :no_message} = Mailbox.reply(ctx.mailbox, 999)
    assert {:ok, {:queued, id}} = Mailbox.message(ctx.mailbox, "operator", "d1", "why?")
    assert {:refused, :no_answer} = Mailbox.reply(ctx.mailbox, id)
    assert {:ok, %{uuid: u}} = until(ctx, id, &(&1.status == "delivered"))

    assert {:ok, %{from: "d1", to: "operator", kind: "reply", status: "kept", text: text}} =
             await(fn -> cue(ctx) && Mailbox.reply(ctx.mailbox, id) end, 10_000)

    # The reply's own text, as its row keeps it (F-146's new-4).
    assert %{text: ^text} = Table.answer(ctx.mtable, u)
    assert text != ""
    refute Enum.any?(Table.open_rows(ctx.mtable), &(&1.reply_to == u))
  end

  # An ask whose agent ended: answered and kept, settled ended, never delivered.
  test "an answer to an agent that ended is stored and settled ended", ctx do
    {sid, brief} = started(ctx, "d1")
    until_taken(ctx, ["message #{brief}"])
    {:ok, {:asked, id}} = Mailbox.ask(ctx.mailbox, "d1", [question("Base")])
    {:ok, _} = Stream.end_session(ctx.stream, sid)
    {:ok, _} = await(fn -> if fold(ctx, sid).gone, do: {:ok, 1} end)

    assert {:ok, {:queued, a}} =
             Mailbox.answer(ctx.mailbox, id, [%{"labels" => ["Wait"], "text" => ""}])

    {:ok, _} = until(ctx, a, &(&1.status == "ended"))
    assert {:ok, %{answer: %{status: "ended"}}} = Mailbox.asked(ctx.mailbox, id)
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{brief}", "end"]
  end

  defp started(ctx, name) do
    brief = Stream.uuid()
    {:ok, {:queued, _}} = Mailbox.brief(ctx.mailbox, "main", name, "Review it.", brief)

    # As Delegates does (F-152): the brief is marked by stream for the start, which writes it
    # right after its hold, and the start's answer is told.
    deadline = System.os_time(:millisecond) + 60_000
    {:ok, first} = Mailbox.launch(ctx.mailbox, name, deadline, via: :stream)

    launch =
      Keyword.put(
        SessionsSetup.headless(ctx, :on_message),
        :first,
        Map.take(first, [:uuid, :text])
      )

    answer = Sessions.start(ctx.sessions, name, ctx.account, launch)
    {:ok, _} = Mailbox.launched(ctx.mailbox, first.id, answer)
    {:ok, %{session_id: sid}} = answer
    {sid, brief}
  end

  defp until_taken(ctx, taken) do
    idle? = fn ->
      {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
      Enum.all?(rows, & &1.idle)
    end

    {:ok, _} =
      await(
        fn -> cue(ctx) && HeadlessStandIn.taken(ctx.dir) == taken && idle?.() && {:ok, 1} end,
        10_000
      )
  end

  defp cue(ctx) do
    {:ok, _} = Stream.read(ctx.stream)
    Mailbox.cue(ctx.mailbox, %{topic: "stream:test", ids: []})
    Mailbox.status(ctx.mailbox, 0)
  end

  defp until(ctx, id, ready?) do
    check = fn row -> if ready?.(row), do: {:ok, row}, else: row end
    await(fn -> cue(ctx) && check.(Table.get(ctx.mtable, id)) end, 10_000)
  end

  defp fold(ctx, sid) do
    cue(ctx)
    {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
    Enum.find(rows, &(&1.session == sid))
  end
end
