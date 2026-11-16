defmodule CodingAgentFramework.Jobs do
  @moduledoc """
  One-off commands on a host, in a copy of a worktree: held by dtach, logged, ended by their
  exit or their timeout (see "Hosts" in `docs/design.md` and `model/tla/Copy.tla`). One
  process with no name, started by the embedding app, which owns the `jobs` table
  (`CodingAgentFramework.Jobs.Table`). A run's call works in the caller's process.

  **A run** (`run/6`) takes the copy's turn and syncs it (`CodingAgentFramework.Copies`), then
  holds the job on the host under a wrapper, settles the start and gives the turn back, waits
  for the job's end, and answers:

    * `{:ok, %{exit: code, log: tail, fetch: fetch}}`: the command exited with `code`;
    * `{:unknown, {:timeout, %{fetch: fetch}}}`: the host ended the job at its timeout;
    * `{:unknown, :no_exit}`: the socket is dead and there is no exit file; nothing is fetched;
    * `{:unknown, :dropped}`: the call's deadline (the job's timeout) passed with the host
      unread; its end comes later, as a late end;
    * `{:refused, {:sync, reason}}`: the sync was cut, and nothing ran.

  **The fetch** (`fetch: paths`) begins once the end is read, and brings back only the named
  paths, each only while the worktree's file is still what the sync recorded
  (`CodingAgentFramework.Copies.fetch/5`). `fetch` is `:done`, `:none` (nothing named),
  `{:conflict, paths}` (the worktree's edits kept, the copy's versions left on the host), or
  `{:unknown, reason}` (cut).

  **A late end**: a job whose call answered `{:unknown, :dropped}`, or whose call a restart
  cut (a row `starting` or `running` when `Jobs` starts), is owed its end. `Jobs` settles such
  rows from the host when it starts and at each `cue/2`, and hands each end, once, to the
  embedding app's `:on_late_end` function, in `Jobs`' process:
  `%{job: id, end: {:exit, code} | {:unknown, :timeout} | {:unknown, :no_exit} | {:refused,
  {:start, :not_held} | {:refused, :interrupted}}, fetch: :not_fetched}`. Nothing is fetched for a late end, and a later
  run fetches nothing for it. `Jobs` sends no message itself: the embedding app routes the end
  to the job's caller. The row is marked told only after the function returns, so one that
  raises is handed again at the next start. `{:refused, :interrupted}` is for a row a restart
  left `asked`: nothing reached the host, so it is never run or retried. It and `{:refused,
  {:start, :not_held}}` are not an end: the job never ran.

  At its start, `Jobs` also removes the temporary folder of a fetch a restart cut
  (`CodingAgentFramework.Copies.sweep_fetch/1`), under the worktree of each row whose job had
  ended, and nowhere else.

  **The wrapper** runs on the host as dtach's child, so it leads its own process group, and the
  job runs in that group. At the job's timeout a timer in the group writes `timeout` to the
  exit file and ends the group. When the command exits, the wrapper writes its code and ends
  the group, itself included: the group's id is the wrapper's own pid, alive until then, so the
  kill never reaches a reused id. Whichever comes first wins the exit file, by `mkdir`; the
  other leaves it to the winner. dtach removes the socket once the wrapper is gone, so a job is
  read dead first, then its exit file, and nothing of its group is left by then.

      {:ok, jobs} = Jobs.start_link(dir: dir, copies: copies, on_late_end: &route/1,
        hosts: %{"box" => %{programs: p, dir: "/srv/caf"}})
      Jobs.run(jobs, "j7", %{host: "box", project: "web", name: "fix-login"}, worktree,
        ["/usr/bin/make", "test"], timeout: 600_000, fetch: ["coverage.json"])
      #=> {:ok, %{exit: 0, log: "...", fetch: :done}}
  """

  use GenServer

  alias CodingAgentFramework.{Copies, Programs, Shell}
  alias CodingAgentFramework.Copies.Held
  alias CodingAgentFramework.Jobs.Table

  @call 5_000
  @log_max 16_384
  # How long past the call's deadline a read waits for the host to end the job itself.
  @grace 5_000
  # $1..$7: the copy, the log, the exit file, the timeout in seconds, kill, sleep, mkdir; then
  # the job's argv. `mkdir` of `<exit>.won` picks the one writer of the exit file.
  @wrapper ~S"""
  c=$1 l=$2 e=$3 t=$4 k=$5 s=$6 m=$7; shift 7
  ( "$s" "$t"; "$m" "$e.won" 2>/dev/null || exit 0; echo timeout > "$e"; "$k" -KILL -- "-$$" ) \
    </dev/null >/dev/null 2>&1 &
  ( cd "$c" && exec "$@" ) </dev/null >>"$l" 2>&1
  x=$?
  "$m" "$e.won" 2>/dev/null || { wait; exit 0; }
  echo "$x" > "$e"
  "$k" -KILL -- "-$$"
  exit "$x"
  """
  # How long a read made in `Jobs`' own process (its start, a cue) waits on the host.
  @settle_read 2_000
  @ended ~w(exited timedout lost refused interrupted)
  # $0 dtach; $1 the socket, $2 the exit file, $3 sleep, $4 "wait" to wait while it lives.
  # The socket is read dead first, then the exit file, in one process.
  @read ~S"""
  while [ -e "$1" ]; do
    if out=$("$0" -p "$1" </dev/null 2>&1); then
      [ "$4" = wait ] || { echo live; exit 0; }
      "$3" 0.2; continue
    fi
    case $out in *"Connection refused"*) break ;; *) echo "unknown $out"; exit 0 ;; esac
  done
  if [ -e "$2" ]; then printf 'end '; cat "$2"; else echo 'end none'; fi
  """

  @type where :: %{host: String.t(), project: String.t(), name: String.t()}

  @doc """
  Starts the part. Options: `:dir`, a directory of this machine of its own (the table);
  `:copies`, the `Copies` server; `:hosts`, each host's name to `%{programs: programs, dir:
  dir}`, its `Programs` (with `dtach`, `sh`, `env`, `rm`, `kill`, `sleep`, `mkdir`, `tail`,
  and for the copy `flock` and `rsync`) and its framework directory; `:on_late_end`, a function
  of one argument that is handed each late end.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Runs `argv` as job `id` (a socket name: letters, digits, `-`, `_`) in the copy `where` names
  of `worktree`. Options: `:timeout` (ms), the job's, kept on the host and the call's deadline;
  `:sync_timeout` and `:lock_wait` (ms) for the sync; `:start_timeout` (ms) for dtach's reply;
  `:env`, the job's whole environment as `{name, value}` pairs; `:reaper`; `:interval` (ms)
  between reads that failed; `:log_bytes`, the tail's size; `:fetch`, the paths to bring back,
  relative to the worktree. The fetch's rsync has the sync's timeout and lock wait.
  """
  @spec run(GenServer.server(), String.t(), where, String.t(), [String.t()], keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def run(jobs, id, where, worktree, argv, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    start = Keyword.get(opts, :start_timeout, 5_000)
    paths = Keyword.get(opts, :fetch, [])

    with :ok <- named(paths),
         {:ok, ctx} <- context(jobs, id, where, start),
         :ok <- call(jobs, {:ask, row(id, where, worktree)}),
         refused = fn _ -> put(jobs, id, %{state: "refused"}) end,
         {:ok, %{record: record}} <- Held.ready(ctx, worktree, opts, refused) do
      now = now()
      deadline = now + start + timeout
      put(jobs, id, %{state: "starting", start_until: now + start, deadline: deadline})
      secs = :erlang.float_to_binary(timeout / 1000, decimals: 3)
      %{kill: k, sleep: s, mkdir: m} = ctx.programs.paths
      args = ["caf-job", ctx.path, ctx.log, ctx.exit, secs, k, s, m]
      held = Held.hold(ctx, @wrapper, args, argv, Keyword.get(opts, :env, []))
      put = &put(jobs, id, &1)
      interval = Keyword.get(opts, :interval, 200)

      # dtach's held reply: the job is live. Its reply cut: the host is read until the deadline.
      read = fn
        :reply -> {:ok, :live}
        :cut -> retry(deadline, interval, fn -> read(ctx, :once, @call) end)
      end

      with {:ok, :running} <- Held.settle(ctx, held, now + start, read, &started(put, &1)),
           {:ok, value} <- wait_end(ctx, deadline, Keyword.get(opts, :interval, 200)),
           :ok <- put.(ended(value)) do
        fetch = fn -> fetch(ctx, worktree, record, opts) end
        answer(ctx, ended(value), fetch, Keyword.get(opts, :log_bytes, 16_384))
      end
      |> owe(jobs, id)
    end
  end

  @doc """
  Settles job `id`'s row from the host once, as after a restart or a call that answered
  unknown: a start whose reply was cut, once its deadline passed, is read as running or
  refused, and its copy's turn is given back; a running job read dead gets its end. Answers
  the row.
  """
  @spec settle(GenServer.server(), String.t()) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def settle(jobs, id) do
    with {:ok, row} <- row_of(jobs, id),
         {:ok, ctx} <- context(jobs, id, row, @call) do
      case settle_row(ctx, row, @call, &put(jobs, id, &1)) do
        :ok -> row_of(jobs, id)
        {:ok, :running} -> row_of(jobs, id)
        {:refused, {:start, :not_held}} -> row_of(jobs, id)
        other -> other
      end
    end
  end

  @doc """
  Hands `Jobs` a host reader's cue: every row owed a late end is settled from the host again.
  Answers `:ok` at once.
  """
  @spec cue(GenServer.server(), map) :: :ok
  def cue(jobs, %{topic: _}), do: GenServer.cast(jobs, :cue)

  @doc """
  The job's log from byte `offset`: `{:ok, %{text: text, next: offset}}`, where `next` is the
  offset to read from next. The host's `tail | head` takes at most `:max` bytes (default 16 KiB),
  so a long log does not move through `Shell` whole. Options: `:timeout` (ms), `:max` (bytes).
  """
  @spec log(GenServer.server(), String.t(), non_neg_integer, keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def log(jobs, id, offset, opts \\ []) do
    max = Keyword.get(opts, :max, @log_max)

    with {:ok, row} <- row_of(jobs, id),
         {:ok, ctx} <- context(jobs, id, row, @call),
         {:ok, text} <- bounded(ctx, offset, max, Keyword.get(opts, :timeout, @call)),
         do: {:ok, %{text: text, next: offset + byte_size(text)}}
  end

  @doc "Every job's row, for a view or a test."
  @spec rows(GenServer.server()) :: [map] | {:unknown, term}
  def rows(jobs), do: call(jobs, :rows)

  defp context(jobs, id, where, start) do
    with {:ok, config} <- call(jobs, :config), do: context_of(config, id, where, start)
  end

  defp context_of(config, id, where, start) do
    where = %{host: where.host, project: where.project, copy: where.name}

    with {:ok, %{base: b} = ctx} <-
           Held.context(config, Map.merge(where, %{kind: "jobs", name: id, run: id}), start),
         do: {:ok, Map.merge(ctx, %{socket: b <> ".sock", log: b <> ".log", exit: b <> ".exit"})}
  end

  # Each named path is relative and stays inside the worktree.
  defp named(paths) do
    case Enum.reject(paths, &inside?/1) do
      [] -> :ok
      bad -> {:refused, {:fetch_paths, bad}}
    end
  end

  defp inside?(p) when is_binary(p) and p != "" do
    Path.type(p) == :relative and Enum.all?(Path.split(p), &(&1 not in [".", ".."]))
  end

  defp inside?(_), do: false

  defp fetch(_ctx, _worktree, record, _opts) when map_size(record) == 0, do: :none

  defp fetch(ctx, worktree, record, opts),
    do: Copies.fetch(ctx.copies, ctx.copy, worktree, record, Held.copy_opts(opts))

  # A call that gave up owes its caller the job's end, once the host is read.
  defp owe({:unknown, :dropped} = dropped, jobs, id) do
    call(jobs, {:owe, id})
    dropped
  end

  defp owe(answer, _jobs, _id), do: answer

  # One read of the row's job on the host, as after a restart; `put` writes the row.
  defp settle_row(ctx, row, timeout, put) do
    case row.state do
      "starting" ->
        read = fn :cut -> read(ctx, :once, timeout) end
        Held.settle_cut(ctx, row.start_until, read, &started(put, &1))

      "running" ->
        case read(ctx, :once, timeout) do
          {:ok, {:end, value}} -> put.(ended(value))
          {:ok, :live} -> :ok
          other -> other
        end

      _ ->
        :ok
    end
  end

  # The row a settled start makes: live, or ended with an exit file, the job ran; dtach's
  # refusal, or a dead socket with no exit file, nothing ran.
  defp started(put, {:refused, _} = refused) do
    put.(%{state: "refused"})
    refused
  end

  defp started(put, {:ok, {:end, "none"}}) do
    put.(%{state: "refused"})
    {:refused, {:start, :not_held}}
  end

  defp started(put, {:ok, _live_or_ended}) do
    put.(%{state: "running"})
    {:ok, :running}
  end

  # One read waits on the host while the job lives, until the call's deadline and a grace for
  # the host's own end of it. A read that fails is tried again until the deadline.
  defp wait_end(ctx, deadline, interval) do
    retry(deadline, interval, fn -> read(ctx, :wait, max(deadline - now(), 0) + @grace) end)
    |> case do
      {:ok, {:end, value}} -> {:ok, value}
      {:ok, :live} -> {:unknown, :dropped}
      other -> other
    end
  end

  defp retry(deadline, interval, read) do
    case read.() do
      {:ok, _} = ok ->
        ok

      _ ->
        if now() >= deadline do
          {:unknown, :dropped}
        else
          pause(min(interval, deadline - now()))
          retry(deadline, interval, read)
        end
    end
  end

  defp read(ctx, mode, timeout) do
    %{dtach: dtach, sh: sh, sleep: sleep} = ctx.programs.paths
    args = ["-c", @read, dtach, ctx.socket, ctx.exit, sleep, Atom.to_string(mode)]

    case Shell.run(ctx.programs.host, sh, args, timeout: timeout) do
      {:ok, %{status: 0, output: "live\n"}} -> {:ok, :live}
      {:ok, %{status: 0, output: "end " <> value}} -> {:ok, {:end, String.trim(value)}}
      other -> {:unknown, {:read, other}}
    end
  end

  defp ended("timeout"), do: %{state: "timedout"}
  defp ended("none"), do: %{state: "lost"}
  defp ended(code), do: %{state: "exited", code: String.to_integer(code)}

  defp answer(_ctx, %{state: "timedout"}, fetch, _),
    do: {:unknown, {:timeout, %{fetch: fetch.()}}}

  defp answer(_ctx, %{state: "lost"}, _fetch, _), do: {:unknown, :no_exit}

  defp answer(ctx, %{state: "exited", code: code}, fetch, bytes) do
    fetch = fetch.()

    log =
      case tail(ctx, "#{bytes}", @call) do
        {:ok, text} -> text
        other -> other
      end

    {:ok, %{exit: code, log: log, fetch: fetch}}
  end

  # A pipe hides the tail's own status, so a log that cannot be read is refused before it; the
  # tail's broken-pipe complaint, once head has its bytes, goes to /dev/null, not into the text.
  @bounded ~S"""
  [ -r "$1" ] || exit 1
  "$2" -c "+$3" "$1" 2>/dev/null | "$4" -c "$5"
  """

  defp bounded(ctx, offset, max, timeout) do
    with {:ok, p} <- Programs.take(ctx.programs, [:sh, :tail, :head]) do
      args = ["-c", @bounded, "sh", ctx.log, p.tail, "#{offset + 1}", p.head, "#{max}"]

      case Shell.run(ctx.programs.host, p.sh, args, timeout: timeout) do
        {:ok, %{status: 0, output: text}} -> {:ok, text}
        other -> {:unknown, {:log, other}}
      end
    end
  end

  # The last `bytes` of the log (`tail -c N`): already bounded.
  defp tail(ctx, from, timeout) do
    args = ["-c", from, ctx.log]

    case Shell.run(ctx.programs.host, ctx.programs.paths.tail, args, timeout: timeout) do
      {:ok, %{status: 0, output: text}} -> {:ok, text}
      other -> {:unknown, {:log, other}}
    end
  end

  defp pause(ms) when ms > 0 do
    receive do
    after
      ms -> :ok
    end
  end

  defp pause(_), do: :ok

  defp now, do: System.os_time(:millisecond)

  defp row(id, where, worktree) do
    %{
      id: id,
      host: where.host,
      project: where.project,
      name: where.name,
      state: "asked",
      worktree: worktree
    }
  end

  defp row_of(jobs, id) do
    case call(jobs, {:get, id}) do
      nil -> {:refused, {:no_job, id}}
      %{} = row -> {:ok, row}
      other -> other
    end
  end

  defp put(jobs, id, fields), do: call(jobs, {:put, id, fields})

  defp call(jobs, request) do
    GenServer.call(jobs, request, @call)
  catch
    :exit, reason -> {:unknown, {:jobs, reason}}
  end

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)

    with :ok <- File.mkdir_p(dir),
         {:ok, db} <- Table.open(Path.join(dir, "jobs.db")) do
      config = %{hosts: Keyword.fetch!(opts, :hosts), copies: Keyword.fetch!(opts, :copies)}
      # A row whose start or run was under way lost its call with the restart: it is owed.
      rows = Table.all(db)

      for %{state: state, late: nil} = row <- rows,
          state in ~w(starting running),
          do: Table.put(db, %{row | late: "owed"})

      # Nothing of an `asked` row reached the host: it is interrupted, handed on once, never run.
      for %{state: "asked", late: nil} = row <- rows,
          do: Table.put(db, %{row | state: "interrupted", late: "owed"})

      # A fetch starts once a job's end is written, so only such a row's worktree can hold the
      # temporary folder of a fetch the restart cut.
      for %{state: state, worktree: wt} <- rows,
          state in ~w(exited timedout) and is_binary(wt),
          do: Copies.sweep_fetch(wt)

      s = %{db: db, config: config, on_late_end: Keyword.fetch!(opts, :on_late_end)}
      {:ok, s, {:continue, :settle}}
    else
      {:error, reason} -> {:stop, {:dir, reason}}
      refused -> {:stop, refused}
    end
  end

  @impl true
  def handle_continue(:settle, s), do: {:noreply, settle_owed(s)}

  @impl true
  def handle_cast(:cue, s), do: {:noreply, settle_owed(s)}

  @impl true
  def handle_call(:config, _from, s), do: {:reply, {:ok, s.config}, s}
  def handle_call(:rows, _from, s), do: {:reply, Table.all(s.db), s}
  def handle_call({:get, id}, _from, s), do: {:reply, Table.get(s.db, id), s}

  def handle_call({:ask, %{id: id} = row}, _from, s) do
    if Table.get(s.db, id),
      do: {:reply, {:refused, {:job_exists, id}}, s},
      else: {:reply, Table.put(s.db, row), s}
  end

  def handle_call({:put, id, fields}, _from, s) do
    case Table.get(s.db, id) do
      nil -> {:reply, {:refused, {:no_job, id}}, s}
      row -> {:reply, write(s, Map.merge(row, fields)), s}
    end
  end

  def handle_call({:owe, id}, _from, s) do
    case Table.get(s.db, id) do
      nil -> {:reply, {:refused, {:no_job, id}}, s}
      row -> {:reply, write(s, %{row | late: "owed"}), s}
    end
  end

  # Reads each owed row's job on the host once, in this process, so its end is written by the
  # one writer that hands it on. A row still live, or unread, waits for the next cue.
  defp settle_owed(s) do
    for %{late: "owed"} = row <- Table.all(s.db) do
      put = fn fields -> write(s, Map.merge(Table.get(s.db, row.id), fields)) end

      with {:ok, ctx} <- context_of(s.config, row.id, row, @settle_read),
           do: settle_row(ctx, row, @settle_read, put)

      # An end already written, whose hand-on a crash cut.
      with %{late: "owed"} = now <- Table.get(s.db, row.id), do: write(s, now)
    end

    s
  end

  # Every write of a row goes here: an owed row that has ended is handed on, then marked told.
  defp write(s, %{late: "owed", state: state} = row) when state in @ended do
    s.on_late_end.(%{job: row.id, end: late_end(row), fetch: :not_fetched})
    Table.put(s.db, %{row | late: "told"})
  end

  defp write(s, row), do: Table.put(s.db, row)

  defp late_end(%{state: "exited", code: code}), do: {:exit, code}
  defp late_end(%{state: "timedout"}), do: {:unknown, :timeout}
  defp late_end(%{state: "lost"}), do: {:unknown, :no_exit}
  defp late_end(%{state: "refused"}), do: {:refused, {:start, :not_held}}
  defp late_end(%{state: "interrupted"}), do: {:refused, :interrupted}
end
