defmodule CodingAgentFramework.Usage.Allowance do
  @moduledoc """
  Whether an account's allowance has room for a new start, for the `Scheduler`'s gate
  (`docs/design.md`, "A lease"): both windows, the five-hour one and the weekly one, must have
  room. A pure module over `Usage`'s table, read through a connection of the caller's own, so
  asking never waits on `Usage`'s process.

  A window has no room when its share used is at or above `full_at` (a percentage, default 100;
  a placeholder until it is measured) and its reset has not passed. A share used only grows
  until its window resets, so an old reading that says spent stays spent until the reset. An
  account with no reading, or a window the reading lacks, has room: nothing says it is spent,
  and an account has no reading until a session on it draws its status line.

      iex> alias CodingAgentFramework.Usage.Allowance
      iex> reading = %{used: 40.0, resets_at: 9_000, five_used: 100.0, five_resets_at: 2_000}
      iex> Allowance.room(reading, 1_000)
      {:spent, 2_000_000}
      iex> Allowance.room(reading, 2_500)
      :room
      iex> Allowance.room(%{reading | used: 99.0}, 2_500, full_at: 95.0)
      {:spent, 9_000_000}
      iex> Allowance.room(nil, 1_000)
      :room
  """

  alias CodingAgentFramework.Usage.Table

  @doc "Opens a connection of the caller's own to `Usage`'s file at `path`."
  @spec open(String.t()) :: {:ok, Table.db()} | {:refused, term}
  def open(path), do: Table.open(path)

  @doc """
  `account`'s room by its stored reading at `now` (Unix seconds, default the system's):
  `:room`, or `{:spent, retry_at}`, `retry_at` in ms the latest reset among the spent windows.
  Option `full_at:` (percent, default 100).
  """
  @spec check(Table.db(), String.t(), keyword) :: :room | {:spent, integer}
  def check(db, account, opts \\ []) do
    now = Keyword.get(opts, :now, System.os_time(:second))

    case Table.rows(db) do
      {:ok, %{rows: rows}} -> room(Enum.find(rows, &(&1.account == account)), now, opts)
      :unread -> :room
    end
  end

  @doc "A reading's room at `now` (Unix seconds); see the module's doc."
  @spec room(map | nil, integer, keyword) :: :room | {:spent, integer}
  def room(reading, now, opts \\ [])
  def room(nil, _now, _opts), do: :room

  def room(reading, now, opts) do
    full = Keyword.get(opts, :full_at, 100.0)

    spent =
      for {used, resets} <- [
            {reading[:used], reading[:resets_at]},
            {reading[:five_used], reading[:five_resets_at]}
          ],
          is_number(used) and is_integer(resets),
          used >= full and resets > now,
          do: resets

    case spent do
      [] -> :room
      resets -> {:spent, Enum.max(resets) * 1000}
    end
  end
end
