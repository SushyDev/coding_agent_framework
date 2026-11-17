defmodule CodingAgentFramework.Sessions.Dialog do
  @moduledoc """
  A startup dialog on an agent row (F-140, `model/tla/Dialog.tla`): what the row keeps of the
  dialog an interactive start's pane shows, and of each answer to one.

  Claude Code shows the folder trust dialog (`:trust`) and the external `CLAUDE.md` imports
  dialog (`:imports`) before a session's first turn, with no hook event and no session file.
  `Sessions` reads the pane while its start has no session file, and the row says `dialog`
  until the start goes on. Its `dialog` column is the dialog shown (`shown/1`), and its
  `answers` column each kind's answer, marked `pressing` before its press goes, then `sent` or
  `unknown` (`answers/1`). An answer whose mark is `pressing` when `Sessions` restarts is
  `unknown`: its press may have gone. A kind with any mark is never pressed again.

      iex> alias CodingAgentFramework.Sessions.Dialog
      iex> screen = %{state: :dialog, kind: :trust, options: ["No, exit", "Yes"], selected: "No, exit"}
      iex> row = %{dialog: Dialog.encode(screen), answers: nil}
      iex> Dialog.shown(row)
      %{kind: :trust, options: ["No, exit", "Yes"], selected: "No, exit", paths: []}
      iex> Dialog.check(row, :trust, "Yes")
      :ok
      iex> Dialog.check(%{row | answers: ~s({"trust":{"label":"Yes","mark":"sent"}})}, :trust, "Yes")
      {:refused, {:answered, "sent"}}
  """

  @kinds [:trust, :imports]

  @typedoc "A startup dialog's kind."
  @type kind :: :trust | :imports

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

  @doc "Whether a `Screen` reading is a startup dialog."
  @spec startup?(map) :: boolean
  def startup?(%{state: :dialog, kind: kind}) when kind in @kinds, do: true
  def startup?(_), do: false

  @doc "The row's `dialog` column for a startup dialog `Screen` read."
  @spec encode(map) :: map
  def encode(%{state: :dialog, kind: kind} = screen) do
    %{kind: kind, options: screen.options, selected: screen.selected}
    |> Map.put(:paths, Map.get(screen, :paths, []))
  end

  @doc "The dialog the row shows, or showed last: `%{kind, options, selected, paths}`, or nil."
  @spec shown(map | nil) :: map | nil
  def shown(%{dialog: text}) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{"kind" => name, "options" => options, "selected" => selected} = d} ->
        if kind = kind(name),
          do: %{kind: kind, options: options, selected: selected, paths: d["paths"] || []}

      _ ->
        nil
    end
  end

  def shown(%{dialog: %{kind: _} = dialog}), do: dialog
  def shown(_), do: nil

  @doc "Each kind's answer on the row: `%{kind => %{label: label, mark: mark}}`."
  @spec answers(map | nil) :: %{kind => %{label: String.t(), mark: String.t()}}
  def answers(%{answers: text}) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = all} ->
        for {name, %{"label" => label, "mark" => mark}} <- all, kind = kind(name), into: %{} do
          {kind, %{label: label, mark: mark}}
        end

      _ ->
        %{}
    end
  end

  def answers(_), do: %{}

  @doc """
  The row's answers with `kind`'s marked `mark` (nil removes it), as the column stores them.
  """
  @spec mark(map, kind, String.t(), String.t() | nil) :: map
  def mark(row, kind, _label, nil), do: Map.delete(answers(row), kind)
  def mark(row, kind, label, mark), do: Map.put(answers(row), kind, %{label: label, mark: mark})

  @doc """
  The answers a restart finds: a press marked `pressing` may have gone, so it is `unknown`.
  Answers nil when nothing changes.
  """
  @spec after_restart(map) :: map | nil
  def after_restart(row) do
    all = answers(row)

    if Enum.any?(all, fn {_, a} -> a.mark == "pressing" end) do
      Map.new(all, fn
        {k, %{mark: "pressing"} = a} -> {k, %{a | mark: "unknown"}}
        pair -> pair
      end)
    end
  end

  @doc """
  Whether `label` may answer `kind` on this row now: the row shows that dialog, with that
  option, and no answer to it has been marked. Refusals: `{:shown, kind | nil}` (another
  dialog, or none), `{:no_option, label}`, `{:answered, mark}`.
  """
  @spec check(map, kind, String.t()) :: :ok | {:refused, term}
  def check(row, kind, label) do
    shown = shown(row)

    cond do
      shown == nil or shown.kind != kind -> {:refused, {:shown, shown && shown.kind}}
      label not in shown.options -> {:refused, {:no_option, label}}
      a = answers(row)[kind] -> {:refused, {:answered, a.mark}}
      true -> :ok
    end
  end

  @doc """
  The default of the app's `dialog:` callback: ask a person. Nothing answers a startup dialog
  on its own unless the app gives a callback that does.

      iex> CodingAgentFramework.Sessions.Dialog.ask(:trust, ["No, exit", "Yes, I trust this folder"])
      :ask
  """
  @spec ask(kind, [String.t()]) :: :ask
  def ask(_kind, _options), do: :ask
end
