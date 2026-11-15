defmodule CodingAgentFramework.IntakeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Accounts, Intake}
  alias CodingAgentFramework.Intake.{Event, Table}
  alias CodingAgentFramework.Tracker.IntakeSource

  doctest Intake
  doctest Event
  doctest Table
  doctest Intake.Plug

  @secret "s3cr3t"

  setup do
    dir = test_dir()
    me = self()
    db = Path.join(dir, "intake.db")
    notify = &send(me, &1)
    start = &start_supervised!({Intake, [db: db, host: "h", notify: notify] ++ &1})
    {:ok, db: db, dir: dir, start: start}
  end

  defp body(event, extra \\ %{}),
    do: JSON.encode!(Map.merge(%{"hook_event_name" => event, "session_id" => "s1"}, extra))

  defp post(intake, body, opts \\ []) do
    Plug.Test.conn(
      Keyword.get(opts, :method, :post),
      Keyword.get(opts, :path, "/hooks/work"),
      body
    )
    |> Plug.Conn.put_req_header("x-caf-secret", Keyword.get(opts, :secret, @secret))
    |> Map.put(:remote_ip, Keyword.get(opts, :ip, {127, 0, 0, 1}))
    |> Intake.Plug.call(Intake.Plug.init(intake: intake, secret: @secret))
  end

  defp rows(db) do
    {:ok, db} = Table.open(db)
    {:ok, %{rows: rows}} = Table.rows(db, "h", "work")
    rows
  end

  defp hold(intake) do
    task = Task.async(fn -> post(intake, body("PermissionRequest", %{"tool_use_id" => "t1"})) end)
    assert_receive %{topic: "intake:h:work", ids: [id]}, 5_000
    {task, id}
  end

  test "over HTTP, an event is stored before its 200, and a held request carries its answer",
       %{db: db, start: start} do
    # Mix leaves inets off the code path, since the library does not need it.
    Mix.ensure_application!(:inets)
    {:ok, _} = Application.ensure_all_started(:inets)
    intake = start.([])
    plug = {Intake.Plug, intake: intake, secret: @secret}

    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    url = ~c"http://127.0.0.1:#{port}/hooks/work"
    request = &{url, [{~c"x-caf-secret", ~c"#{@secret}"}], ~c"application/json", &1}

    {:ok, {{_, 200, _}, _, ~c""}} = :httpc.request(:post, request.(body("Stop")), [], [])
    # The cue goes out after the row's write and before the reply, so it is already here.
    assert_received %{topic: "intake:h:work", ids: [_]}
    assert [%{event: "Stop", hold: nil}] = rows(db)

    held = request.(body("PermissionRequest", %{"tool_use_id" => "t1"}))
    task = Task.async(fn -> :httpc.request(:post, held, [timeout: 5_000], []) end)
    assert_receive %{ids: [id]}, 5_000
    assert {:ok, :sent} = Intake.answer(intake, id, {:deny, "no"})
    {:ok, {{_, 200, _}, _, answer}} = Task.await(task)

    assert %{"hookSpecificOutput" => %{"decision" => %{"behavior" => "deny", "message" => "no"}}} =
             JSON.decode!(to_string(answer))
  end

  test "a second post of one event writes no second row", %{db: db, start: start} do
    intake = start.([])
    assert %{status: 200, resp_body: ""} = post(intake, body("SessionStart", %{"source" => "x"}))
    assert %{status: 200} = post(intake, body("SessionStart", %{"source" => "x"}))
    assert [%{key: "SessionStart:s1:x"}] = rows(db)

    {:ok, source} = IntakeSource.open(db: db, host: "h", account: "work")
    assert {:ok, %{rows: [_]}} = IntakeSource.read(source, :all)
  end

  test "a wrong secret, path, method or address is refused with no row", %{db: db, start: start} do
    intake = start.([])
    assert post(intake, body("Stop"), secret: "nope").status == 401
    assert post(intake, body("Stop"), path: "/hooks/a/b").status == 404
    assert post(intake, body("Stop"), path: "/hooks/Work").status == 404
    assert post(intake, body("Stop"), method: :put).status == 405
    assert post(intake, body("Stop"), ip: {10, 0, 0, 2}).status == 403
    assert rows(db) == []
  end

  test "a held request is answered once; a second answer is refused", %{db: db, start: start} do
    intake = start.([])
    {task, id} = hold(intake)
    assert [%{hold: "held"}] = rows(db)
    assert {:refused, {:bad_decision, :maybe}} = Intake.answer(intake, id, :maybe)
    assert {:ok, :sent} = Intake.answer(intake, id, :allow)
    conn = Task.await(task)

    assert JSON.decode!(conn.resp_body)["hookSpecificOutput"]["decision"] == %{
             "behavior" => "allow"
           }

    assert [%{hold: "answered"}] = rows(db)
    assert {:refused, {:not_held, "answered"}} = Intake.answer(intake, id, :allow)
  end

  test "a hold no one answers expires with an empty body", %{db: db, start: start} do
    intake = start.(deadline: 50)
    {task, id} = hold(intake)
    assert %{status: 200, resp_body: ""} = Task.await(task)
    assert [%{hold: "expired"}] = rows(db)
    assert {:refused, {:not_held, "expired"}} = Intake.answer(intake, id, :allow)
  end

  test "after a restart a held row is lost and an answering one unknown", %{db: db, start: start} do
    intake = start.([])
    {task, id} = hold(intake)
    {:ok, other} = Table.open(db)

    {:new, id2} =
      Table.insert(
        other,
        "h",
        "work",
        Event.parse(body("PermissionRequest", %{"tool_use_id" => "t2"})),
        1
      )

    true = Table.move(other, id2, "held", "answering", "{}", 1)
    stop_supervised!(Intake)
    # The Intake is gone, so the open request is let go with no decision.
    assert %{status: 200, resp_body: ""} = Task.await(task)

    start.([])
    assert_receive %{topic: "intake:h:work", ids: ids}, 5_000
    assert Enum.sort(ids) == Enum.sort([id, id2])
    assert [%{hold: "lost"}, %{hold: "unknown"}] = rows(db)
  end

  test "Accounts writes the http hooks into both role settings", %{dir: dir} do
    {:ok, accounts} = Accounts.new(dir, ["work"])
    own = %{"Stop" => [%{"hooks" => [%{"type" => "command", "command" => "true"}]}]}

    {:ok, account} =
      Accounts.prepare(accounts, "work", %{hooks: own, intake: %{port: 4790, secret: @secret}})

    for role <- [:parent, :delegate] do
      hooks = JSON.decode!(File.read!(account.settings[role]))["hooks"]
      assert Map.keys(hooks) == Enum.sort(Event.names())
      assert [%{"hooks" => [%{"type" => "command"}]}, %{"hooks" => [stop]}] = hooks["Stop"]
      assert %{"url" => "http://127.0.0.1:4790/hooks/work", "timeout" => 10} = stop
      assert stop["headers"] == %{"x-caf-secret" => @secret}
      refute Map.has_key?(stop, "onFailure")
      assert [%{"hooks" => [%{"timeout" => 600}]}] = hooks["PermissionRequest"]
    end
  end

  describe "the event parser" do
    defp text,
      do: one_of([constant("PermissionRequest"), member_of(Event.names()), string(:printable)])

    defp value, do: one_of([text(), integer(), constant(nil), list_of(integer(), max_length: 2)])

    defp map_body do
      keys = ~w(hook_event_name session_id tool_use_id prompt_id source agent_id other)

      gen(
        all(
          pairs <- list_of({member_of(keys), value()}, max_length: 7),
          do: JSON.encode!(Map.new(pairs))
        )
      )
    end

    defp any_body,
      do: one_of([map_body(), binary(), map(list_of(integer()), &JSON.encode!/1)])

    property "parsing is total: a known event is a row, anything else a named problem" do
      check all(body <- any_body()) do
        row = Event.parse(body)
        assert is_binary(row.key)

        if row.problem,
          do: assert({row.event, row.hold} == {nil, false}),
          else: assert(row.event in Event.names() and is_binary(row.session_id))
      end
    end

    property "every body posted is stored or held, never a crash", %{start: start} do
      intake = start.([])

      check all(body <- any_body()) do
        assert {:ok, outcome} = Intake.post(intake, "work", body)
        assert outcome in [:stored, :seen] or match?({:held, _, _, _}, outcome)
      end
    end
  end
end
