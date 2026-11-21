defmodule CafPrompts.MixProject do
  use Mix.Project

  # The inbox (B6, F-179): one reader of every request that waits on a person, over the rows of
  # the parts that own them, and one answer through each owner.
  def project do
    [
      app: :caf_prompts,
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
      {:caf_mailbox, in_umbrella: true},
      {:caf_logins, in_umbrella: true},
      {:caf_sessions, in_umbrella: true},
      {:caf_watch, in_umbrella: true},
      {:caf_stream, in_umbrella: true},
      {:caf_accounts, in_umbrella: true, only: :test},
      {:caf_grants, in_umbrella: true, only: :test},
      {:caf_inlet, in_umbrella: true, only: :test},
      {:caf_test, in_umbrella: true, only: :test}
    ]
  end
end
