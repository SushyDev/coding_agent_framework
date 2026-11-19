defmodule CafMailbox.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_mailbox,
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
      {:caf_accounts, in_umbrella: true},
      {:caf_acts, in_umbrella: true},
      {:caf_cli, in_umbrella: true},
      {:caf_grants, in_umbrella: true},
      {:caf_inlet, in_umbrella: true},
      {:caf_intake, in_umbrella: true},
      {:caf_registry, in_umbrella: true},
      {:caf_sessions, in_umbrella: true},
      {:caf_shell, in_umbrella: true},
      {:caf_stream, in_umbrella: true},
      {:caf_store, in_umbrella: true},
      {:caf_transcripts, in_umbrella: true},
      {:exqlite, "~> 0.43.0", only: :test},
      {:bandit, "~> 1.14", only: :test},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
