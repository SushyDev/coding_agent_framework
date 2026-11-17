defmodule CodingAgentFramework.Usage.Reading do
  @moduledoc """
  One account's allowance, its weekly window and its five-hour one, read from the JSON Claude
  Code hands its `statusLine` command. Pure and total: any bytes give a reading or a named
  problem, never a raise.

  In Claude Code 2.1.322 that JSON has `rate_limits.seven_day` and `rate_limits.five_hour`,
  each with `used_percentage` (0 to 100) and `resets_at` (Unix seconds), for a subscriber,
  after the session's first answer from the API, and each only while that window's reset has
  not passed. A reading keeps each window's share used, as a float, and its reset: the weekly
  one as `used` and `resets_at`, which it must have, and the five-hour one as `five_used` and
  `five_resets_at`, nil when the JSON has none.

      iex> alias CodingAgentFramework.Usage.Reading
      iex> Reading.parse(~s({"rate_limits": {"seven_day": {"used_percentage": 41, "resets_at": 1800000000}}}))
      {:ok, %{used: 41.0, resets_at: 1800000000, five_used: nil, five_resets_at: nil}}
      iex> Reading.parse(~s({"rate_limits": {"seven_day": {"used_percentage": 41, "resets_at": 1800000000},
      ...>   "five_hour": {"used_percentage": 97.5, "resets_at": 1700003600}}}))
      {:ok, %{used: 41.0, resets_at: 1800000000, five_used: 97.5, five_resets_at: 1700003600}}
      iex> Reading.parse(~s({"rate_limits": {"five_hour": {}}}))
      {:malformed, :no_seven_day}
  """

  @type t :: %{
          used: float,
          resets_at: integer,
          five_used: float | nil,
          five_resets_at: integer | nil
        }

  @doc "The reading in `bytes`, or `{:malformed, reason}`."
  @spec parse(binary) :: {:ok, t} | {:malformed, term}
  def parse(bytes) when is_binary(bytes) do
    with {:ok, json} <- decode(bytes),
         %{"rate_limits" => %{"seven_day" => week}} when is_map(week) <- json,
         {:ok, used} <- number(week, "used_percentage"),
         {:ok, resets_at} <- number(week, "resets_at"),
         {:ok, five} <- five_hour(json["rate_limits"]["five_hour"]) do
      {:ok, Map.merge(%{used: used / 1, resets_at: trunc(resets_at)}, five)}
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

  - `{:assumed, 0.0}`: its window has reset, so the week started anew and nothing used since is
    known. The reset wins over the age: an idle account's reading is always old, and it is the
    account this rule exists for;
  - `{:current, used}`: its window has not reset and it was written within `max_age`;
  - `:unknown`: its window has not reset but it is older than `max_age`, or it is not a
    reading.

  Pure and total. A reading from the future counts as just written.

      iex> alias CodingAgentFramework.Usage.Reading
      iex> reading = %{used: 41.0, resets_at: 2000, seen_at: 1_000_000}
      iex> Reading.status(reading, 1500)
      {:current, 41.0}
      iex> Reading.status(reading, 2500)
      {:assumed, 0.0}
      iex> Reading.status(reading, 1000 + 6 * 3600)
      {:assumed, 0.0}
      iex> Reading.status(%{reading | resets_at: 99_999}, 1000 + 6 * 3600)
      :unknown
  """
  @spec status(term, integer, integer) :: {:current | :assumed, float} | :unknown
  def status(reading, now, max_age \\ @max_age)

  def status(%{used: used, resets_at: resets_at, seen_at: seen_at}, now, max_age)
      when is_number(used) and is_integer(resets_at) and is_integer(seen_at) and is_integer(now) and
             is_integer(max_age) do
    cond do
      resets_at <= now -> {:assumed, 0.0}
      seen_at + max_age * 1000 <= now * 1000 -> :unknown
      true -> {:current, used / 1}
    end
  end

  def status(_, _, _), do: :unknown

  # The five-hour window is absent once its reset passed; one that is there must be whole.
  defp five_hour(nil), do: {:ok, %{five_used: nil, five_resets_at: nil}}

  defp five_hour(%{} = five) do
    with {:ok, used} <- number(five, "used_percentage"),
         {:ok, resets_at} <- number(five, "resets_at"),
         do: {:ok, %{five_used: used / 1, five_resets_at: trunc(resets_at)}}
  end

  defp five_hour(_), do: {:malformed, {:wrong_type, "five_hour"}}

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
