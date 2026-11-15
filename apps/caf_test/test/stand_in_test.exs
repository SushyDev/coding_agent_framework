defmodule CodingAgentFramework.StandInTest do
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{ClaudeStandIn, HeadlessStandIn}

  test "ending the stand-ins of a test that started none answers :ok" do
    dir = test_dir()

    assert :ok = ClaudeStandIn.kill_all(dir)
    assert :ok = HeadlessStandIn.kill_all(dir)
  end
end
