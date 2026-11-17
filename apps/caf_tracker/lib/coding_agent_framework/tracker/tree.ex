defmodule CodingAgentFramework.Tracker.Tree do
  @moduledoc """
  The tree (`docs/design.md`, "Concepts"), as a pure and total function of the `Tracker`'s view:
  what `agents()` answers. It keeps nothing; each call reads the view it is given.

  Which agents are in it is `Sessions`' rule, `Sessions.Agents.tree/1`, applied to the agent
  rows in the view (`Sessions.Table.meta/0`'s source), the same rule `Grants` reads from the
  table, so the two never disagree on who is an agent, only, for a moment after a write, on
  how fresh their read is (F-99's new-3).

  - **A main session** is a row of kind `main`, with its project and account. Nothing reads its
    state or subagents yet (its turn state is R9's second part), so its row leaves them out.
  - **A delegate**'s state is its `Stream` row's (by session): `gone`, `waiting` while a
    `can_use_tool` request is held (`waits_on` names each), `working` or `idle`; `starting`
    while its agent row's start or resume is under way, `ended` once no process of it will run
    again (its start refused, or done for good), `unread` with no `Stream` row. Its subagents
    are its transcript's.

  `stuck` is never answered: nothing reads it yet. A row of the wrong shape is named in
  `problems`, and the others still show. `sources` gives each source's age, `:unread` before
  its first read.

      iex> alias CodingAgentFramework.Tracker.Tree
      iex> m = %{id: 1, host: "h", name: "main", kind: "main", parent: nil, project: "app",
      ...>   account: "work", session_id: nil, status: "running"}
      iex> d = %{id: 2, host: "h", name: "app-fix", kind: "delegate", parent: "main",
      ...>   project: "app", account: "work", status: "running", session_id: "s1"}
      iex> s = %{session: "s1", gone: false, idle: false, requests: %{}}
      iex> view = %{{"h", "agents"} => %{agents: [%{key: 1, row: m}, %{key: 2, row: d}], sources: %{}},
      ...>   {"h", "stream"} => %{stream: [%{key: 1, row: s}], sources: %{}}}
      iex> %{agents: [main, fix]} = Tree.agents(view)
      iex> {main.kind, fix.state, fix.parent}
      {"main", "working", "main"}
  """

  alias CodingAgentFramework.Sessions.Agents

  @read ["sessions:", "stream:", "transcripts:"]
  @subagent [:type, :description, :state, :status, :tokens]

  @doc "The tree in `view`: `%{agents: rows, sources: ages, problems: problems}`."
  @spec agents(map) :: %{agents: [map], sources: map, problems: [map]}
  def agents(view) when is_map(view) do
    parts = Enum.filter(Map.values(view), &is_map/1)
    entries = fn kind -> for p <- parts, %{row: %{}} = e <- List.wrap(p[kind]), do: e end
    {good, bad} = Enum.split_with(entries.(:agents), &agent?(&1.row))

    streams = for %{row: r} <- entries.(:stream), into: %{}, do: {r[:session], r}
    transcripts = for %{row: r} <- entries.(:transcripts), into: %{}, do: {key(r), r}
    rows = Enum.map(Agents.tree(Enum.map(good, & &1.row)), &row(&1, streams, transcripts))
    ages = for p <- parts, {t, s} <- Map.get(p, :sources, %{}), do: {t, s[:age]}

    %{
      agents: Enum.sort_by(rows, &{to_string(&1.project), &1.kind != "main", &1.name}),
      sources: for({t, age} <- ages, String.starts_with?(t, @read), into: %{}, do: {t, age}),
      problems: for(e <- bad, do: %{key: e.key, problem: :shape})
    }
  end

  defp agent?(%{id: id, name: n, kind: k, status: s}),
    do: is_integer(id) and is_binary(n) and k in ["main", "delegate"] and is_binary(s)

  defp agent?(_), do: false

  defp key(r), do: {r[:account], r[:session_id]}

  defp row(%{kind: "main"} = m, _streams, _transcripts),
    do: Map.take(m, [:name, :kind, :project, :parent, :account, :host])

  defp row(d, streams, transcripts) do
    {state, waits} = state(d, streams[d[:session_id]])

    Map.merge(Map.take(d, [:name, :kind, :project, :parent, :account, :session_id, :host]), %{
      state: state,
      waits_on: waits,
      subagents: subagents(transcripts[key(d)])
    })
  end

  defp state(d, stream) do
    cond do
      Agents.ended?(d) -> {"ended", []}
      Agents.starting?(d) -> {"starting", []}
      stream == nil -> {"unread", []}
      stream[:gone] == true -> {"gone", []}
      true -> live(stream)
    end
  end

  defp live(stream) do
    requests = if is_map(stream[:requests]), do: stream.requests, else: %{}

    held =
      for {id, %{state: :held} = r} <- requests,
          do: %{request: id, tool: r[:tool_name], input: r[:input]}

    cond do
      held != [] -> {"waiting", held}
      stream[:idle] == false -> {"working", []}
      true -> {"idle", []}
    end
  end

  defp subagents(%{subagents: %{} = agents}) do
    for(%{} = a <- Map.values(agents), do: a)
    |> Enum.sort_by(&{to_string(&1[:started_at]), to_string(&1[:tool_use_id])})
    |> Enum.map(&Map.take(&1, @subagent))
  end

  defp subagents(_), do: []
end
