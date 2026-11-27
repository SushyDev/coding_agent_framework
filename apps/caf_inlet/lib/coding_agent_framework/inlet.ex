defmodule CodingAgentFramework.Inlet do
  @moduledoc """
  The checked typed write into an interactive session with no waiter (`docs/design.md`, "The
  parts", "A session with no waiter"; `model/tla/Delivery.tla`'s `typed`). It is `Mailbox`'s
  `typed` transport, and the one writer of text into a session's pane on its host.

  The caller's supervision tree starts one `Inlet` per host, with no name of its own. A write
  names a session, which is also its viewer pane's tag (`Sessions` opens the viewers), and goes
  out only through `Tmux`'s one-command check of that tag (`model/tla/Agent.tla`, `WriteAsked`).

  `type/4` types only into an ended turn, never on one read alone (F-113's new-2). In one turn
  of the queue, with no other call between, it reads both again, then writes:

  1. the turn, by the caller's `turn:` function (`Mailbox` reads `Sessions.Turn` there): it
     answers `:ok` or `{:refused, reason}`;
  2. the screen, captured and read by `Screen` as the session's recorded release draws it: the
     turn ended and the input box empty. A release with no reading refuses the write, and so
     does a session with no recorded release;
  3. the text, pasted bracketed with its newlines kept and no Enter (F-279): loaded into a
     tmux buffer named for this write alone (`buffer:`) from stdin, then pasted under the tag
     check, which drops the buffer (`Tmux.write/4`'s `{:paste, buffer, text}`); then the
     screen again, until the box is no longer empty (`see:` ms, 2 000 by default, or the
     instance's own `see:`);
  4. Enter, as its own tmux command, once the paste is drawn: Claude Code takes the paste
     first, so the Enter submits it whole.

  **What the box shows.** Claude Code 2.1.322 draws a long or many-line paste folded, as
  `[Pasted text #1 +N lines]`, and a short one as its text. No fixture of the fold was
  captured, and `Screen` reads a box of more than one line as unrecognized (F-113's new-1). So
  the check after the paste is that the box no longer reads empty: its text, or a screen
  `Screen` cannot read. The box was empty before the paste, so what it holds is the paste.
  The text is confirmed by the transcript's user line, which carries it whole with its mark
  (`Mailbox`'s settle), never by the screen. A text is refused, not pasted, as
  `Tmux.paste_text/1` refuses it: empty, over `Tmux.paste_max/0` bytes, or with a control
  character but newline and tab.

  Answers `{:ok, :sent}`; `{:refused, reason}` when nothing was typed; `{:unknown, reason}`
  when something may have been typed: an unknown write is never typed again here.

  **The queue** (F-249, `model/tla/Inlet.tla`). This process runs the calls on its host one at
  a time, each in a task, so it answers the others while one runs. Every call has a finite
  `timeout:` (15 s by default), and its deadline is that less 1 000, the reply's way back: the
  caller waits the whole `timeout:`, so the `Inlet`'s answer always comes first. A call starts
  only while its own bound still fits before its deadline. A call still queued when that stops
  being so is answered `{:refused, :busy}` at once, and never starts: nothing touched the
  screen. A press's bound is `press_bound/1`; the other calls' bounds are not counted, so each
  starts while its deadline has not passed.

      iex> {:ok, fake} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(fake, {"laptop", "fake"})
      iex> {:ok, inlet} = CodingAgentFramework.Inlet.start_link(tmux: server)
      iex> opts = [release: "2.1.322", turn: fn -> :ok end, buffer: "caf-u1"]
      iex> CodingAgentFramework.Inlet.type(inlet, "alpha", "a\\nb", opts)
      {:refused, :no_server}
      iex> CodingAgentFramework.Inlet.type(inlet, "alpha", "a\\e[201~b", opts)
      {:refused, {:bad_text, :control}}
  """

  use GenServer

  alias CodingAgentFramework.{Screen, Tmux}

  @timeout 15_000
  @see 2_000
  # The tmux commands of one press, counted in `act/3`'s choose (F-245): the pane's list
  # (`pane/2`), the dialog's capture (`dialog/5`), the keys (`move/4`) and Enter (`enter/3`)
  # outside its reads, and the capture each of its three reads may start just before its
  # deadline (`settling/7`, F-246; `selected/7`, `left/6`). An Escape's press runs fewer: the
  # list, the capture, Escape and two reads.
  @commands 7
  # The press's own work between its commands, Screen's reading of each capture, and its
  # reply: not measured.
  @reply 1_000
  # The caller waits its whole `timeout:`; the deadline it hands the queue is this much
  # earlier, for the answer's way back to it. Not measured: a message within one VM.
  @answer 1_000
  # How long a press may wait in the queue behind other calls: a look, a typed line or a short
  # press, each well under a second on a host that answers. Not measured.
  @queue 10_000
  # How long a dialog must read the same before a press's keys go (F-246). 2.1.322 draws a
  # dialog again about 150 ms after its first draw (147 to 214 ms measured, at loads 20 to 47),
  # setting its selection back; a key before then is lost and an Enter dropped, and with no key
  # the second draw changes nothing on the screen. 1 s is over six times the common case and
  # over F-238's x4 for a loaded host.
  @settle 1_000
  # How long a typed command's result line may take to be drawn: not measured (F-233's new-1).
  @result 10_000
  # Between two captures while the box is drawn; only spaces the reads.
  @look 20
  # The prompt, its space, and two columns to spare.
  @margin 4

  @type outcome :: {:ok, :sent} | {:refused, term} | {:unknown, term}

  @doc """
  Starts an `Inlet` for one host's tmux server. `opts`: `tmux:` the server (required), and
  `see:`, the ms each read of a `choose/5`, and of a `type/4` that names no `see:` of its own,
  waits for the screen to show its keys (2 000 by default). This is the one place a press's
  `see` is set (F-245): `press_bound/1` answers the bound that covers it. A loaded host redraws
  late: a press whose read back passes that bound is unknown, never made again (F-238).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    see = Keyword.get(opts, :see, @see)
    GenServer.start_link(__MODULE__, %{tmux: Keyword.fetch!(opts, :tmux), see: see})
  end

  @doc """
  The `see:` an instance takes when it is given none, in ms: 2 000.

      iex> CodingAgentFramework.Inlet.see()
      2000
  """
  @spec see() :: pos_integer
  def see, do: @see

  @doc """
  How long a dialog must read the same before `choose/5` sends its keys, in ms: 1 000 (F-246,
  `model/tla/Press.tla`). Claude Code 2.1.322 draws a dialog again about 150 ms after its first
  draw and sets its selection back to its first option; a press before then is lost, and its
  Enter may confirm that first option. The second draw cannot be read, so only time tells it
  has passed.

      iex> CodingAgentFramework.Inlet.settle()
      1000
  """
  @spec settle() :: pos_integer
  def settle, do: @settle

  @doc """
  The bound of one `choose/5` by an `Inlet` whose `see:` is `see` ms, on a tmux server whose
  one command takes at most `command` ms (`Tmux.bound/1`), F-245: its three reads, each up to
  `see` and the pause between two captures (the settle's, F-246, also up to `settle/0` more;
  then the marker's before Enter and the dialog's leaving after it); the seven tmux commands a
  press runs (the module's `@commands`), each up to `command`; and a margin of 1 000 for the
  press's own work and its reply. The instance answers its own (`press_bound/1`); a caller that
  waits on a press takes its bound from there.

      iex> CodingAgentFramework.Inlet.press_bound_at(10_000, 6_500)
      77560
      iex> CodingAgentFramework.Inlet.press_bound_at(2_000, 6_500)
      53560
  """
  @spec press_bound_at(pos_integer, pos_integer) :: pos_integer
  def press_bound_at(see, command)
      when is_integer(see) and see > 0 and is_integer(command) and command > 0,
      do: 3 * (see + @look) + @settle + @commands * command + @reply

  @doc """
  This instance's press bound: `press_bound_at/2` of its own `see:` and its server's
  `Tmux.bound/1`. `Sessions` asks it once, as it starts, so the reads and the bound come from
  one number, the `Inlet`'s (F-245). This process answers it at once, outside the queue, so
  the ask never waits behind a press (F-249). Answers `{:ok, ms}`, or the call's refusal or
  unknown. Option `timeout:` (15 000 by default).

      iex> {:ok, fake} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(fake, {"laptop", "fake"})
      iex> {:ok, inlet} = CodingAgentFramework.Inlet.start_link(tmux: server, see: 10_000)
      iex> CodingAgentFramework.Inlet.press_bound(inlet)
      {:ok, 67060}
  """
  @spec press_bound(GenServer.server(), keyword) ::
          {:ok, pos_integer} | {:refused, term} | {:unknown, term}
  def press_bound(inlet, opts \\ []), do: call(inlet, :press_bound, nil, opts)

  @doc """
  The `timeout:` a caller of `choose/5` passes, from the press bound `press` (`press_bound/1`),
  F-249: the press itself, up to 10 000 waiting in the queue behind other calls, and the 1 000
  the call keeps for the answer's way back. Past the queue's 10 000 the press is answered
  `{:refused, :busy}` and never made. Pure.

      iex> CodingAgentFramework.Inlet.press_timeout(60_040)
      71040
  """
  @spec press_timeout(pos_integer) :: pos_integer
  def press_timeout(press) when is_integer(press) and press > 0, do: press + @queue + @answer

  @doc """
  Pastes `text` into `session` and then Enter, checked as the module doc says: any number of
  lines, up to `Tmux.paste_max/0` bytes. Options: `release:` (required: the Claude Code release
  the session runs, or nil when none was recorded), `turn:` (required: a function read in the
  write's step, `:ok` when the turn has ended), `buffer:` (required: the tmux buffer's name,
  this write's alone; `Mailbox` names it for the row's uuid), `see:` and `timeout:` (ms).

  Refusals: `Tmux.paste_text/1`'s (`{:bad_text, :empty | :invalid | :control}`, `{:too_long,
  max}`), `{:bad_buffer, name}`, `:no_release`, `{:unknown_release, release}`, `{:turn,
  reason}`, `{:screen, reading}` (the screen read but not idle with an empty box, or
  `:unrecognized`), and `Tmux`'s (`:no_pane`, `{:tagged_for, other}`, `:no_server`, `{:load,
  reason}`, `:no_buffer`). Unknown: `{:not_seen, reading}` (pasted, and the box never showed
  it; no Enter went), `{:enter, reason}` (pasted and seen, the Enter's outcome not known), or
  `Tmux`'s.
  """
  @spec type(GenServer.server(), String.t(), String.t(), keyword) :: outcome
  def type(inlet, session, text, opts) do
    checks = {Keyword.fetch!(opts, :release), Keyword.fetch!(opts, :turn)}
    request = {:type, session, text, checks, Keyword.fetch!(opts, :buffer)}
    call(inlet, request, Keyword.get(opts, :see), opts)
  end

  @doc """
  Answers a dialog of `kind` on `session`'s screen by the option labeled `label`: the checked
  press of a start's dialog (F-140, `model/tla/Dialog.tla`'s `Press`), which `Sessions` makes
  for a person's answer or the app's. In one turn of the queue, with no other call between: the
  screen is read as the session's release draws it, and must show that dialog; it is read again
  until its reading has stayed the same for `settle/0` (up to `see:` ms past it; a reading that
  changes starts the wait again), so a press never goes before the program's second draw of the
  dialog (F-246, `model/tla/Press.tla`); the keys that move its selection there
  (`Screen.option_keys/2`) go as one tmux command; the screen is read again until that option is
  selected (`see:` ms); then Enter, as its own command; then the screen again, until that dialog
  has left (`see:` ms, the instance's own). A pane gone after the Enter or the Escape (`Tmux`
  refuses its capture `:no_pane`, or `:no_server` once its server went with it) is the dialog
  left, and answers at once: "No, exit" ends the program and its pane (F-242, from F-238's
  new-2). Options `release:` and `timeout:` (required): `press_timeout/1` of `press_bound/1` is
  the `timeout:` that covers a press and its wait in the queue. A press takes no `see:` of its
  own, so its reads and its bound come from the instance's one `see:` (F-245).

  Answers `{:ok, :sent}` once the dialog has left; `{:refused, reason}` when no key went:
  `:busy` (its bound no longer fits before its deadline, as the module doc says),
  `:no_release`, `{:screen, reading}` (another screen, or another dialog), `{:unsettled,
  reading}` (the dialog never read the same for `settle/0` within the bound), `{:no_option,
  label}`, or `Tmux`'s; `{:unknown, reason}` once a key may have gone: `{:not_selected,
  reading}` (the keys went and the screen never showed the option selected; no Enter went),
  `{:enter, reason}`, or `{:still_shown, reading}` (Enter went and the dialog stayed). An
  unknown press is never made again by the caller: its keys may still land.

  A menu no rule names (`Screen`'s kind `:menu`, F-198, `model/tla/Menu.tla`) is named
  `{:menu, title, options}`: the pane must show a menu with that title and those options, and
  the option is read back, the marker on it, before Enter. `label` `:esc` presses Escape in
  place of a choice, checked the same way: the pane shows that dialog and settles, Escape goes as its own
  command, and the dialog leaves; unknown `{:escape, reason}` or `{:still_shown, reading}`.

      iex> {:ok, fake} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(fake, {"laptop", "fake"})
      iex> {:ok, inlet} = CodingAgentFramework.Inlet.start_link(tmux: server)
      iex> CodingAgentFramework.Inlet.choose(inlet, "alpha", :trust, "Yes", release: nil, timeout: 60_000)
      {:refused, :no_release}
  """
  @spec choose(
          GenServer.server(),
          String.t(),
          atom | {:menu, String.t(), [String.t()]},
          String.t() | :esc,
          keyword
        ) :: outcome
  def choose(inlet, session, kind, label, opts) do
    request = {:choose, session, kind, label, Keyword.fetch!(opts, :release)}
    call(inlet, request, nil, timeout: Keyword.fetch!(opts, :timeout))
  end

  @doc """
  Interrupts `session`'s running turn by Escape, as a person would (F-142, item 4: an
  interactive delegate's interrupt, which no `Stream` carries). In one turn of the queue, with
  no other call between: the screen is read as the session's release draws it, and must show a
  turn running; Escape goes as its own tmux command; then the screen is read again until it no
  longer shows the turn running (`see:` ms, 5 000 by default). Options `release:` (required), `see:` and `timeout:`.

  Answers `{:ok, :sent}` once the turn has ended; `{:refused, reason}` when no key went:
  `:no_release`, `{:screen, reading}` (no turn runs), or `Tmux`'s; `{:unknown, reason}` once
  the key may have gone: `{:escape, reason}`, or `{:still_running, reading}`.

      iex> {:ok, fake} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(fake, {"laptop", "fake"})
      iex> {:ok, inlet} = CodingAgentFramework.Inlet.start_link(tmux: server)
      iex> CodingAgentFramework.Inlet.interrupt(inlet, "alpha", release: nil)
      {:refused, :no_release}
  """
  @spec interrupt(GenServer.server(), String.t(), keyword) :: outcome
  def interrupt(inlet, session, opts) do
    request = {:interrupt, session, Keyword.fetch!(opts, :release)}
    call(inlet, request, Keyword.get(opts, :see, 5_000), opts)
  end

  @doc """
  Types `/reload-plugins` into `session` and reads its result line (F-233): a person's way to
  load a changed plugin into a running session, which the framework types for them since it
  owns every write. It goes as `type/4`'s text goes, with the same checks in one turn of the
  queue: the turn by `turn:`, an idle screen with an empty box, the command typed and seen in
  the box (`see:` ms), then Enter. Then the screen is read, one capture a call of its own, so
  this process writes for other sessions meanwhile, until `Screen.result/3` shows the command's
  result line under its echo, above a box that is empty again, and the lines above the box
  differ from those read before the command was typed, so a result an earlier reload left is
  never read as this one's (`result:` ms, 10 000 by default). Options `release:` and `turn:`
  (required), `see:`, `result:` and `timeout:` (ms a call, 15 000 by default).

  Answers `{:ok, :reloaded}`; refused as `type/4` is, when nothing was typed (`{:turn,
  reason}`, `{:screen, reading}` for a turn running, a dialog shown or a box not empty); unknown
  as `type/4` is once something may have been typed, and `{:no_result, reading}` when the
  bound passed with no result line. An unknown reload is never typed again here.

      iex> {:ok, fake} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(fake, {"laptop", "fake"})
      iex> {:ok, inlet} = CodingAgentFramework.Inlet.start_link(tmux: server)
      iex> CodingAgentFramework.Inlet.reload_plugins(inlet, "alpha", release: nil, turn: fn -> :ok end)
      {:refused, :no_release}
  """
  @spec reload_plugins(GenServer.server(), String.t(), keyword) ::
          {:ok, :reloaded} | {:refused, term} | {:unknown, term}
  def reload_plugins(inlet, session, opts) do
    text = "/reload-plugins"
    release = Keyword.fetch!(opts, :release)
    request = {:command, session, text, {release, Keyword.fetch!(opts, :turn)}}

    with {:ok, before} <- call(inlet, request, Keyword.get(opts, :see, @see), opts) do
      deadline = now() + Keyword.get(opts, :result, @result)
      result(inlet, {:result, session, release, text}, before, deadline, opts)
    end
  end

  # The result is read by one capture a call, not in the write's step: this process writes for
  # every session on its host, and a command may take seconds to draw its result.
  defp result(inlet, request, before, deadline, opts) do
    reading = call(inlet, request, 0, opts)

    cond do
      match?(
        {:ok, %{result: line, above: above}} when is_binary(line) and above != before,
        reading
      ) ->
        {:ok, :reloaded}

      now() >= deadline ->
        {:unknown, {:no_result, reading}}

      true ->
        receive do
        after
          @look -> result(inlet, request, before, deadline, opts)
        end
    end
  end

  @doc """
  Reads `session`'s screen as `release` draws it (`Screen.read/2`), for a caller that writes
  nothing: `Sessions` reads a starting session's pane for a dialog. Answers `{:ok, screen}`,
  `{:unknown, {:unrecognized, release}}`, or a refusal (`:no_release`, `{:unknown_release,
  release}`, `Tmux`'s). Option `timeout:`.

      iex> {:ok, fake} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(fake, {"laptop", "fake"})
      iex> {:ok, inlet} = CodingAgentFramework.Inlet.start_link(tmux: server)
      iex> CodingAgentFramework.Inlet.look(inlet, "alpha", nil)
      {:refused, :no_release}
  """
  @spec look(GenServer.server(), String.t(), String.t() | nil, keyword) ::
          {:ok, Screen.t()} | {:refused, term} | {:unknown, term}
  def look(inlet, session, release, opts \\ []),
    do: call(inlet, {:look, session, release}, 0, opts)

  defp call(inlet, request, see, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    deadline = now() + timeout - @answer

    try do
      GenServer.call(inlet, {request, see, deadline}, timeout)
    catch
      # An Inlet that is not there typed nothing; one that ended or stalled mid-call may have.
      :exit, {:noproc, _} -> {:refused, :no_inlet}
      :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
      :exit, {reason, _} -> {:unknown, {:exit, reason}}
    end
  end

  @impl true
  def init(state), do: {:ok, Map.merge(state, %{queue: [], running: nil})}

  @impl true
  def handle_call({:press_bound, _see, _deadline}, _from, state),
    do: {:reply, {:ok, press_bound_at(state.see, Tmux.bound(state.tmux))}, state}

  # Queued, with a timer at the last time its bound fits before its deadline.
  def handle_call({request, see, deadline}, from, state) do
    id = make_ref()
    bound = bound(request, state)
    timer = Process.send_after(self(), {:late, id}, max(deadline - bound - now(), 0))
    entry = %{id: id, from: from, request: request, see: see || state.see, timer: timer}
    entry = Map.merge(entry, %{deadline: deadline, bound: bound})
    {:noreply, next(%{state | queue: state.queue ++ [entry]})}
  end

  @impl true
  def handle_info({ref, answer}, %{running: %{ref: ref, from: from}} = state) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, answer)
    {:noreply, next(%{state | running: nil})}
  end

  def handle_info({:late, id}, state) do
    case Enum.split_with(state.queue, &(&1.id == id)) do
      {[entry], rest} ->
        GenServer.reply(entry.from, {:refused, :busy})
        {:noreply, %{state | queue: rest}}

      {[], _} ->
        {:noreply, state}
    end
  end

  # The oldest call's turn. The task is linked, as a call run in this process was: a call that
  # crashes ends the Inlet, and its caller's call answers the exit unknown.
  defp next(%{running: nil, queue: [entry | rest]} = state) do
    Process.cancel_timer(entry.timer)

    if now() + entry.bound <= entry.deadline do
      tmux = state.tmux
      task = Task.async(fn -> act(entry.request, entry.see, tmux) end)
      %{state | queue: rest, running: %{ref: task.ref, from: entry.from}}
    else
      GenServer.reply(entry.from, {:refused, :busy})
      next(%{state | queue: rest})
    end
  end

  defp next(state), do: state

  # A call's own bound: a press's is counted (F-245); the others' are not, so they start
  # while their deadline has not passed.
  defp bound({:choose, _session, _kind, _label, _release}, state),
    do: press_bound_at(state.see, Tmux.bound(state.tmux))

  defp bound(_request, _state), do: 0

  defp act({:type, session, text, {release, turn}, buffer}, see, tmux) do
    with :ok <- Tmux.paste_text(text),
         :ok <- if(is_binary(release), do: :ok, else: {:refused, :no_release}),
         {:ok, pane} <- pane(tmux, session),
         :ok <- turn(turn),
         {:ok, _width} <- empty_box(tmux, pane, session, release),
         {:ok, :sent} <- Tmux.write(tmux, pane, session, {:paste, buffer, text}) do
      case pasted(tmux, pane, session, release, now() + see) do
        :seen -> enter(tmux, pane, session)
        {:not_seen, reading} -> {:unknown, {:not_seen, reading}}
      end
    end
  end

  # A typed command: `type`'s checks and writes. It answers the lines above the box read before
  # the command was typed, which its result is told from.
  defp act({:command, session, text, {release, turn}}, see, tmux) do
    with :ok <- if(is_binary(release), do: :ok, else: {:refused, :no_release}),
         {:ok, pane} <- pane(tmux, session),
         :ok <- turn(turn),
         {:ok, width} <- empty_box(tmux, pane, session, release),
         :ok <- fits(text, width),
         {:ok, %{above: before}} <- read_result(tmux, pane, session, release, text),
         {:ok, :sent} <- Tmux.write(tmux, pane, session, {:text, text}),
         :seen <- seen(tmux, pane, session, release, text, now() + see),
         {:ok, :sent} <- enter(tmux, pane, session) do
      {:ok, before}
    else
      {:not_seen, reading} -> {:unknown, {:not_seen, reading}}
      other -> other
    end
  end

  defp act({:result, session, release, text}, _see, tmux) do
    with {:ok, pane} <- pane(tmux, session),
         do: read_result(tmux, pane, session, release, text)
  end

  # Checked: a turn runs, the press lands, the turn ends.
  defp act({:interrupt, session, release}, see, tmux) do
    with :ok <- if(is_binary(release), do: :ok, else: {:refused, :no_release}),
         {:ok, pane} <- pane(tmux, session),
         :ok <- running(tmux, pane, session, release) do
      case Tmux.write(tmux, pane, session, {:keys, ["Escape"]}) do
        {:ok, :sent} ->
          ended(tmux, pane, session, release, now() + see)

        {:refused, _} = refused ->
          refused

        {:unknown, reason} ->
          {:unknown, {:escape, reason}}
      end
    end
  end

  defp act(:press_bound, see, tmux), do: {:ok, press_bound_at(see, Tmux.bound(tmux))}

  defp act({:look, session, release}, _see, tmux) do
    with :ok <- if(is_binary(release), do: :ok, else: {:refused, :no_release}),
         {:ok, pane} <- pane(tmux, session),
         {:ok, %{text: screen}} <- Tmux.capture(tmux, pane, session) do
      Screen.read(screen, release)
    end
  end

  # Escape on the dialog named: checked shown, then left.
  defp act({:choose, session, kind, :esc, release}, see, tmux) do
    with :ok <- if(is_binary(release), do: :ok, else: {:refused, :no_release}),
         {:ok, pane} <- pane(tmux, session),
         {:ok, screen} <- dialog(tmux, pane, session, release, kind),
         {:ok, _screen} <- settled(tmux, pane, session, release, kind, screen, see) do
      case Tmux.write(tmux, pane, session, {:keys, ["Escape"]}) do
        {:ok, :sent} ->
          left(tmux, pane, session, release, kind, now() + see)

        {:refused, _} = refused ->
          refused

        {:unknown, reason} ->
          {:unknown, {:escape, reason}}
      end
    end
  end

  defp act({:choose, session, kind, label, release}, see, tmux) do
    with :ok <- if(is_binary(release), do: :ok, else: {:refused, :no_release}),
         {:ok, pane} <- pane(tmux, session),
         {:ok, first} <- dialog(tmux, pane, session, release, kind),
         {:ok, screen} <- settled(tmux, pane, session, release, kind, first, see),
         {:ok, keys} <- Screen.option_keys(screen, label),
         {:ok, :sent} <- move(tmux, pane, session, keys) do
      deadline = now() + see

      with :selected <- selected(tmux, pane, session, release, kind, label, deadline),
           {:ok, :sent} <- enter(tmux, pane, session) do
        left(tmux, pane, session, release, kind, now() + see)
      else
        {:not_selected, reading} -> {:unknown, {:not_selected, reading}}
        unknown -> unknown
      end
    end
  end

  # After the Enter, the dialog of `kind` leaves: the pane is read, and shows another screen,
  # another dialog, or one being drawn (unrecognized), or is gone: tmux never gives a pane's id
  # to another, so a pane gone is not one that may still show the dialog. Any other failed
  # capture says nothing.
  defp left(tmux, pane, session, release, kind, deadline) do
    reading =
      with {:ok, %{text: screen}} <- Tmux.capture(tmux, pane, session),
           do: Screen.read(screen, release)

    gone? =
      case reading do
        {:ok, screen} -> not shows?(screen, kind)
        {:unknown, {:unrecognized, _}} -> true
        {:refused, why} when why in [:no_pane, :no_server] -> true
        _ -> false
      end

    cond do
      gone? ->
        {:ok, :sent}

      now() >= deadline ->
        {:unknown, {:still_shown, reading}}

      true ->
        receive do
        after
          @look -> left(tmux, pane, session, release, kind, deadline)
        end
    end
  end

  # Before any key: the dialog read until its reading has stayed the same for @settle, so the
  # program's second draw, which sets the selection back and cannot be read, has passed
  # (`Press.tla`'s Keys). A changed reading starts the wait again, and so does a screen caught
  # mid-draw (unrecognized); another screen refuses, as the first read does; past `see` beyond
  # @settle nothing went, so it is refused too.
  defp settled(tmux, pane, session, release, kind, reading, see) do
    settling(tmux, pane, session, release, kind, {reading, now()}, now() + @settle + see)
  end

  defp settling(tmux, pane, session, release, kind, {reading, since}, deadline) do
    receive do
    after
      @look -> :ok
    end

    next =
      case dialog(tmux, pane, session, release, kind) do
        {:ok, next} -> next
        {:refused, {:screen, :unrecognized}} -> :unrecognized
        refused -> refused
      end

    since = if next == reading, do: since, else: now()

    cond do
      match?({:refused, _}, next) -> next
      next != :unrecognized and now() - since >= @settle -> {:ok, next}
      now() >= deadline -> {:refused, {:unsettled, next}}
      true -> settling(tmux, pane, session, release, kind, {next, since}, deadline)
    end
  end

  defp running(tmux, pane, session, release) do
    with {:ok, %{text: screen}} <- Tmux.capture(tmux, pane, session) do
      case Screen.read(screen, release) do
        {:ok, %{state: :running}} -> :ok
        {:ok, reading} -> {:refused, {:screen, reading}}
        {:unknown, {:unrecognized, _}} -> {:refused, {:screen, :unrecognized}}
        {:refused, _} = refused -> refused
      end
    end
  end

  # After the Escape, the turn ends: the screen shows anything but a turn running.
  defp ended(tmux, pane, session, release, deadline) do
    reading =
      with {:ok, %{text: screen}} <- Tmux.capture(tmux, pane, session),
           do: Screen.read(screen, release)

    cond do
      match?({:ok, %{state: state}} when state != :running, reading) ->
        {:ok, :sent}

      now() >= deadline ->
        {:unknown, {:still_running, reading}}

      true ->
        receive do
        after
          @look -> ended(tmux, pane, session, release, deadline)
        end
    end
  end

  defp dialog(tmux, pane, session, release, kind) do
    with {:ok, %{text: screen}} <- Tmux.capture(tmux, pane, session) do
      case Screen.read(screen, release) do
        {:ok, reading} -> if shows?(reading, kind), do: {:ok, reading}, else: refused(reading)
        {:unknown, {:unrecognized, _}} -> {:refused, {:screen, :unrecognized}}
        {:refused, _} = refused -> refused
      end
    end
  end

  # Whether a reading is the dialog named: a kind a rule names, or a menu by its title and
  # options (`{:menu, title, options}`).
  defp shows?(%{state: :dialog, kind: :menu} = s, {:menu, title, options}),
    do: s.title == title and s.options == options

  defp shows?(%{state: :dialog, kind: kind}, kind) when is_atom(kind), do: true
  defp shows?(_screen, _kind), do: false

  defp refused(reading), do: {:refused, {:screen, reading}}

  defp move(_tmux, _pane, _session, []), do: {:ok, :sent}

  defp move(tmux, pane, session, keys) do
    case Tmux.write(tmux, pane, session, {:keys, keys}) do
      {:ok, :sent} -> {:ok, :sent}
      {:refused, _} = refused -> refused
      {:unknown, reason} -> {:unknown, {:keys, reason}}
    end
  end

  defp selected(tmux, pane, session, release, kind, label, deadline) do
    reading =
      with {:ok, %{text: screen}} <- Tmux.capture(tmux, pane, session),
           do: Screen.read(screen, release)

    cond do
      match?({:ok, %{selected: ^label}}, reading) and shows?(elem(reading, 1), kind) ->
        :selected

      now() >= deadline ->
        {:not_selected, reading}

      true ->
        receive do
        after
          @look -> selected(tmux, pane, session, release, kind, label, deadline)
        end
    end
  end

  # The session's pane is the one its tag names; the writes check that tag again themselves.
  defp pane(tmux, session) do
    with {:ok, panes} <- Tmux.list_panes(tmux) do
      case Enum.find(panes, &match?(%{tag: ^session}, &1)) do
        %{pane: pane} -> {:ok, pane}
        nil -> {:refused, :no_pane}
      end
    end
  end

  defp turn(turn) do
    case turn.() do
      :ok -> :ok
      {:refused, reason} -> {:refused, {:turn, reason}}
      other -> {:refused, {:turn, other}}
    end
  end

  defp empty_box(tmux, pane, session, release) do
    with {:ok, %{text: screen, width: width}} <- Tmux.capture(tmux, pane, session) do
      case Screen.read(screen, release) do
        {:ok, %{state: :idle, box: :empty}} -> {:ok, width}
        {:ok, reading} -> {:refused, {:screen, reading}}
        {:unknown, {:unrecognized, _}} -> {:refused, {:screen, :unrecognized}}
        {:refused, _} = refused -> refused
      end
    end
  end

  defp fits(text, width) do
    limit = width - @margin
    if String.length(text) <= limit, do: :ok, else: {:refused, {:too_long, limit}}
  end

  # The box is drawn after the keys arrive; the screen is read until it shows the text, or the
  # bound passes. Anything else drawn there (a turn started, a paste marker) is not the text.
  defp seen(tmux, pane, session, release, expected, deadline) do
    reading =
      with {:ok, %{text: screen}} <- Tmux.capture(tmux, pane, session),
           do: Screen.read(screen, release)

    cond do
      match?({:ok, %{state: :idle, box: {:text, ^expected}}}, reading) ->
        :seen

      now() >= deadline ->
        {:not_seen, reading}

      true ->
        receive do
        after
          @look -> seen(tmux, pane, session, release, expected, deadline)
        end
    end
  end

  # After the paste, the box no longer reads empty: its text, or a fold or many lines `Screen`
  # cannot read. A turn started, a dialog or an empty box is not the paste drawn.
  defp pasted(tmux, pane, session, release, deadline) do
    reading =
      with {:ok, %{text: screen}} <- Tmux.capture(tmux, pane, session),
           do: Screen.read(screen, release)

    drawn? =
      match?({:ok, %{state: :idle, box: {:text, _}}}, reading) or
        match?({:unknown, {:unrecognized, _}}, reading)

    cond do
      drawn? ->
        :seen

      now() >= deadline ->
        {:not_seen, reading}

      true ->
        receive do
        after
          @look -> pasted(tmux, pane, session, release, deadline)
        end
    end
  end

  defp read_result(tmux, pane, session, release, text) do
    with {:ok, %{text: screen}} <- Tmux.capture(tmux, pane, session),
         do: Screen.result(screen, release, text)
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp enter(tmux, pane, session) do
    case Tmux.write(tmux, pane, session, {:keys, ["Enter"]}) do
      {:ok, :sent} -> {:ok, :sent}
      {_, reason} -> {:unknown, {:enter, reason}}
    end
  end
end
