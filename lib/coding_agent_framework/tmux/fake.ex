defmodule CodingAgentFramework.Tmux.Fake do
  @moduledoc """
  The `CodingAgentFramework.Tmux` contract in memory, for tests of the parts above `Tmux`.

  It is an `Agent` the caller's supervision tree starts; it passes the same contract tests as
  `CodingAgentFramework.Tmux.CLI`. Like tmux, a server that starts again counts pane ids from
  `%0`, and a write checks the pane's tag and sends in one step.

      iex> {:ok, pid} = CodingAgentFramework.Tmux.Fake.start_link(key: {"laptop", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(pid, {"laptop", "fake"})
      iex> {:ok, pane} = CodingAgentFramework.Tmux.new_session(server, "alpha", ["/bin/cat"])
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
    Agent.start_link(fn -> %{up: false, next: 0, panes: %{}, received: %{}} end)
  end

  @doc "A handle on a started fake."
  @spec new(pid, CodingAgentFramework.Tmux.key()) :: t
  def new(pid, key), do: %__MODULE__{pid: pid, key: key}

  @doc "Test aid: sets or removes (`nil`) a pane's tag, as a test of an untagged pane needs."
  @spec set_tag(t, String.t(), String.t() | nil) :: :ok
  def set_tag(%__MODULE__{} = s, pane, tag),
    do: Agent.update(s.pid, &put_in(&1, [:panes, pane, :tag], tag), s.timeout)

  @doc "Test aid: what a pane received, oldest first."
  @spec received(t, String.t()) :: [CodingAgentFramework.Tmux.input()]
  def received(%__MODULE__{} = s, pane),
    do: Agent.get(s.pid, &Enum.reverse(Map.get(&1.received, pane, [])), s.timeout)

  @impl true
  def key(%__MODULE__{key: key}), do: key

  @impl true
  def new_session(%__MODULE__{} = s, session, argv, _opts) do
    call(s, fn st ->
      st = if st.up, do: st, else: %{st | up: true, next: 0}

      if Enum.any?(st.panes, fn {_, p} -> p.session == session end) do
        {{:refused, {:session_exists, session}}, st}
      else
        pane = "%#{st.next}"
        info = %{session: session, tag: session, argv: argv}
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
              do: %{pane: pane, session: p.session, tag: p.tag}

        {{:ok, panes}, st}
    end)
  end

  @impl true
  def write(%__MODULE__{} = s, pane, session, input) do
    call(s, fn st ->
      outcome =
        case st.panes do
          _ when not st.up -> {:refused, :no_server}
          %{^pane => %{tag: ^session}} -> {:ok, :sent}
          %{^pane => %{tag: nil}} -> {:refused, :untagged}
          %{^pane => %{tag: other}} -> {:refused, {:tagged_for, other}}
          _ -> {:refused, :no_pane}
        end

      case outcome do
        {:ok, :sent} ->
          {outcome,
           update_in(st.received, &Map.update(&1, pane, [input], fn l -> [input | l] end))}

        _ ->
          {outcome, st}
      end
    end)
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
      st -> {{:ok, :killed}, %{st | up: false, panes: %{}}}
    end)
  end

  defp call(%__MODULE__{pid: pid, timeout: timeout}, fun),
    do: Agent.get_and_update(pid, fun, timeout)

  defp pane_number("%" <> n), do: String.to_integer(n)
end
