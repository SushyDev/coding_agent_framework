defmodule CodingAgentFramework.Mailbox.Transport do
  @moduledoc """
  How a row `Mailbox` marked `sending` settles, one module per transport (`docs/design.md`,
  "Delivery"; `model/tla/Delivery.tla`): each names its evidence and what a restart does to a
  row it left `sending`. The mark, the refusal that undoes it and the unknown that keeps it are
  `Mailbox`'s, once. `waiter` is settled by the transcript (`Transport.Waiter`); `typed` comes
  with R8, as one more module here.

  `settle/2` answers `:keep` (the evidence has not decided), `:delivered`, or `:again` (due
  again, first, under its same uuid). A row an earlier build marked has no `via`: it went by
  the stream.

      iex> alias CodingAgentFramework.Mailbox.Transport
      iex> Transport.settle(%{via: "call", id: 1}, %{calls: %{}, fold: nil})
      :again
  """

  alias CodingAgentFramework.Mailbox.Transport.{Call, Stream, Waiter}

  @doc """
  Settles `row` by its transport's evidence: `%{fold: fold | nil, calls: calls}`, and for a
  `waiter` row `waiter:`, as `Waiter.settle/2` reads it.
  """
  @spec settle(map, map) :: :keep | :delivered | :again
  def settle(%{via: "call"} = row, evidence), do: Call.settle(row, evidence.calls)
  def settle(%{via: "waiter"} = row, evidence), do: Waiter.settle(row, evidence.waiter)
  def settle(row, evidence), do: Stream.settle(row, evidence.fold)
end

defmodule CodingAgentFramework.Mailbox.Transport.Waiter do
  @moduledoc """
  The `waiter` transport: the answer to an interactive session's waiting Stop hook, handed on by
  `Intake.deliver/5` (`docs/design.md`, "Delivery into a main session"; `Delivery.tla`'s
  `SettleSeen`, `wire`). `{:ok, :sent}` says the text was written to the hook, not that Claude
  Code read it, so the row stays `sending` until the session's transcript decides.

  The text carries the row's uuid on a last line of its own (`text/2`), which the transcript
  keeps, so the settle finds this row's lines and never a look-alike. Claude Code 2.1.322
  writes, within about a second of the hook's exit, a `queue-operation` line `enqueue` whose
  `content` holds the text: it reached Claude Code's queue. Then it takes it: into an ended turn
  as a `dequeue` and a user line (`Stop hook blocking error from command "Stop": …`), or into
  a running turn at its next tool boundary as a `remove` and an `attachment` of type
  `queued_command` (measured by the main session for F-127). Either is delivery.

  The take bound (`take_bound:` of `Mailbox`, 10 s by default) is how long after the hand-on
  the `enqueue` line has come or never will: with no line of the row past it, or with its
  process gone and no take, the row is due again, first, under its same uuid. Enqueued and not
  yet taken, it waits for the take. A restart changes nothing: the same evidence settles it. A
  row marked and never handed on (`sent_at` nil: a restart between the two) is due again.

      iex> alias CodingAgentFramework.Mailbox.Transport.Waiter
      iex> line = ~s({"type":"queue-operation","operation":"dequeue","content":"hi\\\\n\\\\n[delivery u1]"}\\n)
      iex> Waiter.seen(line, "u1")
      :taken
      iex> Waiter.settle(%{sent_at: 0}, %{seen: :none, gone: false, now: 20_000, bound: 10_000})
      :again
  """

  @doc """
  The text handed to the waiter: the row's text and, on a last line of its own, its uuid.

      iex> CodingAgentFramework.Mailbox.Transport.Waiter.text("Done.", "u1")
      "Done.\\n\\n[delivery u1]"
  """
  @spec text(String.t(), String.t()) :: String.t()
  def text(text, uuid), do: text <> "\n\n" <> mark(uuid)

  defp mark(uuid), do: "[delivery " <> uuid <> "]"

  @doc """
  What the transcript `bytes` (whole lines) show of the row stored under `uuid`: `:taken` (a
  `dequeue` or `remove`, a user line or a `queued_command` attachment carrying its mark),
  `:queued` (only its `enqueue`), or `:none`.
  """
  @spec seen(binary, String.t()) :: :taken | :queued | :none
  def seen(bytes, uuid) do
    mark = mark(uuid)

    bytes
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, uuid))
    |> Enum.map(&line(&1, mark))
    |> Enum.reduce(:none, fn
      :taken, _ -> :taken
      :queued, :none -> :queued
      _, seen -> seen
    end)
  end

  defp line(text, mark) do
    case JSON.decode(text) do
      {:ok, %{"type" => "queue-operation", "operation" => op, "content" => c}}
      when is_binary(c) ->
        cond do
          not String.contains?(c, mark) -> :none
          op == "enqueue" -> :queued
          op in ["dequeue", "remove"] -> :taken
          true -> :none
        end

      {:ok, %{"attachment" => %{"type" => "queued_command", "prompt" => p}}} when is_binary(p) ->
        if String.contains?(p, mark), do: :taken, else: :none

      {:ok, %{"type" => "user", "message" => %{"content" => c}}} ->
        if String.contains?(content(c), mark), do: :taken, else: :none

      _ ->
        :none
    end
  end

  defp content(c) when is_binary(c), do: c

  defp content(c) when is_list(c),
    do: Enum.map_join(c, "\n", &if(is_map(&1), do: to_string(&1["text"]), else: ""))

  defp content(_), do: ""

  @doc """
  Settles `row` by `evidence`: `%{seen: seen/2's answer | :unread, gone: whether the process the
  row was handed to is gone, now: wall-clock ms, bound: the take bound}`. A transcript that could
  not be read decides nothing.
  """
  @spec settle(map, map) :: :keep | :delivered | :again
  def settle(_row, %{seen: :unread}), do: :keep
  def settle(_row, %{seen: :taken}), do: :delivered
  def settle(%{sent_at: nil}, _evidence), do: :again
  def settle(_row, %{gone: true}), do: :again
  def settle(_row, %{seen: :queued}), do: :keep

  def settle(row, %{now: now, bound: bound}),
    do: if(now >= row.sent_at + bound, do: :again, else: :keep)
