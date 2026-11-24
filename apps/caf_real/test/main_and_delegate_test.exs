defmodule CodingAgentFramework.Real.MainAndDelegateTest do
  # `docs/e2e.md` steps 1, 2, 3, 5 and 14 against the real Claude Code (F-223). One test, since
  # each step stands on the one before; each step has its own bound.
  use CodingAgentFramework.RealCase, async: false

  alias CodingAgentFramework.Mains
  alias CodingAgentFramework.Example.Run

  # The cheapest model that does each step: replies of one line, one tool call.
  @model "haiku"

  test "a main session starts, its headless delegate's Bash waits in the inbox, an ask is answered, and both end" do
    ctx = start_tree!("real1")

    # Step 1: the project is cloned from its origin, and the main session is declared, not run.
    await!(
      ctx,
      "the checkout",
      fn ->
        case Mains.checkout(Run.parts(ctx.run).mains, ctx.project) do
          {:ok, %{branch: "main"} = r} -> {:ok, r}
          other -> {:not_yet, other}
        end
      end,
      120_000
    )

    assert %{kind: "main", state: "gone"} = agent(ctx, ctx.main)

    # Step 2: the main session starts on the account with the most room, and its brief runs
    # as its first turn. The checkout may be trusted already by the setup's account; any
    # startup dialog that waits is answered from the inbox with its trusting label.
    brief = "You are the main session of a framework test. Reply in one line: ready."

    main = ctx.main
    # A checkout the account has not seen meets the trust dialog: the start answers unknown,
    # and the dialog waits in the inbox (step 2).
    assert op(ctx, :start_main, [ctx.project, main, brief, @model]) in [
             {:ok, %{main: main}},
             {:unknown, {:dialog, :trust}}
           ]

    answer_trust(ctx, ctx.main)
    await_state!(ctx, ctx.main, "idle", 180_000)
    await_screen!(ctx, ctx.main, ~r/ready/i, 60_000)

    # Step 3: a headless delegate's Bash waits in the inbox (F-221: the stdio prompt tool) and
    # the parent is told of it; allowed, it runs, the answer settles (F-221's echo), and the
    # report wakes the idle main session by the waiter.
    task = "Run this with your Bash tool: touch made-by-delegate.txt. Then report the word done."

    assert {:ok, %{delegate: name}} =
             op(ctx, :start_delegate, [ctx.main, ctx.project, "unit/real", @model, task])

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

    assert request.text =~ "touch made-by-delegate.txt"
    assert {:ok, _} = answer(ctx, request.id, "allow")
    assert {:refused, :settled} = answer(ctx, request.id, "allow")

    await!(
      ctx,
      "the answered request settles",
      fn -> if prompts(ctx, agent: name) == [], do: {:ok, :settled}, else: {:not_yet, nil} end,
      120_000,
      name
    )

    await_transcript!(ctx, ctx.main, "From #{name}", 240_000)
    await_state!(ctx, name, "idle", 120_000)

    # Step 5: an ask from the main session reaches the inbox; answered, it is delivered once.
    # The framework's own `ask` tool, named: Claude Code's `AskUserQuestion` shows on the screen
    # and reaches no inbox until B10 (F-223's new-5).
    ask =
      "Use the `ask` tool of the caf MCP server (not AskUserQuestion) to ask me one question: " <>
        "go on, yes or no. Then wait for my answer."

    assert {:ok, _} = op(ctx, :message, [ctx.main, ask])

    [question] =
      await!(
        ctx,
        "the main session's ask in the inbox",
        fn ->
          case prompts(ctx, kind: "ask") do
            [_] = one -> {:ok, one}
            other -> {:not_yet, other}
          end
        end,
        180_000
      )

    label = question |> labels() |> Enum.find(&(&1 =~ ~r/yes/i))
    assert {:ok, _} = answer(ctx, question.id, [%{"labels" => [label], "text" => ""}])
    assert {:refused, :settled} = answer(ctx, question.id, [%{"labels" => [label], "text" => ""}])
    await_state!(ctx, ctx.main, "idle", 180_000)

    # Step 14: the main session's end is refused while its delegate lives; after the stop, it
    # ends, and nothing of the tree holds a lease.
    assert {:refused, {:delegates, [^name]}} = op(ctx, :end_main, [ctx.main])
    assert {:ok, %{done: :stopped}} = op(ctx, :stop, [name])
    assert {:ok, _} = op(ctx, :end_main, [ctx.main])
    assert %{state: "ended"} = agent(ctx, ctx.main, true)
  end

  # An ask's options are its questions; the first question's own options carry the labels.
  defp labels(%{options: [%{"options" => options} | _]}), do: Enum.map(options, & &1["label"])
end
