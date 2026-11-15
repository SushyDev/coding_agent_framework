defmodule CodingAgentFramework.Intake do
  @moduledoc """
  Where Claude Code's hook events reach the framework, on the node's own host: the one writer
  of `CodingAgentFramework.Intake.Table`, and the holder of each open `PermissionRequest`.
  `model/tla/Intake.tla` models it, and comments name the spec's actions where the code does
  them.

  The library starts no process. The host app starts one `Intake` per instance and serves
  `CodingAgentFramework.Intake.Plug` on 127.0.0.1 with a server of its choice, such as Bandit:

      children = [
        {CodingAgentFramework.Intake, db: "/srv/caf/intake.db", host: "laptop", name: MyApp.Intake},
        {Bandit, ip: {127, 0, 0, 1}, port: 4790,
         plug: {CodingAgentFramework.Intake.Plug, intake: MyApp.Intake, secret: secret}}
      ]

  and `CodingAgentFramework.Accounts.prepare/3` with `intake: %{port: 4790, secret: secret}`
  writes the hooks that post there (`hooks/3`).

  - An event's row is written, then the plug answers 200 with an empty body. A second post of
    one key (`CodingAgentFramework.Intake.Event`) writes no second row.
  - A `PermissionRequest`'s row is written `held` and its request stays open. `answer/4` moves
    it `answering`, sends the decision as the response, then marks it `answered`. At the
    deadline (option `deadline:`, 570 s by default, before the hook's 600 s timeout) the
    request is answered with an empty body, no decision, and the row is `expired`.
  - When this process starts, a row still `held` becomes `lost` and one `answering` becomes
    `unknown`: the requests ended with the process that held them.

  After each write it calls `notify` with `%{topic: "intake:<host>:<account>", ids: ids}`, a
  cue and never the data. `CodingAgentFramework.Tracker.IntakeSource` reads the rows.
  """

  use GenServer

  alias CodingAgentFramework.Intake.{Event, Table}

  @deadline 570_000
  @timeout 5_000

  @doc """
  Starts an `Intake`. Options: `db:` (this instance's SQLite path), `host:` (the node's host
  name), and optionally `notify:` (a function of one cue), `deadline:` (ms a hold is kept) and
  `name:` (for the host app's tree; the library looks up no name).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc """
  The settings' `hooks` for `account`: an `http` hook per event of `Event.names/0`, posting to
  this host's port with the secret in the `x-caf-secret` header. PermissionRequest waits 600 s
  and the rest 10 s, which also raises SessionEnd's shared 1.5 s budget. `onFailure` is left
  at its default, continue, so a framework that is down never refuses a tool call.

      iex> hooks = CodingAgentFramework.Intake.hooks(4790, "work", "s3")
      iex> [%{"hooks" => [hook]}] = hooks["PermissionRequest"]
      iex> {hook["url"], hook["timeout"]}
      {"http://127.0.0.1:4790/hooks/work", 600}
  """
  @spec hooks(:inet.port_number(), String.t(), String.t()) :: map
  def hooks(port, account, secret) do
    Map.new(Event.names(), fn name ->
      hook = %{
        "type" => "http",
        "url" => "http://127.0.0.1:#{port}/hooks/#{account}",
        "headers" => %{"x-caf-secret" => secret},
        "timeout" => if(name == "PermissionRequest", do: 600, else: 10)
      }

      {name, [%{"hooks" => [hook]}]}
    end)
  end

  @doc """
  Stores one post's body for `account`, as the plug does. Returns `{:ok, :stored}` or
  `{:ok, :seen}` (a row with its key was there), or `{:ok, {:held, id, ref, wait}}`: the caller
  holds the request and waits up to `wait` ms for `{ref, {:decision, body}}` or
  `{ref, :release}`, and after writing a decision calls `written/3`.
  """
  @spec post(GenServer.server(), String.t(), binary, keyword) ::
          {:ok, :stored | :seen | {:held, integer, reference, pos_integer}}
          | {:refused, term}
          | {:unknown, term}
  def post(intake, account, body, opts \\ []), do: call(intake, {:post, account, body}, opts)

  @doc """
  Answers held row `id` with `decision`: `:allow`, `{:allow, updated_permissions}` (for "don't
  ask again") or `{:deny, message}`. Returns `{:ok, :sent}` once the response is written; a
  person may have answered the dialog first, which a later read shows. A row that is not
  `held` is refused with `{:refused, {:not_held, hold}}`.
  """
  @spec answer(GenServer.server(), integer, term, keyword) ::
          {:ok, :sent} | {:refused, term} | {:unknown, term}
  def answer(intake, id, decision, opts \\ []), do: call(intake, {:answer, id, decision}, opts)

  @doc "Tells the `Intake` that the decision for row `id` went out as the response."
  @spec written(GenServer.server(), integer, reference) :: :ok
  def written(intake, id, ref), do: GenServer.cast(intake, {:written, id, ref})

  defp call(intake, request, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    try do
      GenServer.call(intake, request, timeout)
    catch
      :exit, {:noproc, _} -> {:refused, :no_intake}
      :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
      :exit, {reason, _} -> {:unknown, {:exit, reason}}
    end
  end

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)

    case Table.open(Keyword.fetch!(opts, :db)) do
      {:ok, db} ->
        state = %{
          host: host,
          db: db,
          notify: Keyword.get(opts, :notify, fn _ -> :ok end),
          deadline: Keyword.get(opts, :deadline, @deadline),
          holds: %{}
        }

        settled = Table.start(db, host, now())

        for {account, ids} <- Enum.group_by(settled, &elem(&1, 1), &elem(&1, 0)),
            do: cue(state, account, ids)

        {:ok, state}

      {:refused, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:post, account, body}, {pid, _}, state) do
    row = Event.parse(body)

    case Table.insert(state.db, state.host, account, row, now()) do
      {:seen, _id, _hold} ->
        {:reply, {:ok, :seen}, state}

      {:new, id} when row.hold ->
        # Spec action HoldStored: the row says held while the plug keeps the request open.
        ref = make_ref()
        timer = Process.send_after(self(), {:expire, id}, state.deadline)
        hold = %{account: account, pid: pid, ref: ref, mon: Process.monitor(pid), timer: timer}
        cue(state, account, [id])
        {:reply, {:ok, {:held, id, ref, state.deadline}}, put_in(state.holds[id], hold)}

      {:new, id} ->
        # Spec action Stored: the row is written before the plug's 200 (Acked).
        cue(state, account, [id])
        {:reply, {:ok, :stored}, state}
    end
  end

  def handle_call({:answer, id, decision}, from, state) do
    with {:ok, body} <- response(decision),
         %{} = hold <- state.holds[id],
         true <- Table.move(state.db, id, "held", "answering", body, now()) do
      # Spec action AnswerAsked: the row says answering before the decision goes out.
      send(hold.pid, {hold.ref, {:decision, body}})
      cue(state, hold.account, [id])
      {:noreply, put_in(state.holds[id], Map.put(hold, :from, from))}
    else
      {:refused, _} = refused -> {:reply, refused, state}
      _ -> {:reply, {:refused, {:not_held, hold_of(state, id)}}, state}
    end
  end

  @impl true
  def handle_cast({:written, id, ref}, state) do
    case state.holds[id] do
      %{ref: ^ref, from: from} = hold ->
        # Spec action AnswerMarked: the plug wrote the decision (AnswerWritten).
        Table.move(state.db, id, "answering", "answered", nil, now())
        GenServer.reply(from, {:ok, :sent})
        {:noreply, drop(state, id, hold)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:expire, id}, state) do
    case state.holds[id] do
      %{from: _} ->
        {:noreply, state}

      %{} = hold ->
        # Spec action HoldExpires: no decision, and the dialog waits for a person.
        Table.move(state.db, id, "held", "expired", nil, now())
        send(hold.pid, {hold.ref, :release})
        {:noreply, drop(state, id, hold)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, mon, :process, _, reason}, state) do
    case Enum.find(state.holds, fn {_, hold} -> hold.mon == mon end) do
      {id, %{from: from} = hold} ->
        # Spec action HoldSettled: the request closed before the answer was written.
        Table.move(state.db, id, "answering", "unknown", nil, now())
        GenServer.reply(from, {:unknown, {:request_closed, reason}})
        {:noreply, drop(state, id, hold)}

      {id, hold} ->
        # Spec action HoldSettled: the request closed while held.
        Table.move(state.db, id, "held", "lost", nil, now())
        {:noreply, drop(state, id, hold)}

      nil ->
        {:noreply, state}
    end
  end

  defp drop(state, id, hold) do
    Process.demonitor(hold.mon, [:flush])
    Process.cancel_timer(hold.timer)
    cue(state, hold.account, [id])
    %{state | holds: Map.delete(state.holds, id)}
  end

  defp hold_of(state, id) do
    case is_integer(id) && Table.rows_by_id(state.db, [id]) do
      [%{host: host, hold: hold}] when host == state.host -> hold
      _ -> :no_row
    end
  end

  # The PermissionRequest output in the shape Claude Code 2.1.322 reads (F-24).
  defp response(decision) do
    with {:ok, d} <- decision(decision) do
      output = %{"hookEventName" => "PermissionRequest", "decision" => d}
      {:ok, JSON.encode!(%{"hookSpecificOutput" => output})}
    end
  rescue
    e -> {:refused, {:bad_decision, Exception.message(e)}}
  end

  defp decision(:allow), do: {:ok, %{"behavior" => "allow"}}

  defp decision({:allow, perms}) when is_list(perms),
    do: {:ok, %{"behavior" => "allow", "updatedPermissions" => perms}}

  defp decision({:deny, message}) when is_binary(message),
    do: {:ok, %{"behavior" => "deny", "message" => message}}

  defp decision(other), do: {:refused, {:bad_decision, other}}

  defp cue(state, account, ids),
    do: state.notify.(%{topic: "intake:#{state.host}:#{account}", ids: ids})

  defp now, do: System.os_time(:millisecond)
end
