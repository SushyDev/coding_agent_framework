defmodule CodingAgentFramework.CaptureScreenTest do
  @moduledoc """
  Runs `bin/capture-screen --dry-run` on a real tmux server of its own, with a stand-in in place
  of Claude Code, and checks the fixtures it writes, their manifest and the scrubbing. Each run
  has its own home, temporary and output directories inside this test's directory.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  @script Path.expand("../../../bin/capture-screen", __DIR__)
  @states ~w(trust-dialog idle-empty text-typed turn-running turn-ended permission-dialog
             turn-ended-after-tool turn-ended-background exit-dialog exited)

  setup do
    dir = test_dir()
    paths = for name <- [:home, :tmp, :out], into: %{}, do: {name, Path.join(dir, "#{name}")}
    Enum.each(Map.values(paths), &File.mkdir_p!/1)
    Map.put(paths, :dir, dir)
  end

  # The script's own temporary directory, under `tmp`, holds its socket and scratch repository.
  defp capture(ctx, config, args \\ []) do
    File.mkdir_p!(config)

    System.cmd(program!(:bash), [@script, "--dry-run", "--out", ctx.out] ++ args ++ [config],
      env: [{"HOME", ctx.home}, {"TMPDIR", ctx.tmp}],
      stderr_to_stdout: true
    )
  end

  test "writes each state with and without escapes, scrubbed, with a manifest", ctx do
    config = Path.join([ctx.home, "accounts", "Ada Lovelace", "claude"])
    {output, status} = capture(ctx, config, ["--name", "Ada Lovelace"])
    assert status == 0, output

    dest = Path.join(ctx.out, "dry-run")
    files = for state <- @states, ext <- ~w(txt ansi), do: "#{state}.#{ext}"
    assert Enum.sort(File.ls!(dest)) == Enum.sort(["manifest.json" | files])

    manifest = dest |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()
    assert %{"claude_version" => "dry-run", "dry_run" => true} = manifest
    assert manifest["pane"] == %{"width" => 120, "height" => 40}
    assert Enum.map(manifest["fixtures"], & &1["file"]) == files

    for entry <- manifest["fixtures"] do
      assert entry["file"] == "#{entry["state"]}.#{if entry["escapes"], do: "ansi", else: "txt"}"
      assert {entry["width"], entry["height"]} == {120, 40}
      assert {:ok, _, 0} = DateTime.from_iso8601(entry["captured_at"])
    end

    for state <- @states do
      text = File.read!(Path.join(dest, "#{state}.txt"))
      escaped = File.read!(Path.join(dest, "#{state}.ansi"))

      assert text =~ "[stand-in: #{state}]"
      assert length(String.split(text, "\n", trim: true)) <= 40
      refute text =~ "\e"
      assert escaped =~ "\e["

      for fixture <- [text, escaped] do
        assert fixture =~ "cwd: /work/repo"
        assert fixture =~ "home: /home/user\n"
        assert fixture =~ "config: /home/user/accounts/Person/claude\n"
        assert fixture =~ "user: user on host\n"
        refute fixture =~ ctx.dir
        refute fixture =~ "Ada Lovelace"
      end
    end

    # The stand-in redraws after each key and names its state at the end of every draw, so the
    # name is on the screen after the first key. The capture has to wait for the last one.
    for ext <- ~w(txt ansi) do
      assert File.read!(Path.join(dest, "text-typed.#{ext}")) =~
               "│ > hello from the capture script ",
             "text-typed.#{ext} was captured before all the typed text was drawn"
    end

    assert String.split(File.read!(Path.join(dest, "trust-dialog.txt")), "\n")
           |> Enum.member?("/work/repo")

    assert output =~ "trust-dialog.txt:3\n  - home: #{ctx.home}\n  + home: /home/user\n"
    assert File.ls!(ctx.tmp) == [], "the script left #{inspect(File.ls!(ctx.tmp))}"
  end

  test "refuses a name the screen shows in another case, and writes nothing", ctx do
    config = Path.join([ctx.home, "accounts", "ADA LOVELACE", "claude"])
    {output, status} = capture(ctx, config, ["--name", "Ada Lovelace"])

    assert status == 1, output
    assert output =~ ~s(still holds "Ada Lovelace")
    assert output =~ "nothing written"
    assert File.ls!(ctx.out) == []
    assert File.ls!(ctx.tmp) == []
  end

  test "refuses a home path the screen wraps across two lines", ctx do
    home = Path.join(ctx.dir, String.duplicate("h", 130))
    {output, status} = capture(%{ctx | home: home}, Path.join(home, "claude"))

    assert status == 1, output
    assert output =~ ~s(cuts "#{home}" across two lines)
    assert File.ls!(ctx.out) == []
    assert File.ls!(ctx.tmp) == []
  end

  test "refuses the default config directory before it starts anything", ctx do
    {output, status} = capture(ctx, Path.join(ctx.home, ".claude"))

    assert status == 1, output
    assert output =~ "is the default directory"
    assert File.ls!(ctx.tmp) == []
  end
end
