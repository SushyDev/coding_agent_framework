defmodule CodingAgentFramework.Screen.Reading.V2_1_322 do
  @moduledoc """
  The reading of Claude Code 2.1.322, from its fixtures (`docs/build-notes/F-105.md`).

  The input box is one line between two rules of `─`: `❯`, a no-break space, then the typed text
  or the placeholder `Try "…"`. An earlier prompt in the conversation shows `❯` and a plain
  space, so it never reads as the box. The trust dialog's options are bare labels; a permission
  dialog's are numbered.
  """

  @behaviour CodingAgentFramework.Screen.Reading

  @impl true
  def reading do
    %{
      box: "❯ ",
      prompt: "❯",
      placeholder: ~r/\ATry ".*"\z/u,
      running: "esc to interrupt",
      exited: "Resume this session with:",
      resume: "claude --resume ",
      dialogs: [
        %{
          kind: :trust,
          title: "Accessing workspace:",
          footer: "Enter to confirm · Esc to cancel",
          numbered: false
        },
        %{
          kind: :permission,
          title: "Do you want to proceed?",
          footer: "Esc to cancel",
          numbered: true
        }
      ]
    }
  end
end
