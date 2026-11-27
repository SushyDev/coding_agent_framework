defmodule CodingAgentFramework.InletTest.Probe do
  @moduledoc """
  A `Tmux` over another one that tells the test each write, and the process that made it: the
  `Inlet` whose task runs the call (F-249), or the process itself.
  """
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
    send(s.test, {:write, writer(), input})
    Tmux.write(s.inner, pane, session, input)
  end

  @doc "The process a call runs for: a task's starter, or the process itself."
  def writer, do: List.first(Process.get(:"$callers", []), self())
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

  # Pasted only into an ended turn (OnlyIntoEndedTurn): the turn and the box are read again in
  # the write's own step, then the paste, into a buffer of its own, then Enter as its own
  # command (F-279).
  test "pastes into an ended turn with an empty box, then Enter on its own", ctx do
    open(ctx, "alpha")
    me = self()

    turn = fn ->
      send(me, {:turn, Probe.writer()})
      :ok
    end

    opts = [release: @release, buffer: "caf-u1", turn: turn]
    assert {:ok, :sent} = Inlet.type(ctx.inlet, "alpha", "hello there", opts)

    inlet = ctx.inlet
    assert_received {:turn, ^inlet}
    assert_received {:write, ^inlet, {:paste, "caf-u1", "hello there"}}
    assert_received {:write, ^inlet, {:keys, ["Enter"]}}
    assert {:ok, ["hello there"]} = submitted(ctx, 1)
  end

  # IntoRunningTurn's guard, and a person's draft left alone (F-113's new-2: never one read).
  test "types nothing when the turn reads otherwise, into a running turn, or over a draft",
       ctx do
    open(ctx, "alpha")
    refused = fn -> {:refused, :running} end

    assert {:refused, {:turn, :running}} =
             Inlet.type(ctx.inlet, "alpha", "one",
               release: @release,
               buffer: "caf-t",
               turn: refused
             )

    # The file says idle, but the screen shows a turn running: the second reading refuses.
    open(ctx, "busy", ["--screen", "running"])

    assert {:refused, {:screen, %{state: :running}}} =
             Inlet.type(ctx.inlet, "busy", "two",
               release: @release,
               buffer: "caf-t",
               turn: fn -> :ok end
             )

    # A draft a person left in the box is not touched.
    {:ok, pane} = pane(ctx, "alpha")
    assert {:ok, :sent} = Tmux.write(ctx.server, pane, "alpha", {:text, "draft"})
    {:ok, _} = screen(ctx, "alpha", &match?(%{box: {:text, "draft"}}, &1))

    assert {:refused, {:screen, %{state: :idle, box: {:text, "draft"}}}} =
             Inlet.type(ctx.inlet, "alpha", "three",
               release: @release,
               buffer: "caf-t",
               turn: fn -> :ok end
             )

    refute_received {:write, _, _}
    assert ScreenStandIn.submitted(ctx.dir) == []
  end

  test "refuses a text it cannot paste, and a release it cannot read", ctx do
    open(ctx, "alpha")
    ok = fn -> :ok end
    opts = [release: @release, buffer: "caf-t", turn: ok]
    long = String.duplicate("a", Tmux.paste_max() + 1)

    assert {:refused, {:too_long, 16_384}} = Inlet.type(ctx.inlet, "alpha", long, opts)

    # An escape could end the paste's bracket early, and the rest would go in as keys.
    assert {:refused, {:bad_text, :control}} =
             Inlet.type(ctx.inlet, "alpha", "a\e[201~\rb", opts)

    assert {:refused, :no_release} =
             Inlet.type(ctx.inlet, "alpha", "hi", Keyword.put(opts, :release, nil))

    assert {:refused, {:unknown_release, "0.0.1"}} =
             Inlet.type(ctx.inlet, "alpha", "hi", Keyword.put(opts, :release, "0.0.1"))

    refute_received {:write, _, _}

    # A text far wider than the 120-column pane goes in whole, folded in the box.
    wide = String.duplicate("b", 3_000)
    assert {:ok, :sent} = Inlet.type(ctx.inlet, "alpha", wide, opts)
    assert {:ok, [^wide]} = submitted(ctx, 1)
  end

  # F-279: a paste keeps its newlines as newlines, so none of them submits the box; the one
  # Enter after it does, once.
  test "a newline inside a text does not submit it early", ctx do
    open(ctx, "alpha")
    opts = [release: @release, buffer: "caf-t", turn: fn -> :ok end]
    text = "one\ntwo\n\n\tthree"
    assert {:ok, :sent} = Inlet.type(ctx.inlet, "alpha", text, opts)
    assert {:ok, ["one\\ntwo\\n\\n\tthree"]} = submitted(ctx, 1)

    # The box is empty again once the stand-in has drawn the turn's end.
    {:ok, _} = screen(ctx, "alpha", &match?(%{state: :idle, box: :empty}, &1))
    assert {:ok, :sent} = Inlet.type(ctx.inlet, "alpha", "four", opts)
    assert {:ok, [_, "four"]} = submitted(ctx, 2)
  end

  # PastesItsOwnText (Agent.tla): two Inlets on one server paste at once, each into a buffer
  # named for its own write, and each pane gets its own text whole.
  test "two pastes to two sessions at once each land whole in their own pane", ctx do
    open(ctx, "alpha")
    open(ctx, "beta")
    other = start_supervised!({Inlet, tmux: ctx.server}, id: :other)
    a = Enum.map_join(1..40, "\n", &"alpha line #{&1}")
    b = Enum.map_join(1..40, "\n", &"beta line #{&1}")
    ok = fn -> :ok end

    [one, two] =
      [{ctx.inlet, "alpha", a, "caf-a"}, {other, "beta", b, "caf-b"}]
      |> Enum.map(fn {inlet, session, text, buffer} ->
        opts = [release: @release, buffer: buffer, turn: ok]
        Task.async(fn -> Inlet.type(inlet, session, text, opts) end)
      end)
      |> Task.await_many(30_000)

    assert {:ok, :sent} = one
    assert {:ok, :sent} = two
    {:ok, lines} = submitted(ctx, 2)
    assert Enum.sort(lines) == Enum.sort([escaped(a), escaped(b)])
  end

  test "a session with no tagged pane, or a server gone, takes nothing" do
    {:ok, fake} = Fake.start_link(key: {"laptop", "fake"})
    server = Fake.new(fake, {"laptop", "fake"})
    inlet = start_supervised!({Inlet, tmux: server}, id: :fake)
    ok = fn -> :ok end
    {:ok, pane} = Tmux.new_session(server, "alpha", [program!(:cat)])
    Fake.set_tag(server, pane, "beta")

    assert {:refused, :no_pane} =
             Inlet.type(inlet, "alpha", "hi", release: @release, buffer: "caf-t", turn: ok)

    {:ok, :killed} = Tmux.kill_server(server)

    assert {:refused, :no_server} =
             Inlet.type(inlet, "alpha", "hi", release: @release, buffer: "caf-t", turn: ok)

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
  # 10 s (`Config`'s `press_see`) the same press is answered, inside its `press_bound/1`. A
  # stopped program draws nothing, so the press settles (F-246) and its keys go while it is
  # stopped: the stop lasts 3 s past the settle.
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
      spawn(fn -> receive after: (Inlet.settle() + 3_000 -> kill(pid, "-CONT")) end)

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

  # F-249, Inlet.tla's Busy: a press queued behind a long one, whose bound no longer fits before
  # its deadline, is answered busy at its last start, while the long one still runs, and never
  # starts. The long one runs to its end. The Inlet's bound is answered meanwhile, outside the
  # queue: the ask `Sessions` makes as it starts.
  test "a press queued behind a long press is busy at its deadline, and never runs", ctx do
    probe = %Probe{inner: ctx.server, test: self()}
    inlet = start_supervised!({Inlet, tmux: probe, see: 5_000}, id: :five_seconds)
    long = dialog(ctx, "long")
    short = dialog(ctx, "short")
    {:ok, before} = screen(ctx, "short", &match?(%{state: :dialog, kind: :trust}, &1))
    [pid] = File.ls!(Path.join(long, "pids"))
    {:ok, %{status: 0}} = kill(pid, "-STOP")
    spawn(fn -> receive after: (3_000 -> kill(pid, "-CONT")) end)
    me = self()

    spawn_link(fn ->
      send(me, {:long, Inlet.choose(inlet, "long", :trust, @trust, press(inlet))})
    end)

    # The long press runs: its keys went, and wait in the stopped program's pane.
    assert_receive {:write, _, {:keys, ["Down"]}}, 10_000
    {:ok, bound} = Inlet.press_bound(inlet)
    assert {:ok, ^bound} = Inlet.press_bound(inlet)

    # A timeout that leaves 1 000 in the queue: its last start passes while the long one runs.
    {took, answer} =
      :timer.tc(
        fn ->
          Inlet.choose(inlet, "short", :trust, @trust, release: @release, timeout: bound + 2_000)
        end,
        :millisecond
      )

    assert {{:refused, :busy}, true} = {answer, took >= 1_000}
    refute_received {:long, _}
    assert_receive {:long, {:ok, :sent}}, 60_000
    assert {:ok, _} = await(fn -> File.read(Path.join(long, "trusted")) end)

    # The short press never ran: its dialog is as it was, and nothing was trusted.
    assert {:ok, ^before} = screen(ctx, "short", &match?(%{state: :dialog}, &1))
    refute File.exists?(Path.join(short, "trusted"))
  end

  # F-249: a write queued behind a short press waits for it and runs, inside its deadline.
  test "a write queued behind a short press still runs", ctx do
    dialog(ctx, "first")
    open(ctx, "alpha")
    inlet = ctx.inlet
    me = self()

    spawn_link(fn ->
      send(me, {:press, Inlet.choose(inlet, "first", :trust, @trust, press(inlet))})
    end)

    # The press runs: its first key went.
    assert_receive {:write, _, {:keys, _}}, 10_000

    assert {:ok, :sent} =
             Inlet.type(inlet, "alpha", "after",
               release: @release,
               buffer: "caf-t",
               turn: fn -> :ok end
             )

    assert_receive {:press, {:ok, :sent}}, 10_000
    assert {:ok, ["after"]} = submitted(ctx, 1)
  end

  # F-246, measured on 2.1.322: the trust dialog is drawn again about 150 ms after its first
  # draw, its selection set back to "No, exit". The stand-in does the same (`redraw: 150`). A
  # Down and Enter sent at its first draw are lost, as on the real program; the Inlet's press,
  # made at once, waits for the dialog to settle, then trusts, each key sent once.
  test "a trust dialog drawn again after its first show is pressed once it settles", ctx do
    start = fn name, redraw ->
      dir = Path.join(ctx.dir, name)
      File.mkdir_p!(dir)
      script = ScreenStandIn.write!(dir, @release, stand_in_idle(), trust: true, redraw: redraw)
      {:ok, _} = Tmux.new_session(ctx.server, name, [script], size: {120, 40})
      {:ok, _} = screen(ctx, name, &match?(%{state: :dialog, kind: :trust}, &1))
      dir
    end

    # Pressed at the first draw, past the Inlet: the marker moves, the Enter is dropped, and
    # the second draw puts the marker back on "No, exit". Its second draw comes at 3 s here, so
    # the keys land before it on a loaded host.
    dir = start.("raw", 3_000)
    {:ok, pane} = pane(ctx, "raw")
    {:ok, :sent} = Tmux.write(ctx.server, pane, "raw", {:keys, ["Down"]})
    {:ok, _} = screen(ctx, "raw", &match?(%{selected: @trust}, &1))
    {:ok, :sent} = Tmux.write(ctx.server, pane, "raw", {:keys, ["Enter"]})
    {:ok, _} = screen(ctx, "raw", &match?(%{state: :dialog, selected: "No, exit"}, &1))
    refute File.exists?(Path.join(dir, "trusted"))

    dir = start.("settled", 150)

    {took, answer} =
      :timer.tc(fn -> Inlet.choose(ctx.inlet, "settled", :trust, @trust, press(ctx.inlet)) end)

    assert {{:ok, :sent}, true} = {answer, div(took, 1_000) >= Inlet.settle()}
    assert {:ok, _} = await(fn -> File.read(Path.join(dir, "trusted")) end)
    assert ScreenStandIn.dialog_keys(dir) == ["down", "enter"]
    inlet = ctx.inlet
    assert_received {:write, ^inlet, {:keys, ["Down"]}}
    assert_received {:write, ^inlet, {:keys, ["Enter"]}}
    refute_received {:write, ^inlet, _}
  end

  # F-246: a dialog that never reads the same for the settle (drawn again every 300 ms, the
  # marker moving each time) takes no key: refused at its bound, `settle/0` past `see:`.
  test "a dialog that never settles is refused at its bound, no key sent", ctx do
    script =
      ScreenStandIn.write!(ctx.dir, @release, stand_in_idle(), trust: true, redraw: {:every, 300})

    {:ok, _} = Tmux.new_session(ctx.server, "alpha", [script], size: {120, 40})
    {:ok, _} = screen(ctx, "alpha", &match?(%{state: :dialog, kind: :trust}, &1))
    probe = %Probe{inner: ctx.server, test: self()}
    inlet = start_supervised!({Inlet, tmux: probe, see: 1_000}, id: :one_second)

    {took, answer} =
      :timer.tc(fn -> Inlet.choose(inlet, "alpha", :trust, @trust, press(inlet)) end)

    assert {:refused, {:unsettled, _}} = answer
    assert div(took, 1_000) >= Inlet.settle() + 1_000
    refute_received {:write, _, _}
    assert ScreenStandIn.dialog_keys(ctx.dir) == []
    assert {:ok, _} = screen(ctx, "alpha", &match?(%{state: :dialog, kind: :trust}, &1))
  end

  # A press's options: the instance's own bound and its wait in the queue (F-245, F-249).
  defp press(inlet) do
    {:ok, bound} = Inlet.press_bound(inlet)
    [release: @release, timeout: Inlet.press_timeout(bound)]
  end

  # A stand-in on its trust dialog in a directory of its own, under a shell of its own as in
  # the test above; answers that directory.
  defp dialog(ctx, name) do
    dir = Path.join(ctx.dir, name)
    File.mkdir_p!(dir)
    script = ScreenStandIn.write!(dir, @release, stand_in_idle(), trust: true)
    argv = [program!(:bash), "-c", ~s("$0"; :), script]
    {:ok, _} = Tmux.new_session(ctx.server, name, argv, size: {120, 40})
    {:ok, _} = screen(ctx, name, &match?(%{state: :dialog, kind: :trust}, &1))
    dir
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

  # A text as the stand-in writes it to `submitted`: each newline as `\n`.
  defp escaped(text), do: String.replace(text, "\n", "\\n")
end
