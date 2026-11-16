defmodule CodingAgentFramework.JobsTest do
  # Each test is named for the Copy.tla property it checks. No remote machine: the ssh host's
  # ssh is a stand-in that drops ssh's own arguments and runs the command here, or, while the
  # test's `down` file exists, exits 255 as a dropped connection does. While `cut-fetch`
  # exists, it drops the connection under a fetch, once part of the file has come.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Jobs.Table

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Copies, Host, Jobs, Programs, Shell}

  setup do
    dir = test_dir()
    on_exit(fn -> end_recorded(dir) end)
    wt = Path.join(dir, "wt")
    env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    File.mkdir_p!(wt)
    {_, 0} = System.cmd(program!(:git), ["-C", wt, "init", "-q"], env: env)
    File.write!(Path.join(wt, "a.txt"), "one\n")
    File.mkdir_p!(Path.join(dir, "pids"))
    {_, 0} = System.cmd(program!(:mkfifo), [Path.join(dir, "fifo")])

    bash = program!(:bash)
    # The job: it records its pid, then exits with a code, waits on the fifo, leaves a child,
    # writes files in the copy (and then waits on the fifo), or writes a 4 MB file.
    write_whole(Path.join(dir, "job"), """
    : 2>/dev/null > "#{dir}/pids/$$" || exit 0
    echo "job $1 in $(#{program!(:cat)} a.txt)"
    case $1 in
      exit) exit "$2" ;;
      write) shift; while [ $# -gt 1 ]; do
          case $1 in */*) #{program!(:mkdir)} -p "${1%/*}" ;; esac; echo "$2" > "$1"; shift 2; done; exit 0 ;;
      writewait) echo "$3" > "$2"; set -- wait ;;
      chatty) i=0; while [ $i -lt 5000 ]; do echo "line $i of a long log, padded to forty"; i=$((i+1)); done; exit 0 ;;
      big) echo 1 > big.bin; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21; do
          #{program!(:cat)} big.bin big.bin > big.new; #{program!(:mv)} big.new big.bin; done; exit 0 ;;
    esac
    case $1 in
      wait) exec #{bash} -c 'read -r -t #{stand_in_idle()} l <> "$1"; exit "${l:-9}"' "$0" "#{dir}/fifo" ;;
      child) #{bash} -c ': > "#{dir}/pids/$$"; echo $$ > "#{dir}/child.new"; #{program!(:mv)} "#{dir}/child.new" "#{dir}/child"; read -r -t #{stand_in_idle()} l <> "#{dir}/fifo"' "$0" &
        wait_for() { [ -e "#{dir}/child" ] || { #{program!(:sleep)} 0.05; wait_for; }; }; wait_for; exit 0 ;;
    esac
    """)

    write_whole(Path.join(dir, "ssh"), """
    #!#{bash}
    [ -e "#{dir}/down" ] && exit 255
    while :; do case $1 in -o|-l) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
    shift
    cmd="$*"
    # Under `cut-fetch`, the fetch's sender is slowed, and the connection drops once part of
    # the file has come into the fetch's temporary directory (bounded at 10 s).
    case $cmd in *--sender*) [ -e "#{dir}/cut-fetch" ] && {
      cmd=${cmd/--server /--server --bwlimit=1000 }
      for ((i = 0; i < 500; i++)); do
        for f in "#{wt}"/.caf-fetch-*/.big.bin.* "#{wt}"/.caf-fetch-*/big.bin; do
          [ -s "$f" ] && { : > "#{dir}/down"; break 2; }
        done
        #{program!(:sleep)} 0.02
      done & } ;;
    esac
    # A drop cuts a command under way too: its output stops, every process of it ends, as a
    # closed connection ends them, and ssh exits 255. Its tree is walked by parent pid, each
    # process stopped before its children are read; a process dtach holds has left the tree.
    end_tree() {
      kill -STOP "$1" 2>/dev/null
      for k in $(#{program!(:ps)} -A -o pid=,ppid= | while read -r c pp; do [ "$pp" = "$1" ] && echo "$c"; done); do
        end_tree "$k"
      done
      kill -KILL "$1" 2>/dev/null
    }
    #{program!(:sh)} -c "$cmd" <&0 & p=$!
    while kill -0 $p 2>/dev/null; do
      [ -e "#{dir}/down" ] && { end_tree $p; exit 255; }
      #{program!(:sleep)} 0.05
    done
    wait $p
    """)

    File.chmod!(Path.join(dir, "ssh"), 0o755)
    box = Host.ssh("box", Path.join(dir, "ssh"), "box", program!(:kill))
    {:ok, remote} = Programs.new(box, programs().paths)
    copies = start_supervised!({Copies, dir: Path.join(dir, "copies"), programs: programs()})

    hosts = %{
      "test" => %{programs: programs(), dir: Path.join(dir, "ws")},
      "box" => %{programs: remote, dir: Path.join(dir, "box")}
    }

    test = self()
    late = fn late_end -> send(test, {:late, late_end}) end
    opts = [dir: Path.join(dir, "jobs"), copies: copies, hosts: hosts, on_late_end: late]
    %{dir: dir, wt: wt, jobs: start_supervised!({Jobs, opts}), opts: opts, bash: bash}
  end

  defp write_whole(path, text) do
    File.write!(path <> ".new", text)
    File.rename!(path <> ".new", path)
  end

  defp run(c, id, host, args, opts \\ []) do
    where = %{host: host, project: "p", name: "w"}
    opts = Keyword.merge([timeout: 10_000, start_timeout: 2_000, interval: 50], opts)
    Jobs.run(c.jobs, id, where, c.wt, [c.bash, Path.join(c.dir, "job") | args], opts)
  end

  defp pid(c, n) do
    await(fn ->
      case File.ls!(Path.join(c.dir, "pids")) do
        pids when length(pids) >= n -> {:ok, pids}
        _ -> :none
      end
    end)
  end

  # A late end, handed on at a cue the way a host's reader cues `Jobs`.
  defp late(jobs) do
    cue = fn -> Jobs.cue(jobs, %{topic: :host}) end

    await_cued(
      jobs,
      cue,
      fn -> receive(do: ({:late, e} -> {:ok, e}), after: (0 -> nil)) end,
      10_000
    )
  end

  # Once handed on, a late end is not handed on again at the next cue.
  defp no_second(jobs) do
    Jobs.cue(jobs, %{topic: :host})
    :sys.get_state(jobs)
    refute_received {:late, _}
  end

  defp leftovers(c), do: Path.wildcard(Path.join(c.wt, "**/.caf-fetch-*"), match_dot: true)

  defp gone(pid), do: await(fn -> if alive?(pid), do: :alive, else: {:ok, :gone} end)

  for host <- ["test", "box"] do
    test "AnswerIsReal: a job on #{host} answers its own exit code and its log", c do
      assert {:ok, %{exit: 0, log: "job exit in one\n", fetch: :none}} =
               run(c, "j0", unquote(host), ~w(exit 0))

      assert {:ok, %{exit: 3, log: log}} = run(c, "j3", unquote(host), ~w(exit 3))
      assert log =~ "job exit"
      assert {:ok, %{text: "exit in one\n", next: 16}} = Jobs.log(c.jobs, "j3", 4)
      assert %{state: "exited", code: 3} = Enum.find(Jobs.rows(c.jobs), &(&1.id == "j3"))
      assert {:refused, {:job_exists, "j3"}} = run(c, "j3", unquote(host), ~w(exit 0))
    end
  end

  for host <- ["test", "box"] do
    test "BoundedRead: a log read on #{host} from an offset answers at most the bound", c do
      assert {:ok, %{exit: 0}} = run(c, "jc", unquote(host), ~w(chatty))
      # The log is written by dtach's own process, and may still be coming when the exit is known.
      await(fn ->
        with {:ok, %{text: <<_>>}} <- Jobs.log(c.jobs, "jc", 150_000, max: 1), do: {:ok, :whole}
      end)

      assert {:ok, %{text: first, next: 100}} = Jobs.log(c.jobs, "jc", 0, max: 100)
      assert byte_size(first) == 100
      assert {:ok, %{text: second, next: 250}} = Jobs.log(c.jobs, "jc", 100, max: 150)
      assert byte_size(second) == 150

      # The log is over 16 KiB (and over a pipe's buffer), so a read with no bound given stops at the default.
      assert {:ok, %{text: text, next: 16_484}} = Jobs.log(c.jobs, "jc", 100)
      assert byte_size(text) == 16_384
      assert String.starts_with?(first <> second, "job chatty in one\nline 0 of")
    end
  end

  for host <- ["test", "box"] do
    test "FetchOnlyNamed: a fetch on #{host} brings back the named paths, and nothing else", c do
      args = ~w(write a.txt changed d/b.txt two c.txt three)
      fetch = ["a.txt", "d/b.txt"]
      assert {:ok, %{exit: 0, fetch: :done}} = run(c, "jf", unquote(host), args, fetch: fetch)
      assert File.read!(Path.join(c.wt, "a.txt")) == "changed\n"
      assert File.read!(Path.join(c.wt, "d/b.txt")) == "two\n"
      refute File.exists?(Path.join(c.wt, "c.txt"))
      assert leftovers(c) == []
    end
  end

  test "NoEditLost: an edit made in the worktree during the job is kept, as a conflict", c do
    args = ~w(writewait a.txt job)
    task = Task.async(fn -> run(c, "je", "box", args, fetch: ["a.txt", "n.txt"]) end)
    {:ok, _} = pid(c, 1)
    File.write!(Path.join(c.wt, "a.txt"), "edit\n")
    File.write!(Path.join(c.dir, "fifo"), "0\n")
    assert {:ok, %{exit: 0, fetch: {:conflict, ["a.txt"]}}} = Task.await(task, 15_000)
    assert File.read!(Path.join(c.wt, "a.txt")) == "edit\n"
    assert File.read!(Path.join(c.dir, "box/copies/p/w/a.txt")) == "job\n"
    assert leftovers(c) == []
  end

  test "AnswerIsReal: a fetch cut by a drop answers unknown and leaves no temporary file", c do
    File.write!(Path.join(c.dir, "cut-fetch"), "")

    assert {:ok, %{exit: 0, fetch: {:unknown, {:fetch, {:ok, %{status: _}}}}}} =
             run(c, "jx", "box", ["big"], fetch: ["big.bin"], sync_timeout: 5_000)

    assert File.exists?(Path.join(c.dir, "down"))
    refute File.exists?(Path.join(c.wt, "big.bin"))
    assert leftovers(c) == []
  end

  test "JobEndsAtTimeout: the host ends a job at its timeout", c do
    assert {:unknown, {:timeout, %{fetch: :none}}} = run(c, "jt", "box", ["wait"], timeout: 500)
    {:ok, [pid]} = pid(c, 1)
    assert {:ok, :gone} = gone(pid)
  end

  test "JobEndsAtTimeout: with the connection down, the call answers dropped and the host still ends the job",
       c do
    task = Task.async(fn -> run(c, "jd", "box", ["wait"], timeout: 1_000) end)
    {:ok, [pid]} = pid(c, 1)
    File.write!(Path.join(c.dir, "down"), "")
    assert {:unknown, :dropped} = Task.await(task, 15_000)
    assert {:ok, :gone} = gone(pid)
    assert File.read!(Path.join(c.dir, "box/jobs/jd.exit")) == "timeout\n"
    File.rm!(Path.join(c.dir, "down"))
    assert {:ok, %{job: "jd", end: {:unknown, :timeout}, fetch: :not_fetched}} = late(c.jobs)
    assert %{state: "timedout", late: "told"} = Enum.find(Jobs.rows(c.jobs), &(&1.id == "jd"))
    no_second(c.jobs)
  end

  test "JobGoneAtEnd: a child the command left in its group is ended at the command's exit",
       c do
    assert {:ok, %{exit: 0}} = run(c, "jc", "box", ["child"])
    child = c.dir |> Path.join("child") |> File.read!() |> String.trim()
    assert {:ok, :gone} = gone(child)
  end

  test "AnswerIsReal: a dead socket with no exit file answers no_exit, never a code", c do
    task = Task.async(fn -> run(c, "jn", "box", ["wait"]) end)
    {:ok, [pid]} = pid(c, 1)
    ps = ["-o", "pgid=", "-p", pid]
    {:ok, %{status: 0, output: pgid}} = Shell.run(host(), program!(:ps), ps, timeout: 5_000)
    # The wrapper leads the group, and its command line names this test's directory.
    {:ok, %{status: 0}} =
      Shell.run(host(), program!(:kill), ["-KILL", "--", "-" <> String.trim(pgid)],
        timeout: 5_000
      )

    assert {:unknown, :no_exit} = Task.await(task, 15_000)
    assert %{state: "lost", code: nil} = Enum.find(Jobs.rows(c.jobs), &(&1.id == "jn"))
  end

  test "StartsOnSyncedCopy: a cut sync refuses the run, and nothing runs", c do
    File.write!(Path.join(c.dir, "down"), "")
    assert {:refused, {:sync, _}} = run(c, "js", "box", ~w(exit 0))
    assert File.ls!(Path.join(c.dir, "pids")) == []
    assert %{state: "refused"} = Enum.find(Jobs.rows(c.jobs), &(&1.id == "js"))
  end

  test "JobSettles: a restart ends the call, and the job's row is still settled and handed on",
       c do
    task = Task.async(fn -> run(c, "jr", "box", ["wait"]) end)
    {:ok, _} = pid(c, 1)

    {:ok, _} =
      await(fn -> if Enum.any?(Jobs.rows(c.jobs), &(&1.state == "running")), do: {:ok, 1} end)

    stop_supervised!(Jobs)
    Task.shutdown(task, :brutal_kill)
    File.write!(Path.join(c.dir, "fifo"), "4\n")
    {:ok, _} = read_when(Path.join(c.dir, "box/jobs/jr.exit"), "4\n")
    jobs = start_supervised!({Jobs, c.opts})

    assert {:ok, %{job: "jr", end: {:exit, 4}, fetch: :not_fetched}} = late(jobs)
    assert {:ok, %{state: "exited", code: 4, late: "told"}} = Jobs.settle(jobs, "jr")
    no_second(jobs)
  end

  # A restart ends the fetch's call before it removes its temporary folder; the stand-in for
  # that is the folder left under the worktree of a row whose job had ended.
  test "JobSettles: a restart leaves no fetch folder under a row's worktree, and no other", c do
    assert {:ok, %{exit: 0}} = run(c, "jw", "test", ~w(exit 0))
    stop_supervised!(Jobs)

    other = Path.join(c.dir, "other-wt")
    inside = [".caf-fetch-12345/part", ".caf-fetch-7/d/x"]
    keep = [".caf-fetch-x/y", "sub/.caf-fetch-3/z", "caf-fetch-4/z", "a.txt"]

    for f <- inside ++ keep, do: write_whole_in(c.wt, f)
    write_whole_in(other, ".caf-fetch-9/z")

    jobs = start_supervised!({Jobs, c.opts})
    :sys.get_state(jobs)

    assert Path.wildcard(Path.join(c.wt, ".caf-fetch-[0-9]*"), match_dot: true) == []
    for f <- keep, do: assert(File.exists?(Path.join(c.wt, f)))
    assert File.exists?(Path.join(other, ".caf-fetch-9/z"))
  end

  test "JobSettles: a row left asked is handed on once as interrupted, across two restarts", c do
    stop_supervised!(Jobs)
    {:ok, db} = Jobs.Table.open(Path.join(c.opts[:dir], "jobs.db"))

    :ok =
      Jobs.Table.put(db, %{
        id: "ja",
        host: "test",
        project: "p",
        name: "w",
        state: "asked",
        worktree: c.wt
      })

    jobs = start_supervised!({Jobs, c.opts})
    assert {:ok, %{job: "ja", end: {:refused, :interrupted}, fetch: :not_fetched}} = late(jobs)
    assert %{state: "interrupted", late: "told"} = Enum.find(Jobs.rows(jobs), &(&1.id == "ja"))
    assert File.ls!(Path.join(c.dir, "pids")) == []
    no_second(jobs)

    stop_supervised!(Jobs)
    jobs = start_supervised!({Jobs, c.opts})
    no_second(jobs)
    assert %{state: "interrupted", late: "told"} = Enum.find(Jobs.rows(jobs), &(&1.id == "ja"))
  end

  test "JobSettles: a file made before the worktree column gains it on open", c do
    path = Path.join(c.dir, "old.db")
    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE jobs (id TEXT PRIMARY KEY, host TEXT NOT NULL, project TEXT NOT NULL,
        name TEXT NOT NULL, state TEXT NOT NULL, code INTEGER, start_until INTEGER,
        deadline INTEGER, late TEXT);
      INSERT INTO jobs (id, host, project, name, state) VALUES ('jo', 'h', 'p', 'n', 'exited');
      """)

    Exqlite.Sqlite3.close(db)
    {:ok, db} = Jobs.Table.open(path)
    assert %{id: "jo", worktree: nil} = Jobs.Table.get(db, "jo")
    assert {:ok, _} = Jobs.Table.open(path)
  end

  defp write_whole_in(root, file) do
    path = Path.join(root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "x")
  end
end
