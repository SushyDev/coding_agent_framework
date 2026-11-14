defmodule CodingAgentFramework.UsageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Usage}
  alias CodingAgentFramework.Tracker.UsageSource
  alias CodingAgentFramework.Usage.{Reading, Table}

  doctest Usage
  doctest Reading
  doctest Table

  @now 1_800_000_000

  defp week(used, resets_at),
    do: %{
      "rate_limits" => %{"seven_day" => %{"used_percentage" => used, "resets_at" => resets_at}}
    }

  defp start(names) do
    # A quote in the home's path shows the status line command quotes its words.
    {:ok, accounts} = Accounts.new(Path.join(test_dir(), "caf o'home"), names)
    me = self()
    db = Path.join(test_dir(), "usage.db")
    {:ok, usage} = Usage.start_link(accounts: accounts, host: "h", db: db, notify: &send(me, &1))
    %{accounts: accounts, usage: usage, db: db}
  end

  test "the status line command keeps a text with the weekly window, and Usage reads it" do
    %{accounts: accounts, usage: usage, db: db} = start(["work"])
    {:ok, account} = Accounts.prepare(accounts, "work", %{programs: programs()})

    for role <- [:parent, :delegate] do
      %{"statusLine" => %{"type" => "command", "command" => command}} =
        JSON.decode!(File.read!(account.settings[role]))

      assert command =~ "statusline.sh"
    end

    %{"statusLine" => %{"command" => command}} =
      JSON.decode!(File.read!(account.settings.parent))

    # Claude Code runs the command through a shell with the JSON on its input.
    run = fn json ->
      input = Path.join(test_dir(), "input.json")
      File.write!(input, JSON.encode!(json))
      assert {"", 0} = System.cmd(program!(:sh), ["-c", command <> " < '#{input}'"])
    end

    assert Usage.readings(usage) == :unread
    run.(Map.merge(week(41.5, @now), %{"session_id" => "s1", "model" => %{"id" => "m"}}))
    assert {:ok, %{readings: 1, problems: 0, ids: [{"work", id}]}} = Usage.read(usage)
    assert_received %{topic: "usage:h:work", ids: [^id]}

    {:ok, %{readings: %{"work" => reading}}} = Usage.readings(usage)
    assert %{used: 41.5, resets_at: @now, problem: nil, seen_at: seen} = reading
    assert is_integer(seen) and seen <= System.os_time(:millisecond)
    assert Usage.pick(%{"work" => reading}, ["work"], div(seen, 1000)) == {:ok, "work"}

    # A text before the first answer from the API has no weekly window: the reading stays.
    run.(%{"session_id" => "s2", "rate_limits" => %{"five_hour" => %{"used_percentage" => 3}}})
    assert {:ok, %{ids: []}} = Usage.read(usage)
    refute_received %{topic: _}

    # A half-written file keeps the last good reading and names the problem.
    {:ok, file} = Accounts.usage_file(accounts, "work")
    File.write!(file, ~s({"rate_limits": {"seven))
    assert {:ok, %{problems: 1}} = Usage.read(usage)
    {:ok, %{readings: %{"work" => kept}}} = Usage.readings(usage)
    assert %{kept | problem: nil} == reading and kept.problem == ":not_json"

    {:ok, source} = UsageSource.open(db: db, account: "work", clock: fn -> div(seen, 1000) end)

    assert {:ok, %{rows: [%{account: "work", used: 41.5, assumed: false}]}} =
             UsageSource.read(source, :all)

    # Once its reset has passed, the source marks the reading assumed.
    File.write!(file, JSON.encode!(week(41.5, 1)))
    assert {:ok, %{ids: [_]}} = Usage.read(usage)
    assert {:ok, %{rows: [%{assumed: true}]}} = UsageSource.read(source, :all)
    assert {:ok, %{rows: []}} = UsageSource.read(source, [id + 1])
  end

  @seen 1_000 * @now

  defp reading_gen do
    one_of([
      fixed_map(%{
        used: float(min: 0.0, max: 100.0),
        resets_at: integer((@now - 10)..(@now + 10)),
        # Written between 7 hours before and a minute after `@now`, in ms.
        seen_at: integer((@seen - 7 * 3_600_000)..(@seen + 60_000))
      }),
      fixed_map(%{used: constant(nil), resets_at: constant(nil), seen_at: constant(nil)}),
      map_of(atom(:alphanumeric), term(), max_length: 2),
      term()
    ])
  end

  # What `pick` should see, stated apart from `Reading.status/3`.
  defp expected(%{used: u, resets_at: r, seen_at: s}, max_age)
       when is_float(u) and is_integer(r) and is_integer(s) do
    cond do
      s + max_age * 1000 <= @seen -> :unknown
      r > @now -> {:current, u}
      true -> {:assumed, 0.0}
    end
  end

  defp expected(_, _), do: :unknown

  property "pick answers the most left among current and assumed readings, current first" do
    check all readings <- map(list_of({member_of(~w(a b c d)), reading_gen()}), &Map.new/1),
              among <- list_of(one_of([member_of(~w(a b c d e)), term()]), max_length: 6),
              max_age <- one_of([constant(Reading.max_age()), integer(0..30_000)]) do
      known =
        for a <- Enum.uniq(among),
            {kind, used} <- [expected(readings[a], max_age)],
            do: {a, kind, used}

      case Usage.pick(readings, among, @now, max_age) do
        {:refused, :none_known} ->
          assert known == []

        {:ok, account} ->
          {^account, kind, used} = List.keyfind(known, account, 0)
          assert Enum.all?(known, fn {_, _, u} -> u >= used end)
          # An assumed pick means no current reading has that share.
          assert kind == :current or
                   Enum.all?(known, fn {_, k, u} -> k == :assumed or u > used end)
      end
    end
  end

  test "the age bound is 6 hours by default, and the caller may pass another" do
    fresh = %{used: 50.0, resets_at: @now + 100, seen_at: @seen - 6 * 3_600_000 + 1_000}
    stale = %{fresh | seen_at: @seen - 6 * 3_600_000}
    assert Usage.pick(%{"a" => fresh}, ["a"], @now) == {:ok, "a"}
    assert Usage.pick(%{"a" => stale}, ["a"], @now) == {:refused, :none_known}
    assert Usage.pick(%{"a" => stale}, ["a"], @now, 7 * 3600) == {:ok, "a"}
    assert Reading.status(%{stale | seen_at: nil}, @now) == :unknown
  end

  test "an assumed reading counts as 0 used, and a current one wins the same share" do
    reset = %{used: 90.0, resets_at: @now - 1, seen_at: @seen - 1_000}
    zero = %{used: 0.0, resets_at: @now + 5, seen_at: @seen}
    assert Reading.status(reset, @now) == {:assumed, 0.0}
    assert Usage.pick(%{"a" => reset, "b" => %{zero | used: 10.0}}, ~w(a b), @now) == {:ok, "a"}
    assert Usage.pick(%{"a" => reset, "b" => zero}, ~w(a b), @now) == {:ok, "b"}
    assert Usage.pick(%{"a" => zero, "b" => reset}, ~w(b a), @now) == {:ok, "a"}
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
              assert Map.take(readings[name], [:used, :resets_at, :problem]) ==
                       Map.put(reading, :problem, nil)

              {name, reading}

            {:malformed, _} ->
              assert Map.take(readings[name], [:used, :resets_at]) ==
                       (good[name] || %{used: nil, resets_at: nil})

              assert is_binary(readings[name].problem)
              {name, good[name]}
          end
        end
      end)

      GenServer.stop(usage)
    end
  end
end
