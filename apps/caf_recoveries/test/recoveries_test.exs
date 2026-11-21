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

  import CodingAgentFramework.RecoveriesSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Acts, Holder, Recoveries, RecoveriesSetup, Sessions, Tmux, Watch}
  alias CodingAgentFramework.TmuxSampler

  doctest Recoveries

  setup {RecoveriesSetup, :recoveries}

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

    assert [%{id: ^id, outcome: "unknown", reason: "session_exists", answer: "exists"}] =
             rows(ctx)

    # Its viewer dies before the next sample: the row still reads the same, yet it is a new loss.
    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, pane, "alpha")
    assert {:ok, second} = agree(ctx, "alpha")
    assert second != id
    assert [%{acted_at: at}, %{status: "acted", answer: "ok", state: state}] = rows(ctx)
    assert String.ends_with?(state, ":#{at}")
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
    assert %{outcome: "failed", reason: "repeating", acted_at: nil} = List.last(rows(ctx))
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert length(rows(ctx)) == 5

    # F-183: one clear, the remedy prompt's, which the healer copies onto its row.
    state = List.last(rows(ctx)).state
    assert {:ok, [%{id: sid, state: ^state}]} = Watch.read(ctx.watch, status: "asked")
    assert {:ok, :answered} = Watch.clear(ctx.watch, sid, "sam")
    assert {:ok, sixth} = agree(ctx, "alpha")
    assert %{id: ^sixth, status: "acted", answer: "ok"} = List.last(rows(ctx))
    {:ok, %{cleared_at: at}} = Acts.get(ctx.acts, id)
    assert {:ok, [%{answered_at: ^at}]} = Watch.read(ctx.watch, state: state)
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
    assert [%{status: "skipped", reason: reason, answer: nil}] = rows(ctx)
    assert reason == ~s(["sample_too_old",#{age}])
    assert held(ctx, "alpha").status == :unviewed

    # A fresh sample agrees with the last one checked, and its claim takes the row over.
    assert {:ok, %{claimed: [_]}} = Recoveries.check(ctx.recoveries)
    assert [%{status: "acted", reason: nil, answer: "ok"}] = rows(ctx)
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
    assert [%{status: "acted"} = acted] = rows(ctx)
    assert pane(acted) == "%0"
    assert JSON.decode!(acted.detail)["symptom"] =~ "lost_viewer:alpha:"

    assert %{status: :viewed} = held(ctx, "alpha")
    assert {:ok, %{generation: 1}} = TmuxSampler.rows(ctx.sampler)
    assert {:ok, %{ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert [%{outcome: "recovered"}] = rows(ctx)
    assert alive?(child)
  end

  test "a Recoveries restarted between its claim and its act does not act", ctx do
    hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    assert held(ctx, "alpha").status == :unviewed

    # The claim a Recoveries wrote just before it ended, with no act after it.
    {:ok, read} = TmuxSampler.rows(ctx.sampler)
    [lost] = Recoveries.lost_viewers(read, %{})
    state = "test:#{key(ctx)}:#{lost.key}"
    {:ok, id} = Acts.claim(ctx.acts, actor(ctx), "alpha", state, :reopen)
    ref = Process.monitor(ctx.recoveries)
    GenServer.stop(ctx.recoveries)
    assert_receive {:DOWN, ^ref, _, _, _}

    # The restarted Recoveries closes the claim it did not act on, and never acts on its state.
    {:ok, recoveries} = Recoveries.start_link(ctx.opts)
    assert [%{id: ^id, status: "interrupted", answer: nil}] = rows(ctx)
    assert {:ok, %{claimed: []}} = Recoveries.check(recoveries)
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(recoveries)
    assert {:ok, [%{id: ^id}]} = Acts.faults(ctx.acts, actor: actor(ctx))
    assert held(ctx, "alpha").status == :unviewed
  end

  test "a viewer that fails to open leaves a failed row and the agent running", ctx do
    # Held with no agent row: `Sessions` has no viewer command for it, so the open is refused
    # before it reaches tmux.
    {child, _} = hold!(ctx, "alpha", nil)
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])

    assert {:ok, _} = agree(ctx, "alpha")
    assert [%{outcome: "failed", reason: "no_session", acted_at: nil}] = rows(ctx)
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert {:ok, :live} = Holder.state(ctx.holder, "alpha")
    assert alive?(child)
  end

  test "a lost viewer of an interactive session is reopened with dtach -a", ctx do
    hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])

    assert {:ok, id} = agree(ctx, "alpha")
    assert [%{status: "acted", answer: "ok"}] = rows(ctx)
    assert {:ok, [dtach, "-a" | _] = argv} = Holder.viewer_argv(ctx.holder, "alpha")
    assert dtach == program!(:dtach)
    assert started_with(ctx, "alpha") == Enum.join(argv, " ")

    assert %{status: :viewed} = held(ctx, "alpha")
    assert {:ok, %{ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert [%{outcome: "recovered"}] = rows(ctx)
  end

  test "a lost viewer of a delegate is reopened following its event log", ctx do
    hold!(ctx, "delta", "delegate")
    log = log(ctx, "delta")
    File.mkdir_p!(Path.dirname(log))
    File.write!(log, "an event\n")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])

    assert {:ok, id} = agree(ctx, "delta")
    assert [%{status: "acted", answer: "ok"}] = rows(ctx)
    assert started_with(ctx, "delta") == Enum.join([program!(:tail), "-F", log], " ")
    # The viewer shows the log, which `dtach -a` of the held stand-in would not.
    assert {:ok, _} = await(fn -> if screen(ctx, "delta") =~ "an event", do: {:ok, :shown} end)

    assert %{status: :viewed} = held(ctx, "delta")
    assert {:ok, %{ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert [%{outcome: "recovered"}] = rows(ctx)
  end

  test "a lost viewer of a socket Sessions has no row of is not reopened", ctx do
    {child, _} = hold!(ctx, "alpha", nil)
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])

    assert {:ok, _} = agree(ctx, "alpha")
    assert [%{outcome: "failed", reason: "no_session", acted_at: nil}] = rows(ctx)
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert alive?(child)
  end

  test "a lost viewer is not reopened when the host's Sessions is gone", ctx do
    {child, _} = hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    :ok = GenServer.stop(ctx.sessions)

    assert {:ok, _} = agree(ctx, "alpha")
    assert [%{outcome: "failed", reason: "no_sessions", acted_at: nil}] = rows(ctx)
    assert held(ctx, "alpha").status == :unviewed
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

  test "F-118: an orphan's process is ended by its record, once; Sessions then stops its row",
       ctx do
    {:ok, procs} = Holder.Process.new(programs(), ctx.holder)
    script = ~s(trap '' TERM; ) <> echo_tail!(ctx.dir)
    on_exit(fn -> end_recorded(ctx.dir) end)

    assert {:ok, _} =
             Holder.Process.hold(procs, "lost", [
               program!(:sh),
               "-c",
               script,
               Path.join(ctx.dir, "lost")
             ])

    assert {:ok, %{pid: pid} = record} = await(fn -> record(procs, "lost") end)
    orphan!(ctx, "lost", record)

    # TERM is ignored, so KILL ends it at the grace; the row is the claim of that state.
    assert {:ok, _} = TmuxSampler.sample(ctx.sampler)
    assert {:ok, %{ends: [id]}} = Recoveries.check(ctx.recoveries)
    refute alive?(pid)
    assert [%{id: ^id, act: "end", outcome: "recovered", answer: "ended"}] = rows(ctx)

    # Sessions settles its row at the next cue; the state is never acted on again.
    Sessions.cue(ctx.sessions, %{topic: "tmux:test:#{key(ctx)}", ids: []})

    assert {:ok, %{reason: "ended"}} =
             await(fn ->
               case Sessions.Table.get(sessions_db(ctx), "test", "lost") do
                 %{status: "stopped"} = row -> {:ok, row}
                 other -> other
               end
             end)

    assert {:ok, %{ends: []}} = Recoveries.check(ctx.recoveries)

    # Its symptom was recorded before the end, and passed once no end was owed.
    assert {:ok, [%{kind: "end_owed", target: "lost", status: "passed", evidence: evidence}]} =
             Watch.read(ctx.watch, kind: "end_owed")

    assert evidence =~ ~s("pid":#{pid})
  end

  test "F-182: a lost viewer is recorded before its claim, and passes once viewed", ctx do
    hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])

    assert {:ok, id} = agree(ctx, "alpha")
    [%{state: state, claimed_at: claimed}] = rows(ctx)

    assert {:ok, [%{kind: "lost_viewer", target: "alpha", state: ^state, recorded_at: at}]} =
             Watch.read(ctx.watch, status: "open")

    assert at < claimed
    assert %{status: :viewed} = held(ctx, "alpha")
    assert {:ok, %{ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert {:ok, [%{status: "passed"}]} = Watch.read(ctx.watch)
  end

  test "F-182: past its kind's cap in the bound, a loss is asked, not claimed", ctx do
    watch = watch!(ctx, %{"lost_viewer" => %{remedy: "reopen", cap: 1}})
    {:ok, recoveries} = Recoveries.start_link(Keyword.put(ctx.opts, :watch, watch))
    hold!(ctx, "alpha")
    hold!(ctx, "beta")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])

    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: []}} = Recoveries.check(recoveries)
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: [id]}} = Recoveries.check(recoveries)
    assert [%{id: ^id, target: first}] = rows(ctx)

    assert {:ok, [%{target: other, reason: ~s(["cap",1,3600000]), remedy: "reopen"}]} =
             Watch.read(watch, status: "asked")

    assert Enum.sort([first, other]) == ["alpha", "beta"]
    # Asked once: the next check claims nothing and asks nothing more.
    assert {:ok, %{claimed: []}} = Recoveries.check(recoveries)
    assert {:ok, [_]} = Watch.read(watch, status: "asked")
  end

  test "F-182: a remedy whose verify fails leaves the list, and the next loss is asked", ctx do
    hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    assert {:ok, id} = agree(ctx, "alpha")
    assert [%{status: "acted"} = acted] = rows(ctx)
    pane = pane(acted)

    # The viewer is gone again before the sample that verifies it.
    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, pane, "alpha")
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert [%{outcome: "failed", reason: "not_viewed"}] = rows(ctx)

    assert {:ok, %{"lost_viewer" => %{allowed: false, last: %{act: "drop", by: "healer"}}}} =
             Watch.remedies(ctx.watch, :list)

    assert {:ok, [%{reason: ~s(["verify_failed","not_viewed"])}]} =
             Watch.read(ctx.watch, status: "asked")

    # The loss after it is a new state, off the list now: asked, never claimed.
    assert held(ctx, "alpha").status == :unviewed
    assert {:ok, %{claimed: []}} = Recoveries.check(ctx.recoveries)
    assert length(rows(ctx)) == 1

    assert {:ok, [%{reason: ~s(["verify_failed","not_viewed"])}, %{reason: "not_on_list"}]} =
             Watch.read(ctx.watch, status: "asked")
  end

  test "F-182: a claim a restart cut is asked", ctx do
    hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    assert held(ctx, "alpha").status == :unviewed
    {:ok, read} = TmuxSampler.rows(ctx.sampler)
    [lost] = Recoveries.lost_viewers(read, %{})
    state = "test:#{key(ctx)}:#{lost.key}"
    sym = %{kind: "lost_viewer", target: "alpha", state: state, source: actor(ctx), since: 1}
    {:ok, %{id: sid}} = Watch.record(ctx.watch, sym)
    {:ok, _} = Acts.claim(ctx.acts, actor(ctx), "alpha", state, :reopen)
    GenServer.stop(ctx.recoveries)

    {:ok, _} = Recoveries.start_link(ctx.opts)
    assert {:ok, [%{id: ^sid, reason: "interrupted"}]} = Watch.read(ctx.watch, status: "asked")
  end

  test "F-118 new-5: an end that settled unknown is asked, and its prompt's answer tries it again",
       ctx do
    {:ok, procs} = Holder.Process.new(programs(), ctx.holder)
    on_exit(fn -> end_recorded(ctx.dir) end)
    argv = [program!(:sh), "-c", echo_tail!(ctx.dir), Path.join(ctx.dir, "lost")]
    assert {:ok, _} = Holder.Process.hold(procs, "lost", argv)
    assert {:ok, %{pid: pid, start: start} = record} = await(fn -> record(procs, "lost") end)
    orphan!(ctx, "lost", record)

    # The end of this state was tried and its process outlived the KILL, as the row says.
    state = "test:#{key(ctx)}:end:lost:#{pid}:#{Holder.Process.normal(start)}"
    {:ok, first} = Acts.claim(ctx.acts, actor(ctx), "lost", state, :end)
    {:ok, :unknown} = Acts.settle(ctx.acts, first, :unknown, reason: :alive, acted: true)

    assert {:ok, _} = TmuxSampler.sample(ctx.sampler)
    assert {:ok, %{ends: []}} = Recoveries.check(ctx.recoveries)
    assert alive?(pid)
    assert {:ok, [%{id: ^first, cleared_at: nil}]} = Acts.faults(ctx.acts, target: "lost")
    # Its claim ended unknown, so its state is a person's (Heal.tla's Ended), once.
    assert {:ok, [%{id: sid, reason: ~s(["ended","unknown"])}]} =
             Watch.read(ctx.watch, status: "asked", state: state)

    assert {:ok, %{ends: []}} = Recoveries.check(ctx.recoveries)
    assert alive?(pid)
    assert {:ok, :answered} = Watch.answer(ctx.watch, sid, "leave", "sam")
    assert {:ok, %{ends: [second]}} = Recoveries.check(ctx.recoveries)
    refute alive?(pid)
    assert [%{cleared_at: at}, %{id: ^second, outcome: "recovered", state: again}] = rows(ctx)
    assert again == "#{state}:cleared:#{at}"
    assert {:ok, [%{answered_at: ^at}]} = Watch.read(ctx.watch, state: state)
    assert {:refused, :settled} = Watch.clear(ctx.watch, sid, "sam")
  end

  defp record(procs, name) do
    case Holder.Process.read(procs, [name]) do
      {:ok, %{^name => %{process: :live, record: record}}} -> {:ok, record}
      other -> {:waiting, other}
    end
  end

  # The orphan row Sessions' adoption leaves, with the held program's record.
  defp orphan!(ctx, name, %{pid: pid, start: start}) do
    db = sessions_db(ctx)

    row = %{
      host: "test",
      name: name,
      socket: name,
      account: "work",
      role: "parent",
      cwd: ctx.dir,
      resume: nil,
      session_id: nil,
      deadline: nil
    }

    Sessions.Table.update(db, Sessions.Table.starting(db, row),
      status: "orphan",
      reason: "no_session_file",
      pid: pid,
      proc_start: start
    )
  end

  defp sessions_db(ctx) do
    {:ok, db} = Sessions.Table.open(ctx.db)
    db
  end

  defp move(ctx, ms), do: :counters.add(ctx.time, 1, ms)

  # A Watch of its own, with the allow-list `remedies`, on the test's clock.
  defp watch!(ctx, remedies) do
    db = Path.join(ctx.dir, "watch.db")
    {:ok, watch} = Watch.start_link(db: db, remedies: remedies, clock: ctx.clock)
    watch
  end

  # The command tmux says the viewer pane of session `name` started with, and what it shows,
  # from this test's own tmux server.
  defp started_with(ctx, name),
    do: tmux!(ctx, ["list-panes", "-t", "=#{name}:", "-F", "\#{pane_start_command}"])

  defp screen(ctx, name), do: tmux!(ctx, ["capture-pane", "-p", "-t", "=#{name}:"])

  defp tmux!(ctx, args) do
    {out, 0} = System.cmd(program!(:tmux), ["-S", Path.join(ctx.dir, "tmux.sock") | args])
    String.trim(out)
  end

  # Kills the viewer, has it reopened, and verifies it: answers the new viewer's pane.
  defp lose_and_reopen(ctx, pane) do
    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, pane, "alpha")
    assert {:ok, id} = agree(ctx, "alpha")
    assert held(ctx, "alpha").status == :viewed
    assert {:ok, %{ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert %{id: ^id, outcome: "recovered"} = recovered = List.last(rows(ctx))
    pane(recovered)
  end

  # The reopened viewer's pane, in the act's detail beside its claim's symptom (F-193).
  defp pane(%{detail: detail}), do: JSON.decode!(detail)["pane"]
end
