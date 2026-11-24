defmodule CodingAgentFramework.RealCase do
  @moduledoc """
  The case every real test uses (F-223): a home of its own with the example app's tree in it,
  against the real Claude Code, on the accounts a `bin/caf-login --setup` logged in.

  `CAF_REAL_SETUP` names that setup's home, which is the suite's own: a login is kept by its
  config directory's path (macOS's Keychain names the path), so the trees start there, not in
  homes that link to it. No test logs in or meets an onboarding screen. Without it, every test is
  skipped, and the reason says how to set it up.

  One home holds one tree at a time (F-215), and a tree writes its own settings (its hook port
  among them) into each account's config directory, so the modules run one at a time
  (`async: false`), each with its own instance, ports, project and agent names.
  """

  use ExUnit.CaseTemplate
  require ExUnit.Assertions

  alias CodingAgentFramework.Example.{ConfigFile, Run}
  alias CodingAgentFramework.{Operator, TestHost}
  alias CodingAgentFramework.Sessions.Agents

  @setup "CAF_REAL_SETUP"

  using do
    quote do
      import CodingAgentFramework.RealCase
      @moduletag :real
      # A real turn takes seconds to minutes; each test states its own bound below this.
      @moduletag timeout: 1_200_000
      unless CodingAgentFramework.RealCase.setup_dir(),
        do: @moduletag(skip: CodingAgentFramework.RealCase.how())
    end
  end

  @doc "The setup's home, when `CAF_REAL_SETUP` names one with both accounts' directories."
  def setup_dir do
    with "/" <> _ = dir <- System.get_env(@setup),
         true <- Enum.all?(~w(one two), &File.dir?(Path.join([dir, "accounts", &1, "claude"]))) do
      dir
    else
      _ -> nil
    end
  end

  @doc "Why the tests are skipped, and what to run."
  def how,
    do:
      "set #{@setup} to a home where `bin/caf-login --setup <home> one two` logged both " <>
        "accounts in, then run `mix test.real`"

  @doc """
  Starts the example app's tree in a new home: accounts `one` and `two` linked from the setup,
  project `demo` cloned from a new bare origin, main session `demo-main` declared. Answers the
  context the helpers below take; the tree is stopped and its tmux server ended at the test's end.
  """
  def start_tree!(name) do
    # The setup's home is the suite's own. A login is kept by its config directory's path
    # (macOS's Keychain names the path), so another home's link to it is logged out: the trees
    # start on the setup's home itself, one at a time (F-215 holds the home). Each run has its
    # own project, origin and agent names, so an earlier run's ended rows never collide.
    home = setup_dir()
    run_id = "r" <> Integer.to_string(System.os_time(:second), 36)
    project = String.downcase(name <> run_id)
    main = project <> "-main"
    origin = origin!(TestHost.test_dir(), project)

    config = %{
      "home" => home,
      "instance" => name,
      "accounts" => ["one", "two"],
      "ports" => %{"intake" => free_port(), "mcp" => free_port()},
      "projects" => %{
        project => %{
          "origin" => origin,
          "trunk" => "main",
          "mains" => [main],
          "branches" => "^unit/",
          "cap" => 4
        }
      }
    }

    {:ok, c} = ConfigFile.parse(JSON.encode!(config), System.get_env())
    {:ok, run} = Run.start(c)
    # `on_exit` runs after the test's process has exited: unlinked, the tree outlives it, so the
    # exit hook can end the run's agents through it before stopping it.
    Process.unlink(run)

    ctx = %{
      run: run,
      config: c,
      home: home,
      mcp: Run.parts(run).mcp,
      project: project,
      main: main
    }

    ExUnit.Callbacks.on_exit(fn -> end_run(ctx) end)
    ctx
  end

  # The suite's home outlives a run, so a run ends what it started, passed or failed: its
  # delegates, then its main session, then its tree. What does not end is left in the home's
  # tmux server for a person to read.
  defp end_run(ctx) do
    if Process.alive?(ctx.run) do
      case CodingAgentFramework.MCP.operate(ctx.mcp, "agents", %{"all" => false}) do
        {:ok, %{agents: tree}} ->
          for %{name: name, kind: "delegate"} <- tree,
              String.starts_with?(name, ctx.project),
              do: Operator.stop(ctx.mcp, name)

        _ ->
          :ok
      end

      # A main still at its start's dialog is `starting`, which `end_main` refuses: the dialog
      # is answered with its exit first (F-223's new-3).
      for %{id: id, kind: "dialog", options: options} <- prompts(ctx, agent: ctx.main),
          no = Enum.find(options, &(&1 =~ ~r/exit/i)),
          do: answer(ctx, id, no)

      Operator.end_main(ctx.mcp, ctx.main, force: true)
      Run.stop(ctx.run)
    end
  end

  # A bare repository with one commit, as `docs/e2e.md`'s step 0 makes, named as its project:
  # a checkout's directory is its origin's name, so two runs' origins must not share one.
  defp origin!(dir, project) do
    git = TestHost.program!(:git)
    seed = Path.join(dir, "seed")
    bare = Path.join(dir, project <> ".git")
    File.mkdir_p!(seed)
    File.write!(Path.join(seed, "README.md"), "# demo\n\nA scratch project for the framework.\n")
    env = [{"GIT_AUTHOR_NAME", "Seed"}, {"GIT_AUTHOR_EMAIL", "seed@example.com"}]
    env = env ++ [{"GIT_COMMITTER_NAME", "Seed"}, {"GIT_COMMITTER_EMAIL", "seed@example.com"}]

    run = fn args ->
      {_, 0} = System.cmd(git, args, cd: seed, env: env, stderr_to_stdout: true)
    end

    run.(["init", "-q", "-b", "main"])
    run.(["add", "README.md"])
    run.(["-c", "commit.gpgsign=false", "commit", "-qm", "Seed the demo project"])
    run.(["clone", "-q", "--bare", ".", bare])
    bare
  end

  defp free_port do
    {:ok, s} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(s)
    :gen_tcp.close(s)
    port
  end

  @doc "Calls `check` until it answers `{:ok, value}`, or fails at `ms`, naming the screen."
  def await!(ctx, what, check, ms, agent \\ nil) do
    agent = agent || ctx.main

    case TestHost.await(check, ms) do
      {:ok, value} ->
        value

      other ->
        ExUnit.Assertions.flunk(
          "#{what}: not within #{ms} ms (#{inspect(other, limit: 10)}); " <>
            "#{agent}'s screen:\n#{screen(ctx, agent)}"
        )
    end
  end

  @doc """
  Reads `read` until it answers a non-empty list or `ms` pass by the clock, and answers the last
  read: for what may come or may not (a startup dialog in a folder the account trusts already).
  """
  def await_some(read, ms) do
    case TestHost.await(fn -> if (r = read.()) != [], do: {:ok, r}, else: {:not_yet, r} end, ms) do
      {:ok, r} -> r
      _ -> read.()
    end
  end

  @doc "The last lines of agent `name`'s pane, as `capture-pane` reads them."
  def screen(ctx, name) do
    args = ["-S", Path.join(ctx.home, "tmux.sock"), "capture-pane", "-p", "-t", "=#{name}:"]
    {out, _} = System.cmd(TestHost.program!(:tmux), args, stderr_to_stdout: true)

    out
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.take(-25)
    |> Enum.join("\n")
  end

  @doc """
  Agent `name` as the console's `agents` reads it (`state` is `idle`, `working`, `waiting`,
  `gone` or `starting`), or nil; `all: true` keeps ended ones.
  """
  def agent(ctx, name, all \\ false) do
    {:ok, %{agents: tree}} =
      CodingAgentFramework.MCP.operate(ctx.mcp, "agents", %{"all" => all})

    Enum.find(tree, &(&1.name == name))
  end

  @doc "Waits until agent `name` reads `state`, then answers it."
  def await_state!(ctx, name, state, ms) do
    await!(
      ctx,
      "#{name} #{state}",
      fn ->
        case agent(ctx, name) do
          %{state: ^state} = a -> {:ok, a}
          other -> {:not_yet, other && other.state}
        end
      end,
      ms,
      name
    )
  end

  @doc """
  Agent `name`'s transcript so far, the JSONL Claude Code writes, or "" before it has one. A
  delivered notice shows collapsed on the screen ("Stop hook feedback"), so delivery is read
  here, not on the screen.
  """
  def transcript(ctx, name) do
    with %{session_id: id, account: account} when is_binary(id) <-
           ctx.run |> Run.info() |> Map.fetch!(:agents) |> Agents.rows() |> find(name),
         [path | _] <-
           Path.wildcard(
             Path.join([ctx.home, "accounts", account, "claude/projects/*", id <> ".jsonl"])
           ) do
      File.read!(path)
    else
      _ -> ""
    end
  end

  defp find(rows, name), do: Enum.find(rows, &(&1.name == name))

  @doc "Waits until agent `name`'s transcript holds `text`."
  def await_transcript!(ctx, name, text, ms) do
    await!(
      ctx,
      "#{name}'s transcript holds #{inspect(text)}",
      fn -> if transcript(ctx, name) =~ text, do: {:ok, true}, else: {:not_yet, nil} end,
      ms,
      name
    )
  end

  @doc "Waits until agent `name`'s screen shows `text`."
  def await_screen!(ctx, name, text, ms) do
    await!(
      ctx,
      "#{name}'s screen shows #{inspect(text)}",
      fn ->
        s = screen(ctx, name)
        if s =~ text, do: {:ok, s}, else: {:not_yet, nil}
      end,
      ms,
      name
    )
  end

  @doc """
  Agent `name`'s whole pane as `capture-pane` reads it, plain or with its escapes (`escapes:
  true`), blank lines kept: the shape a `caf_screen` fixture's `.txt` and `.ansi` have.
  """
  def capture(ctx, name, escapes \\ false) do
    flags = if escapes, do: ["-p", "-e"], else: ["-p"]
    {out, _} = tmux(ctx, ["capture-pane" | flags] ++ ["-t", "=#{name}:"])
    out
  end

  defp tmux(ctx, args) do
    args = ["-S", Path.join(ctx.home, "tmux.sock") | args]
    System.cmd(TestHost.program!(:tmux), args, stderr_to_stdout: true)
  end

  @doc """
  The suite's records folder (F-239): `records` in the setup's home, as `docs/e2e.md`'s step 0
  keeps a run's readings in a folder of their own. Made when first written.
  """
  def records_dir, do: Path.join(setup_dir(), "records")

  @doc """
  Writes agent `name`'s pane into the records folder as `<project>-<what>.txt` (plain) and
  `<project>-<what>.ansi` (with escapes), and `note` with the pane's width as
  `<project>-<what>.meta`. Answers the plain file's path. A real screen no fixture had yet
  becomes one from these.

      record_screen!(ctx, ctx.main, "reload-1", "answer: {:ok, %{done: :reloaded}}")
  """
  def record_screen!(ctx, name, what, note \\ "") do
    dir = records_dir()
    File.mkdir_p!(dir)
    base = Path.join(dir, "#{ctx.project}-#{what}")
    {width, _} = tmux(ctx, ["display-message", "-p", "-t", "=#{name}:", "\#{pane_width}"])
    File.write!(base <> ".txt", capture(ctx, name))
    File.write!(base <> ".ansi", capture(ctx, name, true))
    File.write!(base <> ".meta", "agent: #{name}\nwidth: #{String.trim(width)}\n#{note}\n")
    base <> ".txt"
  end

  @doc """
  Runs `fun`, one step of a test, and answers its value. An assertion that fails in it names
  the step first, so a failed real run says where it stopped.

      step("4, the trust dialog", fn -> answer_trust(ctx, name) end)
  """
  def step(name, fun) do
    fun.()
  rescue
    e in ExUnit.AssertionError ->
      reraise %{e | message: "step #{name}: #{e.message}"}, __STACKTRACE__
  end

  @doc """
  Answers the startup dialog agent `name`'s start waits on (the trust dialog, in a folder the
  account has not seen) from the inbox with its trusting label. None may come, as the account
  may trust the folder already. Answers the prompt's id, or `:none`.
  """
  def answer_trust(ctx, name) do
    case await_some(fn -> prompts(ctx, agent: name, kind: "dialog") end, 20_000) do
      [%{id: id, options: options}] ->
        label = Enum.find(options, &(&1 =~ ~r/trust/i))
        ExUnit.Assertions.assert({:ok, _} = answer(ctx, id, label))
        id

      [] ->
        :none
    end
  end

  @doc """
  `docs/e2e.md`'s steps 1 and 2: waits until the project's checkout is ready on `main` (a
  start is refused `{:checkout, "cloning"}` before), then starts the run's main session on
  `model` with `brief`, answers its trust dialog from the inbox, and waits until it is idle
  with `reply` (a pattern) on its screen. Each wait has its own bound, and a failure names
  the step.
  """
  def start_main!(ctx, brief, model, reply) do
    # A start refuses a checkout still cloning, so step 1's ready comes first, bounded.
    step("1, the checkout is ready", fn ->
      await!(
        ctx,
        "the checkout",
        fn ->
          case CodingAgentFramework.Mains.checkout(Run.parts(ctx.run).mains, ctx.project) do
            {:ok, %{branch: "main"} = r} -> {:ok, r}
            other -> {:not_yet, other}
          end
        end,
        120_000
      )
    end)

    step("2, the main session starts", fn ->
      main = ctx.main

      ExUnit.Assertions.assert(
        op(ctx, :start_main, [ctx.project, main, brief, model]) in [
          {:ok, %{main: main}},
          {:unknown, {:dialog, :trust}}
        ]
      )

      answer_trust(ctx, main)
      await_state!(ctx, main, "idle", 180_000)
      await_screen!(ctx, main, reply, 60_000)
    end)
  end

  @doc """
  `docs/e2e.md`'s step 14 for a run with no delegate left: the main session ends, and reads
  `ended`. The exit hook ends what a failed run left; a passed run ends it here.
  """
  def end_main!(ctx) do
    step("14, the main session ends", fn ->
      ExUnit.Assertions.assert({:ok, _} = op(ctx, :end_main, [ctx.main]))
      ExUnit.Assertions.assert(%{state: "ended"} = agent(ctx, ctx.main, true))
    end)
  end

  @doc """
  Allows every permission request of agent `name` open now, from the inbox. Answers the ids it
  answered, so a test can check its parent was told of each.
  """
  def allow_all(ctx, name) do
    for %{id: id, status: "open"} <- prompts(ctx, agent: name, kind: "permission"),
        match?({:ok, _}, answer(ctx, id, "allow")),
        do: id
  end

  @doc "The prompts open now, narrowed as `CodingAgentFramework.prompts/2` narrows them."
  def prompts(ctx, filter \\ []) do
    {:ok, prompts} = CodingAgentFramework.prompts(ctx.config.instance, filter)
    prompts
  end

  @doc "Answers prompt `id` with `choice` as the config's operator."
  def answer(ctx, id, choice),
    do: CodingAgentFramework.answer(ctx.config.instance, id, choice, ctx.config.operator)

  @doc "The operator's call `fun` of `Operator`, on this tree."
  def op(ctx, fun, args), do: apply(Operator, fun, [ctx.mcp | args])
end
