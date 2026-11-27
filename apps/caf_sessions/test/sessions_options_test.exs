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
    bad = headless(ctx, :on_message) ++ [options: %{env: %{"HOME" => "/x"}}]
    assert {{:refused, _}, nil} = {start(ctx, bad), Table.get(ctx.table, "test", "o1")}

    launch = headless(ctx, :on_message)
    first = launch[:first].uuid
    assert {:ok, %{session_id: id}} = start(ctx, launch ++ [options: options])
    own = Path.join(ctx.account.config_dir, "framework/agents/o1.settings.json")

    assert JSON.decode!(File.read!(own))["permissions"] ==
             Map.put(deny["permissions"], "allow", ["Artifact"])

    flags = ["--settings", own, "--add-dir", "/srv/docs", "--append-system-prompt=Be brief."]
    assert Enum.chunk_every(HeadlessStandIn.argv(ctx.dir, id), 5, 1) |> Enum.member?(flags)
    kept = Table.get(ctx.table, "test", "o1").options
    assert CodingAgentFramework.ClaudeCLI.Options.decode(kept) == {:ok, options}

    # The start's first line opens a turn, and a stop refuses a running turn: the stop waits
    # until `Stream` announces that line delivered and the turn ended (F-155's new-12).
    assert %{messages: %{^first => %{state: :delivered}}} = turn_ended(ctx, id)
    assert {:ok, :stopped} = Sessions.stop(ctx.sessions, "o1")
    {:ok, _} = await(fn -> if Holder.state(ctx.holder, "o1") == {:ok, :absent}, do: {:ok, 1} end)
    File.rm!(Path.join([ctx.dir, "argv", id]))

    assert %{model: "opus"} = Table.get(ctx.table, "test", "o1")

    # The resume names no options and no model: those of the row are given again (F-133's
    # new-3), as a resume another part makes (a move, a recovery) has them.
    launch = Keyword.delete(headless(ctx, :on_message), :model)
    assert {:ok, _} = Sessions.resume(ctx.sessions, "o1", ctx.account, id, launch)

    {:ok, again} = await(fn -> if a = HeadlessStandIn.argv(ctx.dir, id), do: {:ok, a} end)
    assert Enum.chunk_every(again, 5, 1) |> Enum.member?(flags)
    assert Enum.chunk_every(again, 2, 1) |> Enum.member?(["--model", "opus"])
    assert %{options: ^kept, model: "opus"} = Table.get(ctx.table, "test", "o1")
  end

  # F-200: a delegate's settings default `includeGitInstructions` to false; a main session's say
  # nothing of it, so Claude Code reads its own default (`?? true`) and keeps the instructions.
  test "a delegate's overlay has includeGitInstructions false, a main session's has none", ctx do
    deny = %{"permissions" => %{"deny" => ["Bash(git push *)"]}}
    own = Path.join(ctx.account.config_dir, "framework/agents/o1.settings.json")
    written = fn path -> JSON.decode!(File.read!(path)) end

    # A delegate with no options of its own still has an overlay, and its settings win.
    assert {:ok, %{session_id: id}} = start(ctx, headless(ctx, :on_message))
    assert %{"includeGitInstructions" => false} = written.(own)

    assert Enum.chunk_every(HeadlessStandIn.argv(ctx.dir, id), 2, 1)
           |> Enum.member?(["--settings", own])

    # A main session's file is the account's, or its overlay over it: never the default.
    assert Map.has_key?(written.(ctx.account.settings.parent), "includeGitInstructions") == false

    main = launch(ctx, :at_start) ++ [options: %{settings: deny}]
    assert {:ok, _} = Sessions.start(ctx.sessions, "m1", ctx.account, main)
    overlay = written.(Path.join(ctx.account.config_dir, "framework/agents/m1.settings.json"))
    assert overlay["permissions"] == Map.put(deny["permissions"], "allow", ["Artifact"])
    refute Map.has_key?(overlay, "includeGitInstructions")
  end

  defp start(ctx, launch), do: Sessions.start(ctx.sessions, "o1", ctx.account, launch)
end
