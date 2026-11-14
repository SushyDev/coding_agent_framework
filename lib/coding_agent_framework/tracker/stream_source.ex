defmodule CodingAgentFramework.Tracker.StreamSource do
  @moduledoc """
  `Stream`'s table as a `Tracker` source, for one host: options `db:` and `host:` (its name).
  Its topic is the one `Stream` cues on; its rows are headless delegates.
  """

  @behaviour CodingAgentFramework.Tracker.Source

  alias CodingAgentFramework.Stream.Table

  @impl true
  def open(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         do: {:ok, %{db: db, host: Keyword.fetch!(opts, :host)}}
  end

  @impl true
  def describe(opts) do
    host = Keyword.fetch!(opts, :host)
    %{topic: "stream:#{host}", scope: {host, "stream"}, kind: :stream}
  end

  @impl true
  def read(%{db: db, host: host}, :all), do: Table.rows(db, host)

  def read(%{db: db, host: host}, ids) do
    with {:ok, at} <- Table.last_read(db, host),
         do: {:ok, %{read_at: at, rows: Table.rows_by_id(db, host, ids)}}
  end
end
