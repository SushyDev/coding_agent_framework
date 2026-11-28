defmodule CodingAgentFramework.Delegates.Work do
  @moduledoc """
  Whether a delegate's work has ended, as its owner answers the `Scheduler` about the lease
  that admitted it (`model/tla/Schedule.tla`'s `work`; F-134's new-1). The lease names the
  delegate's row in `Delegates`' table, written `starting` before the lease is asked for, as
  `{"delegate", "<host>:<id>"}`. A pure module over connections of its own to `Delegates`'
  table and, through `Sessions.Agents`, to the agent rows, so the `Scheduler` never waits on
  `Delegates`' process, which may be waiting on it.

  The work is `:live` while the row may still start or run a process: `starting`, `resuming`,
  `going_on` (the word to go on after a usage limit), and `running` (a running delegate whose process is gone may be resumed once, under the same
  lease). It has `:ended` once it is `refused`, `finished` or `failed` and its agent row is free
  of a process (`Sessions.Agents.free?/1`), or a newer start owns its name. A refused start is
  read as a finished one is: a start may reach `Sessions` after its row was refused, and its
  process then lives under that row (`Delegate.tla`'s WorkEndedIsFree; F-163's new-1). A row
  that does not exist never runs anything: ended.

  A finished row whose seat is `free` has ended too, though its process idles (F-301,
  `Delegate.tla`'s `seat`): its report is delivered and nothing is due to it, and no row goes in
  to it until a lease is granted again for its next turn (`seated?/2`, which `Mailbox` reads).
  Every lease of the row is then released; one asked for its next turn is live while the seat
  is `asking`, and after.

      {:ok, work} = Delegates.Work.open(path, path, "ws")
      Delegates.Work.state(work, "ws:12")
      #=> :live
  """

  alias CodingAgentFramework.Delegates.Table
  alias CodingAgentFramework.Sessions.Agents

  @enforce_keys [:db, :agents, :host]
  defstruct [:db, :agents, :host]

  @type t :: %__MODULE__{}

  # The seats `Mailbox` puts nothing in through: closed for its check, free, or asked for.
  @unseated ~w(closing free asking)

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

  @doc """
  Whether a row to agent `name` may go in now (F-301, `Delegate.tla`'s `Gated`): false while its
  delegate is finished and its seat is not held (`closing`, `free` or `asking`), true for any
  other row and for a name that is no delegate here. `Mailbox` reads it in the step that marks
  a row, given as its `seated:` function.

      Delegates.Work.seated?(work, "app-unit-review")
      #=> false
  """
  @spec seated?(t, String.t()) :: boolean
  def seated?(%__MODULE__{} = work, name) do
    case Table.latest_of(work.db, work.host, name) do
      %{status: "finished", seat: seat} when seat in @unseated -> false
      _ -> true
    end
  end

  defp of(_work, %{status: status}) when status in ~w(starting resuming going_on running),
    do: :live

  defp of(_work, %{status: "finished", seat: "free"}), do: :ended

  # Refused, finished, failed or ended: no process of it may live once its agent row is free.
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
