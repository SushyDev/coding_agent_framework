defmodule CafScreen.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_screen,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: []
    ]
  end
end
