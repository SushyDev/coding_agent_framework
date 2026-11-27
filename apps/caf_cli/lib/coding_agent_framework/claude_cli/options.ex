defmodule CodingAgentFramework.ClaudeCLI.Options do
  @moduledoc """
  An agent's own launch options, checked. Pure. Keys are atoms or their strings, each optional:
  `settings` (Claude Code settings, which `CodingAgentFramework.Accounts.overlay/4` merges over
  the account's; never the keys the framework writes, and in `skillOverrides`, a map of skill
  name to text, never an entry it writes, `Accounts.skill_overrides/0`; the agent's other
  entries merge one by one over the account's, F-285), `env` (names to strings; never a name
  the framework sets, `CLAUDECODE` or `TMUX…`), `add_dirs` (absolute paths),
  `append_system_prompt` (at most 64 KiB), and `allowed_tools` and `disallowed_tools` (patterns
  such as `Bash(git *)`). A list or map holds at most 64, and all of them as JSON at most 256
  KiB, far under the system's limit on a launch's arguments and environment.

      iex> alias CodingAgentFramework.ClaudeCLI.Options
      iex> {:ok, options} = Options.check(%{"env" => %{"APP_MODE" => "review"}, add_dirs: ["/a"]})
      iex> Options.decode(Options.encode(options))
      {:ok, %{env: %{"APP_MODE" => "review"}, add_dirs: ["/a"]}}
      iex> Options.check(%{env: %{"CLAUDE_CONFIG_DIR" => "/tmp"}})
      {:refused, {:bad_option, :env, {:reserved, "CLAUDE_CONFIG_DIR"}}}
  """

  alias CodingAgentFramework.Accounts

  @type t :: %{optional(atom) => term}

  @keys ~w(settings env add_dirs append_system_prompt allowed_tools disallowed_tools)a
  @by_name Map.new(@keys, &{Atom.to_string(&1), &1})
  @flags [
    add_dirs: "--add-dir",
    allowed_tools: "--allowedTools",
    disallowed_tools: "--disallowedTools"
  ]
  @own_settings ~w(hooks statusLine remoteControlAtStartup autoContinueAtUsageLimit disableAllHooks env)
  @own_env ~w(CLAUDE_CONFIG_DIR HOME PATH TERM LANG MCP_TOOL_TIMEOUT
              CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT DISABLE_AUTOUPDATER CLAUDECODE)
  @rules ~w(allow deny ask additionalDirectories)
  @variable ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  # A tool's name, then an optional rule in parentheses with none inside.
  @tool ~r/\A[A-Za-z0-9_][A-Za-z0-9_*.:-]{0,127}(\([^()[:cntrl:]]{0,255}\))?\z/u
  @total 256 * 1024

  @doc "Checks `options` (a map, or nil): `{:ok, options}` with atom keys, or a refusal."
  @spec check(map | nil) :: {:ok, t} | {:refused, {:bad_option, term, term}}
  def check(nil), do: {:ok, %{}}

  def check(options) when is_map(options) do
    checked =
      Enum.reduce_while(options, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
        key = if is_atom(name) and name in @keys, do: name, else: @by_name[name]

        case key && value(key, value) do
          nil -> {:halt, {:refused, {:bad_option, name, :unknown}}}
          :ok -> {:cont, {:ok, Map.put(acc, key, value)}}
          why -> {:halt, {:refused, {:bad_option, key, why}}}
        end
      end)

    with {:ok, all} <- checked,
         true <- json?(all, @total) or {:refused, {:bad_option, :options, {:too_long, @total}}},
         do: checked
  end

  def check(_options), do: {:refused, {:bad_option, :options, :not_a_map}}

  @doc "The options as JSON for an agent's row, or nil for none; `decode/1` checks them again."
  @spec encode(t) :: String.t() | nil
  def encode(options), do: if(options == %{}, do: nil, else: JSON.encode!(options))

  @spec decode(String.t() | nil) :: {:ok, t} | {:refused, term}
  def decode(nil), do: {:ok, %{}}

  def decode(text) do
    case JSON.decode(text) do
      {:ok, map} -> check(map)
      _ -> {:refused, {:bad_option, :options, :not_json}}
    end
  end

  @doc """
  The flags, which go after `--settings` and before `--mcp-config`: a list flag takes values up
  to the next flag, and the prompt is one `--flag=text` word, never read as a flag.
  """
  @spec argv(t) :: [String.t()]
  def argv(options) do
    p = options[:append_system_prompt]

    Enum.flat_map(@flags, fn {key, flag} -> if l = options[key], do: [flag | l], else: [] end) ++
      if p, do: ["--append-system-prompt=" <> p], else: []
  end

  defp value(:settings, %{} = settings) do
    keys = Map.keys(settings)
    p = Map.get(settings, "permissions", %{})
    rules = if is_map(p), do: Map.values(Map.take(p, @rules)), else: [p]

    with :ok <- first(keys, &(&1 not in @own_settings), :reserved),
         :ok <- first(keys, &is_binary/1, :bad_key),
         :ok <- skill_overrides(Map.get(settings, "skillOverrides", %{})),
         :ok <-
           first(rules, &(is_list(&1) and Enum.all?(&1, fn r -> is_binary(r) end)), :bad_rules),
         do: if(json?(settings, @total), do: :ok, else: :not_json)
  end

  defp value(:env, %{} = env) when map_size(env) <= 64 do
    names = Map.keys(env)

    with :ok <- first(names, &(is_binary(&1) and &1 =~ @variable), :bad_name),
         :ok <-
           first(names, &(&1 not in @own_env and not String.starts_with?(&1, "TMUX")), :reserved),
         do: first(Map.values(env), &text?/1, :bad_value)
  end

  defp value(:add_dirs, dirs) when is_list(dirs) and length(dirs) <= 64,
    do:
      first(dirs, &(text?(&1) and Path.type(&1) == :absolute and Path.expand(&1) == &1), :bad_dir)

  defp value(:append_system_prompt, p) when is_binary(p) and p != "",
    do: (byte_size(p) > 65_536 && {:too_long, 65_536}) || (text?(p) && :ok) || :not_text

  defp value(tools, list)
       when tools in [:allowed_tools, :disallowed_tools] and is_list(list) and length(list) <= 64,
       do: first(list, &(is_binary(&1) and &1 =~ @tool), :bad_pattern)

  defp value(_key, _value), do: :bad_value

  # An entry the framework writes (F-285) is refused, as a key it writes is; the others are the
  # agent's, merged one by one over the account's.
  defp skill_overrides(%{} = overrides) do
    own = Map.keys(Accounts.skill_overrides())
    entry? = fn {skill, value} -> is_binary(skill) and text?(value) end

    with :ok <- first(Map.keys(overrides), &(&1 not in own), :reserved_skill),
         do: first(Map.to_list(overrides), entry?, :bad_skill)
  end

  defp skill_overrides(other), do: {:bad_skill, other}

  # `:ok`, or the first item that fails `ok?`, as `{why, item}`.
  defp first(items, ok?, why) do
    case Enum.reject(items, ok?) do
      [] -> :ok
      [bad | _] -> {why, bad}
    end
  end

  defp text?(v), do: is_binary(v) and String.valid?(v) and not String.contains?(v, <<0>>)

  defp json?(value, max) do
    byte_size(JSON.encode!(value)) <= max
  rescue
    _ -> false
  end
end
