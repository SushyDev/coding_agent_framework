defmodule CodingAgentFramework.Example.Run do
  @moduledoc """
  The process that holds one running example app for a console
  (`CodingAgentFramework.Example.Console`): it starts the tree (`CodingAgentFramework.Example`)
  from a config and keeps it, with the config and readers of the agent rows
  (`Sessions.Agents`) and of the hook events (`Intake.Table`). It is started unlinked, so an error in the shell that typed a command
  never takes the tree down; it traps the tree's exit, so a tree that gave up is a reading, not
  a crash.

      {:ok, run} = Run.start(config)
      Run.parts(run).mcp
      #=> #PID<0.402.0>
  """

  use GenServer

  alias CodingAgentFramework.Example
  alias CodingAgentFramework.Example.Config
  alias CodingAgentFramework.Intake.Table, as: IntakeTable
  alias CodingAgentFramework.Sessions.Agents

  # A first start clones each project's checkout before it answers: minutes, not forever.
  @start 600_000
  @step 5_000

  @doc """
  Starts the tree from `config`. Answers `{:ok, run}`, or the tree's own refusal or unknown
  (`Example.start_link/1`).
  """
  @spec start(Config.t()) :: {:ok, pid} | {:refused, term} | {:unknown, term}
  def start(%Config{} = config) do
    case GenServer.start(__MODULE__, config, timeout: @start) do
      {:ok, run} -> {:ok, run}
      {:error, {tag, _} = answer} when tag in [:refused, :unknown] -> answer
      {:error, {:shutdown, {:failed_to_start_child, key, why}}} -> {:refused, {key, why}}
      {:error, reason} -> {:refused, reason}
    end
  end

  @doc """
  What the console reads: `%{config, agents, intake, parts, down}`, `parts` each part's
  process by its key, `down` nil while the tree runs, else why it ended.
  """
  @spec info(pid) :: map
  def info(run), do: GenServer.call(run, :info, @step)

  @doc "Each part's process, by its key."
  @spec parts(pid) :: %{atom => pid}
  def parts(run), do: info(run).parts

  @doc "Stops the tree and this process."
  @spec stop(pid) :: :ok
  def stop(run), do: GenServer.stop(run, :normal, @start)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    # After the tree, which makes the home and its tables.
    with {:ok, sup} <- Example.start_link(config),
         {:ok, agents} <- Agents.open(Config.path(config, "caf.db"), config.workstation),
         {:ok, intake} <- IntakeTable.open(Config.path(config, "caf.db")) do
      {:ok, %{config: config, agents: agents, intake: intake, sup: sup, down: nil}}
    else
      {:error, reason} -> {:stop, reason}
      other -> {:stop, other}
    end
  end

  @impl true
  def handle_call(:info, _from, s) do
    parts = if s.sup, do: Example.parts(s.sup), else: %{}
    info = %{config: s.config, agents: s.agents, intake: s.intake, parts: parts, down: s.down}
    {:reply, info, s}
  end

  @impl true
  def handle_info({:EXIT, sup, reason}, %{sup: sup} = s),
    do: {:noreply, %{s | sup: nil, down: reason}}

  def handle_info({:EXIT, _other, _reason}, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, %{sup: sup}) when is_pid(sup) do
    ref = Process.monitor(sup)
    Process.exit(sup, :shutdown)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      @start -> :ok
    end
  end

  def terminate(_reason, _s), do: :ok
end
