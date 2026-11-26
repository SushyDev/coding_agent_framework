defmodule CodingAgentFramework.TmuxScopeTest do
  @moduledoc """
  `Tmux.CLI` on a host whose `scope` is `:systemd_user`, with a stand-in for `systemd-run`: one
  that records its words and runs the command after its options, as `systemd-run --scope`
  does, and one that fails as `systemd-run` does without a user bus. The server listens on a
  socket this test owns.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Host, Tmux}
  alias CodingAgentFramework.Tmux.CLI

  setup do
    {:ok, dir: test_dir()}
  end

  test "a scoped host's server needs its systemd_run" do
    host = Host.local("test", program!(:kill), scope: :systemd_user)

    assert {:refused, {:no_program, [:systemd_run]}} =
             CLI.new(programs(host), {:socket, "/x/tmux.sock"})
  end

  test "each new session's client runs in a scope of its own", %{dir: dir} do
    words = Path.join(dir, "words")

    passing =
      stand_in(dir, "passing", """
      printf '%s\\n' "$@" >> "#{words}"
      while [ "${1#--}" != "$1" ]; do shift; done
      exec "$@"
      """)

    server = server!(dir, passing)
    assert {:ok, "%" <> _} = Tmux.new_session(server, "alpha", [program!(:cat)], [])
    assert {:ok, "%" <> _} = Tmux.new_session(server, "beta", [program!(:cat)], [])
    assert {:ok, [_, _]} = Tmux.list_panes(server)

    units = for "--unit=" <> unit <- lines(File.read!(words)), do: unit
    assert [first, second] = units
    assert first != second
    assert first =~ ~r/\Acaf-[0-9a-f]{12}-tmux-\d+-\d+\z/

    assert ["--user", "--scope", "--collect", "--quiet", "--expand-environment=no" | _] =
             lines(File.read!(words))
  end

  test "a systemd-run that fails refuses the start, and no server runs", %{dir: dir} do
    failing =
      stand_in(dir, "failing", """
      echo "Failed to connect to user scope bus via local transport: no bus" >&2
      exit 1
      """)

    server = server!(dir, failing)

    assert {:refused, {:scope, "Failed to connect" <> _}} =
             Tmux.new_session(server, "alpha", [program!(:cat)], [])

    assert {:refused, :no_server} = Tmux.list_panes(server)
  end

  defp server!(dir, systemd_run) do
    host = Host.local("test", program!(:kill), scope: :systemd_user)
    programs = programs(host, %{systemd_run: systemd_run})
    {:ok, server} = CLI.new(programs, {:socket, Path.join(dir, "tmux.sock")})
    # The test owns this server; it ends it and its socket file whatever the test did.
    on_exit(fn -> Tmux.kill_server(server) end)
    server
  end

  defp stand_in(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!#{program!(:sh)}\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp lines(text), do: String.split(text, "\n", trim: true)
end
