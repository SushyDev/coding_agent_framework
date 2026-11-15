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

  **A main session**'s delivery needs `Screen`: its rows stay queued, `attempt` `:no_delivery`.

  It reads every open row again at its start and at each `cue/2` (of `Stream` and `Delegates`);
  after each write `notify` gets `%{topic: "mailbox", ids: [id]}`.
  """

  use GenServer

  alias CodingAgentFramework.{Delegates, Grants, Stream}
  alias CodingAgentFramework.Mailbox.Table

  @step 5_000
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
  What became of message `id`: `{:ok, %{id, from, to, status, attempt}}`, `status` being
  `queued`, `sending`, `delivered` or `ended`; or `{:refused, :no_message}`.
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
              %{id: id, from: m.from_agent, to: m.to_agent, status: m.status, attempt: m.attempt}}

    {:reply, reply, s}
  end

  # Every open row, read against Stream's rows and Delegates' rows; a failed read decides nothing.
  defp settle(s) do
    with {:ok, %{rows: rows}} <- Stream.rows(s.stream, timeout: @step) do
      folds = Map.new(rows, &{&1.session, &1})
      Enum.each(Table.open_rows(s.db), &settle_sending(s, &1, folds))
      agents = Map.new(Delegates.Table.with_status(s.ddb, s.host, @delegates), &{&1.name, &1})

      Table.open_rows(s.db)
      |> Enum.group_by(& &1.to_agent)
      |> Enum.each(fn {to, rows} -> deliver(s, rows, agents[to], folds) end)
    end

    s
  end

  # DeliveryMarked by the replay; SendingSettled by the exit's settle, or by no mark at all.
  defp settle_sending(s, %{status: "sending"} = m, folds) do
    case get_in(folds, [m.session_id, :messages, m.uuid]) do
      %{state: :delivered} -> write(s, m, status: "delivered", attempt: nil)
      %{state: :writing} -> :ok
      _ -> write(s, m, status: "queued")
    end
  end

  defp settle_sending(_s, _m, _folds), do: :ok

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
