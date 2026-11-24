defmodule CodingAgentFramework.ToolHooks do
  @moduledoc ~S"""
  The app's tool hooks, named in the config as data (F-195): `tool_hooks: {module, opts}`,
  where `module` implements a callback per hook it takes and `opts` is plain data, what a
  config file could hold. A function, pid, port or reference in it is refused `{:not_data,
  module}`, and a struct `{:not_data, module, {:struct, struct}}`: the config itself is one, so
  a hook that reads the agent rows names the instance instead
  (`CodingAgentFramework.agent_rows("a")`, F-201). A hook the module does not implement is not
  written into the accounts' settings, so Claude Code never posts it.

  Each callback gets the event as `CodingAgentFramework.Intake` hands it (its `cwd`, where the
  call runs, as Claude Code posted it, or nil, F-201), the config's `opts`,
  and `part`, a lookup of a part's process by its key in the tree (`CodingAgentFramework.parts/1`'s
  keys), called when the hook runs, so a hook reaches the live part after a restart, as an
  extension's tool does (`CodingAgentFramework.Extension`). It answers what `Intake`'s callback
  of the same name answers:

  - `pre_tool_use/3`: `:allow`, `{:deny, reason}`, `:ask`, `:pass`, or a correction
    (`{:allow, updated_input: map, additional_context: text}` and the others `Intake.start_link/1`
    lists), within `Intake`'s tool deadline (5 s by default), else a pass;
  - `post_tool_use/3`: `:pass`, or `{:replace, response}` (F-197) within the same tool
    deadline, else a pass. The call has already run; a replacement changes what the model
    reads of it. `response` is a map of the tool's own response shape, the event's
    `tool_response` (`%{"stdout" => …, "stderr" => "", "interrupted" => false, "isImage" =>
    false}` for `Bash`), and goes out as `updatedToolOutput`. Measured on Claude Code 2.1.322
    with `Bash`, from a command hook and from an `http` hook as the framework's is: an object of
    that shape is what the model reads; a string is ignored, so `Intake` passes it; a hook past
    its `timeout` leaves the output as it was. Not measured: `updatedMCPToolOutput`, an MCP
    tool's output, and an `Edit`'s. Or `{:context, text}` (F-201), a note on the call it is
    about, sent as `additionalContext` (at most 10,000 characters, as `PreToolUse`'s): measured
    on 2.1.322 with `Bash`, from a command hook and from an `http` hook alike, the model reads it
    on that call as "PostToolUse:Bash hook additional context: <text>", and the tool's output
    is unchanged. `{:replace, response, context: text}` does both;
  - `stop/3`: `:pass` (the turn ends) or `{:block, reason}` (the agent goes on, told the reason);
  - `session_start/3` (F-236): `:pass`, or `{:context, text}`, the session's own rules, within
    the same tool deadline, else a pass. The text goes out as `SessionStart`'s
    `additionalContext` (at most 10,000 characters, as the others; a longer one is a pass whose
    row says `context_too_long`), and the model reads it with the session's first prompt. The
    event has `agent`, `account`, `session_id`, `cwd` and `source` (`"startup"`, `"resume"`,
    `"clear"` or `"compact"`). Claude Code 2.1.322 runs no `http` hook on `SessionStart`, so a
    module that implements it gets a `command` hook in the accounts' settings
    (`Intake.start_hook/4`) that posts to `Intake` and prints its answer. Measured on 2.1.322:
    the model reads the context headless and in an interactive start in a trusted folder, but
    not when the start waited on the trust dialog: that session starts without it.

  The framework's own `PreToolUse` callback (a move's drain) decides first, and a heavy
  command's wrapper and a background command's closed stdin apply to what this one answers.

      defmodule App.Hooks do
        @behaviour CodingAgentFramework.ToolHooks

        @impl true
        def pre_tool_use(%{tool_name: "WebFetch"}, opts, _part),
          do: {:deny, "Fetches go through #{opts[:proxy]}."}

        def pre_tool_use(_event, _opts, _part), do: :pass

        @impl true
        def stop(%{agent: agent}, _opts, part), do: App.Board.done?(part.(:mailbox), agent)
      end

      Config.new(..., tool_hooks: {App.Hooks, proxy: "the board"})
  """

  alias CodingAgentFramework.Intake

  @type part :: (atom -> pid | nil)

  @callback pre_tool_use(event :: Intake.tool_event(), opts :: term, part) :: term
  @callback post_tool_use(event :: Intake.tool_event(), opts :: term, part) ::
              :pass | {:replace, map} | {:context, String.t()} | {:replace, map, keyword}
  @callback stop(event :: Intake.stop_event(), opts :: term, part) ::
              :pass | {:block, String.t()}
  @callback session_start(event :: Intake.start_event(), opts :: term, part) ::
              :pass | {:context, String.t()}

  @optional_callbacks pre_tool_use: 3, post_tool_use: 3, stop: 3, session_start: 3

  @hooks [:pre_tool_use, :post_tool_use, :stop, :session_start]

  @doc """
  The hooks a module implements, in `[:pre_tool_use, :post_tool_use, :stop, :session_start]`'s
  order.

      iex> CodingAgentFramework.ToolHooks.implemented(Enum)
      []
  """
  @spec implemented(module) :: [:pre_tool_use | :post_tool_use | :stop | :session_start]
  def implemented(module) when is_atom(module) do
    if Code.ensure_loaded?(module),
      do: Enum.filter(@hooks, &function_exported?(module, &1, 3)),
      else: []
  end

  @doc """
  Each hook the module implements as `Intake`'s callback of one argument, the event, with the
  config's `opts` and the live `part` lookup bound.
  """
  @spec callbacks({module, term} | nil, part) :: %{atom => (map -> term)}
  def callbacks(nil, _part), do: %{}

  def callbacks({module, opts}, part) do
    Map.new(implemented(module), fn hook ->
      {hook, fn event -> apply(module, hook, [event, opts, part]) end}
    end)
  end
end
