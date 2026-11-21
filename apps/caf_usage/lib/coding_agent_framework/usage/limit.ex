defmodule CodingAgentFramework.Usage.Limit do
  @moduledoc """
  An account's usage limit, read from Claude Code's record of it (`docs/design.md`, "Usage
  limits"; `model/tla/Limit.tla`'s `Read`). Pure and total.

  Claude Code 2.1.322 writes one record at a turn that hits a limit, in one shape in three
  places (measured in F-181): a transcript line's `quotaLimits` (and its
  `apiErrorParams.rate_limit_info`), a headless stream's `rate_limit_event`'s
  `rate_limit_info`, and the stream's assistant line's `api_error_params.rate_limit_info`. A
  record says the account is limited only when its `status` is `"rejected"`; its `resetsAt`
  (Unix seconds) is when the limit ends, its `rateLimitType` the window (`five_hour`,
  `seven_day`, or a model family's), and its `overageStatus` whether usage credits are on.

  `can_spend` is true only for an `overageStatus` that says credits are on (`allowed`,
  `allowed_warning`); every other value, `rejected` the one measured, and none at all, is
  false. Spending is never the framework's: a person answers a `usage_credits` prompt.

      iex> alias CodingAgentFramework.Usage.Limit
      iex> Limit.parse(%{"status" => "rejected", "resetsAt" => 1_800_000_000,
      ...>   "rateLimitType" => "seven_day", "overageStatus" => "rejected"})
      {:ok, %{limited_until: 1_800_000_000, window: "seven_day", can_spend: false}}
      iex> Limit.parse(%{"status" => "allowed_warning", "resetsAt" => 1_800_000_000})
      :none
      iex> Limit.parse(%{"status" => "rejected"})
      {:malformed, {:missing, "resetsAt"}}
  """

  @type t :: %{limited_until: integer, window: String.t() | nil, can_spend: boolean}

  @spends ~w(allowed allowed_warning)

  @doc """
  The limit in a record (a decoded `quotaLimits` or `rate_limit_info` map): `{:ok, limit}`,
  `:none` for a record that is not a rejection, or `{:malformed, reason}`.
  """
  @spec parse(term) :: {:ok, t} | :none | {:malformed, term}
  def parse(%{"status" => "rejected"} = info) do
    case info["resetsAt"] do
      at when is_number(at) ->
        window = if is_binary(info["rateLimitType"]), do: info["rateLimitType"]

        {:ok,
         %{limited_until: trunc(at), window: window, can_spend: info["overageStatus"] in @spends}}

      nil ->
        {:malformed, {:missing, "resetsAt"}}

      _ ->
        {:malformed, {:wrong_type, "resetsAt"}}
    end
  end

  def parse(%{"status" => status}) when is_binary(status), do: :none
  def parse(_), do: {:malformed, :no_status}

  @doc """
  Whether a newer record `new` replaces the account's `old` one at `now` (Unix seconds): a later
  reset, or any record once the old one's reset passed. A record read late, whose reset is
  earlier than one still in force, never shortens it.

      iex> alias CodingAgentFramework.Usage.Limit
      iex> Limit.replaces?(%{limited_until: 200}, %{limited_until: 100}, 50)
      true
      iex> Limit.replaces?(%{limited_until: 90}, %{limited_until: 100}, 50)
      false
      iex> Limit.replaces?(%{limited_until: 90}, %{limited_until: 100}, 150)
      true
      iex> Limit.replaces?(%{limited_until: 90}, nil, 150)
      true
  """
  @spec replaces?(map, map | nil, integer) :: boolean
  def replaces?(_new, nil, _now), do: true
  def replaces?(_new, %{limited_until: nil}, _now), do: true

  def replaces?(%{limited_until: new}, %{limited_until: old}, now),
    do: new >= old or old <= now
end
