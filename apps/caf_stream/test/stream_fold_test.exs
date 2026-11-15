defmodule CodingAgentFramework.StreamFoldTest do
  @moduledoc "Properties of `Stream.Line`, the one encoder, and `Stream.Fold`, the event fold."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CodingAgentFramework.Stream.{Fold, Line}

  property "every message is one whole JSON line that decodes to its text" do
    check all(
            text <- one_of([string(:utf8), string(:printable), string([0..0x1F, 0x2028, 0x2029])])
          ) do
      {:ok, line} = Line.encode({:message, "u", text})
      assert one_line?(line)
      assert {:ok, %{"message" => %{"content" => ^text}, "uuid" => "u"}} = JSON.decode(line)
    end
  end

  property "an answer fits the pipe's atomic size, its message cut to fit" do
    check all(
            id <- string(:alphanumeric, max_length: 40),
            message <- string(:utf8, max_length: 700)
          ) do
      {:ok, line} = Line.encode({:answer, id, {:deny, message}})
      assert byte_size(line) <= Line.atomic() and one_line?(line)
      {:ok, %{"response" => %{"request_id" => ^id, "response" => r}}} = JSON.decode(line)
      assert String.starts_with?(message, r["message"])
    end
  end

  test "a line that is not text, or not a line, is refused" do
    assert {:refused, :not_utf8} = Line.encode({:message, "u", <<0xFF>>})
    assert {:refused, :bad_line} = Line.encode({:message, "u", 7})
  end

  property "reads at any cut points fold each whole line once, as one read does" do
    check all(events <- list_of(event(), max_length: 30), cuts <- list_of(integer(0..2_000))) do
      log = Enum.map_join(events, &(JSON.encode!(&1) <> "\n"))
      sizes = cuts |> Enum.map(&min(&1, byte_size(log))) |> Enum.sort()

      folded =
        Enum.reduce(sizes ++ [byte_size(log)], marked(), fn size, fold ->
          Fold.take(fold, binary_part(log, fold.offset, max(size - fold.offset, 0)))
        end)

      assert folded == Fold.take(marked(), log)

      assert {folded.offset, folded.events, folded.problems} ==
               {byte_size(log), length(events), 0}
    end
  end

  property "a row moves only along the spec's arrows" do
    check all(events <- list_of(event(), max_length: 40)) do
      fold = Enum.reduce(events, marked(), &Fold.event(&2, &1))
      replayed = for %{"isReplay" => true, "uuid" => u} <- events, do: u

      for {u, m} <- fold.messages,
          do: assert(m.state == if(u in replayed, do: :delivered, else: :writing))

      for {id, r} <- fold.requests do
        canceled? =
          Enum.any?(events, &(&1["type"] == "control_cancel_request" and &1["request_id"] == id))

        assert r.state == :held or (r.state == :canceled and canceled?)
      end

      gone = Fold.exit_seen(fold, &(&1 == "m1"))
      assert Enum.all?(gone.requests, fn {_, r} -> r.state in [:canceled, :lost] end)
      assert Enum.all?(gone.messages, fn {_, m} -> m.state in [:delivered, :undelivered] end)
    end
  end

  test "an answer's replay answers only a request being answered, by its id" do
    fold =
      Fold.new()
      |> Fold.event(request("r1"))
      |> Fold.event(request("r2"))
      |> Fold.mark({:answer, "r2", :allow}, "x\n", 0)
      |> Fold.event(%{
        "type" => "control_response",
        "isReplay" => true,
        "response" => %{"request_id" => "r2"}
      })

    assert {fold.requests["r1"].state, fold.requests["r2"].state} == {:held, :answered}
    assert {:refused, {:request, :answered}} = Fold.check(fold, {:answer, "r2", :allow})
  end

  # Two messages marked as writing, so replays have rows to settle.
  defp marked do
    Fold.new()
    |> Fold.mark({:message, "m1", ""}, "x\n", 0)
    |> Map.put(:idle, true)
    |> Fold.mark({:message, "m2", ""}, "x\n", 0)
  end

  defp request(id),
    do: %{
      "type" => "control_request",
      "request_id" => id,
      "request" => %{"subtype" => "can_use_tool"}
    }

  defp event do
    id = member_of(["m1", "m2", "r1", "r2"])

    one_of([
      map(id, &%{"type" => "user", "isReplay" => true, "uuid" => &1}),
      constant(%{"type" => "result", "user_message_uuids" => ["m1"]}),
      map(id, &request/1),
      map(id, &%{"type" => "control_cancel_request", "request_id" => &1}),
      map(
        id,
        &%{"type" => "control_response", "isReplay" => true, "response" => %{"request_id" => &1}}
      ),
      constant(%{
        "type" => "assistant",
        "message" => %{"content" => "line\nbreak " <> <<0x2028::utf8>> <> ""}
      }),
      constant(%{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => "allowed"}})
    ])
  end

  defp one_line?(line) do
    String.ends_with?(line, "\n") and
      not String.contains?(binary_part(line, 0, byte_size(line) - 1), ["\n", "\r"]) and
      not String.contains?(line, [<<0x2028::utf8>>, <<0x2029::utf8>>]) and
      not Enum.any?(:binary.bin_to_list(line, 0, byte_size(line) - 1), &(&1 < 0x20))
  end
end
