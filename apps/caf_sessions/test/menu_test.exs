defmodule CodingAgentFramework.Sessions.MenuTest do
  @moduledoc """
  The row's menu field (F-198, `Menu.tla`'s Read, Take, Pressed and Recover), as a pure module.
  """
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Sessions.Menu

  doctest Menu

  @screen %{
    state: :dialog,
    kind: :menu,
    title: "Teach auto mode about your environment?",
    detail: ["Auto mode works better when it knows your environment."],
    options: ["Yes", "Not now", "Don't show again"],
    selected: "Yes"
  }

  test "a read keeps one menu by its title and options, and its key with it" do
    {:write, field} = Menu.seen(nil, @screen, 7, 100)
    assert %{"start" => 7, "at" => 100, "selected" => "Yes"} = field

    # The marker moved at the viewer: the same menu, the same key.
    assert {:write, %{"at" => 100, "selected" => "Not now"}} =
             Menu.seen(field, %{@screen | selected: "Not now"}, 7, 200)

    # Another menu is another prompt.
    assert {:write, %{"at" => 300, "title" => "Another?"}} =
             Menu.seen(field, %{@screen | title: "Another?"}, 7, 300)

    # A screen with no menu takes it away; with none on the row there is nothing to write.
    assert Menu.seen(field, %{state: :idle, box: :empty}, 7, 400) == {:write, nil}
    assert Menu.seen(nil, %{state: :idle, box: :empty}, 7, 400) == :same
  end

  test "a press under way is not read over; once sent, the menu read again is a new one" do
    {:write, field} = Menu.seen(nil, @screen, 7, 100)
    pressing = Menu.mark(field, "pressing", %{"label" => "Yes", "by" => "sam", "act" => 3})
    assert Menu.seen(pressing, %{state: :idle, box: :empty}, 7, 200) == :same
    assert Menu.status(pressing) == "answering"
    assert Menu.check(pressing, 100, "Yes") == {:refused, {:answered, "pressing"}}

    sent = Menu.mark(pressing, "sent", %{})
    assert Menu.status(sent) == nil
    assert {:write, %{"at" => 300} = again} = Menu.seen(sent, @screen, 7, 300)
    refute Map.has_key?(again, "mark")

    unknown = Menu.mark(pressing, "unknown", %{})
    assert Menu.seen(unknown, @screen, 7, 300) == :same
    assert Menu.status(unknown) == "unknown"
  end

  test "a refusal takes the mark back; a restart makes a press under way unknown" do
    {:write, field} = Menu.seen(nil, @screen, 7, 100)
    pressing = Menu.mark(field, "pressing", %{"label" => "esc", "by" => "sam", "act" => 3})
    assert Menu.mark(pressing, nil, %{}) == field
    assert %{"mark" => "unknown", "act" => 3} = Menu.after_restart(pressing)
    assert Menu.after_restart(field) == nil
    assert Menu.check(field, 100, "esc") == :ok
    assert Menu.check(field, 100, "Maybe") == {:refused, {:no_option, "Maybe"}}
    assert Menu.check(nil, 100, "Yes") == {:refused, :settled}
  end
end
