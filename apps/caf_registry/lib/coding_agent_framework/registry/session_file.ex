defmodule CodingAgentFramework.Registry.SessionFile do
  @moduledoc """
  Reads one of Claude Code's `<config>/sessions/<pid>.json` files. Pure, and total over what a
  file can hold: it never raises.

  `pid` and `sessionId` are required; without them, or with them of the wrong type, the file is
  `{:malformed, reason}`. Every other known key is optional: a missing one is `nil`, and one of
  the wrong type is `nil` with the key named in `:problems`. Unknown keys are kept in `:extra`.

      iex> alias CodingAgentFramework.Registry.SessionFile
      iex> {:ok, row} = SessionFile.parse(~s({"pid": 7, "sessionId": "s", "updatedAt": "x", "new": 1}))
      iex> {row.pid, row.session_id, row.updated_at, row.problems, row.extra}
      {7, "s", nil, [{:wrong_type, "updatedAt"}], %{"new" => 1}}
      iex> SessionFile.parse(~s({"pid": 7, "sessionId))
      {:malformed, :not_json}
  """

  # {key in the file, field, type, required?}
  @fields [
    {"pid", :pid, :pid, true},
    {"sessionId", :session_id, :string, true},
    {"cwd", :cwd, :string, false},
    {"name", :name, :string, false},
    {"nameSource", :name_source, :string, false},
    {"status", :status, :string, false},
    {"version", :version, :string, false},
    {"kind", :kind, :string, false},
    {"entrypoint", :entrypoint, :string, false},
    {"procStart", :proc_start, :string, false},
    {"startedAt", :started_at, :integer, false},
    {"statusUpdatedAt", :status_updated_at, :integer, false},
    {"updatedAt", :updated_at, :integer, false}
  ]
  @keys Enum.map(@fields, &elem(&1, 0))

  @type reason :: :not_json | :not_an_object | {:missing | :wrong_type, String.t()}
  @type row :: %{required(atom) => term}

  @doc "The row fields `parse/1` fills, in order."
  @spec fields() :: [atom]
  def fields, do: Enum.map(@fields, &elem(&1, 1))

  @doc "Parses a file's bytes into a row, or names why it cannot."
  @spec parse(binary) :: {:ok, row} | {:malformed, reason}
  def parse(bytes) when is_binary(bytes) do
    case decode(bytes) do
      {:ok, %{} = map} -> row(map)
      {:ok, _} -> {:malformed, :not_an_object}
      :error -> {:malformed, :not_json}
    end
  end

  # A half-written file is invalid JSON; bytes that are not UTF-8 are too.
  defp decode(bytes) do
    {:ok, JSON.decode!(bytes)}
  rescue
    _ -> :error
  end

  defp row(map) do
    Enum.reduce_while(@fields, %{problems: [], extra: Map.drop(map, @keys)}, fn
      {key, field, type, required}, row ->
        case {Map.fetch(map, key), required} do
          {:error, true} -> {:halt, {:missing, key}}
          {:error, false} -> {:cont, Map.put(row, field, nil)}
          {{:ok, nil}, false} -> {:cont, Map.put(row, field, nil)}
          {{:ok, value}, _} -> typed(row, key, field, type, value, required)
        end
    end)
    |> case do
      %{} = row -> {:ok, Map.update!(row, :problems, &Enum.reverse/1)}
      reason -> {:malformed, reason}
    end
  end

  defp typed(row, key, field, type, value, required) do
    cond do
      type?(type, value) ->
        {:cont, Map.put(row, field, value)}

      required ->
        {:halt, {:wrong_type, key}}

      true ->
        {:cont, %{row | problems: [{:wrong_type, key} | row.problems]} |> Map.put(field, nil)}
    end
  end

  defp type?(:pid, v), do: is_integer(v) and v > 0
  defp type?(:string, v), do: is_binary(v)
  defp type?(:integer, v), do: is_integer(v)
end
