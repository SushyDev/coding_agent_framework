defmodule CodingAgentFramework.Intake.Background do
  @moduledoc """
  The framework's own `PreToolUse` correction for background commands (`docs/design.md`,
  "Intercepted, not added"; F-180), always on.

  Claude Code gives a `Bash` command run with `run_in_background: true` a stdin that is an open
  socket and never closes (a foreground command gets `/dev/null`), so a program that reads stdin
  (`cat` with no file, `python3 -`, a listing program that reads a pipe) waits on it for ever,
  and a delegate's report waits with it. So every such call runs as

      exec </dev/null; <command>

  and every program in it reads end of file at once. A command that redirects stdin keeps its
  own: a `<`, a here-doc or a pipe gives that program its stdin after the `exec`, and the
  programs after it still read end of file. A command that already starts with `exec
  </dev/null;` is left as it is.

  `pre_tool_use/1` wraps the next callback (the heavy commands' rewrite and the app's own): it
  answers first, on the call as the agent made it, so its patterns match what the agent wrote,
  and the correction applies to the input its answer lets run. A pass becomes `{:pass,
  updated_input: …}`, which leaves the decision to Claude Code's own permission rules; an allow
  keeps its decision and context; an ask stays an ask, its prompt showing the corrected command
  (measured on 2.1.322, F-182), so a person's approval runs it with its stdin closed; a deny is
  the app's, unchanged. A line of context says why the command changed.
  """

  @prefix "exec </dev/null; "
  @closed ~r/\A\s*exec\s*<\s*\/dev\/null\s*;/
  @context "The framework put `exec </dev/null;` before this background command: Claude Code " <>
             "gives a background command a stdin that never closes, so a program that reads " <>
             "stdin would wait for ever. A `<` redirect, a here-doc or a pipe still gives a " <>
             "program its own stdin."
  # Claude Code 2.1.322 reads a hook's `additionalContext` up to this many characters.
  @context_max 10_000

  @doc """
  The correction around `then` (the next callback, or nil for none). A callback that raises is
  taken as `:pass`, as `Intake` takes it.

      iex> pre = CodingAgentFramework.Intake.Background.pre_tool_use(nil)
      iex> {:pass, opts} = pre.(%{tool_name: "Bash",
      ...>   tool_input: %{"command" => "make it", "run_in_background" => true}})
      iex> opts[:updated_input]["command"]
      "exec </dev/null; make it"
      iex> pre.(%{tool_name: "Bash", tool_input: %{"command" => "make it"}})
      :pass
  """
  @spec pre_tool_use((map -> term) | nil) :: (map -> term)
  def pre_tool_use(then) do
    fn event ->
      answer =
        try do
          if then, do: then.(event), else: :pass
        rescue
          _ -> :pass
        end

      correct(event, answer)
    end
  end

  @doc """
  `answer` with the correction applied to the input it lets `event`'s call run with, or
  `answer` as it is when it does not let a background `Bash` command run.

      iex> alias CodingAgentFramework.Intake.Background
      iex> event = %{tool_name: "Bash", tool_input: %{"command" => "ls", "run_in_background" => true}}
      iex> Background.correct(event, {:deny, "no"})
      {:deny, "no"}
      iex> {:ask, asked} = Background.correct(event, :ask)
      iex> asked[:updated_input]["command"]
      "exec </dev/null; ls"
      iex> {:allow, opts} = Background.correct(event, :allow)
      iex> opts[:updated_input]
      %{"command" => "exec </dev/null; ls", "run_in_background" => true}
      iex> closed = %{event | tool_input: %{"command" => "exec </dev/null; ls", "run_in_background" => true}}
      iex> Background.correct(closed, :pass)
      :pass
  """
  @spec correct(map, term) :: term
  def correct(event, answer) do
    with {:ok, decision, opts} <- lets_run(answer),
         input = Keyword.get(opts, :updated_input, event[:tool_input]),
         true <- event[:tool_name] == "Bash" and background?(input),
         %{"command" => command} when is_binary(command) <- input,
         false <- String.trim(command) == "" or Regex.match?(@closed, command) do
      input = Map.put(input, "command", @prefix <> command)
      {decision, opts |> Keyword.put(:updated_input, input) |> context()}
    else
      _ -> answer
    end
  end

  # The decision an answer that lets the call run keeps, and its options.
  defp lets_run(answer) when answer in [:pass, :allow, :ask], do: {:ok, answer, []}

  defp lets_run({decision, opts}) when decision in [:pass, :allow, :ask] and is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, decision, opts}, else: :no
  end

  defp lets_run(_answer), do: :no

  defp background?(%{"run_in_background" => true}), do: true
  defp background?(_input), do: false

  # The app's context first; the line is left out where both would pass Claude Code's limit.
  defp context(opts) do
    case Keyword.get(opts, :additional_context) do
      nil ->
        Keyword.put(opts, :additional_context, @context)

      text when is_binary(text) ->
        both = text <> "\n" <> @context

        if String.length(both) <= @context_max,
          do: Keyword.put(opts, :additional_context, both),
          else: opts

      _ ->
        opts
    end
  end
end
