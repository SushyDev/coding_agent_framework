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

  describe "the app's subscribers" do
    # A subscriber gets cues after the parts in the order of the cues, so a last cue it gets
    # tells the test that every earlier one was handed on.
    defp subscribed(cues, parts, topics) do
      {:ok, ref} = Cues.subscribe(cues, self(), topics ++ ["last"])
      for {key, _} <- parts, do: Cues.started(cues, key, stand_in(key))
      ref
    end

    defp got_until_last(acc) do
      receive do
        {:caf_cue, %{topic: "last"}} -> Enum.reverse(acc)
        {:caf_cue, %{topic: topic}} -> got_until_last([topic | acc])
      after
        5_000 -> flunk("no last cue; got #{inspect(acc)}")
      end
    end

    test "a subscriber gets each cue of its topics, after the parts, and no other" do
      parts = [sessions: part(["sessions", "intake:*:*:waiters", "last"])]
      {:ok, cues} = start_supervised({Cues, parts: parts})
      subscribed(cues, parts, ["sessions:", "intake:ws:work:waiters"])

      Cues.cue(cues, %{topic: "sessions:ws", ids: [1]})
      Cues.cue(cues, %{topic: "stream:ws", ids: [2]})
      Cues.cue(cues, %{topic: "intake:ws:work:waiters", ids: ["s1"]})
      Cues.cue(cues, %{topic: "intake:ws:home:waiters", ids: ["s2"]})
      Cues.cue(cues, %{topic: "last"})

      assert got_until_last([]) == ["sessions:ws", "intake:ws:work:waiters"]
    end

    test "a topic no part declares, or no list of topics, is refused" do
      {:ok, cues} = start_supervised({Cues, parts: [a: part(["sessions"]), t: part(:all)]})
      assert Cues.subscribe(cues, self(), ["acts"]) == {:refused, {:undeclared, "acts"}}
      assert Cues.subscribe(cues, self(), ["sessions", "*"]) == {:refused, {:undeclared, "*"}}
      assert Cues.subscribe(cues, self(), []) == {:refused, {:bad, :topics}}
      assert Cues.subscribe(cues, self(), "sessions") == {:refused, {:bad, :topics}}
      assert Cues.subscribe(cues, self(), ["sessions::ws"]) == {:refused, {:bad, :topics}}
      assert Cues.subscriptions(cues) == {:ok, []}
    end

    test "a subscriber that exits is removed; one that crashes touches nothing" do
      parts = [a: part(["sessions", "last"])]
      {:ok, cues} = start_supervised({Cues, parts: parts})
      test = self()

      sub =
        spawn(fn ->
          {:ok, _} = Cues.subscribe(cues, self(), ["sessions"])
          send(test, :subscribed)
          receive do: ({:caf_cue, _} -> exit(:crash))
        end)

      assert_receive :subscribed
      ref = Process.monitor(sub)
      Cues.cue(cues, %{topic: "sessions:ws", ids: [1]})
      assert_receive {:DOWN, ^ref, :process, ^sub, :crash}

      assert {:ok, []} =
               await(fn ->
                 with {:ok, [_ | _]} <- Cues.subscriptions(cues), do: :waiting
               end)

      assert Process.alive?(cues)
    end

    test "unsubscribe ends a subscription; a ref it does not hold is refused" do
      parts = [a: part(["sessions", "last"])]
      {:ok, cues} = start_supervised({Cues, parts: parts})
      ref = subscribed(cues, parts, ["sessions"])
      assert Cues.unsubscribe(cues, ref) == :ok
      assert Cues.unsubscribe(cues, ref) == {:refused, :no_subscription}
      {:ok, last} = Cues.subscribe(cues, self(), ["last"])

      Cues.cue(cues, %{topic: "sessions:ws", ids: [1]})
      Cues.cue(cues, %{topic: "last"})
      assert got_until_last([]) == []
      assert Cues.unsubscribe(cues, last) == :ok
    end

    test "a restarted Cues keeps the subscriptions its starter's table holds" do
      parts = [a: part(["sessions", "last"])]
      table = :ets.new(:subs, [:public])
      {:ok, cues} = start_supervised({Cues, parts: parts, subscriptions: table})
      subscribed(cues, parts, ["sessions"])

      # A subscriber that exits while no `Cues` runs is removed when the next one starts.
      gone = spawn(fn -> receive do: (:never -> :ok) end)
      {:ok, _} = Cues.subscribe(cues, gone, ["sessions"])
      :ok = stop_supervised(Cues)
      Process.exit(gone, :kill)

      {:ok, cues} = start_supervised({Cues, parts: parts, subscriptions: table})
      Cues.cue(cues, %{topic: "sessions:ws", ids: [1]})
      Cues.cue(cues, %{topic: "last"})
      assert got_until_last([]) == ["sessions:ws"]
      me = self()

      assert {:ok, [{_, ^me, _}]} =
               await(fn ->
                 with {:ok, [_, _]} <- Cues.subscriptions(cues), do: :waiting
               end)
    end
  end

  # The state a `:DOWN` changes, read until `check` answers it settled.
  defp await(check, tries \\ 100) do
    case check.() do
      :waiting when tries > 0 ->
        receive after: (10 -> await(check, tries - 1))

      other ->
        other
    end
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
