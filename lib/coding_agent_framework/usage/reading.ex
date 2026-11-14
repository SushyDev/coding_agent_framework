defmodule CodingAgentFramework.Usage.Reading do
  @moduledoc """
  One account's weekly allowance, read from the JSON Claude Code hands its `statusLine` command.
  Pure and total: any bytes give a reading or a named problem, never a raise.

  In Claude Code 2.1.322 that JSON has `rate_limits.seven_day` with `used_percentage` (0 to
  100) and `resets_at` (Unix seconds), for a subscriber, after the session's first answer from
  the API, and only while that window's reset has not passed. A reading keeps the share used,
  as a float, and the reset.

      iex> alias CodingAgentFramework.Usage.Reading
      iex> Reading.parse(~s({"rate_limits": {"seven_day": {"used_percentage": 41, "resets_at": 1800000000}}}))
      {:ok, %{used: 41.0, resets_at: 1800000000}}
      iex> Reading.parse(~s({"rate_limits": {"five_hour": {}}}))
      {:malformed, :no_seven_day}
  """

  @type t :: %{used: float, resets_at: integer}

  @doc "The reading in `bytes`, or `{:malformed, reason}`."
  @spec parse(binary) :: {:ok, t} | {:malformed, term}
  def parse(bytes) when is_binary(bytes) do
    with {:ok, json} <- decode(bytes),
         %{"rate_limits" => %{"seven_day" => week}} when is_map(week) <- json,
         {:ok, used} <- number(week, "used_percentage"),
         {:ok, resets_at} <- number(week, "resets_at") do
      {:ok, %{used: used / 1, resets_at: trunc(resets_at)}}
    else
      {:malformed, _} = bad -> bad
      _ -> {:malformed, :no_seven_day}
    end
  end

  def parse(_), do: {:malformed, :not_text}

  @max_age 6 * 60 * 60

  @doc "How long a reading is current, in seconds: 6 hours."
  @spec max_age() :: pos_integer
  def max_age, do: @max_age

  @doc """
  What `reading` says at `now` (Unix seconds), for a reading kept `max_age` seconds (default 6
  hours) from its `seen_at` (ms):

  - `{:current, used}`: written within `max_age` and its window has not reset;
  - `{:assumed, 0.0}`: written within `max_age`, but its window has reset, so the week started
    anew and nothing used since is known;
  - `:unknown`: older than `max_age`, without a `seen_at`, or not a reading.

  Pure and total. A reading from the future counts as just written.

      iex> alias CodingAgentFramework.Usage.Reading
      iex> reading = %{used: 41.0, resets_at: 2000, seen_at: 1_000_000}
      iex> Reading.status(reading, 1500)
      {:current, 41.0}
      iex> Reading.status(reading, 2500)
      {:assumed, 0.0}
      iex> Reading.status(reading, 1000 + 6 * 3600)
      :unknown
  """
  @spec status(term, integer, integer) :: {:current | :assumed, float} | :unknown
  def status(reading, now, max_age \\ @max_age)

  def status(%{used: used, resets_at: resets_at, seen_at: seen_at}, now, max_age)
      when is_number(used) and is_integer(resets_at) and is_integer(seen_at) and is_integer(now) and
             is_integer(max_age) do
    cond do
      seen_at + max_age * 1000 <= now * 1000 -> :unknown
      resets_at > now -> {:current, used / 1}
      true -> {:assumed, 0.0}
    end
  end

  def status(_, _, _), do: :unknown

  defp decode(bytes) do
    case JSON.decode(bytes) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:malformed, :not_json}
    end
  end

  defp number(map, key) do
    case map do
      %{^key => n} when is_number(n) -> {:ok, n}
      %{^key => _} -> {:malformed, {:wrong_type, key}}
      _ -> {:malformed, {:missing, key}}
    end
  end
end
