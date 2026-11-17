defmodule CafCues.MixProject do
  use Mix.Project

  # A base app: the router of one instance's cues. It uses no other app: each part declares
  # what it reads as data, and the embedding app hands those declarations to `Cues`.
  def project do
    [
      app: :caf_cues,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
