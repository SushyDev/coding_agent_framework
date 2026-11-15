defmodule CodingAgentFramework.TmuxSampler.Join do
  @moduledoc """
  The pure, total join of one server's panes with one host's held sockets
  (`model/tla/Agent.tla`, `SamplerReads`).

  A held socket is a row keyed `"held:<name>"`: a live one is `:viewed` when a pane tagged with
  its name shows it, `:unviewed` when none does (the model's `unviewed`), and `:no_server` when
  the server is down; a stale socket is `:stale`, one whose state is unknown `:unknown`. A
  tagged pane is a row keyed by its generation and id, `"viewer:<gen>:<pane>"`: `:live`,
  `:stale`, `:gone` (no socket) or `:unknown`, by its tag's socket. A pane entry or a held entry
  of no known shape is a `:problem` row, never a crash.

  Pane ids are never compared across servers or restarts: each server start is a new
  generation, seen by a new `start` (the server's pid and start time), by a read with no server
  before this one, or by an id that is new and no higher than the last read's highest (tmux
  counts up within one server).

      iex> alias CodingAgentFramework.TmuxSampler.Join
      iex> panes = [%{pane: "%0", session: "alpha", tag: "alpha", start: "7@5"}]
      iex> j = Join.join({:ok, panes}, [%{name: "alpha", state: :live}, %{name: "beta", state: :live}], nil)
      iex> {j.rows["held:alpha"].status, j.rows["held:beta"].status, j.rows["viewer:0:%0"].status}
      {:viewed, :unviewed, :live}
      iex> Join.join(:no_server, [%{name: "alpha", state: :live}], j).rows["held:alpha"].status
      :no_server
  """

  @type last :: %{
          up: boolean,
          generation: non_neg_integer,
          start: String.t() | nil,
          ids: [integer]
        }
  @type t :: %{
          up: boolean,
          generation: non_neg_integer,
          start: String.t() | nil,
          ids: [integer],
          rows: %{String.t() => map}
        }

  @columns [:kind, :name, :pane, :generation, :socket, :status, :panes, :problem]

  @doc "The row columns, each row has all of them."
  @spec columns() :: [atom]
  def columns, do: @columns

  @doc """
  Joins `{:ok, panes}` (`Tmux.list_panes/1`'s entries) or `:no_server` with `held`
  (`Holder.list/1`'s entries), given the last good join (`nil` before the first).
  """
  @spec join({:ok, list} | :no_server, list, last | t | nil) :: t
  def join(panes, held, last) do
    {panes, pane_problems} = split_panes(panes)
    {held, held_problems} = split_held(held)
    {up, start, ids} = server(panes)
    generation = generation(last, up, start, ids)
    sockets = Map.new(held, &{&1.name, &1.state})

    held_rows =
      Map.new(held, fn %{name: name, state: state} ->
        shown = for p <- panes || [], p.tag == name, do: p.pane

        status =
          case {state, panes, shown} do
            {:live, nil, _} -> :no_server
            {:live, _, []} -> :unviewed
            {:live, _, _} -> :viewed
            {:stale, _, _} -> :stale
            _ -> :unknown
          end

        {"held:" <> name,
         row(kind: :held, name: name, socket: state, status: status, panes: join_ids(shown))}
      end)

    viewer_rows =
      for p <- panes || [], is_binary(p.tag), into: %{} do
        socket = Map.get(sockets, p.tag, :absent)

        status =
          case socket do
            :live -> :live
            :stale -> :stale
            :absent -> :gone
            _ -> :unknown
          end

        {"viewer:#{generation}:#{p.pane}",
         row(
           kind: :viewer,
           name: p.tag,
           pane: p.pane,
           generation: generation,
           socket: socket,
           status: status
         )}
      end

    problem_rows =
      for entry <- pane_problems ++ held_problems, into: %{} do
        text = inspect(entry, limit: 20, printable_limit: 200)
        {"problem:#{generation}:#{text}", row(kind: :problem, status: :malformed, problem: text)}
      end

    %{
      up: up,
      generation: generation,
      start: start,
      ids: ids,
      rows: held_rows |> Map.merge(viewer_rows) |> Map.merge(problem_rows)
    }
  end

  defp row(fields), do: Map.merge(Map.new(@columns, &{&1, nil}), Map.new(fields))

  defp split_panes(:no_server), do: {nil, []}
  defp split_panes({:ok, entries}) when is_list(entries), do: Enum.split_with(entries, &pane?/1)
  defp split_panes(other), do: {[], [other]}

  defp split_held(entries) when is_list(entries), do: Enum.split_with(entries, &held?/1)
  defp split_held(other), do: {[], [other]}

  defp pane?(%{pane: "%" <> n, session: s, tag: t, start: start}),
    do: id(n) != nil and is_binary(s) and (is_nil(t) or is_binary(t)) and is_binary(start)

  defp pane?(_), do: false

  defp held?(%{name: name, state: _}), do: is_binary(name)
  defp held?(_), do: false

  defp server(nil), do: {false, nil, []}

  defp server(panes) do
    start = panes |> Enum.map(& &1.start) |> Enum.max(fn -> nil end)
    {true, start, Enum.map(panes, &id(binary_part(&1.pane, 1, byte_size(&1.pane) - 1)))}
  end

  defp id(n) do
    case Integer.parse(n) do
      {id, ""} when id >= 0 -> id
      _ -> nil
    end
  end

  defp generation(nil, _up, _start, _ids), do: 0
  defp generation(%{generation: g}, false, _start, _ids), do: g

  defp generation(%{generation: g} = last, true, start, ids) do
    old = MapSet.new(last.ids)
    high = Enum.max(last.ids, fn -> -1 end)

    restarted =
      not last.up or
        (is_binary(start) and is_binary(last.start) and start != last.start) or
        Enum.any?(ids, &(&1 <= high and not MapSet.member?(old, &1)))

    if restarted, do: g + 1, else: g
  end

  defp join_ids([]), do: nil
  defp join_ids(ids), do: Enum.join(ids, ",")
end
