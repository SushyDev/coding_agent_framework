defmodule CodingAgentFramework.Grants do
  @moduledoc """
  Who may act on whom, by the tree's edges (`docs/design.md`, "Agents working together";
  `model/tla/Team.tla`: `Edge`, `MayFix`, `MayFixService` and `MayHand`). A pure module: it
  starts no process.

  **The tree** is read from what holds it at each check, never kept: `tree` is a function the
  embedding app hands `new/1`, of no arguments, that answers one map per delegate the framework
  holds, `%{name: String.t(), project: String.t(), parent: String.t()}` (for now, each row of
  `Delegates`' table). Main sessions are the parents no entry names as a delegate. The checks
  read only `name` and `parent`; a name the tree does not hold is
  `{:refused, {:unknown_agent, name}}`, and one named with two parents is
  `{:refused, {:two_parents, name}}`.

  **The checks** answer `:ok` or `{:refused, reason}`, the reason naming the rule:

  | Check | Rule | Reason |
  |---|---|---|
  | `may_message?/3` | a main session to its delegates and the other main sessions; a delegate to its parent | `:along_edges` |
  | `may_read?/3` (`look`, `transcript`) | the target's parent, its children, and for a main session the other main sessions | `:close_read_along_edges` |
  | `may_fix?/3` | a parent on its own child | `:no_self_fix`, `:main_never_fixed`, `:only_parent_fixes` |
  | `may_fix_service?/3` | the service's owner or the owner's parent | `:service_fixed_by_owner_or_parent` |
  | `may_hand?/4` | the owner, to its parent or a child | `:handed_by_owner`, `:handed_along_edge` |

  A fix's claim, the other half of its job, is the next unit (F-73's build note).

      iex> tree = fn -> [%{name: "app-fix", project: "app", parent: "app-main"}] end
      iex> grants = CodingAgentFramework.Grants.new(tree)
      iex> CodingAgentFramework.Grants.may_message?(grants, "app-fix", "app-main")
      :ok
      iex> CodingAgentFramework.Grants.may_fix?(grants, "app-fix", "app-main")
      {:refused, :main_never_fixed}
  """

  @enforce_keys [:tree]
  defstruct [:tree]

  @type t :: %__MODULE__{tree: (-> [map])}
  @type answer :: :ok | {:refused, term}

  @doc "The `Grants` that reads `tree` at each check."
  @spec new((-> [map])) :: t
  def new(tree) when is_function(tree, 0), do: %__MODULE__{tree: tree}

  @doc "May `caller` message `target`? Along an edge of the tree only (`Team.tla`, `Edge`)."
  @spec may_message?(t, String.t(), String.t()) :: answer
  def may_message?(grants, caller, target) do
    check(grants, [caller, target], fn tree ->
      if edge?(tree, caller, target), do: :ok, else: {:refused, :along_edges}
    end)
  end

  @doc "May `caller` read `target` closely (`look`, `transcript`)? Along an edge, as a message."
  @spec may_read?(t, String.t(), String.t()) :: answer
  def may_read?(grants, caller, target) do
    check(grants, [caller, target], fn tree ->
      if edge?(tree, caller, target), do: :ok, else: {:refused, :close_read_along_edges}
    end)
  end

  @doc """
  May `caller` fix `target` (interrupt, answer, resume, stop)? Only as its parent
  (`Team.tla`, `MayFix`).
  """
  @spec may_fix?(t, String.t(), String.t()) :: answer
  def may_fix?(grants, caller, target) do
    check(grants, [caller, target], fn tree ->
      cond do
        caller == target -> {:refused, :no_self_fix}
        main?(tree, target) -> {:refused, :main_never_fixed}
        child?(tree, target, caller) -> :ok
        true -> {:refused, :only_parent_fixes}
      end
    end)
  end

  @doc "May `caller` restart or stop a service `owner` owns? As the owner or its parent."
  @spec may_fix_service?(t, String.t(), String.t()) :: answer
  def may_fix_service?(grants, caller, owner) do
    check(grants, [caller, owner], fn tree ->
      if caller == owner or child?(tree, owner, caller),
        do: :ok,
        else: {:refused, :service_fixed_by_owner_or_parent}
    end)
  end

  @doc "May `caller` hand a service `owner` owns to `to`? Only the owner, to its parent or a child."
  @spec may_hand?(t, String.t(), String.t(), String.t()) :: answer
  def may_hand?(grants, caller, owner, to) do
    check(grants, [caller, owner, to], fn tree ->
      cond do
        caller != owner -> {:refused, :handed_by_owner}
        child?(tree, to, owner) or child?(tree, owner, to) -> :ok
        true -> {:refused, :handed_along_edge}
      end
    end)
  end

  # The tree as each delegate's parent, read once per check.
  defp check(grants, names, rule) do
    entries = grants.tree.()
    parents = Map.new(entries, &{&1.name, &1.parent})
    two = Enum.find(entries, &(parents[&1.name] != &1.parent))
    mains = for %{parent: p} <- entries, not Map.has_key?(parents, p), into: MapSet.new(), do: p
    tree = %{parents: parents, mains: mains}

    cond do
      two -> {:refused, {:two_parents, two.name}}
      unknown = Enum.find(names, &(not known?(tree, &1))) -> {:refused, {:unknown_agent, unknown}}
      true -> rule.(tree)
    end
  end

  defp known?(tree, name), do: Map.has_key?(tree.parents, name) or main?(tree, name)
  defp main?(tree, name), do: MapSet.member?(tree.mains, name)
  defp child?(tree, child, parent), do: Map.get(tree.parents, child) == parent

  defp edge?(tree, a, b) do
    (main?(tree, a) and main?(tree, b) and a != b) or child?(tree, a, b) or child?(tree, b, a)
  end
end
