defmodule CodingAgentFramework.MCPServicesTest do
  # No Claude Code: the test is the MCP client, with a token per agent, over a real `Services`
  # whose one host is this workstation. The service is a stand-in that records its pid, says
  # `up`, and echoes each line it reads, until it is ended.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Copies, Grants, MCP, Services}

  setup do
    dir = test_dir()
    on_exit(fn -> end_recorded(dir) end)
    wt = Path.join(dir, "wt")
    File.mkdir_p!(wt)
    File.mkdir_p!(Path.join(dir, "pids"))
    git = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    {_, 0} = System.cmd(program!(:git), ["-C", wt, "init", "-q"], env: git)

    File.write!(Path.join(dir, "echo"), """
    : 2>/dev/null > "#{dir}/pids/$$" || exit 0
    echo up
    exec #{program!(:bash)} -c 'while IFS= read -r -t #{stand_in_idle()} l; do echo "got $l"; done' "$0"
    """)

    tree = [
      %{name: "app-fix", project: "app", parent: "app-main"},
      %{name: "app-other", project: "app", parent: "app-main"},
      %{name: "app-fix1", project: "app", parent: "app-fix"}
    ]

    grants = Grants.new(fn -> tree end)
    copies = start_supervised!({Copies, dir: Path.join(dir, "copies"), programs: programs()})

    services =
      start_supervised!(
        {Services,
         dir: Path.join(dir, "services"),
         copies: copies,
         grants: grants,
         acts: :unused,
         ended: fn _ -> false end,
         hosts: %{"ws" => %{programs: programs(), dir: Path.join(dir, "ws")}},
         workstation: "ws"}
      )

    mcp =
      start_supervised!(
        {MCP,
         dir: dir,
         port: 4791,
         grants: grants,
         acts: :unused,
         mailbox: {__MODULE__, :unused},
         jobs: {__MODULE__, :unused},
         delegates: {__MODULE__, :unused},
         services: {Services, services},
         workstation: "ws",
         tracker: {__MODULE__, :unused},
         stream: {__MODULE__, :unused},
         transcripts: nil,
         place: fn agent -> {:ok, %{project: "app", name: agent, worktree: wt}} end,
         instance: "s",
         cap: 60_000,
         tool_timeout: 600_000,
         margin: 60_000}
      )

    tokens =
      for a <- ~w(app-main app-fix app-other app-fix1 stray), into: %{} do
        {:ok, path} = MCP.issue(mcp, a)
        {a, JSON.decode!(File.read!(path))["mcpServers"]["caf"]["headers"]["x-caf-token"]}
      end

    %{mcp: mcp, tokens: tokens, services: services, dir: dir}
  end

  defp tool(c, agent, name, args) do
    body =
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })

    conn =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("x-caf-token", c.tokens[agent])

    %{status: 200, resp_body: resp} = MCP.Plug.call(conn, MCP.Plug.init(mcp: c.mcp))
    %{"result" => %{"content" => [%{"text" => text}]}} = JSON.decode!(resp)
    JSON.decode!(text)
  end

  defp start(c, agent, args \\ %{}) do
    argv = [program!(:bash), Path.join(c.dir, "echo")]
    tool(c, agent, "service_start", Map.merge(%{"name" => "db", "argv" => argv}, args))
  end

  defp wait_line(c, agent, pattern),
    do:
      tool(c, agent, "service_wait", %{
        "name" => "db",
        "until" => %{"line" => pattern},
        "timeout" => 5_000
      })

  test "a service is the caller's, in its copy, and any agent reads it", c do
    args = %{"owner" => "app-other", "opts" => %{"keep" => true}}

    assert %{
             "ok" => %{
               "owner" => "app-fix",
               "state" => "running",
               "host" => "ws",
               "copy" => "app-fix",
               "keep" => true
             }
           } =
             start(c, "app-fix", args)

    assert tool(c, "app-other", "services", %{}) == %{
             "ok" => [
               %{
                 "name" => "db",
                 "host" => "ws",
                 "owner" => "app-fix",
                 "state" => "running",
                 "restarts" => 0,
                 "port" => nil,
                 "local" => nil
               }
             ]
           }

    assert %{"ok" => ["line", "up", 3]} = wait_line(c, "app-other", "^up$")

    assert %{"ok" => %{"text" => "up\n", "next" => 3}} =
             tool(c, "app-other", "service_logs", %{"name" => "db", "from" => 0})

    assert tool(c, "app-fix", "service_send", %{"name" => "db", "input" => "hi\n"}) == %{
             "ok" => "sent"
           }

    assert %{"ok" => ["line", "got hi", _]} = wait_line(c, "app-fix", "^got")

    assert [%{agent: "app-fix", tool: "service_start", state: "answered"} | _] = MCP.calls(c.mcp)
    assert %{"refused" => ["unknown_agent", "stray"]} = tool(c, "stray", "services", %{})
  end

  test "service_logs answers at most the window, and the next offset to read from", c do
    assert %{"ok" => %{"state" => "running"}} = start(c, "app-fix")
    assert %{"ok" => ["line", "up", 3]} = wait_line(c, "app-fix", "^up$")
    [log] = Path.wildcard(Path.join(c.dir, "**/services/db.log"))
    File.write!(log, String.duplicate("0123456789", 100_000), [:append])

    assert %{"ok" => %{"text" => text, "next" => 16_384}} =
             tool(c, "app-fix", "service_logs", %{"name" => "db", "from" => 0})

    assert byte_size(text) == 16_384

    assert %{"ok" => %{"text" => more, "next" => 32_768}} =
             tool(c, "app-fix", "service_logs", %{"name" => "db", "from" => 16_384})

    assert byte_size(more) == 16_384
  end

  test "each fix is refused where the tools table says", c do
    assert %{"refused" => ["unknown_agent", "stray"]} = start(c, "stray")
    assert %{"ok" => %{"owner" => "app-fix"}} = start(c, "app-fix")

    for {agent, t, args} <- [
          {"app-other", "service_send", %{"input" => "x\n"}},
          {"app-other", "service_stop", %{}},
          {"app-fix1", "service_restart", %{}},
          {"app-main", "service_hand", %{"to" => "app-other"}},
          {"app-fix", "service_hand", %{"to" => "app-other"}}
        ] do
      assert %{"refused" => _} = tool(c, agent, t, Map.put(args, "name", "db")), "#{agent} #{t}"
    end

    assert %{"ok" => %{"owner" => "app-fix1"}} =
             tool(c, "app-fix", "service_hand", %{"name" => "db", "to" => "app-fix1"})

    assert %{"ok" => %{"restarts" => 1, "state" => "running"}} =
             tool(c, "app-fix", "service_restart", %{"name" => "db"})

    assert %{"ok" => %{"state" => "ended"}} =
             tool(c, "app-fix", "service_stop", %{"name" => "db"})
  end

  test "bad arguments are refused before anything runs", c do
    bad = %{"refused" => ["bad", "args"]}
    bash = program!(:bash)

    for {t, args} <- [
          {"service_start", %{"name" => 5, "argv" => [bash]}},
          {"service_start", %{"name" => "db", "argv" => [bash], "opts" => %{"local" => 5}}},
          {"service_start", %{"name" => "db", "argv" => [bash], "timeout" => 60_001}},
          {"service_start", %{"name" => "db", "argv" => [bash], "timeout" => 0}},
          {"service_start", %{"name" => "db", "argv" => []}},
          {"service_start", %{"name" => "db", "argv" => [bash, 1]}},
          {"service_start", %{"name" => "db", "argv" => [bash], "opts" => "x"}},
          {"service_start", %{"name" => "db", "argv" => [bash], "opts" => %{"forward" => 0}}},
          {"service_start", %{"name" => "db", "argv" => [bash], "opts" => %{"keep" => "yes"}}},
          {"service_logs", %{"name" => "db", "from" => -1}},
          {"service_send", %{"name" => "db", "input" => 3}},
          {"service_wait", %{"name" => "db", "until" => %{"line" => 1}, "timeout" => 100}},
          {"service_wait", %{"name" => "db", "until" => "exit", "timeout" => 60_001}},
          {"service_hand", %{"name" => "db"}},
          {"service_stop", %{"name" => 7}}
        ] do
      assert tool(c, "app-fix", t, args) == bad, "#{t} #{inspect(args)}"
    end

    assert Services.list(c.services) == []
  end

  test "a name's form, a local port and a timeout are Services' to answer", c do
    assert start(c, "app-fix", %{"name" => "../db"}) == %{"refused" => ["name", "../db"]}
    assert Services.list(c.services) == []

    # The one host is the workstation, which needs no forward: its port is the local one.
    assert %{"refused" => ["bad_forward", [5000, 5001]]} =
             start(c, "app-fix", %{"opts" => %{"forward" => 5000, "local" => 5001}})

    assert %{"ok" => %{"state" => "running", "local" => 5000}} =
             start(c, "app-fix", %{"opts" => %{"forward" => 5000}, "timeout" => 30_000})

    assert %{"refused" => ["local_taken", "db"]} =
             start(c, "app-fix", %{"name" => "web", "opts" => %{"forward" => 5000}})

    assert [%{name: "db"}] = Services.list(c.services)
  end

  test "each answer kind of Services is passed through unchanged", c do
    assert %{"ok" => %{"state" => "running"}} = start(c, "app-fix")

    assert tool(c, "app-fix", "service_stop", %{"name" => "nope"}) == %{
             "refused" => ["no_service", "nope"]
           }

    assert tool(c, "app-fix", "service_wait", %{
             "name" => "db",
             "until" => %{"line" => "^never"},
             "timeout" => 300
           }) ==
             %{"unknown" => "timeout"}

    assert %{"ok" => %{"state" => "ended"}} =
             tool(c, "app-main", "service_stop", %{"name" => "db"})

    assert tool(c, "app-fix", "service_wait", %{
             "name" => "db",
             "until" => "exit",
             "timeout" => 5_000
           }) == %{"ok" => "exited"}
  end
end
