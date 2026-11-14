defmodule CodingAgentFramework.Stream do
  @moduledoc """
  The host's one writer for headless delegates: it writes lines into each delegate's stdin and
  reads its event log, built against `model/tla/Stream.tla` ("Headless delegates" in
  `docs/design.md`). The caller's supervision tree starts one per host, with no name. It writes
  `CodingAgentFramework.Stream.Table`, which it alone writes, and after a write that changed rows
  `notify` gets a cue `%{topic: "stream:<host>", ids: ids}`.

  Each delegate has a directory `<home>/streams/<session>/` with the FIFO `in`, the log
  `events.jsonl` and spool files `out/<uuid>.json`; `follow/4` makes them before the delegate is
  held. A write marks its row, spools the line, and starts the claim command
  `exec 3<spool && rm spool && exec cat <&3 >fifo`, only for a live delegate and under the
  write's deadline. Removing the spool is the claim: a line is never written twice, never cut by
  the framework, and a restart claims again only what no claim took. `read/2` folds the whole
  lines of each log from its saved offset (`CodingAgentFramework.Stream.Fold`).

  Nothing here kills a process: an end is the `end_session` line, and a claim still waiting past
  its deadline is `Shell`'s to end, by its pid.
  """

  use GenServer

  alias CodingAgentFramework.{Holder, Programs, Shell}
  alias CodingAgentFramework.Stream.{Fold, Line, Table}

  @timeout 5_000
  @follow ~S"""
  "$2" -p "$1/out" && { [ -p "$1/in" ] || "$3" "$1/in"; }
  """
  @spool ~S"""
  printf '%s' "$2" > "$1"
  """
  # Exit 9: no spool, so a claim took it before (this run's or an earlier one's).
  @claim ~S"""
  [ -e "$1" ] || exit 9
  exec 3<"$1" && "$3" "$1" && exec "$4" <&3 >"$2"
  """
  @tail ~S"""
  [ -f "$1" ] || { printf 'nofile'; exit 0; }
  printf 'file'
  exec "$2" -c "+$3" "$1"
  """

  @doc """
  Starts a `Stream`. Options: `programs:` (naming sh, rm, cat, tail, mkdir and mkfifo),
  `holder:` (the `Holder` whose sockets hold the delegates), `home:` (the framework home on the
  host), `db:`, and optionally `notify:` and `timeout:` (ms per shell run, default 5 s).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc ~S"""
  A delegate's directory under `home`.

      iex> CodingAgentFramework.Stream.dir("/h", "s1")
      "/h/streams/s1"
  """
  @spec dir(String.t(), String.t()) :: String.t()
  def dir(home, session), do: Path.join([home, "streams", session])

  @doc """
  Makes `session`'s directory and FIFO and starts following it: its dtach socket is `socket` in
  the holder, and `transcript` is its transcript's path, read only to settle a message at its
  exit. Answers `{:ok, dir}`. Following a session again keeps its row.
  """
  def follow(stream, session, socket, transcript, opts \\ []),
    do: call(stream, {:follow, session, socket, transcript}, opts)

  @doc """
  Writes one line: `{:message, text}` (or `{:message, uuid, text}` to keep a uuid on a resend),
  `{:answer, request_id, :allow | {:deny, message}}`, `:interrupt` or `:end_session`. Option
  `:timeout` is the write's deadline (default 5 s).

  Answers `{:ok, %{uuid: uuid}}` once the line is in the pipe; `{:refused, reason}` when nothing
  was marked or written (`:not_live`, `:turn_running`, `:message_waiting`, `:no_request`,
  `:gone`, …); `{:unknown, reason}` when the row is marked and the line may or may not go in:
  the replay, a later claim or the exit settles it.
  """
  def write(stream, session, line, opts \\ []) do
    deadline = Keyword.get(opts, :timeout, @timeout)
    call(stream, {:write, session, line, deadline}, timeout: 3 * deadline)
  end

  @doc "Interrupts the delegate's turn: `write(stream, session, :interrupt, opts)`."
  def interrupt(stream, session, opts \\ []), do: write(stream, session, :interrupt, opts)

  @doc "Ends the session; it cuts a running turn, so it goes in after the turn ended."
  def end_session(stream, session, opts \\ []), do: write(stream, session, :end_session, opts)

  @doc """
  Reads each followed delegate's log, claims again what a restart left unclaimed, and sees its
  exit. Answers `{:ok, %{ids: ids, failed: [{session, reason}]}}`; a failed read changes nothing.
  """
  def read(stream, opts \\ []), do: call(stream, :read, opts)

  @doc "The rows, as `Table.rows/2` gives them."
  def rows(stream, opts \\ []), do: call(stream, :rows, opts)

  defp call(stream, request, opts) do
    timeout = Keyword.get(opts, :timeout, 6 * @timeout)

    try do
      GenServer.call(stream, request, timeout)
    catch
      :exit, {:noproc, _} -> {:refused, :no_stream}
      :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
      :exit, {reason, _} -> {:unknown, {:exit, reason}}
    end
  end

  @impl true
  def init(opts) do
    %Programs{host: host} = programs = Keyword.fetch!(opts, :programs)

    with {:ok, paths} <- Programs.take(programs, [:sh, :rm, :cat, :tail, :mkdir, :mkfifo]),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      {:ok,
       %{
         host: host,
         db: db,
         p: paths,
         holder: %Holder{} = Keyword.fetch!(opts, :holder),
         home: Keyword.fetch!(opts, :home),
         notify: Keyword.get(opts, :notify, fn _ -> :ok end),
         timeout: Keyword.get(opts, :timeout, @timeout),
         delegates: Table.delegates(db, host.name)
       }}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:follow, session, socket, transcript}, _from, s) do
    d = dir(s.home, session)

    case sh(s, @follow, [d, s.p.mkdir, s.p.mkfifo], s.timeout) do
      {:ok, %{status: 0}} ->
        delegate = Map.get(s.delegates, session, %{fold: Fold.new()})

        {:reply, {:ok, d},
         save(s, session, Map.merge(delegate, %{socket: socket, transcript: transcript}))}

      other ->
        {:reply, failed(other), s}
    end
  end

  def handle_call({:write, session, term, deadline}, _from, s) do
    ends = System.monotonic_time(:millisecond) + deadline

    with {:ok, d} <- fetch(s, session),
         {:ok, line_term} <- with_id(term),
         {:ok, line} <- Line.encode(line_term),
         :ok <- Fold.check(d.fold, line_term),
         :ok <- live(s, d) do
      # Mark (AnswerAsked for an answer): the row first, before anything is written.
      d = put_in(d.fold, Fold.mark(d.fold, line_term, line, System.os_time(:millisecond)))
      s = save(s, session, d)
      {reply, s} = claim(s, session, elem(line_term, 1), ends)
      {:reply, with({:ok, _} <- reply, do: {:ok, %{uuid: elem(line_term, 1)}}), s}
    else
      other -> {:reply, other, s}
    end
  end

  def handle_call(:read, _from, s) do
    {s, ids, failed} =
      Enum.reduce(s.delegates, {s, [], []}, fn
        {_session, %{fold: %{gone: true}}}, acc ->
          acc

        {session, d}, {s, ids, failed} ->
          case read_one(s, session, d) do
            {:ok, ^d} -> {s, ids, failed}
            {:ok, d} -> {s, [{session, d} | ids], failed}
            other -> {s, ids, [{session, other} | failed]}
          end
      end)

    written = Table.write(s.db, s.host.name, ids, System.os_time(:millisecond))
    s = %{s | delegates: Map.merge(s.delegates, Map.new(ids))}
    if written != [], do: s.notify.(%{topic: topic(s), ids: written})
    # Claim again what a restart left marked or spooled, for a live delegate only.
    s = Enum.reduce(Map.keys(s.delegates), s, &reclaim(&2, &1))
    {:reply, {:ok, %{ids: written, failed: Enum.reverse(failed)}}, s}
  end

  def handle_call(:rows, _from, s), do: {:reply, Table.rows(s.db, s.host.name), s}

  defp read_one(s, session, d) do
    # The pid is checked before the log is read, so a delegate seen gone has written its last
    # whole line before this read.
    with {:ok, state} <- Holder.state(s.holder, d.socket),
         {:ok, bytes} <- tail(s, Path.join(dir(s.home, session), "events.jsonl"), d.fold.offset) do
      # Read: the whole lines, handled; the offset is saved with them in one transaction.
      fold = %{Fold.take(d.fold, bytes) | live_seen: d.fold.live_seen or state == :live}

      if state != :live and fold.live_seen,
        do: exit_seen(s, %{d | fold: fold}),
        else: {:ok, %{d | fold: fold}}
    end
  end

  # ExitSeen: a message still writing is settled by the transcript; a failed read decides
  # nothing.
  defp exit_seen(s, d) do
    case Fold.writing(d.fold) do
      [] ->
        {:ok, %{d | fold: Fold.exit_seen(d.fold, fn _ -> false end)}}

      _ ->
        with {:ok, bytes} <- tail(s, d.transcript, 0),
             do: {:ok, %{d | fold: Fold.exit_seen(d.fold, &String.contains?(bytes, &1))}}
    end
  end

  defp reclaim(s, session) do
    d = s.delegates[session]
    ends = System.monotonic_time(:millisecond) + s.timeout

    if d.fold.lines == %{} or d.fold.gone or live(s, d) != :ok,
      do: s,
      else: Enum.reduce(Map.keys(d.fold.lines), s, &elem(claim(&2, session, &1, ends), 1))
  end

  # Claim: spool the line (again, whole, if no claim can have taken it), then run the claim
  # command, which removes the spool before it writes. Answers the outcome and the state.
  defp claim(s, session, id, ends) do
    d = s.delegates[session]
    %{line: line, phase: phase} = d.fold.lines[id]
    out = Path.join([dir(s.home, session), "out", id <> ".json"])

    with {:ok, s} <- spool(s, session, id, phase, out, line, ends),
         {:ok, s} <- run_claim(s, session, id, out, ends) do
      {{:ok, :written}, s}
    end
  end

  defp spool(s, _session, _id, :spooled, _out, _line, _ends), do: {:ok, s}

  defp spool(s, session, id, :marked, out, line, ends) do
    case sh(s, @spool, [out, line], left(ends)) do
      {:ok, %{status: 0}} -> {:ok, save(s, session, &Fold.phase(&1, id, :spooled))}
      other -> {failed(other), s}
    end
  end

  defp run_claim(s, session, id, out, ends) do
    fifo = Path.join(dir(s.home, session), "in")

    case sh(s, @claim, [out, fifo, s.p.rm, s.p.cat], left(ends)) do
      # CatWrites: the line is in the pipe, whole; or an earlier claim took it.
      {:ok, %{status: status}} when status in [0, 9] ->
        {:ok, save(s, session, &Fold.phase(&1, id, :claimed))}

      other ->
        {failed(other), s}
    end
  end

  defp left(ends), do: max(ends - System.monotonic_time(:millisecond), 1)

  defp live(s, d) do
    case Holder.state(s.holder, d.socket) do
      {:ok, :live} -> :ok
      {:ok, state} -> {:refused, {:not_live, state}}
      other -> other
    end
  end

  defp fetch(s, session) do
    case s.delegates[session] do
      %{fold: %{gone: true}} -> {:refused, :gone}
      nil -> {:refused, :not_followed}
      d -> {:ok, d}
    end
  end

  defp with_id({:message, text}), do: {:ok, {:message, uuid(), text}}
  defp with_id({:message, uuid, text}) when is_binary(uuid), do: {:ok, {:message, uuid, text}}
  defp with_id({:answer, id, decision}) when is_binary(id), do: {:ok, {:answer, id, decision}}
  defp with_id(kind) when kind in [:interrupt, :end_session], do: {:ok, {kind, uuid()}}
  defp with_id(_), do: {:refused, :bad_line}

  defp save(s, session, fun) when is_function(fun),
    do: save(s, session, Map.update!(s.delegates[session], :fold, fun))

  defp save(s, session, d) do
    ids = Table.write(s.db, s.host.name, [{session, d}], nil)
    s.notify.(%{topic: topic(s), ids: ids})
    %{s | delegates: Map.put(s.delegates, session, d)}
  end

  defp tail(s, path, offset) do
    case sh(s, @tail, [path, s.p.tail, Integer.to_string(offset + 1)], s.timeout) do
      {:ok, %{status: 0, output: "nofile"}} -> {:ok, ""}
      {:ok, %{status: 0, output: "file" <> bytes}} -> {:ok, bytes}
      other -> failed(other)
    end
  end

  defp sh(s, script, args, timeout),
    do: Shell.run(s.host, s.p.sh, ["-c", script, "sh" | args], timeout: timeout)

  defp failed({:ok, %{status: status, output: out}}),
    do: {:unknown, {:sh, status, String.slice(out, 0, 200)}}

  defp failed(other), do: other

  defp topic(s), do: "stream:#{s.host.name}"

  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u::128>> = <<a::48, 4::4, b::12, 2::2, c::62>>
    hex = u |> Integer.to_string(16) |> String.pad_leading(32, "0") |> String.downcase()

    Enum.map_join([0..7, 8..11, 12..15, 16..19, 20..31], "-", &String.slice(hex, &1))
  end
end
