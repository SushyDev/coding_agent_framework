defmodule CodingAgentFramework.Tracker.RegistrySource do
  @moduledoc """
  `Registry`'s table as a `Tracker` source, for one `{host, account}`: options `db:`, `host:`
  (its name) and `account:`. Its topic is the one `Registry` cues on, and its rows are sessions.
  """

  @behaviour CodingAgentFramework.Tracker.Source

  alias CodingAgentFramework.Registry.Table

  @impl true
  def open(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      {:ok, %{db: db, host: Keyword.fetch!(opts, :host), account: Keyword.fetch!(opts, :account)}}
    end
  end

  @impl true
  def describe(opts) do
    {host, account} = {Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :account)}
    %{topic: "registry:#{host}:#{account}", scope: {host, account}, kind: :sessions}
  end

  @impl true
  def read(%{db: db, host: host, account: account}, :all) do
    case Table.rows(db, host, account) do
      :unread -> :unread
      {:ok, %{read_at: at, rows: rows}} -> {:ok, %{read_at: at, rows: rows}}
    end
  end

  def read(%{db: db, host: host, account: account}, ids) do
    case Table.last_read(db, host, account) do
      :unread ->
        :unread

      {:ok, %{read_at: at}} ->
        # An id is global to the table; a row of another account is not this topic's.
        rows =
          for row <- Table.rows_by_id(db, ids), row.host == host, row.account == account, do: row

        {:ok, %{read_at: at, rows: rows}}
    end
  end
end
