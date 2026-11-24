defmodule CodingAgentFramework.Real.ReloadTest do
  # F-233's reload against the real Claude Code (F-239): its result line (`  ⎿  Reloaded…`) and
  # its 10 s bound are modeled, not captured (F-233's new-1). Each reload's screen, answer and
  # time go to the records folder whatever it answers, so the real line can be fixed from them.
  use CodingAgentFramework.RealCase, async: false

  @model "haiku"

  test "an idle main session's plugins reload twice, each answered ok" do
    ctx = start_tree!("real2")

    start_main!(
      ctx,
      "You are the main session of a framework test. Reply in one line: ready.",
      @model,
      ~r/ready/i
    )

    for n <- [1, 2] do
      step("reload #{n}", fn ->
        await_state!(ctx, ctx.main, "idle", 60_000)
        {ms, answer} = :timer.tc(fn -> op(ctx, :reload_plugins, [ctx.main]) end, :millisecond)
        note = "answer: #{inspect(answer)}\nms: #{ms}"
        path = record_screen!(ctx, ctx.main, "reload-#{n}", note)

        assert match?({:ok, %{done: :reloaded}}, answer),
               "#{inspect(answer)} after #{ms} ms; the pane is in #{path} (and .ansi)"
      end)
    end

    end_main!(ctx)
  end
end
