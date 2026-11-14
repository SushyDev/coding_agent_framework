defmodule CodingAgentFramework.Tracker.RecoveriesSource do
  @moduledoc """
  `Recoveries`' table as a `Tracker` source, for one `{host, server}`: options `db:`, `host:`
  and `server:`. Its topic is the one `Recoveries` cues on, `recoveries:<host>:<server>`; its
  rows are of kind `:recoveries`, under the sampler's scope `{host, "tmux:<server>"}`.
  """

  @behaviour CodingAgentFramework.Tracker.Source

  alias CodingAgentFramework.Recoveries.Table

  @impl true
  def open(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      {:ok, %{db: db, host: Keyword.fetch!(opts, :host), server: Keyword.fetch!(opts, :server)}}
    end
  end

  @impl true
  def describe(opts) do
    {host, server} = {Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :server)}
    %{topic: "recoveries:#{host}:#{server}", scope: {host, "tmux:" <> server}, kind: :recoveries}
  end

  @impl true
  def read(%{db: db, host: host, server: server}, :all),
    do: {:ok, %{read_at: now(), rows: Table.rows(db, host, server)}}

  def read(%{db: db, host: host, server: server}, ids) do
    # An id is global to the table; a row of another server is not this topic's.
    rows = for row <- Table.rows_by_id(db, ids), row.host == host, row.server == server, do: row
    {:ok, %{read_at: now(), rows: rows}}
  end

  defp now, do: System.os_time(:millisecond)
end
