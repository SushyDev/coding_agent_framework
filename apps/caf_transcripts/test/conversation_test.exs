defmodule CodingAgentFramework.ConversationTest do
  # A session's conversation as `Transcripts.conversation/3` reads it (F-260): real files under
  # the test's directory, read through a real `Shell`, on the local host and through a stand-in
  # for ssh.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Host, Programs, Transcripts}

  setup do
    dir = test_dir()
    opts = [programs: programs(), accounts: ["a"], db: Path.join(dir, "t.db")]
    {:ok, t} = Transcripts.start_link(opts)
    %{dir: dir, t: t, opts: opts, path: Path.join(dir, "s1.jsonl")}
  end

  defp line(map), do: JSON.encode!(map) <> "\n"

  defp at(second), do: "2026-11-25T09:00:#{String.pad_leading("#{second}", 2, "0")}.000Z"

  defp prompt(uuid, text, second \\ 0),
    do: line(%{type: "user", uuid: uuid, timestamp: at(second), message: %{content: text}})

  defp reply(uuid, text, second \\ 1),
    do:
      line(%{
        type: "assistant",
        uuid: uuid,
        timestamp: at(second),
        message: %{
          id: "m-" <> uuid,
          stop_reason: "end_turn",
          content: [%{type: "text", text: text}]
        }
      })

  defp use(uuid, id, name, input, second),
    do:
      line(%{
        type: "assistant",
        uuid: uuid,
        timestamp: at(second),
        message: %{
          id: "m-" <> uuid,
          content: [%{type: "tool_use", id: id, name: name, input: input}]
        }
      })

  defp result(uuid, id, content, second, error \\ false),
    do:
      line(%{
        type: "user",
        uuid: uuid,
        timestamp: at(second),
        message: %{
          content: [%{type: "tool_result", tool_use_id: id, content: content, is_error: error}]
        }
      })

  # Every kind of entry, in one session.
  defp every_kind do
    prompt("u1", "Review it.\n\n[delivery 6f1c-row]", 0) <>
      line(%{type: "user", uuid: "x1", isMeta: true, message: %{content: "caveat"}}) <>
      use("a1", "tu-1", "Bash", %{command: "ls"}, 1) <>
      result("u2", "tu-1", [%{type: "text", text: "a.txt"}], 3) <>
      use("a2", "tu-2", "Read", %{file_path: "/nope"}, 4) <>
      result("u3", "tu-2", "no such file", 4, true) <>
      reply("a3", "Done.", 5) <>
      line(%{
        type: "user",
        uuid: "u4",
        isMeta: true,
        timestamp: at(6),
        message: %{
          content:
            "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"
        }
      }) <>
      line(%{
        type: "user",
        uuid: "u5",
        timestamp: at(7),
        message: %{content: [%{type: "text", text: "[Request interrupted by user for tool use]"}]}
      }) <>
      line(%{
        type: "system",
        uuid: "s1",
        subtype: "compact_boundary",
        content: "Conversation compacted",
        timestamp: at(8)
      }) <>
      line(%{type: "file-history-snapshot", messageId: "x"})
  end

  test "each entry kind, a delivered message's id, and a call's result and duration", ctx do
    File.write!(ctx.path, every_kind())
    assert {:ok, %{entries: entries, reset: nil}} = Transcripts.conversation(ctx.t, ctx.path)

    assert Enum.map(entries, &{&1.kind, &1.uuid}) == [
             {"prompt", "u1"},
             {"tool_call", "a1"},
             {"tool_call", "a2"},
             {"assistant", "a3"},
             {"notice", "u4"},
             {"interrupt", "u5"},
             {"system", "s1"}
           ]

    [prompt, bash, read, reply, notice, interrupt, system] = entries
    assert %{message: "6f1c-row", text: "Review it.\n\n[delivery 6f1c-row]", agent: nil} = prompt
    assert prompt.offset == 0

    assert %{name: "Bash", input: %{"command" => "ls"}, result: "a.txt", is_error: false} = bash
    assert %{duration_ms: 2000, done: true} = bash
    assert %{name: "Read", result: "no such file", is_error: true, duration_ms: 0} = read
    assert %{text: "Done."} = reply
    assert reply.at == DateTime.to_unix(~U[2026-11-25 09:00:05Z], :millisecond)
    assert %{task_id: "b1", status: "completed"} = notice
    assert interrupt.tool_use
    assert %{subtype: "compact_boundary", text: "Conversation compacted"} = system
  end

  test "a conversation read in calls by cursor, each bounded by its limit", ctx do
    File.write!(ctx.path, prompt("u1", "one") <> use("a1", "tu-1", "Bash", %{}, 1))

    # The first read answers the newest entry; the older cursor reads the one before it.
    assert {:ok, %{entries: [%{uuid: "a1", done: false}], next: next, older: older}} =
             Transcripts.conversation(ctx.t, ctx.path, limit: 1)

    assert {:ok, %{entries: [%{uuid: "u1"}], older: nil, next: nil, queue: nil}} =
             Transcripts.conversation(ctx.t, ctx.path, before: older)

    # Nothing new: no entry, and the cursor stays where it was.
    assert {:ok, %{entries: [], next: ^next}} =
             Transcripts.conversation(ctx.t, ctx.path, from: next)

    # A partial line waits; the call's result, read later, gives the call again by its id.
    File.write!(ctx.path, ~s({"type":"user"), [:append])

    assert {:ok, %{entries: [], next: ^next}} =
             Transcripts.conversation(ctx.t, ctx.path, from: next)

    File.write!(
      ctx.path,
      ~s(,"uuid":"r"}\n) <> result("u2", "tu-1", "ok", 4) <> reply("a2", "Hi."),
      [:append]
    )

    assert {:ok, %{entries: [call, %{kind: "assistant", text: "Hi."}]}} =
             Transcripts.conversation(ctx.t, ctx.path, from: next)

    assert %{id: "tu-1", name: "Bash", input: nil, result: "ok", duration_ms: 3000, done: true} =
             call
  end

  test "a cursor past a truncation, or of a resumed session's new file, reads from the start",
       ctx do
    File.write!(ctx.path, prompt("u1", "one") <> prompt("u2", "two"))
    {:ok, %{next: next}} = Transcripts.conversation(ctx.t, ctx.path)

    # The file shrank and was written again: the bytes before the cursor are not the ones read.
    File.write!(ctx.path, prompt("u9", "new"))

    assert {:ok, %{entries: [%{uuid: "u9"}], reset: :rewritten}} =
             Transcripts.conversation(ctx.t, ctx.path, from: next)

    # The session resumed into a new file: the cursor names the old one.
    resumed = Path.join(ctx.dir, "s2.jsonl")
    File.write!(resumed, prompt("v1", "again"))

    assert {:ok, %{entries: [%{uuid: "v1"}], reset: :new_file}} =
             Transcripts.conversation(ctx.t, resumed, from: next)
  end

  test "a subagent's entries with subagents: true, each with its agent", ctx do
    File.write!(ctx.path, prompt("u1", "go") <> use("a1", "tu-9", "Agent", %{}, 1))
    subagents = Path.join([ctx.dir, "s1", "subagents"])
    File.mkdir_p!(subagents)
    side = prompt("g1", "look around") <> use("g2", "tu-s", "Grep", %{pattern: "x"}, 2)
    File.write!(Path.join(subagents, "agent-ab12.jsonl"), side)

    assert {:ok, %{entries: [_, _]}} = Transcripts.conversation(ctx.t, ctx.path)

    assert {:ok, %{entries: entries, next: next}} =
             Transcripts.conversation(ctx.t, ctx.path, subagents: true)

    assert Enum.map(entries, &{&1.agent, &1.uuid}) ==
             [{nil, "u1"}, {nil, "a1"}, {"ab12", "g1"}, {"ab12", "g2"}]

    File.write!(Path.join(subagents, "agent-ab12.jsonl"), reply("g3", "Found it."), [:append])

    assert {:ok, %{entries: [%{agent: "ab12", text: "Found it."}]}} =
             Transcripts.conversation(ctx.t, ctx.path, subagents: true, from: next)
  end

  test "a line longer than the read's bound is one entry, forward and backward", ctx do
    long = prompt("u2", String.duplicate("x", 300))
    File.write!(ctx.path, prompt("u1", "first"))
    {:ok, %{next: next}} = Transcripts.conversation(ctx.t, ctx.path)
    File.write!(ctx.path, long <> prompt("u3", "short"), [:append])

    # Each call reads 150 bytes at most, over the short lines' length: the long line is passed
    # over in pieces, then the short one read.
    {entries, _} =
      Enum.reduce(1..6, {[], next}, fn _, {got, from} ->
        {:ok, %{entries: entries, next: next}} =
          Transcripts.conversation(ctx.t, ctx.path, max_bytes: 150, from: from)

        {got ++ entries, next}
      end)

    offset = byte_size(prompt("u1", "first"))
    assert [%{subtype: "unread_line", offset: ^offset}, %{uuid: "u3"}] = entries

    # Backward from the end: the short line, the long one once, then the first.
    assert {:ok, %{entries: [%{uuid: "u3"}], older: older}} =
             Transcripts.conversation(ctx.t, ctx.path, max_bytes: 150)

    assert older_entries(ctx, older, max_bytes: 150) ==
             [{"prompt", "u1"}, {"system", nil}]
  end

  # Every entry the older cursors read, oldest first, as `{kind, uuid}`.
  defp older_entries(ctx, older, opts, got \\ [])
  defp older_entries(_ctx, nil, _opts, got), do: got

  defp older_entries(ctx, older, opts, got) do
    {:ok, %{entries: entries, older: older}} =
      Transcripts.conversation(ctx.t, ctx.path, [before: older] ++ opts)

    older_entries(ctx, older, opts, Enum.map(entries, &{&1.kind, &1.uuid}) ++ got)
  end

  # A prompt or a reply of `n` filler characters, so lines differ in length.
  defp numbered(i) do
    text = "#{i} " <> String.duplicate("y", rem(i * 37, 211))
    if rem(i, 3) == 0, do: reply("r#{i}", text), else: prompt("p#{i}", text)
  end

  defp uuids(range), do: Enum.map(range, &if(rem(&1, 3) == 0, do: "r#{&1}", else: "p#{&1}"))

  test "paging backward to the start and then forward loses and repeats no entry", ctx do
    File.write!(ctx.path, Enum.map_join(1..120, &numbered/1))
    # A block holds 4 to 9 of these lines, so some reads stop at the limit and some at a block's
    # edge, with a line cut there.
    opts = [limit: 7, max_bytes: 1_500]

    assert {:ok, %{entries: newest, next: next, older: older}} =
             Transcripts.conversation(ctx.t, ctx.path, opts)

    assert length(newest) in 1..7
    seen = older_entries(ctx, older, opts) ++ Enum.map(newest, &{&1.kind, &1.uuid})
    assert Enum.map(seen, &elem(&1, 1)) == uuids(1..120)

    File.write!(ctx.path, Enum.map_join(121..150, &numbered/1), [:append])

    later =
      Stream.unfold(next, fn from ->
        case Transcripts.conversation(ctx.t, ctx.path, [from: from] ++ opts) do
          {:ok, %{entries: [], next: ^from}} -> nil
          {:ok, %{entries: entries, next: next}} -> {Enum.map(entries, & &1.uuid), next}
        end
      end)

    assert Enum.concat(later) == uuids(121..150)
  end

  test "a first read of a long transcript reads only its end", ctx do
    # The host's head is a stand-in that notes the bytes each read takes at most: every
    # bounded read runs through it.
    log = Path.join(ctx.dir, "head.log")
    head = Path.join(ctx.dir, "head")

    File.write!(head, """
    #!#{program!(:sh)}
    printf '%s\\n' "$2" >> "#{log}"
    exec #{program!(:head)} "$@"
    """)

    File.chmod!(head, 0o755)
    opts = Keyword.merge(ctx.opts, programs: programs(host(), %{head: head}))
    {:ok, t} = Transcripts.start_link(Keyword.put(opts, :db, Path.join(ctx.dir, "h.db")))

    File.write!(ctx.path, Enum.map_join(1..30_000, &numbered/1))
    size = File.stat!(ctx.path).size
    assert size > 4_000_000

    assert {:ok, %{entries: entries, older: older}} =
             Transcripts.conversation(t, ctx.path, limit: 20, max_bytes: 65_536)

    assert Enum.map(entries, & &1.uuid) == uuids(29_981..30_000)
    assert is_binary(older)
    assert [bytes] = log |> File.read!() |> String.split() |> Enum.map(&String.to_integer/1)
    assert bytes == 65_537
  end

  defp queue(op, text, second),
    do: line(%{type: "queue-operation", operation: op, timestamp: at(second), content: text})

  test "a message enqueued while a turn runs shows as queued, and is gone after its take", ctx do
    File.write!(
      ctx.path,
      prompt("u1", "go") <>
        use("a1", "tu-1", "Bash", %{command: "make"}, 1) <>
        queue("enqueue", "Also run the tests.", 2) <>
        queue("enqueue", "Hi.\n\n[delivery row-7]", 3)
    )

    assert {:ok, %{queue: [typed, delivered], next: next}} =
             Transcripts.conversation(ctx.t, ctx.path)

    assert %{source: :claude_code, text: "Also run the tests.", message: nil} = typed
    assert typed.at == DateTime.to_unix(~U[2026-11-25 09:00:02Z], :millisecond)
    assert %{message: "row-7"} = delivered

    # The running turn takes the first at its next tool boundary, by its text.
    File.write!(
      ctx.path,
      result("u2", "tu-1", "ok", 4) <> queue("remove", "Also run the tests.", 4),
      [:append]
    )

    assert {:ok, %{queue: [%{message: "row-7"}], next: next}} =
             Transcripts.conversation(ctx.t, ctx.path, from: next)

    File.write!(ctx.path, queue("dequeue", nil, 5), [:append])
    assert {:ok, %{queue: []}} = Transcripts.conversation(ctx.t, ctx.path, from: next)
  end

  test "its refusals name what is wrong", ctx do
    assert {:refused, :no_file} = Transcripts.conversation(ctx.t, ctx.path)
    assert {:refused, {:bad, :from}} = Transcripts.conversation(ctx.t, ctx.path, from: "nope")
    assert {:refused, {:bad, :before}} = Transcripts.conversation(ctx.t, ctx.path, before: 1)

    assert {:refused, {:bad, :before}} =
             Transcripts.conversation(ctx.t, ctx.path, from: "a", before: "b")

    assert {:refused, {:bad, :limit}} = Transcripts.conversation(ctx.t, ctx.path, limit: 0)

    assert {:refused, {:bad, :subagents}} =
             Transcripts.conversation(ctx.t, ctx.path, subagents: 1)
  end

  test "a reader of another host reads there, over ssh, and a dropped host is unknown", ctx do
    # The stand-in drops ssh's options and the host's name and runs the command, as ssh runs it
    # on the host; while `down` exists it fails as a lost connection does, with 255.
    ssh = Path.join(ctx.dir, "ssh")

    File.write!(ssh, """
    #!#{program!(:sh)}
    [ -e "#{ctx.dir}/down" ] && exit 255
    while :; do case $1 in -o|-l|-F) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
    shift
    exec #{program!(:sh)} -c "$*"
    """)

    File.chmod!(ssh, 0o755)
    {:ok, box} = Programs.new(Host.ssh("box", ssh, "box", program!(:kill)), programs().paths)
    opts = Keyword.merge(ctx.opts, programs: box, db: Path.join(ctx.dir, "box.db"))
    {:ok, remote} = Transcripts.start_link(opts)

    File.write!(ctx.path, prompt("u1", "far"))

    assert {:ok, %{entries: [%{uuid: "u1", text: "far"}]}} =
             Transcripts.conversation(remote, ctx.path)

    File.write!(Path.join(ctx.dir, "down"), "")
    assert {:unknown, {:host, _}} = Transcripts.conversation(remote, ctx.path)
  end
end
