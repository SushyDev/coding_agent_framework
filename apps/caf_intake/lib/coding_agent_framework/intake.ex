defmodule CodingAgentFramework.Intake do
  @moduledoc """
  Where Claude Code's hook events reach the framework, on the node's own host: the one writer
  of `CodingAgentFramework.Intake.Table`, and the holder of each hook that waits.
  `model/tla/Intake.tla` models it, and comments name the spec's actions where the code does
  them.

  The library starts no process. The embedding app starts one `Intake` per instance and serves
  `CodingAgentFramework.Intake.Plug` on 127.0.0.1 with a server of its choice, such as Bandit:

      children = [
        {CodingAgentFramework.Intake, db: "/srv/caf/intake.db", host: "laptop", name: MyApp.Intake},
        {Bandit, ip: {127, 0, 0, 1}, port: 4790,
         plug: {CodingAgentFramework.Intake.Plug, intake: MyApp.Intake, secret: secret}}
      ]

  and `CodingAgentFramework.Accounts.prepare/3` with `intake: %{port: 4790, secret: secret}`
  writes the hooks that post there (`hooks/4`), with `tools: [:pre_tool_use]` for each tool
  callback the app gives.

  - An event's row is written, then the plug answers 200 with an empty body. A second post of
    one key (`CodingAgentFramework.Intake.Event`) writes no second row.
  - A hook that waits is a hold (`model/tla/Hold.tla`), one structure for every kind: its row
    is written `held` and its request stays open. A decision moves the row `deciding`, goes out
    as the response, and the row is then `answered`. At the kind's deadline, or for a pass, the
    response is an empty body and the row `expired` or `passed`. Exactly one response goes out,
    and a decision after it is dropped. A request that closes first settles its row: `held`
    becomes `lost` and `deciding` becomes `unknown`, since its decision may have gone out; when
    this process starts, it settles the rows the last one left the same way. The kinds differ
    only in their decider, deadline and response:
  - `PermissionRequest`: decided by `answer/4`, which names the row; deadline `deadline:`, 570 s
    by default, before the hook's 600 s timeout. The dialog stays on the screen for a person.
  - `PreToolUse`: decided by the app's `pre_tool_use:` callback, in a process of its own;
    deadline `tool_deadline:`, 5 s by default, under the hook's 10 s timeout. `:pass`, a crash,
    an exit or a value that is not a decision is a pass. A decision's row has the actor `app`,
    and a second post of the call's key answers the row's decision again, or an empty body.
  - A `PostToolUse` is answered 200 at once and handed to the `post_tool_use:` callback in a
    process of its own, with no row.

  After each write it calls `notify` with `%{topic: "intake:<host>:<account>", ids: ids}`, a
  cue and never the data. `CodingAgentFramework.Tracker.IntakeSource` reads the rows.
  """

  use GenServer

  alias CodingAgentFramework.Intake.{Event, Table}

  @deadline 570_000
  @tool_deadline 5_000
  # How long past a kind's deadline the plug waits, if the `Intake` stops answering: a
  # PreToolUse's deadline is at most 8 s under the hook's 10 s timeout.
  @margins %{permission: 5_000, tool: 1_500}
  @timeout 5_000
  @tools %{pre_tool_use: "PreToolUse", post_tool_use: "PostToolUse"}

  @typedoc """
  A tool call, as a callback gets it: the agent (`nil` when the `agent:` lookup knows none), its
  account and session, the tool's name and input, and its `tool_use_id`. A PostToolUse also
  has `tool_response`.
  """
  @type tool_event :: %{
          required(:agent) => String.t() | nil,
          required(:account) => String.t(),
          required(:session_id) => String.t(),
          required(:tool_name) => term,
          required(:tool_input) => term,
          required(:tool_use_id) => String.t(),
          optional(:tool_response) => term
        }

  @doc """
  Starts an `Intake`. Options: `db:` (this instance's SQLite path), `host:` (the node's host
  name), and optionally `notify:` (a function of one cue), `deadline:` (ms a hold is kept),
  `pre_tool_use:` (`fun(tool_event) -> :allow | {:deny, reason} | :ask | :pass`),
  `post_tool_use:` (`fun(tool_event)`, its value ignored), `tool_deadline:` (ms the first is
  waited for, under 8 s), `agent:` (`fun(account, session_id) -> name | nil`, for the events'
  `agent`) and `name:` (for the embedding app's tree; the library looks up no name).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc """
  The settings' `hooks` for `account`: an `http` hook per event of `Event.names/0`, and one for
  each tool callback named in `tools` (`:pre_tool_use`, `:post_tool_use`), posting to this
  host's port with the secret in the `x-caf-secret` header. PermissionRequest waits 600 s and
  the rest 10 s, which also raises SessionEnd's shared 1.5 s budget. `onFailure` is left at its
  default, continue, so a framework that is down never refuses a tool call.

      iex> hooks = CodingAgentFramework.Intake.hooks(4790, "work", "s3")
      iex> [%{"hooks" => [hook]}] = hooks["PermissionRequest"]
      iex> {hook["url"], hook["timeout"], Map.has_key?(hooks, "PreToolUse")}
      {"http://127.0.0.1:4790/hooks/work", 600, false}
      iex> CodingAgentFramework.Intake.hooks(4790, "work", "s3", [:pre_tool_use])["PreToolUse"]
      ...> |> hd() |> Map.fetch!("hooks") |> hd() |> Map.fetch!("timeout")
      10
  """
  @spec hooks(:inet.port_number(), String.t(), String.t(), [:pre_tool_use | :post_tool_use]) ::
          map
  def hooks(port, account, secret, tools \\ []) do
    Map.new(Event.names() ++ Enum.map(tools, &Map.fetch!(@tools, &1)), fn name ->
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
  `{:ok, :seen}` (a row with its key was there), or `{:ok, {:held, id, ref, wait}}` for a
  hold of any kind: the caller holds the request and waits up to `wait` ms for
  `{ref, {:decision, body}}` or `{ref, :release}`, and after writing a decision calls
  `written/3`. A PreToolUse whose row has a decision is `{:ok, {:decided, body}}`. A tool event
  with no callback is `{:ok, :not_read}`, and a PostToolUse handed to its callback
  `{:ok, :handed}`.
  """
  @spec post(GenServer.server(), String.t(), binary, keyword) ::
          {:ok,
           :stored
           | :seen
           | :not_read
           | :handed
           | {:held, integer, reference, pos_integer}
           | {:decided, binary}}
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
          deadlines: %{
            permission: Keyword.get(opts, :deadline, @deadline),
            tool: Keyword.get(opts, :tool_deadline, @tool_deadline)
          },
          pre_tool_use: Keyword.get(opts, :pre_tool_use),
          post_tool_use: Keyword.get(opts, :post_tool_use),
          agent: Keyword.get(opts, :agent, fn _, _ -> nil end),
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
  def handle_call({:post, account, body}, from, state) do
    case Event.parse(body) do
      %{event: "PreToolUse"} when state.pre_tool_use == nil -> {:reply, {:ok, :not_read}, state}
      %{event: "PostToolUse"} = row -> post_tool_use(row, account, state)
      row -> store(row, account, from, state)
    end
  end

  def handle_call({:answer, id, decision}, from, state) do
    with {:ok, body} <- permission_response(decision),
         %{kind: :permission} <- state.holds[id],
         {:ok, state} <- decide(state, id, body, nil) do
      {:noreply, put_in(state.holds[id][:from], from)}
    else
      {:refused, _} = refused -> {:reply, refused, state}
      _ -> {:reply, {:refused, {:not_held, hold_of(state, id)}}, state}
    end
  end

  defp post_tool_use(_row, _account, %{post_tool_use: nil} = state),
    do: {:reply, {:ok, :not_read}, state}

  defp post_tool_use(row, account, state) do
    %{post_tool_use: callback, agent: agent} = state
    spawn(fn -> callback.(tool_event(row, account, agent)) end)
    {:reply, {:ok, :handed}, state}
  end

  # Built in the callback's own process, unlinked, so neither a slow `agent` lookup nor a crash
  # reaches this process. The answer comes back as a message, and a crash or exit as `:DOWN`.
  defp tool_event(row, account, agent) do
    data = JSON.decode!(row.data)

    event = %{
      agent: agent.(account, row.session_id),
      account: account,
      session_id: row.session_id,
      tool_name: data["tool_name"],
      tool_input: data["tool_input"],
      tool_use_id: data["tool_use_id"]
    }

    if row.event == "PostToolUse",
      do: Map.put(event, :tool_response, data["tool_response"]),
      else: event
  end

  defp store(row, account, {pid, _}, state) do
    case Table.insert(state.db, state.host, account, row, now()) do
      # A second post of a PreToolUse answers the row's decision, or none.
      {:seen, _id, _hold, decision} when row.event == "PreToolUse" and decision != nil ->
        {:reply, {:ok, {:decided, decision}}, state}

      {:seen, _id, _hold, _decision} ->
        {:reply, {:ok, :seen}, state}

      {:new, id} when row.hold ->
        # Spec actions HoldStored and ToolHeld (Hold's Held): the row says held while the plug
        # keeps the request open, and the deadline starts.
        kind = if row.event == "PreToolUse", do: :tool, else: :permission

        hold = %{
          kind: kind,
          account: account,
          pid: pid,
          ref: make_ref(),
          mon: Process.monitor(pid)
        }

        hold =
          Map.put(hold, :timer, Process.send_after(self(), {:expire, id}, state.deadlines[kind]))

        hold = if kind == :tool, do: ask(state, id, hold, row), else: hold
        cue(state, account, [id])
        wait = state.deadlines[kind] + @margins[kind]
        {:reply, {:ok, {:held, id, hold.ref, wait}}, put_in(state.holds[id], hold)}

      {:new, id} ->
        # Spec action Stored: the row is written before the plug's 200 (Acked).
        cue(state, account, [id])
        {:reply, {:ok, :stored}, state}
    end
  end

  # Spec action ToolHeld: the app's callback is asked in a process of its own.
  defp ask(state, id, hold, row) do
    {me, %{pre_tool_use: callback, agent: agent}} = {self(), state}
    ask = fn -> send(me, {:tool_answer, id, callback.(tool_event(row, hold.account, agent))}) end
    {_, wmon} = spawn_monitor(ask)
    Map.put(hold, :wmon, wmon)
  end

  # Hold's Asked: the row says deciding, with the response it carries, before the response is
  # handed to the plug (Decides). Only a held row moves, so a late decision is dropped.
  defp decide(state, id, body, actor) do
    hold = state.holds[id]

    if Table.move(state.db, id, "held", "deciding", body, now(), actor) do
      send(hold.pid, {hold.ref, {:decision, body}})
      cue(state, hold.account, [id])
      {:ok, put_in(state.holds[id], hold |> Map.put(:deciding, true) |> unwatch())}
    else
      :not_held
    end
  end

  # An empty response to a held request, and its row's end: Hold's Empty.
  defp release(state, id, hold, row_end) do
    Table.move(state.db, id, "held", row_end, nil, now())
    send(hold.pid, {hold.ref, :release})
    drop(state, id, hold)
  end

  @impl true
  def handle_cast({:written, id, ref}, state) do
    case state.holds[id] do
      %{ref: ^ref, deciding: true} = hold ->
        # Spec actions AnswerMarked and ToolMarked (Hold's Marked): the plug wrote the decision.
        Table.move(state.db, id, "deciding", "answered", nil, now())
        if hold[:from], do: GenServer.reply(hold.from, {:ok, :sent})
        {:noreply, drop(state, id, hold)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:expire, id}, state) do
    case state.holds[id] do
      # Spec actions HoldExpires and ToolDeadline: no decision. A deciding hold is past it.
      %{deciding: true} -> {:noreply, state}
      %{} = hold -> {:noreply, release(state, id, hold, "expired")}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:tool_answer, id, answer}, state) do
    case {state.holds[id], tool_response(answer)} do
      # A decision after the deadline, or for a request gone: dropped, never sent (LateDropped).
      {nil, _} -> {:noreply, state}
      {%{deciding: true}, _} -> {:noreply, state}
      {hold, :pass} -> {:noreply, release(state, id, hold, "passed")}
      {_, {:decision, body}} -> {:noreply, decided(state, decide(state, id, body, "app"))}
    end
  end

  def handle_info({:DOWN, mon, :process, _, reason}, state) do
    case Enum.find(state.holds, fn {_, h} -> mon in [h.mon, h[:wmon]] end) do
      # The callback crashed or exited before it answered: no decision.
      {id, %{wmon: ^mon} = hold} -> {:noreply, release(state, id, hold, "passed")}
      # Spec actions HoldSettled and ToolSettled (Hold's Cut, then Settles): the request
      # closed before its response was written.
      {id, hold} -> {:noreply, settle(state, id, hold, reason)}
      nil -> {:noreply, state}
    end
  end

  defp settle(state, id, %{deciding: true} = hold, reason) do
    Table.move(state.db, id, "deciding", "unknown", nil, now())
    if hold[:from], do: GenServer.reply(hold.from, {:unknown, {:request_closed, reason}})
    drop(state, id, hold)
  end

  defp settle(state, id, hold, _reason) do
    Table.move(state.db, id, "held", "lost", nil, now())
    drop(state, id, hold)
  end

  defp decided(_state, {:ok, state}), do: state
  defp decided(state, :not_held), do: state

  defp unwatch(%{wmon: wmon} = hold) do
    Process.demonitor(wmon, [:flush])
    Map.delete(hold, :wmon)
  end

  defp unwatch(hold), do: hold

  # One drop for every kind: whatever comes for this hold after it is dropped.
  defp drop(state, id, hold) do
    hold = unwatch(hold)
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

  # The PreToolUse output in the shape Claude Code 2.1.322 reads. It keeps a reason only beside
  # deny or ask, so an allow carries none.
  defp tool_response(:allow), do: tool_response("allow", %{})
  defp tool_response(:ask), do: tool_response("ask", %{})

  defp tool_response({:deny, reason}) when is_binary(reason),
    do: tool_response("deny", %{"permissionDecisionReason" => reason})

  defp tool_response(_), do: :pass

  defp tool_response(decision, reason) do
    output =
      Map.merge(%{"hookEventName" => "PreToolUse", "permissionDecision" => decision}, reason)

    {:decision, JSON.encode!(%{"hookSpecificOutput" => output})}
  end

  # The PermissionRequest output in the shape Claude Code 2.1.322 reads (F-24).
  defp permission_response(decision) do
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
