defmodule CodingAgentFramework.Tracker.Tree do
  @moduledoc """
  The tree (`docs/design.md`, "Concepts"), as a pure and total function of the `Tracker`'s view:
  what `agents()` answers. It keeps nothing; each call reads the view it is given.

  - **A delegate** is the newest start of its name in `Delegates`' rows that holds an agent.
    Its state is its `Stream` row's (by session): `gone`, `waiting` while a `can_use_tool`
    request is held (`waits_on` names each), `working` or `idle`; `starting` while `Delegates`
    starts or resumes it, `unread` with no `Stream` row. Its subagents are its transcript's.
  - **A main session** is, until `Mains` exists, a parent a delegate's row names that is not
    itself a delegate, as `Grants` reads it. Its project is its delegates'. Nothing reads its
    account, state or subagents yet, so its row leaves them out.

  `stuck` is never answered: nothing reads it yet. A delegate row of the wrong shape is named in
  `problems`, and the others still show. `sources` gives each source's age, `:unread` before
  its first read.

      iex> alias CodingAgentFramework.Tracker.Tree
      iex> d = %{id: 1, host: "h", name: "app-fix", parent: "main", project: "app",
      ...>   account: "work", status: "running", session_id: "s1"}
      iex> s = %{session: "s1", gone: false, idle: false, requests: %{}}
      iex> view = %{{"h", "delegates"} => %{delegates: [%{key: 1, row: d}], sources: %{}},
      ...>   {"h", "stream"} => %{stream: [%{key: 1, row: s}], sources: %{}}}
      iex> %{agents: [main, fix]} = Tree.agents(view)
      iex> {main, fix.state, fix.parent}
      {%{name: "main", kind: "main", project: "app", parent: nil}, "working", "main"}
  """

  # The statuses of a start that holds an agent.
  @held ~w(starting running resuming finished failed)
  @read ["delegates:", "stream:", "transcripts:"]
  @subagent [:type, :description, :state, :status, :tokens]

  @doc "The tree in `view`: `%{agents: rows, sources: ages, problems: problems}`."
  @spec agents(map) :: %{agents: [map], sources: map, problems: [map]}
  def agents(view) when is_map(view) do
    parts = Enum.filter(Map.values(view), &is_map/1)
    entries = fn kind -> for p <- parts, %{row: %{}} = e <- List.wrap(p[kind]), do: e end
    {good, bad} = Enum.split_with(entries.(:delegates), &start?(&1.row))

    delegates =
      for(%{row: %{status: s} = r} <- good, s in @held, do: r)
      |> Enum.group_by(&{&1[:host], &1.name})
      |> Enum.map(fn {_, starts} -> Enum.max_by(starts, & &1.id) end)

    streams = for %{row: r} <- entries.(:stream), into: %{}, do: {r[:session], r}
    transcripts = for %{row: r} <- entries.(:transcripts), into: %{}, do: {key(r), r}
    names = MapSet.new(delegates, & &1.name)

    mains =
      for d <- Enum.uniq_by(delegates, & &1.parent),
          not MapSet.member?(names, d.parent),
          do: %{name: d.parent, kind: "main", project: d.project, parent: nil}

    rows = mains ++ Enum.map(delegates, &delegate(&1, streams, transcripts))
    ages = for p <- parts, {t, s} <- Map.get(p, :sources, %{}), do: {t, s[:age]}

    %{
      agents: Enum.sort_by(rows, &{&1.project, &1.kind != "main", &1.name}),
      sources: for({t, age} <- ages, String.starts_with?(t, @read), into: %{}, do: {t, age}),
      problems: for(e <- bad, do: %{key: e.key, problem: :shape})
    }
  end

  defp start?(%{id: id, name: n, parent: p, project: pr, status: s} = row),
    do: is_integer(id) and Enum.all?([n, p, pr, s], &is_binary/1) and is_binary(row[:account])

  defp start?(_), do: false

  defp key(r), do: {r[:account], r[:session_id]}

  defp delegate(d, streams, transcripts) do
    {state, waits} = state(d.status, streams[d[:session_id]])

    Map.merge(Map.take(d, [:name, :project, :parent, :account, :session_id, :host]), %{
      kind: "delegate",
      state: state,
      waits_on: waits,
      subagents: subagents(transcripts[key(d)])
    })
  end

  defp state(status, _) when status in ~w(starting resuming), do: {"starting", []}
  defp state(_, nil), do: {"unread", []}
  defp state(_, %{gone: true}), do: {"gone", []}

  defp state(_, stream) do
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
