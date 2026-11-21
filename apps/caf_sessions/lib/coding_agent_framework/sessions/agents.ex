defmodule CodingAgentFramework.Sessions.Agents do
  @moduledoc """
  The agent rows as every other part reads them (`docs/design.md`, "The parts"): the tree, one
  agent's row, and what its status means. `Grants`, the `Tracker`, `Mailbox`, `Delegates` and
  the embedding app read `Sessions`' state only here, never by naming a status or a column's
  value themselves, so a status renamed in `Sessions` changes this module alone.

  A pure module over a reader's own connection to `Sessions`' file (`open/2`), which never
  writes, so a reader never waits on `Sessions`' process, which itself waits on `Mailbox` in a
  stop. The tree functions are also total functions of rows (`tree/1`), so the `Tracker` folds
  the rows of its view by the same rule `Grants` reads from the file.

  **The tree** (`tree/1`): every row of kind `main` (a main session is never archived), and
  every row of kind `delegate` with its parent. A delegate that ended keeps its place and its
  edge, so what it kept goes to its parent and a message to it is answered as ended; it no
  longer holds its parent's cap (`active?/1`). Each entry is `%{name, kind, project, parent,
  account, session_id, host, status}`, `kind` being `"main"` or `"delegate"`.

      iex> alias CodingAgentFramework.Sessions.Agents
      iex> rows = [%{id: 1, host: "h", name: "app-main", kind: "main", parent: nil, project: "app",
      ...>   account: nil, session_id: nil, status: "declared"},
      ...>  %{id: 2, host: "h", name: "app-fix", kind: "delegate", parent: "app-main",
      ...>   project: "app", account: "work", session_id: "s1", status: "running"},
      ...>  %{id: 3, host: "h", name: "app-old", kind: "delegate", parent: "app-main",
      ...>   project: "app", account: "work", session_id: "s0", status: "ended"}]
      iex> Enum.map(Agents.tree(rows), &{&1.name, &1.parent})
      [{"app-main", nil}, {"app-fix", "app-main"}, {"app-old", "app-main"}]
      iex> rows |> Enum.filter(&Agents.active?/1) |> Enum.map(& &1.name)
      ["app-main", "app-fix"]
  """

  alias CodingAgentFramework.Sessions.{Dialog, Table}

  @enforce_keys [:db, :host]
  defstruct [:db, :host]

  @type t :: %__MODULE__{db: Table.db(), host: String.t()}
  @type row :: Table.row()

  @entry [:name, :kind, :project, :parent, :account, :session_id, :host, :status]

  @doc "A reader of `host`'s agent rows in `Sessions`' file at `path`."
  @spec open(String.t(), String.t()) :: {:ok, t} | {:refused, term}
  def open(path, host) do
    with {:ok, db} <- Table.open_read(path), do: {:ok, %__MODULE__{db: db, host: host}}
  end

  @doc """
  The host's rows in `Sessions`' file at `path`, oldest first, read once through a read-only
  connection that is closed after (F-195): for a reader outside the tree, which opens no
  writer's file. `{:ok, []}` before `Sessions` made its table; `{:refused, {:sqlite, reason}}`
  for a file it cannot open.
  """
  @spec read_only(String.t(), String.t()) :: {:ok, [row]} | {:refused, term}
  def read_only(path, host),
    do: CodingAgentFramework.Store.read_only(path, "agents", [], &Table.rows(&1, host))

  @doc "The host's rows, oldest first."
  @spec rows(t) :: [row]
  def rows(%__MODULE__{db: db, host: host}), do: Table.rows(db, host)

  @doc "Agent `name`'s row, or nil."
  @spec get(t, String.t()) :: row | nil
  def get(%__MODULE__{db: db, host: host}, name), do: Table.get(db, host, name)

  @doc "The tree of the host's rows, read now: `tree/1` of `rows/1`."
  @spec read_tree(t) :: [map]
  def read_tree(agents), do: tree(rows(agents))

  @doc "The tree of `rows`, as the module doc says: a total function of the rows it is given."
  @spec tree([row]) :: [map]
  def tree(rows) when is_list(rows) do
    for %{} = row <- rows, holds?(row), do: Map.take(row, @entry)
  end

  @doc """
  Whether a row is an agent of the tree: a main session's always, a delegate's when it names
  its parent. A row of no known kind is none.

      iex> CodingAgentFramework.Sessions.Agents.holds?(%{kind: "delegate", parent: "m", status: "ended"})
      true
  """
  @spec holds?(row | nil) :: boolean
  def holds?(%{kind: "main"}), do: true
  def holds?(%{kind: "delegate", parent: p}) when is_binary(p), do: true
  def holds?(_), do: false

  @doc """
  Whether an agent has ended: a delegate whose start was refused or that is done for good, so
  no process of it will run again and what it owned ends with it; a main session once the
  operator ended it (`Sessions.end_main/3`, F-143), and not for a refused start, after which
  its name may start again. A name with no row has not.

      iex> CodingAgentFramework.Sessions.Agents.ended?(%{kind: "main", status: "ended"})
      true
      iex> CodingAgentFramework.Sessions.Agents.ended?(%{kind: "main", status: "refused"})
      false
  """
  @spec ended?(row | nil) :: boolean
  def ended?(%{kind: "delegate", status: status}), do: status in Table.done()
  def ended?(%{kind: "main", status: "ended"}), do: true
  def ended?(_), do: false

  @doc """
  Whether an agent of the tree has not ended: a delegate so holds its parent's cap.
  """
  @spec active?(row | nil) :: boolean
  def active?(row), do: holds?(row) and not ended?(row)

  @doc """
  Whether no process of the row may live, so its name may start again: a declared main
  session, a stopped or refused start, an ended delegate, or no row at all.
  """
  @spec free?(row | nil) :: boolean
  def free?(nil), do: true
  def free?(%{status: status}), do: status in Table.free()

  @doc """
  Whether the row is a main session declared and not started since (F-141): `Mains` may start
  a main session under its name.

      iex> CodingAgentFramework.Sessions.Agents.declared?(%{kind: "main", status: "declared"})
      true
  """
  @spec declared?(row | nil) :: boolean
  def declared?(%{kind: "main", status: "declared"}), do: true
  def declared?(_), do: false

  @doc "Whether the row's process runs, as its start or a settle confirmed it."
  @spec running?(row | nil) :: boolean
  def running?(%{status: "running"}), do: true
  def running?(_), do: false

  @doc """
  The startup dialog the agent's start waits on, for a view (F-140): `%{kind, options,
  selected, paths, answers}`, `answers` each kind's answer so far (`%{kind => %{label, mark}}`),
  or nil when its row is not on one. Such a row is neither started nor idle, and not free: its
  lease stays held. A person answers it through `Sessions.answer_dialog/5`.

      iex> row = %{status: "dialog", answers: nil,
      ...>   dialog: ~s({"kind":"trust","options":["No, exit","Yes"],"selected":"No, exit"})}
      iex> CodingAgentFramework.Sessions.Agents.dialog(row).kind
      :trust
  """
  @spec dialog(row | nil) :: map | nil
  def dialog(%{status: "dialog"} = row) do
    with %{} = shown <- Dialog.shown(row), do: Map.put(shown, :answers, Dialog.answers(row))
  end

  def dialog(_), do: nil

  @doc "Whether a start or a resume of the row is under way."
  @spec starting?(row | nil) :: boolean
  def starting?(%{status: "starting"}), do: true
  def starting?(_), do: false

  @doc """
  Whether a move of the agent is under way (`Mover`, F-133): from its drain until it runs on
  the other account. `Mailbox` hands it no row that would start a turn, and `Delegates` starts
  no delegate under it and takes its end for the move's, not a kill.

      iex> CodingAgentFramework.Sessions.Agents.moving?(%{move: "draining"})
      true
  """
  @spec moving?(row | nil) :: boolean
  def moving?(%{move: phase}) when is_binary(phase), do: true
  def moving?(_), do: false

  @doc "The host's rows a move is under way for, by index (nothing is pruned)."
  @spec moving(t) :: [row]
  def moving(%__MODULE__{db: db, host: host}), do: Table.moving(db, host)

  @doc """
  The move under way: `%{phase, from, to, act, deadline}`, or nil when none is.
  """
  @spec move(row | nil) :: map | nil
  def move(%{move: phase} = row) when is_binary(phase) do
    %{
      phase: phase,
      from: row.move_from,
      to: row.move_to,
      act: row.move_act,
      deadline: row.move_deadline
    }
  end

  def move(_), do: nil

  @doc """
  The embedding app's own metadata on the row (F-154): the map its start's `meta:` gave or
  `Sessions.put_meta/4` set since, as JSON gives it back (string keys), or `%{}` for none. The
  framework never reads it.

      iex> CodingAgentFramework.Sessions.Agents.meta(%{meta: ~s({"ticket":41})})
      %{"ticket" => 41}
  """
  @spec meta(row | nil) :: map
  def meta(%{meta: text}) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = meta} -> meta
      _ -> %{}
    end
  end

  def meta(_), do: %{}

  @doc """
  The usage limit the row's last turn ended at (F-185, `Sessions.Table`'s `usage_limit`), as
  JSON gives it back (string keys: `until`, the reset in Unix seconds, `window`, `line`,
  `step`), or nil when the row is not `limited`. `Sessions.Turn` answers `:limited` for such a
  row: never idle, never an ended turn, until a turn of it runs after the limit.

      iex> CodingAgentFramework.Sessions.Agents.limit(%{usage_limit: ~s({"until":1800000000,"step":"look"})})
      %{"until" => 1800000000, "step" => "look"}
      iex> CodingAgentFramework.Sessions.Agents.limit(%{usage_limit: nil})
      nil
  """
  @spec limit(row | nil) :: map | nil
  def limit(%{usage_limit: text}) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{"until" => until} = limit} when is_integer(until) -> limit
      _ -> nil
    end
  end

  def limit(_), do: nil

  @doc """
  The row as `Mailbox` reads its turn at `now` (Unix seconds): with its limit while the limit's
  reset has not passed, so its turn is `:limited` and no row goes in (`Boxes.tla`'s
  `NoRowIntoLimit`: a row would start a turn that hits the limit again), and without it after,
  so the word to go on and the rows held go into its ended turn as into any.

      iex> alias CodingAgentFramework.Sessions.Agents
      iex> row = %{usage_limit: ~s({"until":100,"step":"idle"})}
      iex> {Agents.unheld(row, 99) == row, Agents.unheld(row, 100).usage_limit}
      {true, nil}
  """
  @spec unheld(row | nil, integer) :: row | nil
  def unheld(row, now) do
    case limit(row) do
      %{"until" => until} when now >= until -> %{row | usage_limit: nil}
      _ -> row
    end
  end

  @doc "Whether the row runs headless (a delegate's stream), not Claude Code's terminal interface."
  @spec headless?(row | nil) :: boolean
  def headless?(%{role: "delegate"}), do: true
  def headless?(_), do: false

  @doc "Whether the row's start, whose call was asked at wall-clock ms `at`, is that call's or later."
  @spec since?(row | nil, integer) :: boolean
  def since?(%{started_at: started}, at) when is_integer(started), do: started >= at
  def since?(_, _), do: false

  @doc "The name of the agent whose session on `account` is `session_id`, or nil."
  @spec by_session(t, String.t(), String.t()) :: String.t() | nil
  def by_session(agents, account, session_id) do
    Enum.find_value(rows(agents), fn row ->
      if row.account == account and row.session_id == session_id, do: row.name
    end)
  end

  @doc """
  Where agent `name` works, for its jobs and services: `{:ok, %{project, name, worktree}}`, the
  worktree being its row's `cwd`, or `{:refused, :no_worktree}` for a name with no project or
  no directory yet.
  """
  @spec place(t, String.t()) :: {:ok, map} | {:refused, :no_worktree}
  def place(agents, name) do
    case get(agents, name) do
      %{project: p, cwd: "/" <> _ = cwd} when is_binary(p) ->
        {:ok, %{project: p, name: name, worktree: cwd}}

      _ ->
        {:refused, :no_worktree}
    end
  end

  @doc "The names among the rows with these ids (or all, `:all`) whose agent has ended."
  @spec ended_names(t, :all | [integer]) :: [String.t()]
  def ended_names(%__MODULE__{db: db} = agents, ids) do
    rows = if ids == :all, do: rows(agents), else: Table.rows_by_id(db, ids)
    for row <- rows, row.host == agents.host, ended?(row), do: row.name
  end

  @doc "How many of `parent`'s delegates have not ended, besides the names in `also`: its cap."
  @spec children(t, String.t(), [String.t()]) :: non_neg_integer
  def children(agents, parent, also \\ []) do
    named =
      for %{kind: "delegate", name: n} = row <- Table.children(agents.db, agents.host, parent),
          active?(row),
          do: n

    length(Enum.uniq(named ++ also))
  end
end
