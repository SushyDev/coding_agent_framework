defmodule CodingAgentFramework.InletTest.Probe do
  @moduledoc "A `Tmux` over another one that tells the test each write, from the process that made it."
  @behaviour CodingAgentFramework.Tmux

  alias CodingAgentFramework.Tmux

  defstruct [:inner, :test]

  @impl true
  def key(s), do: Tmux.key(s.inner)
  @impl true
  def new_session(s, session, argv, opts), do: Tmux.new_session(s.inner, session, argv, opts)
  @impl true
  def list_panes(s), do: Tmux.list_panes(s.inner)
  @impl true
  def list_clients(s), do: Tmux.list_clients(s.inner)
  @impl true
  def capture(s, pane, session), do: Tmux.capture(s.inner, pane, session)
  @impl true
  def kill_pane(s, pane, session), do: Tmux.kill_pane(s.inner, pane, session)
  @impl true
  def respawn_pane(s, pane, session, argv), do: Tmux.respawn_pane(s.inner, pane, session, argv)
  @impl true
  def resize_pane(s, pane, session, size), do: Tmux.resize_pane(s.inner, pane, session, size)
  @impl true
  def kill_session(s, session), do: Tmux.kill_session(s.inner, session)
  @impl true
  def kill_server(s), do: Tmux.kill_server(s.inner)

  @impl true
  def write(s, pane, session, input) do
    send(s.test, {:write, self(), input})
    Tmux.write(s.inner, pane, session, input)
  end
end

