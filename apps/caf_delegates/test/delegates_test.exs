defmodule CodingAgentFramework.DelegatesTest do
  @moduledoc """
  `Delegates` up to a held report, over a real `Sessions`, `Stream` and `Transcripts`, real
  dtach and tmux, a real git repository in this test's own directory, and the headless
  stand-in for Claude Code. Each test waits on rows and moves the test's clock instead of
  waiting for a deadline, and names the `Delegate.tla` steps it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Delegates, HeadlessStandIn, SessionsSetup, Stream, Usage}
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

    launch = SessionsSetup.headless(ctx, :at_start) |> Keyword.take([:claude, :env])

    opts = [
      host: "test",
      db: db,
      sessions_db: db,
      sessions: ctx.sessions,
      stream: ctx.stream,
      usage: usage,
      accounts: accounts,
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

  test "an exit before its turn's result leaves the row running, with no report", ctx do
    # The kill path (the transcript's last reply, one resume) is a later unit: until it is
    # built, a gone process with no result is neither finished nor failed, and nothing is
    # written to it again.
    hold(ctx)
    assert {:ok, %{id: id, brief: {:ok, %{uuid: u}}}} = start(ctx, "app", "unit/one")
    stream_row(ctx, id, &(&1.messages[u].state == :delivered))
    kill_delegate(ctx, id)
    cue(ctx, current(ctx))
    assert {:ok, []} = Delegates.held(current(ctx), "main")

    assert %{status: "running", report: "none", resumes: 0, resume_uuid: nil} =
             Table.get(ctx.dtable, id)

    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}"]
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

  defp start(ctx, project, branch),
    do: Delegates.start_delegate(current(ctx), "main", project, branch, "opus", "Review it.")

  defp session_row(ctx, name),
    do: CodingAgentFramework.Sessions.Table.get(ctx.table, "test", name)

  defp ok(nil), do: nil
  defp ok(row), do: {:ok, row}

  # While the file is there, the stand-in's every turn waits on a permission: it runs on.
  defp hold(ctx), do: File.write!(Path.join(ctx.dir, "hold"), "")

  # Ends the delegate's current process by the pid its row in Sessions names, and lets
  # Delegates see the exit as the host app would: Stream reads, and its cue comes.
  defp kill_delegate(ctx, id) do
    %{pid: pid} = session_row(ctx, Table.get(ctx.dtable, id).name)
    kill(pid)
    stream_row(ctx, id, & &1.gone)
    Delegates.cue(current(ctx), %{topic: "stream:test", ids: []})
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
