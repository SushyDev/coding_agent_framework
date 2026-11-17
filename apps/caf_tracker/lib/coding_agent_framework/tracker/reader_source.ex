defmodule CodingAgentFramework.Tracker.ReaderSource do
  @moduledoc """
  A reader's table as a `Tracker` source, made from the table's metadata
  (`CodingAgentFramework.Reader`): option `table:` names the reader's table module, the one
  with `meta/0` (`Registry.Table`, `Transcripts.Table`, `Usage.Table`, `TmuxSampler.Table`), and
  the rest are the scope it reads: `db:`, `host:`, and `account:` or `server:` as the table
  names. Its topic is the one the reader cues on.

      {Tracker.ReaderSource, table: Registry.Table, db: path, host: "laptop", account: "work"}
  """

  @behaviour CodingAgentFramework.Tracker.Source

  alias CodingAgentFramework.Reader

  @impl true
  def open(opts) do
    meta = Keyword.fetch!(opts, :table).meta()

    with {:ok, db} <- Reader.open(meta, Keyword.fetch!(opts, :db)),
         do: {:ok, %{meta: meta, db: db, opts: opts}}
  end

  @impl true
  def describe(opts), do: Reader.describe(Keyword.fetch!(opts, :table).meta(), opts)

  @impl true
  def read(%{meta: meta, db: db, opts: opts}, ids), do: Reader.source_read(meta, db, opts, ids)
end
