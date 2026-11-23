defmodule CodingAgentFramework.Real do
  @moduledoc """
  The end-to-end run as tests against the real Claude Code (F-223). The app holds no code of its
  own: its tests (`apps/caf_real/test`, tagged `:real`) start the example app's tree in a home of
  their own and drive it as `docs/e2e.md`'s console does. Only `mix test.real` runs them, given
  `CAF_REAL_SETUP`, the home a `bin/caf-login --setup` logged accounts `one` and `two` in.
  """
end
