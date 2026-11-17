defmodule CodingAgentFramework.UsageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import CodingAgentFramework.UsageSetup

  alias CodingAgentFramework.{Accounts, Usage, UsageSetup}
  alias CodingAgentFramework.Usage.{Allowance, Reading, Table}

  doctest Usage
  doctest Reading
  doctest Table
  doctest Allowance

  @windows [:used, :resets_at, :five_used, :five_resets_at]

  @now UsageSetup.now()

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
      r <= @now -> {:assumed, 0.0}
      s + max_age * 1000 <= @seen -> :unknown
      true -> {:current, u}
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