end

defmodule CodingAgentFramework.Mailbox.Transport.Stream do
  @moduledoc """
  The `stream` transport: a headless session's FIFO line, written by `Stream` under the row's
  uuid (`Delivery.tla`'s `SettleReplay`, `SettleExit`). Its evidence is the session's fold: the
  replay while the process runs, and at its exit the transcript, which the fold records.
  Undelivered is final, since no line of an earlier process reaches a later one: the row is due
  again, first, and goes to the resumed process under its same uuid. A row the fold never
  marked (a restart between the mark and the write, or a write refused) is due again too:
  nothing of it went in. A restart changes nothing else: the same evidence settles the row once
  read.

      iex> alias CodingAgentFramework.Mailbox.Transport.Stream
      iex> Stream.settle(%{uuid: "u1"}, %{messages: %{"u1" => %{state: :undelivered}}})
      :again
  """

  alias CodingAgentFramework.Stream.Fold

  @doc "Settles `row` by `fold`, the fold of its session (nil when `Stream` follows none)."
  @spec settle(map, map | nil) :: :keep | :delivered | :again
  def settle(row, fold) do
    case Fold.outcome(fold || %{messages: %{}}, row.uuid) do
      :writing -> :keep
      outcome when outcome in [:none, :undelivered] -> :again
      _delivered -> :delivered
    end
  end
end

defmodule CodingAgentFramework.Mailbox.Transport.Call do
  @moduledoc """
  The `call` transport: the answer of a waiting `run_delegate`, inside the turn that called
  (`Delivery.tla`'s `Told`, `CallerSeen`, `SettleCut`). The row is taken for the call before its
  deadline and stays `sending` until the caller says how the endpoint's write went: written, it
  is delivered; failed, it is due again. `Mailbox` watches the process that waits: its end makes
  the row due again. A restart ends every call with the node, so a row whose call is not in
  `calls` (memory) is due again, for another transport.

      iex> CodingAgentFramework.Mailbox.Transport.Call.settle(%{id: 4}, %{4 => :ref})
      :keep
  """

  @doc "Settles `row` by `calls`, the calls in memory by row id."
  @spec settle(map, map) :: :keep | :again
  def settle(row, calls), do: if(Map.has_key?(calls, row.id), do: :keep, else: :again)
end
