defmodule CodingAgentFramework.ActsSourceTest do
  @moduledoc """
  `Acts`' table read into a `Tracker` by the source made from its metadata (`Acts.Table.meta/0`),
  with the rows `Recoveries` writes on a real tmux server and real dtach sockets in this test's
  own directory, `cat` held as the agent's stand-in, and an operator's claim beside them.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.RecoveriesSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Acts, Recoveries, RecoveriesSetup, Tmux, Tracker}

  setup {RecoveriesSetup, :recoveries}

  test "a killed viewer is reopened once and verified, and the Tracker reads the ledger", ctx do
    {child, _} = hold!(ctx, "alpha")
    {:ok, viewer} = view(ctx, "alpha")
    # A pane of another session keeps the server up when the viewer goes.
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    assert held(ctx, "alpha").status == :viewed
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)

    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, viewer, "alpha")
    assert {:ok, id} = agree(ctx, "alpha")
    assert_received {:cue, %{topic: "acts:test:a", ids: [^id]}}
    # The same reading again claims nothing: it was read before the open.
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert [%{status: "acted", answer: "ok", detail: pane}] = rows(ctx)
    assert pane != viewer

    assert held(ctx, "alpha").status == :viewed
    assert {:ok, %{claimed: [], ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert [%{outcome: "recovered", act: "reopen", state: state}] = rows(ctx)
    assert state =~ ":lost_viewer:alpha:"
    assert alive?(child)

    # A second loss of the same agent is a new state, named from the sample where its row
    # turned unviewed again: after the reopen.
    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, pane, "alpha")
    assert {:ok, second} = agree(ctx, "alpha")
    assert second != id
    [first, %{state: again}] = rows(ctx)
    [since | _] = again |> String.split(":") |> Enum.reverse()
    assert String.to_integer(since) > first.acted_at

    {:ok, tracker} =
      Tracker.start_link(
        sources: [
          {Tracker.TableSource, table: Acts.Table, db: ctx.db, host: "test", instance: "a"}
        ],
        timer: false
      )

    {:ok, view} = Tracker.view(tracker)
    assert %{acts: [_, _]} = view[{"test", "acts:a"}]

    # The operator's claim is a row of the same ledger, and its cue reaches the view.
    {:ok, claim} = Acts.claim(ctx.acts, "operator", "alpha", %{epoch: 1}, :interrupt)
    assert_received {:cue, %{topic: "acts:test:a", ids: [^claim]} = cue}
    Tracker.cue(tracker, cue)
    {:ok, view} = Tracker.view(tracker)

    assert %{acts: [_, _, %{row: %{actor: "operator", state: ~s({"epoch":1})}}]} =
             view[{"test", "acts:a"}]
  end
end
