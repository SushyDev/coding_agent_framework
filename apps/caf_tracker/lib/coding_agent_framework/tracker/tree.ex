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
    its subagents (each with Claude Code's `agent_id`) are that transcript's. A subagent has its
    `agent_id` from its start, from its own file's meta (F-237), and its `tool`, the newest
    call of its own file not yet ended while it runs (`state` `:open` or `:background`);
    `not_read` is `:finished` for one whose file was not read, it having ended before the
    first read, and `partial` is true when the first read took only the file's last part.
  - **What it does now** (F-235): `tool`, the call it runs now (`%{name, id, started_at}`),
    the newest call its transcript started and has not ended while it is `working`, else nil;
    and `last_event_at`, the newer of its transcript's last entry and its newest `Intake` row
    (ms), or nil. `tool_calls/3` answers its recent calls. `partial` is true when its
    transcript's first read took only the file's last part (F-244): calls and subagents started
    before that part are absent, and a subagent the fold knows only from its file's meta has its
    `type` and `description` from the meta and no `started_at`.

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
    ev = Map.put(ev, :hooks, hooks(entries.(:events)))
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
    |> Map.merge(activity(full, state, ev))
  end

  # The path the transcripts' source read, never one built from the cwd: nil until it has one.
  defp transcript(%{path: path}) when is_binary(path), do: path
  defp transcript(_), do: nil

  defp activity(row, state, ev) do
    t = ev.transcripts[key(row)] || %{}

    %{
      tool: if(state == "working", do: open_call(t[:tools])),
      last_event_at: newer(int(t[:last_event_at]), ev.hooks[key(row)]),
      partial: t[:partial] == true
    }
  end

  # A subagent runs a call while it has not ended, as an agent row does while it is `working`.
  defp running(%{state: state, agent_id: agent}, tools)
       when state in [:open, :background] and is_binary(agent),
       do: open_call(tools[agent])

  defp running(_subagent, _tools), do: nil

  defp open_call(calls) when is_list(calls) do
    case Enum.find(calls, &(is_map(&1) and is_nil(&1[:ended_at]))) do
      nil -> nil
      call -> Map.take(call, [:name, :id, :started_at])
    end
  end

  defp open_call(_), do: nil

  # Each agent's newest `Intake` row, by `{account, session_id}`.
  defp hooks(entries) do
    for %{row: r} <- entries,
        is_binary(r[:session_id]),
        is_integer(r[:written_at]),
        reduce: %{} do
      acc -> Map.update(acc, key(r), r.written_at, &max(&1, r.written_at))
    end
  end

  defp newer(nil, b), do: b
  defp newer(a, nil), do: a
  defp newer(a, b), do: max(a, b)

  defp int(n) when is_integer(n), do: n
  defp int(_), do: nil

  @doc """
  The recent tool calls of `agent` in `view`, newest first, each `%{id, name, started_at,
  ended_at, ms, duration_ms}` (`ended_at` and `ms` nil while it runs): `ms` is the call's result
  less its call in the transcript, so calls sent in one batch each show the batch's wait, and
  `duration_ms` is the call's own time, as Claude Code's `PostToolUse` or `PostToolUseFailure`
  hook reported it to `Intake` (`Intake.Event`), nil for a call with no such row. The two stay
  distinct: `ms` never stands in for `duration_ms`. An agent of the tree by name, or a
  subagent by its `agent_id`. Options: `limit:` (default 50; the transcript keeps at most 200
  per agent, `Transcripts.Fold`) and `host:` to choose among agents of one name on two hosts.
  An agent with no transcript read yet has none. `{:refused, {:not_read, :finished}}` for a
  subagent whose file was not read because it had finished before its first read (F-237),
  `{:refused, :unknown_agent}` for a name no agent or subagent has, `{:refused, :ambiguous}` for one on two hosts with no `host:`.

      iex> alias CodingAgentFramework.Tracker.Tree
      iex> m = %{id: 1, host: "h", name: "main", kind: "main", parent: nil, project: "app",
      ...>   account: "work", session_id: "s0", status: "running"}
      iex> call = %{id: "tu-1", name: "Bash", started_at: 1, ended_at: nil, ms: nil, duration_ms: nil}
      iex> t = %{account: "work", session_id: "s0", tools: [call], agent_tools: %{}}
      iex> view = %{{"h", "agents"} => %{agents: [%{key: 1, row: m}]},
      ...>   {"h", "work"} => %{transcripts: [%{key: 1, row: t}]}}
      iex> Tree.tool_calls(view, "main")
      {:ok, [call]}
      iex> Tree.tool_calls(view, "other")
      {:refused, :unknown_agent}
  """
  @spec tool_calls(map, String.t(), keyword) :: {:ok, [map]} | {:refused, term}
  def tool_calls(view, agent, opts \\ []) when is_map(view) do
    limit = Keyword.get(opts, :limit, 50)
    parts = Enum.filter(Map.values(view), &is_map/1)
    entries = fn kind -> for p <- parts, %{row: %{}} = e <- List.wrap(p[kind]), do: e.row end
    transcripts = for r <- entries.(:transcripts), into: %{}, do: {key(r), r}
    durations = durations(entries.(:events))

    named =
      for r <- entries.(:agents),
          agent?(r),
          r.name == agent,
          opts[:host] in [nil, r[:host]],
          do: r

    case named do
      [row] ->
        {:ok, take(transcripts[key(row)][:tools], limit, durations)}

      [_ | _] ->
        {:refused, :ambiguous}

      [] ->
        found =
          for t <- Map.values(transcripts),
              is_map(t[:agent_tools]),
              c = t.agent_tools[agent],
              do: c

        skipped =
          for t <- Map.values(transcripts),
              is_map(t[:files]),
              %{not_read: reason} when not is_nil(reason) <- [t.files[agent]],
              do: reason

        case {found, skipped} do
          {[calls | _], _} -> {:ok, take(calls, limit, durations)}
          {[], [reason | _]} -> {:refused, {:not_read, reason}}
          {[], []} -> {:refused, :unknown_agent}
        end
    end
  end

  defp take(calls, limit, durations) when is_list(calls) do
    calls
    |> Enum.filter(&is_map/1)
    |> Enum.take(limit)
    |> Enum.map(&Map.put(&1, :duration_ms, durations[&1[:id]]))
  end

  defp take(_, _, _), do: []

  # Each call's own time by `tool_use_id`, from the `PostToolUse` and `PostToolUseFailure` rows
  # `Intake` keeps. A row whose `data` is not that shape gives none.
  defp durations(rows) do
    for %{event: event, data: data} <- rows,
        event in ["PostToolUse", "PostToolUseFailure"],
        is_binary(data),
        {:ok, %{"tool_use_id" => id, "duration_ms" => ms}} <- [JSON.decode(data)],
        is_binary(id) and is_integer(ms) and ms >= 0,
        into: %{},
        do: {id, ms}
  end

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

  defp subagents(%{subagents: %{} = agents} = t) do
    tools = if is_map(t[:agent_tools]), do: t.agent_tools, else: %{}
    files = if is_map(t[:files]), do: t.files, else: %{}

    for(%{} = a <- Map.values(agents), do: a)
    |> Enum.sort_by(&{to_string(&1[:started_at]), to_string(&1[:tool_use_id])})
    |> Enum.map(fn a ->
      file = if is_map(files[a[:agent_id]]), do: files[a[:agent_id]], else: %{}

      Map.merge(Map.take(a, @subagent), %{
        tool: running(a, tools),
        not_read: file[:not_read],
        partial: file[:partial] == true
      })
    end)
  end

  defp subagents(_), do: []
end
