defmodule CodingAgentFramework.Mailbox.Transport do
  @moduledoc """
  How a row `Mailbox` marked `sending` settles, one module per transport (`docs/design.md`,
  "Delivery"; `model/tla/Delivery.tla`): each names its evidence and what a restart does to a
  row it left `sending`. The mark, the refusal that undoes it and the unknown that keeps it are
  `Mailbox`'s, once. `waiter` and `typed` come with their units (the waiter's, then R8's), each
  as one more module here, settled by the transcript.

  `settle/2` answers `:keep` (the evidence has not decided), `:delivered`, or `:again` (due
  again, first, under its same uuid). A row an earlier build marked has no `via`: it went by
  the stream.

      iex> alias CodingAgentFramework.Mailbox.Transport
      iex> Transport.settle(%{via: "call", id: 1}, %{calls: %{}, fold: nil})
      :again
  """

  alias CodingAgentFramework.Mailbox.Transport.{Call, Stream}

  @doc "Settles `row` by its transport's evidence: `%{fold: fold | nil, calls: calls}`."
  @spec settle(map, %{fold: map | nil, calls: map}) :: :keep | :delivered | :again
  def settle(%{via: "call"} = row, evidence), do: Call.settle(row, evidence.calls)
  def settle(row, evidence), do: Stream.settle(row, evidence.fold)
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
