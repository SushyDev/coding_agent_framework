defmodule CafTracker.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_tracker,
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
      {:caf_delegates, in_umbrella: true},
      {:caf_intake, in_umbrella: true},
      {:caf_acts, in_umbrella: true, only: :test},
      {:caf_recoveries, in_umbrella: true, only: :test},
      {:caf_sessions, in_umbrella: true},
      {:caf_store, in_umbrella: true},
      {:caf_stream, in_umbrella: true},
      {:caf_accounts, in_umbrella: true, only: :test},
      {:caf_registry, in_umbrella: true, only: :test},
      {:caf_sampler, in_umbrella: true, only: :test},
      {:caf_usage, in_umbrella: true, only: :test},
      {:caf_tmux, in_umbrella: true, only: :test},
      {:caf_test, in_umbrella: true, only: :test},
      {:exqlite, "~> 0.43.0", only: :test},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end
end
