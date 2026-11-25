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

  test "a conversation read in two calls by cursor, each bounded by its limit", ctx do
    File.write!(ctx.path, prompt("u1", "one") <> use("a1", "tu-1", "Bash", %{}, 1))

    assert {:ok, %{entries: [%{uuid: "u1"}], next: next}} =
             Transcripts.conversation(ctx.t, ctx.path, limit: 1)

    assert {:ok, %{entries: [%{uuid: "a1", done: false}], next: next}} =
             Transcripts.conversation(ctx.t, ctx.path, from: next)

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

  test "a line longer than the read's bound is one entry and the read goes on", ctx do
    long = prompt("u1", String.duplicate("x", 300))
    File.write!(ctx.path, long <> prompt("u2", "short"))

    # Each call reads 150 bytes at most, over the short line's length: the long line is passed
    # over in pieces, then the short one read.
    {entries, _} =
      Enum.reduce(1..6, {[], nil}, fn _, {got, from} ->
        {:ok, %{entries: entries, next: next}} =
          Transcripts.conversation(ctx.t, ctx.path, max_bytes: 150, from: from)

        {got ++ entries, next}
      end)

    assert [%{kind: "system", subtype: "unread_line", offset: 0}, %{uuid: "u2"}] = entries
  end

  test "its refusals name what is wrong", ctx do
    assert {:refused, :no_file} = Transcripts.conversation(ctx.t, ctx.path)
    assert {:refused, {:bad, :from}} = Transcripts.conversation(ctx.t, ctx.path, from: "nope")
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
