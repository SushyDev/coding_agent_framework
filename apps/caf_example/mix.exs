defmodule CafExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_example,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  # The example: a config file and a console over the app's surface (`caf_surface`).
  defp deps do
    [
      {:caf_surface, in_umbrella: true},
      {:caf_acts, in_umbrella: true},
      {:caf_intake, in_umbrella: true},
      {:caf_mailbox, in_umbrella: true},
      {:caf_mains, in_umbrella: true},
      {:caf_mcp, in_umbrella: true},
      {:caf_recoveries, in_umbrella: true},
      {:caf_usage, in_umbrella: true},
      {:caf_scheduler, in_umbrella: true},
      {:caf_sessions, in_umbrella: true},
      {:caf_shell, in_umbrella: true},
      {:caf_tmux, in_umbrella: true, only: :test},
      {:caf_tool_home, in_umbrella: true},
      {:bandit, "~> 1.14"},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
