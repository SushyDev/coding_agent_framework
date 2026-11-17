defmodule CodingAgentFramework.Example.Ends do
  @moduledoc """
  The owner's end of each agent that ended, in a process of its own: `act` (the app's call of
  `Services.owner_ended/3`) ends the services it owns, which waits on hosts, and a cue runs in
  the part that sends it, so the cue only hands the ids on.

  `ended` is a function of `:all` or a list of agent row ids (`Sessions`' cue) that answers the
  names of the agents among them that have ended (`Sessions.Agents.ended_names/2`). At its start it acts on every agent that has ended,
  since a cue sent while it was down is lost; `owner_ended/3` takes nothing from an owner with
  no running service, so acting twice on one end does nothing more.

      {:ok, ends} = Ends.start_link(ended: &ended/1, act: &Services.owner_ended(services, &1))
      Ends.cue(ends, %{topic: "sessions:ws", ids: [4]})
  """

  use GenServer

  @doc "Starts it. Options: `ended:` and `act:`, as the module's doc says."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @doc "Hands it a `sessions:` cue. Answers `:ok` at once."
  @spec cue(GenServer.server(), map) :: :ok
  def cue(ends, %{ids: ids}) when is_list(ids), do: GenServer.cast(ends, {:ended, ids})
  def cue(_ends, _cue), do: :ok

  @doc "What it reads, for `Cues`: the agent rows' cues."
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(sessions), cue: &cue/2}

  @impl true
  def init(%{ended: _, act: _} = s), do: {:ok, s, {:continue, {:ended, :all}}}

  @impl true
  def handle_continue(ids, s), do: handle_cast(ids, s)

  @impl true
  def handle_cast({:ended, ids}, s) do
    for name <- s.ended.(ids), do: s.act.(name)
    {:noreply, s}
  end
end
