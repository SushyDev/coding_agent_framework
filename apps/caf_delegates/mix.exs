defmodule CafDelegates.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_delegates,
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
      {:caf_sessions, in_umbrella: true},
      {:caf_stream, in_umbrella: true},
      {:caf_transcripts, in_umbrella: true},
      {:caf_usage, in_umbrella: true},
      {:exqlite, "~> 0.43.0"},
      {:caf_holder, in_umbrella: true, only: :test},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
