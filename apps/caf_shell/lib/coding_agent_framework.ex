defmodule CodingAgentFramework do
  @moduledoc """
  Runs and supervises Claude Code agents across Claude accounts and machines.

  This is a library: it starts no processes. An embedding app's supervision tree starts each part,
  per instance, so two instances can run in one app. The parts and the order they are built in
  are in `docs/design.md`. The protocols they follow are written and checked first, as TLA+
  specs in `model/tla/` (`bin/check-model`).
  """
end
