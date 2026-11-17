defmodule CodingAgentFramework.TmuxContractTest do
  @moduledoc """
  The `Tmux` contract, run on a real tmux server and on the fake. The real server listens on a
  socket this test owns (`tmux -S <path>`) in this VM's own directory, never the default server.

  A pane runs a stand-in that copies what it receives to a file. Nothing arrived from a refused
  write is shown by order, not by waiting: a later accepted write to the same pane, and the file
  then holds only that write.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Shell, Tmux}
  alias CodingAgentFramework.Tmux.{CLI, Fake}

  doctest Tmux
  doctest CLI
  doctest Fake

  @text "it's $HOME ~ \#{pane_id} a\\b \"q\" end;"

  for impl <- [:cli, :fake] do
    describe "#{impl}" do
      @describetag impl: impl

      setup ctx, do: start(ctx.impl)

      test "a new session's pane is tagged with its session as it opens", ctx do
        {:ok, pane} = Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"))
        assert pane =~ ~r/\A%\d+\z/

        assert {:ok, [%{pane: ^pane, session: "alpha", tag: "alpha"}]} =
                 Tmux.list_panes(ctx.server)
      end

      test "a write to the session's own pane arrives, literally", ctx do
        {:ok, pane} = Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"))
        assert {:ok, :sent} = Tmux.write(ctx.server, pane, "alpha", {:text, @text})
        assert {:ok, :sent} = Tmux.write(ctx.server, pane, "alpha", {:keys, ["Enter"]})
        assert {:ok, @text <> "\n"} == received(ctx, pane, "alpha", @text <> "\n")
      end

      test "a write to a pane tagged for another session sends nothing", ctx do
        {:ok, a} = Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"))
        {:ok, _b} = Tmux.new_session(ctx.server, "beta", stand_in(ctx, "beta"))

        assert {:refused, {:tagged_for, "alpha"}} =
                 Tmux.write(ctx.server, a, "beta", {:text, "wrong"})

        assert_only_later_write_arrives(ctx, a, "alpha")
      end

      test "a write to an untagged pane sends nothing", ctx do
        {:ok, pane} = Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"))
        set_tag(ctx, pane, nil)
        assert {:refused, :untagged} = Tmux.write(ctx.server, pane, "alpha", {:text, "wrong"})
        set_tag(ctx, pane, "alpha")
        assert_only_later_write_arrives(ctx, pane, "alpha")
      end

      test "a pane id kept from before a restart reaches no other session's pane", ctx do
        {:ok, kept} = Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"))
        assert {:ok, :killed} = Tmux.kill_server(ctx.server)
        assert {:refused, :no_server} = Tmux.write(ctx.server, kept, "alpha", {:text, "x"})
        assert {:refused, :no_server} = Tmux.list_panes(ctx.server)

        # The new server counts from %0 again, and beta's pane takes alpha's kept id.
        {:ok, ^kept} = Tmux.new_session(ctx.server, "beta", stand_in(ctx, "beta"))

        assert {:refused, {:tagged_for, "beta"}} =
                 Tmux.write(ctx.server, kept, "alpha", {:text, "wrong"})

        assert_only_later_write_arrives(ctx, kept, "beta")
      end

      test "a missing pane, a bad target and a duplicate session are refused", ctx do
        {:ok, _} = Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"))
        assert {:refused, :no_pane} = Tmux.write(ctx.server, "%99", "alpha", {:text, "x"})
        assert {:refused, {:bad_target, ""}} = Tmux.write(ctx.server, "", "alpha", {:text, "x"})
        assert {:refused, {:bad_target, "0"}} = Tmux.write(ctx.server, "0", "alpha", {:text, "x"})

        assert {:refused, {:bad_session, "a:b"}} =
                 Tmux.write(ctx.server, "%0", "a:b", {:text, "x"})

        assert {:refused, {:bad_input, {:keys, ["C-c;"]}}} =
                 Tmux.write(ctx.server, "%0", "alpha", {:keys, ["C-c;"]})

        assert {:refused, {:session_exists, "alpha"}} =
                 Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"))
      end

      test "a pane is killed or respawned only for the session its tag names", ctx do
        {:ok, a} = Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"))
        {:ok, _} = Tmux.new_session(ctx.server, "beta", stand_in(ctx, "beta"))
        argv = stand_in(ctx, "alpha2")
        assert {:refused, {:tagged_for, "alpha"}} = Tmux.respawn_pane(ctx.server, a, "beta", argv)
        assert {:refused, {:tagged_for, "alpha"}} = Tmux.kill_pane(ctx.server, a, "beta")
        assert {:refused, {:bad_argv, []}} = Tmux.respawn_pane(ctx.server, a, "alpha", [])

        # The respawned pane keeps its id and its tag, and runs the new program.
        assert {:ok, :respawned} = Tmux.respawn_pane(ctx.server, a, "alpha", argv)
        {:ok, panes} = Tmux.list_panes(ctx.server)
        assert %{tag: "alpha"} = Enum.find(panes, &(&1.pane == a))
        assert {:ok, :sent} = Tmux.write(ctx.server, a, "alpha", {:line, "again"})
        assert {:ok, "again\n"} == received(ctx, a, "alpha2", "again\n")

        assert {:ok, :killed} = Tmux.kill_pane(ctx.server, a, "alpha")
        assert {:refused, :no_pane} = Tmux.kill_pane(ctx.server, a, "alpha")
        assert {:ok, [%{session: "beta"}]} = Tmux.list_panes(ctx.server)
      end

      test "a killed session's pane is gone", ctx do
        {:ok, pane} = Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"))
        {:ok, _} = Tmux.new_session(ctx.server, "beta", stand_in(ctx, "beta"))
        assert {:ok, :killed} = Tmux.kill_session(ctx.server, "alpha")
        assert {:refused, :no_session} = Tmux.kill_session(ctx.server, "alpha")
        assert {:refused, :no_pane} = Tmux.write(ctx.server, pane, "alpha", {:text, "x"})
        assert {:ok, [%{session: "beta"}]} = Tmux.list_panes(ctx.server)
      end
    end
  end

  describe "cli only" do
    setup do: start(:cli)

    test "an argument ending in ; reaches the pane's program whole", ctx do
      out = Path.join(ctx.dir, "argv")
      args = ["x;", "y;z", "a\\;", "p\\", "\#{pane_id}", "$HOME"]
      script = ~s(printf '%s|' "$@" > "$0"; exec #{program!(:cat)})
      {:ok, _} = Tmux.new_session(ctx.server, "alpha", [program!(:sh), "-c", script, out | args])
      expected = Enum.map_join(args, &(&1 <> "|"))
      assert {:ok, ^expected} = read_when(out, expected)
    end

    test "a window opened one row short grows, and keeps no fixed window-size", ctx do
      {:ok, pane} =
        Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"), size: {100, 29})

      assert tmux(ctx, ["display-message", "-p", "-t", pane, "\#{window_height}"]) == "29\n"
      assert {:ok, :resized} = Tmux.resize_pane(ctx.server, pane, "alpha", {100, 30})
      assert {:refused, {:tagged_for, "alpha"}} = Tmux.resize_pane(ctx.server, pane, "b", {9, 9})
      assert tmux(ctx, ["display-message", "-p", "-t", pane, "\#{window_height}"]) == "30\n"
      assert tmux(ctx, ["show-options", "-w", "-t", pane, "window-size"]) == ""
    end

    test "a capture shows the pane's screen and width, only for the session its tag names",
         ctx do
      script = ~s(printf 'hello\\nworld  '; exec #{program!(:cat)})
      argv = [program!(:sh), "-c", script]
      {:ok, pane} = Tmux.new_session(ctx.server, "alpha", argv, size: {50, 5})
      assert {:refused, {:tagged_for, "alpha"}} = Tmux.capture(ctx.server, pane, "beta")

      assert {:ok, %{width: 50, text: "hello\nworld\n" <> _}} =
               await(fn ->
                 with {:ok, %{text: "hello\nworld\n" <> _}} = ok <-
                        Tmux.capture(ctx.server, pane, "alpha"),
                      do: ok
               end)
    end

    test "killing the server removes its socket file", ctx do
      {:ok, _} = Tmux.new_session(ctx.server, "alpha", stand_in(ctx, "alpha"))
      assert File.exists?(ctx.socket)
      assert {:ok, :killed} = Tmux.kill_server(ctx.server)
      refute File.exists?(ctx.socket)
      assert {:refused, :no_server} = Tmux.kill_server(ctx.server)
    end
  end

  defp tmux(%{server: server, socket: socket}, args) do
    {:ok, %{status: 0, output: out}} =
      Shell.run(server.host, server.tmux, ["-S", socket | args], timeout: 5_000)

    out
  end

  defp start(:cli) do
    dir = test_dir()
    socket = Path.join(dir, "tmux.sock")
    {:ok, server} = CLI.new(programs(), {:socket, socket})
    # The test owns this server; it ends it and its socket file whatever the test did.
    on_exit(fn -> Tmux.kill_server(server) end)
    {:ok, impl: :cli, server: server, dir: dir, socket: socket}
  end

  defp start(:fake) do
    key = {"test", "fake"}
    pid = start_supervised!({Fake, key: key})
    {:ok, impl: :fake, server: Fake.new(pid, key), dir: nil}
  end

  # The pane's program: it copies its input to a file named for its session.
  defp stand_in(%{impl: :cli, dir: dir}, session),
    do: [
      program!(:sh),
      "-c",
      ~s(exec #{program!(:cat)} > "$0"),
      Path.join(dir, session <> ".out")
    ]

  defp stand_in(%{impl: :fake}, _session), do: [program!(:cat)]

  defp received(%{impl: :cli, dir: dir}, _pane, session, expected),
    do: read_when(Path.join(dir, session <> ".out"), expected)

  defp received(%{impl: :fake} = ctx, pane, _session, expected) do
    await(fn ->
      text = Enum.map_join(received_list(ctx, pane), &render/1)
      if byte_size(text) >= byte_size(expected), do: {:ok, text}, else: text
    end)
  end

  defp received_list(%{impl: :fake, server: server}, pane), do: Fake.received(server, pane)

  defp render({:text, text}), do: text
  defp render({:line, text}), do: text <> "\n"
  defp render({:keys, ["Enter"]}), do: "\n"

  defp assert_only_later_write_arrives(ctx, pane, session) do
    assert {:ok, :sent} = Tmux.write(ctx.server, pane, session, {:text, "right"})
    assert {:ok, :sent} = Tmux.write(ctx.server, pane, session, {:keys, ["Enter"]})
    assert {:ok, "right\n"} == received(ctx, pane, session, "right\n")
  end

  defp set_tag(%{impl: :fake, server: server}, pane, tag), do: Fake.set_tag(server, pane, tag)

  # The contract has no call to change a tag, so the test sets it with tmux itself.
  defp set_tag(%{impl: :cli, server: server, socket: socket}, pane, tag) do
    value = if tag, do: [server.tag, tag], else: ["-u", server.tag]
    args = ["-S", socket, "set-option", "-p", "-t", pane | value]
    {:ok, %{status: 0}} = Shell.run(server.host, server.tmux, args, timeout: 5_000)
    :ok
  end
end
