defmodule CodingAgentFramework.Sessions.Menu do
  @moduledoc """
  A numbered menu on a running interactive session's screen (F-198; `docs/design.md`,
  "Prompts"; `model/tla/Menu.tla`): what the agent row's `menu` column keeps of the menu its
  pane shows, read by `Screen` as kind `:menu`, and of the one answer to it. A pure module, so
  `Sessions`, which writes the column, and `Prompts`, which shows it as a `dialog` prompt, read
  one shape.

  The field is a map with string keys, as JSON gives it back: `start` (the row's `started_at`
  when it was read, so a later start never shows it), `at` (wall-clock ms of the read that
  found it: the prompt's key), `title`, `detail`, `options` (the labels, in order) and
  `selected` (the label the marker is on, as last read), and once answered `label` (an option's
  label, or `esc`), `by`, `act` (its row in `Acts`) and `mark`: `pressing` while its press is
  under way, then `sent` or `unknown`. A menu is one menu by its title and options, as read; a
  press is never made twice for it, and a restart makes a `pressing` one `unknown`.

      iex> alias CodingAgentFramework.Sessions.Menu
      iex> screen = %{state: :dialog, kind: :menu, title: "Pick one", detail: [],
      ...>   options: ["Yes", "No"], selected: "Yes"}
      iex> {:write, field} = Menu.seen(nil, screen, 7, 100)
      iex> {field["at"], Menu.choices(field), Menu.status(field)}
      {100, ["Yes", "No", "esc"], "open"}
      iex> Menu.seen(field, screen, 7, 200)
      :same
      iex> Menu.check(field, 100, "No")
      :ok
      iex> Menu.check(field, 99, "No")
      {:refused, :settled}
  """

  @doc "The field the row's `menu` column holds, or nil."
  @spec of(map | nil) :: map | nil
  def of(%{menu: text}) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{"at" => at} = field} when is_integer(at) -> field
      _ -> nil
    end
  end

  def of(_), do: nil

  @doc """
  What a read of the pane makes of the row's field (`Menu.tla`'s Read), for a row of start
  `start` read at `now`: `{:write, field}` for a menu that is another than the field's (by its
  title and options) or after the field's was sent, or the field's with the marker moved;
  `{:write, nil}` for a screen with no menu; `:same` when nothing changes. A field whose press
  is under way is not read: its press reads the pane itself.
  """
  @spec seen(map | nil, map, integer, integer) :: {:write, map | nil} | :same
  def seen(%{"mark" => "pressing"}, _screen, _start, _now), do: :same

  def seen(field, %{state: :dialog, kind: :menu} = screen, start, now) do
    cond do
      field == nil or field["mark"] == "sent" or not same?(field, screen) ->
        {:write, fresh(screen, start, now)}

      field["selected"] != screen.selected ->
        {:write, Map.put(field, "selected", screen.selected)}

      true ->
        :same
    end
  end

  def seen(nil, _screen, _start, _now), do: :same
  def seen(_field, _screen, _start, _now), do: {:write, nil}

  defp same?(field, screen),
    do: field["title"] == screen.title and field["options"] == screen.options

  defp fresh(screen, start, now) do
    %{
      "start" => start,
      "at" => now,
      "title" => screen.title,
      "detail" => Map.get(screen, :detail, []),
      "options" => screen.options,
      "selected" => screen.selected
    }
  end

  @doc "What an answer may be: one of the options' labels, or `esc` (Escape)."
  @spec choices(map) :: [String.t()]
  def choices(field), do: field["options"] ++ ["esc"]

  @doc """
  Whether `choice` may answer the menu read at `at` now: the field is that read's, unmarked,
  and the choice one it offers. Refusals: `:settled` (no menu now, or another), `{:answered,
  mark}`, `{:no_option, choice}`.
  """
  @spec check(map | nil, integer, term) :: :ok | {:refused, term}
  def check(field, at, choice) do
    cond do
      field == nil or field["at"] != at -> {:refused, :settled}
      field["mark"] != nil -> {:refused, {:answered, field["mark"]}}
      choice not in choices(field) -> {:refused, {:no_option, choice}}
      true -> :ok
    end
  end

  @doc "The field with its answer marked `mark`, with `fields` (`label`, `by`, `act`)."
  @spec mark(map, String.t() | nil, map) :: map
  def mark(field, nil, _fields), do: Map.drop(field, ~w(mark label by act))
  def mark(field, mark, fields), do: field |> Map.merge(fields) |> Map.put("mark", mark)

  @doc """
  The field a restart finds (`Menu.tla`'s Recover): a press marked `pressing` may have gone,
  so it is `unknown`, never pressed again. Nil when nothing changes.

      iex> CodingAgentFramework.Sessions.Menu.after_restart(%{"at" => 1, "mark" => "pressing"})
      %{"at" => 1, "mark" => "unknown"}
  """
  @spec after_restart(map | nil) :: map | nil
  def after_restart(%{"mark" => "pressing"} = field), do: %{field | "mark" => "unknown"}
  def after_restart(_), do: nil

  @doc """
  The prompt's status for the field: `open` while no answer is marked, `answering` while its
  press is under way, `unknown` when its outcome is not known (a person answers it at the
  viewer), and nil once it was sent.
  """
  @spec status(map) :: String.t() | nil
  def status(%{"mark" => "pressing"}), do: "answering"
  def status(%{"mark" => "unknown"}), do: "unknown"
  def status(%{"mark" => "sent"}), do: nil
  def status(_), do: "open"

  @doc "The text a person reads for the menu: its title and the lines under it."
  @spec text(map) :: String.t()
  def text(field), do: Enum.join([field["title"] | field["detail"] || []], " ")
end
