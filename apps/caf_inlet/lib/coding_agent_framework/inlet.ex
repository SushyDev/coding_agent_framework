defmodule CodingAgentFramework.Inlet do
  @moduledoc """
  The checked typed write into an interactive session with no waiter (`docs/design.md`, "The
  parts", "A session with no waiter"; `model/tla/Delivery.tla`'s `typed`). It is `Mailbox`'s
  `typed` transport, and the one writer of text into a session's pane on its host.

  The caller's supervision tree starts one `Inlet` per host, with no name of its own. A write
  names a session, which is also its viewer pane's tag (`Sessions` opens the viewers), and goes
  out only through `Tmux`'s one-command check of that tag (`model/tla/Agent.tla`, `WriteAsked`).

  `type/4` types only into an ended turn, never on one read alone (F-113's new-2). In one step
  of this process it reads both again, then writes:

  1. the turn, by the caller's `turn:` function (`Mailbox` reads `Sessions.Turn` there): it
     answers `:ok` or `{:refused, reason}`;
  2. the screen, captured and read by `Screen` as the session's recorded release draws it: the
     turn ended and the input box empty. A release with no reading refuses the write, and so
     does a session with no recorded release;
  3. the text, typed with no Enter; then the screen again, until the box shows exactly that
     text (`see:` ms, 2 000 by default, or the instance's own `see:`);
  4. Enter, as its own tmux command: text and Enter in one burst read as a paste, and the Enter
     as a newline in the box.

  **The limit.** `Screen` reads a box of more than one line as unrecognized (F-113's new-1),
  since no fixture shows how a release draws a wrapped text. So a text is refused, not typed,
  when it holds a control character (a newline among them) or is longer than the pane's width
  less four columns (the prompt, its space and two to spare). A character drawn two columns
  wide may still wrap a text under the limit; then the box never shows it, and the write is
  unknown with the text in the box, for a person.

  Answers `{:ok, :sent}`; `{:refused, reason}` when nothing was typed; `{:unknown, reason}`
  when something may have been typed: an unknown write is never typed again here. Every call has
  a finite timeout (`:timeout`, 15 s by default); a request still queued when its time is up is
  dropped untyped.

      iex> {:ok, fake} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(fake, {"laptop", "fake"})
      iex> {:ok, inlet} = CodingAgentFramework.Inlet.start_link(tmux: server)
      iex> CodingAgentFramework.Inlet.type(inlet, "alpha", "hi", release: "2.1.322", turn: fn -> :ok end)
      {:refused, :no_server}
      iex> CodingAgentFramework.Inlet.type(inlet, "alpha", "a\\nb", release: "2.1.322", turn: fn -> :ok end)
      {:refused, {:bad_text, :control}}
  """

  use GenServer

  alias CodingAgentFramework.{Screen, Tmux}

  @timeout 15_000
  @see 2_000
  # The tmux commands of one press outside its two reads: the pane's list, the dialog's
  # capture, the keys, Enter and the capture that ends each read. The part of F-140's 20 s
  # bound that two 2 s reads left, kept, so the library's default press bound is unchanged.
  @commands 16_000
  # How long a typed command's result line may take to be drawn: not measured (F-233's new-1).
  @result 10_000
  # Between two captures while the box is drawn; only spaces the reads.
  @look 20
  # The prompt, its space, and two columns to spare.
  @margin 4

  @type outcome :: {:ok, :sent} | {:refused, term} | {:unknown, term}

  @doc """
  Starts an `Inlet` for one host's tmux server. `opts`: `tmux:` the server (required), and
  `see:`, the ms a `type/4` or `choose/5` that names no `see:` of its own waits for the screen
  to show its keys (2 000 by default). A loaded host redraws late: a press whose read back
  passes that bound is unknown, never made again (F-238).
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
  The bound of one `choose/5` at `see` ms (F-242): its two reads, the marker's before Enter and
  the dialog's leaving after it, each up to `see`, and the tmux commands around them. A caller
  that waits on a press (`Sessions`) takes its bound from here, so a longer `see:` is never cut
  by a shorter fixed bound.

      iex> CodingAgentFramework.Inlet.press_bound(2_000)
      20000
      iex> CodingAgentFramework.Inlet.press_bound(10_000)
      36000
  """
  @spec press_bound(pos_integer) :: pos_integer
  def press_bound(see) when is_integer(see) and see > 0, do: 2 * see + @commands

  @doc """
  Types `text` into `session` and then Enter, checked as the module doc says. Options:
  `release:` (required: the Claude Code release the session runs, or nil when none was
  recorded), `turn:` (required: a function read in the write's step, `:ok` when the turn has
  ended), `see:` and `timeout:` (ms).

  Refusals: `{:bad_text, :empty | :control}`, `{:too_long, limit}`, `:no_release`,
  `{:unknown_release, release}`, `{:turn, reason}`, `{:screen, reading}` (the screen read but not
  idle with an empty box, or `:unrecognized`), and `Tmux`'s (`:no_pane`, `{:tagged_for, other}`,
  `:no_server`). Unknown: `{:not_seen, reading}` (typed, and the box never showed it; no Enter
  went), `{:enter, reason}` (typed and seen, the Enter's outcome not known), or `Tmux`'s.
  """
  @spec type(GenServer.server(), String.t(), String.t(), keyword) :: outcome
  def type(inlet, session, text, opts) do
    request = {:type, session, text, Keyword.fetch!(opts, :release), Keyword.fetch!(opts, :turn)}
    call(inlet, request, Keyword.get(opts, :see), opts)
  end

  @doc """
  Answers a dialog of `kind` on `session`'s screen by the option labeled `label`: the checked
  press of a start's dialog (F-140, `model/tla/Dialog.tla`'s `Press`), which `Sessions` makes
  for a person's answer or the app's. In one step of this process: the screen is read as the
  session's release draws it, and must show that dialog; the keys that move its selection
  there (`Screen.option_keys/2`) go as one tmux command; the screen is read again until that
  option is selected (`see:` ms); then Enter, as its own command; then the screen again, until
  that dialog has left (`see:` ms). A pane gone after the Enter or the Escape (`Tmux` refuses
  its capture `:no_pane`, or `:no_server` once its server went with it) is the dialog left, and
  answers at once: "No, exit" ends the program and its pane (F-242, from F-238's new-2).
  Options `release:` (required), `see:` and `timeout:`; `press_bound/1` is the `timeout:` that
  covers a press at a `see:`.

  Answers `{:ok, :sent}` once the dialog has left; `{:refused, reason}` when no key went:
  `:no_release`, `{:screen, reading}` (another screen, or another dialog), `{:no_option,
  label}`, or `Tmux`'s; `{:unknown, reason}` once a key may have gone: `{:not_selected,
  reading}` (the keys went and the screen never showed the option selected; no Enter went),
  `{:enter, reason}`, or `{:still_shown, reading}` (Enter went and the dialog stayed). An
  unknown press is never made again by the caller: its keys may still land.

  A menu no rule names (`Screen`'s kind `:menu`, F-198, `model/tla/Menu.tla`) is named
  `{:menu, title, options}`: the pane must show a menu with that title and those options, and
  the option is read back, the marker on it, before Enter. `label` `:esc` presses Escape in
  place of a choice, checked the same way: the pane shows that dialog, Escape goes as its own
  command, and the dialog leaves; unknown `{:escape, reason}` or `{:still_shown, reading}`.

      iex> {:ok, fake} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(fake, {"laptop", "fake"})
      iex> {:ok, inlet} = CodingAgentFramework.Inlet.start_link(tmux: server)
      iex> CodingAgentFramework.Inlet.choose(inlet, "alpha", :trust, "Yes", release: nil)
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
    call(inlet, request, Keyword.get(opts, :see), opts)
  end

  @doc """
  Interrupts `session`'s running turn by Escape, as a person would (F-142, item 4: an
  interactive delegate's interrupt, which no `Stream` carries). In one step of this process: the
  screen is read as the session's release draws it, and must show a turn running; Escape goes as
  its own tmux command; then the screen is read again until it no longer shows the turn running
  (`see:` ms, 5 000 by default). Options `release:` (required), `see:` and `timeout:`.

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
  owns every write. It goes as `type/4`'s text goes, with the same checks in one step of this
  process: the turn by `turn:`, an idle screen with an empty box, the command typed and seen in
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
    deadline = System.monotonic_time(:millisecond) + timeout

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
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({request, see, deadline}, _from, state) do
    # The caller has already answered itself unknown; acting now would act late.
    if System.monotonic_time(:millisecond) >= deadline,
      do: {:reply, {:refused, :expired}, state},
      else: {:reply, act(request, see || state.see, state.tmux), state}
  end

  defp act({:type, session, text, release, turn}, see, tmux) do
    with :ok <- text?(text),
         :ok <- if(is_binary(release), do: :ok, else: {:refused, :no_release}),
         {:ok, pane} <- pane(tmux, session),
         :ok <- turn(turn),
         {:ok, width} <- empty_box(tmux, pane, session, release),
         :ok <- fits(text, width),
         {:ok, :sent} <- Tmux.write(tmux, pane, session, {:text, text}) do
      expected = String.trim_trailing(text, " ")
      deadline = System.monotonic_time(:millisecond) + see

      case seen(tmux, pane, session, release, expected, deadline) do
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
          ended(tmux, pane, session, release, System.monotonic_time(:millisecond) + see)

        {:refused, _} = refused ->
          refused

        {:unknown, reason} ->
          {:unknown, {:escape, reason}}
      end
    end
  end

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
         {:ok, _screen} <- dialog(tmux, pane, session, release, kind) do
      case Tmux.write(tmux, pane, session, {:keys, ["Escape"]}) do
        {:ok, :sent} ->
          left(tmux, pane, session, release, kind, System.monotonic_time(:millisecond) + see)

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
         {:ok, screen} <- dialog(tmux, pane, session, release, kind),
         {:ok, keys} <- Screen.option_keys(screen, label),
         {:ok, :sent} <- move(tmux, pane, session, keys) do
      deadline = System.monotonic_time(:millisecond) + see

      with :selected <- selected(tmux, pane, session, release, kind, label, deadline),
           {:ok, :sent} <- enter(tmux, pane, session) do
        left(tmux, pane, session, release, kind, System.monotonic_time(:millisecond) + see)
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

      System.monotonic_time(:millisecond) >= deadline ->
        {:unknown, {:still_shown, reading}}

      true ->
        receive do
        after
          @look -> left(tmux, pane, session, release, kind, deadline)
        end
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

      System.monotonic_time(:millisecond) >= deadline ->
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

      System.monotonic_time(:millisecond) >= deadline ->
        {:not_selected, reading}

      true ->
        receive do
        after
          @look -> selected(tmux, pane, session, release, kind, label, deadline)
        end
    end
  end

  defp text?(text) when not is_binary(text) or text == "", do: {:refused, {:bad_text, :empty}}

  defp text?(text) do
    if String.valid?(text) and not Regex.match?(~r/[\x00-\x1f\x7f]/, text),
      do: :ok,
      else: {:refused, {:bad_text, :control}}
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

      System.monotonic_time(:millisecond) >= deadline ->
        {:not_seen, reading}

      true ->
        receive do
        after
          @look -> seen(tmux, pane, session, release, expected, deadline)
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
