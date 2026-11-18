defmodule CodingAgentFramework.ToolHomeTest do
  @moduledoc """
  The home's tool files (F-155) with devenv's real git and ssh-keygen in this test's own
  directory: a commit under the home's config carries the author it was given and a signature
  git verifies, and a project's override reaches its checkout's worktrees.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.ToolHome

  doctest ToolHome

  setup do
    dir = test_dir()
    home = Path.join(dir, "home")
    File.mkdir_p!(Path.join(home, "git"))
    key(ToolHome.signing_key(home))
    {:ok, dir: dir, home: home}
  end

  test "a commit carries the home's author and a signature git verifies", ctx do
    author = %{
      name: "App Bot",
      email: "bot@example.com",
      signing_key: ToolHome.signing_key(ctx.home)
    }

    assert :ok = prepare(ctx.home, author, %{})

    repo = Path.join(ctx.dir, "repo")
    git!(ctx, ["init", "-q", "-b", "main", repo])
    git!(ctx, ["-C", repo, "commit", "-q", "--allow-empty", "-m", "one"])

    assert git!(ctx, ["-C", repo, "log", "-1", "--format=%an <%ae> %G?"]) ==
             "App Bot <bot@example.com> G\n"

    assert git!(ctx, ["-C", repo, "log", "-1", "--show-signature"]) =~
             ~s(Good "git" signature for bot@example.com)

    # The files a tool keeps go in the home; ssh's are made once and kept.
    for {_, path} <- ToolHome.env(ctx.home, program!(:ssh)), String.starts_with?(path, "/") do
      assert File.exists?(path), path
    end

    File.write!(Path.join([ctx.home, "ssh", "config"]), "Host box\n")
    assert :ok = prepare(ctx.home, author, %{})
    assert File.read!(Path.join([ctx.home, "ssh", "config"])) == "Host box\n"
  end

  test "a project's override reaches every worktree of its checkout", ctx do
    own = ToolHome.signing_key(ctx.home, "demo_signing_key")
    key(own)

    author = %{
      name: "App Bot",
      email: "bot@example.com",
      signing_key: ToolHome.signing_key(ctx.home)
    }

    checkout = Path.join(ctx.dir, "checkouts/demo")
    project = %{checkout: checkout, name: "Demo Bot", signing_key: own}
    assert :ok = prepare(ctx.home, author, %{"demo" => project})

    git!(ctx, ["init", "-q", "-b", "main", checkout])
    git!(ctx, ["-C", checkout, "commit", "-q", "--allow-empty", "-m", "one"])
    worktree = Path.join(ctx.dir, "worktrees/demo/unit-one")
    git!(ctx, ["-C", checkout, "worktree", "add", "-q", "-b", "unit/one", worktree])
    git!(ctx, ["-C", worktree, "commit", "-q", "--allow-empty", "-m", "two"])

    for repo <- [checkout, worktree] do
      assert git!(ctx, ["-C", repo, "log", "-1", "--format=%an <%ae> %G?"]) ==
               "Demo Bot <bot@example.com> G\n"
    end

    # Another repository keeps the home's author.
    other = Path.join(ctx.dir, "other")
    git!(ctx, ["init", "-q", "-b", "main", other])
    git!(ctx, ["-C", other, "commit", "-q", "--allow-empty", "-m", "one"])
    assert git!(ctx, ["-C", other, "log", "-1", "--format=%an"]) == "App Bot\n"
  end

  test "a missing key, a bad author or a home with a space is refused", ctx do
    author = %{
      name: "App Bot",
      email: "bot@example.com",
      signing_key: Path.join(ctx.home, "nokey")
    }

    assert {:refused, {:no_signing_key, _}} = prepare(ctx.home, author, %{})
    refute File.exists?(ToolHome.git_config(ctx.home))

    assert {:refused, {:bad, :email}} = prepare(ctx.home, %{author | email: "bot"}, %{})

    # With no author, git refuses a commit rather than guess one from the machine.
    assert :ok = prepare(ctx.home, nil, %{})
    repo = Path.join(ctx.dir, "bare")
    git!(ctx, ["init", "-q", "-b", "main", repo])
    assert {out, 128} = git(ctx, ["-C", repo, "commit", "-q", "--allow-empty", "-m", "one"])
    assert out =~ "no name was given and auto-detection is disabled" or out =~ "no email"
    assert {:refused, {:whitespace, _}} = prepare(ctx.home <> " x", author, %{})
  end

  defp prepare(home, author, projects) do
    ToolHome.prepare(home,
      author: author,
      projects: projects,
      gh: program!(:gh),
      ssh_keygen: program!(:ssh_keygen)
    )
  end

  defp key(path) do
    {_, 0} = System.cmd(program!(:ssh_keygen), ["-q", "-t", "ed25519", "-N", "", "-f", path])
  end

  # git with the home's environment only, as a launch, a job or a service runs it.
  defp git!(ctx, args) do
    {out, 0} = git(ctx, args)
    out
  end

  defp git(ctx, args) do
    env = [{"HOME", ctx.dir}, {"PATH", "/nonexistent"} | ToolHome.env(ctx.home, program!(:ssh))]
    vars = Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)
    System.cmd(program!(:env), ["-i" | vars] ++ [program!(:git) | args], stderr_to_stdout: true)
  end
end
