defmodule CodingAgentFramework.Real.InteractiveDelegateTest do
  # `docs/e2e.md` step 4 against the real Claude Code (F-239): an interactive delegate, its
  # trust dialog and its permission requests answered from the inbox, its report delivered to
  # the main session, then step 14: the delegate stopped and the main session ended.
  use CodingAgentFramework.RealCase, async: false

  @model "haiku"

  test "an interactive delegate's prompts are answered from the inbox, and its report reaches the main session" do
    ctx = start_tree!("real4")

    start_main!(
      ctx,
      "You are the main session of a framework test. Reply in one line: ready.",
      @model,
      ~r/ready/i
    )

    task =
      "Write NOTES.md with three lines about this repository, commit it on your branch, " <>
        "and report the commit's hash in one line."

    name = ctx.project <> "-unit-notes"

    step("4, the interactive delegate starts", fn ->
      # Its new worktree may meet the trust dialog, so the start may answer before it is up.
      args = [ctx.main, ctx.project, "unit/notes", @model, task, [interactive: true]]

      case op(ctx, :start_delegate, args) do
        {:ok, %{delegate: ^name}} -> :ok
        {:unknown, {:dialog, :trust}} -> :ok
        other -> flunk("the start answered #{inspect(other)}")
      end
    end)

    trust =
      step("4, the delegate's trust dialog is in the inbox with its parent", fn ->
        case await_some(
               fn -> prompts(ctx, subtree: ctx.main, agent: name, kind: "dialog") end,
               60_000
             ) do
          [%{id: id, parent: parent, options: options}] ->
            assert parent == ctx.main
            press!(ctx, name, id, Enum.find(options, &(&1 =~ ~r/trust/i)))
            [id]

          [] ->
            []
        end
      end)

    # Every permission request the delegate makes on the way is answered from the inbox; the
    # ids are kept, since the main session must be told of each once.
    allowed =
      step(
        "4, the delegate's requests are answered and its report reaches the main session",
        fn ->
          await!(
            ctx,
            "#{name}'s report in #{ctx.main}'s transcript",
            fn ->
              ids = allow_all(ctx, name)
              send(self(), {:allowed, ids})

              if reports(ctx, name) != [], do: {:ok, true}, else: {:not_yet, nil}
            end,
            600_000,
            name
          )

          collect_allowed([])
        end
      )

    step("4, the report is the reply to the brief, a commit's hash", fn ->
      await_state!(ctx, name, "idle", 120_000)
      assert [report] = reports(ctx, name)
      assert report =~ hash(), "the report: #{inspect(report)}"
    end)

    # F-269: the pinned release ends a turn's lines with its own turn-end line after the reply,
    # which ends an interactive report's turn whatever runs in the background.
    step("4, the report's turn ends with Claude Code's turn-end line", fn ->
      lines = String.split(transcript(ctx, name), "\n", trim: true)
      last_reply = Enum.find_index(Enum.reverse(lines), &(&1 =~ ~s("stop_reason":"end_turn")))
      assert last_reply, "no end_turn reply in #{name}'s transcript"
      after_reply = Enum.take(lines, -last_reply)
      assert Enum.any?(after_reply, &(&1 =~ ~s("subtype":"turn_duration"))), inspect(after_reply)
    end)

    step("4, the main session was told once of each prompt", fn ->
      for id <- trust ++ allowed do
        assert told(ctx, id) == 1, "#{ctx.main} was told of #{id} #{told(ctx, id)} times"
      end
    end)

    # docs/e2e.md has a person type this turn on the delegate's screen; a message is typed into
    # the same box. Its reply is the delegate's own, and the report stays the brief's.
    step("4, a turn after the report is not the report", fn ->
      assert {:ok, _} = op(ctx, :message, [name, "Reply in one line with the word hello."])

      await!(
        ctx,
        "#{name} replies hello",
        fn ->
          if replies(ctx, name) =~ ~r/hello/i, do: {:ok, true}, else: {:not_yet, nil}
        end,
        180_000,
        name
      )

      await_state!(ctx, name, "idle", 120_000)
      assert [report] = reports(ctx, name)
      assert report =~ hash()
    end)

    step("14, the delegate stops and the main session ends", fn ->
      assert {:refused, {:delegates, [^name]}} = op(ctx, :end_main, [ctx.main])
      assert {:ok, %{done: :stopped}} = op(ctx, :stop, [name])
    end)

    end_main!(ctx)
  end

  defp collect_allowed(acc) do
    receive do
      {:allowed, ids} -> collect_allowed(acc ++ ids)
    after
      0 -> Enum.uniq(acc)
    end
  end

  # A delivered row's label (`Mailbox.frame/1`): `From <name> on <account> (report):`.
  defp report_line(name), do: ~r/From #{Regex.escape(name)} on [^(\n]* \(report\):/

  # A commit's hash in a report: hex standing alone, so no part of a delivery mark's uuid
  # (hex groups joined by hyphens) is read as one.
  defp hash, do: ~r/(?<![-\w])[0-9a-f]{7,40}(?![-\w])/

  # The main session's transcript lines that are not Claude Code's own replies, which may quote
  # a notice: the lines delivered to it.
  defp delivered(ctx) do
    transcript(ctx, ctx.main)
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 =~ ~s("type":"assistant")))
  end

  # The text of each of `name`'s reports delivered to the main session: up to 400 bytes after
  # its label. Claude Code may write one delivered text on more than one line of its
  # transcript, so a text is counted once.
  defp reports(ctx, name) do
    for(
      line <- delivered(ctx),
      [_, text] <- [Regex.split(report_line(name), line, parts: 2)],
      do: binary_part(text, 0, min(400, byte_size(text)))
    )
    |> Enum.uniq()
  end

  # Agent `name`'s own replies, its transcript's assistant lines joined.
  defp replies(ctx, name) do
    transcript(ctx, name)
    |> String.split("\n", trim: true)
    |> Enum.filter(&(&1 =~ ~s("type":"assistant")))
    |> Enum.join("\n")
  end

  # How many delivered lines told the main session of prompt `id`.
  defp told(ctx, id), do: Enum.count(delivered(ctx), &String.contains?(&1, "(prompt #{id})"))
end
