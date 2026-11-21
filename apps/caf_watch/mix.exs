defmodule CafWatch.MixProject do
  use Mix.Project

  # The Watch's record (B7's start, B8; F-182): each symptom a fact with its state, the
  # remedies' allow-list and its acts, and the `remedy` prompt's row.
  def project do
    [
      app: :caf_watch,
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
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
