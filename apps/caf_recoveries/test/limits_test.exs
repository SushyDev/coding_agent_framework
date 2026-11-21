defmodule CodingAgentFramework.LimitsTest do
  @moduledoc """
  The usage limit's healer (`Limits`) on real `Acts`, `Watch` and `Sessions` files in this
  test's own directory, against `model/tla/Limit.tla`. The agent rows are written as `Sessions`
  leaves a running one, with no pid, so its settle decides nothing about them. The transcript's
  row, the screen, the press, the word and the resume are stand-ins the test sets, each call
  told to the test; their own contracts are `TranscriptsTest`'s, `ScreenTest`'s, `InletTest`'s
  and `MailboxTest`'s. A clock the test moves is every part's, so no test sleeps. Each test
  names the property of `Limit.tla` it checks.
  """
  use ExUnit.Case, async: true

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Acts, Limits, Sessions, Watch}
  alias CodingAgentFramework.Sessions.Agents
  alias CodingAgentFramework.Tmux.Fake

  doctest Limits

  @until 1_000_100
  @margin 1_000
  @stop "Stop and wait for limit to reset"
  @wait "Wait here, then continue automatically at 9pm"
  @menu %{state: :dialog, kind: :usage_limit_menu, options: [@stop, @wait, "Upgrade your plan"]}

  setup do
    dir = test_dir()
    db = Path.join(dir, "caf.db")
    time = :counters.new(1, [:atomics])
    :counters.put(time, 1, 1_000_000_000)
    clock = fn -> :counters.get(time, 1) end

    {:ok, acts} =
      Acts.start_link(db: db, start_id: "s1", host: "test", instance: "a", clock: clock)

    {:ok, watch} = Watch.start_link(db: db, remedies: Watch.default_remedies(), clock: clock)
    {:ok, fake} = Fake.start_link(key: {"test", "fake"})
    tmux = Fake.new(fake, {"test", "fake"})
    File.mkdir_p!(Path.join(dir, "d"))

    {:ok, sessions} =
      Sessions.start_link(programs: programs(), dir: Path.join(dir, "d"), tmux: tmux, db: db)

    {:ok, table} = Sessions.Table.open(db)
    {:ok, agents} = Sessions.Agents.open(db, "test")
    {:ok, world} = Agent.start_link(fn -> %{screen: {:ok, @menu}, press: {:ok, :sent}} end)

    %{
      acts: acts,
      watch: watch,
      sessions: sessions,
      table: table,
      agents: agents,
      world: world,
      time: time,
      clock: clock,
      dir: dir
    }
  end

  # A running interactive main of the test, with the transcript's row `limit` (nil: none).
  defp agent!(ctx, name, fields \\ []) do
    row = %{host: "test", name: name, socket: name, account: "work", cwd: ctx.dir}
    id = Sessions.Table.starting(ctx.table, Map.merge(row, %{role: "parent", resume: nil}))
    fields = Keyword.merge([status: "running", session_id: "sid-" <> name], fields)
    Sessions.Table.update(ctx.table, id, fields)
    id
  end

  defp healer!(ctx) do
    me = self()
    w = ctx.world

    opts = [
      agents: ctx.agents,
      sessions: ctx.sessions,
      acts: ctx.acts,
      watch: ctx.watch,
      host: "test",
      margin: @margin,
      credits: 5_000,
      clock: ctx.clock,
      transcripts: fn _account ->
        {:ok, %{rows: Agent.get(w, &Map.get(&1, :transcripts, []))}}
      end,
      folds: fn -> {:ok, %{rows: Agent.get(w, &Map.get(&1, :folds, []))}} end,
      go_on: fn name, text, key, opts ->
        if opts[:resume] == false,
          do: send(me, {:held, name, text, key}),
          else: send(me, {:go_on, name, text, key})

        Agent.get(w, &Map.get(&1, {:go_on, name}, {:ok, :resumed}))
      end,
      # The Mover's pick and its move, told to the test; the move's end is the test's write of
      # the claim it was handed, as the Mover settles it.
      room: fn _row -> Agent.get(w, &Map.get(&1, :room, {:refused, :no_mover})) end,
      move: fn actor, name, to, act ->
        send(me, {:move, actor, name, to, act})
        Agent.get(w, &Map.get(&1, {:move, name}, {:ok, %{act: act}}))
      end,
      look: fn row ->
        send(me, {:looked, row.name})
        Agent.get(w, & &1.screen)
      end,
      # The screen after a press is `after`, when the test sets one.
      press: fn name, label ->
        send(me, {:pressed, name, label})
        Agent.get_and_update(w, &{&1.press, Map.put(&1, :screen, Map.get(&1, :after, &1.screen))})
      end,
      word: fn name, text, key ->
        send(me, {:word, name, text, key})
        {:ok, {:queued, 1}}
      end,
      resume: fn row ->
        send(me, {:resumed, row.name})
        {:ok, %{name: row.name}}
      end
    ]

    {:ok, healer} = Limits.start_link(opts)
    healer
  end

  # The transcript's last limit line of `name`: its reset, uuid, and whether a turn followed.
  defp hit!(ctx, name, uuid, opts \\ []) do
    record = %{
      "status" => "rejected",
      "resetsAt" => Keyword.get(opts, :until, @until),
      "rateLimitType" => "five_hour",
      "overageStatus" => Keyword.get(opts, :overage, "rejected")
    }

    t = %{
      session_id: "sid-" <> name,
      limit: %{record: record, uuid: uuid, followed: Keyword.get(opts, :followed, false)},
      ends_with_reply: Keyword.get(opts, :ended, false)
    }

    Agent.update(ctx.world, fn w ->
      others = Enum.reject(Map.get(w, :transcripts, []), &(&1.session_id == t.session_id))
      Map.put(w, :transcripts, [t | others])
    end)
  end

  defp screen!(ctx, screen), do: Agent.update(ctx.world, &Map.put(&1, :screen, screen))
  defp limit(ctx, name), do: Agents.limit(Agents.get(ctx.agents, name))
  defp step(ctx, name), do: limit(ctx, name)["step"]

  # Checks until the row's step stops moving: each write is a cue in the app's tree.
  defp settle(healer, ctx, name, n \\ 8) do
    Enum.reduce_while(1..n, step(ctx, name), fn _, before ->
      assert {:ok, _} = Limits.check(healer)
      now = step(ctx, name)
      if now == before, do: {:halt, now}, else: {:cont, now}
    end)
  end

  defp past_reset!(ctx), do: :counters.put(ctx.time, 1, @until * 1000 + @margin)

  # MenuPressedOnce, GoOnOnce and NoAgentLeftLimited: the menu is pressed once, by its stop's
  # label; at the reset plus the margin one word goes, under its key; a turn after it clears.
  test "a menu is pressed once, the word goes once at the reset, and a turn clears it", ctx do
    agent!(ctx, "app-epic")
    hit!(ctx, "app-epic", "a1")
    healer = healer!(ctx)

    assert settle(healer, ctx, "app-epic") == "idle"
    assert_received {:pressed, "app-epic", @stop}
    refute_received {:pressed, _, _}
    assert %{"until" => @until, "window" => "five_hour", "line" => "a1"} = limit(ctx, "app-epic")

    assert {:ok, [%{act: "press_stop", outcome: "recovered", state: state}]} =
             Acts.rows(ctx.acts, actor: "limits:test")

    assert state =~ "limit_menu:app-epic:#{@until}"
    assert {:ok, [%{status: "open"}]} = Watch.read(ctx.watch, kind: "limited")

    # Before the reset nothing more goes; after it and the margin, one word.
    assert settle(healer, ctx, "app-epic") == "idle"
    refute_received {:word, _, _, _}
    past_reset!(ctx)
    assert settle(healer, ctx, "app-epic") == "word"
    key = "limit:app-epic:#{@until}"
    assert_received {:word, "app-epic", _text, ^key}
    assert settle(healer, ctx, "app-epic") == "word"
    refute_received {:word, _, _, _}
    refute_received {:resumed, _}
    assert limit(ctx, "app-epic")["goes"] == 1

    # A turn ran after the line: the limit clears, its count kept, and the symptom passes.
    hit!(ctx, "app-epic", "a1", followed: true)
    assert {:ok, _} = Limits.check(healer)
    assert limit(ctx, "app-epic") == nil

    assert Sessions.Limit.of(Agents.get(ctx.agents, "app-epic")) == %{
             "goes" => 1,
             "noted" => @until
           }

    assert {:ok, [%{status: "passed"}]} = Watch.read(ctx.watch, kind: "limited")

    # It ended by itself: the go-ons in a row end.
    hit!(ctx, "app-epic", "a1", followed: true, ended: true)
    assert {:ok, _} = Limits.check(healer)
    assert Sessions.Limit.of(Agents.get(ctx.agents, "app-epic")) == nil
  end

  # MenuPressedOnce (RetryUnknown): a press whose outcome is unknown is never made again; the
  # menu still shown is a person's prompt, whose "go on" lets one more press go.
  test "an unknown press is a person's prompt, and only their answer presses again", ctx do
    agent!(ctx, "app-epic")
    hit!(ctx, "app-epic", "a1")
    Agent.update(ctx.world, &Map.put(&1, :press, {:unknown, {:not_selected, :menu}}))
    healer = healer!(ctx)

    assert settle(healer, ctx, "app-epic") == "prompt"
    assert_received {:pressed, "app-epic", @stop}
    refute_received {:pressed, _, _}
    assert limit(ctx, "app-epic")["why"] =~ "unknown"

    # A record read late changes nothing: the prompt stays.
    hit!(ctx, "app-epic", "a2")
    assert settle(healer, ctx, "app-epic") == "prompt"
    refute_received {:pressed, _, _}

    assert {:refused, {:bad, :choice}} =
             Sessions.answer_limit(ctx.sessions, "app-epic", "limit", "spend", "sam")

    assert {:ok, _} = Sessions.answer_limit(ctx.sessions, "app-epic", "limit", "go_on", "sam")

    assert {:refused, :settled} =
             Sessions.answer_limit(ctx.sessions, "app-epic", "limit", "go_on", "sam")

    Agent.update(ctx.world, &Map.put(&1, :press, {:ok, :sent}))
    assert settle(healer, ctx, "app-epic") == "idle"
    assert_received {:pressed, "app-epic", @stop}

    assert {:ok, [%{outcome: "unknown"}, %{outcome: "recovered"}]} =
             Acts.rows(ctx.acts, actor: "limits:test", act: "press_stop")
  end

  # TrustOwnWait and IgnoreOwnWait: Claude Code's own wait is watched, never typed into; still
  # shown past the reset and the margin, it is a person's prompt; ended with no turn, the
  # screen is read again.
  test "Claude Code's own wait is watched, and asked about only past the reset", ctx do
    agent!(ctx, "app-epic")
    hit!(ctx, "app-epic", "a1")
    screen!(ctx, {:ok, %{state: :usage_limit_wait, at: "9pm"}})
    healer = healer!(ctx)

    assert settle(healer, ctx, "app-epic") == "own"
    past_reset!(ctx)
    assert settle(healer, ctx, "app-epic") == "prompt"
    refute_received {:pressed, _, _}
    refute_received {:word, _, _, _}

    # Another agent's wait ended with no turn (an Esc): the stop, and the word at the reset.
    agent!(ctx, "app-api")
    hit!(ctx, "app-api", "b1")
    :counters.put(ctx.time, 1, 1_000_000_000)
    assert settle(healer, ctx, "app-api") == "own"
    screen!(ctx, {:ok, %{state: :idle, box: :empty}})
    assert settle(healer, ctx, "app-api") == "idle"
    past_reset!(ctx)
    assert settle(healer, ctx, "app-api") == "word"
    assert_received {:word, "app-api", _, _}
  end

  # NeverSpends and DefaultSpends: where the account can spend, a person is asked first; the
  # deadline's default is the stop, and the credits are pressed only as a person's answer.
  test "an account able to spend asks first; its deadline presses the stop", ctx do
    agent!(ctx, "app-epic")
    hit!(ctx, "app-epic", "a1", overage: "allowed")
    menu = %{@menu | options: [@stop, @wait, "Use usage credits"]}
    screen!(ctx, {:ok, menu})
    healer = healer!(ctx)

    assert settle(healer, ctx, "app-epic") == "credits"
    refute_received {:pressed, _, _}
    assert Sessions.Limit.options(limit(ctx, "app-epic")) == [@stop, "Use usage credits"]

    # The deadline passes: the stop, as the framework's.
    :counters.add(ctx.time, 1, 5_000)
    assert settle(healer, ctx, "app-epic") == "idle"
    assert_received {:pressed, "app-epic", @stop}

    # Another agent: a person answers the credits, pressed as theirs.
    agent!(ctx, "app-api")
    hit!(ctx, "app-api", "b1", overage: "allowed")
    assert settle(healer, ctx, "app-api") == "credits"

    assert {:ok, _} =
             Sessions.answer_limit(
               ctx.sessions,
               "app-api",
               "usage_credits",
               "Use usage credits",
               "sam"
             )

    assert settle(healer, ctx, "app-api") == "idle"
    assert_received {:pressed, "app-api", "Use usage credits"}

    assert {:ok, [_, %{detail: detail}]} =
             Acts.rows(ctx.acts, actor: "limits:test", act: "press_stop")

    assert detail =~ "sam"
  end

  # BoundedRetries and NoResumeOnLimited's word by launch: past the bound of go-ons in a row,
  # a person's prompt; a gone process is resumed with its word.
  test "go-ons past the bound are asked, and a gone main is resumed with its word", ctx do
    agent!(ctx, "app-epic")
    hit!(ctx, "app-epic", "a1")
    healer = healer!(ctx)
    assert settle(healer, ctx, "app-epic") == "idle"

    l = limit(ctx, "app-epic")
    assert {:ok, _} = Sessions.put_limit(ctx.sessions, "app-epic", Map.put(l, "goes", 3))
    past_reset!(ctx)
    assert settle(healer, ctx, "app-epic") == "prompt"
    assert limit(ctx, "app-epic")["why"] =~ "3 go-ons"
    refute_received {:word, _, _, _}

    agent!(ctx, "app-api", status: "stopped", reason: "exited")
    hit!(ctx, "app-api", "b1")
    assert settle(healer, ctx, "app-api") == "word"
    assert_received {:word, "app-api", _, _}
    assert_received {:resumed, "app-api"}
    refute_received {:pressed, "app-api", _}
  end

  # Limit.tla's Report and Deliver (F-186's new-1): a headless delegate's limit is its stream's
  # result and event; at the reset its word is `Delegates`' (`go_on:`), which stores it and
  # resumes the gone process, never a notice and a resume here. Refused, it is a person's.
  test "a gone headless delegate's word at the reset is Delegates', once", ctx do
    for name <- ["app-unit-a", "app-unit-b"] do
      fields = [kind: "delegate", role: "delegate", status: "stopped", reason: "exited"]
      agent!(ctx, name, fields)
    end

    record = %{"status" => "rejected", "resetsAt" => @until, "rateLimitType" => "five_hour"}

    folds =
      for name <- ["app-unit-a", "app-unit-b"] do
        limit = %{api_error: "usage_limit_reached", user_message_uuids: ["b-" <> name]}
        %{session: "sid-" <> name, idle: true, last_result: limit, rate_limit: record}
      end

    Agent.update(ctx.world, &Map.put(&1, :folds, folds))

    Agent.update(
      ctx.world,
      &Map.put(&1, {:go_on, "app-unit-b"}, {:refused, {:status, "finished"}})
    )

    healer = healer!(ctx)
    assert settle(healer, ctx, "app-unit-a") == "idle"
    refute_received {:looked, _}

    past_reset!(ctx)
    assert settle(healer, ctx, "app-unit-a") == "word"
    key = "limit:app-unit-a:#{@until}"
    assert_received {:go_on, "app-unit-a", _text, ^key}
    assert settle(healer, ctx, "app-unit-a") == "word"
    refute_received {:go_on, "app-unit-a", _, _}
    refute_received {:word, _, _, _}
    refute_received {:resumed, _}

    assert step(ctx, "app-unit-b") == "prompt"
    assert limit(ctx, "app-unit-b")["why"] =~ "refused"
  end

  # Unchecked: a press refused as the screen moved reads it again; refused otherwise, it is a
  # person's, never pressed again in its state.
  test "a press refused is read again, or asked, never made twice", ctx do
    agent!(ctx, "app-epic")
    hit!(ctx, "app-epic", "a1")
    # A person answered the menu at the viewer just before the press.
    idle = {:ok, %{state: :idle, box: :empty}}
    refused = {:refused, {:screen, %{state: :idle}}}
    Agent.update(ctx.world, &Map.merge(&1, %{press: refused, after: idle}))
    healer = healer!(ctx)
    assert settle(healer, ctx, "app-epic") == "idle"
    assert_received {:pressed, "app-epic", @stop}
    refute_received {:pressed, _, _}

    # A new hit shows the menu again, with a press that fails for another reason.
    menu = {:ok, @menu}

    Agent.update(
      ctx.world,
      &Map.merge(&1, %{press: {:refused, :no_server}, screen: menu, after: menu})
    )

    hit!(ctx, "app-epic", "a2")
    assert settle(healer, ctx, "app-epic") == "prompt"
    assert_received {:pressed, "app-epic", @stop}
    refute_received {:pressed, _, _}
    assert limit(ctx, "app-epic")["why"] =~ "no_server"
  end

  # Limit.tla's Away and MoveAct, MoveOnce (F-191): a delegate whose reset is more than
  # `move_after` away, with another account that has room, moves once per limit: the claim on
  # its row first, the word stored and held, then the Mover's one move, which settles the claim.
  # A move refused is a person's prompt, never a second move; the word then goes at the reset.
  test "a delegate far from its reset moves once, its word first; a refused move is asked", ctx do
    far = 1_000_000 + 3 * 3600
    fields = [kind: "delegate"]
    agent!(ctx, "app-unit-m", fields)
    agent!(ctx, "app-unit-n", fields)
    hit!(ctx, "app-unit-m", "m1", until: far)
    hit!(ctx, "app-unit-n", "n1", until: far)
    screen!(ctx, {:ok, %{state: :idle, box: :empty}})
    refused = {:refused, {:none_usable, []}}

    Agent.update(
      ctx.world,
      &Map.merge(&1, %{:room => {:ok, "spare"}, {:move, "app-unit-n"} => refused})
    )

    healer = healer!(ctx)

    assert settle(healer, ctx, "app-unit-m") == "move"
    key = "limit:app-unit-m:#{far}"
    assert_received {:held, "app-unit-m", _text, ^key}
    assert_received {:move, "framework", "app-unit-m", "spare", id}
    assert %{"act" => ^id, "move_to" => "spare", "away" => ^far} = limit(ctx, "app-unit-m")

    assert {:ok, %{act: "move", actor: "limits:test", status: "claimed", state: state}} =
             Acts.get(ctx.acts, id)

    assert state =~ "limit_far:app-unit-m:#{far}"

    # The Mover takes the claim as its own and settles it once the agent runs there.
    assert {:ok, _} = Acts.acted(ctx.acts, id)
    assert {:ok, :verified} = Acts.answered(ctx.acts, id, {:ok, "spare"})
    assert settle(healer, ctx, "app-unit-m") == "moved"
    refute_received {:move, _, "app-unit-m", _, _}

    # The other's move was refused: a person's, and no second move after their "go on".
    assert step(ctx, "app-unit-n") == "prompt"
    assert_received {:move, "framework", "app-unit-n", "spare", _}
    assert limit(ctx, "app-unit-n")["why"] =~ "none_usable"
    assert {:ok, _} = Sessions.answer_limit(ctx.sessions, "app-unit-n", "limit", "go_on", "sam")
    assert settle(healer, ctx, "app-unit-n") == "idle"
    refute_received {:move, _, "app-unit-n", _, _}

    # At the reset its word is Delegates' under the same key, stored once.
    :counters.put(ctx.time, 1, far * 1000 + @margin)
    assert settle(healer, ctx, "app-unit-n") == "word"
    key = "limit:app-unit-n:#{far}"
    assert_received {:go_on, "app-unit-n", _, ^key}
  end

  # NeverMovesMain (F-191): a main far from its reset is never moved on the framework's own; its
  # `limit` prompt offers the move beside the wait, once per limit, and a person's answer moves
  # it, a claim of its own with the person named.
  test "a main far from its reset is asked, and moved only by a person's answer", ctx do
    far = 1_000_000 + 3 * 3600
    agent!(ctx, "app-epic")
    hit!(ctx, "app-epic", "a1", until: far)
    screen!(ctx, {:ok, %{state: :idle, box: :empty}})
    Agent.update(ctx.world, &Map.put(&1, :room, {:ok, "spare"}))
    healer = healer!(ctx)

    assert settle(healer, ctx, "app-epic") == "prompt"
    assert Sessions.Limit.options(limit(ctx, "app-epic")) == ~w(go_on move leave)
    refute_received {:move, _, _, _, _}

    # "Go on" before the reset waits: no second prompt for this limit.
    assert {:ok, _} = Sessions.answer_limit(ctx.sessions, "app-epic", "limit", "go_on", "sam")
    assert settle(healer, ctx, "app-epic") == "idle"

    # A later look at the same limit asks no more; a person's "move" from a prompt moves it.
    Sessions.put_limit(
      ctx.sessions,
      "app-epic",
      Map.put(limit(ctx, "app-epic"), "step", "prompt"),
      from: "idle"
    )

    assert {:ok, _} = Sessions.answer_limit(ctx.sessions, "app-epic", "limit", "move", "sam")
    assert settle(healer, ctx, "app-epic") == "move"
    key = "limit:app-epic:#{far}"
    assert_received {:word, "app-epic", _, ^key}
    assert_received {:move, "sam", "app-epic", "spare", id}
    assert {:ok, %{act: "move", detail: detail}} = Acts.get(ctx.acts, id)
    assert detail =~ "sam"
  end

  # The one shape: a kind off the list is asked in the Watch, and nothing acts.
  test "a press off the list is asked, never made", ctx do
    {:ok, _} = Watch.remedies(ctx.watch, {:revoke, "limit_menu", "sam"})
    agent!(ctx, "app-epic")
    hit!(ctx, "app-epic", "a1")
    healer = healer!(ctx)

    assert settle(healer, ctx, "app-epic") == "press"
    refute_received {:pressed, _, _}

    assert {:ok, [%{kind: "limit_menu", reason: "not_on_list"}]} =
             Watch.read(ctx.watch, status: "asked")
  end
end
