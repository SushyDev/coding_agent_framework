defmodule CodingAgentFramework.SessionsWorktreeTest do
  @moduledoc """
  `Sessions`' worktrees (F-55) on a real git repository in this test's own directory, never the
  repository the tests run in, with the interactive stand-in for Claude Code. Each test names
  the `Start.tla` step or guard it checks. git runs with an empty environment here too, so no
  variable of the test's own environment reaches another repository.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Sessions, SessionsSetup}
  alias CodingAgentFramework.Sessions.Table

  setup {SessionsSetup, :sessions}

  setup ctx do
    repo = Path.join(ctx.dir, "repo")
    git!(ctx, ["init", "-q", "-b", "main", repo])
    File.write!(Path.join(repo, ".gitignore"), "built.log\n")
    git!(ctx, ["-C", repo, "add", ".gitignore"])
    git!(ctx, ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"])
    # The root as git prints it: the test's directory may sit behind a symlink.
    {root, 0} = System.cmd(program!(:sh), ["-c", ~S(cd -- "$1" && pwd -P), "sh", ctx.dir])
    {:ok, repo: repo, root: Path.join(String.trim(root), "worktrees/app")}
  end

  test "Checked, Added and the setup: a new branch's tree, set up again at each start", ctx do
    assert {:ok, _} = start(ctx, "w1", "unit/one")
    path = Path.join(ctx.root, "w1")

    assert %{status: "running", cwd: ^path, worktree: "added; not trusted: " <> _} =
             row(ctx, "w1")

    assert {_, 0} = git(ctx, ["-C", ctx.repo, "show-ref", "--verify", "refs/heads/unit/one"])
    assert File.read!(Path.join(path, "built.log")) == "built\n"
    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "w1")

    # The build state the setup made is ignored, so the tree is clean and reused.
    assert {:ok, _} = start(ctx, "w1", "unit/one")
    assert %{worktree: "reused; not trusted: " <> _} = row(ctx, "w1")
    assert File.read!(Path.join(path, "built.log")) == "built\nbuilt\n"
  end

  test "ReusedWasClean: a start refuses a tree with changes, and a resume takes it", ctx do
    assert {:ok, _} = start(ctx, "w2", "unit/two")
    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "w2")
    File.write!(Path.join([ctx.root, "w2", "work.txt"]), "the killed delegate's work\n")

    assert {:refused, {:worktree, :dirty}} = start(ctx, "w2", "unit/two")
    launch = tree_launch(ctx, "unit/two")
    assert {:ok, _} = Sessions.resume(ctx.sessions, "w2", ctx.account, "earlier-2", launch)
    assert %{worktree: "reused; not trusted: " <> _, resume: "earlier-2"} = row(ctx, "w2")
  end

  test "OnlyInTrees: an add at a taken path leaves its branch, which is not the tree", ctx do
    path = Path.join(ctx.root, "w3")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "someone's"), "")

    assert {:refused, {:worktree, {:add, {:git, :add, 128, _}}}} = start(ctx, "w3", "unit/three")
    assert {_, 0} = git(ctx, ["-C", ctx.repo, "show-ref", "--verify", "refs/heads/unit/three"])
    assert %{status: "refused"} = row(ctx, "w3")

    # Once the path is free, the branch left behind is checked out, without -b.
    File.rm_rf!(path)
    assert {:ok, _} = start(ctx, "w3", "unit/three")
    assert %{worktree: "added; not trusted: " <> _} = row(ctx, "w3")
  end

  test "Checked: a path whose tree is on another branch is refused", ctx do
    git!(ctx, ["-C", ctx.repo, "worktree", "add", "-q", "-b", "other", Path.join(ctx.root, "w4")])
    assert {:refused, {:worktree, {:on, "other"}}} = start(ctx, "w4", "unit/four")
  end

  test "SetupEnds: a setup that fails or passes its deadline refuses and keeps the tree", ctx do
    failing = [[program!(:sh), "-c", "exit 3"]]
    sh = program!(:sh)
    assert {:refused, {:setup, ^sh, 3, _}} = start(ctx, "w5", "unit/five", failing)
    assert %{status: "refused", worktree: "added"} = row(ctx, "w5")

    slow = [[program!(:sleep), "5"]]
    assert {:refused, {:setup, :timeout}} = start(ctx, "w5", "unit/five", slow, 300)

    assert {:ok, _} = start(ctx, "w5", "unit/five")
    assert %{status: "running", worktree: "reused; not trusted: " <> _} = row(ctx, "w5")
  end

  test "RowWritten: a path another session's row holds is refused", ctx do
    path = Path.join(ctx.root, "w6")
    File.mkdir_p!(path)
    parent = Keyword.put(SessionsSetup.launch(ctx, :at_start), :cwd, path)
    assert {:ok, _} = Sessions.start(ctx.sessions, "p6", ctx.account, parent)

    assert {:refused, {:held, ["p6"]}} = start(ctx, "w6", "unit/six")
    assert Table.get(ctx.table, "test", "w6") == nil
  end

  test "Remove: a restart ends the setup; then a clean tree is removed, a dirty one kept", ctx do
    clean = task(ctx, "w7", "unit/seven", waiting(ctx, "w7", ""))
    dirty = task(ctx, "w8", "unit/eight", waiting(ctx, "w8", "echo x > work.txt; "))
    pids = for name <- ["w7", "w8"], do: setup_pid(ctx, name)

    Process.exit(ctx.sessions, :kill)
    assert {:unknown, {:exit, :killed}} = Task.await(clean)
    assert {:unknown, {:exit, :killed}} = Task.await(dirty)
    # The reaper ended each setup with the task that ran it.
    for pid <- pids, do: assert({:ok, :gone} = await(fn -> gone(pid) end))

    Agent.update(ctx.clock, &(&1 + 600_000))
    start_supervised!(Supervisor.child_spec({Sessions, ctx.opts}, id: :again))
    assert {:ok, %{worktree: "removed"}} = row_when(ctx, "w7", &(&1.status == "refused"))
    assert {:ok, %{worktree: "kept: dirty"}} = row_when(ctx, "w8", &(&1.status == "refused"))
    refute File.exists?(Path.join(ctx.root, "w7"))
    assert {_, 0} = git(ctx, ["-C", ctx.repo, "show-ref", "--verify", "refs/heads/unit/seven"])
    assert File.exists?(Path.join([ctx.root, "w8", "work.txt"]))
  end

  defp start(ctx, name, branch, setup \\ nil, timeout \\ 10_000),
    do: Sessions.start(ctx.sessions, name, ctx.account, tree_launch(ctx, branch, setup, timeout))

  defp task(ctx, name, branch, setup),
    do: Task.async(fn -> start(ctx, name, branch, setup) end)

  defp tree_launch(ctx, branch, setup \\ nil, timeout \\ 10_000) do
    setup = setup || [[program!(:sh), "-c", "echo built >> built.log"]]

    project = %{
      name: "app",
      repo: ctx.repo,
      trunk: "main",
      setup: setup,
      setup_timeout: timeout,
      env: %{"HOME" => ctx.dir}
    }

    SessionsSetup.launch(ctx, :at_start)
    |> Keyword.delete(:cwd)
    |> Keyword.put(:worktree, %{project: project, branch: branch})
  end

  # A setup that does `first`, writes its pid outside the tree, and waits a bounded time. Its
  # environment has no PATH, so every program is named by its path.
  defp waiting(ctx, name, first) do
    pid_file = Path.join(ctx.dir, "#{name}.setup")
    script = ~s(#{first}echo $$ > "$1.tmp" && "$3" "$1.tmp" "$1"; exec "$2" 30)
    [[program!(:sh), "-c", script, "sh", pid_file, program!(:sleep), program!(:mv)]]
  end

  defp setup_pid(ctx, name) do
    path = Path.join(ctx.dir, "#{name}.setup")
    {:ok, text} = await(fn -> if File.exists?(path), do: File.read(path) end, 10_000)
    String.trim(text)
  end

  defp gone(pid) do
    case System.cmd(program!(:kill), ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> :alive
      _ -> {:ok, :gone}
    end
  end

  defp row(ctx, name), do: Table.get(ctx.table, "test", name)

  defp row_when(ctx, name, ready?) do
    await(
      fn ->
        row = row(ctx, name)
        if row && ready?.(row), do: {:ok, row}, else: row
      end,
      10_000
    )
  end

  # git in an empty environment, on this test's own repository only.
  defp git(ctx, args),
    do:
      System.cmd(program!(:env), ["-i", "HOME=#{ctx.dir}", program!(:git) | args],
        stderr_to_stdout: true
      )

  defp git!(ctx, args) do
    {out, status} = git(ctx, args)
    if status != 0, do: raise("git #{inspect(args)}: #{out}")
    out
  end
end
