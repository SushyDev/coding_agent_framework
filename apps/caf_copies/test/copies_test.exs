defmodule CodingAgentFramework.CopiesTest do
  # Each test is named for the Copy.tla invariant it checks. No remote machine: the ssh host's
  # ssh is a stand-in that drops ssh's own arguments and runs the command here.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Copies.Table

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Copies, Host, Programs}

  setup do
    dir = test_dir()
    on_exit(fn -> end_recorded(dir) end)
    wt = Path.join(dir, "wt")
    # The test's own repository, apart from the person's git config.
    env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    git = fn args -> {_, 0} = System.cmd(program!(:git), ["-C", wt | args], env: env) end
    File.mkdir_p!(Path.join(wt, "lib"))
    git.(["init", "-q"])
    File.write!(Path.join(wt, ".gitignore"), "_build/\n")
    File.write!(Path.join(wt, "a.txt"), "one\n")
    File.write!(Path.join(wt, "lib/b.txt"), "b\n")
    git.(["add", "."])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first"])

    ssh = Path.join(dir, "ssh")
    File.mkdir_p!(Path.join(dir, "ssh-pids"))
    sh = program!(:sh)

    File.write!(ssh <> ".new", """
    #!#{program!(:bash)}
    : 2>/dev/null > "#{dir}/ssh-pids/$$" || exit 0
    while :; do case $1 in -o|-l) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
    shift
    if [ -e "#{dir}/cut" ]; then
      #{sh} -c "$*" </dev/null >/dev/null 2>&1 &
      : > "#{dir}/ssh-pids/$!"
      exit 255
    fi
    exec #{sh} -c "$*"
    """)

    File.chmod!(ssh <> ".new", 0o755)
    File.rename!(ssh <> ".new", ssh)
    {:ok, remote} = Programs.new(Host.ssh("box", ssh, "box", program!(:kill)), programs().paths)
    copies = start_supervised!({Copies, dir: Path.join(dir, "local"), programs: programs()})

    copy = fn programs, name ->
      %{programs: programs, dir: Path.join(dir, programs.host.name), project: "p", name: name}
    end

    %{
      dir: dir,
      wt: wt,
      copies: copies,
      local: copy.(programs(), "w"),
      remote: copy.(remote, "w"),
      copy: copy,
      remote_programs: remote
    }
  end

  defp sync(c, copy, run, opts \\ []),
    do:
      Copies.sync(
        c.copies,
        copy,
        run,
        c.wt,
        Keyword.merge([timeout: 10_000, lock_wait: 5_000], opts)
      )

  defp files(copy) do
    {:ok, {path, _}} = Copies.place(copy)

    for f <- Path.wildcard(Path.join(path, "**"), match_dot: true),
        File.regular?(f),
        into: MapSet.new(),
        do: Path.relative_to(f, path)
  end

  # A stand-in that holds the copy's lock on its host, as the host side of another sync would.
  defp hold_lock(c, copy) do
    {:ok, {path, lock}} = Copies.place(copy)
    File.mkdir_p!(Path.dirname(path))
    holder = Path.join(c.dir, "holder")
    File.mkdir_p!(holder)
    script = ~s(echo held > "$0"; ) <> echo_tail!(holder)
    args = [lock, program!(:sh), "-c", script, Path.join(holder, "held")]

    Task.start(fn ->
      CodingAgentFramework.Shell.run(host(), program!(:flock), args, timeout: 30_000)
    end)

    {:ok, _} = read_when(Path.join(holder, "held"), "held")
    holder
  end

  for reach <- [:local, :remote] do
    test "StartsOnSyncedCopy: the #{reach} copy gets an edit of the same size in the same second",
         c do
      copy = c[unquote(reach)]
      file = Path.join(c.wt, "a.txt")
      assert {:ok, :taken} = Copies.take(c.copies, copy, "r1")
      assert {:ok, _} = sync(c, copy, "r1")
      {:ok, {path, _}} = Copies.place(copy)
      assert File.read!(Path.join(path, "a.txt")) == "one\n"
      assert {:ok, :given} = Copies.give_back(c.copies, copy, "r1")

      # Same size, and the same whole second as the copy's file: the quick check of size and
      # whole-second time cannot see it. Only the nanoseconds differ.
      %{mtime: seconds} = File.stat!(file, time: :posix)
      File.write!(file, "six\n")
      File.touch!(file, seconds)

      assert {:ok, :taken} = Copies.take(c.copies, copy, "r2")
      assert {:ok, _} = sync(c, copy, "r2")
      assert File.read!(Path.join(path, "a.txt")) == "six\n"
    end
  end

  for reach <- [:local, :remote] do
    test "StartsOnSyncedCopy: the #{reach} copy gets every file git does not ignore", c do
      copy = c[unquote(reach)]
      File.write!(Path.join(c.wt, "a.txt"), "edited\n")
      File.write!(Path.join(c.wt, "u.txt"), "untracked\n")
      File.mkdir_p!(Path.join(c.wt, "_build"))
      File.write!(Path.join(c.wt, "_build/x"), "ignored\n")

      assert {:ok, :taken} = Copies.take(c.copies, copy, "r1")
      assert {:ok, %{record: record}} = sync(c, copy, "r1", fetch: ["a.txt", "none.txt"])
      assert %{"a.txt" => %{size: 7, hash: _, mtime: _}, "none.txt" => :absent} = record
      assert files(copy) == MapSet.new(~w(.gitignore a.txt lib/b.txt u.txt))
      {:ok, {path, _}} = Copies.place(copy)
      assert File.read!(Path.join(path, "a.txt")) == "edited\n"
      assert {:ok, :given} = Copies.give_back(c.copies, copy, "r1")

      # A build output in the copy stays; files gone from the worktree go.
      File.mkdir_p!(Path.join(path, "_build"))
      File.write!(Path.join(path, "_build/out"), "built\n")
      File.rm!(Path.join(c.wt, "u.txt"))
      File.rm!(Path.join(c.wt, "lib/b.txt"))
      assert {:ok, :taken} = Copies.take(c.copies, copy, "r2")
      assert {:ok, _} = sync(c, copy, "r2")
      assert files(copy) == MapSet.new(~w(.gitignore a.txt _build/out))
    end
  end

  test "each write cues copies, and the table is a Tracker source of every copy's turn", c do
    me = self()
    dir = Path.join(c.dir, "cued")

    copies =
      start_supervised!({Copies, dir: dir, programs: programs(), notify: &send(me, &1)},
        id: :cued
      )

    assert_receive %{topic: "copies"}
    assert {:ok, :taken} = Copies.take(copies, c.local, "r1")
    assert_receive %{topic: "copies"} = cue
    refute Map.has_key?(cue, :ids)

    alias CodingAgentFramework.{Copies.Table, Reader}
    meta = Table.meta()

    assert %{topic: "copies", scope: {"ws", "copies"}, kind: :copies} =
             Reader.describe(meta, host: "ws")

    {:ok, db} = Reader.open(meta, Path.join(dir, "copies.db"))
    {:ok, %{rows: [row]}} = Reader.source_read(meta, db, [host: "ws"], :all)
    assert %{holder: "r1", state: "taken", id: id} = row
    assert id == "#{row.host}/#{row.project}/#{row.name}"
    refute Map.has_key?(row, :sent)
  end

  test "NoTurn: a second take is refused, naming the holder", c do
    assert {:ok, :taken} = Copies.take(c.copies, c.local, "r1")
    assert {:refused, {:turn_held, "r1"}} = Copies.take(c.copies, c.local, "r2")
    assert {:refused, {:turn, "r1", "taken"}} = sync(c, c.local, "r2")
    assert {:ok, _} = sync(c, c.local, "r1")
    assert :ok = Copies.starting(c.copies, c.local, "r1")
    assert {:refused, {:turn_held, "r1"}} = Copies.take(c.copies, c.local, "r2")
    assert {:ok, :given} = Copies.give_back(c.copies, c.local, "r1")
    assert {:ok, :taken} = Copies.take(c.copies, c.local, "r2")
  end

  test "NoHostLock: a second sync waits for the lock, and is refused at its deadline", c do
    holder = hold_lock(c, c.remote)
    assert {:ok, :taken} = Copies.take(c.copies, c.remote, "r1")
    assert {:refused, {:sync, {:lock, 300}}} = sync(c, c.remote, "r1", lock_wait: 300)
    # Its host side exited without the lock, so the turn is back at once.
    assert {:ok, :taken} = Copies.take(c.copies, c.remote, "r2")
    pids = length(File.ls!(Path.join(c.dir, "ssh-pids")))
    task = Task.async(fn -> sync(c, c.remote, "r2") end)

    {:ok, _} =
      await(fn ->
        if length(File.ls!(Path.join(c.dir, "ssh-pids"))) > pids, do: {:ok, :waiting}
      end)

    end_recorded(holder)
    assert {:ok, _} = Task.await(task, 15_000)
    assert "a.txt" in files(c.remote)
  end

  test "CutBeforeDeadline: a cut sync keeps the turn until its host side can no longer lock", c do
    hold_lock(c, c.remote)
    File.write!(Path.join(c.dir, "cut"), "")
    assert {:ok, :taken} = Copies.take(c.copies, c.remote, "r1")

    assert {:refused, {:sync, {:status, _, _}}} =
             sync(c, c.remote, "r1", timeout: 1_000, lock_wait: 1_000)

    assert {:refused, {:turn_held, "r1"}} = Copies.take(c.copies, c.remote, "r2")
    assert {:refused, {:cut, _}} = Copies.give_back(c.copies, c.remote, "r1")
    assert {:ok, :taken} = await(fn -> Copies.take(c.copies, c.remote, "r2") end, 10_000)
  end

  test "TurnInMemory: a restart keeps a sync's and a start's turn, and frees the others", c do
    [synced, starting] = for n <- ~w(synced starting), do: c.copy.(programs(), n)

    for {copy, run} <- [{synced, "s"}, {starting, "t"}, {c.remote, "r"}],
        do: {:ok, :taken} = Copies.take(c.copies, copy, run)

    {:ok, _} = sync(c, synced, "s")
    {:ok, _} = sync(c, starting, "t")
    :ok = Copies.starting(c.copies, starting, "t")
    hold_lock(c, c.remote)
    pids = length(File.ls!(Path.join(c.dir, "ssh-pids")))
    # The reaper ends the local rsync and, here, its host side, with the killed caller.
    reaper = start_supervised!({CodingAgentFramework.Shell.Reaper, programs: programs()})
    opts = [timeout: 20_000, lock_wait: 20_000, reaper: reaper]
    task = Task.async(fn -> sync(c, c.remote, "r", opts) end)

    {:ok, _} =
      await(fn ->
        if length(File.ls!(Path.join(c.dir, "ssh-pids"))) > pids, do: {:ok, :waiting}
      end)

    stop_supervised!(Copies)
    Task.shutdown(task, :brutal_kill)
    copies = start_supervised!({Copies, dir: Path.join(c.dir, "local"), programs: programs()})
    assert {:ok, :taken} = Copies.take(copies, synced, "x")
    assert {:refused, {:turn_held, "t"}} = Copies.take(copies, starting, "x")
    assert {:refused, {:turn_held, "r"}} = Copies.take(copies, c.remote, "x")
    assert %{state: "cut"} = Enum.find(Copies.turns(copies), &(&1.holder == "r"))
    assert {:ok, :given} = Copies.give_back(copies, starting, "t")
  end

  test "a copy is removed with its worktree, and not while its turn is held", c do
    {:ok, :taken} = Copies.take(c.copies, c.remote, "r1")
    {:ok, _} = sync(c, c.remote, "r1")
    assert {:refused, {:turn_held, "r1"}} = Copies.remove(c.copies, c.remote, timeout: 5_000)
    {:ok, :given} = Copies.give_back(c.copies, c.remote, "r1")
    assert {:ok, :removed} = Copies.remove(c.copies, c.remote, timeout: 5_000)
    {:ok, {path, _}} = Copies.place(c.remote)
    refute File.exists?(path)
    assert Copies.turns(c.copies) == []
  end
end
