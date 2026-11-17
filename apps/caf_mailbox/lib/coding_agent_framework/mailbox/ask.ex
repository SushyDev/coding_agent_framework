defmodule CodingAgentFramework.Mailbox.Ask do
  @moduledoc """
  The shape of an ask and of its answer (`docs/design.md`, "Agents working together", `ask`;
  `model/tla/Team.tla`'s `Ask` and `Answers`): a pure module `Mailbox` checks both with.

  An ask is one to four questions. Each has a `header` (a short tag), the `question`'s text,
  two to four `options` (a `label` and a `description` each, the labels distinct) and a
  `multiSelect` flag, so an app can show it as a dialog. It is stored as JSON in the row's text.

  An answer is one entry per question, in order: the `labels` the person chose (at most one
  when the question is not multi-select, each one of the question's) and the person's own
  `text`, at least one of the two. It goes to the asking agent as one line per question.

      iex> alias CodingAgentFramework.Mailbox.Ask
      iex> q = %{"header" => "Base", "question" => "Rebase or merge?", "multiSelect" => false,
      ...>   "options" => [%{"label" => "Rebase", "description" => "linear"},
      ...>                 %{"label" => "Merge", "description" => "keeps the merge"}]}
      iex> {:ok, [q]} = Ask.questions([q])
      iex> {:ok, [a]} = Ask.answers([q], [%{"labels" => ["Rebase"], "text" => ""}])
      iex> Ask.text(7, [q], [a])
      "Ask 7, Base: Rebase"
  """

  @type question :: %{String.t() => term}
  @type answer :: %{String.t() => term}

  @doc """
  Checks `questions` (string or atom keys) and answers them in the stored form, string keys
  only: `{:ok, questions}`, or `{:refused, {:bad, :questions}}`.
  """
  @spec questions(term) :: {:ok, [question]} | {:refused, {:bad, :questions}}
  def questions(questions) when is_list(questions) and length(questions) in 1..4 do
    checked = Enum.map(questions, &question/1)

    if Enum.all?(checked, &is_map/1),
      do: {:ok, checked},
      else: {:refused, {:bad, :questions}}
  end

  def questions(_), do: {:refused, {:bad, :questions}}

  defp question(q) when is_map(q) do
    header = get(q, "header")
    text = get(q, "question")
    multi = get(q, "multiSelect")
    options = get(q, "options")

    with true <- text?(header) and text?(text) and multi in [true, false, nil],
         true <- is_list(options) and length(options) in 2..4,
         options = Enum.map(options, &option/1),
         true <- Enum.all?(options, &is_map/1),
         labels = Enum.map(options, & &1["label"]),
         true <- Enum.uniq(labels) == labels do
      %{"header" => header, "question" => text, "options" => options, "multiSelect" => !!multi}
    else
      _ -> nil
    end
  end

  defp question(_), do: nil

  defp option(o) when is_map(o) do
    label = get(o, "label")
    description = get(o, "description")
    if text?(label) and text?(description), do: %{"label" => label, "description" => description}
  end

  defp option(_), do: nil

  @doc """
  Checks `answers` against the stored `questions`: one per question, in order, each `labels`
  (a list of the question's labels, at most one unless it is multi-select) and `text` (a
  string or nil), not both empty. Answers `{:ok, answers}` in the stored form, or `{:refused,
  {:bad, :answers}}`.
  """
  @spec answers([question], term) :: {:ok, [answer]} | {:refused, {:bad, :answers}}
  def answers(questions, answers)
      when is_list(answers) and length(answers) == length(questions) do
    checked = Enum.zip_with(questions, answers, &answer/2)

    if Enum.all?(checked, &is_map/1),
      do: {:ok, checked},
      else: {:refused, {:bad, :answers}}
  end

  def answers(_questions, _answers), do: {:refused, {:bad, :answers}}

  defp answer(q, a) when is_map(a) do
    labels = get(a, "labels") || []
    text = get(a, "text") || ""
    known = Enum.map(q["options"], & &1["label"])

    with true <- is_list(labels) and is_binary(text),
         true <- Enum.all?(labels, &(&1 in known)) and Enum.uniq(labels) == labels,
         true <- q["multiSelect"] or length(labels) <= 1,
         true <- labels != [] or String.trim(text) != "" do
      %{"labels" => labels, "text" => text}
    else
      _ -> nil
    end
  end

  defp answer(_q, _a), do: nil

  @doc """
  The answer as the asking agent reads it: one line per question, naming ask `id`, the
  question's header, the labels chosen and the person's own text on the same line.

      iex> q = %{"header" => "Tests", "options" => [], "multiSelect" => true}
      iex> CodingAgentFramework.Mailbox.Ask.text(3, [q], [%{"labels" => [], "text" => "Run\\nall."}])
      "Ask 3, Tests: the person wrote: Run all."
  """
  @spec text(integer, [question], [answer]) :: String.t()
  def text(id, questions, answers) do
    Enum.zip_with(questions, answers, fn q, a ->
      chosen = Enum.join(a["labels"], ", ")
      own = a["text"] |> String.split() |> Enum.join(" ")

      said =
        case {chosen, own} do
          {c, ""} -> c
          {"", o} -> "the person wrote: " <> o
          {c, o} -> c <> "; the person wrote: " <> o
        end

      "Ask #{id}, #{one_line(q["header"])}: " <> said
    end)
    |> Enum.join("\n")
  end

  defp one_line(text), do: text |> String.split() |> Enum.join(" ")

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  # A question from JSON has string keys; one the app's own code builds may have atom keys.
  @atoms Map.new(
           ~w(header question options multiSelect label description labels text)a,
           &{Atom.to_string(&1), &1}
         )
  defp get(map, key), do: Map.get(map, key, Map.get(map, Map.fetch!(@atoms, key)))
end
