defmodule CodingAgentFramework.Real.AbsentMainTest do
  # `docs/e2e.md` step 13 against the real Claude Code (F-243): a main session whose process
  # ended (its row kept, `stopped` with reason `exited`) is resumed once by the operator's
  # `resume`, under the same session, reaches idle, takes one message, and ends.
  #
  # The healer (`AbsentMains`) would resume it by itself, so this test's tree has `absent_main`
  # off its allow-list: the absence is only asked, and the one resume is the operator's.
  use CodingAgentFramework.RealCase, async: false

  alias CodingAgentFramework.Acts
  alias CodingAgentFramework.Example.Run

  @model "haiku"

  test "an absent main session is resumed once by the operator, takes a message, and ends" do
    ctx =
      start_tree!("real13", fn c -> %{c | remedies: Map.delete(c.remedies, "absent_main")} end)

    main = ctx.main

    start_main!(
      ctx,
      "You are the main session of a framework test. Reply in one line: ready.",
      @model,
      ~r/ready/i
    )

    before = row(ctx, main)

    ps =
      step("13, the main session's process is ended by its pid", fn ->
        assert %{pid: pid, proc_start: start, session_id: id} = before
        assert is_integer(pid) and is_binary(start) and is_binary(id)
        {ps, 0} = System.cmd("ps", ["-o", "pid=,lstart=,args=", "-p", to_string(pid)])
        assert ps =~ "claude", "pid #{pid} is not Claude Code's: #{ps}"
        {_, 0} = System.cmd("kill", [to_string(pid)])
        ps
      end)

    step("13, the main session reads absent, its row kept", fn ->
      await!(
        ctx,
        "#{main}'s row stopped with reason exited",
        fn ->
          case row(ctx, main) do
            %{status: "stopped", reason: "exited"} = r -> {:ok, r}
            other -> {:not_yet, other && {other.status, other.reason}}
          end
        end,
        60_000
      )
    end)

    resumed =
      step("13, the operator's resume", fn ->
        assert {:ok, _} = answer = op(ctx, :resume, [main])
        answer_trust(ctx, main)
        await_state!(ctx, main, "idle", 180_000)
        after_resume = row(ctx, main)
        assert after_resume.session_id == before.session_id
        assert after_resume.pid != before.pid
        {answer, after_resume}
      end)

    step("13, the resumed session takes one message", fn ->
      assert {:ok, _} = op(ctx, :message, [main, "Reply with only the sum of 17 and 25."])
      await_screen!(ctx, main, ~r/\b42\b/, 180_000)
      await_state!(ctx, main, "idle", 120_000)
      assert transcript(ctx, main) =~ "ready", "the earlier turn is not in the session"
    end)

    step("13, one resume, the operator's", fn ->
      {:ok, acts} = Acts.rows(Run.parts(ctx.run).acts, act: "resume", target: main)
      {:ok, symptoms} = CodingAgentFramework.symptoms(ctx.config.instance, kind: "absent_main")
      {answer, after_resume} = resumed

      path =
        record(ctx, "absent-main", """
        row before: #{inspect(before, limit: :infinity)}
        ps before the kill: #{String.trim(ps)}
        resume: #{inspect(answer, limit: :infinity)}
        row after: #{inspect(after_resume, limit: :infinity)}
        acts: #{inspect(acts, limit: :infinity)}
        symptoms: #{inspect(symptoms, limit: :infinity)}
        prompts: #{inspect(prompts(ctx), limit: :infinity)}
        """)

      # One resume is two rows (`docs/design.md`, "An act"): the operator's claim, and the
      # resume `Sessions` makes for it, an act of its own, under the same start. The healer's
      # actor, `absent_mains:<host>`, has none.
      {mine, others} = Enum.split_with(acts, &(&1.actor == "operator"))
      assert [%{start_id: start, outcome: "verified"}] = mine, "operator acts: #{path}"
      assert [%{actor: "sessions:" <> _, start_id: ^start}] = others, "other acts: #{path}"
    end)

    end_main!(ctx)
  end
end
