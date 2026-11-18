defmodule CodingAgentFramework.DelegatesTest do
  @moduledoc """
  `Delegates` with its brief and report in `Mailbox`, over a real `Sessions`, `Stream`,
  `Transcripts` and `Mailbox`, real dtach and tmux, a real git repository in this test's own
  directory, and the headless stand-in for Claude Code. Each test waits on rows and moves the
  test's clock instead of waiting for a deadline, and names the `Delegate.tla` steps it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Delegates, Grants, HeadlessStandIn, Holder, Mailbox}
  alias CodingAgentFramework.{Scheduler, Sessions, SessionsSetup, Stream, Transcripts, Usage}
  alias CodingAgentFramework.ClaudeCLI.Options
  alias CodingAgentFramework.Delegates.{Table, Work}
  alias CodingAgentFramework.Sessions.Agents

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

    transcripts =
      start_supervised!({Transcripts, programs: programs(), accounts: ["work"], db: db})

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
      SessionsSetup.headless(ctx, :on_message) |> Keyword.take([:claude, :env, :tool_timeout])

    opts = [
      host: "test",
      db: db,
      sessions_db: db,
      sessions: ctx.sessions,
      stream: ctx.stream,
      usage: usage,
      accounts: accounts,
      transcripts: transcripts,
      launch: launch,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      projects: %{
        "app" => project,
        "slow" => %{project | name: "slow", setup: [[program!(:cat), fifo]]}
      }
    ]

    {:ok, dtable} = Table.open(db)
    {:ok, mtable} = Mailbox.Table.open(db)
    {:ok, agents} = Agents.open(db, "test")
    tree = fn -> [%{name: "main", project: "app", parent: nil} | Agents.read_tree(agents)] end

    mopts = [db: db, grants: Grants.new(tree), stream: ctx.stream, sessions_db: db, host: "test"]
    mailbox = start_supervised!(Supervisor.child_spec({Mailbox, mopts}, id: make_ref()))
    opts = [{:mailbox, mailbox} | opts]
    delegates = start_supervised!(Supervisor.child_spec({Delegates, opts}, restart: :temporary))

    {:ok,
     delegates: delegates,
     dopts: opts,
     fifo: fifo,
     dtable: dtable,
     agents: agents,
     mailbox: mailbox,
     mopts: mopts,
     mtable: mtable}
  end

  test "a start's row comes first, its brief goes in once, and its result is the report", ctx do
    # StartAsked, Called, CallAnswered, InputWritten, StopHandled.
    assert {:refused, {:unknown_project, "web"}} = start(ctx, "web", "unit/one")
    assert {:refused, {:bad, :branch}} = start(ctx, "app", "main")

    assert {:ok, %{id: id, name: "app-unit-one", account: "work", brief_uuid: u}} =
             start(ctx, "app", "unit/one")

    # The brief is Mailbox's row, stored before the session, from the parent, under its uuid;
    # the agent row names the parent and the project.
    assert %{brief_uuid: ^u} = Table.get(ctx.dtable, id)
    assert %{kind: "delegate", parent: "main", project: "app"} = session_row(ctx, "app-unit-one")

    assert [%{uuid: ^u, kind: "brief", from_agent: "main", to_agent: "app-unit-one"}] =
             Enum.filter(rows(ctx), &(&1.kind == "brief"))

    # The cap counts a delegate until it ends: a finished one holds its report and its tree.
    assert {:refused, {:cap, 1}} = start(ctx, "app", "unit/two")

    assert {:ok, %{report: "taken", text: text}} = cue_until(ctx, id, &(&1.status == "finished"))
    assert text == "done #{u}"
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}"]

    # The report is the reply to the brief, and its row leaves running once, across a restart.
    assert {:ok, %{kind: "reply", from: "app-unit-one", to: "main", status: "queued"}} =
             Mailbox.answer_to(ctx.mailbox, u)

    delegates = restart(ctx)
    cue(ctx, delegates)
    assert [%{text: ^text}] = Enum.filter(rows(ctx), &(&1.reply_to == u))
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}"]
  end

  # Delegate.tla's TurnEndsBare, BoundPasses and IdleTold: IdleToldOnce and IdleNoticed.
  test "a delegate idle with no report is told to its parent once per idle state", ctx do
    restart(ctx, idle_bound: 60_000)

    assert {:ok, %{id: id, name: name, brief_uuid: u}} =
             Delegates.start_delegate(current(ctx), "main", "app", "unit/one", "opus", "quiet")

    stream_row(ctx, id, &(&1.idle and &1.messages[u].state == :delivered))
    idle_seen(ctx, id)
    assert notices(ctx) == []

    tick(ctx, 60_000)
    cue(ctx, current(ctx))
    assert [%{to_agent: "main", text: text}] = notices(ctx)
    assert text =~ "Delegate #{name} is idle with no report"

    # Once per idle state: a later cue, and a restart whose bound then passes again, tell no more.
    cue(ctx, current(ctx))
    restart(ctx, idle_bound: 60_000)
    idle_seen(ctx, id)
    tick(ctx, 60_000)
    cue(ctx, current(ctx))
    assert [_] = notices(ctx)

    # A turn that starts ends the state: the parent's message, whose turn ends the same way, is
    # a new idle state, told once its bound passes.
    {:ok, {:queued, m}} = Mailbox.message(ctx.mailbox, "main", name, "quiet again")
    {:ok, %{uuid: mu}} = mailbox_until(ctx, m, &(&1.status == "delivered"))
    stream_row(ctx, id, &(&1.idle and &1.messages[mu].state == :delivered))
    idle_seen(ctx, id)
    assert [_] = notices(ctx)
    tick(ctx, 60_000)
    cue(ctx, current(ctx))
    assert [_, _] = notices(ctx)

    # Never a kill or a nudge: the delegate took only its brief and the message, and runs on.
    assert %{status: "running", report: "none"} = Table.get(ctx.dtable, id)
    assert %{status: "running"} = session_row(ctx, name)
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}", "message #{mu}"]
  end

  # Delegate.tla's StartAgain: a start idempotent per branch.
  test "a second start of a branch answers its live delegate; one gone with no report starts again",
       ctx do
    hold(ctx)
    assert {:ok, %{id: id, name: name, brief_uuid: u} = first} = start(ctx, "app", "unit/one")

    # Live: the same delegate, with nothing written; the cap of one does not refuse it.
    assert start(ctx, "app", "unit/one") == {:ok, Map.put(first, :already, true)}
    assert [_] = Table.rows(ctx.dtable, "test")
    assert [_] = Enum.filter(rows(ctx), &(&1.kind == "brief"))

    assert {:refused, {:other_parent, ^name}} =
             Delegates.start_delegate(current(ctx), "other", "app", "unit/one", "opus", "Go.")

    # Gone with no report, its agent row settled stopped before Delegates resumes it: a new row,
    # and the old one is never resumed.
    stream_row(ctx, id, &(&1.messages[u].state == :delivered))
    kill_delegate(ctx, id, [])

    {:ok, _} =
      await(fn ->
        Sessions.cue(ctx.sessions, %{topic: "stream:test", ids: []})
        Sessions.viewer_argv(ctx.sessions, name)
        if session_row(ctx, name).status == "stopped", do: {:ok, 1}
      end)

    File.rm!(Path.join(ctx.dir, "hold"))
    assert {:ok, %{id: two, name: ^name, brief_uuid: u2}} = start(ctx, "app", "unit/one")
    assert two != id
    assert {:ok, %{report: "taken", text: text}} = cue_until(ctx, two, &(&1.status == "finished"))
    assert text == "done #{u2}"
    assert %{status: "running", resumes: 0, reason: "replaced"} = Table.get(ctx.dtable, id)
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}", "message #{u2}"]
  end

  test "a start whose init never comes takes a stop, and settles refused", ctx do
    # F-152: a stand-in that never writes its init, held past its first line. The row stays
    # starting; a parent's stop ends its held program by its record, and the start is refused.
    never = Keyword.put(ctx.dopts[:launch], :claude, HeadlessStandIn.write!(ctx.dir, :never))
    delegates = restart(%{ctx | dopts: Keyword.put(ctx.dopts, :launch, never)})
    name = "app-unit-one"

    call =
      Task.async(fn ->
        Delegates.start_delegate(delegates, "main", "app", "unit/one", "opus", "Review it.")
      end)

    {:ok, _} = await(fn -> if match?(%{viewer: "open"}, session_row(ctx, name)), do: {:ok, 1} end)

    # The brief went in right after the hold: the stand-in took it, and wrote no init.
    [%{brief_uuid: u}] = Table.rows(ctx.dtable, "test")
    taken = ["message #{u}"]
    {:ok, _} = await(fn -> if HeadlessStandIn.taken(ctx.dir) == taken, do: {:ok, 1} end)

    {:ok, %{status: "starting", offset: nil} = state} =
      Delegates.fix_state(delegates, "main", name)

    assert {:refused, {:not_started, "starting"}} =
             Delegates.fix(delegates, "main", name, :interrupt, state)

    assert {:ok, :stopped} = Delegates.fix(delegates, "main", name, :stop, state)
    assert {:refused, :stopped} = Task.await(call)
    assert [%{status: "refused", reason: "stopped"}] = Table.rows(ctx.dtable, "test")
    assert %{status: "refused", reason: "stopped"} = session_row(ctx, name)

    # Its replay settles the brief, whatever the start answered; nothing else went in.
    assert HeadlessStandIn.taken(ctx.dir) == taken

    {:ok, _} =
      await(fn ->
        {:ok, _} = Stream.read(ctx.stream)
        Mailbox.cue(ctx.mailbox, %{topic: "stream:test", ids: []})
        brief = Enum.find(rows(ctx), &(&1.kind == "brief"))
        if brief.status == "delivered", do: {:ok, brief}, else: brief
      end)
  end

  # Move.tla's NoStartWhileDraining: a move's drain starts no delegate under its session.
  describe "a lease (Schedule.tla)" do
    test "a start asks first; a refusal holds nothing, starts nothing and is no failed run",
         ctx do
      %{scheduler: scheduler} = with_scheduler(ctx, allowance: fn _ -> {:spent, 123} end)
      assert {:refused, {:lease, {:allowance, 123}}} = start(ctx, "app", "unit/one")

      assert [%{id: id, status: "refused", reason: reason}] = Table.rows(ctx.dtable, "test")
      assert reason == ~s(["lease",["allowance",123]])
      assert session_row(ctx, "app-unit-one") == nil
      assert Enum.filter(rows(ctx), &(&1.kind == "brief")) == []

      assert [%{outcome: "refused", holder: {"delegate", key}}] = Scheduler.leases(scheduler)
      assert key == "test:#{id}"
    end

    test "queued: its row is live while it waits; the Scheduler's end refuses it", ctx do
      %{scheduler: scheduler, work: work} = with_scheduler(ctx, resources: %{"seat" => 0})
      delegates = current(ctx)

      task =
        Task.async(fn ->
          Delegates.start_delegate(delegates, "main", "app", "unit/one", "opus", "Go.")
        end)

      {:ok, %{id: id}} =
        await(fn -> ok(List.first(Table.with_status(ctx.dtable, "test", ["starting"]))) end)

      assert Work.state(work, "test:#{id}") == :live
      GenServer.stop(scheduler)
      assert {:refused, {:lease, :scheduler_ended}} = Task.await(task)
      assert %{status: "refused"} = Table.get(ctx.dtable, id)
      assert Work.state(work, "test:#{id}") == :ended
    end

    test "queued, then refused at its deadline", ctx do
      with_scheduler(ctx, resources: %{"seat" => 0}, max_wait: 50)
      assert {:refused, {:lease, {:deadline, _}}} = start(ctx, "app", "unit/one")
      assert session_row(ctx, "app-unit-one") == nil
    end

    test "granted: the start runs under a lease that names its row", ctx do
      %{scheduler: scheduler, work: work} = with_scheduler(ctx, [])
      assert {:ok, %{id: id}} = start(ctx, "app", "unit/one")

      key = "test:#{id}"

      assert [
               %{
                 outcome: "granted",
                 class: "builder",
                 module: "app",
                 account: "work",
                 holder: {"delegate", ^key},
                 released_at: nil
               }
             ] =
               Scheduler.leases(scheduler)

      assert Work.state(work, key) == :live
      assert Work.state(work, "other:#{id}") == {:unknown, {:not_mine, "other:#{id}"}}
    end

    # Delegate.tla's WorkEndedIsFree (F-163's new-1): a start that reached Sessions after its
    # row was refused at its deadline runs under that row. The row is written refused here
    # while the process runs, as that race leaves it.
    test "a refused start whose process still lives keeps its seat", ctx do
      %{work: work} = with_scheduler(ctx, [])
      hold(ctx)
      assert {:ok, %{id: id, name: name, brief_uuid: u}} = start(ctx, "app", "unit/one")
      stream_row(ctx, id, &(&1.messages[u].state == :delivered))

      :ok = Table.update(ctx.dtable, id, status: "refused", reason: "interrupted")
      assert %{status: "running"} = session_row(ctx, name)
      assert Work.state(work, "test:#{id}") == :live

      # Its process gone and its agent row stopped, the seat goes.
      kill_delegate(ctx, id, [])

      {:ok, _} =
        await(fn ->
          Sessions.cue(ctx.sessions, %{topic: "stream:test", ids: []})
          Sessions.viewer_argv(ctx.sessions, name)
          if session_row(ctx, name).status == "stopped", do: {:ok, 1}
        end)

      assert Work.state(work, "test:#{id}") == :ended
    end
  end

  # A Scheduler over a seat, and a Delegates that asks it, in place of the setup's.
  defp with_scheduler(ctx, more) do
    {:ok, work} = Work.open(ctx.dopts[:db], ctx.dopts[:db], "test")

    sopts =
      Keyword.merge(
        [
          db: Path.join(ctx.dir, "leases.db"),
          host: "test",
          resources: %{"seat" => 1},
          holders: %{"delegate" => &Work.state(work, &1)}
        ],
        more
      )

    spec = Supervisor.child_spec({Scheduler, sopts}, id: make_ref(), restart: :temporary)
    scheduler = start_supervised!(spec)
    Process.exit(current(ctx), :kill)
    opts = ctx.dopts |> Keyword.put(:mailbox, mailbox(ctx)) |> Keyword.put(:scheduler, scheduler)
    child = Supervisor.child_spec({Delegates, opts}, id: make_ref(), restart: :temporary)
    Process.put(:delegates, start_supervised!(child))
    %{scheduler: scheduler, work: work}
  end

  test "no delegate starts under a parent a move drains", ctx do
    id = Sessions.Table.declare(ctx.table, "test", "main", "app")
    :ok = Sessions.Table.update(ctx.table, id, move: "draining")
    assert {:refused, {:moving, "main"}} = start(ctx, "app", "unit/one")
    assert [] = Table.latest(ctx.dtable, "test")

    :ok = Sessions.Table.update(ctx.table, id, move: nil)
    assert {:ok, %{name: "app-unit-one"}} = start(ctx, "app", "unit/one")
  end

  test "a kill before the last reply is resumed once, after Sessions' row ends, and finishes",
       ctx do
    # KillSeen waits for Sessions' row to end (RunningSettled, F-61); then the resume, counted
    # first, with a message of its own since the brief went in; Called, CallAnswered,
    # InputWritten under that uuid, StopHandled.
    hold(ctx)
    assert {:ok, %{id: id, brief_uuid: u}} = start(ctx, "app", "unit/one")
    stream_row(ctx, id, &(&1.messages[u].state == :delivered))
    kill_delegate(ctx, id, [])

    # Sessions has not settled its row yet: it still says running, so nothing is asked.
    assert %{status: "running"} = session_row(ctx, "app-unit-one")
    cue(ctx, current(ctx))

    assert %{status: "running", resumes: 0, resume_uuid: nil, report: "none"} =
             Table.get(ctx.dtable, id)

    File.rm!(Path.join(ctx.dir, "hold"))
    {:ok, _} = resumed(ctx, id)

    assert {:ok, %{report: "taken", text: text, resumes: 1, resume_uuid: r}} =
             cue_until(ctx, id, &(&1.status == "finished"))

    # The word to go on was Mailbox's row, from framework, and the report is still the reply to
    # the brief.
    assert is_binary(r) and r != u
    assert [%{kind: "resume", from_agent: "framework"}] = Enum.filter(rows(ctx), &(&1.uuid == r))
    assert text == "done #{r}"
    assert {:ok, %{kind: "reply"}} = Mailbox.answer_to(ctx.mailbox, u)
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}", "message #{r}"]
  end

  test "a delegate's own options are checked, kept on its row, and given again on its resume",
       ctx do
    start = &Delegates.start_delegate(ctx.delegates, "main", "app", "unit/one", "opus", "Go.", &1)
    bad = {:bad_option, :disallowed_tools, {:bad_pattern, "-x"}}
    assert start.(options: %{"disallowed_tools" => ["-x"]}) == {:refused, bad}
    assert Table.rows(ctx.dtable, "test") == []
    hold(ctx)
    options = %{"env" => %{"APP_MODE" => "review"}, "disallowed_tools" => ["WebFetch"]}
    assert {:ok, %{id: id, name: name, session_id: sid, brief_uuid: u}} = start.(options: options)
    kept = session_row(ctx, name).options
    assert {:ok, %{env: %{"APP_MODE" => "review"}}} = Options.decode(kept)

    stream_row(ctx, id, &(&1.messages[u].state == :delivered))
    kill_delegate(ctx, id, [])
    File.rm!(Path.join([ctx.dir, "argv", sid]))
    File.rm!(Path.join(ctx.dir, "hold"))
    {:ok, _} = resumed(ctx, id)
    {:ok, again} = await(fn -> if a = HeadlessStandIn.argv(ctx.dir, sid), do: {:ok, a} end)
    assert ["--disallowedTools", "WebFetch", "--resume"] -- again == []
    assert session_row(ctx, name).options == kept
  end

  test "a second kill before the last reply is the report, never resumed again", ctx do
    # KillSeen twice: the first resumed, the second failed with its text held as the report.
    hold(ctx)
    assert {:ok, %{id: id, brief_uuid: u}} = start(ctx, "app", "unit/one")
    stream_row(ctx, id, &(&1.messages[u].state == :delivered))
    killed = kill_delegate(ctx, id, [])
    {:ok, %{resume_uuid: r}} = resumed(ctx, id)

    stream_row(ctx, id, &(&1.messages[r].state == :delivered))
    kill_delegate(ctx, id, killed)

    assert {:ok, %{report: "taken", text: text, resumes: 1}} =
             cue_until(ctx, id, &(&1.status == "failed"))

    assert text =~ "killed twice"
    assert {:ok, %{kind: "notice", from: "framework"}} = Mailbox.answer_to(ctx.mailbox, u)
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}", "message #{r}"]
  end

  test "a kill after the last reply is a finish, read from the transcript", ctx do
    # TranscriptRead: no result in the log, and the transcript ends with the reply.
    hold(ctx)
    assert {:ok, %{id: id, brief_uuid: u}} = start(ctx, "app", "unit/one")
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
    assert {:ok, %{report: "taken", text: "all done", resumes: 0}} =
             cue_until(ctx, id, &(&1.status == "finished"))

    assert {:ok, %{kind: "reply", from: "app-unit-one"}} = Mailbox.answer_to(ctx.mailbox, u)
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

    Delegates.cue(delegates, %{topic: "sessions:test", ids: []})
    assert {:ok, %{brief_uuid: u}} = cue_until(ctx, id, &(&1.status == "finished"))
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}"]

    # Settled with no Sessions row of its call: past its deadline it never reached Sessions.
    lost =
      Table.starting(ctx.dtable, %{
        host: "test",
        branch: "unit/lost",
        name: "app-unit-lost",
        model: "opus",
        brief_uuid: "x",
        deadline: Agent.get(ctx.clock, & &1)
      })

    restart(ctx)
    assert {:ok, %{reason: "interrupted"}} = row_when(ctx, lost, &(&1.status == "refused"))
  end

  # Delivery.tla's call transport, as run_delegate takes a report: Told; past its deadline the
  # report stays due for its parent's other transport.
  test "a report a waiting call takes is delivered by its word; past its deadline it stays due",
       ctx do
    hold(ctx)
    assert {:ok, %{id: id, brief_uuid: u}} = start(ctx, "app", "unit/one")
    assert {:unknown, :timeout} = Mailbox.await(ctx.mailbox, "main", u, 200)

    # The wait passed while the turn ran: the report is due, taken by no call.
    allow(ctx, id, u)
    File.rm!(Path.join(ctx.dir, "hold"))
    {:ok, %{report: "taken"}} = cue_until(ctx, id, &(&1.status == "finished"))
    assert {:ok, %{status: "queued", kind: "reply"}} = Mailbox.answer_to(ctx.mailbox, u)

    # A second delegate's report, taken by the call that waits on it.
    # The project's cap is one: the first agent is set apart so a second may start.
    %{id: first} = session_row(ctx, Table.get(ctx.dtable, id).name)
    CodingAgentFramework.Sessions.Table.update(ctx.table, first, status: "ended")
    assert {:ok, %{id: two, brief_uuid: u2}} = start(ctx, "app", "unit/two")
    wait = caller(ctx, u2, 10_000)
    {:ok, _} = cue_until(ctx, two, &(&1.report == "taken"))
    assert_receive {:took, {:ok, %{kind: "reply", text: "done " <> ^u2}}}, 10_000
    assert {:ok, %{status: "sending", via: "call"}} = Mailbox.answer_to(ctx.mailbox, u2)

    # The answer reached the agent: delivered, though its caller then ends.
    assert {:ok, :delivered} = settle(wait, :written)
    assert {:ok, %{status: "delivered"}} = Mailbox.answer_to(ctx.mailbox, u2)
    assert {:ok, %{status: "queued"}} = Mailbox.answer_to(ctx.mailbox, u)
  end

  test "a delegate stopped after its report is ended, and no longer holds its parent's cap",
       ctx do
    assert {:ok, %{id: id, name: name, brief_uuid: u}} = start(ctx, "app", "unit/one")
    wait = caller(ctx, u, 10_000)
    {:ok, _} = cue_until(ctx, id, &(&1.report == "taken"))
    assert_receive {:took, {:ok, _}}, 10_000

    # Not yet delivered to its parent: a stop is refused, and the row stays finished.
    assert {:ok, state} = Delegates.fix_state(current(ctx), "main", name)

    assert {:refused, {:report, "sending"}} =
             Delegates.fix(current(ctx), "main", name, :stop, state)

    assert {:ok, :delivered} = settle(wait, :written)
    assert {:refused, {:cap, 1}} = start(ctx, "app", "unit/two")

    # A row to it still open refuses the stop too: it would be cut. The word goes in while a
    # turn the parent's message started waits on a permission, so the row stays due.
    hold(ctx)
    {:ok, {:queued, busy}} = Mailbox.message(ctx.mailbox, "main", name, "Busy.")
    {:ok, %{uuid: b}} = mailbox_until(ctx, busy, &(&1.status == "delivered"))
    stream_row(ctx, id, &(&1.requests["req-" <> b] != nil))
    {:ok, {:queued, open}} = Mailbox.go_on(ctx.mailbox, name, "Later.", Stream.uuid())
    {:ok, state} = Delegates.fix_state(current(ctx), "main", name)

    assert {:refused, {:open, [^open]}} =
             Delegates.fix(current(ctx), "main", name, :stop, state)

    File.rm!(Path.join(ctx.dir, "hold"))
    allow(ctx, id, b)
    {:ok, _} = mailbox_until(ctx, open, &(&1.status == "delivered"))
    stream_row(ctx, id, & &1.idle)

    # Stopped: the process is gone, and the agent row is `ended` without a cue from the test, as
    # the stop's own end brings it. It keeps its place in the tree, and its cap is free.
    {:ok, state} = Delegates.fix_state(current(ctx), "main", name)
    assert {:ok, :stopped} = Delegates.fix(current(ctx), "main", name, :stop, state)

    {:ok, %{status: "ended"}} =
      await(fn ->
        case session_row(ctx, name) do
          %{status: "ended"} = row -> {:ok, row}
          _ -> :none
        end
      end)

    assert %{status: "finished", report: "taken"} = Table.get(ctx.dtable, id)
    assert Agents.children(ctx.agents, "main") == 0
    assert {:ok, %{id: two}} = start(ctx, "app", "unit/two")
    assert two != id

    # A later cue does not move an ended agent, and a second stop is refused.
    cue(ctx, current(ctx))
    assert %{status: "ended"} = session_row(ctx, name)
    {:ok, state} = Delegates.fix_state(current(ctx), "main", name)
    assert {:refused, _} = Delegates.fix(current(ctx), "main", name, :stop, state)
  end

  # F-153's new-7 (`Team.tla`'s RefusedEnded): a start refused once its call reached Sessions,
  # its process gone with no report, as the first end-to-end run left one whose init never
  # came. No process of it runs again, so its agent row is ended, and it holds its parent's end
  # and cap no more. The refusal is written here as the late answer wrote it.
  test "a start refused after its process ran is ended, and frees its parent", ctx do
    hold(ctx)
    assert {:ok, %{id: id, name: name}} = start(ctx, "app", "unit/one")
    Table.update(ctx.dtable, id, status: "refused", reason: "ended")
    kill_delegate(ctx, id, [])

    {:ok, _} =
      await(fn ->
        Sessions.cue(ctx.sessions, %{topic: "stream:test", ids: []})
        Sessions.viewer_argv(ctx.sessions, name)
        cue(ctx, current(ctx))
        with %{status: "ended"} = row <- session_row(ctx, name), do: {:ok, row}
      end)

    assert %{status: "refused", resumes: 0, report: "none"} = Table.get(ctx.dtable, id)
    assert Agents.children(ctx.agents, "main") == 0
    assert {:ok, %{id: two}} = start(ctx, "app", "unit/two")
    assert two != id
  end

  # Delegate.tla's Report: handed once, under the brief's key, across restarts of Delegates.
  test "a report Mailbox did not take is handed again, once taken never twice", ctx do
    assert {:ok, %{id: id, brief_uuid: u}} = start(ctx, "app", "unit/one")
    GenServer.stop(ctx.mailbox)
    {:ok, %{report: "held", text: "done " <> _}} = cue_until(ctx, id, &(&1.status == "finished"))

    mailbox = start_mailbox(ctx)
    Process.put(:mailbox, mailbox)
    restart(ctx)
    {:ok, _} = cue_until(ctx, id, &(&1.report == "taken"))

    assert {:ok, %{kind: "reply", from: "app-unit-one", to: "main"}} =
             Mailbox.answer_to(mailbox, u)

    restart(ctx)
    cue(ctx, current(ctx))
    assert [_] = for(r <- Mailbox.Table.open_rows(ctx.mtable), r.reply_to == u, do: r)
  end

  # A caller as MCP's: one process waits on the report, sends what it took, then says how its
  # write went (`settle/2`'s function) and ends.
  defp caller(ctx, key, timeout) do
    test = self()
    mailbox = mailbox(ctx)

    Task.async(fn ->
      took = Mailbox.await(mailbox, "main", key, timeout)
      send(test, {:took, took})

      receive do
        {:settle, nil} -> :ended
        {:settle, said} -> Mailbox.told(mailbox, elem(took, 1).id, said)
      end
    end)
  end

  defp mailbox(ctx), do: Process.get(:mailbox, ctx.mailbox)

  defp start_mailbox(ctx),
    do: start_supervised!(Supervisor.child_spec({Mailbox, ctx.mopts}, id: make_ref()))

  defp mailbox_until(ctx, id, ready?) do
    await(
      fn ->
        cue(ctx, current(ctx))
        row = Mailbox.Table.get(ctx.mtable, id)
        if row && ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end

  defp settle(wait, said) do
    send(wait.pid, {:settle, said})
    Task.await(wait)
  end

  defp start(ctx, project, branch),
    do: Delegates.start_delegate(current(ctx), "main", project, branch, "opus", "Review it.")

  # A held turn waits on its permission request: answering it lets the turn end.
  defp allow(ctx, id, uuid) do
    %{session_id: sid} = session_row(ctx, Table.get(ctx.dtable, id).name)
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
        row = Table.get(ctx.dtable, id)
        # Without a hold the resumed process can finish before this poll reads its row.
        if row.status in ["running", "finished"] and row.resumes == 1,
          do: {:ok, row},
          else: row
      end,
      10_000
    )
  end

  defp rows(ctx), do: Enum.reject(Enum.map(1..50, &Mailbox.Table.get(ctx.mtable, &1)), &is_nil/1)

  # The framework's notices that a delegate is idle with no report.
  defp notices(ctx),
    do: Enum.filter(rows(ctx), &(&1.from_agent == "framework" and &1.kind == "msg"))

  defp tick(ctx, ms), do: Agent.update(ctx.clock, &(&1 + ms))

  # Cues until Delegates has read row `id`'s idle state: its bound runs from that read.
  defp idle_seen(ctx, id) do
    {:ok, _} =
      await(fn ->
        cue(ctx, current(ctx))
        if :sys.get_state(current(ctx)).idle[id], do: {:ok, 1}
      end)
  end

  defp current(ctx), do: Process.get(:delegates, ctx.delegates)

  defp restart(ctx, more \\ []) do
    if Process.alive?(current(ctx)), do: Process.exit(current(ctx), :kill)
    opts = ctx.dopts |> Keyword.put(:mailbox, mailbox(ctx)) |> Keyword.merge(more)
    child = Supervisor.child_spec({Delegates, opts}, id: make_ref(), restart: :temporary)
    delegates = start_supervised!(child)
    Process.put(:delegates, delegates)
    delegates
  end

  # Reads Stream, then cues Mailbox and Delegates as the embedding app's wiring would; a call
  # after each cast answers once it is handled.
  defp cue(ctx, delegates) do
    {:ok, _} = Stream.read(ctx.stream)
    Mailbox.cue(mailbox(ctx), %{topic: "stream:test", ids: []})
    Mailbox.status(mailbox(ctx), 0)
    Delegates.cue(delegates, %{topic: "stream:test", ids: []})
    :sys.get_state(delegates)
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
    %{session_id: sid} = session_row(ctx, Table.get(ctx.dtable, id).name)

    {:ok, row} =
      await(
        fn ->
          # Mailbox is cued too: the brief and the word to go on are its rows.
          {:ok, _} = Stream.read(ctx.stream)
          Mailbox.cue(mailbox(ctx), %{topic: "stream:test", ids: []})
          Mailbox.status(mailbox(ctx), 0)
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
