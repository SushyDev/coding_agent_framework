defmodule CodingAgentFramework.ConfigTest do
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Config

  @fields [
    home: "/srv/caf",
    instance: "a",
    programs: %{},
    accounts: [],
    ports: %{intake: 1, mcp: 2},
    claude: "/bin/claude",
    env: %{home: "/srv/caf", path: "/bin", term: "dumb", lang: "C.UTF-8"}
  ]

  # F-173
  test "the user is passed on in the launch env, and on macOS it is required" do
    assert {:ok, %Config{user: "me", env: %{user: "me"}}} = Config.new([user: "me"] ++ @fields)

    for bad <- ["", "a\nb", :me],
        do: assert(Config.new([user: bad] ++ @fields) == {:refused, {:bad, :user}})

    case :os.type() do
      {:unix, :darwin} -> assert Config.new(@fields) == {:refused, {:bad, :user}}
      _ -> assert {:ok, %Config{user: nil}} = Config.new(@fields)
    end
  end
end
