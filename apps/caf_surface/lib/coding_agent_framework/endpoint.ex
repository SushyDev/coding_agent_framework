defmodule CodingAgentFramework.Endpoint do
  @moduledoc """
  The intake's port, as the tree serves it on 127.0.0.1: `POST /runs` goes to
  `CodingAgentFramework.Runs.Plug` (a heavy command's wrapper asking for its lease, F-171),
  and everything else to `CodingAgentFramework.Intake.Plug` (the hooks). Options: `intake:`
  and `secret:`, as `Intake.Plug` takes them, and `runs:`, `Runs.Plug`'s own but the secret.

      iex> opts = CodingAgentFramework.Endpoint.init(intake: self(), secret: "s3",
      ...>   runs: [scheduler: fn -> nil end, units: fn _, _ -> {:ok, %{}} end])
      iex> Plug.Test.conn(:get, "/runs") |> CodingAgentFramework.Endpoint.call(opts) |> Map.get(:status)
      405
  """

  @behaviour Plug

  alias CodingAgentFramework.{Intake, Runs}

  @impl true
  def init(opts) do
    secret = Keyword.fetch!(opts, :secret)

    %{
      intake: Intake.Plug.init(intake: Keyword.fetch!(opts, :intake), secret: secret),
      runs: Runs.Plug.init(Keyword.fetch!(opts, :runs) ++ [secret: secret])
    }
  end

  @impl true
  def call(%Plug.Conn{path_info: ["runs"]} = conn, opts), do: Runs.Plug.call(conn, opts.runs)
  def call(conn, opts), do: Intake.Plug.call(conn, opts.intake)
end
