defmodule CafLogins.MixProject do
  use Mix.Project

  # Each account's login, read with `claude auth status` and kept a while (F-181, F-177's
  # new-2): read before a start or a resume, and a refused one a `login` prompt.
  def project do
    [
      app: :caf_logins,
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
      {:caf_store, in_umbrella: true},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
