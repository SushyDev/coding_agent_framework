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
        [
          :tmux,
          :dtach,
          :git,
          :gh,
          :rsync,
          :ssh,
          :flock,
          :nc,
          :wc,
          :lsof,
          :curl,
          :sh,
          :sleep,
          :rm,
          :kill,
          :env,
          :ps,
          :cat,
          :tail,
          :head,
          :mkdir,
          :mkfifo
        ],
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
    :rsync,
    :ssh,
    :flock,
    :nc,
    :wc,
    :lsof,
    :curl,
    :sh,
    :bash,
    :rm,
    :mv,
    :env,
    :kill,
    :ps,
    :cat,
    :tail,
    :head,
    :mkdir,
    :mkfifo,
    :stty,
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

  @doc """
  Like `await/2` for a part that settles only at a cue. Each poll first calls `cue` (which sends
  the cue the way the embedding app wires it), then waits until `server` has handled it, then calls
  `check`. A real host's sampler cues at each read, so a settle that decided nothing at one cue
  (a read that failed under load) is taken again at the next; one cue sent once and then waited
  on for the whole `timeout` is not what a host does. The wait on `server` ends at the same
  deadline, so the answer is `{:ok, value}`, or `{:timeout, last}` once `timeout` ms have
  passed, as `await/2` answers.

      await_cued(sessions, fn -> Sessions.cue(sessions, cue) end, fn -> row_if_stopped() end, 10_000)
  """
  def await_cued(server, cue, check, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    await(
      fn ->
        cue.()
        handled(server, deadline)
        check.()
      end,
      timeout
    )
  end

  # The cue is a cast: a call after it is answered once the cast was handled, since a process
  # reads its mailbox in order. One that passes the deadline is left to the next check.
  defp handled(server, deadline) do
    :sys.get_state(server, max(deadline - System.monotonic_time(:millisecond), 1))
    :ok
  catch
    :exit, {:timeout, _} -> :late
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

  @doc """
  Starts a `Shell.Reaper`, runs `path` with it in a process of its own, and writes `announce`
  once the reaper holds the command's group. For a `:peer` VM, which has this module's code.
  """
  def run_reaped(path, args, timeout, announce) do
    {:ok, reaper} = Shell.Reaper.start_link(programs: programs())
    spawn(fn -> Shell.run(host(), path, args, timeout: timeout, reaper: reaper) end)
    {:ok, _} = await(fn -> if Shell.Reaper.held(reaper) == %{}, do: :none, else: {:ok, :held} end)
    File.write!(announce, "held\n")
  end

  @doc "Whether a process lives, by its pid (`kill -0`)."
  def alive?(pid) do
    match?({:ok, %{status: 0}}, kill(pid, "-0"))
  end

  # The longest a test runs is ExUnit's 60 s timeout, and the longest that uses a stand-in took
  # about 1.2 s (F-66), so 90 s with no input outlasts every test and still ends a stand-in that
  # every cleanup missed soon after its run.
  @idle 90

  @doc """
  How many seconds a stand-in waits with no input before it ends by itself: no stand-in lives
  past its run for long, even one whose VM was killed before it could end anything.
  """
  def stand_in_idle, do: @idle

  @doc """
  The end of a held stand-in's script, in place of `exec cat`: it records its pid in
  `<dir>/pids/` and echoes each line it reads until `stand_in_idle/0` seconds pass with none.
  `$0` names a path under `dir`, so the echo's command line names the test's directory. It
  exits at once if `end_recorded/2` has already ended `dir`.

      script = ~s(echo $$ > "$0"; ) <> TestHost.echo_tail!(dir)
      Holder.hold(h, "alpha", [program!(:sh), "-c", script, Path.join(dir, "alpha.pid")])
  """
  def echo_tail!(dir) do
    File.mkdir_p!(Path.join(dir, "pids"))

    ~s(: 2>/dev/null > "#{dir}/pids/$$" || exit 0; exec #{program!(:bash)} -c ) <>
      ~s('while IFS= read -r -t #{@idle} l; do printf "%s\\n" "$l"; done' "$0")
  end

  @doc """
  Ends every process a stand-in recorded under `dir`, at any depth, by its pid alone. A stand-in
  records `pids/<pid>` beside its script. Each `pids` directory is first renamed, so a stand-in
  that starts after this cannot record and exits at once, and one that recorded is ended here.
  A pid is signaled only while its command line names `dir`, so a pid another program reused is
  never touched. Each gets CONT, since a stopped one acts on nothing else, then TERM; one alive
  after `wait` ms gets KILL. Answers the pids that were alive.

      iex> CodingAgentFramework.TestHost.end_recorded(CodingAgentFramework.TestHost.test_dir())
      []
  """
  def end_recorded(dir, wait \\ 5_000) do
    for pids <- Path.wildcard(Path.join(dir, "**/pids")), File.dir?(pids) do
      File.rename(pids, "#{pids}.ended-#{System.unique_integer([:positive])}")
    end

    live =
      for ended <- Path.wildcard(Path.join(dir, "**/pids.ended-*")),
          {:ok, names} <- [File.ls(ended)],
          name <- names,
          {pid, ""} <- [Integer.parse(name)],
          names?(pid, dir),
          uniq: true,
          do: pid

    for signal <- ["-CONT", "-TERM"], pid <- live, do: kill(pid, signal)

    with {:timeout, _} <- await(fn -> all_gone(live) end, wait) do
      for pid <- live, not gone?(pid), do: kill(pid, "-KILL")
      await(fn -> all_gone(live) end, wait)
    end

    live
  end

  @doc """
  Ends what this VM's tests left (`end_recorded/2`) and removes its directory. Each
  `test_helper.exs` calls it when the suite ends. A pid it had to end is printed: a per-test
  cleanup missed it.
  """
  def end_vm do
    case end_recorded(vm_dir()) do
      [] -> :ok
      left -> IO.puts(:stderr, "test VM ended what its tests left: #{Enum.join(left, " ")}")
    end

    File.rm_rf(vm_dir())
  end

  defp names?(pid, dir) do
    case Shell.run(host(), program!(:ps), ["-ww", "-o", "command=", "-p", "#{pid}"],
           timeout: 5_000
         ) do
      {:ok, %{status: 0, output: command}} -> String.contains?(command, dir <> "/")
      _ -> false
    end
  end

  # Gone only when kill says so: a kill that failed to run is no answer.
  defp gone?(pid), do: match?({:ok, %{status: s}} when s != 0, kill(pid, "-0"))

  defp all_gone(pids) do
    case Enum.reject(pids, &gone?/1) do
      [] -> {:ok, :gone}
      left -> {:alive, left}
    end
  end
end
