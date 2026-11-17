defmodule CodingAgentFramework.SessionsSetup do
  @moduledoc """
  The setup `SessionsTest` and `SessionsSourceTest` share: a `Sessions` on a real tmux server
  and real dtach sockets in the test's own directory, with its `Control`, a `Registry` of one
  prepared account, a `Stream` for its delegates, a `Shell.Reaper` for its worktrees' commands,
  and a clock the test moves; and the launches
  of stand-ins for Claude Code: interactive (`CodingAgentFramework.ClaudeStandIn`) and headless
  (`CodingAgentFramework.HeadlessStandIn`).

  It compiles only for tests. It lives in `caf_sessions`, not `caf_test`, because it uses
  `Sessions`, and `caf_test` may not use an app above it.

      setup {CodingAgentFramework.SessionsSetup, :sessions}
  """

  import CodingAgentFramework.TestHost
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias CodingAgentFramework.{Accounts, ClaudeStandIn, Control, HeadlessStandIn, Holder, Registry}
  alias CodingAgentFramework.{Sessions, Shell, Stream, Tmux}
  alias CodingAgentFramework.Sessions.Table
  alias CodingAgentFramework.Tmux.CLI

  @doc """
  An ExUnit setup. Its `opts` start another `Sessions` on the same table; its cues come to the
  test as `{:cue, cue}`. The test's `clock` is an `Agent` holding ms, `open` an `Agent` holding
  the `Mailbox` rows `open_to:` answers (`%{{name, :open | :sending} => ids}`), and `server` its
  tmux server.
  """
  def sessions(_context) do
    dir = test_dir()
    {:ok, server} = CLI.new(programs(), {:socket, Path.join(dir, "tmux.sock")})
    on_exit(fn -> Tmux.kill_server(server) end)
    control = start_supervised!({Control, tmux: server})

    {:ok, accounts} = Accounts.new(Path.join(dir, "home"), ["work"])
    {:ok, account} = Accounts.prepare(accounts, "work", %{})
    File.mkdir_p!(Path.join(account.config_dir, "sessions"))
    db = Path.join(dir, "caf.db")

    registry =
      start_supervised!(
        {Registry, programs: programs(), accounts: %{"work" => account.config_dir}, db: db}
      )

    dtach = Path.join(dir, "d")
    File.mkdir_p!(dtach)
    {:ok, holder} = Holder.new(programs(), dtach)
    me = self()
    clock = start_supervised!({Agent, fn -> System.os_time(:millisecond) end})
    stream_opts = [programs: programs(), holder: holder, home: dir, db: db]
    stream = start_supervised!(Supervisor.child_spec({Stream, stream_opts}, id: Stream))
    reaper = start_supervised!({Shell.Reaper, programs: programs()})
    # Mailbox's open rows as the test sets them: `{name, :open | :sending}` to ids.
    open = start_supervised!(Supervisor.child_spec({Agent, fn -> %{} end}, id: :open))

    opts = [
      open_to: fn name, which -> {:ok, Agent.get(open, &Map.get(&1, {name, which}, []))} end,
      reaper: reaper,
      programs: programs(),
      dir: dtach,
      control: control,
      registry: registry,
      stream: stream,
      home: dir,
      db: db,
      notify: &send(me, {:cue, &1}),
      poll: 50,
      clock: fn -> Agent.get(clock, & &1) end
    ]

    {:ok, table} = Table.open(db)
    # A start can answer before its stand-in records its pid; the seal makes that one exit.
    on_exit(fn -> end_recorded(dir) end)

    {:ok,
     dir: dir,
     account: account,
     server: server,
     control: control,
     holder: holder,
     table: table,
     opts: opts,
     clock: clock,
     open: open,
     registry: registry,
     stream: stream,
     sessions: start_supervised!(Supervisor.child_spec({Sessions, opts}, restart: :temporary))}
  end

  @doc """
  The launch options of an interactive stand-in in the test's directory that writes its file in
  `mode`. It runs as a parent: a delegate is headless (`headless/2`).
  """
  def launch(ctx, mode) do
    claude = ClaudeStandIn.write!(ctx.dir, mode)

    [
      role: :parent,
      cwd: ctx.dir,
      claude: claude,
      model: "opus",
      env: env(ctx),
      prompt: "brief",
      tool_timeout: 3_600_000
    ]
  end

  @doc "The launch options of a delegate: a headless stand-in that writes its init in `mode`."
  def headless(ctx, mode) do
    claude = HeadlessStandIn.write!(ctx.dir, mode)

    [
      role: :delegate,
      cwd: ctx.dir,
      claude: claude,
      model: "opus",
      env: env(ctx),
      tool_timeout: 3_600_000
    ]
  end

  defp env(ctx),
    do: %{home: ctx.dir, path: "/nonexistent", term: "xterm-256color", lang: "C.UTF-8"}
end
