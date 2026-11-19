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

  # F-156: a checkout's directory is its repository's name, or the project's `dir:`, and two
  # projects never share one.
  test "each project's checkout has a directory of its own" do
    project = %{origin: "git@github.com:me/app_repo.git", trunk: "main"}
    fields = [user: "me"] ++ @fields

    assert {:ok, %Config{projects: %{"app" => %{dir: "app_repo", repo: repo}}}} =
             Config.new([projects: %{"app" => project}] ++ fields)

    assert repo == "/srv/caf/checkouts/app_repo"

    twice = %{"app" => project, "web" => Map.put(project, :dir, "app_repo")}

    assert Config.new([projects: twice] ++ fields) ==
             {:refused, {:bad, :projects, {:same_dir, "app_repo", ["app", "web"]}}}

    apart = %{"app" => project, "web" => Map.put(project, :dir, "web")}

    assert {:ok, %Config{projects: %{"web" => %{dir: "web"}}}} =
             Config.new([projects: apart] ++ fields)
  end
end
