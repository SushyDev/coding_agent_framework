defmodule CodingAgentFramework.Mailbox do
  @moduledoc """
  Every delivery (`docs/design.md`, "Delivery", "Agents working together", "Messages";
  `model/tla/Delivery.tla`): a message, the app's word, a delegate's brief and its word to go on
  after a resume, a reply, the framework's notice in a reply's place, and the report, which is
  the reply to the brief. Each is one row of `Mailbox.Table`, with one mark and one settle; only
  the transport differs (`Mailbox.Transport`). The caller's supervision tree starts one per
  host, with no name:

      {:ok, mailbox} = Mailbox.start_link(db: db, grants: grants, stream: stream,
        sessions_db: db, host: "laptop")
      Mailbox.message(mailbox, "app-main", "app-unit-review", "Rebase on main first.")
      #=> {:ok, {:queued, 1}}

  **Stored first.** A message is checked by `Grants.may_message?/3`, then stored `queued`
  before anything else. `Delegates` stores a delegate's brief (`brief/5`) before it starts it,
  the word to go on (`go_on/4`) before it resumes it, and its report (`report/5`) once its turn
  ended.

  **The mark.** Per addressee, while no row to it is `sending`, the first `queued` row (one made
  due again first, then the oldest) is marked `sending` with its transport and the process it
  is for, then handed on. A refusal undoes the mark; an unknown answer keeps it for the
  evidence. The transport is the addressee's:

  - `stream`, for a headless delegate (its agent row, read through `Sessions.Agents`): only
    into an ended turn of its current process (`Stream`'s fold idle, live, no end marked, its
    agent row
    `running`), written through `Stream` under the row's uuid;
  - `call`, for a reply or a notice a waiting `run_delegate` takes (`await/4`), only before the
    call's deadline; `told/3` settles it, and the end of the process that waits makes it due
    again;
  - `waiter`, for an interactive session (any agent row not headless), when `Mailbox` was
    given `intake:`: only while its row is `running` and `Intake` holds a waiter for it, into
    an ended turn or queued by Claude Code into a running one, handed to `Intake.deliver/5`
    with the row's uuid on a last line (`Transport.Waiter`). `{:ok, :sent}` keeps the row
    `sending`: the session's transcript, read through `transcripts:` at the account's
    directory (`accounts:`), settles it, or `take_bound:` ms (10 s by default) with no line
    makes it due again. With no waiter its rows stay `queued`, `attempt` `:no_waiter`, until
    `Intake`'s waiter cue;
  - `typed` is R8's. Without `intake:` a main session's rows stay `queued`, `attempt`
    `:no_delivery`, unless a call takes them.

  **Answers.** A delivered message's turn ends with a `result` that names its uuid; that
  result's text is stored as a reply from the delegate to the message's sender (to its parent,
  the sender of its brief, for a message from `framework`), `reply_to` the message's uuid, with
  the result's `subtype` and `is_error`. When the process ended during the message's turn with
  no result, a notice from `"framework"` says so in its place. The table's unique `reply_to`
  lets in one answer per row. The answers to a brief or a word to go on are `Delegates'`: it
  decides between a finish, a resume and a second kill, and hands the report here.

  **Ended.** Once a delegate's session ended for good (its `end_session` went in and its
  process is gone, or its agent row says it ended), or its start was refused (`ended/3`), its
  `queued` rows are settled `ended`.

  It reads every open row again at its start, at each `cue/2` (of `Stream`, `Sessions`,
  `Delegates`, `Transcripts` and `Intake`'s waiters, as `reads/0` declares; a waiter row's
  transcript only on the last two) and at a waiter row's take bound; after each write
  `notify` gets `%{topic: "mailbox", ids: [id]}`.
  """

  use GenServer

  alias CodingAgentFramework.{Accounts, Grants, Intake, Stream, Transcripts}
  alias CodingAgentFramework.Sessions.{Agents, Turn}
  alias CodingAgentFramework.Mailbox.{Table, Transport}
  alias CodingAgentFramework.Stream.Fold

  @step 5_000
  # The take bound (`docs/design.md`, "Delivery"): Claude Code 2.1.322 writes the `enqueue`
  # line within about a second of the waiter's answer (measured for F-127).
  @take_bound 10_000
  # The sender of a notice and of the words to go on; no agent has this name, as an agent's
  # name holds its project's.
  @framework "framework"

  @doc """
  Starts a `Mailbox`. Options: `db:`, `grants:`, `stream:` and `host:` (where the delegates
  run), `sessions_db:` (the file of `Sessions`' table, read through `Sessions.Agents`), and
  optionally `notify:`; for the
  waiter transport, `intake:` with `transcripts:` and `accounts:` (an `Accounts`), and
  `take_bound:` (ms, 10 000 by default).
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
  Stores `text` as a message from `framework` to agent `to`, delivered as any message is: the
  embedding app's word to an agent, such as a job's late end. `to` must be an agent the tree
  holds (`Grants.may_use?/2`), not the operator. Option `:key`: a message stored under the same key before is
  not stored again, so a repeat of one event (a late end handed twice) is dropped. Answers
  `{:ok, {:queued, id}}`, `{:ok, :stored_before}`, or `{:refused, reason}` with no row.

      Mailbox.notify(mailbox, "app-main", "Job mcp-a-7 ended: exit 0.", key: "job:mcp-a-7")
      #=> {:ok, {:queued, 9}}
  """
  def notify(mailbox, to, text, opts \\ []),
    do: call(mailbox, {:notify, to, text, Keyword.get(opts, :key)}, opts)

  @doc """
  Stores delegate `to`'s brief from its parent `from` under `uuid`, the uuid `Delegates` chose
  before its start: `{:ok, {:queued, id}}`, or `{:ok, :stored_before}` when a row of `uuid` is
  stored already. No `Grants` check: `Delegates` checked the start.

      Mailbox.brief(mailbox, "app-main", "app-unit-review", "Review it.", uuid)
      #=> {:ok, {:queued, 3}}
  """
  def brief(mailbox, from, to, text, uuid),
    do: store(mailbox, %{from: from, to: to, text: text, uuid: uuid, kind: "brief"})

  @doc """
  Stores the word a resumed delegate `to` gets to go on with its brief, from `framework`, under
  `uuid`: it goes before every other row due to `to`, as a resend does. Answers as `brief/5`.
  """
  def go_on(mailbox, to, text, uuid) do
    row = %{from: @framework, to: to, text: text, uuid: uuid, kind: "resume", again: true}
    store(mailbox, row)
  end

  @doc """
  Stores delegate `from`'s report to its parent `to`, as the answer to its brief's uuid `key`:
  `{:reply, text, result}` (a finish, from the delegate, with the result's `subtype` and
  `is_error`), or `{:notice, text}` (a second kill or a refused resume, from `framework`).
  Answers `{:ok, {:queued, id}}`, or `{:ok, :stored_before}` when `key` has an answer already.

      Mailbox.report(mailbox, "app-unit-review", "app-main", brief_uuid, {:reply, "Done.", %{}})
      #=> {:ok, {:queued, 5}}
  """
  def report(mailbox, from, to, key, answer) do
    row =
      case answer do
        {:reply, text, result} ->
          %{from: from, kind: "reply", text: text, subtype: result[:subtype]}
          |> Map.put(:is_error, result[:is_error])

        {:notice, text} ->
          %{from: @framework, kind: "notice", text: text}
      end

    store(mailbox, Map.merge(row, %{to: to, uuid: Stream.uuid(), reply_to: key}))
  end

  @doc """
  Delegate `to` will never take a row: its start was refused. Its `queued` rows are settled
  `ended`. Answers `{:ok, ids}`.
  """
  def ended(mailbox, to, opts \\ []), do: call(mailbox, {:ended, to}, opts)

  @doc """
  Waits up to `timeout` ms for the answer to the row stored under `key` (a delegate's report,
  the answer to its brief) to `to`, and takes it for a call that answers with it
  (`run_delegate`): the `call` transport. Once it is `queued`, first among `to`'s rows from its
  sender, no row to `to` is `sending`, and only before the deadline, it is marked `sending` by
  the call in the same step, so it goes no other way. The caller then says `told/3`, from the
  process that waited: when that process ends first, the row is due again. Answers `{:ok, %{id,
  from, kind, text}}`; `{:unknown, :timeout}` at the deadline, the row then due as any other;
  or `{:refused, reason}`: `:awaited` (another call waits on it), `{:status, status}` for one
  already taken, delivered or ended.

      Mailbox.await(mailbox, "app-main", brief_uuid, 60_000)
      #=> {:ok, %{id: 5, from: "app-unit-review", kind: "reply", text: "Done."}}
  """
  def await(mailbox, to, key, timeout) when is_integer(timeout) and timeout >= 0 do
    # The deadline is the caller's, on the node's clock: a request that waits in the queue does
    # not move it, so the row is never taken after the caller stopped waiting.
    deadline = System.monotonic_time(:millisecond) + timeout
    call(mailbox, {:await, to, key, deadline}, timeout: timeout + @step)
  end

  @doc """
  How the endpoint's write of row `id`, which `await/4` took, went: `:written` makes it
  `delivered`, anything else due again, first. Answers `{:ok, :delivered}`, `{:ok, :queued}`,
  or `{:refused, {:not_taken, status}}`.
  """
  def told(mailbox, id, written), do: call(mailbox, {:told, id, written}, [])

  @doc """
  What became of row `id`: `{:ok, %{id, from, to, kind, status, via, attempt, reply_to, subtype,
  is_error}}`, `status` being `queued`, `sending`, `delivered` or `ended`, `reply_to` the uuid
  of the row an answer answers (`key:<key>` for a `notify/4` stored under a key, nil for any
  other), and `subtype` and `is_error` a reply's result's; or `{:refused, :no_message}`.
  """
  def status(mailbox, id, opts \\ []), do: call(mailbox, {:status, id}, opts)

  @doc """
  The answer to the row stored under `key` (the report, for a brief's uuid), as `status/3`
  answers a row, or `{:refused, :no_answer}`.
  """
  def answer_to(mailbox, key, opts \\ []), do: call(mailbox, {:answer_to, key}, opts)

  @doc """
  The ids of the rows to `to` still `queued` or `sending`: `{:ok, ids}`. With `status:
  :sending`, only those `sending`. `Sessions` reads it before a stop, through the `open_to:`
  function the embedding app hands it:

      open_to = fn name, which -> Mailbox.open_to(mailbox, name, status: which) end
      open_to.("app-main", :sending)
      #=> {:ok, []}
  """
  def open_to(mailbox, to, opts \\ []),
    do: call(mailbox, {:open_to, to, Keyword.get(opts, :status, :open)}, opts)

  @doc """
  Hands it a reader's cue: every open row is read again. A `waiter` row's lines are read from
  its transcript only on a `transcripts:` cue or a waiter's (and at its take bound): the other
  cues leave it as it is. Answers `:ok` at once.
  """
  def cue(mailbox, %{topic: topic}) when is_binary(topic),
    do: GenServer.cast(mailbox, {:cue, transcript?(topic)})

  @doc "What `Mailbox` reads, for `Cues` (see `cue/2`)."
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads do
    %{
      topics: ~w(stream sessions delegates transcripts intake:*:*:waiters),
      cue: &cue/2
    }
  end

  defp transcript?("transcripts:" <> _), do: true
  defp transcript?(topic), do: String.ends_with?(topic, ":waiters")

  defp store(mailbox, row), do: call(mailbox, {:store, row}, [])

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
         host = Keyword.fetch!(opts, :host),
         {:ok, agents} <- Agents.open(Keyword.fetch!(opts, :sessions_db), host) do
      s = Map.new(~w(grants stream host)a, &{&1, Keyword.fetch!(opts, &1)})
      notify = Keyword.get(opts, :notify, fn _ -> :ok end)
      # The waiter transport's parts; without `intake:` a main session has no transport here.
      waiter =
        if opts[:intake],
          do: Map.new(~w(intake transcripts accounts)a, &{&1, Keyword.fetch!(opts, &1)}),
          else: %{intake: nil}

      waiter = Map.put(waiter, :bound, Keyword.get(opts, :take_bound, @take_bound))
      # `calls`: row id to the call that took it; `waits`: key to the call waiting for it.
      s = Map.merge(s, %{db: db, agents: agents, notify: notify, calls: %{}, waits: %{}})
      {:ok, Map.put(s, :waiter, waiter), {:continue, :read}}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  # A restart settles what it finds marked, from Stream's rows read to the end of each log; a
  # row a call took finds no call in memory, and is due again. A waiter's row is settled at its
  # take bound, which no timer of the last process carries over.
  @impl true
  def handle_continue(:read, s) do
    Stream.read(s.stream, timeout: @step)

    for %{via: "waiter", status: "sending", sent_at: at} <- Table.open_rows(s.db),
        is_integer(at),
        do: bound(s, at)

    {:noreply, settle(s, true)}
  end

  def handle_continue(:settle, s), do: {:noreply, settle(s)}

  @impl true
  def handle_cast({:cue, transcript?}, s), do: {:noreply, settle(s, transcript?)}

  @impl true
  def handle_call({:message, from, to, text}, _from, s) do
    with true <-
           Enum.all?([from, to, text], &(is_binary(&1) and &1 != "")) or
             {:refused, {:bad, :message}},
         :ok <- Grants.may_message?(s.grants, from, to) do
      row = %{from: from, to: to, text: text, uuid: Stream.uuid(), kind: "msg"}
      stored(s, Table.store(s.db, row))
    else
      refused -> {:reply, refused, s}
    end
  end

  # The key goes in `reply_to`, whose unique index takes one row per key; a key is never a
  # row's uuid, since it carries its own prefix.
  def handle_call({:notify, to, text, key}, _from, s) do
    with true <-
           (Enum.all?([to, text], &(is_binary(&1) and &1 != "")) and
              (is_nil(key) or is_binary(key))) or {:refused, {:bad, :message}},
         :ok <- Grants.may_use?(s.grants, to),
         # The operator is no agent: nothing would deliver to it.
         true <- to != Grants.operator(s.grants) or {:refused, {:not_an_agent, to}} do
      row = %{from: @framework, to: to, text: text, uuid: Stream.uuid(), kind: "msg"}
      stored(s, Table.store(s.db, Map.put(row, :reply_to, key && "key:" <> key)))
    else
      refused -> {:reply, refused, s}
    end
  end

  def handle_call({:store, row}, _from, s) do
    if Enum.all?([row.from, row.to, row.text, row.uuid], &(is_binary(&1) and &1 != "")),
      do: stored(s, Table.store(s.db, row)),
      else: {:reply, {:refused, {:bad, :message}}, s}
  end

  def handle_call({:ended, to}, _from, s) do
    ids = for %{to_agent: ^to, status: "queued"} = m <- Table.open_rows(s.db), do: m.id
    for id <- ids, do: write(s, %{id: id}, status: "ended")
    {:reply, {:ok, ids}, s}
  end

  def handle_call({:await, to, key, deadline}, from, s) do
    m = Table.answer(s.db, key)

    cond do
      Map.has_key?(s.waits, key) ->
        {:reply, {:refused, :awaited}, s}

      m != nil and m.status != "queued" ->
        {:reply, {:refused, {:status, m.status}}, s}

      true ->
        # A call with no time left takes only a row it can take now, and never waits.
        left = deadline - System.monotonic_time(:millisecond)
        # The timer names this wait: one a take or a 0 ms answer canceled too late must not end
        # a later wait on the same key.
        ref = make_ref()
        timer = Process.send_after(self(), {:waited, key, ref}, max(left, 0))
        w = %{from: from, to: to, deadline: deadline, timer: timer, ref: ref}
        s = put_in(s.waits[key], w)
        s = take_waiting(s)

        if left <= 0 and Map.has_key?(s.waits, key) do
          Process.cancel_timer(timer)
          {:reply, {:unknown, :timeout}, %{s | waits: Map.delete(s.waits, key)}}
        else
          {:noreply, s}
        end
    end
  end

  def handle_call({:told, id, written}, _from, s) do
    case Table.get(s.db, id) do
      %{status: "sending", via: "call"} = m ->
        s = unwatch(s, id)

        if written == :written do
          write(s, m, status: "delivered")
          {:reply, {:ok, :delivered}, s, {:continue, :settle}}
        else
          again(s, m, :write_failed)
          {:reply, {:ok, :queued}, s, {:continue, :settle}}
        end

      %{status: status} ->
        {:reply, {:refused, {:not_taken, status}}, s}

      nil ->
        {:reply, {:refused, :no_message}, s}
    end
  end

  def handle_call({:status, id}, _from, s),
    do: {:reply, shown(Table.get(s.db, id) || {:refused, :no_message}), s}

  def handle_call({:answer_to, key}, _from, s),
    do: {:reply, shown(Table.answer(s.db, key) || {:refused, :no_answer}), s}

  def handle_call({:open_to, to, which}, _from, s) do
    ids =
      for %{to_agent: ^to} = m <- Table.open_rows(s.db),
          which == :open or m.status == "sending",
          do: m.id

    {:reply, {:ok, ids}, s}
  end

  # A waiter's row reached its take bound: settled now, by the transcript as it is.
  @impl true
  def handle_info(:bound, s), do: {:noreply, settle(s, true)}

  def handle_info({:waited, key, ref}, s) do
    case s.waits[key] do
      %{ref: ^ref, from: from} ->
        GenServer.reply(from, {:unknown, :timeout})
        {:noreply, %{s | waits: Map.delete(s.waits, key)}}

      _stale ->
        {:noreply, s}
    end
  end

  # CallerSeen: the process that took a row ended before it said how its write went. The write
  # may have reached the agent; the row is due again, for another transport.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) do
    case Enum.find(s.calls, fn {_id, r} -> r == ref end) do
      {id, _} ->
        s = %{s | calls: Map.delete(s.calls, id)}
        with %{status: "sending", via: "call"} = m <- Table.get(s.db, id), do: again(s, m, :gone)
        {:noreply, settle(s)}

      nil ->
        {:noreply, s}
    end
  end

  defp stored(s, nil), do: {:reply, {:ok, :stored_before}, s}

  defp stored(s, id) do
    announce(s, id)
    {:reply, {:ok, {:queued, id}}, s, {:continue, :settle}}
  end

  defp shown({:refused, _} = refused), do: refused

  defp shown(m) do
    keys = [:id, :kind, :status, :via, :attempt, :reply_to, :subtype]

    {:ok,
     Map.take(m, keys)
     |> Map.merge(%{from: m.from_agent, to: m.to_agent, is_error: bool(m.is_error)})}
  end

  defp bool(n), do: %{1 => true, 0 => false}[n]

  # Every open row, read against Stream's rows and Sessions' rows; a failed read decides nothing.
  # A waiter's row is read against its transcript only when `transcript?` (F-127's new-1): on a
  # cue of the transcripts or the waiters, at its take bound and at the start.
  defp settle(s, transcript? \\ false) do
    with {:ok, %{rows: rows}} <- Stream.rows(s.stream, timeout: @step) do
      folds = Map.new(rows, &{&1.session, &1})

      for %{status: "sending"} = m <- Table.open_rows(s.db),
          m.via != "waiter" or transcript? do
        evidence = %{fold: folds[m.session_id], calls: s.calls}

        evidence =
          if m.via == "waiter", do: Map.put(evidence, :waiter, seen(s, m)), else: evidence

        settled(s, m, Transport.settle(m, evidence))
      end

      replies(s, folds)

      Table.open_rows(s.db)
      |> Enum.group_by(& &1.to_agent)
      |> Enum.each(fn {to, rows} -> deliver(s, rows, target(s, to, folds)) end)
    end

    take_waiting(s)
  end

  defp settled(_s, _m, :keep), do: :ok
  defp settled(s, m, :delivered), do: write(s, m, status: "delivered", attempt: nil)
  defp settled(s, m, :again), do: again(s, m, nil)

  # Due again, first, under its same uuid.
  defp again(s, m, why),
    do: write(s, m, status: "queued", via: nil, at: nil, again: 1, attempt: why, sent_at: nil)

  # ReplyStored and NoticeStored: a delivered message's turn ended with a result that names it
  # (the fold keeps it on the message, so a later turn's never replaces it), or its process
  # ended with none (`:exited`). Either one row goes to its sender under the message's uuid,
  # whose unique index lets in one reply or one notice, across restarts and cues.
  defp replies(s, folds) do
    for {sid, fold} <- folds,
        ended = for({u, _} <- fold.messages, turn_ended?(Fold.outcome(fold, u)), do: u),
        m <- Table.unanswered(s.db, sid, ended),
        to = sender(s, m),
        do: answer(s, m, to, Fold.outcome(fold, m.uuid))
  end

  # A message from `framework` is answered to the delegate's parent, the sender of its brief.
  defp sender(s, %{from_agent: @framework} = m) do
    case Table.brief(s.db, m.to_agent) do
      %{from_agent: parent} -> parent
      nil -> nil
    end
  end

  defp sender(_s, m), do: m.from_agent

  defp turn_ended?({:result, _}), do: true
  defp turn_ended?(outcome), do: outcome == :exited

  defp answer(s, m, to, {:result, r}) do
    row = %{from: m.to_agent, to: to, text: r.text, uuid: Stream.uuid(), kind: "reply"}
    row = Map.merge(row, %{reply_to: m.uuid, subtype: r.subtype, is_error: r.is_error})
    stored_quietly(s, Table.store(s.db, row))
  end

  defp answer(s, m, to, :exited) do
    row = %{from: @framework, to: to, text: notice(m), uuid: Stream.uuid(), kind: "notice"}
    stored_quietly(s, Table.store(s.db, Map.put(row, :reply_to, m.uuid)))
  end

  defp notice(m),
    do:
      "Your message #{m.id} went in to #{m.to_agent}, and its process ended before it " <>
        "answered: no reply will come. Resume it to ask again."

  defp stored_quietly(_s, nil), do: :ok
  defp stored_quietly(s, id), do: announce(s, id)

  # The addressee and its transport, by its agent row (`Sessions.Agents`): a headless
  # delegate's stream, with the fold of its session; an interactive session's waiter, when this
  # Mailbox was given an `Intake`. Anything else has none (the typed write is R8's).
  defp target(s, to, folds) do
    srow = Agents.get(s.agents, to)

    cond do
      Agents.ended?(srow) ->
        {:ended, srow.updated_at}

      Agents.headless?(srow) and is_binary(srow.session_id) ->
        {:stream, srow, folds[srow.session_id]}

      Agents.headless?(srow) ->
        :not_started

      srow != nil and s.waiter.intake != nil ->
        {:waiter, srow}

      true ->
        :none
    end
  end

  defp deliver(s, rows, :none) do
    for %{status: "queued"} = m <- rows,
        m.attempt != "no_delivery",
        do: write(s, m, attempt: :no_delivery)
  end

  defp deliver(_s, _rows, :not_started), do: :ok

  # An agent that ended takes nothing: no process of it runs again (EndedNotDelivered). A brief
  # stored since its end is a later start's, stored before `Sessions` writes that start, and
  # waits for it.
  defp deliver(s, rows, {:ended, at}) do
    for %{status: "queued"} = m <- rows,
        m.kind != "brief" or m.created_at <= at,
        do: write(s, m, status: "ended")
  end

  defp deliver(s, rows, {:stream, srow, fold}) do
    cond do
      # EndedFirst: queued rows only; a sending one is settled first.
      match?(%{gone: true, ending: true}, fold) ->
        for %{status: "queued"} = m <- rows, do: write(s, m, status: "ended")

      # One row in flight per addressee.
      Enum.any?(rows, &(&1.status == "sending")) or not ready?(srow, fold) ->
        :ok

      true ->
        mark(s, hd(rows), srow.session_id, fold.resumes)
    end
  end

  # A main session's waiter: one row in flight, to a running session that has a waiter held now
  # (each turn's end starts one). Claude Code takes the text into an ended turn, or queues it
  # into a running one (a person's prompt started a turn while the last turn's waiter waited);
  # nothing is typed either way. A session with no waiter keeps its rows due, and `Intake`'s
  # waiter cue tries them again.
  defp deliver(s, rows, {:waiter, srow}) do
    cond do
      Enum.any?(rows, &(&1.status == "sending")) ->
        :ok

      not Agents.running?(srow) or not is_integer(srow.pid) or not is_binary(srow.session_id) ->
        :ok

      Intake.waiter?(s.waiter.intake, srow.account, srow.session_id, timeout: @step) ==
          {:ok, true} ->
        hand(s, hd(rows), srow)

      true ->
        m = hd(rows)
        if m.attempt != "no_waiter", do: write(s, m, attempt: :no_waiter)
    end
  end

  # Mark, then the hand-on: refused undoes the mark (nothing was marked in Stream); unknown
  # stays sending for Stream's fold to settle.
  defp mark(s, m, sid, at) do
    write(s, m, status: "sending", via: "stream", session_id: sid, at: at)

    case Stream.write(s.stream, sid, {:message, m.uuid, m.text}, timeout: @step) do
      {:ok, _} -> :ok
      {:refused, why} -> write(s, m, status: "queued", via: nil, at: nil, attempt: why)
      {:unknown, why} -> write(s, m, attempt: why)
    end
  end

  # Mark, then the hand-on, as `mark/4`; the transcript's offset read before the mark bounds
  # what its settle reads. Sent or unknown starts the take bound: the text may have been read.
  defp hand(s, m, srow) do
    from = offset(s, srow)
    mark = [status: "sending", via: "waiter", session_id: srow.session_id, at: srow.pid]
    write(s, m, mark ++ [from_byte: from, sent_at: nil])
    text = Transport.Waiter.text(m.text, m.uuid)

    case Intake.deliver(s.waiter.intake, srow.account, srow.session_id, text, timeout: @step) do
      {:ok, :sent} ->
        write(s, m, sent_at: now(), attempt: nil)
        bound(s, now())

      {:refused, why} ->
        write(s, m, status: "queued", via: nil, at: nil, attempt: why)

      {:unknown, why} ->
        write(s, m, sent_at: now(), attempt: why)
        bound(s, now())
    end
  end

  defp bound(s, sent_at),
    do: Process.send_after(self(), :bound, max(sent_at + s.waiter.bound - now(), 0) + 1)

  defp now, do: System.os_time(:millisecond)

  # The waiter's evidence for row `m`: its lines in the transcript of its session, read now
  # from the offset its mark kept, and whether the process it was handed to is gone.
  defp seen(s, m) do
    srow = Agents.get(s.agents, m.to_agent)
    gone = srow == nil or srow.pid != m.at or Agents.free?(srow)

    seen =
      with %{} <- srow,
           {:ok, path} <- transcript(s, srow),
           {:ok, %{failed: []}} <-
             Transcripts.read(s.waiter.transcripts, [{srow.account, m.session_id, path}],
               timeout: @step
             ),
           {:ok, %{bytes: bytes}} <-
             Transcripts.text(s.waiter.transcripts, srow.account, m.session_id, m.from_byte || 0,
               timeout: @step
             ) do
        Transport.Waiter.seen(bytes, m.uuid)
      else
        {:refused, :no_file} -> :none
        _ -> :unread
      end

    %{seen: seen, gone: gone, now: now(), bound: s.waiter.bound}
  end

  # How much of the session's transcript is read now: a row's lines come after it.
  defp offset(s, srow) do
    with {:ok, path} <- transcript(s, srow),
         {:ok, _} <-
           Transcripts.read(s.waiter.transcripts, [{srow.account, srow.session_id, path}],
             timeout: @step
           ),
         {:ok, %{offset: offset}} <-
           Transcripts.session(s.waiter.transcripts, srow.account, srow.session_id,
             timeout: @step
           ) do
      offset
    else
      _ -> 0
    end
  end

  defp transcript(s, srow) do
    with {:ok, dir} <- Accounts.config_dir(s.waiter.accounts, srow.account),
         do: Transcripts.path(dir, srow.cwd, srow.session_id)
  end

  # Into an ended turn of the current process only, never to a session whose row is stopping:
  # `Sessions`' turn function for a headless session.
  defp ready?(srow, fold), do: Turn.headless(srow, fold) == :ended

  # The call transport's take: each waiting call whose row is due, first among its addressee's
  # rows from its sender, with none to it in flight, takes it now, before its deadline.
  defp take_waiting(s) do
    Enum.reduce(s.waits, s, fn {key, w}, s ->
      with %{status: "queued", to_agent: to} = m <- Table.answer(s.db, key),
           true <- to == w.to and first?(s, m) do
        take(s, key, w, m)
      else
        _ -> s
      end
    end)
  end

  defp first?(s, m) do
    rows = for %{to_agent: to} = r <- Table.open_rows(s.db), to == m.to_agent, do: r

    not Enum.any?(rows, &(&1.status == "sending")) and
      not Enum.any?(rows, fn r ->
        r.id != m.id and r.status == "queued" and r.from_agent == m.from_agent and
          (r.again > m.again or (r.again == m.again and r.id < m.id))
      end)
  end

  defp take(s, key, w, m) do
    Process.cancel_timer(w.timer)
    s = %{s | waits: Map.delete(s.waits, key)}

    if System.monotonic_time(:millisecond) < w.deadline do
      write(s, m, status: "sending", via: "call", at: nil, attempt: nil)
      {pid, _tag} = w.from
      GenServer.reply(w.from, {:ok, %{id: m.id, from: m.from_agent, kind: m.kind, text: m.text}})
      put_in(s.calls[m.id], Process.monitor(pid))
    else
      GenServer.reply(w.from, {:unknown, :timeout})
      s
    end
  end

  defp unwatch(s, id) do
    {ref, calls} = Map.pop(s.calls, id)
    if ref, do: Process.demonitor(ref, [:flush])
    %{s | calls: calls}
  end

  defp write(s, m, fields) do
    Table.update(s.db, m.id, fields)
    announce(s, m.id)
  end

  defp announce(s, id), do: s.notify.(%{topic: "mailbox", ids: [id]})
end
