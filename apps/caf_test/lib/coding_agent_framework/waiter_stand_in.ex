defmodule CodingAgentFramework.WaiterStandIn do
  @moduledoc """
  Claude Code's side of a main session's waiter, for tests, beside the interactive stand-in
  (`CodingAgentFramework.ClaudeStandIn`): at a turn's end it runs the session's Stop hooks of
  type `command` with `asyncRewake`, from the settings file the session was started with, as
  Claude Code does, with the Stop hook's input on stdin. When the hook exits 2, it writes the
  transcript lines Claude Code 2.1.322 writes for its stderr text (measured in F-114 and for
  F-127), in the `shape` the test names:

  - `:idle`, the session idle: a `queue-operation` `enqueue` line, a `dequeue` and the user line
    `Stop hook blocking error from command "Stop": <text>`;
  - `:busy`, a person's turn running: the `enqueue`, then at the turn's next tool boundary a
    `remove` and an `attachment` of type `queued_command`, with no user line;
  - `:enqueued`, only the `enqueue` (the process ended before it took the text);
  - `:lost`, no line (the text was written to a connection that had died unseen).

  Each line's `content` is the text inside the `task-notification` and `system-reminder` that
  wrap it.

      task = WaiterStandIn.turn_end(settings, "s1", transcript, :idle)
      Task.await(task)
      #=> {2, "a report is due"}
  """

  import CodingAgentFramework.TestHost, only: [program!: 1, test_dir: 0]

  @doc """
  Runs the waiter hooks of `settings` (a path) for session `session_id` in a task, and answers
  it. The task answers `{status, text}` once the hook exits, after it wrote `shape`'s lines to
  `transcript`; `{:no_hook, settings}` when the file names no waiter.
  """
  def turn_end(settings, session_id, transcript, shape)
      when shape in [:idle, :busy, :enqueued, :lost] do
    input = JSON.encode!(%{"hook_event_name" => "Stop", "session_id" => session_id})

    Task.async(fn ->
      case command(settings) do
        nil ->
          {:no_hook, settings}

        command ->
          case run(command, input) do
            {2, text} -> write(transcript, session_id, String.trim_trailing(text), shape)
            other -> other
          end
      end
    end)
  end

  @doc "The waiter hook's command in the settings file at `path`, or nil."
  def command(path) do
    hooks = JSON.decode!(File.read!(path)) |> Map.get("hooks", %{}) |> Map.get("Stop", [])

    Enum.find_value(hooks, fn %{"hooks" => list} ->
      Enum.find_value(list, &if(&1["asyncRewake"] == true, do: &1["command"]))
    end)
  end

  defp run(command, input) do
    dir = Path.join(test_dir(), "waiter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {in_file, err} = {Path.join(dir, "in"), Path.join(dir, "err")}
    File.write!(in_file, input)

    port =
      Port.open({:spawn_executable, program!(:sh)}, [
        :binary,
        :exit_status,
        args: ["-c", ~S(eval "$1" < "$2" 2> "$3"), "sh", command, in_file, err]
      ])

    status =
      receive do
        {^port, {:exit_status, status}} -> status
      end

    text = File.read!(err)
    File.rm_rf!(dir)
    {status, text}
  end

  defp write(transcript, session_id, text, shape) do
    content =
      "<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n" <>
        "<system-reminder>\nStop hook blocking error from command \"Stop\": #{text}\n" <>
        "</system-reminder>"

    queue = &%{"type" => "queue-operation", "operation" => &1, "content" => content}
    at = %{"sessionId" => session_id, "timestamp" => DateTime.to_iso8601(DateTime.utc_now())}

    lines =
      case shape do
        :idle ->
          user = %{"role" => "user", "content" => content}
          [queue.("enqueue"), queue.("dequeue"), %{"type" => "user", "message" => user}]

        :busy ->
          attachment = %{"type" => "queued_command", "prompt" => content}

          [
            queue.("enqueue"),
            queue.("remove"),
            %{"type" => "attachment", "attachment" => attachment}
          ]

        :enqueued ->
          [queue.("enqueue")]

        :lost ->
          []
      end

    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, Enum.map(lines, &[JSON.encode!(Map.merge(&1, at)), "\n"]), [:append])
    {2, text}
  end
end
