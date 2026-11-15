defmodule Mix.Tasks.Caf.Deps do
  @shortdoc "Checks that each umbrella app declares every umbrella app it uses"

  @moduledoc """
  Fails when an app's code names a module of an umbrella app it does not declare directly, or
  when an app declares an umbrella app its code (or, for an `only: :test` entry, its tests) never
  names. Hex packages are not checked. `CodingAgentFramework.DepsGate` decides; this task gathers
  and prints.

  Run it from the umbrella root, in the test env, so that `caf_test` and its own code compile:

      MIX_ENV=test mix caf.deps

  What the code names comes from each app's compile manifest, the data `mix xref` reads, for
  sources outside `test/`. What the tests name, `test/support/` included, comes from reading
  `test/**/*.{ex,exs}` with `DepsGate.names_in/1`; nothing in them runs.
  """

  use Mix.Task

  require Mix.Compilers.Elixir, as: Manifest
  alias CodingAgentFramework.DepsGate

  @impl Mix.Task
  def run(_args) do
    if !Mix.Project.umbrella?(), do: Mix.raise("caf.deps runs from the umbrella root")
    Mix.Task.run("compile", [])

    apps = for {app, path} <- Enum.sort(Mix.Project.apps_paths()), do: gather(app, path)

    case DepsGate.check(apps) do
      [] ->
        Mix.shell().info("caf.deps: each of #{length(apps)} apps declares the apps it uses")

      problems ->
        Enum.each(problems, &Mix.shell().error(describe(&1)))
        Mix.raise("caf.deps: #{length(problems)} found, each named above")
    end
  end

  defp gather(app, path) do
    Mix.Project.in_project(app, path, fn _module ->
      {modules, sources} =
        Mix.Project.manifest_path()
        |> Path.join("compile.elixir")
        |> Manifest.read_manifest()

      # A part's `test/support/` compiles in the test env (F-42), so the manifest holds it too;
      # it is test code, read below with the other test files, not counted as the app's code.
      code =
        for {path, source} <- sources,
            not String.starts_with?(Path.relative_to_cwd(path), "test/"),
            module <- references(source),
            uniq: true,
            do: module

      tests =
        for file <- Path.wildcard("test/**/*.{ex,exs}"),
            module <-
              file |> File.read!() |> Code.string_to_quoted!(file: file) |> DepsGate.names_in(),
            uniq: true,
            do: module

      %{
        app: app,
        deps: umbrella_deps(Mix.Project.config()[:deps]),
        modules: Map.keys(modules),
        code: code,
        tests: tests
      }
    end)
  end

  # A manifest's source entry is a Mix.Compilers.Elixir `source` record; a reference of any
  # kind (compile, export, runtime) is a use.
  defp references(source) do
    Manifest.source(source, :compile_references) ++
      Manifest.source(source, :export_references) ++
      Manifest.source(source, :runtime_references)
  end

  defp umbrella_deps(deps) do
    for dep <- deps, opts = List.last(Tuple.to_list(dep)), is_list(opts), opts[:in_umbrella] do
      {elem(dep, 0), if(opts[:only] in [:test, [:test]], do: :test, else: :code)}
    end
  end

  defp describe({:undeclared, app, :code, module, owner}),
    do:
      "#{app}: its code names #{inspect(module)} of #{owner}, which #{app} does not declare for its code"

  defp describe({:undeclared, app, :test, module, owner}),
    do: "#{app}: its tests name #{inspect(module)} of #{owner}, which #{app} does not declare"

  defp describe({:unused, app, dep, :code}),
    do: "#{app}: declares #{dep}, and its code names no module of it"

  defp describe({:unused, app, dep, :test}),
    do: "#{app}: declares #{dep} only: :test, and its tests name no module of it"
end
