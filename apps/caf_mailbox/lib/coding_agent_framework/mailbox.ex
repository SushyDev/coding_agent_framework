defmodule CodingAgentFramework.Mailbox do
  @moduledoc """
  Every delivery (`docs/design.md`, "Delivery", "Agents working together", "Messages";
  `model/tla/Delivery.tla`): a message, the app's word, a delegate's brief and its word to go on
  after a resume, a reply, the framework's notice in a reply's place, and the report, which is
  the reply to the brief. Each is one row of `Mailbox.Table`, with one mark and one settle; only
  the transport differs (`Mailbox.Transport`). The caller's supervision tree starts one per
  host, with no name:

      {:ok, mailbox} = Mailbox.start_link(db: db, grants: grants, stream: stream,
        sessions_db: db, host: "laptop")
      Mailbox.message(mailbox, "app-main", "app-unit-review", "Rebase on main first.")
      #=> {:ok, {:queued, 1}}

  **Stored first.** A message is checked by `Grants.may_message?/3`, then stored `queued`
  before anything else. `Delegates` stores a delegate's brief (`brief/5`) before it starts it,
  the word to go on (`go_on/4`) before it resumes it, and its report (`report/5`) once its turn
  ended.

  **The mark.** Per addressee, while no row to it is `sending`, the first `queued` row (one made
  due again first, then the oldest) is marked `sending` with its transport and the process it
  is for, then handed on. A refusal undoes the mark; an unknown answer keeps it for the
  evidence. The hand-on runs in a task of its own, whose answer comes back as a message, so
  `message/5`, `status/3` and every other call answer while a write (a typed one takes seconds)
  runs; the row is `sending` meanwhile and no evidence settles it until the answer is in
  (`Delivery.tla`'s `hand`). The transport is the addressee's:

  - `stream`, for a headless delegate (its agent row, read through `Sessions.Agents`): only
    into an ended turn of its current process (`Stream`'s fold idle, live, no end marked, its
    agent row
    `running`), written through `Stream` under the row's uuid; the first row to a new process
    is marked before its start (`launch/4`, `via: :stream`) and written by the start right
    after its hold, since the process writes its init only after it read a line (F-152);
  - `call`, for a reply or a notice a waiting `run_delegate` takes (`await/4`), only before the
    call's deadline; `told/3` settles it, and the end of the process that waits makes it due
    again;
  - `waiter`, for an interactive session (any agent row not headless), when `Mailbox` was
    given `intake:`: only while its row is `running` and `Intake` holds a waiter for it, into
    an ended turn or queued by Claude Code into a running one, handed to `Intake.deliver/5`
    with the row's uuid on a last line (`Transport.Waiter`). `{:ok, :sent}` keeps the row
    `sending`: the session's transcript, read through `transcripts:` at the account's
    directory (`accounts:`), settles it, or `take_bound:` ms (10 s by default) with no line
    makes it due again. With no waiter its rows stay `queued`, `attempt` `:no_waiter`, until
    `Intake`'s waiter cue;
  - `typed`, for an interactive session with no waiter held, when `Mailbox` was given `inlet:`
    (with `registry:`, `transcripts:` and `accounts:`): only while its row is `running` and its
    session file reads idle, handed to `Inlet.type/4` as one line with the row's uuid at its end
    (`Transport.Typed`). The `Inlet` reads the turn again in its own step, with the screen as
    the session's recorded release draws it, and types only into an ended turn with an empty
    box. The transcript settles it, as a waiter's row. A row too long to type (more than one
    line, a control character, or longer than `Transport.Typed.short/0`) is written whole to
    `<home>/due/<agent>/<id>.md` (`Sessions.due_dir/2`, which each interactive start of the agent
    may read by `--add-dir`), and the line typed names that file in backticks, framed with the
    row's sender (`Transport.pointer_line/2`, `Transport.Typed.pointer/2`, F-172);
    the file goes once the row is delivered. A row whose line the `Inlet` refused anyway (the
    box narrower than the line), or one too long with no `home:`, is not typed again: it waits
    for a waiter (F-240, `Delivery.tla`'s `Wake` and `WaitBound`). With the session idle and no
    waiter held, the wake line, `[framework] a message is waiting for you.`, is typed once in
    its place, its mark (`woke_at`) written before its keys: that turn's end brings a waiter,
    which carries the row whole. `wait_bound:` ms (10 minutes by default) from the wake line's
    mark with no waiter, the row is `undelivered`, `attempt` `["wait_bound", refusal]`, never
    sent, and its sender gets a notice, ``undelivered: message <id> to <agent>, after <n> s``.
    Rows go in order per addressee, one in flight, so the rows behind it wait as long and no
    longer.

  - `launch` (F-137), for the first row to an interactive session's new process: marked by
    `launch/4` before the start that carries it as its prompt, told the start's answer by
    `launched/3` (refused, due again), and settled by the transcript's user line with its mark
    (`Transport.Launch`). A row longer than the workstation's argument carries
    (`ClaudeCLI.prompt_max/1`) is written to the agent's due directory as a typed row's is, and
    the prompt is one line naming that file (`Transport.Launch.pointer/2`, F-155).

  Without `intake:` or `inlet:` a main session's rows stay `queued`, `attempt` `:no_delivery`,
  unless a call takes them.

  While a move of the addressee is under way (`Sessions.Agents.moving?/1`, F-133), no row is
  marked by the stream or the waiter: its rows stay `queued` and go to the process the move
  resumes, and a waiter row is settled against the transcript of the account the agent row
  names, after the resume the copy. A waiting call still takes its answer, since the drain waits
  for it.

  While the addressee is `limited` and its usage limit's reset has not passed (F-185,
  `Sessions.Agents.unheld/2`, `Boxes.tla`'s `NoRowIntoLimit`), no row is marked either: a row
  handed in would start a turn into the limit. Once the reset passed, its turn is read as any
  row's, and its rows go into its ended turn.

  **Answers.** A delivered message's turn ends with a `result` that names its uuid; that
  result's text is stored as a reply from the delegate to the message's sender (to its parent,
  the sender of its brief, for a message from `framework`), `reply_to` the message's uuid, with
  the result's `subtype` and `is_error`. When the process ended during the message's turn with
  no result, a notice from `"framework"` says so in its place. The table's unique `reply_to`
  lets in one answer per row. The answers to a brief or a word to go on are `Delegates'`: it
  decides between a finish, a resume and a second kill, and hands the report here.

  **Asks.** An agent asks a person through `ask/4`: a row from it to the operator, kept for the
  app and never delivered, read by `open_asks/2` and `asked/3`. The app answers through
  `answer/4`: a row from the operator to the agent that asked, under the ask's uuid, delivered
  as any row is (`Team.tla`'s `Ask`, `Answers`). A person who dismisses the ask in the app
  withdraws it (`withdraw/4`, F-172): a row under the same key that tells the agent why, so an
  answer and a withdrawal race to one settle (`Prompt.tla`'s `AnswerNow`, `WithdrawNow`).

  **Ended.** Once a delegate's session ended for good (its `end_session` went in and its
  process is gone, or its agent row says it ended), or its start was refused (`ended/3`), its
  `queued` rows are settled `ended`.

  It reads every open row again at its start, at each `cue/2` (of `Stream`, `Sessions`,
  `Delegates`, `Transcripts` and `Intake`'s waiters, as `reads/0` declares; a waiter row's
  transcript only on the last two) and at a waiter row's take bound; after each write
  `notify` gets `%{topic: "mailbox", ids: [id]}`.
  """

  use GenServer

  alias CodingAgentFramework.{Accounts, Acts, Grants, Inlet, Intake, Registry, Sessions, Store}
  alias CodingAgentFramework.Stream
  alias CodingAgentFramework.{ClaudeCLI, Programs, Transcripts}
  alias CodingAgentFramework.Sessions.{Agents, Turn}
  alias CodingAgentFramework.Mailbox.{Ask, Table, Transport}
  alias CodingAgentFramework.Stream.Fold

  @step 5_000
  # The take bound (`docs/design.md`, "Delivery"): Claude Code 2.1.322 writes the `enqueue`
  # line within about a second of the waiter's answer (measured for F-127).
  @take_bound 10_000
  # The Inlet's typed write: its reads, the keys, and the box seen before the Enter.
  @inlet 10_000
  # How long a row the Inlet refused waits for a waiter (F-240): long enough for a person's turn
  # under way to end and start one. Not measured.
  @wait_bound 600_000
  # The wake line (F-240): typed once in a stuck row's place, so a turn starts and its end
  # brings a waiter. Short and fixed, well under any box.
  @wake "[framework] a message is waiting for you."
  # A typed command's: its reads, its keys, and its result line (F-233).
  @reload 15_000
  # The sender of a notice and of the words to go on; no agent has this name, as an agent's
  # name holds its project's.
  @framework "framework"

  @doc """
  Starts a `Mailbox`. Options: `db:`, `grants:`, `stream:` and `host:` (where the delegates
  run), `sessions_db:` (the file of `Sessions`' table, read through `Sessions.Agents`), and
  optionally `notify:`; for the
  waiter transport, `intake:` with `transcripts:` and `accounts:` (an `Accounts`), and
  `take_bound:` (ms, 10 000 by default); for the typed transport, `inlet:` with `registry:` (the
  host's `Registry`), `transcripts:` and `accounts:`, and `home:`, the framework home `Sessions`
  was given, whose due directories carry a row too long to type or to launch with, and
  `wait_bound:` (ms, 600 000 by default: how long a row the `Inlet` refused waits for a
  waiter); `os:`, the
  workstation's operating system (`Programs.os/1`, this VM's own by default), whose argument
  limit (`ClaudeCLI.prompt_max/1`) bounds a launch's prompt; `frame:`, a function that frames a
  row's text with its sender (`frame/1` by default, F-170); `acts:`, the instance's `Acts`,
  whose forced end of an agent settles its rows left `sending` at `Mailbox`'s own settle
  (F-172; without it only `ended_while_sending/3` settles them).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The topics of the cues it writes, each as its whole shape, `*` for a word it fills in
  (`CodingAgentFramework.Cues`): `mailbox`.
  """
  @spec writes() :: [String.t()]
  def writes, do: ~w(mailbox)

  @doc """
  The sender's frame on the text an agent reads (F-170): every row but a brief and a word to go
  on, which are the delegate's own first prompt, names whose it is, so a main session with
  several delegates always knows. `row` is `%{from: name, kind: kind, to: name, text: text}`:
  `kind` is `"message"`, `"reply"`, `"report"` (the answer to a brief), `"notice"` or
  `"answer"` (a person's answer to an ask), and `from` the agent the row is from, or for the
  framework's notice in a reply's or a report's place, the agent whose row it answers; and
  optionally `account`, the sender's account, which `Mailbox` reads from the sender's agent row
  (F-188's new-3), so an app that runs agents on several accounts needs no frame of its own. The
  frame is a first line of its own, `From <name> (<kind>):` or `From <name> on <account>
  (<kind>):`, or for a one-line text the start of that line, so a short typed row stays one
  line. An app's `frame:` answers the text in its
  place: a non-empty string, or the row is not handed on (`attempt` `{:bad, :frame}`). The
  delivery mark goes after the framed text, so each row is still settled by its own uuid line.

      iex> CodingAgentFramework.Mailbox.frame(%{from: "app-api", kind: "report", to: "app-main",
      ...>   text: "Done.\\nAll tests pass."})
      "From app-api (report):\\n\\nDone.\\nAll tests pass."
      iex> CodingAgentFramework.Mailbox.frame(%{from: "app-main", kind: "message", to: "app-api",
      ...>   text: "Rebase first."})
      "From app-main (message): Rebase first."
      iex> CodingAgentFramework.Mailbox.frame(%{from: "app-api", kind: "reply", to: "app-main",
      ...>   text: "Yes.", account: "work"})
      "From app-api on work (reply): Yes."
  """
  @spec frame(map) :: String.t()
  def frame(%{from: from, kind: kind, text: text} = row) do
    on = if is_binary(row[:account]), do: " on #{row.account}", else: ""
    label = "From #{from}#{on} (#{kind}):"
    if String.contains?(text, "\n"), do: label <> "\n\n" <> text, else: label <> " " <> text
  end

  @doc """
  Sends `text` from agent `from` to agent `to`: `{:ok, {:queued, id}}` once its row is stored,
  or `{:refused, reason}` with no row (`Grants`' reason, or `{:bad, :message}`).
  """
  def message(mailbox, from, to, text, opts \\ []),
    do: call(mailbox, {:message, from, to, text}, opts)

  @doc """
  Stores `text` as a message from `framework` to agent `to`, delivered as any message is: the
  embedding app's word to an agent, such as a job's late end. `to` must be an agent the tree
  holds (`Grants.may_use?/2`), not the operator. Option `:key`: a message stored under the same key before is
  not stored again, so a repeat of one event (a late end handed twice) is dropped. Option
  `:kind`: `:msg` (the default) or `:notice`, a word no turn answers, so the addressee's next
  result is never read as a reply to it: a delegate's turn of its own told to its parent
  (F-155); or `:prompt`, a notice from agent `from:` (an agent of the tree), that it waits on a
  person (F-179, `Prompts`): the addressee reads it as `From <from> (prompt): <text>`, and no
  turn answers it either. Answers `{:ok, {:queued, id}}`, `{:ok, :stored_before}`, or
  `{:refused, reason}` with no row (`{:bad, :kind}` for another kind).

      Mailbox.notify(mailbox, "app-main", "Job mcp-a-7 ended: exit 0.", key: "job:mcp-a-7")
      #=> {:ok, {:queued, 9}}
      Mailbox.notify(mailbox, "app-main", "waiting on a permission: Bash", key: "prompt:p",
        kind: :prompt, from: "app-unit")
      #=> {:ok, {:queued, 10}}
  """
  def notify(mailbox, to, text, opts \\ []) do
    {key, kind} = {Keyword.get(opts, :key), Keyword.get(opts, :kind, :msg)}
    call(mailbox, {:notify, to, text, key, kind, Keyword.get(opts, :from, @framework)}, opts)
  end

  @doc """
  Stores delegate `to`'s brief from its parent `from` under `uuid`, the uuid `Delegates` chose
  before its start: `{:ok, {:queued, id}}`, or `{:ok, :stored_before}` when a row of `uuid` is
  stored already. No `Grants` check: `Delegates` checked the start.

      Mailbox.brief(mailbox, "app-main", "app-unit-review", "Review it.", uuid)
      #=> {:ok, {:queued, 3}}
  """
  def brief(mailbox, from, to, text, uuid),
    do: store(mailbox, %{from: from, to: to, text: text, uuid: uuid, kind: "brief"})

  @doc """
  Stores the word a resumed delegate `to` gets to go on with its brief, from `framework`, under
  `uuid`: it goes before every other row due to `to`, as a resend does. Answers as `brief/5`.
  """
  def go_on(mailbox, to, text, uuid) do
    row = %{from: @framework, to: to, text: text, uuid: uuid, kind: "resume", again: true}
    store(mailbox, row)
  end

  @doc """
  Stores delegate `from`'s report to its parent `to`, as the answer to its brief's uuid `key`:
  `{:reply, text, result}` (a finish, from the delegate, with the result's `subtype` and
  `is_error`), or `{:notice, text}` (a second kill or a refused resume, from `framework`).
  Answers `{:ok, {:queued, id}}`, or `{:ok, :stored_before}` when `key` has an answer already.

      Mailbox.report(mailbox, "app-unit-review", "app-main", brief_uuid, {:reply, "Done.", %{}})
      #=> {:ok, {:queued, 5}}
  """
  def report(mailbox, from, to, key, answer) do
    row =
      case answer do
        {:reply, text, result} ->
          %{from: from, kind: "reply", text: text, subtype: result[:subtype]}
          |> Map.put(:is_error, result[:is_error])

        {:notice, text} ->
          %{from: @framework, kind: "notice", text: text}
      end

    store(mailbox, Map.merge(row, %{to: to, uuid: Stream.uuid(), reply_to: key}))
  end

  @doc """
  Marks the first `queued` row to interactive session `to` `sending` by `launch` (F-137,
  `Transport.Launch`): its text, with its uuid on a last line, is the prompt argument of the
  start or resume the caller makes next, which must end by `deadline` (wall-clock ms). The
  caller tells the start's answer with `launched/3`. Answers `{:ok, %{id, uuid, text}}`,
  `{:ok, :none}` when no row is due, or `{:refused, reason}` with nothing marked:
  `{:sending, ids}` while a row to `to` is in flight, `:no_transcripts` for a `Mailbox` with no
  waiter or typed transport, which settles none.

  With `via: :stream`, the row is the first line of a headless delegate's start (F-152): a
  headless process writes its `system`/`init` only after it read a line, so its start writes
  this row through `Stream` right after the hold, under the row's uuid, before it waits for the
  init. The row is marked `sending` by `stream`, its text as it is, and settles by the replay
  as any `stream` row (`Transport.Stream`); until the start's answer, and after a restart until
  `deadline`, a fold with no line of it decides nothing.

      Mailbox.launch(mailbox, "app-unit-review", deadline)
      #=> {:ok, %{id: 3, uuid: "…", text: "Review it.\\n\\n[delivery …]"}}
      Mailbox.launch(mailbox, "app-unit-review", deadline, via: :stream)
      #=> {:ok, %{id: 3, uuid: "…", text: "Review it."}}
  """
  def launch(mailbox, to, deadline, opts \\ []),
    do: call(mailbox, {:launch, to, deadline, Keyword.get(opts, :via, :launch)}, opts)

  @doc """
  The answer of the start `launch/4` marked row `id` for: `{:ok, %{session_id, pid}}` keeps it
  `sending` until the transcript shows its user line, or no process of the start runs, however
  long a startup dialog holds the first turn (F-153); `{:refused, _}` makes it due again, under
  its same uuid; `{:unknown, _}` keeps it as `{:ok, _}` does. Answers `{:ok, status}` or
  `{:refused, {:not_launched, status}}`.

  A `stream` row a headless start was handed (F-152) is settled by its session's fold from the
  answer on, whatever the answer: a start refused after its hold may have written the line,
  and one refused before holds none of it, so the fold makes it due again.
  """
  def launched(mailbox, id, answer), do: call(mailbox, {:launched, id, answer}, [])

  @doc """
  Delegate `to` will never take a row: its start was refused. Its `queued` rows are settled
  `ended`. Answers `{:ok, ids}`.
  """
  def ended(mailbox, to, opts \\ []), do: call(mailbox, {:ended, to}, opts)

  @doc """
  Agent `to`'s end was forced by the operator (F-170, `Delivery.tla`'s ForceSettled): each row
  still `sending` to it settles `unknown`, `attempt` `ended_while_sending`. `Mailbox` given
  `acts:` does the same at each of its own settles, for every ended agent whose forced end's row
  `Acts` holds (F-172), so a restart between the end and this call leaves no row `sending`. Its text may or may
  not have gone in, and no evidence will come: it is never due again, so never sent twice, and
  never counted delivered. A hand-on of it still under way answers into nothing. Only once no
  process of `to` may live (`Sessions.Agents.free?/1`): else `{:refused, {:not_free, status}}`,
  and nothing is settled. Answers `{:ok, ids}`, the rows it settled.

      Mailbox.ended_while_sending(mailbox, "app-epic")
      #=> {:ok, [7]}
  """
  def ended_while_sending(mailbox, to, opts \\ []),
    do: call(mailbox, {:ended_while_sending, to}, opts)

  @doc """
  The one row stored under `uuid` will never go in: the brief of a main session's start that
  was refused (`Mains`, F-143), while other rows to that name stay queued for its next start.
  A `queued` row is settled `ended`; answers `{:ok, :ended}`, `{:ok, status}` for a row already
  settled, or `{:refused, {:not_queued, status}}` for one in flight, or `{:refused,
  :no_message}`.

      Mailbox.settle_row(mailbox, "6f1c…")
      #=> {:ok, :ended}
  """
  def settle_row(mailbox, uuid, opts \\ []), do: call(mailbox, {:settle_row, uuid}, opts)

  @doc """
  Agent `from` asks a person (`docs/design.md`, `ask`; `Team.tla`'s `Ask`), with `questions`
  as `Mailbox.Ask.questions/1` checks them. The ask is a row from `from` to the operator, kept
  for the app as a reply to the operator is, and never delivered: nothing waits on it. Answers
  at once `{:ok, {:asked, id}}`, or `{:refused, reason}` with no row: `Grants`' reason,
  `:no_operator`, `{:not_an_agent, from}` for the operator itself, or `{:bad, :questions}`.

      Mailbox.ask(mailbox, "app-unit-review", [question])
      #=> {:ok, {:asked, 12}}
  """
  def ask(mailbox, from, questions, opts \\ []),
    do: call(mailbox, {:ask, from, questions}, opts)

  @doc "The asks not answered yet, oldest first: `{:ok, asks}`, each as `asked/3` shows one."
  def open_asks(mailbox, opts \\ []), do: call(mailbox, :open_asks, opts)

  @doc """
  Ask `id`, for the app: `{:ok, %{id, from, questions, asked_at, answer}}`, `answer` nil until
  it is settled, then `%{id, kind, text, status, answers}`: `kind` `answer` or `withdrawn`
  (`withdraw/4`), the text the agent gets, its row's status (`queued`, `sending`, `delivered`,
  or `ended` when the agent ended first) and the answers as `answer/4` took them, labels and
  text (nil for a withdrawal, and for an answer an earlier build stored); or `{:refused,
  :no_ask}`.
  """
  def asked(mailbox, id, opts \\ []), do: call(mailbox, {:asked, id}, opts)

  @doc """
  The person's answer to ask `ask_id` (`Team.tla`'s `Answers`): one entry per question, in
  order, each `%{"labels" => [label], "text" => text}` as `Mailbox.Ask.answers/2` checks it. It
  is stored as a row from the operator to the agent that asked, under the ask's uuid, and
  delivered as any row is, one line per question, so an idle agent wakes to it; to an agent that
  ended first it is stored and settled `ended`. The ask settles once: the table's unique key
  refuses a second answer, or an answer after a withdrawal (`withdraw/4`). Answers `{:ok,
  {:queued, id}}`, or `{:refused, reason}`: `:no_ask`, `:settled`, or `{:bad, :answers}`.

      Mailbox.answer(mailbox, 12, [%{"labels" => ["Rebase"], "text" => ""}])
      #=> {:ok, {:queued, 13}}
  """
  def answer(mailbox, ask_id, answers, opts \\ []),
    do: call(mailbox, {:answer, ask_id, answers}, opts)

  @doc """
  Withdraws open ask `ask_id` (F-172, `Prompt.tla`'s `WithdrawNow`): the person dismissed it in
  the app, and the agent that asked should stop waiting. `reason`, a non-empty string, goes to
  the agent once, as an answer does: a row from the operator under the ask's uuid, kind
  `withdrawn`, delivered as any row is. An answer and a withdrawal race to one settle: the
  first is stored, and the second is refused `:settled`. Answers `{:ok, {:queued, id}}`, or
  `{:refused, reason}`: `:no_ask`, `:settled`, or `{:bad, :reason}`.

      Mailbox.withdraw(mailbox, 12, "Dismissed: the release went out without it.")
      #=> {:ok, {:queued, 13}}
  """
  def withdraw(mailbox, ask_id, reason, opts \\ []),
    do: call(mailbox, {:withdraw, ask_id, reason}, opts)

  @doc """
  Waits up to `timeout` ms for the answer to the row stored under `key` (a delegate's report,
  the answer to its brief) to `to`, and takes it for a call that answers with it
  (`run_delegate`): the `call` transport. Once it is `queued`, first among `to`'s rows from its
  sender, no row to `to` is `sending`, and only before the deadline, it is marked `sending` by
  the call in the same step, so it goes no other way. The caller then says `told/3`, from the
  process that waited: when that process ends first, the row is due again. Answers `{:ok, %{id,
  from, kind, text}}`; `{:unknown, :timeout}` at the deadline, the row then due as any other;
  or `{:refused, reason}`: `:awaited` (another call waits on it), `{:status, status}` for one
  already taken, delivered or ended.

      Mailbox.await(mailbox, "app-main", brief_uuid, 60_000)
      #=> {:ok, %{id: 5, from: "app-unit-review", kind: "reply", text: "Done."}}
  """
  def await(mailbox, to, key, timeout) when is_integer(timeout) and timeout >= 0 do
    # The deadline is the caller's, on the node's clock: a request that waits in the queue does
    # not move it, so the row is never taken after the caller stopped waiting.
    deadline = System.monotonic_time(:millisecond) + timeout
    call(mailbox, {:await, to, key, deadline}, timeout: timeout + @step)
  end

  @doc """
  How the endpoint's write of row `id`, which `await/4` took, went: `:written` makes it
  `delivered`, anything else due again, first. Answers `{:ok, :delivered}`, `{:ok, :queued}`,
  or `{:refused, {:not_taken, status}}`.
  """
  def told(mailbox, id, written), do: call(mailbox, {:told, id, written}, [])

  @doc """
  What became of row `id`: `{:ok, %{id, from, to, kind, status, via, attempt, reply_to, subtype,
  is_error}}`, `status` being `queued`, `sending`, `delivered`, `ended`, `kept` (a row to the operator, never
  delivered) or `unknown` (in flight at a forced end, never resent, F-170), `reply_to` the uuid
  of the row an answer answers (`key:<key>` for a `notify/4` stored under a key, nil for any
  other), and `subtype` and `is_error` a reply's result's; or `{:refused, :no_message}`.
  """
  def status(mailbox, id, opts \\ []), do: call(mailbox, {:status, id}, opts)

  @doc """
  The answer to the row stored under `key` (the report, for a brief's uuid), as `status/3`
  answers a row, or `{:refused, :no_answer}`.
  """
  def answer_to(mailbox, key, opts \\ []), do: call(mailbox, {:answer_to, key}, opts)

  @doc """
  The reply to message `id`, or the notice in its place, as `status/3` answers a row and with
  its `text`: how the app reads the answer to the operator's message, which is `kept` for it
  and never delivered ("Agents working together"). `{:refused, :no_message}` for no such row,
  `{:refused, :no_answer}` while none has come.

      Mailbox.reply(mailbox, 12)
      #=> {:ok, %{id: 14, from: "app-unit", to: "operator", kind: "reply", status: "kept",
      #=>   text: "The tests pass.", …}}
  """
  def reply(mailbox, id), do: call(mailbox, {:reply, id}, [])

  @doc """
  The ids of the rows to `to` still `queued` or `sending`: `{:ok, ids}`. With `status:
  :sending`, only those `sending`. `Sessions` reads it before a stop, through the `open_to:`
  function the embedding app hands it:

      open_to = fn name, which -> Mailbox.open_to(mailbox, name, status: which) end
      open_to.("app-main", :sending)
      #=> {:ok, []}
  """
  def open_to(mailbox, to, opts \\ []),
    do: call(mailbox, {:open_to, to, Keyword.get(opts, :status, :open)}, opts)

  @doc """
  The keys of the calls of agent `to` that wait here now for an answer (`await/4`, a
  `run_delegate` under way): `{:ok, keys}`. A move's drain waits until there is none, and until
  no row to `to` is `sending` (`open_to/3`), a row a call took included.

      Mailbox.awaited(mailbox, "app-main")
      #=> {:ok, []}
  """
  def awaited(mailbox, to, opts \\ []), do: call(mailbox, {:awaited, to}, opts)

  @doc """
  Hands it a reader's cue: every open row is read again. A `waiter` row's lines are read from
  its transcript only on a `transcripts:` cue or a waiter's (and at its take bound): the other
  cues leave it as it is. Answers `:ok` at once.
  """
  def cue(mailbox, %{topic: topic}) when is_binary(topic),
    do: GenServer.cast(mailbox, {:cue, transcript?(topic)})

  @doc "What `Mailbox` reads, for `Cues` (see `cue/2`)."
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads do
    %{
      topics: ~w(stream sessions delegates transcripts intake:*:*:waiters),
      cue: &cue/2
    }
  end

  defp transcript?("transcripts:" <> _), do: true
  defp transcript?(topic), do: String.ends_with?(topic, ":waiters")

  defp store(mailbox, row), do: call(mailbox, {:store, row}, [])

  @doc """
  Types `/reload-plugins` into interactive agent `name`'s session and reads its result line
  (F-233, `Inlet.reload_plugins/3`): the operator's act, which reloads a changed plugin into a
  running session. It is checked as a typed message is: the turn is read in the write's own
  step, from the agent's row, its session file and its waiter, so it goes only where a message
  could be typed, and never twice. The `Inlet` works in a task, so this process waits on no
  pane. Answers `{:ok, :reloaded}`, or refused `:headless` (a headless delegate has no screen,
  and loads its plugins at its next start), `{:no_agent, name}`, `:no_inlet` (no typed
  transport), or as the `Inlet` answers. Option `timeout:` (ms, 20 000 by default).

      Mailbox.reload_plugins(mailbox, "app-main")
      #=> {:ok, :reloaded}
  """
  def reload_plugins(mailbox, name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @reload + @step)
    call(mailbox, {:reload_plugins, name, timeout - @step}, timeout: timeout)
  end

  defp call(mailbox, request, opts) do
    timeout = Keyword.get(opts, :timeout, @step)
    GenServer.call(mailbox, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_mailbox}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @step)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         host = Keyword.fetch!(opts, :host),
         {:ok, agents} <- Agents.open(Keyword.fetch!(opts, :sessions_db), host) do
      s = Map.new(~w(grants stream host)a, &{&1, Keyword.fetch!(opts, &1)})
      notify = Keyword.get(opts, :notify, fn _ -> :ok end)
      # The interactive transports' parts: the waiter with `intake:`, the typed write with
      # `inlet:`, both settled by the transcript. With neither, a main session has no transport.
      waiter =
        if opts[:intake] || opts[:inlet],
          do: Map.new(~w(transcripts accounts)a, &{&1, Keyword.fetch!(opts, &1)}),
          else: %{}

      bound = Keyword.get(opts, :take_bound, @take_bound)
      waiter = Map.merge(waiter, %{intake: opts[:intake], bound: bound})

      typed =
        if opts[:inlet],
          do: %{
            inlet: opts[:inlet],
            registry: Keyword.fetch!(opts, :registry),
            wait_bound: Keyword.get(opts, :wait_bound, @wait_bound)
          }

      # `calls`: row id to the call that took it; `waits`: key to the call waiting for it;
      # `hands`: a hand-on's task ref to the row it hands on and what its answer writes.
      s = Map.merge(s, %{db: db, agents: agents, notify: notify, calls: %{}, waits: %{}})

      s =
        Map.merge(s, %{home: opts[:home], os: Keyword.get_lazy(opts, :os, &Programs.local_os/0)})

      s = Map.merge(s, %{hands: %{}, launching: MapSet.new()})
      s = Map.put(s, :frame, Keyword.get(opts, :frame, &frame/1))
      s = Map.put(s, :acts, opts[:acts])
      {:ok, Map.merge(s, %{waiter: waiter, typed: typed}), {:continue, :read}}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  # A restart settles what it finds marked, from Stream's rows read to the end of each log; a
  # row a call took finds no call in memory, and is due again. A waiter's or typed row is settled
  # at its take bound, which no timer of the last process carries over; a headless start's first
  # line, at its start's deadline; a launch row has none.
  @impl true
  def handle_continue(:read, s) do
    Stream.read(s.stream, timeout: @step)
    s = keep_operators(s)

    for %{via: via, status: "sending", sent_at: at} <- Table.open_rows(s.db),
        via in ["waiter", "typed", "stream"],
        is_integer(at),
        do: bound(s, at)

    # A row the Inlet refused waits for its wait bound, which runs from that refusal (F-240).
    for %{status: "queued"} = m <- Table.open_rows(s.db),
        Transport.Typed.text_refused?(m.attempt),
        do: wait_timer(s, m)

    {:noreply, settle(s, true)}
  end

  def handle_continue(:settle, s), do: {:noreply, settle(s)}

  @impl true
  def handle_cast({:cue, transcript?}, s), do: {:noreply, settle(s, transcript?)}

  @impl true
  def handle_call({:message, from, to, text}, _from, s) do
    with true <-
           Enum.all?([from, to, text], &(is_binary(&1) and &1 != "")) or
             {:refused, {:bad, :message}},
         :ok <- Grants.may_message?(s.grants, from, to) do
      row = %{from: from, to: to, text: text, uuid: Stream.uuid(), kind: "msg"}
      stored(s, put(s, row))
    else
      refused -> {:reply, refused, s}
    end
  end

  # The key goes in `reply_to`, whose unique index takes one row per key; a key is never a
  # row's uuid, since it carries its own prefix.
  def handle_call({:notify, to, text, key, kind, from}, _from, s) do
    with true <- kind in [:msg, :notice, :prompt] or {:refused, {:bad, :kind}},
         true <-
           (Enum.all?([to, text], &(is_binary(&1) and &1 != "")) and
              (is_nil(key) or is_binary(key))) or {:refused, {:bad, :message}},
         :ok <- Grants.may_use?(s.grants, to),
         # A prompt's notice is its asker's: an agent of the tree, never the framework.
         :ok <- if(kind == :prompt, do: Grants.may_use?(s.grants, from), else: :ok),
         from = if(kind == :prompt, do: from, else: @framework),
         # The operator is no agent: nothing would deliver to it.
         true <- to != Grants.operator(s.grants) or {:refused, {:not_an_agent, to}} do
      row = %{
        from: from,
        to: to,
        text: text,
        uuid: Stream.uuid(),
        kind: Atom.to_string(kind)
      }

      stored(s, put(s, Map.put(row, :reply_to, key && "key:" <> key)))
    else
      refused -> {:reply, refused, s}
    end
  end

  def handle_call({:ask, from, questions}, _from, s) do
    operator = Grants.operator(s.grants)

    with {:ok, questions} <- Ask.questions(questions),
         true <- is_binary(from) or {:refused, {:bad, :message}},
         true <- operator != nil or {:refused, :no_operator},
         true <- from != operator or {:refused, {:not_an_agent, from}},
         :ok <- Grants.may_use?(s.grants, from) do
      row = %{from: from, to: operator, text: JSON.encode!(questions), kind: "ask"}

      case put(s, Map.put(row, :uuid, Stream.uuid())) do
        nil ->
          {:reply, {:unknown, :not_stored}, s}

        id ->
          announce(s, id)
          {:reply, {:ok, {:asked, id}}, s}
      end
    else
      refused -> {:reply, refused, s}
    end
  end

  def handle_call(:open_asks, _from, s),
    do: {:reply, {:ok, Enum.map(Table.open_asks(s.db), &shown_ask(s, &1))}, s}

  def handle_call({:asked, id}, _from, s) do
    case Table.get(s.db, id) do
      %{kind: "ask"} = m -> {:reply, {:ok, shown_ask(s, m)}, s}
      _ -> {:reply, {:refused, :no_ask}, s}
    end
  end

  # The answer's row is keyed by the ask's uuid in `reply_to`, whose unique index lets in the
  # first answer only, across restarts (`Team.tla`'s AnswerOnce).
  def handle_call({:answer, id, answers}, _from, s) do
    with %{kind: "ask"} = m <- Table.get(s.db, id) || {:refused, :no_ask},
         questions = JSON.decode!(m.text),
         {:ok, answers} <- Ask.answers(questions, answers) do
      row = %{from: m.to_agent, to: m.from_agent, text: Ask.text(id, questions, answers)}
      row = Map.merge(row, %{uuid: Stream.uuid(), kind: "answer", reply_to: m.uuid})
      # The labels as the app gave them, beside the agent's text (F-138's new-3).
      row = Map.put(row, :answer, JSON.encode!(answers))

      settle_ask(s, row)
    else
      %{} -> {:reply, {:refused, :no_ask}, s}
      refused -> {:reply, refused, s}
    end
  end

  # The withdrawal takes the same key as an answer, so the first of the two is the one settle.
  def handle_call({:withdraw, id, reason}, _from, s) do
    with %{kind: "ask"} = m <- Table.get(s.db, id) || {:refused, :no_ask},
         true <- (is_binary(reason) and String.trim(reason) != "") or {:refused, {:bad, :reason}} do
      text = "Ask #{id} was withdrawn: " <> (reason |> String.split() |> Enum.join(" "))
      row = %{from: m.to_agent, to: m.from_agent, text: text, kind: "withdrawn"}
      settle_ask(s, Map.merge(row, %{uuid: Stream.uuid(), reply_to: m.uuid}))
    else
      %{} -> {:reply, {:refused, :no_ask}, s}
      refused -> {:reply, refused, s}
    end
  end

  def handle_call({:store, row}, _from, s) do
    if Enum.all?([row.from, row.to, row.text, row.uuid], &(is_binary(&1) and &1 != "")),
      do: stored(s, put(s, row)),
      else: {:reply, {:refused, {:bad, :message}}, s}
  end

  # The mark before a start: one row in flight per addressee, the first due, for the process
  # the start makes; its transcript's offset now bounds what its settle reads. The row is in
  # `launching` until the start's answer: no evidence settles it before.
  def handle_call({:launch, to, deadline, via}, _from, s) do
    rows = for %{to_agent: ^to} = m <- Table.open_rows(s.db), do: m

    case {Enum.filter(rows, &(&1.status == "sending")), rows} do
      _ when via == :launch and not is_map_key(s.waiter, :transcripts) ->
        {:reply, {:refused, :no_transcripts}, s}

      {[_ | _] = sending, _} ->
        {:reply, {:refused, {:sending, Enum.map(sending, & &1.id)}}, s}

      {[], []} ->
        {:reply, {:ok, :none}, s}

      # Delivery.tla's stream row for a start: marked while no process of it runs (`at` nil),
      # for the session the agent row names at a resume, or the start's answer names.
      {[], [m | _]} when via == :stream ->
        with {:ok, text} <- framed(s, m) do
          srow = Agents.get(s.agents, to)
          mark = [status: "sending", via: "stream", session_id: srow && srow.session_id, at: nil]
          write(s, m, mark ++ [attempt: nil, sent_at: deadline])
          s = %{s | launching: MapSet.put(s.launching, m.id)}
          {:reply, {:ok, %{id: m.id, uuid: m.uuid, text: text}}, s}
        else
          refused -> {:reply, refused, s}
        end

      {[], [m | _]} ->
        with {:ok, text} <- launch_text(s, to, m) do
          srow = Agents.get(s.agents, to)
          sid = srow && srow.session_id
          from = if is_binary(sid), do: offset(s, srow), else: 0
          mark = [status: "sending", via: "launch", session_id: sid, at: nil, attempt: nil]
          write(s, m, mark ++ [from_byte: from, sent_at: deadline])
          s = %{s | launching: MapSet.put(s.launching, m.id)}
          {:reply, {:ok, %{id: m.id, uuid: m.uuid, text: text}}, s}
        else
          other -> {:reply, other, s}
        end
    end
  end

  def handle_call({:launched, id, answer}, _from, s) do
    s = %{s | launching: MapSet.delete(s.launching, id)}

    case {Table.get(s.db, id), answer} do
      # A headless start's first line went in through Stream before its init: its fold settles
      # it from now on, as any stream row.
      {%{status: "sending", via: "stream"} = m, {:ok, %{session_id: sid}}} ->
        write(s, m, session_id: sid, sent_at: nil, attempt: nil)
        {:reply, {:ok, "sending"}, s, {:continue, :settle}}

      # A start refused after its hold (a stop of one never confirmed) may have written the
      # line: the fold of the session it was held as decides, as at any exit; one refused
      # before it holds no line of it, and the row is due again.
      {%{status: "sending", via: "stream"} = m, {:refused, why}} ->
        sid = m.session_id || session_of(s, m)
        write(s, m, session_id: sid, sent_at: nil, attempt: why)
        {:reply, {:ok, "sending"}, s, {:continue, :settle}}

      # Unknown: the start's deadline, kept as `sent_at`, bounds the wait for its line.
      {%{status: "sending", via: "stream"} = m, {_unknown, why}} ->
        write(s, m, attempt: why)
        if is_integer(m.sent_at), do: bound(s, m.sent_at)
        {:reply, {:ok, "sending"}, s, {:continue, :settle}}

      {%{status: "sending", via: "launch"} = m, {:ok, %{session_id: sid} = started}} ->
        write(s, m, session_id: sid, at: started[:pid], sent_at: now(), attempt: nil)
        {:reply, {:ok, "sending"}, s}

      {%{status: "sending", via: "launch"} = m, {:refused, why}} ->
        write(s, m, status: "queued", via: nil, at: nil, sent_at: nil, attempt: why)
        {:reply, {:ok, "queued"}, s, {:continue, :settle}}

      {%{status: "sending", via: "launch"} = m, {_unknown, why}} ->
        write(s, m, attempt: why)
        {:reply, {:ok, "sending"}, s}

      {%{status: status}, _} ->
        {:reply, {:refused, {:not_launched, status}}, s}

      {nil, _} ->
        {:reply, {:refused, :no_message}, s}
    end
  end

  def handle_call({:ended, to}, _from, s) do
    ids = for %{to_agent: ^to, status: "queued"} = m <- Table.open_rows(s.db), do: m.id
    for id <- ids, do: write(s, %{id: id}, status: "ended")
    {:reply, {:ok, ids}, s}
  end

  def handle_call({:ended_while_sending, to}, _from, s) do
    srow = Agents.get(s.agents, to)

    if srow != nil and Agents.free?(srow) do
      rows = for %{to_agent: ^to, status: "sending"} = m <- Table.open_rows(s.db), do: m
      {ids, s} = unknown(s, rows)
      {:reply, {:ok, ids}, s}
    else
      {:reply, {:refused, {:not_free, srow && srow.status}}, s}
    end
  end

  def handle_call({:settle_row, uuid}, _from, s) do
    reply =
      case Table.by_uuid(s.db, uuid) do
        nil ->
          {:refused, :no_message}

        %{status: "queued"} = m ->
          write(s, m, status: "ended")
          {:ok, :ended}

        %{status: "sending"} ->
          {:refused, {:not_queued, "sending"}}

        %{status: status} ->
          {:ok, status}
      end

    {:reply, reply, s}
  end

  def handle_call({:await, to, key, deadline}, from, s) do
    m = Table.answer(s.db, key)

    cond do
      Map.has_key?(s.waits, key) ->
        {:reply, {:refused, :awaited}, s}

      m != nil and m.status != "queued" ->
        {:reply, {:refused, {:status, m.status}}, s}

      true ->
        # A call with no time left takes only a row it can take now, and never waits.
        left = deadline - System.monotonic_time(:millisecond)
        # The timer names this wait: one a take or a 0 ms answer canceled too late must not end
        # a later wait on the same key.
        ref = make_ref()
        timer = Process.send_after(self(), {:waited, key, ref}, max(left, 0))
        w = %{from: from, to: to, deadline: deadline, timer: timer, ref: ref}
        s = put_in(s.waits[key], w)
        s = take_waiting(s)

        if left <= 0 and Map.has_key?(s.waits, key) do
          Process.cancel_timer(timer)
          {:reply, {:unknown, :timeout}, %{s | waits: Map.delete(s.waits, key)}}
        else
          {:noreply, s}
        end
    end
  end

  def handle_call({:told, id, written}, _from, s) do
    case Table.get(s.db, id) do
      %{status: "sending", via: "call"} = m ->
        s = unwatch(s, id)

        if written == :written do
          write(s, m, status: "delivered", delivered_at: now())
          {:reply, {:ok, :delivered}, s, {:continue, :settle}}
        else
          again(s, m, :write_failed)
          {:reply, {:ok, :queued}, s, {:continue, :settle}}
        end

      %{status: status} ->
        {:reply, {:refused, {:not_taken, status}}, s}

      nil ->
        {:reply, {:refused, :no_message}, s}
    end
  end

  def handle_call({:status, id}, _from, s),
    do: {:reply, shown(Table.get(s.db, id) || {:refused, :no_message}), s}

  def handle_call({:answer_to, key}, _from, s),
    do: {:reply, shown(Table.answer(s.db, key) || {:refused, :no_answer}), s}

  # The reload's checks read here, its write in a task that answers the caller itself: the
  # turn read again in the Inlet's step, as a typed row's is (`type_line/4`).
  def handle_call({:reload_plugins, name, timeout}, from, s) do
    row = s.agents |> Agents.get(name) |> Agents.unheld(div(now(), 1000))

    cond do
      row == nil ->
        {:reply, {:refused, {:no_agent, name}}, s}

      Agents.headless?(row) ->
        {:reply, {:refused, :headless}, s}

      s.typed == nil ->
        {:reply, {:refused, :no_inlet}, s}

      true ->
        reads = Map.take(s, [:agents, :typed, :waiter])
        turn = fn -> turn_now(reads, name, row.pid) end
        opts = [release: row.release, turn: turn, timeout: timeout]
        inlet = s.typed.inlet

        Task.start(fn ->
          GenServer.reply(from, guarded(fn -> Inlet.reload_plugins(inlet, name, opts) end))
        end)

        {:noreply, s}
    end
  end

  def handle_call({:reply, id}, _from, s) do
    case Table.get(s.db, id) do
      %{uuid: uuid} ->
        case Table.answer(s.db, uuid) do
          nil -> {:reply, {:refused, :no_answer}, s}
          answer -> {:reply, with_text(shown(answer), answer), s}
        end

      nil ->
        {:reply, {:refused, :no_message}, s}
    end
  end

  def handle_call({:open_to, to, which}, _from, s) do
    ids =
      for %{to_agent: ^to} = m <- Table.open_rows(s.db),
          which == :open or m.status == "sending",
          do: m.id

    {:reply, {:ok, ids}, s}
  end

  def handle_call({:awaited, to}, _from, s),
    do: {:reply, {:ok, for({key, %{to: ^to}} <- s.waits, do: key)}, s}

  # A waiter's row reached its take bound: settled now, by the transcript as it is.
  @impl true
  def handle_info(:bound, s), do: {:noreply, settle(s, true)}

  # A hand-on's answer: the row is settled by it as the transport says, and evidence reads it
  # again from the next settle on.
  # An answer that kept the mark is settled at once: evidence that came in meanwhile was left.
  # A refusal waits for the next cue, as the row did before its mark.
  def handle_info({ref, answer}, %{hands: hands} = s) when is_map_key(hands, ref) do
    Process.demonitor(ref, [:flush])
    s = handed(s, ref, answer)
    if match?({:refused, _}, answer), do: {:noreply, s}, else: {:noreply, s, {:continue, :settle}}
  end

  def handle_info({:waited, key, ref}, s) do
    case s.waits[key] do
      %{ref: ^ref, from: from} ->
        GenServer.reply(from, {:unknown, :timeout})
        {:noreply, %{s | waits: Map.delete(s.waits, key)}}

      _stale ->
        {:noreply, s}
    end
  end

  # CallerSeen: the process that took a row ended before it said how its write went. The write
  # may have reached the agent; the row is due again, for another transport.
  # A hand-on's task ended with no answer: the write may have gone in, as an unknown answer.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{hands: hands} = s)
      when is_map_key(hands, ref),
      do: {:noreply, handed(s, ref, {:unknown, {:exit, reason}}), {:continue, :settle}}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) do
    case Enum.find(s.calls, fn {_id, r} -> r == ref end) do
      {id, _} ->
        s = %{s | calls: Map.delete(s.calls, id)}
        with %{status: "sending", via: "call"} = m <- Table.get(s.db, id), do: again(s, m, :gone)
        {:noreply, settle(s)}

      nil ->
        {:noreply, s}
    end
  end

  # The one store: a row to the operator is no session's, so it is `kept` from the start and
  # out of `Table.open_rows/1`: no settle reads it again (F-138's new-1).
  defp put(s, row) do
    operator = Grants.operator(s.grants)
    row = if operator && row.to == operator, do: Map.put(row, :status, "kept"), else: row
    Table.store(s.db, row)
  end

  # Rows to the operator an earlier build stored `queued` are kept, once, at the start.
  defp keep_operators(s) do
    operator = Grants.operator(s.grants)

    for %{to_agent: ^operator, status: "queued"} = m <- Table.open_rows(s.db),
        do: Table.update(s.db, m.id, status: "kept", attempt: nil)

    s
  end

  defp settle_ask(s, row) do
    case put(s, row) do
      nil -> {:reply, {:refused, :settled}, s}
      id -> stored(s, id)
    end
  end

  defp stored(s, nil), do: {:reply, {:ok, :stored_before}, s}

  defp stored(s, id) do
    announce(s, id)
    {:reply, {:ok, {:queued, id}}, s, {:continue, :settle}}
  end

  defp shown({:refused, _} = refused), do: refused

  defp shown(m) do
    keys = [:id, :kind, :status, :via, :attempt, :reply_to, :subtype]

    {:ok,
     Map.take(m, keys)
     |> Map.merge(%{from: m.from_agent, to: m.to_agent, is_error: bool(m.is_error)})}
  end

  defp with_text({:ok, shown}, m), do: {:ok, Map.put(shown, :text, m.text)}

  defp bool(n), do: %{1 => true, 0 => false}[n]

  defp shown_ask(s, m) do
    answer =
      case Table.answer(s.db, m.uuid) do
        nil ->
          nil

        a ->
          answers = a.answer && JSON.decode!(a.answer)
          %{id: a.id, kind: a.kind, text: a.text, status: a.status, answers: answers}
      end

    %{
      id: m.id,
      from: m.from_agent,
      questions: JSON.decode!(m.text),
      asked_at: m.created_at,
      answer: answer
    }
  end

  # Every open row, read against Stream's rows and Sessions' rows; a failed read decides nothing.
  # A waiter's row is read against its transcript only when `transcript?` (F-127's new-1): on a
  # cue of the transcripts or the waiters, at its take bound and at the start. A launch row is
  # read at every cue, as a typed one is: its process's end, a `sessions` cue, is its evidence too.
  defp settle(s, transcript? \\ false) do
    s = forced(s)

    with {:ok, %{rows: rows}} <- Stream.rows(s.stream, timeout: @step) do
      folds = Map.new(rows, &{&1.session, &1})

      handing = handing(s)

      for %{status: "sending"} = m <- Table.open_rows(s.db),
          not MapSet.member?(handing, m.id) and not MapSet.member?(s.launching, m.id),
          m.via != "waiter" or transcript? do
        evidence = %{fold: folds[m.session_id || session_of(s, m)], calls: s.calls, now: now()}

        evidence =
          case m.via do
            "waiter" -> Map.put(evidence, :waiter, seen(s, m))
            "typed" -> Map.put(evidence, :typed, typed_seen(s, m))
            "launch" -> Map.put(evidence, :launch, launch_seen(s, m))
            _ -> evidence
          end

        settled(s, m, Transport.settle(m, evidence))
      end

      replies(s, folds)

      Table.open_rows(s.db)
      |> Enum.group_by(& &1.to_agent)
      |> Enum.reduce(s, fn {to, rows}, s -> deliver(s, rows, target(s, to, folds)) end)
      |> take_waiting()
    else
      _ -> take_waiting(s)
    end
  end

  # Rows still `sending` at a forced end settle unknown, never resent, never delivered
  # (`Delivery.tla`'s ForceSettled, ForcedSettles; F-170, F-172).
  defp unknown(s, rows) do
    for m <- rows, do: write(s, m, status: "unknown", attempt: :ended_while_sending)
    ids = Enum.map(rows, & &1.id)
    s = Enum.reduce(ids, s, &unwatch(&2, &1))
    {ids, %{s | launching: MapSet.difference(s.launching, MapSet.new(ids))}}
  end

  # Mailbox's own ForceSettled, before any transport reads its evidence: a row `sending` to an
  # agent whose row ended, with no process of it left, whose end the operator forced (the
  # end's claim in `Acts`, `detail` `force`, made before that end). Each settle is a row of
  # `Acts`, as the operator's call writes it. A read of `Acts` that fails decides nothing.
  defp forced(%{acts: nil} = s), do: s

  defp forced(s) do
    Table.open_rows(s.db)
    |> Enum.filter(&(&1.status == "sending"))
    |> Enum.group_by(& &1.to_agent)
    |> Enum.reduce(s, fn {to, rows}, s ->
      srow = Agents.get(s.agents, to)

      with true <- srow != nil and Agents.ended?(srow) and Agents.free?(srow),
           %{actor: actor} <- forced_end(s, srow) do
        {ids, s} = unknown(s, rows)

        for id <- ids do
          Acts.record(s.acts, actor, to, "settle", :unknown,
            reason: :ended_while_sending,
            detail: %{row: id}
          )
        end

        s
      else
        _ -> s
      end
    end)
  end

  defp forced_end(s, srow) do
    case Acts.rows(s.acts, [target: srow.name, act: ["end_main", "stop"]], timeout: @step) do
      {:ok, acts} ->
        Enum.find(acts, fn a ->
          a.detail == Store.text(%{force: true}) and a.outcome != "failed" and
            (not is_integer(srow.ended_at) or a.claimed_at <= srow.ended_at)
        end)

      _ ->
        nil
    end
  end

  # A headless start's first row names no session until the start's answer: after a restart,
  # its agent row's.
  defp session_of(s, m) do
    srow = Agents.get(s.agents, m.to_agent)
    srow && srow.session_id
  end

  defp handing(s), do: MapSet.new(Map.values(s.hands), fn {m, _} -> m.id end)

  # A row settled while its hand-on ran (`ended_while_sending/3`) takes no answer of it.
  defp handed(s, ref, answer) do
    {{m, after_hand}, hands} = Map.pop(s.hands, ref)
    s = %{s | hands: hands}
    if match?(%{status: "sending"}, Table.get(s.db, m.id)), do: after_hand.(s, m, answer)
    s
  end

  # The hand-on, in a task: `hand_on` runs there, and `after_hand` writes its answer here. The
  # task is linked, so it ends with this process; the row is then settled by its transport's
  # restart policy. `hand_on` answers its part's outcome; a raise, throw or exit in it is an
  # unknown answer, since the write may have gone in.
  defp hand_on(s, m, hand_on, after_hand) do
    task = Task.async(fn -> guarded(hand_on) end)
    put_in(s.hands[task.ref], {m, after_hand})
  end

  # A write that raised may have gone in: unknown, never refused.
  defp guarded(write) do
    write.()
  rescue
    e -> {:unknown, {:raised, e.__struct__}}
  catch
    kind, _ -> {:unknown, {kind, :hand_on}}
  end

  defp settled(_s, _m, :keep), do: :ok

  defp settled(s, m, :delivered) do
    # A pointer's file stays: the line is taken before the agent reads the file, in the turn it
    # starts, and nothing tells when that read is done. The framework keeps its data.
    write(s, m, status: "delivered", attempt: nil, delivered_at: now())
  end

  defp settled(s, m, :again), do: again(s, m, nil)

  # Due again, first, under its same uuid.
  defp again(s, m, why),
    do: write(s, m, status: "queued", via: nil, at: nil, again: 1, attempt: why, sent_at: nil)

  # ReplyStored and NoticeStored: a delivered message's turn ended with a result that names it
  # (the fold keeps it on the message, so a later turn's never replaces it), or its process
  # ended with none (`:exited`). Either one row goes to its sender under the message's uuid,
  # whose unique index lets in one reply or one notice, across restarts and cues.
  defp replies(s, folds) do
    for {sid, fold} <- folds,
        ended = for({u, _} <- fold.messages, turn_ended?(Fold.outcome(fold, u)), do: u),
        m <- Table.unanswered(s.db, sid, ended),
        to = sender(s, m),
        do: reply_row(s, m, to, Fold.outcome(fold, m.uuid))
  end

  # A message from `framework` is answered to the delegate's parent, the sender of its brief.
  defp sender(s, %{from_agent: @framework} = m) do
    case Table.brief(s.db, m.to_agent) do
      %{from_agent: parent} -> parent
      nil -> nil
    end
  end

  defp sender(_s, m), do: m.from_agent

  defp turn_ended?({:result, _}), do: true
  defp turn_ended?(outcome), do: outcome == :exited

  defp reply_row(s, m, to, {:result, r}) do
    row = %{from: m.to_agent, to: to, text: r.text, uuid: Stream.uuid(), kind: "reply"}
    row = Map.merge(row, %{reply_to: m.uuid, subtype: r.subtype, is_error: r.is_error})
    stored_quietly(s, put(s, row))
  end

  defp reply_row(s, m, to, :exited) do
    row = %{from: @framework, to: to, text: notice(m), uuid: Stream.uuid(), kind: "notice"}
    stored_quietly(s, put(s, Map.put(row, :reply_to, m.uuid)))
  end

  defp notice(m),
    do:
      "Your message #{m.id} went in to #{m.to_agent}, and its process ended before it " <>
        "answered: no reply will come. Resume it to ask again."

  defp stored_quietly(_s, nil), do: :ok
  defp stored_quietly(s, id), do: announce(s, id)

  # The addressee and its transport, by its agent row (`Sessions.Agents`): a headless
  # delegate's stream, with the fold of its session; an interactive session's waiter or typed
  # write, when this Mailbox was given an `Intake` or an `Inlet`. Anything else has none.
  defp target(s, to, folds) do
    srow = s.agents |> Agents.get(to) |> Agents.unheld(div(now(), 1000))

    cond do
      Agents.ended?(srow) ->
        {:ended, srow.ended_at}

      # A move under way (Move.tla's MarkWhileEnding): no row that would start a turn goes in
      # until the session runs on the other account; a waiting call's answer still may.
      Agents.moving?(srow) ->
        :moving

      # A usage limit's reset not yet passed (Boxes.tla's NoRowIntoLimit): a row handed in
      # would start a turn into the limit. After it, the turn is read as any row's.
      Agents.limit(srow) != nil ->
        :limited

      Agents.headless?(srow) and is_binary(srow.session_id) ->
        {:stream, srow, folds[srow.session_id]}

      Agents.headless?(srow) ->
        :not_started

      srow != nil and (s.waiter.intake != nil or s.typed != nil) ->
        {:waiter, srow}

      true ->
        :none
    end
  end

  defp deliver(s, rows, :none) do
    for %{status: "queued"} = m <- rows,
        m.attempt != "no_delivery",
        do: write(s, m, attempt: :no_delivery)

    s
  end

  defp deliver(s, _rows, :not_started), do: s
  defp deliver(s, _rows, :moving), do: s
  defp deliver(s, _rows, :limited), do: s

  # An agent that ended takes nothing: no process of it runs again (EndedNotDelivered). A brief
  # stored since its end is a later start's, stored before `Sessions` writes that start, and
  # waits for it. "Since" is read from the end's own time, which only the end writes, never the
  # row's last write (F-165).
  defp deliver(s, rows, {:ended, at}) do
    for %{status: "queued"} = m <- rows,
        m.kind != "brief" or before_end?(m, at),
        do: write(s, m, status: "ended")

    s
  end

  defp deliver(s, rows, {:stream, srow, fold}) do
    cond do
      # EndedFirst: queued rows only; a sending one is settled first.
      match?(%{gone: true, ending: true}, fold) ->
        for %{status: "queued"} = m <- rows, do: write(s, m, status: "ended")
        s

      # One row in flight per addressee.
      Enum.any?(rows, &(&1.status == "sending")) or not ready?(srow, fold) ->
        s

      true ->
        mark(s, hd(rows), srow.session_id, fold.resumes)
    end
  end

  # A main session's waiter: one row in flight, to a running session that has a waiter held now
  # (each turn's end starts one). Claude Code takes the text into an ended turn, or queues it
  # into a running one (a person's prompt started a turn while the last turn's waiter waited);
  # nothing is typed either way. A session with no waiter gets the Inlet's typed write, into an
  # ended turn only; with no Inlet, or a text it refused, its rows stay due, and `Intake`'s
  # waiter cue tries them again.
  defp deliver(s, rows, {:waiter, srow}) do
    m = hd(rows)

    cond do
      Enum.any?(rows, &(&1.status == "sending")) ->
        s

      not Agents.running?(srow) or not is_integer(srow.pid) or not is_binary(srow.session_id) ->
        s

      true ->
        interactive(s, m, srow, waiter?(s, srow))
    end
  end

  # Both times are wall-clock milliseconds, so within the end's own millisecond the order is
  # not known. A brief there waits: a later start's brief may follow its end that closely, and
  # a start's own brief cannot go unsent and its start end within one millisecond (a refused
  # start's brief is settled by `ended/3` instead). An end with no time yet (a file an earlier
  # build wrote, until `Sessions` opens it) ends no brief.
  defp before_end?(m, at) when is_integer(at), do: m.created_at < at
  defp before_end?(_m, nil), do: false

  defp interactive(s, m, srow, {:ok, true}), do: hand(s, m, srow)

  defp interactive(s, m, srow, held) do
    refused = Transport.Typed.text_refused?(m.attempt)

    cond do
      # Only a waiter known absent: an unread one may be there, and its turn not ended.
      held == {:ok, false} and s.typed != nil and not refused ->
        type(s, m, srow)

      refused and held == {:ok, false} and s.typed != nil ->
        stuck(s, m, srow, turn_now(s, srow.name, srow.pid))

      m.attempt != "no_waiter" and not refused ->
        write(s, m, attempt: :no_waiter)
        s

      true ->
        s
    end
  end

  # A row the Inlet refused, its session idle with no waiter (`Delivery.tla`'s `Stuck`, F-240):
  # no waiter comes until a turn of it ends. Wake: the wake line, typed once in its place, its
  # mark written first, so a restart never types it again; that turn's end brings the waiter,
  # which carries the row. WaitBound: past the bound none came. The row is undelivered, never
  # sent, its sender told, and the next row to the session goes now, not at the next cue,
  # which may never come. A turn running now ends with a waiter: neither, yet.
  defp stuck(s, _m, _srow, {:refused, _}), do: s

  defp stuck(s, m, srow, :ok) do
    cond do
      waited?(s, m) ->
        write(s, m, status: "undelivered", attempt: {:wait_bound, JSON.decode!(m.attempt)})
        told(s, m)
        send(self(), :bound)
        s

      m.woke_at == nil ->
        wake(s, m, srow)

      true ->
        s
    end
  end

  defp wake(s, m, srow) do
    write(s, m, woke_at: now())
    wait_timer(s, Table.get(s.db, m.id))
    reads = Map.take(s, [:agents, :typed, :waiter])
    turn = fn -> turn_now(reads, srow.name, srow.pid) end
    inlet = s.typed.inlet
    opts = [release: srow.release, turn: turn, timeout: @inlet]
    # Its answer writes nothing: the row stays queued, and the waiter or the bound settles it.
    hand_on(s, m, fn -> Inlet.type(inlet, srow.name, @wake, opts) end, fn _s, _m, _ -> :ok end)
  end

  # The undelivered row's notice to its sender, under its key, as a process's end gives one.
  defp told(s, m) do
    to = sender(s, m)
    secs = div(s.typed.wait_bound, 1000)
    text = "undelivered: message #{m.id} to #{m.to_agent}, after #{secs} s"
    row = %{from: @framework, to: to, text: text, uuid: Stream.uuid(), kind: "notice"}
    if to, do: stored_quietly(s, put(s, Map.put(row, :reply_to, m.uuid)))
  end

  # Mark, then the hand-on: refused undoes the mark (nothing was marked in Stream); unknown
  # stays sending for Stream's fold to settle.
  defp mark(s, m, sid, at), do: with_framed(s, m, &mark(&1, m, sid, at, &2))

  defp mark(s, m, sid, at, text) do
    write(s, m, status: "sending", via: "stream", session_id: sid, at: at)
    stream = s.stream

    hand_on(
      s,
      m,
      fn -> Stream.write(stream, sid, {:message, m.uuid, text}, timeout: @step) end,
      fn
        _s, _m, {:ok, _} -> :ok
        s, m, {:refused, why} -> write(s, m, status: "queued", via: nil, at: nil, attempt: why)
        s, m, {:unknown, why} -> write(s, m, attempt: why)
      end
    )
  end

  # Mark, then the hand-on, as `mark/4`; the transcript's offset read before the mark bounds
  # what its settle reads. Sent or unknown starts the take bound: the text may have been read.
  defp hand(s, m, srow), do: with_framed(s, m, &hand(&1, m, srow, &2))

  defp hand(s, m, srow, text) do
    from = offset(s, srow)
    mark = [status: "sending", via: "waiter", session_id: srow.session_id, at: srow.pid]
    write(s, m, mark ++ [from_byte: from, sent_at: nil])
    text = Transport.Waiter.text(text, m.uuid)
    intake = s.waiter.intake

    hand_on(
      s,
      m,
      fn -> Intake.deliver(intake, srow.account, srow.session_id, text, timeout: @step) end,
      &sent/3
    )
  end

  # A waiter's or typed write's answer: sent or unknown starts the take bound, refused undoes
  # the mark.
  defp sent(s, m, {:ok, :sent}) do
    write(s, m, sent_at: now(), attempt: nil)
    bound(s, now())
  end

  defp sent(s, m, {:refused, why}) do
    write(s, m, status: "queued", via: nil, at: nil, sent_at: nil, attempt: why)
    refused(s, m)
  end

  defp sent(s, m, {:unknown, why}) do
    write(s, m, sent_at: now(), attempt: why)
    bound(s, now())
  end

  defp waiter?(%{waiter: %{intake: nil}}, _srow), do: {:ok, false}

  defp waiter?(s, srow),
    do: Intake.waiter?(s.waiter.intake, srow.account, srow.session_id, timeout: @step)

  # The typed write: marked only once the session file reads idle (a row is not marked and
  # unmarked at every cue while a turn runs); the Inlet reads the turn again in its own step,
  # with the screen. `sent_at` at the mark is the latest the keys can go in, the Inlet's call
  # timeout past it, so a restart before the answer waits that long and the bound.
  defp type(s, m, srow) do
    case turn_now(s, srow.name, srow.pid) do
      :ok ->
        type_line(s, m, srow, line(s, m, srow))

      {:refused, why} ->
        if m.attempt != Store.text(why), do: write(s, m, attempt: why)
        s
    end
  end

  # The line typed: the row's own, or for a row too long to type, one that names the file its
  # text is written to in the agent's due directory, which its start may read (F-142).
  defp line(s, m, srow) do
    with {:ok, text} <- framed(s, m) do
      if Transport.Typed.short?(text, m.uuid),
        do: {:ok, Transport.Typed.text(text, m.uuid)},
        else:
          with(
            {:ok, path} <- due_file(s, srow.name, m, text),
            {:ok, line} <- pointer(s, m, path),
            do: {:ok, Transport.Typed.pointer(line, m.uuid)}
          )
    end
  end

  # The line that names the file a row's text is in, framed with its sender as the text is.
  defp pointer(_s, %{kind: kind}, path) when kind in ["brief", "resume"],
    do: {:ok, Transport.pointer_line(path, false)}

  defp pointer(s, m, path), do: framed(s, %{m | text: Transport.pointer_line(path)})

  # The text an agent reads of row `m`, framed with its sender by `frame/1` or the app's
  # `frame:` (F-170); a brief and a word to go on are the delegate's own prompt, as they are.
  defp framed(_s, %{kind: kind} = m) when kind in ["brief", "resume"], do: {:ok, m.text}

  defp framed(s, m) do
    {from, kind} = sender_of(s, m)
    account = with %{account: a} <- Agents.get(s.agents, from), do: a
    row = %{from: from, kind: kind, to: m.to_agent, text: m.text, account: account}

    case s.frame.(row) do
      text when is_binary(text) and text != "" -> {:ok, text}
      _ -> {:refused, {:bad, :frame}}
    end
  end

  # Whose the row is: a reply's or a report's agent; for the framework's notice in a reply's
  # or a report's place, the agent whose row it answers.
  defp sender_of(s, %{kind: kind} = m) when kind in ["reply", "notice"] do
    case m.reply_to && Table.by_uuid(s.db, m.reply_to) do
      %{kind: "brief", to_agent: to} ->
        {if(kind == "reply", do: m.from_agent, else: to), "report"}

      %{to_agent: to} when kind == "notice" ->
        {to, "notice"}

      _ ->
        {m.from_agent, kind}
    end
  end

  defp sender_of(_s, %{kind: kind} = m) when kind in [nil, "msg"], do: {m.from_agent, "message"}
  defp sender_of(_s, m), do: {m.from_agent, m.kind}

  # A transport's mark with the framed text, or none: a frame refused is the row's attempt.
  defp with_framed(s, m, mark) do
    case framed(s, m) do
      {:ok, text} ->
        mark.(s, text)

      {:refused, why} ->
        if m.attempt != Store.text(why), do: write(s, m, attempt: why)
        s
    end
  end

  # The launch's prompt: the row's text, or for one longer than the host's argument carries,
  # a short line naming the file its text is in, as a typed row's pointer (F-155).
  defp launch_text(s, to, m) do
    with {:ok, framed} <- framed(s, m),
         text = Transport.Launch.text(framed, m.uuid),
         {:ok, max} <- ClaudeCLI.prompt_max(s.os) do
      if byte_size(text) <= max,
        do: {:ok, text},
        else:
          with(
            {:ok, path} <- due_file(s, to, m, framed),
            {:ok, line} <- pointer(s, m, path),
            do: {:ok, Transport.Launch.pointer(line, m.uuid)}
          )
    end
  end

  # The row's whole text in the agent's due directory, written whole and renamed into place.
  defp due_file(%{home: nil}, _name, _m, _text), do: {:refused, {:too_long, :no_home}}

  defp due_file(s, name, m, text) do
    path = Path.join(Sessions.due_dir(s.home, name), "#{m.id}.md")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", text),
         :ok <- File.rename(path <> ".tmp", path) do
      {:ok, path}
    else
      {:error, why} -> {:unknown, {:due_file, why}}
    end
  end

  defp type_line(s, m, _srow, {:refused, why}) do
    write(s, m, attempt: why)
    refused(s, m)
    s
  end

  defp type_line(s, m, _srow, {:unknown, why}) do
    if m.attempt != Store.text(why), do: write(s, m, attempt: why)
    s
  end

  defp type_line(s, m, srow, {:ok, text}) do
    from = offset(s, srow)
    mark = [status: "sending", via: "typed", session_id: srow.session_id, at: srow.pid]
    write(s, m, mark ++ [from_byte: from, sent_at: now() + @inlet])
    reads = Map.take(s, [:agents, :typed, :waiter])
    turn = fn -> turn_now(reads, srow.name, srow.pid) end
    inlet = s.typed.inlet

    hand_on(
      s,
      m,
      fn ->
        Inlet.type(inlet, srow.name, text, release: srow.release, turn: turn, timeout: @inlet)
      end,
      &sent/3
    )
  end

  # The turn of `name`'s process `pid` read now: its row, its session file and its waiter.
  defp turn_now(s, name, pid) do
    with %{} = row <- s.agents |> Agents.get(name) |> Agents.unheld(div(now(), 1000)),
         {:ok, files} <- files(s, row),
         {:ok, held} <- waiter?(s, row) do
      Transport.Typed.turn(Turn.interactive(row, files, held), row.pid == pid)
    else
      nil -> {:refused, :no_row}
      {_, why} -> {:refused, why}
    end
  end

  defp files(s, row) do
    with {:ok, _} <- Registry.read(s.typed.registry, timeout: @step),
         {:ok, %{rows: files}} <- Registry.rows(s.typed.registry, row.account, timeout: @step),
         do: {:ok, files}
  end

  # A typed row's evidence: the waiter's, and whether the turn reads ended now.
  defp typed_seen(s, m) do
    srow = s.agents |> Agents.get(m.to_agent) |> Agents.unheld(div(now(), 1000))

    ended =
      with %{} <- srow,
           {:ok, files} <- files(s, srow) do
        Turn.interactive(srow, files, false) in [:idle, :ended]
      else
        _ -> false
      end

    Map.put(seen(s, m), :ended, ended)
  end

  defp bound(s, sent_at),
    do: Process.send_after(self(), :bound, max(sent_at + s.waiter.bound - now(), 0) + 1)

  # A text the Inlet, or the pointer's file, refused starts its row's wait bound.
  # Its wake line goes at once, not at the next cue.
  defp refused(s, m) do
    m = Table.get(s.db, m.id)

    if Transport.Typed.text_refused?(m.attempt) do
      wait_timer(s, m)
      send(self(), :bound)
    end
  end

  # A refused row's wait bound runs from its wake line's mark, or with none yet from the
  # refusal, its last write (`updated_at`): nothing else writes the row while it waits, and a
  # restart reads the same time.
  defp waited?(s, m), do: now() >= waits_from(m) + s.typed.wait_bound

  defp waits_from(m), do: m.woke_at || m.updated_at

  defp wait_timer(%{typed: nil}, _m), do: :ok

  defp wait_timer(s, m),
    do: Process.send_after(self(), :bound, max(waits_from(m) + s.typed.wait_bound - now(), 0) + 1)

  defp now, do: System.os_time(:millisecond)

  # The waiter's evidence for row `m`: its lines in the transcript of its session, read now
  # from the offset its mark kept, and whether the process it was handed to is gone.
  defp seen(s, m) do
    srow = Agents.get(s.agents, m.to_agent)
    gone = srow == nil or srow.pid != m.at or Agents.free?(srow)
    %{seen: lines(s, srow, m), gone: gone, now: now(), bound: s.waiter.bound}
  end

  # A launch row's evidence: its own user line (`Transport.Launch.seen/2`), and whether the
  # start's process is gone: before the start's answer the row names no process, and the start
  # is gone once its agent row holds none. Its session is the agent row's when the mark had none
  # (a new session, a restart before the answer).
  defp launch_seen(s, m) do
    srow = Agents.get(s.agents, m.to_agent)
    gone = srow == nil or Agents.free?(srow) or (m.at != nil and srow.pid != m.at)
    m = %{m | session_id: m.session_id || (srow && srow.session_id)}

    seen =
      if is_binary(m.session_id),
        do: lines(s, srow, m, &Transport.Launch.seen/2),
        else: :none

    %{seen: seen, gone: gone}
  end

  defp lines(s, srow, m, seen \\ &Transport.Waiter.seen/2) do
    with %{} <- srow,
         {:ok, path} <- transcript(s, srow),
         {:ok, %{failed: []}} <-
           Transcripts.read(s.waiter.transcripts, [{srow.account, m.session_id, path}],
             timeout: @step
           ),
         {:ok, %{bytes: bytes}} <-
           Transcripts.text(s.waiter.transcripts, srow.account, m.session_id, m.from_byte || 0,
             timeout: @step
           ) do
      seen.(bytes, m.uuid)
    else
      {:refused, :no_file} -> :none
      _ -> :unread
    end
  end

  # How much of the session's transcript is read now: a row's lines come after it.
  defp offset(s, srow) do
    with {:ok, path} <- transcript(s, srow),
         {:ok, _} <-
           Transcripts.read(s.waiter.transcripts, [{srow.account, srow.session_id, path}],
             timeout: @step
           ),
         {:ok, %{offset: offset}} <-
           Transcripts.session(s.waiter.transcripts, srow.account, srow.session_id,
             timeout: @step
           ) do
      offset
    else
      _ -> 0
    end
  end

  defp transcript(s, srow) do
    with {:ok, dir} <- Accounts.config_dir(s.waiter.accounts, srow.account),
         do: Transcripts.path(dir, srow.cwd, srow.session_id)
  end

  # Into an ended turn of the current process only, never to a session whose row is stopping:
  # `Sessions`' turn function for a headless session.
  defp ready?(srow, fold), do: Turn.headless(srow, fold) == :ended

  # The call transport's take: each waiting call whose row is due, first among its addressee's
  # rows from its sender, with none to it in flight, takes it now, before its deadline.
  defp take_waiting(s) do
    Enum.reduce(s.waits, s, fn {key, w}, s ->
      with %{status: "queued", to_agent: to} = m <- Table.answer(s.db, key),
           true <- to == w.to and first?(s, m) do
        take(s, key, w, m)
      else
        _ -> s
      end
    end)
  end

  defp first?(s, m) do
    rows = for %{to_agent: to} = r <- Table.open_rows(s.db), to == m.to_agent, do: r

    not Enum.any?(rows, &(&1.status == "sending")) and
      not Enum.any?(rows, fn r ->
        r.id != m.id and r.status == "queued" and r.from_agent == m.from_agent and
          (r.again > m.again or (r.again == m.again and r.id < m.id))
      end)
  end

  defp take(s, key, w, m) do
    Process.cancel_timer(w.timer)
    s = %{s | waits: Map.delete(s.waits, key)}

    if System.monotonic_time(:millisecond) < w.deadline do
      write(s, m, status: "sending", via: "call", at: nil, attempt: nil)
      {pid, _tag} = w.from
      GenServer.reply(w.from, {:ok, %{id: m.id, from: m.from_agent, kind: m.kind, text: m.text}})
      put_in(s.calls[m.id], Process.monitor(pid))
    else
      GenServer.reply(w.from, {:unknown, :timeout})
      s
    end
  end

  defp unwatch(s, id) do
    {ref, calls} = Map.pop(s.calls, id)
    if ref, do: Process.demonitor(ref, [:flush])
    %{s | calls: calls}
  end

  defp write(s, m, fields) do
    Table.update(s.db, m.id, fields)
    announce(s, m.id)
  end

  defp announce(s, id), do: s.notify.(%{topic: "mailbox", ids: [id]})
end
