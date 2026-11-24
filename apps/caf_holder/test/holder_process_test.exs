defmodule CodingAgentFramework.Holder.ProcessTest do
  @moduledoc """
  `Holder.Process` on real dtach sockets in this test's own directory: the record its wrapper
  writes, one reading of several names, a signal only by pid and start time, and an end by TERM,
  then KILL.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Holder

  doctest Holder.Process

  setup do
    dir = test_dir()
    {:ok, holder} = Holder.new(programs(), dir)
    {:ok, p} = Holder.Process.new(programs(), holder)
    on_exit(fn -> end_recorded(dir) end)
    {:ok, dir: dir, p: p}
  end

  # F-246: Linux's start time, field 22 of `/proc/<pid>/stat`, counted from after the line's
  # last `)`, since the program's name in field 2 may hold spaces and ") (".
  test "a stat line's start time is read past a name holding \") (\"" do
    stat = fn pid, comm, start ->
      "#{pid} (#{comm}) S 1 #{pid} #{pid} 0 -1 4194560 7 0 0 0 3 1 0 0 20 0 9 0 #{start} 8 9\n"
    end

    out =
      stat.(41, "claude) (x", "653385178") <>
        stat.(42, ") (", "12") <> "cat: /proc/43/stat: No such file or directory\n"

    procs = [{41, "653385178"}, {42, "11"}, {43, "5"}, {44, "5"}]

    assert Holder.Process.judge_stat({:ok, %{status: 1, output: out}}, procs) == %{
             {41, "653385178"} => :live,
             {42, "11"} => :replaced,
             {43, "5"} => :gone,
             {44, "5"} => :unknown
           }

    # Anything unreadable, or a cat that did not run cleanly, decides nothing.
    for outcome <- [
          {:ok, %{status: 0, output: "41 (claude S 1\n"}},
          {:ok, %{status: 2, output: ""}},
          {:unknown, :timeout}
        ] do
      assert Holder.Process.judge_stat(outcome, [{41, "1"}]) == %{{41, "1"} => :unknown}
    end
  end

  test "a hold writes the program's record; a reading names it live, and it is not dead",
       %{p: p} = ctx do
    pid = hold!(ctx, "alpha", echo_tail!(ctx.dir))
    assert {:ok, %{"alpha" => r}} = Holder.Process.read(p, ["alpha"], wait: 2_000)
    assert %{socket: :live, process: :live, record: %{pid: ^pid, start: start}} = r
    assert start == own_start(pid)
    refute Holder.Process.dead?(r)
  end

  test "one reading of several names: absent with no record, and a held one",
       %{p: p} = ctx do
    hold!(ctx, "alpha", echo_tail!(ctx.dir))

    assert {:ok, %{"alpha" => %{process: :live}, "nobody" => nobody}} =
             Holder.Process.read(p, ["alpha", "nobody"], wait: 2_000)

    assert %{socket: :absent, process: :none, record: nil} = nobody
    assert Holder.Process.dead?(nobody)
  end

  test "a record whose pid another process has now reads replaced, and is never signaled",
       %{p: p} = ctx do
    pid = hold!(ctx, "alpha", echo_tail!(ctx.dir))
    record = %{pid: pid, start: "Thu Jan 1 00:00:00 1970"}
    assert {:ok, :gone} = Holder.Process.signal(p, record, "TERM")
    assert alive?(pid)
    File.write!(Holder.Process.record_path(p, "alpha"), "#{pid} Thu Jan 1 00:00:00 1970\n")
    assert {:ok, %{"alpha" => %{process: :replaced}}} = Holder.Process.read(p, ["alpha"])
  end

  test "a hold never clears a live program's record", %{p: p} = ctx do
    pid = hold!(ctx, "alpha", echo_tail!(ctx.dir))
    assert {:refused, {:live, "alpha"}} = Holder.Process.hold(p, "alpha", [program!(:cat)])
    assert {:ok, %{"alpha" => %{record: %{pid: ^pid}}}} = Holder.Process.read(p, ["alpha"])
  end

  test "an end sends TERM, and the program is dead once its socket goes", %{p: p} = ctx do
    pid = hold!(ctx, "alpha", echo_tail!(ctx.dir))
    {:ok, %{"alpha" => %{record: record}}} = Holder.Process.read(p, ["alpha"])
    assert {:ok, :ended} = Holder.Process.end_held(p, "alpha", record, 5_000)
    refute alive?(pid)
    assert {:ok, %{"alpha" => r}} = Holder.Process.read(p, ["alpha"])
    assert Holder.Process.dead?(r)
  end

  test "a program that ignores TERM is sent KILL at the end's deadline", %{p: p} = ctx do
    script = ~s(trap '' TERM; ) <> echo_tail!(ctx.dir)
    pid = hold!(ctx, "deaf", script)
    {:ok, %{"deaf" => %{record: record}}} = Holder.Process.read(p, ["deaf"])
    assert {:ok, :ended} = Holder.Process.end_held(p, "deaf", record, 300)
    refute alive?(pid)
  end

  test "a wait on the host answers once the program is dead, or the last reading at its end",
       %{p: p} = ctx do
    pid = hold!(ctx, "waited", echo_tail!(ctx.dir))
    assert {:ok, %{process: :live} = r} = Holder.Process.await_dead(p, "waited", 300)
    refute Holder.Process.dead?(r)
    waiter = Task.async(fn -> Holder.Process.await_dead(p, "waited", 5_000) end)
    kill(pid)
    assert {:ok, r} = Task.await(waiter, 10_000)
    assert Holder.Process.dead?(r)
  end

  # A wait on the host ends by its clock (F-217): within one round of reads (0.1 s apart) after
  # its bound, never before. Each round runs `dtach` and `ps`, and every sleep wakes late under
  # load, so the slack is stated wide.
  @slack 1_000

  test "a wait on the host ends by the clock, one deadline for every name, never before it",
       %{p: p} = ctx do
    hold!(ctx, "waited", echo_tail!(ctx.dir))
    {waited, answer} = timed(fn -> Holder.Process.await_dead(p, "waited", 1_500) end)
    assert {:ok, %{process: :live}} = answer
    assert waited in 1_500..(1_500 + @slack)

    # Two live sockets whose records never come: both wait out the one bound, not one each.
    for name <- ["bare1", "bare2"] do
      argv = [program!(:sh), "-c", echo_tail!(ctx.dir), Path.join(ctx.dir, name)]
      assert {:ok, _} = Holder.hold(p.holder, name, argv)
    end

    {waited, answer} = timed(fn -> Holder.Process.read(p, ["bare1", "bare2"], wait: 1_500) end)
    assert {:ok, %{"bare1" => %{record: nil}, "bare2" => %{record: nil}}} = answer
    assert waited in 1_500..(1_500 + @slack)
  end

  # A deadline that lives in one call is on the monotonic clock (F-218): `dead_by/3` reads a
  # live program until its monotonic deadline, and no sooner. Read as OS time, a monotonic
  # reading (small, or negative) has long passed, and the wait would end at its first read.
  test "dead_by waits for a deadline on the monotonic clock, and no sooner", %{p: p} = ctx do
    hold!(ctx, "waited", echo_tail!(ctx.dir))
    deadline = System.monotonic_time(:millisecond) + 1_000
    {waited, answer} = timed(fn -> Holder.Process.dead_by(p, "waited", deadline) end)
    assert {:unknown, {:not_dead, %{process: :live}}} = answer
    assert waited in 1_000..(1_000 + @slack)
  end

  test "input reaches the program only while its record is the held one", %{p: p} = ctx do
    out = Path.join(ctx.dir, "said")
    script = ~s(read -r l; echo "$l" > "#{out}"; ) <> echo_tail!(ctx.dir)
    hold!(ctx, "ears", script)
    {:ok, %{"ears" => %{record: record}}} = Holder.Process.read(p, ["ears"])
    stale = %{record | start: "Thu Jan 1 00:00:00 1970"}
    assert {:ok, :gone} = Holder.Process.push(p, "ears", stale, "no\n")
    assert {:ok, :sent} = Holder.Process.push(p, "ears", record, "yes\n")
    assert {:ok, "yes\n"} = read_when(out, "yes\n")
  end

  test "a group signal reaches the program's children", %{p: p} = ctx do
    child = Path.join(ctx.dir, "child")
    script = ~s(#{program!(:sleep)} 30 & echo $! > "#{child}"; ) <> echo_tail!(ctx.dir)
    hold!(ctx, "group", script)
    {:ok, text} = read_when(child, "1")
    sleeper = text |> String.trim() |> String.to_integer()
    {:ok, %{"group" => %{record: record}}} = Holder.Process.read(p, ["group"])
    assert {:ok, :ended} = Holder.Process.end_held(p, "group", record, 5_000, group: true)
    assert {:ok, :gone} = await(fn -> if alive?(sleeper), do: :alive, else: {:ok, :gone} end)
  end

  test "a group whose members are all zombies not yet reaped is gone to a group signal",
       %{p: p} = ctx do
    zombie = zombie_leader!(ctx)
    record = %{pid: zombie, start: own_start(zombie)}
    # macOS answers EPERM for this group; another system may answer ESRCH. Either is gone.
    assert {:ok, :gone} = Holder.Process.signal(p, record, "TERM", group: true)
    assert {:ok, :gone} = Holder.Process.signal(p, record, "KILL", group: true)
  end

  test "a group signal that fails while a member lives stays unknown", ctx do
    kill = Path.join(ctx.dir, "kill-eperm")
    File.write!(kill, "#!/bin/sh\necho \"kill: ($3) - Operation not permitted\" >&2\nexit 1\n")
    File.chmod!(kill, 0o755)
    {:ok, holder} = Holder.new(programs(host(), %{kill: kill}), ctx.dir)
    {:ok, p} = Holder.Process.new(programs(host(), %{kill: kill}), holder)

    pid = hold!(ctx, "alive", echo_tail!(ctx.dir))
    {:ok, %{"alive" => %{record: record}}} = Holder.Process.read(p, ["alive"])

    assert {:unknown, {:signal, {:ok, %{status: 1, output: out}}}} =
             Holder.Process.signal(p, record, "TERM", group: true)

    assert out =~ "Operation not permitted"
    assert alive?(pid)

    # The same failure of a lone pid is never read from its group.
    assert {:unknown, {:signal, _}} = Holder.Process.signal(p, record, "TERM")

    zombie = zombie_leader!(ctx)
    zombie_record = %{pid: zombie, start: own_start(zombie)}
    assert {:ok, :gone} = Holder.Process.signal(p, zombie_record, "TERM", group: true)
  end

  # Holds a program that starts a child in its own group, and then never reaps it: once the
  # child exits it is a zombie that leads a group of zombies. Answers the child's pid.
  defp zombie_leader!(ctx) do
    file = Path.join(ctx.dir, "zombie")
    sleep = program!(:sleep)
    script = ~s(set -m; #{sleep} 0.2 & echo $! > "#{file}"; exec #{sleep} 30)
    hold!(ctx, "parent", script)
    {:ok, text} = read_when(file, "1")
    zombie = text |> String.trim() |> String.to_integer()
    assert {:ok, :zombie} = await(fn -> zombie_state(zombie) end)
    zombie
  end

  defp zombie_state(pid) do
    {out, _} = System.cmd(program!(:ps), ["-o", "stat=", "-p", "#{pid}"])
    if String.starts_with?(String.trim(out), "Z"), do: {:ok, :zombie}, else: {:waiting, out}
  end

  # What `fun` answered and how long it took, in ms by the monotonic clock.
  defp timed(fun) do
    from = System.monotonic_time(:millisecond)
    answer = fun.()
    {System.monotonic_time(:millisecond) - from, answer}
  end

  # Holds `sh -c script` as `name` and answers the pid its record names.
  defp hold!(%{p: p, dir: dir}, name, script) do
    assert {:ok, _} =
             Holder.Process.hold(p, name, [program!(:sh), "-c", script, Path.join(dir, name)])

    assert {:ok, %{record: %{pid: pid}}} =
             await(fn ->
               case Holder.Process.read(p, [name]) do
                 {:ok, %{^name => %{record: %{}} = r}} -> {:ok, r}
                 other -> {:waiting, other}
               end
             end)

    pid
  end

  defp own_start(pid) do
    {out, 0} =
      System.cmd(program!(:env), [
        "LC_ALL=C",
        "TZ=UTC",
        program!(:ps),
        "-o",
        "lstart=",
        "-p",
        "#{pid}"
      ])

    Holder.Process.normal(out)
  end
end
