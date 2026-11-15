defmodule CodingAgentFramework.Stream.Fold do
  @moduledoc """
  The pure fold of one headless delegate: its event log read from an offset, and the rows of
  what the framework wrote to it. `model/tla/Stream.tla` models it; each function names the spec
  action it does.

  `take/2` reads whole lines only: a last line without its newline is still being written and
  waits for the next read. Each event writes what `Stream.tla`'s `Handle` says: a replay
  delivers its message, a `result` ends the turn, a `can_use_tool` request is held, an answer's
  replay answers it, a cancel cancels it. It also keeps the session id of `system`/`init` and the
  latest `rate_limit_event`. It is total: a line that is not a JSON object is counted as a problem.

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
    result = %{subtype: e["subtype"], is_error: e["is_error"], user_message_uuids: uuids}
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
  Whether `line` may be marked now, and why not: a message needs the turn ended (`idle`) and no
  other message waiting for its replay; an answer needs its request held; an end needs the turn
  ended.
  """
  @spec check(t, tuple) :: :ok | {:refused, term}
  def check(%{gone: true}, _line), do: {:refused, :gone}

  def check(fold, {:message, uuid, _}) do
    cond do
      Map.has_key?(fold.messages, uuid) ->
        {:refused, :duplicate_uuid}

      not fold.idle ->
        {:refused, :turn_running}

      Enum.any?(fold.messages, fn {_, m} -> m.state == :writing end) ->
        {:refused, :message_waiting}

      true ->
        :ok
    end
  end

  def check(fold, {:answer, id, _}) do
    case fold.requests[id] do
      %{state: :held} -> :ok
      nil -> {:refused, :no_request}
      %{state: state} -> {:refused, {:request, state}}
    end
  end

  # An end cuts a running turn ("Headless delegates", "Ending").
  def check(%{idle: false}, {:end_session, _}), do: {:refused, :turn_running}

  def check(_fold, _line), do: :ok

  @doc """
  `Mark` (and `AnswerAsked` for an answer): the row says writing before anything is written, and
  the line waits as `:marked` until it is spooled and claimed. A message clears `idle`.
  """
  @spec mark(t, tuple, binary, integer) :: t
  def mark(fold, term, line, at) do
    id = elem(term, 1)

    fold = %{
      fold
      | lines: Map.put(fold.lines, id, %{kind: elem(term, 0), line: line, phase: :marked})
    }

    case term do
      {:message, uuid, _} ->
        %{fold | idle: false, messages: Map.put(fold.messages, uuid, %{state: :writing, at: at})}

      {:answer, id, _} ->
        settle(fold, :requests, id, :held, :answering)

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

  @doc "Messages still waiting for their replay: the ones the transcript settles at the exit."
  @spec writing(t) :: [String.t()]
  def writing(fold), do: for({u, %{state: :writing}} <- fold.messages, do: u)
end
