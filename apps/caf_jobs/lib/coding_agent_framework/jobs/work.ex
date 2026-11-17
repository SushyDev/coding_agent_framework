defmodule CodingAgentFramework.Jobs.Work do
  @moduledoc """
  Whether a job's work has ended, as its owner answers the `Scheduler` about the lease that
  admitted it (`model/tla/Schedule.tla`'s `work`). The lease names the job's row in `Jobs`'
  table, written `asked` before the lease is asked for, as `{"job", id}`. A pure module over a
  connection of its own to that table, so the `Scheduler` never waits on `Jobs`' process, and
  a run waiting for its lease never waits on the `Scheduler`'s.

  The work is `:live` while its row is `asked`, `starting` or `running`: it may still start, or
  runs on its host. It has `:ended` once the row holds the end `Jobs` read from the host
  (`exited`, `timedout`, `lost`, by `Holder.Process`'s record), or says nothing ran (`refused`,
  `interrupted`). After a restart a row `starting` or `running` stays live until `Jobs` settles
  it from its host. A row that does not exist never runs anything: ended.

      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> {:ok, work} = CodingAgentFramework.Jobs.Work.open(dir)
      iex> CodingAgentFramework.Jobs.Work.state(work, "j1")
      :ended
  """

  alias CodingAgentFramework.Jobs.Table

  @enforce_keys [:db]
  defstruct [:db]

  @type t :: %__MODULE__{}

  @live ~w(asked starting running)

  @doc "Opens its own connection to the table in `Jobs`' directory `dir` (`Jobs`' `:dir`)."
  @spec open(String.t()) :: {:ok, t} | {:refused, term}
  def open(dir) do
    with :ok <- mkdir(dir),
         {:ok, db} <- Table.open(Path.join(dir, "jobs.db")),
         do: {:ok, %__MODULE__{db: db}}
  end

  @doc "Whether the work of job `id` is `:live` or has `:ended`."
  @spec state(t, String.t()) :: :live | :ended | {:unknown, term}
  def state(%__MODULE__{db: db}, id) do
    case Table.get(db, id) do
      %{state: state} when state in @live -> :live
      _ended_or_none -> :ended
    end
  rescue
    e -> {:unknown, {:read, Exception.message(e)}}
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:refused, {:dir, reason}}
    end
  end
end
