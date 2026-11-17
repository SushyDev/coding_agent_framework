defmodule CodingAgentFramework.Delegates.TurnTest do
  @moduledoc "The pure part of `Delegates`: a start's checks and what a `Stream` row says."
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Delegates.{Table, Turn}
  alias CodingAgentFramework.Stream.Fold

  doctest Turn
  doctest Table

  @project %{name: "app", branches: ~r/\Aunit\//, cap: 2}
  @row %{brief_uuid: "b1", resume_uuid: nil}

  test "a start names a project it was given and a branch its pattern takes" do
    projects = %{"app" => @project, "odd" => %{name: "odd"}, "zero" => %{@project | cap: 0}}
    assert {:ok, %{name: "app", cap: 2}} = Turn.check(projects, "app", "unit/one")
    assert {:refused, {:unknown_project, "web"}} = Turn.check(projects, "web", "unit/one")
    assert {:refused, {:bad, :branch}} = Turn.check(projects, "app", "main")
    assert {:refused, {:bad, :branch}} = Turn.check(projects, "app", nil)
    assert {:refused, {:bad, :project}} = Turn.check(projects, "odd", "unit/one")
    assert {:refused, {:bad, :cap}} = Turn.check(projects, "zero", "unit/one")
  end

  test "a brief's turn waits for its result; the brief itself is Mailbox's to write" do
    assert :waiting = Turn.next(@row, fold(%{}))
    assert :waiting = Turn.next(@row, fold(%{"b1" => %{state: :writing}}))
    assert :waiting = Turn.next(@row, fold(%{"b1" => %{state: :delivered}}, false))

    assert {:finished, %{text: "r"}} =
             Turn.next(@row, fold(%{"b1" => %{state: :delivered}}, true, result("r", "b1")))
  end

  test "a resumed process waits for its own message: the earlier turn's result does not count" do
    # KillSeen under the resume's uuid: the brief's replay and the follow again's idle are old.
    fold = fold(%{"b1" => %{state: :delivered}}, true, result("half", "b1"))
    resumed = %{@row | resume_uuid: "r1"}
    assert :waiting = Turn.next(resumed, fold)
    assert Turn.uuid(resumed) == "r1"
    assert :waiting = Turn.next(resumed, put_in(fold.messages["r1"], %{state: :writing}))

    assert {:finished, %{text: "r"}} =
             Turn.next(
               resumed,
               Fold.upgrade(%{
                 fold
                 | messages: %{"r1" => %{state: :delivered}},
                   last_result: result("r", "r1")
               })
             )
  end

  test "a brief found undelivered waits for Mailbox's resend; a gone process with none is exited" do
    assert :waiting = Turn.next(@row, fold(%{"b1" => %{state: :undelivered}}))
    assert :exited = Turn.next(@row, %{fold(%{"b1" => %{state: :undelivered}}) | gone: true})
    # A turn whose message went in but whose result never came, as a kill leaves it.
    assert :exited = Turn.next(@row, %{fold(%{"b1" => %{state: :delivered}}, false) | gone: true})
    # A finish, then an exit: the result came first.
    done = %{fold(%{"b1" => %{state: :delivered}}, true, result(nil, "b1")) | gone: true}
    assert {:finished, %{text: ""}} = Turn.next(@row, done)
  end

  test "a result that names another message is not this turn's" do
    # A self-started turn's, or a later message's: the brief still waits for its own.
    assert :waiting =
             Turn.next(@row, fold(%{"b1" => %{state: :delivered}}, true, result("x", "m2")))
  end

  defp result(text, uuid), do: %{text: text, user_message_uuids: [uuid]}

  # A fold as an earlier build stored it, loaded as `Stream.Table` loads one.
  defp fold(messages, idle \\ true, last \\ nil),
    do: Fold.upgrade(%{gone: false, idle: idle, messages: messages, last_result: last})
end
