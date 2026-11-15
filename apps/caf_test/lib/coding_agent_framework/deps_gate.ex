defmodule CodingAgentFramework.DepsGate do
  @moduledoc """
  Checks that each umbrella app declares, directly, every umbrella app it uses, and uses every
  umbrella app it declares. `mix caf.deps` gathers the facts and prints what this returns.

  Elixir accepts a module from any app in the dependency tree, so a use that only reaches an app
  through another declared app still compiles. This check closes that gap.

  Each app is a map:

    * `:app`: its name.
    * `:deps`: the umbrella apps it declares, each `{app, :code}`, or `{app, :test}` for an
      `only: :test` entry.
    * `:modules`: the modules it defines.
    * `:code`: the modules its code names (from xref).
    * `:tests`: the modules its tests name (from `names_in/1`).

  A module no app defines (a test module, a Hex package's) is not checked here.
  """

  @type kind :: :code | :test
  @type app :: %{
          app: atom(),
          deps: [{atom(), kind()}],
          modules: [module()],
          code: [module()],
          tests: [module()]
        }
  @type problem ::
          {:undeclared, app :: atom(), kind(), module(), owner :: atom()}
          | {:unused, app :: atom(), dep :: atom(), kind()}

  @doc """
  Returns every problem, sorted. An empty list means every app declares what it uses.

  Code may name only an app it declares for code. Tests may name an app it declares either way.
  A code dep must be named by the code, and an `only: :test` dep by the tests.

      iex> shell = %{app: :shell, deps: [], modules: [Shell], code: [], tests: []}
      iex> holder = %{app: :holder, deps: [{:shell, :code}], modules: [Holder], code: [Shell], tests: []}
      iex> stream = %{app: :stream, deps: [{:holder, :code}], modules: [Stream], code: [Holder, Shell], tests: []}
      iex> CodingAgentFramework.DepsGate.check([shell, holder, stream])
      [{:undeclared, :stream, :code, Shell, :shell}]

      iex> cli = %{app: :cli, deps: [{:shell, :test}], modules: [CLI], code: [], tests: []}
      iex> shell = %{app: :shell, deps: [], modules: [Shell], code: [], tests: []}
      iex> CodingAgentFramework.DepsGate.check([cli, shell])
      [{:unused, :cli, :shell, :test}]
  """
  @spec check([app()]) :: [problem()]
  def check(apps) do
    owners = for a <- apps, m <- a.modules, into: %{}, do: {m, a.app}

    apps
    |> Enum.flat_map(&problems(&1, owners))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp problems(a, owners) do
    code_deps = for {d, :code} <- a.deps, do: d
    all_deps = Enum.map(a.deps, &elem(&1, 0))
    used = fn mods -> for m <- mods, o = owners[m], o != nil, o != a.app, do: {m, o} end
    code_used = used.(a.code)
    tests_used = used.(a.tests)

    undeclared =
      for({m, o} <- code_used, o not in code_deps, do: {:undeclared, a.app, :code, m, o}) ++
        for {m, o} <- tests_used, o not in all_deps, do: {:undeclared, a.app, :test, m, o}

    unused =
      for {d, kind} <- a.deps,
          d not in Enum.map(if(kind == :code, do: code_used, else: tests_used), &elem(&1, 1)),
          do: {:unused, a.app, d, kind}

    undeclared ++ unused
  end

  @doc """
  Returns the modules a test file names, given its quoted form.

  An `alias` names each module it aliases, and the names after it expand through it. An alias
  inside a nested module counts to the end of the file, not of that module: a test file aliases
  at its top. A name built on `__MODULE__`, built at run time (`Module.concat/1`) or written as
  an atom is left out.

      iex> quoted = Code.string_to_quoted!(\"""
      ...> alias CodingAgentFramework.{Holder, Tmux}
      ...> alias Tmux.CLI, as: TmuxCLI
      ...> Holder.args(TmuxCLI)
      ...> Enum.map([], & &1)
      ...> \""")
      iex> CodingAgentFramework.DepsGate.names_in(quoted)
      [CodingAgentFramework.Holder, CodingAgentFramework.Tmux, CodingAgentFramework.Tmux.CLI, Enum]
  """
  @spec names_in(Macro.t()) :: [module()]
  def names_in(quoted) do
    {_, {_aliases, names}} = Macro.prewalk(quoted, {%{}, []}, &name/2)
    names |> Enum.uniq() |> Enum.sort()
  end

  # An alias form is not walked into: its base (`CodingAgentFramework` in
  # `alias CodingAgentFramework.{A, B}`) is not a use.
  defp name({:alias, _, _} = node, {aliases, names}) do
    acc =
      Enum.reduce(alias_targets(node), {aliases, names}, fn {parts, as}, {aliases, names} ->
        module = expand(parts, aliases)
        {Map.put(aliases, as, Module.split(module)), [module | names]}
      end)

    {nil, acc}
  end

  defp name({:__aliases__, _, [first | _] = parts}, {aliases, names}) when is_atom(first),
    do: {nil, {aliases, [expand(parts, aliases) | names]}}

  defp name(node, acc), do: {node, acc}

  # Each {parts, as} an alias form sets up, with the parts as written.
  defp alias_targets({:alias, _, [{:__aliases__, _, [first | _] = parts} | rest]})
       when is_atom(first) do
    case rest do
      [opts] when is_list(opts) -> [{parts, as(opts[:as], parts)}]
      _ -> [{parts, List.last(parts)}]
    end
  end

  defp alias_targets(
         {:alias, _, [{{:., _, [{:__aliases__, _, [first | _] = base}, :{}]}, _, children} | _]}
       )
       when is_atom(first),
       do: for({:__aliases__, _, parts} <- children, do: {base ++ parts, List.last(parts)})

  defp alias_targets(_), do: []

  defp as({:__aliases__, _, [as]}, _parts), do: as
  defp as(_, parts), do: List.last(parts)

  defp expand([first | rest], aliases) do
    case aliases do
      %{^first => target} -> Module.concat(target ++ rest)
      _ -> Module.concat([first | rest])
    end
  end
end
