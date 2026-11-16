defmodule CodingAgentFramework.Screen.Reading do
  @moduledoc """
  What one Claude Code release draws, as data `CodingAgentFramework.Screen` reads a capture by.

  Each release has a module of its own named by its version, `Reading.V<major>_<minor>_<patch>`
  (`Reading.V2_1_322` for 2.1.322). `Screen` finds it by that name, so a new release adds one
  module and changes nothing else. A release's reading comes from its own captured fixtures
  (`apps/caf_screen/test/fixtures/<release>/`), never from an older release's.

  The fields:

    * `box`: what starts the input box's line, the prompt mark and what follows it;
    * `prompt`: the prompt mark alone, which is an empty box too;
    * `placeholder`: the hint an empty box shows, which is not typed text;
    * `running`: the words in the footer under the box while a turn runs;
    * `exited`: the line Claude Code leaves on the screen when it exits;
    * `resume`: what starts the line under `exited`;
    * `dialogs`: each dialog `Screen` knows, by its kind: its `title` (a line inside it), its
      `footer` (what starts its last line) and whether its options are `numbered`.
  """

  @type dialog :: %{
          kind: atom,
          title: String.t(),
          footer: String.t(),
          numbered: boolean
        }

  @type t :: %{
          box: String.t(),
          prompt: String.t(),
          placeholder: Regex.t(),
          running: String.t(),
          exited: String.t(),
          resume: String.t(),
          dialogs: [dialog]
        }

  @doc "The release's reading."
  @callback reading() :: t
end
