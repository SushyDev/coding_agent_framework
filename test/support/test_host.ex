defmodule CodingAgentFramework.TestHost do
  @moduledoc """
  Test aids for the host layer: this VM's own directory, the programs from devenv, and a
  bounded wait on an announced event.
  """

  alias CodingAgentFramework.{Host, Programs, Shell}

  @doc "This VM's own directory, named with its OS pid. `test_helper.exs` makes and removes it."
  def vm_dir, do: Path.join(System.tmp_dir!(), "caf-#{System.pid()}")

  @doc "A new directory of the calling test's own, inside `vm_dir/0`."
  def test_dir do
    dir = Path.join(vm_dir(), "t#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  @doc "The local host tests run on, with devenv's kill."
  def host, do: Host.local("test", program!(:kill))

  @doc "`host`'s `Programs`, each path from devenv; `overrides` replace some of them."
  def programs(host \\ host(), overrides \\ %{}) do
    paths =
      Map.new(
        [:tmux, :dtach, :git, :gh, :sh, :rm, :kill, :env, :ps, :cat, :tail, :mkdir, :mkfifo],
        &{&1, program!(&1)}
      )

    {:ok, programs} = Programs.new(host, Map.merge(paths, overrides))
    programs
  end

  # The programs devenv exports as CAF_<NAME> (devenv.nix) that the tests run.
  @programs [
    :tmux,
    :dtach,
    :git,
    :gh,
    :sh,
    :bash,
    :rm,
    :mv,
    :env,
    :kill,
    :ps,
    :cat,
    :tail,
    :mkdir,
    :mkfifo,
    :echo,
    :sleep,
    true,
    :tlc
  ]

  @doc """
  The absolute path of one program, from devenv's `CAF_<NAME>` variable, never from `PATH`:
  `program!(:sh)` reads `CAF_SH`.
  """
  def program!(name) when name in @programs do
    case System.get_env(variable(name)) do
      "/" <> _ = path -> path
      other -> raise "#{variable(name)} is #{inspect(other)}; run: devenv shell -- mix test"
    end
  end

  @doc """
  Checks, before any test runs, that this VM runs the Erlang and Elixir devenv's lock gives and
  that every program's variable names a file. Returns `:ok` or raises naming each mismatch.
  """
  def check_environment! do
    release = List.to_string(:erlang.system_info(:otp_release))
    otp = File.read!(Path.join([:code.root_dir(), "releases", release, "OTP_VERSION"]))

    running = [
      {"CAF_OTP_VERSION", String.trim(otp)},
      {"CAF_ELIXIR_VERSION", System.version()}
    ]

    versions =
      for {variable, version} <- running, System.get_env(variable) != version do
        "#{variable} is #{inspect(System.get_env(variable))}, but this VM runs #{version}"
      end

    programs =
      for name <- @programs,
          path = System.get_env(variable(name), ""),
          not (Path.type(path) == :absolute and File.regular?(path)) do
        "#{variable(name)} is #{inspect(path)}"
      end

    case versions ++ programs do
      [] ->
        :ok

      wrong ->
        raise "not devenv's environment; run: devenv shell -- mix test\n" <>
                Enum.join(wrong, "\n")
    end
  end

  defp variable(name), do: "CAF_" <> String.upcase(Atom.to_string(name))

  @doc """
  Calls `check` until it returns `{:ok, value}` or `timeout` ms pass. The event is what `check`
  reads (a file a stand-in writes, a process gone); the pause between reads only spaces them.
  """
  def await(check, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await(check, deadline, nil)
  end

  defp await(check, deadline, last) do
    case check.() do
      {:ok, value} ->
        {:ok, value}

      other ->
        if System.monotonic_time(:millisecond) > deadline do
          {:timeout, other || last}
        else
          receive do
          after
            20 -> await(check, deadline, other)
          end
        end
    end
  end

  @doc "Reads a file a stand-in writes, once it has `expected`'s length."
  def read_when(path, expected) do
    await(fn ->
      case File.read(path) do
        {:ok, text} when byte_size(text) >= byte_size(expected) -> {:ok, text}
        # A short read is not done yet: `await/2` ends on any `{:ok, _}`.
        {:ok, text} -> {:short, text}
        other -> other
      end
    end)
  end

  @doc "Ends a process this test started, by its pid; one already gone is fine."
  def kill(pid, signal \\ "-TERM") do
    Shell.run(host(), program!(:kill), [signal, to_string(pid)], timeout: 5_000)
  end

  @doc "Whether a process lives, by its pid (`kill -0`)."
  def alive?(pid) do
    match?({:ok, %{status: 0}}, kill(pid, "-0"))
  end
end
