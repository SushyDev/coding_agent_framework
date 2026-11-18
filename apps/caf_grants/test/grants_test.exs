defmodule CodingAgentFramework.GrantsTest do
  # The checks, as properties over generated trees, each named for the invariant of
  # model/tla/Team.tla it checks. What each check should answer is stated here apart from
  # Grants, from where the generator put each agent.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CodingAgentFramework.Grants

  doctest Grants
  doctest CodingAgentFramework.Extension

  @projects ["app", "web"]
  @mains for p <- @projects, do: %{name: "#{p}-main", project: p, parent: nil}

  # Two projects, one to three delegates per main session.
  defp tree_gen do
    gen all counts <- list_of(integer(1..3), length: 2) do
      for {p, n} <- Enum.zip(@projects, counts),
          i <- 1..n,
          do: %{name: "#{p}-d#{i}", project: p, parent: "#{p}-main"}
    end
  end

  # Each agent's place: {:main, project} or {:delegate, project}; and the operator, `op`.
  defp places(tree) do
    mains = Map.new(@projects, &{"#{&1}-main", {:main, &1}})
    mains = Map.put(mains, "op", :operator)
    Map.merge(mains, Map.new(tree, &{&1.name, {:delegate, &1.project}}))
  end

  # As `Sessions`' tree holds them: each main session is an entry of its own, with no parent.
  defp grants(tree), do: Grants.new(fn -> with_mains(tree) end, operator: "op")

  defp with_mains(tree), do: @mains ++ tree

  defp edge?(places, c, t) do
    case {places[c], places[t]} do
      {:operator, :operator} -> false
      {:operator, _} -> true
      {{:main, _}, {:main, _}} -> c != t
      {{:main, p}, {:delegate, p}} -> true
      {{:delegate, p}, {:main, p}} -> true
      _ -> false
    end
  end

  defp parent?(places, c, t), do: match?({{:main, p}, {:delegate, p}}, {places[c], places[t]})

  property "AlongEdges: a message and a close read go along an edge of the tree only" do
    check all tree <- tree_gen() do
      places = places(tree)

      for c <- Map.keys(places), t <- Map.keys(places) do
        want = if edge?(places, c, t), do: :ok, else: :refused
        assert Grants.may_message?(grants(tree), c, t) == ok(want, :along_edges)
        read = if c == t, do: :ok, else: want
        assert Grants.may_read?(grants(tree), c, t) == ok(read, :close_read_along_edges)
      end
    end
  end

  property "OnlyParentFixes, NoSelfFix, MainFixedByOperatorOnly: a parent's or the operator's" do
    check all tree <- tree_gen() do
      places = places(tree)

      for c <- Map.keys(places), t <- Map.keys(places) do
        want =
          cond do
            c == t -> {:refused, :no_self_fix}
            places[c] == :operator -> :ok
            match?({:main, _}, places[t]) -> {:refused, :main_fixed_by_operator_only}
            parent?(places, c, t) -> :ok
            true -> {:refused, :only_parent_fixes}
          end

        assert Grants.may_fix?(grants(tree), c, t) == want
      end
    end
  end

  property "ServiceFixedByOwnerOrParent: the owner, the owner's parent or the operator" do
    check all tree <- tree_gen() do
      places = places(tree)

      for c <- Map.keys(places), o <- Map.keys(places) do
        want =
          if c == o or parent?(places, c, o) or places[c] == :operator,
            do: :ok,
            else: :refused

        assert Grants.may_fix_service?(grants(tree), c, o) ==
                 ok(want, :service_fixed_by_owner_or_parent)
      end
    end
  end

  property "HandedAlongEdge: the owner hands a service to its parent or a child" do
    check all tree <- tree_gen() do
      places = places(tree)
      names = Map.keys(places)

      for c <- names, o <- names, b <- names do
        want =
          cond do
            c != o -> {:refused, :handed_by_owner}
            parent?(places, o, b) or parent?(places, b, o) -> :ok
            true -> {:refused, :handed_along_edge}
          end

        assert Grants.may_hand?(grants(tree), c, o, b) == want
      end
    end
  end

  test "a name the tree does not hold is refused; a main session with no delegate is held" do
    g = grants([%{name: "app-d1", project: "app", parent: "app-main"}])
    assert Grants.may_message?(g, "app-main", "nobody") == {:refused, {:unknown_agent, "nobody"}}
    # One rule with the Tracker's (F-99's new-3): a main session is its own row of the tree.
    assert Grants.may_message?(g, "web-main", "app-main") == :ok
    assert Grants.may_fix?(g, "app-main", "app-d1") == :ok

    only =
      Grants.new(fn -> [hd(@mains), %{name: "app-d1", project: "app", parent: "app-main"}] end)

    assert Grants.may_message?(only, "web-main", "app-main") ==
             {:refused, {:unknown_agent, "web-main"}}
  end

  test "any agent the tree holds may start a service; a kept one goes to the owner's parent" do
    g = grants([%{name: "app-d1", project: "app", parent: "app-main"}])
    assert Grants.may_start_service?(g, "app-main") == :ok
    assert Grants.may_start_service?(g, "app-d1") == :ok
    assert Grants.may_start_service?(g, "nobody") == {:refused, {:unknown_agent, "nobody"}}
    assert Grants.may_use?(g, "app-d1") == :ok
    assert Grants.may_use?(g, "nobody") == {:refused, {:unknown_agent, "nobody"}}
    assert Grants.parent(g, "app-d1") == {:ok, "app-main"}
    assert Grants.parent(g, "app-main") == {:refused, :main_has_no_parent}
  end

  test "a main session starts its own delegate; the operator one under any main session" do
    g =
      grants([
        %{name: "app-d1", project: "app", parent: "app-main"},
        %{name: "web-d1", project: "web", parent: "web-main"}
      ])

    assert Grants.may_start_delegate?(g, "app-main") == :ok
    assert Grants.may_start_delegate?(g, "app-d1") == {:refused, :main_session_only}
    assert Grants.may_start_delegate?(g, "nobody") == {:refused, {:unknown_agent, "nobody"}}
    assert Grants.may_start_delegate?(g, "op", "web-main") == :ok

    assert Grants.may_start_delegate?(g, "app-main", "web-main") ==
             {:refused, :parent_or_operator}

    assert Grants.may_start_delegate?(g, "op", "app-d1") == {:refused, :main_session_only}
    assert Grants.may_start_delegate?(g, "op") == {:refused, :main_session_only}
  end

  test "the operator owns nothing, and its name is never an agent's" do
    g = grants([%{name: "app-d1", project: "app", parent: "app-main"}])
    assert Grants.may_use?(g, "op") == :ok
    assert Grants.may_start_service?(g, "op") == {:refused, :operator_owns_nothing}
    assert Grants.may_hand?(g, "app-main", "app-main", "op") == {:refused, :handed_along_edge}
    assert Grants.may_message?(g, "app-main", "op") == {:refused, :along_edges}

    named = grants([%{name: "op", project: "app", parent: "app-main"}])
    assert Grants.may_message?(named, "app-main", "op") == {:refused, {:reserved, "op"}}
    root = grants([%{name: "op", project: "app", parent: nil}])
    assert Grants.may_use?(root, "app-main") == {:refused, {:reserved, "op"}}

    # With no operator, its name is any other unknown name.
    plain =
      Grants.new(fn -> with_mains([%{name: "app-d1", project: "app", parent: "app-main"}]) end)

    assert Grants.may_fix?(plain, "op", "app-d1") == {:refused, {:unknown_agent, "op"}}
    assert_raise ArgumentError, fn -> Grants.new(fn -> [] end, operator: "framework") end
  end

  test "a parent with no entry of its own is no main session" do
    g = Grants.new(fn -> [%{name: "app-d1", project: "app", parent: "app-main"}] end)
    assert Grants.may_start_delegate?(g, "app-main") == {:refused, {:unknown_agent, "app-main"}}
  end

  test "a delegate named with two parents refuses every check" do
    g =
      grants([
        %{name: "app-d1", project: "app", parent: "app-main"},
        %{name: "app-d1", project: "app", parent: "web-main"}
      ])

    assert Grants.may_fix?(g, "app-main", "app-d1") == {:refused, {:two_parents, "app-d1"}}
  end

  test "the tree is read at each check, never kept" do
    reads = :atomics.new(1, [])
    one = [%{name: "app-d1", project: "app", parent: "app-main"}]

    tree = fn ->
      if :atomics.add_get(reads, 1, 1) == 1,
        do: one,
        else: one ++ [%{(one |> hd()) | name: "app-d2"}]
    end

    g = Grants.new(fn -> with_mains(tree.()) end)
    assert Grants.may_fix?(g, "app-main", "app-d2") == {:refused, {:unknown_agent, "app-d2"}}
    assert Grants.may_fix?(g, "app-main", "app-d2") == :ok
  end

  defp ok(:ok, _reason), do: :ok
  defp ok(:refused, reason), do: {:refused, reason}
end
