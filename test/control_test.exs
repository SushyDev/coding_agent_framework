defmodule CodingAgentFramework.ControlTest.Probe do
  @moduledoc """
  A `Tmux` over another one that reports each write to the test: the process that made it, how
  many writes were under way at once, and the input. It answers `answer` in place of writing
  when given one, and holds a write of the line `"hold"` until the test sends `:go`.
  """
  @behaviour CodingAgentFramework.Tmux

  alias CodingAgentFramework.Tmux

  defstruct [:inner, :test, :busy, :answer]

  @impl true
  def key(s), do: Tmux.key(s.inner)
  @impl true
  def new_session(s, session, argv, opts), do: Tmux.new_session(s.inner, session, argv, opts)
  @impl true
  def list_panes(s), do: Tmux.list_panes(s.inner)
  @impl true
  def kill_pane(s, pane, session), do: Tmux.kill_pane(s.inner, pane, session)
  @impl true
  def respawn_pane(s, pane, session, argv), do: Tmux.respawn_pane(s.inner, pane, session, argv)
  @impl true
  def kill_session(s, session), do: Tmux.kill_session(s.inner, session)
  @impl true
  def kill_server(s), do: Tmux.kill_server(s.inner)

  @impl true
  def write(s, pane, session, input) do
    :counters.add(s.busy, 1, 1)
    send(s.test, {:write, self(), :counters.get(s.busy, 1), input})
    if input == {:line, "hold"}, do: receive(do: (:go -> :ok), after: (5_000 -> :ok))
    outcome = s.answer || Tmux.write(s.inner, pane, session, input)
    :counters.sub(s.busy, 1, 1)
    outcome
  end
end

