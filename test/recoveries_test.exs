defmodule CodingAgentFramework.RecoveriesTest do
  @moduledoc """
  `Recoveries` on a real tmux server and real dtach sockets in this test's own directory, with
  `cat` held as the agent's stand-in. Each sample and each check is a call, so the test reads
  what each event left without waiting on a timer; a process ending is waited on by its pid.
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
    {:ok, sampler} = TmuxSampler.start_link(server: server, holder: holder, db: db)
    me = self()

    opts = [
      sampler: sampler,
      control: control,
      holder: holder,
      server: server,
      db: db,
      size: {80, 24},
      notify: &send(me, {:cue, &1})
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
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: [id], ended: []}} = Recoveries.check(ctx.recoveries)
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

    # A second loss of the same agent is a new state.
    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, pane, "alpha")
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: [second]}} = Recoveries.check(ctx.recoveries)
    assert second != id

    {:ok, tracker} =
      Tracker.start_link(
        sources: [{Tracker.RecoveriesSource, db: ctx.db, host: "test", server: key(ctx)}],
        timer: false
      )

    {:ok, view} = Tracker.view(tracker)
    assert %{recoveries: [_, _]} = view[{"test", "tmux:" <> key(ctx)}]
  end

  test "a killed server comes back with the viewer", ctx do
    {child, _} = hold!(ctx, "alpha")
    {:ok, "%0"} = view(ctx, "alpha")
    assert held(ctx, "alpha").status == :viewed

    assert {:ok, :killed} = Tmux.kill_server(ctx.server)
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
    {:ok, id} = Table.claim(db, state, System.os_time(:millisecond))
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
    assert held(ctx, "alpha").status == :unviewed
    # The host's writer is gone: the open is refused before it reaches tmux.
    :ok = GenServer.stop(ctx.control)

    assert {:ok, %{claimed: [_]}} = Recoveries.check(ctx.recoveries)
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
    assert rows(ctx) == []
  end

  defp key(ctx), do: elem(Tmux.key(ctx.server), 1)

  defp rows(ctx) do
    {:ok, db} = Table.open(ctx.db)
    Table.rows(db, "test", key(ctx))
  end

  defp held(ctx, name) do
    assert {:ok, _} = TmuxSampler.sample(ctx.sampler)
    {:ok, %{rows: rows}} = TmuxSampler.rows(ctx.sampler)
    Enum.find(rows, &(&1.key == "held:" <> name))
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
