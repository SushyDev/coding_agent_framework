defmodule CodingAgentFramework.DepsGateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CodingAgentFramework.DepsGate

  doctest CodingAgentFramework.DepsGate

  # An umbrella of up to six apps, :a0 to :a5, that each declare exactly what they use: a code
  # dep for each app their code names, a test dep for each app only their tests name. App i owns
  # the modules :"a<i>.m<j>", and uses only modules of apps 0 to i, so there is no cycle.
  defp umbrella do
    gen all sizes <- list_of(integer(1..3), min_length: 2, max_length: 6),
            uses = list_of(integer(0..20), min_length: 1),
            picks <- list_of({uses, list_of(integer(0..20))}, length: length(sizes)) do
      owned = for {size, i} <- Enum.with_index(sizes), do: for(j <- 1..size, do: :"a#{i}.m#{j}")

      for {{code, tests}, i} <- Enum.with_index(picks) do
        below = owned |> Enum.take(i + 1) |> List.flatten()
        code = for p <- code, do: Enum.at(below, rem(p, length(below)))
        tests = for p <- tests, do: Enum.at(below, rem(p, length(below)))
        code_apps = Enum.uniq(Enum.map(code, &owner/1)) -- [:"a#{i}"]
        test_apps = Enum.uniq(Enum.map(tests, &owner/1)) -- [:"a#{i}" | code_apps]

        %{
          app: :"a#{i}",
          deps: Enum.map(code_apps, &{&1, :code}) ++ Enum.map(test_apps, &{&1, :test}),
          modules: Enum.at(owned, i),
          code: code,
          tests: tests
        }
      end
    end
  end

  defp owner(module),
    do: module |> Atom.to_string() |> String.split(".") |> hd() |> String.to_atom()

  # An umbrella, the index of one of its apps that `fit?` holds for, and a number to choose with.
  defp umbrella_app(fit?) do
    gen all apps <- umbrella(),
            fits = for({a, i} <- Enum.with_index(apps), fit?.(a, apps), do: i),
            fits != [],
            n <- integer(0..20) do
      {apps, at(fits, n), n}
    end
  end

  defp code_deps(a), do: for({d, :code} <- a.deps, do: d)

  defp extra_deps(a, apps),
    do: Enum.map(apps, & &1.app) -- [a.app | Enum.map(a.deps, &elem(&1, 0))]

  defp at(list, n), do: Enum.at(list, rem(n, length(list)))

  property "an umbrella whose apps declare exactly what they use has no problem" do
    check all apps <- umbrella(), order <- list_of(integer(), length: length(apps)) do
      assert DepsGate.check(apps) == []

      assert apps
             |> Enum.zip(order)
             |> Enum.sort_by(&elem(&1, 1))
             |> Enum.map(&elem(&1, 0))
             |> DepsGate.check() == []
    end
  end

  property "a removed dep is named once per module that code or tests use of it" do
    check all {apps, i, n} <- umbrella_app(fn a, _ -> a.deps != [] end) do
      a = Enum.at(apps, i)
      {dep, _} = at(a.deps, n)
      apps = List.replace_at(apps, i, %{a | deps: List.keydelete(a.deps, dep, 0)})

      expected =
        for(m <- Enum.uniq(a.code), owner(m) == dep, do: {:undeclared, a.app, :code, m, dep}) ++
          for m <- Enum.uniq(a.tests), owner(m) == dep, do: {:undeclared, a.app, :test, m, dep}

      assert expected != []
      assert DepsGate.check(apps) == Enum.sort(expected)
    end
  end

  property "a code dep declared only: :test fails for each module the code names" do
    check all {apps, i, n} <- umbrella_app(fn a, _ -> code_deps(a) != [] end) do
      a = Enum.at(apps, i)
      dep = at(code_deps(a), n)
      apps = List.replace_at(apps, i, %{a | deps: List.keyreplace(a.deps, dep, 0, {dep, :test})})

      expected =
        for(m <- Enum.uniq(a.code), owner(m) == dep, do: {:undeclared, a.app, :code, m, dep}) ++
          if Enum.any?(a.tests, &(owner(&1) == dep)), do: [], else: [{:unused, a.app, dep, :test}]

      assert DepsGate.check(apps) == Enum.sort(expected)
    end
  end

  property "an extra dep that nothing names is the only problem" do
    check all {apps, i, n} <- umbrella_app(&(extra_deps(&1, &2) != [])),
              kind <- member_of([:code, :test]) do
      a = Enum.at(apps, i)
      dep = at(extra_deps(a, apps), n)
      apps = List.replace_at(apps, i, %{a | deps: [{dep, kind} | a.deps]})
      assert DepsGate.check(apps) == [{:unused, a.app, dep, kind}]
    end
  end

  property "a module no app defines is not checked" do
    check all apps <- umbrella(), others <- list_of(atom(:alias)) do
      assert apps
             |> Enum.map(&%{&1 | code: &1.code ++ others, tests: others ++ &1.tests})
             |> DepsGate.check() == []
    end
  end

  property "names_in reads each module a file names, through its aliases" do
    check all parts <- uniq_list_of(string(?A..?Z, length: 1..2), min_length: 1, max_length: 6),
              split <- integer(0..6) do
      {grouped, single} = Enum.split(parts, split)

      group =
        if grouped == [],
          do: "",
          else: "alias CodingAgentFramework.{#{Enum.join(grouped, ", ")}}\n"

      singles = for p <- single, do: "alias CodingAgentFramework.Sub.#{p}, as: Single#{p}\n"
      calls = Enum.map(grouped, &"#{&1}.f()\n") ++ Enum.map(single, &"Single#{&1}.Inner.g()\n")
      quoted = Code.string_to_quoted!(group <> Enum.join(singles) <> Enum.join(calls))

      expected =
        Enum.map(grouped, &Module.concat(CodingAgentFramework, &1)) ++
          Enum.flat_map(
            single,
            &[
              Module.concat([CodingAgentFramework, Sub, &1]),
              Module.concat([CodingAgentFramework, Sub, &1, Inner])
            ]
          )

      assert DepsGate.names_in(quoted) == Enum.sort(expected)
    end
  end

  test "names_in leaves out an alias's base, names on __MODULE__ and a variable named alias" do
    quoted =
      Code.string_to_quoted!("""
      alias CodingAgentFramework.{Shell}
      alias __MODULE__.Probe
      alias = 1
      __MODULE__.Probe.run(alias)
      """)

    assert DepsGate.names_in(quoted) == [CodingAgentFramework.Shell]
  end
end
