defmodule CodingAgentFramework.Screen do
  @moduledoc ~S"""
  Reads one captured screen of an interactive Claude Code session for a named release.

  A capture is what `tmux capture-pane -p` prints for the pane, with or without `-e` (the
  escapes are dropped before reading). `read/2` places it in one state, by what the release
  draws at the bottom of the screen (`CodingAgentFramework.Screen.Reading`):

      iex> rule = String.duplicate("─", 20)
      iex> CodingAgentFramework.Screen.read("#{rule}\n❯\u00a0hello\n#{rule}\n", "2.1.322")
      {:ok, %{state: :idle, box: {:text, "hello"}}}
      iex> CodingAgentFramework.Screen.read("Welcome\n", "2.1.322")
      {:unknown, {:unrecognized, "2.1.322"}}
      iex> CodingAgentFramework.Screen.read("Welcome\n", "0.0.1")
      {:refused, {:unknown_release, "0.0.1"}}

  The states:

    * `%{state: :idle, box: :empty}`: the turn has ended and the input box is empty;
    * `%{state: :idle, box: {:text, text}}`: text typed in the box and not sent;
    * `%{state: :running}`: a turn runs. Only the footer under the box says so; a spinner line
      alone does not, and an ended turn's `… · done` line stays above the box;
    * `%{state: :dialog, kind: kind, options: [label], selected: label}`: a dialog, its
      options' labels in order and the one the `❯` marks. Answer it by label (`option_keys/2`).
      Its kinds: `:trust` (the folder trust dialog), `:imports` (external `CLAUDE.md` imports,
      with `paths:`, the external paths it lists) and `:permission`. The two a start meets
      first, `:trust` and `:imports`, send no hook event;
    * `%{state: :exited}`: Claude Code has exited.

  A screen the release's reading cannot place, or places only by a guess, is unrecognized: a
  box of more than one line while no turn runs, a dialog of an unknown kind, options with no
  one selected or a label twice. This module starts no process and reads no file.
  """

  alias CodingAgentFramework.Screen.Reading

  @type box :: :empty | {:text, String.t()}
  @type t ::
          %{state: :idle, box: box}
          | %{state: :running}
          | %{
              required(:state) => :dialog,
              required(:kind) => atom,
              required(:options) => [String.t()],
              required(:selected) => String.t(),
              optional(:paths) => [String.t()]
            }
          | %{state: :exited}

  @doc """
  Places `capture` in one state, read as Claude Code `release` draws it.

  Answers `{:ok, screen}`, `{:unknown, {:unrecognized, release}}` for a screen it cannot place,
  or `{:refused, {:unknown_release, release}}` for a release with no reading.
  """
  @spec read(String.t(), String.t()) ::
          {:ok, t}
          | {:unknown, {:unrecognized, String.t()}}
          | {:refused, {:unknown_release, term}}
  def read(capture, release) when is_binary(capture) do
    with {:ok, reading} <- reading(release),
         {:ok, screen} <- place(lines(capture), reading) do
      {:ok, screen}
    else
      :no_reading -> {:refused, {:unknown_release, release}}
      :error -> {:unknown, {:unrecognized, release}}
    end
  end

  @doc """
  The keys that move a dialog's selection from its selected option to the one labeled `label`:
  a list of `"Down"` or of `"Up"`, empty when that option is already selected.

      iex> screen = %{state: :dialog, kind: :trust, options: ["No", "Yes"], selected: "No"}
      iex> CodingAgentFramework.Screen.option_keys(screen, "Yes")
      {:ok, ["Down"]}
      iex> CodingAgentFramework.Screen.option_keys(screen, "Maybe")
      {:refused, {:no_option, "Maybe"}}
  """
  @spec option_keys(t, String.t()) ::
          {:ok, [String.t()]} | {:refused, {:no_option, String.t()} | :no_dialog}
  def option_keys(%{state: :dialog, options: options, selected: selected}, label) do
    case {Enum.find_index(options, &(&1 == label)), Enum.find_index(options, &(&1 == selected))} do
      {nil, _} -> {:refused, {:no_option, label}}
      {_, nil} -> {:refused, {:no_option, selected}}
      {to, from} when to >= from -> {:ok, List.duplicate("Down", to - from)}
      {to, from} -> {:ok, List.duplicate("Up", from - to)}
    end
  end

  def option_keys(_screen, _label), do: {:refused, :no_dialog}

  defp reading(release) when is_binary(release) do
    # Only a version string reaches Module.concat, so the atoms it makes stay few.
    with true <- Regex.match?(~r/\A\d{1,4}\.\d{1,4}\.\d{1,4}\z/, release),
         module = Module.concat(Reading, "V" <> String.replace(release, ".", "_")),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :reading, 0) do
      {:ok, module.reading()}
    else
      false -> :no_reading
    end
  end

  defp reading(_release), do: :no_reading

  # Trailing spaces say nothing, and a capture with escapes keeps some that one without drops.
  defp lines(capture) do
    capture
    |> String.replace(~r{\e\[[0-?]*[ -/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)}, "")
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, " "))
    |> drop_trailing_blanks()
  end

  defp place(lines, reading) do
    with :error <- exited(lines, reading),
         {:ok, above, below} <- split_at_last_rule(lines),
         :error <- box(above, below, reading) do
      dialog(below, reading)
    end
  end

  defp exited(lines, %{exited: exited, resume: resume}) do
    case Enum.take(lines, -2) do
      [^exited, command] -> if String.starts_with?(command, resume), do: {:ok, %{state: :exited}}
      _ -> nil
    end || :error
  end

  # The box sits between two rules; its footer, under the lower one, is the last thing drawn.
  defp box(above, footer, reading) do
    with {:ok, _, [first | _] = inside} <- split_at_last_rule(above),
         true <- first == reading.prompt or String.starts_with?(first, reading.box) do
      cond do
        Enum.any?(footer, &String.contains?(&1, reading.running)) -> {:ok, %{state: :running}}
        length(inside) == 1 -> {:ok, %{state: :idle, box: box_text(first, reading)}}
        true -> :error
      end
    else
      _ -> :error
    end
  end

  defp box_text(line, %{prompt: line}), do: :empty

  defp box_text(line, reading) do
    case String.replace_prefix(line, reading.box, "") do
      "" -> :empty
      text -> if Regex.match?(reading.placeholder, text), do: :empty, else: {:text, text}
    end
  end

  # A dialog is drawn under its rule, with its footer last and its options just above it.
  defp dialog(region, reading) do
    footer = region |> List.last("") |> String.trim_leading()

    Enum.find_value(reading.dialogs, :error, fn kind ->
      String.starts_with?(footer, kind.footer) && options(Enum.drop(region, -1), kind)
    end)
  end

  defp options(body, kind) do
    pad = String.duplicate(" ", kind.indent)

    {run, rest} =
      body |> drop_trailing_blanks() |> Enum.reverse() |> Enum.split_while(&option?(&1, pad))

    titled = Enum.any?(rest, &(String.trim(&1) == kind.title))
    # A line just above the options that is neither blank nor the title may be a wrapped option.
    bounded = String.trim(List.first(rest, "")) in ["", kind.title]
    parsed = run |> Enum.reverse() |> Enum.map(&parse_option(&1, pad))
    labels = Enum.map(parsed, &label(&1, kind))

    with true <- titled and bounded and run != [],
         [selected] <- parsed |> Enum.filter(&elem(&1, 0)) |> Enum.map(&label(&1, kind)),
         true <- Enum.all?(labels, &is_binary/1) and Enum.uniq(labels) == labels,
         true <- not kind.numbered or numbered_in_order?(parsed),
         {:ok, extra} <- paths(Enum.reverse(rest), kind) do
      {:ok,
       Map.merge(%{state: :dialog, kind: kind.kind, options: labels, selected: selected}, extra)}
    else
      _ -> nil
    end
  end

  # The paths a dialog lists under its heading, one a line, more indented than the heading,
  # up to the first blank line. A heading with no path under it is not the dialog the
  # fixture shows.
  defp paths(body, %{paths: heading}) do
    with [line | after_it] <- Enum.drop_while(body, &(String.trim(&1) != heading)),
         depth = indent(line),
         listed = Enum.take_while(after_it, &(&1 != "")),
         true <- listed != [] and Enum.all?(listed, &(indent(&1) > depth)) do
      {:ok, %{paths: Enum.map(listed, &String.trim/1)}}
    else
      _ -> :error
    end
  end

  defp paths(_body, _kind), do: {:ok, %{}}

  defp option?(line, pad) do
    case String.split_at(line, String.length(pad)) do
      {^pad, rest} -> Regex.match?(~r/\A[❯ ] \S/u, rest)
      _ -> false
    end
  end

  defp parse_option(line, pad) do
    case String.replace_prefix(line, pad, "") do
      "❯ " <> text -> {true, text}
      "  " <> text -> {false, text}
    end
  end

  defp label({_, text}, %{numbered: false}), do: text

  defp label({_, text}, %{numbered: true}) do
    case Regex.run(~r/\A\d+\. (.+)\z/u, text) do
      [_, label] -> label
      nil -> nil
    end
  end

  defp numbered_in_order?(parsed) do
    parsed
    |> Enum.with_index(1)
    |> Enum.all?(fn {{_, text}, n} -> String.starts_with?(text, "#{n}. ") end)
  end

  defp split_at_last_rule(lines) do
    case lines |> Enum.reverse() |> Enum.find_index(&rule?/1) do
      nil ->
        :error

      after_it ->
        {:ok, Enum.take(lines, length(lines) - after_it - 1), Enum.take(lines, -after_it)}
    end
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line, " "))

  defp rule?(line), do: line != "" and String.trim(line, "─") == ""

  defp drop_trailing_blanks(lines),
    do: lines |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
end
