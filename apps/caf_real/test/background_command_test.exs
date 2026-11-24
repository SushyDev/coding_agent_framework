defmodule CodingAgentFramework.Real.BackgroundCommandTest do
  # `docs/e2e.md` step 12 against the real Claude Code (F-243): a headless delegate runs one
  # background command, its report goes while the command runs, the command's end wakes it in
  # a turn of Claude Code's own, and that turn's result reaches the main session as a notice
  # naming the command's output. The wake gap (the command's end to that turn's init, as the
  # event log's lines are first read) is checked against `Stream`'s `wake:` and recorded.
  use CodingAgentFramework.RealCase, async: false

  alias CodingAgentFramework.{Stream, TestHost}

  @model "haiku"
  # The command's output, `bg 42`, is not in its text, so a report that names it read it.
  @command "sleep 30; echo bg $((6*7))"
  @output "bg 42"
  # `Stream`'s `wake:` (its default; the test's config sets none), the design's bound on the
  # gap between a background command's end and the init of the turn it begins (F-204).
  @wake 30_000

  test "a headless delegate's background command ends in a turn of its own, told once as a notice" do
    ctx = start_tree!("real12")

    start_main!(
      ctx,
      "You are the main session of a framework test. Reply in one line: ready.",
      @model,
      ~r/ready/i
    )

    name = ctx.project <> "-unit-bg"

    task =
      "Use the Bash tool with run_in_background set to true to run exactly this command and " <>
        "nothing else: #{@command}. Do not wait for it. Then report the words started in " <>
        "background in one line. When it finishes, reply in one line with its output."

    step("12, the delegate starts", fn ->
      assert {:ok, %{delegate: ^name}} =
               op(ctx, :start_delegate, [ctx.main, ctx.project, "unit/bg", @model, task])
    end)

    # The event log has no times of its own: its lines are stamped as they are first read.
    log =
      step("12, the delegate's event log", fn ->
        id =
          await!(
            ctx,
            "#{name}'s session id",
            fn ->
              case row(ctx, name) do
                %{session_id: id} when is_binary(id) -> {:ok, id}
                other -> {:not_yet, other}
              end
            end,
            120_000,
            name
          )

        follow(Path.join(Stream.dir(ctx.home, id), "events.jsonl"))
      end)

    step("12, the Bash request is allowed from the inbox, and the parent told of it", fn ->
      [request] =
        await!(
          ctx,
          "#{name}'s Bash request in the inbox",
          fn ->
            case prompts(ctx, agent: name, kind: "permission") do
              [_] = one -> {:ok, one}
              other -> {:not_yet, other}
            end
          end,
          180_000,
          name
        )

      at = DateTime.utc_now()
      {ms, answer} = :timer.tc(fn -> answer(ctx, request.id, "allow") end, :millisecond)

      told =
        TestHost.await(
          fn ->
            case Enum.filter(delivered(ctx, name, "prompt"), &(&1.text =~ request.id)) do
              [] -> {:not_yet, nil}
              some -> {:ok, some}
            end
          end,
          60_000
        )

      path =
        record(ctx, "permission", """
        request: #{inspect(request, limit: :infinity)}
        answered: #{DateTime.to_iso8601(at)}
        answer: #{inspect(answer, limit: :infinity)}
        ms: #{ms}
        told the parent: #{inspect(told, limit: :infinity)}
        """)

      assert request.text =~ "sleep 30", "the request: #{path}"
      assert {:ok, _} = answer, "the answer: #{path}"
      assert {:ok, [_]} = told, "the parent's prompt notices: #{path}"
    end)

    step("12, the report reaches the main session while the command runs", fn ->
      await!(
        ctx,
        "#{name}'s report in #{ctx.main}'s transcript",
        fn ->
          case delivered(ctx, name, "report") do
            [] -> {:not_yet, nil}
            reports -> {:ok, reports}
          end
        end,
        240_000
      )

      refute Enum.any?(lines(log), &event?(&1, "system", "task_notification")),
             "the command had ended before the report was read"
    end)

    step("12, the command's end wakes the delegate, and its turn is told as a notice", fn ->
      await!(
        ctx,
        "the notice of #{name}'s own turn naming #{@output}",
        fn ->
          case Enum.filter(notices(ctx, name), &(&1.text =~ @output)) do
            [] -> {:not_yet, deliveries(ctx, ctx.main)}
            some -> {:ok, some}
          end
        end,
        240_000
      )

      await_state!(ctx, name, "idle", 120_000)
    end)

    step("12, the event log holds one init and one result per turn, and the gap", fn ->
      events = for {ms, l} <- lines(log), e = decode(l), do: {ms, e}
      kinds = Enum.map(events, fn {_, e} -> {e["type"], e["subtype"]} end)
      ended = Enum.find(events, fn {_, e} -> event?(e, "system", "task_notification") end)

      woke =
        ended &&
          Enum.find(events, fn {ms, e} -> ms >= elem(ended, 0) and event?(e, "system", "init") end)

      gap = woke && elem(woke, 0) - elem(ended, 0)

      path =
        record(ctx, "background", """
        command: #{@command}
        events (ms, type, subtype):
        #{Enum.map_join(events, "\n", fn {ms, e} -> "#{ms} #{e["type"]} #{e["subtype"]}" end)}
        wake gap: #{inspect(gap)} ms (bound #{@wake} ms; read about every 100 ms)
        exec </dev/null in the log: #{Enum.any?(events, fn {_, e} -> JSON.encode!(e) =~ "exec </dev/null; " end)}
        """)

      assert Enum.count(kinds, &(&1 == {"system", "init"})) == 2, "inits: #{path}"
      assert Enum.count(kinds, &match?({"result", _}, &1)) == 2, "results: #{path}"
      assert is_integer(gap), "no init after the command's end: #{path}"
      assert gap < @wake, "the wake gap #{gap} ms is past #{@wake} ms: #{path}"

      assert Enum.any?(events, fn {_, e} -> JSON.encode!(e) =~ "exec </dev/null; " end),
             "the command ran without its stdin at end of file: #{path}"

      # One report and one notice: no second report.
      told = deliveries(ctx, ctx.main)
      assert [_] = delivered(ctx, name, "report"), "reports: #{inspect(told)}"
      assert [_] = notices(ctx, name), "notices: #{inspect(told)}"
    end)

    step("14, the delegate stops", fn ->
      assert {:ok, %{done: :stopped}} = op(ctx, :stop, [name])
    end)

    end_main!(ctx)
  end

  # What `name` itself delivered to the main session, of `kind`.
  defp delivered(ctx, name, kind),
    do: for(%{from: ^name, kind: ^kind} = d <- deliveries(ctx, ctx.main), do: d)

  # A delegate's own turn after its report is told by the framework, as a notice naming it.
  defp notices(ctx, name) do
    for %{from: "framework", kind: "notice", text: text} = d <- deliveries(ctx, ctx.main),
        String.starts_with?(text, "Delegate #{name}, in a turn of its own after its report:"),
        do: d
  end

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, %{} = e} -> e
      _ -> nil
    end
  end

  defp event?({_ms, line}, type, subtype) when is_binary(line),
    do: event?(decode(line), type, subtype)

  defp event?(%{"type" => type, "subtype" => subtype}, type, subtype), do: true
  defp event?(_, _, _), do: false
end
