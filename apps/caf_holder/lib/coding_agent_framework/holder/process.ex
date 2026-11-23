defmodule CodingAgentFramework.Holder.Process do
  @moduledoc """
  A held program's record, read and ended by it alone (`docs/design.md`, "The parts";
  `model/tla/Start.tla`'s `Held`, `Signal` and `Kill`).

  **The record** is the program's pid, its start time as `LC_ALL=C TZ=UTC ps -o lstart=` prints
  it, and its socket. `hold/4` holds the program under a wrapper that writes `<pid> <start>` to
  `<dir>/<name>.pid` before it execs the program, so the pid stays the program's, and every hold
  has a record: dtach itself reports no pid. A hold first removes the record an earlier hold of
  the name left, only while that socket is not live. A start time compares with its runs of
  spaces made one (`normal/1`), since `ps` pads a day of one digit and a shell's word splitting
  does not keep that.

  **A reading** (`read/3`) of several names runs in one shell on the host: each socket's state
  (`:live`, `:stale`, `:absent`), then its record and whether that pid still runs with that
  start time (`:live`, `:replaced` when the pid is another program's now, `:gone`, `:none` with
  no record). A program is **dead** (`dead?/1`) when its process is not live and its socket is
  absent or stale; a read that failed is neither. `await_dead/3` waits for that on the host, in
  one shell, and `push/5` writes input to the program's terminal only while the record's process
  is the held one.

  **An end** (`end_held/4`) sends TERM, waits until the program is dead, and sends KILL at its
  deadline. Each signal reaches only the process that still has the record's pid and start
  time: the check and the signal run in one shell, so a pid another program took is never
  signaled. A process is never found by its name. `Sessions`' stop sends one TERM (`signal/4`);
  `Recoveries`, `Services` and the forward end a program with `end_held/4`.

      iex> CodingAgentFramework.Holder.Process.normal(" Sat Nov  7 09:00:00 2026\\n")
      "Sat Nov 7 09:00:00 2026"
      iex> CodingAgentFramework.Holder.Process.dead?(%{socket: :stale, process: :gone})
      true
      iex> CodingAgentFramework.Holder.Process.dead?(%{socket: :absent, process: :live})
      false
  """

  alias CodingAgentFramework.{Holder, Host, Programs, Shell}

  @enforce_keys [:holder, :ps, :kill, :sleep]
  defstruct [:holder, :ps, :kill, :sleep]

  @type t :: %__MODULE__{holder: Holder.t(), ps: String.t(), kill: String.t(), sleep: String.t()}
  @type held :: %{pid: pos_integer, start: String.t()}
  @type process :: :live | :replaced | :gone | :none | :unknown
  @type reading :: %{
          name: String.t(),
          socket: Holder.state() | :unknown,
          record: held | nil,
          process: process
        }

  # The wrapper: $1 the record's file, $2 ps; then the program. The start time is read with the
  # wrapper's own pid, which exec keeps; the assignments reach ps alone, not the program.
  @wrapper ~S"""
  f=$1 p=$2; shift 2
  t=$(LC_ALL=C TZ=UTC "$p" -o lstart= -p $$) || exit 1
  echo $$ $t > "$f"
  exec "$@"
  """
  # $0 dtach; $1 the socket, $2 the record, $3 rm. An earlier hold's record goes only while its
  # socket does not answer.
  @clear ~S"""
  if [ -e "$1" ] && "$0" -p "$1" </dev/null >/dev/null 2>&1; then echo live; exit 0; fi
  "$3" -f -- "$2" && echo cleared
  """
  # $0 dtach; $1 ps, $2 sleep, $3 the wait in seconds, $4 what a name waits for: `record` (its
  # record, while its socket lives, as just after a hold), `dead`, or `none`; then pairs of a
  # socket and its record. One line per pair: the socket's state, the record (or -), and what ps
  # prints for its pid (gone, failed, or the start time). The socket is read first.
  #
  # The wait is bounded by the clock, not by a count of reads (F-217): one sleep of the whole
  # wait runs beside the reads, and a name is read again, 0.1 s apart, only while that sleep
  # lives. A count of short sleeps overshoots, since each wakes late under load. Every name's
  # wait ends at that one deadline. The timer is this shell's own child, so its pid is no other
  # program's until this shell reaps it, and it is ended only while `kill -0` finds it.
  @read ~S"""
  p=$1 z=$2 w=$3 m=$4; shift 4
  d=
  [ "$m" = none ] || { "$z" "$w" </dev/null >/dev/null 2>&1 & d=$!; }
  timer() { [ -n "$d" ] && kill -0 "$d" 2>/dev/null; }
  look() {
    if [ ! -e "$1" ]; then st=absent
    elif out=$("$0" -p "$1" </dev/null 2>&1); then st=live
    else case $out in *"Connection refused"*) st=stale ;; *) st=unknown ;; esac
    fi
    r=- t=-
    if [ -s "$2" ] && read -r r < "$2"; then
      q=${r%% *}
      case $q in
        ''|*[!0-9]*) t=failed ;;
        *) if t=$(LC_ALL=C TZ=UTC "$p" -o lstart= -p "$q" 2>&1); then t=$(echo $t)
           elif [ -z "$t" ]; then t=gone; else t=failed; fi ;;
      esac
    fi
  }
  waiting() {
    case $m in
      record) [ "$r" = - ] && [ "$st" = live ] ;;
      dead)
        case $st in absent|stale) ;; *) return 0 ;; esac
        [ "$r" != - ] && [ "$t" != gone ] && { [ "$t" = failed ] || [ "$t" = "${r#* }" ]; } ;;
      *) return 1 ;;
    esac
  }
  while [ "$#" -ge 2 ]; do
    s=$1 f=$2; shift 2
    look "$s" "$f"
    while waiting && timer; do "$z" 0.1; look "$s" "$f"; done
    printf '%s\t%s\t%s\n' "$st" "$r" "$t"
  done
  ! timer || kill "$d" 2>/dev/null
  exit 0
  """
  # $1 ps, $2 the pid, $3 its start time, $4 dtach, $5 the socket, $6 the input. The same check
  # as a signal's, in the process that pushes, so input never reaches a program put in its place.
  @push ~S"""
  t=$(LC_ALL=C TZ=UTC "$1" -o lstart= -p "$2") || { echo gone; exit 0; }
  [ "$(echo $t)" = "$3" ] || { echo gone; exit 0; }
  out=$(printf '%s' "$6" | "$4" -p "$5" 2>&1) && { echo sent; exit 0; }
  case $out in *"Connection refused"*|*"No such file"*) echo gone ;; *) echo "unknown $out" ;; esac
  """
  # $1 ps, $2 kill, $3 the pid, $4 its start time, $5 the signal, $6 the target (the pid, or
  # the group as -pid). The check and the signal in one process. When a group's signal fails,
  # its members are listed: macOS answers EPERM, not ESRCH, for a group whose members are all
  # zombies not yet reaped, and such a group never runs again, so it is gone. A failure while any
  # member is not a zombie, or a list that failed, is printed as it came.
  @signal ~S"""
  t=$(LC_ALL=C TZ=UTC "$1" -o lstart= -p "$3") || { echo gone; exit 0; }
  [ "$(echo $t)" = "$4" ] || { echo gone; exit 0; }
  out=$("$2" -"$5" -- "$6" 2>&1) && { echo sent; exit 0; }
  case $6 in -*) ;; *) printf '%s\n' "$out"; exit 1 ;; esac
  m=$(LC_ALL=C "$1" -A -o pgid=,stat= 2>&1) || { printf '%s\n' "$out"; exit 1; }
  live=$(printf '%s\n' "$m" | while read -r g s; do
    if [ "$g" = "$3" ]; then case $s in Z*) ;; *) echo live; break ;; esac; fi
  done)
  [ -z "$live" ] && { echo gone; exit 0; }
  printf '%s\n' "$out"; exit 1
  """
  # The wait between reads while an end waits for the program to be dead.
  @round 100
  # How long, after KILL, an end waits for the socket to read dead. Like the grace, it is a
  # deadline that lives in one call, so it is taken from the monotonic clock (F-218).
  @kill_wait 2_000

  @doc """
  The records of `holder`'s programs, with the host's `ps`, `kill` and `sleep` from `programs`.
  Nothing runs.
  """
  @spec new(Programs.t(), Holder.t()) :: {:ok, t} | {:refused, {:no_program, list}}
  def new(%Programs{} = programs, %Holder{} = holder) do
    with {:ok, paths} <- Programs.take(programs, [:ps, :kill, :sleep]),
         do: {:ok, struct!(__MODULE__, [holder: holder] ++ Map.to_list(paths))}
  end

  @doc "The file of `name`'s record: `<dir>/<name>.pid`."
  @spec record_path(t, String.t()) :: String.t()
  def record_path(%__MODULE__{holder: h}, name), do: Path.join(h.dir, name <> ".pid")

  @doc """
  Holds `argv` as `CodingAgentFramework.Holder.hold/4` does, under the wrapper that writes its
  record first. An earlier hold's record is removed first, only while its socket is not live
  (a live one is refused, as `Holder.hold/4` refuses it). Answers what `Holder.hold/4` answers.
  """
  @spec hold(t, String.t(), [String.t()], keyword) ::
          {:ok, String.t()} | {:refused, term} | {:unknown, term}
  def hold(%__MODULE__{holder: h} = p, name, argv, opts \\ []) do
    with {:ok, _} <- Holder.hold_argv(h, name, argv, []),
         socket = Path.join(h.dir, name <> ".sock"),
         :ok <- clear(p, name, socket) do
      Holder.hold(
        h,
        name,
        [h.sh, "-c", @wrapper, "caf-held", record_path(p, name), p.ps | argv],
        opts
      )
    end
  end

  defp clear(%{holder: h} = p, name, socket) do
    case Shell.run(h.host, h.sh, ["-c", @clear, h.dtach, socket, record_path(p, name), h.rm],
           timeout: h.timeout
         ) do
      {:ok, %{status: 0, output: "cleared\n"}} -> :ok
      {:ok, %{status: 0, output: "live\n"}} -> {:refused, {:live, name}}
      other -> {:unknown, {:clear, other}}
    end
  end

  @doc """
  Reads each of `names` in one shell on the host: `{:ok, %{name => reading}}`. Option
  `:wait` (ms, default 0): how long a name whose socket lives waits for its record, as just
  after a hold, when the wrapper may not have run yet. The wait is one deadline for all the
  names, by the host's clock: a name is read again 0.1 s apart until it is met or the wait has
  passed, so the answer comes within one read of the wait. Option `:timeout` (ms) bounds the
  shell, by default the holder's plus the wait.
  """
  @spec read(t, [String.t()], keyword) :: {:ok, %{String.t() => reading}} | {:unknown, term}
  def read(%__MODULE__{} = p, names, opts \\ []) do
    wait = Keyword.get(opts, :wait, 0)
    run_read(p, names, if(wait > 0, do: "record", else: "none"), wait, opts)
  end

  @doc """
  Waits on the host, in one shell, until `name`'s program reads dead or `wait` ms pass by the
  host's clock (as `read/3`'s wait), and answers the last reading: `{:ok, reading}`, dead or not
  (`dead?/1` says which), or `{:unknown, reason}`. A job's end is waited for this way, so a host reached over ssh is asked once, not
  every few hundred ms.
  """
  @spec await_dead(t, String.t(), non_neg_integer) :: {:ok, reading} | {:unknown, term}
  def await_dead(%__MODULE__{} = p, name, wait) do
    with {:ok, %{^name => reading}} <- run_read(p, [name], "dead", wait, []), do: {:ok, reading}
  end

  defp run_read(%{holder: h} = p, names, mode, wait, opts) do
    timeout = Keyword.get(opts, :timeout, h.timeout + wait)
    pairs = Enum.flat_map(names, &[Path.join(h.dir, &1 <> ".sock"), record_path(p, &1)])
    mode = if wait > 0, do: mode, else: "none"
    secs = :erlang.float_to_binary(max(wait, 0) / 1000, decimals: 3)
    args = ["-c", @read, h.dtach, p.ps, p.sleep, secs, mode | pairs]

    case Shell.run(h.host, h.sh, args, timeout: timeout) do
      {:ok, %{status: 0, output: out}} -> readings(names, String.split(out, "\n", trim: true))
      other -> {:unknown, {:read, other}}
    end
  end

  @doc """
  Writes `input` to `name`'s terminal (`dtach -p`), only while the process with `record`'s pid
  and start time runs: the check and the write run in one shell. Answers `{:ok, :sent}`, `{:ok,
  :gone}` when the program is not the record's and nothing went in, or `{:unknown, reason}` when
  some of it may have. Option: `:timeout` (ms).
  """
  @spec push(t, String.t(), held, String.t(), keyword) :: {:ok, :sent | :gone} | {:unknown, term}
  def push(%__MODULE__{holder: h} = p, name, %{pid: pid, start: start}, input, opts \\ []) do
    socket = Path.join(h.dir, name <> ".sock")
    args = ["-c", @push, "caf-push", p.ps, "#{pid}", normal(start), h.dtach, socket, input]

    case Shell.run(h.host, h.sh, args, timeout: Keyword.get(opts, :timeout, h.timeout)) do
      {:ok, %{status: 0, output: "sent\n"}} -> {:ok, :sent}
      {:ok, %{status: 0, output: "gone\n"}} -> {:ok, :gone}
      other -> {:unknown, {:push, other}}
    end
  end

  defp readings(names, lines) when length(names) == length(lines) do
    {:ok,
     names
     |> Enum.zip(lines)
     |> Map.new(fn {name, line} -> {name, reading(name, String.split(line, "\t", parts: 3))} end)}
  end

  defp readings(_names, lines), do: {:unknown, {:read, lines}}

  defp reading(name, [socket, recorded, ps]) do
    record = parse(recorded)

    %{
      name: name,
      socket: socket_state(socket),
      record: record,
      process: process(record, recorded, ps)
    }
  end

  defp reading(name, _), do: %{name: name, socket: :unknown, record: nil, process: :unknown}

  defp socket_state("live"), do: :live
  defp socket_state("stale"), do: :stale
  defp socket_state("absent"), do: :absent
  defp socket_state(_), do: :unknown

  defp parse(recorded) do
    with [pid, start] <- String.split(recorded, " ", parts: 2),
         {pid, ""} when pid > 0 <- Integer.parse(pid),
         start when start != "" <- normal(start) do
      %{pid: pid, start: start}
    else
      _ -> nil
    end
  end

  defp process(nil, "-", _ps), do: :none
  defp process(nil, _recorded, _ps), do: :unknown
  defp process(_record, _recorded, "gone"), do: :gone
  defp process(_record, _recorded, "failed"), do: :unknown

  defp process(%{start: start}, _recorded, ps),
    do: if(normal(ps) == start, do: :live, else: :replaced)

  @doc """
  Whether a reading says the program is dead: its process not live (gone, replaced, or no
  record) and its socket absent or stale. A part of the reading that failed is not dead.
  """
  @spec dead?(map) :: boolean
  def dead?(%{socket: socket, process: process}),
    do: socket in [:absent, :stale] and process in [:gone, :replaced, :none]

  @doc """
  Sends `signal` (`"TERM"` or `"KILL"`) to the process with `record`'s pid and start time, or,
  with `group: true`, to the group it leads (a held program leads its own: dtach's child starts
  a session). Answers `{:ok, :sent}`, `{:ok, :gone}` when no process has that pid and start time
  (nothing was sent), or `{:unknown, reason}`. A group's signal that fails while every member of
  the group is a zombie not yet reaped, or none is left, is `{:ok, :gone}` too: macOS answers
  EPERM for such a group, and nothing in it can run again. It stays `{:unknown, reason}` while
  any member is not a zombie.
  """
  @spec signal(t, held, String.t(), keyword) :: {:ok, :sent | :gone} | {:unknown, term}
  def signal(%__MODULE__{holder: h} = p, %{pid: pid, start: start}, signal, opts \\ [])
      when signal in ["TERM", "KILL"] do
    target = if Keyword.get(opts, :group, false), do: "-#{pid}", else: "#{pid}"
    args = ["-c", @signal, "caf-signal", p.ps, p.kill, "#{pid}", normal(start), signal, target]

    case Shell.run(h.host, h.sh, args, timeout: Keyword.get(opts, :timeout, h.timeout)) do
      {:ok, %{status: 0, output: "sent\n"}} -> {:ok, :sent}
      {:ok, %{status: 0, output: "gone\n"}} -> {:ok, :gone}
      other -> {:unknown, {:signal, other}}
    end
  end

  @doc """
  Ends `name`'s program by `record` (`nil`: nothing to signal, the socket alone is waited on):
  TERM, a wait until it is dead within `grace` ms, then KILL and a short wait. Options: `:group`
  as for `signal/4`. Answers `{:ok, :ended}` once it reads dead, or `{:unknown, reason}`:
  `{:not_dead, reading}` when it still lives after KILL, or a signal or read that failed.
  """
  @spec end_held(t, String.t(), held | nil, non_neg_integer, keyword) ::
          {:ok, :ended} | {:unknown, term}
  def end_held(%__MODULE__{} = p, name, record, grace, opts \\ []) do
    with :ok <- send_signal(p, record, "TERM", opts) do
      case dead_by(p, name, now() + grace) do
        {:unknown, {:not_dead, _}} ->
          with :ok <- send_signal(p, record, "KILL", opts),
               do: dead_by(p, name, now() + @kill_wait)

        done ->
          done
      end
    end
  end

  defp send_signal(_p, nil, _signal, _opts), do: :ok

  defp send_signal(p, record, signal, opts) do
    case signal(p, record, signal, opts) do
      {:ok, _sent_or_gone} -> :ok
      other -> other
    end
  end

  @doc """
  Waits until `name`'s program reads dead, reading again every 100 ms until `deadline`
  (`System.monotonic_time(:millisecond)`, F-218: a deadline that lives in one call is not moved
  by a step of the OS clock). Answers `{:ok, :ended}`, or `{:unknown, {:not_dead, last}}` at the deadline, where
  `last` is the last reading or the read that failed.
  """
  @spec dead_by(t, String.t(), integer) :: {:ok, :ended} | {:unknown, term}
  def dead_by(%__MODULE__{} = p, name, deadline) do
    read = read(p, [name])

    case read do
      {:ok, %{^name => reading}} ->
        if dead?(reading), do: {:ok, :ended}, else: again(p, name, deadline, reading)

      other ->
        again(p, name, deadline, other)
    end
  end

  defp again(p, name, deadline, last) do
    if now() >= deadline do
      {:unknown, {:not_dead, last}}
    else
      pause(min(@round, deadline - now()))
      dead_by(p, name, deadline)
    end
  end

  @doc """
  Whether each `{pid, start}` still runs, by its pid and start time, with one `ps` on `host`:
  `:live`, `:replaced` (`ps` lists the pid with another start time: it was reused), `:gone` (a
  `ps` that ran cleanly does not list it), or `:unknown` (`ps` failed or answered something
  unreadable, or no start time is known). A failed `ps` under load never counts a live process
  as gone. Options, all required: `:env` and `:ps` (the host's programs; `ps` runs under `env
  LC_ALL=C TZ=UTC`) and `:timeout` (ms).
  """
  @spec liveness(Host.t(), [{pos_integer, String.t() | nil}], keyword) :: %{
          {pos_integer, String.t() | nil} => :live | :replaced | :gone | :unknown
        }
  def liveness(_host, [], _opts), do: %{}

  def liveness(%Host{} = host, procs, opts) do
    pids = procs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(",")
    args = ["LC_ALL=C", "TZ=UTC", Keyword.fetch!(opts, :ps), "-o", "pid=,lstart=", "-p", pids]

    host
    |> Shell.run(Keyword.fetch!(opts, :env), args, timeout: Keyword.fetch!(opts, :timeout))
    |> judge(procs)
  end

  @doc """
  Judges each `{pid, start}` from a `Shell` outcome of the `ps` that `liveness/3` runs. Pure.

      iex> CodingAgentFramework.Holder.Process.judge(
      ...>   {:ok, %{status: 0, output: "  7 Sat Nov 14 09:00:00 2026\\n  9 Sat Nov 14 09:00:00 2026\\n"}},
      ...>   [{7, "Sat Nov 14 09:00:00 2026"}, {8, "Sat Nov 14 09:00:00 2026"}, {9, nil}])
      %{{7, "Sat Nov 14 09:00:00 2026"} => :live, {8, "Sat Nov 14 09:00:00 2026"} => :gone, {9, nil} => :unknown}
  """
  @spec judge(Shell.outcome(), [{pos_integer, String.t() | nil}]) :: %{
          {pos_integer, String.t() | nil} => :live | :replaced | :gone | :unknown
        }
  def judge(outcome, procs) do
    listed =
      case outcome do
        {:ok, %{status: 0, output: out}} -> listed(out)
        # ps exits 1 with no output when none of the pids exists.
        {:ok, %{status: 1, output: ""}} -> {:ok, %{}}
        _ -> :unknown
      end

    Map.new(procs, fn {pid, start} -> {{pid, start}, judge_one(listed, pid, start)} end)
  end

  defp judge_one(:unknown, _, _), do: :unknown
  defp judge_one({:ok, listed}, pid, start), do: judge_one(Map.get(listed, pid), start)

  defp judge_one(nil, _), do: :gone
  defp judge_one(_, nil), do: :unknown
  defp judge_one(listed, start), do: if(listed == normal(start), do: :live, else: :replaced)

  defp listed(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      with [pid, start] <- String.split(String.trim(line), ~r/\s+/, parts: 2),
           {pid, ""} <- Integer.parse(pid) do
        {:cont, {:ok, Map.put(acc, pid, normal(start))}}
      else
        _ -> {:halt, :unknown}
      end
    end)
  end

  @doc "A start time with its runs of whitespace made one space, trimmed."
  @spec normal(String.t()) :: String.t()
  def normal(start), do: start |> String.split() |> Enum.join(" ")

  defp pause(ms) when ms > 0 do
    receive do
    after
      ms -> :ok
    end
  end

  defp pause(_), do: :ok

  defp now, do: System.monotonic_time(:millisecond)
end
