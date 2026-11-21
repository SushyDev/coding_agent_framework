defmodule CodingAgentFramework.WatchTest do
  @moduledoc """
  The symptom record and the allow-list on a real SQLite file in this test's own directory.
  Each write's cue comes to the test as `{:cue, cue}`.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Watch
  alias CodingAgentFramework.Watch.Table

  doctest Watch
  doctest Table

  @remedies %{
    "lost_viewer" => %{remedy: "reopen", cap: 2},
    "mcp_dropped" => %{remedy: nil, cap: 0}
  }

  setup do
    db = Path.join(test_dir(), "watch.db")
    me = self()
    {:ok, watch} = Watch.start_link(db: db, remedies: @remedies, notify: &send(me, {:cue, &1}))
    {:ok, db: db, watch: watch}
  end

  defp symptom(state, kind \\ "lost_viewer"),
    do: %{
      kind: kind,
      target: "alpha",
      state: state,
      source: "healer",
      since: 1,
      evidence: %{n: 1}
    }

  test "a state is recorded once, cued, and read by its fields", ctx do
    assert {:ok, %{id: id, status: "open"}} = Watch.record(ctx.watch, symptom("k1"))
    assert_receive {:cue, %{topic: "watch", ids: [^id]}}
    assert {:ok, %{id: ^id}} = Watch.record(ctx.watch, symptom("k1"))
    refute_receive {:cue, _}, 50

    assert {:ok, [%{id: ^id, evidence: ~s({"n":1}), status: "open"}]} =
             Watch.read(ctx.watch, kind: "lost_viewer", status: ["open", "asked"])

    assert {:refused, {:unknown_kind, "stuck"}} = Watch.record(ctx.watch, symptom("k1", "stuck"))
    assert {:refused, {:bad, :symptom}} = Watch.record(ctx.watch, %{kind: "lost_viewer"})
    assert {:refused, {:bad, :filter}} = Watch.read(ctx.watch, color: "red")
  end

  test "a state is asked once, and its prompt answered once", ctx do
    {:ok, %{id: id}} = Watch.record(ctx.watch, symptom("k1"))
    assert {:ok, ^id} = Watch.ask(ctx.watch, symptom("k1"), {:outcome, :unknown})
    assert {:refused, {:status, "asked"}} = Watch.ask(ctx.watch, symptom("k1"), :again)

    assert [%{id: ^id, remedy: "reopen", reason: ~s(["outcome","unknown"])}] =
             Table.asked(open!(ctx))

    assert {:refused, {:bad, :choice}} = Watch.answer(ctx.watch, id, "act", "sam")
    assert {:ok, :answered} = Watch.answer(ctx.watch, id, "leave", "sam")
    assert {:refused, :settled} = Watch.answer(ctx.watch, id, "approve", "sam")
    assert Table.asked(open!(ctx)) == []
    assert {:refused, :no_symptom} = Watch.ask(ctx.watch, symptom("k9"), :why)
  end

  test "a kind with no remedy is shown and never asked", ctx do
    {:ok, _} = Watch.record(ctx.watch, symptom("k1", "mcp_dropped"))

    assert {:refused, {:no_remedy, "mcp_dropped"}} =
             Watch.ask(ctx.watch, symptom("k1", "mcp_dropped"), :why)

    assert {:ok, %{"mcp_dropped" => %{allowed: false}}} = Watch.remedies(ctx.watch, :list)

    assert {:refused, {:no_remedy, "mcp_dropped"}} =
             Watch.remedies(ctx.watch, {:approve, "mcp_dropped", "sam"})
  end

  test "the list narrows by the healer, widens by the operator, and a restart keeps it", ctx do
    assert {:ok, %{"lost_viewer" => %{allowed: true, cap: 2, last: nil}}} =
             Watch.remedies(ctx.watch, :list)

    assert {:ok, false} = Watch.remedies(ctx.watch, {:drop, "lost_viewer", :not_viewed})

    # A restart reads the list as it was left, not the config's again.
    GenServer.stop(ctx.watch)
    {:ok, watch} = Watch.start_link(db: ctx.db, remedies: @remedies)

    assert {:ok, %{"lost_viewer" => %{allowed: false, last: %{act: "drop", by: "healer"}}}} =
             Watch.remedies(watch, :list)

    # The person's approve, through the remedy prompt, puts it back.
    {:ok, %{id: id}} = Watch.record(watch, symptom("k1"))
    {:ok, ^id} = Watch.ask(watch, symptom("k1"), :not_on_list)
    assert {:ok, :answered} = Watch.answer(watch, id, "approve", "sam")

    assert {:ok, %{"lost_viewer" => %{allowed: true, last: %{act: "approve", by: "sam"}}}} =
             Watch.remedies(watch, :list)

    assert {:ok, false} = Watch.remedies(watch, {:revoke, "lost_viewer", "sam"})
    assert {:refused, {:bad, :by}} = Watch.remedies(watch, {:approve, "lost_viewer", "healer"})
    assert {:refused, {:unknown_kind, "x"}} = Watch.remedies(watch, {:approve, "x", "sam"})
  end

  test "states no longer read pass, their prompts with them", ctx do
    {:ok, %{id: a}} = Watch.record(ctx.watch, symptom("k1"))
    {:ok, %{id: b}} = Watch.record(ctx.watch, symptom("k2"))
    {:ok, ^b} = Watch.ask(ctx.watch, symptom("k2"), :why)
    lv = {"healer", "lost_viewer"}
    # The open state no longer read passes; the asked one stays while its target shows the kind.
    assert {:ok, [^a]} = Watch.pass(ctx.watch, lv, %{targets: ["alpha"], states: ["k3"]})
    assert {:ok, [^b]} = Watch.pass(ctx.watch, lv, %{targets: [], states: []})
    assert {:ok, []} = Watch.pass(ctx.watch, lv, %{targets: [], states: []})
    assert Table.asked(open!(ctx)) == []
    assert {:ok, [%{status: "passed"}, %{status: "passed"}]} = Watch.read(ctx.watch)
  end

  defp open!(ctx) do
    {:ok, db} = Table.open(ctx.db)
    db
  end
end
