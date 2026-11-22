defmodule CodingAgentFramework.Example.ConsoleTest do
  # The config file the example app starts from, read and refused as `ConfigFile` documents,
  # and `bin/caf-example` started on one with the headless stand-in as Claude Code, up to its
  # console's first reading.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Example.ConfigFile

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{HeadlessStandIn, Shell, Tmux}
  alias CodingAgentFramework.Config
  alias CodingAgentFramework.Example.{ConfigFile, Console, Run}

  @root Path.expand("../../..", __DIR__)

  setup do
    dir = test_dir()
    repo = Path.join(dir, "repo")
    git = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    {_, 0} = System.cmd(program!(:git), ["init", "-q", "-b", "main", repo], env: git)
    commit = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "i"]
    {_, 0} = System.cmd(program!(:git), commit ++ ["--allow-empty"], env: git)

    data = %{
      "home" => Path.join(dir, "home"),
      "instance" => "t",
      "accounts" => ["one", "two"],
      "ports" => %{"intake" => free_port(), "mcp" => free_port()},
      "projects" => %{
        "app" => %{
          "origin" => repo,
          "trunk" => "main",
          "mains" => ["app-main"],
          "branches" => "^unit/",
          "cap" => 2,
          "env" => %{"HOME" => dir}
        }
      },
      "launch" => %{"claude" => HeadlessStandIn.write!(dir), "home" => dir},
      "interval" => 200
    }

    %{dir: dir, data: data, env: System.get_env()}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp write!(ctx, data) do
    path = Path.join(ctx.dir, "caf-#{System.unique_integer([:positive])}.json")
    File.write!(path, JSON.encode!(data))
    path
  end

  # F-173: the OS user, which Claude Code's Keychain lookup needs on macOS.
  test "the launch's user is the environment's USER, or the file's; none on macOS is refused",
       ctx do
    env = Map.put(ctx.env, "USER", "someone")

    assert {:ok, %Config{user: "someone", env: %{user: "someone"}}} =
             ConfigFile.read(write!(ctx, ctx.data), env)

    data = Map.put(ctx.data, "launch", %{"user" => "other"})
    assert {:ok, %Config{user: "other"}} = ConfigFile.read(write!(ctx, data), env)

    data = Map.put(ctx.data, "launch", %{"user" => 1})
    assert ConfigFile.read(write!(ctx, data), env) == {:refused, {"launch.user", :not_a_string}}

    case :os.type() do
      {:unix, :darwin} ->
        assert ConfigFile.read(write!(ctx, ctx.data), Map.delete(env, "USER")) ==
                 {:refused, {:bad, :user}}

      _ ->
        assert {:ok, %Config{user: nil}} =
                 ConfigFile.read(write!(ctx, ctx.data), Map.delete(env, "USER"))
    end
  end

  test "a config file is read whole into the example app's config", ctx do
    assert {:ok, %Config{} = c} = ConfigFile.read(write!(ctx, ctx.data), ctx.env)
    home = ctx.data["home"]

    assert %{home: ^home, instance: "t", accounts: ["one", "two"], operator: "operator"} = c
    assert c.mains == %{"app-main" => "app"}
    assert c.main_model == "opus" and c.interval == 200
    assert %{"app" => %{name: "app", repo: repo, trunk: "main", cap: 2, setup: []}} = c.projects
    # The checkout is named by its repository (F-156).
    assert repo == Path.join(home, "checkouts/repo")
    assert Regex.match?(c.projects["app"].branches, "unit/one")
    assert c.resources == %{"seat" => 4, "slot" => 2} and c.lease == %{"seat" => 1}
    assert c.job_lease.landing == %{"slot" => 1}
    assert c.heavy == []
    heavy = [%{"match" => "^mix test", "class" => "builder"}]
    data = put_in(ctx.data, ["scheduler"], %{"heavy" => heavy})

    assert {:ok, %Config{heavy: [%{match: "^mix test", class: :builder}]}} =
             ConfigFile.read(write!(ctx, data), ctx.env)

    # F-155: devenv's programs first on a launch's and a project's PATH, the system's last.
    assert %{home: _, path: path, term: _, lang: _} = c.env
    assert [git_dir | _] = String.split(path, ":")
    assert git_dir in Enum.map([program!(:tmux), program!(:dtach)], &Path.dirname/1)
    assert String.ends_with?(path, ":/usr/bin:/bin:/usr/sbin:/sbin")
    assert c.programs.tmux == program!(:tmux) and c.programs.git == program!(:git)
    assert c.git == %{author: nil, projects: %{}}

    # The author agents commit as, and a project's own.
    data = Map.put(ctx.data, "git", %{"name" => "App Bot", "email" => "bot@example.com"})
    data = put_in(data, ["projects", "app", "git"], %{"signing_key" => "app_key"})
    assert {:ok, %Config{git: git}} = ConfigFile.read(write!(ctx, data), ctx.env)
    key = Path.join([home, "git", "signing_key"])
    assert git.author == %{name: "App Bot", email: "bot@example.com", signing_key: key}
    assert git.projects == %{"app" => %{signing_key: Path.join([home, "git", "app_key"])}}
  end

  test "each refusal names its key", ctx do
    app = ctx.data["projects"]["app"]
    project = fn changes -> put_in(ctx.data, ["projects", "app"], Map.merge(app, changes)) end

    cases = [
      {Map.delete(ctx.data, "home"), {"home", :missing}},
      {Map.put(ctx.data, "accounts", ["one", "One"]), {"accounts", {:not_a_name, "One"}}},
      {Map.put(ctx.data, "accounts", ["one", "one"]), {"accounts", {:twice, ["one"]}}},
      {Map.delete(ctx.data, "ports"), {"ports", :missing}},
      {put_in(ctx.data, ["ports", "mcp"], 70_000), {"ports.mcp", :not_a_port}},
      {put_in(ctx.data, ["projects", "app"], Map.delete(app, "cap")),
       {"projects.app.cap", :missing}},
      {project.(%{"repository" => "x"}), {"projects.app.repository", :unknown_key}},
      {project.(%{"branches" => "("}), {"projects.app.branches", :not_a_pattern}},
      {project.(%{"setup" => [["mix", "deps.get"]]}), {"projects.app.setup.0", :not_an_argv}},
      {project.(%{"mains" => ["framework"]}), {"projects.app.mains", {:reserved, "framework"}}},
      {project.(%{"env" => %{"HOME" => 1}}), {"projects.app.env.HOME", :not_a_string}},
      {put_in(ctx.data, ["projects", "App"], app), {"projects.App", :not_a_name}},
      {put_in(ctx.data, ["projects", "web"], app), {"projects.web.mains", {:twice, "app-main"}}},
      {Map.put(ctx.data, "scheduler", %{"resources" => %{"seat" => 0}}),
       {"scheduler.resources.seat", :not_positive}},
      {Map.put(ctx.data, "scheduler", %{"lease" => %{"gpu" => 1}}),
       {"scheduler.lease.gpu", :no_such_resource}},
      {Map.put(ctx.data, "scheduler", %{"job_lease" => %{"nightly" => %{}}}),
       {"scheduler.job_lease.nightly", :unknown_key}},
      {Map.put(ctx.data, "scheduler", %{"heavy" => [%{"match" => "x"}]}),
       {"scheduler.heavy.0", :not_a_command}},
      {Map.put(ctx.data, "scheduler", %{
         "resources" => %{"seat" => 1, "slot" => 1, "land:app" => 1}
       }), {"scheduler.resources.land:app", :reserved}},
      {put_in(ctx.data, ["launch", "claude"], "claude"), {"launch.claude", :not_absolute}},
      {Map.put(ctx.data, "operator", "app-main"),
       {"projects.app.mains", {:reserved, "app-main"}}},
      {Map.put(ctx.data, "git", %{"name" => "Bot"}), {"git.email", :missing}},
      {Map.put(ctx.data, "git", %{"name" => "Bot", "email" => "bot"}),
       {"git.email", :not_an_email}},
      {project.(%{"git" => %{"signing_key" => "../key"}}),
       {"projects.app.git.signing_key", :not_a_file_name}},
      {project.(%{"git" => %{"author" => "x"}}), {"projects.app.git.author", :unknown_key}}
    ]

    for {data, refusal} <- cases,
        do: assert(ConfigFile.read(write!(ctx, data), ctx.env) == {:refused, refusal})

    missing = Path.join(ctx.dir, "none.json")
    assert ConfigFile.read(missing, ctx.env) == {:refused, {:file, {missing, :enoent}}}

    assert ConfigFile.read(write!(ctx, ctx.data), Map.delete(ctx.env, "CAF_LSOF")) ==
             {:refused, {:programs, {:unset, ["CAF_LSOF"]}}}
  end

  test "bin/caf-example starts the app with the stand-in and reaches the console", ctx do
    {:ok, config} = ConfigFile.read(path = write!(ctx, ctx.data), ctx.env)
    {:ok, server} = CodingAgentFramework.server(config)
    on_exit(fn -> Tmux.kill_server(server) end)
    on_exit(fn -> end_recorded(ctx.dir) end)

    {port, os_pid} = script(path)
    on_exit(fn -> kill(os_pid, "-KILL") end)

    # The console's first reading: the declared main session, a root of the tree.
    send_line(port, ~s|agents(caf)|)
    {:ok, out} = read_until(port, "app-main: main of app")
    assert out =~ "caf: started at #{config.home}"
    assert out =~ "account two: #{Path.join(config.home, "accounts/two/claude")}"
    assert out =~ "caf: the console is ready"

    send_line(port, ~s|attach(caf, "app-main")|)

    socket = Shell.shell_quote(Path.join(config.home, "tmux.sock"))
    tmux = Shell.shell_quote(program!(:tmux))
    {:ok, _} = read_until(port, "#{tmux} -S #{socket} attach -t '=app-main'")

    # A new shell evaluates the dot file again, as after IEx's interrupt (F-153's new-5): the
    # app started once is `caf` again, and the VM runs on.
    send_line(port, ~s|import_file("apps/caf_example/console.iex.exs")|)
    {:ok, _} = read_until(port, "caf: this shell's app runs, started once")

    # Each reading reaches its part and prints what is there, nothing yet.
    readings = [
      {"dialogs(caf)", "no startup dialog waits"},
      {"asks(caf)", "no open asks"},
      {"leases(caf)", "no lease held, none refused"},
      {"faults(caf)", "no faults"},
      {"checkout(caf)", "  #{config.home}/checkouts/repo"},
      {~s|start_main(caf, "app", "framework", "Go.")|, ~s|refused: {:running, "framework"}|},
      {~s|message(caf, "nobody", "Hi.")|, "refused: "},
      {~s|end_main(caf, "app-main")|, "ok: :ended"},
      {"agents(caf)", "no agents"},
      {"agents(caf, true)", "app-main: main of app, on no account, ended"}
    ]

    for {command, reading} <- readings do
      send_line(port, command)
      assert {:ok, _} = read_until(port, reading), command
    end

    send_line(port, "System.halt()")
    assert {:exit, 0} = exited(port)
  end

  test "bin/caf-example names a refused config and ends with status 2", ctx do
    path = write!(ctx, put_in(ctx.data, ["projects", "app", "cap"], 0))
    {port, os_pid} = script(path)
    on_exit(fn -> kill(os_pid, "-KILL") end)

    {:ok, _} =
      read_until(port, ~s|caf: not started: refused: {"projects.app.cap", :not_positive}|)

    assert {:exit, 2} = exited(port)
  end

  # The console in this VM, its output read from the test's own group leader, which the
  # process `run_delegate` waits in inherits.
  test "the console's acts go through the operator's tools, each with its reading", ctx do
    {:ok, io} = StringIO.open("")
    Process.group_leader(self(), io)
    out = fn -> elem(StringIO.contents(io), 1) end

    # Runs `act` until the output shows `text`.
    see = fn act, text ->
      case await(fn -> (act.() && out.() =~ text && {:ok, text}) || nil end, 20_000) do
        {:ok, _} -> :ok
        _ -> flunk("no #{inspect(text)} in:\n" <> out.())
      end
    end

    # A new home: no account has a reading, so each counts as assumed at 0 % (F-146's new-1),
    # and a start picks the first.
    path = write!(ctx, ctx.data)
    {:ok, config} = ConfigFile.read(path, ctx.env)
    {:ok, server} = CodingAgentFramework.server(config)
    on_exit(fn -> Tmux.kill_server(server) end)
    on_exit(fn -> end_recorded(ctx.dir) end)
    {:ok, caf} = Console.start(path, ctx.env)
    on_exit(fn -> Run.stop(caf) end)

    see.(fn -> Console.checkout(caf) end, "app: ready, on main")

    see.(
      fn -> Console.start_delegate(caf, "app-main", "app", "unit/one", "Go.") end,
      ~s|ok: %{delegate: "app-unit-one"}|
    )

    # F-200: the console's `effort:` is the tool's; a level `claude --effort` lacks is refused.
    see.(
      fn ->
        Console.start_delegate(caf, "app-main", "app", "unit/three", "Go.", effort: "ultra")
      end,
      ~s|refused: {:effort, "ultra"}|
    )

    see.(fn -> Console.agents(caf) end, "  app-unit-one: delegate of app-main, on one, idle")

    :ok = Console.message(caf, "app-unit-one", "Hi.")
    [_, id] = Regex.run(~r/queued as message (\d+);/, out.())
    delivered = "message #{id} from operator to app-unit-one: delivered by stream"
    see.(fn -> Console.status(caf, String.to_integer(id)) end, delivered)

    # The reply's own text follows its status (F-146's new-4).
    see.(
      fn -> Console.status(caf, String.to_integer(id)) end,
      ~r/  reply \d+ from app-unit-one: kept\n  \| \S/
    )

    # A main session's held permission requests (F-146's new-5): a declared one holds none.
    see.(fn -> Console.requests(caf, "app-main") end, "app-main holds no permission request")

    # The operator's run_delegate prints the report once it comes, from a process of its own.
    :ok = Console.run_delegate(caf, "app-main", "app", "unit/two", "Go.", timeout: 20_000)
    see.(fn -> :ok end, ~s|run_delegate unit/two: ok: %{|)
    assert out.() =~ ~s|delegate: "app-unit-two"|

    see.(
      fn -> Console.leases(caf, true) end,
      ~r/lease \d+: builder for app asked on one, seat 1: /
    )

    see.(fn -> Console.faults(caf) end, "no faults")

    # F-189's new-1 and new-6: the inbox, the symptoms, the acts, usage and a delegate's groups.
    see.(fn -> Console.prompts(caf, kind: "ask") end, "no prompt waits")
    see.(fn -> Console.answer(caf, "permission:999", "allow") end, "refused: :no_prompt")
    see.(fn -> Console.symptoms(caf, kind: "absent_main") end, "no symptoms")
    see.(fn -> Console.acts(caf, actor: "nobody") end, "no acts")
    see.(fn -> Console.acts(caf) end, ~r/act \d+: \S+ \S+ /)
    see.(fn -> Console.usage(caf) end, ~r/no account has a reading|usage not read yet|one: /)

    see.(
      fn -> Console.groups(caf, "app-unit-one") end,
      ~r/unknown: :no_proc|leads no group of its own|group \d+, started/
    )

    see.(fn -> Console.groups(caf, "nobody") end, "refused: :no_agent")
  end

  # Only its refusals: a login runs the real Claude Code, which no test starts.
  test "bin/caf-login refuses a home that is not absolute and a name that is no account's" do
    login = Path.join(@root, "bin/caf-login")

    for {args, why} <- [
          {["home", "one"], "home is not an absolute path"},
          {["/srv/caf", "One"], "One is not an account's name"},
          {["/srv/caf"], "usage: bin/caf-login [--check] <home> <account>"}
        ] do
      assert {out, 2} = System.cmd(login, args, stderr_to_stdout: true)
      assert out =~ why
    end

    for {args, why} <- [
          {["--git", "/srv/caf", "--key", "../k"], "../k is not a key file's name"},
          {["--check", "--git", "/srv/caf"], "usage:"},
          {["--gh"], "usage:"}
        ] do
      assert {out, 2} = System.cmd(login, args, stderr_to_stdout: true)
      assert out =~ why
    end
  end

  # F-155: the home's own signing key, made once and never written over; declining the offer
  # to add it to GitHub runs no gh.
  test "bin/caf-login --git makes the home's signing key once", ctx do
    login = Path.join(@root, "bin/caf-login")
    home = Path.join(ctx.dir, "home")
    run = fn -> System.cmd(program!(:sh), ["-c", ~s(echo n | "$0" --git "$1"), login, home]) end

    assert {out, 0} = run.()
    key = Path.join([home, "git", "signing_key"])
    assert out =~ "made #{key}" and out =~ "ssh-ed25519 "
    pub = File.read!(key <> ".pub")

    assert {out, 0} = run.()
    assert out =~ "is there already" and File.read!(key <> ".pub") == pub
  end

  # F-153's new-3: `--check` says whether Claude Code's first-run onboarding was passed on the
  # account, as its `.claude.json` records it. A stand-in answers `claude auth status`.
  test "bin/caf-login --check names the onboarding passed or not", ctx do
    login = Path.join(@root, "bin/caf-login")
    claude = Path.join(ctx.dir, "claude-auth")
    File.write!(claude, "#!#{program!(:bash)}\necho \"auth: $*\"\n")
    File.chmod!(claude, 0o755)
    home = Path.join(ctx.dir, "login-home")
    env = [{"CAF_CLAUDE", claude}]

    assert {out, 1} =
             System.cmd(login, ["--check", home, "one"], env: env, stderr_to_stdout: true)

    assert out =~ "auth: auth status --text"
    assert out =~ "onboarding: not passed; run bin/caf-login #{home} one"

    dir = Path.join(home, "accounts/one/claude")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, ".claude.json"),
      ~s|{"theme": "dark", "hasCompletedOnboarding": true}|
    )

    assert {out, 0} =
             System.cmd(login, ["--check", home, "one"], env: env, stderr_to_stdout: true)

    assert out =~ "onboarding: passed"
  end

  # F-173's new-2: the login names the OS user as USER, whatever the shell had, as every held
  # launch does, so it writes the Keychain item those sessions read.
  test "bin/caf-login sets USER to the OS user", ctx do
    login = Path.join(@root, "bin/caf-login")
    claude = Path.join(ctx.dir, "claude-user")
    File.write!(claude, "#!#{program!(:bash)}\necho \"user: ${USER-unset}\"\n")
    File.chmod!(claude, 0o755)
    home = Path.join(ctx.dir, "user-home")
    {me, 0} = System.cmd(program!(:id), ["-un"])

    for user <- [{"USER", "someone-else"}, {"USER", nil}] do
      env = [{"CAF_CLAUDE", claude}, user]
      {out, _} = System.cmd(login, ["--check", home, "one"], env: env, stderr_to_stdout: true)
      assert out =~ "user: #{String.trim(me)}\n"
    end
  end

  # The script as a person runs it, in this VM's devenv environment, compiled for tests.
  defp script(config) do
    port =
      Port.open({:spawn_executable, Path.join(@root, "bin/caf-example")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [config],
        cd: @root,
        env: [{~c"MIX_ENV", ~c"test"}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp send_line(port, line), do: Port.command(port, line <> "\n")

  # Output comes as the VM writes it; each wait ends on the line it names.
  defp read_until(port, text, out \\ "") do
    receive do
      {^port, {:data, data}} ->
        out = out <> data
        if out =~ text, do: {:ok, out}, else: read_until(port, text, out)

      {^port, {:exit_status, status}} ->
        {:exited, status, out}
    after
      45_000 -> {:timeout, out}
    end
  end

  defp exited(port, out \\ "") do
    receive do
      {^port, {:data, data}} -> exited(port, out <> data)
      {^port, {:exit_status, status}} -> {:exit, status}
    after
      30_000 -> {:timeout, out}
    end
  end
end
