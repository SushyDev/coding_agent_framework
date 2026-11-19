defmodule CodingAgentFramework.Runs.Plug do
  @moduledoc """
  The endpoint the wrapper (`CodingAgentFramework.Runs`) asks for its lease at: `POST /runs`
  from 127.0.0.1 with the instance's secret in `x-caf-secret`, its form fields as
  `Runs.ask/1` reads them. Anything else is refused with a status: 404 for another path, 405
  for another method, 403 from another address, 401 for a wrong secret, 413 for a body past
  8 KiB. The embedding app serves it on the intake's port, beside `Intake.Plug`.

  The request's own process is the `Scheduler`'s requester, so a wrapper that goes away while
  queued leaves the queue. The request is `%{id: "run:" <> tool_use_id, class: class, module:
  agent, account: nil, units: units, holder: {"run", "<pid> <start>"}}`, the units from the
  app's `units:` function of the class and the agent. The answer is one line of text, the last
  of a chunked response:

    * `granted <lease id>`: the lease is this wrapper's (its holder, not released);
    * `refused <reason> <retry time>`: the `Scheduler`'s refusal, the time in UTC (ISO 8601);
      `used` when the id's lease is another process's or was released, `bad_<field>` for a
      request out of shape, a refusal of `units` by its first word, each with `-` for a time;
    * `unknown <reason>`: no answer from the `Scheduler` (gone, or past its deadline).

  Queued, the response is chunked: `queued (position n)` first (unless the wrapper asks again
  after a cut, `again=1`), then a newline every `beat:` ms (5 000 by default), whose failed
  write is how a wrapper gone is found, then the answer. A wait longer than `wait:` ms
  (600 000 by default, past every class's `max_wait`) ends `unknown no_answer`.

      iex> plug = CodingAgentFramework.Runs.Plug
      iex> opts = plug.init(scheduler: fn -> nil end, units: fn _, _ -> {:ok, %{}} end, secret: "s")
      iex> conn = Plug.Test.conn(:get, "/runs") |> plug.call(opts)
      iex> conn.status
      405
  """

  @behaviour Plug

  import Plug.Conn

  alias CodingAgentFramework.{Runs, Scheduler}

  @header "x-caf-secret"
  @max_body 8_192
  @beat 5_000
  @wait 600_000

  @impl true
  def init(opts) do
    secret = Keyword.fetch!(opts, :secret)

    %{
      scheduler: Keyword.fetch!(opts, :scheduler),
      units: Keyword.fetch!(opts, :units),
      # Kept behind a function, so a crash report or `inspect` of the options never shows it.
      secret: fn -> secret end,
      beat: Keyword.get(opts, :beat, @beat),
      wait: Keyword.get(opts, :wait, @wait)
    }
  end

  @impl true
  def call(conn, opts) do
    given = get_req_header(conn, @header)
    conn = delete_req_header(conn, @header)

    with {:path, ["runs"]} <- {:path, conn.path_info},
         {:method, "POST"} <- {:method, conn.method},
         {:from, {127, 0, 0, 1}} <- {:from, conn.remote_ip},
         {:secret, true} <- {:secret, secret?(given, opts.secret.())},
         {:ok, body, conn} <- read_body(conn, length: @max_body) do
      case Runs.ask(URI.decode_query(body)) do
        {:ok, ask} -> lease(conn, opts, ask)
        {:refused, {:bad, field}} -> answer(conn, "refused bad_#{field} -")
      end
    else
      {:path, _} -> send_resp(conn, 404, "")
      {:method, _} -> send_resp(conn, 405, "")
      {:from, _} -> send_resp(conn, 403, "")
      {:secret, _} -> send_resp(conn, 401, "")
      {:more, _, conn} -> send_resp(conn, 413, "")
      {:error, _} -> send_resp(conn, 400, "")
    end
  end

  defp secret?([given], secret), do: Plug.Crypto.secure_compare(given, secret)
  defp secret?(_, _), do: false

  defp lease(conn, opts, ask) do
    case opts.units.(ask.class, ask.agent) do
      {:ok, units} -> request(conn, opts, ask, units)
      {:refused, why} -> answer(conn, "refused #{word(why)} -")
    end
  end

  defp request(conn, opts, ask, units) do
    holder = {"run", ask.holder}

    req = %{
      id: "run:" <> ask.id,
      class: ask.class,
      module: ask.agent,
      account: nil,
      units: units,
      holder: holder
    }

    case ask(opts.scheduler.(), req) do
      {:ok, lease} ->
        answer(conn, granted(lease, holder))

      {:queued, %{position: n}} ->
        conn = conn |> put_resp_content_type("text/plain") |> send_chunked(200)
        until = System.monotonic_time(:millisecond) + opts.wait

        case if(ask.again, do: {:ok, conn}, else: chunk(conn, "queued (position #{n})\n")) do
          {:ok, conn} -> wait(conn, req.id, holder, opts.beat, until)
          {:error, _} -> conn
        end

      {:refused, {reason, retry_at}} when is_atom(reason) and is_integer(retry_at) ->
        answer(conn, "refused #{reason} #{time(retry_at)}")

      {:refused, why} ->
        answer(conn, "refused #{word(why)} -")

      {:unknown, why} ->
        answer(conn, "unknown #{word(why)}")
    end
  end

  defp ask(nil, _req), do: {:unknown, :no_scheduler}
  defp ask(scheduler, req), do: Scheduler.request(scheduler, req)

  # A lease the id already has is this wrapper's only while it holds it and it is not released:
  # a second process under one id never shares a slot.
  defp granted(%{holder: holder, released_at: nil, id: id}, holder), do: "granted #{id}"
  defp granted(_lease, _holder), do: "refused used -"

  # The one more answer the `Scheduler` owes, with a heartbeat between: a write that fails ends
  # this process, and the `Scheduler` drops the request.
  defp wait(conn, id, holder, beat, until) do
    left = until - System.monotonic_time(:millisecond)

    receive do
      {:lease, ^id, {:ok, lease}} ->
        last(conn, granted(lease, holder))

      {:lease, ^id, {:refused, {reason, retry_at}}} ->
        last(conn, "refused #{reason} #{time(retry_at)}")
    after
      max(min(beat, left), 0) ->
        cond do
          left <= 0 -> last(conn, "unknown no_answer")
          match?({:ok, _}, chunk(conn, "\n")) -> wait(conn, id, holder, beat, until)
          true -> conn
        end
    end
  end

  defp last(conn, line) do
    case chunk(conn, line <> "\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp answer(conn, line),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(200, line <> "\n")

  defp time(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  # One word for a line the wrapper splits on spaces.
  defp word(why) when is_atom(why), do: Atom.to_string(why)
  defp word(why) when is_tuple(why), do: why |> elem(0) |> word()
  defp word(_why), do: "other"
end
