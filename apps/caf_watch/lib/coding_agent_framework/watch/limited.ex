defmodule CodingAgentFramework.Watch.Limited do
  @moduledoc """
  The digest of the symptom `limited` by account (`docs/design.md`, "Metrics and healing" and
  "Usage limits"; F-193): one pure fold of the `Watch`'s rows of that kind, as `Limits`
  records them, one per agent and limit, its evidence the account, the window and the reset.

  An account is limited while a row of it is `open`. Its reading is its newest reset and that
  reset's window, and its agents, each with its own reset, when its row began (`since`, ms) and
  how long it has waited (`waited`, ms, to `now`). Accounts come in name order, and their
  agents by how long they have waited, longest first.

      iex> rows = [
      ...>   %{kind: "limited", target: "app-unit", status: "open", since: 1_000,
      ...>     evidence: ~s({"account":"work","until":1800,"window":"five_hour"})},
      ...>   %{kind: "limited", target: "app-main", status: "open", since: 4_000,
      ...>     evidence: ~s({"account":"work","until":1800,"window":"five_hour"})},
      ...>   %{kind: "limited", target: "app-old", status: "passed", since: 0,
      ...>     evidence: ~s({"account":"spare","until":900,"window":"seven_day"})}]
      iex> CodingAgentFramework.Watch.Limited.digest(rows, 10_000)
      [%{account: "work", window: "five_hour", until: 1800,
         agents: [%{agent: "app-unit", until: 1800, since: 1_000, waited: 9_000},
                  %{agent: "app-main", until: 1800, since: 4_000, waited: 6_000}]}]
  """

  @typedoc "One account's reading."
  @type reading :: %{
          account: String.t(),
          window: String.t() | nil,
          until: integer | nil,
          agents: [%{agent: String.t(), until: integer | nil, since: integer, waited: integer}]
        }

  @doc "The accounts limited now, from the `Watch`'s rows (any kind; only `limited` counts)."
  @spec digest([map], integer) :: [reading]
  def digest(rows, now) do
    rows
    |> Enum.filter(&(&1.kind == "limited" and &1.status == "open"))
    |> Enum.map(&{evidence(&1.evidence), &1})
    |> Enum.filter(fn {ev, _} -> is_binary(ev["account"]) end)
    |> Enum.group_by(fn {ev, _} -> ev["account"] end)
    |> Enum.sort()
    |> Enum.map(fn {account, held} -> reading(account, held, now) end)
  end

  defp reading(account, held, now) do
    {newest, _} = Enum.max_by(held, fn {ev, _} -> ev["until"] || 0 end)

    agents =
      for {ev, row} <- held do
        %{
          agent: row.target,
          until: ev["until"],
          since: row.since,
          waited: max(now - row.since, 0)
        }
      end

    %{
      account: account,
      window: newest["window"],
      until: newest["until"],
      agents: Enum.sort_by(agents, &{-&1.waited, &1.agent})
    }
  end

  defp evidence(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = ev} -> ev
      _ -> %{}
    end
  end

  defp evidence(_), do: %{}
end
