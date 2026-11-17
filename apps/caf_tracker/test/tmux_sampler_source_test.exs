defmodule CodingAgentFramework.TmuxSamplerSourceTest do
  @moduledoc """
  `TableSource` over `TmuxSampler.Table` reads what a `TmuxSampler` wrote, and its failed
  reads, into a `Tracker`.
  The sampler reads a server whose panes the test sets.
  """
  use ExUnit.Case, async: true

  alias CodingAgentFramework.{SamplerSetup, TmuxSampler, Tracker}

  # A server whose panes the test sets: a read that fails, or panes of any shape.
  defmodule Scripted do
    defstruct [:pid]
    def key(_), do: {"test", "scripted"}
    def list_panes(%__MODULE__{pid: pid}), do: Agent.get(pid, & &1)
  end

  setup {SamplerSetup, :sampler}

  test "a failed read answers unknown and keeps the last good sample, with its age", ctx do
    {:ok, script} = Agent.start_link(fn -> {:ok, []} end)
    holder = ctx.holder
    me = self()
    db = Path.join(ctx.dir, "f.db")

    {:ok, sampler} =
      TmuxSampler.start_link(
        server: %Scripted{pid: script},
        holder: holder,
        db: db,
        notify: &send(me, {:cue, &1})
      )

    {:ok, tracker} =
      Tracker.start_link(
        sources: [
          {Tracker.TableSource,
           table: TmuxSampler.Table, db: db, host: "test", server: "scripted"}
        ],
        timer: false
      )

    Agent.update(script, fn _ -> {:ok, [{:malformed, "%9\tjunk"}, :junk]} end)
    assert {:ok, %{problems: 2}} = TmuxSampler.sample(sampler)
    assert {:ok, %{rows: [_, _], read_at: at}} = TmuxSampler.rows(sampler)
    assert {:ok, %{{"test", "tmux:scripted"} => %{viewers: [_, _]}}} = Tracker.view(tracker)

    Agent.update(script, fn _ -> {:unknown, :timeout} end)
    assert {:unknown, {:tmux, {:unknown, :timeout}}} = TmuxSampler.sample(sampler)

    assert {:ok, %{rows: [_, _], read_at: ^at, failed_at: f, age: age}} =
             TmuxSampler.rows(sampler)

    assert is_integer(f) and is_integer(age)
    assert_received {:cue, %{ids: []}}

    {:ok, view} = Tracker.view(tracker)

    assert %{
             viewers: [_, _],
             sources: %{"tmux:test:scripted" => %{problem: {:sample_failed, _, _}}}
           } =
             view[{"test", "tmux:scripted"}]
  end
end
