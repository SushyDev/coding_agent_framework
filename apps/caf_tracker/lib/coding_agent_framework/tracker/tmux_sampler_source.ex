defmodule CodingAgentFramework.Tracker.TmuxSamplerSource do
  @moduledoc """
  `TmuxSampler`'s table as a `Tracker` source, for one `{host, server}`: options `db:`, `host:`
  and `server:`. Its topic is the one `TmuxSampler` cues on, `tmux:<host>:<server>`; its rows
  are of kind `:viewers`, under the scope `{host, "tmux:<server>"}`, since a server belongs to no
  account. When the newest sample failed it answers `{:unknown, reason}`, so the fold keeps the
  last good rows and their age, and names the problem.
  """

  @behaviour CodingAgentFramework.Tracker.Source

  alias CodingAgentFramework.TmuxSampler.Table

  @impl true
  def open(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      {:ok, %{db: db, host: Keyword.fetch!(opts, :host), server: Keyword.fetch!(opts, :server)}}
    end
  end

  @impl true
  def describe(opts) do
    {host, server} = {Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :server)}
    %{topic: "tmux:#{host}:#{server}", scope: {host, "tmux:" <> server}, kind: :viewers}
  end

  @impl true
  def read(%{db: db, host: host, server: server}, ids) do
    case Table.last_read(db, host, server) do
      nil ->
        :unread

      %{failed_at: at, problem: problem} when is_integer(at) ->
        {:unknown, {:sample_failed, at, problem}}

      %{read_at: at} when ids == :all ->
        {:ok, %{read_at: at, rows: elem(Table.rows(db, host, server), 1).rows}}

      %{read_at: at} ->
        # An id is global to the table; a row of another server is not this topic's.
        rows =
          for row <- Table.rows_by_id(db, ids), row.host == host, row.server == server, do: row

        {:ok, %{read_at: at, rows: rows}}
    end
  end
end
