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
  #   - rsync, ssh, flock: a copy's sync (Copies): rsync over ssh, its host side under flock.
  #   - nc: a service's port wait (Services.wait), `nc -z`.
  #   - wc, lsof: a service's log offset at its start, and whether a forward's own ssh holds its
  #     local port (Services).
  #   - curl: a main session's waiter hook (Intake.waiter_hook), run by its contract test.
  #   - sh, bash, rm, mv, env, kill, ps, cat, tail, head, mkdir, mkfifo, stty, echo, sleep, true: the
  #     POSIX tools the tests and scripts call (stty: the screen stand-in reads keys raw).
  #   - tlc and java: TLA+ checks of model/tla (bin/check-model). Development only.
  programs = {
    TMUX = lib.getExe pkgs.tmux;
    DTACH = lib.getExe pkgs.dtach;
    CLAUDE = lib.getExe pkgs.claude-code;
    GIT = lib.getExe pkgs.git;
    GH = lib.getExe pkgs.gh;
    RSYNC = lib.getExe pkgs.rsync;
    SSH = lib.getExe' pkgs.openssh "ssh";
    FLOCK = lib.getExe pkgs.flock;
    NC = lib.getExe' pkgs.netcat "nc";
    WC = lib.getExe' pkgs.coreutils "wc";
    LSOF = lib.getExe pkgs.lsof;
    CURL = lib.getExe pkgs.curl;
    SH = lib.getExe' pkgs.bash "sh";
    BASH = lib.getExe pkgs.bash;
    RM = lib.getExe' pkgs.coreutils "rm";
    MV = lib.getExe' pkgs.coreutils "mv";
    ENV = lib.getExe' pkgs.coreutils "env";
    KILL = lib.getExe' pkgs.coreutils "kill";
    PS = lib.getExe' pkgs.ps "ps";
    CAT = lib.getExe' pkgs.coreutils "cat";
    TAIL = lib.getExe' pkgs.coreutils "tail";
    HEAD = lib.getExe' pkgs.coreutils "head";
    MKDIR = lib.getExe' pkgs.coreutils "mkdir";
    MKFIFO = lib.getExe' pkgs.coreutils "mkfifo";
    STTY = lib.getExe' pkgs.coreutils "stty";
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
    [ "rsync" "$CAF_RSYNC --version" "version ${pkgs.rsync.version}" ]
    [ "ssh" "$CAF_SSH -V" "OpenSSH_${pkgs.openssh.version}" ]
    [ "flock" "$CAF_FLOCK --version" "flock ${pkgs.flock.version}" ]
  ];
  otpVersion = ''{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:put_chars(V), halt().'';

  # What `devenv test` runs, in this order. Each is a script below and a task `caf:<name>`.
  gates = [ "check-versions" "gate-format" "gate-compile" "gate-deps" "gate-test" "gate-model" ];
  # A gate task that passes exports this variable. devenv hands a run's task exports to that
  # run's enterTest, so unlike a mark file it cannot outlive its run.
  passed = gate: "CAF_PASSED_" + lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] gate);

  # `devenv test` runs the gates as tasks, one after another, before devenv:enterTest. Under a
  # coding agent devenv prints only errors, and it hides the enterTest script's output when it
  # passes; showOutput is the one way to print a passing gate there. A failing gate stops the
  # gates after it and fails `devenv test`. wantedBy keeps them out of `devenv shell` and every
  # other task run.
  gateTasks = lib.listToAttrs (lib.imap0 (i: gate: lib.nameValuePair "caf:${gate}" {
    description = "Gate: ${gate}";
    exec = ''
      ${gate}
      export ${passed gate}=1
    '';
    exports = [ (passed gate) ];
    cwd = config.devenv.root;
    showOutput = true;
    # The first gate waits for the shell's setup and the hooks, whose mix format would otherwise
    # share _build with gate-compile.
    after = if i == 0
      then [ "devenv:enterShell" "devenv:git-hooks:run" ]
      else [ "caf:${lib.elemAt gates (i - 1)}" ];
    before = [ "devenv:enterTest" ];
    wantedBy = [ "devenv:enterTest" ];
  }) gates);
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
    pkgs.rsync
    pkgs.openssh
    pkgs.flock
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

  # The five gates, each alone; `devenv test` runs them all, as gateTasks.
  scripts.gate-format.exec = "mix format --check-formatted";
  scripts.gate-compile.exec = "mix compile --warnings-as-errors";
  # Each app declares directly every umbrella app it uses, and uses each one it declares. Elixir
  # only checks that a module is somewhere in an app's dependency tree. The task lives in
  # caf_test, which compiles only for tests.
  scripts.gate-deps.exec = "MIX_ENV=test mix caf.deps";
  # The model test runs TLC; gate-model runs it on its own, so it is left out here. The test VM
  # works under /tmp/caf-<its pid>/ (TestHost.vm_dir/0), and the subshell execs mix, so its pid
  # is the VM's. A process whose command line still names that directory after the run is one
  # the run left: the gate names each and fails. It lists them; it never ends them. A dtach
  # master exits just after its child, so the list is read again for a few seconds first.
  scripts.gate-test.exec = ''
    vm_file=$(mktemp)
    status=0
    ( echo "$BASHPID" > "$vm_file"; exec mix test --exclude model ) || status=$?
    vm=$(<"$vm_file")
    "$CAF_RM" -f "$vm_file"
    for ((try = 0; try < 50; try++)); do
      if ! listing=$("$CAF_PS" -axww -o pid=,command=); then
        echo "gate-test: ps failed, so what the test VM left is unknown" >&2
        exit 1
      fi
      left=""
      while read -r pid command; do
        [[ $command == *"/caf-$vm/"* ]] && left="$left"$'\n'"  $pid $command"
      done <<< "$listing"
      [ -z "$left" ] && break
      "$CAF_SLEEP" 0.1
    done
    if [ -n "$left" ]; then
      echo "gate-test: the test VM $vm left these processes running:$left" >&2
      status=1
    fi
    exit $status
  '';
  scripts.gate-model.exec = ''"$CAF_BASH" "$DEVENV_ROOT/bin/check-model" all'';

  # The last step of `devenv test`: it fails unless every gate passed in this run, so a devenv
  # that stops running these tasks fails the run rather than passing it with nothing checked.
  # Its lines go to stderr, which devenv prints even under a coding agent.
  enterTest = ''
    missing=""
    ${lib.concatMapStrings (gate: ''
      [ -n "''${${passed gate}:-}" ] || missing="$missing ${gate}"
    '') gates}
    if [ -n "$missing" ]; then
      echo "devenv test: these gates did not run:$missing" >&2
      exit 1
    fi
    echo "devenv test: every gate ran: ${lib.concatStringsSep " " gates}" >&2
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
      # Screen fixtures are Claude Code's own output as captured, so they are not checked.
      excludes = [ "^apps/caf_screen/test/fixtures/" ];
      settings.config.default = {
        locale = "en-us";
        extend-ignore-re = [ "@behaviour" ];
        extend-words.caf = "caf";
      };
    };
  };

  # The repository's own pre-commit hook, in the common git directory so every worktree shares
  # it. Git's core.hooksPath may be global, which stops devenv's installer (prek) and makes git
  # look elsewhere; the global hooks directory hands off to this file. Every path is a store
  # path, so a plain `git commit` outside the shell needs no PATH. prek reads the same config
  # git-hooks generates and runs it on the staged files.
  tasks = gateTasks // {
    "devenv:git-hooks:install".status = "exit 0"; # prek must not write this file's place.
  };

  enterShell = let
    git = lib.getExe pkgs.git;
    hook = pkgs.writeText "caf-pre-commit" ''
      #!${lib.getExe pkgs.bash}
      # caf-repo-hook: written by devenv.nix on shell entry; edits are overwritten.
      export PATH=${lib.makeBinPath [ pkgs.git ]}
      exec ${lib.getExe config.git-hooks.package} run --config ${config.git-hooks.configFile} "$@"
    '';
  in ''
    caf_hook="$(${git} rev-parse --path-format=absolute --git-common-dir)/hooks/pre-commit"
    if [ ! -e "$caf_hook" ] || [ "$(${lib.getExe' pkgs.coreutils "head"} -n 2 "$caf_hook" | ${lib.getExe' pkgs.coreutils "tail"} -n 1)" = "# caf-repo-hook: written by devenv.nix on shell entry; edits are overwritten." ]; then
      ${lib.getExe' pkgs.coreutils "mkdir"} -p "''${caf_hook%/*}"
      ${lib.getExe' pkgs.coreutils "install"} -m 755 ${hook} "$caf_hook"
    else
      echo "pre-commit hook: $caf_hook exists and this repository did not write it; not replaced." >&2
    fi
    case "$(${git} config --show-scope --get core.hooksPath)" in local* | worktree*)
      echo "pre-commit hook: core.hooksPath is set in this repository; git will not run $caf_hook." >&2 ;;
    esac
    unset caf_hook
  '';
}
