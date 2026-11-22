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
    * `named_rule`: the rule above the box of a session that has a name, with the name in it;
    * `placeholder`: the hint an empty box shows, which is not typed text;
    * `running`: the words in the footer under the box while a turn runs;
    * `wait`: a line of the footer under the box while Claude Code waits at a usage limit by
      itself, its one capture the time it names;
    * `exited`: the line Claude Code leaves on the screen when it exits;
    * `resume`: what starts the line under `exited`;
    * `menu`: what makes a menu no dialog names (F-198): its `footer`, what starts its last
      line; `Screen` reads any numbered menu with it, by its shape alone;
    * `dialogs`: each dialog `Screen` knows, by its kind: its `title` (a line inside it), its
      `footer` (what starts its last line), whether its options are `numbered`, their `indent`
      (the spaces before the selection mark), and, for a dialog that lists paths, the heading
      above them (`paths`), and the character of its rule (`rule`) when it is not `─`. Two
      kinds that share a footer differ by their title or their rule.
  """

  @type dialog :: %{
          required(:kind) => atom,
          required(:title) => String.t(),
          required(:footer) => String.t(),
          required(:numbered) => boolean,
          required(:indent) => pos_integer,
          optional(:paths) => String.t(),
          optional(:rule) => String.t()
        }

  @type t :: %{
          box: String.t(),
          prompt: String.t(),
          named_rule: Regex.t(),
          placeholder: Regex.t(),
          running: String.t(),
          wait: Regex.t(),
          exited: String.t(),
          resume: String.t(),
          menu: %{footer: String.t()},
          dialogs: [dialog]
        }

  @doc "The release's reading."
  @callback reading() :: t
end
