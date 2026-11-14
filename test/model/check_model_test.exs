defmodule CodingAgentFramework.Model.CheckModelTest do
  @moduledoc """
  Runs `bin/check-model all`: TLC on every fast configuration in `model/tla/`. It passes only
  when each design configuration finds no violation and each `Break_*` configuration finds the
  bug it was given. Run it alone with `mix test --only model`.
  """
  use ExUnit.Case, async: true

  @moduletag :model
  # TLC takes about a minute for every fast configuration; the bound leaves room for a loaded
  # machine and still ends a hung run.
  @moduletag timeout: 300_000

  @root Path.expand("../..", __DIR__)

  test "every fast TLC configuration passes" do
    assert System.find_executable("tlc"),
           "tlc is not on the PATH; run the tests inside devenv: devenv shell -- mix test"

    {output, status} =
      System.cmd(Path.join(@root, "bin/check-model"), ["all"], cd: @root, stderr_to_stdout: true)

    assert status == 0, "bin/check-model all exited #{status}:\n#{output}"
  end
end
