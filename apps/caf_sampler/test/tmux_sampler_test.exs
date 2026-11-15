defmodule CodingAgentFramework.TmuxSamplerTest do
  @moduledoc """
  `TmuxSampler` on a real tmux server and real dtach sockets in this test's own directory. The
  held stand-in records its pid and dtach's, so the test waits on that file and ends both by pid.
  A viewer is a pane running `dtach -a` on the stand-in's socket. Each sample is a call, so the
  test reads what each event left without waiting on a timer.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Holder, SamplerSetup, Tmux, TmuxSampler}
  alias CodingAgentFramework.TmuxSampler.Join

  doctest TmuxSampler
  doctest Join
  doctest TmuxSampler.Table

  setup {SamplerSetup, :sampler}

  test "a held agent with a viewer, then its viewer killed: unviewed", ctx do
    assert TmuxSampler.rows(ctx.sampler) == :unread
    hold!(ctx, "alpha")
    {:ok, viewer} = view(ctx, "alpha")
    # A pane tagged for a session with no socket keeps the server up when the viewer goes.
    {:ok, keeper} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])

    assert %{"held:alpha" => %{status: :viewed, panes: ^viewer}, ("viewer:0:" <> ^viewer) => v} =
             sample!(ctx)

    assert %{status: :live, name: "alpha"} = v
    assert %{status: :gone} = sample!(ctx)["viewer:0:" <> keeper]
    assert_received {:cue, %{topic: "tmux:test:" <> _, ids: [_ | _]}}

    assert {:ok, :killed} = Tmux.kill_pane(ctx.server, viewer, "alpha")
    rows = sample!(ctx)
    assert %{status: :unviewed, socket: :live} = rows["held:alpha"]
    refute Map.has_key?(rows, "viewer:0:" <> viewer)
  end

  test "a dead server is no_server; a new server's %0 is a new set", ctx do
    hold!(ctx, "alpha")
    hold!(ctx, "beta")
    {:ok, "%0"} = view(ctx, "alpha")
    assert %{"viewer:0:%0" => %{name: "alpha"}} = sample!(ctx)

    assert {:ok, :killed} = Tmux.kill_server(ctx.server)
    rows = sample!(ctx)
    assert %{status: :no_server} = rows["held:alpha"]
    assert %{status: :no_server} = rows["held:beta"]
    refute Map.has_key?(rows, "viewer:0:%0")

    # The new server counts from %0 again; beta's viewer takes alpha's old id.
    {:ok, "%0"} = view(ctx, "beta")
    rows = sample!(ctx)
    assert %{status: :unviewed} = rows["held:alpha"]
    assert %{status: :viewed, panes: "%0"} = rows["held:beta"]
    assert %{name: "beta", generation: 1} = rows["viewer:1:%0"]
    refute Map.has_key?(rows, "viewer:0:%0")

    # A restart seen by its start alone, with no sample between, is a new set too.
    assert {:ok, :killed} = Tmux.kill_server(ctx.server)
    {:ok, "%0"} = view(ctx, "beta")
    assert %{"viewer:2:%0" => %{name: "beta"}} = rows = sample!(ctx)
    refute Map.has_key?(rows, "viewer:1:%0")
  end

  test "a stale socket, and a pane tagged for it", ctx do
    {_child, master} = hold!(ctx, "alpha")
    {:ok, _} = Tmux.new_session(ctx.server, "keeper", [program!(:cat)])
    kill(master, "-KILL")
    assert {:ok, :stale} = await(fn -> stale(ctx.holder) end)
    # A viewer's dtach -a would fail on the stale socket; a pane tagged for alpha stays.
    {:ok, pane} = Tmux.new_session(ctx.server, "alpha", [program!(:cat)])
    rows = sample!(ctx)
    assert %{status: :stale, socket: :stale} = rows["held:alpha"]
    assert %{status: :stale, name: "alpha"} = rows["viewer:0:" <> pane]
  end

  describe "the join" do
    property "is total, keeps each bad entry as a problem, and sees every unviewed agent" do
      check all panes <- list_of(pane()),
                held <- list_of(held()),
                server <- member_of([:up, :no_server]) do
        input = if server == :up, do: {:ok, panes}, else: :no_server
        join = Join.join(input, held, nil)
        good = Enum.filter(panes, &is_map/1)
        names = for %{name: n} <- held, is_binary(n), uniq: true, do: n

        for name <- names do
          row = join.rows["held:" <> name]
          state = held |> Enum.filter(&(&1[:name] == name)) |> List.last() |> Map.get(:state)
          shown? = Enum.any?(good, &(&1.tag == name))

          expected =
            case state do
              :live when server == :no_server -> :no_server
              :live -> if shown?, do: :viewed, else: :unviewed
              :stale -> :stale
              _ -> :unknown
            end

          assert row.status == expected
        end

        bad = if server == :up, do: Enum.reject(panes, &is_map/1), else: []
        bad = Enum.uniq(bad ++ Enum.reject(held, &is_binary(&1[:name])))
        assert Enum.count(join.rows, fn {_, r} -> r.kind == :problem end) == length(bad)
      end
    end

    property "a new server start is a new generation; no pane key crosses it" do
      check all a <- list_of(integer(0..5), min_length: 1),
                b <- list_of(integer(0..5), min_length: 1) do
        first = Join.join({:ok, panes(a, "1@1")}, [], nil)
        second = Join.join({:ok, panes(b, "2@1")}, [], first)
        assert second.generation == first.generation + 1
        keys = fn j -> j.rows |> Map.keys() |> MapSet.new() end
        assert MapSet.disjoint?(keys.(first), keys.(second))
      end
    end
  end

  defp panes(ids, start),
    do: for(i <- Enum.uniq(ids), do: %{pane: "%#{i}", session: "s", tag: "s", start: start})

  defp pane do
    good =
      map({integer(0..9), member_of(["a", "b", "c"]), member_of(["a", "b", nil])}, fn {i, s, t} ->
        %{pane: "%#{i}", session: s, tag: t, start: "1@1"}
      end)

    one_of([good, map(string(:printable), &{:malformed, &1}), constant(:junk)])
  end

  defp held do
    good =
      map({member_of(["a", "b", "c"]), member_of([:live, :stale, :unknown])}, fn {n, s} ->
        %{name: n, state: s}
      end)

    one_of([good, constant(%{name: 7, state: :live}), constant(nil)])
  end

  defp sample!(ctx) do
    assert {:ok, _} = TmuxSampler.sample(ctx.sampler)
    {:ok, %{rows: rows}} = TmuxSampler.rows(ctx.sampler)
    Map.new(rows, &{&1.key, &1})
  end

  defp view(ctx, name) do
    {:ok, argv} = Holder.viewer_argv(ctx.holder, name)
    Tmux.new_session(ctx.server, name, argv)
  end

  defp stale(holder) do
    case Holder.state(holder, "alpha") do
      {:ok, :stale} -> {:ok, :stale}
      other -> other
    end
  end

  # Holds the stand-in and waits for its pids; ends it when the test ends, while its socket lives.
  defp hold!(%{holder: h, dir: dir}, name) do
    pids = Path.join(dir, "#{name}.pids")

    script =
      ~s(echo "$$ $PPID" > "$0.tmp" && #{program!(:mv)} "$0.tmp" "$0"; #{echo_tail!(dir)})

    # Registered before the hold, so a test that fails mid-start ends it too.
    on_exit(fn -> end_recorded(dir) end)

    assert {:ok, _} = Holder.hold(h, name, [program!(:sh), "-c", script, pids])
    assert {:ok, text} = await(fn -> File.read(pids) end)
    [child, master] = text |> String.split() |> Enum.map(&String.to_integer/1)

    on_exit(fn ->
      if Holder.state(h, name) == {:ok, :live} and alive?(master), do: kill(child)
    end)

    {child, master}
  end
end
