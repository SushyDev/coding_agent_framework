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
     text (`see:` ms, 2 000 by default);
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
  # Between two captures while the box is drawn; only spaces the reads.
  @look 20
  # The prompt, its space, and two columns to spare.
  @margin 4

  @type outcome :: {:ok, :sent} | {:refused, term} | {:unknown, term}

  @doc "Starts an `Inlet` for one host's tmux server. `opts`: `tmux:` the server (required)."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :tmux))

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
    call(inlet, request, Keyword.get(opts, :see, @see), opts)
  end

  @doc """
  Answers a dialog of `kind` on `session`'s screen by the option labeled `label` (F-137: a
  start's trust dialog, `:trust` and "Yes, I trust this folder"). In one step of this process:
  the screen is read as the session's release draws it, and must show that dialog; the keys
  that move its selection there (`Screen.option_keys/2`) go as one tmux command; the screen is
  read again until that option is selected (`see:` ms); then Enter, as its own command. Options
  `release:` (required), `see:` and `timeout:`.

  Answers `{:ok, :sent}`; `{:refused, reason}` when no key went: `:no_release`,
  `{:screen, reading}` (another screen, or another dialog), `{:no_option, label}`, or `Tmux`'s;
  `{:unknown, reason}` once a key may have gone: `{:not_selected, reading}` (the keys went and
  the screen never showed the option selected; no Enter went), `{:enter, reason}`.

      iex> {:ok, fake} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(fake, {"laptop", "fake"})
      iex> {:ok, inlet} = CodingAgentFramework.Inlet.start_link(tmux: server)
      iex> CodingAgentFramework.Inlet.choose(inlet, "alpha", :trust, "Yes", release: nil)
      {:refused, :no_release}
  """
  @spec choose(GenServer.server(), String.t(), atom, String.t(), keyword) :: outcome
  def choose(inlet, session, kind, label, opts) do
    request = {:choose, session, kind, label, Keyword.fetch!(opts, :release)}
    call(inlet, request, Keyword.get(opts, :see, @see), opts)
  end

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
  def init(tmux), do: {:ok, %{tmux: tmux}}

  @impl true
  def handle_call({request, see, deadline}, _from, state) do
    # The caller has already answered itself unknown; acting now would act late.
    if System.monotonic_time(:millisecond) >= deadline,
      do: {:reply, {:refused, :expired}, state},
      else: {:reply, act(request, see, state.tmux), state}
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

  defp act({:choose, session, kind, label, release}, see, tmux) do
    with :ok <- if(is_binary(release), do: :ok, else: {:refused, :no_release}),
         {:ok, pane} <- pane(tmux, session),
         {:ok, screen} <- dialog(tmux, pane, session, release, kind),
         {:ok, keys} <- Screen.option_keys(screen, label),
         {:ok, :sent} <- move(tmux, pane, session, keys) do
      deadline = System.monotonic_time(:millisecond) + see

      case selected(tmux, pane, session, release, kind, label, deadline) do
        :selected -> enter(tmux, pane, session)
        {:not_selected, reading} -> {:unknown, {:not_selected, reading}}
      end
    end
  end

  defp dialog(tmux, pane, session, release, kind) do
    with {:ok, %{text: screen}} <- Tmux.capture(tmux, pane, session) do
      case Screen.read(screen, release) do
        {:ok, %{state: :dialog, kind: ^kind} = dialog} -> {:ok, dialog}
        {:ok, reading} -> {:refused, {:screen, reading}}
        {:unknown, {:unrecognized, _}} -> {:refused, {:screen, :unrecognized}}
        {:refused, _} = refused -> refused
      end
    end
  end

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
      match?({:ok, %{state: :dialog, kind: ^kind, selected: ^label}}, reading) ->
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

  defp enter(tmux, pane, session) do
    case Tmux.write(tmux, pane, session, {:keys, ["Enter"]}) do
      {:ok, :sent} -> {:ok, :sent}
      {_, reason} -> {:unknown, {:enter, reason}}
    end
  end
end
