{ pkgs, ... }:

let
  beam = pkgs.beam.packages.erlang_29;
in
{
  # Erlang/OTP 29 and Elixir 1.20 built against it: the newest stable pair in nixpkgs-unstable.
  languages.elixir = {
    enable = true;
    package = beam.elixir_1_20;
    erlang.package = pkgs.beam.interpreters.erlang_29;
    lsp.enable = false;
  };

  # The programs the framework runs on a host, so tests and a host app find one release of each:
  #   - tmux: the framework's own server per host;
  #   - dtach: holds each Claude Code process apart from tmux, so it outlives its server;
  #   - claude-code: the agents. It is unfree; devenv.yaml permits this one package;
  #   - git and gh: worktrees, branches and stacked pull requests.
  #
  # TLA+ and TLC check the protocols in `model/tla/` (`bin/check-model`). `tlaplus18` brings
  # `tlc` and `tla2sany`, run on a headless JDK. Development tooling only: nothing that ships
  # needs Java.
  packages = [
    pkgs.tmux
    pkgs.dtach
    pkgs.claude-code
    pkgs.git
    pkgs.gh
    pkgs.tlaplus18
    pkgs.jdk21_headless
  ];

  env = {
    ERL_AFLAGS = "-kernel shell_history enabled";
  };
}
