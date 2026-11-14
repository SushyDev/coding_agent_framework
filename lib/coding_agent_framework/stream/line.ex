defmodule CodingAgentFramework.Stream.Line do
  @moduledoc """
  The one encoder of the lines written to a headless delegate's stdin, in the shapes Claude Code
  2.1.322 reads (`docs/build-notes/F-31.md`). A line that does not parse ends the session, so
  every line is one whole JSON object and one line: control characters, U+2028 and U+2029 are
  escaped, and the only newline is the last byte.

  A message may be long; it is written alone. Every other line is kept within the pipe's atomic
  size (512 bytes on macOS), so lines written together never mix: a deny's message is cut to fit.

      iex> {:ok, line} = CodingAgentFramework.Stream.Line.encode({:message, "u1", "hi"})
      iex> line
      ~s({"message":{"content":"hi","role":"user"},"parent_tool_use_id":null,"session_id":"","type":"user","uuid":"u1"}\\n)
      iex> CodingAgentFramework.Stream.Line.encode({:answer, "r1", {:deny, String.duplicate("x", 900)}}) |> elem(1) |> byte_size()
      512
  """

  @atomic 512
  @max_message 262_144

  @type t ::
          {:message, String.t(), String.t()}
          | {:answer, String.t(), :allow | {:deny, String.t()}}
          | {:interrupt, String.t()}
          | {:end_session, String.t()}

  @doc "The pipe's atomic size: the most a line other than a message may take."
  def atomic, do: @atomic

  @doc """
  Encodes one line, newline included. Answers `{:ok, line}` or `{:refused, reason}`: `:not_utf8`,
  `:too_long`, or `:bad_line`.
  """
  @spec encode(t) :: {:ok, binary} | {:refused, term}
  def encode({:message, uuid, text}) when is_binary(text) do
    with {:ok, line} <- json(user(uuid, text)) do
      if byte_size(line) <= @max_message, do: {:ok, line}, else: {:refused, :too_long}
    end
  end

  def encode({:answer, id, :allow}), do: small(answer(id, %{"behavior" => "allow"}))

  def encode({:answer, id, {:deny, message}}) when is_binary(message) do
    if String.valid?(message), do: deny(id, message), else: {:refused, :not_utf8}
  end

  def encode({kind, id}) when kind in [:interrupt, :end_session] and is_binary(id),
    do:
      small(%{"type" => "control_request", "request_id" => id, "request" => %{"subtype" => kind}})

  def encode(_), do: {:refused, :bad_line}

  defp user(uuid, text) do
    %{
      "type" => "user",
      "uuid" => uuid,
      "session_id" => "",
      "parent_tool_use_id" => nil,
      "message" => %{"role" => "user", "content" => text}
    }
  end

  defp answer(id, response) do
    inner = %{"subtype" => "success", "request_id" => id, "response" => response}
    %{"type" => "control_response", "response" => inner}
  end

  # The message is cut a character at a time until the line fits.
  defp deny(id, message) do
    case json(answer(id, %{"behavior" => "deny", "message" => message})) do
      {:ok, line} when byte_size(line) <= @atomic -> {:ok, line}
      {:ok, _} when message == "" -> {:refused, :too_long}
      {:ok, _} -> deny(id, String.slice(message, 0..-2//1))
      refused -> refused
    end
  end

  defp small(map) do
    with {:ok, line} <- json(map),
         do: if(byte_size(line) <= @atomic, do: {:ok, line}, else: {:refused, :too_long})
  end

  defp json(map) do
    if strings_valid?(map) do
      line =
        map
        |> JSON.encode!()
        |> String.replace(<<0x2028::utf8>>, "\\u2028")
        |> String.replace(<<0x2029::utf8>>, "\\u2029")

      {:ok, line <> "\n"}
    else
      {:refused, :not_utf8}
    end
  end

  defp strings_valid?(map) when is_map(map),
    do: Enum.all?(map, fn {_, v} -> strings_valid?(v) end)

  defp strings_valid?(s) when is_binary(s), do: String.valid?(s)
  defp strings_valid?(_), do: true
end
