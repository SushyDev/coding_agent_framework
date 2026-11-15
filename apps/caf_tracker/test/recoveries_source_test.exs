defmodule CodingAgentFramework.RecoveriesSourceTest do
  @moduledoc """
  `RecoveriesSource` reads the rows `Recoveries` writes into a `Tracker`, on a real tmux server
  and real dtach sockets in this test's own directory, with `cat` held as the agent's stand-in.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.RecoveriesSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Recoveries, RecoveriesSetup, Tmux, Tracker}

  setup {RecoveriesSetup, :recoveries}

  test "a killed viewer is reopened once and verified", ctx do
    {child, _} = hold!(ctx, "alpha")
    {:ok, viewer} = view(ctx, "alpha")
    # A pane of another session keeps the server up when the viewer goes.
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    assert held(ctx, "alpha").status == :viewed
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)

    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, viewer, "alpha")
    assert {:ok, id} = agree(ctx, "alpha")
    assert_received {:cue, %{topic: "recoveries:test:" <> _, ids: [^id]}}
    # The same reading again claims nothing: it was read before the open.
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert [%{status: "opened", open: "ok", pane: pane}] = rows(ctx)
    assert pane != viewer

    assert held(ctx, "alpha").status == :viewed
    assert {:ok, %{claimed: [], ended: [^id]}} = Recoveries.check(ctx.recoveries)
    assert {:ok, %{claimed: [], ended: []}} = Recoveries.check(ctx.recoveries)
    assert [%{status: "recovered", key: "lost_viewer:alpha:" <> _}] = rows(ctx)
    assert alive?(child)

    # A second loss of the same agent is a new state, named from the sample where its row
    # turned unviewed again: after the reopen.
    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, pane, "alpha")
    assert {:ok, second} = agree(ctx, "alpha")
    assert second != id
    [first, %{since: since}] = rows(ctx)
    assert since > first.opened_at

    {:ok, tracker} =
      Tracker.start_link(
        sources: [{Tracker.RecoveriesSource, db: ctx.db, host: "test", server: key(ctx)}],
        timer: false
      )

    {:ok, view} = Tracker.view(tracker)
    assert %{recoveries: [_, _]} = view[{"test", "tmux:" <> key(ctx)}]
  end
end
