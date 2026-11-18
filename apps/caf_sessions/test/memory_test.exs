defmodule CodingAgentFramework.Sessions.MemoryTest do
  @moduledoc """
  One memory per checkout (F-155): each account's memory folder of a cwd is a link to the
  home's one, an account's own folder is moved in once, and nothing is written over.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Sessions.Memory

  doctest Memory

  setup do
    dir = test_dir()
    cwd = Path.join(dir, "checkouts/demo")

    accounts =
      for a <- ["one", "two"], into: %{}, do: {a, Path.join([dir, "accounts", a, "claude"])}

    {:ok, shared} = Memory.dir(dir, cwd)
    {:ok, dir: dir, cwd: cwd, accounts: accounts, shared: shared}
  end

  test "every account's memory of a cwd is the home's one folder", ctx do
    for {_, config} <- ctx.accounts do
      assert :ok = Memory.link(ctx.dir, config, ctx.cwd)
      assert :ok = Memory.link(ctx.dir, config, ctx.cwd)
    end

    File.write!(Path.join(memory(ctx, "one"), "MEMORY.md"), "kept")
    assert File.read!(Path.join(memory(ctx, "two"), "MEMORY.md")) == "kept"
    assert File.read!(Path.join(ctx.shared, "MEMORY.md")) == "kept"
  end

  test "an account's own folder is moved in once; with both holding files it is refused", ctx do
    File.mkdir_p!(memory(ctx, "one"))
    File.write!(Path.join(memory(ctx, "one"), "a.md"), "from one")
    assert :ok = Memory.link(ctx.dir, ctx.accounts["one"], ctx.cwd)
    assert {:ok, _} = File.read_link(memory(ctx, "one"))
    assert File.read!(Path.join(ctx.shared, "a.md")) == "from one"

    File.mkdir_p!(memory(ctx, "two"))
    File.write!(Path.join(memory(ctx, "two"), "b.md"), "from two")
    two = memory(ctx, "two")
    shared = ctx.shared
    assert {:refused, {:both, ^two, ^shared}} = Memory.link(ctx.dir, ctx.accounts["two"], ctx.cwd)
    assert File.read!(Path.join(two, "b.md")) == "from two"
    refute File.exists?(Path.join(shared, "b.md"))
  end

  test "a file or a link elsewhere is left as it is and refused", ctx do
    File.mkdir_p!(Path.dirname(memory(ctx, "one")))
    File.write!(memory(ctx, "one"), "a file")
    path = memory(ctx, "one")
    assert {:refused, {:not_a_folder, ^path}} = Memory.link(ctx.dir, ctx.accounts["one"], ctx.cwd)

    File.mkdir_p!(Path.dirname(memory(ctx, "two")))
    File.ln_s!(ctx.dir, memory(ctx, "two"))

    assert {:refused, {:links_elsewhere, _, _}} =
             Memory.link(ctx.dir, ctx.accounts["two"], ctx.cwd)

    assert File.read!(path) == "a file"
  end

  defp memory(ctx, account) do
    {:ok, dir} = CodingAgentFramework.Transcripts.project_dir(ctx.accounts[account], ctx.cwd)
    Path.join(dir, "memory")
  end
end
