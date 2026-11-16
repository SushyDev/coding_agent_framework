defmodule CafMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_mcp,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:crypto]]

  defp deps do
    [
      {:caf_grants, in_umbrella: true},
      {:exqlite, "~> 0.43.0"},
      {:plug, "~> 1.20"},
      {:caf_copies, in_umbrella: true, only: :test},
      {:caf_jobs, in_umbrella: true, only: :test},
      {:caf_test, in_umbrella: true, only: :test},
      {:bandit, "~> 1.14", only: :test}
    ]
  end
end
