defmodule CafScheduler.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_scheduler,
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
      {:caf_store, in_umbrella: true},
      {:telemetry, "~> 1.4"},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
