defmodule CodingAgentFramework.IntakeBackgroundTest do
  @moduledoc """
  A background command's stdin closed (F-180): the correction around the next callback, its
  answer through `Intake`, and the corrected command in a shell whose stdin never closes.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.IntakeSetup

  alias CodingAgentFramework.Intake.Background
  alias CodingAgentFramework.TestHost

  setup {CodingAgentFramework.IntakeSetup, :intake}

  doctest Background

  defp bash(command, background \\ true) do
    input = %{"command" => command, "description" => "d", "timeout" => 600_000}

    %{
      agent: "fix-1",
      tool_name: "Bash",
      tool_use_id: "toolu_1",
      tool_input: if(background, do: Map.put(input, "run_in_background", true), else: input)
    }
  end

  defp command({_decision, opts}), do: opts[:updated_input]["command"]

  test "each answer that lets a background command run runs it with stdin at end of file" do
    event = bash("ls")

    assert {:pass, opts} = Background.pre_tool_use(nil).(event)
    # Every other field of the input stays.
    assert opts[:updated_input] == %{event.tool_input | "command" => "exec </dev/null; ls"}
    assert opts[:additional_context] =~ "stdin that never closes"

    assert {:allow, _} = allowed = Background.correct(event, :allow)
    assert command(allowed) == "exec </dev/null; ls"

    # The app's correction is what runs, and the app's context comes first.
    app =
      {:allow,
       updated_input: %{event.tool_input | "command" => "ls -a"}, additional_context: "A."}

    assert {:allow, opts} = Background.correct(event, app)
    assert opts[:updated_input]["command"] == "exec </dev/null; ls -a"
    assert "A.\nThe framework put" <> _ = opts[:additional_context]

    # A context the line would push past Claude Code's limit is the app's alone.
    long = String.duplicate("é", 9_990)
    assert {:allow, opts} = Background.correct(event, {:allow, additional_context: long})
    assert opts[:additional_context] == long
    assert command({:allow, opts}) == "exec </dev/null; ls"
  end

  test "a deny, an ask, a foreground call, another tool or a closed command is left as it is" do
    assert Background.correct(bash("ls"), {:deny, "no"}) == {:deny, "no"}

    assert Background.correct(bash("ls"), {:deny, "no", additional_context: "x"}) ==
             {:deny, "no", additional_context: "x"}

    assert Background.correct(bash("ls"), :ask) == :ask
    assert Background.correct(bash("ls", false), :pass) == :pass
    assert Background.correct(%{bash("ls") | tool_name: "Monitor"}, :pass) == :pass
    assert Background.correct(bash("  exec < /dev/null ; ls"), :allow) == :allow
    assert Background.correct(bash("  "), :pass) == :pass
    # An app that takes the call out of the background takes the correction with it.
    foreground = {:allow, updated_input: Map.delete(bash("ls").tool_input, "run_in_background")}
    assert Background.correct(bash("ls"), foreground) == foreground
  end

  test "the next callback answers on the call as the agent made it, and its crash is a pass" do
    me = self()

    pre =
      Background.pre_tool_use(fn event ->
        send(me, {:asked, event.tool_input["command"]})
        :allow
      end)

    assert {:allow, _} = pre.(bash("make it"))
    assert_received {:asked, "make it"}

    assert {:pass, _} = Background.pre_tool_use(fn _ -> raise "boom" end).(bash("ls"))
  end

  test "through Intake, a pass's correction goes out with no decision", %{db: db, start: start} do
    intake = start.(pre_tool_use: Background.pre_tool_use(fn _ -> :pass end))

    input = %{"command" => "ls", "run_in_background" => true}

    conn =
      post(
        intake,
        body("PreToolUse", %{
          "tool_use_id" => "t1",
          "tool_name" => "Bash",
          "tool_input" => input
        })
      )

    assert conn.status == 200
    output = JSON.decode!(conn.resp_body)["hookSpecificOutput"]
    refute Map.has_key?(output, "permissionDecision")
    assert output["hookEventName"] == "PreToolUse"
    assert output["updatedInput"] == %{input | "command" => "exec </dev/null; ls"}
    assert output["additionalContext"] =~ "stdin that never closes"

    # A correction is a decision as any other: its row keeps what went out.
    assert [row] = rows(db)
    assert {row.actor, row.hold} == {"app", "answered"}
  end

  # The corrected command in `sh -c`, its stdin a pipe from this VM that never closes, as
  # Claude Code's background shell has. Answers its output, once the shell has exited.
  defp run(command) do
    {_pass, opts} = Background.correct(bash(command), :pass)

    port =
      Port.open({:spawn_executable, TestHost.program!(:sh)}, [
        :binary,
        :exit_status,
        args: ["-c", opts[:updated_input]["command"]]
      ])

    collect(port, "")
  end

  defp collect(port, out) do
    receive do
      {^port, {:data, data}} -> collect(port, out <> data)
      {^port, {:exit_status, 0}} -> out
    end
  end

  test "in a shell whose stdin never closes, every program reads end of file, and a redirect keeps its own" do
    dir = TestHost.test_dir()
    file = Path.join(dir, "in.txt")
    File.write!(file, "from the file\n")

    # A program that reads stdin ends at once.
    assert run("cat; echo ended") == "ended\n"
    # A redirect gives its program the file, and the program after it reads end of file.
    assert run("cat < '#{file}'; cat; echo ended") == "from the file\nended\n"
    # A here-doc feeds its program alone.
    assert run("cat <<'EOF'\nfrom the here-doc\nEOF\ncat; echo ended") ==
             "from the here-doc\nended\n"

    # A pipe into a program still gives it the pipe.
    assert run("echo piped | cat; cat; echo ended") == "piped\nended\n"
  end
end
