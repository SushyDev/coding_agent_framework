defmodule CafMains.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_mains,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:caf_accounts, in_umbrella: true},
      {:caf_intake, in_umbrella: true},
      {:caf_mailbox, in_umbrella: true},
      {:caf_scheduler, in_umbrella: true},
      {:caf_sessions, in_umbrella: true},
      {:caf_shell, in_umbrella: true},
      {:caf_store, in_umbrella: true},
      {:caf_stream, in_umbrella: true},
      {:caf_usage, in_umbrella: true},
      {:caf_grants, in_umbrella: true, only: :test},
      {:caf_inlet, in_umbrella: true, only: :test},
      {:caf_registry, in_umbrella: true, only: :test},
      {:caf_transcripts, in_umbrella: true, only: :test},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
