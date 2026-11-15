defmodule CodingAgentFramework.Intake.Plug do
  @moduledoc """
  The HTTP endpoint of `CodingAgentFramework.Intake`. Options: `intake:` (the `Intake`, by pid
  or by the name the embedding app gave it) and `secret:` (the instance's secret, given by the
  embedding app). See `CodingAgentFramework.Intake` for how the embedding app serves it.

  It answers only `POST /hooks/<account>` from 127.0.0.1 with the secret in `x-caf-secret`,
  compared in constant time. Anything else is refused with a status and writes no row: 404 for
  another path, 405 for another method, 403 from another address, 401 for a wrong secret, 503
  when the `Intake` does not answer. A stored event gets 200 with an empty body; a held
  `PermissionRequest` gets its decision, or an empty body at the deadline.

      iex> plug = CodingAgentFramework.Intake.Plug
      iex> opts = plug.init(intake: self(), secret: "s3")
      iex> conn = Plug.Test.conn(:get, "/hooks/work") |> plug.call(opts)
      iex> conn.status
      405
  """

  @behaviour Plug

  import Plug.Conn

  alias CodingAgentFramework.Intake

  @header "x-caf-secret"
  @account ~r/\A[a-z0-9][a-z0-9_-]{0,31}\z/
  # Bodies past this are not hook inputs the framework reads; they are refused, not cut.
  @max_body 8_000_000
  # How long past the `Intake`'s own deadline the request waits, if the `Intake` stops answering.
  @margin 5_000

  @impl true
  def init(opts) do
    secret = Keyword.fetch!(opts, :secret)
    # Kept behind a function, so a crash report or `inspect` of the options never shows it.
    %{intake: Keyword.fetch!(opts, :intake), secret: fn -> secret end}
  end

  @impl true
  def call(conn, opts) do
    given = get_req_header(conn, @header)
    conn = delete_req_header(conn, @header)

    with {:path, ["hooks", account]} <- {:path, conn.path_info},
         {:method, "POST"} <- {:method, conn.method},
         {:account, true} <- {:account, account =~ @account},
         {:from, {127, 0, 0, 1}} <- {:from, conn.remote_ip},
         {:secret, true} <- {:secret, secret?(given, opts.secret.())},
         {:ok, body, conn} <- read_body(conn, length: @max_body) do
      post(conn, opts.intake, account, body)
    else
      {:path, _} -> send_resp(conn, 404, "")
      {:account, _} -> send_resp(conn, 404, "")
      {:method, _} -> send_resp(conn, 405, "")
      {:from, _} -> send_resp(conn, 403, "")
      {:secret, _} -> send_resp(conn, 401, "")
      {:more, _, conn} -> send_resp(conn, 413, "")
      {:error, _} -> send_resp(conn, 400, "")
    end
  end

  defp secret?([given], secret), do: Plug.Crypto.secure_compare(given, secret)
  defp secret?(_, _), do: false

  defp post(conn, intake, account, body) do
    case Intake.post(intake, account, body) do
      {:ok, stored} when stored in [:stored, :seen] -> send_resp(conn, 200, "")
      {:ok, {:held, id, ref, wait}} -> hold(conn, intake, id, ref, wait)
      _ -> send_resp(conn, 503, "")
    end
  end

  defp hold(conn, intake, id, ref, wait) do
    mon = Process.monitor(GenServer.whereis(intake) || self())

    receive do
      {^ref, {:decision, body}} ->
        # Spec action AnswerWritten: the decision is the response, and the request closes.
        conn = conn |> put_resp_content_type("application/json") |> send_resp(200, body)
        Intake.written(intake, id, ref)
        conn

      {^ref, :release} ->
        send_resp(conn, 200, "")

      # The `Intake` stopped: its next start marks this row lost.
      {:DOWN, ^mon, :process, _, _} ->
        send_resp(conn, 200, "")
    after
      wait + @margin -> send_resp(conn, 200, "")
    end
  end
end
