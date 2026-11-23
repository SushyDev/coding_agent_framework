defmodule CodingAgentFramework.Screen do
  @moduledoc ~S"""
  Reads one captured screen of an interactive Claude Code session for a named release.

  A capture is what `tmux capture-pane -p` prints for the pane, with or without `-e` (the
  escapes are dropped before reading, after the input box's line drops its runs drawn dim;
  `Tmux.capture/3` captures with them). `read/2` places it in one state, by what the release
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
    * `%{state: :idle, box: {:text, text}}`: text typed in the box and not sent. A prompt
      suggestion is not typed text: Claude Code draws it dim (`ESC[2m` up to the reset), and a
      run drawn dim on the box's line is dropped, so a box holding only a suggestion is
      `:empty`. Only a capture with escapes (`capture-pane -e`) shows it; without them a
      suggestion reads as text. Only the screen sees a suggestion: what a person typed and sent
      reaches the framework from `UserPromptSubmit` (F-194), never from here;
    * `%{state: :running}`: a turn runs. Only the footer under the box says so; a spinner line
      alone does not, and an ended turn's `… · done` line stays above the box;
    * `%{state: :usage_limit_wait, at: time}`: Claude Code's own wait at a usage limit, `at` the
      time its notice under the box names as drawn ("Continuing automatically at <time> · Esc to
      cancel"). The box is drawn empty under it, as at an ended turn, but the wait is no ended
      turn: a text typed into it would start a turn into the limit (F-181's new-3);
    * `%{state: :dialog, kind: kind, options: [label], selected: label}`: a dialog, its
      options' labels in order and the one the `❯` marks. Answer it by label (`option_keys/2`).
      Its kinds: `:trust` (the folder trust dialog), `:imports` (external `CLAUDE.md` imports,
      with `paths:`, the external paths it lists, and `shortened:`, those of them drawn
      shortened: a path wider than the pane is cut in its middle with `…` on one line, never
      wrapped, so it reads as one path that is not whole), `:permission` and `:usage_limit_menu`
      (the menu at a usage limit, in place of the input box; its options are read by label,
      since the third is what the account allows, F-181's new-4). The two a start meets first,
      `:trust` and `:imports`, send no hook event;
    * `%{state: :dialog, kind: :menu, title: title, detail: [line], options: [label], selected:
      label}`: any other numbered menu (F-198), read by its shape where no kind names it: under
      a rule, its title (its first line), the lines under it (`detail`), two or more numbered
      options in a row, numbered from 1 at one indent with the `❯` on one, and the footer
      "Enter to confirm · Esc to cancel", drawn in place of the box or above it. Only with that
      footer is it a menu, so a numbered list in the agent's own output never reads as one;
    * `%{state: :exited}`: Claude Code has exited.

  A screen the release's reading cannot place, or places only by a guess, is unrecognized: a
  box of more than one line while no turn runs, a dialog of an unknown kind, options with no
  one selected or a label twice. This module starts no process and reads no file.

  Nothing it reads depends on the pane's width: a rule is a line of `─` alone, however long, and
  the rule above the box may carry the session's name (`──── name ─`, a session started with
  `--name`). A person who attaches to a viewer redraws it at their own width, so the same
  session is read at 80 columns and at 400 (F-153's new-2).
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
              optional(:title) => String.t(),
              optional(:detail) => [String.t()],
              optional(:paths) => [String.t()],
              optional(:shortened) => [String.t()]
            }
          | %{state: :usage_limit_wait, at: String.t()}
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
         {lines, typed} = lines(capture),
         {:ok, screen} <- place(lines, typed, reading) do
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

  # Each line with its escapes dropped, and each as typed: with the runs drawn dim dropped too,
  # for the input line (a prompt suggestion is drawn dim). Trailing spaces say nothing, and a
  # capture with escapes keeps some that one without drops.
  defp lines(capture) do
    raw = String.split(capture, "\n")
    lines = raw |> Enum.map(&plain/1) |> drop_trailing_blanks()
    {lines, raw |> Enum.take(length(lines)) |> Enum.map(&(&1 |> undim() |> plain()))}
  end

  @escape ~r{\e\[[0-?]*[ -/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)}

  defp plain(line), do: line |> String.replace(@escape, "") |> String.trim_trailing(" ")

  # The line with every run drawn dim (SGR 2, up to a reset, SGR 0 or 22) dropped; its other
  # escapes stay, for `plain/1`.
  defp undim(line) do
    ~r/\e\[([0-9;]*)m/
    |> Regex.split(line, include_captures: true)
    |> Enum.reduce({[], false}, fn part, {kept, dim} ->
      case Regex.run(~r/\A\e\[([0-9;]*)m\z/, part) do
        [_, params] -> {kept, dim(String.split(params, ";"), dim)}
        nil -> {if(dim, do: kept, else: [part | kept]), dim}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  # An SGR's parameters in order; a color's own (38, 48 or 58, then 5;n or 2;r;g;b) are no dim.
  defp dim([], dim), do: dim
  defp dim([p | rest], _dim) when p in ["", "0", "22"], do: dim(rest, false)
  defp dim(["2" | rest], _dim), do: dim(rest, true)
  defp dim([c, "5", _ | rest], dim) when c in ["38", "48", "58"], do: dim(rest, dim)
  defp dim([c, "2", _, _, _ | rest], dim) when c in ["38", "48", "58"], do: dim(rest, dim)
  defp dim([_ | rest], dim), do: dim(rest, dim)

  # A dialog drawn in place of the box comes first, then a menu no rule names, which may be
  # drawn above the box, then the box.
  defp place(lines, typed, reading) do
    with :error <- exited(lines, reading),
         :error <- dialog(lines, reading),
         :none <- menu(lines, reading) do
      boxed(lines, typed, reading)
    end
  end

  defp boxed(lines, typed, reading) do
    case split_at_last_rule(lines) do
      {:ok, above, below} -> box(above, below, typed, reading)
      :error -> :error
    end
  end

  defp exited(lines, %{exited: exited, resume: resume}) do
    case Enum.take(lines, -2) do
      [^exited, command] -> if String.starts_with?(command, resume), do: {:ok, %{state: :exited}}
      _ -> nil
    end || :error
  end

  # The box sits between two rules; its footer, under the lower one, is the last thing drawn.
  # The upper rule carries the session's name when it has one (`--name`).
  defp box(above, footer, typed, reading) do
    with {:ok, before, [first | _] = inside} <- split_at_last_rule(above, &upper?(&1, reading)),
         true <- first == reading.prompt or String.starts_with?(first, reading.box) do
      # The box's line as typed: a prompt suggestion, drawn dim, is not in it.
      first = Enum.at(typed, length(before) + 1, first)

      wait =
        Enum.find_value(
          footer,
          &Regex.run(reading.wait, String.trim(&1), capture: :all_but_first)
        )

      cond do
        wait -> {:ok, %{state: :usage_limit_wait, at: hd(wait)}}
        Enum.any?(footer, &String.contains?(&1, reading.running)) -> {:ok, %{state: :running}}
        length(inside) == 1 -> {:ok, %{state: :idle, box: box_text(first, reading)}}
        true -> :error
      end
    else
      _ -> :error
    end
  end

  defp upper?(line, reading), do: rule?(line) or Regex.match?(reading.named_rule, line)

  defp box_text(line, %{prompt: line}), do: :empty

  defp box_text(line, reading) do
    case String.replace_prefix(line, reading.box, "") do
      "" -> :empty
      text -> if Regex.match?(reading.placeholder, text), do: :empty, else: {:text, text}
    end
  end

  # A dialog is drawn under its rule, with its footer last and its options just above it. A
  # kind names its rule's character when it is not `─` (the usage limit's menu, `▔`).
  defp dialog(lines, reading) do
    Enum.find_value(reading.dialogs, :error, fn kind ->
      with {:ok, _, region} <- split_at_last_rule(lines, &rule?(&1, Map.get(kind, :rule, "─"))) do
        footer = region |> List.last("") |> String.trim_leading()
        String.starts_with?(footer, kind.footer) && options(Enum.drop(region, -1), kind)
      else
        :error -> nil
      end
    end)
  end

  # A menu no rule names (F-198): under a rule, its title, any lines under it, two or more
  # numbered options in a row at one indent, one marked, then the release's menu footer, with
  # nothing but blank lines under it before the box's upper rule or the screen's end. The footer
  # makes it a menu, so a numbered list in the agent's own output is never one; with the footer
  # and anything else in that shape, the screen is unrecognized.
  defp menu(lines, %{menu: %{footers: footers}} = reading) do
    top = box_top(lines, reading)

    at =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _} -> footer?(line, footers) end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&closed?(lines, &1, top, reading))
      |> List.last()

    with at when is_integer(at) <- at || :none,
         {:ok, _, region} <- split_at_last_rule(Enum.take(lines, at)) do
      menu_options(region)
    else
      :none -> :none
      :error -> :none
    end
  end

  defp footer?(line, footers),
    do: Enum.any?(footers, &String.starts_with?(String.trim_leading(line), &1))

  # Under a menu's footer: blank lines, then the box's own upper rule or the screen's end, or the
  # box's named rule as the screen's last line: a dialog drawn in the box's place, with no box
  # under it (F-228's capture of "Allow this read outside the working directories?"). A rule the
  # agent's output prints (a capture of a menu, say) is not the box's.
  defp closed?(lines, at, top, reading) do
    case lines
         |> Enum.with_index()
         |> Enum.drop(at + 1)
         |> Enum.drop_while(&(elem(&1, 0) == "")) do
      [] -> true
      [{line, i}] -> i == top or Regex.match?(reading.named_rule, line)
      [{_, i} | _] -> i == top
    end
  end

  # The index of the box's upper rule: above the last rule, the last rule or named rule.
  defp box_top(lines, reading) do
    with {:ok, above, _} <- split_at_last_rule(lines),
         {:ok, before, _} <- split_at_last_rule(above, &upper?(&1, reading)) do
      length(before)
    else
      :error -> nil
    end
  end

  @option ~r/\A( *)([❯ ]) (\d+)\. (\S.*)\z/u

  defp menu_options(region) do
    body = region |> Enum.drop_while(&(&1 == "")) |> drop_trailing_blanks()
    numbered = for {line, i} <- Enum.with_index(body), m = Regex.run(@option, line), do: {i, m}

    with [{first, _} | _] when first > 0 <- numbered,
         [title | detail] = Enum.take(body, first),
         indices = Enum.map(numbered, &elem(&1, 0)),
         true <- indices == Enum.to_list(first..(length(body) - 1)//1),
         true <- length(numbered) >= 2,
         parsed =
           Enum.map(numbered, fn {_, [_, pad, mark, n, label]} -> {pad, mark, n, label} end),
         true <- parsed |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 1,
         true <- Enum.map(parsed, &elem(&1, 2)) == Enum.map(1..length(parsed), &to_string/1),
         labels = Enum.map(parsed, &elem(&1, 3)),
         true <- Enum.uniq(labels) == labels,
         [selected] <- for({_, "❯", _, label} <- parsed, do: label) do
      {:ok,
       %{
         state: :dialog,
         kind: :menu,
         title: String.trim(title),
         # A dialog's inner rules of `╌` (around the tool and its input) are no text of it.
         detail: for(line <- detail, line != "", not rule?(line, "╌"), do: String.trim(line)),
         options: labels,
         selected: selected
       }}
    else
      _ -> :error
    end
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
  # fixture shows. A path drawn with the release's ellipsis was shortened to fit the pane.
  defp paths(body, %{paths: heading} = kind) do
    with [line | after_it] <- Enum.drop_while(body, &(String.trim(&1) != heading)),
         depth = indent(line),
         listed = Enum.take_while(after_it, &(&1 != "")),
         true <- listed != [] and Enum.all?(listed, &(indent(&1) > depth)) do
      paths = Enum.map(listed, &String.trim/1)
      {:ok, %{paths: paths, shortened: Enum.filter(paths, &String.contains?(&1, kind.shortened))}}
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

  defp split_at_last_rule(lines, rule? \\ &rule?/1) do
    case lines |> Enum.reverse() |> Enum.find_index(rule?) do
      nil ->
        :error

      after_it ->
        {:ok, Enum.take(lines, length(lines) - after_it - 1), Enum.take(lines, -after_it)}
    end
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line, " "))

  defp rule?(line, char \\ "─"), do: line != "" and String.trim(line, char) == ""

  defp drop_trailing_blanks(lines),
    do: lines |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
end
