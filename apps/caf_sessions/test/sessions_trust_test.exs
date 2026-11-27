defmodule CodingAgentFramework.SessionsTrustTest do
  @moduledoc """
  The trust mark a start writes on its account before it runs in a worktree the framework made
  (F-255, `model/tla/Trust.tla`), over a real `Sessions`, `Inlet`, `Registry`, git, dtach and
  tmux in this test's own directory, with the screen stand-in drawing 2.1.322's trust dialog
  unless `.claude.json` marks its folder's real path, as the real program does.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Acts, Inlet, Registry, ScreenStandIn, Sessions}
  alias CodingAgentFramework.SessionsSetup
  alias CodingAgentFramework.Sessions.{Agents, Dialog, Table}

  @trust "Yes, I trust this folder"
  # What Claude Code keeps in `.claude.json` after its first start, in short.
  @state %{"hasCompletedOnboarding" => true, "numStartups" => 3, "projects" => %{"/x" => %{}}}

  setup {SessionsSetup, :sessions}

  setup ctx do
    repo = Path.join(ctx.dir, "repo")
    git!(ctx, ["init", "-q", "-b", "main", repo])

    git!(
      ctx,
      ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q"] ++
        ["--allow-empty", "-m", "init"]
    )

    # The root as git prints it: the test's directory may sit behind a symlink (/tmp on macOS).
    {root, 0} = System.cmd(program!(:sh), ["-c", ~S(cd -- "$1" && pwd -P), "sh", ctx.dir])
    see = scaled(2_000)
    inlet = start_supervised!({Inlet, tmux: ctx.server, see: see})
    claude = ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), trust: true, marks: true)
    write_state!(ctx.account)
    {:ok, agents} = Agents.open(Path.join(ctx.dir, "caf.db"), "test")

    {:ok,
     repo: repo,
     root: Path.join(String.trim(root), "worktrees"),
     claude: claude,
     agents: agents,
     opts: ctx.opts ++ [inlet: inlet, look: 50]}
  end

  # MarkBeforeStart: the mark is on the account before the hold, so the program shows no
  # dialog and nothing is pressed; Claude Code's own keys stay. A start again finds it there.
  test "a start in a worktree the framework made is trusted first, and never pressed", ctx do
    sessions = sessions(ctx)
    path = Path.join([ctx.root, "app", "t1"])

    assert {:ok, _} = Sessions.start(sessions, "t1", ctx.account, tree_launch(ctx, "unit/t1"))
    assert %{status: "running", cwd: ^path, worktree: "added; trusted"} = row(ctx, "t1")
    assert ScreenStandIn.dialog_keys(ctx.dir) == []
    refute File.exists?(Path.join(ctx.dir, "trusted"))

    state = read_state!(ctx.account)
    assert state["projects"][path] == %{"hasTrustDialogAccepted" => true}

    assert Map.take(state, ["hasCompletedOnboarding", "numStartups"]) ==
             Map.delete(@state, "projects")

    assert state["projects"]["/x"] == %{}
    refute File.exists?(lock(ctx.account))
    # Claude Code writes the file 0600; the mark keeps the file's mode.
    assert File.stat!(state_file(ctx.account)).mode |> Bitwise.band(0o777) == 0o600

    # A stop waits on the session file's idle, which a loaded host writes late; a refused stop
    # changes nothing, so it is asked again.
    assert {:ok, :stopped} = await(fn -> Sessions.stop(sessions, "t1") end, 30_000)
    assert {:ok, _} = Sessions.start(sessions, "t1", ctx.account, tree_launch(ctx, "unit/t1"))
    assert %{worktree: "reused; trusted already"} = row(ctx, "t1")
    assert ScreenStandIn.dialog_keys(ctx.dir) == []
  end

  # Only a tree the framework made: a start in another folder writes no mark and meets the
  # dialog, as before. The operator's rule names no other folder (F-286, `Dialog.tla`'s
  # TrustAny): nothing presses it, and it waits on a person.
  test "a start outside the worktrees gets no mark and meets the trust dialog", ctx do
    acts = acts(ctx)
    sessions = sessions(ctx, acts: acts)
    launch = SessionsSetup.launch(ctx, :at_start) |> Keyword.put(:claude, ctx.claude)

    assert {:unknown, {:dialog, :trust}} = Sessions.start(sessions, "t2", ctx.account, launch)
    assert read_state!(ctx.account) == @state
    assert %{status: "dialog", trust: nil} = Agents.get(ctx.agents, "t2")
    assert ScreenStandIn.dialog_keys(ctx.dir) == []
    assert {:ok, []} = Acts.rows(acts, act: "answer_startup")
  end

  # RefusedWroteNothing, and the operator's rule as the fallback (F-286, `Dialog.tla`'s Rule):
  # a lock another writer holds refuses the mark at once, the row says so, and the trust dialog
  # the start then meets is pressed by the framework, no person asked, an act in `Acts` naming
  # the rule and the folder. The start goes on to run.
  test "a mark refused while the lock is held leaves the dialog to the rule's press", ctx do
    acts = acts(ctx)
    sessions = sessions(ctx, acts: acts)
    File.mkdir!(lock(ctx.account))
    path = Path.join([ctx.root, "app", "t3"])

    assert {:ok, _} = Sessions.start(sessions, "t3", ctx.account, tree_launch(ctx, "unit/t3"))

    assert %{status: "running", trust: "worktree", worktree: "added; not trusted: locked"} =
             row(ctx, "t3")

    assert read_state!(ctx.account) == @state
    # The lock is the other writer's: it is left as it was.
    assert File.dir?(lock(ctx.account))
    assert File.exists?(Path.join(ctx.dir, "trusted"))
    assert_rule_act(acts, "t3", "worktree", path)
    assert %{trust: %{label: @trust, mark: "sent"}} = Dialog.answers(row(ctx, "t3"))
  end

  # The rule's other folder (F-286): a main session's checkout the app configured, which its
  # caller names (`Mains` does, `trusted: :checkout`). The framework presses the trust dialog
  # there as in a worktree; the row keeps the rule. A delegate, or a worktree's start, may not
  # name it.
  test "a main session's start in its configured checkout passes the trust dialog", ctx do
    acts = acts(ctx)
    sessions = sessions(ctx, acts: acts)

    launch =
      SessionsSetup.launch(ctx, :at_start)
      |> Keyword.merge(claude: ctx.claude, cwd: ctx.repo, trusted: :checkout)

    assert {:ok, _} = Sessions.start(sessions, "t5", ctx.account, launch)
    assert %{status: "running", trust: "checkout", cwd: cwd} = row(ctx, "t5")
    assert ScreenStandIn.dialog_keys(ctx.dir) == ["down", "enter"]
    assert_rule_act(acts, "t5", "checkout", cwd)

    delegate = Keyword.merge(launch, role: :delegate, kind: :delegate, parent: "t5")
    assert {:refused, {:bad, :trusted}} = Sessions.start(sessions, "t6", ctx.account, delegate)

    tree = Keyword.put(tree_launch(ctx, "unit/t7"), :trusted, :checkout)
    assert {:refused, {:bad, :trusted}} = Sessions.start(sessions, "t7", ctx.account, tree)
    assert row(ctx, "t6") == nil and row(ctx, "t7") == nil
  end

  # A move resumes its session on the other account with the row's worktree, as
  # `Mover` does (`Sessions.resume/6`): the mark is written there before that start.
  test "a resume on another account marks the tree on that account first", ctx do
    {:ok, accounts} = Accounts.new(Path.join(ctx.dir, "home"), ["work", "spare"])
    {:ok, spare} = Accounts.prepare(accounts, "spare", %{})
    File.mkdir_p!(Path.join(spare.config_dir, "sessions"))
    write_state!(spare)

    dirs = %{"work" => ctx.account.config_dir, "spare" => spare.config_dir}
    db = Path.join(ctx.dir, "registry.db")

    registry =
      start_supervised!(
        Supervisor.child_spec({Registry, programs: programs(), accounts: dirs, db: db},
          id: :both
        )
      )

    sessions = sessions(ctx, registry: registry)
    path = Path.join([ctx.root, "app", "t4"])

    assert {:ok, _} = Sessions.start(sessions, "t4", ctx.account, tree_launch(ctx, "unit/t4"))
    assert {:ok, :stopped} = Sessions.stop(sessions, "t4")
    refute Map.has_key?(read_state!(spare)["projects"], path)

    launch = tree_launch(ctx, "unit/t4")
    assert {:ok, _} = Sessions.resume(sessions, "t4", spare, "earlier-4", launch)
    assert %{account: "spare", worktree: "reused; trusted"} = row(ctx, "t4")
    assert read_state!(spare)["projects"][path] == %{"hasTrustDialogAccepted" => true}
    assert ScreenStandIn.dialog_keys(ctx.dir) == []
  end

  defp sessions(ctx, extra \\ []) do
    spec =
      Supervisor.child_spec({Sessions, Keyword.merge(ctx.opts, extra)},
        id: make_ref(),
        restart: :temporary
      )

    start_supervised!(spec)
  end

  defp acts(ctx) do
    spec = {Acts, db: Path.join(ctx.dir, "acts.db"), start_id: "t", host: "test", instance: "a"}
    start_supervised!(spec)
  end

  # The rule's press is one act, by the framework, the rule and the folder in its detail,
  # settled verified once the press's answer comes back, which may be after the start's.
  defp assert_rule_act(acts, name, rule, folder) do
    assert {:ok, [act]} =
             await(fn ->
               case Acts.rows(acts, act: "answer_startup", target: name) do
                 {:ok, [%{status: "settled"}]} = settled -> settled
                 _ -> nil
               end
             end)

    assert %{actor: "framework", outcome: "verified", detail: detail} = act
    assert detail =~ "operator_rule" and detail =~ rule and detail =~ folder
  end

  defp tree_launch(ctx, branch) do
    project = %{
      name: "app",
      repo: ctx.repo,
      trunk: "main",
      setup: [],
      setup_timeout: 10_000,
      env: %{"HOME" => ctx.dir}
    }

    SessionsSetup.launch(ctx, :at_start)
    |> Keyword.delete(:cwd)
    |> Keyword.put(:claude, ctx.claude)
    |> Keyword.put(:worktree, %{project: project, branch: branch})
  end

  defp state_file(account), do: Path.join(account.config_dir, ".claude.json")
  defp lock(account), do: state_file(account) <> ".lock"

  defp write_state!(account) do
    File.write!(state_file(account), JSON.encode!(@state))
    File.chmod!(state_file(account), 0o600)
  end

  defp read_state!(account), do: account |> state_file() |> File.read!() |> JSON.decode!()

  defp row(ctx, name), do: Table.get(ctx.table, "test", name)

  # git in an empty environment, on this test's own repository only.
  defp git!(ctx, args) do
    {out, status} =
      System.cmd(program!(:env), ["-i", "HOME=#{ctx.dir}", program!(:git) | args],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("git #{inspect(args)}: #{out}")
    out
  end
end
