defmodule CodingAgentFramework.CuesTest do
  # Each part here is a stand-in process that tells the test every cue it is handed.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Cues

  alias CodingAgentFramework.Cues

  defp stand_in(key) do
    test = self()

    spawn_link(fn ->
      receive_loop = fn loop ->
        receive do
          {:cued, cue} -> send(test, {:cued, key, cue})
        end

        loop.(loop)
      end

      receive_loop.(receive_loop)
    end)
  end

  defp part(topics), do: %{topics: topics, cue: &send(&1, {:cued, &2})}

  # Cues casts to each part in the order of the cues it got, so a last cue to every part tells
  # the test that every earlier one was handed on.
  defp drained(cues, keys) do
    Cues.cue(cues, %{topic: "last"})
    for key <- keys, do: assert_receive({:cued, ^key, %{topic: "last"}})
  end

  test "each cue reaches every part that declared its topic, and no other" do
    parts = [
      sessions: part(["registry", "stream", "last"]),
      mailbox: part(["stream", "intake:*:*:waiters", "last"]),
      tracker: part(:all)
    ]

    {:ok, cues} = start_supervised({Cues, parts: parts})
    for key <- Keyword.keys(parts), do: Cues.started(cues, key, stand_in(key))

    Cues.cue(cues, %{topic: "stream:ws", ids: [1]})
    Cues.cue(cues, %{topic: "intake:ws:work:waiters", ids: ["s1"]})
    Cues.cue(cues, %{topic: "intake:ws:work", ids: [2]})
    Cues.cue(cues, %{topic: "registryx:ws", ids: [3]})
    Cues.cue(cues, :not_a_cue)
    drained(cues, Keyword.keys(parts))

    got = collect([])

    assert Enum.sort(got) ==
             Enum.sort([
               {:sessions, "stream:ws"},
               {:mailbox, "stream:ws"},
               {:tracker, "stream:ws"},
               {:mailbox, "intake:ws:work:waiters"},
               {:tracker, "intake:ws:work:waiters"},
               {:tracker, "intake:ws:work"},
               {:tracker, "registryx:ws"}
             ])
  end

  test "a restarted part gets the cues from its new process on; one not started gets none" do
    parts = [sessions: part(["stream", "last"]), mailbox: part(["stream"])]
    {:ok, cues} = start_supervised({Cues, parts: parts})
    old = stand_in(:old)
    Cues.started(cues, :sessions, old)
    Cues.started(cues, :sessions, stand_in(:sessions))

    Cues.cue(cues, %{topic: "stream:ws", ids: [1]})
    drained(cues, [:sessions])

    assert collect([]) == [{:sessions, "stream:ws"}]
  end

  test "a part whose cue raises does not stop the others" do
    parts = [bad: %{topics: :all, cue: fn _, _ -> raise "no" end}, good: part(:all)]
    {:ok, cues} = start_supervised({Cues, parts: parts})
    Cues.started(cues, :bad, stand_in(:bad))
    Cues.started(cues, :good, stand_in(:good))

    ExUnit.CaptureLog.capture_log(fn ->
      Cues.cue(cues, %{topic: "stream:ws", ids: []})
      drained(cues, [:good])
    end)

    assert Process.alive?(cues)
    assert collect([]) == [{:good, "stream:ws"}]
  end

  test "a cue to no router is dropped" do
    assert Cues.cue(nil, %{topic: "stream:ws"}) == :ok
  end

  defp collect(acc) do
    receive do
      {:cued, _key, %{topic: "last"}} -> collect(acc)
      {:cued, key, %{topic: topic}} -> collect([{key, topic} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
