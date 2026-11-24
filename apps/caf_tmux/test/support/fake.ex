defmodule CodingAgentFramework.Tmux.Fake do
  @moduledoc """
  The `CodingAgentFramework.Tmux` contract in memory, for tests of the parts above `Tmux`.

  It is an `Agent` the caller's supervision tree starts; it passes the same contract tests as
  `CodingAgentFramework.Tmux.CLI`. Like tmux, a server that starts again counts pane ids from
  `%0`, and a write checks the pane's tag and sends in one step.

      iex> {:ok, pid} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(pid, {"laptop", "fake"})
      iex> {:ok, pane} = CodingAgentFramework.Tmux.new_session(server, "alpha", ["/run/bin/cat"])
      iex> CodingAgentFramework.Tmux.write(server, pane, "beta", {:text, "hi"})
      {:refused, {:tagged_for, "alpha"}}
  """

  @behaviour CodingAgentFramework.Tmux

  use Agent

  @enforce_keys [:pid, :key]
  defstruct [:pid, :key, timeout: 5_000]

  @type t :: %__MODULE__{pid: pid, key: CodingAgentFramework.Tmux.key(), timeout: pos_integer}

  @doc "Starts a fake server, down until its first session opens."
  @spec start_link(keyword) :: Agent.on_start()
  def start_link(opts) do
    Keyword.fetch!(opts, :key)

    Agent.start_link(fn ->
      %{up: false, next: 0, starts: 0, panes: %{}, received: %{}, clients: %{}, ticks: 0}
    end)
  end

  @doc "A handle on a started fake."
  @spec new(pid, CodingAgentFramework.Tmux.key()) :: t
  def new(pid, key), do: %__MODULE__{pid: pid, key: key}

  @doc "Test aid: sets or removes (`nil`) a pane's tag, as a test of an untagged pane needs."
  @spec set_tag(t, String.t(), String.t() | nil) :: :ok
  def set_tag(%__MODULE__{} = s, pane, tag),
    do: Agent.update(s.pid, &put_in(&1, [:panes, pane, :tag], tag), s.timeout)

  @doc "Test aid: the program a pane runs, as it opened or was last respawned."
  @spec argv(t, String.t()) :: [String.t()] | nil
  def argv(%__MODULE__{} = s, pane),
    do: Agent.get(s.pid, &get_in(&1, [:panes, pane, :argv]), s.timeout)

  @doc "Test aid: what a pane received, oldest first."
  @spec received(t, String.t()) :: [CodingAgentFramework.Tmux.input()]
  def received(%__MODULE__{} = s, pane),
    do: Agent.get(s.pid, &Enum.reverse(Map.get(&1.received, pane, [])), s.timeout)

  @impl true
  def key(%__MODULE__{key: key}), do: key

  # Each command is one call to the fake's process at its `timeout`.
  @impl true
  def bound(%__MODULE__{timeout: timeout}), do: timeout

  @impl true
  def new_session(%__MODULE__{} = s, session, argv, opts) do
    call(s, fn st ->
      st = if st.up, do: st, else: %{st | up: true, next: 0, starts: st.starts + 1}

      if Enum.any?(st.panes, fn {_, p} -> p.session == session end) do
        {{:refused, {:session_exists, session}}, st}
      else
        pane = "%#{st.next}"
        info = %{session: session, tag: session, argv: argv, size: opts[:size]}
        {{:ok, pane}, %{st | next: st.next + 1, panes: Map.put(st.panes, pane, info)}}
      end
    end)
  end

  @impl true
  def list_panes(%__MODULE__{} = s) do
    call(s, fn
      %{up: false} = st ->
        {{:refused, :no_server}, st}

      st ->
        panes =
          for {pane, p} <- Enum.sort_by(st.panes, fn {id, _} -> pane_number(id) end),
              do: %{pane: pane, session: p.session, tag: p.tag, start: "fake@#{st.starts}"}

        {{:ok, panes}, st}
    end)
  end

  @impl true
  def list_clients(%__MODULE__{} = s) do
    call(s, fn
      %{up: false} = st -> {{:refused, :no_server}, st}
      st -> {{:ok, Enum.sort_by(Map.values(st.clients), & &1.created)}, st}
    end)
  end

  @doc """
  Test aid: a person's terminal attaches to `session` at `tty`, as `tmux attach` does. Its
  creation time counts up from 1 per attach, so a tty attached again is a new client. Answers
  `{:refused, :no_server}` on a server that is down.
  """
  @spec attach(t, String.t(), String.t()) :: :ok | {:refused, :no_server}
  def attach(%__MODULE__{} = s, tty, session) do
    call(s, fn
      %{up: false} = st ->
        {{:refused, :no_server}, st}

      st ->
        client = %{tty: tty, session: session, created: st.ticks + 1}
        {:ok, %{st | ticks: st.ticks + 1, clients: Map.put(st.clients, tty, client)}}
    end)
  end

  @doc "Test aid: the terminal at `tty` detaches."
  @spec detach(t, String.t()) :: :ok
  def detach(%__MODULE__{} = s, tty),
    do: Agent.update(s.pid, &%{&1 | clients: Map.delete(&1.clients, tty)}, s.timeout)

  @impl true
  def write(%__MODULE__{} = s, pane, session, input) do
    guarded(s, pane, session, :sent, fn st ->
      update_in(st.received, &Map.update(&1, pane, [input], fn l -> [input | l] end))
    end)
  end

  @doc "Test aid: sets the screen `capture/3` answers for a pane, empty until set."
  @spec set_screen(t, String.t(), String.t()) :: :ok
  def set_screen(%__MODULE__{} = s, pane, text),
    do: Agent.update(s.pid, &put_in(&1, [:panes, pane, :screen], text), s.timeout)

  @impl true
  def capture(%__MODULE__{} = s, pane, session) do
    call(s, fn st ->
      case st.panes do
        %{^pane => %{tag: ^session} = p} when st.up ->
          {columns, _} = p.size || {80, 24}
          {{:ok, %{text: Map.get(p, :screen, ""), width: columns}}, st}

        _ ->
          {guarded_refusal(st, pane), st}
      end
    end)
  end

  @impl true
  def kill_pane(%__MODULE__{} = s, pane, session),
    do: guarded(s, pane, session, :killed, &%{&1 | panes: Map.delete(&1.panes, pane)})

  @impl true
  def respawn_pane(%__MODULE__{} = s, pane, session, argv),
    do: guarded(s, pane, session, :respawned, &put_in(&1, [:panes, pane, :argv], argv))

  @impl true
  def resize_pane(%__MODULE__{} = s, pane, session, size),
    do: guarded(s, pane, session, :resized, &put_in(&1, [:panes, pane, :size], size))

  @doc "Test aid: a pane's window size, as it opened or was last resized."
  @spec size(t, String.t()) :: {pos_integer, pos_integer} | nil
  def size(%__MODULE__{} = s, pane),
    do: Agent.get(s.pid, &get_in(&1, [:panes, pane, :size]), s.timeout)

  # Checks the pane's tag and acts in one step, as the CLI does in one tmux command.
  defp guarded(s, pane, session, done, act) do
    call(s, fn st ->
      case st.panes do
        %{^pane => %{tag: ^session}} when st.up -> {{:ok, done}, act.(st)}
        _ -> {guarded_refusal(st, pane), st}
      end
    end)
  end

  defp guarded_refusal(st, pane) do
    case st.panes do
      _ when not st.up -> {:refused, :no_server}
      %{^pane => %{tag: nil}} -> {:refused, :untagged}
      %{^pane => %{tag: other}} -> {:refused, {:tagged_for, other}}
      _ -> {:refused, :no_pane}
    end
  end

  @impl true
  def kill_session(%__MODULE__{} = s, session) do
    call(s, fn st ->
      gone = for {pane, %{session: ^session}} <- st.panes, do: pane

      cond do
        not st.up -> {{:refused, :no_server}, st}
        gone == [] -> {{:refused, :no_session}, st}
        true -> {{:ok, :killed}, %{st | panes: Map.drop(st.panes, gone)}}
      end
    end)
  end

  @impl true
  def kill_server(%__MODULE__{} = s) do
    call(s, fn
      %{up: false} = st -> {{:refused, :no_server}, st}
      st -> {{:ok, :killed}, %{st | up: false, panes: %{}, clients: %{}}}
    end)
  end

  defp call(%__MODULE__{pid: pid, timeout: timeout}, fun),
    do: Agent.get_and_update(pid, fun, timeout)

  defp pane_number("%" <> n), do: String.to_integer(n)
end
