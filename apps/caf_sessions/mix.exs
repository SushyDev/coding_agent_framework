defmodule CafSessions.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_sessions,
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
      {:caf_cli, in_umbrella: true},
      {:caf_control, in_umbrella: true},
      {:caf_holder, in_umbrella: true},
      {:caf_registry, in_umbrella: true},
      {:caf_shell, in_umbrella: true},
      {:exqlite, "~> 0.43.0"}
    ]
  end
end
