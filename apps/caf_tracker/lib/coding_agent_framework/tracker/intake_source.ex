defmodule CodingAgentFramework.Tracker.IntakeSource do
  @moduledoc """
  `Intake`'s table as a `Tracker` source, for one `{host, account}`: options `db:`, `host:` (the
  name `Intake` was started with) and `account:`. Its topic is the one `Intake` cues on, and its
  rows are hook events. It is `:unread` until that host's `Intake` has started once.
  """

  @behaviour CodingAgentFramework.Tracker.Source

  alias CodingAgentFramework.Intake.Table

  @impl true
  def open(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      {:ok, %{db: db, host: Keyword.fetch!(opts, :host), account: Keyword.fetch!(opts, :account)}}
    end
  end

  @impl true
  def describe(opts) do
    {host, account} = {Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :account)}
    %{topic: "intake:#{host}:#{account}", scope: {host, account}, kind: :events}
  end

  @impl true
  def read(%{db: db, host: host, account: account}, :all), do: Table.rows(db, host, account)

  def read(%{db: db, host: host, account: account}, ids) do
    with {:ok, %{read_at: at}} <- Table.last_read(db, host, account) do
      # An id is global to the table; a row of another account is not this topic's.
      rows =
        for row <- Table.rows_by_id(db, ids), row.host == host, row.account == account, do: row

      {:ok, %{read_at: at, rows: rows}}
    end
  end
end
