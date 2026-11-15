defmodule CafAccounts.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_accounts,
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
      {:caf_intake, in_umbrella: true},
      {:caf_shell, in_umbrella: true}
    ]
  end
end
