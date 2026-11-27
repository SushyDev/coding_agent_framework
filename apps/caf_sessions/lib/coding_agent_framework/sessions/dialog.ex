defmodule CodingAgentFramework.Sessions.Dialog do
  @moduledoc """
  A startup dialog on an agent row (F-140, `model/tla/Dialog.tla`): what the row keeps of the
  dialog an interactive start's pane shows, and of each answer to one.

  Claude Code shows the folder trust dialog (`:trust`) and the external `CLAUDE.md` imports
  dialog (`:imports`) before a session's first turn, with no hook event and no session file.
  `Sessions` reads the pane while its start has no session file, and the row says `dialog`
  until the start goes on. Its `dialog` column is the dialog shown (`shown/1`), and its
  `answers` column each kind's answer, marked `pressing` before its press goes, then `sent` or
  `unknown` (`answers/1`), with the id of its row in `Acts` (`act`). An answer whose mark is
  `pressing` when `Sessions` restarts is `cut`: its press may have gone. A kind with any mark
  is never pressed again, but for a `cut` one a person cleared (`clear/2`, F-144): it is
  `cleared`, may be answered once more, and a press of it cut again is `unknown`.

  A numbered menu no rule names that a start meets (`Screen`'s kind `:menu`; an onboarding menu
  on a new account, say) is a startup dialog too (F-203), kind `:start_menu`, kept with its
  `title`: no app's `dialogs:` answers it ahead, so it waits on a person, and its press is the
  Inlet's of a menu (`press_kind/2`), the marker read back on the label before Enter. Its kind
  is not `:menu`, so its prompt's id is never a running session's menu's.

  A start may show several menus one after another (F-206), so a start's menu is keyed by its
  read, as a running session's menu is (`Sessions.Menu`): its `at` is the wall-clock ms of the
  read that found it (`seen/3`), and its answer holds that `at`. A read of another menu (by its
  title and options), or of any menu once the row's was sent, is a new read; an answer to an
  earlier read is no answer to it (`answers/1`), so each menu is asked and pressed once.

      iex> alias CodingAgentFramework.Sessions.Dialog
      iex> screen = %{state: :dialog, kind: :trust, options: ["No, exit", "Yes"], selected: "No, exit"}
      iex> row = %{dialog: Dialog.encode(screen), answers: nil}
      iex> Dialog.shown(row)
      %{kind: :trust, options: ["No, exit", "Yes"], selected: "No, exit", paths: [], shortened: []}
      iex> Dialog.check(row, :trust, "Yes")
      :ok
      iex> Dialog.check(%{row | answers: ~s({"trust":{"label":"Yes","mark":"sent"}})}, :trust, "Yes")
      {:refused, {:answered, "sent"}}
  """

  @kinds [:trust, :imports, :start_menu]

  @typedoc "A startup dialog's kind."
  @type kind :: :trust | :imports | :start_menu

  @doc "The kinds a start meets before its first turn: those `Sessions` reads and answers."
  @spec kinds() :: [kind]
  def kinds, do: @kinds

  @doc """
  A kind by its name, as an operator's tool names it; nil for any other name, so no atom is
  made from a caller's text.

      iex> CodingAgentFramework.Sessions.Dialog.kind("imports")
      :imports
      iex> CodingAgentFramework.Sessions.Dialog.kind("permission")
      nil
  """
  @spec kind(String.t() | atom) :: kind | nil
  def kind(kind) when kind in @kinds, do: kind
  def kind(name) when is_binary(name), do: Enum.find(@kinds, &(Atom.to_string(&1) == name))
  def kind(_), do: nil

  @doc """
  The kinds an app's `dialogs:` may answer ahead: every kind but a start's menu, which has no
  default.
  """
  @spec preset_kinds() :: [kind]
  def preset_kinds, do: @kinds -- [:start_menu]

  @doc "Whether a `Screen` reading is a startup dialog: a start's menu among them."
  @spec startup?(map) :: boolean
  def startup?(%{state: :dialog, kind: :menu}), do: true
  def startup?(%{state: :dialog, kind: kind}) when kind in @kinds, do: true
  def startup?(_), do: false

  @doc """
  The row's `dialog` column for a startup dialog `Screen` read; a menu's is kind
  `:start_menu`, with its `title`.

      iex> screen = %{state: :dialog, kind: :menu, title: "Choose the text style", detail: [],
      ...>   options: ["Dark mode", "Light mode"], selected: "Dark mode"}
      iex> CodingAgentFramework.Sessions.Dialog.encode(screen)
      %{kind: :start_menu, title: "Choose the text style", options: ["Dark mode", "Light mode"],
        selected: "Dark mode", paths: [], shortened: []}
  """
  @spec encode(map) :: map
  def encode(%{state: :dialog, kind: :menu} = screen) do
    %{screen | kind: :start_menu}
    |> Map.take([:kind, :title, :options, :selected])
    |> Map.merge(%{paths: [], shortened: []})
  end

  def encode(%{state: :dialog, kind: kind} = screen) do
    %{kind: kind, options: screen.options, selected: screen.selected}
    |> Map.put(:paths, Map.get(screen, :paths, []))
    |> Map.put(:shortened, Map.get(screen, :shortened, []))
  end

  @doc """
  The row's `dialog` column for a startup dialog `Screen` read at `now` (`Dialog.tla`'s Read):
  `encode/1`'s, and for a start's menu its read's `at`. The menu the row shows keeps its `at`
  while the pane shows the same menu (its title and options) and its answer was not sent; any
  other menu is a new read, `at` now.

      iex> alias CodingAgentFramework.Sessions.Dialog
      iex> screen = %{state: :dialog, kind: :menu, title: "Pick a style", detail: [],
      ...>   options: ["Dark", "Light"], selected: "Dark"}
      iex> first = Dialog.seen(%{dialog: nil, answers: nil}, screen, 100)
      iex> first.at
      100
      iex> Dialog.seen(%{dialog: first, answers: nil}, %{screen | selected: "Light"}, 200).at
      100
      iex> Dialog.seen(%{dialog: first, answers: nil}, %{screen | title: "Pick a theme"}, 200).at
      200
  """
  @spec seen(map, map, integer) :: map
  def seen(row, %{state: :dialog, kind: :menu} = screen, now) do
    fresh = encode(screen)

    shown = shown(row)
    last = shown[:at]

    at =
      cond do
        not is_integer(last) -> now
        match?(%{mark: "sent"}, answers(row)[:start_menu]) -> new_read(now, last)
        same?(shown, fresh) -> last
        true -> new_read(now, last)
      end

    Map.put(fresh, :at, at)
  end

  def seen(_row, screen, _now), do: encode(screen)

  defp same?(a, b), do: a[:title] == b.title and a[:options] == b.options

  # A new read's key is later than the last one, even on a clock that has not moved.
  defp new_read(now, last), do: max(now, last + 1)

  @doc """
  What the Inlet's checked press names for `kind` on the row (`Inlet.choose/5`): the kind, or
  for a start's menu `{:menu, title, options}`, the menu the pane must still show.
  """
  @spec press_kind(map, kind) :: kind | {:menu, String.t(), [String.t()]}
  def press_kind(row, :start_menu) do
    %{title: title, options: options} = shown(row)
    {:menu, title, options}
  end

  def press_kind(_row, kind), do: kind

  @doc """
  The dialog the row shows, or showed last: `%{kind, options, selected, paths, shortened}`
  (`shortened` the paths the pane drew cut in their middle, `Screen`'s), and a start's menu's
  `title` and `at` (its read's, `seen/3`); or nil.
  """
  @spec shown(map | nil) :: map | nil
  def shown(%{dialog: text}) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{"kind" => name, "options" => options, "selected" => selected} = d} ->
        if kind = kind(name) do
          shown = %{
            kind: kind,
            options: options,
            selected: selected,
            paths: d["paths"] || [],
            shortened: d["shortened"] || []
          }

          if kind == :start_menu,
            do: Map.merge(shown, %{title: d["title"], at: d["at"]}),
            else: shown
        end

      _ ->
        nil
    end
  end

  def shown(%{dialog: %{kind: _} = dialog}), do: dialog
  def shown(_), do: nil

  @doc """
  Each kind's answer on the row: `%{kind => %{label: label, mark: mark}}`, with `act` (its row
  in `Acts`) and `cleared: true` (a person cleared a cut press of it) when it has them. A
  start's menu's answer holds `at`, the read it answers, and is the row's only while the row
  shows that read (F-206): an answer to an earlier menu is none to the one shown now.

      iex> alias CodingAgentFramework.Sessions.Dialog
      iex> answers = ~s({"start_menu":{"label":"Dark","mark":"sent","at":100}})
      iex> Dialog.answers(%{dialog: %{kind: :start_menu, at: 100}, answers: answers})
      %{start_menu: %{label: "Dark", mark: "sent", at: 100}}
      iex> Dialog.answers(%{dialog: %{kind: :start_menu, at: 200}, answers: answers})
      %{}
  """
  @spec answers(map | nil) :: %{kind => %{label: String.t(), mark: String.t()}}
  def answers(%{answers: text} = row) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = all} ->
        read = shown(row)[:at]

        for {name, %{"label" => label, "mark" => mark} = a} <- all,
            kind = kind(name),
            kind != :start_menu or a["at"] == read,
            into: %{} do
          extra =
            for {k, v} <- [act: a["act"], cleared: a["cleared"], at: a["at"]], v, do: {k, v}

          {kind, Map.new([label: label, mark: mark] ++ extra)}
        end

      _ ->
        %{}
    end
  end

  def answers(_), do: %{}

  @doc """
  The row's answers with `kind`'s marked `mark`, as the column stores them, with `fields`
  (`act:`) over what the answer had. A start's menu's answer holds the read the row shows
  (`at`). A refusal, which pressed nothing, takes the mark back to what it was before the
  press: none, or `cleared`.
  """
  @spec mark(map, kind, String.t(), String.t() | nil, keyword) :: map
  def mark(row, kind, label, mark, fields \\ [])

  def mark(row, kind, _label, nil, _fields) do
    all = answers(row)

    case all[kind] do
      %{cleared: true} = a -> Map.put(all, kind, %{a | mark: "cleared"})
      _ -> Map.delete(all, kind)
    end
  end

  def mark(row, kind, label, mark, fields) do
    all = answers(row)
    old = Map.take(all[kind] || %{}, [:act, :cleared])
    read = if kind == :start_menu, do: [at: shown(row)[:at]], else: []
    Map.put(all, kind, Map.merge(old, Map.new([label: label, mark: mark] ++ read ++ fields)))
  end

  @doc """
  The answers a restart finds: a press marked `pressing` may have gone, so it is `cut`, or
  `unknown` once a person cleared it before. Answers nil when nothing changes.
  """
  @spec after_restart(map) :: map | nil
  def after_restart(row) do
    all = answers(row)

    if Enum.any?(all, fn {_, a} -> a.mark == "pressing" end) do
      Map.new(all, fn
        {k, %{mark: "pressing", cleared: true} = a} -> {k, %{a | mark: "unknown"}}
        {k, %{mark: "pressing"} = a} -> {k, %{a | mark: "cut"}}
        pair -> pair
      end)
    end
  end

  @doc """
  The answers after a person's clear of `kind`'s cut press (`Dialog.tla`'s Clear): `cleared`,
  so it may be answered once more. Refused `{:not_cut, mark}` for any other mark, a press
  cleared once among them, and `:no_answer` for none.

      iex> alias CodingAgentFramework.Sessions.Dialog
      iex> row = %{answers: ~s({"trust":{"label":"Yes","mark":"cut"}})}
      iex> Dialog.clear(row, :trust)
      {:ok, %{trust: %{label: "Yes", mark: "cleared", cleared: true}}}
      iex> Dialog.clear(%{answers: ~s({"trust":{"label":"Yes","mark":"unknown"}})}, :trust)
      {:refused, {:not_cut, "unknown"}}
  """
  @spec clear(map, kind) :: {:ok, map} | {:refused, term}
  def clear(row, kind) do
    all = answers(row)

    case all[kind] do
      %{mark: "cut"} = a ->
        {:ok, Map.put(all, kind, Map.merge(a, %{mark: "cleared", cleared: true}))}

      %{mark: mark} ->
        {:refused, {:not_cut, mark}}

      nil ->
        {:refused, :no_answer}
    end
  end

  @doc """
  Whether a press of an answer on the row is under way: one is marked `pressing`.

      iex> CodingAgentFramework.Sessions.Dialog.pressing?(%{answers: ~s({"trust":{"label":"Yes","mark":"pressing"}})})
      true
  """
  @spec pressing?(map) :: boolean
  def pressing?(row), do: Enum.any?(answers(row), fn {_, a} -> a.mark == "pressing" end)

  @doc """
  The mark an answer of `kind` is taken from: `"none"`, or `"cleared"` after a person's
  clear. With the row's start, it is the state the answer's row in `Acts` claims, so each is
  answered once.
  """
  @spec from_mark(map, kind) :: String.t()
  def from_mark(row, kind) do
    case answers(row)[kind] do
      nil -> "none"
      %{mark: mark} -> mark
    end
  end

  @doc """
  Whether `label` may answer `kind` on this row now: the row shows that dialog, with that
  option, and no answer to it has been marked but a `cleared` one. For a start's menu, `at`
  names the read answered (its prompt's), or nil for the one shown. Refusals: `{:shown, kind |
  nil}` (another dialog, or none), `{:read, at}` (another menu, the row's read at `at`),
  `{:no_option, label}`, `{:answered, mark}`.

      iex> alias CodingAgentFramework.Sessions.Dialog
      iex> row = %{dialog: %{kind: :start_menu, at: 200, options: ["Dark"]}, answers: nil}
      iex> Dialog.check(row, :start_menu, "Dark", 200)
      :ok
      iex> Dialog.check(row, :start_menu, "Dark", 100)
      {:refused, {:read, 200}}
  """
  @spec check(map, kind, String.t(), integer | nil) :: :ok | {:refused, term}
  def check(row, kind, label, at \\ nil) do
    shown = shown(row)

    cond do
      shown == nil or shown.kind != kind -> {:refused, {:shown, shown && shown.kind}}
      at != nil and shown[:at] != at -> {:refused, {:read, shown[:at]}}
      label not in shown.options -> {:refused, {:no_option, label}}
      (a = answers(row)[kind]) && a.mark != "cleared" -> {:refused, {:answered, a.mark}}
      true -> :ok
    end
  end

  @doc """
  The option an end presses on the row's dialog (F-231, `Dialog.tla`'s EndPress): the trust
  dialog's exit option, `No, exit`, while it may still be answered (`check/4`). Refused
  `{:no_exit, kind}` for a dialog with no exit option (the imports dialog goes on with imports
  off; a start's menu names none), or `check/4`'s refusal: an end then sends SIGTERM instead.

      iex> alias CodingAgentFramework.Sessions.Dialog
      iex> row = %{dialog: %{kind: :trust, options: ["No, exit", "Yes"]}, answers: nil}
      iex> Dialog.exit_option(row)
      {:ok, "No, exit"}
      iex> Dialog.exit_option(%{row | dialog: %{kind: :imports, options: ["Yes", "No"]}})
      {:refused, {:no_exit, :imports}}
  """
  @spec exit_option(map) :: {:ok, String.t()} | {:refused, term}
  def exit_option(row) do
    case shown(row) do
      %{kind: :trust, options: options} ->
        case Enum.find(options, &String.ends_with?(&1, "exit")) do
          nil ->
            {:refused, {:no_exit, :trust}}

          label ->
            with :ok <- check(row, :trust, label), do: {:ok, label}
        end

      shown ->
        {:refused, {:no_exit, shown && shown.kind}}
    end
  end

  @doc """
  The option the operator's rule presses on the row's trust dialog (F-286): the one that
  trusts the folder, `Yes, I trust this folder` on 2.1.322, while it may still be answered
  (`check/4`). Refused `{:no_trust, kind}` for another dialog or one with no such option.

      iex> alias CodingAgentFramework.Sessions.Dialog
      iex> row = %{dialog: %{kind: :trust, options: ["No, exit", "Yes, I trust this folder"]}, answers: nil}
      iex> Dialog.trust_option(row)
      {:ok, "Yes, I trust this folder"}
      iex> Dialog.trust_option(%{row | dialog: %{kind: :imports, options: ["Yes", "No"]}})
      {:refused, {:no_trust, :imports}}
  """
  @spec trust_option(map) :: {:ok, String.t()} | {:refused, term}
  def trust_option(row) do
    with %{kind: :trust, options: options} <- shown(row),
         label when is_binary(label) <- Enum.find(options, &(&1 =~ ~r/\AYes\b.*\btrust\b/)) do
      with :ok <- check(row, :trust, label), do: {:ok, label}
    else
      _ -> {:refused, {:no_trust, shown(row) && shown(row).kind}}
    end
  end

  @doc """
  The default of the app's `dialog:` callback: ask a person. Nothing answers a startup dialog
  on its own unless the app gives a callback that does, but for the trust dialog of a folder
  the operator's rule names (`trust_option/1`), which the framework presses first.

      iex> CodingAgentFramework.Sessions.Dialog.ask(:trust, ["No, exit", "Yes, I trust this folder"])
      :ask
  """
  @spec ask(kind, [String.t()]) :: :ask
  def ask(_kind, _options), do: :ask
end
