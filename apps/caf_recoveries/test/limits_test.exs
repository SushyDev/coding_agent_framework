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
      folds: fn -> {:ok, %{rows: []}} end,
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
