defmodule CodingAgentFramework.Transcripts.Fold do
  @moduledoc """
  The pure fold of one session's transcript, `<config>/projects/<project>/<session>.jsonl`, a
  line of JSON per entry (Claude Code 2.1.322; sources in `docs/build-notes/F-28.md`).

  It answers the session's last assistant reply, its user prompts with their ids, its
  subagents with their token counts, its own token usage, and the last usage limit a turn of it
  hit (`limit`, below). It is total: a line that is not
  JSON, not an object, of an unknown type or of an odd shape is kept as a problem, and the fold
  goes on.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> line = ~s({"type":"user","uuid":"u1","promptId":"p1","message":{"content":"hi"}})
      iex> {:ok, fold} = Fold.take(Fold.new(), line <> "\\n" <> ~s({"type":"user"))
      iex> {fold.offset, Enum.map(fold.prompts, & &1.prompt_id)}
      {71, ["p1"]}

  **A usage limit** (`docs/design.md`, "Usage limits"; measured on 2.1.322 in F-178 and
  F-181): a turn that hits one writes one assistant line with `isApiErrorMessage: true`,
  `apiError: "usage_limit_reached"` and the account's record in `quotaLimits` (or
  `apiErrorParams.rate_limit_info`). `limit` is the last such line: `record` (that map, as
  `CodingAgentFramework.Usage.Limit.parse/1` reads it), `uuid`, `at` (its `timestamp`),
  `offset`, and `followed`, true once a later line shows a turn ran after it (a prompt, or a
  reply that is not an API error). The line's text is never a reply.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> hit = ~s({"type":"assistant","uuid":"a1","timestamp":"2026-11-21T06:48:44.124Z",) <>
      ...>   ~s("isApiErrorMessage":true,"apiError":"usage_limit_reached",) <>
      ...>   ~s("quotaLimits":{"status":"rejected","resetsAt":1795254036},) <>
      ...>   ~s("message":{"id":"m1","stop_reason":"stop_sequence","content":[]}}\\n)
      iex> {:ok, fold} = Fold.take(Fold.new(), hit)
      iex> {fold.limit.record["resetsAt"], fold.limit.followed}
      {1795254036, false}
      iex> again = ~s({"type":"user","message":{"content":"again"}}\\n)
      iex> {:ok, fold} = Fold.take(Fold.new(), hit <> again)
      iex> fold.limit.followed
      true

  **An interrupt** (F-194): a turn a key ended (Esc, whoever pressed it, or the framework's own
  interrupt) writes a user line whose text is `[Request interrupted by user]`, or `[Request
  interrupted by user for tool use]` when a tool call was under way (both checked by name in
  the 2.1.322 binary). `interrupts` keeps each, oldest first: `uuid`, `at` (ms), `offset`,
  `tool_use`, and `turn_at`, the time of the prompt that opened the turn it ended (nil when
  the fold read none), so a reader can tell whether the framework interrupted that turn.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> go = ~s({"type":"user","timestamp":"2026-11-21T09:00:00.000Z","message":{"content":"go"}}\\n)
      iex> esc = ~s({"type":"user","uuid":"i1","timestamp":"2026-11-21T09:00:05.000Z",) <>
      ...>   ~s("message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}\\n)
      iex> {:ok, fold} = Fold.take(Fold.new(), go <> esc)
      iex> [%{uuid: "i1", tool_use: false, at: at, turn_at: turn_at}] = fold.interrupts
      iex> at - turn_at
      5000

  **Tool calls** (F-235): each `tool_use` block of an assistant entry starts a call and the
  user entry whose `tool_result` names its id ends it. `tools` keeps the session's own calls,
  newest first, each `%{id, name, started_at, ended_at, ms}` (ms of the entries' timestamps;
  `ended_at` and `ms` nil while it runs), at most 200 of them. A sidechain entry's calls are
  its subagent's, kept in `agent_tools` under its `agentId`, never the session's: at most
  200 per subagent and 50 subagents. `last_event_at` is the time of the session's last
  entry. On 2.1.322 the `tool_use` line is in the file when the tool starts, its timestamp a
  second or two before (F-235's measurement).

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> use = ~s({"type":"assistant","timestamp":"2026-11-21T09:00:00.000Z","message":) <>
      ...>   ~s({"id":"m1","content":[{"type":"tool_use","id":"tu-1","name":"Bash"}]}}\\n)
      iex> done = ~s({"type":"user","timestamp":"2026-11-21T09:00:02.500Z","message":) <>
      ...>   ~s({"content":[{"type":"tool_result","tool_use_id":"tu-1"}]}}\\n)
      iex> {:ok, fold} = Fold.take(Fold.new(), use)
      iex> hd(fold.tools).ended_at
      nil
      iex> {:ok, fold} = Fold.take(Fold.new(), use <> done)
      iex> {hd(fold.tools).name, hd(fold.tools).ms}
      {"Bash", 2500}

  **A subagent's own file** (F-237): 2.1.322 writes a subagent's entries to
  `<session id>/subagents/agent-<agent id>.jsonl`, not the main file. `take_file/3` folds it
  into the same fold, with its own offset and seam in `files` (by agent id, with its
  `tool_use_id` and `problem`), and `file_meta/3` reads its `agent-<agent id>.meta.json`, whose
  `toolUseId` gives the parent's call its `agent_id` while the subagent runs.

  **A bounded first read** (F-244): `take_from/2` folds a main file read from inside it, as
  `Transcripts` reads a long one the first time: from its first whole line, with `partial:
  true`. Such a fold does not know what was before that line: the session's first entries and
  prompts, its usage before it, and the calls and subagents started before it. A subagent whose
  meta names a call the fold does not hold still gets its row, from the meta (`file_meta/3`).
  A partial fold's `usage` counts from the cut and is never the session's total.

  A fold an earlier build stored has other keys, so it is read again from the file's start
  (`Transcripts.Table.load_fold/1`), and its interrupts with it.

  The offset counts only whole lines: a partial last line waits for the next read. The fold
  keeps the last bytes before its offset (`seam`); a read resumes `byte_size(seam)` bytes before
  the offset, and when those bytes differ (the file shrank or was replaced), `take/2` answers
  `:rewritten` and the caller reads the file again from its start.
  """

  @seam 64
  @kept_problems 20
  @preview 500
  @kept_tools 200
  @kept_agents 50

  # Entry types Claude Code 2.1.322 writes (its table of types and how a resume treats each).
  # The fold reads the first five; the rest are known and skipped by name.
  @read ~w(user assistant attachment system summary)
  @skipped ~w(progress queue-operation api-request api-request-shape api-request-blob frame-link
              observer-ref continued-in resume-head-vouch file-history-snapshot file-history-delta
              attribution-snapshot custom-title ai-title tag relocated agent-name agent-color
              agent-setting mode permission-mode session-owner isolation-latch dev-mods atis-latch
              worktree-state bridge-session tools-used pr-link history-suppression ended-by-model
              cost-state last-prompt content-replacement memory-mode artifact-comment-monitor
              artifact-autoreact-ledger fork-context-ref repl-mode)
  @usage ~w(input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens)
  @tool_use "[Request interrupted by user for tool use]"
  @interrupts ["[Request interrupted by user]", @tool_use]

  @type t :: %{
          offset: non_neg_integer,
          seam: binary,
          entries: non_neg_integer,
          prompts: [map],
          last_reply: map | nil,
          ends_with_reply: boolean,
          message: map | nil,
          subagents: %{String.t() => map},
          usage: %{String.t() => non_neg_integer},
          limit: map | nil,
          interrupts: [map],
          tools: [map],
          agent_tools: %{String.t() => [map]},
          last_event_at: integer | nil,
          files: %{String.t() => map},
          partial: boolean,
          problems: [map],
          problem_count: non_neg_integer
        }

  @doc "A fold that has read nothing."
  @spec new() :: t
  def new do
    %{
      offset: 0,
      seam: "",
      entries: 0,
      prompts: [],
      last_reply: nil,
      ends_with_reply: false,
      message: nil,
      subagents: %{},
      usage: zero(),
      limit: nil,
      interrupts: [],
      tools: [],
      agent_tools: %{},
      last_event_at: nil,
      files: %{},
      partial: false,
      problems: [],
      problem_count: 0
    }
  end

  @doc "The byte a read starts at: the seam's first byte, before the offset."
  @spec read_from(t) :: non_neg_integer
  def read_from(fold), do: fold.offset - byte_size(fold.seam)

  @doc """
  Folds `bytes`, the file read from `read_from/1`. Answers `{:ok, fold}`, or `:rewritten`
  when the bytes do not start with the seam: the file shrank or was replaced.
  """
  @spec take(t, binary) :: {:ok, t} | :rewritten
  def take(fold, bytes) do
    size = byte_size(fold.seam)

    case bytes do
      <<seam::binary-size(^size), rest::binary>> when seam == fold.seam ->
        {:ok, lines(fold, rest)}

      _ ->
        :rewritten
    end
  end

  @doc """
  Folds the first read of a main file when it starts at byte `at`, not at the file's start: a
  read bounded to the file's last bytes (`Transcripts`' `first_read:`). The first line, cut by
  the bound, is skipped, so the fold starts at a whole line and says `partial: true`; its seam
  is the cut line's last bytes, so the next read checks them as `take/2` does. At 0 it is
  `take/2` on a new fold, not partial. Bytes with no whole line leave it a fold that has read
  nothing.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> use = ~s({"type":"assistant","message":) <>
      ...>   ~s({"id":"m1","content":[{"type":"tool_use","id":"tu-2","name":"Read"}]}}\\n)
      iex> {:ok, fold} = Fold.take_from(900, ~s(ut-line"}\\n) <> use)
      iex> {fold.partial, fold.offset - 910 == byte_size(use), hd(fold.tools).id}
      {true, true, "tu-2"}
      iex> {:ok, fold} = Fold.take_from(0, use)
      iex> fold.partial
      false
  """
  @spec take_from(non_neg_integer, binary) :: {:ok, t}
  def take_from(0, bytes), do: take(new(), bytes)

  def take_from(at, bytes) do
    case :binary.split(bytes, "\n") do
      [_no_whole_line] ->
        {:ok, new()}

      [cut, rest] ->
        read = cut <> "\n"
        seam = binary_part(read, byte_size(read), -min(byte_size(read), @seam))
        {:ok, lines(%{new() | offset: at + byte_size(read), seam: seam, partial: true}, rest)}
    end
  end

  @doc """
  Whether a prompt in `bytes` (whole lines of a transcript) holds both `mark` and `text`: a
  user entry's text, or a queued prompt's. A partial last line is not read.

      iex> line = ~s({"type":"user","message":{"content":"[r-7] done"}}\\n)
      iex> CodingAgentFramework.Transcripts.Fold.contains?(line, "[r-7]", "done")
      true
  """
  @spec contains?(binary, String.t(), String.t()) :: boolean
  def contains?(bytes, mark, text) do
    bytes
    |> String.split("\n")
    |> Enum.drop(-1)
    |> Enum.any?(fn line ->
      case JSON.decode(line) do
        {:ok, e} when is_map(e) -> Enum.any?(texts(e), &(&1 =~ mark and &1 =~ text))
        _ -> false
      end
    end)
  end

  @doc """
  The reply of the turn that the first prompt holding `mark` began, in `bytes` (whole lines of
  a transcript): an interactive delegate's report, the reply to its brief (F-137). Answers
  `:absent` while no prompt holds `mark`, else `{:ok, %{reply: text | nil, closed: closed}}`:
  the last reply that ended a message of that turn (`stop_reason` `end_turn`), and whether a
  later user entry began another turn, which closes it: a prompt, or a notification that starts
  a turn (a waiter's text). A text queued into the running turn (a waiter's `queued_command`
  attachment) joins it, as Claude Code takes it there.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> brief = ~s({"type":"user","message":{"content":"Review it. [delivery b-1]"}}\\n)
      iex> reply = ~s({"type":"assistant","message":{"id":"m1","stop_reason":"end_turn",) <>
      ...>   ~s("content":[{"type":"text","text":"Done."}]}}\\n)
      iex> Fold.reply_to(brief <> reply, "[delivery b-1]")
      {:ok, %{reply: "Done.", closed: false}}
      iex> later = ~s({"type":"user","message":{"content":"And now?"}}\\n)
      iex> Fold.reply_to(brief <> reply <> later, "[delivery b-1]")
      {:ok, %{reply: "Done.", closed: true}}
      iex> Fold.reply_to(reply, "[delivery b-1]")
      :absent
  """
  @spec reply_to(binary, String.t()) ::
          :absent | {:ok, %{reply: String.t() | nil, closed: boolean}}
  def reply_to(bytes, mark) do
    lines = bytes |> String.split("\n") |> Enum.drop(-1)

    case Enum.split_while(lines, &(not marked?(&1, mark))) do
      {_, []} ->
        :absent

      {_, [first | rest]} ->
        {fold, closed} =
          Enum.reduce_while(rest, {line(new(), first), false}, fn l, {f, _} ->
            if opens?(l), do: {:halt, {f, true}}, else: {:cont, {line(f, l), false}}
          end)

        {:ok, %{reply: fold.last_reply && fold.last_reply.text, closed: closed}}
    end
  end

  @doc """
  The turns of an interactive delegate's own after the turn that `bytes` (whole lines of a
  transcript, from that turn's first line) begins: each a turn a background command of its own
  began (F-155), its first entry a `<task-notification>` that `marked?` finds no delivery of the
  framework's in. A person's prompt, or a row the framework delivered, begins a turn that is not
  its own. Each with a reply: `%{uuid, text, closed}`, the uuid of the reply's line (the turn's
  key), its text, and whether a later turn closed it; a turn not closed may still be running.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> brief = ~s({"type":"user","message":{"content":"Look. [delivery b-1]"}}\\n)
      iex> wake = ~s({"type":"user","message":{"content":"<task-notification>done"}}\\n)
      iex> reply = ~s({"type":"assistant","uuid":"r-1","message":{"id":"m1",) <>
      ...>   ~s("stop_reason":"end_turn","content":[{"type":"text","text":"It passed."}]}}\\n)
      iex> marked? = &String.contains?(&1, "[delivery ")
      iex> Fold.own_turns(brief <> reply <> wake <> reply, marked?)
      [%{uuid: "r-1", text: "It passed.", closed: false}]
      iex> Fold.own_turns(brief <> reply <> brief <> reply, marked?)
      []
  """
  @spec own_turns(binary, (String.t() -> boolean)) :: [
          %{uuid: String.t(), text: String.t(), closed: boolean}
        ]
  def own_turns(bytes, marked?) do
    turns =
      bytes
      |> String.split("\n")
      |> Enum.drop(-1)
      |> Enum.drop(1)
      |> Enum.reduce([], fn l, turns ->
        cond do
          opens?(l) -> [[l] | turns]
          turns == [] -> turns
          true -> [[l | hd(turns)] | tl(turns)]
        end
      end)
      |> Enum.map(&Enum.reverse/1)

    count = length(turns)

    for {[first | _] = turn, i} <- Enum.with_index(Enum.reverse(turns)),
        own?(first, marked?),
        %{uuid: uuid, text: text} <- [Enum.reduce(turn, new(), &line(&2, &1)).last_reply],
        is_binary(uuid),
        do: %{uuid: uuid, text: text, closed: i < count - 1}
  end

  defp own?(line, marked?) do
    case JSON.decode(line) do
      {:ok, %{"type" => "user"} = e} ->
        texts = texts(e)
        Enum.any?(texts, &notification/1) and not Enum.any?(texts, marked?)

      _ ->
        false
    end
  end

  defp line(fold, l), do: lines(fold, l <> "\n")

  # A user entry that is not a tool's result nor meta begins a turn: a person's prompt, or a
  # notification that starts one (a waiter's text, a background task's end).
  defp opens?(line) do
    case JSON.decode(line) do
      {:ok, %{"type" => "user", "message" => %{"content" => c}} = e} ->
        e["isMeta"] != true and e["isSidechain"] != true and
          not (is_list(c) and Enum.any?(c, &match?(%{"type" => "tool_result"}, &1)))

      _ ->
        false
    end
  end

  @doc """
  The tool calls whole lines of `bytes` show, oldest first: each `tool_use` block of an
  assistant entry, with its id, its tool's name and its entry's time in ms (nil when it has
  none). A cut first line, as a read from inside the file leaves it, is skipped. `HooksSilent`
  reads it (F-184).

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> call = ~s({"type":"assistant","timestamp":"2026-11-21T09:00:00.000Z",) <>
      ...>   ~s("message":{"content":[{"type":"tool_use","id":"tu-1","name":"Bash"}]}}\\n)
      iex> Fold.tool_calls(~s(cut"}\\n) <> call)
      [%{id: "tu-1", name: "Bash", at: 1795251600000}]
  """
  @spec tool_calls(binary) :: [%{id: String.t(), name: String.t(), at: integer | nil}]
  def tool_calls(bytes) do
    for line <- bytes |> String.split("\n") |> Enum.drop(-1),
        {:ok, %{"type" => "assistant", "message" => %{"content" => c}} = e} <- [JSON.decode(line)],
        is_list(c),
        %{"type" => "tool_use", "id" => id, "name" => name} <- c,
        is_binary(id),
        do: %{id: id, name: name, at: ms(e["timestamp"])}
  end

  defp ms(stamp) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> DateTime.to_unix(at, :millisecond)
      _ -> nil
    end
  end

  defp ms(_), do: nil

  @doc """
  The byte offset in `bytes` of the first user line that carries `mark`, or nil: where a reader
  that found it reads from next time (F-137's new-4). Only whole lines count.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> other = ~s({"type":"user","message":{"content":"Hi."}}\\n)
      iex> brief = ~s({"type":"user","message":{"content":"Review it. [delivery b-1]"}}\\n)
      iex> Fold.marked_at(other <> brief, "[delivery b-1]") == byte_size(other)
      true
      iex> Fold.marked_at(other, "[delivery b-1]")
      nil
  """
  @spec marked_at(binary, String.t()) :: non_neg_integer | nil
  def marked_at(bytes, mark) do
    bytes
    |> String.split("\n")
    |> Enum.drop(-1)
    |> Enum.reduce_while(0, fn line, at ->
      if marked?(line, mark), do: {:halt, {:at, at}}, else: {:cont, at + byte_size(line) + 1}
    end)
    |> case do
      {:at, at} -> at
      _ -> nil
    end
  end

  defp marked?(line, mark) do
    case JSON.decode(line) do
      {:ok, %{"type" => "user"} = e} -> Enum.any?(texts(e), &String.contains?(&1, mark))
      _ -> false
    end
  end

  defp texts(%{"type" => "user", "message" => %{"content" => c}}) when is_binary(c), do: [c]

  defp texts(%{"type" => "user", "message" => %{"content" => c}}) when is_list(c),
    do: for(%{"type" => "text", "text" => t} <- c, is_binary(t), do: t)

  defp texts(%{"type" => "attachment", "attachment" => %{"prompt" => p}}) when is_binary(p),
    do: [p]

  defp texts(_), do: []

  # `agent` is nil for the main file, or the subagent whose own file the bytes are.
  defp lines(fold, rest, agent \\ nil) do
    case :binary.split(rest, "\n") do
      [_partial] ->
        fold

      [line, rest] ->
        end_at = fold.offset + byte_size(line) + 1
        read = fold.seam <> line <> "\n"
        seam = binary_part(read, byte_size(read), -min(byte_size(read), @seam))
        fold = %{fold | offset: end_at, seam: seam, entries: fold.entries + 1}
        lines(entry(fold, line, end_at, agent), rest, agent)
    end
  end

  defp entry(fold, "", _at, _agent), do: fold

  defp entry(fold, line, at, agent) do
    case JSON.decode(line) do
      {:ok, %{"type" => type} = e} when type in @read ->
        e = if agent, do: Map.merge(e, %{"isSidechain" => true, "agentId" => agent}), else: e
        fold |> seen(e) |> read(type, e, at)

      {:ok, %{"type" => type}} when type in @skipped ->
        fold

      {:ok, %{"type" => type}} ->
        problem(fold, at, {:unknown_type, inspect(type)})

      {:ok, %{}} ->
        problem(fold, at, :no_type)

      {:ok, _} ->
        problem(fold, at, :not_an_object)

      {:error, _} ->
        problem(fold, at, :not_json)
    end
  end

  # A sidechain entry is a subagent's, not the session's: only its tool calls are kept, under its
  # agent id. On 2.1.322 these come from the subagent's own file (`take_file/3`); older releases
  # wrote them into the main file.
  defp read(fold, _type, %{"isSidechain" => true} = e, _at), do: side(fold, e)

  # The usage limit's line: the account's record, and no reply (F-181).
  defp read(fold, "assistant", %{"apiError" => "usage_limit_reached"} = e, at) do
    record =
      Enum.find([e["quotaLimits"], get_in(e, ["apiErrorParams", "rate_limit_info"])], &is_map/1)

    if record do
      limit = %{record: record, uuid: e["uuid"], at: e["timestamp"], offset: at, followed: false}
      %{fold | limit: limit, ends_with_reply: false}
    else
      problem(fold, at, {:shape, "usage limit"})
    end
  end

  defp read(fold, "assistant", %{"message" => %{"id" => id} = m} = e, at) when is_binary(id) do
    fold = if e["isApiErrorMessage"] == true, do: fold, else: followed(fold)
    content = if is_list(m["content"]), do: m["content"], else: []

    texts =
      for %{"type" => "text", "text" => t} <- content, is_binary(t), String.trim(t) != "", do: t

    # One API message is written as one line per content block, each with the message's
    # usage so far; a message counts once, by its latest line.
    prev =
      case fold.message do
        %{id: ^id} = prev -> prev
        _ -> %{id: id, texts: [], usage: zero()}
      end

    counts =
      if is_map(m["usage"]), do: Map.new(@usage, &{&1, count(m["usage"][&1])}), else: prev.usage

    usage = Map.new(@usage, &{&1, fold.usage[&1] - prev.usage[&1] + counts[&1]})
    msg = %{id: id, texts: prev.texts ++ texts, usage: counts}
    fold = started(%{fold | message: msg, usage: usage, ends_with_reply: false}, content, e)
    fold = %{fold | tools: calls(fold.tools, content, e)}

    if m["stop_reason"] == "end_turn" and msg.texts != [] do
      reply = %{message_id: id, uuid: e["uuid"], at: e["timestamp"], offset: at}

      %{
        fold
        | last_reply: Map.put(reply, :text, Enum.join(msg.texts, "\n\n")),
          ends_with_reply: true
      }
    else
      fold
    end
  end

  defp read(fold, "assistant", _e, at), do: problem(fold, at, {:shape, "assistant"})

  defp read(fold, "user", %{"message" => %{"content" => content}} = e, at) do
    blocks = if is_list(content), do: content, else: []
    results = for %{"type" => "tool_result"} = b <- blocks, do: b

    cond do
      results != [] -> Enum.reduce(results, ends(fold, results, e), &result(&2, &1, e))
      notification(content) -> ended(fold, content, e)
      e["isMeta"] == true -> fold
      true -> fold |> interrupt(content, e, at) |> prompt(content, e, at)
    end
  end

  defp read(fold, "user", _e, at), do: problem(fold, at, {:shape, "user"})

  defp read(fold, "attachment", %{"attachment" => %{"prompt" => p}} = e, _at) when is_binary(p),
    do: if(notification(p), do: ended(fold, p, e), else: fold)

  defp read(fold, _type, _e, _at), do: fold

  # Claude Code's line for a turn a key ended (F-194; the two texts checked by name in the
  # 2.1.322 binary): kept with the time of the prompt that opened the turn it ended. It stays a
  # prompt too, as every user line that is not a tool's result or meta is.
  defp interrupt(fold, content, e, at) do
    case Enum.find(prompt_texts(content), &(&1 in @interrupts)) do
      nil ->
        fold

      text ->
        opened = Enum.find(Enum.reverse(fold.prompts), &(not interrupt?(&1.text)))

        entry = %{
          uuid: e["uuid"],
          at: ms(e["timestamp"]),
          offset: at,
          tool_use: text == @tool_use,
          turn_at: opened && ms(opened.at)
        }

        %{fold | interrupts: fold.interrupts ++ [entry]}
    end
  end

  defp prompt_texts(text) when is_binary(text), do: [String.trim(text)]

  defp prompt_texts(blocks) when is_list(blocks),
    do: for(%{"type" => "text", "text" => t} <- blocks, is_binary(t), do: String.trim(t))

  defp prompt_texts(_), do: []

  @doc """
  Whether `text` is Claude Code's line for a turn a key ended: `[Request interrupted by user]`,
  or `[Request interrupted by user for tool use]` when it ended in a tool call.

      iex> CodingAgentFramework.Transcripts.Fold.interrupt?("[Request interrupted by user]")
      true
  """
  @spec interrupt?(term) :: boolean
  def interrupt?(text) when is_binary(text), do: String.trim(text) in @interrupts
  def interrupt?(_), do: false

  # A prompt is a string, or a list of blocks when it holds an image.
  defp prompt(fold, content, e, at) do
    {text, images} =
      case content do
        text when is_binary(text) ->
          {text, 0}

        blocks when is_list(blocks) ->
          {Enum.join(for(%{"type" => "text", "text" => t} <- blocks, is_binary(t), do: t), "\n"),
           Enum.count(blocks, &match?(%{"type" => "image"}, &1))}

        _ ->
          {"", 0}
      end

    prompt = %{
      prompt_id: e["promptId"],
      uuid: e["uuid"],
      at: e["timestamp"],
      offset: at,
      text: String.slice(text, 0, @preview),
      chars: String.length(text),
      images: images
    }

    %{followed(fold) | prompts: fold.prompts ++ [prompt], ends_with_reply: false}
  end

  # A turn ran after the last limit's line.
  defp followed(%{limit: %{followed: false} = limit} = fold),
    do: %{fold | limit: %{limit | followed: true}}

  defp followed(fold), do: fold

  defp started(fold, content, e) do
    agents =
      for %{"type" => "tool_use", "name" => name, "id" => id} = b <- content,
          name in ["Agent", "Task"],
          is_binary(id),
          into: fold.subagents do
        input = if is_map(b["input"]), do: b["input"], else: %{}

        {id,
         %{
           tool_use_id: id,
           agent_id: file_agent(fold, id),
           type: input["subagent_type"],
           description: input["description"],
           state: :open,
           status: nil,
           tokens: nil,
           started_at: e["timestamp"],
           ended_at: nil
         }}
      end

    %{fold | subagents: agents}
  end

  # The Agent tool's result: `completed` with its tokens, or `async_launched` for one that runs
  # on in the background and ends with a task notification.
  defp result(fold, %{"tool_use_id" => id} = block, e) do
    case {fold.subagents[id], e["toolUseResult"]} do
      {nil, _} ->
        fold

      {agent, %{"status" => "async_launched"} = r} ->
        put_agent(fold, id, %{agent | agent_id: r["agentId"], state: :background})

      {agent, %{"status" => status} = r} ->
        put_agent(fold, id, close(agent, status, r["totalTokens"], e, r["agentId"]))

      {agent, _} ->
        status = if block["is_error"] == true, do: "error", else: "unknown"
        put_agent(fold, id, close(agent, status, nil, e, nil))
    end
  end

  defp result(fold, _block, _e), do: fold

  defp notification(text) when is_binary(text),
    do: String.starts_with?(text, "<task-notification>")

  defp notification(_), do: false

  defp ended(fold, text, e) do
    {task, tool_use} = {tag(text, "task-id"), tag(text, "tool-use-id")}
    found = Enum.find(fold.subagents, fn {id, a} -> id == tool_use or a.agent_id == task end)

    case {task, found} do
      {nil, _} ->
        fold

      {_, nil} ->
        # A notification of a task that is not a subagent of this transcript, such as a shell.
        fold

      {task, {id, agent}} ->
        tokens =
          case Regex.run(~r/subagent_tokens(?:>|: )(\d+)/, text) do
            [_, n] -> String.to_integer(n)
            nil -> nil
          end

        put_agent(fold, id, close(agent, tag(text, "status"), tokens, e, task))
    end
  end

  defp tag(text, name) do
    case Regex.run(~r/<#{name}>([^<]*)<\/#{name}>/, text) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp close(agent, status, tokens, e, agent_id) do
    %{
      agent
      | state: :ended,
        status: status,
        tokens: if(is_integer(tokens), do: tokens, else: agent.tokens),
        agent_id: agent_id || agent.agent_id,
        ended_at: e["timestamp"]
    }
  end

  defp put_agent(fold, id, agent), do: %{fold | subagents: Map.put(fold.subagents, id, agent)}

  # The session's own entries alone say when it last did anything.
  defp seen(fold, %{"isSidechain" => true}), do: fold

  defp seen(fold, e) do
    case ms(e["timestamp"]) do
      nil -> fold
      at -> %{fold | last_event_at: at}
    end
  end

  defp side(fold, %{"agentId" => agent, "message" => %{"content" => c}} = e)
       when is_binary(agent) and is_list(c) do
    old = Map.get(fold.agent_tools, agent, [])
    new = c |> Enum.filter(&match?(%{"type" => "tool_result"}, &1)) |> end_calls(old, e)
    new = if e["type"] == "assistant", do: calls(new, c, e), else: new
    agents = Map.put(fold.agent_tools, agent, new)

    agents =
      if map_size(agents) > @kept_agents,
        do: Map.delete(agents, stalest(Map.delete(agents, agent))),
        else: agents

    %{fold | agent_tools: agents}
  end

  defp side(fold, _e), do: fold

  defp stalest(agents),
    do: agents |> Enum.min_by(fn {_, calls} -> newest_at(calls) end) |> elem(0)

  defp newest_at([%{started_at: at} | _]) when is_integer(at), do: at
  defp newest_at(_), do: 0

  # Each `tool_use` block starts a call; a block seen before (a line written twice) does not.
  defp calls(calls, content, e) do
    for %{"type" => "tool_use", "id" => id, "name" => name} <- content,
        is_binary(id),
        not Enum.any?(calls, &(&1.id == id)),
        reduce: calls do
      acc ->
        call = %{id: id, name: name, started_at: ms(e["timestamp"]), ended_at: nil, ms: nil}
        Enum.take([call | acc], @kept_tools)
    end
  end

  defp ends(fold, results, e), do: %{fold | tools: end_calls(results, fold.tools, e)}

  # A result ends its call; one whose call the bound dropped, or never started here, ends none.
  defp end_calls(results, calls, e) do
    at = ms(e["timestamp"])

    Enum.reduce(results, calls, fn
      %{"tool_use_id" => id}, calls when is_binary(id) ->
        Enum.map(calls, fn
          %{id: ^id, ended_at: nil, started_at: s} = c ->
            %{c | ended_at: at, ms: if(is_integer(at) and is_integer(s), do: max(at - s, 0))}

          c ->
            c
        end)

      _block, calls ->
        calls
    end)
  end

  @doc """
  The byte a read of subagent `agent`'s own file starts at, as `read_from/1` is the main
  file's: 0 for a file the fold has not read.
  """
  @spec file_read_from(t, String.t()) :: non_neg_integer
  def file_read_from(fold, agent) do
    file = file(fold, agent)
    file.offset - byte_size(file.seam)
  end

  @doc """
  The whole lines read so far of subagent `agent`'s own file, `agent-<agent>.jsonl` (F-237):
  its offset, 0 for a file the fold has not read.
  """
  @spec file_offset(t, String.t()) :: non_neg_integer
  def file_offset(fold, agent), do: file(fold, agent).offset

  @doc """
  Folds `bytes` of subagent `agent`'s own file, read from `file_read_from/2`, into the same
  fold, as `take/2` does the main file's: with that file's own offset and seam in `files`.
  Every entry of the file is the subagent's, so only its tool calls are kept, under `agent`,
  whatever its own `isSidechain` and `agentId` say. A line it cannot read is a problem with
  `file:` the file's name. `:rewritten` when the bytes do not start with the file's seam.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> use = ~s({"type":"assistant","isSidechain":true,"agentId":"a1","message":) <>
      ...>   ~s({"id":"m1","content":[{"type":"tool_use","id":"tu-1","name":"Grep"}]}}\\n)
      iex> {:ok, fold} = Fold.take_file(Fold.new(), "a1", use <> "nope\\n")
      iex> {hd(fold.agent_tools["a1"]).name, fold.tools, hd(fold.problems).file}
      {"Grep", [], "agent-a1.jsonl"}
  """
  @spec take_file(t, String.t(), binary) :: {:ok, t} | :rewritten
  def take_file(fold, agent, bytes) do
    file = file(fold, agent)
    size = byte_size(file.seam)

    case bytes do
      <<seam::binary-size(^size), rest::binary>> when seam == file.seam ->
        inner = %{fold | offset: file.offset, seam: file.seam, problems: [], problem_count: 0}
        inner = lines(inner, rest, agent)
        name = "agent-#{agent}.jsonl"
        problems = Enum.map(inner.problems, &Map.put(&1, :file, name))
        file = %{file | offset: inner.offset, seam: inner.seam, problem: nil}

        {:ok,
         %{
           inner
           | offset: fold.offset,
             seam: fold.seam,
             entries: fold.entries,
             problems: Enum.take(fold.problems ++ problems, -@kept_problems),
             problem_count: fold.problem_count + inner.problem_count,
             files: Map.put(fold.files, agent, file)
         }}

      _ ->
        :rewritten
    end
  end

  @doc """
  Folds the first read of subagent `agent`'s file when it starts at byte `at`, not at the
  file's start: a read bounded to the file's last bytes (`Transcripts`' `first_read:`). The
  first line, cut by the bound, is skipped, so the fold starts at a whole line, and the file's
  entry says `partial: true`; calls before it are not known. At 0 it is `take_file/3` on a file
  read from its start. Bytes with no whole line leave the file unread.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> use = ~s({"type":"assistant","message":) <>
      ...>   ~s({"id":"m1","content":[{"type":"tool_use","id":"tu-2","name":"Read"}]}}\\n)
      iex> {:ok, fold} = Fold.take_file_from(Fold.new(), "a1", 900, ~s(ut-line"}\\n) <> use)
      iex> {fold.files["a1"].partial, fold.files["a1"].offset - 910 == byte_size(use)}
      {true, true}
      iex> hd(fold.agent_tools["a1"]).id
      "tu-2"
  """
  @spec take_file_from(t, String.t(), non_neg_integer, binary) :: {:ok, t}
  def take_file_from(fold, agent, at, bytes) do
    old = file(fold, agent)
    keep = %{new_file() | tool_use_id: old.tool_use_id, finished: old.finished}
    fold = %{fold | agent_tools: Map.delete(fold.agent_tools, agent)}

    case {at, :binary.split(bytes, "\n")} do
      {0, _} ->
        take_file(%{fold | files: Map.put(fold.files, agent, keep)}, agent, bytes)

      {_, [_no_whole_line]} ->
        {:ok, fold}

      {_, [cut, rest]} ->
        file = %{keep | offset: at + byte_size(cut) + 1, partial: true}
        take_file(%{fold | files: Map.put(fold.files, agent, file)}, agent, rest)
    end
  end

  @doc """
  Marks subagent `agent`'s file not read (`not_read: :finished`): a file the fold never read
  whose meta says the subagent finished. Its calls are absent; its `agent_id` is the meta's.
  `size` is the file's size then, so a file that grows after is looked at again.
  """
  @spec skip_file(t, String.t(), non_neg_integer) :: t
  def skip_file(fold, agent, size) do
    file = %{file(fold, agent) | not_read: :finished, size: size}
    %{fold | files: Map.put(fold.files, agent, file)}
  end

  @doc """
  Forgets what the fold read of subagent `agent`'s file, its calls with it, so the file is read
  again from its start; the call that started it stays known.
  """
  @spec restart_file(t, String.t()) :: t
  def restart_file(fold, agent) do
    old = file(fold, agent)
    file = %{new_file() | tool_use_id: old.tool_use_id, finished: old.finished}

    %{
      fold
      | files: Map.put(fold.files, agent, file),
        agent_tools: Map.delete(fold.agent_tools, agent)
    }
  end

  @doc """
  Names a problem of subagent `agent`'s file in its `files` entry (`"no_file"` once it is gone,
  `"rewritten"`), or nil once it reads cleanly again, keeping what was read of it.
  """
  @spec file_problem(t, String.t(), String.t() | nil) :: t
  def file_problem(fold, agent, problem),
    do: %{fold | files: Map.put(fold.files, agent, %{file(fold, agent) | problem: problem})}

  @doc """
  Reads subagent `agent`'s `agent-<agent>.meta.json`, which Claude Code 2.1.322 writes when the
  subagent starts (F-237's measurement): its `toolUseId` is the parent's `Agent` call that
  started it, so that call's row in `subagents` has the subagent's `agent_id` while it runs,
  before its result names it, and its `finished` (true once the subagent ended) is kept in the
  file's entry. A call the fold does not hold, one a bounded first read began after (F-244),
  gets a row from the meta alone: its ids, `type` and `description` from its `agentType` and
  `description`, `state` `:ended` if the meta says `finished` and `:open` if not, and
  `started_at` nil. `:unreadable` for bytes
  without one, such as a file not yet whole.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> call = ~s({"type":"assistant","message":{"id":"m1","content":) <>
      ...>   ~s([{"type":"tool_use","id":"tu-1","name":"Agent","input":{"description":"look"}}]}}\\n)
      iex> {:ok, fold} = Fold.take(Fold.new(), call)
      iex> {:ok, fold} = Fold.file_meta(fold, "a1", ~s({"toolUseId":"tu-1"}))
      iex> fold.subagents["tu-1"].agent_id
      "a1"
  """
  @spec file_meta(t, String.t(), binary) :: {:ok, t} | :unreadable
  def file_meta(fold, agent, bytes) do
    case JSON.decode(bytes) do
      {:ok, %{"toolUseId" => id} = meta} when is_binary(id) ->
        file = %{file(fold, agent) | tool_use_id: id, finished: meta["finished"] == true}
        fold = %{fold | files: Map.put(fold.files, agent, file)}

        case fold.subagents[id] do
          %{agent_id: nil} = a -> {:ok, put_agent(fold, id, %{a | agent_id: agent})}
          nil -> {:ok, put_agent(fold, id, unseen(id, agent, meta))}
          _ -> {:ok, fold}
        end

      _ ->
        :unreadable
    end
  end

  # The row of a subagent whose `Agent` call the fold does not hold, a bounded first read
  # having started after it (F-244): only what its meta says is known, not when it started.
  defp unseen(id, agent, meta) do
    %{
      tool_use_id: id,
      agent_id: agent,
      type: text(meta["agentType"]),
      description: text(meta["description"]),
      state: if(meta["finished"] == true, do: :ended, else: :open),
      status: nil,
      tokens: nil,
      started_at: nil,
      ended_at: nil
    }
  end

  defp text(t) when is_binary(t), do: t
  defp text(_), do: nil

  defp file(fold, agent), do: Map.get(fold.files, agent, new_file())

  defp new_file,
    do: %{
      offset: 0,
      seam: "",
      tool_use_id: nil,
      problem: nil,
      finished: false,
      not_read: nil,
      partial: false,
      size: nil
    }

  # The subagent whose meta names the call `id`, for a call folded after its file was read.
  defp file_agent(fold, id) do
    Enum.find_value(fold.files, fn {agent, f} -> if f.tool_use_id == id, do: agent end)
  end

  defp zero, do: Map.new(@usage, &{&1, 0})

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_), do: 0

  defp problem(fold, at, reason) do
    problems = Enum.take(fold.problems ++ [%{offset: at, reason: reason}], -@kept_problems)
    %{fold | problems: problems, problem_count: fold.problem_count + 1}
  end
end
