defmodule CodingAgentFramework.Services do
  @moduledoc """
  Programs agents start and keep on a host, in a copy of a worktree: held by dtach, owned,
  logged, handed, stopped and restarted (see "Hosts" and "Agents working together" in `docs/design.md`, `model/tla/Copy.tla`
  and `model/tla/Team.tla`). One process with no name, started by the embedding app, which owns
  the `services` table (`CodingAgentFramework.Services.Table`). A call works in the caller's
  process; `Grants` checks each caller against the tree.

  **A start** (`start/5`) takes the copy's turn, syncs (`CodingAgentFramework.Copies`), holds
  `argv` under a wrapper that records the program's pid and then execs it in the copy, with
  its output appended to `<dir>/services/<name>.log` on the host and its input from dtach's
  terminal. The row then holds the pid and the start time `ps` gives.

  **An end** (`stop/4`, a restart, the owner's end) is written to the row (`ending` or
  `restarting`, with `end_until`) before it is sent. It sends TERM to the program's group only
  while its pid still has the recorded start time; at `end_until` (the call's timeout, its
  grace) with the socket still live, it sends KILL the same way, as its own step. It is done
  only once the socket reads dead. A host unread, or a socket still live a short wait after
  KILL, answers `{:unknown, _}` and the row stays as written; a second call, or `cue/2`, sends
  it again.

  **A restart** (`restart/4`) counts up, ends the service, then starts it with its own sync.

  **The owner's end** (`owner_ended/3`), which the embedding app calls when an agent ends: each
  running service it owns ends, or, with `keep`, goes to the owner's parent. `keep` stays with
  the service when it is handed (`hand/4`). A start that settles after its owner's end reads
  that end (the `:ended` option) as it writes `running`, and is taken the same way.

  **After a restart of the framework**, at its start and at each `cue/2`, in `Services`' own
  process: a row `asked` is `refused` (nothing was sent); one `starting` past its
  `start_until` is read once, made `running` or `refused`, and its copy's turn given back; one
  `ending` or `restarting` is sent its end again (KILL past its `end_until`) and is `ended` once
  its socket reads dead. A restart that a restart cut is not started again.

      {:ok, services} = Services.start_link(dir: dir, copies: copies, grants: grants,
        ended: &agent_ended?/1, hosts: %{"box" => %{programs: p, dir: "/srv/caf"}})
      Services.start(services, "web-fix", "db", ["/usr/bin/postgres", "-D", "data"],
        host: "box", project: "web", copy: "fix-login", worktree: wt, keep: true)
      #=> {:ok, %{name: "db", state: "running", pid: 4242, restarts: 0, ...}}
  """

  use GenServer

  alias CodingAgentFramework.{Grants, Holder, Shell}
  alias CodingAgentFramework.Copies.Held
  alias CodingAgentFramework.Services.Table

  @call 5_000
  # The grace before KILL when no call names one; and how long, after KILL, the end waits for
  # the socket to read dead.
  @grace 10_000
  @kill_wait 2_000
  # An ended row holds no process and has no owner (`EndedIsEnded`, Team.tla's `OneOwner`).
  @ended %{state: "ended", pid: nil, started: nil, owner: nil}
  # How long a read made in `Services`' own process (its start, a cue) waits on the host.
  @settle_read 2_000
  # $1 the pid file, $2 the log, $3 the copy; then argv. exec keeps the pid the wrapper wrote,
  # and the program leads the group dtach's child leads.
  @wrapper ~S"""
  p=$1 l=$2 c=$3; shift 3
  echo $$ > "$p"
  cd "$c" && exec "$@" >>"$l" 2>&1
  """
  # $1 the pid file, $2 sleep, $3 ps, $4 tries 0.1 s apart. Prints `held <pid> <start time>`,
  # `gone` when the pid no longer runs, or `none` with no pid file.
  @held ~S"""
  i=0
  while [ ! -s "$1" ]; do [ "$i" -ge "$4" ] && { echo none; exit 0; }; i=$((i+1)); "$2" 0.1; done
  read -r p < "$1"; export LC_ALL=C TZ=UTC
  t=$("$3" -o lstart= -p "$p") || { echo gone; exit 0; }
  echo held "$p" $t
  """
  # $1 the pid, $2 its start time, $3 ps, $4 kill, $5 the signal. The check and the signal run
  # in one process, so a pid another program took is never signaled.
  @end_script ~S"""
  export LC_ALL=C TZ=UTC
  t=$("$3" -o lstart= -p "$1") || { echo gone; exit 0; }
  [ "$(echo $t)" = "$2" ] || { echo gone; exit 0; }
  "$4" -"$5" -- "-$1" && echo sent
  """

  @doc """
  Starts the part. Options: `:dir`, a directory of this machine of its own (the table);
  `:copies`, the `Copies` server; `:grants`, a `Grants`; `:ended`, a function of an agent's
  name that answers true once that agent has ended (the embedding app's durable row); `:hosts`, each host's name to
  `%{programs: programs, dir: dir}`, its `Programs` (with `dtach`, `sh`, `env`, `rm`, `kill`,
  `sleep`, `mkdir`, `ps`, `tail`, and for the copy `flock` and `rsync`) and its framework
  directory.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Starts service `name` (a socket name: letters, digits, `-`, `_`) for `owner`, holding `argv`
  in the copy the options name. Options: `:host`, `:project`, `:copy` (the worktree's name) and
  `:worktree` (its path), all required; `:keep` (false); `:env`, the program's whole
  environment as `{name, value}` pairs; `:start_timeout` (ms) for dtach's reply;
  `:sync_timeout`, `:lock_wait` and `:reaper` for the sync. A name is free once its row is
  `ended` or `refused`. Answers the row, `running`; or, when the owner ended before the start
  settled, the row handed to the owner's parent (with `keep`) or `{:refused, {:start,
  :owner_ended}}` once it is ended.
  """
  @spec start(GenServer.server(), String.t(), String.t(), [String.t()], keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def start(services, owner, name, argv, opts) do
    row = %{
      name: name,
      host: Keyword.fetch!(opts, :host),
      project: Keyword.fetch!(opts, :project),
      copy: Keyword.fetch!(opts, :copy),
      worktree: Keyword.fetch!(opts, :worktree),
      argv: argv,
      env: Keyword.get(opts, :env, []),
      owner: owner,
      keep: Keyword.get(opts, :keep, false),
      pid: nil,
      started: nil,
      restarts: 0,
      state: "asked",
      start_until: nil,
      end_until: nil
    }

    with {:ok, grants} <- grants(services),
         :ok <- Grants.may_start_service?(grants, owner),
         :ok <- call(services, {:ask, row}),
         do: launch(services, row, opts)
  end

  @doc """
  Ends service `name`, for `caller`, its owner or the owner's parent. Option: `:timeout` (ms,
  default 10 s), the grace TERM has before KILL. Answers the row, `ended`.
  """
  @spec stop(GenServer.server(), String.t(), String.t(), keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def stop(services, caller, name, opts \\ []) do
    with {:ok, row} <- fixable(services, caller, name, ~w(running ending)),
         do: end_service(services, row, %{state: "ending"}, opts)
  end

  @doc """
  Restarts service `name`, for its owner or the owner's parent: its restart count goes up, it
  ends as `stop/4` ends it, then starts again with its own sync, with `start/5`'s options.
  Answers the row, `running`.
  """
  @spec restart(GenServer.server(), String.t(), String.t(), keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def restart(services, caller, name, opts \\ []) do
    with {:ok, row} <- fixable(services, caller, name, ~w(running)),
         {:ok, row} <-
           end_service(services, row, %{state: "restarting", restarts: row.restarts + 1}, opts),
         do: launch(services, row, opts)
  end

  @doc """
  Hands running service `name` from `caller`, its owner, to `to`, the owner's parent or one of
  its children. `keep` stays with the service. Answers the row.
  """
  @spec hand(GenServer.server(), String.t(), String.t(), String.t()) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def hand(services, caller, name, to) do
    with {:ok, row} <- row_of(services, name),
         :ok <- in_state(row, ~w(running)),
         {:ok, grants} <- grants(services),
         :ok <- Grants.may_hand?(grants, caller, row.owner, to),
         do: put(services, name, %{owner: to}, %{owner: row.owner, state: "running"})
  end

  @doc """
  Service `name`'s log from byte `offset`: `{:ok, %{text: text, next: offset}}`, where `next` is
  the offset to read from next. Option: `:timeout` (ms, default 5 s).

      Services.logs(services, "db", 3)
      #=> {:ok, %{text: "in one\n", next: 10}}
  """
  @spec logs(GenServer.server(), String.t(), non_neg_integer, keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def logs(services, name, offset, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @call)

    with {:ok, row} <- row_of(services, name),
         {:ok, ctx} <- context(services, row, timeout) do
      args = ["-c", "+#{offset + 1}", ctx.log]

      case Shell.run(ctx.programs.host, ctx.programs.paths.tail, args, timeout: timeout) do
        {:ok, %{status: 0, output: text}} -> {:ok, %{text: text, next: offset + byte_size(text)}}
        other -> {:unknown, {:log, other}}
      end
    end
  end

  @doc """
  The owner's end: the embedding app calls it when agent `owner` ends. Each running service it
  owns with `keep` goes to its parent; each other one ends, as `stop/4` ends it, with its
  options. Answers each service's outcome by name: `{:ok, {:handed, parent}}`, `{:ok,
  :ended}`, or what its end answered. A service whose start is under way is not taken.
  """
  @spec owner_ended(GenServer.server(), String.t(), keyword) :: {:ok, map} | {:unknown, term}
  def owner_ended(services, owner, opts \\ []) do
    with {:ok, grants} <- grants(services), rows when is_list(rows) <- list(services) do
      {:ok,
       for row <- rows, row.owner == owner, row.state in ~w(running ending), into: %{} do
         {row.name, owner_end(services, grants, row, opts)}
       end}
    end
  end

  defp owner_end(services, grants, %{keep: true, state: "running"} = row, _opts) do
    with {:ok, parent} <- Grants.parent(grants, row.owner),
         {:ok, _} <- put(services, row.name, %{owner: parent}, %{owner: row.owner}),
         do: {:ok, {:handed, parent}}
  end

  defp owner_end(services, _grants, row, opts) do
    with {:ok, _} <- end_service(services, row, %{state: "ending"}, opts), do: {:ok, :ended}
  end

  @doc "Every service's row."
  @spec list(GenServer.server()) :: [map] | {:unknown, term}
  def list(services), do: call(services, :rows)

  @doc "Hands `Services` a host reader's cue: rows a restart left are settled. Answers `:ok`."
  @spec cue(GenServer.server(), map) :: :ok
  def cue(services, %{topic: _}), do: GenServer.cast(services, :cue)

  defp fixable(services, caller, name, states) do
    with {:ok, row} <- row_of(services, name),
         :ok <- in_state(row, states),
         {:ok, grants} <- grants(services),
         :ok <- Grants.may_fix_service?(grants, caller, row.owner),
         do: {:ok, row}
  end

  defp in_state(row, states),
    do: if(row.state in states, do: :ok, else: {:refused, {:state, row.state}})

  # The copy's turn, the sync, then the hold; the turn goes back once the start is settled.
  defp launch(services, row, opts) do
    start = Keyword.get(opts, :start_timeout, 5_000)
    refused = fn _ -> put(services, row.name, %{state: "refused", owner: nil}) end

    with {:ok, ctx} <- context(services, row, start),
         {:ok, _} <- Held.ready(ctx, row.worktree, [clear: [ctx.pid]] ++ opts, refused),
         until = now() + start,
         {:ok, _} <- put(services, row.name, %{state: "starting", start_until: until}) do
      held =
        Held.hold(ctx, @wrapper, ["caf-service", ctx.pid, ctx.log, ctx.path], row.argv, row.env)

      # Held or cut, the pid file says whether the wrapper ran.
      Held.settle(
        ctx,
        held,
        until,
        fn _ -> read_held(ctx, @call) end,
        &started(services, row.name, &1, opts)
      )
    end
  end

  # A start its owner's end took is ended here, in the start's own call.
  defp started(services, name, seen, opts) do
    with {:ok, row} <- call(services, {:started, name, seen}) do
      case seen do
        _ when row.state == "ending" ->
          with {:ok, _} <- end_service(services, row, %{state: "ending"}, opts),
               do: {:refused, {:start, :owner_ended}}

        {:ok, {_, _}} ->
          {:ok, row}

        {:ok, :gone} ->
          {:refused, {:start, :exited}}

        {:ok, :none} ->
          {:refused, {:start, :not_held}}

        {:refused, _} = refused ->
          refused
      end
    end
  end

  defp read_held(ctx, timeout) do
    %{sh: sh, sleep: sleep, ps: ps} = ctx.programs.paths
    args = ["-c", @held, "caf-held", ctx.pid, sleep, ps, "#{div(timeout, 200)}"]

    case Shell.run(ctx.programs.host, sh, args, timeout: timeout) do
      {:ok, %{status: 0, output: "none\n"}} -> {:ok, :none}
      {:ok, %{status: 0, output: "gone\n"}} -> {:ok, :gone}
      {:ok, %{status: 0, output: "held " <> rest}} -> held(rest)
      other -> {:unknown, {:read, other}}
    end
  end

  defp held(rest) do
    [pid, started] = String.split(String.trim(rest), " ", parts: 2)
    {:ok, {String.to_integer(pid), started}}
  end

  # The end is written before it is sent, and is done once the socket reads dead: TERM, then
  # KILL once its grace has passed.
  defp end_service(services, row, fields, opts) do
    until = now() + Keyword.get(opts, :timeout, @grace)
    fields = Map.put(fields, :end_until, until)

    with {:ok, ctx} <- context(services, row, @call),
         {:ok, row} <- put(services, row.name, fields, %{state: row.state}),
         :ok <- send_end(ctx, row, "TERM"),
         :ok <- dead_or_kill(ctx, row, until) do
      put(services, row.name, after_end(row))
    end
  end

  defp dead_or_kill(ctx, row, until) do
    with {:unknown, {:not_dead, _}} <- dead(ctx, row.name, until),
         :ok <- send_end(ctx, row, "KILL"),
         do: dead(ctx, row.name, now() + @kill_wait)
  end

  # A restart's end leaves the row asked, for its start.
  defp after_end(%{state: "restarting"}), do: %{state: "asked", pid: nil, started: nil}
  defp after_end(_), do: @ended

  defp send_end(%{}, %{pid: nil}, _signal), do: :ok

  defp send_end(ctx, row, signal) do
    %{sh: sh, ps: ps, kill: kill} = ctx.programs.paths
    args = ["-c", @end_script, "caf-end", "#{row.pid}", row.started, ps, kill, signal]

    case Shell.run(ctx.programs.host, sh, args, timeout: @call) do
      {:ok, %{status: 0, output: out}} when out in ["sent\n", "gone\n"] -> :ok
      other -> {:unknown, {:end, other}}
    end
  end

  defp dead(ctx, name, deadline) do
    case Holder.state(ctx.holder, name) do
      {:ok, state} when state in [:absent, :stale] ->
        :ok

      other ->
        if now() >= deadline do
          {:unknown, {:not_dead, other}}
        else
          pause(min(100, deadline - now()))
          dead(ctx, name, deadline)
        end
    end
  end

  defp context(services, row, timeout) do
    with {:ok, config} <- call(services, :config), do: context_of(config, row, timeout)
  end

  # An earlier start of this name may have left its pid file: `Held.ready/4` clears it.
  defp context_of(config, row, timeout) do
    where = %{host: row.host, project: row.project, copy: row.copy, kind: "services"}

    with {:ok, %{base: b} = ctx} <-
           Held.context(
             config,
             Map.merge(where, %{name: row.name, run: "service:" <> row.name}),
             timeout
           ),
         do: {:ok, Map.merge(ctx, %{log: b <> ".log", pid: b <> ".pid"})}
  end

  defp pause(ms) when ms > 0 do
    receive do
    after
      ms -> :ok
    end
  end

  defp pause(_), do: :ok

  defp now, do: System.os_time(:millisecond)

  defp grants(services),
    do: with({:ok, config} <- call(services, :config), do: {:ok, config.grants})

  defp row_of(services, name) do
    case call(services, {:get, name}) do
      nil -> {:refused, {:no_service, name}}
      %{} = row -> {:ok, row}
      other -> other
    end
  end

  # Writes `fields` only while the row still has each of `expect`'s values; answers the row.
  defp put(services, name, fields, expect \\ %{}),
    do: call(services, {:put, name, fields, expect})

  defp call(services, request) do
    GenServer.call(services, request, @call)
  catch
    :exit, reason -> {:unknown, {:services, reason}}
  end

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)

    with :ok <- File.mkdir_p(dir),
         {:ok, db} <- Table.open(Path.join(dir, "services.db")) do
      keys = [:hosts, :copies, :grants, :ended]
      config = Map.new(keys, &{&1, Keyword.fetch!(opts, &1)})
      # A start not yet sent lost its call with the restart: nothing runs.
      for %{state: "asked"} = row <- Table.all(db),
          do: Table.put(db, %{row | state: "refused", owner: nil})

      {:ok, %{db: db, config: config}, {:continue, :settle}}
    else
      {:error, reason} -> {:stop, {:dir, reason}}
      refused -> {:stop, refused}
    end
  end

  @impl true
  def handle_continue(:settle, s), do: {:noreply, settle(s)}

  @impl true
  def handle_cast(:cue, s), do: {:noreply, settle(s)}

  @impl true
  def handle_call(:config, _from, s), do: {:reply, {:ok, s.config}, s}
  def handle_call(:rows, _from, s), do: {:reply, Table.all(s.db), s}
  def handle_call({:get, name}, _from, s), do: {:reply, Table.get(s.db, name), s}

  def handle_call({:ask, %{name: name} = row}, _from, s) do
    case Table.get(s.db, name) do
      %{state: state} when state not in ~w(ended refused) ->
        {:reply, {:refused, {:service_exists, name}}, s}

      _ ->
        {:reply, Table.put(s.db, row), s}
    end
  end

  def handle_call({:put, name, fields, expect}, _from, s),
    do: {:reply, put_row(s, name, fields, expect), s}

  def handle_call({:started, name, seen}, _from, s), do: {:reply, started_row(s, name, seen), s}

  defp put_row(s, name, fields, expect) do
    case Table.get(s.db, name) do
      nil ->
        {:refused, {:no_service, name}}

      row ->
        if Map.take(row, Map.keys(expect)) == expect do
          row = Map.merge(row, fields)
          Table.put(s.db, row)
          {:ok, row}
        else
          {:refused, {:changed, Map.take(row, Map.keys(expect))}}
        end
    end
  end

  # In this process, with short reads: a start a restart cut is settled once its deadline has
  # passed; then each end (one such a start's owner's end made too) is sent again and done once
  # the socket reads dead. A row unread waits for the next cue.
  defp settle(s) do
    for states <- [~w(starting), ~w(ending restarting)],
        row <- Table.all(s.db),
        row.state in states do
      with {:ok, ctx} <- context_of(s.config, row, @settle_read) do
        settle_row(s, ctx, row)
      end
    end

    s
  end

  defp settle_row(s, ctx, %{state: "starting"} = row) do
    Held.settle_cut(ctx, row.start_until, fn :cut -> read_held(ctx, @settle_read) end, fn seen ->
      started_row(s, row.name, seen)
    end)
  end

  # A restart a restart cut is ended, not started again; KILL once the end's grace has passed.
  defp settle_row(s, ctx, row) do
    signal = if now() < (row.end_until || 0), do: "TERM", else: "KILL"

    with :ok <- send_end(ctx, row, signal),
         :ok <- dead(ctx, row.name, now()),
         do: put_row(s, row.name, @ended, %{state: row.state})
  end

  # A settled start, written; one that lands after its owner's end is taken as that end takes
  # it (`Copy.tla`'s `OwnerSeen`): handed to the owner's parent with `keep`, else ended. Read in
  # the same call as the write, so the owner's end either sees `running` or is seen here.
  defp started_row(s, name, seen) do
    with {:ok, row} <- put_row(s, name, start_fields(seen), %{state: "starting"}) do
      if row.state == "running" and s.config.ended.(row.owner),
        do: put_row(s, name, taken(s.config.grants, row), %{state: "running"}),
        else: {:ok, row}
    end
  end

  defp taken(grants, row) do
    with true <- row.keep, {:ok, parent} <- Grants.parent(grants, row.owner) do
      %{owner: parent}
    else
      _ -> %{state: "ending", owner: nil, end_until: now() + @grace}
    end
  end

  # What a settled start says the row is.
  defp start_fields({:ok, {pid, started}}), do: %{state: "running", pid: pid, started: started}
  defp start_fields({:ok, :gone}), do: @ended
  defp start_fields(_none_or_refused), do: %{@ended | state: "refused"}
end
