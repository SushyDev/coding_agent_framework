defmodule CodingAgentFramework.Mailbox do
  @moduledoc """
  Messages along the tree's edges (`docs/design.md`, "Agents working together", "Messages";
  `model/tla/Team.tla`'s `Send`, `DeliveryAsked`, `DeliveryTyped`, `DeliveryRefused`,
  `DeliveryMarked`, `SendingSettled`, `EndedFirst`). The caller's supervision tree starts one,
  with no name:

      {:ok, mailbox} = Mailbox.start_link(db: db, grants: grants, stream: stream,
        delegates_db: db, host: "laptop")
      Mailbox.message(mailbox, "app-main", "app-unit-review", "Rebase on main first.")
      #=> {:ok, {:queued, 1}}

  **A message** is checked by `Grants.may_message?/3`, then stored `queued` before anything else.

  **A delegate** (the latest `Delegates` row of its name) takes one only into an ended turn: its
  row is `finished` (its brief's turn ended, its report held) and its `Stream` row idle, live and
  not ending. Its oldest queued message, while none to it is under way (so each sender's go in
  order), is marked `sending` with the session, then written through `Stream` under the uuid it
  was stored with. A `sending` row settles from `Stream`'s row: `delivered` by its replay, or
  `queued` again, same uuid, when the exit found it undelivered or `Stream` never marked it;
  never written again while it may be in the pipe. A dead delegate's messages wait. One whose
  session ended (`end_session` marked, process gone), or whose start was refused, has its
  queued messages settled `ended`.

  **A reply**: a delivered message's turn ends with a `result` that names its uuid; that result's
  text is stored as a message from the delegate to its main session (its `Delegates` row's
  `parent`), `reply_to` the answered message's uuid, with the result's `subtype` and
  `is_error`, so a failed turn is told from an answer. **A notice**: when the process ended
  during the message's turn with no result (`Stream.Fold.outcome/2`'s `:exited`), a message
  from `"framework"` says so in place of the reply, under the same `reply_to`. The table's
  unique index on `reply_to` lets in one of them, once.

  **A main session**'s delivery needs `Screen`: its rows stay queued, `attempt` `:no_delivery`.

  It reads every open row again at its start and at each `cue/2` (of `Stream` and `Delegates`);
  after each write `notify` gets `%{topic: "mailbox", ids: [id]}`.
  """

  use GenServer

  alias CodingAgentFramework.{Delegates, Grants, Stream}
  alias CodingAgentFramework.Mailbox.Table
  alias CodingAgentFramework.Stream.Fold

  @step 5_000
  # The sender of a notice; no agent has this name, as an agent's name holds its project's.
  @framework "framework"
  @delegates ~w(starting resuming running finished failed refused)

  @doc """
  Starts a `Mailbox`. Options: `db:`, `grants:`, `stream:` and `host:` (where the delegates
  run), `delegates_db:` (the file of `Delegates`' table), and optionally `notify:`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Sends `text` from agent `from` to agent `to`: `{:ok, {:queued, id}}` once its row is stored,
  or `{:refused, reason}` with no row (`Grants`' reason, or `{:bad, :message}`).
  """
  def message(mailbox, from, to, text, opts \\ []),
    do: call(mailbox, {:message, from, to, text}, opts)

  @doc """
  What became of message `id`: `{:ok, %{id, from, to, status, attempt, reply_to, subtype,
  is_error}}`, `status` being `queued`, `sending`, `delivered` or `ended`, `reply_to` the uuid
  of the message a delegate's reply or the framework's notice answers (nil for any other), and
  `subtype` and `is_error` a reply's result's; or `{:refused, :no_message}`.
  """
  def status(mailbox, id, opts \\ []), do: call(mailbox, {:status, id}, opts)

  @doc "Hands it a reader's cue: every open row is read again. Answers `:ok` at once."
  def cue(mailbox, %{topic: _}), do: GenServer.cast(mailbox, :cue)

  defp call(mailbox, request, opts) do
    timeout = Keyword.get(opts, :timeout, @step)
    GenServer.call(mailbox, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_mailbox}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @step)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         {:ok, ddb} <- Delegates.Table.open(Keyword.fetch!(opts, :delegates_db)) do
      s = Map.new(~w(grants stream host)a, &{&1, Keyword.fetch!(opts, &1)})
      notify = Keyword.get(opts, :notify, fn _ -> :ok end)
      {:ok, Map.merge(s, %{db: db, ddb: ddb, notify: notify}), {:continue, :read}}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  # A restart settles what it finds marked, from Stream's rows read to the end of each log.
  @impl true
  def handle_continue(:read, s) do
    Stream.read(s.stream, timeout: @step)
    {:noreply, settle(s)}
  end

  def handle_continue(:settle, s), do: {:noreply, settle(s)}

  @impl true
  def handle_cast(:cue, s), do: {:noreply, settle(s)}

  @impl true
  def handle_call({:message, from, to, text}, _from, s) do
    with true <-
           Enum.all?([from, to, text], &(is_binary(&1) and &1 != "")) or
             {:refused, {:bad, :message}},
         :ok <- Grants.may_message?(s.grants, from, to) do
      # Send: the row first; delivery follows the reply.
      id = Table.queued(s.db, from, to, text, Stream.uuid())
      announce(s, id)
      {:reply, {:ok, {:queued, id}}, s, {:continue, :settle}}
    else
      refused -> {:reply, refused, s}
    end
  end

  def handle_call({:status, id}, _from, s) do
    reply =
      with %{} = m <- Table.get(s.db, id) || {:refused, :no_message},
           do:
             {:ok,
              %{
                id: id,
                from: m.from_agent,
                to: m.to_agent,
                status: m.status,
                attempt: m.attempt,
                reply_to: m.reply_to,
                subtype: m.subtype,
                is_error: %{1 => true, 0 => false}[m.is_error]
              }}

    {:reply, reply, s}
  end

  # Every open row, read against Stream's rows and Delegates' rows; a failed read decides nothing.
  defp settle(s) do
    with {:ok, %{rows: rows}} <- Stream.rows(s.stream, timeout: @step) do
      folds = Map.new(rows, &{&1.session, &1})
      Enum.each(Table.open_rows(s.db), &settle_sending(s, &1, folds))
      agents = Map.new(Delegates.Table.with_status(s.ddb, s.host, @delegates), &{&1.name, &1})
      replies(s, folds, agents)

      Table.open_rows(s.db)
      |> Enum.group_by(& &1.to_agent)
      |> Enum.each(fn {to, rows} -> deliver(s, rows, agents[to], folds) end)
    end

    s
  end

  # DeliveryMarked by the replay; SendingSettled by the exit's settle, or by no mark at all.
  defp settle_sending(s, %{status: "sending"} = m, folds) do
    case Fold.outcome(folds[m.session_id] || %{messages: %{}}, m.uuid) do
      :writing -> :ok
      outcome when outcome in [:none, :undelivered] -> write(s, m, status: "queued")
      _delivered -> write(s, m, status: "delivered", attempt: nil)
    end
  end

  defp settle_sending(_s, _m, _folds), do: :ok

  # ReplyStored and NoticeStored: a delivered message's turn ended with a result that names it
  # (the fold keeps it on the message, so a later turn's never replaces it), or its process
  # ended with none (`:exited`). Either one row goes to the main session under the message's
  # uuid, whose unique index lets in one reply or one notice, across restarts and cues.
  defp replies(s, folds, agents) do
    for {sid, fold} <- folds,
        ended = for({u, _} <- fold.messages, turn_ended?(Fold.outcome(fold, u)), do: u),
        m <- Table.unanswered(s.db, sid, ended),
        %{parent: main} <- [agents[m.to_agent]],
        do: answer(s, m, main, Fold.outcome(fold, m.uuid))
  end

  defp turn_ended?({:result, _}), do: true
  defp turn_ended?(outcome), do: outcome == :exited

  defp answer(s, m, main, {:result, r}),
    do: stored(s, Table.reply(s.db, m.to_agent, main, r.text, Stream.uuid(), m.uuid, r))

  defp answer(s, m, main, :exited),
    do: stored(s, Table.reply(s.db, @framework, main, notice(m), Stream.uuid(), m.uuid))

  defp notice(m),
    do:
      "Your message #{m.id} went in to #{m.to_agent}, and its process ended before it " <>
        "answered: no reply will come. Resume it to ask again."

  defp stored(_s, nil), do: :ok
  defp stored(s, id), do: announce(s, id)

  # A main session: no delivery until Screen.
  defp deliver(s, rows, nil, _folds) do
    for m <- rows, m.attempt != ":no_delivery", do: write(s, m, attempt: :no_delivery)
  end

  defp deliver(s, rows, d, folds) do
    fold = folds[d.session_id]

    cond do
      # EndedFirst: queued rows only; a sending one is settled first.
      ended?(d, fold) ->
        for %{status: "queued"} = m <- rows, do: write(s, m, status: "ended")

      Enum.any?(rows, &(&1.status == "sending")) or not ready?(d, fold) ->
        :ok

      true ->
        typed(s, hd(rows), d)
    end
  end

  # DeliveryAsked, then the write: refused leaves nothing marked in Stream (DeliveryRefused);
  # unknown stays sending for Stream's row to settle.
  defp typed(s, m, d) do
    write(s, m, status: "sending", session_id: d.session_id)

    case Stream.write(s.stream, d.session_id, {:message, m.uuid, m.text}, timeout: @step) do
      {:ok, _} -> :ok
      {:refused, why} -> write(s, m, status: "queued", attempt: why)
      {:unknown, why} -> write(s, m, attempt: why)
    end
  end

  # Its brief's turn ended with its report held, and its process takes a line now.
  defp ready?(%{status: "finished"}, %{} = f), do: f.idle and not f.gone and not f.ending
  defp ready?(_d, _fold), do: false

  defp ended?(%{status: "refused"}, _fold), do: true
  defp ended?(_d, fold), do: match?(%{gone: true, ending: true}, fold)

  defp write(s, m, fields) do
    Table.update(s.db, m.id, fields)
    announce(s, m.id)
  end

  defp announce(s, id), do: s.notify.(%{topic: "mailbox", ids: [id]})
end
