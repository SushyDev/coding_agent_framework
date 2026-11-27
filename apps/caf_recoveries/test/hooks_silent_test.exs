defmodule CodingAgentFramework.HooksSilentTest do
  @moduledoc """
  The `hooks_silent` detector on real `Watch`, `Sessions`, `Intake` and `Transcripts` files in
  this test's own directory: an agent row as `Sessions` keeps a running one, its transcript
  written as Claude Code writes tool calls, and `Intake` rows as its hooks' posts leave them.
  The clock is the test's, so no test sleeps.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{HooksSilent, Sessions, Transcripts, Watch}
  alias CodingAgentFramework.Intake.Table, as: IntakeTable

  doctest HooksSilent

  # 2026-11-21T09:00:00Z, the first tool call's time.
  @t0 1_795_251_600_000
  @bound 60_000

  setup do
    dir = test_dir()
    db = Path.join(dir, "caf.db")
    clock = start_supervised!({Agent, fn -> @t0 end})
    remedies = %{"hooks_silent" => %{remedy: nil, cap: 0}}
    {:ok, watch} = Watch.start_link(db: Path.join(dir, "w.db"), remedies: remedies)

    {:ok, table} = Sessions.Table.open(db)
    {:ok, agents} = Sessions.Agents.open(db, "test")
    row = %{host: "test", name: "app-epic", socket: "app-epic", account: "work", cwd: dir}
    id = Sessions.Table.starting(table, Map.merge(row, %{role: "parent", resume: nil}))
    Sessions.Table.update(table, id, status: "running", session_id: "s1")

    {:ok, intake} = IntakeTable.open(db)
    IntakeTable.start(intake, "test", @t0 - 10_000)

    transcripts =
      start_supervised!({Transcripts, programs: programs(), accounts: ["work"], db: db})

    path = Path.join(dir, "s1.jsonl")
    File.write!(path, "")
    {:ok, _} = Transcripts.read(transcripts, [{"work", "s1", path}])

    detector =
      start_supervised!(
        {HooksSilent,
         agents: agents,
         transcripts: transcripts,
         intake_db: db,
         watch: watch,
         host: "test",
         bound: @bound,
         clock: fn -> Agent.get(clock, & &1) end}
      )

    %{
      watch: watch,
      intake: intake,
      transcripts: transcripts,
      path: path,
      clock: clock,
      detector: detector
    }
  end

  defp call(ctx, id, at) do
    stamp = DateTime.from_unix!(at, :millisecond) |> DateTime.to_iso8601()
    content = [%{"type" => "tool_use", "id" => id, "name" => "Bash", "input" => %{}}]
    entry = %{"type" => "assistant", "timestamp" => stamp, "message" => %{"content" => content}}
    File.write!(ctx.path, JSON.encode!(entry) <> "\n", [:append])
    {:ok, _} = Transcripts.read(ctx.transcripts, [{"work", "s1", ctx.path}])
  end

  defp hook(ctx, key, at) do
    row = %{key: key, event: "PreToolUse", session_id: "s1", data: "{}", problem: nil, hold: nil}
    {:new, _} = IntakeTable.insert(ctx.intake, "test", "work", row, at)
  end

  defp tick(ctx, ms), do: Agent.update(ctx.clock, &(&1 + ms))

  test "a tool call with no hook row past the bound is shown, never asked, and passes", ctx do
    call(ctx, "tu-1", @t0)
    assert {:ok, %{silent: []}} = HooksSilent.check(ctx.detector)

    tick(ctx, @bound)
    state = "hooks_silent:app-epic:tu-1"
    assert {:ok, %{silent: [^state]}} = HooksSilent.check(ctx.detector)

    assert {:ok, [%{status: "open", target: "app-epic", since: @t0, evidence: evidence}]} =
             Watch.read(ctx.watch, kind: "hooks_silent")

    assert JSON.decode!(evidence) == %{
             "tool" => "Bash",
             "tool_use_id" => "tu-1",
             "newest_hook" => nil
           }

    # A symptom only: no remedy, so it is never asked.
    assert {:refused, {:no_remedy, "hooks_silent"}} =
             Watch.ask(ctx.watch, %{kind: "hooks_silent", target: "app-epic", state: state}, :x)

    # The hooks speak again: its next call has its row, and the state passes.
    hook(ctx, "k2", @t0 + @bound + 1)
    call(ctx, "tu-2", @t0 + @bound + 1)
    tick(ctx, @bound)
    assert {:ok, %{silent: []}} = HooksSilent.check(ctx.detector)
    assert {:ok, [%{status: "passed"}]} = Watch.read(ctx.watch, state: state)
  end

  test "a call whose hook row came is not silent; one within the bound waits", ctx do
    hook(ctx, "k1", @t0 + 20)
    call(ctx, "tu-1", @t0)
    tick(ctx, @bound)
    assert {:ok, %{silent: []}} = HooksSilent.check(ctx.detector)

    call(ctx, "tu-2", @t0 + @bound)
    tick(ctx, @bound - 1)
    assert {:ok, %{silent: []}} = HooksSilent.check(ctx.detector)
    assert {:ok, []} = Watch.read(ctx.watch, kind: "hooks_silent")
  end

  test "a transcript is read again only once its reader read past it (F-299)", ctx do
    call(ctx, "tu-1", @t0)
    # Read once at this offset, after the detector's own first check.
    assert {:ok, %{silent: []}} = HooksSilent.check(ctx.detector)
    # Each tail read is a `{:text, …}` call into `Transcripts`, which runs a shell there.
    :erlang.trace_pattern(
      {Transcripts, :handle_call, 3},
      [{[{:text, :_, :_, :_}, :_, :_], [], []}],
      [:local]
    )

    :erlang.trace(ctx.transcripts, true, [:call])
    for _ <- 1..5, do: HooksSilent.check(ctx.detector)
    tick(ctx, @bound)
    state = "hooks_silent:app-epic:tu-1"
    assert {:ok, %{silent: [^state]}} = HooksSilent.check(ctx.detector)

    call(ctx, "tu-2", @t0 + @bound)
    tick(ctx, @bound)
    assert {:ok, %{silent: ["hooks_silent:app-epic:tu-2"]}} = HooksSilent.check(ctx.detector)
    :erlang.trace(ctx.transcripts, false, [:call])
    ref = :erlang.trace_delivered(ctx.transcripts)
    assert_receive {:trace_delivered, _, ^ref}

    # Seven checks, one read: at the offset the reader moved to with tu-2.
    reads = Stream.repeatedly(fn -> receive_text(ctx.transcripts) end) |> Enum.take_while(& &1)
    assert length(reads) == 1
  end

  defp receive_text(pid) do
    receive do
      {:trace, ^pid, :call, {Transcripts, :handle_call, [{:text, _, _, _}, _, _]}} -> true
    after
      0 -> nil
    end
  end
end
