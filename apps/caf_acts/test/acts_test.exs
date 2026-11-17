defmodule CodingAgentFramework.ActsTest do
  @moduledoc """
  `Acts` on a SQLite file in the test's own directory: one claim per state under the unique
  index, a restart's interrupt, the fault ledger, the cue, and the rows it takes from the two
  tables it replaced.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Acts, Store}
  alias CodingAgentFramework.Acts.Table

  doctest Acts
  doctest Table

  setup do
    dir = test_dir()
    me = self()
    opts = [db: Path.join(dir, "acts.db"), host: "h", instance: "i", notify: &send(me, &1)]
    {:ok, dir: dir, opts: opts, acts: start!(opts, "s1")}
  end

  defp start!(opts, start_id) do
    {:ok, acts} = Acts.start_link([start_id: start_id] ++ opts)
    acts
  end

  defp status(acts, id), do: elem(Acts.get(acts, id), 1).status

  test "one claim per state, whoever the actor and the act", %{acts: acts} do
    assert {:ok, a} = Acts.claim(acts, "app-main", "app-a", {:stuck, 1}, :interrupt)
    assert_received %{topic: "acts:h:i", ids: [^a]}

    assert Acts.claim(acts, "operator", "app-a", {:stuck, 1}, :resume) ==
             {:refused, {:claimed, "app-main"}}

    assert {:ok, b} = Acts.claim(acts, "app-main", "app-a", {:stuck, 2}, :interrupt)
    assert {:ok, c} = Acts.claim(acts, "app-main", "app-b", {:stuck, 1}, :interrupt)

    assert {:ok, [%{id: ^a, state: ~s(["stuck",1]), act: "interrupt"}, %{id: ^b}, %{id: ^c}]} =
             Acts.rows(acts)

    # A state stays claimed whatever its claim's end.
    assert {:ok, :not_verified} = Acts.settle(acts, a, :not_verified, answer: {:ok, :sent})

    assert Acts.claim(acts, "operator", "app-a", {:stuck, 1}, :resume) ==
             {:refused, {:already_claimed, "app-main"}}

    assert {:ok, %{outcome: "not_verified", answer: ~s(["ok","sent"])}} = Acts.get(acts, a)
    assert Acts.settle(acts, a, :verified) == {:refused, {:not_open, :settled}}
    assert Acts.settle(acts, 999, :verified) == {:refused, :unknown_act}
  end

  test "an act whose outcome waits, settled later with the act's time kept", %{acts: acts} do
    {:ok, id} = Acts.claim(acts, "recoveries:h:s", "alpha", "k1", :reopen)
    assert {:ok, :acted} = Acts.acted(acts, id, answer: "ok", detail: "%3")
    assert Acts.acted(acts, id) == {:refused, {:not_claimed, :acted}}
    {:ok, %{acted_at: at}} = Acts.get(acts, id)
    assert {:ok, :recovered} = Acts.settle(acts, id, :recovered, acted: true)

    assert {:ok, %{status: "settled", acted_at: ^at, detail: "%3", reason: nil}} =
             Acts.get(acts, id)
  end

  test "a skipped state is taken over by its claim, and keeps no claim of its own", %{acts: acts} do
    {:ok, id} = Acts.skip(acts, "r", "alpha", "k1", :reopen, {:sample_too_old, 40})
    assert {:ok, ^id} = Acts.skip(acts, "r", "alpha", "k1", :reopen, {:sample_too_old, 50})
    assert {:ok, %{status: "skipped", reason: ~s(["sample_too_old",50])}} = Acts.get(acts, id)
    assert {:ok, ^id} = Acts.claim(acts, "r", "alpha", "k1", :reopen)
    assert {:ok, %{status: "claimed", reason: nil}} = Acts.get(acts, id)
    assert Acts.skip(acts, "r", "alpha", "k1", :reopen, :late) == {:refused, {:claimed, "r"}}
  end

  test "a restart closes another start's open claims as interrupted, never this start's", ctx do
    {:ok, open} = Acts.claim(ctx.acts, "app-main", "app-a", 1, :interrupt)
    {:ok, done} = Acts.claim(ctx.acts, "app-main", "app-b", 1, :interrupt)
    {:ok, :verified} = Acts.settle(ctx.acts, done, :verified)

    # A second open in the same start closes nothing live.
    again = start!(ctx.opts, "s1")
    assert status(again, open) == "claimed"

    restarted = start!(ctx.opts, "s2")
    assert {status(restarted, open), status(restarted, done)} == {"interrupted", "settled"}

    assert Acts.claim(restarted, "app-main", "app-a", 1, :interrupt) ==
             {:refused, {:already_claimed, "app-main"}}

    assert Acts.settle(restarted, open, :verified) == {:refused, {:not_open, :interrupted}}
    assert {:ok, [%{id: ^open}]} = Acts.faults(restarted)
  end

  test "an actor that restarts closes its own claims; a person clears what waits", %{acts: acts} do
    {:ok, mine} = Acts.claim(acts, "r1", "alpha", "k1", :reopen)
    {:ok, other} = Acts.claim(acts, "r2", "alpha", "k2", :reopen)
    assert {:ok, [^mine]} = Acts.interrupt(acts, "r1")
    assert {status(acts, mine), status(acts, other)} == {"interrupted", "claimed"}

    assert {:ok, [^mine]} = Acts.clear(acts, [mine, other])
    assert {:ok, []} = Acts.clear(acts, [mine])
    assert {:ok, %{cleared_at: at}} = Acts.get(acts, mine)
    assert is_integer(at)
  end

  test "a record takes no claim; the fault ledger is a query of the rows", %{acts: acts} do
    {:ok, a} = Acts.record(acts, "app-main", "app-a", :start, :recovered)
    {:ok, b} = Acts.record(acts, "app-main", "app-a", :start, :failed, reason: {:exit, 1})
    {:ok, c} = Acts.claim(acts, "app-main", "app-a", 3, :resume)
    {:ok, :unknown} = Acts.settle(acts, c, :unknown, reason: :timeout)

    assert {:ok, [%{id: ^a, state: nil}, %{id: ^b}, %{id: ^c}]} = Acts.rows(acts, target: "app-a")
    assert {:ok, [%{id: ^b, reason: ~s(["exit",1])}, %{id: ^c}]} = Acts.faults(acts)
    assert {:ok, [%{id: ^c}]} = Acts.faults(acts, act: [:resume, "end"])
    assert Acts.rows(acts, owner: "x") == {:refused, {:no_column, :owner}}
  end

  test "an answer that does not come is unknown, and a missing Acts refused", %{acts: acts} do
    :sys.suspend(acts)
    assert {:unknown, {:timeout, 50}} = Acts.rows(acts, [], timeout: 50)
    :sys.resume(acts)
    GenServer.stop(acts)
    assert {:refused, :no_acts} = Acts.rows(acts)
  end

  test "F-126: the rows of the recoveries and claims tables are taken once, converted", ctx do
    path = Path.join(ctx.dir, "old.db")
    claims = Path.join(ctx.dir, "claims.db")
    write_recoveries!(path)
    write_claims!(claims)

    acts = start!([db: path, claims: claims, host: "h", instance: "i"], "s9")
    {:ok, rows} = Acts.rows(acts)

    assert [
             %{actor: "recoveries:ws:t", target: "alpha", state: "ws:t:lost_viewer:alpha:0:7"} =
               failed,
             %{target: "alpha", status: "interrupted", reason: nil},
             %{act: "end", status: "acted", answer: "ok", detail: "%2"},
             %{status: "skipped", reason: ~s(["sample_too_old",31001])},
             %{actor: "app-main", target: "app-a", act: "fix", status: "settled"} = fix,
             %{target: "service:app-b", status: "interrupted"}
           ] = rows

    assert %{status: "settled", outcome: "failed", reason: "repeating", cleared_at: nil} = failed
    assert fix.state == Store.text(%{epoch: 2, held: ["r"]}) and fix.outcome == "not_verified"

    # A state claimed before stays claimed.
    assert Acts.claim(acts, "operator", "app-a", %{held: ["r"], epoch: 2}, :interrupt) ==
             {:refused, {:already_claimed, "app-main"}}

    # Both old tables are gone, so a second start takes nothing again.
    {:ok, db} = Store.open(path, "")
    assert Store.query(db, "SELECT name FROM sqlite_master WHERE name = 'recoveries'", []) == []
    {:ok, old} = Store.open(claims, "")
    assert Store.query(old, "SELECT name FROM sqlite_master WHERE name = 'claims'", []) == []
    GenServer.stop(acts)
    acts = start!([db: path, claims: claims, host: "h", instance: "i"], "s10")
    assert {:ok, ^rows} = Acts.rows(acts)
  end

  # The recoveries table as F-118 left it, with its `inspect` reasons.
  defp write_recoveries!(path) do
    {:ok, db} =
      Store.open(path, """
      CREATE TABLE recoveries (
        id INTEGER PRIMARY KEY, host TEXT NOT NULL, server TEXT NOT NULL, key TEXT NOT NULL,
        kind TEXT NOT NULL, socket TEXT NOT NULL, generation INTEGER, since INTEGER,
        status TEXT NOT NULL, reason TEXT, pane TEXT, open TEXT,
        claimed_at INTEGER NOT NULL, opened_at INTEGER, ended_at INTEGER, cleared_at INTEGER,
        UNIQUE (host, server, key));
      """)

    for {key, kind, status, reason, pane, open} <- [
          {"lost_viewer:alpha:0:7", "lost_viewer", "failed", ":repeating", nil, nil},
          {"lost_viewer:alpha:0:9", "lost_viewer", "unknown", ":interrupted", nil, nil},
          {"end:alpha:42:Tue", "end", "opened", nil, "%2", "ok"},
          {"lost_viewer:beta:0:3", "lost_viewer", "skipped", "{:sample_too_old, 31001}", nil, nil}
        ] do
      Store.insert(db, "recoveries",
        host: "ws",
        server: "t",
        key: key,
        kind: kind,
        socket: if(key =~ "beta", do: "beta", else: "alpha"),
        status: status,
        reason: reason,
        pane: pane,
        open: open,
        claimed_at: 5
      )
    end
  end

  # The claims table as F-119 left it, with its terms stored as Erlang's external format.
  defp write_claims!(path) do
    {:ok, db} =
      Store.open(path, """
      CREATE TABLE claims (
        id INTEGER PRIMARY KEY, caller TEXT NOT NULL, target BLOB NOT NULL, state BLOB NOT NULL,
        start_id TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL);
      """)

    for {target, state, status} <- [
          {"app-a", %{held: ["r"], epoch: 2}, "not_verified"},
          {{:service, "app-b"}, 1, "claimed"}
        ] do
      Store.insert(db, "claims",
        caller: "app-main",
        target: {:blob, :erlang.term_to_binary(target)},
        state: {:blob, :erlang.term_to_binary(state)},
        start_id: "s0",
        status: status,
        created_at: 1,
        updated_at: 2
      )
    end
  end
end
