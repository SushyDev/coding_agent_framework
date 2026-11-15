defmodule CodingAgentFramework.ClaudeCLIHeldTest do
  @moduledoc """
  A stand-in held with `ClaudeCLI`'s environment for an account of `Accounts`. Its setup sets
  variables in this VM's own environment, so it runs alone (`async: false`) and puts them back
  after.
  """
  use ExUnit.Case, async: false

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, AccountsSetup, ClaudeCLI, Holder}

  setup {AccountsSetup, :accounts}

  test "a held stand-in sees the account's own directory and none of the VM's CLAUDE_ variables",
       ctx do
    {:ok, account} = Accounts.prepare(ctx.accounts, "work", %{})
    out = Path.join(ctx.dir, "seen")

    # The stand-in plays claude: it writes its environment and argv, then waits on its input.
    stand_in = Path.join(ctx.dir, "claude")

    File.write!(stand_in, """
    #!#{program!(:sh)}
    #{program!(:env)} > "#{out}.env"
    for a in "$@"; do printf '%s\\n' "$a"; done > "#{out}.argv"
    echo $$ > "#{out}.tmp" && #{program!(:mv)} "#{out}.tmp" "#{out}"
    exec #{program!(:cat)}
    """)

    File.chmod!(stand_in, 0o755)

    env = %{
      home: ctx.fake_home,
      path: "/nonexistent/bin",
      term: "xterm-256color",
      lang: "C.UTF-8"
    }

    {:ok, %{argv: argv, env: vars}} =
      ClaudeCLI.session(:delegate, account,
        claude: stand_in,
        model: "opus",
        name: "d1",
        env: env,
        prompt: "brief"
      )

    {:ok, holder} = Holder.new(programs(), Path.join(ctx.dir, "sockets"))
    File.mkdir_p!(holder.dir)
    assert {:ok, _} = Holder.hold(holder, "d1", argv, env: vars)
    assert {:ok, pid} = await(fn -> File.read(out) end)
    on_exit(fn -> if Holder.state(holder, "d1") == {:ok, :live}, do: kill(String.trim(pid)) end)

    held =
      for line <- String.split(File.read!(out <> ".env"), "\n", trim: true),
          [k, v] <- [String.split(line, "=", parts: 2)],
          into: %{},
          do: {k, v}

    assert held["CLAUDE_CONFIG_DIR"] == account.config_dir
    assert held["HOME"] == ctx.fake_home
    assert for({k, _} <- held, String.starts_with?(k, "CLAUDE"), do: k) == ["CLAUDE_CONFIG_DIR"]
    assert File.read!(out <> ".argv") == Enum.join(tl(argv), "\n") <> "\n"
  end
end
