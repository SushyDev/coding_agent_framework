defmodule CodingAgentFramework.Real.OwnBracketsTest do
  # F-287: the framework brackets a paste's text itself (`Tmux.bracketed/1`) and pastes it with
  # no `-p`, so tmux adds no second pair. Here the real Claude Code takes a 3-line paste made
  # that way into its idle main session's pane, then the Enter, as one user line that holds
  # every line: no newline submitted early, and no marker left in the text.
  use CodingAgentFramework.RealCase, async: false

  alias CodingAgentFramework.{TestHost, Tmux}

  @model "haiku"

  test "a 3-line paste in the framework's own brackets is one user line" do
    ctx = start_tree!("real-brackets")

    start_main!(
      ctx,
      "You are the main session of a framework test. Reply in one line: ready.",
      @model,
      ~r/ready/i
    )

    mark = "f287-#{System.unique_integer([:positive])}"
    text = "Reply in one line: pasted.\nsecond line #{mark}\nthird line #{mark}"

    step("the paste and its Enter", fn ->
      {:ok, server} =
        Tmux.CLI.new(TestHost.programs(), {:socket, Path.join(ctx.home, "tmux.sock")})

      {:ok, panes} = Tmux.list_panes(server)
      %{pane: pane, tag: tag} = Enum.find(panes, &(&1.session == ctx.main))
      assert {:ok, :sent} = Tmux.write(server, pane, tag, {:paste, "caf-#{mark}", text})
      assert {:ok, :sent} = Tmux.write(server, pane, tag, {:keys, ["Enter"]})
    end)

    step("one user line holds the whole text", fn ->
      [line] =
        await!(
          ctx,
          "a user line with #{mark}",
          fn ->
            case user_lines(ctx, mark) do
              [] -> {:not_yet, nil}
              lines -> {:ok, lines}
            end
          end,
          120_000,
          ctx.main
        )

      assert line =~ text
      refute line =~ "\e"
      await_state!(ctx, ctx.main, "idle", 120_000)
      assert [^line] = user_lines(ctx, mark)
    end)

    end_main!(ctx)
  end

  # The text of each user line in the main session's transcript that names `mark`.
  defp user_lines(ctx, mark) do
    for json <- String.split(transcript(ctx, ctx.main), "\n", trim: true),
        %{"type" => "user", "message" => %{"content" => content}} <- [JSON.decode!(json)],
        text = content_text(content),
        text =~ mark,
        do: text
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content),
    do: Enum.map_join(content, &if(is_map(&1), do: &1["text"] || "", else: ""))
end
