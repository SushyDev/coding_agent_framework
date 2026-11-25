defmodule CodingAgentFramework.SurfaceConversationTest do
  # `CodingAgentFramework.conversation/3` on a whole tree (F-260): a main session an import
  # wrote, stopped, so no part acts on it, whose transcript the test writes where Claude Code
  # keeps it, and a message queued for it.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Config, HeadlessStandIn, Mailbox, Tmux, Transcripts}
  alias CodingAgentFramework.Sessions.Table

  setup do
    dir = test_dir()
    instance = "conv-#{System.unique_integer([:positive])}"
    home = Path.join(dir, instance)

    {:ok, c} =
      Config.new(
        home: home,
        instance: instance,
        programs: programs().paths,
        accounts: ["work"],
        ports: %{intake: free_port(), mcp: free_port()},
        claude: HeadlessStandIn.write!(dir, :on_message),
        env: %{home: dir, path: "/nonexistent", term: "xterm-256color", lang: "C.UTF-8"},
        user: "tester",
        interval: 200,
        undeclared_cues: :raise
      )

    File.mkdir_p!(home)
    {:ok, server} = CodingAgentFramework.server(c)
    on_exit(fn -> Tmux.kill_server(server) end)
    %{dir: dir, config: c, home: home}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp line(map), do: JSON.encode!(map) <> "\n"

  test "a session's entries by cursor, a delivered message's id, and the rows queued for it",
       ctx do
    start_supervised!({CodingAgentFramework, ctx.config})
    instance = ctx.config.instance
    cwd = Path.join(ctx.dir, "work")
    db_path = Path.join(ctx.home, "caf.db")

    assert {:refused, :unknown_agent} = CodingAgentFramework.conversation(instance, "app-main")
    assert {:refused, :no_instance} = CodingAgentFramework.conversation("nope", "app-main")

    {:ok, sessions} = Table.open(db_path)
    fields = %{account: "work", session_id: "s-1", cwd: cwd, project: nil, meta: nil}
    Table.imported(sessions, "ws", "app-main", fields)

    config_dir = Path.join([ctx.home, "accounts", "work", "claude"])
    {:ok, path} = Transcripts.path(config_dir, cwd, "s-1")
    assert {:refused, :no_file} = CodingAgentFramework.conversation(instance, "app-main")

    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      line(%{type: "user", uuid: "u1", message: %{content: "Look.\n\n[delivery row-1]"}}) <>
        line(%{
          type: "assistant",
          uuid: "a1",
          message: %{id: "m1", content: [%{type: "text", text: "Looked."}]}
        })
    )

    {:ok, mailbox} = Mailbox.Table.open(db_path)
    text = "From app-unit (msg): next"

    Mailbox.Table.store(mailbox, %{
      from: "app-unit",
      to: "app-main",
      text: text,
      uuid: "row-2",
      kind: "msg"
    })

    assert {:ok, %{entries: [prompt], next: next, queued: queued, reset: nil}} =
             CodingAgentFramework.conversation(instance, "app-main", limit: 1)

    assert %{kind: "prompt", uuid: "u1", message: "row-1"} = prompt
    assert [%{uuid: "row-2", from: "app-unit", status: "queued", text: ^text}] = queued

    assert {:ok, %{entries: [%{kind: "assistant", text: "Looked."}]}} =
             CodingAgentFramework.conversation(instance, "app-main", from: next)

    assert {:refused, {:bad, :limit}} =
             CodingAgentFramework.conversation(instance, "app-main", limit: -1)
  end
end
