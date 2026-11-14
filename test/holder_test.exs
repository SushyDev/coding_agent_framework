defmodule CodingAgentFramework.HolderTest do
  @moduledoc """
  `Holder` on real dtach sockets in this test's own directory. The held stand-in writes its pid
  and dtach's pid to a file, so the test waits on that file and ends both by pid.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Holder, Host, Programs, Shell}

  doctest Holder

  setup do
    dir = test_dir()
    {:ok, holder} = Holder.new(programs(), dir)
    {:ok, dir: dir, holder: holder}
  end

  test "a holder needs its programs; a variable name is checked", %{holder: h} do
    {:ok, bare} = Programs.new(host(), %{dtach: program!(:dtach)})
    assert {:refused, {:no_program, [:sh, :env, :rm]}} = Holder.new(bare, "/x")

    assert {:refused, {:bad_variable, "A=B"}} =
             Holder.hold(h, "alpha", [program!(:cat)], env: [{"A=B", "c"}])

    assert {:ok, :absent} = Holder.state(h, "alpha")
  end

  test "over ssh, the held command is the same, quoted for the remote shell", %{holder: h} do
    box = Host.ssh("box", "/run/bin/ssh", "agent@box", program!(:sh), program!(:sleep))
    {:ok, [env | args] = argv} = Holder.hold_argv(h, "alpha", ["/run/claude"], [{"HOME", "/h"}])

    assert {:ok, {"/run/bin/ssh", [_, _, "--", "agent@box", remote]}} =
             Shell.command(box, env, args)

    assert remote == Enum.map_join(argv, " ", &Shell.shell_quote/1)
    assert [_env, "-i", "HOME=/h", _dtach, "-n" | _] = argv
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
    assert {:refused, {:live, "alpha"}} = Holder.hold(h, "alpha", [program!(:cat)])
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
    assert {:refused, {:bad_name, "../x"}} = Holder.hold(h, "../x", [program!(:cat)])
    long = String.duplicate("a", 64)

    assert {:refused, {:socket_path_too_long, _}} =
             Holder.hold(%{h | dir: "/" <> long}, long, [program!(:cat)])

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

    script =
      ~s(echo "$$ $PPID" > "$0.tmp" && #{program!(:mv)} "$0.tmp" "$0"; exec #{program!(:cat)})

    assert {:ok, _socket} = Holder.hold(h, name, [program!(:sh), "-c", script, pids])
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

defmodule CodingAgentFramework.HolderEnvTest do
  @moduledoc """
  A held process's environment on a real dtach socket. It sets variables in this VM's own
  environment, so it runs alone (`async: false`) and puts them back after.
  """
  use ExUnit.Case, async: false

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Holder, Shell}

  @leaks %{
    "CLAUDECODE" => "1",
    "CLAUDE_CODE_ENTRYPOINT" => "cli",
    "TMUX" => "/tmp/other,1,0",
    "TMUX_PANE" => "%9"
  }

  setup do
    before = Map.new(@leaks, fn {k, _} -> {k, System.get_env(k)} end)
    System.put_env(@leaks)

    on_exit(fn ->
      Enum.each(before, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    dir = test_dir()
    {:ok, holder} = Holder.new(programs(), dir)
    {:ok, dir: dir, holder: holder}
  end

  test "a held process sees exactly the variables it is given", %{dir: dir, holder: h} do
    allowed = [
      {"HOME", dir},
      {"PATH", "/nonexistent/bin"},
      {"LANG", "C.UTF-8"},
      {"CLAUDE_CONFIG_DIR", Path.join(dir, "account")}
    ]

    out = Path.join(dir, "stand-in")

    script =
      ~s(#{program!(:env)} > "$0.env"; echo "$$ $PPID" > "$0.tmp" && ) <>
        ~s(#{program!(:mv)} "$0.tmp" "$0"; exec #{program!(:cat)})

    assert {:ok, _} = Holder.hold(h, "alpha", [program!(:sh), "-c", script, out], env: allowed)
    assert {:ok, pids} = await(fn -> File.read(out) end)
    [child, _dtach] = String.split(pids)
    on_exit(fn -> if Holder.state(h, "alpha") == {:ok, :live}, do: kill(child) end)

    held = parse(File.read!(out <> ".env"))

    # The same sh, run by `env -i` alone, sets a few variables of its own (such as PWD and
    # SHLVL); the held process has those and the allowed ones, and nothing else.
    {:ok, %{status: 0, output: plain}} =
      Shell.run(host(), program!(:env), ["-i", program!(:sh), "-c", program!(:env)],
        timeout: 5_000
      )

    own = plain |> parse() |> Map.keys()

    assert Enum.sort(Map.keys(held)) ==
             Enum.sort(Enum.uniq(own ++ Enum.map(allowed, &elem(&1, 0))))

    for {k, v} <- allowed, do: assert(held[k] == v)
    for {k, _} <- @leaks, do: refute(Map.has_key?(held, k))
    assert System.get_env("CLAUDECODE") == "1"
  end

  defp parse(text) do
    for line <- String.split(text, "\n", trim: true),
        [k, v] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {k, v}
  end
end
