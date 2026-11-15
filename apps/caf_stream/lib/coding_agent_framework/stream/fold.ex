defmodule CodingAgentFramework.Stream.Fold do
  @moduledoc """
  The pure fold of one headless delegate: its event log read from an offset, and the rows of
  what the framework wrote to it. `model/tla/Stream.tla` models it; each function names the spec
  action it does.

  `take/2` reads whole lines only: a last line without its newline is still being written and
  waits for the next read. Each event writes what `Stream.tla`'s `Handle` says: a replay
  delivers its message, a `result` ends the turn, a `can_use_tool` request is held, an answer's
  replay answers it, a cancel cancels it. It also keeps the session id of `system`/`init` and the
  latest `rate_limit_event`, and the last `result` with its text. It is total: a line that is
  not a JSON object is counted as a problem.

      iex> alias CodingAgentFramework.Stream.Fold
      iex> fold = Fold.mark(Fold.new(), {:message, "u1", "hi"}, ~s({"x":1}\\n), 0)
      iex> fold = Fold.take(fold, ~s({"type":"user","isReplay":true,"uuid":"u1"}\\n{"type":"res))
      iex> {fold.offset, fold.messages["u1"].state, fold.idle}
      {44, :delivered, false}
  """

  @type t :: %{
          offset: non_neg_integer,
          session_id: String.t() | nil,
          idle: boolean,
          live_seen: boolean,
          gone: boolean,
          resumes: non_neg_integer,
          ending: boolean,
          messages: %{String.t() => map},
          requests: %{String.t() => map},
          lines: %{String.t() => map},
          last_result: map | nil,
          rate_limit: map | nil,
          events: non_neg_integer,
          problems: non_neg_integer
        }

  @doc "A delegate nothing was read from or written to. Its turn has ended (`Init`: idle)."
  @spec new() :: t
  def new do
    %{
      offset: 0,
      session_id: nil,
      idle: true,
      live_seen: false,
      gone: false,
      resumes: 0,
      ending: false,
      messages: %{},
      requests: %{},
      lines: %{},
      last_result: nil,
      rate_limit: nil,
      events: 0,
      problems: 0
    }
  end

  @doc """
  `Read`: folds the whole lines of `bytes`, the log read from `offset`, and moves the offset past
  them. The caller saves the fold, offset and all, in one transaction.
  """
  @spec take(t, binary) :: t
  def take(fold, bytes) do
    case :binary.matches(bytes, "\n") do
      [] ->
        fold

      matches ->
        {at, 1} = List.last(matches)
        whole = binary_part(bytes, 0, at + 1)

        whole
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{fold | offset: fold.offset + at + 1}, &line/2)
    end
  end

  defp line(text, fold) do
    case JSON.decode(text) do
      {:ok, %{} = event} -> event(%{fold | events: fold.events + 1}, event)
      _ -> %{fold | problems: fold.problems + 1}
    end
  end

  @doc "`Handle`: what one event writes."
  @spec event(t, map) :: t
  def event(fold, %{"type" => "system", "subtype" => "init", "session_id" => id})
      when is_binary(id),
      do: %{fold | session_id: id}

  def event(fold, %{"type" => "user", "isReplay" => true, "uuid" => uuid}),
    do: settle(fold, :messages, uuid, :writing, :delivered)

  def event(fold, %{"type" => "result"} = e) do
    uuids = Map.get(e, "user_message_uuids", [])
    # `text` is the turn's last message, a finished delegate's report (`Delegates`).
    text = if is_binary(e["result"]), do: e["result"]
    result = %{subtype: e["subtype"], is_error: e["is_error"], user_message_uuids: uuids}
    result = Map.put(result, :text, text)
    %{fold | idle: true, last_result: result}
  end

  def event(fold, %{"type" => "control_request", "request_id" => id, "request" => r})
      when is_binary(id) and is_map(r) do
    if r["subtype"] == "can_use_tool" and not Map.has_key?(fold.requests, id) do
      held = %{state: :held, tool_name: r["tool_name"], tool_use_id: r["tool_use_id"]}
      %{fold | requests: Map.put(fold.requests, id, Map.put(held, :input, r["input"]))}
    else
      fold
    end
  end

  def event(fold, %{"type" => "control_cancel_request", "request_id" => id}) do
    fold
    |> settle(:requests, id, :held, :canceled)
    |> settle(:requests, id, :answering, :canceled)
  end

  # The replay of an answer that settled a pending request (F-31: `--replay-user-messages`
  # passes it on); its shape is the release check's to confirm.
  def event(fold, %{"type" => "control_response", "isReplay" => true, "response" => r})
      when is_map(r),
      do: settle(fold, :requests, r["request_id"], :answering, :answered)

  def event(fold, %{"type" => "rate_limit_event", "rate_limit_info" => info}) when is_map(info),
    do: %{fold | rate_limit: info}

  def event(fold, _event), do: fold

  defp settle(fold, table, key, from, to) do
    case Map.fetch(Map.fetch!(fold, table), key) do
      {:ok, %{state: ^from} = row} ->
        Map.put(fold, table, Map.put(fold[table], key, %{row | state: to}))

      _ ->
        fold
    end
  end

  @doc """
  Whether `line` may be marked now, and why not (`Mark`, `EndMarked`). A message needs no end
  marked, the turn ended (`idle`) and every other message delivered: one waiting for its replay
  refuses it as `:message_waiting`, one found undelivered as `{:undelivered, uuid}`, since that
  one goes again first, under its own uuid. A uuid already used is refused unless its message
  was found undelivered. An answer needs its request held. An end needs the turn ended and no
  message under way or found undelivered; behind `Sessions`' check of the report, this is
  defense in depth.

      iex> alias CodingAgentFramework.Stream.Fold
      iex> fold = Fold.mark(Fold.new(), {:message, "u1", "hi"}, "", 0)
      iex> fold = Fold.exit_seen(fold, fn _ -> false end) |> Fold.again()
      iex> {Fold.check(fold, {:message, "u2", "x"}), Fold.check(fold, {:message, "u1", "hi"})}
      {{:refused, {:undelivered, "u1"}}, :ok}
  """
  @spec check(t, tuple) :: :ok | {:refused, term}
  def check(%{gone: true}, _line), do: {:refused, :gone}

  def check(fold, {:message, uuid, _}) do
    cond do
      fold.ending ->
        {:refused, :ending}

      Map.has_key?(fold.messages, uuid) and fold.messages[uuid].state != :undelivered ->
        {:refused, :duplicate_uuid}

      not fold.idle ->
        {:refused, :turn_running}

      true ->
        others(fold, uuid)
    end
  end

  def check(fold, {:answer, id, _}) do
    case fold.requests[id] do
      %{state: :held} -> :ok
      nil -> {:refused, :no_request}
      %{state: state} -> {:refused, {:request, state}}
    end
  end

  # An end cuts a running turn and drops what has not gone in ("Headless delegates", "Ending").
  def check(fold, {:end_session, _}) do
    cond do
      fold.ending -> {:refused, :ending}
      not fold.idle -> {:refused, :turn_running}
      true -> others(fold, nil)
    end
  end

  def check(_fold, _line), do: :ok

  defp others(fold, uuid) do
    case Enum.find(fold.messages, fn {u, m} -> u != uuid and m.state != :delivered end) do
      nil -> :ok
      {_, %{state: :writing}} -> {:refused, :message_waiting}
      {u, %{state: :undelivered}} -> {:refused, {:undelivered, u}}
    end
  end

  @doc """
  `Mark` (and `AnswerAsked` for an answer, `EndMarked` for an end): the row says writing before
  anything is written, and the line waits as `:marked` until it is spooled and claimed. The
  write's check found the socket live, so the process is seen (`live_seen`). A message clears
  `idle`; an end marks `ending`, which refuses every later message.
  """
  @spec mark(t, tuple, binary, integer) :: t
  def mark(fold, term, line, at) do
    id = elem(term, 1)
    line = %{kind: elem(term, 0), line: line, phase: :marked}
    fold = %{fold | live_seen: true, lines: Map.put(fold.lines, id, line)}

    case term do
      {:message, uuid, _} ->
        %{fold | idle: false, messages: Map.put(fold.messages, uuid, %{state: :writing, at: at})}

      {:answer, id, _} ->
        settle(fold, :requests, id, :held, :answering)

      {:end_session, _} ->
        %{fold | ending: true}

      _ ->
        fold
    end
  end

  @doc "A line moves to `:spooled`, or is dropped from `lines` once `:claimed`."
  @spec phase(t, String.t(), :spooled | :claimed) :: t
  def phase(fold, id, :claimed), do: %{fold | lines: Map.delete(fold.lines, id)}

  def phase(fold, id, :spooled),
    do: %{fold | lines: Map.update!(fold.lines, id, &%{&1 | phase: :spooled})}

  @doc """
  `ExitSeen`: the delegate is gone and its log read to its end. Each message still writing is
  delivered when the transcript holds its uuid (`taken?`) and undelivered otherwise; a held or
  answering request is lost; an unclaimed line is dropped.
  """
  @spec exit_seen(t, (String.t() -> boolean)) :: t
  def exit_seen(fold, taken?) do
    messages =
      Map.new(fold.messages, fn
        {u, %{state: :writing} = m} ->
          {u, %{m | state: if(taken?.(u), do: :delivered, else: :undelivered)}}

        other ->
          other
      end)

    requests =
      Map.new(fold.requests, fn
        {id, %{state: s} = r} when s in [:held, :answering] -> {id, %{r | state: :lost}}
        other -> other
      end)

    %{fold | gone: true, messages: messages, requests: requests, lines: %{}}
  end

  @doc """
  `FollowAgain`: the row is followed again for a resume. Its offset, messages and requests stay;
  the resumed process reads the next FIFO (`fifo/1`), is not yet seen, has no session id read
  yet and no end marked, and its turn has not begun: a process that exited during a turn ran no
  `result`, and the resumed one starts none of its own.

      iex> alias CodingAgentFramework.Stream.Fold
      iex> fold = Fold.again(%{Fold.new() | idle: false, gone: true})
      iex> {Fold.fifo(fold), fold.idle, fold.gone}
      {"in.1", true, false}
  """
  @spec again(t) :: t
  def again(fold) do
    %{
      fold
      | resumes: fold.resumes + 1,
        gone: false,
        live_seen: false,
        session_id: nil,
        idle: true,
        ending: false
    }
  end

  @doc """
  `HeldTold`: `Sessions` held the process, so a later exit is this process's, whether or not a
  read saw it live. An exit already seen stays seen.
  """
  @spec held(t) :: t
  def held(%{gone: true} = fold), do: fold
  def held(fold), do: %{fold | live_seen: true}

  @doc "The name of the current process's FIFO in the delegate's directory: `in.<resumes>`."
  @spec fifo(t) :: String.t()
  def fifo(fold), do: "in.#{fold.resumes}"

  @doc "Messages still waiting for their replay: the ones the transcript settles at the exit."
  @spec writing(t) :: [String.t()]
  def writing(fold), do: for({u, %{state: :writing}} <- fold.messages, do: u)
end
