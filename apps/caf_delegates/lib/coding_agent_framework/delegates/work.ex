defmodule CodingAgentFramework.Delegates.Work do
  @moduledoc """
  Whether a delegate's work has ended, as its owner answers the `Scheduler` about the lease
  that admitted it (`model/tla/Schedule.tla`'s `work`; F-134's new-1). The lease names the
  delegate's row in `Delegates`' table, written `starting` before the lease is asked for, as
  `{"delegate", "<host>:<id>"}`. A pure module over connections of its own to `Delegates`'
  table and, through `Sessions.Agents`, to the agent rows, so the `Scheduler` never waits on
  `Delegates`' process, which may be waiting on it.

  The work is `:live` while the row may still start or run a process: `starting`, `resuming`,
  and `running` (a running delegate whose process is gone may be resumed once, under the same
  lease). It has `:ended` once its start was `refused`, or once it is `finished` or `failed`
  and its agent row is free of a process (`Sessions.Agents.free?/1`), or a newer start owns its
  name. A row that does not exist never runs anything: ended.

      {:ok, work} = Delegates.Work.open(path, path, "ws")
      Delegates.Work.state(work, "ws:12")
      #=> :live
  """

  alias CodingAgentFramework.Delegates.Table
  alias CodingAgentFramework.Sessions.Agents

  @enforce_keys [:db, :agents, :host]
  defstruct [:db, :agents, :host]

  @type t :: %__MODULE__{}

  @doc "Opens its own connections: `Delegates`' file and `Sessions`' file, for `host`."
  @spec open(String.t(), String.t(), String.t()) :: {:ok, t} | {:refused, term}
  def open(db, sessions_db, host) do
    with {:ok, conn} <- Table.open_read(db),
         {:ok, agents} <- Agents.open(sessions_db, host),
         do: {:ok, %__MODULE__{db: conn, agents: agents, host: host}}
  end

  @doc "The holder key of row `id` on `host`, as a lease names it."
  @spec key(String.t(), integer) :: String.t()
  def key(host, id), do: "#{host}:#{id}"

  @doc "Whether the work of the row `key` names is `:live` or has `:ended`."
  @spec state(t, String.t()) :: :live | :ended | {:unknown, term}
  def state(%__MODULE__{} = work, key) do
    with {:ok, id} <- parse(work, key) do
      case Table.get(work.db, id) do
        nil -> :ended
        row -> of(work, row)
      end
    end
  end

  defp of(_work, %{status: status}) when status in ~w(starting resuming running), do: :live
  defp of(_work, %{status: "refused"}), do: :ended

  defp of(work, row) do
    latest = Enum.find(Table.latest(work.db, work.host), &(&1.name == row.name))
    agent = Agents.get(work.agents, row.name)

    if latest.id != row.id or Agents.free?(agent), do: :ended, else: :live
  end

  defp parse(work, key) do
    # The id follows the last colon: a host's name may hold one.
    with [_, host, n] <- Regex.run(~r/\A(.*):(\d+)\z/, key),
         true <- host == work.host do
      {:ok, String.to_integer(n)}
    else
      _ -> {:unknown, {:not_mine, key}}
    end
  end
end
