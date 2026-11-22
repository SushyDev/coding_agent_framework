defmodule CodingAgentFramework.InterventionsTest do
  @moduledoc """
  The reader of a person's interventions (F-194) on real `Acts`, `Sessions`, `Intake`, `Mailbox`
  and `Transcripts` files in this test's own directory: agent rows as `Sessions` keeps an
  interactive and a headless one, `Intake` rows as `UserPromptSubmit` posts leave them, a
  `Mailbox` row the framework handed, and a transcript written as Claude Code writes a turn a key
  ended. The clocks are the test's, so no test sleeps.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Acts, Interventions, Sessions, Transcripts}
  alias CodingAgentFramework.Intake.Table, as: IntakeTable
  alias CodingAgentFramework.Mailbox.Table, as: MailboxTable

  doctest Interventions

  # 2026-11-21T09:00:00Z.
  @t0 1_795_251_600_000

  setup do
    dir = test_dir()
    db = Path.join(dir, "caf.db")
    clock = start_supervised!({Agent, fn -> @t0 end})
    now = fn -> Agent.get(clock, & &1) end

    acts =
      start_supervised!({Acts, db: db, start_id: "s1", host: "test", instance: "t", clock: now})

    {:ok, table} = Sessions.Table.open(db)
    {:ok, agents} = Sessions.Agents.open(db, "test")

    for {name, role, sid} <- [{"app-epic", "parent", "s1"}, {"app-unit", "delegate", "s2"}] do
      row = %{host: "test", name: name, socket: name, account: "work", cwd: dir}
      id = Sessions.Table.starting(table, Map.merge(row, %{role: role, resume: nil}))
      Sessions.Table.update(table, id, status: "running", session_id: sid)
    end

    {:ok, intake} = IntakeTable.open(db)
    {:ok, mailbox} = MailboxTable.open(db)

    transcripts =
      start_supervised!({Transcripts, programs: programs(), accounts: ["work"], db: db})

    path = Path.join(dir, "s1.jsonl")
    File.write!(path, "")
    {:ok, _} = Transcripts.read(transcripts, [{"work", "s1", path}])

    opts = [
      agents: agents,
      transcripts: transcripts,
      intake_db: db,
      mailbox_db: db,
      acts: acts,
      host: "test",
      person: "sam",
      clock: now
    ]

    # Its read at start is queued before this call, so it has read nothing yet when the call
    # answers, and only a test's own check reads the rows the test writes after (F-203: the
    # start's read once ran after a test's rows and before its check).
    reader = start_supervised!({Interventions, opts})
    {:ok, %{recorded: []}} = Interventions.check(reader)

    %{
      acts: acts,
      intake: intake,
      mailbox: mailbox,
      transcripts: transcripts,
      path: path,
      clock: clock,
      opts: opts,
      reader: reader
    }
  end

  defp prompt(ctx, sid, key, text) do
    body = JSON.encode!(%{"hook_event_name" => "UserPromptSubmit", "prompt" => text})
    row = %{key: key, event: "UserPromptSubmit", session_id: sid, data: body, problem: nil}

    {:new, id} =
      IntakeTable.insert(ctx.intake, "test", "work", Map.put(row, :hold, nil), now(ctx))

    id
  end

  defp line(ctx, uuid, at, content) do
    stamp = DateTime.from_unix!(at, :millisecond) |> DateTime.to_iso8601()
    entry = %{"type" => "user", "uuid" => uuid, "timestamp" => stamp, "message" => content}
    File.write!(ctx.path, JSON.encode!(entry) <> "\n", [:append])
    {:ok, _} = Transcripts.read(ctx.transcripts, [{"work", "s1", ctx.path}])
  end

  defp interrupt(text), do: %{"content" => [%{"type" => "text", "text" => text}]}

  defp now(ctx), do: Agent.get(ctx.clock, & &1)
  defp at(ctx, ms), do: Agent.update(ctx.clock, fn _ -> ms end)

  test "a prompt with no mark of a row the framework handed is a person's typed input", ctx do
    MailboxTable.store(ctx.mailbox, %{
      from: "operator",
      to: "app-epic",
      text: "Review it.",
      uuid: "u-1",
      kind: "msg"
    })

    _framework = prompt(ctx, "s1", "p1", "Review it. [delivery u-1]")
    typed = prompt(ctx, "s1", "p2", "also look at the tests")
    # A headless delegate has no box a person types in.
    _headless = prompt(ctx, "s2", "p3", "never read")

    state = "typed:test:#{typed}"
    assert {:ok, %{recorded: [^state]}} = Interventions.check(ctx.reader)

    assert {:ok, [row]} = Acts.rows(ctx.acts, act: "typed")
    assert %{actor: "sam", target: "app-epic", status: "settled", outcome: "verified"} = row
    assert %{"intake" => ^typed, "session_id" => "s1", "chars" => 22} = JSON.decode!(row.detail)

    # A restart reads every row again and writes none twice.
    :ok = stop_supervised(Interventions)
    reader = start_supervised!({Interventions, ctx.opts})
    assert {:ok, %{recorded: []}} = Interventions.check(reader)
    assert {:ok, [_one]} = Acts.rows(ctx.acts, act: "typed")
  end

  test "a prompt of a session no agent row names waits, then is passed by", ctx do
    early = prompt(ctx, "s9", "p1", "whose?")
    later = prompt(ctx, "s1", "p2", "mine")
    assert {:ok, %{recorded: [_]}} = Interventions.check(ctx.reader)
    assert :sys.get_state(ctx.reader).past == early - 1

    at(ctx, @t0 + 60_000)
    assert {:ok, %{recorded: []}} = Interventions.check(ctx.reader)
    assert :sys.get_state(ctx.reader).past == later
  end

  test "an interrupt line on a turn the framework did not interrupt is a person's", ctx do
    line(ctx, "p-1", @t0, %{"content" => "go"})
    line(ctx, "i-1", @t0 + 5_000, interrupt("[Request interrupted by user]"))
    line(ctx, "p-2", @t0 + 10_000, %{"content" => "again"})

    # The framework's own interrupt of the next turn: a parent's fix, claimed before its Esc.
    at(ctx, @t0 + 12_000)
    {:ok, fix} = Acts.claim(ctx.acts, "app-main", "app-epic", "fix:1", :interrupt)
    {:ok, _} = Acts.settle(ctx.acts, fix, :verified)
    line(ctx, "i-2", @t0 + 13_000, interrupt("[Request interrupted by user for tool use]"))

    assert {:ok, %{recorded: ["interrupt:app-epic:i-1"]}} = Interventions.check(ctx.reader)
    assert {:ok, [row]} = Acts.rows(ctx.acts, act: "interrupt", actor: "sam")
    assert %{target: "app-epic", state: "interrupt:app-epic:i-1"} = row

    assert %{"uuid" => "i-1", "tool_use" => false, "at" => at, "turn_at" => @t0} =
             JSON.decode!(row.detail)

    assert at == @t0 + 5_000
    assert {:ok, %{recorded: []}} = Interventions.check(ctx.reader)
  end
end
