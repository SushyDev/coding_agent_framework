defmodule CodingAgentFramework.MixProject do
  use Mix.Project

  # An umbrella: one OTP app per part under apps/ ("The parts" in docs/design.md). Each app
  # declares only the apps and packages it uses. Elixir refuses a module from outside an app's
  # dependency tree; `MIX_ENV=test mix caf.deps` (gate-deps) checks each declaration is direct.
  # The apps are libraries: none starts a process of its own; the host app's supervision tree
  # starts each part.
  def project do
    [apps_path: "apps", version: "0.1.0", deps: [], aliases: aliases()]
  end

  # The end-to-end run against the real Claude Code (F-223): only `caf_real`'s tests, tagged
  # `:real`, which every other run leaves out.
  def cli, do: [preferred_envs: ["test.real": :test]]

  defp aliases, do: ["test.real": ["test --only real"]]
end
