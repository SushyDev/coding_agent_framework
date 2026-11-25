defmodule CodingAgentFramework.Tracker.BackgroundTest do
  @moduledoc """
  An agent's background commands in the tree (F-259), on a real tmux server and real dtach
  sockets in this test's own directory, with stand-ins for Claude Code: a headless delegate's
  from its `Stream` fold, and an interactive session's from the `Stop` rows `Intake` keeps and
  the session file `Registry` reads. Each writer's cue is handed to the `Tracker` as `Cues`
  would hand it.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.SessionsSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Holder, Intake, IntakeSetup, Registry, Sessions, Stream, Tracker}
  alias CodingAgentFramework.StuckBackgrounds.Groups
  alias CodingAgentFramework.Tracker.{Background, TableSource}

  doctest Background

  setup {CodingAgentFramework.SessionsSetup, :sessions}

  setup ctx do
    intake_db = Path.join(ctx.dir, "intake.db")
    db = ctx.opts[:db]

    sources = [
      {TableSource, table: Sessions.Table, db: db, host: "test"},
      {TableSource, table: Stream.Table, db: db, host: "test"},
      {TableSource, table: Registry.Table, db: db, host: "test", account: "work"},
      {TableSource, table: Intake.Table, db: intake_db, host: "test", account: "work"}
    ]

    tracker = start_supervised!({Tracker, sources: sources, timer: false})
    notify = &Tracker.cue(tracker, &1)
    intake = start_supervised!({Intake, db: intake_db, host: "test", notify: notify})
    {:ok, tracker: tracker, intake: intake}
  end

  # A `Stop` input of Claude Code 2.1.322's shape, listing `ids` as running shell commands.
  defp stop(ctx, session, ids, said) do
    tasks =
      for id <- ids,
          do: %{
            id: id,
            type: "shell",
            status: "running",
            description: "wait",
            command: "sleep 30"
          }

    body =
      JSON.encode!(%{
        hook_event_name: "Stop",
        session_id: session,
        stop_hook_active: false,
        last_assistant_message: said,
        background_tasks: tasks,
        session_crons: []
      })

    assert %{status: 200} = IntakeSetup.post(ctx.intake, body)
  end

  # The agent rows' cue, as `Sessions` gives it after a start, is handed on before each read.
  defp agent(ctx, name, opts \\ []) do
    Tracker.cue(ctx.tracker, %{topic: "sessions:test"})
    {:ok, %{agents: agents}} = Tracker.agents(ctx.tracker, opts)
    Enum.find(agents, &(&1.name == name))
  end

  # The session file is what the stand-in writes: read it as `Registry` does, hand its cue on,
  # and read the tree, until `ok?` holds.
  defp file_until(ctx, name, ok?) do
    await(
      fn ->
        {:ok, _} = Registry.read(ctx.registry)
        Tracker.cue(ctx.tracker, %{topic: "registry:test:work"})
        a = agent(ctx, name)
        if a && ok?.(a), do: {:ok, a}, else: {:not_yet, a}
      end,
      10_000
    )
    |> case do
      {:ok, a} -> a
      other -> flunk("the tree never read it so: #{inspect(other)}")
    end
  end

  defp streamed(ctx, id, ok?) do
    stream_until(ctx, id, ok?)
    Tracker.cue(ctx.tracker, %{topic: "stream:test"})
    agent(ctx, ctx.delegate)
  end

  test "an interactive session's command runs after its turn, ends between turns, and a stale Stop is emptied",
       ctx do
    {:ok, %{session_id: sid}} =
      Sessions.start(ctx.sessions, "main", ctx.account, launch(ctx, :at_start))

    # Before any Stop, an idle file says none; a turn with no Stop kept cannot say.
    assert %{background: %{count: 0, source: "session_file"}} =
             file_until(ctx, "main", &(&1.state == "idle"))

    type(ctx, "main", "busy")

    assert %{background: {:unknown, :no_stop}} =
             file_until(ctx, "main", &(&1.state == "working"))

    # The turn ends with a command running: its Stop lists it, then the file says `shell`.
    stop(ctx, sid, ["b1"], "started it")

    assert %{background: %{count: 1, source: "stop", since: since}} = agent(ctx, "main")
    assert is_integer(since)
    type(ctx, "main", "shell")

    assert %{background: %{count: 1, source: "session_file", since: ^since}} =
             file_until(ctx, "main", &match?(%{source: "session_file"}, &1.background))

    # It ends between turns: no hook fires, and the file's `idle` empties the Stop's list.
    type(ctx, "main", "idle")

    assert %{state: "idle", background: %{count: 0, source: "session_file"}} =
             file_until(ctx, "main", &match?(%{count: 0}, &1.background))

    # A later turn's Stop still lists the ended command, as the release does: the tree shows it
    # until the file read after that Stop says idle.
    type(ctx, "main", "busy")
    file_until(ctx, "main", &(&1.state == "working"))
    stop(ctx, sid, ["b1"], "done")
    assert %{background: %{count: 1, source: "stop"}} = agent(ctx, "main")
    type(ctx, "main", "idle")

    assert %{background: %{count: 0, source: "session_file"}} =
             file_until(ctx, "main", &match?(%{count: 0}, &1.background))
  end

  test "a headless delegate's command runs after its turn, ends between turns, and the groups read",
       ctx do
    fifo = Path.join(ctx.dir, "bg.fifo")
    {_, 0} = System.cmd(program!(:mkfifo), [fifo])
    {:ok, _} = Sessions.start(ctx.sessions, "main", ctx.account, launch(ctx, :at_start))
    launch = headless(ctx, :on_message) ++ [project: "app"]
    {:ok, %{session_id: sid}} = Sessions.start(ctx.sessions, "app-bg", ctx.account, launch)
    ctx = Map.put(ctx, :delegate, "app-bg")
    turn_ended(ctx, sid)

    assert %{background: %{count: 0, source: "stream"}} =
             streamed(ctx, sid, &(&1.tasks == %{}))

    {:ok, _} = Stream.write(ctx.stream, sid, {:message, "bg go"})

    # Its turn's result came while the command runs: busy, with one command since a read.
    assert %{state: "working", background: %{count: 1, source: "stream", since: since}} =
             streamed(ctx, sid, &(&1.idle and &1.tasks != %{}))

    assert is_integer(since)

    # The host's read of its process groups is shown beside the count; macOS cannot read them.
    {:ok, procs} = Holder.Process.new(programs(), ctx.holder)
    read = &Groups.read(procs, &1)
    %{background: %{groups: groups}} = agent(ctx, "app-bg", groups: %{"test" => read})

    case :os.type() do
      {:unix, :darwin} -> assert groups == {:unknown, :no_proc}
      _ -> assert is_integer(groups)
    end

    # The command ends between turns: the fold empties it before the turn of its own begins.
    File.write!(fifo, "end\n")

    assert %{background: %{count: 0, source: "stream", since: nil}} =
             streamed(ctx, sid, &(&1.tasks == %{}))
  end
end
