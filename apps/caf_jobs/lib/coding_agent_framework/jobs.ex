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
    * `{:refused, {:sync, reason}}`: the sync was cut, and nothing ran;
    * `{:refused, {:lease, why}}`: the lease was refused, and nothing ran (below).

  **The lease** (`docs/design.md`, "A lease"; `model/tla/Schedule.tla`). With a `scheduler:`,
  a run asks it for a lease before the copy's turn, in the class its caller names (`lease:`,
  `%{class: :heavy | :builder | :landing, module: m, units: units}`): one request for every
  unit the job needs, so a landing's slot and lock come in one gang lease or not at all. It
  names the job's host (`where: %{host: host}`), so a slot is that host's (F-292). The
  holder is the job's row, written `asked` first; `Jobs.Work` answers for it, and the lease
  lasts until the row holds the job's end. Queued, the run waits in the caller's process for
  the one more answer, at most `:lease_wait` ms, which the request carries, so no lease is
  granted after it (F-276). A refusal, by the `Scheduler` or the
  framework (`scheduler_ended`, `unanswered`, `unknown`), is a row `refused` with its
  `reason` and `retry_at`, never a failed run: `{:refused, {:lease, {reason, retry_at}}}`.

  **The fence.** Under a lease, `Jobs` writes the lease id beside the job on its host
  (`<job>.exit.lease`) before it sends the start, and the wrapper hands it the same id. The
  wrapper takes the fence (`mkdir <job>.exit.fence`) before it runs anything, and runs only
  when it took it and the id is its own. A start whose reply was cut is settled as never run
  only once `Jobs` took the fence itself; when the wrapper has it, the job ran. So a start
  that lands late, after its lease was released, runs nothing (`Schedule.tla`'s
  `NoRunUnleased`).

  **The fetch** (`fetch: paths`) begins once the end is read, and brings back only the named
  paths, each only while the worktree's file is still what the sync recorded
  (`CodingAgentFramework.Copies.fetch/5`). `fetch` is `:done`, `:none` (nothing named),
  `{:conflict, paths}` (the worktree's edits kept, the copy's versions left on the host), or
  `{:unknown, reason}` (cut).

  **A late end**: a job whose call answered `{:unknown, :dropped}`, or whose call a restart
  cut (a row `starting` or `running` when `Jobs` starts), is owed its end. `Jobs` settles such
  rows from the host when it starts, on its `interval:` and at `cue/2`, and hands each end, once, to the
  embedding app's `:on_late_end` function, in `Jobs`' process:
  `%{job: id, end: {:exit, code} | {:unknown, :timeout} | {:unknown, :no_exit} | {:refused,
  {:start, :not_held} | {:refused, :interrupted}}, fetch: :not_fetched}`. Nothing is fetched for a late end, and a later
  run fetches nothing for it. `Jobs` sends no message itself: the embedding app routes the end
  to the job's caller. The function answers `:ok` once the end is stored, and the row
  is then marked told; it answers `{:unknown, reason}` when it could not store it, and the row
  stays owed and is handed again at the next cue. One that raises is handed again at the next
  start. `{:refused, :interrupted}` is for a row a restart, or the end of its caller's process,
  left `asked`: nothing reached the host, so it is never run or retried. A caller's process
  that ends during its start or run leaves the row owed, as a restart does. It and `{:refused,
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
  read dead first, then its exit file, and nothing of its group is left by then. "Dead" is
  `Holder.Process`'s: the wrapper's pid, recorded with its start time as it was held, gone, and
  the socket absent or stale. A run's wait for the end runs on the host
  (`Holder.Process.await_dead/3`), one shell for the whole wait.

      {:ok, jobs} = Jobs.start_link(dir: dir, copies: copies, on_late_end: &route/1,
        hosts: %{"box" => %{programs: p, dir: "/srv/caf"}})
      Jobs.run(jobs, "j7", %{host: "box", project: "web", name: "fix-login"}, worktree,
        ["/usr/bin/make", "test"], timeout: 600_000, fetch: ["coverage.json"])
      #=> {:ok, %{exit: 0, log: "...", fetch: :done}}
  """

  use GenServer

  alias CodingAgentFramework.{Copies, Holder, Programs, Reader, Scheduler, Shell, Store}
  alias CodingAgentFramework.Copies.Held
  alias CodingAgentFramework.Jobs.Table

  @call 5_000
  @log_max 16_384
  # How long past the call's deadline a read waits for the host to end the job itself.
  @grace 5_000
  # $1..$8: the copy, the log, the exit file, the timeout in seconds, kill, sleep, mkdir, the
  # lease id (empty with no lease); then the job's argv. Under a lease, `mkdir` of
  # `<exit>.fence` picks who decides the start: this wrapper, which then runs only with its own
  # id, or `Jobs`, which settles it never run. `mkdir` of `<exit>.won` picks the one writer of
  # the exit file.
  @wrapper ~S"""
  c=$1 l=$2 e=$3 t=$4 k=$5 s=$6 m=$7 f=$8; shift 8
  if [ -n "$f" ]; then
    "$m" "$e.fence" 2>/dev/null || exit 0
    read -r x < "$e.lease" && [ "$x" = "$f" ] || exit 0
  fi
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
  # $1 the exit file, read once the job is dead (`Holder.Process`): its process gone and its
  # socket dead, so nothing of the job writes it after.
  @exit ~S"""
  if [ -e "$1" ]; then read -r x < "$1"; echo "end $x"; else echo 'end none'; fi
  """
  # $1 the lease file, $2 the lease id: written whole before the start is sent, in the
  # directory the copy's start made, so the wrapper reads it whole.
  @fence ~S"""
  echo "$2" > "$1"
  """
  # $1 mkdir, $2 the fence: `Jobs` takes it, or finds the wrapper took it first.
  @revoke ~S"""
  if "$1" "$2" 2>/dev/null; then echo revoked; elif [ -d "$2" ]; then echo taken; fi
  """
  @lease_wait 300_000

  @type where :: %{host: String.t(), project: String.t(), name: String.t()}

  @doc """
  Starts the part. Options: `:dir`, a directory of this machine of its own (the table);
  `:copies`, the `Copies` server; `:hosts`, each host's name to `%{programs: programs, dir:
  dir}`, its `Programs` (with `dtach`, `sh`, `env`, `rm`, `kill`, `sleep`, `mkdir`, `tail`, `ps`,
  and for the copy `flock` and `rsync`) and its framework directory; `:on_late_end`, a function
  of one argument that is handed each late end and answers `:ok` or `{:unknown, reason}`; and
  optionally `:interval` (ms between settles of the owed rows; without it, they settle only at
  its start and at `cue/2`), `:notify`, a function of one cue: after each write of a row it
  gets `%{topic: "jobs", ids: [id]}`, and `:scheduler`, the instance's `Scheduler`, which every
  run then asks for a lease first.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The topics of the cues it writes, each as its whole shape, `*` for a word it fills in
  (`CodingAgentFramework.Cues`): `jobs`.
  """
  @spec writes() :: [String.t()]
  def writes, do: ~w(jobs)

  @doc """
  Runs `argv` as job `id` (a socket name: letters, digits, `-`, `_`) in the copy `where` names
  of `worktree`. Options: `:timeout` (ms), the job's, kept on the host and the call's deadline;
  `:sync_timeout` and `:lock_wait` (ms) for the sync; `:start_timeout` (ms) for dtach's reply;
  `:env`, the job's whole environment as `{name, value}` pairs; `:reaper`; `:interval` (ms)
  between reads that failed; `:log_bytes`, the tail's size; `:fetch`, the paths to bring back,
  relative to the worktree. The fetch's rsync has the sync's timeout and lock wait. With a
  `scheduler:`, `:lease` (`%{class: class, module: module, units: units}`, the class one of
  `:landing`, `:builder`, `:heavy`) and `:lease_wait` (ms a queued lease is waited for, 300 000
  by default); without `:lease` the run is refused `{:bad, :lease}` before any row is written.
  """
  @spec run(GenServer.server(), String.t(), where, String.t(), [String.t()], keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def run(jobs, id, where, worktree, argv, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    start = Keyword.get(opts, :start_timeout, 5_000)
    paths = Keyword.get(opts, :fetch, [])

    with :ok <- named(paths),
         {:ok, config} <- call(jobs, :config),
         {:ok, ask} <- lease_request(config, id, where, opts),
         {:ok, ctx} <- context_of(config, id, where, start, :place),
         :ok <- call(jobs, {:ask, row(id, where, worktree, argv), self()}),
         {:ok, lease} <- lease(jobs, id, config.scheduler, ask, opts),
         refused = fn _ -> put(jobs, id, %{state: "refused"}) end,
         {:ok, %{record: record}} <- Held.ready(ctx, worktree, opts, refused),
         :ok <- fence(jobs, ctx, id, lease) do
      now = now()
      deadline = now + start + timeout
      # The call's own reads wait on the monotonic clock; the row keeps `deadline` on OS time,
      # which outlives a restart (F-218).
      bound = mono() + start + timeout
      secs = :erlang.float_to_binary(timeout / 1000, decimals: 3)
      %{kill: k, sleep: s, mkdir: m} = ctx.programs.paths
      args = ["caf-job", ctx.path, ctx.log, ctx.exit, secs, k, s, m, lease_id(lease)]
      put = &put(jobs, id, &1)
      interval = Keyword.get(opts, :interval, 200)

      # dtach's held reply: the job is live. Its reply cut: the host is read until the deadline.
      read = fn
        :reply -> {:ok, :live}
        :cut -> retry(bound, interval, fn -> cut_read(ctx, lease, @call) end)
      end

      # The row leaves `asked` only while it is still `asked`: a restart, or the end of this
      # process, that made it `interrupted` ended its lease, so nothing is sent.
      starting = %{state: "starting", start_until: now + start, deadline: deadline}

      with :ok <- advance(jobs, ctx, id, starting),
           held = Held.hold(ctx, @wrapper, args, argv, Keyword.get(opts, :env, [])),
           {:ok, :running} <- Held.settle(ctx, held, now + start, read, &started(put, &1)),
           {:ok, value} <- wait_end(ctx, bound, Keyword.get(opts, :interval, 200)),
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
  Settles every row owed a late end from the host now, as each tick of its interval does. No
  other part's cue says that a host changed, so `Jobs` reads no topic. Answers `:ok` at once.
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

  @doc """
  Job `id`'s row: `{:ok, row}`, `{:refused, {:no_job, id}}`, or `{:unknown, reason}` when `Jobs`
  does not answer. A caller that streams a job's log reads its `state` to know it started.
  """
  @spec row(GenServer.server(), String.t()) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def row(jobs, id), do: row_of(jobs, id)

  defp context(jobs, id, where, start) do
    with {:ok, config} <- call(jobs, :config), do: context_of(config, id, where, start, :reach)
  end

  # A run places new work on the host (`:place`); every later read reaches the work placed.
  defp context_of(config, id, where, start, mode) do
    where = %{host: where.host, project: where.project, copy: where.name}

    with {:ok, %{base: b} = ctx} <-
           Held.context(config, Map.merge(where, %{kind: "jobs", name: id, run: id}), start, mode),
         do: {:ok, Map.merge(ctx, %{socket: b <> ".sock", log: b <> ".log", exit: b <> ".exit"})}
  end

  # The lease a run asks for, when `Jobs` has a `Scheduler`: the caller names its class.
  defp lease_request(%{scheduler: nil}, _id, _where, _opts), do: {:ok, nil}

  defp lease_request(_config, id, where, opts) do
    case Keyword.get(opts, :lease) do
      %{class: class, module: module, units: units} when class in [:landing, :builder, :heavy] ->
        {:ok,
         %{
           id: "job:" <> id,
           class: class,
           module: module,
           account: nil,
           units: units,
           holder: {"job", id},
           # Its slot is its own host's (HostSlots.tla, F-292).
           where: %{host: where.host},
           # The caller waits this long for a queued lease: none is granted after (F-276).
           wait: Keyword.get(opts, :lease_wait, @lease_wait)
         }}

      _ ->
        {:refused, {:bad, :lease}}
    end
  end

  # Schedule.tla: the row (`asked`) is the lease's holder, written before the lease is asked for.
  # A queued request's one more answer comes to this process, the caller's.
  defp lease(_jobs, _id, nil, nil, _opts), do: {:ok, nil}

  defp lease(jobs, id, scheduler, ask, opts) do
    case Scheduler.request(scheduler, ask) do
      {:queued, %{id: request}} -> await_lease(scheduler, request, opts) |> leased(jobs, id)
      answer -> leased(answer, jobs, id)
    end
  end

  defp await_lease(scheduler, request, opts) do
    ref = Process.monitor(scheduler)

    receive do
      {:lease, ^request, answer} ->
        Process.demonitor(ref, [:flush])
        answer

      {:DOWN, ^ref, :process, _, _} ->
        {:refused, {:scheduler_ended, now()}}
    after
      Keyword.get(opts, :lease_wait, @lease_wait) ->
        Process.demonitor(ref, [:flush])
        {:refused, {:unanswered, now()}}
    end
  end

  defp leased({:ok, lease}, jobs, id) do
    case put(jobs, id, %{lease: lease.id}) do
      :ok -> {:ok, lease}
      other -> other
    end
  end

  # Every other answer is a refusal of the job, never a failed run: its row says why and when
  # to ask again. A lease granted to a request whose answer was unknown is released, since the
  # row now says its work ended.
  defp leased(not_granted, jobs, id) do
    {reason, retry_at} =
      case not_granted do
        {:refused, {reason, retry_at}} when is_integer(retry_at) -> {reason, retry_at}
        {:refused, reason} -> {reason, now()}
        {:unknown, reason} -> {{:unknown, reason}, now()}
      end

    text =
      case reason do
        reason when is_atom(reason) -> Atom.to_string(reason)
        # The level and the reading are the lease row's; the job's row names the gate.
        {:pressure, _level, _reading} -> "pressure"
        reason -> inspect(reason)
      end

    put(jobs, id, %{state: "refused", reason: text, retry_at: retry_at})
    {:refused, {:lease, {reason, retry_at}}}
  end

  defp lease_id(nil), do: ""
  defp lease_id(%{id: id}), do: Integer.to_string(id)

  # The fence, under a lease: the lease id beside the job, written before its start is sent. A
  # fence that cannot be written refuses the job before anything is sent.
  defp fence(_jobs, _ctx, _id, nil), do: :ok

  defp fence(jobs, ctx, id, lease) do
    args = ["-c", @fence, "caf-fence", ctx.exit <> ".lease", lease_id(lease)]

    case Shell.run(ctx.programs.host, ctx.programs.paths.sh, args, timeout: @call) do
      {:ok, %{status: 0}} ->
        :ok

      other ->
        put(jobs, id, %{state: "refused"})
        Copies.give_back(ctx.copies, ctx.copy, ctx.run)
        {:refused, {:fence, other}}
    end
  end

  # A start whose reply was cut, read once its deadline passed. Under a lease it is settled as
  # never run only once `Jobs` took the fence; when the wrapper took it, the job ran, and a
  # dead socket with no exit file is a job lost, not one never held.
  defp cut_read(ctx, nil, timeout), do: read(ctx, :once, timeout)

  defp cut_read(ctx, _lease, timeout) do
    %{sh: sh, mkdir: mkdir} = ctx.programs.paths
    args = ["-c", @revoke, "caf-revoke", mkdir, ctx.exit <> ".fence"]

    case Shell.run(ctx.programs.host, sh, args, timeout: timeout) do
      {:ok, %{status: 0, output: "revoked\n"}} ->
        {:refused, {:start, :not_held}}

      {:ok, %{status: 0, output: "taken\n"}} ->
        case read(ctx, :once, timeout) do
          {:ok, {:end, "none"}} -> {:ok, :live}
          other -> other
        end

      other ->
        {:unknown, {:revoke, other}}
    end
  end

  # From `asked` to `starting`, only while the row is still `asked`; else the copy's turn goes
  # back and nothing is sent.
  defp advance(jobs, ctx, id, fields) do
    case call(jobs, {:advance, id, "asked", fields}) do
      :ok ->
        :ok

      other ->
        Copies.give_back(ctx.copies, ctx.copy, ctx.run)
        other
    end
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
        read = fn :cut -> cut_read(ctx, row.lease, timeout) end
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
  # the host's own end of it. A read that fails is tried again until the deadline. The deadline
  # is on the monotonic clock, as it lives in this call only.
  defp wait_end(ctx, deadline, interval) do
    retry(deadline, interval, fn -> read(ctx, :wait, max(deadline - mono(), 0) + @grace) end)
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
        if mono() >= deadline do
          {:unknown, :dropped}
        else
          pause(min(interval, deadline - mono()))
          retry(deadline, interval, read)
        end
    end
  end

  # The job's record and socket, once (`:once`) or waited on the host until it is dead
  # (`:wait`); once dead, its exit file. A part of the reading that failed is no answer.
  defp read(ctx, mode, timeout) do
    name = ctx.name

    reading =
      case mode do
        :once -> Holder.Process.read(ctx.procs, [name], timeout: timeout)
        :wait -> Holder.Process.await_dead(ctx.procs, name, timeout)
      end

    case reading do
      {:ok, %{^name => r}} -> judge(ctx, r)
      {:ok, %{} = r} -> judge(ctx, r)
      other -> {:unknown, {:read, other}}
    end
  end

  defp judge(ctx, reading) do
    cond do
      Holder.Process.dead?(reading) -> exit_file(ctx)
      :unknown in [reading.socket, reading.process] -> {:unknown, {:read, reading}}
      true -> {:ok, :live}
    end
  end

  defp exit_file(ctx) do
    args = ["-c", @exit, "caf-exit", ctx.exit]

    case Shell.run(ctx.programs.host, ctx.programs.paths.sh, args, timeout: @call) do
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

  defp mono, do: System.monotonic_time(:millisecond)

  defp row(id, where, worktree, argv) do
    %{
      id: id,
      argv: Store.text(argv),
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
      config = %{
        hosts: Keyword.fetch!(opts, :hosts),
        copies: Keyword.fetch!(opts, :copies),
        scheduler: Keyword.get(opts, :scheduler)
      }

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

      s = %{db: db, config: config, on_late_end: Keyword.fetch!(opts, :on_late_end), callers: %{}}
      {:ok, Map.merge(s, Reader.loop(opts)), {:continue, :settle}}
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
  def handle_info(:tick, s), do: {:noreply, Reader.tick(s, &{:ok, settle_owed(&1)})}

  # The caller's process ended with its run under way: a row still `asked` sent nothing and is
  # interrupted, as after a restart; one starting or running is owed its end. Either way its
  # row settles, so the lease it holds is released.
  def handle_info({:DOWN, ref, :process, _, _}, s) do
    {id, callers} = Map.pop(s.callers, ref)
    s = %{s | callers: callers}

    case id && Table.get(s.db, id) do
      %{state: "asked"} = row ->
        write(s, %{row | state: "interrupted", late: "owed"})

      %{state: st, late: nil} = row when st in ~w(starting running) ->
        write(s, %{row | late: "owed"})

      _ ->
        :ok
    end

    {:noreply, s}
  end

  @impl true
  def handle_call(:config, _from, s), do: {:reply, {:ok, s.config}, s}
  def handle_call(:rows, _from, s), do: {:reply, Table.all(s.db), s}
  def handle_call({:get, id}, _from, s), do: {:reply, Table.get(s.db, id), s}

  def handle_call({:ask, %{id: id} = row, caller}, _from, s) do
    if Table.get(s.db, id) do
      {:reply, {:refused, {:job_exists, id}}, s}
    else
      s = put_in(s.callers[Process.monitor(caller)], id)
      {:reply, put_row(s, row), s}
    end
  end

  def handle_call({:put, id, fields}, _from, s) do
    case Table.get(s.db, id) do
      nil -> {:reply, {:refused, {:no_job, id}}, s}
      row -> {:reply, write(s, Map.merge(row, fields)), forget(s, id, fields)}
    end
  end

  def handle_call({:advance, id, from, fields}, _from, s) do
    case Table.get(s.db, id) do
      %{state: ^from} = row -> {:reply, write(s, Map.merge(row, fields)), s}
      %{state: state} -> {:reply, {:refused, {:row, state}}, s}
      nil -> {:reply, {:refused, {:no_job, id}}, s}
    end
  end

  def handle_call({:owe, id}, _from, s) do
    case Table.get(s.db, id) do
      nil -> {:reply, {:refused, {:no_job, id}}, s}
      row -> {:reply, write(s, %{row | late: "owed"}), s}
    end
  end

  # A row its run has settled needs no watch on its caller.
  defp forget(s, id, %{state: state}) when state in @ended do
    case Enum.find(s.callers, fn {_ref, of} -> of == id end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])
        %{s | callers: Map.delete(s.callers, ref)}

      nil ->
        s
    end
  end

  defp forget(s, _id, _fields), do: s

  # Reads each owed row's job on the host once, in this process, so its end is written by the
  # one writer that hands it on. A row still live, or unread, waits for the next cue.
  defp settle_owed(s) do
    for %{late: "owed"} = row <- Table.all(s.db) do
      put = fn fields -> write(s, Map.merge(Table.get(s.db, row.id), fields)) end

      with {:ok, ctx} <- context_of(s.config, row.id, row, @settle_read, :reach),
           do: settle_row(ctx, row, @settle_read, put)

      # An end already written, whose hand-on a crash cut.
      with %{late: "owed"} = now <- Table.get(s.db, row.id), do: write(s, now)
    end

    s
  end

  # Every write of a row goes here: an owed row that has ended is handed on, then marked told.
  # The hand-on answers `:ok` (the end is stored: told) or `{:unknown, reason}` (not stored: the
  # row stays owed, and the next cue hands it again). Any other answer is the app's bug: it raises.
  defp write(s, %{late: "owed", state: state} = row) when state in @ended do
    case s.on_late_end.(%{job: row.id, end: late_end(row), fetch: :not_fetched}) do
      :ok -> put_row(s, %{row | late: "told"})
      {:unknown, _reason} -> put_row(s, row)
    end
  end

  defp write(s, row), do: put_row(s, row)

  defp put_row(s, row) do
    :ok = Table.put(s.db, row)
    s.notify.(%{topic: "jobs", ids: [row.id]})
    :ok
  end

  defp late_end(%{state: "exited", code: code}), do: {:exit, code}
  defp late_end(%{state: "timedout"}), do: {:unknown, :timeout}
  defp late_end(%{state: "lost"}), do: {:unknown, :no_exit}
  defp late_end(%{state: "refused"}), do: {:refused, {:start, :not_held}}
  defp late_end(%{state: "interrupted"}), do: {:refused, :interrupted}
end
