defmodule CodingAgentFramework.ScreenTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Screen

  doctest Screen

  @fixtures Path.expand("fixtures/2.1.322", __DIR__)
  @manifest @fixtures |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()
  @release @manifest["claude_version"]

  @trust ["No, exit", "Yes, I trust this folder"]
  @imports ["No, disable external imports", "Yes, allow external imports"]
  @long "/work/shared-notes-with-a-deliberately-…e-path-onto-another-line/" <>
          "outside-file-with-a-long-name.md"
  @permission [
    "Yes",
    "Yes, and always allow access to /work/repo from this project",
    "Yes, and switch to auto mode · auto mode handles these prompts for you",
    "No"
  ]

  # What each state the capture script records reads as. A state the manifest names and this
  # map does not fails the test below, so a new capture is read before it is trusted.
  @expected %{
    "trust-dialog" => %{state: :dialog, kind: :trust, options: @trust, selected: "No, exit"},
    "idle-empty" => %{state: :idle, box: :empty},
    "text-typed" => %{state: :idle, box: {:text, "hello from the capture script"}},
    "turn-running" => %{state: :running},
    "turn-ended" => %{state: :idle, box: :empty},
    "permission-dialog" => %{
      state: :dialog,
      kind: :permission,
      options: @permission,
      selected: "Yes"
    },
    "turn-ended-after-tool" => %{state: :idle, box: :empty},
    "exited" => %{state: :exited},
    "imports-dialog" => %{
      state: :dialog,
      kind: :imports,
      options: @imports,
      selected: "No, disable external imports",
      paths: ["/work/outside.md"],
      shortened: []
    },
    # A path wider than the pane, shortened in the middle on one line (F-144's capture).
    "imports-long-path" => %{
      state: :dialog,
      kind: :imports,
      options: @imports,
      selected: "No, disable external imports",
      paths: [@long],
      shortened: [@long]
    },
    # A main session as the framework launches it, its name in the rule above the box (F-153).
    "main-idle" => %{state: :idle, box: :empty},
    "main-text" => %{state: :idle, box: {:text, "a short draft"}}
  }

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # One change to a fixture; the change must apply, or the test would read the fixture itself.
  defp edit(name, from, to) do
    text = fixture(name)
    assert String.contains?(text, from), "#{name} has no #{inspect(from)}"
    String.replace(text, from, to)
  end

  test "the manifest names each fixture with escapes and without" do
    shown = Enum.reject(@manifest["fixtures"], &(&1["shown"] == false))
    assert Enum.count(shown, & &1["escapes"]) == Enum.count(shown, &(!&1["escapes"]))
    assert shown != []
  end

  for %{"file" => file, "state" => state} = entry <- @manifest["fixtures"],
      entry["shown"] != false do
    test "#{file} reads as #{state}" do
      assert Map.has_key?(@expected, unquote(state)), "no reading expected for #{unquote(state)}"
      assert Screen.read(fixture(unquote(file)), @release) == {:ok, @expected[unquote(state)]}
    end
  end

  # A viewer's window takes the size of whoever attaches, so a person's attach redraws the
  # screen at their width (F-153's new-2): each fixture reads the same with its rules redrawn
  # at 80 and at 400 columns, and with the session's name in the rule above its box.
  describe "at any width" do
    for %{"file" => file, "state" => state} <- @manifest["fixtures"], width <- [80, 400] do
      test "#{file} reads as #{state} at #{width} columns" do
        screen = redraw(fixture(unquote(file)), unquote(width))
        assert Screen.read(screen, @release) == {:ok, @expected[unquote(state)]}
      end
    end

    test "a session's name in the rule above the box, at each width" do
      for width <- [80, 120, 400], file <- ["turn-ended.txt", "text-typed.ansi"] do
        screen = file |> fixture() |> redraw(width) |> name_rule("demo-main", width)
        assert {:ok, %{state: :idle}} = Screen.read(screen, @release), "#{file} at #{width}"
      end

      running = edit("main-idle-120.txt", "· ← for agents", "· esc to interrupt · ← for agents")
      assert Screen.read(running, @release) == {:ok, %{state: :running}}
    end

    test "a name in the rule under the box, or a rule with words and no name's shape, is not the box" do
      under = edit("main-idle-120.txt", "\n" <> String.duplicate("─", 120), "\n" <> named(120))
      assert Screen.read(under, @release) == {:unknown, {:unrecognized, @release}}

      loose = edit("main-idle-120.txt", " capture-main ─\n", " capture-main\n")
      assert Screen.read(loose, @release) == {:unknown, {:unrecognized, @release}}
    end
  end

  # Every rule of the screen drawn `width` columns wide, as Claude Code redraws at that width.
  defp redraw(screen, width) do
    rule = String.duplicate("─", width)

    screen
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      case Regex.run(~r/\A((?:\e\[[0-9;]*m)*)─+((?:\e\[[0-9;]*m)*) *\z/u, line) do
        [_, pre, post] -> pre <> rule <> post
        nil -> String.replace(line, ~r/─+ capture-main ─/u, named(width))
      end
    end)
  end

  defp named(width, name \\ "capture-main"),
    do: String.duplicate("─", width - String.length(name) - 3) <> " #{name} ─"

  # The rule above the box made a named one: the last rule but one.
  defp name_rule(screen, name, width) do
    lines = String.split(screen, "\n")
    rules = for {l, i} <- Enum.with_index(lines), Regex.match?(~r/\A(\e\[[0-9;]*m)*─+/u, l), do: i
    at = Enum.at(rules, -2)

    lines
    |> List.update_at(at, &String.replace(&1, ~r/─+/u, named(width, name)))
    |> Enum.join("\n")
  end

  describe "a fixture with one change" do
    test "a dialog with an unknown question is unrecognized" do
      screen = edit("permission-dialog.txt", "Do you want to proceed?", "Do you want to edit?")
      assert Screen.read(screen, @release) == {:unknown, {:unrecognized, @release}}
    end

    test "a dialog with an unknown footer is unrecognized" do
      screen = edit("trust-dialog.ansi", "Enter", "Space")
      assert Screen.read(screen, @release) == {:unknown, {:unrecognized, @release}}
    end

    test "a dialog with no option selected is unrecognized" do
      screen = edit("permission-dialog.txt", " ❯ 1. Yes", "   1. Yes")
      assert Screen.read(screen, @release) == {:unknown, {:unrecognized, @release}}
    end

    test "a dialog whose options are out of order is unrecognized" do
      screen = edit("permission-dialog.txt", "   2. Yes, and always", "   5. Yes, and always")
      assert Screen.read(screen, @release) == {:unknown, {:unrecognized, @release}}
    end

    test "a line above the options that may be a wrapped option is unrecognized" do
      screen =
        edit("permission-dialog.txt", "   4. No", "      an option's second line\n   4. No")

      assert Screen.read(screen, @release) == {:unknown, {:unrecognized, @release}}
    end

    test "text that starts like the placeholder is text" do
      screen = edit("idle-empty.txt", ~s(Try "how does <filepath> work?"), "Try the build again")

      assert Screen.read(screen, @release) ==
               {:ok, %{state: :idle, box: {:text, "Try the build again"}}}
    end

    test "the prompt mark alone is an empty box" do
      screen = edit("turn-ended.txt", "❯ \n", "❯\n")
      assert Screen.read(screen, @release) == {:ok, %{state: :idle, box: :empty}}
    end

    test "a typed prompt mark is text" do
      screen = edit("turn-ended.txt", "❯ \n", "❯ ❯\n")
      assert Screen.read(screen, @release) == {:ok, %{state: :idle, box: {:text, "❯"}}}
    end

    test "a box of two lines is unrecognized while no turn runs" do
      screen = edit("text-typed.txt", "capture script\n", "capture script\n  and more\n")
      assert Screen.read(screen, @release) == {:unknown, {:unrecognized, @release}}
    end

    test "a done line above a running footer is a running turn" do
      screen =
        edit(
          "turn-ended.txt",
          "⏸ manual mode on · ? for shortcuts",
          "⏸ manual mode on · esc to interrupt"
        )

      assert screen =~ "· done"
      assert Screen.read(screen, @release) == {:ok, %{state: :running}}
    end

    test "a spinner line with no running footer is not a running turn" do
      screen = edit("turn-running.ansi", " · esc to interrupt", "")
      assert screen =~ "Ionizing"
      assert Screen.read(screen, @release) == {:ok, %{state: :idle, box: :empty}}
    end

    test "the imports dialog lists each external path, and needs one" do
      two =
        edit("imports-dialog.txt", "    /work/outside.md\n", "    /work/a.md\n    /work/b.md\n")

      assert {:ok, %{kind: :imports, paths: ["/work/a.md", "/work/b.md"]}} =
               Screen.read(two, @release)

      none = edit("imports-dialog.txt", "    /work/outside.md\n", "")
      assert Screen.read(none, @release) == {:unknown, {:unrecognized, @release}}

      flush = edit("imports-dialog.txt", "    /work/outside.md", "  /work/outside.md")
      assert Screen.read(flush, @release) == {:unknown, {:unrecognized, @release}}
    end

    test "of several paths, only one drawn with an ellipsis is shortened" do
      both =
        edit("imports-long-path.txt", "    /work/shared", "    /work/short.md\n    /work/shared")

      assert {:ok, %{paths: ["/work/short.md", @long], shortened: [@long]}} =
               Screen.read(both, @release)
    end

    test "a dialog's options at another dialog's indent are unrecognized" do
      screen =
        edit(
          "imports-dialog.txt",
          "Allow external CLAUDE.md file imports?",
          "Accessing workspace:"
        )

      assert Screen.read(screen, @release) == {:unknown, {:unrecognized, @release}}
    end

    test "a resume line with more under it is not an exit" do
      screen = fixture("exited.txt") <> "$ \n"
      assert Screen.read(screen, @release) == {:unknown, {:unrecognized, @release}}
    end
  end

  test "a release with no reading is refused" do
    for release <- ["0.0.1", "2.1.999", "latest", "2.1", "../2.1.322", nil] do
      assert Screen.read(fixture("idle-empty.txt"), release) ==
               {:refused, {:unknown_release, release}}
    end
  end

  describe "option_keys/2" do
    test "moves from the trust dialog's selected option to each one" do
      {:ok, screen} = Screen.read(fixture("trust-dialog.txt"), @release)
      assert Screen.option_keys(screen, "No, exit") == {:ok, []}
      assert Screen.option_keys(screen, "Yes, I trust this folder") == {:ok, ["Down"]}
    end

    test "moves from the permission dialog's selected option to each one" do
      {:ok, screen} = Screen.read(fixture("permission-dialog.ansi"), @release)

      keys = for label <- @permission, do: Screen.option_keys(screen, label)

      assert keys == [
               {:ok, []},
               {:ok, ["Down"]},
               {:ok, ["Down", "Down"]},
               {:ok, ["Down", "Down", "Down"]}
             ]
    end

    test "moves up from a selection below" do
      screen =
        "permission-dialog.txt"
        |> edit(" ❯ 1. Yes", "   1. Yes")
        |> String.replace("   4. No", " ❯ 4. No")

      {:ok, %{selected: "No"} = screen} = Screen.read(screen, @release)
      assert Screen.option_keys(screen, "Yes") == {:ok, ["Up", "Up", "Up"]}
    end

    test "moves from the imports dialog's selected option to each one" do
      {:ok, screen} = Screen.read(fixture("imports-dialog.ansi"), @release)
      assert Screen.option_keys(screen, "No, disable external imports") == {:ok, []}
      assert Screen.option_keys(screen, "Yes, allow external imports") == {:ok, ["Down"]}
    end

    test "refuses a label the dialog does not show, and a screen with no dialog" do
      {:ok, dialog} = Screen.read(fixture("trust-dialog.txt"), @release)
      {:ok, idle} = Screen.read(fixture("idle-empty.txt"), @release)
      assert Screen.option_keys(dialog, "Yes") == {:refused, {:no_option, "Yes"}}
      assert Screen.option_keys(idle, "Yes") == {:refused, :no_dialog}
    end
  end
end
