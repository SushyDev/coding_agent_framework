defmodule CafIntake.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_intake,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:crypto]]

  defp deps do
    [
      {:exqlite, "~> 0.43.0"},
      {:plug, "~> 1.20"}
    ]
  end
end
