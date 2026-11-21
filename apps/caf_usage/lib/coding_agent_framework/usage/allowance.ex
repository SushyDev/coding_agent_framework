defmodule CodingAgentFramework.Usage.Allowance do
  @moduledoc """
  Whether an account has room for new work, for the `Scheduler`'s gate (`docs/design.md`, "A
  lease"; `model/tla/Limit.tla`'s `Admit`): `CodingAgentFramework.Usage.Room`'s rule over
  `Usage`'s table, read through a connection of the caller's own, so asking never waits on
  `Usage`'s process. An account limited by its record (`limited_until`) is spent until that
  reset, whatever its status line said; a window past its reset has room again, however old
  the reading.

      iex> alias CodingAgentFramework.Usage.Allowance
      iex> reading = %{used: 40.0, resets_at: 9_000, five_used: 100.0, five_resets_at: 2_000}
      iex> Allowance.room(reading, 1_000)
      {:spent, 2_000_000}
      iex> Allowance.room(reading, 2_500)
      :room
      iex> Allowance.room(%{reading | used: 99.0}, 2_500, full_at: 95.0)
      {:spent, 9_000_000}
      iex> Allowance.room(Map.put(reading, :limited_until, 3_000), 2_500)
      {:spent, 3_000_000}
      iex> Allowance.room(nil, 1_000)
      :room
  """

  alias CodingAgentFramework.Usage.{Room, Table}

  @doc "Opens a connection of the caller's own to `Usage`'s file at `path`."
  @spec open(String.t()) :: {:ok, Table.db()} | {:refused, term}
  def open(path), do: Table.open(path)

  @doc """
  `account`'s room by its stored reading at `now` (Unix seconds, default the system's):
  `:room`, or `{:spent, retry_at}`, `retry_at` in ms the latest reset among the spent windows
  and the limit. Option `full_at:` (percent, default 100).
  """
  @spec check(Table.db(), String.t(), keyword) :: :room | {:spent, integer}
  def check(db, account, opts \\ []) do
    now = Keyword.get(opts, :now, System.os_time(:second))

    case Table.rows(db) do
      {:ok, %{rows: rows}} -> room(Enum.find(rows, &(&1.account == account)), now, opts)
      :unread -> :room
    end
  end

  @doc "A reading's room at `now` (Unix seconds), as the gate reads it; see the module's doc."
  @spec room(map | nil, integer, keyword) :: :room | {:spent, integer}
  def room(reading, now, opts \\ []) do
    case Room.room(reading, now, opts) do
      {:room, _} -> :room
      spent -> spent
    end
  end
end
