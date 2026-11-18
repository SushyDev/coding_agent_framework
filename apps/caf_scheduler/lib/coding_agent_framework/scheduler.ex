defmodule CodingAgentFramework.Scheduler do
  @moduledoc """
  The lease ledger in front of every agent start, heavy run and landing (`docs/design.md`, "A
  lease"; `model/tla/Schedule.tla`). One process per instance, with no name, started by the
  embedding app; the one writer of the `leases` table (`Scheduler.Table`).

  **A request** names its `id` (the requester's; asking again under it is safe), its `class`
  (`:main`, `:landing`, `:builder` or `:heavy`), its `module` (who asks, for the turns inside a
  class), its `account` (or nil), the `units` of each declared resource it needs, all taken in
  one lease, and its `holder`, `{kind, key}`: the row of the work the lease admits (an agent
  row, a job row), whose owner says when that work ended. The answer comes at once:

    * `{:ok, lease}`: granted now, or granted before under this id (the lease is looked up
      before any refusal is decided);
    * `{:queued, %{id: id, position: n}}`: exactly one more answer follows, as a message to the
      requester's process, `{:lease, id, {:ok, lease}}` or `{:lease, id, {:refused, {reason,
      retry_at}}}`, and no position updates;
    * `{:refused, {reason, retry_at}}`, final for the request, holding nothing, never a failed
      run: `:allowance` (the account's five-hour or weekly window has no room; `retry_at` is its
      reset), `:pressure` (the host's pressure bars the class), `:queue_full`, or `:deadline` (a
      queued request waited its class's `max_wait`). `retry_at` is wall-clock ms.

  A refused request is a row too, so a view shows it. A requester's process that ends while it
  waits leaves the queue; the queue is in memory, so after a restart a requester still waiting
  asks again under its id, and is handed the lease if the grant was written.

  **The grant** (`Scheduler.Queue` picks the next request) is one immediate transaction that
  sums the units the unreleased rows hold and inserts only within each resource's capacity and
  beside what waiting higher classes hold (`Scheduler.Table.grant/5`). Its id is the lease's
  fencing token.

  **The gates.** Pressure (`Scheduler.Pressure`, read on its own interval): `high` admits no new
  heavy run, `severe` nothing new but a person's main session. A request its class is barred
  from is refused at once; a queued one waits for its deadline. The allowance, the function
  `allowance:`, answers `:room` or `{:spent, retry_at}` for an account: a spent one is refused at
  once, and a queued request whose account is spent is refused then. Gates stop new starts only:
  no lease is taken back.

  **The end.** A lease lasts as long as its work. The `Scheduler` asks the holder's owner (the
  function `holders:` gives for its kind) whether the work ended: `:live` (a row still starting
  is live), `:ended`, or `{:unknown, reason}`, which decides nothing. It asks for each lease it
  monitors at each cue (`reads/0`) and on its `interval:`, and for every unreleased row when it
  starts (the reclaimer), never because time passed. Both release by a compare-and-set on the
  lease id (`Scheduler.Table.release/4`), so one succeeds.

  **Telemetry**: `[:coding_agent_framework, :scheduler, :grant]` with `%{wait: ms}`, and
  `[:coding_agent_framework, :scheduler, :refusal]` with `%{count: 1}`, each with the class,
  module and account (and the reason) as metadata. After each write `notify` gets
  `%{topic: "scheduler:<host>", ids: [id]}`.

      {:ok, s} = Scheduler.start_link(db: path, host: "ws", resources: %{"seat" => 4},
        holders: %{"delegate" => &Delegates.Work.state(work, &1)},
        allowance: &Usage.Allowance.room(usage, &1))
      Scheduler.request(s, %{id: "delegate:ws:7", class: :builder, module: "app",
        account: "work", units: %{"seat" => 1}, holder: {"delegate", "ws:7"}})
      #=> {:ok, %{id: 12, request_id: "delegate:ws:7", ...}}
  """

  use GenServer

  alias CodingAgentFramework.Scheduler.{Pressure, Queue, Table}

  @call 5_000
  @reasons [:queue_full, :deadline, :pressure, :allowance]

  @doc """
  Starts the `Scheduler`. Options: `db:` (its file), `host:` (for its topic), `resources:` (each
  resource's name to its capacity), and optionally `holders:` (each holder kind to a function
  of its key answering `:live`, `:ended` or `{:unknown, reason}`), `allowance:` (a function of
  an account answering `:room` or `{:spent, retry_at}`; without it every account has room),
  `pressure:` (`source: :psi | {:level, read} | :none`, `dir:` for `:psi`, `interval:` ms, and
  `Scheduler.Pressure`'s thresholds; `:none` by default), `queue_bound:` (requests one class's
  queue holds, default 4, or a map by class), `max_wait:` (ms a queued request waits, default
  240 000, or a map by class), `age:` (ms after which a request goes first in its class, default
  120 000; nil for none), `interval:` (ms between asks of the holders' owners; without it only
  at cues), `notify:` and `clock:` (wall-clock ms).

  Every number here is a placeholder until it is measured on the workstation.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Asks for a lease (see the module's doc). Option `timeout:` (ms, default 5 000)."
  @spec request(GenServer.server(), map, keyword) ::
          {:ok, map}
          | {:queued, %{id: String.t(), position: pos_integer}}
          | {:refused, term}
          | {:unknown, term}
  def request(scheduler, request, opts \\ []),
    do: call(scheduler, {:request, request, self()}, opts)

  @doc "Every row, granted and refused, oldest first: for a view or a test."
  @spec leases(GenServer.server(), keyword) :: [map] | {:refused, term} | {:unknown, term}
  def leases(scheduler, opts \\ []), do: call(scheduler, :leases, opts)

  @doc "The host's pressure now: `:ok`, `:high` or `:severe`."
  @spec pressure(GenServer.server(), keyword) :: Pressure.level() | {:unknown, term}
  def pressure(scheduler, opts \\ []), do: call(scheduler, :pressure, opts)

  @doc """
  Hands it a cue: each lease it monitors is asked about again, and the queue served. Answers
  `:ok` at once.
  """
  @spec cue(GenServer.server(), map) :: :ok
  def cue(scheduler, %{topic: _}), do: GenServer.cast(scheduler, :check)

  @doc """
  What the `Scheduler` reads, for `Cues`: the agent rows, the delegates' rows, the main
  sessions' starts and the job rows (a delegate's, a main session's or a job's work ended), and
  the accounts' readings (a window's room).
  """
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(sessions delegates mains jobs usage), cue: &cue/2}

  defp call(scheduler, request, opts) do
    timeout = Keyword.get(opts, :timeout, @call)
    GenServer.call(scheduler, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_scheduler}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @call)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      pressure = Keyword.get(opts, :pressure, source: :none)

      s = %{
        db: db,
        host: Keyword.fetch!(opts, :host),
        capacity: Keyword.fetch!(opts, :resources),
        holders: Keyword.get(opts, :holders, %{}),
        allowance: Keyword.get(opts, :allowance, fn _ -> :room end),
        bound: Keyword.get(opts, :queue_bound, 4),
        max_wait: Keyword.get(opts, :max_wait, 240_000),
        age: Keyword.get(opts, :age, 120_000),
        interval: Keyword.get(opts, :interval),
        notify: Keyword.get(opts, :notify, fn _ -> :ok end),
        clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
        source: Keyword.get(pressure, :source, :none),
        psi: Keyword.get(pressure, :dir, "/proc/pressure"),
        every: Keyword.get(pressure, :interval, 2_000),
        pressure: Pressure.new(Keyword.take(pressure, Keyword.keys(Pressure.defaults()))),
        entries: [],
        rot: %{},
        seq: 0,
        monitored: MapSet.new(),
        # After a restart every unreleased row is read again by the reclaimer.
        reclaim: MapSet.new(Table.unreleased(db), & &1.id)
      }

      if s.source != :none, do: send(self(), :pressure)
      if s.interval, do: Process.send_after(self(), :tick, s.interval)
      {:ok, s, {:continue, :check}}
    end
  end

  @impl true
  def handle_continue(:check, s), do: {:noreply, check(s)}

  @impl true
  def handle_call({:request, req, pid}, _from, s) do
    case checked(req, s) do
      {:ok, req} -> receive_request(s, Map.put(req, :asked_at, now(s)), pid)
      refused -> {:reply, refused, s}
    end
  end

  def handle_call(:leases, _from, s),
    do: {:reply, Table.all(s.db), s}

  def handle_call(:pressure, _from, s), do: {:reply, s.pressure.level, s}

  @impl true
  def handle_cast(:check, s), do: {:noreply, check(s)}

  @impl true
  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, s.interval)
    {:noreply, check(s)}
  end

  def handle_info(:pressure, s) do
    Process.send_after(self(), :pressure, s.every)
    before = s.pressure.level

    s =
      case sample(s) do
        {:ok, sample} -> %{s | pressure: Pressure.step(s.pressure, sample, now(s))}
        _unread -> s
      end

    {:noreply, if(s.pressure.level != before, do: serve(s), else: s)}
  end

  def handle_info({:deadline, seq}, s) do
    case Enum.find(s.entries, &(&1.seq == seq)) do
      nil -> {:noreply, s}
      e -> {:noreply, serve(refuse_queued(s, e, :deadline, now(s)))}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Enum.find(s.entries, &(&1.ref == ref)) do
      nil -> {:noreply, s}
      e -> {:noreply, serve(drop(s, e))}
    end
  end

  # Receive: the lease this id already has; else a refusal decided now; else queued, and the
  # queue served, so a request that fits now is granted in the same step.
  defp receive_request(s, req, pid) do
    queued = Enum.find(s.entries, &(&1.req.id == req.id))

    cond do
      lease = Table.lease(s.db, req.id) ->
        {:reply, {:ok, lease}, s}

      queued ->
        Process.demonitor(queued.ref, [:flush])
        e = %{queued | pid: pid, ref: Process.monitor(pid)}
        s = %{s | entries: Enum.map(s.entries, &if(&1.seq == e.seq, do: e, else: &1))}
        {:reply, {:queued, %{id: req.id, position: position(s, e)}}, s}

      refusal = refusal(s, req) ->
        {reason, retry_at} = refusal
        refused(s, req, reason, retry_at)
        {:reply, {:refused, refusal}, s}

      true ->
        seq = s.seq + 1
        wait = by_class(s.max_wait, req.class)
        Process.send_after(self(), {:deadline, seq}, wait)
        # No requester yet: a grant in this step is this reply, not a message as well.
        e = %{seq: seq, req: req, asked_at: req.asked_at, pid: nil, ref: nil}
        s = serve(%{s | seq: seq, entries: s.entries ++ [e]})

        case Table.lease(s.db, req.id) do
          nil ->
            e = %{e | pid: pid, ref: Process.monitor(pid)}
            s = %{s | entries: Enum.map(s.entries, &if(&1.seq == seq, do: e, else: &1))}
            {:reply, {:queued, %{id: req.id, position: position(s, e)}}, s}

          lease ->
            {:reply, {:ok, lease}, s}
        end
    end
  end

  defp refusal(s, req) do
    waiting = Enum.count(s.entries, &(&1.req.class == req.class))

    cond do
      spent = spent(s, req) -> {:allowance, spent}
      Pressure.bars?(s.pressure.level, req.class) -> {:pressure, now(s) + window(s)}
      waiting >= by_class(s.bound, req.class) -> {:queue_full, now(s)}
      true -> nil
    end
  end

  # Grants while the queue's next request fits; refuses a queued request whose account has no
  # room left.
  defp serve(s) do
    s = Enum.reduce(s.entries, s, &expire_spent/2)
    admitted? = fn e -> not Pressure.bars?(s.pressure.level, e.req.class) end
    held = Table.held(s.db)
    t = now(s)

    case Queue.next(s.entries, s.rot, held, s.capacity, admitted?, t, s.age) do
      :none ->
        s

      {:grant, e, reserved} ->
        case Table.grant(s.db, e.req, s.capacity, reserved, t) do
          {:ok, lease} -> serve(granted(s, e, lease))
          {:full, _} -> s
        end
    end
  end

  defp expire_spent(e, s) do
    case spent(s, e.req) do
      nil -> s
      retry_at -> refuse_queued(s, e, :allowance, retry_at)
    end
  end

  defp granted(s, e, lease) do
    s = drop(s, e)
    tell(e, {:ok, lease})
    meta = %{class: e.req.class, module: e.req.module, account: e.req[:account], lease: lease.id}
    :telemetry.execute([:coding_agent_framework, :scheduler, :grant], %{wait: lease.waited}, meta)
    announce(s, lease.id)

    %{
      s
      | monitored: MapSet.put(s.monitored, lease.id),
        rot: Map.put(s.rot, e.req.class, e.req.module)
    }
  end

  defp refuse_queued(s, e, reason, retry_at) do
    tell(e, {:refused, {reason, retry_at}})
    refused(s, e.req, reason, retry_at)
    drop(s, e)
  end

  # The one more answer a queued request is owed: one message to its requester.
  defp tell(%{pid: nil}, _answer), do: :ok
  defp tell(e, answer), do: send(e.pid, {:lease, e.req.id, answer})

  defp refused(s, req, reason, retry_at) when reason in @reasons do
    row = Table.refuse(s.db, req, reason, retry_at, now(s))
    meta = %{class: req.class, module: req.module, account: req[:account], reason: reason}
    :telemetry.execute([:coding_agent_framework, :scheduler, :refusal], %{count: 1}, meta)
    announce(s, row.id)
  end

  defp drop(s, e) do
    if e.ref, do: Process.demonitor(e.ref, [:flush])
    %{s | entries: Enum.reject(s.entries, &(&1.seq == e.seq))}
  end

  # The monitor and the reclaimer: each lease's owner is asked whether its work ended. A
  # reclaimed row that is live is monitored from then on; an unknown answer decides nothing.
  defp check(s) do
    {s, _} = Enum.reduce(s.reclaim, {s, "reclaim"}, &ask_owner/2)
    {s, _} = Enum.reduce(s.monitored, {s, "monitor"}, &ask_owner/2)
    serve(s)
  end

  defp ask_owner(id, {s, by}) do
    with %{released_at: nil, holder: {kind, key}} <- Table.get(s.db, id),
         {:ok, owner} <- Map.fetch(s.holders, kind) |> known(kind) do
      case owner.(key) do
        :ended ->
          if Table.release(s.db, id, by, now(s)) == :released, do: announce(s, id)
          {forget(s, id), by}

        :live ->
          {%{forget(s, id) | monitored: MapSet.put(s.monitored, id)}, by}

        {:unknown, _} ->
          {s, by}
      end
    else
      %{released_at: at} when is_integer(at) -> {forget(s, id), by}
      _no_owner -> {s, by}
    end
  end

  defp known(:error, kind), do: {:unknown, {:no_owner, kind}}
  defp known(ok, _kind), do: ok

  defp forget(s, id),
    do: %{s | reclaim: MapSet.delete(s.reclaim, id), monitored: MapSet.delete(s.monitored, id)}

  # A request's own checks: a known class, units of declared resources, a holder.
  defp checked(%{id: id, class: class, module: m, units: units, holder: {kind, _}} = req, s)
       when is_binary(id) and is_binary(m) and is_map(units) and is_binary(kind) do
    cond do
      class not in Queue.classes() ->
        {:refused, {:bad, :class}}

      units == %{} ->
        {:refused, {:bad, :units}}

      bad = Enum.find(Map.keys(units), &(not Map.has_key?(s.capacity, &1))) ->
        {:refused, {:unknown_resource, bad}}

      not Enum.all?(Map.values(units), &(is_integer(&1) and &1 > 0)) ->
        {:refused, {:bad, :units}}

      true ->
        {:ok, Map.put_new(req, :account, nil)}
    end
  end

  defp checked(_req, _s), do: {:refused, {:bad, :request}}

  defp spent(_s, %{account: nil}), do: nil

  defp spent(s, %{account: account}) do
    case s.allowance.(account) do
      {:spent, retry_at} -> retry_at
      _room_or_unread -> nil
    end
  end

  defp position(s, e), do: Queue.position(s.entries, e, s.rot, now(s), s.age)

  defp sample(%{source: :psi, psi: dir}), do: Pressure.psi(dir)
  defp sample(%{source: {:level, read}}), do: with({:ok, n} <- read.(), do: {:ok, {:level, n}})

  defp window(s), do: s.pressure.opts[:window]

  defp by_class(%{} = map, class), do: Map.fetch!(map, class)
  defp by_class(n, _class), do: n

  defp announce(s, id), do: s.notify.(%{topic: "scheduler:#{s.host}", ids: [id]})

  defp now(s), do: s.clock.()
end
