defmodule CodingAgentFramework.RecoveriesSetup do
  @moduledoc """
  The setup and helpers `RecoveriesTest` and `ActsSourceTest` share: a `Recoveries` on a real
  tmux server and real dtach sockets in the test's own directory, with `cat` held as the agent's
  stand-in, the instance's `Acts`, and the host's `Sessions`, which answers each viewer's
  command from the row `hold!/3` leaves. The sampler, `Acts` and `Recoveries` share a clock the
  test moves: it ticks one ms per reading. `Acts`' cues come to the test as `{:cue, cue}`.

  It compiles only for tests. It lives in `caf_recoveries`, not `caf_test`, because it uses
  `Recoveries`, and `caf_test` may not use an app above it.

      setup {CodingAgentFramework.RecoveriesSetup, :recoveries}
  """

  import CodingAgentFramework.TestHost
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias CodingAgentFramework.{Acts, Control, Holder, Recoveries, Sessions, Tmux, TmuxSampler}
  alias CodingAgentFramework.Tmux.CLI

  @doc """
  An ExUnit setup. `time` is the counter the shared clock reads; its cues come to the test as
  `{:cue, cue}`.
  """
  def recoveries(_context) do
    dir = test_dir()
    {:ok, server} = CLI.new(programs(), {:socket, Path.join(dir, "tmux.sock")})
    on_exit(fn -> Tmux.kill_server(server) end)
    File.mkdir_p!(Path.join(dir, "d"))
    {:ok, holder} = Holder.new(programs(), Path.join(dir, "d"))
    {:ok, control} = Control.start_link(tmux: server)
    db = Path.join(dir, "r.db")

    {:ok, sessions} =
      Sessions.start_link(
        programs: programs(),
        dir: Path.join(dir, "d"),
        control: control,
        home: dir,
        db: db
      )

    time = :counters.new(1, [:atomics])
    :counters.put(time, 1, 1_000_000)

    clock = fn ->
      :counters.add(time, 1, 1)
      :counters.get(time, 1)
    end

    {:ok, sampler} = TmuxSampler.start_link(server: server, holder: holder, db: db, clock: clock)
    me = self()

    {:ok, acts} =
      Acts.start_link(
        db: db,
        start_id: "s1",
        host: "test",
        instance: "a",
        clock: clock,
        notify: &send(me, {:cue, &1})
      )

    opts = [
      sampler: sampler,
      control: control,
      holder: holder,
      programs: programs(),
      sessions: sessions,
      server: server,
      acts: acts,
      size: {80, 24},
      end_grace: 300,
      clock: clock
    ]

    {:ok, recoveries} = Recoveries.start_link(opts)

    {:ok,
     dir: dir,
     db: db,
     acts: acts,
     server: server,
     holder: holder,
     control: control,
     sessions: sessions,
     sampler: sampler,
     opts: opts,
     time: time,
     clock: clock,
     recoveries: recoveries}
  end

  @doc "The key of the test's tmux server, as the rows name it."
  def key(ctx), do: elem(Tmux.key(ctx.server), 1)

  @doc "The rows `Recoveries` wrote in `Acts` for the test's server."
  def rows(ctx) do
    {:ok, rows} = Acts.rows(ctx.acts, actor: actor(ctx))
    rows
  end

  @doc "The actor the test's `Recoveries` writes its rows as."
  def actor(ctx), do: "recoveries:test:" <> key(ctx)

  @doc "Samples once and answers the held row of `name`."
  def held(ctx, name) do
    assert {:ok, _} = TmuxSampler.sample(ctx.sampler)
    {:ok, %{rows: rows}} = TmuxSampler.rows(ctx.sampler)
    Enum.find(rows, &(&1.key == "held:" <> name))
  end

  @doc """
  Two samples read `name` lost, a check after each: the first claims nothing, the second claims
  one state, whose id it answers.
  """
  def agree(ctx, name) do
    assert held(ctx, name).status in [:unviewed, :no_server]
    assert {:ok, %{claimed: []}} = Recoveries.check(ctx.recoveries)
    assert held(ctx, name).status in [:unviewed, :no_server]
    assert {:ok, %{claimed: [id]}} = Recoveries.check(ctx.recoveries)
    {:ok, id}
  end

  @doc "Opens a viewer of `name` through the test's `Control`, as `Sessions` does."
  def view(ctx, name) do
    {:ok, argv} = Sessions.viewer_argv(ctx.sessions, name)
    Sessions.viewer(ctx.control, name, argv, {80, 24})
  end

  @doc """
  Holds the stand-in and waits for its pids, `{child, master}`; ends it when the test ends, while
  its socket lives. It leaves the row `Sessions` would: a running session of `role` (`"parent"`,
  or `"delegate"`, whose event log is `log/2`), or none when `role` is nil.
  """
  def hold!(%{holder: h, dir: dir} = ctx, name, role \\ "parent") do
    pids = Path.join(dir, "#{name}.pids")

    script =
      ~s(echo "$$ $PPID" > "$0.tmp" && #{program!(:mv)} "$0.tmp" "$0"; #{echo_tail!(dir)})

    # Registered before the hold, so a test that fails mid-start ends it too.
    on_exit(fn -> end_recorded(dir) end)

    assert {:ok, _} = Holder.hold(h, name, [program!(:sh), "-c", script, pids])
    assert {:ok, text} = await(fn -> File.read(pids) end)
    [child, master] = text |> String.split() |> Enum.map(&String.to_integer/1)
    if role, do: row!(ctx, name, role, child)

    on_exit(fn ->
      if Holder.state(h, name) == {:ok, :live} and alive?(master), do: kill(child)
    end)

    {child, master}
  end

  @doc "The event log `Sessions` tells a viewer of delegate `name` to follow."
  def log(%{dir: dir}, name), do: Path.join([dir, "streams", "id-" <> name, "events.jsonl"])

  # The row of a running session, as `Sessions` writes it: its table has `Sessions` alone for a
  # writer, so the test writes what a start leaves rather than run one.
  defp row!(ctx, name, role, pid) do
    {:ok, db} = Sessions.Table.open(ctx.db)
    id = if role == "delegate", do: "id-" <> name

    row = %{
      host: "test",
      name: name,
      socket: name,
      account: "work",
      role: role,
      cwd: ctx.dir,
      resume: nil,
      session_id: id,
      deadline: nil
    }

    Sessions.Table.update(db, Sessions.Table.starting(db, row), status: "running", pid: pid)
  end
end
