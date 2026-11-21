defmodule CodingAgentFramework.SubscribeTest do
  # Two whole trees in this test VM, each under its own home with its own tmux server, ports
  # and instance name, and the app's processes subscribed to each by its name.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Config, Cues, HeadlessStandIn, Tmux}

  setup do
    dir = test_dir()
    # Names of this test's own, so another test's instances in this VM never meet them.
    n = System.unique_integer([:positive])
    %{dir: dir, a: config(dir, "sub-a-#{n}"), b: config(dir, "sub-b-#{n}")}
  end

  defp config(dir, instance) do
    home = Path.join(dir, instance)

    {:ok, c} =
      Config.new(
        home: home,
        instance: instance,
        programs: programs().paths,
        accounts: ["work"],
        ports: %{intake: free_port(), mcp: free_port()},
        claude: HeadlessStandIn.write!(dir, :on_message),
        env: %{home: dir, path: "/nonexistent", term: "xterm-256color", lang: "C.UTF-8"},
        user: "tester",
        interval: 200,
        undeclared_cues: :raise
      )

    File.mkdir_p!(home)
    {:ok, server} = CodingAgentFramework.server(c)
    on_exit(fn -> Tmux.kill_server(server) end)
    c
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start(c), do: CodingAgentFramework.parts(start_supervised!({CodingAgentFramework, c}))

  # An app's process: it subscribes to `topics` of `instance`, and hands the test each cue it
  # gets as `{tag, topic}`.
  defp subscriber(instance, topics, tag) do
    test = self()

    pid =
      spawn_link(fn ->
        send(test, {tag, :subscribed, CodingAgentFramework.subscribe(instance, topics)})
        relay(test, tag)
      end)

    assert_receive {^tag, :subscribed, {:ok, %{ref: ref}}}
    {pid, ref}
  end

  defp relay(test, tag) do
    receive do
      {:caf_cue, %{topic: topic}} -> send(test, {tag, topic})
    end

    relay(test, tag)
  end

  test "two instances in one VM each deliver only their own cues", ctx do
    {a, b} = {start(ctx.a), start(ctx.b)}
    subscriber(ctx.a.instance, ["sessions"], :a)
    subscriber(ctx.b.instance, ["sessions"], :b)

    # Each tree's own `Cues`, as its parts' writes reach it. A subscriber gets cues in the order
    # its instance's `Cues` got them, so its `end` cue says every earlier one was handed on.
    for {parts, name} <- [{a, "a"}, {b, "b"}] do
      Cues.cue(parts.cues, %{topic: "sessions:probe-" <> name, ids: [1]})
      Cues.cue(parts.cues, %{topic: "sessions:end-" <> name, ids: []})
    end

    assert_receive {:a, "sessions:end-a"}
    assert_receive {:b, "sessions:end-b"}
    assert_received {:a, "sessions:probe-a"}
    assert_received {:b, "sessions:probe-b"}
    refute_received {:a, "sessions:" <> "probe-b"}
    refute_received {:a, "sessions:end-b"}
    refute_received {:b, "sessions:probe-a"}
    refute_received {:b, "sessions:end-a"}
  end

  test "a subscriber that exits is removed, and the tree runs on", ctx do
    sup = start_supervised!({CodingAgentFramework, ctx.a})
    parts = CodingAgentFramework.parts(sup)
    {pid, _ref} = subscriber(ctx.a.instance, ["mailbox"], :gone)
    {_kept, kept} = subscriber(ctx.a.instance, ["mailbox"], :kept)

    Process.unlink(pid)
    Process.exit(pid, :kill)

    assert {:ok, [{^kept, _, ["mailbox"]}]} =
             await(fn ->
               with {:ok, [_, _]} <- Cues.subscriptions(parts.cues), do: :waiting
             end)

    # The tree did not notice: every part still runs in the process it started in.
    assert CodingAgentFramework.parts(sup) == parts
  end

  test "a topic no part declares is refused; the declared ones are listed", ctx do
    start(ctx.a)
    i = ctx.a.instance
    assert {:ok, topics} = CodingAgentFramework.topics(i)
    assert "sessions" in topics and "intake:*:*:waiters" in topics

    # Every topic a part writes, the ones no part reads among them (F-174's new-1).
    for topic <- ~w(acts:*:* intake:*:* scheduler:* services copies prompts),
        do: assert(topic in topics, topic)

    assert {:ok, %{ref: _}} = CodingAgentFramework.subscribe(i, ["acts", "scheduler:ws"])

    assert CodingAgentFramework.subscribe(i, ["inbox"]) == {:refused, {:undeclared, "inbox"}}

    assert CodingAgentFramework.subscribe(i, []) == {:refused, {:bad, :topics}}

    assert CodingAgentFramework.subscribe("no-such-instance", ["sessions"]) ==
             {:refused, :no_instance}

    assert CodingAgentFramework.topics("no-such-instance") == {:refused, :no_instance}

    {:ok, %{ref: ref}} = CodingAgentFramework.subscribe(i, ["sessions:"])
    assert CodingAgentFramework.unsubscribe(i, ref) == :ok
    assert CodingAgentFramework.unsubscribe(i, ref) == {:refused, :no_subscription}

    # A second instance of the name is refused before it makes anything.
    assert CodingAgentFramework.start_link(ctx.a) == {:refused, {:instance_running, i}}
  end

  # F-174's new-2: the subscriptions live and die with the tree, whose supervisor `subscribe/2`
  # names, and the app subscribes again once the tree is back.
  test "a subscription ends with its tree, which the app watches and subscribes to again", ctx do
    sup = start_supervised!({CodingAgentFramework, ctx.a})
    i = ctx.a.instance
    assert {:ok, %{tree: ^sup}} = CodingAgentFramework.subscribe(i, ["sessions"])
    tree = Process.monitor(sup)

    :ok = Supervisor.stop(sup)
    assert_receive {:DOWN, ^tree, :process, ^sup, _}

    # The test's supervisor starts the tree again: it holds no subscription of the old one's.
    {:ok, %{tree: again, ref: ref}} =
      await(fn -> CodingAgentFramework.subscribe(i, ["sessions"]) end, 20_000)

    assert again != sup
    me = self()
    parts = CodingAgentFramework.parts(again)
    assert {:ok, [{^ref, ^me, ["sessions"]}]} = Cues.subscriptions(parts.cues)

    Cues.cue(parts.cues, %{topic: "sessions:back", ids: [1]})
    assert_receive {:caf_cue, %{topic: "sessions:back"}}
  end
end
