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
  @menu [
    "Stop and wait for limit to reset",
    "Wait here, then continue automatically at Nov 22 at 11:58pm",
    "Upgrade your plan"
  ]
  @teach %{
    state: :dialog,
    kind: :menu,
    title: "Teach auto mode about your environment?",
    detail: ["Auto mode works better when it knows your environment. Takes about a minute."],
    options: ["Yes", "Not now", "Don't show again"]
  }

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
    "main-text" => %{state: :idle, box: {:text, "a short draft"}},
    # A usage limit's two screens and what each leaves (F-181's captures).
    "usage-limit-menu" => %{
      state: :dialog,
      kind: :usage_limit_menu,
      options: @menu,
      selected: "Stop and wait for limit to reset"
    },
    "usage-limit-wait" => %{state: :usage_limit_wait, at: "7:57am"},
    "usage-limit-stopped" => %{state: :idle, box: :empty},
    "usage-limit-went-on" => %{state: :idle, box: :empty},
    # A menu no rule names, above the box (F-198), with the marker on 1 and, after Down, on 2.
    "menu" => Map.put(@teach, :selected, "Yes"),
    "menu-down" => Map.put(@teach, :selected, "Not now"),
    # A permission dialog no reading names, drawn in the box's place (F-228): a menu to a person,
    # its tool and its question in the detail, the `╌` rules around the tool left out.
    "permission-read-outside" => %{
      state: :dialog,
      kind: :menu,
      title: "Read outside the working directories",
      detail: [
        "Read(/home/user/notes/hand-off.md)",
        "Auto mode and the sandbox read outside the working directories without asking. Yes or No " <>
          "answers for this read; the rest is for later reads. Block: the file tools",
        "refuse reads outside the working directories in every project. The sandbox doesn't " <>
          "enforce it on this machine (off, filesystem rules relaxed, managed read-path lock",
        "on, or working directory name has glob characters). Auto mode asks before each shell " <>
          "command it can't check. To undo, remove",
        "permissions.blockReadsOutsideWorkingDirectories from your user settings; file tools " <>
          "follow next session, sandboxed commands at once.",
        "Allow this read outside the working directories?"
      ],
      options: [
        "Yes, and keep allowing any reads outside the working directories",
        "No, and block reads outside the working directories from now on",
        "No, and ask again next time",
        "Yes, but ask again next time"
      ],
      selected: "Yes, and keep allowing any reads outside the working directories"
    },
    # A dim prompt suggestion is no typed text; without its colors nothing says it is one.
    "suggestion" => %{state: :idle, box: :empty},
    "suggestion-plain" => %{state: :idle, box: {:text, "yes, run the end-to-end rerun"}}
  }

  @suggested "yes, run the end-to-end rerun"

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
    # F-228: a permission dialog whose question no reading names is a menu to a person, not an
    # unrecognized screen that leaves the agent reading as idle.
    test "a permission dialog with an unknown question is a menu to a person" do
      screen = edit("permission-dialog.txt", "Do you want to proceed?", "Do you want to edit?")
      assert {:ok, %{state: :dialog, kind: :menu, detail: detail}} = Screen.read(screen, @release)
      assert List.last(detail) == "Do you want to edit?"
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

    test "the wait's notice makes no empty box an ended turn, and its time is read" do
      screen = edit("usage-limit-wait.txt", "at 7:57am · Esc", "at Nov 22 at 11:58pm · Esc")

      assert Screen.read(screen, @release) ==
               {:ok, %{state: :usage_limit_wait, at: "Nov 22 at 11:58pm"}}

      gone =
        edit(
          "usage-limit-wait.txt",
          "    Continuing automatically at 7:57am · Esc to cancel\n",
          ""
        )

      assert Screen.read(gone, @release) == {:ok, %{state: :idle, box: :empty}}
    end

    test "the menu's third option is read by its label, whatever it is" do
      screen = edit("usage-limit-menu.ansi", "Upgrade your plan", "Use usage credits")

      assert {:ok, %{kind: :usage_limit_menu, options: [_, _, "Use usage credits"]}} =
               Screen.read(screen, @release)
    end

    test "the usage limit menu's options under a rule of ─ are a menu no rule names" do
      screen =
        edit("usage-limit-menu.txt", String.duplicate("▔", 120), String.duplicate("─", 120))

      assert {:ok, %{kind: :menu, title: "What do you want to do?", options: @menu}} =
               Screen.read(screen, @release)
    end

    test "a menu with blank lines around its parts reads the same" do
      screen =
        "menu.ansi"
        |> edit("  Auto mode works", "\n  Auto mode works")
        |> String.replace("    3. Don't show again\n", "    3. Don't show again\n\n")
        |> String.replace("Esc to cancel\n", "Esc to cancel\n\n")

      assert Screen.read(screen, @release) == {:ok, Map.put(@teach, :selected, "Yes")}
    end

    test "a numbered list with no menu footer is the agent's output, not a menu" do
      screen = edit("menu.txt", "  Enter to confirm · Esc to cancel\n", "")
      assert Screen.read(screen, @release) == {:ok, %{state: :idle, box: {:text, @suggested}}}

      assert {:ok, %{state: :idle, box: :empty}} =
               Screen.read(fixture("suggestion.ansi"), @release)
    end

    test "a menu needs two numbered options in a row, from 1, one marked, one indent" do
      for {from, to} <- [
            {"    2. Not now\n    3. Don't show again\n", ""},
            {"    3. Don't show again", "    4. Don't show again"},
            {"    2. Not now", "      an option's second line\n    2. Not now"},
            {"  ❯ 1. Yes", "    1. Yes"},
            {"    2. Not now", "  ❯ 2. Not now"},
            {"    3. Don't show again", "     3. Don't show again"},
            {"    3. Don't show again\n", "    3. Don't show again\n  More words\n"}
          ] do
        screen = edit("menu.txt", from, to)

        assert Screen.read(screen, @release) == {:unknown, {:unrecognized, @release}},
               "#{inspect(from)} -> #{inspect(to)}"
      end
    end

    test "a menu the agent's output prints, rules and all, above the box is not a menu" do
      printed = "menu.txt" |> fixture() |> String.split("\n") |> Enum.take(8) |> Enum.join("\n")
      screen = printed <> "\n  and the agent goes on\n" <> fixture("idle-empty.txt")
      assert Screen.read(screen, @release) == {:ok, %{state: :idle, box: :empty}}
    end

    test "a menu footer with more under it than the box is not a menu's" do
      screen =
        edit(
          "menu.txt",
          "  Enter to confirm · Esc to cancel\n",
          "  Enter to confirm · Esc to cancel\n  and more\n"
        )

      assert Screen.read(screen, @release) == {:ok, %{state: :idle, box: {:text, @suggested}}}
    end

    test "a dim run only on the box's line is dropped, up to its reset" do
      dim = "\e[39m❯ \e[2myes, run the end-to-end rerun\e[0m"
      typed = "\e[39m❯ ye\e[2ms, run the end-to-end rerun\e[22m"
      truecolor = "\e[39m❯ \e[38;2;1;2;3mhello\e[0m"

      for {line, box} <- [{dim, :empty}, {typed, {:text, "ye"}}, {truecolor, {:text, "hello"}}] do
        screen = edit("suggestion.ansi", dim, line)
        assert Screen.read(screen, @release) == {:ok, %{state: :idle, box: box}}
      end

      assert Screen.read(fixture("exited.ansi"), @release) == {:ok, %{state: :exited}}
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

    test "moves from the usage limit menu's selected option to its stop" do
      {:ok, screen} = Screen.read(fixture("usage-limit-menu.ansi"), @release)
      assert Screen.option_keys(screen, "Stop and wait for limit to reset") == {:ok, []}
      assert Screen.option_keys(screen, "Upgrade your plan") == {:ok, ["Down", "Down"]}
    end

    test "moves from a menu's marker to each option" do
      {:ok, screen} = Screen.read(fixture("menu-down.ansi"), @release)
      assert Screen.option_keys(screen, "Yes") == {:ok, ["Up"]}
      assert Screen.option_keys(screen, "Don't show again") == {:ok, ["Down"]}
    end

    test "refuses a label the dialog does not show, and a screen with no dialog" do
      {:ok, dialog} = Screen.read(fixture("trust-dialog.txt"), @release)
      {:ok, idle} = Screen.read(fixture("idle-empty.txt"), @release)
      assert Screen.option_keys(dialog, "Yes") == {:refused, {:no_option, "Yes"}}
      assert Screen.option_keys(idle, "Yes") == {:refused, :no_dialog}
    end
  end
end
