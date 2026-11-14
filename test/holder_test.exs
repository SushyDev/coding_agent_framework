defmodule CodingAgentFramework.HolderTest do
  @moduledoc """
  `Holder` on real dtach sockets in this test's own directory. The held stand-in writes its pid
  and dtach's pid to a file, so the test waits on that file and ends both by pid.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Holder

  doctest Holder

  setup do
    dir = test_dir()
    {:ok, dir: dir, holder: Holder.new(host(), dir, program!(:dtach))}
  end

  test "holds a process, lists it, and says it lives", %{holder: h} = ctx do
    {child, master} = hold!(ctx, "alpha")
    assert {:ok, :live} = Holder.state(h, "alpha")
    socket = Path.join(ctx.dir, "alpha.sock")
    assert {:ok, [%{name: "alpha", socket: ^socket, state: :live}]} = Holder.list(h)
    assert alive?(child) and alive?(master)
  end

  test "never removes or replaces a live socket", %{holder: h} = ctx do
    {child, _master} = hold!(ctx, "alpha")
    assert {:refused, {:live, "alpha"}} = Holder.hold(h, "alpha", ["/bin/cat"])
    assert {:refused, {:live, "alpha"}} = Holder.remove_stale(h, "alpha")
    assert {:ok, :live} = Holder.state(h, "alpha")
    assert alive?(child)
  end

  test "a socket whose dtach was killed hard is stale, and a new hold replaces it",
       %{holder: h} = ctx do
    {_child, master} = hold!(ctx, "alpha")
    kill(master, "-KILL")
    assert {:ok, :stale} = await(fn -> stale(h) end)
    assert {:ok, [%{name: "alpha", state: :stale}]} = Holder.list(h)

    {_child, master2} = hold!(ctx, "alpha")
    assert master2 != master
    assert {:ok, :live} = Holder.state(h, "alpha")
  end

  test "an absent socket, a bad name and a long path are named", %{holder: h} do
    assert {:ok, :absent} = Holder.state(h, "nobody")
    assert {:refused, {:absent, "nobody"}} = Holder.remove_stale(h, "nobody")
    assert {:refused, {:bad_name, "../x"}} = Holder.hold(h, "../x", ["/bin/cat"])
    long = String.duplicate("a", 64)

    assert {:refused, {:socket_path_too_long, _}} =
             Holder.hold(%{h | dir: "/" <> long}, long, ["/bin/cat"])

    assert {:ok, []} = Holder.list(h)
  end

  test "a viewer attaches with dtach -a to the socket", %{holder: h, dir: dir} do
    dtach = h.dtach
    socket = Path.join(dir, "alpha.sock")
    assert {:ok, [^dtach, "-a", ^socket | _]} = Holder.viewer_argv(h, "alpha")
  end

  defp stale(h) do
    case Holder.state(h, "alpha") do
      {:ok, :stale} -> {:ok, :stale}
      other -> other
    end
  end

  # Holds the stand-in and waits for its pids; ends both when the test ends.
  defp hold!(%{holder: h, dir: dir}, name) do
    pids = Path.join(dir, "#{name}-#{System.unique_integer([:positive])}.pids")
    script = ~S(echo "$$ $PPID" > "$0.tmp" && mv "$0.tmp" "$0"; exec /bin/cat)
    assert {:ok, _socket} = Holder.hold(h, name, ["/bin/sh", "-c", script, pids])
    assert {:ok, text} = await(fn -> File.read(pids) end)
    [child, master] = text |> String.split() |> Enum.map(&String.to_integer/1)

    # Ending the child ends its dtach. It is killed only while its socket is live, so the pid
    # is still the stand-in's and not a reused one.
    on_exit(fn ->
      if Holder.state(h, name) == {:ok, :live} and alive?(master), do: kill(child)
    end)

    {child, master}
  end
end
