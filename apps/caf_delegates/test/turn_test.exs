defmodule CodingAgentFramework.Delegates.TurnTest do
  @moduledoc "The pure part of `Delegates`: a start's checks and what a `Stream` row says."
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Delegates.{Table, Turn}

  doctest Turn
  doctest Table

  @project %{name: "app", branches: ~r/\Aunit\//, cap: 2}
  @row %{brief_uuid: "b1", brief: "do it"}

  test "a start names a project it was given and a branch its pattern takes" do
    projects = %{"app" => @project, "odd" => %{name: "odd"}, "zero" => %{@project | cap: 0}}
    assert {:ok, %{name: "app", cap: 2}} = Turn.check(projects, "app", "unit/one")
    assert {:refused, {:unknown_project, "web"}} = Turn.check(projects, "web", "unit/one")
    assert {:refused, {:bad, :branch}} = Turn.check(projects, "app", "main")
    assert {:refused, {:bad, :branch}} = Turn.check(projects, "app", nil)
    assert {:refused, {:bad, :project}} = Turn.check(projects, "odd", "unit/one")
    assert {:refused, {:bad, :cap}} = Turn.check(projects, "zero", "unit/one")
  end

  test "a brief goes in once: written, it waits for its turn's result" do
    assert {:write, "b1", "do it"} = Turn.next(@row, fold(%{}))
    assert :waiting = Turn.next(@row, fold(%{"b1" => %{state: :writing}}))
    assert :waiting = Turn.next(@row, fold(%{"b1" => %{state: :delivered}}, false))

    assert {:finished, "r"} =
             Turn.next(@row, fold(%{"b1" => %{state: :delivered}}, true, %{text: "r"}))
  end

  test "a brief found undelivered goes again under its uuid; a gone process with none is exited" do
    assert {:write, "b1", "do it"} = Turn.next(@row, fold(%{"b1" => %{state: :undelivered}}))
    assert :exited = Turn.next(@row, %{fold(%{"b1" => %{state: :undelivered}}) | gone: true})
    # A turn whose message went in but whose result never came, as a kill leaves it.
    assert :exited = Turn.next(@row, %{fold(%{"b1" => %{state: :delivered}}, false) | gone: true})
    # A finish, then an exit: the result came first.
    done = %{fold(%{"b1" => %{state: :delivered}}, true, %{}) | gone: true}
    assert {:finished, ""} = Turn.next(@row, done)
  end

  defp fold(messages, idle \\ true, last \\ nil),
    do: %{gone: false, idle: idle, messages: messages, last_result: last}
end
