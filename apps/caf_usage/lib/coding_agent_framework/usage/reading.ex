defmodule CodingAgentFramework.Usage.Reading do
  @moduledoc """
  One account's allowance, its weekly window and its five-hour one. Pure and total: any input
  gives a reading or a named problem, never a raise.

  Two sources give it, both Claude Code's (2.1.322):

  - `parse/1`: the JSON Claude Code hands its `statusLine` command, with
    `rate_limits.seven_day` and `rate_limits.five_hour`, each with `used_percentage` (0 to 100)
    and `resets_at` (Unix seconds), for a subscriber, after the session's first answer from the
    API, and each only while that window's reset has not passed. It must have the weekly window.
  - `windows/1`: a headless session's `rate_limit_event`, whose `unifiedWindows` has
    `five_hour` and `seven_day`, each with `utilization` (0 to 1) and `resetsAt`, measured in
    F-181 (an event of a limit names only the window it closed). Either window may be absent.

  A reading keeps each window's share used, as a float percentage, and its reset: the weekly
  one as `used` and `resets_at`, and the five-hour one as `five_used` and `five_resets_at`, nil
  where the source has none.

      iex> alias CodingAgentFramework.Usage.Reading
      iex> Reading.parse(~s({"rate_limits": {"seven_day": {"used_percentage": 41, "resets_at": 1800000000}}}))
      {:ok, %{used: 41.0, resets_at: 1800000000, five_used: nil, five_resets_at: nil}}
      iex> Reading.parse(~s({"rate_limits": {"seven_day": {"used_percentage": 41, "resets_at": 1800000000},
      ...>   "five_hour": {"used_percentage": 97.5, "resets_at": 1700003600}}}))
      {:ok, %{used: 41.0, resets_at: 1800000000, five_used: 97.5, five_resets_at: 1700003600}}
      iex> Reading.parse(~s({"rate_limits": {"five_hour": {}}}))
      {:malformed, :no_seven_day}
      iex> Reading.windows(%{"five_hour" => %{"utilization" => 0.02, "resetsAt" => 1700003600}})
      {:ok, %{five_used: 2.0, five_resets_at: 1700003600}}
  """

  @type t :: %{
          used: float | nil,
          resets_at: integer | nil,
          five_used: float | nil,
          five_resets_at: integer | nil
        }

  @doc "The status line's reading in `bytes`, or `{:malformed, reason}`."
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

  @doc """
  The windows a stream's `rate_limit_event` names in its `unifiedWindows`: a partial reading
  with only the windows it has, `{:ok, %{}}` for none, or `{:malformed, reason}`.
  """
  @spec windows(term) :: {:ok, map} | {:malformed, term}
  def windows(unified) when is_map(unified) do
    Enum.reduce_while(
      [{"seven_day", :used, :resets_at}, {"five_hour", :five_used, :five_resets_at}],
      {:ok, %{}},
      fn {key, used_key, resets_key}, {:ok, acc} ->
        case unified[key] do
          nil ->
            {:cont, {:ok, acc}}

          %{} = w ->
            with {:ok, u} <- number(w, "utilization"),
                 {:ok, r} <- number(w, "resetsAt") do
              {:cont, {:ok, Map.merge(acc, %{used_key => u * 100.0, resets_key => trunc(r)})}}
            else
              bad -> {:halt, bad}
            end

          _ ->
            {:halt, {:malformed, {:wrong_type, key}}}
        end
      end
    )
  end

  def windows(_), do: {:malformed, :no_windows}

  @doc """
  What `reading`'s weekly window says at `now` (Unix seconds): `{:assumed, 0.0}` once its reset
  has passed, since the week started anew and nothing used since is known; `{:current, used}`
  before it, however old the reading, since an idle account's share does not grow; `:unknown`
  for what is not a reading. A view shows a reading's age beside it. Pure and total.

      iex> alias CodingAgentFramework.Usage.Reading
      iex> reading = %{used: 41.0, resets_at: 2000, seen_at: 1_000_000}
      iex> Reading.status(reading, 1500)
      {:current, 41.0}
      iex> Reading.status(reading, 2500)
      {:assumed, 0.0}
      iex> Reading.status(reading, 1000 + 6 * 3600)
      {:assumed, 0.0}
      iex> Reading.status(%{reading | resets_at: 99_999}, 1000 + 6 * 3600)
      {:current, 41.0}
  """
  @spec status(term, integer) :: {:current | :assumed, float} | :unknown
  def status(%{used: used, resets_at: resets_at}, now)
      when is_number(used) and is_integer(resets_at) and is_integer(now) do
    if resets_at <= now, do: {:assumed, 0.0}, else: {:current, used / 1}
  end

  def status(_, _), do: :unknown

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
