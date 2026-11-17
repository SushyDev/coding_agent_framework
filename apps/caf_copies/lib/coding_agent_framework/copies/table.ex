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
