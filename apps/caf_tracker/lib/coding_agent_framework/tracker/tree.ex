defmodule CodingAgentFramework.Tracker.Tree do
  @moduledoc """
  The tree (`docs/design.md`, "Concepts"), as a pure and total function of the `Tracker`'s view:
  what `agents()` answers. It keeps nothing; each call reads the view it is given.

  Which agents are in it is `Sessions`' rule, `Sessions.Agents.tree/1`, applied to the agent
  rows in the view (`Sessions.Table.meta/0`'s source), the same rule `Grants` reads from the
  table, so the two never disagree on who is an agent, only, for a moment after a write, on
  how fresh their read is (F-99's new-3).

  - **A main session** is a row of kind `main`, with its project and account. Its state is its
    session file's, as `Sessions.Turn.file_state/1` reads it from the view's `Registry` rows
    of its `{host, account}`, the file whose pid and start time are the row's: `working`,
    `waiting`, `idle`, `gone`, `unread`; `starting` while its start is under way and `gone`
    while no process of it may live (`declared`, `stopped`). The view holds no waiter, so this
    is one read, for a person to see, and never what decides a write (F-113's new-2).
  - **A headless delegate**'s state is its `Stream` row's (by session), as
    `Sessions.Turn.stream/1` reads it: `gone`, `waiting` while a `can_use_tool` request is held
    (`waits_on` names each), `working` or `idle`; `starting` while its agent row's start or
    resume is under way, `ended` once no process of it will run again (its start refused, or
    done for good), `unread` with no `Stream` row.
  - **An interactive delegate** (role `parent`) has no `Stream` row: its state is its session
    file's, as a main session's is (F-153's new-6).
  - **A session on a startup dialog** (its row `dialog`, F-140) is `dialog`, never `idle`
    (`Sessions.Turn.interactive/3`), and `waits_on` names the dialog's kind and options (F-180).
  - Each agent's `transcript` is the path its transcript row holds, nil while there is none, and
    its subagents (each with Claude Code's `agent_id`) are that transcript's.

  A delegate that ended keeps its place in the tree, but `agents/2` leaves it out unless asked
  (`all: true`): a busy day ends many (F-129's new-5).

  `stuck` is never answered: nothing reads it yet. A row of the wrong shape is named in
  `problems`, and the others still show. `sources` gives each source's age, `:unread` before
  its first read.

      iex> alias CodingAgentFramework.Tracker.Tree
      iex> m = %{id: 1, host: "h", name: "main", kind: "main", parent: nil, project: "app",
      ...>   account: "work", session_id: nil, status: "running"}
      iex> d = %{id: 2, host: "h", name: "app-fix", kind: "delegate", parent: "main",
      ...>   project: "app", account: "work", status: "running", session_id: "s1", role: "delegate"}
      iex> s = %{session: "s1", gone: false, idle: false, requests: %{}}
      iex> view = %{{"h", "agents"} => %{agents: [%{key: 1, row: m}, %{key: 2, row: d}], sources: %{}},
      ...>   {"h", "stream"} => %{stream: [%{key: 1, row: s}], sources: %{}}}
      iex> %{agents: [main, fix]} = Tree.agents(view)
      iex> {main.kind, fix.state, fix.parent}
      {"main", "working", "main"}
  """

  alias CodingAgentFramework.Sessions.{Agents, Turn}

  @read ["sessions:", "registry:", "stream:", "transcripts:"]
  @subagent [:agent_id, :type, :description, :state, :status, :tokens]

  @doc """
  The tree in `view`: `%{agents: rows, sources: ages, problems: problems}`. Option `all:`
  (false by default) keeps the delegates that ended.
  """
  @spec agents(map, keyword) :: %{agents: [map], sources: map, problems: [map]}
  def agents(view, opts \\ []) when is_map(view) do
    parts = Enum.filter(Map.values(view), &is_map/1)
    entries = fn kind -> for p <- parts, %{row: %{}} = e <- List.wrap(p[kind]), do: e end
    {good, bad} = Enum.split_with(entries.(:agents), &agent?(&1.row))

    streams = for %{row: r} <- entries.(:stream), into: %{}, do: {r[:session], r}
    transcripts = for %{row: r} <- entries.(:transcripts), into: %{}, do: {key(r), r}

    # The session files by `{host, account}`, the scope the view keys them by: a session entry
    # is the fold's own (`Tracker.Fold`), with no row inside it and no scope of its own.
    files =
      for {{_, _} = scope, %{sessions: entries}} <- view,
          is_list(entries),
          into: %{},
          do: {scope, Enum.filter(entries, &is_map/1)}

    full = Map.new(good, &{{&1.row.host, &1.row.name}, &1.row})
    ev = %{streams: streams, transcripts: transcripts, files: files, full: full}
    shown = if opts[:all], do: good, else: Enum.reject(good, &Agents.ended?(&1.row))
    rows = Enum.map(Agents.tree(Enum.map(shown, & &1.row)), &row(&1, ev))

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

  # `entry` is the tree's entry; its full row holds the process the evidence names.
  defp row(entry, ev) do
    full = Map.get(ev.full, {entry.host, entry.name}, entry)
    {state, waits} = state(full, ev)

    Map.merge(Map.take(entry, [:name, :kind, :project, :parent, :account, :session_id, :host]), %{
      state: state,
      waits_on: waits,
      transcript: transcript(ev.transcripts[key(full)]),
      subagents: subagents(ev.transcripts[key(full)])
    })
  end

  # The path the transcripts' source read, never one built from the cwd: nil until it has one.
  defp transcript(%{path: path}) when is_binary(path), do: path
  defp transcript(_), do: nil

  defp state(row, ev) do
    cond do
      Agents.ended?(row) ->
        {"ended", []}

      Agents.starting?(row) ->
        {"starting", []}

      Agents.headless?(row) ->
        stream(ev.streams[row[:session_id]])

      Agents.free?(row) ->
        {"gone", []}

      # No session file exists while a startup dialog is shown: the row is the evidence.
      Turn.interactive(row, [], false) == :dialog ->
        {"dialog", dialog(row)}

      true ->
        {word(Turn.file_state(Turn.file(row, ev.files[{row[:host], row[:account]}] || []))), []}
    end
  end

  defp stream(stream) do
    case Turn.stream(stream) do
      :waiting -> {"waiting", held(stream)}
      turn -> {word(turn), []}
    end
  end

  defp held(stream) do
    requests = if is_map(stream[:requests]), do: stream.requests, else: %{}

    for {id, %{state: :held} = r} <- requests,
        do: %{request: id, tool: r[:tool_name], input: r[:input]}
  end

  defp dialog(row) do
    case Agents.dialog(row) do
      %{kind: kind, options: options} -> [%{dialog: kind, options: options}]
      _unreadable -> []
    end
  end

  # The view's words for a turn state: what a person reads, never what decides a write.
  defp word(:running), do: "working"
  defp word(:waiting), do: "waiting"
  defp word(:gone), do: "gone"
  defp word(:unread), do: "unread"
  defp word(_ended_idle_or_ending), do: "idle"

  defp subagents(%{subagents: %{} = agents}) do
    for(%{} = a <- Map.values(agents), do: a)
    |> Enum.sort_by(&{to_string(&1[:started_at]), to_string(&1[:tool_use_id])})
    |> Enum.map(&Map.take(&1, @subagent))
  end

  defp subagents(_), do: []
end
