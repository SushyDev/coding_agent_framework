defmodule CodingAgentFramework.Runs.Remote do
  @moduledoc """
  A heavy command run on another host (F-296, `model/tla/RemoteRun.tla`): `Runs.Plug`'s path
  for a wrapper whose `--host` the app's list names for its command.

  The command runs as a job, `Jobs.run/6`, in a process of its own: the job's lease is that
  host's slot, its row the holder, and its copy the agent's own on that host (`where`'s
  project, and the agent's name as the copy's), synced from the agent's worktree before each
  run. It runs in the copy at the wrapper's directory relative to the worktree, as `sh -c
  <command>` there, with the host's environment; nothing is fetched back. A run no agent asks
  for (the app's own, F-304) is placed by the wrapper's directory instead, when that is a
  folder the framework knows (`Runs.folder/2`), and refused `no_worktree` elsewhere.

  The answer is chunked, one line each:

    * `started on <host> (job <id>)` once the job's row reads it running;
    * `o <line>` for each line of the job's log (its output and its errors, as one), read from
      an offset every `poll:` ms, and `p <text>` for text with no newline yet (at the end, or
      past 16 KiB);
    * a newline every `beat:` ms with nothing else to send, whose failed write is how a wrapper
      gone is found;
    * the end, only once the log was read to its end (`WholeStream`): `ended exit <code>`,
      `ended timeout` (the host ended the job at its timeout), `ended unknown <reason>`, or a
      refusal, `refused <reason> <time | ->`, when nothing ran.

  **The host away.** Once the job started, a log read that fails is not yet an end: the reads
  go on, and only once they have failed for `away:` ms in a row (30 s by default) does the run
  end `ended unknown host_away`. Its process is ended then, which leaves the job's row owed
  (`Jobs`): the job may still run on the host, so its lease is released once `Jobs` reads its
  end there, never before (`NoRunUnleased`); a host away takes no new work meanwhile.

  **The wrapper gone** (the agent's Ctrl-C, or Claude Code's own timeout): the next write fails,
  and the run's process is ended the same way. A job not started yet never starts; one started
  runs on to its own end or its timeout, holding its slot, and its end is the row's.
  """

  import Plug.Conn

  alias CodingAgentFramework.{Jobs, Runs}

  @away 30_000
  @poll 1_000
  @read 5_000
  @max 16_384
  @started ~w(running exited timedout lost)
  # The agent's command, in its directory of the copy.
  @in_dir ~S(cd -- "$1" && eval "$2")

  @doc "How long, in ms, a started run's log reads may fail in a row before it ends: 30 000."
  @spec away() :: pos_integer
  def away, do: @away

  @doc "How often, in ms, a run's log is read: 1 000, one ssh connection each."
  @spec poll() :: pos_integer
  def poll, do: @poll

  @doc """
  Runs `ask` (`Runs.ask/1`'s, with a host) on its host under `units`, streaming on `conn`, a
  chunked response. `opts` are `Runs.Plug`'s. Answers the conn. `fallback`, a function of the
  conn or nil, takes the run on when its placement is refused `host_away` and `Jobs` has no
  row for it, so nothing was sent (F-304, `RemotePlace.tla`): never once the job may have
  started.
  """
  @spec run(Plug.Conn.t(), map, map, map, (Plug.Conn.t() -> Plug.Conn.t()) | nil) ::
          Plug.Conn.t()
  def run(conn, opts, ask, units, fallback \\ nil) do
    with {:jobs, jobs} when jobs != nil <- {:jobs, opts.jobs.()},
         {:ok, place} <- opts.where.(ask.agent, ask.cwd),
         {:ok, dir} <- inside(place.worktree, ask.cwd) do
      id = "run-" <> ask.id
      where = %{host: ask.host, project: place.project, name: place.name}
      argv = ["/bin/sh", "-c", @in_dir, "caf-run", dir, ask.command]
      lease = %{class: ask.class, module: ask.agent, units: units}
      run_opts = [timeout: opts.remote_timeout, lease: lease, lease_wait: ask.wait]
      me = self()

      # Linked, so a crash of either ends both; every other end of this request ends it too.
      pid =
        spawn_link(fn ->
          send(me, {:remote, id, Jobs.run(jobs, id, where, place.worktree, argv, run_opts)})
        end)

      st = %{conn: conn, jobs: jobs, id: id, pid: pid, host: ask.host, offset: 0, rest: ""}
      st = Map.merge(st, %{started: false, failing: nil, beat: now() + opts.beat})
      st = Map.put(st, :fallback, fallback)
      loop(st, opts)
    else
      {:jobs, nil} -> last(conn, "unknown no_jobs")
      {:refused, why} -> last(conn, "refused #{Runs.Plug.word(why)} -")
    end
  end

  defp inside(worktree, cwd) do
    {wt, cwd} = {Path.expand(worktree), Path.expand(cwd)}

    cond do
      cwd == wt -> {:ok, "."}
      String.starts_with?(cwd, wt <> "/") -> {:ok, Path.relative_to(cwd, wt)}
      true -> {:refused, :outside}
    end
  end

  defp loop(st, opts) do
    receive do
      {:remote, id, answer} when id == st.id -> finish(st, opts, answer)
    after
      opts.poll ->
        case tick(st, opts) do
          {:ok, st} ->
            loop(st, opts)

          {:away, st} ->
            stop(st)
            last(st.conn, "ended unknown host_away")

          {:gone, st} ->
            stop(st)
            st.conn
        end
    end
  end

  defp tick(st, opts) do
    with {:ok, st} <- start(st), {:ok, st} <- read(st, opts), do: beat(st, opts)
  end

  # The job's row says when it started; its log is read only from then.
  defp start(%{started: true} = st), do: {:ok, st}

  defp start(st) do
    case Jobs.row(st.jobs, st.id) do
      {:ok, %{state: state}} when state in @started ->
        send_text(%{st | started: true}, "started on #{st.host} (job #{st.id})\n")

      _ ->
        {:ok, st}
    end
  end

  # As much of the log as there is now; a failed read counts toward the away bound.
  defp read(%{started: false} = st, _opts), do: {:ok, st}

  defp read(st, opts) do
    case Jobs.log(st.jobs, st.id, st.offset, timeout: @read, max: @max) do
      {:ok, %{text: text, next: next}} ->
        with {:ok, st} <- lines(%{st | offset: next, failing: nil}, text) do
          if byte_size(text) == @max, do: read(st, opts), else: {:ok, st}
        end

      _failed ->
        failing = st.failing || now()
        st = %{st | failing: failing}
        if now() - failing >= opts.away, do: {:away, st}, else: {:ok, st}
    end
  end

  defp beat(st, opts) do
    if now() >= st.beat, do: send_text(st, "\n", opts), else: {:ok, st}
  end

  # Whole lines go as they come; text with no newline waits for the rest, up to 16 KiB.
  defp lines(st, text) do
    parts = String.split(st.rest <> text, "\n")
    {done, [rest]} = Enum.split(parts, -1)
    out = Enum.map_join(done, "", &("o " <> &1 <> "\n"))

    {out, rest} =
      if byte_size(rest) > @max, do: {out <> "p " <> rest <> "\n", ""}, else: {out, rest}

    st = %{st | rest: rest}
    if out == "", do: {:ok, st}, else: send_text(st, out)
  end

  defp send_text(st, text, opts \\ nil) do
    case chunk(st.conn, text) do
      {:ok, conn} -> {:ok, %{st | conn: conn, beat: next_beat(st, opts)}}
      {:error, _} -> {:gone, st}
    end
  end

  defp next_beat(st, nil), do: st.beat
  defp next_beat(_st, opts), do: now() + opts.beat

  # The run answered. Its code goes only once the log is read to its end: the job's group was
  # ended before its end was read, so nothing writes the log after.
  defp finish(st, opts, answer) do
    Process.unlink(st.pid)

    case answer do
      {:ok, %{exit: code}} -> drained(st, opts, "ended exit #{code}")
      {:unknown, {:timeout, _}} -> drained(st, opts, "ended timeout")
      {:unknown, :dropped} -> last(st.conn, "ended unknown dropped")
      {:unknown, why} -> drained(st, opts, "ended unknown #{Runs.Plug.word(why)}")
      {:refused, {:lease, {reason, at}}} -> last(st.conn, Runs.Plug.refused(reason, at))
      {:refused, {:job_exists, _}} -> last(st.conn, "ended unknown job_exists")
      {:refused, {:host_away, _} = why} -> away(st, why)
      {:refused, why} -> last(st.conn, "refused #{Runs.Plug.word(why)} -")
    end
  end

  # The placement found the host away: `Jobs` refuses it before the job's row and its lease, so
  # no row means nothing was sent, and only then does the run go on elsewhere. A row, or a read
  # that cannot say, keeps it here: refused, never moved.
  defp away(st, why) do
    case {st.fallback, st.started, Jobs.row(st.jobs, st.id)} do
      {next, false, {:refused, {:no_job, _}}} when next != nil -> next.(st.conn)
      _ -> last(st.conn, "refused #{Runs.Plug.word(why)} -")
    end
  end

  defp drained(st, opts, line) do
    case drain(%{st | started: true}, opts) do
      {:ok, %{rest: ""} = st} -> last(st.conn, line)
      {:ok, st} -> last(st.conn, "p " <> st.rest <> "\n" <> line)
      {:away, st} -> last(st.conn, "ended unknown log_cut")
      {:gone, st} -> st.conn
    end
  end

  defp drain(st, opts) do
    offset = st.offset

    case read(st, opts) do
      {:ok, %{offset: ^offset, failing: nil} = st} ->
        {:ok, st}

      {:ok, st} ->
        if st.failing, do: pause(opts.poll)
        drain(st, opts)

      other ->
        other
    end
  end

  # The run's process is ended: `Jobs` leaves its row interrupted (nothing sent) or owed.
  defp stop(st) do
    Process.unlink(st.pid)
    Process.exit(st.pid, :kill)

    receive do
      {:remote, id, _} when id == st.id -> :ok
    after
      0 -> :ok
    end
  end

  defp last(conn, line) do
    case chunk(conn, line <> "\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp pause(ms) do
    receive do
    after
      ms -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
