defmodule CodingAgentFramework.MCP do
  @moduledoc """
  The agents' tools (`docs/design.md`, "Agents working together"): who calls, the call log, and
  the tools. One process with no name, started by the embedding app, the one writer of
  `CodingAgentFramework.MCP.Table`; a call works in the caller's process, as the endpoint's
  request (`CodingAgentFramework.MCP.Plug`).

  **Who calls.** `issue/2` makes an agent a token and writes its MCP config,
  `<dir>/agents/<agent>.json`, with one `http` server entry, `caf`, that carries the token in
  the `x-caf-token` header. `CodingAgentFramework.ClaudeCLI` names that file at the agent's
  launch (`mcp:`). `who/2` maps a token to its agent; no argument of a call names the caller.

  **A call** (`call/4`) is written `called` before it acts and `answered` with its outcome, a
  refusal included. It answers `{:ok, value}`, `{:refused, reason}` or `{:unknown, reason}`:

  - `message(to, text)`: `Grants.may_message?/3`, then the mailbox's `message/5`.

  The other tools of the design's table come in later parts (`docs/build-notes/F-86.md`).

      {:ok, mcp} = MCP.start_link(dir: dir, port: 4791, grants: grants,
        mailbox: {Mailbox, mailbox})
      {:ok, config} = MCP.issue(mcp, "app-fix")
      MCP.call(mcp, "app-fix", "message", %{"to" => "app-main", "text" => "Done."})
      #=> {:ok, {:queued, 3}}
  """

  use GenServer

  alias CodingAgentFramework.Grants
  alias CodingAgentFramework.MCP.Table

  @step 5_000
  @agent ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @tools [
    %{
      name: "message",
      description: "Sends a message to an agent along an edge of the tree.",
      inputSchema: %{
        type: "object",
        properties: %{to: %{type: "string"}, text: %{type: "string"}},
        required: ["to", "text"]
      }
    }
  ]

  @doc """
  Starts the part. Options: `:dir` (a directory of its own: the table and the agents' configs),
  `:port` (where the embedding app serves the endpoint on 127.0.0.1), `:grants`, and `:mailbox`
  (`{CodingAgentFramework.Mailbox, pid}`, or a stand-in module with the same `message/5`).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The tools, as `tools/list` answers them."
  @spec tools() :: [map]
  def tools, do: @tools

  @doc """
  Makes `agent` a new token, in place of any earlier one, and writes its MCP config. Answers
  `{:ok, path}`, `{:refused, {:bad, :agent}}`, or `{:unknown, reason}` when the write fails.
  """
  @spec issue(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:refused, term} | {:unknown, term}
  def issue(mcp, agent) do
    if is_binary(agent) and agent =~ @agent,
      do: ask(mcp, {:issue, agent}),
      else: {:refused, {:bad, :agent}}
  end

  @doc "The agent `token` was made for: `{:ok, agent}` or `{:refused, :unknown_token}`."
  @spec who(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:refused, term} | {:unknown, term}
  def who(mcp, token), do: ask(mcp, {:who, token})

  @doc "Calls `tool` with `args` (a JSON object) as `agent`; see the module's doc."
  @spec call(GenServer.server(), String.t(), String.t(), map) ::
          {:ok, term} | {:refused, term} | {:unknown, term}
  def call(mcp, agent, tool, args) do
    with {:ok, id, ctx} <- ask(mcp, {:called, agent, tool, JSON.encode!(args)}) do
      outcome = act(ctx, agent, tool, args)
      # The outcome stands whether or not its row is written; a row left `called` reads `cut`.
      ask(mcp, {:answered, id, JSON.encode!(json(outcome))})
      outcome
    end
  end

  @doc "Every call's row, oldest first."
  @spec calls(GenServer.server()) :: [map] | {:unknown, term}
  def calls(mcp), do: ask(mcp, :calls)

  @doc "An outcome as JSON data: atoms as strings, tuples as lists."
  @spec json(term) :: term
  def json({:ok, v}), do: %{"ok" => json(v)}
  def json({:refused, v}), do: %{"refused" => json(v)}
  def json({:unknown, v}), do: %{"unknown" => json(v)}
  def json(v) when is_boolean(v) or is_nil(v) or is_number(v) or is_binary(v), do: v
  def json(v) when is_atom(v), do: Atom.to_string(v)
  def json(v) when is_tuple(v), do: v |> Tuple.to_list() |> json()
  def json(v) when is_list(v), do: Enum.map(v, &json/1)
  def json(v) when is_map(v), do: Map.new(v, fn {k, x} -> {to_string(json(k)), json(x)} end)
  def json(v), do: inspect(v)

  defp act(ctx, caller, "message", %{"to" => to, "text" => text})
       when is_binary(to) and is_binary(text) do
    {mod, server} = ctx.mailbox

    with :ok <- Grants.may_message?(ctx.grants, caller, to),
         do: mod.message(server, caller, to, text, timeout: @step)
  end

  defp act(_ctx, _caller, tool, _args) do
    if Enum.any?(@tools, &(&1.name == tool)),
      do: {:refused, {:bad, :args}},
      else: {:refused, {:unknown_tool, tool}}
  end

  defp ask(mcp, request) do
    GenServer.call(mcp, request, @step)
  catch
    :exit, {:noproc, _} -> {:refused, :no_mcp}
    :exit, {:timeout, _} -> {:unknown, {:timeout, @step}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)

    with :ok <- File.mkdir_p(Path.join(dir, "agents")),
         {:ok, db} <- Table.open(Path.join(dir, "mcp.db")) do
      ctx = Map.new(~w(grants mailbox)a, &{&1, Keyword.fetch!(opts, &1)})
      {:ok, %{db: db, dir: dir, port: Keyword.fetch!(opts, :port), ctx: ctx}}
    else
      {:error, reason} -> {:stop, {:mkdir, reason}}
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:issue, agent}, _from, s) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    path = Path.join([s.dir, "agents", agent <> ".json"])

    server = %{
      "type" => "http",
      "url" => "http://127.0.0.1:#{s.port}/mcp",
      "headers" => %{"x-caf-token" => token}
    }

    tmp = path <> ".tmp"
    text = JSON.encode!(%{"mcpServers" => %{"caf" => server}})

    # The file first: a token is kept only once its agent can read it.
    with :ok <- File.write(tmp, text),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      Table.put_token(s.db, agent, token)
      {:reply, {:ok, path}, s}
    else
      {:error, reason} -> {:reply, {:unknown, {path, reason}}, s}
    end
  end

  def handle_call({:who, token}, _from, s) when is_binary(token) do
    case Table.agent(s.db, token) do
      nil -> {:reply, {:refused, :unknown_token}, s}
      agent -> {:reply, {:ok, agent}, s}
    end
  end

  def handle_call({:who, _}, _from, s), do: {:reply, {:refused, :unknown_token}, s}

  def handle_call({:called, agent, tool, args}, _from, s),
    do: {:reply, {:ok, Table.called(s.db, agent, tool, args), s.ctx}, s}

  def handle_call({:answered, id, outcome}, _from, s),
    do: {:reply, Table.answered(s.db, id, outcome), s}

  def handle_call(:calls, _from, s), do: {:reply, Table.calls(s.db), s}
end
