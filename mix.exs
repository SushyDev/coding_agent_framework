defmodule CodingAgentFramework.MixProject do
  use Mix.Project

  def project do
    [
      app: :coding_agent_framework,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # A library: it starts no processes of its own, so it has no application callback. The host
  # app's supervision tree starts each part.
  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    []
  end
end
