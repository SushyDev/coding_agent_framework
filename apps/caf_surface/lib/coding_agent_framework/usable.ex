defmodule CodingAgentFramework.Usable do
  @moduledoc ~S"""
  Which accounts the app lets a start use, named in the config as data (F-207): `usable:
  {module, opts}`, where `module` implements `usable?/3` and `opts` is plain data, what a config
  file could hold, as `tool_hooks`' and `extensions`' are. A function, pid, port or reference in
  it is refused `{:not_data, module}`, and a struct `{:not_data, module, {:struct, struct}}`.
  A function in place of the pair is refused `{:not_usable, value}`.

  An app refuses its own starts on an account it has flagged (two accounts logged in to one
  organization, say). A start the framework makes itself picks its account without asking the
  app: a delegate's, by its parent's call or the operator's, one that waited at a usage limit,
  a main session's, a move's. So the tree hands the module to every part that picks an account
  (`Delegates`, `Mains` and the `Mover`, as their `usable:`), beside its own check
  (`CodingAgentFramework.Logins.usable/3`: prepared and logged in). An account is usable only
  if both say so; the framework's check is read first, and its refusal is the answer when it
  refuses. With no `usable` in the config, its check alone decides.

  `usable?(account, opts, part)` gets the account's name, the config's `opts` and `part`, a
  lookup of a part's process by its key in the tree (`CodingAgentFramework.parts/1`'s keys),
  called when the check runs, so it reaches the live part after a restart. It answers `true`,
  or `{false, reason}`, `reason` any term a person can read. It runs in the process of the part
  that picks, at each pick and for each account, so it answers from what the app already holds,
  and does not wait.

  A refused account reads in the pick's refusal as `{:refused, {:app, reason}}`, tagged so the
  app's reason is never taken for the framework's own (a `{:allowance, retry_at}` of its own
  would read as a usage limit). A pick that finds none usable says why for each:

      {:refused, {:none_usable, %{"work" => {:refused, {:app, "same organization as side"}}}}}

  A callback that raises, exits, or answers something else is `{:unknown, {:raised, module,
  message}}`, `{:unknown, {:exit, module, reason}}` or `{:unknown, {:bad_answer, module,
  answer}}`: the account is not picked, and the part goes on.

      defmodule App.Accounts do
        @behaviour CodingAgentFramework.Usable

        @impl true
        def usable?(account, opts, _part) do
          if account in opts[:flagged], do: {false, "flagged by the app"}, else: true
        end
      end

      Config.new(..., usable: {App.Accounts, flagged: ["side"]})
  """

  @type part :: (atom -> pid | nil)

  @callback usable?(account :: String.t(), opts :: term, part) :: true | {false, term}

  @doc """
  Whether `module` implements `usable?/3`.

      iex> CodingAgentFramework.Usable.implemented?(Enum)
      false
      iex> CodingAgentFramework.Usable.implemented?(NoSuchModule)
      false
  """
  @spec implemented?(module) :: boolean
  def implemented?(module) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :usable?, 3)

  @doc """
  What the app says of `account`: `:ok` (usable, or the config has no `usable`),
  `{:refused, {:app, reason}}`, or `{:unknown, reason}` for a callback that raised, exited or
  answered something that is neither `true` nor `{false, reason}`. `part` is the live lookup of
  a part by its key.

      iex> CodingAgentFramework.Usable.check(nil, "work", fn _ -> nil end)
      :ok
  """
  @spec check({module, term} | nil, String.t(), part) ::
          :ok | {:refused, {:app, term}} | {:unknown, term}
  def check(nil, _account, _part), do: :ok

  def check({module, opts}, account, part) do
    case module.usable?(account, opts, part) do
      true -> :ok
      {false, reason} -> {:refused, {:app, reason}}
      other -> {:unknown, {:bad_answer, module, other}}
    end
  rescue
    e -> {:unknown, {:raised, module, Exception.message(e)}}
  catch
    :exit, reason -> {:unknown, {:exit, module, reason}}
  end
end
