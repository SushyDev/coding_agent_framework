defmodule CodingAgentFramework.Sessions.LimitTest do
  @moduledoc """
  The usage limit's field on an agent row (`Sessions.Limit`), and what `Sessions`, its one
  writer, checks before each write and press of it (F-186): a write from a step the row has
  left is refused, a person's answer gets in once, and the menu is pressed only for a row whose
  step is `press`, with an option the row read. The press itself is the `Inlet`'s checked press
  (`InletTest`); no `Inlet` is given here, so a press that passes every check is refused
  `:no_inlet`, with nothing sent.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.Sessions
  alias CodingAgentFramework.Sessions.{Agents, Limit, Table}
  alias CodingAgentFramework.Tmux.Fake

  doctest Limit

  @stop "Stop and wait for limit to reset"

  setup do
    dir = test_dir()
    db = Path.join(dir, "caf.db")
    {:ok, fake} = Fake.start_link(key: {"test", "fake"})
    File.mkdir_p!(Path.join(dir, "d"))

    {:ok, sessions} =
      Sessions.start_link(
        programs: programs(),
        dir: Path.join(dir, "d"),
        tmux: Fake.new(fake, {"test", "fake"}),
        db: db
      )

    {:ok, table} = Table.open(db)
    {:ok, agents} = Agents.open(db, "test")
    row = %{host: "test", name: "app-epic", socket: "app-epic", account: "work", cwd: dir}
    id = Table.starting(table, Map.merge(row, %{role: "parent", resume: nil}))
    Table.update(table, id, status: "running")
    %{sessions: sessions, agents: agents}
  end

  test "a write from a step the row left is refused; the counts alone clear the limit", ctx do
    l = %{"until" => 9, "step" => "credits", "options" => [@stop, "Use usage credits"]}
    assert {:ok, _} = Sessions.put_limit(ctx.sessions, "app-epic", l, from: nil)

    assert {:ok, _} =
             Sessions.answer_limit(ctx.sessions, "app-epic", "usage_credits", @stop, "sam")

    # The healer read `credits` before the answer: its write is refused, the answer stays.
    assert {:refused, {:moved, "press"}} =
             Sessions.put_limit(ctx.sessions, "app-epic", %{l | "step" => "idle"},
               from: "credits"
             )

    assert %{"step" => "press", "label" => @stop, "by" => "sam"} =
             Agents.limit(Agents.get(ctx.agents, "app-epic"))

    assert {:refused, :settled} =
             Sessions.answer_limit(ctx.sessions, "app-epic", "usage_credits", @stop, "sam")

    assert {:ok, row} =
             Sessions.put_limit(ctx.sessions, "app-epic", %{"goes" => 2}, from: "press")

    assert Agents.limit(row) == nil
    assert Limit.of(row) == %{"goes" => 2}
    assert {:refused, {:bad, :limit}} = Sessions.put_limit(ctx.sessions, "app-epic", goes: 2)
  end

  test "the menu is pressed only from the step press, by an option the row read", ctx do
    assert {:refused, {:step, nil}} = Sessions.press_limit(ctx.sessions, "app-epic", @stop)
    assert {:refused, :no_session} = Sessions.press_limit(ctx.sessions, "app-none", @stop)

    l = %{"until" => 9, "step" => "press", "label" => @stop, "options" => [@stop]}
    assert {:ok, _} = Sessions.put_limit(ctx.sessions, "app-epic", l)

    assert {:refused, {:no_option, "Use usage credits"}} =
             Sessions.press_limit(ctx.sessions, "app-epic", "Use usage credits")

    assert {:refused, :no_inlet} = Sessions.press_limit(ctx.sessions, "app-epic", @stop)
  end
end
