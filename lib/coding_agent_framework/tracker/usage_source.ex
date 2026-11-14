defmodule CodingAgentFramework.Tracker.UsageSource do
  @moduledoc """
  `Usage`'s table as a `Tracker` source, for one account: options `db:`, `host:` (the name
  `Usage` was started with) and `account:`. Its topic is the one `Usage` cues on, its scope is
  `{host, account}`, and its rows are the account's reading.
  """

  @behaviour CodingAgentFramework.Tracker.Source

  alias CodingAgentFramework.Usage.Table

  @impl true
  def open(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         do: {:ok, %{db: db, account: Keyword.fetch!(opts, :account)}}
  end

  @impl true
  def describe(opts) do
    {host, account} = {Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :account)}
    %{topic: "usage:#{host}:#{account}", scope: {host, account}, kind: :usage}
  end

  @impl true
  def read(%{db: db, account: account}, :all) do
    with {:ok, %{read_at: at, rows: rows}} <- Table.rows(db),
         do: {:ok, %{read_at: at, rows: Enum.filter(rows, &(&1.account == account))}}
  end

  def read(%{db: db, account: account}, ids) do
    with {:ok, %{read_at: at}} <- Table.last_read(db) do
      # An id is global to the table; a row of another account is not this topic's.
      {:ok,
       %{
         read_at: at,
         rows: for(row <- Table.rows_by_id(db, ids), row.account == account, do: row)
       }}
    end
  end
end
