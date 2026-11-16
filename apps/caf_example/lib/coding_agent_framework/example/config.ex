defmodule CodingAgentFramework.Example.Config do
  @moduledoc """
  What the example app runs with, as data: the embedding app's whole configuration, read by no
  part from the environment.

  - `home`: the framework home, an absolute path. Every file the app writes is under it:
    `caf.db` (the readers' and writers' tables), `claims.db`, `accounts/`, `d/` (the dtach
    directory, kept short for macOS's 104-byte socket paths), `tmux.sock` (its own tmux
    server), `streams/`, `worktrees/`, `parts/` (the tables of `Copies`, `Jobs`, `Services` and
    `MCP`) and `ws/` (the workstation's copies and service logs);
  - `instance`: this framework instance's name, in each job id `MCP` makes;
  - `workstation`: the workstation's host name, and `programs`, the absolute path of each
    program there (`CodingAgentFramework.Programs`);
  - `hosts`: the other hosts, name to `%{programs: programs, dir: dir}` as `Jobs` and `Services`
    read them; none by default;
  - `accounts`: the Claude accounts' names;
  - `projects`: name to the project as `Sessions` and `Delegates` read it: `repo`, `trunk`,
    `setup`, `setup_timeout`, `env`, `branches` and `cap` (the name is filled in);
  - `mains`: each project's main session, project to its name; the tree holds each as a root
    (no parent), so it can start its first delegate. None by default;
  - `operator`: the name the operator acts under (`CodingAgentFramework.Operator`), a person or
    this app acting from outside the tree; `"operator"` by default. It is no agent's name, nor
    `framework`;
  - `ports`: `%{intake: port, mcp: port}` on 127.0.0.1;
  - `claude` and `env`: what every agent's launch shares (`CodingAgentFramework.ClaudeCLI`);
    `tool_timeout` and `margin`, Claude Code's MCP tool timeout and what `run_delegate` keeps
    under it;
  - `interval`: ms between the reads of the readers that read on a timer.
  - `tool_hooks`: the app's tool callbacks, `%{pre_tool_use: fun, post_tool_use: fun}`, each
    optional, as `CodingAgentFramework.Intake` takes them; each one given adds its hook to
    every account's settings. None by default.

      iex> {:ok, c} = CodingAgentFramework.Example.Config.new(home: "/srv/caf", instance: "a",
      ...>   programs: %{kill: "/bin/kill"}, accounts: ["work"], ports: %{intake: 4790, mcp: 4791},
      ...>   claude: "/bin/claude", env: %{home: "/srv/caf", path: "/bin"})
      iex> {c.workstation, c.hosts, c.projects}
      {"ws", %{}, %{}}
      iex> CodingAgentFramework.Example.Config.new(home: "caf")
      {:refused, {:bad, :home}}
  """

  @enforce_keys [:home, :instance, :programs, :accounts, :ports, :claude, :env]
  defstruct [
    :home,
    :instance,
    :programs,
    :accounts,
    :ports,
    :claude,
    :env,
    workstation: "ws",
    hosts: %{},
    projects: %{},
    mains: %{},
    operator: "operator",
    tool_timeout: 3_600_000,
    margin: 60_000,
    interval: 2_000,
    tool_hooks: %{}
  ]

  @type t :: %__MODULE__{}

  @doc "A config from a keyword list or map; answers `{:ok, config}` or `{:refused, {:bad, key}}`."
  @spec new(keyword | map) :: {:ok, t} | {:refused, {:bad, atom}}
  def new(fields) do
    fields = Map.new(fields)
    missing = Enum.find(@enforce_keys, &(not Map.has_key?(fields, &1)))

    cond do
      not (is_binary(fields[:home]) and Path.type(fields[:home]) == :absolute) ->
        {:refused, {:bad, :home}}

      missing ->
        {:refused, {:bad, missing}}

      not match?(%{intake: i, mcp: m} when is_integer(i) and is_integer(m), fields.ports) ->
        {:refused, {:bad, :ports}}

      not operator?(fields) ->
        {:refused, {:bad, :operator}}

      true ->
        c = struct!(__MODULE__, fields)
        {:ok, %{c | projects: Map.new(c.projects, fn {n, p} -> {n, Map.put(p, :name, n)} end)}}
    end
  end

  defp operator?(fields) do
    op = Map.get(fields, :operator, "operator")
    is_binary(op) and op not in ["", "framework" | Map.values(Map.get(fields, :mains, %{}))]
  end

  @doc "A path under the home."
  @spec path(t, String.t()) :: String.t()
  def path(%__MODULE__{home: home}, rest), do: Path.join(home, rest)
end
