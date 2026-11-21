defmodule CodingAgentFramework.Sessions.Limit do
  @moduledoc """
  The usage limit on an agent row and its remedy's phase (`docs/design.md`, "Usage limits";
  `model/tla/Limit.tla`'s row variables), as the `usage_limit` column keeps it: a pure module,
  so the limit's healer (`CodingAgentFramework.Limits`), `Sessions`, which writes the column,
  and `Prompts`, which shows a person's prompts from it, read one shape.

  The field is a map with string keys, as JSON gives it back:

  - `until`: the reset, Unix seconds; a map without it is no limit, only the counts the row
    keeps after one (`goes`, `noted`);
  - `window`, `line` (the record it was read from: a transcript line's uuid, or a stream's
    result) and `spend` (the record says the account can spend usage credits);
  - `step`: the phase, one of `steps/0`;
  - `label` (the menu's option to press) and `by` (the person whose answer it is; none for the
    framework's own press), `options` (the menu's labels as read), `deadline` (wall-clock ms,
    the `usage_credits` prompt's), `why` (what opened the `limit` prompt), `menu` (the person's
    clears of a press, so a press after one is a new act);
  - `goes` (go-ons in a row that each hit a limit again) and `noted` (the limit whose word the
    count took last), kept when the limit clears, so the count runs across limits.

      iex> alias CodingAgentFramework.Sessions.Limit
      iex> l = %{"until" => 100, "step" => "prompt", "goes" => 3, "noted" => 100}
      iex> Limit.answer(l, "limit", "go_on", "sam")
      {:ok, %{"until" => 100, "step" => "look", "goes" => 0, "noted" => 100, "menu" => 1,
              "by" => "sam"}}
      iex> Limit.answer(%{l | "step" => "idle"}, "limit", "go_on", "sam")
      {:refused, :settled}
  """

  # Limit.tla's Steps: look, own, credits, press, unknown, idle, send, word, prompt; and left,
  # the `limit` prompt answered "leave": nothing acts until a turn runs or a new record comes.
  @steps ~w(look own credits press unknown idle send word prompt left)

  @doc "The remedy's phases (`Limit.tla`'s `Steps`, and `left`)."
  @spec steps() :: [String.t()]
  def steps, do: @steps

  @doc """
  The row's field as written, a limit or only the counts kept after one, or nil.
  `Sessions.Agents.limit/1` reads only a limit.

      iex> CodingAgentFramework.Sessions.Limit.of(%{usage_limit: ~s({"goes":2,"noted":9})})
      %{"goes" => 2, "noted" => 9}
  """
  @spec of(map | nil) :: map | nil
  def of(%{usage_limit: text}) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = field} -> field
      _ -> nil
    end
  end

  def of(_), do: nil

  @doc "The step the field names, or nil for none (no limit)."
  @spec step(map | nil) :: String.t() | nil
  def step(%{"until" => _, "step" => step}), do: step
  def step(_), do: nil

  @doc """
  The prompt a person sees for the field, or nil: `"limit"` while its step is `prompt`,
  `"usage_credits"` while it is `credits`.

      iex> CodingAgentFramework.Sessions.Limit.prompt(%{"until" => 1, "step" => "credits"})
      "usage_credits"
  """
  @spec prompt(map | nil) :: String.t() | nil
  def prompt(%{"until" => _, "step" => "prompt"}), do: "limit"
  def prompt(%{"until" => _, "step" => "credits"}), do: "usage_credits"
  def prompt(_), do: nil

  @doc """
  The choices a prompt offers: the `limit` prompt `go_on` and `leave`; the `usage_credits`
  prompt the menu's stop and its usage credits' option, by their labels as read.

      iex> alias CodingAgentFramework.Sessions.Limit
      iex> Limit.options(%{"step" => "credits", "options" => ["Stop and wait for limit to reset",
      ...>   "Wait here, then continue automatically at 9pm", "Use usage credits"]})
      ["Stop and wait for limit to reset", "Use usage credits"]
  """
  @spec options(map) :: [String.t()]
  def options(%{"step" => "prompt"}), do: ~w(go_on leave)

  def options(%{"step" => "credits"} = l) do
    labels = l["options"] || []
    stop = stop_label(labels)
    spend = Enum.reject(labels, &(&1 == stop or wait?(&1)))
    Enum.reject([stop | spend], &is_nil/1)
  end

  def options(_), do: []

  @doc """
  The menu's option that stops and waits for the reset, found by its label (2.1.322: "Stop and
  wait for limit to reset"), or nil.
  """
  @spec stop_label([String.t()]) :: String.t() | nil
  def stop_label(labels), do: Enum.find(labels, &String.starts_with?(&1, "Stop and wait"))

  defp wait?(label), do: String.starts_with?(label, "Wait here")

  @doc """
  A person's answer of the prompt `kind` the field shows, as `by` (`Limit.tla`'s `AnswerLimit`
  and `AnswerCredits`): the field after it, or `{:refused, :settled}` when the field shows no
  such prompt now, `{:refused, {:bad, :choice}}` for a choice it does not offer.

  - `limit`, `"go_on"`: the go-ons in a row start again, the screen is read again, and a press
    whose outcome was unknown is cleared (`menu`), so the menu may be pressed once more;
  - `limit`, `"leave"`: nothing more acts on this limit (`left`);
  - `usage_credits`, a label it offers: that option is pressed, a person's answer.
  """
  @spec answer(map | nil, String.t(), term, String.t()) :: {:ok, map} | {:refused, term}
  def answer(limit, kind, choice, by) do
    cond do
      prompt(limit) != kind -> {:refused, :settled}
      choice not in options(limit) -> {:refused, {:bad, :choice}}
      true -> {:ok, answered(limit, kind, choice, by)}
    end
  end

  defp answered(l, "limit", "go_on", by),
    do: Map.merge(l, %{"step" => "look", "goes" => 0, "menu" => (l["menu"] || 0) + 1, "by" => by})

  defp answered(l, "limit", "leave", by), do: Map.merge(l, %{"step" => "left", "by" => by})

  defp answered(l, "usage_credits", label, by),
    do: Map.merge(l, %{"step" => "press", "label" => label, "by" => by})

  @doc """
  What the row keeps once its limit clears (`Limit.tla`'s `Continued`): the counts, and no
  `until`, so `Sessions.Agents.limit/1` reads no limit. Nil when there is nothing to keep.

      iex> CodingAgentFramework.Sessions.Limit.cleared(%{"until" => 9, "step" => "word", "goes" => 1, "noted" => 9})
      %{"goes" => 1, "noted" => 9}
  """
  @spec cleared(map | nil) :: map | nil
  def cleared(limit) do
    kept = Map.take(limit || %{}, ~w(goes noted))
    if kept["goes"] in [nil, 0], do: nil, else: kept
  end
end