defmodule CodingAgentFramework.InletTest do
  @moduledoc """
  `Inlet` on a real tmux server (a socket this test owns, in this VM's own directory), with
  panes that run `ScreenStandIn`: it draws Claude Code 2.1.322's captured screens and reads keys
  one at a time, so nothing reaches the real Claude Code. Each test names the
  `Delivery.tla` guard it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Inlet, ScreenStandIn, Screen, Tmux}
  alias CodingAgentFramework.InletTest.Probe
  alias CodingAgentFramework.Tmux.{CLI, Fake}

  doctest Inlet

  @release "2.1.322"

  setup do
    dir = test_dir()
    {:ok, server} = CLI.new(programs(), {:socket, Path.join(dir, "tmux.sock")})
    on_exit(fn -> Tmux.kill_server(server) end)
    on_exit(fn -> end_recorded(dir) end)
    probe = %Probe{inner: server, test: self()}
    {:ok, dir: dir, server: server, inlet: start_supervised!({Inlet, tmux: probe})}
  end

  # Typed only into an ended turn (OnlyIntoEndedTurn): the turn and the box are read again in
  # the write's own step, then the text, then Enter as its own command.
  test "types into an ended turn with an empty box, then Enter on its own", ctx do
    open(ctx, "alpha")
    me = self()

    turn = fn ->
      send(me, {:turn, self()})
      :ok
    end

    assert {:ok, :sent} =
             Inlet.type(ctx.inlet, "alpha", "hello there", release: @release, turn: turn)

    inlet = ctx.inlet
    assert_received {:turn, ^inlet}
    assert_received {:write, ^inlet, {:text, "hello there"}}
    assert_received {:write, ^inlet, {:keys, ["Enter"]}}
    assert {:ok, ["hello there"]} = submitted(ctx, 1)
  end

  # IntoRunningTurn's guard, and a person's draft left alone (F-113's new-2: never one read).
  test "types nothing when the turn reads otherwise, into a running turn, or over a draft",
       ctx do
    open(ctx, "alpha")
    refused = fn -> {:refused, :running} end

    assert {:refused, {:turn, :running}} =
             Inlet.type(ctx.inlet, "alpha", "one", release: @release, turn: refused)

    # The file says idle, but the screen shows a turn running: the second reading refuses.
    open(ctx, "busy", ["--screen", "running"])

    assert {:refused, {:screen, %{state: :running}}} =
             Inlet.type(ctx.inlet, "busy", "two", release: @release, turn: fn -> :ok end)

    # A draft a person left in the box is not touched.
    {:ok, pane} = pane(ctx, "alpha")
    assert {:ok, :sent} = Tmux.write(ctx.server, pane, "alpha", {:text, "draft"})
    {:ok, _} = screen(ctx, "alpha", &match?(%{box: {:text, "draft"}}, &1))

    assert {:refused, {:screen, %{state: :idle, box: {:text, "draft"}}}} =
             Inlet.type(ctx.inlet, "alpha", "three", release: @release, turn: fn -> :ok end)

    refute_received {:write, _, _}
    assert ScreenStandIn.submitted(ctx.dir) == []
  end

  test "refuses a text it cannot check, and a release it cannot read", ctx do
    open(ctx, "alpha")
    ok = fn -> :ok end
    # The pane is 120 columns wide: the prompt, its space and two to spare leave 116.
    long = String.duplicate("a", 117)

    assert {:refused, {:too_long, 116}} =
             Inlet.type(ctx.inlet, "alpha", long, release: @release, turn: ok)

    assert {:refused, {:bad_text, :control}} =
             Inlet.type(ctx.inlet, "alpha", "a\nb", release: @release, turn: ok)

    assert {:refused, :no_release} = Inlet.type(ctx.inlet, "alpha", "hi", release: nil, turn: ok)

    assert {:refused, {:unknown_release, "0.0.1"}} =
             Inlet.type(ctx.inlet, "alpha", "hi", release: "0.0.1", turn: ok)

    refute_received {:write, _, _}

    # The longest text it takes goes in whole, on one line.
    fits = String.duplicate("b", 116)
    assert {:ok, :sent} = Inlet.type(ctx.inlet, "alpha", fits, release: @release, turn: ok)
    assert {:ok, [^fits]} = submitted(ctx, 1)
  end

  test "a session with no tagged pane, or a server gone, takes nothing" do
    {:ok, fake} = Fake.start_link(key: {"laptop", "fake"})
    server = Fake.new(fake, {"laptop", "fake"})
    inlet = start_supervised!({Inlet, tmux: server}, id: :fake)
    ok = fn -> :ok end
    {:ok, pane} = Tmux.new_session(server, "alpha", [program!(:cat)])
    Fake.set_tag(server, pane, "beta")
    assert {:refused, :no_pane} = Inlet.type(inlet, "alpha", "hi", release: @release, turn: ok)
    {:ok, :killed} = Tmux.kill_server(server)
    assert {:refused, :no_server} = Inlet.type(inlet, "alpha", "hi", release: @release, turn: ok)
    assert Fake.received(server, pane) == []
  end

  # A start's trust dialog (F-137): moved to its option by label, seen selected, then Enter on
  # its own; a screen that is not that dialog takes no key.
  test "answers a dialog by its label, and nothing that is not that dialog", ctx do
    script = ScreenStandIn.write!(ctx.dir, @release, stand_in_idle(), trust: true)
    {:ok, _} = Tmux.new_session(ctx.server, "alpha", [script, "--", "go"], size: {120, 40})
    {:ok, %{kind: :trust}} = screen(ctx, "alpha", &(&1.state == :dialog))
    yes = "Yes, I trust this folder"

    assert {:ok, :sent} = Inlet.choose(ctx.inlet, "alpha", :trust, yes, release: @release)
    inlet = ctx.inlet
    assert_received {:write, ^inlet, {:keys, ["Down"]}}
    assert_received {:write, ^inlet, {:keys, ["Enter"]}}
    assert {:ok, _} = screen(ctx, "alpha", &(&1.state == :idle))

    assert {:ok, ["go"]} =
             await(fn ->
               if ScreenStandIn.prompts(ctx.dir) == [],
                 do: :no,
                 else: {:ok, ScreenStandIn.prompts(ctx.dir)}
             end)

    assert {:refused, {:screen, %{state: :idle}}} =
             Inlet.choose(ctx.inlet, "alpha", :trust, yes, release: @release)

    refute_received {:write, ^inlet, _}
  end

  # F-198, Menu.tla's Check and Back: a menu no rule names, named by its title and options,
  # moved to its option, the marker read back on it, then Enter; Escape for esc; another
  # menu, or none, takes no key.
  test "answers a menu by its label, read back before Enter, or by Escape", ctx do
    [_, not_now, _] = options = ScreenStandIn.menu()
    menu = {:menu, "Teach auto mode about your environment?", options}
    inlet = ctx.inlet

    open(ctx, "alpha", ["--screen", "menu"], :dialog)
    other = {:menu, "Another menu?", options}

    assert {:refused, {:screen, %{kind: :menu}}} =
             Inlet.choose(inlet, "alpha", other, not_now, release: @release)

    refute_received {:write, ^inlet, _}

    assert {:ok, :sent} = Inlet.choose(inlet, "alpha", menu, not_now, release: @release)
    assert_received {:write, ^inlet, {:keys, ["Down"]}}
    assert_received {:write, ^inlet, {:keys, ["Enter"]}}
    assert ScreenStandIn.menu_answer(ctx.dir) == not_now

    assert {:refused, {:screen, %{state: :idle}}} =
             Inlet.choose(inlet, "alpha", menu, :esc, release: @release)

    open(ctx, "beta", ["--screen", "menu"], :dialog)
    assert {:ok, :sent} = Inlet.choose(inlet, "beta", menu, :esc, release: @release)
    assert_received {:write, ^inlet, {:keys, ["Escape"]}}
    refute_received {:write, ^inlet, _}
  end

  # F-142, item 4: an interactive delegate's interrupt. Checked: a turn runs, the Escape lands,
  # the turn ends; an idle screen takes no key.
  test "interrupts a running turn by Escape, and nothing when no turn runs", ctx do
    open(ctx, "busy", ["--screen", "running"])
    inlet = ctx.inlet
    assert {:ok, :sent} = Inlet.interrupt(inlet, "busy", release: @release)
    assert_received {:write, ^inlet, {:keys, ["Escape"]}}
    assert File.exists?(Path.join(ctx.dir, "interrupted"))
    assert {:ok, %{state: :idle}} = screen(ctx, "busy", &(&1.state == :idle))

    assert {:refused, {:screen, %{state: :idle}}} =
             Inlet.interrupt(inlet, "busy", release: @release)

    assert {:refused, :no_release} = Inlet.interrupt(inlet, "busy", release: nil)
    refute_received {:write, ^inlet, _}
  end

  defp open(ctx, name, args \\ [], state \\ nil) do
    script = ScreenStandIn.write!(ctx.dir)
    {:ok, _} = Tmux.new_session(ctx.server, name, [script | args], size: {120, 40})
    {:ok, _} = screen(ctx, name, &(&1.state in if(state, do: [state], else: [:idle, :running])))
  end

  defp pane(ctx, name) do
    {:ok, panes} = Tmux.list_panes(ctx.server)
    {:ok, Enum.find_value(panes, &(&1.tag == name && &1.pane))}
  end

  # The screen as `Screen` reads it, once `ready?` holds.
  defp screen(ctx, name, ready?) do
    {:ok, pane} = pane(ctx, name)

    await(fn ->
      with {:ok, %{text: text}} <- Tmux.capture(ctx.server, pane, name),
           {:ok, reading} <- Screen.read(text, @release),
           true <- ready?.(reading) do
        {:ok, reading}
      end
    end)
  end

  defp submitted(ctx, n) do
    await(fn ->
      lines = ScreenStandIn.submitted(ctx.dir)
      if length(lines) >= n, do: {:ok, lines}, else: lines
    end)
  end
end
