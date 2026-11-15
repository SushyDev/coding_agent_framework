defmodule CodingAgentFramework.MixProject do
  use Mix.Project

  # An umbrella: one OTP app per part under apps/ ("The parts" in docs/design.md). Each app
  # declares only the apps and packages it uses, so a use it does not declare does not compile.
  # The apps are libraries: none starts a process of its own; the host app's supervision tree
  # starts each part.
  def project do
    [apps_path: "apps", version: "0.1.0", deps: []]
  end
end
