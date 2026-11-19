defmodule CodingAgentFramework.Mailbox.Transport do
  @moduledoc """
  How a row `Mailbox` marked `sending` settles, one module per transport (`docs/design.md`,
  "Delivery"; `model/tla/Delivery.tla`): each names its evidence and what a restart does to a
  row it left `sending`. The mark, the refusal that undoes it and the unknown that keeps it are
  `Mailbox`'s, once. `waiter`, `typed` and `launch` are settled by the transcript
  (`Transport.Waiter`, `Transport.Typed`, `Transport.Launch`).

  `settle/2` answers `:keep` (the evidence has not decided), `:delivered`, or `:again` (due
  again, first, under its same uuid). A row an earlier build marked has no `via`: it went by
  the stream.

      iex> alias CodingAgentFramework.Mailbox.Transport
      iex> Transport.settle(%{via: "call", id: 1}, %{calls: %{}, fold: nil})
      :again
  """

  alias CodingAgentFramework.Mailbox.Transport.{Call, Launch, Stream, Typed, Waiter}

  @doc """
  Settles `row` by its transport's evidence: `%{fold: fold | nil, calls: calls}`, and for a
  `waiter` row `waiter:`, as `Waiter.settle/2` reads it, and for a `typed` row `typed:`, as
  `Typed.settle/2` reads it.
  """
  @spec settle(map, map) :: :keep | :delivered | :again
  def settle(%{via: "call"} = row, evidence), do: Call.settle(row, evidence.calls)
  def settle(%{via: "waiter"} = row, evidence), do: Waiter.settle(row, evidence.waiter)
  def settle(%{via: "typed"} = row, evidence), do: Typed.settle(row, evidence.typed)
  def settle(%{via: "launch"} = row, evidence), do: Launch.settle(row, evidence.launch)
  def settle(row, evidence), do: Stream.settle(row, evidence.fold, evidence[:now])

  @doc """
  The sentence that names the file a row's whole text is in, for a row too long to type or to
  launch with (F-142, F-155). The path is in backticks, so a home with a space in it reads as
  one path (F-169's new-3). `Mailbox` frames it with the row's sender, as it frames the text
  itself, so the agent knows whose it is before it reads the file (F-170's new-6); a brief and a
  word to go on, which are not framed, take it with a capital, as `pointer_line(path, false)`.

      iex> CodingAgentFramework.Mailbox.Transport.pointer_line("/h/my home/due/main/7.md")
      "a message for you is in `/h/my home/due/main/7.md`; read it."
  """
  @spec pointer_line(Path.t(), boolean) :: String.t()
  def pointer_line(path, framed \\ true) do
    line = "message for you is in `#{path}`; read it."
    if framed, do: "a " <> line, else: "A " <> line
  end
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

  @doc """
  The mark a row's text carries on its last line, which the transcript keeps.

      iex> CodingAgentFramework.Mailbox.Transport.Waiter.mark("u1")
      "[delivery u1]"
  """
  @spec mark(String.t()) :: String.t()
  def mark(uuid), do: "[delivery " <> uuid <> "]"

  @doc """
  Whether `text` carries a row's mark, of any uuid: a delivery of the framework's, which a
  turn of a delegate's own never begins with (F-155).

      iex> CodingAgentFramework.Mailbox.Transport.Waiter.marked?("Hi. [delivery u1]")
      true
      iex> CodingAgentFramework.Mailbox.Transport.Waiter.marked?("<task-notification>")
      false
  """
  @spec marked?(String.t()) :: boolean
  def marked?(text), do: String.contains?(text, "[delivery ")

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

  A headless start's first row (F-152, `Mailbox.launch/4` with `via: :stream`) is marked before
  the start writes it, with the start's deadline as `sent_at`: until then, a fold with no line
  of it decides nothing, since the start may still write it. The start's answer clears
  `sent_at`.

      iex> alias CodingAgentFramework.Mailbox.Transport.Stream
      iex> Stream.settle(%{uuid: "u1"}, %{messages: %{"u1" => %{state: :undelivered}}})
      :again
      iex> Stream.settle(%{uuid: "u1", sent_at: 100}, nil, 50)
      :keep
  """

  alias CodingAgentFramework.Stream.Fold

  @doc """
  Settles `row` by `fold`, the fold of its session (nil when `Stream` follows none), at `now`
  (wall-clock ms; needed only for a start's first row).
  """
  @spec settle(map, map | nil, integer | nil) :: :keep | :delivered | :again
  def settle(row, fold, now \\ nil) do
    case Fold.outcome(fold || %{messages: %{}}, row.uuid) do
      :writing -> :keep
      :none -> if starting?(row, now), do: :keep, else: :again
      :undelivered -> :again
      _delivered -> :delivered
    end
  end

  defp starting?(%{sent_at: at}, now) when is_integer(at), do: now == nil or now < at
  defp starting?(_row, _now), do: false
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

defmodule CodingAgentFramework.Mailbox.Transport.Typed do
  @moduledoc """
  The `typed` transport: the `Inlet`'s checked write into an interactive session with no waiter
  (`docs/design.md`, "A session with no waiter"; `Delivery.tla`'s `typed`, `Unknown`,
  `SettleSeen`). The text is typed into the session's input box and sent with Enter, so it is
  one line: the row's uuid goes at its end (`text/2`), which the transcript's user line keeps.

  The `Inlet` types only when the turn function it is handed, read in its own step, says the
  turn ended (`turn/2`: the session file reads idle with no waiter held, for the process the row
  was marked for) and the screen shows an empty box. `{:ok, :sent}` says the keys went in, not
  that Claude Code took them, so the row stays `sending` until the transcript decides, as a
  waiter's does: the user line carrying the mark, once the turn it started has ended (or its
  process is gone), is delivered; no line of it past the take bound, or its process gone with no
  line, is due again, first, under its same uuid. An unknown write keeps the mark and is never
  typed again by the `Inlet`; the same evidence settles it.

  The bound runs from `sent_at`. The mark sets it to the latest the hand-on can be (the mark's
  time and the `Inlet`'s call timeout), and the answer to its own time, so a restart between the
  two never makes a row due again while its keys may still go in.

      iex> alias CodingAgentFramework.Mailbox.Transport.Typed
      iex> Typed.text("Done.", "u1")
      "Done. [delivery u1]"
      iex> Typed.settle(%{sent_at: 0}, %{seen: :taken, ended: false, gone: false, now: 1, bound: 10})
      :keep
  """

  alias CodingAgentFramework.Mailbox.Transport.Waiter

  # The longest line typed as the row's own text: under the box of an 80-column pane, the
  # narrowest a session's pane is drawn at, so a short row needs no screen's width to decide.
  @short 76

  @doc "The text typed: the row's text and, at the end of the same line, its uuid."
  @spec text(String.t(), String.t()) :: String.t()
  def text(text, uuid), do: text <> " [delivery " <> uuid <> "]"

  @doc "The longest line typed as a row's own text, in characters."
  @spec short() :: pos_integer
  def short, do: @short

  @doc """
  Whether a row's text is typed as itself (`text/2`): one line of printable characters within
  `short/0`. Any other row is written to a file and typed as `pointer/2` (F-142).

      iex> CodingAgentFramework.Mailbox.Transport.Typed.short?("Done.", "u1")
      true
      iex> CodingAgentFramework.Mailbox.Transport.Typed.short?("Done.\\nAll of it.", "u1")
      false
  """
  @spec short?(String.t(), String.t()) :: boolean
  def short?(text, uuid) do
    line = text(text, uuid)
    String.length(line) <= @short and not Regex.match?(~r/[\x00-\x1f\x7f]/, line)
  end

  @doc """
  The line typed for a row too long to type: `line`, the framed sentence that names the file
  its whole text is in (`Transport.pointer_line/2`), which the session may read, with the uuid
  at its end as `text/2` does. It is typed whatever its length: it is the short form.

      iex> alias CodingAgentFramework.Mailbox.Transport
      iex> line = "From d1 (message): " <> Transport.pointer_line("/h/due/main/7.md")
      iex> Transport.Typed.pointer(line, "u1")
      "From d1 (message): a message for you is in `/h/due/main/7.md`; read it. [delivery u1]"
  """
  @spec pointer(String.t(), String.t()) :: String.t()
  def pointer(line, uuid), do: text(line, uuid)

  @doc """
  What the transcript `bytes` show of the row under `uuid`, as `Waiter.seen/2` reads them: a user
  line with its mark is `:taken`.
  """
  @spec seen(binary, String.t()) :: :taken | :queued | :none
  def seen(bytes, uuid), do: Waiter.seen(bytes, uuid)

  @doc """
  The `Inlet`'s turn check, from `Sessions.Turn.interactive/3` read in the write's step: `:ok`
  for `:idle` (the file reads idle, and no waiter is held) when the row's process is still the
  one the row was marked for. `:ended` means a waiter is held now, which is the `waiter`
  transport's.

      iex> CodingAgentFramework.Mailbox.Transport.Typed.turn(:idle, true)
      :ok
      iex> CodingAgentFramework.Mailbox.Transport.Typed.turn(:running, true)
      {:refused, :running}
  """
  @spec turn(atom, boolean) :: :ok | {:refused, term}
  def turn(_state, false), do: {:refused, :other_process}
  def turn(:idle, true), do: :ok
  def turn(:ended, true), do: {:refused, :waiter}
  def turn(state, true), do: {:refused, state}

  @doc """
  Whether a row's stored `attempt` says the `Inlet` refused its text itself (too long, or a
  control character in it): such a row waits for a waiter, and is not typed again.

      iex> CodingAgentFramework.Mailbox.Transport.Typed.text_refused?(~s(["too_long",116]))
      true
  """
  @spec text_refused?(String.t() | nil) :: boolean
  def text_refused?(attempt) when is_binary(attempt) do
    match?({:ok, [kind | _]} when kind in ["too_long", "bad_text"], JSON.decode(attempt))
  end

  def text_refused?(_attempt), do: false

  @doc """
  Settles `row` by `evidence`: `%{seen: seen/2's answer | :unread, ended: whether the session's
  turn reads ended or idle now, gone: whether the process it was typed into is gone, now:
  wall-clock ms, bound: the take bound}`.
  """
  @spec settle(map, map) :: :keep | :delivered | :again
  def settle(_row, %{seen: :unread}), do: :keep
  def settle(_row, %{seen: :taken, gone: true}), do: :delivered
  def settle(_row, %{seen: :taken, ended: ended}), do: if(ended, do: :delivered, else: :keep)
  def settle(_row, %{gone: true}), do: :again
  def settle(_row, %{seen: :queued}), do: :keep

  def settle(row, %{now: now, bound: bound}),
    do: if(now >= row.sent_at + bound, do: :again, else: :keep)
end

defmodule CodingAgentFramework.Mailbox.Transport.Launch do
  @moduledoc """
  The `launch` transport (F-137; `Delivery.tla`'s `Launch`): the first row to an interactive
  session (a delegate's brief, its word to go on at a resume) is the prompt argument of the
  session's start, and Claude Code runs it as the session's first turn. The row is marked before
  the start (`Mailbox.launch/4`, by the part that starts the session) and told the start's
  answer (`Mailbox.launched/3`): a refused start makes it due again, under its same uuid; a
  start that runs, or one whose answer is unknown, waits for the transcript.

  The text carries the row's uuid on a last line of its own, as a waiter's does
  (`Transport.Waiter.text/2`). The delivery is the launch's own line (`seen/2`): a user line
  whose text is the prompt, its mark last, as Claude Code 2.1.322 writes the first turn of a
  start (`promptSource` `typed`); never a waiter's `Stop hook blocking error` line, which would
  be a second delivery.

  With no such line, the row is due again only once no process of the start runs. No bound
  stands for the take: a startup dialog (the trust dialog, the imports dialog) holds the first
  turn until a person answers it, minutes or more, and the row is never handed to another
  transport while its process lives (F-153's new-1; `Delivery.tla`'s `SettleSeen` and
  `Break_Delivery_LaunchBound`). A transcript that could not be read decides nothing.

      iex> alias CodingAgentFramework.Mailbox.Transport.Launch
      iex> Launch.settle(%{sent_at: 0}, %{seen: :taken, gone: true, now: 0, bound: 10_000})
      :delivered
      iex> Launch.settle(%{sent_at: 0}, %{seen: :none, gone: false, now: 3_600_000, bound: 10_000})
      :keep
      iex> Launch.settle(%{sent_at: 0}, %{seen: :none, gone: true, now: 5_000, bound: 10_000})
      :again
  """

  alias CodingAgentFramework.Mailbox.Transport.Waiter

  @doc "The prompt a start carries: the row's text and its uuid, as `Waiter.text/2`."
  @spec text(String.t(), String.t()) :: String.t()
  def text(text, uuid), do: Waiter.text(text, uuid)

  @doc """
  What the transcript `bytes` (whole lines) show of the launch of the row under `uuid`:
  `:taken` for a user line whose text ends with its mark, else `:none`. A queued line or a
  waiter's line (its mark inside a `system-reminder`) is not the launch's.

      iex> alias CodingAgentFramework.Mailbox.Transport.Launch
      iex> line = ~s({"type":"user","message":{"role":"user","content":"Go.\\\\n\\\\n[delivery u1]"}}\\n)
      iex> Launch.seen(line, "u1")
      :taken
      iex> Launch.seen(String.replace(line, "u1]", "u1]\\\\n\\\\n</system-reminder>"), "u1")
      :none
  """
  @spec seen(binary, String.t()) :: :taken | :none
  def seen(bytes, uuid) do
    mark = Waiter.mark(uuid)

    bytes
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, uuid))
    |> Enum.any?(&launch?(&1, mark))
    |> if(do: :taken, else: :none)
  end

  defp launch?(line, mark) do
    case JSON.decode(line) do
      {:ok, %{"type" => "user", "message" => %{"content" => c}}} ->
        c |> text_of() |> String.trim_trailing() |> String.ends_with?(mark)

      _ ->
        false
    end
  end

  defp text_of(c) when is_binary(c), do: c

  defp text_of(c) when is_list(c),
    do: Enum.map_join(c, "\n", &if(is_map(&1), do: to_string(&1["text"]), else: ""))

  defp text_of(_), do: ""

  @doc """
  The prompt a start carries for a row longer than the host's argument holds: `line`, the
  sentence that names the file its whole text is in (`Transport.pointer_line/2`, in the agent's
  due directory, which each interactive start may read), and its uuid, as `text/2` (F-155).

      iex> alias CodingAgentFramework.Mailbox.Transport
      iex> Transport.Launch.pointer(Transport.pointer_line("/h/due/main/7.md", false), "u1")
      "A message for you is in `/h/due/main/7.md`; read it.\\n\\n[delivery u1]"
  """
  @spec pointer(String.t(), String.t()) :: String.t()
  def pointer(line, uuid), do: text(line, uuid)

  @doc """
  Settles `row` by `evidence`: `%{seen: seen/2's answer | :unread, gone: whether no process of
  the start runs}`. Any other key (`now`, `bound`) decides nothing.
  """
  @spec settle(map, map) :: :keep | :delivered | :again
  def settle(_row, %{seen: :unread}), do: :keep
  def settle(_row, %{seen: :taken}), do: :delivered
  def settle(_row, %{gone: true}), do: :again
  def settle(_row, _evidence), do: :keep
end
