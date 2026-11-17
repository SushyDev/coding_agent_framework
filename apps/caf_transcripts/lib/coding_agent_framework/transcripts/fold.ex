defmodule CodingAgentFramework.Transcripts.Fold do
  @moduledoc """
  The pure fold of one session's transcript, `<config>/projects/<project>/<session>.jsonl`, a
  line of JSON per entry (Claude Code 2.1.322; sources in `docs/build-notes/F-28.md`).

  It answers the session's last assistant reply, its user prompts with their ids, its
  subagents with their token counts, and its own token usage. It is total: a line that is not
  JSON, not an object, of an unknown type or of an odd shape is kept as a problem, and the fold
  goes on.

      iex> alias CodingAgentFramework.Transcripts.Fold
      iex> line = ~s({"type":"user","uuid":"u1","promptId":"p1","message":{"content":"hi"}})
      iex> {:ok, fold} = Fold.take(Fold.new(), line <> "\\n" <> ~s({"type":"user"))
      iex> {fold.offset, Enum.map(fold.prompts, & &1.prompt_id)}
      {71, ["p1"]}

  The offset counts only whole lines: a partial last line waits for the next read. The fold
  keeps the last bytes before its offset (`seam`); a read resumes `byte_size(seam)` bytes before
  the offset, and when those bytes differ (the file shrank or was replaced), `take/2` answers
  `:rewritten` and the caller reads the file again from its start.
  """

  @seam 64
  @kept_problems 20
  @preview 500

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

  defp lines(fold, rest) do
    case :binary.split(rest, "\n") do
      [_partial] ->
        fold

      [line, rest] ->
        end_at = fold.offset + byte_size(line) + 1
        read = fold.seam <> line <> "\n"
        seam = binary_part(read, byte_size(read), -min(byte_size(read), @seam))
        fold = %{fold | offset: end_at, seam: seam, entries: fold.entries + 1}
        lines(entry(fold, line, end_at), rest)
    end
  end

  defp entry(fold, "", _at), do: fold

  defp entry(fold, line, at) do
    case JSON.decode(line) do
      {:ok, %{"type" => type} = e} when type in @read -> read(fold, type, e, at)
      {:ok, %{"type" => type}} when type in @skipped -> fold
      {:ok, %{"type" => type}} -> problem(fold, at, {:unknown_type, inspect(type)})
      {:ok, %{}} -> problem(fold, at, :no_type)
      {:ok, _} -> problem(fold, at, :not_an_object)
      {:error, _} -> problem(fold, at, :not_json)
    end
  end

  # A sidechain entry inside the main file (older releases wrote subagents there) is a
  # subagent's, not the session's: it is skipped by name, as is any line not of this session.
  defp read(fold, _type, %{"isSidechain" => true}, _at), do: fold

  defp read(fold, "assistant", %{"message" => %{"id" => id} = m} = e, at) when is_binary(id) do
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
      results != [] -> Enum.reduce(results, fold, &result(&2, &1, e))
      notification(content) -> ended(fold, content, e)
      e["isMeta"] == true -> fold
      true -> prompt(fold, content, e, at)
    end
  end

  defp read(fold, "user", _e, at), do: problem(fold, at, {:shape, "user"})

  defp read(fold, "attachment", %{"attachment" => %{"prompt" => p}} = e, _at) when is_binary(p),
    do: if(notification(p), do: ended(fold, p, e), else: fold)

  defp read(fold, _type, _e, _at), do: fold

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

    %{fold | prompts: fold.prompts ++ [prompt], ends_with_reply: false}
  end

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
           agent_id: nil,
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

  defp zero, do: Map.new(@usage, &{&1, 0})

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_), do: 0

  defp problem(fold, at, reason) do
    problems = Enum.take(fold.problems ++ [%{offset: at, reason: reason}], -@kept_problems)
    %{fold | problems: problems, problem_count: fold.problem_count + 1}
  end
end
