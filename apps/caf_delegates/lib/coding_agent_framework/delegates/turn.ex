defmodule CodingAgentFramework.Delegates.Turn do
  @moduledoc """
  The pure part of `CodingAgentFramework.Delegates`: a start's checks, its session's name, and
  what a running delegate's `Stream` row says of its turn (`model/tla/Delegate.tla`'s
  `StopHandled` and `KillSeen`).

      iex> alias CodingAgentFramework.Delegates.Turn
      iex> Turn.name(%{name: "app"}, "unit/f-1.fix")
      "app-unit-f-1-fix"
      iex> row = %{brief_uuid: "b1", resume_uuid: nil}
      iex> Turn.next(row, %{gone: false, idle: true, messages: %{}, last_result: nil})
      :waiting
      iex> fold = %{gone: false, idle: true, last_result: nil,
      ...>   messages: %{"b1" => %{state: :delivered, result: %{text: "done"}}}}
      iex> Turn.next(row, fold)
      {:finished, %{text: "done", subtype: nil, is_error: nil}}
  """

  alias CodingAgentFramework.Delegates.Table
  alias CodingAgentFramework.Sessions.Agents
  alias CodingAgentFramework.Stream.Fold

  @keys [:branches, :cap]

  @doc """
  A resumed process's message when its brief went in before the kill: it takes no turn of its
  own (`docs/design.md`, "What `Delegates` holds").
  """
  @spec resumed() :: String.t()
  def resumed,
    do:
      "The framework resumed this session after its process was killed. Go on with your brief " <>
        "from where you stopped, and end with your report."

  @doc """
  Checks a start: the project is one `Delegates` was given, with its branch pattern (a
  `Regex`) and its cap (delegates of one parent at once); the branch matches the pattern.
  `Sessions` checks the rest of the project and that the branch is a plain ref name.
  """
  @spec check(map, String.t(), term) :: {:ok, map} | {:refused, term}
  def check(projects, project, branch) do
    with {:ok, p} <- Map.fetch(projects, project) |> or_refuse({:unknown_project, project}),
         true <- Enum.all?(@keys, &Map.has_key?(p, &1)) or {:refused, {:bad, :project}},
         true <- (is_integer(p.cap) and p.cap > 0) or {:refused, {:bad, :cap}},
         true <-
           (is_binary(branch) and Regex.match?(p.branches, branch)) or
             {:refused, {:bad, :branch}} do
      {:ok, p}
    end
  end

  defp or_refuse(:error, why), do: {:refused, why}
  defp or_refuse(ok, _why), do: ok

  @doc """
  A delegate's session name: its project and branch, each character other than a letter, a
  digit, `_` or `-` as `-`. A later start of the branch so finds its worktree.
  """
  @spec name(map, String.t()) :: String.t()
  def name(project, branch), do: project.name <> "-" <> String.replace(branch, ~r/[^\w-]/, "-")

  @doc """
  What a start of a branch does when its name has a row already (a start idempotent per branch,
  `Delegate.tla`'s `StartAgain`), from the name's latest row and its agent row:

  - `:new`: no delegate of it holds the name (no row, a refused start, or an agent that ended);
  - `:already`: its session is live, so the start answers that delegate and writes nothing;
  - `:again`: a row with no report whose process is gone does not count as running, so a new
    start goes on, and the old row is history, never resumed;
  - `{:refused, reason}` otherwise: `{:starting, name}` while a call of `Sessions` is under way,
    `{:other_parent, name}` for another parent's delegate, and `{:delegate, %{name, status,
    session}}` for one neither live nor gone (a report on its way, a stop under way, a move).

      iex> alias CodingAgentFramework.Delegates.Turn
      iex> row = %{name: "app-unit-a", status: "running", report: "none"}
      iex> Turn.again(row, %{kind: "delegate", parent: "m", status: "running"}, "m")
      :already
      iex> Turn.again(row, %{kind: "delegate", parent: "m", status: "stopped"}, "m")
      :again
      iex> Turn.again(row, %{kind: "delegate", parent: "n", status: "running"}, "m")
      {:refused, {:other_parent, "app-unit-a"}}
  """
  @spec again(map | nil, map | nil, String.t()) ::
          :new | :already | :again | {:refused, term}
  def again(nil, _agent, _parent), do: :new
  def again(%{status: "refused"}, _agent, _parent), do: :new

  def again(row, agent, parent) do
    cond do
      row.status in Table.calling() ->
        {:refused, {:starting, row.name}}

      agent == nil or Agents.ended?(agent) ->
        :new

      agent.parent != parent ->
        {:refused, {:other_parent, row.name}}

      Agents.running?(agent) and not Agents.moving?(agent) ->
        :already

      row.status == "running" and Agents.free?(agent) ->
        :again

      true ->
        {:refused, {:delegate, %{name: row.name, status: row.status, session: agent.status}}}
    end
  end

  @doc """
  The uuid of the message the current process's turn waits for: the brief's, or after a resume
  whose brief had gone in, the word to go on's (`resume_uuid`, whose text is `resumed/0`).

      iex> CodingAgentFramework.Delegates.Turn.uuid(%{brief_uuid: "b1", resume_uuid: nil})
      "b1"
  """
  @spec uuid(map) :: String.t()
  def uuid(%{resume_uuid: nil} = row), do: row.brief_uuid
  def uuid(row), do: row.resume_uuid

  @doc """
  What a running delegate's `Stream` row (`fold`) says, read by `Stream.Fold.outcome/2`:
  `{:finished, result}` once the turn's message is delivered and a `result` names it (an
  earlier turn's result, as a resume leaves it, names another uuid), with its `text`, `subtype`
  and `is_error`; `:exited` when its process is gone first; `:waiting` otherwise. The message
  itself is `Mailbox`'s row, which goes in, and again when found undelivered, by its own rule.
  """
  @spec next(map, map) :: {:finished, map} | :exited | :waiting
  def next(row, fold) do
    case Fold.outcome(fold, uuid(row)) do
      {:result, result} -> {:finished, result}
      _ when fold.gone -> :exited
      _ -> :waiting
    end
  end
end
