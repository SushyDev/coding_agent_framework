defmodule CodingAgentFramework.Tracker.Background do
  @moduledoc """
  An agent's background commands as the tree shows them (`docs/design.md`, "A background
  command outlives its report"; `model/tla/Background.tla`): pure and total. Each read answers
  `%{count, since, source, groups}`, or `{:unknown, reason}` where no source can know. The tree
  never shows a count of 0 while a command runs that began before the evidence it read.

  - **A headless delegate** reads its `Stream` fold (`source: "stream"`): the commands its log
    started and has not ended (`tasks`), each stamped with the read that saw it start, which is
    `since` for the oldest. No fold is `{:unknown, :no_stream}`.
  - **An interactive session** reads its newest `Stop` input and its session file. Claude Code
    2.1.322 lists in the `Stop` input's `background_tasks` each task in flight, and a command is
    one of type `shell`. The session file says `shell` while a command runs after the turn and
    `idle` once none does, with the time it changed (`status_updated_at`). A file that changed
    after the newest `Stop` says the count now (`source: "session_file"`): `idle` is 0 and
    `shell` at least 1. Otherwise the newest `Stop` says it (`source: "stop"`), and a turn
    running after it may have started more. With neither, it is `{:unknown, :no_stop}`. A `Stop`
    input lists shells long after they ended, so only the file empties it between turns.
  - **No process** (ended, or not running) has none (`source: "process"`): a background command
    is a child of the session's process and ends with it.

  `groups` is what a Linux host read of the agent's process groups
  (`StuckBackgrounds.Groups`): how many it leads, `{:unknown, reason}` (`:no_proc` on macOS),
  or nil when none was asked. It decides nothing: a group may be an MCP server.

      iex> alias CodingAgentFramework.Tracker.Background
      iex> stop = %{written_at: 10, data: ~s({"background_tasks":[{"id":"b1","type":"shell"}]})}
      iex> Background.interactive(%{alive: :live, status: "busy", status_updated_at: 20}, [stop])
      %{count: 1, since: 10, source: "stop", groups: nil}
      iex> Background.interactive(%{alive: :live, status: "idle", status_updated_at: 30}, [stop])
      %{count: 0, since: nil, source: "session_file", groups: nil}
  """

  @type t ::
          %{
            count: non_neg_integer,
            since: integer | nil,
            source: String.t(),
            groups: non_neg_integer | {:unknown, term} | nil
          }
          | {:unknown, term}

  @doc "None: no process of the agent runs."
  @spec none() :: t
  def none, do: shown(0, nil, "process")

  @doc """
  A headless delegate's, from its `Stream` fold as the view holds it, or nil.

      iex> alias CodingAgentFramework.Tracker.Background
      iex> Background.headless(%{gone: false, tasks: %{"b1" => %{at: 5}, "b2" => %{at: 7}}})
      %{count: 2, since: 5, source: "stream", groups: nil}
      iex> Background.headless(nil)
      {:unknown, :no_stream}
  """
  @spec headless(map | nil) :: t
  def headless(nil), do: {:unknown, :no_stream}
  def headless(%{gone: true}), do: none()

  def headless(%{} = fold) do
    tasks = if is_map(fold[:tasks]), do: Map.values(fold.tasks), else: []
    ats = for %{at: at} <- tasks, is_integer(at), do: at
    shown(length(tasks), if(ats != [], do: Enum.min(ats)), "stream")
  end

  @doc """
  An interactive session's, from its session file (`Sessions.Turn.file/2`'s, or nil) and its
  `Stop` rows as `Intake` keeps them (`written_at`, `data`), in any order.
  """
  @spec interactive(map | nil, [map]) :: t
  def interactive(file, stops) do
    stops = for %{written_at: at} = row <- stops, is_integer(at), do: {at, shells(row[:data])}
    newest = Enum.max_by(stops, &elem(&1, 0), fn -> nil end)
    file = if is_map(file), do: file, else: %{}

    case {file[:alive], file[:status], newest} do
      {alive, _, _} when alive in [:gone, :replaced] ->
        none()

      {:live, status, _} when status in ["idle", "shell"] ->
        cond do
          after?(file[:status_updated_at], newest) ->
            from_file(status, file.status_updated_at, newest, stops)

          newest == nil ->
            {:unknown, :no_stop}

          true ->
            from_stop(newest, stops)
        end

      {_, _, nil} ->
        {:unknown, :no_stop}

      _turn_or_unread ->
        from_stop(newest, stops)
    end
  end

  # The file changed after the newest Stop, or no Stop was kept.
  defp after?(at, nil), do: is_integer(at)
  defp after?(at, {stop_at, _}), do: is_integer(at) and at > stop_at

  defp from_file("idle", _at, _newest, _stops), do: shown(0, nil, "session_file")

  defp from_file("shell", at, newest, stops) do
    case newest do
      {_, [_ | _] = ids} -> shown(length(ids), since(ids, stops) || at, "session_file")
      _none -> shown(1, at, "session_file")
    end
  end

  defp from_stop({_, ids}, stops), do: shown(length(ids), since(ids, stops), "stop")

  # The oldest Stop that listed any command the newest one lists: when the tree first saw it.
  defp since([], _stops), do: nil

  defp since(ids, stops) do
    stops
    |> Enum.filter(fn {_, listed} -> Enum.any?(listed, &(&1 in ids)) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.min(fn -> nil end)
  end

  # The ids of the shell tasks a Stop input lists. A body of another shape lists none.
  defp shells(data) when is_binary(data) do
    case JSON.decode(data) do
      {:ok, %{"background_tasks" => tasks}} when is_list(tasks) ->
        for %{"id" => id, "type" => "shell"} <- tasks, is_binary(id), do: id

      _ ->
        []
    end
  end

  defp shells(_), do: []

  @doc """
  Adds a host's read of the agent's process groups (`StuckBackgrounds.Groups.read/3`'s answer)
  to a count. An unknown count stays unknown.

      iex> alias CodingAgentFramework.Tracker.Background
      iex> Background.groups(Background.none(), {:unknown, :no_proc}).groups
      {:unknown, :no_proc}
  """
  @spec groups(t, {:ok, list} | {:unknown, term}) :: t
  def groups(%{} = shown, {:ok, groups}) when is_list(groups),
    do: %{shown | groups: length(groups)}

  def groups(%{} = shown, {:unknown, why}), do: %{shown | groups: {:unknown, why}}
  def groups(%{} = shown, other), do: %{shown | groups: {:unknown, {:unreadable, other}}}
  def groups(unknown, _answer), do: unknown

  defp shown(count, since, source),
    do: %{count: count, since: since, source: source, groups: nil}
end
