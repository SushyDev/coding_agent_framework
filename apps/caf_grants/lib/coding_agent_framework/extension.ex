defmodule CodingAgentFramework.Extension do
  @moduledoc """
  The extensions the embedding app brings (`docs/design.md`, "Extensions"; F-154): each a
  bundle under one name, scoped by role and project. A pure module: it starts no process.

  Today a bundle holds its tools, which the agents' MCP endpoint serves beside the framework's
  (`CodingAgentFramework.MCP`, its `extensions:`). B12 adds the bundle's skill, context, events
  and guards as keys of the same map, each checked here and read by the part that uses it, so
  the endpoint reads only `tools`.

      %{
        name: "board",
        scope: %{roles: [:main], projects: ["app"]},
        tools: [
          %{
            name: "board_cards",
            description: "The project's open cards.",
            schema: %{type: "object", properties: %{column: %{type: "string"}}},
            call: fn caller, args -> Board.cards(caller, args) end
          }
        ]
      }

  **The name** is 1 to 16 lowercase letters and digits, starting with a letter, no framework
  tool's name and no prefix of one (`service` would take `service_stop`).

  **Scope** (`scope:`, on the bundle and on any tool, which narrows it): `roles`, a list of
  `:main` (a main session) and `:delegate`, and `projects`, a list of project names or `:all`;
  each is all by default. An agent sees and may call a tool only where both hold its role and
  its project (`CodingAgentFramework.Grants.may_call?/3`); the operator, which reaches every
  agent, may call every tool.

  **A tool**: `name`, the bundle's name, `_`, then 1 or more lowercase letters, digits or `_`,
  at most 64 in all; `description`, a non-empty string; `schema`, the JSON schema of its
  arguments, an object's (`type: "object"`), handed to the client as it is and not checked by
  the framework, so `call` checks what it is given; `call`, a function of the caller's name
  and the arguments (a JSON object) that answers `{:ok, result}`, `{:refused, reason}` or
  `{:unknown, reason}`; and `timeout` (ms, optional), at most the endpoint's deadline.

      iex> {:ok, [tool]} = CodingAgentFramework.Extension.check([%{name: "kb", tools: [
      ...>   %{name: "kb_find", description: "Finds.", schema: %{type: "object"},
      ...>     call: fn _caller, _args -> {:ok, []} end}]}], ["message"], 1_000)
      iex> {tool.name, tool.scope}
      {"kb_find", %{roles: [:main, :delegate], projects: :all}}
      iex> CodingAgentFramework.Extension.check([%{name: "kb", skill: "x", tools: []}], [], 1_000)
      {:refused, {:extension, "kb", {:unknown_key, :skill}}}
  """

  @keys [:name, :scope, :tools]
  @tool_keys [:name, :description, :schema, :call, :scope, :timeout]
  @roles [:main, :delegate]
  @all %{roles: @roles, projects: :all}
  # How long a killed call's `DOWN` may take: a kill cannot be refused, so it comes at once.
  @down 1_000

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          schema: map,
          call: (String.t(), map -> {:ok, term} | {:refused, term} | {:unknown, term}),
          scope: %{roles: [atom], projects: :all | [String.t()]},
          timeout: pos_integer | nil
        }

  @doc """
  Checks `extensions` whole and answers their tools, in order, each with the one scope its
  bundle's and its own leave: `{:ok, tools}`, or `{:refused, {:extension, name, why}}` for the
  first bad one. `taken` is the framework's tool names; `max` the most a tool's `timeout` may
  be (ms).
  """
  @spec check([map], [String.t()], pos_integer) :: {:ok, [tool]} | {:refused, term}
  def check(extensions, taken, max) when is_list(extensions) do
    names = Enum.map(extensions, &(is_map(&1) && &1[:name]))

    if length(Enum.uniq(names)) == length(names),
      do: collect(extensions, &bundle(&1, taken, max)),
      else: {:refused, {:extensions, :names_twice}}
  end

  def check(_extensions, _taken, _max), do: {:refused, {:extensions, :not_a_list}}

  defp bundle(%{name: name} = ext, taken, max) when is_binary(name) do
    with :ok <- form(name, ~r/\A[a-z][a-z0-9]{0,15}\z/, :name),
         :ok <- free(name, taken),
         :ok <- keys(ext, @keys),
         {:ok, scope} <- scope(Map.get(ext, :scope, %{}), @all),
         tools when is_list(tools) <- Map.get(ext, :tools, []) || {:refused, :tools},
         {:ok, tools} <- collect(tools, &tool(&1, name, scope, max)),
         true <- Enum.uniq_by(tools, & &1.name) == tools or {:refused, :tools_twice} do
      {:ok, tools}
    else
      {:refused, why} -> {:refused, {:extension, name, why}}
      _ -> {:refused, {:extension, name, :tools}}
    end
  end

  defp bundle(ext, _taken, _max),
    do: {:refused, {:extension, if(is_map(ext), do: ext[:name]), :name}}

  defp tool(%{name: name} = t, ext, scope, max) when is_binary(name) do
    timeout = Map.get(t, :timeout)

    with :ok <- form(name, ~r/\A#{ext}_[a-z0-9_]{1,#{63 - byte_size(ext)}}\z/, {:tool, name}),
         :ok <- keys(t, @tool_keys),
         true <- (is_binary(t[:description]) and t.description != "") or {:refused, :description},
         true <- object?(t[:schema]) or {:refused, {:schema, name}},
         true <- is_function(t[:call], 2) or {:refused, {:call, name}},
         true <-
           timeout == nil or (is_integer(timeout) and timeout in 1..max) or
             {:refused, {:timeout, name}},
         {:ok, scope} <- scope(Map.get(t, :scope, %{}), scope) do
      {:ok,
       %{name: name, description: t.description, schema: t.schema, call: t.call}
       |> Map.merge(%{scope: scope, timeout: timeout})}
    end
  end

  defp tool(_tool, _ext, _scope, _max), do: {:refused, :tool}

  defp object?(%{type: "object"}), do: true
  defp object?(%{"type" => "object"}), do: true
  defp object?(_), do: false

  # A tool's scope narrows its bundle's: what both hold.
  defp scope(%{} = given, within) do
    roles = Map.get(given, :roles, @roles)
    projects = Map.get(given, :projects, :all)

    with :ok <- keys(given, [:roles, :projects]),
         true <- (is_list(roles) and roles -- @roles == []) or {:refused, :roles},
         true <-
           projects == :all or (is_list(projects) and Enum.all?(projects, &is_binary/1)) or
             {:refused, :projects} do
      {:ok,
       %{
         roles: Enum.filter(within.roles, &(&1 in roles)),
         projects: both(within.projects, projects)
       }}
    end
  end

  defp scope(_given, _within), do: {:refused, :scope}

  defp both(:all, b), do: b
  defp both(a, :all), do: a
  defp both(a, b), do: Enum.filter(a, &(&1 in b))

  defp form(name, re, why), do: if(name =~ re, do: :ok, else: {:refused, why})

  defp free(name, taken) do
    if Enum.any?(taken, &(&1 == name or String.starts_with?(&1, name <> "_"))),
      do: {:refused, :clashes},
      else: :ok
  end

  defp keys(map, allowed) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      [key | _] -> {:refused, {:unknown_key, key}}
    end
  end

  # The items' answers in order, or the first refusal.
  defp collect(items, check) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case check.(item) do
        {:ok, more} when is_list(more) -> {:cont, {:ok, acc ++ more}}
        {:ok, one} -> {:cont, {:ok, acc ++ [one]}}
        refused -> {:halt, refused}
      end
    end)
  end

  @doc """
  Calls `tool` as `caller` with `args`, in a process of its own linked to the caller, and
  answers its outcome within `deadline` ms: the function's own `{:ok, _}`, `{:refused, _}` or
  `{:unknown, _}`; `{:unknown, {:crashed, text}}` when it raised, threw or exited;
  `{:unknown, {:bad_answer, text}}` for any other answer; `{:unknown, {:timeout, deadline}}`
  past the deadline, when its process is ended, so nothing of the call runs on. Its process ends
  with the caller's too.

      iex> tool = %{call: fn caller, args -> {:ok, {caller, args["n"]}} end}
      iex> CodingAgentFramework.Extension.run(tool, "app-fix", %{"n" => 1}, 1_000)
      {:ok, {"app-fix", 1}}
      iex> CodingAgentFramework.Extension.run(%{call: fn _, _ -> raise "no board" end}, "a", %{}, 1_000)
      {:unknown, {:crashed, "no board"}}
  """
  @spec run(%{call: function}, String.t(), map, pos_integer) ::
          {:ok, term} | {:refused, term} | {:unknown, term}
  def run(%{call: call}, caller, args, deadline) do
    me = self()
    tag = make_ref()
    pid = spawn_link(fn -> send(me, {tag, guarded(call, caller, args)}) end)
    ref = Process.monitor(pid)

    receive do
      {^tag, answer} ->
        Process.demonitor(ref, [:flush])
        answer

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:unknown, {:crashed, inspect(reason)}}
    after
      deadline ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        # The kill makes the `DOWN` come, after any answer sent just before it, which is
        # dropped: the call is past its deadline.
        receive(do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok), after: (@down -> :ok))
        receive(do: ({^tag, _} -> :ok), after: (0 -> :ok))
        {:unknown, {:timeout, deadline}}
    end
  end

  defp guarded(call, caller, args) do
    case call.(caller, args) do
      {kind, _} = answer when kind in [:ok, :refused, :unknown] -> answer
      other -> {:unknown, {:bad_answer, inspect(other)}}
    end
  rescue
    e -> {:unknown, {:crashed, Exception.message(e)}}
  catch
    kind, value -> {:unknown, {:crashed, inspect({kind, value})}}
  end
end
