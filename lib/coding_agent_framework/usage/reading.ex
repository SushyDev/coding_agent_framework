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
      iex> Reading.current?(%{used: 41.0, resets_at: 1800000000}, 1700000000)
      true
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

  @doc """
  Whether `reading` is a reading whose window has not reset at `now` (Unix seconds). After the
  reset, what was used since is not known, so the reading no longer says how much is left.
  """
  @spec current?(term, integer) :: boolean
  def current?(%{used: used, resets_at: resets_at}, now)
      when is_number(used) and is_integer(resets_at) and is_integer(now),
      do: resets_at > now

  def current?(_, _), do: false

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
