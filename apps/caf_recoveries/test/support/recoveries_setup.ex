defmodule CodingAgentFramework.RecoveriesSetup do
  @moduledoc """
  The setup and helpers `RecoveriesTest` and `RecoveriesSourceTest` share: a `Recoveries` on a
  real tmux server and real dtach sockets in the test's own directory, with `cat` held as the
  agent's stand-in. The sampler and `Recoveries` share a clock the test moves: it ticks one ms
  per reading.

  It compiles only for tests. It lives in `caf_recoveries`, not `caf_test`, because it uses
  `Recoveries`, and `caf_test` may not use an app above it.

      setup {CodingAgentFramework.RecoveriesSetup, :recoveries}
  """

  import CodingAgentFramework.TestHost
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias CodingAgentFramework.{Control, Holder, Recoveries, Sessions, Tmux, TmuxSampler}
  alias CodingAgentFramework.Recoveries.Table
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
    time = :counters.new(1, [:atomics])
    :counters.put(time, 1, 1_000_000)

    clock = fn ->
      :counters.add(time, 1, 1)
      :counters.get(time, 1)
    end

    {:ok, sampler} = TmuxSampler.start_link(server: server, holder: holder, db: db, clock: clock)
    me = self()

    opts = [
      sampler: sampler,
      control: control,
      holder: holder,
      server: server,
      db: db,
      size: {80, 24},
      notify: &send(me, {:cue, &1}),
      clock: clock
    ]

    {:ok, recoveries} = Recoveries.start_link(opts)

    {:ok,
     dir: dir,
     db: db,
     server: server,
     holder: holder,
     control: control,
     sampler: sampler,
     opts: opts,
     time: time,
     clock: clock,
     recoveries: recoveries}
  end

  @doc "The key of the test's tmux server, as the rows name it."
  def key(ctx), do: elem(Tmux.key(ctx.server), 1)

  @doc "The rows `Recoveries` wrote for the test's server."
  def rows(ctx) do
    {:ok, db} = Table.open(ctx.db)
    Table.rows(db, "test", key(ctx))
  end

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
    {:ok, argv} = Holder.viewer_argv(ctx.holder, name)
    Sessions.viewer(ctx.control, name, argv, {80, 24})
  end

  @doc """
  Holds the stand-in and waits for its pids, `{child, master}`; ends it when the test ends, while
  its socket lives.
  """
  def hold!(%{holder: h, dir: dir}, name) do
    pids = Path.join(dir, "#{name}.pids")

    script =
      ~s(echo "$$ $PPID" > "$0.tmp" && #{program!(:mv)} "$0.tmp" "$0"; exec #{program!(:cat)})

    assert {:ok, _} = Holder.hold(h, name, [program!(:sh), "-c", script, pids])
    assert {:ok, text} = await(fn -> File.read(pids) end)
    [child, master] = text |> String.split() |> Enum.map(&String.to_integer/1)

    on_exit(fn ->
      if Holder.state(h, name) == {:ok, :live} and alive?(master), do: kill(child)
    end)

    {child, master}
  end
end
