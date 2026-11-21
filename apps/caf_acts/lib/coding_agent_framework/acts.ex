defmodule CodingAgentFramework.Acts do
  @moduledoc """
  One ledger of acts (`docs/design.md`, "The parts"; `model/tla/Claim.tla`): an actor's act on
  a target's state, written before it acts, once per state, settled after, closed as
  interrupted when a restart cut it, with a cue. An agent's fix, the operator's act and a
  recovery take their claim here; a start takes a row with no state (each call is an act of its
  own), settled by its answer (`answered/4`); a raised error is a record. The fault ledger is
  `faults/2` and the same cue.

  One process owns the table (`CodingAgentFramework.Acts.Table`) and writes it; the embedding
  app's supervision tree starts it. Each answer is `{:ok, …}`, `{:refused, reason}` or, when
  the call itself ends without an answer, `{:unknown, reason}`. Nothing retries or waits.

  **A row's status** is one of `skipped` (a state seen and not acted on, which a claim takes
  over: `Recoveries`' sample too old), `claimed` (written before the act), `acted` (the act ran;
  its outcome waits for a later reading), `settled` (with an `outcome`: `recovered`, `failed`,
  `unknown`, `verified` or `not_verified`) and `interrupted` (a restart cut it before its act;
  never acted on). A settled or interrupted row is never reopened, and its state stays claimed:
  a second claim is refused `{:already_claimed, by}`, a claim of an open one `{:claimed, by}`.

  **A restart** opens the table with a new `start_id` (made once per framework start by the
  embedding app): every row still `claimed` that another start wrote is closed `interrupted`.
  A caller that restarts within one start closes its own with `interrupt/2`.

  **Cues.** After each write it calls `notify` with `%{topic: "acts:<host>:<instance>", ids:
  ids}`, the topic of the `Tracker`'s source made from `Acts.Table.meta/0`.

      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> alias CodingAgentFramework.Acts
      iex> {:ok, acts} = Acts.start_link(db: Path.join(dir, "acts.db"), start_id: "s1",
      ...>   host: "laptop", instance: "a")
      iex> {:ok, id} = Acts.claim(acts, "app-main", "app-fix", %{epoch: 1}, :interrupt)
      iex> Acts.claim(acts, "operator", "app-fix", %{epoch: 1}, :resume)
      {:refused, {:claimed, "app-main"}}
      iex> Acts.settle(acts, id, :verified)
      {:ok, :verified}
      iex> Acts.claim(acts, "operator", "app-fix", %{epoch: 1}, :resume)
      {:refused, {:already_claimed, "app-main"}}
  """

  use GenServer

  alias CodingAgentFramework.Acts.Table
  alias CodingAgentFramework.Store

  @timeout 5_000
  @open ~w(claimed acted)
  @outcomes ~w(recovered failed unknown verified not_verified)a
  # The outcomes the fault ledger shows, beside every interrupted row.
  @faults ~w(failed unknown not_verified)
  # What a caller may set on its row, beside the status and outcome.
  @fields ~w(reason answer detail)a

  @type id :: integer
  @type answer(ok) :: {:ok, ok} | {:refused, term} | {:unknown, term}

  @doc """
  Starts the writer. Options: `db` (the SQLite file), `start_id`, `host` and `instance` (its
  cue's topic), and optionally `notify`, `clock` (a function answering the time in ms) and
  `claims` (the file of the claims table `Acts` replaced, whose rows it takes, F-126). Opening
  takes the rows of the replaced tables, then closes the rows of other starts still `claimed`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The topics of the cues it writes, each as its whole shape, `*` for a word it fills in
  (`CodingAgentFramework.Cues`): `acts:<host>:<instance>`.
  """
  @spec writes() :: [String.t()]
  def writes, do: ~w(acts:*:*)

  @doc """
  Claims `target` in `state` for `act` by `actor`: writes its row `claimed` before the act.
  Refused `{:claimed, by}` while another claim of that state is open, and `{:already_claimed,
  by}` once one has ended, whatever its end. A `skipped` row of the state is taken over.
  Option `detail:` is written on the row with the claim, so a reader knows the act's kind
  before it runs: the operator's forced end, `%{force: true}` (F-172).
  """
  @spec claim(GenServer.server(), String.t(), String.t(), term, atom | String.t(), keyword) ::
          answer(id)
  def claim(acts, actor, target, state, act, opts \\ []) do
    row = row(actor, target, state, act)
    row = if d = opts[:detail], do: Map.put(row, :detail, Store.text(d)), else: row
    call(acts, {:claim, row}, opts)
  end

  @doc """
  Writes a state seen and not acted on as `skipped`, with `reason`: a later claim takes it over.
  A `skipped` row of the state takes the new reason; any other is refused as `claim/6` is.
  """
  @spec skip(GenServer.server(), String.t(), String.t(), term, atom | String.t(), term, keyword) ::
          answer(id)
  def skip(acts, actor, target, state, act, reason, opts \\ []),
    do: call(acts, {:skip, row(actor, target, state, act), Store.text(reason)}, opts)

  @doc """
  The act ran and its outcome waits for a later reading: a `claimed` row becomes `acted`, with
  `fields` (`reason`, `answer`, `detail`). Refused `{:not_claimed, status}` otherwise.
  """
  @spec acted(GenServer.server(), id, keyword, keyword) :: answer(:acted)
  def acted(acts, id, fields \\ [], opts \\ []), do: call(acts, {:acted, id, dump(fields)}, opts)

  @doc """
  Ends an open row (`claimed` or `acted`) with `outcome`, one of #{inspect(@outcomes)}, and
  `fields` (`reason`, `answer`, `detail`; `acted: true` stamps the act's time on a row that had
  none). Refused `{:not_open, status}` for an ended row, `:unknown_act` for none.
  """
  @spec settle(GenServer.server(), id, atom, keyword, keyword) :: answer(atom)
  def settle(acts, id, outcome, fields \\ [], opts \\ []) when outcome in @outcomes do
    acted = Keyword.get(fields, :acted, false)
    call(acts, {:settle, id, outcome, dump(fields), acted}, opts)
  end

  @doc """
  Settles open row `id` by the answer of the act it claimed, one rule for every part: `{:ok,
  _}` is `verified`; `{:refused, reason}` is `failed`, with the reason and no act's time (a
  refusal acts on nothing); `{:unknown, reason}` is `unknown`, with the reason, since the act
  may have run. `settle/5`'s answer.

      Acts.answered(acts, id, Sessions.start(sessions, "reviewer", account, launch))
      #=> {:ok, :verified}
  """
  @spec answered(GenServer.server(), id, term, keyword) :: answer(atom)
  def answered(acts, id, answer, opts \\ [])
  def answered(acts, id, {:ok, _}, opts), do: settle(acts, id, :verified, [acted: true], opts)

  def answered(acts, id, {:refused, why}, opts),
    do: settle(acts, id, :failed, [reason: why], opts)

  def answered(acts, id, {:unknown, why}, opts),
    do: settle(acts, id, :unknown, [reason: why, acted: true], opts)

  def answered(acts, id, other, opts),
    do: settle(acts, id, :unknown, [reason: {:answer, other}, acted: true], opts)

  @doc """
  Writes an act that takes no claim, already settled: a raised error. `fields` as
  `settle/5`'s.
  """
  @spec record(
          GenServer.server(),
          String.t(),
          String.t(),
          atom | String.t(),
          atom,
          keyword,
          keyword
        ) ::
          answer(id)
  def record(acts, actor, target, act, outcome, fields \\ [], opts \\ [])
      when outcome in @outcomes,
      do: call(acts, {:record, row(actor, target, nil, act), outcome, dump(fields)}, opts)

  @doc """
  Closes `actor`'s rows still `claimed` as `interrupted`: the actor restarted, and the calls
  that held them are gone. Answers their ids.
  """
  @spec interrupt(GenServer.server(), String.t(), keyword) :: answer([id])
  def interrupt(acts, actor, opts \\ []), do: call(acts, {:interrupt, actor}, opts)

  @doc """
  A person clears the ended rows with these ids that wait for one: each takes `cleared_at`, once.
  Answers the ids it cleared.
  """
  @spec clear(GenServer.server(), [id], keyword) :: answer([id])
  def clear(acts, ids, opts \\ []), do: call(acts, {:clear, ids}, opts)

  @doc "Row `id`, or `{:refused, :unknown_act}`."
  @spec get(GenServer.server(), id, keyword) :: answer(map)
  def get(acts, id, opts \\ []), do: call(acts, {:get, id}, opts)

  @doc """
  The rows whose columns equal `filter`'s values (a list is any of them, nil is NULL), oldest
  first: `rows(acts, actor: "operator", status: ["claimed", "acted"])`. `since: at` keeps the
  rows claimed, acted, ended or cleared at `at` or later, so a reader of a ledger that keeps
  every row reads what changed in its window, not every row (F-126's new-5).
  """
  @spec rows(GenServer.server(), keyword, keyword) :: answer([map])
  def rows(acts, filter \\ [], opts \\ []), do: call(acts, {:rows, filter, false}, opts)

  @doc """
  The fault ledger: the rows within `filter` that went wrong, each a fault (`fault?/1`), oldest
  first. A row a person cleared stays in it, with `cleared_at`.
  """
  @spec faults(GenServer.server(), keyword, keyword) :: answer([map])
  def faults(acts, filter \\ [], opts \\ []), do: call(acts, {:rows, filter, true}, opts)

  @doc """
  Whether a row is a fault: interrupted, or settled `failed`, `unknown` or `not_verified`.

      iex> CodingAgentFramework.Acts.fault?(%{status: "settled", outcome: "unknown"})
      true
      iex> CodingAgentFramework.Acts.fault?(%{status: "settled", outcome: "recovered"})
      false
  """
  @spec fault?(map) :: boolean
  def fault?(%{status: "interrupted"}), do: true
  def fault?(%{status: "settled", outcome: outcome}), do: outcome in @faults
  def fault?(_), do: false

  defp row(actor, target, state, act),
    do: %{actor: actor, target: target, state: Store.text(state), act: Store.text(act)}

  defp dump(fields), do: for({k, v} <- fields, k in @fields, do: {k, Store.text(v)})

  defp call(acts, request, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    GenServer.call(acts, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_acts}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @timeout)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    start_id = Keyword.fetch!(opts, :start_id)
    clock = Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end)

    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      Table.take_recoveries(db)
      Table.take_claims(db, opts[:claims])

      # Only a row another start wrote is cut off; this start's rows are live.
      Store.query(
        db,
        "UPDATE acts SET status = 'interrupted', ended_at = ?2 " <>
          "WHERE status = 'claimed' AND start_id != ?1",
        [start_id, clock.()]
      )

      topic = "acts:#{Keyword.fetch!(opts, :host)}:#{Keyword.fetch!(opts, :instance)}"

      {:ok,
       %{
         db: db,
         start_id: start_id,
         clock: clock,
         topic: topic,
         notify: Keyword.get(opts, :notify, fn _ -> :ok end)
       }}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:claim, row}, _from, s) do
    taken =
      "actor = excluded.actor, act = excluded.act, start_id = excluded.start_id, " <>
        "status = 'claimed', reason = NULL, claimed_at = excluded.claimed_at"

    {:reply, insert(s, row, "claimed", nil, taken), s}
  end

  def handle_call({:skip, row, reason}, _from, s),
    do: {:reply, insert(s, row, "skipped", reason, "reason = excluded.reason"), s}

  def handle_call({:acted, id, fields}, _from, s) do
    reply =
      case fetch(s.db, id) do
        nil ->
          {:refused, :unknown_act}

        %{status: "claimed"} ->
          write(s, id, [status: "acted", acted_at: now(s)] ++ fields)
          {:ok, :acted}

        %{status: status} ->
          {:refused, {:not_claimed, String.to_existing_atom(status)}}
      end

    {:reply, reply, s}
  end

  def handle_call({:settle, id, outcome, fields, acted}, _from, s) do
    reply =
      case fetch(s.db, id) do
        nil ->
          {:refused, :unknown_act}

        %{status: status} = row when status in @open ->
          at = now(s)
          stamp = if acted and is_nil(row.acted_at), do: [acted_at: at], else: []
          end_fields = [status: "settled", outcome: Atom.to_string(outcome), ended_at: at]
          write(s, id, end_fields ++ stamp ++ fields)
          {:ok, outcome}

        %{status: status} ->
          {:refused, {:not_open, String.to_existing_atom(status)}}
      end

    {:reply, reply, s}
  end

  def handle_call({:record, row, outcome, fields}, _from, s) do
    at = now(s)

    base = [
      status: "settled",
      outcome: Atom.to_string(outcome),
      start_id: s.start_id,
      claimed_at: at,
      acted_at: at,
      ended_at: at
    ]

    [[id]] = Store.insert(s.db, "acts", Map.to_list(row) ++ base ++ fields, "RETURNING id")
    cue(s, [id])
    {:reply, {:ok, id}, s}
  end

  def handle_call({:interrupt, actor}, _from, s) do
    ids =
      for [id] <-
            Store.query(
              s.db,
              "UPDATE acts SET status = 'interrupted', ended_at = ?2 " <>
                "WHERE actor = ?1 AND status = 'claimed' RETURNING id",
              [actor, now(s)]
            ),
          do: id

    if ids != [], do: cue(s, ids)
    {:reply, {:ok, ids}, s}
  end

  def handle_call({:clear, []}, _from, s), do: {:reply, {:ok, []}, s}

  def handle_call({:clear, ids}, _from, s) do
    ids =
      for [id] <-
            Store.query(
              s.db,
              "UPDATE acts SET cleared_at = ?1 WHERE cleared_at IS NULL " <>
                "AND status IN ('settled', 'interrupted') " <>
                "AND id IN (#{Store.marks(length(ids), 2)}) RETURNING id",
              [now(s) | ids]
            ),
          do: id

    if ids != [], do: cue(s, ids)
    {:reply, {:ok, Enum.sort(ids)}, s}
  end

  def handle_call({:get, id}, _from, s) do
    {:reply, if(row = fetch(s.db, id), do: {:ok, row}, else: {:refused, :unknown_act}), s}
  end

  def handle_call({:rows, filter, faults}, _from, s) do
    reply =
      case Keyword.keys(filter) -- [:since | Table.columns()] do
        [] ->
          {where, args} = where(filter)
          rows = Table.select(s.db, where, args)
          {:ok, if(faults, do: Enum.filter(rows, &fault?/1), else: rows)}

        [k | _] ->
          {:refused, {:no_column, k}}
      end

    {:reply, reply, s}
  end

  # The row first, then its claim decided by the unique index: a conflict updates only a
  # `skipped` row, and answers who holds the state otherwise.
  defp insert(s, row, status, reason, update) do
    fields =
      Map.to_list(row) ++
        [start_id: s.start_id, status: status, reason: reason, claimed_at: now(s)]

    case Store.insert(
           s.db,
           "acts",
           fields,
           "ON CONFLICT (target, state) DO UPDATE SET #{update} " <>
             "WHERE acts.status = 'skipped' RETURNING id"
         ) do
      [[id]] ->
        cue(s, [id])
        {:ok, id}

      [] ->
        [%{status: held, actor: by}] =
          Table.select(s.db, "target = ?1 AND state = ?2", [row.target, row.state])

        {:refused, {if(held in @open, do: :claimed, else: :already_claimed), by}}
    end
  end

  defp write(s, id, fields) do
    Store.update(s.db, "acts", id, fields)
    cue(s, [id])
  end

  defp fetch(db, id), do: List.first(Table.select(db, "id = ?1", [id]))

  defp where(filter) do
    {clauses, args} =
      Enum.reduce(filter, {[], []}, fn
        {:since, at}, {clauses, args} ->
          n = length(args) + 1

          times =
            Enum.map_join(~w(claimed_at acted_at ended_at cleared_at), " OR ", &"#{&1} >= ?#{n}")

          {clauses ++ ["(#{times})"], args ++ [at]}

        {k, nil}, {clauses, args} ->
          {clauses ++ ["#{k} IS NULL"], args}

        {k, v}, {clauses, args} ->
          values = List.wrap(v)
          marks = Store.marks(length(values), length(args) + 1)
          {clauses ++ ["#{k} IN (#{marks})"], args ++ values}
      end)

    {if(clauses == [], do: "1 = 1", else: Enum.join(clauses, " AND ")), args}
  end

  defp cue(s, ids), do: s.notify.(%{topic: s.topic, ids: ids})

  defp now(s), do: s.clock.()
end
