defmodule CodingAgentFramework.StreamTest do
  @moduledoc """
  `Stream` against a stand-in for headless Claude Code (`CodingAgentFramework.HeadlessStandIn`),
  held by real dtach through `ClaudeCLI`'s wrapper, in this test's own directory. Each test
  waits on what the stand-in writes to its log, read through `Stream.read/2`.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{ClaudeCLI, HeadlessStandIn, Holder, Stream}
  alias CodingAgentFramework.Accounts.Account
  alias CodingAgentFramework.Stream.{Fold, Line, Table}

  doctest Stream
  doctest Line
  doctest Fold
  doctest Table

  setup do
    dir = test_dir()
    {:ok, holder} = Holder.new(programs(), dir)
    stand_in = HeadlessStandIn.write!(dir)
    on_exit(fn -> HeadlessStandIn.kill_all(dir) end)
    ctx = %{dir: dir, holder: holder, stand_in: stand_in, db: Path.join(dir, "s.db")}
    {:ok, Map.put(ctx, :stream, start!(ctx))}
  end

  test "a message written after a result is replayed and settled", ctx do
    s = hold!(ctx, "d1")
    assert %{session_id: "d1", idle: true} = row!(ctx, s, &(&1.session_id == "d1"))

    {:ok, %{uuid: u1}} = Stream.write(s, "d1", {:message, "first"})
    assert {:refused, :turn_running} = Stream.write(s, "d1", {:message, "early"})
    assert %{idle: true} = row!(ctx, s, &(&1.messages[u1].state == :delivered and &1.idle))

    {:ok, %{uuid: u2}} = Stream.write(s, "d1", {:message, "second"})

    assert %{last_result: %{user_message_uuids: [^u2]}} =
             row!(ctx, s, &(&1.messages[u2].state == :delivered and &1.idle))

    assert %{rate_limit: %{"status" => "allowed"}} = row!(ctx, s, & &1.idle)
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u1}", "message #{u2}"]
  end

  test "a write while no delegate reads is refused within its deadline", ctx do
    {:ok, _} = Stream.follow(ctx.stream, "d2", "d2", "/none")
    started = System.monotonic_time(:millisecond)

    assert {:refused, {:not_live, :absent}} =
             Stream.write(ctx.stream, "d2", {:message, "hi"}, timeout: 2_000)

    assert System.monotonic_time(:millisecond) - started < 2_000

    s = hold!(ctx, "d3")
    assert {:ok, _} = Stream.end_session(s, "d3")
    # Once an end is marked, a message is refused, before its exit is seen (new-5).
    assert {:refused, :ending} = Stream.write(s, "d3", {:message, "after the end"})
    assert %{gone: true} = row!(ctx, s, & &1.gone)
    assert {:refused, :gone} = Stream.write(s, "d3", {:message, "late"})
    assert HeadlessStandIn.taken(ctx.dir) == ["end"]
  end

  test "a restart after the claim, or after the mark, settles once from the log", ctx do
    s = hold!(ctx, "d4")
    {:ok, %{uuid: u1}} = Stream.write(s, "d4", {:message, "before the restart"})
    :ok = GenServer.stop(s)
    s = start!(ctx)
    row!(ctx, s, &(&1.messages[u1].state == :delivered and &1.idle))

    # A Stream that died between Mark and Claim left this row; the next run claims it.
    :ok = GenServer.stop(s)
    {:ok, db} = Table.open(ctx.db)
    %{"d4" => d} = Table.delegates(db, "test")
    {:ok, line} = Line.encode({:message, "u-marked", "marked only"})

    Table.write(
      db,
      "test",
      [{"d4", %{d | fold: Fold.mark(d.fold, {:message, "u-marked", ""}, line, 0)}}],
      nil
    )

    s = start!(ctx)
    row!(ctx, s, &(&1.messages["u-marked"].state == :delivered and &1.lines == %{}))

    :ok = GenServer.stop(s)
    s = start!(ctx)
    row!(ctx, s, & &1.idle)
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u1}", "message u-marked"]
  end

  test "a permission request is answered once, by its id; an interrupt cancels one", ctx do
    s = hold!(ctx, "d5")
    {:ok, %{uuid: u}} = Stream.write(s, "d5", {:message, "ask once"})
    req = "req-" <> u

    assert %{tool_name: "Bash", state: :held} =
             row!(ctx, s, &(&1.requests[req] != nil)).requests[req]

    assert {:refused, :no_request} = Stream.write(s, "d5", {:answer, "req-other", :allow})
    assert {:ok, _} = Stream.write(s, "d5", {:answer, req, {:deny, "no"}})
    assert {:refused, {:request, :answering}} = Stream.write(s, "d5", {:answer, req, :allow})
    row!(ctx, s, &(&1.requests[req].state == :answered and &1.idle))
    assert {:refused, {:request, :answered}} = Stream.write(s, "d5", {:answer, req, :allow})

    {:ok, %{uuid: u2}} = Stream.write(s, "d5", {:message, "ask again"})
    row!(ctx, s, &(&1.requests["req-" <> u2] != nil))
    assert {:ok, _} = Stream.interrupt(s, "d5")
    row!(ctx, s, &(&1.requests["req-" <> u2].state == :canceled and &1.idle))

    assert HeadlessStandIn.taken(ctx.dir) == [
             "message #{u}",
             "answer #{req}",
             "message #{u2}",
             "interrupt"
           ]
  end

  test "a partial last line is read only once whole", ctx do
    s = hold!(ctx, "d6")
    {:ok, %{uuid: u}} = Stream.write(s, "d6", {:message, "half a line"})
    row = row!(ctx, s, &(&1.messages[u].state == :delivered and &1.idle))
    log = File.read!(Path.join([ctx.dir, "streams", "d6", "events.jsonl"]))

    assert row.offset < byte_size(log) and
             binary_part(log, row.offset, byte_size(log) - row.offset) =~ ~r/\A[^\n]+\z/

    {:ok, %{uuid: u2}} = Stream.write(s, "d6", {:message, "next"})
    after_ = row!(ctx, s, &(&1.messages[u2].state == :delivered and &1.idle))
    # The finished line, the replay, assistant, rate limit and result: each once, none broken.
    assert {after_.events - row.events, after_.problems} == {5, 0}
  end

  test "a message found undelivered goes again, first, to the resumed process's own FIFO",
       ctx do
    # A process that never reads its stdin: the line waits in its pipe and dies with it, during
    # the turn the write started (new-6).
    deaf = %{stand_in(ctx, session_id: "r1") | argv: [program!(:sleep), "600"]}
    s = hold!(ctx, "r1", deaf)
    {:ok, %{uuid: u}} = Stream.write(s, "r1", {:message, "lost"})
    kill_held!(ctx, "r1")
    assert %{idle: false} = gone = row!(ctx, s, &(&1.session == "r1" and &1.gone))
    assert gone.messages[u].state == :undelivered

    # A claim command left waiting at the exit, on the old FIFO (new-1).
    in0 = Path.join([ctx.dir, "streams", "r1", "in.0"])
    {:ok, stale} = Line.encode({:message, "stale", "from before the exit"})
    on_exit(fn -> System.cmd(program!(:sh), ["-c", ~S(exec 3<>"$1"), "sh", in0]) end)

    waiting =
      Task.async(fn ->
        System.cmd(program!(:sh), ["-c", ~S(printf '%s' "$1" > "$2"), "sh", stale, in0])
      end)

    hold!(ctx, "r1", stand_in(ctx, resume: "r1"))
    assert File.exists?(Path.join([ctx.dir, "streams", "r1", "in.1"]))

    # The undelivered one goes first, under its own uuid; an end waits for it (new-5).
    assert {:refused, {:undelivered, ^u}} = Stream.write(s, "r1", {:message, "other"})
    assert {:refused, {:undelivered, ^u}} = Stream.end_session(s, "r1")
    assert {:ok, %{uuid: ^u}} = Stream.write(s, "r1", {:message, u, "lost"})
    row!(ctx, s, &(&1.session == "r1" and &1.messages[u].state == :delivered and &1.idle))

    # The resumed process took the resend once, and nothing from the old FIFO (new-4: the
    # stand-in has no drop of a known uuid, and none is needed).
    assert HeadlessStandIn.taken(ctx.dir) == ["message #{u}"]
    assert Task.yield(waiting, 0) == nil
    assert {^stale, 0} = System.cmd(program!(:cat), [in0])
    assert {"", 0} = Task.await(waiting)
  end

  test "a follow again ends the line a death cut, so the resumed process's init is read",
       ctx do
    s = hold!(ctx, "c1")
    {:ok, %{uuid: u}} = Stream.write(s, "c1", {:message, "half a line"})
    row!(ctx, s, &(&1.session == "c1" and &1.messages[u].state == :delivered and &1.idle))
    {:ok, _} = Stream.end_session(s, "c1")
    row!(ctx, s, &(&1.session == "c1" and &1.gone))
    log = Path.join([ctx.dir, "streams", "c1", "events.jsonl"])
    refute File.read!(log) |> String.ends_with?("\n")

    hold!(ctx, "c1", stand_in(ctx, resume: "c1"))
    resumed = row!(ctx, s, &(&1.session == "c1" and &1.session_id == "c1"))
    assert resumed.problems == 1
  end

  test "a process that exits before a read sees it live is seen gone once its hold is told",
       ctx do
    {:ok, %{dir: dir, fifo: fifo}} = Stream.follow(ctx.stream, "e1", "e1", "/none")
    argv = ClaudeCLI.wrapper(program!(:sh), dir, fifo, [program!(true)])
    {:ok, _} = Holder.hold(ctx.holder, "e1", argv, env: [])
    {:ok, :absent} = await(fn -> absent(Holder.state(ctx.holder, "e1")) end)

    {:ok, _} = Stream.read(ctx.stream)
    assert %{gone: false, live_seen: false} = row!(ctx, ctx.stream, &(&1.session == "e1"))
    assert {:ok, :seen} = Stream.held(ctx.stream, "e1")
    row!(ctx, ctx.stream, &(&1.session == "e1" and &1.gone))
    assert {:refused, :gone} = Stream.held(ctx.stream, "e1")
  end

  defp start!(ctx) do
    {:ok, s} =
      Stream.start_link(programs: programs(), holder: ctx.holder, home: ctx.dir, db: ctx.db)

    s
  end

  # The stand-in's argv and environment for a start (`session_id:`) or a resume (`resume:`).
  defp stand_in(ctx, start) do
    account = Account.at("work", Path.join(ctx.dir, "claude"))
    env = %{home: ctx.dir, path: "/nowhere", term: "dumb", lang: "C.UTF-8"}

    {:ok, launch} =
      ClaudeCLI.headless(account, [claude: ctx.stand_in, model: "m", env: env] ++ start)

    launch
  end

  # Follows `session`, holds `launch` (the stand-in's start by default) through the wrapper on
  # the FIFO the follow answered, and waits for a read to see it live.
  defp hold!(ctx, session, launch \\ nil) do
    s = ctx.stream
    %{argv: argv, env: env} = launch || stand_in(ctx, session_id: session)
    transcript = Path.join(ctx.dir, "#{session}.jsonl")
    {:ok, %{dir: dir, fifo: fifo}} = Stream.follow(s, session, session, transcript)
    argv = ClaudeCLI.wrapper(program!(:sh), dir, fifo, argv)
    {:ok, _} = Holder.hold(ctx.holder, session, argv, env: env)
    row!(ctx, s, &(&1.session == session and &1.live_seen))
    s
  end

  # Ends the process the wrapper recorded for `session`, by its pid, and waits for its socket.
  defp kill_held!(ctx, session) do
    pid = File.read!(Path.join([ctx.dir, "streams", session, "pid"])) |> String.trim()
    kill(pid)
    {:ok, :absent} = await(fn -> absent(Holder.state(ctx.holder, session)) end, 10_000)
  end

  defp absent({:ok, :absent}), do: {:ok, :absent}
  defp absent(other), do: {:not_yet, other}

  # Reads until a row satisfies `ok?`, and answers it.
  defp row!(_ctx, s, ok?) do
    {:ok, row} =
      await(fn ->
        {:ok, _} = Stream.read(s)
        {:ok, %{rows: rows}} = Stream.rows(s)

        case Enum.find(rows, &safe(ok?, &1)) do
          nil -> {:waiting, rows}
          row -> {:ok, row}
        end
      end)

    row
  end

  defp safe(ok?, row) do
    ok?.(row) == true
  rescue
    _ -> false
  end
end
