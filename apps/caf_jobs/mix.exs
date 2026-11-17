defmodule CafJobs.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_jobs,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:caf_shell, in_umbrella: true},
      {:caf_copies, in_umbrella: true},
      {:caf_store, in_umbrella: true},
      {:exqlite, "~> 0.43.0", only: :test},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
