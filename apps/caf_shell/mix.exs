defmodule CafShell.MixProject do
  use Mix.Project

  # The host layer's base: Host, Shell, Shell.Reaper and Programs. It uses no other app.
  def project do
    [
      app: :caf_shell,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: []
    ]
  end
end
