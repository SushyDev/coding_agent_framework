defmodule CafMover.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_mover,
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

  defp deps do
    [
      {:caf_accounts, in_umbrella: true},
      {:caf_acts, in_umbrella: true},
      {:caf_mailbox, in_umbrella: true},
      {:caf_sessions, in_umbrella: true},
      {:caf_transcripts, in_umbrella: true},
      {:caf_usage, in_umbrella: true},
      {:bandit, "~> 1.14", only: :test},
      {:caf_cues, in_umbrella: true, only: :test},
      {:caf_grants, in_umbrella: true, only: :test},
      {:caf_holder, in_umbrella: true, only: :test},
      {:caf_intake, in_umbrella: true, only: :test},
      {:caf_registry, in_umbrella: true, only: :test},
      {:caf_shell, in_umbrella: true, only: :test},
      {:caf_stream, in_umbrella: true, only: :test},
      {:caf_test, in_umbrella: true, only: :test},
      {:caf_tmux, in_umbrella: true, only: :test}
    ]
  end
end
