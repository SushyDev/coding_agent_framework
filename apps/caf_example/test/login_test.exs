defmodule CodingAgentFramework.Example.LoginTest do
  # `bin/caf-login`'s setup (F-220), driven with stand-ins for `claude` and `gh` that print what
  # the script reads: a login or none, the onboarding passed or not, a gh token with or without
  # the scope admin:ssh_signing_key, and GitHub's list of signing keys. No test runs the real
  # Claude Code, gh or GitHub. Each stand-in appends its argv to the state folder's `calls`.
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  @root Path.expand("../../..", __DIR__)
  @login Path.join(@root, "bin/caf-login")
  @scope "admin:ssh_signing_key"

  # A login is a file in the account's own config directory; the first run writes the
  # onboarding passed unless the state holds `no-onboarding`.
  @claude ~S"""
  state=$CAF_STAND_IN_STATE
  account=${CLAUDE_CONFIG_DIR%/claude}; account=${account##*/}
  echo "claude $* ($account)" >> "$state/calls"
  case "$1 $2" in
    "auth status")
      if [ -e "$CLAUDE_CONFIG_DIR/stand-in-login" ]; then
        if [ "$3" = --text ]; then echo "Login method: stand-in"; else echo '{"loggedIn": true, "authMethod": "stand_in"}'; fi
        exit 0
      fi
      if [ "$3" = --text ]; then echo "Not logged in."; else echo '{"loggedIn": false, "authMethod": "none"}'; fi
      exit 1 ;;
    "auth login") : > "$CLAUDE_CONFIG_DIR/stand-in-login"; exit 0 ;;
  esac
  [ -e "$state/no-onboarding" ] || echo '{"hasCompletedOnboarding": true}' > "$CLAUDE_CONFIG_DIR/.claude.json"
  """

  # A login is the state's `gh-login`, the token's scopes as gh's status prints them, and a
  # token in the home's hosts.yml; GitHub's signing keys are the state's `signing-keys`.
  @gh ~S"""
  state=$CAF_STAND_IN_STATE
  echo "gh $*" >> "$state/calls"
  base="'gist', 'read:org', 'repo'"
  case "$1 $2" in
    "auth status")
      if [ -e "$state/gh-login" ]; then
        echo "github.com"
        echo "  ✓ Logged in to github.com account someone (keyring)"
        echo "  - Token scopes: $(< "$state/gh-login")"
        exit 0
      fi
      echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
      exit 1 ;;
    "auth login")
      scopes=$base
      case " $* " in *" -s admin:ssh_signing_key "*) scopes="$scopes, 'admin:ssh_signing_key'" ;; esac
      echo "$scopes" > "$state/gh-login"
      printf 'github.com:\n    oauth_token: stand-in\n    user: someone\n' > "$GH_CONFIG_DIR/hosts.yml"
      # As gh does: its git setup writes the global config, which fails if its folder is missing.
      printf '[credential "https://github.com"]\n' >> "$GIT_CONFIG_GLOBAL" || exit 1
      exit 0 ;;
    "auth refresh")
      case " $* " in *" -s admin:ssh_signing_key "*) echo "$base, 'admin:ssh_signing_key'" > "$state/gh-login" ;; esac
      exit 0 ;;
    "api --paginate")
      [ -e "$state/signing-keys" ] && echo "$(< "$state/signing-keys")"
      exit 0 ;;
    "ssh-key add")
      read -r kind blob _ < "$3"
      echo "$kind $blob" >> "$state/signing-keys"
      exit 0 ;;
  esac
  exit 1
  """

  setup do
    dir = test_dir()
    state = Path.join(dir, "state")
    File.mkdir_p!(state)

    for {name, body} <- [claude: @claude, gh: @gh] do
      path = Path.join(dir, "#{name}-stand-in")
      File.write!(path, "#!#{program!(:bash)}\n" <> body)
      File.chmod!(path, 0o755)
    end

    env = [
      {"CAF_CLAUDE", Path.join(dir, "claude-stand-in")},
      {"CAF_GH", Path.join(dir, "gh-stand-in")},
      {"CAF_STAND_IN_STATE", state},
      {"TMPDIR", dir},
      {"CAF_LOGIN_NO_TTY_CHECK", "1"}
    ]

    login = fn args -> System.cmd(@login, args, env: env, stderr_to_stdout: true) end
    %{dir: dir, home: Path.join(dir, "home"), state: state, login: login}
  end

  # The calls since the last read, one line each.
  defp calls!(ctx) do
    path = Path.join(ctx.state, "calls")
    lines = if File.exists?(path), do: String.split(File.read!(path), "\n", trim: true), else: []
    File.rm_rf!(path)
    lines
  end

  defp gh_login!(ctx, scopes) do
    File.write!(Path.join(ctx.state, "gh-login"), scopes <> "\n")
    File.mkdir_p!(Path.join(ctx.home, "gh"))
    File.write!(Path.join(ctx.home, "gh/hosts.yml"), "github.com:\n    oauth_token: t\n")
  end

  # F-220's new-2: with no terminal, a login or onboarding would wait forever; it refuses first.
  test "--setup with no terminal refuses before any step", ctx do
    env = [{"CAF_LOGIN_NO_TTY_CHECK", ""}]

    run = fn ->
      System.cmd(@login, ["--setup", ctx.home, "one"], env: env, stderr_to_stdout: true)
    end

    assert {out, 2} = run.()
    assert out =~ "--setup needs a terminal"
    refute out =~ "step 1"
  end

  test "--setup <home> runs each step once, with its check, and skips each step done", ctx do
    assert {out, 0} = ctx.login.(["--setup", ctx.home, "one", "two"])
    key = Path.join(ctx.home, "git/signing_key")
    status = "gh auth status -h github.com -a"
    keys = "gh api --paginate user/ssh_signing_keys --jq .[].key"

    account = fn name ->
      [
        "claude auth status --json (#{name})",
        "claude auth login (#{name})",
        # The first run ends by itself: /exit is its first prompt.
        "claude /exit (#{name})",
        "claude auth status --text (#{name})"
      ]
    end

    assert calls!(ctx) ==
             account.("one") ++
               account.("two") ++
               [
                 status,
                 "gh auth login -h github.com --insecure-storage -s #{@scope}",
                 status,
                 status,
                 keys,
                 "gh ssh-key add #{key}.pub --type signing --title caf signing_key",
                 keys
               ]

    assert out =~ "step 1 of 4: account one"
    # F-155: the home's own key, an ed25519 key made once and never written over.
    assert out =~ "made #{key}, the home's own signing key" and out =~ "ssh-ed25519 "
    assert out =~ "the token has the scope #{@scope}"
    assert out =~ "check: GitHub lists #{key}.pub as a signing key"
    assert out =~ "setup of #{ctx.home} done: account one, account two, gh, git, each checked"
    pub = File.read!(key <> ".pub")

    # Again: every step is checked and said, and none runs again.
    assert {out, 0} = ctx.login.(["--setup", ctx.home, "one", "two"])

    assert calls!(ctx) ==
             Enum.flat_map(["one", "two"], fn name ->
               ["claude auth status --json (#{name})", "claude auth status --text (#{name})"]
             end) ++ [status, status, status, keys]

    assert out =~ "account one is logged in already"
    assert out =~ "onboarding was passed on two before"
    assert out =~ "the GitHub CLI is logged in already"
    assert out =~ "#{key} is there already; it is kept as it is"
    assert out =~ "GitHub lists it already as a signing key"
    assert File.read!(key <> ".pub") == pub
  end

  test "--setup <config> sets up the accounts named, or every one, with the config's key",
       ctx do
    config = Path.join(ctx.dir, "caf.json")

    File.write!(
      config,
      JSON.encode!(%{
        "home" => ctx.home,
        "accounts" => ["one", "two", "three"],
        "git" => %{"name" => "Bot", "email" => "b@example.com", "signing_key" => "bot_key"}
      })
    )

    assert {out, 2} = ctx.login.(["--setup", config, "four"])
    assert out =~ "#{config} names no account four"

    # --no-git: the account named, and no gh.
    assert {_, 0} = ctx.login.(["--setup", "--no-git", config, "one"])
    calls = calls!(ctx)
    assert "claude auth login (one)" in calls
    refute Enum.any?(calls, &(&1 =~ ~r/\((two|three)\)$|^gh /))

    assert {out, 0} = ctx.login.(["--setup", config])
    calls = calls!(ctx)
    refute "claude auth login (one)" in calls
    assert "claude auth login (two)" in calls and "claude auth login (three)" in calls
    assert File.exists?(Path.join(ctx.home, "git/bot_key.pub"))
    assert out =~ "done: account one, account two, account three, gh, git"

    File.write!(config, ~s({"home": "#{ctx.home}"}))
    assert {out, 2} = ctx.login.(["--setup", config])
    assert out =~ ~s("accounts" is not a list of names)
  end

  test "a gh token without admin:ssh_signing_key: --git stops, --gh adds it by refresh", ctx do
    gh_login!(ctx, "'gist', 'read:org', 'repo'")
    key = Path.join(ctx.home, "git/signing_key")

    assert {out, 1} = ctx.login.(["--git", ctx.home])
    assert out =~ "the gh token lacks the scope #{@scope}"

    assert out =~
             "  GH_CONFIG_DIR=#{ctx.home}/gh gh auth refresh -h github.com -s #{@scope} --insecure-storage\n"

    refute File.exists?(key)

    # gh's own lines, then caf-login's reading of the file and of the scope.
    assert {out, 1} = ctx.login.(["--check", "--gh", ctx.home])
    assert out =~ "Logged in to github.com account someone (keyring)"
    assert out =~ "the token is in the home: a file, #{ctx.home}/gh/hosts.yml"
    assert out =~ "the token lacks the scope #{@scope}"

    calls!(ctx)
    assert {out, 0} = ctx.login.(["--gh", ctx.home])
    calls = calls!(ctx)
    assert "gh auth refresh -h github.com -s #{@scope} --insecure-storage" in calls
    refute Enum.any?(calls, &String.starts_with?(&1, "gh auth login"))
    assert out =~ "the token has the scope #{@scope}"

    assert {_, 0} = ctx.login.(["--git", ctx.home])
    assert File.exists?(key)
  end

  test "--git with gh logged out says so and makes no key", ctx do
    assert {out, 1} = ctx.login.(["--git", ctx.home])
    assert out =~ "the GitHub CLI is not logged in with #{ctx.home}/gh; run bin/caf-login --gh"
    refute File.exists?(Path.join(ctx.home, "git/signing_key"))
  end

  test "--setup stops at an onboarding not passed, and runs no step after it", ctx do
    File.write!(Path.join(ctx.state, "no-onboarding"), "")
    assert {out, 1} = ctx.login.(["--setup", ctx.home, "one", "two"])
    assert out =~ "onboarding: not passed; run bin/caf-login #{ctx.home} one again"
    assert out =~ "setup stopped at account one (status 1)"
    refute Enum.any?(calls!(ctx), &(&1 =~ ~r/\(two\)$|^gh /))
  end

  test "--setup refuses what names no home and accounts" do
    for {args, why} <- [
          {["--setup", "/srv/caf"], "/srv/caf is no config file; name the home and its accounts"},
          {["--setup", "srv", "one"], "srv is not an absolute path"},
          {["--setup", "/srv/caf", "One"], "One is not an account's name"},
          {["--check", "--setup", "/srv/caf", "one"], "usage:"}
        ] do
      assert {out, 2} = System.cmd(@login, args, stderr_to_stdout: true)
      assert out =~ why
    end
  end
end
