defmodule CodingAgentFramework.MoverSetup do
  @moduledoc """
  The setup `MoverTest` uses: two prepared accounts, `work` and `spare`, and over them, on a real
  tmux server and real dtach sockets in the test's own directory, a `Sessions` that puts
  `Intake`'s waiter hook into a main session's overlay, `Intake` behind Bandit, one `Registry`
  and one `Transcripts` over both accounts, a `Stream`, `Mailbox` with the waiter transport,
  `Acts` and the `Mover`, every cue routed by `Cues` from the parts' own declarations, as the
  embedding app routes them. The `Registry` and the `Stream` read on an interval, so a session
  file or an event log that changes is a cue; the `Transcripts` reads only when asked, so a test
  says when a waiter row's lines are read (`transcript_cue/1`).

  The `Mover`'s launch is the test's (`set_launch/2`): by default the interactive stand-in for a
  main session and the headless one for a delegate, each in the test's directory. The test's
  `clock` (an `Agent` holding ms) is the wall clock of `Sessions` and the `Mover`.

      setup {CodingAgentFramework.MoverSetup, :mover}
  """

  import CodingAgentFramework.TestHost
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias CodingAgentFramework.{Accounts, Acts, ClaudeStandIn, Cues, Grants}
  alias CodingAgentFramework.{HeadlessStandIn, Holder, Intake, Mailbox, Mover, Registry}
  alias CodingAgentFramework.{Sessions, Shell, Stream, Tmux, Transcripts}
  alias CodingAgentFramework.Sessions.Agents
  alias CodingAgentFramework.Tmux.CLI

  @doc "An ExUnit setup; `take_bound:` in the test's tags sets `Mailbox`'s (1 s by default)."
  def mover(ctx) do
    dir = test_dir()
    {:ok, server} = CLI.new(programs(), {:socket, Path.join(dir, "tmux.sock")})
    on_exit(fn -> Tmux.kill_server(server) end)
    on_exit(fn -> end_recorded(dir) end)

    {:ok, accounts} = Accounts.new(Path.join(dir, "home"), ["work", "spare"])

    dirs =
      for a <- ~w(work spare), into: %{} do
        {:ok, account} = Accounts.prepare(accounts, a, %{})
        File.mkdir_p!(Path.join(account.config_dir, "sessions"))
        {a, account.config_dir}
      end

    db = Path.join(dir, "caf.db")
    parts = [sessions: Sessions.reads(), mailbox: Mailbox.reads(), mover: Mover.reads()]
    cues = start_supervised!({Cues, parts: parts})
    notify = &Cues.cue(cues, &1)
    read = [programs: programs(), db: db, notify: notify]

    registry = start_supervised!({Registry, [accounts: dirs, interval: 100] ++ read})
    transcripts = start_supervised!({Transcripts, [accounts: ~w(work spare)] ++ read})

    dtach = Path.join(dir, "d")
    File.mkdir_p!(dtach)
    {:ok, holder} = Holder.new(programs(), dtach)
    stream = start_supervised!({Stream, [holder: holder, home: dir, interval: 100] ++ read})
    reaper = start_supervised!({Shell.Reaper, programs: programs()})
    clock = start_supervised!({Agent, fn -> System.os_time(:millisecond) end})
    now = fn -> Agent.get(clock, & &1) end

    secret = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    intake = start_supervised!({Intake, db: db, host: "test", notify: notify})
    plug = {Intake.Plug, intake: intake, secret: secret}

    http =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(http)

    {:ok, agents} = Agents.open(db, "test")
    tree = fn -> [%{name: "d0", project: "app", parent: "main"} | Agents.read_tree(agents)] end

    mailbox =
      start_supervised!(
        {Mailbox,
         db: db,
         grants: Grants.new(tree, operator: "operator"),
         stream: stream,
         sessions_db: db,
         host: "test",
         intake: intake,
         transcripts: transcripts,
         accounts: accounts,
         take_bound: ctx[:take_bound] || 1_000,
         notify: notify}
      )

    sessions =
      start_supervised!(
        {Sessions,
         programs: programs(),
         dir: dtach,
         tmux: server,
         registry: registry,
         stream: stream,
         home: dir,
         db: db,
         reaper: reaper,
         notify: notify,
         poll: 50,
         clock: now,
         open_to: &Mailbox.open_to(mailbox, &1, status: &2),
         waiter: %{port: port, secret: secret}}
      )

    acts =
      start_supervised!(
        {Acts, db: Path.join(dir, "acts.db"), start_id: "s1", host: "test", instance: "a"}
      )

    launches = start_supervised!(Supervisor.child_spec({Agent, fn -> nil end}, id: :launch))

    mover_opts = [
      host: "test",
      sessions: sessions,
      sessions_db: db,
      mailbox: mailbox,
      accounts: accounts,
      usage: nil,
      acts: acts,
      launch: fn row -> (Agent.get(launches, & &1) || (&launch(dir, &1))).(row) end,
      clock: now,
      timeout: 60_000,
      stop: 5_000
    ]

    for {key, pid} <- [sessions: sessions, mailbox: mailbox], do: Cues.started(cues, key, pid)

    ctx = %{dir: dir, cues: cues, mover_opts: mover_opts}

    {:ok,
     dir: dir,
     dirs: dirs,
     accounts: accounts,
     server: server,
     cues: cues,
     registry: registry,
     transcripts: transcripts,
     stream: stream,
     sessions: sessions,
     mailbox: mailbox,
     acts: acts,
     clock: clock,
     agents: agents,
     launches: launches,
     mover_opts: mover_opts,
     mover: restart(ctx)}
  end

  @doc "Starts a `Mover` with the setup's options, named to `Cues`, in place of any earlier one."
  def restart(ctx) do
    spec = Supervisor.child_spec({Mover, ctx.mover_opts}, id: make_ref(), restart: :temporary)
    pid = start_supervised!(spec)
    Cues.started(ctx.cues, :mover, pid)
    Process.put(:mover, pid)
    pid
  end

  @doc """
  Writes `line` into the pane of agent `name` as one checked write, which the interactive
  stand-in reads as a line.
  """
  def type(ctx, name, line) do
    {:ok, panes} = Tmux.list_panes(ctx.server)
    %{pane: pane} = Enum.find(panes, &(&1.tag == name))
    Tmux.write(ctx.server, pane, name, {:line, line})
  end

  @doc "The `Mover`'s launch from now on: a function of the agent row."
  def set_launch(ctx, fun), do: Agent.update(ctx.launches, fn _ -> fun end)

  @doc "The default launch: the interactive stand-in for a main session, the headless for a delegate."
  def launch(dir, %{kind: "delegate"}), do: {:ok, headless(dir)}
  def launch(dir, _row), do: {:ok, interactive(dir)}

  @doc "An interactive stand-in's launch in `dir`, which writes its session file at its start."
  def interactive(dir) do
    [role: :parent, cwd: dir, claude: ClaudeStandIn.write!(dir, :at_start)] ++ shared(dir)
  end

  @doc """
  A headless stand-in's launch in `dir`, as a delegate of `main`. It writes its init at its
  start (`:at_start`) on purpose: `Mover`'s resume of a headless delegate carries no first line,
  so a stand-in in the real release's shape would never be confirmed (F-152's build note, new-1).
  """
  def headless(dir) do
    [role: :delegate, parent: "main", cwd: dir, claude: HeadlessStandIn.write!(dir, :at_start)] ++
      shared(dir)
  end

  defp shared(dir) do
    env = %{home: dir, path: "/nonexistent", term: "xterm-256color", lang: "C.UTF-8"}
    [model: "opus", env: env, tool_timeout: 3_600_000]
  end
end
