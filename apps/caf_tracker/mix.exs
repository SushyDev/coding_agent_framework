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

  # The tests of Intake, Usage, Sessions, TmuxSampler and Recoveries live here, not in their own
  # apps: each also reads its rows through a Tracker source, and an app's test may not use an
  # app above it (Mix refuses the cycle). The test-only apps and packages below are theirs.
  defp deps do
    [
      {:caf_intake, in_umbrella: true},
      {:caf_recoveries, in_umbrella: true},
      {:caf_registry, in_umbrella: true},
      {:caf_sampler, in_umbrella: true},
      {:caf_sessions, in_umbrella: true},
      {:caf_stream, in_umbrella: true},
      {:caf_transcripts, in_umbrella: true},
      {:caf_usage, in_umbrella: true},
      {:caf_accounts, in_umbrella: true, only: :test},
      {:caf_control, in_umbrella: true, only: :test},
      {:caf_holder, in_umbrella: true, only: :test},
      {:caf_tmux, in_umbrella: true, only: :test},
      {:caf_test, in_umbrella: true, only: :test},
      {:bandit, "~> 1.14", only: :test},
      {:exqlite, "~> 0.43.0", only: :test},
      {:plug, "~> 1.20", only: :test},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end
end
