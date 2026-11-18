defmodule CodingAgentFramework.Screen.Reading.V2_1_322 do
  @moduledoc """
  The reading of Claude Code 2.1.322, from its fixtures (`docs/build-notes/F-105.md`, and
  F-140's for the imports dialog).

  The input box is one line between two rules of `─`: `❯`, a no-break space, then the typed text
  or the placeholder `Try "…"`. An earlier prompt in the conversation shows `❯` and a plain
  space, so it never reads as the box. The trust dialog's options are bare labels one column in;
  the imports dialog's two columns in, under the external paths it lists, one a line: a path
  wider than the pane is shortened in its middle with `…` and never wrapped (F-144's capture);
  a permission dialog's are numbered.
  """

  @behaviour CodingAgentFramework.Screen.Reading

  @impl true
  def reading do
    %{
      box: "❯\u00a0",
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
          numbered: false,
          indent: 1
        },
        %{
          kind: :imports,
          title: "Allow external CLAUDE.md file imports?",
          footer: "Enter to confirm · Esc to cancel",
          numbered: false,
          indent: 2,
          paths: "External imports:",
          # A path wider than the pane is cut in its middle with this, on one line (F-144).
          shortened: "…"
        },
        %{
          kind: :permission,
          title: "Do you want to proceed?",
          footer: "Esc to cancel",
          numbered: true,
          indent: 1
        }
      ]
    }
  end
end
