defmodule CodingAgentFramework.AccountsTest do
  @moduledoc """
  `Accounts` on disk, and a stand-in held with `ClaudeCLI`'s environment. Both set variables in
  this VM's own environment, so they run alone (`async: false`) and put them back after.
  """
  use ExUnit.Case, async: false

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, ClaudeCLI, Holder}

  doctest Accounts

  @vm_env %{
    "CLAUDE_CONFIG_DIR" => "/elsewhere/claude",
    "CLAUDECODE" => "1",
    "CLAUDE_CODE_ENTRYPOINT" => "cli"
  }

  setup do
    dir = test_dir()
    fake_home = Path.join(dir, "person")
    File.mkdir_p!(fake_home)
    vars = Map.put(@vm_env, "HOME", fake_home)
    before = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    System.put_env(vars)

    on_exit(fn ->
      Enum.each(before, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    home = Path.join(dir, "caf")
    {:ok, accounts} = Accounts.new(home, ["work", "spare"])
    {:ok, dir: dir, home: home, fake_home: fake_home, accounts: accounts}
  end

  test "prepare writes only the framework's own files, and nothing outside the home", ctx do
    data = %{
      settings: %{"model" => "opus"},
      hooks: %{"Stop" => [%{"hooks" => [%{"type" => "command", "command" => "/bin/true"}]}]},
      mcp_servers: %{"caf" => %{"command" => "/bin/caf-mcp"}}
    }

    assert {:ok, account} = Accounts.prepare(ctx.accounts, "work", data)
    assert account.config_dir == Path.join(ctx.home, "accounts/work/claude")

    parent = JSON.decode!(File.read!(account.settings.parent))
    delegate = JSON.decode!(File.read!(account.settings.delegate))

    assert parent ==
             Map.merge(data.settings, %{"hooks" => data.hooks, "remoteControlAtStartup" => true})

    assert delegate == %{parent | "remoteControlAtStartup" => false}
    assert JSON.decode!(File.read!(account.mcp_config)) == %{"mcpServers" => data.mcp_servers}

    written = Path.wildcard(Path.join(ctx.dir, "**/*"), match_dot: true)

    assert Enum.all?(
             written,
             &(&1 in [ctx.fake_home, ctx.home] or String.starts_with?(&1, ctx.home <> "/"))
           )

    for file <- ["settings.json", ".claude.json", ".credentials.json"],
        do: refute(File.exists?(Path.join(account.config_dir, file)))

    assert Accounts.ready(ctx.accounts, "work") == {:ok, account}
  end

  test "an account not prepared is refused, and its login is read from file names only", ctx do
    assert Accounts.ready(ctx.accounts, "spare") == {:refused, {:not_prepared, "spare"}}
    assert Accounts.login(ctx.accounts, "spare") == {:refused, {:no_config_dir, "spare"}}

    assert Accounts.prepare(ctx.accounts, "nobody", %{}) ==
             {:refused, {:unknown_account, "nobody"}}

    {:ok, account} = Accounts.prepare(ctx.accounts, "spare", %{})
    assert Accounts.login(ctx.accounts, "spare") == {:ok, :logged_out}
    File.write!(Path.join(account.config_dir, ".claude.json"), "")
    assert Accounts.login(ctx.accounts, "spare") == {:unknown, :login_not_readable}
    # The stand-in credential is not JSON: login/2 must not open it.
    File.write!(Path.join(account.config_dir, ".credentials.json"), "not read")
    assert Accounts.login(ctx.accounts, "spare") == {:ok, :looks_logged_in}
  end

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
