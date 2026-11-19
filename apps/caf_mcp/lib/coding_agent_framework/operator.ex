defmodule CodingAgentFramework.Operator do
  @moduledoc """
  The operator's acts (`docs/design.md`, "Concepts"; `model/tla/Team.tla`, `Operators`): a
  person or the app acting on agents from outside the tree, from a view, say. A pure module of
  plain functions the embedding app calls with its `CodingAgentFramework.MCP` process. Each act
  is the agents' tool of the same name, through `MCP.operate/3`: the same `Grants` checks, the
  same claim on a fixed agent's state, the same `Mailbox` order for a message, and a row in the
  call log that names the operator as the actor. Nothing here checks, retries or waits on its
  own, so the operator can do nothing an agent's tool could not do in its place.

  The operator is a parent of every main session and so of every agent: it starts a delegate
  under any main session, messages and fixes any agent, and fixes any service. It owns nothing,
  so it starts no service; a main session's own fixes wait for `Mains`. Each answer is the
  tool's: `{:ok, value}`, `{:refused, reason}` or `{:unknown, reason}`.

      Operator.start_delegate(mcp, "app-main", "app", "unit/review", "opus", "Review it.")
      #=> {:ok, %{delegate: "app-unit-review"}}
      Operator.message(mcp, "app-unit-review", "Rebase on main first.")
      #=> {:ok, {:queued, 7}}
      Operator.interrupt(mcp, "app-unit-review")
      #=> {:ok, %{done: :sent, claim: 3, settled: {:ok, :verified}}}
  """

  alias CodingAgentFramework.MCP

  @type answer :: {:ok, term} | {:refused, term} | {:unknown, term}

  @doc """
  Starts a delegate of main session `parent` on `branch` of `project`; its report goes to
  `parent`. `opts` are the tool's own options (F-170), so an app never names the tool:
  `interactive:` (a boolean), `meta:` (the app's map on the agent row), `options:` (the
  delegate's launch options, `ClaudeCLI.Options`) and `wait:`. The operator's start waits for a
  queued lease by default; with `wait: false` it answers `{:ok, %{delegate: name, queued:
  position}}` at once, and the start's outcome is told to `parent` later as a notice, once. Any
  other option is refused `{:bad, {:option, key}}`, with no call made.

      Operator.start_delegate(mcp, "app-main", "app", "unit/api", "opus", "Build it.",
        meta: %{"card" => 41}, wait: false)
      #=> {:ok, %{delegate: "app-unit-api", queued: 2}}
  """
  @spec start_delegate(GenServer.server(), s, s, s, s, s, keyword) :: answer when s: String.t()
  def start_delegate(mcp, parent, project, branch, model, brief, opts \\ []) do
    args = %{"parent" => parent, "project" => project, "branch" => branch}
    args = Map.merge(args, %{"model" => model, "brief" => brief})

    with {:ok, args} <- start_options(opts, args),
         do: MCP.operate(mcp, "start_delegate", args)
  end

  @start_options ~w(interactive meta options wait)a

  defp start_options(opts, args) do
    Enum.reduce_while(opts, {:ok, args}, fn
      {key, value}, {:ok, args} when key in @start_options ->
        {:cont, {:ok, Map.put(args, Atom.to_string(key), value)}}

      {key, _value}, _ ->
        {:halt, {:refused, {:bad, {:option, key}}}}

      other, _ ->
        {:halt, {:refused, {:bad, {:option, other}}}}
    end)
  end

  @doc """
  Starts main session `name` of `project` in its checkout, with `brief` from the operator as
  its first message (F-141, `CodingAgentFramework.Mains`).

      Operator.start_main(mcp, "app", "app-epic", "Plan the epic.")
      #=> {:ok, %{main: "app-epic"}}
  """
  @spec start_main(GenServer.server(), String.t(), String.t(), String.t(), String.t() | nil) ::
          answer
  def start_main(mcp, project, name, brief, model \\ nil) do
    args = %{"project" => project, "name" => name, "brief" => brief}
    args = if model, do: Map.put(args, "model", model), else: args
    MCP.operate(mcp, "start_main", args)
  end

  @doc """
  Ends main session `name` for good (F-143): refused while any delegate of it has not ended;
  otherwise it is stopped once idle, its agent row is `ended`, and what it owns ends with it.

      Operator.end_main(mcp, "app-epic")
      #=> {:ok, :ended}

  With `force: true` (F-170) the end does not wait for a row in flight to the session, which a
  session that never takes a turn (one not logged in, say) never settles: it is stopped once
  idle, and each row still `sending` to it settles `unknown` (`ended_while_sending`), never
  resent and never counted delivered. The act and each row's settle are rows in `Acts`.

      Operator.end_main(mcp, "app-epic", force: true)
      #=> {:ok, %{done: :ended, act: 12, unknown: [7]}}
  """
  @spec end_main(GenServer.server(), String.t(), keyword) :: answer
  def end_main(mcp, name, opts \\ []),
    do: MCP.operate(mcp, "end_main", forced(%{"name" => name}, opts))

  @doc "Sends `text` to agent `to`, stored first and typed into an ended turn, as any message."
  @spec message(GenServer.server(), String.t(), String.t()) :: answer
  def message(mcp, to, text), do: MCP.operate(mcp, "message", %{"to" => to, "text" => text})

  @doc "Interrupts `agent`'s turn, under a claim on its current state."
  @spec interrupt(GenServer.server(), String.t()) :: answer
  def interrupt(mcp, agent), do: fix(mcp, "interrupt", agent)

  @doc """
  Answers `agent`'s open request `dialog` with `label`, `"allow"` or `"deny"`, under a claim:
  a delegate's through `Delegates`, as its parent would, and a main session's held
  `PermissionRequest` (`dialog` its row's id) through `Mains.answer/5` (F-147).

      Operator.answer(mcp, "app-main", "41", "allow")
      #=> {:ok, %{done: :sent, claim: 7, settled: {:ok, :verified}}}
  """
  @spec answer(GenServer.server(), String.t(), String.t(), String.t()) :: answer
  def answer(mcp, agent, dialog, label),
    do: MCP.operate(mcp, "answer", %{"agent" => agent, "dialog" => dialog, "label" => label})

  @doc """
  Withdraws an agent's open ask `ask` (F-172): a person dismissed it in the app's inbox, and
  the agent reads `reason` once, in the answer's place. The answer and the withdrawal race to
  one settle: the second is refused `:settled`.

      Operator.withdraw(mcp, 12, "Dismissed: the release went out without it.")
      #=> {:ok, {:queued, 13}}
  """
  @spec withdraw(GenServer.server(), integer, String.t()) :: answer
  def withdraw(mcp, ask, reason),
    do: MCP.operate(mcp, "withdraw", %{"ask" => ask, "reason" => reason})

  @doc """
  Answers the startup dialog `agent`'s start waits on (F-140): `kind` `"trust"` or
  `"imports"`, as the agent row shows it, by its option's `label`. Nothing answers one unless
  the operator does, or the app's callback chose to.

      Operator.answer_startup(mcp, "app-main", "trust", "Yes, I trust this folder")
      #=> {:ok, :sent}
  """
  @spec answer_startup(GenServer.server(), String.t(), String.t(), String.t()) :: answer
  def answer_startup(mcp, agent, kind, label) do
    args = %{"agent" => agent, "kind" => kind, "label" => label}
    MCP.operate(mcp, "answer_startup", args)
  end

  @doc "Resumes `agent` whose process died, once per state, under a claim."
  @spec resume(GenServer.server(), String.t()) :: answer
  def resume(mcp, agent), do: fix(mcp, "resume", agent)

  @doc """
  Ends `agent` once its report is delivered, under a claim. With `force: true` (F-170) the stop
  does not wait for the rows to it, and each row still `sending` to it settles `unknown`, as a
  forced `end_main/3`'s do; its answer then names them (`unknown: ids`).
  """
  @spec stop(GenServer.server(), String.t(), keyword) :: answer
  def stop(mcp, agent, opts \\ []),
    do: MCP.operate(mcp, "stop", forced(%{"agent" => agent}, opts))

  defp forced(args, opts),
    do: if(Keyword.get(opts, :force) == true, do: Map.put(args, "force", true), else: args)

  @doc """
  Moves `agent`, a main session or a delegate, to account `to`, or with `nil` to the one with
  the most allowance left: drained, ended once idle, its transcript copied, resumed there under
  the same name and session (`CodingAgentFramework.Mover`). Answers once the drain began.
  """
  @spec move(GenServer.server(), String.t(), String.t() | nil) :: answer
  def move(mcp, agent, to \\ nil) do
    args = if to, do: %{"agent" => agent, "to" => to}, else: %{"agent" => agent}
    MCP.operate(mcp, "move", args)
  end

  @doc "Sends text or keys to service `name`'s terminal (`\\n` is Enter); never resent."
  @spec service_send(GenServer.server(), String.t(), String.t()) :: answer
  def service_send(mcp, name, input),
    do: MCP.operate(mcp, "service_send", %{"name" => name, "input" => input})

  @doc "Restarts service `name`."
  @spec service_restart(GenServer.server(), String.t()) :: answer
  def service_restart(mcp, name), do: MCP.operate(mcp, "service_restart", %{"name" => name})

  @doc "Ends service `name`."
  @spec service_stop(GenServer.server(), String.t()) :: answer
  def service_stop(mcp, name), do: MCP.operate(mcp, "service_stop", %{"name" => name})

  defp fix(mcp, tool, agent), do: MCP.operate(mcp, tool, %{"agent" => agent})
end
