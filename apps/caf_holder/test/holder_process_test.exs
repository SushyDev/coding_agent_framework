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
