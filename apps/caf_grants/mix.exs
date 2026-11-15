defmodule CafGrants.MixProject do
  use Mix.Project

  def project do
    [
      app: :caf_grants,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  defp deps do
    [{:stream_data, "~> 1.4", only: :test}]
  end
end
