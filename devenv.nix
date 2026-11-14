{ pkgs, lib, config, ... }:

let
  beam = pkgs.beam.packages.erlang_29;
  elixir = beam.elixir_1_20;
  erlang = pkgs.beam.interpreters.erlang_29;
  state = config.devenv.state;
  jdk = pkgs.jdk21_headless;
  # TLC on the one JDK below, rather than the JDK its package brings.
  tlaplus = pkgs.tlaplus18.override { jre = jdk; };

  # Every program the tests and bin/check-model run, by its absolute store path. Each is
  # exported as CAF_<NAME>; nothing in the tests looks a program up through PATH or /usr/bin.
  #   - tmux, dtach, claude, git, gh: what the framework runs on a host. claude-code is unfree;
  #     devenv.yaml permits only it.
  #   - sh, bash, rm, mv, env, kill, ps, cat, echo, sleep, true: the POSIX tools the tests and
  #     scripts call.
  #   - tlc and java: TLA+ checks of model/tla (bin/check-model). Development only.
  programs = {
    TMUX = lib.getExe pkgs.tmux;
    DTACH = lib.getExe pkgs.dtach;
    CLAUDE = lib.getExe pkgs.claude-code;
    GIT = lib.getExe pkgs.git;
    GH = lib.getExe pkgs.gh;
    SH = lib.getExe' pkgs.bash "sh";
    BASH = lib.getExe pkgs.bash;
    RM = lib.getExe' pkgs.coreutils "rm";
    MV = lib.getExe' pkgs.coreutils "mv";
    ENV = lib.getExe' pkgs.coreutils "env";
    KILL = lib.getExe' pkgs.coreutils "kill";
    PS = lib.getExe' pkgs.ps "ps";
    CAT = lib.getExe' pkgs.coreutils "cat";
    ECHO = lib.getExe' pkgs.coreutils "echo";
    SLEEP = lib.getExe' pkgs.coreutils "sleep";
    TRUE = lib.getExe' pkgs.coreutils "true";
    TLC = lib.getExe' tlaplus "tlc";
    JAVA = lib.getExe' jdk "java";
  };

  # The one PATH bin/check-model runs with: only the text tools it calls, all pinned.
  toolsPath = lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.gnused ];

  # What `check-versions` expects each program to print, from the lock.
  versions = [
    [ "tmux" "$CAF_TMUX -V" "tmux ${pkgs.tmux.version}" ]
    [ "dtach" "$CAF_DTACH --help" "version ${lib.versions.majorMinor pkgs.dtach.version}" ]
    [ "claude" "$CAF_CLAUDE --version" "${pkgs.claude-code.version} (Claude Code)" ]
    [ "erlang" "erl -noshell -eval ${lib.escapeShellArg otpVersion}" erlang.version ]
    [ "elixir" "elixir --short-version" elixir.version ]
  ];
  otpVersion = ''{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:put_chars(V), halt().'';
in
{
  # Erlang/OTP 29 and Elixir 1.20 built against it: the newest stable pair in nixpkgs-unstable.
  languages.elixir = {
    enable = true;
    package = elixir;
    erlang.package = erlang;
    lsp.enable = false;
  };

  packages = [
    pkgs.tmux
    pkgs.dtach
    pkgs.claude-code
    pkgs.git
    pkgs.gh
    tlaplus
    jdk
  ];

  env = lib.mapAttrs' (name: path: lib.nameValuePair "CAF_${name}" path) programs // {
    CAF_TOOLS_PATH = toolsPath;
    CAF_OTP_VERSION = erlang.version;
    CAF_ELIXIR_VERSION = elixir.version;

    # Tool state stays in the checkout, under .devenv/state. devenv sets MIX_HOME there. Hex and
    # rebar3 come from the lock rather than a download into MIX_HOME.
    HEX_HOME = "${state}/hex";
    MIX_PATH = "${beam.hex}/lib/erlang/lib/hex-${beam.hex.version}/ebin";
    MIX_REBAR3 = lib.getExe beam.rebar3;
    REBAR_CACHE_DIR = "${state}/rebar3";
    ERL_AFLAGS = "-kernel shell_history enabled -kernel shell_history_path '\"${state}/erlang-history\"'";
  };

  # A drift shows at once: each program must print the version the lock gives. Claude Code
  # reads its config directory even for --version, so it gets one of its own here.
  scripts.check-versions.exec = ''
    export CLAUDE_CONFIG_DIR="$DEVENV_STATE/claude-version-check" DISABLE_AUTOUPDATER=1
    failed=0
    check() {
      if out=$(eval "$2" 2>&1) && [[ $out == *"$3"* ]]; then
        echo "ok $1: $3"
      else
        echo "check-versions: $1 is not $3 (got: ''${out%%$'\n'*})" >&2
        failed=1
      fi
    }
    ${lib.concatMapStrings (v: "check ${lib.escapeShellArgs v}\n") versions}
    exit $failed
  '';

  # The four gates, each alone; `devenv test` runs them all.
  scripts.gate-format.exec = "mix format --check-formatted";
  scripts.gate-compile.exec = "mix compile --warnings-as-errors";
  # The model test runs TLC; gate-model runs it on its own, so it is left out here.
  scripts.gate-test.exec = "mix test --exclude model";
  scripts.gate-model.exec = ''"$CAF_BASH" "$DEVENV_ROOT/bin/check-model" all'';

  enterTest = ''
    check-versions
    gate-format
    gate-compile
    gate-test
    gate-model
  '';

  # Format and American spelling before each commit; `devenv test` runs them on every file.
  git-hooks.hooks = {
    mix-format = {
      enable = true;
      entry = lib.mkForce "${lib.getExe' elixir "mix"} format --check-formatted";
    };
    typos = {
      enable = true;
      # American English. `@behaviour` is Elixir's own word, and `caf` is this project's prefix.
      settings.config.default = {
        locale = "en-us";
        extend-ignore-re = [ "@behaviour" ];
        extend-words.caf = "caf";
      };
    };
  };

  # The installer (prek) refuses a core.hooksPath set outside this repository, and its failure
  # would stop every shell entry. Skip it there; `devenv test` still runs the hooks.
  tasks."devenv:git-hooks:install".status = ''
    set -- $(${lib.getExe pkgs.git} config --show-scope --get core.hooksPath)
    case "''${1:-local}" in local | worktree) exit 1 ;; esac
    echo "git-hooks: not installed; core.hooksPath is set in $1 scope" >&2
  '';
}
