defmodule CodingAgentFramework.RunsTest do
  @moduledoc """
  Heavy commands under a lease (F-171, `Schedule.tla`'s shape `Native`): the `PreToolUse`
  rewrite, and the wrapper itself, run with the real `sh`, `curl` and `ps` against a real
  `Scheduler` behind `Runs.Plug` on a real port.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost, except: [await: 1, await: 2]

  alias CodingAgentFramework.{Runs, Scheduler, Shell}

  doctest Runs
  doctest Runs.Plug

  @secret "s3cret"

  defp runs(dir, heavy \\ [%{match: ~r/\bmake\b/, class: :heavy}]) do
    {:ok, runs} = Runs.new(dir, programs(), heavy)
    runs
  end

  describe "the rewrite" do
    setup do
      {:ok, runs: runs("/srv/the home")}
    end

    defp bash(command, extra \\ %{}) do
      %{
        agent: "fix-1",
        tool_name: "Bash",
        tool_use_id: "toolu_01A",
        tool_input: Map.merge(%{"command" => command}, extra)
      }
    end

    test "a heavy Bash call runs under the wrapper; every other field stays", %{runs: runs} do
      pre = Runs.pre_tool_use(runs, nil)
      event = bash("make test && echo 'done'", %{"run_in_background" => true, "timeout" => 9})

      assert {:allow, updated_input: input} = pre.(event)

      assert input == %{
               "command" =>
                 ~S('/srv/the home/bin/caf-run' heavy 'toolu_01A' 'fix-1' -- ) <>
                   ~S('make test && echo '\''done'\'''),
               "run_in_background" => true,
               "timeout" => 9
             }

      # The wrapped call is not wrapped again.
      assert pre.(bash(input["command"])) == :pass
    end

    test "the app answers first: a deny stands, a pass or a correction is rewritten",
         %{runs: runs} do
      deny = Runs.pre_tool_use(runs, fn _ -> {:deny, "not here"} end)
      assert deny.(bash("make")) == {:deny, "not here"}

      fix = fn _ ->
        {:allow, updated_input: %{"command" => "make -j2"}, additional_context: "c"}
      end

      assert {:allow, [updated_input: %{"command" => c}, additional_context: "c"]} =
               Runs.pre_tool_use(runs, fix).(bash("make"))

      assert c =~ "-- 'make -j2'"

      crash = Runs.pre_tool_use(runs, fn _ -> raise "boom" end)
      assert {:allow, _} = crash.(bash("make"))
    end

    test "what is not heavy, not Bash, or of no known agent is the app's answer",
         %{runs: runs} do
      pre = Runs.pre_tool_use(runs, fn _ -> :ask end)
      assert pre.(bash("ls")) == :ask
      assert Runs.pre_tool_use(runs, nil).(bash("ls")) == :pass
      assert Runs.pre_tool_use(runs, nil).(%{bash("make") | tool_name: "Read"}) == :pass
      assert Runs.pre_tool_use(runs, nil).(%{bash("make") | agent: nil}) == :pass
    end
  end

  describe "the wrapper" do
    setup do
      dir = test_dir()
      runs = runs(dir)
      {:ok, dir: dir, runs: runs}
    end

    # A Scheduler on one slot, its owner of a run's lease the process itself, read every 50 ms.
    defp serve(%{dir: dir, runs: runs}, opts \\ []) do
      {plug_opts, opts} = Keyword.pop(opts, :plug, [])

      {:ok, s} =
        Scheduler.start_link(
          [
            db: Path.join(dir, "leases.db"),
            host: "ws",
            resources: %{"slot" => 1},
            holders: %{"run" => &Runs.state(runs, &1)},
            interval: 50
          ] ++ opts
        )

      plug =
        {Runs.Plug,
         [
           scheduler: fn -> s end,
           units: fn :heavy, _ -> {:ok, %{"slot" => 1}} end,
           secret: @secret
         ] ++ plug_opts}

      server =
        start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      :ok = Runs.prepare(runs, programs(), port, @secret)
      s
    end

    defp wrapped(runs, id, command, timeout \\ 20_000) do
      Shell.run(host(), Runs.wrapper(runs), ["heavy", id, "fix-1", "--", command],
        timeout: timeout
      )
    end

    defp released?(s, id) do
      case Enum.find(Scheduler.leases(s), &(&1.request_id == "run:" <> id)) do
        %{released_at: at} = lease when is_integer(at) -> {:ok, lease}
        other -> {:held, other}
      end
    end

    test "the command's own output and exit code, and its end releases the lease once", ctx do
      s = serve(ctx)

      assert {:ok, %{status: 3, output: "out\nerr\n"}} =
               wrapped(ctx.runs, "toolu_1", "echo out; echo err >&2; exit 3")

      assert {:ok, lease} = await(fn -> released?(s, "toolu_1") end)

      assert %{class: "heavy", module: "fix-1", holder: {"run", _}, released_by: "monitor"} =
               lease

      # The same id again takes no second slot: its lease was used.
      assert {:ok, %{status: 75, output: out}} = wrapped(ctx.runs, "toolu_1", "echo again")
      assert out =~ "caf-run: not run: the lease was refused (used)"
      refute out =~ "again\n"
    end

    test "queued: one line while it waits, then it runs once the slot is free", ctx do
      s = serve(ctx)
      gate = Path.join(ctx.dir, "gate")
      {:ok, _} = Shell.run(host(), program!(:mkfifo), [gate], timeout: 5_000)

      held = ~s(echo held > '#{gate}.ran'; exec cat '#{gate}')
      first = Task.async(fn -> wrapped(ctx.runs, "toolu_a", held) end)

      {:ok, _} = read_when(gate <> ".ran", "held")

      err = Path.join(ctx.dir, "second.err")
      cmd = ~s('#{Runs.wrapper(ctx.runs)}' heavy toolu_b fix-1 -- 'echo second' 2> '#{err}')

      second =
        Task.async(fn -> Shell.run(host(), program!(:sh), ["-c", cmd], timeout: 20_000) end)

      assert {:ok, "caf-run: queued (position 1)\n"} = read_when(err, "caf-run: queued")

      File.write!(gate, "go\n")
      assert {:ok, %{status: 0, output: "go\n"}} = Task.await(first, 20_000)
      assert {:ok, %{status: 0, output: "second\n"}} = Task.await(second, 20_000)
      assert File.read!(err) == "caf-run: queued (position 1)\n"
      assert {:ok, _} = await(fn -> released?(s, "toolu_b") end)
    end

    # F-292: the wrapper's own wait is its request's deadline. The class waits a minute, the
    # plug's own wait is 300 ms: a wrapper with a longer wait keeps its place past the plug's,
    # one with none is refused at the plug's, and each is refused `caller_gone` at its own.
    test "a wrapper's own wait keeps its place past the plug's, and is refused caller_gone at it",
         ctx do
      serve(ctx, max_wait: 60_000, plug: [wait: 300, max_wait: 10_000])
      gate = Path.join(ctx.dir, "gate")
      {:ok, _} = Shell.run(host(), program!(:mkfifo), [gate], timeout: 5_000)
      held = ~s(echo held > '#{gate}.ran'; exec cat '#{gate}')
      first = Task.async(fn -> wrapped(ctx.runs, "toolu_a", held) end)
      {:ok, _} = read_when(gate <> ".ran", "held")

      wrapper = Runs.wrapper(ctx.runs)
      sh = fn cmd -> Shell.run(host(), program!(:sh), ["-c", cmd], timeout: 20_000) end
      err = Path.join(ctx.dir, "kept.err")

      kept =
        Task.async(fn ->
          sh.(~s('#{wrapper}' --wait 8 heavy toolu_w fix-1 -- 'echo kept' 2> '#{err}'))
        end)

      assert {:ok, _} = read_when(err, "caf-run: queued")

      # Behind it, one with no wait, then one whose wait comes from the environment.
      assert {:ok, %{status: 75, output: plain}} =
               sh.(~s('#{wrapper}' heavy toolu_p fix-1 -- 'echo plain'))

      assert plain =~ "caf-run: not run: the lease was refused (caller_gone)"

      from = System.monotonic_time(:millisecond)

      assert {:ok, %{status: 75, output: env}} =
               sh.(~s(CAF_RUN_WAIT=1 '#{wrapper}' heavy toolu_e fix-1 -- 'echo env'))

      assert env =~ "caf-run: not run: the lease was refused (caller_gone)"
      assert System.monotonic_time(:millisecond) - from >= 1_000

      # The first's place was kept all along: the slot goes to it.
      File.write!(gate, "go\n")
      assert {:ok, %{status: 0, output: "go\n"}} = Task.await(first, 20_000)
      assert {:ok, %{status: 0, output: out}} = Task.await(kept, 20_000)
      assert out == "kept\n" and File.read!(err) == "caf-run: queued (position 1)\n"

      # A wait over the plug's bound is refused at once, and one out of shape is a usage error.
      assert {:ok, %{status: 75, output: long}} =
               sh.(~s('#{wrapper}' --wait 11 heavy toolu_l fix-1 -- 'echo long'))

      assert long =~ "caf-run: not run: the lease was refused (long_wait)"

      for bad <- ["0", "1.5", "010", "abc"] do
        assert {:ok, %{status: 64}} =
                 sh.(~s(CAF_RUN_WAIT='#{bad}' '#{wrapper}' heavy toolu_b fix-1 -- 'echo bad'))
      end
    end

    # F-276: barred, the request waits in the queue and its line says why; at its deadline,
    # still barred, the refusal carries the level and the reading that set it.
    test "refused: one line with the whole reason and its time, exit 75, nothing run", ctx do
      serve(ctx,
        pressure: [source: {:level, fn -> {:ok, 4} end}, interval: 60_000],
        max_wait: 200
      )

      ran = Path.join(ctx.dir, "ran")

      assert {:ok, %{status: 75, output: out}} =
               wrapped(ctx.runs, "toolu_p", ~s(echo ran > '#{ran}'))

      assert out =~
               ~r/\Acaf-run: queued \(position 1; pressure severe: level 4 at 4\)\ncaf-run: not run: the lease was refused \(pressure severe: level 4 at 4\); try again after 20\d\d-/

      refute File.exists?(ran)
    end

    test "a kill of the running command releases its lease", ctx do
      s = serve(ctx)
      ran = Path.join(ctx.dir, "ran")
      held = ~s(echo held > '#{ran}'; exec '#{program!(:sleep)}' 60)
      run = Task.async(fn -> wrapped(ctx.runs, "toolu_k", held) end)
      {:ok, _} = read_when(ran, "held")

      {:held, %{holder: {"run", key}}} = released?(s, "toolu_k")
      [pid, _start] = String.split(key, " ", parts: 2)
      {:ok, _} = kill(pid, "-KILL")

      assert {:ok, %{released_by: "monitor"}} = await(fn -> released?(s, "toolu_k") end)
      assert {:ok, %{status: status}} = Task.await(run, 20_000)
      assert status != 0
      assert Runs.state(ctx.runs, key) == :ended
    end

    test "with no Scheduler it says so in one line and runs without a lease", ctx do
      plug =
        {Runs.Plug,
         scheduler: fn -> nil end, units: fn _, _ -> {:ok, %{"slot" => 1}} end, secret: @secret}

      server =
        start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      :ok = Runs.prepare(ctx.runs, programs(), port, @secret)

      assert {:ok, %{status: 0, output: out}} = wrapped(ctx.runs, "toolu_n", "echo ran")
      assert out == "caf-run: no lease (no_scheduler); the command runs without one\nran\n"
    end

    # The no-answer bound is by the clock (F-217): the wrapper asks once a second, so it sees
    # the bound pass at its next ask, one second and a late wake after it at most.
    test "with no answer it asks again until its bound by the clock, then runs without a lease",
         ctx do
      # A listener that hangs up on every ask: an answer never comes, and no other test's
      # server can take the port.
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)
      spawn_link(fn -> hang_up(listener) end)
      :ok = Runs.prepare(ctx.runs, programs(), port, @secret, unanswered: 2_000)

      from = System.monotonic_time(:millisecond)
      assert {:ok, %{status: 0, output: out}} = wrapped(ctx.runs, "toolu_d", "echo ran")
      waited = System.monotonic_time(:millisecond) - from

      assert out ==
               "caf-run: no lease (the framework did not answer); the command runs without one\n" <>
                 "ran\n"

      assert waited in 2_000..(2_000 + 1_500)
    end

    # One ask is bounded (F-218): curl's `--max-time` is the plug's `:wait` and 5 s. An intake
    # that accepts and never answers holds each ask to that bound, and the wrapper takes it as
    # no answer: it asks again while its no-answer bound lasts, then runs without a lease.
    test "an ask the intake never answers ends at its bound, and counts as no answer", ctx do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)
      test = self()
      spawn_link(fn -> stall(listener, test, []) end)
      # A bound of 1 s and the 5 s past it: 6 s an ask.
      :ok = Runs.prepare(ctx.runs, programs(), port, @secret, wait: 1_000, unanswered: 1_000)

      from = System.monotonic_time(:millisecond)
      assert {:ok, %{status: 0, output: out}} = wrapped(ctx.runs, "toolu_s", "echo ran", 40_000)
      waited = System.monotonic_time(:millisecond) - from

      assert out ==
               "caf-run: no lease (the framework did not answer); the command runs without one\n" <>
                 "ran\n"

      # Two asks were accepted: the first was cut at its bound and, the no-answer bound being
      # 1 s, the wrapper asked once more after a second's pause. Each bound has 3 s of stated
      # slack for the late wakes of a sleep and of curl's timer under load, and 0.1 s below for
      # the few ms between a curl's start and its accept.
      assert_received {:accepted, first}
      assert_received {:accepted, second}
      refute_received {:accepted, _}
      assert (second - first) in 6_900..(7_000 + 3_000)

      # No ask ran past its bound: the run is two asks, each cut at 6 s, and a pause.
      assert waited in 12_900..(13_000 + 3_000)
    end

    test "the wrapper's ask bound is the plug's wait and 5 s; a bad wait is refused", ctx do
      :ok = Runs.prepare(ctx.runs, programs(), 4790, @secret)
      assert File.read!(Runs.wrapper(ctx.runs)) =~ "asked='605.000'\n"

      :ok = Runs.prepare(ctx.runs, programs(), 4790, @secret, wait: 1_500)
      assert File.read!(Runs.wrapper(ctx.runs)) =~ "asked='6.500'\n"

      assert {:refused, :bad_wait} = Runs.prepare(ctx.runs, programs(), 4790, @secret, wait: 0)
      assert {:refused, :bad_wait} = Runs.prepare(ctx.runs, programs(), 4790, @secret, wait: 1.5)
    end

    test "a bound that is not a positive integer is refused", ctx do
      assert {:refused, :bad_unanswered} =
               Runs.prepare(ctx.runs, programs(), 4790, @secret, unanswered: 0)
    end
  end

  defp hang_up(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, conn} ->
        :gen_tcp.close(conn)
        hang_up(listener)

      {:error, _} ->
        :ok
    end
  end

  # A stand-in intake that accepts each connection, tells the test when, and never answers or
  # closes it: the sockets stay open with this process.
  defp stall(listener, test, held) do
    case :gen_tcp.accept(listener) do
      {:ok, conn} ->
        send(test, {:accepted, System.monotonic_time(:millisecond)})
        stall(listener, test, [conn | held])

      {:error, _} ->
        :ok
    end
  end

  test "the endpoint refuses a wrong secret and a request out of shape" do
    opts =
      Runs.Plug.init(scheduler: fn -> nil end, units: fn _, _ -> {:ok, %{}} end, secret: @secret)

    post = fn body, secret ->
      Plug.Test.conn(:post, "/runs", body)
      |> Plug.Conn.put_req_header("x-caf-secret", secret)
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Runs.Plug.call(opts)
    end

    assert post.("class=heavy", "wrong").status == 401
    assert %{status: 200, resp_body: "refused bad_class -\n"} = post.("class=main", @secret)
  end

  defp await(fun) do
    case CodingAgentFramework.TestHost.await(fun, 10_000) do
      {:ok, value} -> {:ok, value}
      other -> flunk("not reached: #{inspect(other)}")
    end
  end
end
