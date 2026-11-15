defmodule CodingAgentFramework.Grants.ClaimsTest do
  # Each test is named for the invariant of model/tla/Team.tla it checks.
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Grants
  alias CodingAgentFramework.Grants.Claims

  doctest Claims

  @tree [
    %{name: "app-a", project: "app", parent: "app-main"},
    %{name: "app-b", project: "app", parent: "app-main"}
  ]

  setup do
    path = Path.join(CodingAgentFramework.TestHost.test_dir(), "claims.db")
    %{path: path, grants: Grants.new(fn -> @tree end)}
  end

  defp open(ctx, start_id) do
    {:ok, claims} = Claims.start_link(path: ctx.path, grants: ctx.grants, start_id: start_id)
    claims
  end

  defp status(claims, id), do: elem(Claims.get(claims, id), 1).status

  test "OneClaimPerState: a second open claim on one target and state is refused", ctx do
    claims = open(ctx, "s1")
    {:ok, _} = Claims.claim(claims, "app-main", "app-a", {:stuck, 1}, "s1")

    assert {:refused, {:claimed, "app-main"}} =
             Claims.claim(claims, "app-main", "app-a", {:stuck, 1}, "s1")

    assert {:ok, [_only]} = Claims.rows(claims)
  end

  test "OneClaimPerState: another state or another target is a distinct claim", ctx do
    claims = open(ctx, "s1")
    {:ok, a} = Claims.claim(claims, "app-main", "app-a", 1, "s1")
    assert {:ok, b} = Claims.claim(claims, "app-main", "app-a", 2, "s1")
    assert {:ok, c} = Claims.claim(claims, "app-main", "app-b", 1, "s1")
    assert length(Enum.uniq([a, b, c])) == 3
  end

  test "ClaimTaken: a settled claim keeps its state from a second fix; a new state is free",
       ctx do
    claims = open(ctx, "s1")
    {:ok, first} = Claims.claim(claims, "app-main", "app-a", 1, "s1")
    assert {:ok, :not_verified} = Claims.settle(claims, first, :not_verified)

    assert {:refused, {:already_claimed, "app-main"}} =
             Claims.claim(claims, "app-main", "app-a", 1, "s1")

    assert {:ok, second} = Claims.claim(claims, "app-main", "app-a", 2, "s1")
    assert second != first
    assert status(claims, first) == "not_verified"
  end

  test "a service target is checked by the service's fix check and held per state", ctx do
    claims = open(ctx, "s1")
    state = {:held, 0}
    assert {:ok, _} = Claims.claim(claims, "app-main", {:service, "app-a"}, state, "s1")

    assert {:refused, {:claimed, "app-main"}} =
             Claims.claim(claims, "app-main", {:service, "app-a"}, state, "s1")

    assert {:refused, :service_fixed_by_owner_or_parent} =
             Claims.claim(claims, "app-b", {:service, "app-a"}, state, "s1")
  end

  test "MayFix: a refused check writes no row", ctx do
    claims = open(ctx, "s1")
    assert {:refused, :no_self_fix} = Claims.claim(claims, "app-a", "app-a", 1, "s1")
    assert {:refused, :main_never_fixed} = Claims.claim(claims, "app-a", "app-main", 1, "s1")
    assert {:refused, :only_parent_fixes} = Claims.claim(claims, "app-a", "app-b", 1, "s1")

    assert {:refused, {:unknown_agent, "ghost"}} =
             Claims.claim(claims, "app-main", "ghost", 1, "s1")

    assert {:ok, []} = Claims.rows(claims)
  end

  test "ClaimSettled: a restart closes the old start's open rows as interrupted", ctx do
    old = open(ctx, "s1")
    {:ok, open_id} = Claims.claim(old, "app-main", "app-a", 1, "s1")
    {:ok, done_id} = Claims.claim(old, "app-main", "app-b", 1, "s1")
    {:ok, :verified} = Claims.settle(old, done_id, :verified)
    GenServer.stop(old)

    new = open(ctx, "s2")
    assert status(new, open_id) == "interrupted"
    assert status(new, done_id) == "verified"
    # Interrupted, never retried: the state stays held; its next state is free.
    assert {:refused, {:already_claimed, "app-main"}} =
             Claims.claim(new, "app-main", "app-a", 1, "s2")

    assert {:ok, again} = Claims.claim(new, "app-main", "app-a", 2, "s2")
    assert again != open_id
    assert {:refused, {:not_open, :interrupted}} = Claims.settle(new, open_id, :verified)
  end

  test "ClaimSettled: a second open in the same start leaves the current start's rows", ctx do
    first = open(ctx, "s1")
    {:ok, id} = Claims.claim(first, "app-main", "app-a", 1, "s1")
    second = open(ctx, "s1")
    assert status(second, id) == "claimed"
    assert {:ok, :verified} = Claims.settle(second, id, :verified)
  end

  test "a settled row is never reopened", ctx do
    claims = open(ctx, "s1")
    {:ok, id} = Claims.claim(claims, "app-main", "app-a", 1, "s1")
    {:ok, :verified} = Claims.settle(claims, id, :verified)
    assert {:refused, {:not_open, :verified}} = Claims.settle(claims, id, :not_verified)
    assert {:refused, :unknown_claim} = Claims.settle(claims, 999, :verified)
    GenServer.stop(claims)
    assert status(open(ctx, "s2"), id) == "verified"
  end

  test "a call to a writer that is gone is refused, and a slow one is unknown", ctx do
    claims = open(ctx, "s1")
    :sys.suspend(claims)
    assert {:unknown, {:timeout, 50}} = Claims.rows(claims, timeout: 50)
    :sys.resume(claims)
    GenServer.stop(claims)
    assert {:refused, :no_claims} = Claims.rows(claims)
  end
end
