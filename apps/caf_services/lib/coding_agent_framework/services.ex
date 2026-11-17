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

  **Input and waits** (`send/5`, `wait/4`): input goes to the terminal by `dtach -p` on the
  host while the pid still has its start time; a wait polls the log, a port, and the socket. A
  line is looked for from the log's size at the current start, which the row keeps.

  **A forward** (`start/5`'s `:forward`, for a host reached over ssh): once the service runs,
  an `ssh -N -L 127.0.0.1:<local>:127.0.0.1:<port>` with `ExitOnForwardFailure` is held by
  dtach in the workstation's services directory, on a socket named for the service. It is open
  only when that ssh's own pid listens on the local port (`lsof`); the start answers then, and
  a forward that fails ends the service. An end ends the forward first. `reopen/4` opens a lost
  forward again, once per claimed state (see `model/tla/Copy.tla`'s `Fwds`).

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

  alias CodingAgentFramework.{Acts, Grants, Holder, Programs, Shell}
  alias CodingAgentFramework.Copies.Held
  alias CodingAgentFramework.Services.Table

  @call 5_000
  @log_max 16_384
  # A pipe hides the tail's own status, so a log that cannot be read is refused before it; the
  # tail's broken-pipe complaint, once head has its bytes, goes to /dev/null, not into the text.
  @bounded ~S"""
  [ -r "$1" ] || exit 1
  "$2" -c "+$3" "$1" 2>/dev/null | "$4" -c "$5"
  """
  # The grace before KILL when no call names one; and how long, after KILL, the end waits for
  # the socket to read dead.
  @grace 10_000
  @kill_wait 2_000
  # An ended row holds no process and has no owner (`EndedIsEnded`, Team.tla's `OneOwner`).
  @ended %{state: "ended", pid: nil, started: nil, owner: nil}
  # How long a read made in `Services`' own process (its start, a cue) waits on the host.
  @settle_read 2_000
  # $1 the log, $2 the copy, $3 wc, $4 the offset file; then argv. It runs after
  # `Holder.Process`'s wrapper wrote the record, in the same process: exec keeps the pid, and the
  # program leads the group dtach's child leads. The offset file holds the log's size before
  # the program writes, the start's log offset.
  @wrapper ~S"""
  l=$1 c=$2 w=$3 o=$4; shift 4
  : >>"$l" && f=$("$w" -c <"$l") || exit 1
  echo $f > "$o"
  cd "$c" && exec "$@" >>"$l" 2>&1
  """
  # $1 the offset file, $2 sleep: the wrapper writes it a moment after the record, so it is
  # waited for, 0.1 s apart, for at most 2 s.
  @offset ~S"""
  i=0
  while [ ! -s "$1" ] && [ "$i" -lt 20 ]; do "$2" 0.1; i=$((i+1)); done
  [ -s "$1" ] && read -r f < "$1" && echo "$f"
  """
  # On the workstation: $1 mkdir, $2 the forwards' directory.
  @fwd_dir ~S("$1" -p "$2")
  # $1 lsof, $2 the forward's pid, $3 the local port: exits 0 when that pid itself listens on
  # the port (another program's listener reads the same as no listener).
  @fwd_listens ~S"""
  "$1" -n -P -a -p "$2" -iTCP@127.0.0.1:"$3" -sTCP:LISTEN -t >/dev/null 2>&1
  """
  # How long a forward has to open, when no call names it.
  @fwd_timeout 10_000
  # Each read a forward's hold makes in `Services`' own process (a reopen's socket read, the
  # pid file's clear, dtach), and the call that waits for all three.
  @hold_read 2_000
  @hold_call 3 * @hold_read + 1_000
  # An argument carries no NUL, and a remote command line has a bounded length.
  @max_input 65_536
  # The pause between a wait's rounds of reads.
  @round 100

  @doc """
  Starts the part. Options: `:dir`, a directory of this machine of its own (the table);
  `:copies`, the `Copies` server; `:grants`, a `Grants`; `:ended`, a function of an agent's
  name that answers true once that agent has ended (the embedding app's durable row); `:hosts`, each host's name to
  `%{programs: programs, dir: dir}`, its `Programs` (with `dtach`, `sh`, `env`, `rm`, `kill`,
  `sleep`, `mkdir`, `ps`, `tail`, `wc`, `nc` for a port wait, and for the copy `flock` and `rsync`) and its framework
  directory, and for a host reached over ssh, `ssh_env`, the environment its forwards' ssh runs
  in (`{name, value}` pairs, none by default); `:workstation`, the name of the host forwards
  are held on (its programs also with `lsof`); and optionally `:acts`, the instance's `Acts`,
  where each `stop/4` of a running service and each `restart/4` is a row, act `service_stop`
  or `service_restart`, target `service:<name>`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Starts service `name` (a socket name: letters, digits, `-`, `_`) for `owner`, holding `argv`
  in the copy the options name. Options: `:host`, `:project`, `:copy` (the worktree's name) and
  `:worktree` (its path), all required; `:keep` (false); `:env`, the program's whole
  environment as `{name, value}` pairs; `:start_timeout` (ms) for dtach's reply;
  `:sync_timeout`, `:lock_wait` and `:reaper` for the sync; `:forward`, a port the service
  listens on (its host's `127.0.0.1`) to forward to the workstation's same port, or `{port,
  local}`; `:forward_timeout` (ms, default 10 s) for the forward to open. `:timeout` (ms) is
  the deadline of the whole start: each step's own timeout, the forward's too, is cut to what
  is left of it; without it each step has its own. A name is free once its row is `ended` or
  `refused`. A name other than 1 to 64 letters, digits, `-` or `_` is `{:refused, {:name,
  name}}`; a local port another live service's forward holds is `{:refused, {:local_taken,
  holder}}`, both before anything starts. Answers the row, `running`, with its forward open; or, when
  the owner ended before the start settled, the row handed to the owner's parent (with `keep`)
  or `{:refused, {:start, :owner_ended}}` once it is ended; or `{:refused, {:forward, reason}}`
  once a forward that failed has ended the service.
  """
  @spec start(GenServer.server(), String.t(), String.t(), [String.t()], keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def start(services, owner, name, argv, opts) do
    deadline = if t = Keyword.get(opts, :timeout), do: now() + t
    # `:timeout` is also the grace of an end, which a failed start makes: keep it apart.
    opts = opts |> Keyword.delete(:timeout) |> Keyword.put(:deadline, deadline)

    with :ok <- check_name(name),
         {:ok, row} <- new_row(services, owner, name, argv, opts),
         {:ok, grants} <- grants(services),
         :ok <- Grants.may_start_service?(grants, owner),
         :ok <- call(services, {:ask, row}),
         do: launch(services, row, opts)
  end

  # The name is a file and socket name on the host.
  defp check_name(name) do
    if is_binary(name) and name =~ ~r/\A[A-Za-z0-9_-]{1,64}\z/,
      do: :ok,
      else: {:refused, {:name, name}}
  end

  # A step's timeout, cut to what is left of the start's deadline (none: as it is).
  defp within(opts, key, default) do
    t = Keyword.get(opts, key, default)

    case Keyword.get(opts, :deadline) do
      nil -> t
      deadline -> max(0, min(t, deadline - now()))
    end
  end

  defp new_row(services, owner, name, argv, opts) do
    host = Keyword.fetch!(opts, :host)

    with {:ok, config} <- call(services, :config),
         {:ok, port, local} <- forward_of(config, host, Keyword.get(opts, :forward)) do
      {:ok,
       %{
         name: name,
         host: host,
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
         end_until: nil,
         log_from: nil,
         port: port,
         local: local,
         fwd: nil,
         opens: 0
       }}
    end
  end

  # A host this machine reaches without ssh needs no forward: its port is the local one.
  defp forward_of(_config, _host, nil), do: {:ok, nil, nil}

  defp forward_of(config, host, port) when is_integer(port),
    do: forward_of(config, host, {port, port})

  defp forward_of(config, host, {port, local} = forward)
       when port in 1..65_535 and local in 1..65_535 do
    if port == local or forwarded?(config, %{host: host, port: port}),
      do: {:ok, port, local},
      else: {:refused, {:bad_forward, forward}}
  end

  defp forward_of(_config, _host, other), do: {:refused, {:bad_forward, other}}

  # A service whose port is forwarded: one asked for, on a host reached over ssh.
  defp forwarded?(config, %{host: host, port: port}) when is_integer(port),
    do: match?(%{programs: %{host: %{reach: {:ssh, _, _}}}}, config.hosts[host])

  defp forwarded?(_config, _row), do: false

  @doc """
  Ends service `name`, for `caller`, its owner or the owner's parent. Option: `:timeout` (ms,
  default 10 s), the grace TERM has before KILL. Answers the row, `ended`.
  """
  @spec stop(GenServer.server(), String.t(), String.t(), keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def stop(services, caller, name, opts \\ []) do
    with {:ok, row} <- fixable(services, caller, name, ~w(running ending)) do
      run = fn -> end_service(services, row, %{state: "ending"}, opts) end
      # An end sent again (the row `ending`) goes on with the act its first call claimed.
      if row.state == "running",
        do: as_act(services, caller, row, :service_stop, run),
        else: run.()
    end
  end

  @doc """
  Restarts service `name`, for its owner or the owner's parent: its restart count goes up, it
  ends as `stop/4` ends it, then starts again with its own sync, with `start/5`'s options.
  Answers the row, `running`.
  """
  @spec restart(GenServer.server(), String.t(), String.t(), keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def restart(services, caller, name, opts \\ []) do
    with {:ok, row} <- fixable(services, caller, name, ~w(running)) do
      as_act(services, caller, row, :service_restart, fn ->
        with {:ok, row} <-
               end_service(
                 services,
                 row,
                 %{state: "restarting", restarts: row.restarts + 1},
                 opts
               ),
             do: launch(services, row, opts)
      end)
    end
  end

  # A fix's row in `Acts` (F-126's new-4), when the app gave one: claimed by the caller on the
  # running process (its pid, start time and restart count) before `run` acts, and settled by
  # its answer (`Acts.answered/4`). A second fix of that process is refused `{:claimed, by}`
  # or `{:already_claimed, by}`, and acts on nothing.
  defp as_act(services, caller, row, act, run) do
    with {:ok, config} <- call(services, :config) do
      case config.acts do
        nil ->
          run.()

        acts ->
          state = %{pid: row.pid, started: row.started, restarts: row.restarts}

          with {:ok, id} <- Acts.claim(acts, caller, "service:" <> row.name, state, act) do
            answer = run.()
            Acts.answered(acts, id, answer)
            answer
          end
      end
    end
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
  the offset to read from next. The host's `tail | head` takes at most `:max` bytes, so a long
  log does not move through `Shell` whole. Options: `:timeout` (ms, default 5 s), `:max`
  (bytes, default 16 KiB).

      Services.logs(services, "db", 3)
      #=> {:ok, %{text: "in one\n", next: 10}}
  """
  @spec logs(GenServer.server(), String.t(), non_neg_integer, keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def logs(services, name, offset, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @call)
    max = Keyword.get(opts, :max, @log_max)

    with {:ok, row} <- row_of(services, name),
         {:ok, ctx} <- context(services, row, timeout),
         {:ok, p} <- Programs.take(ctx.programs, [:sh, :tail, :head]) do
      args = ["-c", @bounded, "sh", ctx.log, p.tail, "#{offset + 1}", p.head, "#{max}"]

      case Shell.run(ctx.programs.host, p.sh, args, timeout: timeout) do
        {:ok, %{status: 0, output: text}} -> {:ok, %{text: text, next: offset + byte_size(text)}}
        other -> {:unknown, {:log, other}}
      end
    end
  end

  @doc """
  Sends `input` to running service `name`'s terminal, for `caller`, its owner or the owner's
  parent: `dtach -p` on its host, only while its pid still has the recorded start time. The
  input is bytes as typed: `"\\n"` is Enter, `"\\x03"` ctrl-C. Option: `:timeout` (ms, default 5
  s). Answers `{:ok, :sent}`; `{:refused, :not_held}` when the held program is not the row's
  and nothing went in; `{:unknown, _}` when some of it may have. Never resent.

      Services.send(services, "web-a", "repl", "1 + 1\\n")
      #=> {:ok, :sent}
  """
  @spec send(GenServer.server(), String.t(), String.t(), String.t(), keyword) ::
          {:ok, :sent} | {:refused, term} | {:unknown, term}
  def send(services, caller, name, input, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @call)

    with :ok <- input_ok(input),
         {:ok, row} <- fixable(services, caller, name, ~w(running)),
         {:ok, ctx} <- context(services, row, timeout) do
      case Holder.Process.push(ctx.procs, name, record(row), input, timeout: timeout) do
        {:ok, :sent} -> {:ok, :sent}
        {:ok, :gone} -> {:refused, :not_held}
        {:unknown, why} -> {:unknown, {:send, why}}
      end
    end
  end

  defp input_ok(input) do
    cond do
      not is_binary(input) or String.contains?(input, <<0>>) -> {:refused, :bad_input}
      byte_size(input) > @max_input -> {:refused, {:input_too_long, @max_input}}
      true -> :ok
    end
  end

  @doc """
  Waits up to `timeout` ms until service `name` meets `until`, for any caller:

    * `{:line, pattern}` or `{:line, pattern, from}`: a whole line of the log from byte `from`
      (default the current start's offset, so a line an earlier start wrote never answers)
      matches `pattern` (a `Regex` or its source); answers `{:ok, {:line, line, next}}`, `next`
      the offset just after that line;
    * `{:port, port}`: the port listens on the host's `127.0.0.1` (the host's `nc`); answers
      `{:ok, {:port, port}}`;
    * `:exit`.

  The service's exit, its socket read dead, ends every wait with `{:ok, :exited}`; the log is
  read once more after that read. At the timeout: `{:unknown, :timeout}`, or `{:unknown,
  :dropped}` when the last read failed. A failed read is no answer: the next round reads again.

      Services.wait(services, "db", {:line, ~r/ready to accept/}, 30_000)
      #=> {:ok, {:line, "LOG: ready to accept connections", 412}}
  """
  @spec wait(GenServer.server(), String.t(), term, pos_integer) ::
          {:ok, term} | {:refused, term} | {:unknown, term}
  def wait(services, name, until, timeout) do
    deadline = now() + timeout

    with {:ok, until} <- until_ok(until),
         {:ok, row} <- row_of(services, name),
         {:ok, ctx} <- context(services, row, @call),
         {:ok, nc} <- nc(ctx, until) do
      wait_round(Map.put(ctx, :nc, nc), from_start(until, row), deadline, :timeout)
    end
  end

  defp from_start({:line, regex, :start}, row), do: {:line, regex, row.log_from || 0}
  defp from_start(until, _row), do: until

  defguardp from?(from) when from == :start or (is_integer(from) and from >= 0)

  defp until_ok({:line, pattern}), do: until_ok({:line, pattern, :start})
  defp until_ok({:line, %Regex{}, from} = until) when from?(from), do: {:ok, until}

  defp until_ok({:line, source, from}) when is_binary(source) and from?(from) do
    case Regex.compile(source) do
      {:ok, regex} -> {:ok, {:line, regex, from}}
      {:error, _} -> {:refused, {:bad_pattern, source}}
    end
  end

  defp until_ok({:port, port} = until) when port in 1..65_535, do: {:ok, until}
  defp until_ok(:exit), do: {:ok, :exit}
  defp until_ok(other), do: {:refused, {:bad_until, other}}

  defp nc(ctx, {:port, _}) do
    with {:ok, %{nc: nc}} <- Programs.take(ctx.programs, [:nc]), do: {:ok, nc}
  end

  defp nc(_ctx, _until), do: {:ok, nil}

  # One round: the socket, then the condition, so a line written before the exit is found.
  # `last` is how the wait ends at its deadline: dropped while the last round's reads failed.
  # A read the deadline itself cut keeps the round before's.
  defp wait_round(ctx, until, deadline, last) do
    timeout = max(min(deadline - now(), @call), 1)
    state = Holder.state(%{ctx.holder | timeout: timeout}, ctx.name)

    case {met(ctx, until, timeout), state} do
      {{:ok, _} = answer, _} ->
        answer

      {{:no, _}, {:ok, dead}} when dead in [:absent, :stale] ->
        {:ok, :exited}

      {{read, until}, state} ->
        cut = read == :cut or match?({:unknown, {:timeout, _}}, state)

        last =
          cond do
            read == :no and match?({:ok, _}, state) -> :timeout
            cut and now() >= deadline -> last
            true -> :dropped
          end

        if now() >= deadline do
          {:unknown, last}
        else
          pause(min(@round, deadline - now()))
          wait_round(ctx, until, deadline, last)
        end
    end
  end

  # `{:ok, answer}`, `{:no, until}` with a line wait's offset moved past the lines read,
  # `{:cut, until}` for a read its timeout cut, or `{:failed, until}`.
  defp met(_ctx, :exit, _timeout), do: {:no, :exit}

  defp met(ctx, {:port, port} = until, timeout) do
    case Shell.run(ctx.programs.host, ctx.nc, ["-z", "127.0.0.1", "#{port}"], timeout: timeout) do
      {:ok, %{status: 0}} -> {:ok, {:port, port}}
      {:ok, %{status: 1}} -> {:no, until}
      other -> failed(other, until)
    end
  end

  # Reads to the end on purpose: a wait must see every new line, and a bound would hide a match
  # past it.
  defp met(ctx, {:line, regex, from} = until, timeout) do
    args = ["-c", "+#{from + 1}", ctx.log]

    case Shell.run(ctx.programs.host, ctx.programs.paths.tail, args, timeout: timeout) do
      {:ok, %{status: 0, output: text}} -> line(regex, from, String.split(text, "\n"))
      other -> failed(other, until)
    end
  end

  defp failed({:unknown, {:timeout, _}}, until), do: {:cut, until}
  defp failed(_other, until), do: {:failed, until}

  # The last piece has no newline yet: it is read again from its start at the next round.
  defp line(regex, from, [_last]), do: {:no, {:line, regex, from}}

  defp line(regex, from, [line | rest]) do
    next = from + byte_size(line) + 1

    if Regex.match?(regex, line),
      do: {:ok, {:line, line, next}},
      else: line(regex, next, rest)
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
    refused = fn _ -> put(services, row.name, %{state: "refused", owner: nil}) end

    with {:ok, ctx} <- context(services, row, within(opts, :start_timeout, 5_000)),
         ready = [
           clear: [ctx.from],
           sync_timeout: within(opts, :sync_timeout, 60_000),
           lock_wait: within(opts, :lock_wait, 30_000)
         ],
         {:ok, _} <- Held.ready(ctx, row.worktree, ready ++ opts, refused),
         until = now() + within(opts, :start_timeout, 5_000),
         fields = %{state: "starting", start_until: until, fwd: nil, opens: 0},
         {:ok, _} <- put(services, row.name, fields) do
      args = ["caf-service", ctx.log, ctx.path, ctx.programs.paths.wc, ctx.from]
      held = Held.hold(ctx, @wrapper, args, row.argv, row.env)

      # Held or cut, the pid file says whether the wrapper ran.
      with {:ok, row} <-
             Held.settle(
               ctx,
               held,
               until,
               fn _ -> read_held(ctx, @call) end,
               &started(services, row.name, &1, opts)
             ),
           do: forward(services, row, opts)
    end
  end

  # A start its owner's end took is ended here, in the start's own call.
  defp started(services, name, seen, opts) do
    fwd_until = now() + within(opts, :forward_timeout, @fwd_timeout)

    with {:ok, row} <- call(services, {:started, name, seen, fwd_until}) do
      case seen do
        _ when row.state == "ending" ->
          with {:ok, _} <- end_service(services, row, %{state: "ending"}, opts),
               do: {:refused, {:start, :owner_ended}}

        {:ok, {_, _, _}} ->
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

  # The held program's record (waiting up to half of `timeout` for its wrapper to write it),
  # then the start's log offset: `{:ok, {pid, offset, start}}`, `{:ok, :gone}` when the
  # recorded process no longer runs, or `{:ok, :none}` with no record.
  defp read_held(ctx, timeout) do
    name = ctx.name

    case Holder.Process.read(ctx.procs, [name], wait: div(timeout, 2), timeout: timeout) do
      {:ok, %{^name => %{process: :live, record: %{pid: pid, start: start}}}} ->
        with {:ok, from} <- offset(ctx), do: {:ok, {pid, from, start}}

      {:ok, %{^name => %{process: gone}}} when gone in [:gone, :replaced] ->
        {:ok, :gone}

      {:ok, %{^name => %{process: :none}}} ->
        {:ok, :none}

      other ->
        {:unknown, {:read, other}}
    end
  end

  defp offset(ctx) do
    %{sh: sh, sleep: sleep} = ctx.programs.paths
    args = ["-c", @offset, "caf-offset", ctx.from, sleep]

    case Shell.run(ctx.programs.host, sh, args, timeout: @call) do
      {:ok, %{status: 0, output: out}} ->
        case Integer.parse(String.trim(out)) do
          {from, ""} -> {:ok, from}
          _ -> {:unknown, {:offset, out}}
        end

      other ->
        {:unknown, {:offset, other}}
    end
  end

  # The record a row keeps of its held program.
  defp record(%{pid: nil}), do: nil
  defp record(row), do: %{pid: row.pid, start: row.started}

  # The service runs, and its row says its forward is starting: only now is the forward held
  # (`ForwardEarly`), and the start answers once it is open. A forward that fails at its start
  # ends the service (`FailKeepsService`).
  defp forward(services, %{state: "running", fwd: "starting"} = row, opts) do
    with {:ok, ctx} <- context(services, row, @call),
         {:ok, row, held} <-
           call(services, {:hold_forward, row.name, claim(row), %{}, false}, @hold_call),
         do: settle_forward(services, ctx, row, held, opts)
  end

  defp forward(_services, row, _opts), do: {:ok, row}

  @doc """
  Opens service `name`'s forward again after a loss: its socket read dead while the row said
  `open`. `Recoveries` calls it with `claim`, `%{pid: pid, started: started, opens: opens}`
  read from the row with that loss. It acts only while that is still the row's: the service's
  current start and the forward's open count, so a claim reopens once (`Copy.tla`'s
  `ForwardReopened`, once per `Key`), and a claim a restart of the service made stale does
  nothing. Option: `:forward_timeout` (ms, default 10 s). Answers the row with its forward
  `open`; `{:refused, {:forward, reason}}` once a reopen that failed has left it `failed`,
  which stays until the service's next start; `{:refused, {:changed, _}}` for a stale claim.
  """
  @spec reopen(GenServer.server(), String.t(), map, keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def reopen(services, name, %{pid: pid, started: started, opens: opens}, opts \\ []) do
    expect = %{state: "running", fwd: "open", pid: pid, started: started, opens: opens}

    fields = %{
      fwd: "reopening",
      start_until: now() + Keyword.get(opts, :forward_timeout, @fwd_timeout)
    }

    with {:ok, row} <- row_of(services, name),
         {:ok, %{ws: %{}} = ctx} <- context(services, row, @call),
         {:ok, row, held} <-
           call(services, {:hold_forward, name, expect, fields, true}, @hold_call),
         do: settle_forward(services, ctx, row, held, opts)
  end

  # The state a forward's settle claims: the row's current start, open count and forward state.
  defp claim(row), do: Map.take(row, [:state, :pid, :started, :opens, :fwd])

  defp settle_forward(services, ctx, row, held, opts) do
    deadline = if match?({:refused, _}, held), do: now(), else: row.start_until

    case forward_read(ctx.ws, row, deadline) do
      :open ->
        put(services, row.name, %{fwd: "open", opens: row.opens + 1}, claim(row))

      {:failed, reason} when row.fwd == "starting" ->
        with {:ok, _} <- end_service(services, row, %{state: "ending", fwd: "failed"}, opts),
             do: {:refused, {:forward, reason}}

      {:failed, reason} ->
        _ = end_forward(ctx.ws, row)

        with {:ok, _} <- put(services, row.name, %{fwd: "failed"}, claim(row)),
             do: {:refused, {:forward, reason}}
    end
  end

  # Open only when the forward's own ssh listens on the local port (`OpenByPort`); failed once
  # it is gone, or at the deadline.
  defp forward_read(ws, row, deadline) do
    case read_forward(ws, row) do
      {:open, _record} ->
        :open

      :gone ->
        {:failed, :exited}

      _ ->
        if now() >= deadline do
          {:failed, :not_open}
        else
          pause(min(@round, deadline - now()))
          forward_read(ws, row, deadline)
        end
    end
  end

  # The forward's record (`Holder.Process`), then whether that ssh's own pid listens on the
  # local port: `{:open, record}`, `{:held, record}` when it runs but does not listen, `:gone`,
  # or `:none` with no record.
  defp read_forward(ws, row) do
    name = row.name

    case Holder.Process.read(ws.procs, [name]) do
      {:ok, %{^name => %{process: :live, record: record}}} ->
        args = ["-c", @fwd_listens, "caf-forward", ws.lsof, "#{record.pid}", "#{row.local}"]

        case Shell.run(ws.programs.host, ws.programs.paths.sh, args, timeout: @call) do
          {:ok, %{status: 0}} -> {:open, record}
          {:ok, %{status: 1}} -> {:held, record}
          other -> {:unknown, {:forward, other}}
        end

      {:ok, %{^name => %{process: gone}}} when gone in [:gone, :replaced] ->
        :gone

      {:ok, %{^name => %{process: :none}}} ->
        :none

      other ->
        {:unknown, {:forward, other}}
    end
  end

  # The forward's ssh by its record: TERM, then KILL; done once it reads dead. Gone, or its
  # wrapper not yet written: the socket says when it ends.
  defp end_forward(ws, row) do
    case Holder.state(ws.holder, row.name) do
      {:ok, dead} when dead in [:absent, :stale] ->
        :ok

      {:ok, :live} ->
        record =
          case read_forward(ws, row) do
            {state, record} when state in [:open, :held] -> record
            _ -> nil
          end

        ended(Holder.Process.end_held(ws.procs, row.name, record, @kill_wait, group: true))

      other ->
        {:unknown, {:forward, other}}
    end
  end

  defp ended({:ok, :ended}), do: :ok
  defp ended(other), do: other

  defp end_of({:ok, :ended}), do: :ok
  defp end_of({:unknown, why}), do: {:unknown, {:end, why}}

  defp end_forward_of(%{ws: nil}, _row), do: :ok
  defp end_forward_of(ctx, row), do: end_forward(ctx.ws, row)

  # The end is written before it is sent, and is done once both sockets read dead: the
  # forward's first (`ServiceEndFirst`), then the service's, TERM, then KILL once its grace has
  # passed.
  defp end_service(services, row, fields, opts) do
    until = now() + Keyword.get(opts, :timeout, @grace)
    fields = Map.put(fields, :end_until, until)

    with {:ok, ctx} <- context(services, row, @call),
         {:ok, row} <- put(services, row.name, fields, %{state: row.state}),
         :ok <- end_forward_of(ctx, row),
         grace = max(until - now(), 0),
         :ok <-
           end_of(Holder.Process.end_held(ctx.procs, row.name, record(row), grace, group: true)) do
      put(services, row.name, after_end(row))
    end
  end

  # A restart's end leaves the row asked, for its start.
  defp after_end(%{state: "restarting"}), do: %{state: "asked", pid: nil, started: nil}
  defp after_end(_), do: @ended

  # One signal to the group the row's record leads; a row with no record has nothing to signal.
  defp send_end(_ctx, %{pid: nil}, _signal), do: :ok

  defp send_end(ctx, row, signal) do
    case Holder.Process.signal(ctx.procs, record(row), signal, group: true, timeout: @call) do
      {:ok, _sent_or_gone} -> :ok
      {:unknown, why} -> {:unknown, {:end, why}}
    end
  end

  defp context(services, row, timeout) do
    with {:ok, config} <- call(services, :config), do: context_of(config, row, timeout)
  end

  # An earlier start of this name may have left its offset file: `Held.ready/4` clears it, and
  # `Holder.Process.hold/4` its record.
  defp context_of(config, row, timeout) do
    where = %{host: row.host, project: row.project, copy: row.copy, kind: "services"}

    with {:ok, %{base: b} = ctx} <-
           Held.context(
             config,
             Map.merge(where, %{name: row.name, run: "service:" <> row.name}),
             timeout
           ),
         {:ok, ws} <- if(forwarded?(config, row), do: ws(config), else: {:ok, nil}),
         do: {:ok, Map.merge(ctx, %{log: b <> ".log", from: b <> ".from", ws: ws})}
  end

  # Where forwards are held: the workstation's services directory, each socket named for its
  # service, with its record.
  defp ws(config) do
    with {:ok, %{programs: programs, dir: dir}} <- host_of(config, config.workstation),
         dir = Path.join(dir, "services"),
         {:ok, holder} <- Holder.new(programs, dir, timeout: @hold_read),
         {:ok, procs} <- Holder.Process.new(programs, holder),
         {:ok, %{lsof: lsof}} <- Programs.take(programs, [:lsof]),
         do: {:ok, %{programs: programs, holder: holder, procs: procs, dir: dir, lsof: lsof}}
  end

  defp host_of(config, name) do
    case Map.fetch(config.hosts, name) do
      {:ok, host} -> {:ok, host}
      :error -> {:refused, {:no_host, name}}
    end
  end

  # In this process, so a service's end, written here, comes wholly before the claim's check or
  # wholly after the hold: an end that reads the forward's socket dead never meets a forward
  # held after it. A reopen of a claim still current first reads the forward dead: a live one is
  # no loss.
  defp hold_forward(s, name, expect, fields, dead_first) do
    with {:ok, ws} <- ws(s.config),
         {:ok, _} <- put_row(s, name, %{}, expect),
         :ok <- if(dead_first, do: forward_dead(ws, name), else: :ok),
         {:ok, row} <- put_row(s, name, fields, expect) do
      %{sh: sh, mkdir: mkdir} = ws.programs.paths
      {:ssh, ssh, destination} = s.config.hosts[row.host].programs.host.reach
      spec = "127.0.0.1:#{row.local}:127.0.0.1:#{row.port}"
      options = ["-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes"]
      argv = [ssh, "-N" | options] ++ ["-L", spec, "--", destination]
      env = Map.get(s.config.hosts[row.host], :ssh_env, [])

      held =
        case Shell.run(ws.programs.host, sh, ["-c", @fwd_dir, "caf-forward", mkdir, ws.dir],
               timeout: @hold_read
             ) do
          {:ok, %{status: 0}} -> Holder.Process.hold(ws.procs, name, argv, env: env)
          other -> {:refused, {:clear, other}}
        end

      {:ok, row, held}
    end
  end

  defp forward_dead(ws, name) do
    case Holder.state(ws.holder, name) do
      {:ok, dead} when dead in [:absent, :stale] -> :ok
      {:ok, :live} -> {:refused, :forward_live}
      other -> other
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

  defp call(services, request, timeout \\ @call) do
    GenServer.call(services, request, timeout)
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
      config = Map.put(config, :workstation, Keyword.get(opts, :workstation))
      config = Map.put(config, :acts, Keyword.get(opts, :acts))
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
        case local_holder(s.db, row) do
          nil -> {:reply, Table.put(s.db, row), s}
          holder -> {:reply, {:refused, {:local_taken, holder}}, s}
        end
    end
  end

  def handle_call({:put, name, fields, expect}, _from, s),
    do: {:reply, put_row(s, name, fields, expect), s}

  def handle_call({:started, name, seen, fwd_until}, _from, s),
    do: {:reply, started_row(s, name, seen, fwd_until), s}

  def handle_call({:hold_forward, name, expect, fields, dead_first}, _from, s),
    do: {:reply, hold_forward(s, name, expect, fields, dead_first), s}

  # The live service whose forward holds the local port the new row asks for.
  defp local_holder(_db, %{local: nil}), do: nil

  defp local_holder(db, %{local: local, name: name}) do
    Enum.find_value(Table.all(db), fn r ->
      if r.local == local and r.name != name and r.state not in ~w(ended refused), do: r.name
    end)
  end

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
  # passed; then a forward's start or reopen past its deadline; then each end (one such a
  # start's owner's end made too) is sent again and done once both sockets read dead. A row
  # unread waits for the next cue.
  defp settle(s) do
    for states <- [~w(starting), ~w(running), ~w(ending restarting)],
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
      started_row(s, row.name, seen, now())
    end)
  end

  # A forward whose call a restart cut: open if its own ssh holds the port, else failed; a
  # forward that failed at its start ends the service.
  defp settle_row(s, %{ws: %{}} = ctx, %{state: "running", fwd: fwd} = row)
       when fwd in ~w(starting reopening) do
    if now() >= row.start_until do
      case forward_read(ctx.ws, row, now()) do
        :open ->
          put_row(s, row.name, %{fwd: "open", opens: row.opens + 1}, claim(row))

        {:failed, _} ->
          _ = end_forward(ctx.ws, row)
          put_row(s, row.name, failed(row), claim(row))
      end
    end
  end

  defp settle_row(_s, _ctx, %{state: "running"}), do: :ok

  # A restart a restart cut is ended, not started again; KILL once the end's grace has passed.
  defp settle_row(s, ctx, row) do
    signal = if now() < (row.end_until || 0), do: "TERM", else: "KILL"

    with :ok <- end_forward_of(ctx, row),
         :ok <- send_end(ctx, row, signal),
         :ok <- ended(Holder.Process.dead_by(ctx.procs, row.name, now())),
         do: put_row(s, row.name, @ended, %{state: row.state})
  end

  defp failed(%{fwd: "starting"}),
    do: %{fwd: "failed", state: "ending", end_until: now() + @grace}

  defp failed(_reopening), do: %{fwd: "failed"}

  # A settled start, written; one that lands after its owner's end is taken as that end takes
  # it (`Copy.tla`'s `OwnerSeen`): handed to the owner's parent with `keep`, else ended. Read in
  # the same call as the write, so the owner's end either sees `running` or is seen here. A
  # forwarded service's row says its forward is starting, until `fwd_until`, in the same write.
  defp started_row(s, name, seen, fwd_until) do
    fields = start_fields(seen)

    fields =
      if fields.state == "running" and forwarded?(s.config, Table.get(s.db, name) || %{}),
        do: Map.merge(fields, %{fwd: "starting", start_until: fwd_until}),
        else: fields

    with {:ok, row} <- put_row(s, name, fields, %{state: "starting"}) do
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
  defp start_fields({:ok, {pid, from, started}}),
    do: %{state: "running", pid: pid, started: started, log_from: from}

  defp start_fields({:ok, :gone}), do: @ended
  defp start_fields(_none_or_refused), do: %{@ended | state: "refused"}
end
