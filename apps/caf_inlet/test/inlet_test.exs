defmodule CodingAgentFramework.InletTest.Probe do
  @moduledoc "A `Tmux` over another one that tells the test each write, from the process that made it."
  @behaviour CodingAgentFramework.Tmux

  alias CodingAgentFramework.Tmux

  defstruct [:inner, :test]

  @impl true
  def key(s), do: Tmux.key(s.inner)
  @impl true
  def bound(s), do: Tmux.bound(s.inner)
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
  @trust "Yes, I trust this folder"

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

    assert {:ok, :sent} = Inlet.choose(ctx.inlet, "alpha", :trust, yes, press(ctx.inlet))
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
             Inlet.choose(ctx.inlet, "alpha", :trust, yes, press(ctx.inlet))

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
             Inlet.choose(inlet, "alpha", other, not_now, press(inlet))

    refute_received {:write, ^inlet, _}

    assert {:ok, :sent} = Inlet.choose(inlet, "alpha", menu, not_now, press(inlet))
    assert_received {:write, ^inlet, {:keys, ["Down"]}}
    assert_received {:write, ^inlet, {:keys, ["Enter"]}}
    assert ScreenStandIn.menu_answer(ctx.dir) == not_now

    assert {:refused, {:screen, %{state: :idle}}} =
             Inlet.choose(inlet, "alpha", menu, :esc, press(inlet))

    open(ctx, "beta", ["--screen", "menu"], :dialog)
    assert {:ok, :sent} = Inlet.choose(inlet, "beta", menu, :esc, press(inlet))
    assert_received {:write, ^inlet, {:keys, ["Escape"]}}
    refute_received {:write, ^inlet, _}
  end

  # F-230: Claude Code's own question is answered as a menu; the marker crosses the free-text
  # option the menu leaves out, so "Chat about this" is three Downs away, the fourth drawn.
  test "answers Claude Code's own question across the option it leaves out", ctx do
    menu = {:menu, "Go on, yes or no?", ["Yes", "No", "Chat about this"]}
    inlet = ctx.inlet

    open(ctx, "alpha", ["--screen", "ask"], :dialog)

    assert {:refused, {:no_option, "Type something."}} =
             Inlet.choose(inlet, "alpha", menu, "Type something.", press(inlet))

    refute_received {:write, ^inlet, _}

    assert {:ok, :sent} = Inlet.choose(inlet, "alpha", menu, "Chat about this", press(inlet))
    assert_received {:write, ^inlet, {:keys, ["Down", "Down", "Down"]}}
    assert_received {:write, ^inlet, {:keys, ["Enter"]}}
    assert File.read!(Path.join(ctx.dir, "menu")) == "4"
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

  # F-233: `/reload-plugins` goes as a typed text goes, then its result line is read under its
  # echo. A second reload is told from the first by the lines above the box.
  test "reloads plugins into an idle session with an empty box, by its result line", ctx do
    open(ctx, "alpha")
    inlet = ctx.inlet
    ok = fn -> :ok end

    for n <- 1..2 do
      assert {:ok, :reloaded} =
               Inlet.reload_plugins(inlet, "alpha", release: @release, turn: ok)

      assert_received {:write, ^inlet, {:text, "/reload-plugins"}}
      assert_received {:write, ^inlet, {:keys, ["Enter"]}}
      assert length(ScreenStandIn.submitted(ctx.dir)) == n
    end
  end

  test "reloads nothing into a turn running, a dialog shown or a box not empty", ctx do
    inlet = ctx.inlet
    ok = fn -> :ok end
    # The session file reads a dialog: refused before the screen is read.
    open(ctx, "alpha")
    dialog = fn -> {:refused, :dialog} end

    assert {:refused, {:turn, :dialog}} =
             Inlet.reload_plugins(inlet, "alpha", release: @release, turn: dialog)

    open(ctx, "busy", ["--screen", "running"])

    assert {:refused, {:screen, %{state: :running}}} =
             Inlet.reload_plugins(inlet, "busy", release: @release, turn: ok)

    open(ctx, "menu", ["--screen", "menu"], :dialog)

    assert {:refused, {:screen, %{state: :dialog, kind: :menu}}} =
             Inlet.reload_plugins(inlet, "menu", release: @release, turn: ok)

    open(ctx, "draft")
    {:ok, pane} = pane(ctx, "draft")
    assert {:ok, :sent} = Tmux.write(ctx.server, pane, "draft", {:text, "draft"})
    {:ok, _} = screen(ctx, "draft", &match?(%{box: {:text, "draft"}}, &1))
    # The test's own write above went past the probe; the reloads below write nothing.
    assert {:refused, {:screen, %{box: {:text, "draft"}}}} =
             Inlet.reload_plugins(inlet, "draft", release: @release, turn: ok)

    refute_received {:write, _, _}
    assert ScreenStandIn.submitted(ctx.dir) == []
  end

  test "a reload whose result line never comes is unknown, and not typed again", ctx do
    script = ScreenStandIn.write!(ctx.dir, @release, stand_in_idle(), reloaded: false)
    {:ok, _} = Tmux.new_session(ctx.server, "alpha", [script], size: {120, 40})
    {:ok, _} = screen(ctx, "alpha", &(&1.state == :idle))
    inlet = ctx.inlet

    assert {:unknown, {:no_result, {:ok, %{result: nil}}}} =
             Inlet.reload_plugins(inlet, "alpha",
               release: @release,
               turn: fn -> :ok end,
               result: 300
             )

    assert_received {:write, ^inlet, {:text, "/reload-plugins"}}
    assert_received {:write, ^inlet, {:keys, ["Enter"]}}
    refute_received {:write, ^inlet, _}
    assert ScreenStandIn.submitted(ctx.dir) == ["/reload-plugins"]
  end

  # F-232: the stand-in's session file, in 2.1.322's shape, follows its screen, and goes when it
  # exits; written with `session_file: false` it writes none.
  test "the stand-in's session file says what its screen shows, and goes when it exits", ctx do
    config = Path.join(ctx.dir, "config")
    sessions = Path.join(config, "sessions")
    started = System.system_time(:millisecond)

    file = fn ->
      with {:ok, [f]} <- File.ls(sessions),
           {:ok, bytes} <- File.read(Path.join(sessions, f)),
           {:ok, json} <- JSON.decode(bytes),
           do: {:ok, json}
    end

    status = fn s ->
      await(fn ->
        case file.() do
          {:ok, %{"status" => ^s}} = ok -> ok
          other -> {:not_yet, other}
        end
      end)
    end

    open(ctx, "alpha", ["--screen", "menu"], :dialog, config: config)
    assert {:ok, json} = status.("waiting")

    assert %{"pid" => pid, "sessionId" => "stand-in-" <> _, "kind" => "interactive"} = json
    assert %{"version" => @release, "waitingFor" => "dialog open", "procStart" => _} = json
    assert %{"cwd" => _, "startedAt" => at, "updatedAt" => up} = json
    assert at >= started and up >= at

    {:ok, pane} = pane(ctx, "alpha")
    assert {:ok, :sent} = Tmux.write(ctx.server, pane, "alpha", {:keys, ["Enter"]})
    assert {:ok, json} = status.("idle")
    refute Map.has_key?(json, "waitingFor")

    kill(pid)
    assert {:ok, []} = await(fn -> if File.ls(sessions) == {:ok, []}, do: {:ok, []} end)

    open(ctx, "beta", ["--screen", "running"], nil, config: config, session_file: false)
    assert File.ls(sessions) == {:ok, []}
  end

  # F-242, from F-238's new-1: the stand-in stopped (SIGSTOP) for 3 s as the press goes, as a
  # loaded host stops the real program. Its keys wait in the pane, and it redraws once it runs
  # again. At the library's 2 s `see:` that press is unknown and no Enter goes; at the tree's
  # 10 s (`Config`'s `press_see`) the same press is answered, inside its `press_bound/1`.
  test "a press whose redraw comes past 2 s is answered within the tree's see", ctx do
    late = fn name, see ->
      probe = %Probe{inner: ctx.server, test: self()}
      inlet = start_supervised!({Inlet, tmux: probe, see: see}, id: name)
      dir = Path.join(ctx.dir, name)
      File.mkdir_p!(dir)
      script = ScreenStandIn.write!(dir, @release, stand_in_idle(), trust: true)
      # Under a shell of its own: tmux sends SIGCONT to a pane's own process that stops, as
      # Sessions' dtach holds the program a step away from tmux.
      argv = [program!(:bash), "-c", ~s("$0"; :), script]
      {:ok, _} = Tmux.new_session(ctx.server, name, argv, size: {120, 40})
      {:ok, _} = screen(ctx, name, &match?(%{state: :dialog, kind: :trust}, &1))
      [pid] = File.ls!(Path.join(dir, "pids"))
      {:ok, %{status: 0}} = kill(pid, "-STOP")
      spawn(fn -> receive after: (3_000 -> kill(pid, "-CONT")) end)

      {took, answer} =
        :timer.tc(fn -> Inlet.choose(inlet, name, :trust, @trust, press(inlet)) end)

      {div(took, 1_000), answer, dir}
    end

    {_, answer, dir} = late.("early", 2_000)
    assert {:unknown, {:not_selected, {:ok, %{selected: "No, exit"}}}} = answer
    refute_received {:write, _, {:keys, ["Enter"]}}
    {:ok, _} = screen(ctx, "early", &match?(%{state: :dialog, selected: @trust}, &1))
    refute File.exists?(Path.join(dir, "trusted"))

    {took, answer, dir} = late.("late", 10_000)
    assert {{:ok, :sent}, true} = {answer, took >= 3_000}
    assert_received {:write, _, {:keys, ["Enter"]}}
    assert {:ok, _} = await(fn -> File.read(Path.join(dir, "trusted")) end)
  end

  # F-242, from F-238's new-2: "No, exit" ends the stand-in, and its pane goes with it. The
  # pane gone is the dialog left: the press is answered then, not at the end of its `see:`.
  test "a press whose pane closes is answered as soon as the pane is gone", ctx do
    script = ScreenStandIn.write!(ctx.dir, @release, stand_in_idle(), trust: true)
    {:ok, _} = Tmux.new_session(ctx.server, "alpha", [script], size: {120, 40})
    {:ok, _} = screen(ctx, "alpha", &match?(%{state: :dialog, kind: :trust}, &1))
    inlet = start_supervised!({Inlet, tmux: ctx.server, see: 30_000}, id: :thirty)

    {took, answer} =
      :timer.tc(fn -> Inlet.choose(inlet, "alpha", :trust, "No, exit", press(inlet)) end)

    assert {{:ok, :sent}, true} = {answer, div(took, 1_000) < 30_000}

    # Its session was the server's only one, so the server may have gone with it.
    case Tmux.list_panes(ctx.server) do
      {:ok, panes} -> refute Enum.any?(panes, &(&1.tag == "alpha"))
      {:refused, :no_server} -> :ok
    end
  end

  # A press's options: the instance's own bound, asked of it (F-245).
  defp press(inlet) do
    {:ok, bound} = Inlet.press_bound(inlet)
    [release: @release, timeout: bound]
  end

  defp open(ctx, name, args \\ [], state \\ nil, opts \\ []) do
    script =
      ScreenStandIn.write!(
        ctx.dir,
        @release,
        stand_in_idle(),
        Keyword.take(opts, [:session_file])
      )

    script = if config = opts[:config], do: with_config(script, config), else: script
    {:ok, _} = Tmux.new_session(ctx.server, name, [script | args], size: {120, 40})
    {:ok, _} = screen(ctx, name, &(&1.state in if(state, do: [state], else: [:idle, :running])))
  end

  # The stand-in run with `CLAUDE_CONFIG_DIR` set, as `Sessions` starts it.
  defp with_config(script, config) do
    path = "#{script}-#{System.unique_integer([:positive])}"

    File.write!(
      path,
      "#!#{program!(:bash)}\nCLAUDE_CONFIG_DIR='#{config}' exec '#{script}' \"$@\"\n"
    )

    File.chmod!(path, 0o755)
    path
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
