defmodule CodingAgentFramework.IntakeSetup do
  @moduledoc """
  The setup `IntakeTest` and `IntakeSourceTest` share: an `Intake` on a table in the test's own
  directory, and a hook event posted to it through `Intake.Plug` as Claude Code posts it.

  It compiles only for tests. It lives in `caf_intake`, not `caf_test`, because it uses
  `Intake`, and `caf_test` may not use an app above it.

      setup {CodingAgentFramework.IntakeSetup, :intake}
  """

  import CodingAgentFramework.TestHost
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias CodingAgentFramework.Intake
  alias CodingAgentFramework.Intake.Table

  @secret "s3cr3t"

  @doc "The secret each test's `Intake.Plug` checks."
  def secret, do: @secret

  @doc """
  An ExUnit setup: the test's `dir`, the Intake's `db`, and `start`, which starts an `Intake` on
  host `"h"` with the given options. The Intake's cues come to the test process.
  """
  def intake(_context) do
    dir = test_dir()
    me = self()
    db = Path.join(dir, "intake.db")
    notify = &send(me, &1)
    start = &start_supervised!({Intake, [db: db, host: "h", notify: notify] ++ &1})
    {:ok, db: db, dir: dir, start: start}
  end

  @doc "A hook body of `event` for session `s1`, with `extra` fields."
  def body(event, extra \\ %{}),
    do: JSON.encode!(Map.merge(%{"hook_event_name" => event, "session_id" => "s1"}, extra))

  @doc """
  Posts `body` to `intake` through `Intake.Plug`, by default to account `work` from the local
  address with the right secret; `opts` may set `:method`, `:path`, `:secret` and `:ip`.
  """
  def post(intake, body, opts \\ []) do
    Plug.Test.conn(
      Keyword.get(opts, :method, :post),
      Keyword.get(opts, :path, "/hooks/work"),
      body
    )
    |> Plug.Conn.put_req_header("x-caf-secret", Keyword.get(opts, :secret, @secret))
    |> Map.put(:remote_ip, Keyword.get(opts, :ip, {127, 0, 0, 1}))
    |> Intake.Plug.call(Intake.Plug.init(intake: intake, secret: @secret))
  end

  @doc "The rows of host `h` and account `work` in the table at `db`."
  def rows(db) do
    {:ok, db} = Table.open(db)
    {:ok, %{rows: rows}} = Table.rows(db, "h", "work")
    rows
  end
end
