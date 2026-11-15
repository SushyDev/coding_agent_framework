defmodule CafCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_cli,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  # Accounts' test lives here: it holds a stand-in with ClaudeCLI's environment, and caf_cli
  # uses caf_accounts, so caf_accounts' own tests may not use caf_cli.
  defp deps do
    [
      {:caf_accounts, in_umbrella: true},
      {:caf_holder, in_umbrella: true, only: :test},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
