defmodule CodingAgentFramework.Grants do
  @moduledoc """
  Who may act on whom, by the tree's edges (`docs/design.md`, "Agents working together";
  `model/tla/Team.tla`: `Edge`, `MayFix`, `MayFixService` and `MayHand`). A pure module: it
  starts no process.

  **The tree** is read from what holds it at each check, never kept: `tree` is a function the
  embedding app hands `new/1`, of no arguments, that answers one map per agent the framework
  holds, `%{name: String.t(), project: String.t(), parent: String.t() | nil}`: `Sessions`'
  tree, one function of its agent rows (`Sessions.Agents.read_tree/1`), which the `Tracker`
  folds by the same rule. Main sessions are the entries with no parent (`parent: nil`, a
  root): every main session is an agent row of kind `main`. The checks read only `name` and
  `parent`; a name the tree does not hold, a parent with no entry of its own among them, is
  `{:refused, {:unknown_agent, name}}`, and one named with two parents is
  `{:refused, {:two_parents, name}}`.

  **The operator** (`docs/design.md`, "Concepts"): a person or the app acting on agents from
  outside the tree, under a name the embedding app gives `new/2` (`operator:`). It is a parent
  of every main session and so of every agent: it messages, reads and fixes any agent, and fixes
  any service, through the same checks and claims as a parent. It owns nothing: it starts no
  service and is handed none, and no agent messages it. Its name is reserved: a tree that names
  an agent with it refuses every check with `{:refused, {:reserved, name}}`.

  **The checks** answer `:ok` or `{:refused, reason}`, the reason naming the rule:

  | Check | Rule | Reason |
  |---|---|---|
  | `may_message?/3` | the operator to any agent; a main session to its delegates and the other main sessions; a delegate to its parent | `:along_edges` |
  | `may_read?/3` (`look`, `transcript`) | the target itself, its parent, its children, for a main session the other main sessions, and the operator | `:close_read_along_edges` |
  | `may_fix?/3` | a parent on its own child; the operator on any agent | `:no_self_fix`, `:main_fixed_by_operator_only`, `:only_parent_fixes` |
  | `may_start_delegate?/3` | a main session, for itself; the operator, for any main session | `:main_session_only`, `:parent_or_operator` |
  | `may_use?/2` | any agent the tree holds, and the operator | `{:unknown_agent, name}` |
  | `may_start_service?/2` | any agent the tree holds | `{:unknown_agent, name}`, `:operator_owns_nothing` |
  | `may_fix_service?/3` | the service's owner, the owner's parent, or the operator | `:service_fixed_by_owner_or_parent` |
  | `may_hand?/4` | the owner, to its parent or a child | `:handed_by_owner`, `:handed_along_edge` |

  A fix's claim, the other half of its job, is a row in `CodingAgentFramework.Acts`.

      iex> tree = fn -> [%{name: "app-main", project: "app", parent: nil},
      ...>   %{name: "app-fix", project: "app", parent: "app-main"}] end
      iex> grants = CodingAgentFramework.Grants.new(tree)
      iex> CodingAgentFramework.Grants.may_message?(grants, "app-fix", "app-main")
      :ok
      iex> CodingAgentFramework.Grants.may_fix?(grants, "app-fix", "app-main")
      {:refused, :main_fixed_by_operator_only}
  """

  @enforce_keys [:tree]
  defstruct [:tree, :operator]

  @type t :: %__MODULE__{tree: (-> [map]), operator: String.t() | nil}
  @type answer :: :ok | {:refused, term}

  # `Mailbox`'s sender of a notice; the operator is not the framework.
  @framework "framework"

  @doc """
  The `Grants` that reads `tree` at each check. Option `operator:`, the operator's name, a
  non-empty string other than `"framework"`; with none, there is no operator.

      iex> grants = CodingAgentFramework.Grants.new(fn -> [] end, operator: "operator")
      iex> CodingAgentFramework.Grants.operator(grants)
      "operator"
  """
  @spec new((-> [map]), keyword) :: t
  def new(tree, opts \\ []) when is_function(tree, 0) do
    operator = Keyword.get(opts, :operator)

    unless is_nil(operator) or (is_binary(operator) and operator not in ["", @framework]),
      do:
        raise(
          ArgumentError,
          "operator: a name other than #{@framework}, got #{inspect(operator)}"
        )

    %__MODULE__{tree: tree, operator: operator}
  end

  @doc "The operator's name, or nil when there is none."
  @spec operator(t) :: String.t() | nil
  def operator(%__MODULE__{operator: operator}), do: operator

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
      if caller == target or edge?(tree, caller, target),
        do: :ok,
        else: {:refused, :close_read_along_edges}
    end)
  end

  @doc """
  May `caller` fix `target` (interrupt, answer, resume, stop)? Only as its parent, or as the
  operator, which is a parent of every main session (`Team.tla`, `MayFix`).
  """
  @spec may_fix?(t, String.t(), String.t()) :: answer
  def may_fix?(grants, caller, target) do
    check(grants, [caller, target], fn tree ->
      cond do
        caller == target -> {:refused, :no_self_fix}
        operator?(tree, caller) -> :ok
        main?(tree, target) -> {:refused, :main_fixed_by_operator_only}
        child?(tree, target, caller) -> :ok
        true -> {:refused, :only_parent_fixes}
      end
    end)
  end

  @doc """
  May `caller` start a delegate of `parent` (`start_delegate`, `run_delegate`)? `parent` must be
  a main session: an entry with no parent, or a parent the tree names. A main session starts its
  own; the operator starts one under any main session.

      iex> grants = CodingAgentFramework.Grants.new(fn -> [%{name: "app-main", project: "app", parent: nil}] end, operator: "op")
      iex> CodingAgentFramework.Grants.may_start_delegate?(grants, "app-main")
      :ok
      iex> CodingAgentFramework.Grants.may_start_delegate?(grants, "op", "app-main")
      :ok
  """
  @spec may_start_delegate?(t, String.t(), String.t()) :: answer
  def may_start_delegate?(grants, caller, parent \\ nil) do
    parent = parent || caller

    check(grants, [caller, parent], fn tree ->
      cond do
        not main?(tree, parent) -> {:refused, :main_session_only}
        caller == parent or operator?(tree, caller) -> :ok
        true -> {:refused, :parent_or_operator}
      end
    end)
  end

  @doc """
  May `caller` start a service? Any agent the tree holds, a main session or a delegate; never
  the operator, which has no worktree for it to run in and owns nothing.
  """
  @spec may_start_service?(t, String.t()) :: answer
  def may_start_service?(grants, caller) do
    check(grants, [caller], fn tree ->
      if operator?(tree, caller), do: {:refused, :operator_owns_nothing}, else: :ok
    end)
  end

  @doc """
  May `caller` use a tool open to every agent the tree holds (`run`, `reload`, `agents`, …)?
  The operator may too.

      iex> grants = CodingAgentFramework.Grants.new(fn -> [] end)
      iex> CodingAgentFramework.Grants.may_use?(grants, "nobody")
      {:refused, {:unknown_agent, "nobody"}}
  """
  @spec may_use?(t, String.t()) :: answer
  def may_use?(grants, caller), do: check(grants, [caller], fn _ -> :ok end)

  @doc """
  The parent of `name`, to whom a kept service goes when its owner ends: `{:ok, parent}` for a
  delegate, `{:refused, :main_has_no_parent}` for a main session.
  """
  @spec parent(t, String.t()) :: {:ok, String.t()} | {:refused, term}
  def parent(grants, name) do
    check(grants, [name], fn tree ->
      case Map.fetch(tree.parents, name) do
        {:ok, parent} when is_binary(parent) -> {:ok, parent}
        _ -> {:refused, :main_has_no_parent}
      end
    end)
  end

  @doc """
  May `caller` restart, stop or send to a service `owner` owns? As the owner, its parent, or the
  operator.
  """
  @spec may_fix_service?(t, String.t(), String.t()) :: answer
  def may_fix_service?(grants, caller, owner) do
    check(grants, [caller, owner], fn tree ->
      if caller == owner or child?(tree, owner, caller) or operator?(tree, caller),
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
    # A root is a main session, and only a root is.
    mains = MapSet.new(for %{name: n, parent: nil} <- entries, do: n)
    tree = %{parents: parents, mains: mains, operator: grants.operator}
    op = grants.operator

    cond do
      two -> {:refused, {:two_parents, two.name}}
      op && (Map.has_key?(parents, op) or main?(tree, op)) -> {:refused, {:reserved, op}}
      unknown = Enum.find(names, &(not known?(tree, &1))) -> {:refused, {:unknown_agent, unknown}}
      true -> rule.(tree)
    end
  end

  defp known?(tree, name),
    do: Map.has_key?(tree.parents, name) or main?(tree, name) or operator?(tree, name)

  defp main?(tree, name), do: MapSet.member?(tree.mains, name)
  defp operator?(tree, name), do: tree.operator != nil and name == tree.operator
  defp child?(tree, child, parent), do: Map.get(tree.parents, child) == parent

  # The operator reaches every agent; no agent reaches it.
  defp edge?(tree, a, b) do
    (operator?(tree, a) and a != b) or (main?(tree, a) and main?(tree, b) and a != b) or
      child?(tree, a, b) or child?(tree, b, a)
  end
end
