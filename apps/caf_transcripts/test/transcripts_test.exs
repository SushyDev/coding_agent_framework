defmodule CodingAgentFramework.TranscriptsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CodingAgentFramework.{TestHost, Transcripts}
  alias CodingAgentFramework.Transcripts.{Fold, Table}

  doctest CodingAgentFramework.Transcripts
  doctest CodingAgentFramework.Transcripts.Fold
  doctest CodingAgentFramework.Transcripts.Table

  # Synthetic lines of each shape Claude Code 2.1.322 writes, and some it does not.
  defp line(map), do: JSON.encode!(map)

  defp prompt(id, text),
    do:
      line(%{
        type: "user",
        uuid: "u-#{id}",
        promptId: id,
        message: %{role: "user", content: text}
      })

  defp image_prompt(id),
    do:
      line(%{
        type: "user",
        promptId: id,
        message: %{
          content: [
            %{type: "image", source: %{type: "base64", data: "AA=="}},
            %{type: "text", text: "see"}
          ]
        }
      })

  defp assistant(msg, blocks, stop, tokens),
    do:
      line(%{
        type: "assistant",
        uuid: "a-#{msg}-#{length(blocks)}",
        message: %{
          id: msg,
          content: blocks,
          stop_reason: stop,
          usage: %{input_tokens: tokens, output_tokens: tokens}
        }
      })

  defp text(t), do: %{type: "text", text: t}

  defp agent_use(id),
    do: %{
      type: "tool_use",
      id: id,
      name: "Agent",
      input: %{subagent_type: "Explore", description: "look"}
    }

  defp agent_result(id, result),
    do:
      line(%{
        type: "user",
        message: %{content: [%{type: "tool_result", tool_use_id: id, content: "ok"}]},
        toolUseResult: result
      })

  defp notice(agent, tokens),
    do:
      line(%{
        type: "user",
        isMeta: true,
        message: %{
          content:
            "<task-notification>\n<task-id>#{agent}</task-id>\n<status>completed</status>\n" <>
              "<summary>done</summary>\n<usage><subagent_tokens>#{tokens}</subagent_tokens></usage>"
        }
      })

  defp good_line do
    one_of([
      map(string(:alphanumeric, max_length: 12), &prompt("p-#{&1}", &1)),
      constant(image_prompt("p-img")),
      constant(line(%{type: "user", isMeta: true, message: %{content: "meta"}})),
      map(
        integer(0..50),
        &assistant(
          "m#{rem(&1, 3)}",
          [text("r#{&1}")],
          Enum.at(["end_turn", "tool_use", nil], rem(&1, 3)),
          &1
        )
      ),
      map(integer(0..3), &assistant("m-agent-#{&1}", [agent_use("t#{&1}")], "tool_use", 1)),
      map(
        integer(0..3),
        &agent_result("t#{&1}", %{status: "completed", agentId: "g#{&1}", totalTokens: 10})
      ),
      map(integer(0..3), &agent_result("t#{&1}", %{status: "async_launched", agentId: "g#{&1}"})),
      map(integer(0..3), &notice("g#{&1}", 5)),
      constant(
        line(%{
          type: "attachment",
          attachment: %{
            type: "queued_command",
            prompt: "<task-notification>\n<task-id>g1</task-id>\n<status>failed</status>"
          }
        })
      ),
      constant(line(%{type: "system", subtype: "turn_duration"})),
      constant(line(%{type: "summary", summary: "s", leafUuid: "x"})),
      constant(line(%{type: "last-prompt", lastPrompt: "x"})),
      constant(line(%{type: "user", isSidechain: true, message: %{content: "side"}}))
    ])
  end

  defp bad_line do
    one_of([
      constant(line(%{type: "brand-new-type"})),
      constant(line(%{no_type: 1})),
      constant("[1,2]"),
      constant(~s({"type":"user","message":)),
      constant(line(%{type: "assistant", message: "not a map"})),
      map(binary(max_length: 20), &("#" <> String.replace(&1, "\n", "")))
    ])
  end

  defp transcript(min \\ 0),
    do:
      map(
        list_of(one_of([good_line(), bad_line()]), min_length: min, max_length: 30),
        &Enum.map_join(&1, "", fn l -> l <> "\n" end)
      )

  defp fold_all(bytes) do
    {:ok, fold} = Fold.take(Fold.new(), bytes)
    fold
  end

  # Reads `file` as it grows to each cut, from where the fold stopped, through a stored copy.
  defp fold_in_pieces(file, cuts) do
    Enum.reduce(Enum.sort(cuts) ++ [byte_size(file)], Fold.new(), fn cut, fold ->
      from = Fold.read_from(fold)
      {:ok, fold} = Fold.take(fold, binary_part(file, from, max(cut - from, 0)))
      Table.load_fold(:erlang.term_to_binary(fold))
    end)
  end

  describe "the fold" do
    property "is total, counts each bad line, and resumes at any cut" do
      check all(
              lines <-
                list_of(one_of([good_line(), map(bad_line(), &{:bad, &1})]), max_length: 30),
              file =
                Enum.map_join(lines, "", fn
                  {:bad, l} -> l <> "\n"
                  l -> l <> "\n"
                end),
              cuts <- list_of(integer(0..max(byte_size(file), 1)), max_length: 6)
            ) do
        whole = fold_all(file)
        assert whole.offset == byte_size(file)
        assert whole.problem_count == Enum.count(lines, &match?({:bad, _}, &1))
        assert fold_in_pieces(file, Enum.map(cuts, &min(&1, byte_size(file)))) == whole
      end
    end

    property "a partial last line waits for the next read" do
      check all(file <- transcript(), extra <- good_line(), cut <- integer(0..byte_size(extra))) do
        partial = fold_all(file <> binary_part(extra, 0, cut))
        assert partial.offset == byte_size(file)

        assert fold_in_pieces(file <> extra <> "\n", [byte_size(file) + cut]) ==
                 fold_all(file <> extra <> "\n")
      end
    end

    property "a file that shrank or was replaced is found and read again" do
      check all(
              a <- transcript(1),
              b <- transcript(),
              cut <- integer(0..(byte_size(a) - 1))
            ) do
        fold = fold_all(a)
        shrunk = binary_part(a, 0, cut)
        from = Fold.read_from(fold)
        bytes = if from <= cut, do: binary_part(shrunk, from, cut - from), else: ""
        assert Fold.take(fold, bytes) == :rewritten

        replaced = "#{line(%{type: "system"})}\n" <> b

        seam_now =
          if byte_size(replaced) >= fold.offset,
            do: binary_part(replaced, from, fold.offset - from)

        case Fold.take(
               fold,
               if(seam_now, do: binary_part(replaced, from, byte_size(replaced) - from), else: "")
             ) do
          :rewritten -> assert seam_now != fold.seam
          {:ok, _} -> assert seam_now == fold.seam
        end
      end
    end
  end

  describe "what the fold answers" do
    test "the last reply, prompts, subagents and usage" do
      file =
        Enum.map_join(
          [
            prompt("p1", "go"),
            image_prompt("p2"),
            assistant("m1", [agent_use("t1")], "tool_use", 5),
            assistant("m1", [agent_use("t2"), agent_use("t3")], "tool_use", 7),
            agent_result("t1", %{status: "completed", agentId: "g1", totalTokens: 40}),
            agent_result("t2", %{status: "async_launched", agentId: "g2"}),
            notice("g2", 25),
            line(%{type: "unknown-kind"}),
            "{not json",
            assistant("m2", [text("first")], nil, 3),
            assistant("m2", [text("the end")], "end_turn", 4)
          ],
          "",
          &(&1 <> "\n")
        )

      fold = fold_all(file)
      assert %{text: "first\n\nthe end", message_id: "m2"} = fold.last_reply
      assert fold.ends_with_reply

      assert [
               %{prompt_id: "p1", text: "go", images: 0},
               %{prompt_id: "p2", text: "see", images: 1}
             ] = fold.prompts

      # m1 counts once at 7, m2 once at 4.
      assert fold.usage["input_tokens"] == 11
      assert %{state: :ended, tokens: 40, agent_id: "g1"} = fold.subagents["t1"]
      assert %{state: :ended, tokens: 25, status: "completed"} = fold.subagents["t2"]
      assert %{state: :open, tokens: nil} = fold.subagents["t3"]

      assert [%{reason: {:unknown_type, ~s("unknown-kind")}}, %{reason: :not_json}] =
               fold.problems

      later = fold_all(file <> prompt("p3", "more") <> "\n")
      refute later.ends_with_reply
      assert later.last_reply == fold.last_reply
    end

    test "a marked prompt after an offset" do
      before = prompt("p1", "[r-1] report") <> "\n"
      bytes = prompt("p2", "[r-2] second report") <> "\n"
      assert Fold.contains?(before <> bytes, "[r-1]", "report")
      refute Fold.contains?(bytes, "[r-1]", "report")
      refute Fold.contains?(bytes <> prompt("p3", "[r-3] cut"), "[r-3]", "cut")
    end
  end

  describe "the process, through a real Shell" do
    setup do
      dir = TestHost.test_dir()
      me = self()

      opts = [
        programs: TestHost.programs(),
        accounts: ["a"],
        db: Path.join(dir, "t.db"),
        notify: &send(me, {:cue, &1})
      ]

      %{dir: dir, path: Path.join(dir, "s1.jsonl"), opts: opts}
    end

    test "reads a file written in pieces, resumes after a restart, and reads a shrunk file again",
         ctx do
      {:ok, t} = Transcripts.start_link(ctx.opts)
      assert Transcripts.rows(t, "a") == :unread
      assert {:ok, %{ids: [id], failed: []}} = Transcripts.read(t, [{"a", "s1", ctx.path}])
      assert {:ok, %{problem: "no_file", offset: 0}} = Transcripts.session(t, "a", "s1")

      first = prompt("p1", "[r-1] go") <> "\n"
      reply = assistant("m1", [text("done")], "end_turn", 2) <> "\n"
      File.write!(ctx.path, first <> binary_part(reply, 0, 10))
      assert {:ok, %{ids: [^id]}} = Transcripts.read(t)
      assert_received {:cue, %{topic: "transcripts:test:a", ids: [^id]}}
      assert {:ok, %{offset: offset, last_reply: nil}} = Transcripts.session(t, "a", "s1")
      assert offset == byte_size(first)

      File.write!(ctx.path, binary_part(reply, 10, byte_size(reply) - 10), [:append])
      assert {:ok, %{ids: [^id]}} = Transcripts.read(t)

      assert {:ok, %{last_reply: %{text: "done"}, problem: nil}} =
               Transcripts.session(t, "a", "s1")

      assert {:ok, true} = Transcripts.contains(t, "a", "s1", "[r-1]", "go", 0)
      assert {:ok, false} = Transcripts.contains(t, "a", "s1", "[r-1]", "go", offset)

      # A restarted reader resumes at its offset: bytes before the seam are never read again.
      GenServer.stop(t)
      {:ok, t} = Transcripts.start_link(ctx.opts)
      junk = String.duplicate("x", byte_size(first) - 1) <> "\n"
      File.write!(ctx.path, junk <> reply <> prompt("p2", "next") <> "\n")
      assert {:ok, %{ids: [^id]}} = Transcripts.read(t)

      assert {:ok, %{problem_count: 0, prompts: [%{prompt_id: "p1"}, %{prompt_id: "p2"}]}} =
               Transcripts.session(t, "a", "s1")

      File.write!(ctx.path, first)
      assert {:ok, %{ids: [^id]}} = Transcripts.read(t)

      assert {:ok, %{problem: "rewritten", rewrites: 1, prompts: [_], last_reply: nil}} =
               Transcripts.session(t, "a", "s1")
    end

    test "a text read from an offset takes at most the bound, and a read with none runs to the end",
         ctx do
      whole = Enum.map_join(1..3_000, &(prompt("p#{&1}", "go") <> "\n"))
      File.write!(ctx.path, whole)
      size = byte_size(whole)
      {:ok, t} = Transcripts.start_link(ctx.opts)
      {:ok, _} = Transcripts.read(t, [{"a", "s1", ctx.path}])
      assert {:ok, %{offset: ^size}} = Transcripts.session(t, "a", "s1")

      assert {:ok, %{bytes: bytes, from: 5}} = Transcripts.text(t, "a", "s1", 5, max: 100)
      assert bytes == binary_part(whole, 5, 100)

      assert {:ok, %{bytes: bytes, from: from}} =
               Transcripts.text(t, "a", "s1", size - 50, max: 500)

      assert {bytes, from} == {binary_part(whole, size - 50, 50), size - 50}

      assert {:ok, %{bytes: bytes, from: from}} =
               Transcripts.text(t, "a", "s1", {:last, 300}, max: 20)

      assert {bytes, from} == {binary_part(whole, size - 300, 20), size - 300}

      assert {:ok, %{bytes: bytes}} = Transcripts.text(t, "a", "s1", 10)
      assert byte_size(bytes) == size - 10
    end

    test "a failed shell leaves the session as it was", ctx do
      File.write!(ctx.path, prompt("p1", "go") <> "\n")
      {:ok, t} = Transcripts.start_link(ctx.opts)
      {:ok, _} = Transcripts.read(t, [{"a", "s1", ctx.path}])
      GenServer.stop(t)

      programs = TestHost.programs(TestHost.host(), %{tail: "/nonexistent/tail"})
      {:ok, t} = Transcripts.start_link(Keyword.put(ctx.opts, :programs, programs))
      File.write!(ctx.path, prompt("p2", "more") <> "\n", [:append])
      assert {:ok, %{ids: [], failed: [{"s1", {:sh, 127, _}}]}} = Transcripts.read(t)
      assert {:ok, %{prompts: [_]}} = Transcripts.session(t, "a", "s1")
      assert {:refused, :unknown_session} = Transcripts.contains(t, "a", "nope", "m", "t", 0)
    end

    test "one Transcripts over every account: a session id in two accounts is two rows, read on its interval",
         ctx do
      moved = Path.join(ctx.dir, "s1-b.jsonl")
      File.write!(ctx.path, prompt("p1", "go") <> "\n")
      File.write!(moved, prompt("p1", "go") <> "\n" <> prompt("p2", "on") <> "\n")
      {:ok, t} = Transcripts.start_link(Keyword.put(ctx.opts, :accounts, ["a", "b", "c"]))

      sessions = [{"a", "s1", ctx.path}, {"b", "s1", moved}]
      assert {:ok, %{ids: [one, two], failed: []}} = Transcripts.read(t, sessions)
      assert_received {:cue, %{topic: "transcripts:test:a", ids: [^one]}}
      assert_received {:cue, %{topic: "transcripts:test:b", ids: [^two]}}
      assert Transcripts.rows(t, "c") == :unread
      assert {:ok, %{prompts: [_]}} = Transcripts.session(t, "a", "s1")
      assert {:ok, %{prompts: [_, _]}} = Transcripts.session(t, "b", "s1")

      # Every known session, and a read row for every account, on the reader's own interval.
      GenServer.stop(t)
      opts = ctx.opts |> Keyword.put(:accounts, ["a", "b", "c"]) |> Keyword.put(:interval, 60_000)
      {:ok, _} = Transcripts.start_link(opts)
      assert_receive {:cue, %{topic: "transcripts:test:c", ids: []}}
    end
  end
end
