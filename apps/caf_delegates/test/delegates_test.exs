defmodule CodingAgentFramework.DelegatesTest do
  @moduledoc """
  `Delegates` up to a held report, over a real `Sessions`, `Stream` and `Transcripts`, real
  dtach and tmux, a real git repository in this test's own directory, and the headless
  stand-in for Claude Code. Each test waits on rows and moves the test's clock instead of
  waiting for a deadline, and names the `Delegate.tla` steps it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Delegates, HeadlessStandIn, Holder, SessionsSetup, Stream}
  alias CodingAgentFramework.{Sessions, Transcripts, Usage}
  alias CodingAgentFramework.Delegates.Table

  setup {SessionsSetup, :sessions}

  setup ctx do
    repo = Path.join(ctx.dir, "repo")
    git!(ctx, ["init", "-q", "-b", "main", repo])

    git!(ctx, [
      "-C",
      repo,
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "commit",
      "-qm",
      "init",
      "--allow-empty"
    ])

    {:ok, accounts} = Accounts.new(Path.join(ctx.dir, "home"), ["work"])
    {:ok, file} = Accounts.usage_file(accounts, "work")
    File.mkdir_p!(Path.dirname(file))
    week = %{"seven_day" => %{"used_percentage" => 25, "resets_at" => 4_000_000_000}}
    File.write!(file, JSON.encode!(%{"rate_limits" => week}))
    db = Path.join(ctx.dir, "caf.db")
    usage = start_supervised!({Usage, accounts: accounts, host: "test", db: db})
    {:ok, _} = Usage.read(usage)
    transcripts = start_supervised!({Transcripts, programs: programs(), account: "work", db: db})
    fifo = Path.join(ctx.dir, "setup.fifo")
    {_, 0} = System.cmd(program!(:mkfifo), [fifo])

    project = %{
      name: "app",
      repo: repo,
      trunk: "main",
      setup: [],
      setup_timeout: 10_000,
      env: %{"HOME" => ctx.dir},
      branches: ~r/\Aunit\//,
      cap: 1
    }

    launch =
      SessionsSetup.headless(ctx, :at_start) |> Keyword.take([:claude, :env, :tool_timeout])

    opts = [
      host: "test",
      db: db,
      sessions_db: db,
      sessions: ctx.sessions,
      stream: ctx.stream,
      usage: usage,
      accounts: accounts,
      transcripts: %{"work" => transcripts},
      launch: launch,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      projects: %{
        "app" => project,
        "slow" => %{project | name: "slow", setup: [[program!(:cat), fifo]]}
      }
    ]

    delegates = start_supervised!(Supervisor.child_spec({Delegates, opts}, restart: :temporary))
    {:ok, dtable} = Table.open(db)
    {:ok, delegates: delegates, dopts: opts, fifo: fifo, dtable: dtable}
  end

  test "a start's row comes first, its brief goes in once, and its result is the report", ctx do
    # StartAsked, Called, CallAnswered, InputWritten, StopHandled.
    assert {:refused, {:unknown_project, "web"}} = start(ctx, "web", "unit/one")
    assert {:refused, {:bad, :branch}} = start(ctx, "app", "main")

    assert {:ok, %{id: id, name: "app-unit-one", account: "work", brief: {:ok, %{uuid: u}}}} =
             start(ctx, "app", "unit/one")

    assert %{brief_uuid: ^u, brief: "Review it."} = Table.get(ctx.dtable, id)
    # The cap counts a delegate until it ends: a finished one holds its report and its tree.
    assert {:refused, {:cap, 1}} = start(ctx, "app", "unit/two")

    assert {:ok, %{report: "held", text: text, mark: "[report " <> _}} =
             cue_until(ctx, id, &(&1.status == "finished"))

    assert text == "done #{u}"
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}"]

    # Its row leaves running once, and the report survives a restart.
    delegates = restart(ctx)
    cue(ctx, delegates)

    assert {:ok, [%{id: ^id, status: "finished", text: ^text}]} =
             Delegates.held(delegates, "main")

    assert {:ok, []} = Delegates.held(delegates, "other")
    assert {:refused, :no_delivery} = Delegates.deliver(delegates, id)
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}"]
  end

  test "a kill before the last reply is resumed once, after Sessions' row ends, and finishes",
       ctx do
    # KillSeen waits for Sessions' row to end (RunningSettled, F-61); then the resume, counted
    # first, with a message of its own since the brief went in; Called, CallAnswered,
    # InputWritten under that uuid, StopHandled.
    hold(ctx)
    assert {:ok, %{id: id, brief: {:ok, %{uuid: u}}}} = start(ctx, "app", "unit/one")
    stream_row(ctx, id, &(&1.messages[u].state == :delivered))
    kill_delegate(ctx, id, [])

    # Sessions has not settled its row yet: it still says running, so nothing is asked.
    assert %{status: "running"} = session_row(ctx, "app-unit-one")
    cue(ctx, current(ctx))
    # A call after the cast: Delegates has handled the cue.
    assert {:ok, []} = Delegates.held(current(ctx), "main")
    assert %{status: "running", resumes: 0, resume_uuid: nil} = Table.get(ctx.dtable, id)

    File.rm!(Path.join(ctx.dir, "hold"))
    {:ok, _} = resumed(ctx, id)

    assert {:ok, %{report: "held", text: text, resumes: 1, resume_uuid: r}} =
             cue_until(ctx, id, &(&1.status == "finished"))

    assert is_binary(r) and r != u
    assert text == "done #{r}"
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}", "message #{r}"]
  end

  test "a second kill before the last reply is the report, never resumed again", ctx do
    # KillSeen twice: the first resumed, the second failed with its text held as the report.
    hold(ctx)
    assert {:ok, %{id: id, brief: {:ok, %{uuid: u}}}} = start(ctx, "app", "unit/one")
    stream_row(ctx, id, &(&1.messages[u].state == :delivered))
    killed = kill_delegate(ctx, id, [])
    {:ok, %{resume_uuid: r}} = resumed(ctx, id)

    stream_row(ctx, id, &(&1.messages[r].state == :delivered))
    kill_delegate(ctx, id, killed)

    assert {:ok, %{report: "held", text: text, resumes: 1}} =
             cue_until(ctx, id, &(&1.status == "failed"))

    assert text =~ "killed twice"
    assert {:ok, [%{id: ^id, status: "failed"}]} = Delegates.held(current(ctx), "main")
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}", "message #{r}"]
  end

  test "a kill after the last reply is a finish, read from the transcript", ctx do
    # TranscriptRead: no result in the log, and the transcript ends with the reply.
    hold(ctx)
    assert {:ok, %{id: id, brief: {:ok, %{uuid: u}}}} = start(ctx, "app", "unit/one")
    %{transcript: path} = stream_row(ctx, id, &(&1.messages[u].state == :delivered))

    reply = %{
      "type" => "assistant",
      "uuid" => "a1",
      "message" => %{
        "id" => "m1",
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => "all done"}]
      }
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(reply) <> "\n")
    kill_delegate(ctx, id, [])

    # Sessions' row still runs: a finish does not wait for it.
    assert {:ok, %{report: "held", text: "all done", resumes: 0}} =
             cue_until(ctx, id, &(&1.status == "finished"))
  end

  test "after a restart, a starting row is settled by Sessions' row of its call", ctx do
    # Settled: running once Sessions' start, which ran on, is; the brief goes in once.
    task = Task.async(fn -> start(ctx, "slow", "unit/slow") end)

    {:ok, %{id: id}} =
      await(fn -> List.first(Table.with_status(ctx.dtable, "test", ~w(starting))) |> ok() end)

    {:ok, _} = await(fn -> ok(session_row(ctx, "slow-unit-slow")) end)

    Process.exit(ctx.delegates, :kill)
    assert {:unknown, {:exit, :killed}} = Task.await(task)
    delegates = restart(ctx)
    assert %{status: "starting"} = Table.get(ctx.dtable, id)

    File.write!(ctx.fifo, "go\n")

    {:ok, _} =
      await(
        fn -> if session_row(ctx, "slow-unit-slow").status == "running", do: {:ok, 1} end,
        10_000
      )

    Delegates.cue(delegates, %{topic: "sessions:test:work", ids: []})
    assert {:ok, %{brief_uuid: u}} = cue_until(ctx, id, &(&1.status == "finished"))
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}"]

    # Settled with no Sessions row of its call: past its deadline it never reached Sessions.
    lost =
      Table.starting(ctx.dtable, %{
        host: "test",
        parent: "main",
        project: "app",
        branch: "unit/lost",
        name: "app-unit-lost",
        account: "work",
        model: "opus",
        brief: "b",
        brief_uuid: "x",
        deadline: Agent.get(ctx.clock, & &1)
      })

    restart(ctx)
    assert {:ok, %{reason: "interrupted"}} = row_when(ctx, lost, &(&1.status == "refused"))
  end

  test "a report a waiting call takes is answered, never held; past its deadline it is held",
       ctx do
    hold(ctx)
    assert {:ok, %{id: id, name: name, brief: {:ok, %{uuid: u}}}} = start(ctx, "app", "unit/one")
    assert {:refused, {:no_delegate, ^id}} = Delegates.await_report(current(ctx), "other", id, 1)
    assert {:unknown, :timeout} = Delegates.await_report(current(ctx), "main", id, 200)

    # The wait passed while the turn ran: the report is held, for a message.
    allow(ctx, id, u)
    File.rm!(Path.join(ctx.dir, "hold"))
    {:ok, _} = cue_until(ctx, id, &(&1.status == "finished"))
    assert {:ok, [%{id: ^id}]} = Delegates.held(current(ctx), "main")

    # A second delegate's report, taken by the call that waits on it.
    # The project's cap is one: the first row is set apart so a second may start.
    Table.update(ctx.dtable, id, status: "refused")
    assert {:ok, %{id: two}} = start(ctx, "app", "unit/two")
    wait = caller(ctx, two, 10_000)
    assert {:ok, %{status: "finished"}} = cue_until(ctx, two, &(&1.report == "answering"))

    assert_receive {:took,
                    {:ok,
                     %{id: ^two, name: "app-unit-two", status: "finished", text: "done " <> _}}}

    assert {:ok, [%{id: ^id, name: ^name}]} = Delegates.held(current(ctx), "main")
    assert {:refused, :answering} = Delegates.await_report(current(ctx), "main", two, 1)

    # The answer reached the agent: answered, and never held, though its caller then ends.
    assert {:ok, :answered} = settle(wait, &Delegates.answered/2)
    assert %{report: "answered"} = Table.get(ctx.dtable, two)
    assert {:refused, :answered} = Delegates.await_report(current(ctx), "main", two, 1)
    assert {:refused, {:not_answering, "answered"}} = Delegates.release(current(ctx), two)
    assert {:refused, {:not_answering, "held"}} = Delegates.answered(current(ctx), id)
    assert {:refused, {:no_delegate, 99}} = Delegates.answered(current(ctx), 99)
    restart(ctx)
    assert {:ok, [%{id: ^id}]} = Delegates.held(current(ctx), "main")
  end

  test "a delegate stopped after its report is ended, and no longer holds its parent's cap",
       ctx do
    assert {:ok, %{id: id, name: name}} = start(ctx, "app", "unit/one")
    wait = caller(ctx, id, 10_000)
    {:ok, _} = cue_until(ctx, id, &(&1.report == "answering"))
    assert_receive {:took, {:ok, %{id: ^id}}}

    # Not yet answered to its agent: a stop is refused, and the row stays finished.
    assert {:ok, state} = Delegates.fix_state(current(ctx), "main", name)

    assert {:refused, {:report, "answering"}} =
             Delegates.fix(current(ctx), "main", name, :stop, state)

    assert {:ok, :answered} = settle(wait, &Delegates.answered/2)
    assert {:refused, {:cap, 1}} = start(ctx, "app", "unit/two")

    # Stopped: the process is gone, and the row is `ended` without a cue from the test, as the
    # stop's own end brings it. It is announced, and its cap is free.
    {:ok, state} = Delegates.fix_state(current(ctx), "main", name)
    assert {:ok, :stopped} = Delegates.fix(current(ctx), "main", name, :stop, state)

    {:ok, %{status: "ended", report: "answered"}} =
      await(fn ->
        case Table.get(ctx.dtable, id) do
          %{status: "ended"} = row -> {:ok, row}
          _ -> :none
        end
      end)

    assert {:ok, %{id: two}} = start(ctx, "app", "unit/two")
    assert two != id

    # A later cue does not move an ended row, and a second stop is refused.
    cue(ctx, current(ctx))
    assert %{status: "ended"} = Table.get(ctx.dtable, id)
    {:ok, state} = Delegates.fix_state(current(ctx), "main", name)
    assert {:refused, _} = Delegates.fix(current(ctx), "main", name, :stop, state)
  end

  test "an answering report is held again by a release, and by a restart, once", ctx do
    assert {:ok, %{id: id}} = start(ctx, "app", "unit/one")
    wait = caller(ctx, id, 10_000)
    {:ok, %{mark: mark}} = cue_until(ctx, id, &(&1.report == "answering"))
    assert_receive {:took, {:ok, %{id: ^id}}}
    assert {:ok, []} = Delegates.held(current(ctx), "main")

    # The answer's write failed: held again, with its own mark, for a message.
    assert {:ok, :held} = settle(wait, &Delegates.release/2)
    assert {:ok, [%{id: ^id, mark: ^mark}]} = Delegates.held(current(ctx), "main")

    # Taken again, and the process ends before it hears how the write went.
    assert {:ok, %{id: ^id}} = Delegates.await_report(current(ctx), "main", id, 1)
    assert %{report: "answering"} = Table.get(ctx.dtable, id)
    restart(ctx)
    assert {:ok, [%{id: ^id, mark: ^mark}]} = Delegates.held(current(ctx), "main")
    assert {:refused, {:not_answering, "held"}} = Delegates.answered(current(ctx), id)

    restart(ctx)
    assert {:ok, [%{id: ^id, mark: ^mark}]} = Delegates.held(current(ctx), "main")
  end

  # Delegate.tla's CallerSeen: Delegates watches the process that took a report.
  test "an answering report is held again when the process that took it ends", ctx do
    hold(ctx)
    assert {:ok, %{id: id, brief: {:ok, %{uuid: u}}}} = start(ctx, "app", "unit/one")

    # The caller ends while it waits: the take finds it gone, and holds the report again.
    # A wait of 0 ms is refused as :awaited once the caller waits, and never waits itself.
    gone = caller(ctx, id, 10_000)

    awaited? = fn ->
      Delegates.await_report(current(ctx), "main", id, 0) == {:refused, :awaited}
    end

    {:ok, _} = await(fn -> if awaited?.(), do: {:ok, 1} end)
    assert nil == Task.shutdown(gone, :brutal_kill)
    allow(ctx, id, u)
    File.rm!(Path.join(ctx.dir, "hold"))

    # The hold and the take are one step of Delegates, so its own answer, not the table, is read.
    {:ok, [%{mark: mark}]} =
      await(
        fn ->
          cue(ctx, current(ctx))

          case Delegates.held(current(ctx), "main") do
            {:ok, [%{id: ^id}]} = held -> held
            other -> {:not_yet, other}
          end
        end,
        10_000
      )

    assert %{report: "held"} = Table.get(ctx.dtable, id)

    # It takes the report and ends before it says how its write went.
    wait = caller(ctx, id, 10_000)
    assert_receive {:took, {:ok, %{id: ^id}}}
    assert %{report: "answering"} = Table.get(ctx.dtable, id)
    assert :ended = settle(wait, nil)
    assert {:ok, %{mark: ^mark}} = row_when(ctx, id, &(&1.report == "held"))
    assert {:refused, {:not_answering, "held"}} = Delegates.answered(current(ctx), id)

    # One that says answered first is not watched after: its end changes nothing.
    wait = caller(ctx, id, 10_000)
    assert_receive {:took, {:ok, %{id: ^id}}}
    assert {:ok, :answered} = settle(wait, &Delegates.answered/2)
    assert {:refused, :answered} = Delegates.await_report(current(ctx), "main", id, 1)
    assert %{report: "answered"} = Table.get(ctx.dtable, id)
  end

  # A caller as MCP's: one process waits on the report, sends what it took, then says how its
  # write went (`settle/2`'s function) and ends.
  defp caller(ctx, id, timeout) do
    test = self()
    delegates = current(ctx)

    Task.async(fn ->
      send(test, {:took, Delegates.await_report(delegates, "main", id, timeout)})

      receive do
        {:settle, nil} -> :ended
        {:settle, said} -> said.(delegates, id)
      end
    end)
  end

  defp settle(wait, said) do
    send(wait.pid, {:settle, said})
    Task.await(wait)
  end

  defp start(ctx, project, branch),
    do: Delegates.start_delegate(current(ctx), "main", project, branch, "opus", "Review it.")

  # A held turn waits on its permission request: answering it lets the turn end.
  defp allow(ctx, id, uuid) do
    %{session_id: sid} = Table.get(ctx.dtable, id)
    stream_row(ctx, id, &(&1.requests["req-" <> uuid] != nil))
    {:ok, _} = Stream.write(ctx.stream, sid, {:answer, "req-" <> uuid, :allow})
  end

  defp session_row(ctx, name),
    do: CodingAgentFramework.Sessions.Table.get(ctx.table, "test", name)

  defp ok(nil), do: nil
  defp ok(row), do: {:ok, row}

  # While the file is there, the stand-in's every turn waits on a permission: it runs on.
  defp hold(ctx), do: File.write!(Path.join(ctx.dir, "hold"), "")

  # Ends the delegate's current process by the pid its stand-in recorded (one not in `killed`),
  # waits until dtach has removed its socket and Stream has read the exit, and lets Delegates
  # see it as the embedding app would: Stream's cue comes. Answers the pids killed so far.
  defp kill_delegate(ctx, id, killed) do
    pids = Path.join(ctx.dir, "pids")
    {:ok, pid} = await(fn -> ok(List.first(File.ls!(pids) -- killed)) end)
    kill(pid)
    name = Table.get(ctx.dtable, id).name
    {:ok, _} = await(fn -> if Holder.state(ctx.holder, name) == {:ok, :absent}, do: {:ok, 1} end)
    stream_row(ctx, id, & &1.gone)
    Delegates.cue(current(ctx), %{topic: "stream:test", ids: []})
    [pid | killed]
  end

  # Cues Sessions, then Delegates, as the embedding app's wiring would, until the delegate's row has
  # counted its resume and runs again. Sessions' row says stopped only until the resume starts,
  # so the test waits on Delegates' row, not on that. One cue of Sessions may settle nothing
  # (F-61 new-3; this unit's new-5), so each poll cues again; a read of each after its cue
  # answers once the cue is handled, so cues never pile up ahead of the resume's call.
  defp resumed(ctx, id) do
    name = Table.get(ctx.dtable, id).name

    await(
      fn ->
        Sessions.cue(ctx.sessions, %{topic: "stream:test", ids: []})
        Sessions.viewer_argv(ctx.sessions, name)
        cue(ctx, current(ctx))
        Delegates.held(current(ctx), "main")
        row = Table.get(ctx.dtable, id)
        # Without a hold the resumed process can finish before this poll reads its row.
        if row.status in ["running", "finished"] and row.resumes == 1,
          do: {:ok, row},
          else: row
      end,
      10_000
    )
  end

  defp current(ctx), do: Process.get(:delegates, ctx.delegates)

  defp restart(ctx) do
    if Process.alive?(current(ctx)), do: Process.exit(current(ctx), :kill)
    child = Supervisor.child_spec({Delegates, ctx.dopts}, id: make_ref(), restart: :temporary)
    delegates = start_supervised!(child)
    Process.put(:delegates, delegates)
    delegates
  end

  defp cue(ctx, delegates) do
    {:ok, _} = Stream.read(ctx.stream)
    Delegates.cue(delegates, %{topic: "stream:test", ids: []})
  end

  # Reads Stream and cues Delegates until its row satisfies `ready?`.
  defp cue_until(ctx, id, ready?) do
    await(
      fn ->
        cue(ctx, current(ctx))
        row = Table.get(ctx.dtable, id)
        if row && ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end

  defp row_when(ctx, id, ready?) do
    await(
      fn ->
        row = Table.get(ctx.dtable, id)
        if row && ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end

  defp stream_row(ctx, id, ok?) do
    %{session_id: sid} = Table.get(ctx.dtable, id)

    {:ok, row} =
      await(
        fn ->
          {:ok, _} = Stream.read(ctx.stream)
          {:ok, %{rows: rows}} = Stream.rows(ctx.stream)
          row = Enum.find(rows, &(&1.session == sid))
          if row && safe(ok?, row), do: {:ok, row}, else: row
        end,
        10_000
      )

    row
  end

  defp safe(ok?, row) do
    ok?.(row) == true
  rescue
    _ -> false
  end

  defp git!(ctx, args) do
    {out, status} =
      System.cmd(program!(:env), ["-i", "HOME=#{ctx.dir}", program!(:git) | args],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("git #{inspect(args)}: #{out}")
    out
  end
end
