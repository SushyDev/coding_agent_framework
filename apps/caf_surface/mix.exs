defmodule CafSurface.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_surface,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  # The app's surface (B3): the one app that starts and wires every part, so it declares each.
  defp deps do
    [
      {:caf_accounts, in_umbrella: true},
      {:caf_acts, in_umbrella: true},
      {:caf_cli, in_umbrella: true},
      {:caf_copies, in_umbrella: true},
      {:caf_hosts, in_umbrella: true},
      {:caf_cues, in_umbrella: true},
      {:caf_delegates, in_umbrella: true},
      {:caf_grants, in_umbrella: true},
      {:caf_holder, in_umbrella: true},
      {:caf_inlet, in_umbrella: true},
      {:caf_intake, in_umbrella: true},
      {:caf_jobs, in_umbrella: true},
      {:caf_logins, in_umbrella: true},
      {:caf_mailbox, in_umbrella: true},
      {:caf_mains, in_umbrella: true},
      {:caf_mcp, in_umbrella: true},
      {:caf_mover, in_umbrella: true},
      {:caf_recoveries, in_umbrella: true},
      {:caf_runs, in_umbrella: true},
      {:caf_prompts, in_umbrella: true},
      {:caf_registry, in_umbrella: true},
      {:caf_sampler, in_umbrella: true},
      {:caf_services, in_umbrella: true},
      {:caf_scheduler, in_umbrella: true},
      {:caf_sessions, in_umbrella: true},
      {:caf_shell, in_umbrella: true},
      {:caf_store, in_umbrella: true},
      {:caf_stream, in_umbrella: true},
      {:caf_tmux, in_umbrella: true},
      {:caf_tool_home, in_umbrella: true},
      {:caf_tracker, in_umbrella: true},
      {:caf_transcripts, in_umbrella: true},
      {:caf_usage, in_umbrella: true},
      {:caf_watch, in_umbrella: true},
      {:bandit, "~> 1.14"},
      {:plug, "~> 1.20"},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
