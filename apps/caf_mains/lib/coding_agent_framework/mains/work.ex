defmodule CodingAgentFramework.Mains.Work do
  @moduledoc """
  Whether a main session's start has ended its work, as its owner answers the `Scheduler` about
  the lease that admitted it (`model/tla/Schedule.tla`'s `work`, as `Delegates.Work` answers for
  a delegate). The lease names the start's row in `Mains.Starts`, written `starting` before the
  lease is asked for, as `{"main", "<host>:<id>"}`. A pure module over connections of its own,
  so the `Scheduler` never waits on `Mains`' process, which may be waiting on it.

  The work is `:live` while the start is under way (`starting`) and while its agent row may hold
  a process or a move of it is under way. It has `:ended` once the start was `refused`, once its
  agent row is free of a process with no move under way (`Sessions.Agents.free?/1`), or once a
  newer start owns its name. A row that does not exist never runs anything: ended.

      {:ok, work} = Mains.Work.open(path, path, "ws")
      Mains.Work.state(work, "ws:3")
      #=> :live
  """

  alias CodingAgentFramework.Mains.Starts
  alias CodingAgentFramework.Sessions.Agents

  @enforce_keys [:db, :agents, :host]
  defstruct [:db, :agents, :host]

  @type t :: %__MODULE__{}

  @doc "Opens its own connections: `Mains`' file and `Sessions`' file, for `host`."
  @spec open(String.t(), String.t(), String.t()) :: {:ok, t} | {:refused, term}
  def open(db, sessions_db, host) do
    with {:ok, conn} <- Starts.open(db),
         {:ok, agents} <- Agents.open(sessions_db, host),
         do: {:ok, %__MODULE__{db: conn, agents: agents, host: host}}
  end

  @doc "The holder key of row `id` on `host`, as a lease names it."
  @spec key(String.t(), integer) :: String.t()
  def key(host, id), do: "#{host}:#{id}"

  @doc "Whether the work of the row `key` names is `:live` or has `:ended`."
  @spec state(t, String.t()) :: :live | :ended | {:unknown, term}
  def state(%__MODULE__{} = work, key) do
    # The id follows the last colon: a host's name may hold one.
    with [_, host, n] <- Regex.run(~r/\A(.*):(\d+)\z/, key),
         true <- host == work.host do
      case Starts.get(work.db, String.to_integer(n)) do
        nil -> :ended
        row -> of(work, row)
      end
    else
      _ -> {:unknown, {:not_mine, key}}
    end
  end

  defp of(_work, %{status: "starting"}), do: :live
  defp of(_work, %{status: "refused"}), do: :ended

  defp of(work, row) do
    latest = Starts.latest(work.db, work.host, row.name)
    agent = Agents.get(work.agents, row.name)

    cond do
      latest.id != row.id -> :ended
      Agents.moving?(agent) -> :live
      Agents.free?(agent) -> :ended
      true -> :live
    end
  end
end
