defmodule CodingAgentFramework.Limits do
  @moduledoc """
  The healer of a usage limit (F-186; `docs/design.md`, "Usage limits" and "Metrics and
  healing"; `model/tla/Limit.tla`, which this is built against, action by action): each agent's
  limit read onto its row, and the remedies of its phases, each on the one shape of every
  remedy.

  **The evidence.** An interactive agent's limit is its transcript's last limit line
  (`Transcripts`' fold's `limit`: the record, its uuid, and `followed`, a turn ran after it);
  a headless one's is its stream's last `result` with `api_error: "usage_limit_reached"` and
  the stream's `rate_limit_event` (`Stream`'s fold). `StopFailure` is no record (F-181's
  new-1): its rows in `Intake`, and the `Notification` rows of `quota_auto_resume_*`, are cues
  to read the screen again, which is what this acts on. An agent whose evidence is unread
  decides nothing (`Limit.tla`'s `Current`: every act is decided on the newest record).

  **The row.** `Sessions` writes the row (`Sessions.put_limit/4`, from the step this read, so
  a person's answer taken meanwhile wins), and the field is `Sessions.Limit`'s. Per agent:

  - `Read`: a record newer than the row's, no turn run after it: the row is `limited` until the
    record's reset, its step `look`; a step `unknown` or `prompt` stays, so a record read late
    never makes a press go again or closes a person's prompt;
  - `Continued`: a turn ran after the row's record: the limit clears, its counts kept
    (`Sessions.Limit.cleared/1`); `Ended`: a turn ended by itself after it, and the counts go;
  - `look`: the screen read (`look:`). Claude Code's own wait is `own`; the menu is `press` of
    its stop, found by its label, or `credits` where the record says the account can spend (a
    `usage_credits` prompt whose default at its deadline, `credits:` ms, is the stop); an ended
    turn, a gone process or a headless one is `idle`;
  - `own`: watched. The wait ended with no turn is `look` again (the menu's stop); the wait still
    shown at the reset plus the margin (`margin:` ms) is a `limit` prompt. Nothing is typed;
  - `press` (`limit_menu`, remedy `press_stop`): claimed, then `Sessions.press_limit/4`, the
    `Inlet`'s checked press. Sent is `idle`; refused as the screen moved, `look`, and refused
    otherwise, a `limit` prompt; unknown, `unknown`, never pressed again, and the menu still
    shown after it is a `limit` prompt;
  - `idle`: at the reset plus the margin, `send`, the go-on counted once per limit; past
    `bound:` go-ons in a row that each hit a limit again, a `limit` prompt in place of it;
  - `send` (`limit_reset`, remedy `go_on`): claimed, then the word stored through `Mailbox`
    under `limit:<agent>:<until>` (`word:`), so it is stored once per limit; a process that is
    gone is resumed then (`resume:`, a main's through `Mains`, under its lease), its first due
    row the word. A delegate's word is `Delegates`' (`go_on:`, F-186's new-1; an interactive
    one's too, F-187's new-2): its limited turn was not its report, the word is its word to go
    on, whose turn's reply is, and a gone process is resumed with it under its start's lease,
    not counted as the resume after a kill. Then `word`, until a turn shows;
  - before the reset, `idle` or `own` with the reset more than `move_after:` away and another
    account with room (`room:`), once per limit (`Limit.tla`'s Away, F-191): a delegate's
    move (`limit_far`, remedy `move`), claimed, the step `move` with its act on the row, the
    word to go on stored first under the limit's key and held (`go_on:` with `resume: false`,
    or `word:`), then `move:`, the `Mover`'s one move, which takes the claim as its own. A
    main's is the `limit` prompt, offering the move (`move_to`) beside the wait and the leave;
    only a person's answer moves it, a claim of its own. The move's row in `Acts`, read once
    the row no longer moves, makes the step `moved`; refused, failed, unknown or cut by a
    restart, it is the `limit` prompt, never a second move; the word then goes at the reset.

  **On the one shape** (F-182), as `CodingAgentFramework.AbsentMains` is: each limit is the
  symptom `limited`, shown only (state `limited:<agent>:<until>`), and each act's phase its own
  kind with state `<kind>:<agent>:<until>`, recorded in the `Watch` first; a kind off the list
  or past its cap is asked (`Watch.ask/4`), and the act waits; else it is claimed in `Acts`
  under this healer's actor, acts once, and its answer settles the claim. A press after a
  person's "go on" is a new claim (the row's `menu`). Where `Limit.tla` names the person's
  prompt for an outcome (an unknown press, a word refused, a claim a restart cut), that is the
  `limit` prompt on the row, not a `remedy` one, so a person is asked once. A person's answer
  of a `usage_credits` prompt is pressed as theirs, whatever the list says.

  The embedding app's tree starts one per host, after `Sessions`, `Mailbox` and `Watch`. It
  checks at start, at each cue `reads/0` names, at each row's next reset plus the margin or
  deadline, or by `check/2`.
  """

  use GenServer

  require Logger

  alias CodingAgentFramework.{Acts, Sessions, Watch}
  alias CodingAgentFramework.Sessions.{Agents, Limit}
  alias CodingAgentFramework.Usage.Limit, as: Record

  @margin 120_000
  @credits 600_000
  @bound 3
  @move_after 7_200_000
  @timeout 60_000
  @limit_api "usage_limit_reached"
  # One text for every agent (F-187's new-3): true whether it moved or waited for the reset.
  @word "Your turn stopped at a usage limit. Go on with your task from where it stopped."

  @doc """
  Starts the healer. Options: `agents:` (a `Sessions.Agents` reader), `sessions:`, `acts:`,
  `watch:`, `host:` (its actor, `limits:<host>`), and the functions it reads and acts by:

  - `transcripts:`, account -> `Transcripts.rows/3`'s answer;
  - `folds:`, `-> {:ok, %{rows: folds}}`, `Stream.rows/2`'s;
  - `look:`, agent row -> `Inlet.look/4`'s answer for its pane;
  - `word:`, `(name, text, key) ->` `Mailbox.notify/4`'s answer;
  - `resume:`, agent row -> an outcome, or `:none` where nothing resumes it (default);
  - `go_on:`, `(name, text, key, opts) ->` an outcome, a headless delegate's word in place of
    `word:` and `resume:` (`Delegates.go_on/5`; `resume: false` stores it with no resume, before
    a move; refused `:no_delegates` by default);
  - `press:`, `(name, label) ->` an outcome, by default `Sessions.press_limit/4`;
  - `room:`, agent row -> `{:ok, account}`, the account a move would go to now, or why none
    (`Mover.room/2`; refused `:no_mover` by default, so nothing moves);
  - `move:`, `(actor, name, to, act) ->` `Mover.move/4`'s answer, with the claim `act` made
    here (refused `:no_mover` by default).

  Optionally `margin:` (ms past the reset, default 2 min: Claude Code's own wait went on 50 s
  after it, F-181), `credits:` (the `usage_credits` prompt's deadline, ms, default 10 min),
  `bound:` (go-ons in a row, default 3), `move_after:` (ms: a reset further away than this is
  moved from, default 2 h) and `clock:` (ms).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Reads every agent's limit and takes each row's next step. Answers `{:ok, %{acted: ids}}`, the
  rows in `Acts` it claimed, or the `Watch`'s refusal or unknown.
  """
  @spec check(GenServer.server(), keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def check(healer, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    GenServer.call(healer, :check, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_healer}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @timeout)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @doc "Asks for a check without waiting for it. Answers `:ok` at once."
  @spec cue(pid, map) :: :ok
  def cue(healer, _cue \\ %{}) do
    send(healer, :check)
    :ok
  end

  @doc """
  What it reads, for `Cues`: the agent rows, the transcripts and streams (the records), `Intake`
  (a `StopFailure`, a `quota_auto_resume_*`, a waiter held at a turn's end: the screen to read
  again) and the `Watch`.
  """
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(sessions transcripts stream intake watch), cue: &cue/2}

  @doc """
  The newest limit record of an agent, from what was read of it (pure): `%{rec, after?,
  ended?}`, `rec` nil or `%{line, until, window, spend}`; `after?` a turn ran after the record;
  `ended?` a turn ended by itself after it. Nil when nothing was read of the agent.

      iex> t = %{limit: %{record: %{"status" => "rejected", "resetsAt" => 1_800_000_000,
      ...>   "rateLimitType" => "five_hour"}, uuid: "a1", followed: false}, ends_with_reply: false}
      iex> CodingAgentFramework.Limits.evidence(%{role: "parent"}, t)
      %{rec: %{line: "a1", until: 1_800_000_000, window: "five_hour", spend: false},
        after?: false, ended?: false}
  """
  @spec evidence(map, map | nil) :: map | nil
  def evidence(_row, nil), do: nil

  def evidence(%{role: "delegate"}, fold) do
    result = fold[:last_result]

    case result && result[:api_error] == @limit_api && Record.parse(fold[:rate_limit]) do
      {:ok, r} ->
        line = "stream:" <> Enum.join(result[:user_message_uuids] || [], ",")
        %{rec: rec(line, r), after?: fold[:idle] == false, ended?: false}

      _ ->
        %{rec: nil, after?: true, ended?: fold[:idle] == true and result != nil}
    end
  end

  def evidence(_row, transcript) do
    case transcript[:limit] do
      %{record: record, uuid: uuid} = line ->
        case Record.parse(record) do
          {:ok, r} ->
            followed = line[:followed] == true
            %{rec: rec(uuid, r), after?: followed, ended?: followed and ended?(transcript)}

          _ ->
            nil
        end

      _ ->
        %{rec: nil, after?: false, ended?: ended?(transcript)}
    end
  end

  defp ended?(transcript), do: transcript[:ends_with_reply] == true

  defp rec(line, r),
    do: %{line: line, until: r.limited_until, window: r.window, spend: r.can_spend}

  @impl true
  def init(opts) do
    sessions = Keyword.fetch!(opts, :sessions)

    s = %{
      agents: Keyword.fetch!(opts, :agents),
      sessions: sessions,
      acts: Keyword.fetch!(opts, :acts),
      watch: Keyword.fetch!(opts, :watch),
      transcripts: Keyword.fetch!(opts, :transcripts),
      folds: Keyword.fetch!(opts, :folds),
      look: Keyword.fetch!(opts, :look),
      word: Keyword.fetch!(opts, :word),
      resume: Keyword.get(opts, :resume, fn _row -> :none end),
      go_on: Keyword.get(opts, :go_on, fn _, _, _, _ -> {:refused, :no_delegates} end),
      press: Keyword.get(opts, :press, &Sessions.press_limit(sessions, &1, &2)),
      room: Keyword.get(opts, :room, fn _row -> {:refused, :no_mover} end),
      move: Keyword.get(opts, :move, fn _, _, _, _ -> {:refused, :no_mover} end),
      move_after: Keyword.get(opts, :move_after, @move_after),
      actor: "limits:#{Keyword.fetch!(opts, :host)}",
      margin: Keyword.get(opts, :margin, @margin),
      credits: Keyword.get(opts, :credits, @credits),
      bound: Keyword.get(opts, :bound, @bound),
      clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
      timer: nil
    }

    # A claim this actor wrote, or a person's it took (F-192), and did not settle: its act may have gone. A press is never
    # made again, and a word cut is a person's (`Limit.tla`'s Restart, Heal.tla's Ask).
    case Acts.interrupt(s.acts, s.actor) do
      {:ok, cut} ->
        for id <- cut, {:ok, row} <- [Acts.get(s.acts, id)], do: cut_by_restart(s, row)
        send(self(), :check)
        {:ok, s}

      {_, reason} ->
        {:stop, reason}
    end
  end

  defp cut_by_restart(s, %{target: name, act: act}) do
    with %{} = row <- Agents.get(s.agents, name),
         %{} = l <- Agents.limit(row) do
      case act do
        "press_stop" ->
          put(s, name, l, %{"step" => "unknown"})

        "go_on" ->
          put(s, name, l, %{"step" => "prompt", "why" => "its word was cut by a restart"})

        # A move claimed and never begun (`Limit.tla`'s Restart): a person's, never a second.
        "move" ->
          put(s, name, l, %{"step" => "prompt", "why" => "its move was cut by a restart"})

        _ ->
          nil
      end
    end
  end

  @impl true
  def handle_call(:check, _from, s) do
    {reply, s} = check_now(s)
    {:reply, reply, s}
  end

  @impl true
  def handle_info(:check, s), do: {:noreply, elem(check_now(s), 1)}

  defp check_now(s) do
    case Watch.remedies(s.watch, :list) do
      {:ok, list} ->
        rows = Enum.filter(Agents.rows(s.agents), &healed?/1)
        read = reads(s, rows)

        acted =
          for row <- rows,
              id <- List.wrap(heal(s, list, row, read[row.name])),
              is_integer(id),
              do: id

        rows = Enum.filter(Agents.rows(s.agents), &healed?/1)
        pass(s, rows)
        {{:ok, %{acted: acted}}, wake(s, rows)}

      other ->
        {other, s}
    end
  end

  # The agents a limit may hold: running, or gone by themselves or by a move of their limit
  # (F-191: one that failed leaves its process gone), and not moving.
  defp healed?(row) do
    row.kind in ["main", "delegate"] and row.move == nil and
      (row.status == "running" or
         (row.status == "stopped" and (row.reason == "exited" or moved_from?(row))))
  end

  defp moved_from?(row), do: is_integer((Agents.limit(row) || %{})["act"])

  # What was read of each agent: its transcript's row, or its stream's fold.
  defp reads(s, rows) do
    folds =
      case s.folds.() do
        {:ok, %{rows: folds}} -> Map.new(folds, &{&1.session, &1})
        _ -> %{}
      end

    transcripts =
      for account <- rows |> Enum.map(& &1.account) |> Enum.uniq(),
          {:ok, %{rows: ts}} <- [s.transcripts.(account)],
          t <- ts,
          into: %{},
          do: {{account, t.session_id}, t}

    Map.new(rows, fn row ->
      read =
        if Agents.headless?(row),
          do: folds[row.session_id],
          else: transcripts[{row.account, row.session_id}]

      {row.name, evidence(row, read)}
    end)
  end

  defp heal(_s, _list, _row, nil), do: nil

  defp heal(s, list, row, ev) do
    field = Limit.of(row)
    cur = Agents.limit(row)

    cond do
      # Read: a newer record, no turn after it.
      ev.rec != nil and ev.rec.line != (cur && cur["line"]) and not ev.after? ->
        read_limit(s, row, cur, field, ev.rec)

      # Continued: a turn ran after the row's record.
      cur != nil and ev.after? and (ev.rec == nil or ev.rec.line == cur["line"]) ->
        Sessions.put_limit(s.sessions, row.name, Limit.cleared(cur), from: cur["step"])
        nil

      # Ended: the go-ons in a row end with a turn that ended by itself.
      cur == nil and field != nil and ev.ended? ->
        Sessions.put_limit(s.sessions, row.name, nil, from: nil)
        nil

      cur != nil ->
        record_limited(s, row, cur)
        step(s, list, row, cur)

      true ->
        nil
    end
  end

  defp read_limit(s, row, cur, field, rec) do
    kept = Map.take(field || %{}, ~w(goes noted))
    stays = Limit.step(cur) in ["unknown", "prompt"]

    limit =
      Map.merge(kept, %{
        "until" => rec.until,
        "window" => rec.window,
        "line" => rec.line,
        "spend" => rec.spend,
        "step" => if(stays, do: cur["step"], else: "look")
      })

    limit = if stays, do: Map.merge(cur, limit), else: limit
    Sessions.put_limit(s.sessions, row.name, limit, from: Limit.step(cur))
    record_limited(s, row, limit)
    nil
  end

  # The symptom `limited`, shown only: the agent's limit with its window, since the read.
  defp record_limited(s, row, l) do
    Watch.record(s.watch, %{
      kind: "limited",
      target: row.name,
      state: key("limited", row, l),
      source: s.actor,
      since: now(s),
      evidence: %{account: row.account, window: l["window"], until: l["until"], line: l["line"]}
    })
  end

  defp step(s, list, row, %{"step" => "look"} = l), do: look(s, list, row, l)

  # Limit.tla's CreditsDefault and CreditsGone: the stop at the deadline, as the framework's;
  # the menu gone first (a person at the viewer, an exit), the screen read again.
  defp step(s, _list, row, %{"step" => "credits"} = l) do
    if now(s) >= (l["deadline"] || 0) do
      stop = Limit.stop_label(l["options"] || [])
      put(s, row.name, l, %{"step" => "press", "label" => stop, "by" => nil})
    else
      case screen(s, row) do
        :unread -> nil
        shown -> unless menu?(shown), do: put(s, row.name, l, %{"step" => "look"})
      end
    end
  end

  defp step(s, list, row, %{"step" => "press"} = l), do: press(s, list, row, l)

  defp step(s, _list, row, %{"step" => "unknown"} = l) do
    case screen(s, row) do
      :unread ->
        nil

      shown ->
        if menu?(shown),
          do: ask(s, row, l, "a press whose outcome is unknown, and the menu still shown"),
          else: put(s, row.name, l, %{"step" => "look"})
    end
  end

  defp step(s, list, row, %{"step" => "own"} = l) do
    case screen(s, row) do
      %{state: :usage_limit_wait} ->
        if due?(s, l),
          do: ask(s, row, l, "Claude Code's own wait still shown past the reset"),
          else: away(s, list, row, l)

      %{state: :running} ->
        nil

      :unread ->
        if Agents.running?(row), do: nil, else: put(s, row.name, l, %{"step" => "look"})

      _ended ->
        put(s, row.name, l, %{"step" => "look"})
    end
  end

  defp step(s, list, row, %{"step" => "idle"} = l) do
    goes = l["goes"] || 0

    cond do
      not due?(s, l) ->
        away(s, list, row, l)

      goes >= s.bound ->
        ask(s, row, l, "#{goes} go-ons in a row each hit a limit again")

      true ->
        goes = if l["noted"] != l["until"], do: goes + 1, else: goes
        put(s, row.name, l, %{"step" => "send", "goes" => goes, "noted" => l["until"]})
    end
  end

  defp step(s, list, row, %{"step" => "send"} = l), do: send_word(s, list, row, l)
  defp step(s, _list, row, %{"step" => "move"} = l), do: move(s, row, l)
  defp step(_s, _list, _row, _waits), do: nil

  # Limit.tla's Away, before the reset: a reset more than `move_after:` away and another
  # account with room (`room:`), once per limit (the row's `away`). A delegate moves on its
  # own: the remedy `move` of kind `limit_far`, on the list and within its cap, claimed first.
  # A main never does: its `limit` prompt opens, offering the move beside the wait.
  defp away(s, list, row, l) do
    with true <- l["away"] != l["until"],
         true <- l["until"] * 1000 - now(s) > s.move_after,
         {:ok, to} <- s.room.(row) do
      if row.kind == "main",
        do:
          ask(s, row, l, "its limit resets in more than #{div(s.move_after, 60_000)} min", %{
            "away" => l["until"],
            "move_to" => to
          }),
        else: own_move(s, list, row, l, to)
    else
      _near_or_no_room -> nil
    end
  end

  defp own_move(s, list, row, l, to) do
    state = key("limit_far", row, l)

    # The healer's own, or a person's `act` on a state asked for its bound (F-190), as in
    # `send_word/4`.
    with {:ok, sym, actor} <- symptom(s, "limit_far", row, state, l),
         :go <- if(actor == s.actor, do: may_act(s, list, "limit_far", sym), else: :go),
         {:ok, id} <-
           Acts.claim(
             s.acts,
             actor,
             row.name,
             state,
             :move,
             [detail: %{to: to}] ++ healer(s, actor)
           ) do
      l = Map.merge(l, %{"away" => l["until"], "move_to" => to})
      claimed_move(s, id, row, l, if(actor == s.actor, do: "framework", else: actor))
    else
      _shown_asked_or_claimed -> nil
    end
  end

  # Limit.tla's MoveAct, once the claim is on the row: a person's answer is claimed here, as
  # theirs, a new act each time (`menu`); the framework's was claimed by `own_move/5`. Then the
  # move's end, read from its row in `Acts` once the row is no longer moving.
  defp move(s, row, %{"act" => id} = l) when is_integer(id) do
    case Acts.get(s.acts, id) do
      {:ok, %{status: "settled", outcome: "verified"}} ->
        put(s, row.name, l, %{"step" => "moved"})

      {:ok, %{status: status} = act} when status in ["settled", "interrupted"] ->
        ask(s, row, l, "its move did not go: #{act.outcome || status} #{act.reason || ""}")

      _open_or_unread ->
        nil
    end
  end

  defp move(s, row, l) do
    by = l["by"] || "framework"
    claim = %{state: key("limit_far", row, l), by: by, menu: l["menu"] || 0}
    detail = %{to: l["move_to"], by: by}

    case Acts.claim(s.acts, s.actor, row.name, claim, :move, detail: detail) do
      {:ok, id} -> claimed_move(s, id, row, l, by)
      _claimed -> ask(s, row, l, "its move could not be claimed")
    end
  end

  # The claim on the row first, then the word to go on stored, so the move's resume carries it
  # as its first row (F-191, `Move.tla`'s WordStored), then the `Mover`. A refusal or an unknown
  # answer is the `limit` prompt, never a second move.
  defp claimed_move(s, id, row, l, by) do
    l = Map.merge(l, %{"step" => "move", "act" => id})

    with {:ok, _} <-
           Sessions.put_limit(s.sessions, row.name, l, from: Limit.step(Agents.limit(row))),
         {:ok, _} <- held_word(s, row, l) do
      case s.move.(by, row.name, l["move_to"], id) do
        {:ok, _} ->
          id

        {_refused_or_unknown, why} ->
          ask(s, row, l, "its move was not begun: #{inspect(why)}")
          id
      end
    else
      not_stored ->
        Acts.settle(s.acts, id, :failed, reason: {:word, not_stored})
        ask(s, row, l, "its word to go on was not stored: #{inspect(not_stored)}")
        id
    end
  end

  # The word to go on, stored before the move under the limit's key, held while the agent is
  # limited: a headless delegate's as `Delegates`' word (no resume of its own), any other as a
  # notice through `Mailbox`.
  defp held_word(s, row, l) do
    key = "limit:#{row.name}:#{l["until"]}"

    if delegate?(row),
      do: s.go_on.(row.name, @word, key, resume: false),
      else: s.word.(row.name, @word, key)
  end

  # Limit.tla's Look: the screen as it is now decides the phase.
  defp look(s, _list, row, l) do
    if Agents.headless?(row) or not Agents.running?(row) do
      put(s, row.name, l, %{"step" => "idle"})
    else
      case screen(s, row) do
        %{state: :usage_limit_wait} ->
          put(s, row.name, l, %{"step" => "own"})

        %{state: :dialog, kind: :usage_limit_menu, options: options} ->
          menu(s, row, l, options)

        %{state: state} when state in [:idle, :exited] ->
          put(s, row.name, l, %{"step" => "idle"})

        _running_or_unread ->
          nil
      end
    end
  end

  defp menu(s, row, l, options) do
    stop = Limit.stop_label(options)

    cond do
      stop == nil ->
        ask(s, row, l, "the menu shows no option to stop and wait")

      l["spend"] == true ->
        put(s, row.name, l, %{
          "step" => "credits",
          "options" => options,
          "deadline" => now(s) + s.credits
        })

      true ->
        put(s, row.name, l, %{
          "step" => "press",
          "label" => stop,
          "options" => options,
          "by" => nil
        })
    end
  end

  # Limit.tla's Press, on the one shape: a person's answer is pressed as theirs; the
  # framework's own press is the remedy `press_stop`, on the list and within its cap.
  defp press(s, list, row, l) do
    state = key("limit_menu", row, l)
    # Each record's menu, and each person's clear of a press, is a new state to claim.
    claim = %{state: state, line: l["line"], menu: l["menu"] || 0}

    with {:go, actor} <-
           if(is_binary(l["by"]), do: {:go, s.actor}, else: own_press(s, list, row, state, l)),
         {:ok, id} <-
           Acts.claim(
             s.acts,
             actor,
             row.name,
             claim,
             :press_stop,
             [detail: by(l)] ++ healer(s, actor)
           ) do
      case s.press.(row.name, l["label"]) do
        {:ok, _} ->
          Acts.settle(s.acts, id, :recovered, answer: "sent", acted: true)
          put(s, row.name, l, %{"step" => "idle"})

        # The screen moved first (a person at the viewer): read again, as Limit.tla's Press.
        {:refused, {:screen, _} = why} ->
          Acts.settle(s.acts, id, :failed, reason: {:refused, why})
          put(s, row.name, l, %{"step" => "look"})

        # Any other refusal pressed nothing, and its state is claimed: a person's (Heal's Ask).
        {:refused, why} ->
          Acts.settle(s.acts, id, :failed, reason: {:refused, why})
          ask(s, row, l, "its press was refused: #{inspect(why)}")

        {_unknown, why} ->
          Acts.settle(s.acts, id, :unknown, reason: {:unknown, why}, acted: true)
          put(s, row.name, l, %{"step" => "unknown"})
      end

      id
    else
      _shown_asked_or_claimed -> nil
    end
  end

  defp own_press(s, list, row, state, l) do
    with {:ok, sym, actor} <- symptom(s, "limit_menu", row, state, l),
         :go <- if(actor == s.actor, do: may_act(s, list, "limit_menu", sym), else: :go),
         do: {:go, actor}
  end

  # Limit.tla's Send: the word stored once under its key, a gone process resumed with it.
  defp send_word(s, list, row, l) do
    state = key("limit_reset", row, l)

    with {:ok, sym, actor} <- symptom(s, "limit_reset", row, state, l),
         :go <- if(actor == s.actor, do: may_act(s, list, "limit_reset", sym), else: :go),
         {:ok, id} <- Acts.claim(s.acts, actor, row.name, state, :go_on, healer(s, actor)) do
      key = "limit:#{row.name}:#{l["until"]}"
      if delegate?(row), do: delegate_word(s, id, row, l, key), else: own_word(s, id, row, l, key)
      id
    else
      _shown_asked_or_claimed -> nil
    end
  end

  # A delegate's word is `Delegates`' (F-186's new-1; an interactive one's too, F-187's new-2):
  # it stores the word as the delegate's word to go on, whose turn's reply is its report, and
  # resumes a gone process with it under its start's lease, not as the resume after a kill.
  defp delegate?(row), do: row.kind == "delegate"

  defp delegate_word(s, id, row, l, key) do
    case s.go_on.(row.name, @word, key, []) do
      {:ok, answer} ->
        Acts.settle(s.acts, id, :recovered, answer: inspect(answer), acted: true)
        put(s, row.name, l, %{"step" => "word"})

      {:refused, why} ->
        Acts.settle(s.acts, id, :failed, reason: {:refused, why}, acted: true)
        ask(s, row, l, "its word to go on was refused: #{inspect(why)}")

      {_unknown, why} ->
        Acts.settle(s.acts, id, :unknown, reason: {:unknown, why}, acted: true)
        ask(s, row, l, "its word's outcome is unknown")
    end
  end

  defp own_word(s, id, row, l, key) do
    case s.word.(row.name, @word, key) do
      {:ok, stored} ->
        resumed = if Agents.running?(row), do: :none, else: s.resume.(row)

        case resumed do
          {:unknown, why} ->
            Acts.settle(s.acts, id, :unknown, reason: {:resume, why}, acted: true)
            ask(s, row, l, "its resume's outcome is unknown")

          {:refused, why} ->
            Acts.settle(s.acts, id, :failed, reason: {:resume, why}, acted: true)
            ask(s, row, l, "its resume was refused: #{inspect(why)}")

          _ok_or_none ->
            Acts.settle(s.acts, id, :recovered, answer: inspect(stored), acted: true)
            put(s, row.name, l, %{"step" => "word"})
        end

      {:refused, why} ->
        Acts.settle(s.acts, id, :failed, reason: {:refused, why})
        ask(s, row, l, "its word was refused: #{inspect(why)}")

      {_unknown, why} ->
        Acts.settle(s.acts, id, :unknown, reason: {:unknown, why}, acted: true)
        ask(s, row, l, "its word's outcome is unknown")
    end
  end

  defp symptom(s, kind, row, state, l) do
    sym = %{
      kind: kind,
      target: row.name,
      state: state,
      source: s.actor,
      since: now(s),
      evidence: %{until: l["until"], window: l["window"], step: l["step"]}
    }

    # The healer's own, or for a state asked for its bound that a person answered `act`
    # (F-189's new-7), that person's, once: `Acts`' claim on the state lets one in.
    recorded = Watch.record(s.watch, sym)

    case Watch.acting(recorded, s.actor) do
      nil -> {:shown, recorded}
      actor -> {:ok, sym, actor}
    end
  end

  # The list's entry and its cap, a fold of this healer's rows of that remedy in the bound.
  defp may_act(s, list, kind, sym) do
    case list[kind] do
      %{remedy: remedy, allowed: true, cap: cap, bound: bound} when is_binary(remedy) ->
        from = now(s) - bound

        case Acts.rows(s.acts, actor: s.actor, act: remedy, since: from) do
          {:ok, rows} ->
            if Enum.count(rows, &(&1.claimed_at >= from)) >= cap,
              do: watch_ask(s, sym, {:cap, cap, bound}),
              else: :go

          _unread ->
            :wait
        end

      %{remedy: remedy} when is_binary(remedy) ->
        watch_ask(s, sym, :not_on_list)

      _none ->
        :wait
    end
  end

  defp watch_ask(s, sym, why) do
    Watch.ask(s.watch, Map.take(sym, [:kind, :target, :state]), why)
    :asked
  end

  # The `limit` prompt on the row: a person's, with no deadline.
  defp ask(s, row, l, why, fields \\ %{}),
    do: put(s, row.name, l, Map.merge(%{"step" => "prompt", "why" => why}, fields))

  # A phase written from the step this check read; a person's answer meanwhile wins.
  defp put(s, name, l, fields) do
    case Sessions.put_limit(s.sessions, name, Map.merge(l, fields), from: l["step"]) do
      {:ok, _} ->
        nil

      other ->
        Logger.debug("limits: #{name} not moved to #{inspect(fields)}: #{inspect(other)}")
        nil
    end
  end

  # The states each kind reads now: one per agent's limit; the others pass.
  defp pass(s, rows) do
    limited = for row <- rows, l = Agents.limit(row), do: {row, l}

    for kind <- ~w(limited limit_menu limit_reset limit_far) do
      present = %{
        targets: Enum.map(limited, fn {row, _} -> row.name end),
        states: Enum.map(limited, fn {row, l} -> key(kind, row, l) end)
      }

      Watch.pass(s.watch, {s.actor, kind}, present)
    end
  end

  # One timer, to the earliest reset plus the margin or deadline still to come.
  defp wake(s, rows) do
    if s.timer, do: Process.cancel_timer(s.timer)
    now = now(s)

    times =
      for row <- rows,
          l = Agents.limit(row),
          at = at(s, l),
          at > now,
          do: at

    timer = if times != [], do: Process.send_after(self(), :check, Enum.min(times) - now)
    %{s | timer: timer}
  end

  defp at(s, %{"step" => step} = l) when step in ["idle", "own"], do: l["until"] * 1000 + s.margin
  defp at(_s, %{"step" => "credits"} = l), do: l["deadline"]
  defp at(_s, _l), do: nil

  defp due?(s, l), do: now(s) >= l["until"] * 1000 + s.margin

  defp screen(s, row) do
    case s.look.(row) do
      {:ok, screen} -> screen
      _ -> :unread
    end
  end

  defp menu?(%{state: :dialog, kind: :usage_limit_menu}), do: true
  defp menu?(_), do: false

  defp by(%{"by" => by}) when is_binary(by), do: %{by: by}
  defp by(_), do: %{by: "framework"}

  # A person's claim names this healer, whose restart closes it if cut (F-192).
  defp healer(%{actor: actor}, actor), do: []
  defp healer(s, _person), do: [healer: s.actor]

  defp key(kind, row, l), do: "#{kind}:#{row.name}:#{l["until"]}"

  defp now(s), do: s.clock.()
end
