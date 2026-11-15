defmodule CodingAgentFramework.Tracker.UsageSource do
  @moduledoc """
  `Usage`'s table as a `Tracker` source, for one account: options `db:`, `host:` (the name
  `Usage` was started with) and `account:`. Its topic is the one `Usage` cues on, its scope is
  `{host, account}`, and its rows are the account's reading, each with `assumed`: true when
  its window has reset since it was written (`Usage.Reading.status/3`), so a view shows it as
  0 % used and assumed. The clock is option `clock:`, a function of no arguments that answers
  Unix seconds; without it, the system's.
  """

  @behaviour CodingAgentFramework.Tracker.Source

  alias CodingAgentFramework.Usage.{Reading, Table}

  @impl true
  def open(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         do:
           {:ok,
            %{
              db: db,
              account: Keyword.fetch!(opts, :account),
              clock: Keyword.get(opts, :clock, fn -> System.os_time(:second) end)
            }}
  end

  @impl true
  def describe(opts) do
    {host, account} = {Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :account)}
    %{topic: "usage:#{host}:#{account}", scope: {host, account}, kind: :usage}
  end

  @impl true
  def read(%{db: db, account: account} = state, :all) do
    with {:ok, %{read_at: at, rows: rows}} <- Table.rows(db),
         do: {:ok, %{read_at: at, rows: mark(state, Enum.filter(rows, &(&1.account == account)))}}
  end

  def read(%{db: db, account: account} = state, ids) do
    with {:ok, %{read_at: at}} <- Table.last_read(db) do
      # An id is global to the table; a row of another account is not this topic's.
      {:ok,
       %{
         read_at: at,
         rows: mark(state, for(row <- Table.rows_by_id(db, ids), row.account == account, do: row))
       }}
    end
  end

  defp mark(%{clock: clock}, rows) do
    now = clock.()
    for row <- rows, do: Map.put(row, :assumed, match?({:assumed, _}, Reading.status(row, now)))
  end
end
