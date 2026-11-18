defmodule CodingAgentFramework.SessionsViewerTest do
  @moduledoc """
  `Sessions.viewer_argv/3` on a real tmux server and real dtach sockets in this test's own
  directory, with the stand-ins for Claude Code: it answers each row's viewer command, and the
  viewer a start opened runs that same command.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.SessionsSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Holder, Sessions, SessionsSetup, Stream}

  setup {SessionsSetup, :sessions}

  test "an interactive session's viewer is dtach -a of its socket", ctx do
    assert {:ok, _} = Sessions.start(ctx.sessions, "main", ctx.account, launch(ctx, :at_start))

    assert {:ok, [dtach, "-a", socket | _] = argv} = Holder.viewer_argv(ctx.holder, "main")
    assert dtach == program!(:dtach)
    assert Path.basename(socket) == "main.sock"
    assert {:ok, ^argv} = Sessions.viewer_argv(ctx.sessions, "main")
    assert started_with(ctx, "main") == Enum.join(argv, " ")
  end

  test "a delegate's viewer follows its event log, and not its socket", ctx do
    assert {:ok, %{session_id: id}} =
             Sessions.start(ctx.sessions, "d1", ctx.account, headless(ctx, :on_message))

    log = Path.join(Stream.dir(ctx.dir, id), "events.jsonl")
    argv = [program!(:tail), "-F", log]
    assert {:ok, ^argv} = Sessions.viewer_argv(ctx.sessions, "d1")
    assert started_with(ctx, "d1") == Enum.join(argv, " ")
  end

  test "a name with no row, and a Sessions that is gone, are refused", ctx do
    # The setup ends the stand-ins by the pids in this directory, which no start made here.
    File.mkdir_p!(Path.join(ctx.dir, "pids"))
    assert {:refused, :no_session} = Sessions.viewer_argv(ctx.sessions, "nobody")

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert {:refused, :no_sessions} = Sessions.viewer_argv(dead, "main")
  end

  # The command tmux says the viewer pane of session `name` started with, from this test's own
  # tmux server.
  defp started_with(ctx, name) do
    socket = Path.join(ctx.dir, "tmux.sock")
    args = ["-S", socket, "list-panes", "-t", "=#{name}:", "-F", "\#{pane_start_command}"]
    {out, 0} = System.cmd(program!(:tmux), args)
    String.trim(out)
  end
end
