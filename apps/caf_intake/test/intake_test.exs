defmodule CodingAgentFramework.IntakeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import CodingAgentFramework.IntakeSetup

  alias CodingAgentFramework.{Intake, IntakeSetup}
  alias CodingAgentFramework.Intake.{Event, Table}

  doctest Intake
  doctest Event
  doctest Table
  doctest Intake.Plug

  @secret IntakeSetup.secret()

  setup {IntakeSetup, :intake}

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

  test "after a restart a held row is lost and a deciding one unknown", %{db: db, start: start} do
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

    true = Table.move(other, id2, "held", "deciding", "{}", 1)
    stop_supervised!(Intake)
    # The Intake is gone, so the open request is let go with no decision.
    assert %{status: 200, resp_body: ""} = Task.await(task)

    start.([])
    assert_receive %{topic: "intake:h:work", ids: ids}, 5_000
    assert Enum.sort(ids) == Enum.sort([id, id2])
    assert [%{hold: "lost"}, %{hold: "unknown"}] = rows(db)
  end

  test "the hooks' secret is made once per home, kept, and never replaced" do
    dir = CodingAgentFramework.TestHost.test_dir()
    path = Path.join([dir, "home", "intake.secret"])
    {:ok, secret} = Intake.secret(path)
    assert secret =~ ~r/\A[A-Za-z0-9_-]{32}\z/
    assert Intake.secret(path) == {:ok, secret}
    assert File.ls!(Path.dirname(path)) == ["intake.secret"]

    # A person's own secret, a newline after it, is read as it is.
    File.write!(path, "mine.1\n")
    assert Intake.secret(path) == {:ok, "mine.1"}

    File.chmod!(path, 0o640)
    assert Intake.secret(path) == {:refused, {:secret_readable, path}}

    File.chmod!(path, 0o600)
    File.write!(path, "no 'quotes'")
    assert Intake.secret(path) == {:refused, {:bad_secret, path}}
    assert File.read!(path) == "no 'quotes'"
  end

  describe "the event parser" do
    defp text,
      do:
        one_of([
          constant("PermissionRequest"),
          member_of(Event.names() ++ Event.tool_names()),
          string(:printable)
        ])

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
          else:
            assert(
              row.event in (Event.names() ++ Event.tool_names()) and is_binary(row.session_id)
            )
      end
    end

    property "every body posted is stored or held, never a crash", %{start: start} do
      intake = start.([])

      check all(body <- any_body()) do
        assert {:ok, outcome} = Intake.post(intake, "work", body)
        assert outcome in [:stored, :seen, :not_read] or match?({:held, _, _, _}, outcome)
      end
    end
  end
end
