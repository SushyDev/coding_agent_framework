defmodule CodingAgentFramework.SessionsOptionsTest do
  # An agent's own launch options through `Sessions`, read from what the held stand-in recorded.
  use ExUnit.Case, async: true

  import CodingAgentFramework.SessionsSetup
  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{HeadlessStandIn, Holder, Sessions, SessionsSetup}
  alias CodingAgentFramework.Sessions.Table

  setup {SessionsSetup, :sessions}

  test "a delegate's options reach its process, stay on its row, and come again on a resume",
       ctx do
    deny = %{"permissions" => %{"deny" => ["Bash(git push *)"]}}
    options = %{settings: deny, add_dirs: ["/srv/docs"], append_system_prompt: "Be brief."}
    bad = headless(ctx, :at_start) ++ [options: %{env: %{"HOME" => "/x"}}]
    assert {{:refused, _}, nil} = {start(ctx, bad), Table.get(ctx.table, "test", "o1")}

    assert {:ok, %{session_id: id}} = start(ctx, headless(ctx, :at_start) ++ [options: options])
    own = Path.join(ctx.account.config_dir, "framework/agents/o1.settings.json")
    assert JSON.decode!(File.read!(own))["permissions"] == deny["permissions"]
    flags = ["--settings", own, "--add-dir", "/srv/docs", "--append-system-prompt=Be brief."]
    assert Enum.chunk_every(HeadlessStandIn.argv(ctx.dir, id), 5, 1) |> Enum.member?(flags)
    kept = Table.get(ctx.table, "test", "o1").options
    assert CodingAgentFramework.ClaudeCLI.Options.decode(kept) == {:ok, options}

    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "o1")
    {:ok, _} = await(fn -> if Holder.state(ctx.holder, "o1") == {:ok, :absent}, do: {:ok, 1} end)
    File.rm!(Path.join([ctx.dir, "argv", id]))

    # The resume names no options: those of the row are given again.
    assert {:ok, _} =
             Sessions.resume(ctx.sessions, "o1", ctx.account, id, headless(ctx, :at_start))

    {:ok, again} = await(fn -> if a = HeadlessStandIn.argv(ctx.dir, id), do: {:ok, a} end)
    assert Enum.chunk_every(again, 5, 1) |> Enum.member?(flags)
    assert Table.get(ctx.table, "test", "o1").options == kept
  end

  defp start(ctx, launch), do: Sessions.start(ctx.sessions, "o1", ctx.account, launch)
end
