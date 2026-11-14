defmodule CodingAgentFramework.Intake.Event do
  @moduledoc """
  A hook post's body as a row: pure and total. Any body is a row; one that is not a known event
  of a known shape names its problem, and is never held.

  The row's `key` is what a second post of the same event repeats: `session_id` with the
  event's own id where it has one (`tool_use_id`, `prompt_id` for a prompt, the start's
  `source`, `agent_id` for a subagent), and otherwise a hash of the body.

      iex> body = ~s({"hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt_id": "p"})
      iex> CodingAgentFramework.Intake.Event.parse(body)
      %{event: "UserPromptSubmit", session_id: "s", key: "UserPromptSubmit:s:p",
        data: body, problem: nil, hold: false}
      iex> CodingAgentFramework.Intake.Event.parse("{").problem
      :not_json
  """

  @names ~w(SessionStart SessionEnd Stop StopFailure SubagentStart SubagentStop Notification
            UserPromptSubmit PermissionRequest PermissionDenied)
  @ids %{
    "PermissionRequest" => "tool_use_id",
    "PermissionDenied" => "tool_use_id",
    "UserPromptSubmit" => "prompt_id",
    "SessionStart" => "source",
    "SubagentStart" => "agent_id",
    "SubagentStop" => "agent_id"
  }

  @doc "The events every account's settings post, as the design's Intake section lists them."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The row for one body: its event, session, key, the body as data when it is JSON, and its problem."
  @spec parse(binary) :: map
  def parse(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{} = map} -> event(map, body)
      {:ok, _} -> problem(body, :not_an_object, body)
      {:error, _} -> problem(body, :not_json, nil)
    end
  end

  defp event(map, body) do
    {name, session} = {map["hook_event_name"], map["session_id"]}
    field = @ids[name]
    id = if field, do: map[field]

    cond do
      name not in @names -> problem(body, {:unknown_event, text(name)}, body)
      not (is_binary(session) and session != "") -> problem(body, {:bad, "session_id"}, body)
      field && not (is_binary(id) and id != "") -> problem(body, {:bad, field}, body)
      true -> row(name, session, "#{name}:#{session}:#{id || hash(body)}", body, nil)
    end
  end

  defp problem(body, problem, data), do: row(nil, nil, "body:" <> hash(body), data, problem)

  defp row(name, session, key, data, problem) do
    %{
      event: name,
      session_id: session,
      key: key,
      data: data,
      problem: problem,
      hold: name == "PermissionRequest" and is_nil(problem)
    }
  end

  # A name that is not text is kept as what it was, short, so a problem stays readable.
  defp text(name) when is_binary(name), do: String.slice(name, 0, 64)
  defp text(name), do: inspect(name, limit: 5, printable_limit: 64)

  defp hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
