defmodule CodingAgentFramework.RecoveriesTest do
  @moduledoc """
  `Recoveries` on a real tmux server and real dtach sockets in this test's own directory, with
  `cat` held as the agent's stand-in. Each sample and each check is a call, so the test reads
  what each event left without waiting on a timer; a process ending is waited on by its pid.
  The sampler and `Recoveries` share a clock the test moves: it ticks one ms per reading, and
  the test jumps it forward, so no test sleeps.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Control, Holder, Recoveries, Sessions, Tmux, TmuxSampler, Tracker}
  alias CodingAgentFramework.Recoveries.Table
  alias CodingAgentFramework.Tmux.CLI

  doctest Recoveries
  doctest Table

  setup do
    dir = test_dir()
    {:ok, server} = CLI.new(programs(), {:socket, Path.join(dir, "tmux.sock")})
    on_exit(fn -> Tmux.kill_server(server) end)
    File.mkdir_p!(Path.join(dir, "d"))
    {:ok, holder} = Holder.new(programs(), Path.join(dir, "d"))
    {:ok, control} = Control.start_link(tmux: server)
    db = Path.join(dir, "r.db")
    time = :counters.new(1, [:atomics])
    :counters.put(time, 1, 1_000_000)

    clock = fn ->
      :counters.add(time, 1, 1)
      :counters.get(time, 1)
    end

    {:ok, sampler} = TmuxSampler.start_link(server: server, holder: holder, db: db, clock: clock)
    me = self()

    opts = [
      sampler: sampler,
      control: control,
      holder: holder,
      server: server,
      db: db,
      size: {80, 24},
      notify: &send(me, {:cue, &1}),
      clock: clock
    ]

    {:ok, recoveries} = Recoveries.start_link(opts)

    {:ok,
     dir: dir,
     db: db,
     server: server,
     holder: holder,
     control: control,
     sampler: sampler,
     opts: opts,
     time: time,
     clock: clock,
     recoveries: recoveries}
  end

  test "a killed viewer is reopened once and verified", ctx do
    {child, _} = hold!(ctx, "alpha")
    {:ok, viewer} = view(ctx, "alpha")
    # A pane of another session keeps the server up when the viewer goes.
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    assert held(ctx, "alpha").status == :viewed
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)

    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, viewer, "alpha")
    assert {:ok, id} = agree(ctx, "alpha")
    assert_received {:cue, %{topic: "recoveries:test:" <> _, ids: [^id]}}
    # The same reading again claims nothing: it was read before the open.
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert [%{status: "opened", open: "ok", pane: pane}] = rows(ctx)
    assert pane != viewer

    assert held(ctx, "alpha").status == :viewed
    assert {:ok, %{claimed: [], ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert [%{status: "recovered", key: "lost_viewer:alpha:" <> _}] = rows(ctx)
    assert alive?(child)

    # A second loss of the same agent is a new state, named from the sample where its row
    # turned unviewed again: after the reopen.
    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, pane, "alpha")
    assert {:ok, second} = agree(ctx, "alpha")
    assert second != id
    [first, %{since: since}] = rows(ctx)
    assert since > first.opened_at

    {:ok, tracker} =
      Tracker.start_link(
        sources: [{Tracker.RecoveriesSource, db: ctx.db, host: "test", server: key(ctx)}],
        timer: false
      )

    {:ok, view} = Tracker.view(tracker)
    assert %{recoveries: [_, _]} = view[{"test", "tmux:" <> key(ctx)}]
  end

  test "a loss one sample read is not acted on", ctx do
    hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    # Read lost once, as when a start opens its viewer between the sampler's two reads.
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: []}} = Recoveries.check(ctx.recoveries)
    {:ok, _} = view(ctx, "alpha")
    assert held(ctx, "alpha").status == :viewed
    assert {:ok, %{claimed: []}} = Recoveries.check(ctx.recoveries)
    assert rows(ctx) == []
  end

  test "a viewer opened after two samples agree ends the state, and names the next loss", ctx do
    hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: []}} = Recoveries.check(ctx.recoveries)
    assert held(ctx, "alpha").status == :unviewed
    # Another part opens the viewer after the second sample and before the check acts.
    {:ok, pane} = view(ctx, "alpha")
    assert {:ok, %{claimed: [id]}} = Recoveries.check(ctx.recoveries)
    assert [%{id: ^id, status: "unknown", reason: ":session_exists", open: "exists"}] = rows(ctx)

    # Its viewer dies before the next sample: the row still reads the same, yet it is a new loss.
    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, pane, "alpha")
    assert {:ok, second} = agree(ctx, "alpha")
    assert second != id
    assert [%{opened_at: at}, %{status: "opened", open: "ok", since: at}] = rows(ctx)
  end

  test "a third loss within the window waits for a person", ctx do
    hold!(ctx, "alpha")
    {:ok, pane} = view(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])

    pane = lose_and_reopen(ctx, pane)
    pane = lose_and_reopen(ctx, pane)
    # The window passes: the two losses before it do not count.
    move(ctx, 61_000)
    pane = lose_and_reopen(ctx, pane)
    pane = lose_and_reopen(ctx, pane)

    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, pane, "alpha")
    assert {:ok, id} = agree(ctx, "alpha")
    assert %{status: "failed", reason: ":repeating", opened_at: nil} = List.last(rows(ctx))
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert length(rows(ctx)) == 5

    assert {:refused, :not_repeating} = Recoveries.clear(ctx.recoveries, "beta")
    assert {:ok, [^id]} = Recoveries.clear(ctx.recoveries, "alpha")
    assert {:ok, sixth} = agree(ctx, "alpha")
    assert %{id: ^sixth, status: "opened", open: "ok"} = List.last(rows(ctx))
  end

  test "a sample older than the maximum age is not acted on, and the row says why", ctx do
    hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: []}} = Recoveries.check(ctx.recoveries)
    assert held(ctx, "alpha").status == :unviewed
    # The sampler stops; time passes.
    move(ctx, 31_000)
    assert {:refused, {:sample_too_old, age}} = Recoveries.check(ctx.recoveries)
    assert age > 30_000
    assert [%{status: "skipped", reason: reason, open: nil}] = rows(ctx)
    assert reason == inspect({:sample_too_old, age})
    assert held(ctx, "alpha").status == :unviewed

    # A fresh sample agrees with the last one checked, and its claim takes the row over.
    assert {:ok, %{claimed: [_]}} = Recoveries.check(ctx.recoveries)
    assert [%{status: "opened", reason: nil, open: "ok"}] = rows(ctx)
  end

  test "a killed server comes back with the viewer", ctx do
    {child, _} = hold!(ctx, "alpha")
    {:ok, "%0"} = view(ctx, "alpha")
    assert held(ctx, "alpha").status == :viewed

    assert {:ok, :killed} = Tmux.kill_server(ctx.server)
    assert held(ctx, "alpha").status == :no_server
    assert {:ok, %{claimed: []}} = Recoveries.check(ctx.recoveries)
    assert held(ctx, "alpha").status == :no_server
    assert {:ok, %{claimed: [id]}} = Recoveries.check(ctx.recoveries)
    assert [%{status: "opened", pane: "%0"}] = rows(ctx)

    assert %{status: :viewed} = held(ctx, "alpha")
    assert {:ok, %{generation: 1}} = TmuxSampler.rows(ctx.sampler)
    assert {:ok, %{ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert [%{status: "recovered"}] = rows(ctx)
    assert alive?(child)
  end

  test "a Recoveries restarted between its claim and its act does not act", ctx do
    hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    assert held(ctx, "alpha").status == :unviewed

    # The claim a Recoveries wrote just before it ended, with no act after it.
    {:ok, read} = TmuxSampler.rows(ctx.sampler)
    [lost] = Recoveries.lost_viewers(read, %{})
    {:ok, db} = Table.open(ctx.db)
    state = Map.merge(lost, %{host: "test", server: key(ctx)})
    {:ok, id} = Table.claim(db, state, ctx.clock.())
    ref = Process.monitor(ctx.recoveries)
    GenServer.stop(ctx.recoveries)
    assert_receive {:DOWN, ^ref, _, _, _}

    {:ok, recoveries} = Recoveries.start_link(ctx.opts)
    assert {:ok, %{claimed: []}} = Recoveries.check(recoveries)
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: [], ended: [^id]}} = Recoveries.check(recoveries)
    assert [%{status: "unknown", reason: ":interrupted", open: nil}] = rows(ctx)
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(recoveries)
    assert held(ctx, "alpha").status == :unviewed
  end

  test "a viewer that fails to open leaves a failed row and the agent running", ctx do
    {child, _} = hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    # The host's writer is gone: the open is refused before it reaches tmux.
    :ok = GenServer.stop(ctx.control)

    assert {:ok, _} = agree(ctx, "alpha")
    assert [%{status: "failed", reason: ":no_control", opened_at: nil}] = rows(ctx)
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert {:ok, :live} = Holder.state(ctx.holder, "alpha")
    assert alive?(child)
  end

  test "a stale socket is not reopened", ctx do
    {_, master} = hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    kill(master, "-KILL")

    assert {:ok, :stale} =
             await(fn ->
               with {:ok, :live} <- Holder.state(ctx.holder, "alpha"), do: {:live, :not_yet}
             end)

    assert held(ctx, "alpha").status == :stale
    assert {:ok, %{claimed: []}} = Recoveries.check(ctx.recoveries)
    assert held(ctx, "alpha").status == :stale
    assert {:ok, %{claimed: []}} = Recoveries.check(ctx.recoveries)
    assert rows(ctx) == []
  end

  defp key(ctx), do: elem(Tmux.key(ctx.server), 1)

  defp move(ctx, ms), do: :counters.add(ctx.time, 1, ms)

  defp rows(ctx) do
    {:ok, db} = Table.open(ctx.db)
    Table.rows(db, "test", key(ctx))
  end

  defp held(ctx, name) do
    assert {:ok, _} = TmuxSampler.sample(ctx.sampler)
    {:ok, %{rows: rows}} = TmuxSampler.rows(ctx.sampler)
    Enum.find(rows, &(&1.key == "held:" <> name))
  end

  # Two samples read `name` lost, a check after each: the first claims nothing, the second
  # claims one state, whose id it answers.
  defp agree(ctx, name) do
    assert held(ctx, name).status in [:unviewed, :no_server]
    assert {:ok, %{claimed: []}} = Recoveries.check(ctx.recoveries)
    assert held(ctx, name).status in [:unviewed, :no_server]
    assert {:ok, %{claimed: [id]}} = Recoveries.check(ctx.recoveries)
    {:ok, id}
  end

  # Kills the viewer, has it reopened, and verifies it: answers the new viewer's pane.
  defp lose_and_reopen(ctx, pane) do
    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, pane, "alpha")
    assert {:ok, id} = agree(ctx, "alpha")
    assert held(ctx, "alpha").status == :viewed
    assert {:ok, %{ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert %{id: ^id, status: "recovered", pane: new} = List.last(rows(ctx))
    new
  end

  defp view(ctx, name) do
    {:ok, argv} = Holder.viewer_argv(ctx.holder, name)
    Sessions.viewer(ctx.control, name, argv, {80, 24})
  end

  # Holds the stand-in and waits for its pids; ends it when the test ends, while its socket lives.
  defp hold!(%{holder: h, dir: dir}, name) do
    pids = Path.join(dir, "#{name}.pids")

    script =
      ~s(echo "$$ $PPID" > "$0.tmp" && #{program!(:mv)} "$0.tmp" "$0"; exec #{program!(:cat)})

    assert {:ok, _} = Holder.hold(h, name, [program!(:sh), "-c", script, pids])
    assert {:ok, text} = await(fn -> File.read(pids) end)
    [child, master] = text |> String.split() |> Enum.map(&String.to_integer/1)

    on_exit(fn ->
      if Holder.state(h, name) == {:ok, :live} and alive?(master), do: kill(child)
    end)

    {child, master}
  end
end
