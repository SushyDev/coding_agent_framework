defmodule CodingAgentFramework.Runs do
  @moduledoc """
  Heavy commands taken transparently (`docs/design.md`, "Intercepted, not added"; F-171): an
  agent runs its own `Bash`, and a call the app lists as heavy runs under a lease from the
  `Scheduler`, with nothing new for the agent to learn. `model/tla/Schedule.tla`'s shape
  `Native` models the lease.

  **The rewrite.** The app's list of heavy commands is data: each a pattern (a `Regex`, or a
  string compiled as one) matched anywhere in the command, and the class its lease takes
  (`:heavy`, `:builder` or `:landing`); the first that matches decides. `pre_tool_use/2` is the
  `PreToolUse` policy: the app's own callback answers first, and when it lets a `Bash` call run
  as it is (`:pass` or `:allow`, or a correction of its input) and the command matches, the
  call is corrected with `updatedInput` into

      '<home>/bin/caf-run' <class> <tool_use_id> <agent> -- '<command>'

  Every other field of the input stays, `run_in_background` and `timeout` included, so Claude
  Code's own background command and its notification work as before. A deny, an ask, or a call
  whose agent is not known is the app's answer, unchanged. `updatedInput` goes with an allow, so
  the call runs without Claude Code's permission prompt: the app lists only commands its agents
  may run. A command already under the wrapper is not wrapped again.

  **The wrapper** (`prepare/5` writes it, `<home>/bin/caf-run`) asks for the lease over the
  intake's port (`CodingAgentFramework.Runs.Plug`), the tool call's id as the request id, so a
  retry takes no second slot. While queued it prints one line, `caf-run: queued (position n)`.
  Granted, it `exec`s the command in `sh -c`: the process that asked becomes the command, so
  its output is the command's, its exit code is the command's, and the lease's holder is that
  process, `{"run", "<pid> <start time>"}`. Refused, it prints one line with the whole reason
  (for pressure its level and the reading that set it, F-276) and the retry time and exits 75,
  and nothing ran. A request pressure bars waits in the queue, its queued line saying so.

  **Its wait** (F-292): `caf-run --wait <seconds> <class> …`, or `CAF_RUN_WAIT=<seconds>` in its
  environment (the flag wins), whole seconds from 1 to 99 999 999; anything else exits 64. It
  is the request's caller deadline: the lease is waited for until the class's `max_wait` or
  this wait, whichever ends first, and at this wait it is refused `caller_gone` and exits 75.
  So a class whose `max_wait` is longer than the plug's default wait keeps a wrapper's place
  for as long as the wrapper says, and never past `Runs.Plug`'s `max_wait:` (an hour by
  default), over which it is refused `long_wait` at once. Without one, the plug's `:wait`
  is the wait. One ask's bound is its wait and 5 s.

  With no answer (the framework down), or an `unknown` one (no `Scheduler`, as while the app
  restarts, or one that did not answer the plug in time), it asks again under the same id, once
  a second, until its no-answer bound has passed by the clock since the first such ask: its
  wait when it has one, else 30 s (`prepare/5`'s `:unanswered`). Then it exits 75 and says why
  in one line, and nothing ran (F-302, the operator's rule): a heavy command waits for its lease,
  and never runs without one because the framework was slow. Before F-302 it ran the command
  unleased, so every waiting wrapper on the host started at once when the `Scheduler` was slow
  or restarting, and the load that made it slow rose further. `CAF_RUN_UNLEASED=1` in the
  wrapper's environment keeps the old way for a caller that asks for it: the command then runs
  without a lease at that bound, and the wrapper says so.

  **Each ask is bounded too** (F-218). A connection the intake accepts and then stalls without
  closing would hold the wrapper, and so the agent's command. The ask's `--max-time` is the
  plug's `:wait` plus 5 s (`prepare/5`'s `:wait`, `wait/0` by default, as the plug's): a queued
  ask is answered `unknown no_answer` at `:wait`, so only a stalled one passes it. An ask cut
  at its bound is no answer, the path above: it counts as the first with none, and the wrapper
  asks while the no-answer bound lasts. So however the intake fails, the wrapper ends
  within the first ask's bound, the no-answer bound, the bound of the last ask begun
  within it and a second's pause: 1 241 s with the defaults.

  **On another host** (F-296, `model/tla/RemoteRun.tla`). An entry of the list may name a
  host, `%{match: ~r/\\bmix test\\b/, class: :heavy, host: "mac"}`; a match is rewritten
  with `--host 'mac'` before its class, and the wrapper sends its command and its directory
  too. The plug runs it there as a job (`Runs.Remote`), under that host's slot, in the agent's
  copy on that host, synced from its worktree first. While it runs, the wrapper prints
  `caf-run: started on mac (job run-<id>)` on its errors and the job's log on its output, line
  by line, and exits with the job's code once the last line came: 124 when the host ended the
  job at its timeout (`remote_timeout/0`, an hour), 69 when its end is unknown (the host away
  for the plug's bound, the stream cut), 75 when it was refused and nothing ran. A wrapper that
  got its `started` line never runs the command itself. One ask's bound is its wait, the
  job's timeout and 300 s.

  **Hosts in order** (F-304, `model/tla/RemotePlace.tla`). An entry may name several hosts,
  `host: ["mac", "ws"]`, the workstation by its config name; the rewrite names the first. The
  plug takes the first of them that `Hosts` does not hold away or lacking, from what it keeps,
  and when that host's placement is refused `host_away` before anything was sent, the next
  one, once. Either way the wrapper prints `caf-run: mac away; running on ws` on its errors;
  on the workstation it then runs the command itself under that host's slot, as any local
  heavy command. A job that was sent is never moved.

  **The end.** The lease's owner is the process itself (`state/2`, for the `Scheduler`'s
  `holders:`): live while that pid runs with that start time, ended once it does not, read by
  `ps` (`Holder.Process.liveness/3`) on the `Scheduler`'s interval and after its restart. So
  the lease is released once on every end: an exit, a crash, a kill while queued or running.
  The command runs in the wrapper's process, so a command that left a process behind it after
  its own end leaves that process unleased.

      {:ok, runs} = Runs.new("/srv/caf", programs, [%{match: ~r/\\bmix test\\b/, class: :heavy}])
      :ok = Runs.prepare(runs, programs, 4790, secret)
      Intake.start_link(..., pre_tool_use: Runs.pre_tool_use(runs, &MyApp.pre_tool_use/1))
      Scheduler.start_link(..., holders: %{"run" => &Runs.state(runs, &1)})
  """

  alias CodingAgentFramework.{Holder, Programs}

  @enforce_keys [:home, :heavy, :host, :env, :ps]
  defstruct [:home, :heavy, :host, :env, :ps]

  @type t :: %__MODULE__{}
  @type class :: :heavy | :builder | :landing

  @classes [:heavy, :builder, :landing]
  @id ~r/\A[A-Za-z0-9_-]{1,128}\z/
  @agent ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  # How long the owner's `ps` may take.
  @ps_timeout 5_000
  # The plug's `:wait` by default, and how long past it one ask may run (F-218): the slack is for
  # the plug's own end of a queued wait to reach the wrapper.
  @wait 600_000
  @ask_slack 5_000
  @max_wait 3_600_000
  @remote_timeout 3_600_000
  # How long past its wait and its job's timeout one ask for a run on another host may run: the
  # copy's sync and lock wait, the start, the host's own end and the log's last lines.
  @remote_slack 300_000

  # $0 caf-run; the paths, the curl config, the URL, the no-answer bound and one ask's bound in
  # seconds are set above it by `prepare/5`. The body goes as form fields curl encodes. A queued
  # line is printed as it comes; the last line is the answer. `exec` keeps the pid, so the
  # process that asked is the command.
  #
  # The no-answer bound is by the clock, not a count of asks (F-217): the first ask with no
  # answer starts one sleep of the whole bound beside the asks, and the wrapper asks again only
  # while it lives. A count of one-second sleeps overshoots, since each wakes late under load.
  # The timer is this shell's own child, so its pid is no other program's until this shell
  # reaps it; it is ended only while `kill -0` finds it, before the command runs.
  #
  # One ask's bound is curl's `--max-time` (F-218). A cut ask prints no answer, so it takes the
  # path of an ask nobody answered.
  @wrapper ~S"""
  exec 3>&1
  w=${CAF_RUN_WAIT-} host= unleased=${CAF_RUN_UNLEASED-}
  while [ "$#" -ge 2 ]; do
    case $1 in
      --wait) w=$2; shift 2 ;;
      --host) host=$2; shift 2 ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 5 ] && [ "$4" = -- ] || {
    echo 'caf-run: usage: caf-run [--wait <seconds>] [--host <host>] <class> <id> <agent> -- <command>' >&2
    exit 64; }
  case $w in
    '') ;;
    0*|*[!0-9]*|?????????*)
      echo 'caf-run: a wait (--wait or CAF_RUN_WAIT) is whole seconds, 1 to 99999999' >&2
      exit 64 ;;
    *) asked=$((w + 5)); [ "$w" -le "${unanswered%.*}" ] || unanswered=$w ;;
  esac
  class=$1 id=$2 agent=$3 cmd=$5
  if [ -n "$host" ]; then
    asked=$((${w:-$waits} + 5 + remote))
    set -- --data-urlencode "host=$host" --data-urlencode "cmd=$cmd" --data-urlencode "cwd=$PWD"
  else
    set --
  fi
  start=$(LC_ALL=C TZ=UTC "$ps" -o lstart= -p $$) || start=
  again=0 d=
  timer() { [ -n "$d" ] && kill -0 "$d" 2>/dev/null; }
  run() { ! timer || kill "$d" 2>/dev/null; exec "$sh" -c "$cmd" 3>&-; }
  # F-302: past the no-answer bound, nothing runs unless the caller asked for it.
  closed() {
    if [ "$unleased" = 1 ]; then
      printf 'caf-run: no lease (%s); the command runs without one\n' "$1" >&2
      run
    fi
    ! timer || kill "$d" 2>/dev/null
    printf 'caf-run: not run: no lease (%s); try again\n' "$1" >&2
    exit 75
  }
  why='the framework did not answer'
  while :; do
    last=$("$curl" -sN --max-time "$asked" -K "$cfg" --data-urlencode "class=$class" \
        --data-urlencode "id=$id" --data-urlencode "agent=$agent" --data-urlencode "pid=$$" \
        --data-urlencode "start=$start" --data-urlencode "again=$again" --data-urlencode "wait=$w" \
        "$@" "$url" 2>/dev/null |
      { s=
        while IFS= read -r line; do
          case $line in
            queued*) printf 'caf-run: %s\n' "$line" >&2 ;;
            'note '*) printf 'caf-run: %s\n' "${line#note }" >&2 ;;
            'o '*) printf '%s\n' "${line#o }" >&3 ;;
            'p '*) printf '%s' "${line#p }" >&3 ;;
            started*) s=1; printf 'caf-run: %s\n' "$line" >&2 ;;
            granted*|refused*|unknown*|ended*) printf '%s\n' "$line"; exit 0 ;;
          esac
        done
        [ -z "$s" ] || echo cut; })
    case $last in
      granted*) run ;;
      ended*)
        set -- $last
        case $2 in
          exit) exit "$3" ;;
          timeout)
            printf 'caf-run: the job on %s passed its timeout, and the host ended it\n' "$host" >&2
            exit 124 ;;
        esac
        printf 'caf-run: the run on %s has no end (%s); its job may still run there\n' \
          "$host" "${last#ended unknown }" >&2
        exit 69 ;;
      cut)
        printf 'caf-run: the run on %s was cut off; its job may still run there\n' "$host" >&2
        exit 69 ;;
      refused*)
        ! timer || kill "$d" 2>/dev/null
        set -- $last
        why=$2 at=$3
        shift 3
        [ "$#" -eq 0 ] || why="$why $*"
        printf 'caf-run: not run: the lease was refused (%s); try again after %s\n' "$why" "$at" >&2
        exit 75 ;;
      unknown*) why=${last#unknown } ;;
      *) why='the framework did not answer' ;;
    esac
    [ -n "$d" ] || { "$sleep" "$unanswered" </dev/null >/dev/null 2>&1 & d=$!; }
    timer || closed "$why"
    again=1
    "$sleep" 1
  done
  """

  @doc """
  The policy's data: the home (where `prepare/5` writes the wrapper), the app's heavy
  commands, and the workstation's `ps` and `env` (`programs`) for `state/2`. Answers
  `{:ok, runs}`, or `{:refused, {:bad, :heavy}}` for a list out of shape.

      iex> programs = CodingAgentFramework.TestHost.programs()
      iex> {:ok, runs} = CodingAgentFramework.Runs.new("/srv/caf", programs,
      ...>   [%{match: "mix test", class: :heavy}])
      iex> CodingAgentFramework.Runs.class(runs, "cd apps/web && mix test --seed 0")
      {:ok, :heavy}
      iex> CodingAgentFramework.Runs.new("/srv/caf", programs, [%{match: "(", class: :heavy}])
      {:refused, {:bad, :heavy}}
  """
  @spec new(String.t(), Programs.t(), [%{match: Regex.t() | String.t(), class: class}]) ::
          {:ok, t} | {:refused, term}
  def new(home, %Programs{} = programs, heavy) do
    with {:ok, %{ps: ps, env: env}} <- Programs.take(programs, [:ps, :env]),
         {:ok, heavy} <- heavy(heavy) do
      {:ok, %__MODULE__{home: home, heavy: heavy, host: programs.host, env: env, ps: ps}}
    end
  end

  @doc """
  Checks the app's list of heavy commands, each `%{match: regex_or_string, class: class}` and
  optionally `host: name`, the host a match runs on (F-296), or `host: [name, …]`, hosts in
  order of preference, each named once (F-304): `{:ok, [{regex, class, hosts}]}`, `hosts` a
  list, or nil for none, or `{:refused, {:bad, :heavy}}` for an entry out of shape or a string
  that is not a regular expression. `new/3` runs it; a config checks it, and each host's name,
  before start.

      iex> {:ok, [{r, :landing, nil}, {_, :heavy, ["mac"]}, {_, :heavy, ["mac", "ws"]}]} =
      ...>   CodingAgentFramework.Runs.heavy([%{match: "^make", class: :landing},
      ...>     %{match: "mix test", class: :heavy, host: "mac"},
      ...>     %{match: "mix dialyzer", class: :heavy, host: ["mac", "ws"]}])
      iex> Regex.match?(r, "make all")
      true
      iex> CodingAgentFramework.Runs.heavy([%{match: "x", class: :heavy, host: ["mac", "mac"]}])
      {:refused, {:bad, :heavy}}
  """
  @spec heavy(term) ::
          {:ok, [{Regex.t(), class, [String.t()] | nil}]} | {:refused, {:bad, :heavy}}
  def heavy(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case entry(entry) do
        {:ok, e} -> {:cont, {:ok, acc ++ [e]}}
        :bad -> {:halt, {:refused, {:bad, :heavy}}}
      end
    end)
  end

  def heavy(_), do: {:refused, {:bad, :heavy}}

  defp entry(%{match: match, class: class} = e) when class in @classes do
    case {regex(match), hosts(Map.get(e, :host))} do
      {:bad, _} -> :bad
      {_, :bad} -> :bad
      {r, hosts} -> {:ok, {r, class, hosts}}
    end
  end

  defp entry(_), do: :bad

  # One host, or several in order of preference, each named once (F-304).
  defp hosts(nil), do: nil
  defp hosts(host) when is_binary(host) and host != "", do: [host]

  defp hosts([_ | _] = hosts) do
    if Enum.all?(hosts, &(is_binary(&1) and &1 != "")) and Enum.uniq(hosts) == hosts,
      do: hosts,
      else: :bad
  end

  defp hosts(_), do: :bad

  defp regex(%Regex{} = r), do: r

  defp regex(text) when is_binary(text) do
    case Regex.compile(text) do
      {:ok, r} -> r
      _ -> :bad
    end
  end

  defp regex(_), do: :bad

  @doc """
  The wait, in ms, of a wrapper that names none, `Runs.Plug`'s `:wait` by default, and so the
  default of `prepare/5`'s `:wait`: 600 000, past every class's default `max_wait`.
  """
  @spec wait() :: pos_integer
  def wait, do: @wait

  @doc """
  The largest wait, in ms, `Runs.Plug` takes from a wrapper by default (`:max_wait`): 3 600 000,
  an hour. A longer one is refused `long_wait` at once.
  """
  @spec max_wait() :: pos_integer
  def max_wait, do: @max_wait

  @doc "The wrapper's path: `<home>/bin/caf-run`."
  @spec wrapper(t) :: String.t()
  def wrapper(%__MODULE__{home: home}), do: Path.join([home, "bin", "caf-run"])

  @doc "The class of the first heavy command `command` matches: `{:ok, class}` or `:none`."
  @spec class(t, String.t()) :: {:ok, class} | :none
  def class(%__MODULE__{} = runs, command) do
    case place(runs, command) do
      {:ok, class, _host} -> {:ok, class}
      :none -> :none
    end
  end

  @doc """
  The class and the host of the first heavy command `command` matches: `{:ok, class, host}`,
  `host` the entry's first, nil when the entry names none or its first is the workstation
  (`programs`' host), or `:none`. The rewrite names this host; the plug goes on from it to the
  entry's later hosts (`hosts/2`).

      iex> {:ok, runs} = CodingAgentFramework.Runs.new("/srv/caf",
      ...>   CodingAgentFramework.TestHost.programs(),
      ...>   [%{match: "mix test", class: :heavy, host: ["mac", "ws"]}])
      iex> CodingAgentFramework.Runs.place(runs, "mix test --seed 0")
      {:ok, :heavy, "mac"}
  """
  @spec place(t, String.t()) :: {:ok, class, String.t() | nil} | :none
  def place(%__MODULE__{host: own} = runs, command) do
    case hosts(runs, command) do
      {:ok, class, [host | _]} when host == own.name -> {:ok, class, nil}
      {:ok, class, [host | _]} -> {:ok, class, host}
      {:ok, class, nil} -> {:ok, class, nil}
      :none -> :none
    end
  end

  @doc """
  The class and every host, in order, of the first heavy command `command` matches: `{:ok,
  class, hosts}`, `hosts` the entry's list as the app wrote it (the workstation's name
  included) or nil, or `:none`. `Runs.Plug` reads it to choose where a run goes (F-304).

      iex> {:ok, runs} = CodingAgentFramework.Runs.new("/srv/caf",
      ...>   CodingAgentFramework.TestHost.programs(),
      ...>   [%{match: "mix test", class: :heavy, host: ["mac", "ws"]}])
      iex> CodingAgentFramework.Runs.hosts(runs, "mix test")
      {:ok, :heavy, ["mac", "ws"]}
  """
  @spec hosts(t, String.t()) :: {:ok, class, [String.t()] | nil} | :none
  def hosts(%__MODULE__{heavy: heavy}, command) do
    case Enum.find(heavy, fn {r, _, _} -> Regex.match?(r, command) end) do
      {_, class, hosts} -> {:ok, class, hosts}
      nil -> :none
    end
  end

  @doc """
  Where a run that no agent asks for works (F-304): the app's own heavy run, from its lander or
  a script, placed by the wrapper's directory `cwd`. `known` names the folders the framework
  knows, the ones its trust rule names (F-286): `checkouts`, each configured project's checkout
  path to its project, and `worktrees`, the framework's worktrees directory with `projects`,
  the configured projects' names. A `cwd` at or under a checkout answers `{:ok, %{project,
  name: "+checkout", worktree: checkout}}`, the copy's name one no agent can have; at or under
  `<worktrees>/<project>/<name>`, a directory there, `{:ok, %{project, name, worktree}}`, the
  copy an agent working there has. Any other folder is `{:refused, :no_worktree}`. The path is
  read as written, `..` taken out: a symlink is not followed.

      iex> known = %{checkouts: %{"/srv/caf/checkouts/app" => "app"},
      ...>   worktrees: "/srv/caf/worktrees", projects: ["app"]}
      iex> CodingAgentFramework.Runs.folder(known, "/srv/caf/checkouts/app/lib")
      {:ok, %{project: "app", name: "+checkout", worktree: "/srv/caf/checkouts/app"}}
      iex> CodingAgentFramework.Runs.folder(known, "/srv/caf/checkouts/app/../../etc")
      {:refused, :no_worktree}
  """
  @spec folder(map, String.t()) :: {:ok, map} | {:refused, :no_worktree}
  def folder(%{checkouts: checkouts, worktrees: root, projects: projects}, cwd)
      when is_binary(cwd) do
    cwd = Path.expand(cwd)

    checkout =
      Enum.find_value(checkouts, fn {path, project} ->
        path = Path.expand(path)
        if within?(cwd, path), do: %{project: project, name: "+checkout", worktree: path}
      end)

    cond do
      checkout -> {:ok, checkout}
      root != nil and within?(cwd, Path.expand(root)) -> worktree(root, cwd, projects)
      true -> {:refused, :no_worktree}
    end
  end

  def folder(_known, _cwd), do: {:refused, :no_worktree}

  defp within?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp worktree(root, cwd, projects) do
    root = Path.expand(root)

    with [project, name | _] <- Path.split(Path.relative_to(cwd, root)),
         true <- project in projects and name =~ @agent,
         path = Path.join([root, project, name]),
         true <- File.dir?(path) do
      {:ok, %{project: project, name: name, worktree: path}}
    else
      _ -> {:refused, :no_worktree}
    end
  end

  @doc """
  The timeout, in ms, of a heavy command run on another host, by default: 3 600 000, an hour.
  The host ends the job at it (`Jobs.run/6`'s `:timeout`), and the wrapper exits 124.
  """
  @spec remote_timeout() :: pos_integer
  def remote_timeout, do: @remote_timeout

  @doc """
  Writes the wrapper, `<home>/bin/caf-run` (mode 0700), with the workstation's `sh`, `curl`,
  `ps` and `sleep` from `programs` and the intake's `port`, and the curl config that carries
  the secret, `<home>/runs.curl` (mode 0600), so no secret is in a command line. Option
  `:unanswered` (ms, default 30 s): how long, from its first ask with no answer, the wrapper
  asks again before it exits 75 (F-302), or runs the command unleased under `CAF_RUN_UNLEASED=1`;
  a wrapper given a longer wait uses that. Option `:wait` (ms, `wait/0` by
  default): the `:wait` of the app's `Runs.Plug`, which one ask may run 5 s past (curl's
  `--max-time`); an ask cut there is no answer. An app that sets the plug's `:wait` sets it here
  too. Option `:remote_timeout` (ms, `remote_timeout/0` by default): the plug's, which bounds a
  run on another host's ask with its wait and 300 s. Answers `:ok`, `{:refused, reason}` for a
  program missing, a secret out of shape, or a bound that is not a positive integer
  (`:bad_unanswered`, `:bad_wait`, `:bad_remote_timeout`), or `{:unknown, reason}` when a write
  fails.
  """
  @spec prepare(t, Programs.t(), :inet.port_number(), String.t(), keyword) ::
          :ok | {:refused, term} | {:unknown, term}
  def prepare(%__MODULE__{home: home} = runs, programs, port, secret, opts \\ []) do
    cfg = Path.join(home, "runs.curl")
    unanswered = Keyword.get(opts, :unanswered, 30_000)
    wait = Keyword.get(opts, :wait, @wait)
    remote = Keyword.get(opts, :remote_timeout, @remote_timeout)

    with true <- secret =~ ~r/\A[A-Za-z0-9._~+\/=-]{1,256}\z/ or {:refused, :bad_secret},
         true <- (is_integer(unanswered) and unanswered > 0) or {:refused, :bad_unanswered},
         true <- (is_integer(wait) and wait > 0) or {:refused, :bad_wait},
         true <- (is_integer(remote) and remote > 0) or {:refused, :bad_remote_timeout},
         {:ok, p} <- Programs.take(programs, [:sh, :curl, :ps, :sleep]),
         :ok <- write(cfg, ~s(header = "x-caf-secret: #{secret}"\n), 0o600) do
      secs = &:erlang.float_to_binary(&1 / 1000, decimals: 3)

      vars =
        [
          sh: p.sh,
          curl: p.curl,
          ps: p.ps,
          sleep: p.sleep,
          cfg: cfg,
          unanswered: secs.(unanswered),
          asked: secs.(wait + @ask_slack),
          # Whole seconds, for the shell's arithmetic: a run on another host (F-296).
          waits: "#{div(wait + 999, 1000)}",
          remote: "#{div(remote + @remote_slack + 999, 1000)}"
        ]
        |> Enum.map_join("", fn {k, v} -> "#{k}=#{sh_quote(v)}\n" end)

      script =
        "#!#{p.sh}\n# caf-run, written by the framework at its start: a heavy command under a " <>
          "lease (F-171).\n" <> vars <> "url=http://127.0.0.1:#{port}/runs\n" <> @wrapper

      write(wrapper(runs), script, 0o700)
    end
  end

  # Written whole under another name, then renamed, so a wrapper running now never reads half.
  defp write(path, text, mode) do
    tmp = "#{path}.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, ""),
         :ok <- File.chmod(tmp, mode),
         :ok <- File.write(tmp, text),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:unknown, {:write, path, reason}}
    end
  end

  @doc """
  The framework's `PreToolUse` policy for heavy commands, for `Intake`'s `pre_tool_use:`:
  `then` (the app's callback, or nil) answers first, and the rewrite applies to its answer
  (see the module's doc). A callback that raises is taken as `:pass`.

      iex> {:ok, runs} = CodingAgentFramework.Runs.new("/srv/caf",
      ...>   CodingAgentFramework.TestHost.programs(), [%{match: "^make", class: :builder}])
      iex> pre = CodingAgentFramework.Runs.pre_tool_use(runs, nil)
      iex> {:allow, updated_input: %{"command" => c}} = pre.(%{agent: "fix-1",
      ...>   tool_name: "Bash", tool_use_id: "toolu_1", tool_input: %{"command" => "make it"}})
      iex> c
      "'/srv/caf/bin/caf-run' builder 'toolu_1' 'fix-1' -- 'make it'"
  """
  @spec pre_tool_use(t, (map -> term) | nil) :: (map -> term)
  def pre_tool_use(%__MODULE__{} = runs, then) do
    fn event ->
      answer =
        try do
          if then, do: then.(event), else: :pass
        rescue
          _ -> :pass
        end

      rewrite(runs, event, answer)
    end
  end

  defp rewrite(runs, event, answer) do
    with {:ok, input, context} <- runs_as_is(answer, event),
         %{tool_name: "Bash", tool_use_id: id, agent: agent} <- event,
         %{"command" => command} when is_binary(command) <- input,
         true <- is_binary(id) and id =~ @id and is_binary(agent) and agent =~ @agent,
         false <- String.starts_with?(command, sh_quote(wrapper(runs))),
         {:ok, class, host} <- place(runs, command) do
      on = if host, do: [:"--host", host], else: []
      line = Enum.map_join([wrapper(runs)] ++ on ++ [class, id, agent], " ", &sh_quote/1)
      line = line <> " -- "
      {:allow, [updated_input: %{input | "command" => line <> sh_quote(command)}] ++ context}
    else
      _ -> answer
    end
  end

  # The input the call would run with, when the app lets it run as it is or corrects it.
  defp runs_as_is(answer, event) when answer in [:pass, :allow], do: {:ok, event.tool_input, []}

  defp runs_as_is({:allow, opts}, event) when is_list(opts) do
    if Keyword.keyword?(opts),
      do:
        {:ok, opts[:updated_input] || event.tool_input, Keyword.take(opts, [:additional_context])},
      else: :no
  end

  defp runs_as_is(_answer, _event), do: :no

  # A class is quoted as any word is, which leaves it as it is.
  defp sh_quote(word) when is_atom(word), do: Atom.to_string(word)
  defp sh_quote(word), do: "'" <> String.replace(word, "'", ~S('\'')) <> "'"

  @doc """
  The owner's answer for a lease whose holder is `{"run", key}`, `key` the wrapper's `"<pid>
  <start time>"`: `:live` while that process runs, `:ended` once its pid is gone or another
  program's, `{:unknown, reason}` when `ps` cannot say. For the `Scheduler`'s `holders:`.
  """
  @spec state(t, String.t()) :: :live | :ended | {:unknown, term}
  def state(%__MODULE__{} = runs, key) do
    with [pid, start] <- String.split(key, " ", parts: 2),
         {pid, ""} when pid > 0 <- Integer.parse(pid),
         start when start != "" <- Holder.Process.normal(start) do
      opts = [env: runs.env, ps: runs.ps, timeout: @ps_timeout]

      case Holder.Process.liveness(runs.host, [{pid, start}], opts) do
        %{{^pid, ^start} => :live} -> :live
        %{{^pid, ^start} => gone} when gone in [:gone, :replaced] -> :ended
        _ -> {:unknown, :ps}
      end
    else
      _ -> {:unknown, {:bad_key, key}}
    end
  end

  @doc """
  A wrapper's request, from its form fields: `{:ok, %{class, id, agent, holder, again, wait,
  host, command, cwd}}`, or `{:refused, {:bad, field}}`. The holder is `"<pid> <start time>"`,
  the start time with its runs of spaces made one. `wait` is the wrapper's own wait in ms (its
  field in whole seconds, 1 to 99 999 999), or nil when it names none. `host` is the one its
  `--host` names (F-296), with the command (`cmd`) and the wrapper's absolute directory (`cwd`);
  each nil for a run on the plug's own host.

      iex> CodingAgentFramework.Runs.ask(%{"class" => "heavy", "id" => "toolu_1",
      ...>   "agent" => "fix-1", "pid" => "42", "start" => "Thu Nov 19  01:00:00 2026",
      ...>   "again" => "0"})
      {:ok, %{class: :heavy, id: "toolu_1", agent: "fix-1",
        holder: "42 Thu Nov 19 01:00:00 2026", again: false, wait: nil, host: nil,
        command: nil, cwd: nil}}
  """
  @spec ask(map) :: {:ok, map} | {:refused, {:bad, atom}}
  def ask(fields) do
    start = Holder.Process.normal(fields["start"] || "")

    cond do
      fields["class"] not in Enum.map(@classes, &Atom.to_string/1) ->
        {:refused, {:bad, :class}}

      not (is_binary(fields["id"]) and fields["id"] =~ @id) ->
        {:refused, {:bad, :id}}

      not (is_binary(fields["agent"]) and fields["agent"] =~ @agent) ->
        {:refused, {:bad, :agent}}

      not match?({n, ""} when n > 0, Integer.parse(fields["pid"] || "")) ->
        {:refused, {:bad, :pid}}

      start == "" ->
        {:refused, {:bad, :start}}

      not ((fields["wait"] || "") =~ ~r/\A([1-9][0-9]{0,7})?\z/) ->
        {:refused, {:bad, :wait}}

      fields["host"] in [nil, ""] ->
        {:ok, Map.merge(asked(fields, start), %{host: nil, command: nil, cwd: nil})}

      not (is_binary(fields["cmd"]) and fields["cmd"] != "") ->
        {:refused, {:bad, :cmd}}

      not (is_binary(fields["cwd"]) and Path.type(fields["cwd"]) == :absolute) ->
        {:refused, {:bad, :cwd}}

      true ->
        remote = %{host: fields["host"], command: fields["cmd"], cwd: fields["cwd"]}
        {:ok, Map.merge(asked(fields, start), remote)}
    end
  end

  defp asked(fields, start) do
    %{
      class: String.to_existing_atom(fields["class"]),
      id: fields["id"],
      agent: fields["agent"],
      holder: fields["pid"] <> " " <> start,
      again: fields["again"] == "1",
      wait:
        if(fields["wait"] in [nil, ""], do: nil, else: String.to_integer(fields["wait"]) * 1000)
    }
  end
end
