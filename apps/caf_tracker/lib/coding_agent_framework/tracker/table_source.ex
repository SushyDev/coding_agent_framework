defmodule CodingAgentFramework.Tracker.TableSource do
  @moduledoc """
  A part's table as a `Tracker` source, made from the table's metadata
  (`CodingAgentFramework.Reader`): option `table:` names the table module, the one with
  `meta/0` (the readers' `Registry.Table`, `Transcripts.Table`, `Usage.Table` and
  `TmuxSampler.Table`, and the writers' `Acts.Table`, `Sessions.Table` and `Delegates.Table`),
  and the rest are the scope it reads: `db:`, `host:`, and `account:`, `server:` or
  `instance:` as the table names. Its topic is the one its writer cues on. (It was
  `ReaderSource` until the writers' tables gave their metadata too, F-120's new-2.)

      {Tracker.TableSource, table: Registry.Table, db: path, host: "laptop", account: "work"}
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