defmodule CodingAgentFramework.ControlTest do
  @moduledoc """
  `Control` on a real tmux server (a socket this test owns, in this VM's own directory) and on
  the fake. Panes run a stand-in that copies its input to a file; nothing reaches the real
  Claude Code.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Control, Tmux}
  alias CodingAgentFramework.ControlTest.Probe
  alias CodingAgentFramework.Tmux.{CLI, Fake}

  doctest Control

  for impl <- [:cli, :fake] do
    describe "#{impl}" do
      @describetag impl: impl

      setup ctx, do: start(ctx.impl, nil)

      test "a write after a restart, with another session's pane on the kept id, sends nothing",
           ctx do
        {:ok, kept} = Control.open(ctx.control, "alpha", stand_in(ctx, "alpha"))
        assert {:ok, :killed} = Tmux.kill_server(ctx.server)
        assert {:refused, :no_server} = Control.send(ctx.control, "alpha", "lost")

        # The new server counts from %0 again, and beta's pane takes alpha's kept id.
        assert {:ok, ^kept} = Control.open(ctx.control, "beta", stand_in(ctx, "beta"))
        assert {:refused, {:tagged_for, "beta"}} = Control.send(ctx.control, "alpha", "wrong")
        assert {:refused, {:tagged_for, "beta"}} = Control.interrupt(ctx.control, "alpha")
        assert {:refused, {:tagged_for, "beta"}} = Control.stop(ctx.control, "alpha")

        # Shown by order: beta's next line is the first and only thing its pane received.
        assert {:ok, :sent} = Control.send(ctx.control, "beta", "right")
        assert {:ok, "right\n"} == received(ctx, kept, "beta", "right\n")
      end

      test "writes from many callers at once go out one at a time, from Control alone", ctx do
        {:ok, pane} = Control.open(ctx.control, "alpha", stand_in(ctx, "alpha"))
        lines = for i <- 1..30, do: "line #{i}"

        outcomes =
          lines
          |> Enum.map(&Task.async(fn -> Control.send(ctx.control, "alpha", &1) end))
          |> Task.await_many(20_000)

        assert Enum.all?(outcomes, &(&1 == {:ok, :sent}))

        for _ <- lines do
          assert_received {:write, writer, 1, {:line, _}}
          assert writer == ctx.control
        end

        expected = Enum.map_join(lines, &(&1 <> "\n"))
        {:ok, got} = received(ctx, pane, "alpha", expected)
        assert Enum.sort(String.split(got, "\n", trim: true)) == Enum.sort(lines)
      end

      test "send, respawn and stop act on the session's own pane", ctx do
        {:ok, pane} = Control.open(ctx.control, "alpha", stand_in(ctx, "alpha"))
        assert {:ok, :sent} = Control.send(ctx.control, "alpha", "one")
        assert {:ok, "one\n"} == received(ctx, pane, "alpha", "one\n")

        assert {:ok, :respawned} = Control.respawn(ctx.control, "alpha", stand_in(ctx, "again"))
        assert {:ok, :sent} = Control.send(ctx.control, "alpha", "two")
        assert {:ok, _} = received(ctx, pane, "again", "two\n")

        # beta keeps the server up, since tmux ends a server with no sessions left.
        {:ok, _} = Control.open(ctx.control, "beta", stand_in(ctx, "beta"))
        assert {:ok, :killed} = Control.stop(ctx.control, "alpha")
        assert {:ok, [%{session: "beta"}]} = Tmux.list_panes(ctx.server)
        assert {:refused, :no_kept_pane} = Control.send(ctx.control, "alpha", "three")
      end
    end
  end

  describe "fake only" do
    test "a call for a session with no kept pane is refused" do
      ctx = start!(:fake, nil)
      assert {:refused, :no_kept_pane} = Control.send(ctx.control, "ghost", "x")
      assert {:refused, :no_kept_pane} = Control.interrupt(ctx.control, "ghost")
      assert {:refused, :no_kept_pane} = Control.stop(ctx.control, "ghost")
      assert {:refused, :no_kept_pane} = Control.respawn(ctx.control, "ghost", [program!(:cat)])
      refute_received {:write, _, _, _}
    end

    test "an interrupt is one C-c" do
      ctx = start!(:fake, nil)
      {:ok, pane} = Control.open(ctx.control, "alpha", [program!(:cat)])
      assert {:ok, :sent} = Control.interrupt(ctx.control, "alpha")
      assert [{:keys, ["C-c"]}] = Fake.received(ctx.server, pane)
    end

    test "an unknown write is answered as unknown and not resent" do
      ctx = start!(:fake, {:unknown, :lost})
      {:ok, _} = Control.open(ctx.control, "alpha", [program!(:cat)])
      assert {:unknown, :lost} = Control.send(ctx.control, "alpha", "once")
      assert_received {:write, _, _, {:line, "once"}}

      # Control does its work inside each call, so once another call returns nothing more is
      # under way.
      assert {:ok, :killed} = Control.stop(ctx.control, "alpha")
      refute_received {:write, _, _, _}
    end

    test "a call past its timeout is unknown, and goes out neither then nor later" do
      ctx = start!(:fake, nil)
      {:ok, pane} = Control.open(ctx.control, "alpha", [program!(:cat)])
      held = Task.async(fn -> Control.send(ctx.control, "alpha", "hold") end)
      assert_receive {:write, _, 1, {:line, "hold"}}, 5_000

      assert {:unknown, {:timeout, 50}} = Control.send(ctx.control, "alpha", "late", timeout: 50)
      send(ctx.control, :go)
      assert {:ok, :sent} = Task.await(held)
      assert {:ok, :sent} = Control.send(ctx.control, "alpha", "after")
      assert [{:line, "hold"}, {:line, "after"}] = Fake.received(ctx.server, pane)
    end
  end

  defp start!(impl, answer) do
    {:ok, ctx} = start(impl, answer)
    Map.new(ctx)
  end

  defp start(:cli, answer) do
    dir = test_dir()
    server = CLI.new(host(), {:socket, Path.join(dir, "tmux.sock")}, program!(:tmux))
    # The test owns this server; it ends it and its socket file whatever the test did.
    on_exit(fn -> Tmux.kill_server(server) end)
    control(:cli, server, dir, answer)
  end

  defp start(:fake, answer) do
    key = {"test", "fake"}
    pid = start_supervised!({Fake, key: key})
    control(:fake, Fake.new(pid, key), nil, answer)
  end

  defp control(impl, server, dir, answer) do
    probe = %Probe{inner: server, test: self(), busy: :counters.new(1, []), answer: answer}
    control = start_supervised!({Control, tmux: probe})
    {:ok, impl: impl, server: server, dir: dir, control: control}
  end

  # The pane's program: it copies its input to a file named for `name`.
  defp stand_in(%{impl: :cli, dir: dir}, name),
    do: [program!(:sh), "-c", ~s(exec #{program!(:cat)} > "$0"), Path.join(dir, name <> ".out")]

  defp stand_in(%{impl: :fake}, _name), do: [program!(:cat)]

  defp received(%{impl: :cli, dir: dir}, _pane, name, expected),
    do: read_when(Path.join(dir, name <> ".out"), expected)

  defp received(%{impl: :fake, server: server}, pane, _name, expected) do
    await(fn ->
      text = Enum.map_join(Fake.received(server, pane), fn {:line, t} -> t <> "\n" end)
      if byte_size(text) >= byte_size(expected), do: {:ok, text}, else: text
    end)
  end
end
