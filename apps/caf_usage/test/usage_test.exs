defmodule CodingAgentFramework.UsageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import CodingAgentFramework.UsageSetup

  alias CodingAgentFramework.{Accounts, Usage, UsageSetup}
  alias CodingAgentFramework.Usage.{Allowance, Limit, Reading, Room, Table}

  doctest Usage
  doctest Reading
  doctest Table
  doctest Allowance
  doctest Limit
  doctest Room

  @windows [:used, :resets_at, :five_used, :five_resets_at]

  @now UsageSetup.now()

  defp window_gen do
    one_of([
      constant({nil, nil}),
      tuple({float(min: 0.0, max: 120.0), integer((@now - 10)..(@now + 10))})
    ])
  end

  defp reading_gen do
    one_of([
      map(
        {window_gen(), window_gen(), one_of([constant(nil), integer((@now - 10)..(@now + 10))])},
        fn {{u, r}, {fu, fr}, l} ->
          %{used: u, resets_at: r, five_used: fu, five_resets_at: fr, limited_until: l}
        end
      ),
      constant(nil),
      term()
    ])
  end

  # A window's room, stated apart from `Room.room/3`: the whole of it once reset or unknown.
  defp room_of(used, resets) when is_float(used) and is_integer(resets) and resets > @now,
    do: if(used >= 100.0, do: :spent, else: 100.0 - used)

  defp room_of(_, _), do: 100.0

  defp expected(%{used: u, resets_at: r, five_used: fu, five_resets_at: fr, limited_until: l}) do
    rooms = [room_of(u, r), room_of(fu, fr)]

    if :spent in rooms or (is_integer(l) and l > @now),
      do: :spent,
      else: Enum.min(rooms)
  end

  defp expected(_), do: 100.0

  property "pick answers the most room, the tighter of the two windows, never a spent one" do
    check all readings <- map(list_of({member_of(~w(a b c d)), reading_gen()}), &Map.new/1),
              among <- list_of(member_of(~w(a b c d e)), max_length: 6) do
      rooms = for a <- Enum.uniq(among), do: {a, expected(readings[a])}
      open = for {a, r} <- rooms, r != :spent, do: {a, r}

      case Usage.pick(readings, among, @now) do
        {:ok, account} ->
          {^account, room} = List.keyfind(open, account, 0)
          assert Enum.all?(open, fn {_, r} -> r <= room end)
          # The first in `among` at the same room.
          assert hd(for {a, r} <- open, r == room, do: a) == account

        {:refused, {:allowance, at}} ->
          assert open == [] and rooms != []
          assert is_integer(at) and at > @now * 1000

        {:refused, :no_account} ->
          assert among == []
      end
    end
  end

  test "an old reading stays good: only its window's reset gives the room back" do
    old = %{used: 70.0, resets_at: @now + 100, seen_at: 1}
    assert Room.room(old, @now) == {:room, 30.0}
    assert Room.room(old, @now + 100) == {:room, 100.0}
    assert Usage.pick(%{"a" => old, "b" => %{old | used: 60.0}}, ~w(a b), @now) == {:ok, "b"}
    assert Reading.status(old, @now) == {:current, 70.0}
    assert Reading.status(old, @now + 100) == {:assumed, 0.0}
  end

  test "an account able to spend credits is spent at its limit all the same" do
    limited = %{used: 1.0, resets_at: @now + 900, limited_until: @now + 60, can_spend: true}
    assert Room.room(limited, @now) == {:spent, (@now + 60) * 1000}
    assert Usage.pick(%{"a" => limited}, ["a", "b"], @now) == {:ok, "b"}
    assert Usage.pick(%{"a" => limited}, ["a"], @now + 60) == {:ok, "a"}
  end

  test "a limit record is an exact fact: a later reset replaces it, a late earlier one does not" do
    %{usage: usage, db: db} = start(~w(a b), clock: fn -> @now end)
    record = &%{"status" => "rejected", "resetsAt" => &1, "rateLimitType" => "seven_day"}
    ev = %{"source" => "transcript", "session" => "s1"}

    assert {:ok, %{ids: [{"a", _}]}} =
             Usage.take(usage, "a", %{at: @now * 1000, evidence: ev, limit: record.(@now + 600)})

    assert_receive %{topic: "usage:h:a", ids: [_]}
    {:ok, %{readings: %{"a" => a}}} = Usage.readings(usage)

    assert %{limited_until: until, limit_window: "seven_day", can_spend: false, evidence: ^ev} = a
    assert until == @now + 600
    {:ok, conn} = Allowance.open(db)
    assert Allowance.check(conn, "a", now: @now) == {:spent, (@now + 600) * 1000}

    # Read late, an earlier reset changes nothing; a later one replaces it.
    late = %{at: @now * 1000, evidence: ev, limit: record.(@now + 60)}
    assert {:ok, %{ids: []}} = Usage.take(usage, "a", late)
    later = %{at: @now * 1000, evidence: ev, limit: record.(@now + 900)}
    assert {:ok, %{ids: [_]}} = Usage.take(usage, "a", later)
    assert Allowance.check(conn, "a", now: @now) == {:spent, (@now + 900) * 1000}

    # A record that is not a rejection adds nothing; one malformed is refused.
    allowed = %{at: @now * 1000, evidence: ev, limit: %{"status" => "allowed"}}
    assert {:ok, %{ids: []}} = Usage.take(usage, "a", allowed)
    bad = %{at: @now * 1000, evidence: ev, limit: %{"status" => "rejected"}}
    assert {:refused, {:malformed, _}} = Usage.take(usage, "a", bad)
    assert {:refused, {:unknown_account, "z"}} = Usage.take(usage, "z", later)

    # A read of the files keeps the limit of an account that has no file.
    assert {:ok, _} = Usage.read(usage)
    {:ok, %{readings: %{"a" => a}}} = Usage.readings(usage)
    assert a.limited_until == @now + 900
  end

  defmodule FakeStream do
    @moduledoc "A stand-in of `Stream`'s `rows/2`: the rows an Agent holds."
    def rows(agent, _opts), do: {:ok, %{rows: Agent.get(agent, & &1)}}
  end

  test "a transcript's limit line is the account's record, once, on its account's cue" do
    alias CodingAgentFramework.Transcripts

    tdb = Path.join(CodingAgentFramework.TestHost.test_dir(), "transcripts.db")
    {:ok, conn} = Transcripts.Table.open(tdb)
    %{usage: usage} = start(~w(a b), transcripts_db: tdb, clock: fn -> @now end)

    line = fn uuid, resets ->
      JSON.encode!(%{
        "type" => "assistant",
        "uuid" => uuid,
        "timestamp" => "2026-11-21T06:48:44.124Z",
        "isApiErrorMessage" => true,
        "apiError" => "usage_limit_reached",
        "quotaLimits" => %{
          "status" => "rejected",
          "resetsAt" => resets,
          "rateLimitType" => "seven_day"
        },
        "message" => %{"id" => uuid, "stop_reason" => "stop_sequence", "content" => []}
      }) <> "\n"
    end

    put = fn bytes ->
      {:ok, fold} = Transcripts.Fold.take(Transcripts.Fold.new(), bytes)
      row = %{path: "/t/s1.jsonl", fold: fold, rewrites: 0, problem: nil}
      Transcripts.Table.write(conn, "h", [{"b", [{"s1", row}]}], @now * 1000)
      :ok = Usage.cue(usage, %{topic: "transcripts:h:b", ids: [1]})
    end

    put.(line.("l1", @now + 600))
    assert_receive %{topic: "usage:h:b", ids: [_]}
    {:ok, %{readings: %{"b" => b}}} = Usage.readings(usage)
    assert %{limited_until: until, limit_window: "seven_day"} = b
    assert until == @now + 600
    assert b.evidence == %{"source" => "transcript", "session" => "s1", "line" => "l1"}

    # The same line read again adds nothing; a later limit's line replaces it.
    put.(line.("l1", @now + 600))
    refute_receive %{topic: "usage:h:b"}, 100
    put.(line.("l1", @now + 600) <> line.("l2", @now + 900))
    assert_receive %{topic: "usage:h:b", ids: [_]}
    assert {:ok, %{readings: %{"b" => %{limited_until: later}}}} = Usage.readings(usage)
    assert later == @now + 900
  end

  test "a headless session's stream gives the windows and the limit, on its cue" do
    {:ok, rows} = Agent.start_link(fn -> [] end)
    %{accounts: accounts, usage: usage} = start(~w(a b), stream: {FakeStream, rows})
    {:ok, dir} = Accounts.config_dir(accounts, "b")
    transcript = Path.join([dir, "projects", "-work", "s1.jsonl"])

    allowed = %{
      "status" => "allowed_warning",
      "unifiedWindows" => %{
        "five_hour" => %{"utilization" => 0.02, "resetsAt" => @now + 3600, "status" => "allowed"},
        "seven_day" => %{"utilization" => 0.41, "resetsAt" => @now + 86_400}
      }
    }

    row = %{
      session: "s1",
      transcript: transcript,
      written_at: @now * 1000,
      rate_limit: allowed
    }

    Agent.update(rows, fn _ -> [row] end)
    :ok = Usage.cue(usage, %{topic: "stream:h", ids: [1]})
    assert_receive %{topic: "usage:h:b", ids: [_]}
    {:ok, %{readings: %{"b" => b}}} = Usage.readings(usage)
    assert %{used: 41.0, five_used: 2.0, source: "stream", limited_until: nil} = b

    # The measured rejection names its window and reset; the other window stays.
    rejected = %{
      "status" => "rejected",
      "resetsAt" => @now + 600,
      "rateLimitType" => "five_hour",
      "overageStatus" => "rejected",
      "unifiedWindows" => %{"five_hour" => %{"utilization" => 1, "resetsAt" => @now + 600}}
    }

    Agent.update(rows, fn _ ->
      [%{row | written_at: @now * 1000 + 5, rate_limit: rejected}]
    end)

    :ok = Usage.cue(usage, %{topic: "stream:h", ids: [1]})
    assert_receive %{topic: "usage:h:b", ids: [_]}
    {:ok, %{readings: %{"b" => b}}} = Usage.readings(usage)
    assert %{used: 41.0, five_used: 100.0, limited_until: until, can_spend: false} = b
    assert until == @now + 600
    assert b.evidence == %{"source" => "stream", "session" => "s1"}

    # A status line written before the stream's reading does not replace it.
    {:ok, path} = Accounts.usage_file(accounts, "b")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(week(5, @now + 86_400)))
    File.touch!(path, @now - 60)
    assert {:ok, _} = Usage.read(usage)

    assert {:ok, %{readings: %{"b" => %{five_used: 100.0, source: "stream"}}}} =
             Usage.readings(usage)

    # A later one does.
    File.touch!(path, @now + 60)
    assert {:ok, _} = Usage.read(usage)

    assert {:ok,
            %{readings: %{"b" => %{used: 5.0, source: "status_line", limited_until: ^until}}}} =
             Usage.readings(usage)
  end

  defp file_gen do
    one_of([
      map({float(min: 0.0, max: 100.0), integer()}, fn {u, r} -> JSON.encode!(week(u, r)) end),
      map({term(), term()}, fn {u, r} -> JSON.encode!(week(inspect(u), inspect(r))) end),
      constant(~s({"rate_limits": null})),
      constant(~s({"rate_limits": {"seven_day": {"used_percentage": 1}}})),
      constant(~s([1, 2])),
      binary(max_length: 20),
      constant(:missing)
    ])
  end

  property "each read is total over what the files hold, and keeps the last good reading" do
    check all rounds <-
                list_of(fixed_map(%{"a" => file_gen(), "b" => file_gen()}),
                  min_length: 1,
                  max_length: 4
                ),
              max_runs: 25 do
      %{accounts: accounts, usage: usage} = start(~w(a b))
      File.mkdir_p!(Path.join(accounts.home, "usage"))

      Enum.reduce(rounds, %{}, fn files, good ->
        for name <- ~w(a b) do
          {:ok, path} = Accounts.usage_file(accounts, name)

          case Map.get(files, name, :missing) do
            :missing -> File.rm(path)
            bytes -> File.write!(path, bytes)
          end
        end

        assert {:ok, _} = Usage.read(usage)
        {:ok, %{readings: readings}} = Usage.readings(usage)

        for name <- ~w(a b), into: %{} do
          bytes = Map.get(files, name, :missing)
          parsed = if bytes == :missing, do: :missing, else: Reading.parse(bytes)

          case parsed do
            :missing ->
              refute Map.has_key?(readings, name)
              {name, nil}

            {:ok, reading} ->
              assert Map.take(readings[name], [:problem | @windows]) ==
                       Map.put(reading, :problem, nil)

              {name, reading}

            {:malformed, _} ->
              assert Map.take(readings[name], @windows) ==
                       (good[name] || Map.new(@windows, &{&1, nil}))

              assert is_binary(readings[name].problem)
              {name, good[name]}
          end
        end
      end)

      GenServer.stop(usage)
    end
  end

  test "the five-hour window is stored beside the weekly one, and gates a start" do
    %{accounts: accounts, usage: usage, db: db} = start(~w(a b))
    File.mkdir_p!(Path.join(accounts.home, "usage"))
    week = ~s("seven_day": {"used_percentage": 10, "resets_at": #{@now + 900}})
    five = ~s("five_hour": {"used_percentage": 100, "resets_at": #{@now + 60}})

    for {name, limits} <- [{"a", week <> "," <> five}, {"b", week}] do
      {:ok, path} = Accounts.usage_file(accounts, name)
      File.write!(path, ~s({"rate_limits": {#{limits}}}))
    end

    assert {:ok, _} = Usage.read(usage)
    {:ok, %{readings: %{"a" => a}}} = Usage.readings(usage)
    assert %{five_used: 100.0, five_resets_at: reset} = a
    {:ok, conn} = Allowance.open(db)
    assert Allowance.check(conn, "a", now: @now) == {:spent, reset * 1000}
    assert Allowance.check(conn, "b", now: @now) == :room
    assert Allowance.check(conn, "none", now: @now) == :room
  end
end
