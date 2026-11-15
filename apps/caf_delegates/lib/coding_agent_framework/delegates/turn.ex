defmodule CodingAgentFramework.Delegates.Turn do
  @moduledoc """
  The pure part of `CodingAgentFramework.Delegates`: a start's checks, its session's name, and
  what a running delegate's `Stream` row says of its turn (`model/tla/Delegate.tla`'s
  `InputWritten` and `StopHandled`, and that its process is gone).

      iex> alias CodingAgentFramework.Delegates.Turn
      iex> Turn.name(%{name: "app"}, "unit/f-1.fix")
      "app-unit-f-1-fix"
      iex> row = %{brief_uuid: "b1", brief: "do it"}
      iex> Turn.next(row, %{gone: false, idle: true, messages: %{}, last_result: nil})
      {:write, "b1", "do it"}
      iex> fold = %{gone: false, idle: true, messages: %{"b1" => %{state: :delivered}},
      ...>   last_result: %{text: "done"}}
      iex> Turn.next(row, fold)
      {:finished, "done"}
  """

  @keys [:branches, :cap]

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
  What a running delegate's `Stream` row (`fold`) says: `{:finished, text}` once the brief is
  delivered and a `result` came after it (the brief's mark ended the turn, and only a result
  begins idle again); `:exited` when its process is gone first; `{:write, uuid, text}` while the
  brief has not gone in, or went undelivered; `:waiting` otherwise.
  """
  @spec next(map, map) ::
          {:finished, String.t()} | :exited | {:write, String.t(), String.t()} | :waiting
  def next(row, fold) do
    {uuid, text} = {row.brief_uuid, row.brief}

    case fold.messages[uuid] do
      %{state: :delivered} when fold.idle and fold.last_result != nil ->
        {:finished, fold.last_result[:text] || ""}

      _ when fold.gone ->
        :exited

      m when m == nil or m.state == :undelivered ->
        {:write, uuid, text}

      _ ->
        :waiting
    end
  end
end
