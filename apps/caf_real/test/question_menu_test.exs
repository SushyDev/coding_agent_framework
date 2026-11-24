defmodule CodingAgentFramework.Real.QuestionMenuTest do
  # F-230's reading of Claude Code's own question (`AskUserQuestion`) against the real Claude
  # Code (F-239). Its fixture was drawn, not captured, so the dialog's screen goes to the
  # records folder as `<project>-ask-question.{txt,ansi}` whatever the inbox then shows: it
  # becomes F-230's real fixture.
  use CodingAgentFramework.RealCase, async: false

  alias CodingAgentFramework.TestHost

  @model "haiku"
  @question "Which fruit should the demo use?"
  @labels ["Apple", "Pear"]

  test "Claude Code's own question is a menu in the inbox, and the first label's press answers it" do
    ctx = start_tree!("real3")

    start_main!(
      ctx,
      "You are the main session of a framework test. Reply in one line: ready.",
      @model,
      ~r/ready/i
    )

    # The brief names the tool and the options exactly, and the word the next turn says, so
    # the reply is told from the tool's own result, which holds the label too.
    brief =
      "Call your AskUserQuestion tool (Claude Code's own, not the caf MCP server's ask) once, " <>
        "with one question: \"#{@question}\", header \"Fruit\", multiSelect false, and exactly " <>
        "two options, labeled Apple and Pear, with no descriptions. After the answer comes, " <>
        "reply in one line: the word chosen, a colon, then the label I picked."

    step("the question is asked", fn ->
      assert {:ok, _} = op(ctx, :message, [ctx.main, brief])
    end)

    screen =
      step("the dialog shows", fn ->
        # Should Claude Code hold the tool's call for a permission first, it is allowed from
        # the inbox; the failure's screen or the meta file then says it came.
        # The screen is recorded whether the footer F-230 reads comes or not, so a dialog drawn
        # otherwise is captured too.
        shown =
          TestHost.await(
            fn ->
              allow_all(ctx, ctx.main)

              if screen(ctx, ctx.main) =~ ~r/Enter to select/,
                do: {:ok, true},
                else: {:not_yet, nil}
            end,
            180_000
          )

        note = "the dialog as it first showed: #{inspect(shown)}"
        path = record_screen!(ctx, ctx.main, "ask-question", note)
        assert {:ok, true} = shown, "no dialog footer within 180000 ms; the pane is in #{path}"
        path
      end)

    menu =
      step("the inbox shows the menu", fn ->
        await!(
          ctx,
          "the question's menu in the inbox (the dialog's screen is in #{screen})",
          fn ->
            case prompts(ctx, agent: ctx.main, kind: "dialog") do
              [%{id: id} = m] ->
                if String.ends_with?(id, ":menu"), do: {:ok, m}, else: {:not_yet, m}

              other ->
                {:not_yet, other}
            end
          end,
          60_000
        )
      end)

    step("the menu reads the question and its labels", fn ->
      assert menu.text =~ @question
      assert menu.options == @labels ++ ["Chat about this", "esc"]
      refute "Type something." in menu.options
    end)

    step("the first label's press settles the menu", fn ->
      press!(ctx, ctx.main, menu.id, hd(@labels))
      assert {:refused, :settled} = answer(ctx, menu.id, hd(@labels))

      await!(
        ctx,
        "the menu settles",
        fn ->
          if prompts(ctx, agent: ctx.main) == [], do: {:ok, :settled}, else: {:not_yet, nil}
        end,
        60_000
      )
    end)

    step("the next turn names the label", fn ->
      await_transcript!(ctx, ctx.main, ~r/chosen\W{1,4}#{hd(@labels)}/i, 180_000)
      await_state!(ctx, ctx.main, "idle", 120_000)
    end)

    end_main!(ctx)
  end
end
