defmodule CodingAgentFramework.Stream do
  @moduledoc """
  The host's one writer for headless delegates: it writes lines into each delegate's stdin and
  reads its event log, built against `model/tla/Stream.tla` ("Headless delegates" in
  `docs/design.md`). The caller's supervision tree starts one per host, with no name. It writes
  `CodingAgentFramework.Stream.Table`, which it alone writes, and after a write that changed rows
  `notify` gets a cue `%{topic: "stream:<host>", ids: ids}`.

  Each delegate has a directory `<home>/streams/<session>/` with a FIFO `in.<n>` per process, the
  log `events.jsonl` and spool files `out/<uuid>.json`; `follow/5` makes them before the
  delegate is held. A write marks its row, spools the line, and starts the claim command
  `exec 3<spool && rm spool && exec cat <&3 >fifo`, only for a live delegate and under the
  write's deadline. Removing the spool is the claim: a line is never written twice, never cut by
  the framework, and a restart claims again only what no claim took. `read/2` folds the whole
  lines of each log from its saved offset (`CodingAgentFramework.Stream.Fold`).

  Nothing here kills a process: an end is the `end_session` line, and a claim still waiting past
  its deadline is `Shell`'s to end, by its pid.
  """

  use GenServer

  alias CodingAgentFramework.{Holder, Programs, Reader, Shell}
  alias CodingAgentFramework.Stream.{Fold, Line, Table}

  @timeout 5_000
  # The process's own FIFO ($4), and a last line a death cut ended with a newline, so the next
  # process's first event is a line of its own. `$(…)` drops a trailing newline, so it is empty
  # when the log already ends with one.
  @follow ~S"""
  "$2" -p "$1/out" && { [ -p "$1/$4" ] || "$3" "$1/$4"; } || exit
  log="$1/events.jsonl"
  [ -s "$log" ] || exit 0
  [ -z "$("$5" -c 1 "$log")" ] || printf '\n' >> "$log"
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
  host), `db:`, and optionally `notify:`, `interval:` (ms between reads, as `read/2` reads;
  without it, reads happen only on `read/2`) and `timeout:` (ms per shell run, default 5 s).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The topics of the cues it writes, each as its whole shape, `*` for a word it fills in
  (`CodingAgentFramework.Cues`): `stream:<host>`.
  """
  @spec writes() :: [String.t()]
  def writes, do: ~w(stream:*)

  @doc ~S"""
  A delegate's directory under `home`.

      iex> CodingAgentFramework.Stream.dir("/h", "s1")
      "/h/streams/s1"
  """
  @spec dir(String.t(), String.t()) :: String.t()
  def dir(home, session), do: Path.join([home, "streams", session])

  @doc """
  Makes `session`'s directory and its next process's FIFO and starts following it: its dtach
  socket is `socket` in the holder, and `transcript` is its transcript's path, read only to
  settle a message at its exit. Answers `{:ok, %{dir: dir, fifo: fifo}}`; the process reads
  `fifo` (`ClaudeCLI.wrapper/4`), and every claim from now on names it.

  Following a session again, for a resume, keeps its row and offset, so the resumed process's
  events are read from where the last one's ended. An exit not yet seen is seen first, so its
  messages settle; a last line the exit cut is ended with a newline; the row's turn is ended
  and it waits for the new process: `held/3`, or its socket seen live, then its own
  `system`/`init`. The new FIFO is `in.<n>`, `n` the resumes so far, so a line left waiting
  for an earlier process never reaches this one. A session whose socket still lives is refused
  as `{:live, socket}`.

      Stream.follow(stream, "6f1c…", "reviewer", "/…/6f1c….jsonl")
      #=> {:ok, %{dir: "/srv/caf/home/streams/6f1c…", fifo: "/srv/caf/home/streams/6f1c…/in.0"}}
  """
  def follow(stream, session, socket, transcript, opts \\ []),
    do: call(stream, {:follow, session, socket, transcript}, opts)

  @doc """
  Tells `Stream` that `Sessions` held `session`'s process: its exit is seen from now on, even if
  no read finds its socket live first. Answers `{:ok, :seen}`, or `{:refused, :gone}` when its
  exit was already seen, or `{:refused, :not_followed}`.
  """
  def held(stream, session, opts \\ []), do: call(stream, {:held, session}, opts)

  @doc """
  Writes one line: `{:message, text}` (or `{:message, uuid, text}` to keep a uuid on a resend),
  `{:answer, request_id, :allow | {:deny, message}}`, `:interrupt` or `:end_session`. Option
  `:timeout` is the write's deadline (default 5 s).

  Answers `{:ok, %{uuid: uuid}}` once the line is in the pipe; `{:refused, reason}` when nothing
  was marked or written (`:not_live`, `:turn_running`, `:message_waiting`,
  `{:undelivered, uuid}`, `:ending`, `:no_request`, `:gone`, …, as `Fold.check/2` says);
  `{:unknown, reason}` when the row is marked and the line may or may not go in: the replay, a
  later claim or the exit settles it. A message found undelivered at an exit goes again, first,
  as `{:message, uuid, text}` with its own uuid.
  """
  def write(stream, session, line, opts \\ []) do
    deadline = Keyword.get(opts, :timeout, @timeout)
    call(stream, {:write, session, line, deadline}, timeout: 3 * deadline)
  end

  @doc "Interrupts the delegate's turn: `write(stream, session, :interrupt, opts)`."
  def interrupt(stream, session, opts \\ []), do: write(stream, session, :interrupt, opts)

  @doc """
  Answers held request `request_id` by the label an agent's `answer` names: `"allow"`, or
  `"deny"` with a message that says its parent denied it. Any other label is refused as
  `{:bad, :label}` before anything is marked; otherwise it answers as `write/4`.

      Stream.answer(stream, "6f1c…", "req-1", "allow")
      #=> {:ok, %{uuid: "req-1"}}
  """
  def answer(stream, session, request_id, label, opts \\ [])

  def answer(stream, session, id, "allow", opts),
    do: write(stream, session, {:answer, id, :allow}, opts)

  def answer(stream, session, id, "deny", opts),
    do: write(stream, session, {:answer, id, {:deny, "Your parent denied this."}}, opts)

  def answer(_stream, _session, _id, _label, _opts), do: {:refused, {:bad, :label}}

  @doc """
  Ends the session. It cuts a running turn and drops what has not gone in, so it goes in only
  after the turn ended with no message under way or found undelivered; once it is marked, a
  message is refused as `:ending`. The caller (`Sessions`) checks first that the report is
  delivered.
  """
  def end_session(stream, session, opts \\ []), do: write(stream, session, :end_session, opts)

  @doc """
  Reads each followed delegate's log, claims again what a restart left unclaimed, and sees its
  exit. Answers `{:ok, %{ids: ids, failed: [{session, reason}]}}`; a failed read changes nothing.
  """
  def read(stream, opts \\ []), do: call(stream, :read, opts)

  @doc "The rows, as `Table.rows/2` gives them."
  def rows(stream, opts \\ []), do: call(stream, :rows, opts)

  @doc """
  `session`'s event log from byte `from`, as it is now: `{:ok, %{bytes: bytes, from: from}}`.
  With `{:last, n}` in place of `from`, from `n` bytes before the offset read so far. It changes
  no row; `{:refused, :not_followed}` for a session it does not follow.

      Stream.log(stream, "6f1c…", {:last, 4096})
      #=> {:ok, %{bytes: "…}\\n{\\"type\\":\\"result\\",…}\\n", from: 9001}}
  """
  def log(stream, session, from, opts \\ []), do: call(stream, {:log, session, from}, opts)

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
         timeout: Keyword.get(opts, :timeout, @timeout),
         delegates: Table.delegates(db, host.name)
       }
       |> Map.merge(Reader.loop(opts))}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:follow, session, socket, transcript}, _from, s) do
    d = dir(s.home, session)

    # The old process is gone before the log's last line is ended: no one else writes it.
    with {:ok, delegate} <- again(s, session, s.delegates[session]),
         fifo = Fold.fifo(delegate.fold),
         args = [d, s.p.mkdir, s.p.mkfifo, fifo, s.p.tail],
         {:ok, %{status: 0}} <- sh(s, @follow, args, s.timeout) do
      {:reply, {:ok, %{dir: d, fifo: Path.join(d, fifo)}},
       save(s, session, Map.merge(delegate, %{socket: socket, transcript: transcript}))}
    else
      other -> {:reply, failed(other), s}
    end
  end

  def handle_call({:held, session}, _from, s) do
    case fetch(s, session) do
      {:ok, d} -> {:reply, {:ok, :seen}, save(s, session, %{d | fold: Fold.held(d.fold)})}
      refused -> {:reply, refused, s}
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
    {reply, s} = read_now(s)
    {:reply, reply, s}
  end

  def handle_call(:rows, _from, s), do: {:reply, Table.rows(s.db, s.host.name), s}

  def handle_call({:log, session, from}, _from, s) do
    with %{fold: fold} <- s.delegates[session] || {:refused, :not_followed},
         at = with({:last, n} <- from, do: max(fold.offset - n, 0)),
         {:ok, bytes} <- tail(s, Path.join(dir(s.home, session), "events.jsonl"), at) do
      {:reply, {:ok, %{bytes: bytes, from: at}}, s}
    else
      other -> {:reply, other, s}
    end
  end

  @impl true
  def handle_info(:tick, s), do: {:noreply, Reader.tick(s, &read_now/1)}

  defp read_now(s) do
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
    {{:ok, %{ids: written, failed: Enum.reverse(failed)}}, s}
  end

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

  defp again(_s, _session, nil), do: {:ok, %{fold: Fold.new()}}

  # A row not yet seen gone is read first, whether or not it was seen live: a live socket is
  # refused, and an exit already seen as such settles its messages.
  defp again(s, session, d) do
    seen = if d.fold.gone, do: {:ok, d}, else: read_one(s, session, d)

    case seen do
      {:ok, %{fold: %{live_seen: true, gone: false}}} -> {:refused, {:live, d.socket}}
      {:ok, d} -> {:ok, %{d | fold: Fold.again(d.fold)}}
      other -> other
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

  # The claim names the FIFO of the process this write found live; lines are dropped at its
  # exit, so a line never outlives the process it was marked for.
  defp run_claim(s, session, id, out, ends) do
    fifo = Path.join(dir(s.home, session), Fold.fifo(s.delegates[session].fold))

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

  @doc "A random (version 4) uuid, as a line's or a session's id."
  @spec uuid() :: String.t()
  def uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u::128>> = <<a::48, 4::4, b::12, 2::2, c::62>>
    hex = u |> Integer.to_string(16) |> String.pad_leading(32, "0") |> String.downcase()

    Enum.map_join([0..7, 8..11, 12..15, 16..19, 20..31], "-", &String.slice(hex, &1))
  end
end
