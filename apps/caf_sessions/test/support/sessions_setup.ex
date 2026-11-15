defmodule CodingAgentFramework.SessionsSetup do
  @moduledoc """
  The setup `SessionsTest` and `SessionsSourceTest` share: a `Sessions` on a real tmux server
  and real dtach sockets in the test's own directory, with its `Control`, a `Registry` of one
  prepared account, and a clock the test moves; and the launch of a stand-in for Claude Code
  (`CodingAgentFramework.ClaudeStandIn`).

  It compiles only for tests. It lives in `caf_sessions`, not `caf_test`, because it uses
  `Sessions`, and `caf_test` may not use an app above it.

      setup {CodingAgentFramework.SessionsSetup, :sessions}
  """

  import CodingAgentFramework.TestHost
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias CodingAgentFramework.{Accounts, ClaudeStandIn, Control, Holder, Registry, Sessions, Tmux}
  alias CodingAgentFramework.Sessions.Table
  alias CodingAgentFramework.Tmux.CLI

  @doc """
  An ExUnit setup. Its `opts` start another `Sessions` on the same table; its cues come to the
  test as `{:cue, cue}`. The test's `clock` is an `Agent` holding ms.
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
        {Registry, programs: programs(), account: "work", config_dir: account.config_dir, db: db}
      )

    dtach = Path.join(dir, "d")
    File.mkdir_p!(dtach)
    {:ok, holder} = Holder.new(programs(), dtach)
    me = self()
    clock = start_supervised!({Agent, fn -> System.os_time(:millisecond) end})

    opts = [
      programs: programs(),
      dir: dtach,
      control: control,
      registries: %{"work" => registry},
      db: db,
      notify: &send(me, {:cue, &1}),
      poll: 50,
      clock: fn -> Agent.get(clock, & &1) end
    ]

    {:ok, table} = Table.open(db)
    on_exit(fn -> ClaudeStandIn.kill_all(dir) end)

    {:ok,
     dir: dir,
     account: account,
     control: control,
     holder: holder,
     table: table,
     opts: opts,
     clock: clock,
     registry: registry,
     sessions: start_supervised!(Supervisor.child_spec({Sessions, opts}, restart: :temporary))}
  end

  @doc "The launch options of a stand-in in the test's directory that writes its file in `mode`."
  def launch(ctx, mode) do
    env = %{home: ctx.dir, path: "/nonexistent", term: "xterm-256color", lang: "C.UTF-8"}
    claude = ClaudeStandIn.write!(ctx.dir, mode)
    [role: :delegate, cwd: ctx.dir, claude: claude, model: "opus", env: env, prompt: "brief"]
  end
end
