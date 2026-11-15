defmodule CodingAgentFramework.Tracker.SessionsSource do
  @moduledoc """
  `Sessions`' table as a `Tracker` source, for one `{host, account}`: options `db:`, `host:` (its
  name) and `account:`. Its topic is the one `Sessions` cues on, and its rows are of kind
  `:held`, the sessions the framework started. `Sessions` writes as it acts rather than reading
  on a timer, so a read's time is when the table was read.
  """

  @behaviour CodingAgentFramework.Tracker.Source

  alias CodingAgentFramework.Sessions.Table

  @impl true
  def open(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      {:ok, %{db: db, host: Keyword.fetch!(opts, :host), account: Keyword.fetch!(opts, :account)}}
    end
  end

  @impl true
  def describe(opts) do
    {host, account} = {Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :account)}
    %{topic: "sessions:#{host}:#{account}", scope: {host, account}, kind: :held}
  end

  @impl true
  def read(%{db: db, host: host, account: account}, :all),
    do: {:ok, %{read_at: now(), rows: Table.rows(db, host, account)}}

  def read(%{db: db, host: host, account: account}, ids) do
    # An id is global to the table; a row of another host or account is not this topic's.
    rows = for row <- Table.rows_by_id(db, ids), row.host == host, row.account == account, do: row
    {:ok, %{read_at: now(), rows: rows}}
  end

  defp now, do: System.os_time(:millisecond)
end
