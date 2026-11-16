defmodule CodingAgentFramework.Tracker.DelegatesSource do
  @moduledoc """
  `Delegates`' table as a `Tracker` source, for one host: options `db:` and `host:` (its name).
  Its topic is the one `Delegates` cues on, and its rows, of kind `:delegates`, are the starts of
  delegates, each with its parent, project, account and session. `Delegates` writes as it acts
  rather than reading on a timer, so a read's time is when the table was read.
  """

  @behaviour CodingAgentFramework.Tracker.Source

  alias CodingAgentFramework.Delegates.Table

  @impl true
  def open(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         do: {:ok, %{db: db, host: Keyword.fetch!(opts, :host)}}
  end

  @impl true
  def describe(opts) do
    host = Keyword.fetch!(opts, :host)
    %{topic: "delegates:#{host}", scope: {host, "delegates"}, kind: :delegates}
  end

  @impl true
  def read(%{db: db, host: host}, :all), do: {:ok, %{read_at: now(), rows: Table.rows(db, host)}}

  def read(%{db: db, host: host}, ids),
    do: {:ok, %{read_at: now(), rows: Table.rows_by_id(db, host, ids)}}

  defp now, do: System.os_time(:millisecond)
end
