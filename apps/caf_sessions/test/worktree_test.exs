defmodule CodingAgentFramework.Sessions.WorktreeTest do
  @moduledoc "The pure checks of `Sessions.Worktree`, from what git prints."
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Sessions.Worktree

  doctest Worktree

  test "a branch name is never read as an option or a revision" do
    for bad <- ["-b", "a..b", "a//b", "a/", ".a", "a.lock", "a b", "a~1", "a^", "a:b", ""],
        do: assert(Worktree.branch(bad) == {:refused, {:bad, :branch}}, bad)
  end

  test "a project names its repository and every program by an absolute path" do
    good = %{name: "app", repo: "/r", trunk: "main", setup: [], setup_timeout: 1, env: %{}}
    assert {:ok, _} = Worktree.project(good)
    assert {:refused, {:bad, :repo}} = Worktree.project(%{good | repo: "r"})
    assert {:refused, {:bad, :setup}} = Worktree.project(%{good | setup: [["make"]]})
    assert {:refused, {:bad, :env}} = Worktree.project(%{good | env: %{"A B" => "1"}})
    assert {:refused, {:missing, :project, [:env]}} = Worktree.project(Map.delete(good, :env))
  end

  test "Remove keeps anything that is not a clean tree on the row's branch, held by no one" do
    assert Worktree.removal(:absent, nil, "b", false) == {:keep, "absent"}
    assert Worktree.removal({:branch, "b"}, "", "b", true) == {:keep, "held"}
    assert Worktree.removal({:branch, "c"}, "", "b", false) == {:keep, "not on the branch"}
    assert Worktree.removal(:detached, nil, "b", false) == {:keep, "not on the branch"}
  end
end
