defmodule CodingAgentFramework.Delegates.Turn do
  @moduledoc """
  The pure part of `CodingAgentFramework.Delegates`: a start's checks, its session's name, and
  what a running delegate's `Stream` row says of its turn (`model/tla/Delegate.tla`'s
  `InputWritten`, `StopHandled` and `KillSeen`).

      iex> alias CodingAgentFramework.Delegates.Turn
      iex> Turn.name(%{name: "app"}, "unit/f-1.fix")
      "app-unit-f-1-fix"
      iex> row = %{brief_uuid: "b1", resume_uuid: nil, brief: "do it"}
      iex> Turn.next(row, %{gone: false, idle: true, messages: %{}, last_result: nil})
      {:write, "b1", "do it"}
      iex> fold = %{gone: false, idle: true, last_result: nil,
      ...>   messages: %{"b1" => %{state: :delivered, result: %{text: "done"}}}}
      iex> Turn.next(row, fold)
      {:finished, "done"}
  """

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
  The uuid and text of the message the current process's turn waits for: the brief, or after a
  resume whose brief had gone in, `resumed/0` under `resume_uuid`.

      iex> CodingAgentFramework.Delegates.Turn.message(%{brief_uuid: "b1", resume_uuid: nil,
      ...>   brief: "do it"})
      {"b1", "do it"}
  """
  @spec message(map) :: {String.t(), String.t()}
  def message(%{resume_uuid: nil} = row), do: {row.brief_uuid, row.brief}
  def message(row), do: {row.resume_uuid, resumed()}

  @doc """
  What a running delegate's `Stream` row (`fold`) says, read by `Stream.Fold.outcome/2`:
  `{:finished, text}` once the turn's message is delivered and a `result` names it (an earlier
  turn's result, as a resume leaves it, names another uuid);
  `:exited` when its process is gone first; `{:write, uuid, text}` while the message has not
  gone in, or went undelivered; `:waiting` otherwise.
  """
  @spec next(map, map) ::
          {:finished, String.t()} | :exited | {:write, String.t(), String.t()} | :waiting
  def next(row, fold) do
    {uuid, text} = message(row)

    case Fold.outcome(fold, uuid) do
      {:result, %{text: report}} -> {:finished, report}
      _ when fold.gone -> :exited
      outcome when outcome in [:none, :undelivered] -> {:write, uuid, text}
      _ -> :waiting
    end
  end
end
