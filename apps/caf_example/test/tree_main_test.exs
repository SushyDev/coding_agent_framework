defmodule CodingAgentFramework.Example.TreeMainTest do
  # F-232: the example app's whole tree, with the interactive stand-in as Claude Code, starts a
  # main session through `Mains` and sees it reach idle in the tree, as an app would; then ends
  # it. No part is a stand-in: the session file is the stand-in's own, as Claude Code's is.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Mains, ScreenStandIn, Tmux}
  alias CodingAgentFramework.Example.{ConfigFile, Console, Run}

  setup do
    dir = test_dir()
    repo = Path.join(dir, "repo")
    git = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
    {_, 0} = System.cmd(program!(:git), ["init", "-q", "-b", "main", repo], env: git)
    commit = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "i"]
    {_, 0} = System.cmd(program!(:git), commit ++ ["--allow-empty"], env: git)

    data = %{
      "home" => Path.join(dir, "home"),
      "instance" => "t",
      "accounts" => ["one"],
      "ports" => %{"intake" => free_port(), "mcp" => free_port()},
      "projects" => %{
        "app" => %{
          "origin" => repo,
          "trunk" => "main",
          "mains" => [],
          "branches" => "^unit/",
          "cap" => 2,
          "env" => %{"HOME" => dir}
        }
      },
      # The start's brief is delivered once its transcript shows it, as 2.1.322 writes it.
      "launch" => %{
        "claude" => ScreenStandIn.write!(dir, "2.1.322", stand_in_idle(), transcript: true),
        "home" => dir
      },
      "interval" => 200
    }

    path = Path.join(dir, "caf.json")
    File.write!(path, JSON.encode!(data))
    {:ok, config} = ConfigFile.read(path, System.get_env())
    {:ok, server} = CodingAgentFramework.server(config)
    on_exit(fn -> Tmux.kill_server(server) end)
    on_exit(fn -> end_recorded(dir) end)
    %{dir: dir, path: path, config: config}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  test "a main session started through Mains on the whole tree reaches idle, then ends", ctx do
    {:ok, io} = StringIO.open("")
    Process.group_leader(self(), io)
    out = fn -> elem(StringIO.contents(io), 1) end
    {:ok, caf} = Console.start(ctx.path, System.get_env())
    on_exit(fn -> Console.stop(caf) end)

    # Runs `act` until the output shows `text`.
    see = fn act, text ->
      case await(fn -> (act.() && out.() =~ text && {:ok, text}) || nil end, 30_000) do
        {:ok, _} -> :ok
        _ -> flunk("no #{inspect(text)} in:\n" <> out.())
      end
    end

    # A start waits for the checkout, which the tree clones at its start.
    see.(fn -> Console.checkout(caf) end, "app: ready, on main")
    mains = Run.parts(caf).mains

    assert {:ok, %{name: "app-epic", account: "one", session_id: sid}} =
             Mains.start_main(mains, "app", "app-epic", "Plan the epic.")

    # The stand-in's own session file, which `Mains`' start waited for.
    sessions = Path.join(ctx.config.home, "accounts/one/claude/sessions")
    # Only `.json`: the stand-in writes each change through a `.tmp` file it then renames, so a
    # listing can catch both while its status changes.
    assert [path] = Path.wildcard(Path.join(sessions, "*.json"))
    file = Path.basename(path)
    assert %{"sessionId" => ^sid, "kind" => "interactive"} = sessions |> Path.join(file) |> json()

    assert {:ok, [prompt]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    assert prompt =~ "Plan the epic."
    # The stand-in said `busy` before it wrote the prompt, so its file's next `idle` is the
    # brief's turn ended: an end before it is refused `{:not_idle, "busy"}`.
    assert {:ok, "idle"} = await(fn -> status(sessions, file, "idle") end)
    see.(fn -> Console.agents(caf) end, "app-epic: main of app, on one, idle")

    assert {:ok, :ended} = Mains.end_main(mains, "app-epic")
    see.(fn -> Console.agents(caf, true) end, "app-epic: main of app, on one, ended")
    # The stand-in removed its file as it exited.
    assert {:ok, []} = await(fn -> if File.ls(sessions) == {:ok, []}, do: {:ok, []} end)
  end

  # F-246's second item: a main whose start meets the trust dialog, answered from the inbox
  # after the start's own call answered unknown, as the real suite answers it. The row must
  # leave `dialog` once the stand-in writes its session file: `agents` reads it idle.
  test "a main session answered past its trust dialog reaches idle in agents", ctx do
    claude =
      ScreenStandIn.write!(ctx.dir, "2.1.322", stand_in_idle(), trust: true, transcript: true)

    data = ctx.path |> File.read!() |> JSON.decode!() |> put_in(["launch", "claude"], claude)
    File.write!(ctx.path, JSON.encode!(data))
    {:ok, io} = StringIO.open("")
    Process.group_leader(self(), io)
    out = fn -> elem(StringIO.contents(io), 1) end
    {:ok, caf} = Console.start(ctx.path, System.get_env())
    on_exit(fn -> Console.stop(caf) end)

    see = fn act, text, ms ->
      case await(fn -> (act.() && out.() =~ text && {:ok, text}) || nil end, ms) do
        {:ok, _} -> :ok
        _ -> flunk("no #{inspect(text)} in:\n" <> out.())
      end
    end

    see.(fn -> Console.checkout(caf) end, "app: ready, on main", 30_000)
    mains = Run.parts(caf).mains

    assert {:unknown, {:dialog, :trust}} =
             Mains.start_main(mains, "app", "app-epic", "Plan the epic.")

    instance = ctx.config.instance

    assert {:ok, [%{id: id, options: options}]} =
             await(fn ->
               case CodingAgentFramework.prompts(instance, agent: "app-epic", kind: "dialog") do
                 {:ok, [_] = ps} -> {:ok, ps}
                 _ -> nil
               end
             end)

    trust = Enum.find(options, &(&1 =~ ~r/trust/i))
    assert {:ok, _} = CodingAgentFramework.answer(instance, id, trust, ctx.config.operator)
    assert File.exists?(Path.join(ctx.dir, "trusted"))
    see.(fn -> Console.agents(caf) end, "app-epic: main of app, on one, idle", 30_000)
    # The brief goes once its turn shows in the transcript; the end waits for its delivery.
    assert {:ok, [_]} = await(fn -> nonempty(ScreenStandIn.prompts(ctx.dir)) end)
    sessions = Path.join(ctx.config.home, "accounts/one/claude/sessions")
    assert {:ok, [file]} = File.ls(sessions)
    assert {:ok, "idle"} = await(fn -> status(sessions, file, "idle") end)
    assert {:ok, :ended} = await(fn -> ended(mains, "app-epic") end)
  end

  defp ended(mains, name) do
    case Mains.end_main(mains, name) do
      {:ok, :ended} = ok -> ok
      {:refused, {:sending, _}} -> nil
      other -> other
    end
  end

  defp json(path), do: path |> File.read!() |> JSON.decode!()

  # The session file's `status` once it is `want`; a file mid-write reads as not yet.
  defp status(dir, file, want) do
    with {:ok, body} <- File.read(Path.join(dir, file)),
         {:ok, %{"status" => ^want}} <- JSON.decode(body),
         do: {:ok, want},
         else: (_ -> nil)
  end

  defp nonempty([]), do: nil
  defp nonempty(list), do: {:ok, list}
end
