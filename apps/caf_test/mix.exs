defmodule CafTest.MixProject do
  use Mix.Project

  # The shared test aids: the per-VM directory, the programs from devenv and the stand-ins.
  # Other apps use it `only: :test`. It also holds the tests of caf_shell, which its aids use,
  # and the model test, which runs bin/check-model.
  def project do
    [
      app: :caf_test,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # The aids compile only for tests, as they did under test/support.
  defp elixirc_paths(:test), do: ["lib"]
  defp elixirc_paths(_), do: []

  defp deps do
    [
      {:caf_shell, in_umbrella: true},
      # Dev too, so that `mix format` can import its formatter rules.
      {:stream_data, "~> 1.4", only: [:dev, :test]}
    ]
  end
end
