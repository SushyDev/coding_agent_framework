defmodule CafReal.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_real,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The end-to-end run as tests against the real Claude Code (F-223): the example app's tree,
  # driven as its console drives it. Its tests are tagged `:real` and run only by
  # `mix test.real`; no gate runs them.
  defp deps do
    [
      {:caf_example, in_umbrella: true, only: :test},
      {:caf_surface, in_umbrella: true, only: :test},
      {:caf_mcp, in_umbrella: true, only: :test},
      {:caf_mains, in_umbrella: true, only: :test},
      {:caf_sessions, in_umbrella: true, only: :test},
      {:caf_acts, in_umbrella: true, only: :test},
      {:caf_stream, in_umbrella: true, only: :test},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
