defmodule CafSessions.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_sessions,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # The setup its tests share with tests in apps above it compiles only for tests.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:caf_cli, in_umbrella: true},
      {:caf_control, in_umbrella: true},
      {:caf_holder, in_umbrella: true},
      {:caf_registry, in_umbrella: true},
      {:caf_shell, in_umbrella: true},
      {:caf_stream, in_umbrella: true},
      {:caf_transcripts, in_umbrella: true},
      {:exqlite, "~> 0.43.0"},
      {:caf_accounts, in_umbrella: true, only: :test},
      {:caf_test, in_umbrella: true, only: :test},
      {:caf_tmux, in_umbrella: true, only: :test}
    ]
  end
end
