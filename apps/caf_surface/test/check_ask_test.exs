defmodule CodingAgentFramework.CheckAskTest do
  @moduledoc """
  The facade's check of an ask (F-270): the same function `Mailbox` refuses an agent's ask by
  (`Mailbox.Ask.questions/1`), so an app that checks first is never refused after. It needs no
  instance.
  """
  use ExUnit.Case, async: true

  alias CodingAgentFramework.Mailbox.Ask

  defp question(options) do
    %{
      "header" => "Base",
      "question" => "Rebase or merge?",
      "multiSelect" => false,
      "options" => options
    }
  end

  @rebase %{"label" => "Rebase", "description" => "a straight history"}
  @merge %{"label" => "Merge", "description" => "keeps the merge"}

  test "an option with no description is refused by the facade's check as by the framework's" do
    good = [question([@rebase, @merge])]
    assert {:ok, ^good} = CodingAgentFramework.check_ask(good)

    no_description = [question([@rebase, Map.delete(@merge, "description")])]
    blank = [question([@rebase, %{@merge | "description" => "  "}])]
    same = [question([@rebase, @rebase])]
    one = [question([@rebase])]

    atoms = [
      %{
        header: "Base",
        question: "Rebase or merge?",
        multiSelect: false,
        options: [%{label: "Rebase"}, %{label: "Merge"}]
      }
    ]

    for questions <- [no_description, blank, same, one, atoms, [], "no"] do
      assert {:refused, {:bad, :questions}} = CodingAgentFramework.check_ask(questions)
      assert CodingAgentFramework.check_ask(questions) == Ask.questions(questions)
    end
  end
end
