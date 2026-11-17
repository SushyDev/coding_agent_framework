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

  @doc "Starts a delegate of main session `parent` on `branch` of `project`; its report goes to `parent`."
  @spec start_delegate(GenServer.server(), s, s, s, s, s) :: answer when s: String.t()
  def start_delegate(mcp, parent, project, branch, model, brief) do
    args = %{"parent" => parent, "project" => project, "branch" => branch}
    MCP.operate(mcp, "start_delegate", Map.merge(args, %{"model" => model, "brief" => brief}))
  end

  @doc "Sends `text` to agent `to`, stored first and typed into an ended turn, as any message."
  @spec message(GenServer.server(), String.t(), String.t()) :: answer
  def message(mcp, to, text), do: MCP.operate(mcp, "message", %{"to" => to, "text" => text})

  @doc "Interrupts `agent`'s turn, under a claim on its current state."
  @spec interrupt(GenServer.server(), String.t()) :: answer
  def interrupt(mcp, agent), do: fix(mcp, "interrupt", agent)

  @doc "Answers `agent`'s open request `dialog` with `label`, `\"allow\"` or `\"deny\"`, under a claim."
  @spec answer(GenServer.server(), String.t(), String.t(), String.t()) :: answer
  def answer(mcp, agent, dialog, label),
    do: MCP.operate(mcp, "answer", %{"agent" => agent, "dialog" => dialog, "label" => label})

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

  @doc "Ends `agent` once its report is delivered, under a claim."
  @spec stop(GenServer.server(), String.t()) :: answer
  def stop(mcp, agent), do: fix(mcp, "stop", agent)

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
