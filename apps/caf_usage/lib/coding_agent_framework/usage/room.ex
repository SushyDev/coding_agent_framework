defmodule CodingAgentFramework.Usage.Room do
  @moduledoc """
  An account's room, one rule for the `Scheduler`'s gate and for every pick of an account
  (`Mains`, `Delegates`, the `Mover`; F-181, decided by the operator). Pure and total.

  Each of the two windows, the five-hour one and the weekly one, has room `100 - used`
  (percent), or the whole 100 once its reset has passed or when the reading lacks it: a window
  past its `resets_at` is reset, with no session needed to say so, so an idle account is never
  dropped as stale. An account's room is the tighter of its two windows (`min`). An account with
  no reading has the whole room: nothing on it has run.

  It is spent while either window is at or above `full_at` (percent, default 100) before its
  reset, or while its limit record (`limited_until`, `CodingAgentFramework.Usage.Limit`) is in
  force: the record is exact where the status line's numbers may be old. A spent account answers
  `{:spent, retry_at}`, `retry_at` in ms the latest of those resets. An account able to spend
  usage credits is spent all the same: credits are never counted as room.

      iex> alias CodingAgentFramework.Usage.Room
      iex> Room.room(%{used: 40.0, resets_at: 9_000, five_used: 70.0, five_resets_at: 2_000}, 1_000)
      {:room, 30.0}
      iex> Room.room(%{used: 40.0, resets_at: 9_000, five_used: 70.0, five_resets_at: 2_000}, 2_500)
      {:room, 60.0}
      iex> Room.room(%{used: 10.0, resets_at: 9_000, limited_until: 5_000, can_spend: true}, 1_000)
      {:spent, 5_000_000}
      iex> Room.room(nil, 1_000)
      {:room, 100.0}
  """

  @doc "`reading`'s room at `now` (Unix seconds). Option `full_at:` (percent, default 100)."
  @spec room(map | nil, integer, keyword) :: {:room, float} | {:spent, integer}
  def room(reading, now, opts \\ [])
  def room(nil, _now, _opts), do: {:room, 100.0}

  def room(reading, now, opts) when is_map(reading) do
    full = Keyword.get(opts, :full_at, 100.0)

    windows = [
      window(reading[:used], reading[:resets_at], now),
      window(reading[:five_used], reading[:five_resets_at], now)
    ]

    limit =
      case reading[:limited_until] do
        at when is_integer(at) and at > now -> [at]
        _ -> []
      end

    spent = limit ++ for({used, resets} <- windows, used >= full, do: resets)

    case spent do
      [] -> {:room, Enum.min(for {used, _} <- windows, do: max(100.0 - used, 0.0))}
      resets -> {:spent, Enum.max(resets) * 1000}
    end
  end

  def room(_reading, _now, _opts), do: {:room, 100.0}

  # A window's share used before its reset, or 0 once it passed or where it is not known.
  defp window(used, resets, now) when is_number(used) and is_integer(resets) and resets > now,
    do: {used / 1, resets}

  defp window(_used, _resets, _now), do: {0.0, nil}
end
