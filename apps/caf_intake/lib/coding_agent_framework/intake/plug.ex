defmodule CodingAgentFramework.Intake.Plug do
  @moduledoc """
  The HTTP endpoint of `CodingAgentFramework.Intake`. Options: `intake:` (the `Intake`, by pid
  or by the name the embedding app gave it) and `secret:` (the instance's secret, given by the
  embedding app). See `CodingAgentFramework.Intake` for how the embedding app serves it.

  It answers only `POST /hooks/<account>` and `POST /hooks/<account>/waiter` from 127.0.0.1
  with the secret in `x-caf-secret`, compared in constant time. Anything else is refused with a
  status and writes no row: 404 for another path, 405 for another method, 403 from another
  address, 401 for a wrong secret, 503 when the `Intake` does not answer. A stored event gets
  200 with an empty body; a held `PermissionRequest`, `PreToolUse`, `PostToolUse` or `Stop` gets
  its decision, or an empty body at its deadline.

  A waiter (`Intake.waiter_hook/5`) gets 200 at once and a chunked response: a newline every
  `beat` ms, and one at once on `{ref, :beat}`, then its text as the last chunk, or nothing
  more at its deadline. A failed write ends the hold (`Intake.closed/3`): Bandit tells a
  handler that its connection closed only when it writes (F-121). A body that names no session
  gets 400.

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

    with {:path, {account, kind}} <- {:path, route(conn.path_info)},
         {:method, "POST"} <- {:method, conn.method},
         {:account, true} <- {:account, account =~ @account},
         {:from, {127, 0, 0, 1}} <- {:from, conn.remote_ip},
         {:secret, true} <- {:secret, secret?(given, opts.secret.())},
         {:ok, body, conn} <- read_body(conn, length: @max_body) do
      if kind == :waiter,
        do: waiter(conn, opts.intake, account, body),
        else: post(conn, opts.intake, account, body)
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

  defp route(["hooks", account]), do: {account, :event}
  defp route(["hooks", account, "waiter"]), do: {account, :waiter}
  defp route(_), do: nil

  defp secret?([given], secret), do: Plug.Crypto.secure_compare(given, secret)
  defp secret?(_, _), do: false

  defp post(conn, intake, account, body) do
    case Intake.post(intake, account, body) do
      {:ok, stored} when stored in [:stored, :seen, :not_read] ->
        send_resp(conn, 200, "")

      # `wait` is past the hold's own deadline, in case the `Intake` stops answering.
      {:ok, {:held, id, ref, wait}} ->
        hold(conn, intake, id, ref, wait)

      {:ok, {:decided, body}} ->
        decision(conn, body)

      _ ->
        send_resp(conn, 503, "")
    end
  end

  defp decision(conn, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, body)

  defp hold(conn, intake, id, ref, wait) do
    mon = Process.monitor(GenServer.whereis(intake) || self())

    receive do
      {^ref, {:decision, body}} ->
        # Spec actions AnswerWritten and DecisionHanded: the decision is the response, and the
        # request closes; then the row is marked.
        conn = decision(conn, body)
        Intake.written(intake, id, ref)
        conn

      {^ref, :release} ->
        send_resp(conn, 200, "")

      # The `Intake` stopped: its next start marks this row lost.
      {:DOWN, ^mon, :process, _, _} ->
        send_resp(conn, 200, "")
    after
      wait -> send_resp(conn, 200, "")
    end
  end

  defp waiter(conn, intake, account, body) do
    case Intake.wait(intake, account, body) do
      {:ok, {:waiting, key, ref, wait, beat}} ->
        mon = Process.monitor(GenServer.whereis(intake) || self())
        conn = conn |> put_resp_content_type("text/plain") |> send_chunked(200)
        until = System.monotonic_time(:millisecond) + wait
        beats(conn, %{intake: intake, key: key, ref: ref, mon: mon, beat: beat, until: until})

      {:refused, _} ->
        send_resp(conn, 400, "")

      _ ->
        send_resp(conn, 503, "")
    end
  end

  defp beats(conn, w) do
    %{ref: ref, mon: mon} = w
    left = w.until - System.monotonic_time(:millisecond)

    receive do
      {^ref, {:decision, text}} ->
        # Spec actions TextWritten and TextMarked: the text is the last chunk; then Intake is
        # told whether its write succeeded.
        case chunk(conn, text) do
          {:ok, conn} ->
            Intake.written(w.intake, w.key, ref)
            conn

          {:error, _} ->
            Intake.closed(w.intake, w.key, ref)
            conn
        end

      {^ref, :release} ->
        conn

      {^ref, :beat} ->
        beat(conn, w)

      # The `Intake` stopped: the hold is gone with it.
      {:DOWN, ^mon, :process, _, _} ->
        conn
    after
      max(min(w.beat, left), 0) -> if left <= 0, do: conn, else: beat(conn, w)
    end
  end

  # A heartbeat. Its failure is how a connection that closed is found.
  defp beat(conn, w) do
    case chunk(conn, "\n") do
      {:ok, conn} ->
        beats(conn, w)

      {:error, _} ->
        Intake.closed(w.intake, w.key, w.ref)
        conn
    end
  end
end
