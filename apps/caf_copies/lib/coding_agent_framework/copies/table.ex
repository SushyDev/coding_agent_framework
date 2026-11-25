defmodule CodingAgentFramework.Copies.Table do
  @moduledoc """
  `copies`: one row per copy, keyed by `{host, project, name}`, which `Copies` alone writes. It
  holds the copy's turn (`model/tla/Copy.tla`'s `turn`, durable) and what earlier syncs sent.

  `state` is `free`, or the turn's: `taken`, `syncing` (until the sync's answer), `synced`,
  `starting` (the caller is sending its start), or `cut` (a cut sync's turn, kept until `until`,
  wall-clock ms, when its host side can no longer take the lock). `holder` names the run that
  holds the turn. `sent` is every path a sync may have written into the copy, NUL-separated.

      iex> path = Path.join(CodingAgentFramework.TestHost.test_dir(), "doc.db")
      iex> {:ok, db} = CodingAgentFramework.Copies.Table.open(path)
      iex> CodingAgentFramework.Copies.Table.get(db, {"laptop", "p", "w"})
      nil
  """

  alias CodingAgentFramework.Store

  @columns ~w(host project name holder state until sent)a
  @schema """
  CREATE TABLE IF NOT EXISTS copies (
    host TEXT NOT NULL, project TEXT NOT NULL, name TEXT NOT NULL, holder TEXT,
    state TEXT NOT NULL, until INTEGER, sent TEXT NOT NULL,
    PRIMARY KEY (host, project, name));
  """

  @type db :: Store.db()
  @type key :: {String.t(), String.t(), String.t()}

  @doc """
  The table's metadata for `CodingAgentFramework.Reader`'s `Tracker` source (F-171): a
  writer's table, read now; topic `copies` (`Copies` cues one topic for every host), scope
  `{host, "copies"}`, rows of kind `:copies`. A copy is keyed by three columns, so each row
  is given the id `<host>/<project>/<name>`, and a cue names no ids: the source reads every
  row. `sent` is left out, as a view needs only the turn.
  """
  @spec meta() :: map
  def meta do
    %{
      schema: @schema,
      table: "copies",
      reads: nil,
      columns: @columns -- [:sent],
      scope: [],
      order: "host, project, name",
      topic: "copies",
      host_topic: false,
      group: "copies",
      kind: :copies,
      name: nil,
      load: &Map.put(&1, :id, "#{&1.host}/#{&1.project}/#{&1.name}")
    }
  end

  @doc "Opens (and creates) the file at `path`, with the table."
  @spec open(String.t()) :: {:ok, db} | {:refused, term}
  def open(path), do: Store.open(path, @schema)

  @doc "The row of `key`, or nil."
  @spec get(db, key) :: map | nil
  def get(db, {host, project, name}),
    do: List.first(select(db, "host=?1 AND project=?2 AND name=?3", [host, project, name]))

  @doc "Every row."
  @spec all(db) :: [map]
  def all(db), do: select(db, "1 = 1", [])

  @doc "The first `n` rows by host, project and name, without `sent`: a view's bounded read."
  @spec first(db, pos_integer) :: [map]
  def first(db, n) do
    where = "1 = 1 ORDER BY host, project, name LIMIT ?1"
    Store.select(db, "copies", @columns -- [:sent], where, [n])
  end

  @doc "Writes row `key` with `fields` (`holder`, `state`, `until`, `sent`)."
  @spec put(db, key, map) :: :ok
  def put(db, {host, project, name}, fields) do
    Store.upsert(db, "copies",
      host: host,
      project: project,
      name: name,
      holder: fields[:holder],
      state: fields.state,
      until: fields[:until],
      sent: fields[:sent] || ""
    )
  end

  @doc "Removes row `key`."
  @spec delete(db, key) :: :ok
  def delete(db, {host, project, name}) do
    Store.query(db, "DELETE FROM copies WHERE host=?1 AND project=?2 AND name=?3", [
      host,
      project,
      name
    ])

    :ok
  end

  defp select(db, where, args), do: Store.select(db, "copies", @columns, where, args)
end
