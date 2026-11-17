defmodule CafStore.MixProject do
  use Mix.Project

  # A base app: the SQLite table code every writer used to repeat. It starts no process.
  def project do
    [
      app: :caf_store,
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
      {:exqlite, "~> 0.43.0"},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
