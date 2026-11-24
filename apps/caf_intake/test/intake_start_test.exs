defmodule CodingAgentFramework.IntakeStartTest do
  @moduledoc """
  A session's start (F-236): the app's `session_start:` callback, its deadline and rows, and the
  command hook that posts it, run as Claude Code runs it.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.IntakeSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Intake

  setup {CodingAgentFramework.IntakeSetup, :intake}

  defp start_body(source \\ "startup"),
    do: body("SessionStart", %{"source" => source, "cwd" => "/w/app"})

  # A callback that tells the test it runs, then waits for the test's answer.
  defp waiting(me) do
    fn event ->
      send(me, {:asked, self(), event})

      receive do
        {:answer, answer} -> answer
      end
    end
  end

  defp context(conn) do
    assert conn.status == 200
    JSON.decode!(conn.resp_body)["hookSpecificOutput"]
  end

  test "a context is the hook's additionalContext, and each start is a hold of its own",
       %{db: db, start: start} do
    me = self()

    callback = fn event ->
      send(me, {:asked, event})
      {:context, "Rules for #{event.source}."}
    end

    intake = start.(session_start: callback, agent: fn "work", "s1" -> "builder-1" end)

    assert context(post(intake, start_body())) == %{
             "hookEventName" => "SessionStart",
             "additionalContext" => "Rules for startup."
           }

    assert_received {:asked, event}

    assert event == %{
             agent: "builder-1",
             account: "work",
             session_id: "s1",
             cwd: "/w/app",
             source: "startup"
           }

    # A session starts again at each resume, clear and compact, often with one source twice.
    for _ <- 1..2 do
      assert %{"additionalContext" => "Rules for compact."} =
               context(post(intake, start_body("compact")))
    end

    rows = rows(db)
    assert length(rows) == 3
    assert Enum.all?(rows, &(&1.hold == "answered" and &1.actor == "app"))
  end

  @tag capture_log: true
  test "a pass, a crash and a context too long answer nothing",
       %{db: db, start: start} do
    long = String.duplicate("x", 10_001)

    answers = %{
      "startup" => :pass,
      "resume" => fn -> raise "boom" end,
      "clear" => {:context, long}
    }

    callback = fn %{source: source} ->
      case answers[source] do
        f when is_function(f) -> f.()
        answer -> answer
      end
    end

    intake = start.(session_start: callback)

    for source <- ["startup", "resume", "clear"],
        do: assert(%{status: 200, resp_body: ""} = post(intake, start_body(source)))

    problems = Map.new(rows(db), &{JSON.decode!(&1.data)["source"], {&1.hold, &1.problem}})

    assert problems == %{
             "startup" => {"passed", nil},
             "resume" => {"passed", nil},
             "clear" => {"passed", ~s(["context_too_long",10001])}
           }
  end

  test "an answer after the deadline is dropped", %{db: db, start: start} do
    intake = start.(session_start: waiting(self()), tool_deadline: 100)
    assert %{status: 200, resp_body: ""} = post(intake, start_body())
    assert_received {:asked, worker, _event}
    ref = Process.monitor(worker)
    send(worker, {:answer, {:context, "late"}})
    # The worker's answer is in the Intake's mailbox once it has exited; a call after it is
    # handled after the answer.
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    assert {:ok, false} = Intake.waiter?(intake, "work", "s1")
    assert [%{hold: "expired", decision: nil}] = rows(db)
  end

  test "without the callback a start is a row of its own, never held", %{db: db, start: start} do
    intake = start.([])
    assert %{status: 200, resp_body: ""} = post(intake, start_body())
    assert [%{key: "SessionStart:s1:startup", decision: nil}] = rows(db)
  end

  describe "the hook program" do
    setup %{start: start, dir: dir} do
      me = self()

      callback = fn %{source: source} = event ->
        send(me, {:asked, self(), event})

        case source do
          "startup" -> {:context, "The code word is \"blue\"."}
          "resume" -> :pass
          # Past the 300 ms deadline, and bounded, so no worker outlives the test.
          "clear" -> receive(do: (:never -> :pass), after: (1_000 -> {:context, "late"}))
        end
      end

      intake = start.(session_start: callback, tool_deadline: 300)
      plug = {Intake.Plug, intake: intake, secret: secret()}

      server =
        start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      paths = %{sh: program!(:sh), curl: program!(:curl)}
      {:ok, port: port, paths: paths, dir: dir}
    end

    # Runs the hook's command as Claude Code does, the input on stdin: its exit status and
    # stdout.
    defp run_hook(c, source, secret \\ secret()) do
      {:ok, hooks} = Intake.start_hook(c.port, "work", secret, c.paths)
      [%{"hooks" => [%{"command" => command}]}] = hooks["SessionStart"]
      input = Path.join(c.dir, "input-#{System.unique_integer([:positive])}.json")
      File.write!(input, start_body(source))
      script = ~s(eval "$1" < "$2")

      port =
        Port.open({:spawn_executable, program!(:sh)}, [
          :binary,
          :exit_status,
          args: ["-c", script, "sh", command, input]
        ])

      collect(port, "")
    end

    defp collect(port, out) do
      receive do
        {^port, {:data, data}} -> collect(port, out <> data)
        {^port, {:exit_status, status}} -> {status, out}
      after
        10_000 -> {:timeout, out}
      end
    end

    test "a context is printed as the hook's JSON", c do
      assert {0, out} = run_hook(c, "startup")

      assert JSON.decode!(out) == %{
               "hookSpecificOutput" => %{
                 "hookEventName" => "SessionStart",
                 "additionalContext" => "The code word is \"blue\"."
               }
             }
    end

    test "a pass, a late answer and a wrong secret print nothing and exit 0", c do
      assert run_hook(c, "resume") == {0, ""}
      assert run_hook(c, "clear") == {0, ""}
      assert_received {:asked, _, %{source: "clear"}}
      assert run_hook(c, "startup", "wrong") == {0, ""}
    end
  end
end
