defmodule CodingAgentFramework.HolderScopeTest do
  @moduledoc """
  `Holder` on a host whose `scope` is `:systemd_user`, with a stand-in for `systemd-run`: one
  that records its words and runs the command after its options, as `systemd-run --scope`
  does, and one that fails as `systemd-run` does without a user bus.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Holder, Host}

  setup do
    {:ok, dir: test_dir()}
  end

  test "a scoped host's command starts with systemd-run, in a unit named per directory" do
    {:ok, plain} = Holder.new(programs(), "/tmp/agents")
    {:ok, scoped} = Holder.new(scoped_programs("/usr/bin/systemd-run"), "/tmp/agents")
    {:ok, other} = Holder.new(scoped_programs("/usr/bin/systemd-run"), "/tmp/other")

    {:ok, unscoped} = Holder.hold_argv(plain, "alpha", ["/run/claude"], [{"HOME", "/h"}])
    {:ok, argv} = Holder.hold_argv(scoped, "alpha", ["/run/claude"], [{"HOME", "/h"}])

    unit = Holder.unit(scoped, "alpha")
    assert unit =~ ~r/\Acaf-[0-9a-f]{12}-alpha\z/
    assert unit != Holder.unit(other, "alpha")

    scope = ["--user", "--scope", "--collect", "--quiet", "--expand-environment=no"]
    assert argv == ["/usr/bin/systemd-run" | scope] ++ ["--unit=" <> unit | unscoped]

    assert [_env, "-i", "HOME=/h" | _] = unscoped
  end

  test "a scoped host's holder needs its systemd_run" do
    {:ok, bare} = Holder.new(programs(), "/x")
    assert bare.systemd_run == nil

    without = programs(Host.local("test", program!(:kill), scope: :systemd_user))
    assert {:refused, {:no_program, [:systemd_run]}} = Holder.new(without, "/x")
  end

  test "a systemd-run that fails refuses the start, and nothing is held", %{dir: dir} do
    failing =
      stand_in(dir, "failing", """
      echo "Failed to connect to user scope bus via local transport: no bus" >&2
      exit 1
      """)

    {:ok, h} = Holder.new(scoped_programs(failing), dir)

    assert {:refused, {:scope, "Failed to connect" <> _}} =
             Holder.hold(h, "alpha", [program!(:cat)])

    assert {:ok, :absent} = Holder.state(h, "alpha")
  end

  test "under a systemd-run that starts it, the holder holds the process", %{dir: dir} do
    words = Path.join(dir, "words")

    passing =
      stand_in(dir, "passing", """
      printf '%s\\n' "$@" > "#{words}"
      while [ "${1#--}" != "$1" ]; do shift; done
      exec "$@"
      """)

    {:ok, h} = Holder.new(scoped_programs(passing), dir)
    pids = Path.join(dir, "alpha.pids")
    script = ~s(echo "$$" > "$0.tmp" && #{program!(:mv)} "$0.tmp" "$0"; #{echo_tail!(dir)})
    on_exit(fn -> end_recorded(dir) end)

    assert {:ok, _socket} = Holder.hold(h, "alpha", [program!(:sh), "-c", script, pids])
    assert {:ok, _} = await(fn -> File.read(pids) end)
    assert {:ok, :live} = Holder.state(h, "alpha")

    unit = "--unit=" <> Holder.unit(h, "alpha")

    assert ["--user", "--scope", "--collect", "--quiet", "--expand-environment=no", ^unit | _] =
             File.read!(words) |> lines()
  end

  defp scoped_programs(systemd_run),
    do:
      programs(Host.local("test", program!(:kill), scope: :systemd_user), %{
        systemd_run: systemd_run
      })

  defp stand_in(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!#{program!(:sh)}\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp lines(text), do: String.split(text, "\n", trim: true)
end

defmodule CodingAgentFramework.HolderSystemdTest do
  @moduledoc """
  A holder started from inside a transient systemd user unit, as the embedding app's own unit
  starts it, on the host's real user systemd. Stopping that unit ends every process in its
  cgroup: an unscoped holder ends with it, and a scoped one lives on.

  Tagged `:systemd_user`. `test_helper.exs` excludes the tag unless this host's user systemd
  starts a scope, so the gates run it on a Linux host with a user systemd and skip it elsewhere.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Holder, Host, SystemdUser}

  @moduletag :systemd_user

  setup do
    {:ok, systemd} = SystemdUser.find()
    {:ok, dir: test_dir(), systemd: systemd}
  end

  test "stopping the app's unit ends an unscoped holder", %{dir: dir, systemd: systemd} do
    {:ok, h} = Holder.new(programs(), dir)
    {child, unit} = hold_in_unit!(h, dir, systemd)

    stop!(systemd, unit)
    assert {:ok, :ended} = await(fn -> if alive?(child), do: :alive, else: {:ok, :ended} end)
  end

  test "stopping the app's unit leaves a scoped holder and its session", ctx do
    %{dir: dir, systemd: systemd} = ctx
    host = Host.local("test", program!(:kill), scope: :systemd_user)
    {:ok, h} = Holder.new(programs(host, %{systemd_run: systemd.run}), dir)
    {child, unit} = hold_in_unit!(h, dir, systemd)

    stop!(systemd, unit)
    assert alive?(child)
    assert {:ok, :live} = Holder.state(h, "alpha")
  end

  # Starts a transient service, standing in for the app's unit, that runs the holder's command
  # and then stays up. Answers the held process's pid and the service's unit.
  defp hold_in_unit!(h, dir, systemd) do
    unit = "caf-test-app-#{System.pid()}-#{System.unique_integer([:positive])}"
    pids = Path.join(dir, "alpha.pids")
    script = ~s(echo "$$" > "$0.tmp" && #{program!(:mv)} "$0.tmp" "$0"; #{echo_tail!(dir)})
    {:ok, argv} = Holder.hold_argv(h, "alpha", [program!(:sh), "-c", script, pids], [])
    on_exit(fn -> end_recorded(dir) end)
    on_exit(fn -> SystemdUser.run(systemd, systemd.ctl, ["--user", "stop", unit]) end)

    app =
      [
        "--user",
        "--quiet",
        "--collect",
        "--expand-environment=no",
        "--unit=" <> unit,
        "-p",
        "KillMode=control-group"
      ] ++
        ["--", program!(:sh), "-c", ~s("$@"; exec #{program!(:sleep)} 600), "sh" | argv]

    assert {:ok, %{status: 0}} = SystemdUser.run(systemd, systemd.run, app)
    assert {:ok, text} = await(fn -> File.read(pids) end)
    {String.to_integer(String.trim(text)), unit}
  end

  defp stop!(systemd, unit) do
    assert {:ok, %{status: 0}} = SystemdUser.run(systemd, systemd.ctl, ["--user", "stop", unit])
  end
end
