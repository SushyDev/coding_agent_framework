defmodule CafSampler.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_sampler,
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
      {:caf_holder, in_umbrella: true},
      {:caf_tmux, in_umbrella: true},
      {:exqlite, "~> 0.43.0"}
    ]
  end
end
