defmodule CodingAgentFramework.MixProject do
  use Mix.Project

  def project do
    [
      app: :coding_agent_framework,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # A library: it starts no processes of its own, so it has no application callback. The host
  # app's supervision tree starts each part.
  def application do
    [extra_applications: [:logger]]
  end

  # Test aids (the stand-ins and the per-VM directory) compile only for tests.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:exqlite, "~> 0.43.0"},
      {:plug, "~> 1.20"},
      # The library starts no server: the host app runs one. Tests run Bandit with Intake's plug.
      {:bandit, "~> 1.14", only: :test},
      {:stream_data, "~> 1.4", only: [:dev, :test]}
    ]
  end
end
