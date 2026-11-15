defmodule CodingAgentFramework.SessionFiles do
  @moduledoc """
  Synthetic Claude Code session files for tests, as `StreamData` generators. Every value is
  made up; the keys and value types follow the files Claude Code writes.
  """

  use ExUnitProperties

  @strings ~w(cwd name nameSource status version kind entrypoint procStart)
  @ints ~w(startedAt statusUpdatedAt updatedAt)

  @doc "A well-formed session file's map, with some optional keys left out and some unknown keys."
  def good do
    gen all pid <- integer(1..99_998),
            id <- string(:alphanumeric, min_length: 1, max_length: 12),
            strings <- optional(@strings, string(:printable, max_length: 12)),
            ints <- optional(@ints, integer(0..4_000_000_000_000)),
            extra <- optional(~w(peerProtocol peerFeatures pidDomain x_new), json()) do
      Map.merge(extra, %{"pid" => pid, "sessionId" => id})
      |> Map.merge(strings)
      |> Map.merge(ints)
    end
  end

  @doc """
  `{kind, bytes}` for one file: `:good`, `:odd` (parses, with a problem named) or `:bad`
  (cannot be parsed).
  """
  def file do
    one_of([
      map(good(), &{:good, JSON.encode!(&1)}),
      map(bind(good(), &wrong_optional/1), &{:odd, JSON.encode!(&1)}),
      map(bind(good(), &broken/1), &{:bad, &1}),
      map(binary(), &{:bad, "\x01" <> &1})
    ])
  end

  defp optional(keys, value), do: optional_map(Map.new(keys, &{&1, value}))

  defp json do
    one_of([
      integer(),
      string(:printable, max_length: 8),
      boolean(),
      constant(nil),
      list_of(integer(), max_length: 3)
    ])
  end

  defp wrong_optional(map) do
    map(member_of(@strings ++ @ints), fn key ->
      Map.put(map, key, if(key in @ints, do: "not a number", else: 12))
    end)
  end

  # A required key missing or of the wrong type, a file cut short, or not an object.
  defp broken(map) do
    text = JSON.encode!(map)

    one_of([
      constant(JSON.encode!(Map.delete(map, "pid"))),
      constant(JSON.encode!(Map.delete(map, "sessionId"))),
      constant(JSON.encode!(Map.put(map, "pid", "seven"))),
      constant(JSON.encode!(Map.put(map, "sessionId", 7))),
      map(integer(0..(byte_size(text) - 1)), &binary_part(text, 0, &1)),
      constant("[1, 2]")
    ])
  end
end
