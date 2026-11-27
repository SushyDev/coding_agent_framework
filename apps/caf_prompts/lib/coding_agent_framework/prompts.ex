defmodule CodingAgentFramework.Prompts do
  @moduledoc """
  One inbox of prompts (`docs/design.md`, "Prompts", B6; `model/tla/Prompt.tla`): every request
  that waits on a person, whatever asked it and however deep in the tree, read in one place and
  answered in one place.

  **No row of its own.** A prompt is its owner's row, read by one function (`list/2`), so the
  inbox never lags or disagrees with the mechanism that applies the answer:

  | kind | the owner's row | open while |
  | --- | --- | --- |
  | `permission` | `Intake`'s hold of a `PermissionRequest` (a subagent's included; `subagent` names it) | the hold is `held` |
  | `permission` | a headless delegate's `can_use_tool` request, held in its `Stream` fold (F-189's new-2) | the request is `held` |
  | `stop_cap` | `Intake`'s hold of a `Stop` at Claude Code's cap of blocks in a row | the hold is `held` |
  | `dialog` | `Sessions`' agent row on a startup dialog (`trust`, `imports`, a start's menu `start_menu`, F-203) | the row shows it, no press marked |
  | `dialog` | `Sessions`' running row whose screen shows a numbered menu no rule names (F-198, `Sessions.Menu`) | the row's last read of its pane found it, and no press of it was sent |
  | `ask` | `Mailbox`'s ask, from an agent to the operator | no answer row and no withdrawal |
  | `remedy` | `Watch`'s symptom state the healer left to a person (F-182) | the row is `asked` |
  | `remedy` | the same row answered `act` (F-196), shown `answering` | no row in `Acts` of that act has ended, and its state did not pass before its act (F-203) |
  | `login` | `Logins`' row of an account whose login a check refused (F-181) | no check found it logged in since |
  | `limit` | `Sessions`' agent row at a usage limit the healer left to a person (F-186) | its step is `prompt` |
  | `usage_credits` | `Sessions`' agent row on the usage limit menu, the account able to spend | its step is `credits` |
  | `limit` | `Delegates`' or `Mains`' start row refused at a usage limit (F-196) | the row is `waiting`, not answered for this reset |

  A later kind is one more clause of `list/2` and of `answer/5`, and the same data.

  Each prompt is `%{id, kind, status, agent, parent, project, subagent, text, options,
  opened_at, deadline, hidden}`: `id` names its owner's key, so one state is one prompt
  (`"permission:<intake id>"`, `"permission:stream:<session>:<request id>"`,
  `"stop_cap:<intake id>"`, `"dialog:<agent>:<start>:<dialog>"`,
  `"dialog:<agent>:<at>:start_menu"` and `"dialog:<agent>:<at>:menu"` (`at` the wall-clock ms
  of the read that found the menu, a start's or a running screen's, so each menu of one start
  is its own prompt, F-206),
  `"ask:<mailbox id>"`, `"remedy:<symptom id>"`, `"login:<account>:<refused_at>"` (`refused_at`
  the wall-clock ms of the check that refused it, so an account refused again after a login
  is a new prompt, F-205), `"limit:<agent>:<until>"`,
  `"usage_credits:<agent>:<until>"`, `"limit:start:delegate:<row>"` and `"limit:start:main:<row>"`);
  `status` is `open`, `answering` (an answer is on its way to the owner; for a remedy answered
  `act`, its act not yet ended),
  or for a dialog `cut` or `unknown` (a restart cut its press: a person clears it,
  `Sessions.clear_dialog/4`); `agent` is the agent whose session asks (nil for a session no
  agent row names; a remedy's is its symptom's target when an agent row has that name; a
  login's is nil, since an account waits, not an agent),
  `parent` and `project` its row's; `options` the labels a choice is one of,
  or for an ask its questions, each with its options; `opened_at` and `deadline` wall-clock ms,
  `deadline` nil for a kind that waits for ever (a stream's request among them: Claude Code
  waits on the stream for its answer); `hidden` nil, or `%{by, at}` for a prompt a person set
  aside (`hide/3`). A `usage_credits` prompt has the deadline the
  healer set, whose default is the stop, the healer's (`CodingAgentFramework.Limits`); an
  agent's `limit` prompt has none, and a start's has its row's: the reset plus the margin, at
  which its owner takes the default, the wait, and picks its account again.

  **A remedy answered `act`** (F-196, from F-193's new-2): the person's act is the healer's to
  take at its next check, under a claim in `Acts` whose actor is the person and whose detail's
  `symptom` is the state. With `acts_db:` the prompt stays, `answering`, until that row has
  ended (settled or interrupted), and then leaves the inbox: its outcome is the act's row, a
  fault in the fault ledger when it failed. A state the healer no longer reads before it takes
  the act (the viewer came back, the main resumed by itself) is `passed` by `Watch.pass/4` with
  no row in `Acts`, and the prompt leaves then, its outcome "passed before its act" (F-203).

  **One answer.** `answer/5` checks the prompt read now (still open, the choice one it offers)
  and hands the choice to its owner, whose own guard is the claim that lets one answer in
  (`Prompt.tla`'s `Answer` and `AnswerNow`): a hold moves only from `held` (an `Intake` row's,
  or a `Stream` request's, marked `answering` before its line is written), an ask's answer row
  and its withdrawal share one unique key, a dialog's press is marked before it goes. A late or
  second answer is refused `{:refused, :settled}`, whichever of the two checks finds it. Each
  answer the checks let through is one row in `Acts` (`answering/4`), claimed before the owner
  takes it and settled by the owner's answer, so who answered, and when, is read from the
  ledger (F-194).

  **Each open a fact** (F-202). The first read that lists a prompt records its open in `Acts`
  (`Acts.record/7`, actor `prompts:<host>`, act `opened`, keyed `opened:<host>:<prompt id>`),
  its `detail` the prompt's id, kind, agent, `opened_at`, and (F-254) its parent, project,
  subagent, text and options. A dialog, login or limit prompt never answered still counts, with
  its open time. The read before an answer records it too, so every prompt answered here has one.

  **Closed prompts** (F-254, `answered/3`). A prompt that left the inbox has no owner's row that
  still shows it, so it is read from the ledger alone: its `opened` fact (what was asked), its
  `answer` row (who chose what, and when) and its `closed` fact (who closed it, F-270). No copy
  is kept; open prompts keep no row of their own.

  **Each close a fact** (F-270, from F-254's new-1). The read that finds a prompt it listed
  before no longer open records its close in `Acts` (`Acts.record/7`, actor `prompts:<host>`,
  act `closed`, keyed `closed:<host>:<prompt id>`, target as its `opened` fact), its `detail`
  the prompt's id, kind and `by`, who closed it, read from its owner's row in that read.
  `answered/3` reads it as the closed prompt's `by` and `at`. A close no read saw (the inbox
  was down) is recorded by the first `answered/3` page that holds it, `late`, with no time.
  Every place a prompt closes, and its `by`, never nil:

  | kind | it closes when | `by` |
  | --- | --- | --- |
  | any | an answer through `answer/5` is taken, or handed on with its outcome unknown | the answer's `who` (the answer row's actor) |
  | `permission`, `stop_cap` | `Intake` decides the hold otherwise: the app's callback, a pause, the cap | the hold's `actor` (`app`, `pause`, `capped`, a name) |
  | `permission`, `stop_cap` | the hold's deadline passes | `{:framework, :expired}` |
  | `permission`, `stop_cap` | the hold passes with no actor, or its decision's write is unknown | `{:framework, :passed}`, `{:framework, :unknown}` |
  | `permission` (a hook's or a stream's) | Claude Code stops waiting on it (its hook's connection closed, or its request left the fold): answered on its screen, or its session ended | `{:framework, :withdrawn}`, `{:framework, :ended}` once its agent row ended or stopped |
  | `dialog` | a startup dialog the app's callback or the config pressed | that press's act's actor in `Acts` |
  | `dialog` | the screen no longer shows it with no press of ours (answered on the pane), or its start stopped | `{:framework, :withdrawn}`, `{:framework, :ended}` |
  | `ask` | only by `answer/5` (an answer or a withdrawal) | the answer's `who`; one answered before F-194 has no answer row, and reads `{:framework, :passed}` |
  | `remedy` | the `Watch`'s row answered elsewhere (a healer copying a person's answer, F-183), or its state passed | the row's `answered_by`; `{:framework, :passed}` |
  | `login` | a check before a start or a resume finds the account logged in | `{:framework, :logged_in}` |
  | start's `limit` | its deadline passes: its owner takes the wait | `{:framework, :default}`, else `{:framework, :passed}` |
  | `usage_credits` | its deadline passes: the healer takes the stop | `{:framework, :default}` |
  | `limit` (an agent's) | the limit leaves its row (a reset, a turn after it) | `{:framework, :passed}` |
  | any with an agent | its agent row ended or stopped first | `{:framework, :ended}` |

  `{:framework, why}` names the framework's own close: `:expired` (a deadline passed, no
  default), `:default` (a deadline passed and its owner took its kind's default), `:ended`,
  `:withdrawn` (Claude Code or its screen no longer waits on it, no answer of ours), `:passed`
  (its owner's row moved on by its own rule), `:unknown` and `:logged_in`. It is read from the
  owner's row when the inbox sees the close, so for a `late` one it is the row as it is then.

  **A hidden mark** (F-254, `hide/3`, `unhide/3`). A person sets a prompt aside: it stays open
  and answerable, its owner and its answer path unchanged, and `read/3` shows `hidden: %{by,
  at}`. The mark is a fact in `Acts` (act `hide` or `unhide`, actor the person, target the
  prompt's id), the latest one wins, and nothing that answers a prompt reads it. A closed
  prompt's marks are ignored: they are read only for the prompts open now.

  **The parent told once.** When a delegate's prompt opens, its parent gets one notice through
  `Mailbox` (`Mailbox.notify/4`, kind `prompt`, from the delegate): ``From <delegate> (prompt):
  waiting on <kind>: <text> (prompt <id>)``, stored under the prompt's id, so a read after a
  restart finds it stored and the parent reads it once (`Prompt.tla`'s `ParentToldOnce`). A
  builder waiting on a dialog is so never read as idle with no word.

  **Cues.** It reads again on each cue of its owners (`reads/0`), and after a read that opened,
  moved or closed a prompt it calls `notify` with `%{topic: "prompts", ids: ids}`, the ids of
  those prompts: the inbox's one topic. The embedding app's tree starts one per instance.
  """

  use GenServer

  alias CodingAgentFramework.{Acts, Delegates, Intake, Logins, Mailbox, Mains, Sessions, Stream}
  alias CodingAgentFramework.{Store, Watch}
  alias CodingAgentFramework.Sessions.{Agents, Dialog, Limit, Menu}

  @timeout 5_000
  # The most characters of a tool call's input a permission prompt's text carries.
  @input 300

  @kinds ~w(permission stop_cap dialog ask remedy login limit usage_credits)

  @typedoc "A prompt, as the module doc says."
  @type prompt :: %{
          id: String.t(),
          kind: String.t(),
          status: String.t(),
          agent: String.t() | nil,
          parent: String.t() | nil,
          project: String.t() | nil,
          subagent: String.t() | nil,
          text: String.t(),
          options: list,
          opened_at: integer | nil,
          deadline: integer | nil,
          hidden: %{by: String.t(), at: integer} | nil
        }

  @typedoc "A closed prompt, as `answered/3` says."
  @type closed :: %{
          id: String.t(),
          kind: String.t(),
          status: String.t(),
          agent: String.t() | nil,
          parent: String.t() | nil,
          project: String.t() | nil,
          subagent: String.t() | nil,
          text: String.t() | nil,
          options: list | nil,
          opened_at: integer | nil,
          choice: term,
          by: String.t() | {:framework, atom},
          at: integer | nil,
          reason: term
        }

  # The most closed prompts one page of `answered/3` holds, and its default.
  @page 200
  @default_page 50

  @doc """
  Starts the inbox of one host. Options: `host:`, `intake:` (the host's `Intake`) and
  `intake_db:` (its file), `sessions:` (the `Sessions`) and `sessions_db:` (its file), `mailbox:`,
  `watch:` (the `Watch`) and `watch_db:` (its file), `acts:` (where each answer is a row,
  `answering/4`), and optionally `logins:` (the instance's
  `Logins`) with `logins_db:` (its file), `stream:` (the host's `Stream`) with `stream_db:` (its
  file), `delegates:` and `delegates_db:`, `mains:` and `mains_db:` (the starts that wait at a
  usage limit, F-196), `acts_db:` (`acts:`'s file, where a remedy answered `act` is read),
  `notify:` (a function of one cue) and `name:` (for the embedding app's tree; the library
  looks up no name).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc """
  The topics of the cues it writes, each as its whole shape (`CodingAgentFramework.Cues`):
  `prompts`.
  """
  @spec writes() :: [String.t()]
  def writes, do: ~w(prompts)

  @doc "What it reads, for `Cues`: its owners' topics, each cue a read of every prompt."
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads,
    do: %{
      topics: ~w(intake sessions mailbox watch logins stream delegates mains acts),
      cue: &cue/2
    }

  @doc "The kinds it reads."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Hands it an owner's cue: the prompts are read again. Answers `:ok` at once."
  @spec cue(GenServer.server(), map) :: :ok
  def cue(prompts, _cue), do: GenServer.cast(prompts, :read)

  @doc """
  The prompts open now, oldest first, within `filter`: `agent:` (that agent's), `subtree:` (that
  agent's and every agent's under it), `kind:` (one of `kinds/0`), `hidden:` (`false` leaves out
  the prompts a person set aside, `true` keeps only those). Answers `{:ok, prompts}`,
  `{:refused, {:bad, :filter}}`, or `{:unknown, reason}` when an owner did not answer.

      Prompts.read(prompts, subtree: "app-main", kind: "permission", hidden: false)
      #=> {:ok, [%{id: "permission:41", kind: "permission", agent: "app-unit", hidden: nil, …}]}
  """
  @spec read(GenServer.server(), keyword, keyword) ::
          {:ok, [prompt]} | {:refused, term} | {:unknown, term}
  def read(prompts, filter \\ [], opts \\ []) do
    with :ok <- check_filter(filter), do: call(prompts, {:read, filter}, opts)
  end

  @doc """
  The prompts that closed, newest open first, one page of at most `limit:` (1 to #{@page},
  #{@default_page} by default), the next older page from `before:` (the last page's `next`),
  and only agent `agent:`'s when it is given (F-270): the prompts whose `agent` is that name,
  as `read/3`'s `agent:` reads open ones. That is the agent whose wait it is: the asker of an
  ask, a permission or a dialog, the agent a start waits to start as, and the agent a remedy is
  about. It is the agent an `opened` fact is keyed by, so the filter is a term of the ledger's
  query, on its index, and the page is bounded as without it.
  It is a separate read from `read/3`, not a filter on it, since a closed prompt has no owner's
  row: it is read from the ledger, its `opened` fact, its `answer` row and its `closed` fact in
  `Acts`.

  Each is `%{id, kind, status, agent, parent, project, subagent, text, options, opened_at,
  choice, by, at, reason}`: `status` is

  - `answered`: its answer through `answer/5` was taken; `choice` as given (JSON's terms: an
    ask's answers one per question, a deny with its message `["deny", message]`), `by` who
    answered (a person, the app, or an agent's parent by its name), `at` when (ms);
  - `withdrawn`: an ask withdrawn through `answer/5`; `reason` the reason the agent read;
  - `unknown`: an answer was handed on and its owner did not say whether it took it; `reason`
    the owner's answer;
  - `closed`: it left with no answer through the inbox: `choice` is nil, and `by` names who
    closed it, never nil (the module doc's "Each close a fact"): the actor its owner recorded
    (`app` for the app's callback, a name), or `{:framework, why}` for a close of the
    framework's, `why` one of `:expired`, `:default`, `:ended`, `:withdrawn`, `:passed`,
    `:unknown` and `:logged_in`. `at` is when the inbox saw it close, nil for a close found
    only by this read.

  It pages by when each prompt opened, since that is a fact for every prompt. Answers `{:ok,
  %{prompts: closed, next: cursor}}`, `next` nil for a page shorter than its limit (the last);
  `{:refused, {:bad, key}}` for a key it does not take or a value it does not (`limit:` out of
  range, say), `{:refused, {:bad, :filter}}` for a filter that is not a keyword list,
  `{:refused, :no_ledger}` for an inbox started with no `acts_db:`, or `{:unknown, reason}`.

      Prompts.answered(prompts, agent: "app-unit", limit: 20)
      #=> {:ok, %{prompts: [%{id: "ask:12", status: "answered", by: "sam", …}], next: 431}}
      Prompts.answered(prompts, kind: "ask")
      #=> {:refused, {:bad, :kind}}
  """
  @spec answered(GenServer.server(), keyword, keyword) ::
          {:ok, %{prompts: [closed], next: integer | nil}} | {:refused, term} | {:unknown, term}
  def answered(prompts, filter \\ [], opts \\ []) do
    with true <- Keyword.keyword?(filter) or {:refused, {:bad, :filter}},
         :ok <- page_filter(filter) do
      page = {Keyword.get(filter, :limit, @default_page), filter[:before], filter[:agent]}
      call(prompts, {:answered, page}, opts)
    end
  end

  # Each key named, so a caller reads which one it got wrong.
  defp page_filter(filter) do
    Enum.find_value(filter, :ok, fn
      {:limit, n} when is_integer(n) and n in 1..@page -> nil
      {:before, id} when is_integer(id) -> nil
      {:agent, name} when is_binary(name) and name != "" -> nil
      {key, _} -> {:refused, {:bad, key}}
    end)
  end

  @doc """
  Sets open prompt `id` aside for `who`, a person: it stays open and answerable, and `read/3`
  shows it `hidden: %{by: who, at: ms}`. The mark is a fact in `Acts` (act `hide`), and nothing
  that answers a prompt reads it. Answers `{:ok, %{by, at}}`; `{:refused, {:hidden, mark}}`
  when it is hidden already; `{:refused, :settled}` or `{:refused, :no_prompt}` for one not
  open, as `answer/5`; `{:refused, {:bad, :who}}`; `{:refused, :no_ledger}`.

      Prompts.hide(prompts, "ask:12", "sam")
      #=> {:ok, %{by: "sam", at: 1_764_000_000_000}}
  """
  @spec hide(GenServer.server(), String.t(), String.t(), keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def hide(prompts, id, who, opts \\ []), do: mark(prompts, id, who, :hide, opts)

  @doc """
  Brings hidden prompt `id` back, for `who`: a fact in `Acts` (act `unhide`), after which
  `read/3` shows it `hidden: nil`. Answers `{:ok, nil}`; `{:refused, :not_hidden}`; or as
  `hide/3`.

      Prompts.unhide(prompts, "ask:12", "sam")
      #=> {:ok, nil}
  """
  @spec unhide(GenServer.server(), String.t(), String.t(), keyword) ::
          {:ok, nil} | {:refused, term} | {:unknown, term}
  def unhide(prompts, id, who, opts \\ []), do: mark(prompts, id, who, :unhide, opts)

  defp mark(prompts, id, who, act, opts) do
    if is_binary(who) and String.trim(who) != "" and is_binary(id),
      do: call(prompts, {:mark, id, who, act}, opts),
      else: {:refused, {:bad, :who}}
  end

  @doc """
  Answers prompt `id` with `choice`, as `who` (a person's name, or the app's), once:

  - `permission`: `"allow"`, `"deny"`, or `{"deny", message}` (the agent reads the message);
  - `stop_cap`: `"go_on"` (the cap's last block Claude Code honors) or `"end"` (the turn ends);
  - `dialog`: one of its options' labels; for a menu (`…:menu`), also `"esc"`, which presses
    Escape (`Sessions.answer_menu/5`: the marker moved to the label and read back on it before
    Enter). A menu has no default and no deadline: only a person's answer presses it, and its
    prompt leaves once a read of the pane no longer finds it, whoever answered;
  - `ask`: one answer per question, as `Mailbox.answer/4` takes them, or `{:withdraw, reason}`
    (a person dismissed it, `Mailbox.withdraw/4`: one more settle);
  - `remedy`: `"approve"` (its kind's remedy back on the allow-list, the operator's widening)
    or `"leave"` (`Watch.answer/5`); for a state asked for its bound, `"act"` (the remedy once,
    which its healer takes at its next check under `who`'s claim, F-189's new-7) or `"leave"`;
  - `login`: `"check"`, once a person logged the account in (`bin/caf-login`): its login is
    checked again now (`Logins.recheck/3`), and the prompt closes when it is logged in. Its
    id, `login:<account>:<refused_at>`, names the refusal: an account refused again after a
    login is a new prompt with a new id, and the old id answers `{:refused, :settled}`;
  - a start's `limit` (`limit:start:…`): `"wait"` (its default: the row waits for its reset,
    and the prompt leaves) or `"leave"` (the row refused `left`, its parent told),
    `Delegates.answer_wait/4` or `Mains.answer_wait/4`;
  - `limit`: `"go_on"` (the healer reads the screen again and the go-ons in a row start again)
    or `"leave"` (nothing more acts on that limit), and `"move"` where it offers one (a main's
    limit far from its reset, F-191: the healer moves it to the account the prompt names, the
    person's act); `usage_credits`: one of its options' labels,
    the menu's stop or its usage credits (`Sessions.answer_limit/6`).

  The prompt is read now and must be `open`, and the choice one it offers; the owner then takes
  it (`Intake.answer/4` with `by: who`, `Sessions.answer_dialog/5` with `by: who`,
  `Mailbox.answer/4` or `Mailbox.withdraw/4`), in the caller's process. Answers the owner's
  `{:ok, value}`; `{:refused, :settled}` for a prompt answered, withdrawn, expired or gone since
  it opened, or answered on the pane first; `{:refused, :no_prompt}` for an id no owner has;
  `{:refused, {:bad, :choice}}` or `{:refused, {:bad, :who}}`; `{:refused, {:status, status}}`
  for a dialog's press a restart cut; or the owner's other answers. Option `:timeout` (ms) for
  the read; the owner's call has its own bound.

      Prompts.answer(prompts, "permission:41", "allow", "person")
      #=> {:ok, :sent}
      Prompts.answer(prompts, "permission:41", "deny", "person")
      #=> {:refused, :settled}
  """
  @spec answer(GenServer.server(), String.t(), term, String.t(), keyword) ::
          {:ok, term} | {:refused, term} | {:unknown, term}
  def answer(prompts, id, choice, who, opts \\ []) do
    with true <- (is_binary(who) and String.trim(who) != "") or {:refused, {:bad, :who}},
         {:ok, prompt, owners} <- call(prompts, {:get, id}, opts),
         true <- prompt.status == "open" or refused_status(prompt.status),
         {:ok, act} <- choose(prompt, choice, who),
         {:ok, row} <- answering(owners.acts, prompt, choice, who) do
      answer = hand(owners, prompt, act, who)
      Acts.answered(owners.acts, row, answer)
      answer
    end
  end

  @doc """
  The answer's row in `Acts` (F-194, from F-179's new-4), claimed before the owner takes the
  answer and settled by the owner's answer (`Acts.answered/4`): actor `who`, target the prompt's
  agent (its id when it has none, a login's), act `answer`, no state (each answer is an act of
  its own: one the owner refused leaves the prompt open for the next), and in its `detail` the
  prompt's `prompt` id, `kind`, `choice` as given, `opened_at` and `subagent`. Its `claimed_at`
  is when it was answered, so the time to answer is read from the row, never guessed.

      Prompts.answering(acts, %{id: "permission:41", kind: "permission", agent: "app-unit",
        opened_at: 1_000, subagent: nil}, "allow", "sam")
      #=> {:ok, 12}
  """
  @spec answering(GenServer.server(), prompt, term, String.t()) ::
          {:ok, Acts.id()} | {:refused, term} | {:unknown, term}
  def answering(acts, prompt, choice, who) do
    detail = %{
      prompt: prompt.id,
      kind: prompt.kind,
      choice: choice,
      opened_at: prompt.opened_at,
      subagent: prompt.subagent
    }

    Acts.claim(acts, who, prompt.agent || prompt.id, nil, :answer, detail: detail)
  end

  @doc """
  Answers the startup dialog `kind` (`"trust"`, `"imports"`) agent `agent` shows, by its option
  `label`, as `who`: `answer/5` of that dialog's prompt, for a caller that names the agent and
  the dialog rather than the prompt (the operator's `answer_startup`). Answers as `answer/5`;
  `{:refused, :settled}` when the agent's row shows no such dialog but did once (its start went
  on, or it was answered), `{:refused, :no_prompt}` for an agent with no row.

      Prompts.answer_startup(prompts, "app-main", "trust", "Yes, I trust this folder", "operator")
      #=> {:ok, :sent}
  """
  @spec answer_startup(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword
        ) ::
          {:ok, term} | {:refused, term} | {:unknown, term}
  def answer_startup(prompts, agent, kind, label, who, opts \\ []) do
    with {:ok, shown} <- read(prompts, [agent: agent, kind: "dialog"], opts) do
      case Enum.find(shown, &String.ends_with?(&1.id, ":" <> to_string(kind))) do
        %{id: id} -> answer(prompts, id, label, who, opts)
        nil -> answer(prompts, "dialog:#{agent}::#{kind}", label, who, opts)
      end
    end
  end

  defp refused_status("answering"), do: {:refused, :settled}
  defp refused_status(status), do: {:refused, {:status, status}}

  defp call(prompts, request, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    GenServer.call(prompts, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_prompts}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @timeout)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)

    with {:ok, idb} <- Intake.Table.open(Keyword.fetch!(opts, :intake_db)),
         {:ok, agents} <- Agents.open(Keyword.fetch!(opts, :sessions_db), host),
         {:ok, wdb} <- Watch.Table.open(Keyword.fetch!(opts, :watch_db)),
         {:ok, ldb} <- logins_db(opts[:logins_db]),
         {:ok, sdb} <- stream_db(opts[:stream_db]),
         {:ok, ddb} <- maybe(opts[:delegates_db], &Delegates.Table.open_read/1),
         {:ok, mdb} <- maybe(opts[:mains_db], &Mains.Starts.open/1),
         {:ok, adb} <- maybe(opts[:acts_db], &Acts.Table.open/1) do
      owners = Map.new(~w(intake sessions mailbox watch acts)a, &{&1, Keyword.fetch!(opts, &1)})
      owners = Map.merge(owners, %{delegates: opts[:delegates], mains: opts[:mains]})

      s = %{
        host: host,
        idb: idb,
        agents: agents,
        wdb: wdb,
        ldb: ldb,
        sdb: sdb,
        ddb: ddb,
        mdb: mdb,
        adb: adb,
        # A dialog's press waits `Sessions`' own bound, which it asks of `Sessions` (F-245).
        owners: Map.merge(owners, %{logins: opts[:logins], stream: opts[:stream]}),
        notify: Keyword.get(opts, :notify, fn _ -> :ok end),
        # id -> status, as the last read found them: what the next cue says moved.
        shown: %{},
        # The prompts whose parent was told since this start; Mailbox's key keeps it once
        # across starts, and this keeps it to one call per start.
        told: MapSet.new(),
        # The prompts whose open is recorded in `Acts` since this start, the same way.
        opened: MapSet.new(),
        # id -> prompt, as the last read found them, and those gone whose close is not yet
        # written: a prompt in it that a read no longer lists has closed (F-270).
        seen: %{}
      }

      {:ok, s, {:continue, :read}}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  defp logins_db(nil), do: {:ok, nil}
  defp logins_db(path), do: Logins.Table.open(path)

  defp stream_db(nil), do: {:ok, nil}
  defp stream_db(path), do: Stream.Table.open(path)

  defp maybe(nil, _open), do: {:ok, nil}
  defp maybe(path, open), do: open.(path)

  @impl true
  def handle_continue(:read, s), do: {:noreply, reread(s)}

  @impl true
  def handle_cast(:read, s), do: {:noreply, reread(s)}

  @impl true
  def handle_call({:read, filter}, _from, s) do
    reply =
      with {:ok, all} <- list(s), do: {:ok, filtered(all, filter, Agents.rows(s.agents))}

    {:reply, reply, s}
  end

  # The read before an answer records each open too (F-254), so every prompt answered here has
  # its `opened` fact, which `answered/3` reads.
  def handle_call({:get, id}, _from, s) do
    case list(s) do
      {:ok, all} ->
        reply =
          case Enum.find(all, &(&1.id == id)) do
            nil -> gone(s, id)
            prompt -> {:ok, prompt, s.owners}
          end

        {:reply, reply, opened(s, all)}

      unread ->
        {:reply, unread, s}
    end
  end

  def handle_call(_closed_or_mark, _from, %{adb: nil} = s),
    do: {:reply, {:refused, :no_ledger}, s}

  def handle_call({:answered, {limit, before, agent}}, _from, s) do
    reply =
      with {:ok, all} <- list(s) do
        open = MapSet.new(all, & &1.id)
        facts = opened_facts(s, limit + MapSet.size(open), before, agent)
        page = facts |> Enum.reject(&(&1.id in open)) |> Enum.take(limit)
        answers = answers(s, page)
        next = if length(page) == limit, do: List.last(page).fact

        # A close the inbox did not see (it closed while the inbox was down, or before F-270)
        # is named now, once, from its owner's row as it is now.
        shut = shut(s, page)

        late =
          for p <- page, shut[p.id] == nil, taken(answers[p.id] || []) == nil, do: p

        shut =
          if late == [],
            do: shut,
            else: Enum.each(late, &close(s, &1, true)) && shut(s, page)

        {:ok,
         %{prompts: Enum.map(page, &closed(&1, answers[&1.id] || [], shut[&1.id])), next: next}}
      end

    {:reply, reply, s}
  end

  # One step in this process, so two marks of one prompt are taken in turn and each checks the
  # one before it. Its write cues `acts`, and the read again here cues `prompts` at once.
  def handle_call({:mark, id, who, act}, _from, s) do
    with {:ok, all} <- list(s),
         {:ok, prompt} <- shown(s, all, id),
         :ok <- markable(prompt.hidden, act),
         {:ok, _} <- Acts.record(s.owners.acts, who, id, act, :verified) do
      {:reply, {:ok, marks(s, [id])[id]}, reread(s)}
    else
      other -> {:reply, other, s}
    end
  end

  defp shown(s, all, id) do
    case Enum.find(all, &(&1.id == id)) do
      nil -> gone(s, id)
      prompt -> {:ok, prompt}
    end
  end

  defp markable(nil, :hide), do: :ok
  defp markable(mark, :hide), do: {:refused, {:hidden, mark}}
  defp markable(nil, :unhide), do: {:refused, :not_hidden}
  defp markable(_mark, :unhide), do: :ok

  # The newest `opened` facts of this host before the cursor, and of one agent when `agent` names
  # it (the fact's target, F-270), as prompts: `n` covers a page whatever of them is open now.
  defp opened_facts(s, n, before, agent) do
    args = ["prompts:" <> s.host] ++ List.wrap(before) ++ List.wrap(agent)
    cursor = if before, do: " AND id < ?2", else: ""
    target = if agent, do: " AND target = ?#{length(args)}", else: ""
    where = "actor = ?1 AND act = 'opened'#{cursor}#{target} ORDER BY id DESC LIMIT #{n}"

    for row <- Store.select(s.adb, "acts", Acts.Table.columns(), where, args),
        d = decode(row.detail),
        is_binary(d["prompt"]) do
      %{
        id: d["prompt"],
        kind: d["kind"],
        agent: d["agent"],
        parent: d["parent"],
        project: d["project"],
        subagent: d["subagent"],
        text: d["text"],
        options: d["options"],
        opened_at: d["opened_at"],
        deadline: d["deadline"],
        fact: row.id
      }
    end
  end

  # The `answer` rows of these prompts, by prompt id, oldest first. An answer's row is targeted
  # at the prompt's agent, or at its id when it has none (`answering/4`).
  defp answers(s, page) do
    of_prompts(s, page, "answer", fn acc, prompt, row ->
      Map.update(acc, prompt, [row], &(&1 ++ [row]))
    end)
  end

  # The `closed` fact of each of these prompts, by prompt id, targeted as its `opened` fact.
  defp shut(s, page), do: of_prompts(s, page, "closed", &Map.put(&1, &2, &3))

  defp of_prompts(_s, [], _act, _put), do: %{}

  defp of_prompts(s, page, act, put) do
    targets = page |> Enum.map(&(&1.agent || &1.id)) |> Enum.uniq()
    ids = MapSet.new(page, & &1.id)
    marks = Store.marks(length(targets), 2)
    where = "act = ?1 AND target IN (#{marks})"

    for row <- Acts.Table.select(s.adb, where, [act | targets]),
        prompt = decode(row.detail)["prompt"],
        prompt in ids,
        reduce: %{} do
      acc -> put.(acc, prompt, row)
    end
  end

  # An answer row that closed its prompt: the one taken, else one whose outcome is unknown. A
  # refused answer left it open, so it says nothing here.
  defp taken(rows) do
    Enum.find(rows, &(&1.outcome == "verified")) || Enum.find(rows, &(&1.outcome == "unknown"))
  end

  # A closed prompt by its answer rows, else by its `closed` fact (F-270): who closed it, and
  # when the inbox saw it, nil for a close found late.
  defp closed(fact, rows, shut) do
    base = Map.drop(fact, [:fact, :deadline])

    case taken(rows) do
      nil ->
        d = decode(shut && shut.detail)
        by = load_by(d["by"])
        at = if shut && d["late"] != true, do: shut.claimed_at
        Map.merge(base, %{status: "closed", choice: nil, by: by, at: at, reason: nil})

      row ->
        choice = decode(row.detail)["choice"]
        by = %{by: row.actor, at: row.claimed_at}

        case {row.outcome, fact.kind, choice} do
          {"verified", "ask", ["withdraw", reason]} ->
            Map.merge(base, Map.merge(by, %{status: "withdrawn", choice: nil, reason: reason}))

          {"verified", _, _} ->
            Map.merge(base, Map.merge(by, %{status: "answered", choice: choice, reason: nil}))

          {"unknown", _, _} ->
            Map.merge(
              base,
              Map.merge(by, %{status: "unknown", choice: choice, reason: row.reason})
            )
        end
    end
  end

  # A read of every prompt: what opened, moved or closed is cued, and a delegate's new prompt
  # is told to its parent. A read an owner did not answer decides nothing; the next cue reads
  # again.
  defp reread(s) do
    case list(s) do
      {:ok, all} ->
        # A mark set or taken back moves a prompt as its status does (F-254).
        now = Map.new(all, &{&1.id, {&1.status, &1.hidden}})
        moved = for {id, _} <- Map.merge(s.shown, now), s.shown[id] != now[id], do: id
        if moved != [], do: s.notify.(%{topic: "prompts", ids: Enum.sort(moved)})
        %{s | shown: now} |> opened(all) |> tell(all) |> closes(all)

      _unread ->
        s
    end
  end

  # Each prompt's open as a fact (F-202, from F-199's new-3), so one never answered still counts:
  # one row in `Acts` per prompt id, the first time a read lists it, actor `prompts:<host>`,
  # act `opened`, its `detail` the prompt's id, kind, agent and `opened_at` (its own, or this
  # read's time for a prompt that has none). Its key keeps it once across restarts; a record
  # not written is tried again at the next read.
  defp opened(s, all) do
    for p <- all, not MapSet.member?(s.opened, p.id), reduce: s do
      s ->
        at = p.opened_at || System.os_time(:millisecond)
        # What was asked, so a closed prompt reads from this fact alone (F-254), and its
        # deadline, by which a close found late is named (F-270).
        asked =
          Map.take(p, [:kind, :agent, :parent, :project, :subagent, :text, :options, :deadline])

        detail = [detail: Map.merge(asked, %{prompt: p.id, opened_at: at})]
        key = [state: "opened:#{s.host}:#{p.id}"]
        actor = "prompts:" <> s.host

        case Acts.record(s.owners.acts, actor, p.agent || p.id, :opened, :verified, detail, key) do
          {:ok, _} -> %{s | opened: MapSet.put(s.opened, p.id)}
          {:refused, {:already_claimed, _}} -> %{s | opened: MapSet.put(s.opened, p.id)}
          _not_written -> s
        end
    end
  end

  # Each close as a fact (F-270, from F-254's new-1): a prompt the last read listed and this one
  # does not has closed, and one row in `Acts` names who closed it (`closer/2`), read from its
  # owner's row now, in the read that found it gone. Actor `prompts:<host>`, act `closed`, keyed
  # `closed:<host>:<prompt id>`, so it is written once across restarts; one not written stays
  # in `seen` and is tried again at the next read. With no ledger file nothing is read back, so
  # nothing is written.
  defp closes(%{adb: nil} = s, _all), do: s

  defp closes(s, all) do
    open = Map.new(all, &{&1.id, &1})
    left = for {id, p} <- s.seen, not Map.has_key?(open, id), close(s, p, false) != :ok, do: p
    %{s | seen: Map.merge(Map.new(left, &{&1.id, &1}), open)}
  end

  # One close's fact. `late` marks one found by `answered/3` with no fact: when it closed is not
  # known, and its closer is read from its owner's row as it is now.
  defp close(s, p, late) do
    by = closer(s, p)
    detail = %{prompt: p.id, kind: p.kind, by: dump_by(by)}
    detail = if late, do: Map.put(detail, :late, true), else: detail
    key = [state: "closed:#{s.host}:#{p.id}"]
    actor = "prompts:" <> s.host

    case Acts.record(
           s.owners.acts,
           actor,
           p.agent || p.id,
           :closed,
           :verified,
           [detail: detail],
           key
         ) do
      {:ok, _} -> :ok
      {:refused, {:already_claimed, _}} -> :ok
      not_written -> not_written
    end
  end

  # Who closed prompt `p`, never nil: whoever answered it here (its answer row, taken or
  # unknown), else its owner's row's word, else `{:framework, why}` for the framework's close.
  defp closer(s, p) do
    case taken(answers(s, [p])[p.id] || []) do
      %{actor: actor} -> actor
      nil -> owned(s, p)
    end
  end

  # A hold names who decided it, or how it ended (`Intake.Table`'s `hold` and `actor`).
  defp owned(s, %{kind: kind, id: id} = p) when kind in ["permission", "stop_cap"] do
    case String.split(id, ":") do
      [_, n] ->
        case Intake.Table.rows_by_id(s.idb, [int(n)]) do
          [%{hold: hold, actor: actor}]
          when hold in ["answered", "passed"] and is_binary(actor) ->
            actor

          [%{hold: "expired"}] ->
            {:framework, :expired}

          [%{hold: "unknown"}] ->
            {:framework, :unknown}

          [%{hold: "passed"}] ->
            {:framework, :passed}

          _lost_or_none ->
            ended_or(s, p, :withdrawn)
        end

      _stream ->
        ended_or(s, p, :withdrawn)
    end
  end

  # A startup dialog pressed by the app's callback or the config names the press's act's actor;
  # one gone with no press of ours was answered on the pane, or its start ended.
  defp owned(s, %{kind: "dialog", id: id} = p) do
    with ["dialog", agent, _key, kind] when kind != "menu" <- String.split(id, ":"),
         %{} = row <- Agents.get(s.agents, agent),
         %{act: act} when is_integer(act) <-
           Enum.find_value(Dialog.answers(row), fn {k, a} ->
             if Atom.to_string(k) == kind and a.mark == "sent", do: a
           end),
         [%{actor: actor}] <- Acts.Table.select(s.adb, "id = ?1", [act]) do
      actor
    else
      _ -> ended_or(s, p, :withdrawn)
    end
  end

  # A remedy is the `Watch`'s wait about an agent, not the agent's: its state passed, or a
  # person's answer was copied onto its row elsewhere (F-183).
  defp owned(s, %{kind: "remedy", id: "remedy:" <> n} = p) do
    case Watch.Table.select(s.wdb, "id = ?1", [int(n)]) do
      [%{status: "answered", answered_by: by}] when is_binary(by) -> by
      _ -> due_or(s, p, :passed)
    end
  end

  # A login's prompt closes when a check finds the account logged in: one not answered here is
  # a check the framework made before a start or a resume.
  defp owned(_s, %{kind: "login"}), do: {:framework, :logged_in}

  # A start's wait: at its deadline its owner takes the wait, the kind's default.
  defp owned(s, %{kind: "limit", id: "limit:start:" <> _} = p), do: due_or(s, p, :passed)

  defp owned(s, p), do: ended_or(s, p, :passed)

  # Its agent ended (or its process is gone), else its deadline passed, else `why`.
  defp ended_or(s, %{agent: agent} = p, why) when is_binary(agent) do
    row = Agents.get(s.agents, agent)
    gone? = row == nil or Agents.ended?(row) or row.status == "stopped"
    if gone?, do: {:framework, :ended}, else: due_or(s, p, why)
  end

  defp ended_or(s, p, why), do: due_or(s, p, why)

  # Past its deadline: its kind's default taken (a start's wait, the usage limit menu's stop),
  # or, for a kind with none, expired.
  defp due_or(_s, p, why) do
    if is_integer(p[:deadline]) and System.os_time(:millisecond) >= p.deadline,
      do: {:framework, if(p.kind in ["limit", "usage_credits"], do: :default, else: :expired)},
      else: {:framework, why}
  end

  @closers ~w(expired default ended withdrawn passed unknown logged_in)a

  defp dump_by({:framework, why}), do: ["framework", Atom.to_string(why)]
  defp dump_by(by), do: by

  defp load_by(["framework", why]) do
    case Enum.find(@closers, &(Atom.to_string(&1) == why)) do
      nil -> {:framework, :unknown}
      known -> {:framework, known}
    end
  end

  defp load_by(by) when is_binary(by), do: by
  defp load_by(_), do: {:framework, :unknown}

  # Prompt.tla's Notice: one notice per prompt of a delegate, under the prompt's key.
  defp tell(s, all) do
    rows = Map.new(Agents.rows(s.agents), &{&1.name, &1})

    # A remedy prompt is the Watch's about an agent, not the agent's own wait.
    for %{status: "open", agent: agent, parent: parent} = p <- all,
        p.kind != "remedy",
        not MapSet.member?(s.told, p.id),
        match?(%{kind: "delegate"}, rows[agent]) and is_binary(parent),
        reduce: s do
      s ->
        text = "waiting on #{p.kind}: #{p.text} (prompt #{p.id})"
        opts = [key: "prompt:" <> p.id, kind: :prompt, from: agent]

        case Mailbox.notify(s.owners.mailbox, parent, text, opts) do
          # Stored now or before, or refused for good (a parent no edge reaches): told.
          {tag, _} when tag in [:ok, :refused] -> %{s | told: MapSet.put(s.told, p.id)}
          {:unknown, _} -> s
        end
    end
  end

  @doc """
  Every prompt open now, as one function of its owners' rows (the module doc's table): the
  `Intake` holds, the agent rows of `Sessions` and the asks of `Mailbox`. `s` is the process's
  state; answers `{:ok, prompts}` or `{:unknown, reason}` when `Mailbox` did not answer.
  """
  @spec list(map) :: {:ok, [prompt]} | {:unknown, term}
  def list(s) do
    rows = Agents.rows(s.agents)

    with {:ok, asks} <- asks(s.owners.mailbox) do
      prompts =
        holds(s, rows) ++
          requests(s, rows) ++
          dialogs(rows) ++
          menus(rows) ++
          Enum.map(asks, &ask(&1, rows)) ++
          remedies(s, rows) ++
          acting(s, rows) ++
          logins(s) ++
          limits(rows) ++ starts(s)

      marks = marks(s, Enum.map(prompts, & &1.id))
      prompts = Enum.map(prompts, &Map.put(&1, :hidden, marks[&1.id]))
      {:ok, Enum.sort_by(prompts, &{&1.opened_at || 0, &1.id})}
    end
  end

  # Each prompt's hidden mark (F-254): its latest `hide` or `unhide` fact in `Acts`, by id, nil
  # for none or an `unhide`. Read only for the prompts open now, so a closed one's is ignored.
  defp marks(%{adb: nil}, _ids), do: %{}
  defp marks(_s, []), do: %{}

  defp marks(s, ids) do
    where = "target IN (#{Store.marks(length(ids), 1)}) AND act IN ('hide', 'unhide')"

    for row <- Acts.Table.select(s.adb, where, ids), reduce: %{} do
      acc ->
        mark = if row.act == "hide", do: %{by: row.actor, at: row.claimed_at}
        Map.put(acc, row.target, mark)
    end
  end

  defp asks(mailbox) do
    case Mailbox.open_asks(mailbox) do
      {:ok, asks} -> {:ok, asks}
      {_, reason} -> {:unknown, {:mailbox, reason}}
    end
  end

  defp holds(s, rows) do
    by_session = Map.new(rows, &{{&1.account, &1.session_id}, &1})

    for row <- Intake.Table.waiting(s.idb, s.host) do
      agent = by_session[{row.account, row.session_id}]
      data = decode(row.data)
      kind = if row.prompt == "stop_cap", do: "stop_cap", else: "permission"

      fields = %{
        id: "#{kind}:#{row.id}",
        kind: kind,
        status: if(row.hold == "held", do: "open", else: "answering"),
        subagent: if(is_binary(data["agent_id"]), do: data["agent_id"]),
        # Its hold's time (F-202); a row of an earlier build is written again only as its hold
        # moves, and its `written_at` is that time.
        opened_at: row.held_at || row.written_at,
        deadline: row.deadline
      }

      Map.merge(of(agent), Map.merge(fields, hold_text(kind, data)))
    end
  end

  defp hold_text("permission", data) do
    input =
      case data["tool_input"] do
        %{"command" => command} when is_binary(command) -> command
        %{"file_path" => path} when is_binary(path) -> path
        nil -> ""
        other -> JSON.encode!(other)
      end

    text = String.trim("#{data["tool_name"]} #{String.slice(input, 0, @input)}")
    %{text: text, options: ~w(allow deny)}
  end

  defp hold_text("stop_cap", _data) do
    text =
      "its turn would end at Claude Code's cap of Stop blocks in a row: go on once more, or end"

    %{text: text, options: ~w(go_on end)}
  end

  # A headless delegate's `can_use_tool` requests, held in its fold (F-189's new-2): answered
  # through `Stream`, whose fold moves a request only from `held`.
  defp requests(%{sdb: nil}, _rows), do: []

  defp requests(s, rows) do
    by_session = Map.new(rows, &{&1.session_id, &1})

    with {:ok, %{rows: folds}} <- Stream.Table.rows(s.sdb, s.host) do
      for %{gone: false, session: session, requests: requests} <- folds,
          {id, %{state: state} = r} <- Enum.sort(requests),
          state in [:held, :answering] do
        fields = %{
          id: "permission:stream:#{session}:#{id}",
          kind: "permission",
          status: if(state == :held, do: "open", else: "answering"),
          subagent: nil,
          opened_at: r[:held_at],
          deadline: nil
        }

        data = %{"tool_name" => r[:tool_name], "tool_input" => r[:input]}
        Map.merge(of(by_session[session]), Map.merge(fields, hold_text("permission", data)))
      end
    else
      :unread -> []
    end
  end

  # A start's menu is keyed by its read (F-206), so each menu of one start is its own prompt.
  defp dialogs(rows) do
    for %{} = row <- rows, d = Agents.dialog(row), status = dialog_status(d.answers[d.kind]) do
      key = if d.kind == :start_menu, do: d.at, else: row.started_at

      fields = %{
        id: "dialog:#{row.name}:#{key}:#{d.kind}",
        kind: "dialog",
        status: status,
        subagent: nil,
        # A start's menu names its title (F-203); the imports dialog its paths.
        text: Enum.join(["#{d.kind} dialog" | List.wrap(d[:title]) ++ d.paths], ": "),
        options: d.options,
        opened_at: row.updated_at,
        deadline: nil
      }

      Map.merge(of(row), fields)
    end
  end

  # A numbered menu on a running screen (F-198): a dialog with no default and no deadline, its
  # options and `esc`, open while the row's menu is that read's and not sent.
  defp menus(rows) do
    for %{} = row <- rows, m = Agents.menu(row), status = Menu.status(m) do
      fields = %{
        id: "dialog:#{row.name}:#{m["at"]}:menu",
        kind: "dialog",
        status: status,
        subagent: nil,
        text: Menu.text(m),
        options: Menu.choices(m),
        opened_at: m["at"],
        deadline: nil
      }

      Map.merge(of(row), fields)
    end
  end

  # A dialog's prompt by its answer's mark: none or cleared, open; a press under way,
  # answering; cut or unknown, for a person; sent, gone.
  defp dialog_status(nil), do: "open"
  defp dialog_status(%{mark: "cleared"}), do: "open"
  defp dialog_status(%{mark: "pressing"}), do: "answering"
  defp dialog_status(%{mark: mark}) when mark in ["cut", "unknown"], do: mark
  defp dialog_status(_), do: nil

  defp ask(a, rows) do
    row = Enum.find(rows, &(&1.name == a.from)) || %{name: a.from}

    fields = %{
      id: "ask:#{a.id}",
      kind: "ask",
      status: "open",
      subagent: nil,
      text: Enum.map_join(a.questions, "\n", &"#{&1["header"]}: #{&1["question"]}"),
      options: a.questions,
      opened_at: a.asked_at,
      deadline: nil
    }

    Map.merge(of(row), fields)
  end

  defp remedies(s, rows) do
    by_name = Map.new(rows, &{&1.name, &1})

    for sym <- Watch.Table.asked(s.wdb) do
      fields = %{
        id: "remedy:#{sym.id}",
        kind: "remedy",
        status: "open",
        subagent: nil,
        text: "#{sym.kind} of #{sym.target}: #{sym.reason}; its remedy: #{sym.remedy}",
        options: Watch.choices(sym),
        opened_at: sym.asked_at,
        deadline: nil
      }

      Map.merge(of(by_name[sym.target]), fields)
    end
  end

  # A remedy answered `act` (F-196): `answering` while the person's act is the healer's to take
  # or under way, gone once its row in `Acts` has ended, whatever its outcome. A state that
  # passed with no act is gone too, passed before its act (F-203).
  defp acting(%{adb: nil}, _rows), do: []

  defp acting(s, rows) do
    by_name = Map.new(rows, &{&1.name, &1})
    answered = "status IN ('answered', 'passed') AND answer = 'act'"

    for sym <- Watch.Table.select(s.wdb, answered, []),
        act <- [person_act(s, sym)],
        if(act, do: act.status in ["claimed", "acted"], else: sym.status == "answered") do
      now = if act, do: "its #{act.act} is #{act.status}", else: "its healer takes it next"

      fields = %{
        id: "remedy:#{sym.id}",
        kind: "remedy",
        status: "answering",
        subagent: nil,
        text: "#{sym.kind} of #{sym.target}: #{sym.answered_by} answered act; " <> now,
        options: Watch.choices(sym),
        opened_at: sym.asked_at,
        deadline: nil
      }

      Map.merge(of(by_name[sym.target]), fields)
    end
  end

  # The person's act of an answered state, one read of the rows (F-193's new-2): its row in
  # `Acts` by its actor and target whose detail's `symptom` is the state.
  defp person_act(s, sym) do
    s.adb
    |> Acts.Table.select("actor = ?1 AND target = ?2", [sym.answered_by, sym.target])
    |> Enum.find(&(decode(&1.detail)["symptom"] == sym.state))
  end

  # A start refused at a usage limit (F-196): its owner's row while it waits, open until a person
  # answers it for this reset; its deadline the row's, at which the owner takes the wait.
  defp starts(s) do
    waiting =
      Enum.map(
        if(s.ddb, do: Delegates.Table.with_status(s.ddb, s.host, ["waiting"]), else: []),
        &{"delegate", &1, Delegates.Table.request(&1)}
      ) ++
        Enum.map(
          if(s.mdb, do: Mains.Starts.with_status(s.mdb, s.host, "waiting"), else: []),
          &{"main", &1, Mains.Starts.request(&1)}
        )

    for {owner, row, request} <- waiting, row.waited == nil do
      text =
        "#{owner} #{row.name} waits to start until a usage limit's reset at #{iso(row.until)}: " <>
          "wait (the default at #{iso(row.deadline)}) or leave"

      %{
        id: "limit:start:#{owner}:#{row.id}",
        kind: "limit",
        status: "open",
        agent: row.name,
        parent: if(owner == "delegate", do: request.parent),
        project: request.project,
        subagent: nil,
        text: text,
        options: ~w(wait leave),
        opened_at: row.updated_at,
        deadline: row.deadline
      }
    end
  end

  defp iso(ms) when is_integer(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp logins(%{ldb: nil}), do: []

  defp logins(s) do
    for row <- Logins.Table.refused(s.ldb) do
      text =
        "account #{row.account} is not logged in (#{row.state}): log it in with bin/caf-login, " <>
          "then answer check"

      fields = %{
        id: "login:#{row.account}:#{row.refused_at}",
        kind: "login",
        status: "open",
        subagent: nil,
        text: text,
        options: ~w(check),
        opened_at: row.refused_at,
        deadline: nil
      }

      Map.merge(of(nil), fields)
    end
  end

  # The usage limit's prompts, by the row's step (`Sessions.Limit.prompt/1`).
  defp limits(rows) do
    for row <- rows, l = Agents.limit(row), kind = Limit.prompt(l) do
      fields = %{
        id: "#{kind}:#{row.name}:#{l["until"]}",
        kind: kind,
        status: "open",
        subagent: nil,
        text: limit_text(kind, l),
        options: Limit.options(l),
        opened_at: row.updated_at,
        deadline: if(kind == "usage_credits", do: l["deadline"])
      }

      Map.merge(of(row), fields)
    end
  end

  defp limit_text("limit", l) do
    text =
      "usage limit (#{l["window"] || "window"}) until #{l["until"]}: #{l["why"] || "left to you"}"

    # F-191: a main's limit far from its reset offers the move beside the wait.
    if is_binary(l["move_to"]),
      do: text <> "; go_on waits for the reset, move moves it to #{l["move_to"]}",
      else: text
  end

  defp limit_text("usage_credits", l),
    do:
      "usage limit (#{l["window"] || "window"}) until #{l["until"]}: the account can spend " <>
        "usage credits; stop and wait, or spend (the stop at the deadline)"

  defp of(nil), do: %{agent: nil, parent: nil, project: nil}

  defp of(row),
    do: %{agent: row[:name], parent: Map.get(row, :parent), project: Map.get(row, :project)}

  defp decode(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{} = data} -> data
      _ -> %{}
    end
  end

  defp decode(_), do: %{}

  # An id that is no prompt now: its owner's row is there but settled, or there is none.
  defp gone(s, id) do
    case String.split(id, ":") do
      ["permission", "stream", session | request] when s.sdb != nil ->
        settled_if(stream_request?(s, session, Enum.join(request, ":")))

      [kind, n] when kind in ["permission", "stop_cap"] ->
        settled_if(Intake.Table.rows_by_id(s.idb, [int(n)]) != [])

      ["dialog", agent, _start, _kind] ->
        settled_if(Agents.get(s.agents, agent) != nil)

      ["ask", n] ->
        settled_if(match?({:ok, _}, Mailbox.asked(s.owners.mailbox, int(n))))

      ["remedy", n] ->
        settled_if(Watch.Table.select(s.wdb, "id = ?1", [int(n)]) != [])

      ["limit", "start", "delegate", n] when s.ddb != nil ->
        settled_if(Delegates.Table.get(s.ddb, int(n)) != nil)

      ["limit", "start", "main", n] when s.mdb != nil ->
        settled_if(Mains.Starts.get(s.mdb, int(n)) != nil)

      [kind, agent, _until] when kind in ["limit", "usage_credits"] ->
        settled_if(Agents.get(s.agents, agent) != nil)

      ["login", account, _refused_at] when s.ldb != nil ->
        settled_if(Map.has_key?(Logins.Table.rows(s.ldb), account))

      _ ->
        {:refused, :no_prompt}
    end
  end

  defp stream_request?(s, session, request) do
    case Stream.Table.rows(s.sdb, s.host) do
      {:ok, %{rows: folds}} ->
        Enum.any?(folds, &(&1.session == session and Map.has_key?(&1.requests, request)))

      :unread ->
        false
    end
  end

  defp settled_if(true), do: {:refused, :settled}
  defp settled_if(false), do: {:refused, :no_prompt}

  defp int(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> -1
    end
  end

  # The choice as its owner takes it, checked against what the prompt offers.
  defp choose(%{kind: "permission"}, "allow", _who), do: {:ok, :allow}
  defp choose(%{kind: "permission"}, "deny", who), do: {:ok, {:deny, "Denied by #{who}."}}

  defp choose(%{kind: "permission"}, {"deny", message}, _who)
       when is_binary(message) and message != "",
       do: {:ok, {:deny, message}}

  defp choose(%{kind: "stop_cap"}, "go_on", _who), do: {:ok, :go_on}
  defp choose(%{kind: "stop_cap"}, "end", _who), do: {:ok, :end}

  defp choose(%{kind: "dialog", options: options}, label, _who) when is_binary(label),
    do: if(label in options, do: {:ok, label}, else: {:refused, {:bad, :choice}})

  defp choose(%{kind: "ask"}, {:withdraw, reason}, _who), do: {:ok, {:withdraw, reason}}
  defp choose(%{kind: "ask"}, answers, _who) when is_list(answers), do: {:ok, {:answer, answers}}

  defp choose(%{kind: "remedy", options: options}, choice, _who) when is_binary(choice),
    do: if(choice in options, do: {:ok, choice}, else: {:refused, {:bad, :choice}})

  defp choose(%{kind: "login"}, "check", _who), do: {:ok, :check}

  defp choose(%{kind: kind, options: options}, choice, _who)
       when kind in ["limit", "usage_credits"],
       do: if(choice in options, do: {:ok, choice}, else: {:refused, {:bad, :choice}})

  defp choose(_prompt, _choice, _who), do: {:refused, {:bad, :choice}}

  # The owner takes the answer, in the caller's process; its refusal of a request no longer
  # waiting is the same `settled` as the read's. A stream's request: its fold refuses an
  # answer to a request no longer held.
  defp hand(owners, %{kind: "permission", id: "permission:stream:" <> key}, decision, _who) do
    [session, request] = String.split(key, ":", parts: 2)
    label = if decision == :allow, do: "allow", else: {"deny", elem(decision, 1)}

    case Stream.answer(owners.stream, session, request, label) do
      {:refused, why} when why in [:no_request, :gone, :not_followed] -> {:refused, :settled}
      {:refused, {:request, _state}} -> {:refused, :settled}
      other -> other
    end
  end

  defp hand(owners, %{kind: kind, id: id}, decision, who)
       when kind in ["permission", "stop_cap"] do
    [_, n] = String.split(id, ":")

    case Intake.answer(owners.intake, int(n), decision, by: who) do
      {:refused, {:not_held, _}} -> {:refused, :settled}
      other -> other
    end
  end

  defp hand(owners, %{kind: "dialog", agent: agent, id: "dialog:" <> key}, label, who)
       when binary_part(key, byte_size(key), -5) == ":menu" do
    [_, at, "menu"] = String.split(key, ":")
    opts = [by: who]

    case Sessions.answer_menu(owners.sessions, agent, int(at), label, opts) do
      {:refused, why} when why in [:no_session, :settled] -> {:refused, :settled}
      {:refused, {why, _}} when why in [:answered, :not_running] -> {:refused, :settled}
      other -> other
    end
  end

  defp hand(owners, %{kind: "dialog", agent: agent, id: id}, label, who) do
    [_, _, key, kind] = String.split(id, ":")
    # A start's menu's id names its read, which the answer must still be for (F-206).
    at = if kind == "start_menu", do: [at: int(key)], else: []
    opts = [by: who] ++ at

    case Sessions.answer_dialog(owners.sessions, agent, kind, label, opts) do
      {:refused, why}
      when why == :no_session or elem(why, 0) in [:answered, :not_on_dialog, :shown, :read] ->
        {:refused, :settled}

      other ->
        other
    end
  end

  defp hand(owners, %{kind: "ask", id: "ask:" <> n}, {:answer, answers}, _who),
    do: Mailbox.answer(owners.mailbox, int(n), answers)

  defp hand(owners, %{kind: "ask", id: "ask:" <> n}, {:withdraw, reason}, _who),
    do: Mailbox.withdraw(owners.mailbox, int(n), reason)

  defp hand(owners, %{kind: "remedy", id: "remedy:" <> n}, choice, who),
    do: Watch.answer(owners.watch, int(n), choice, who)

  # A check that finds it logged in closes the prompt; one still refused leaves it open.
  defp hand(owners, %{kind: "login", id: id}, :check, _who) do
    # An account's name has no `:`; the id's last part is the refusal's time.
    ["login", account, _refused_at] = String.split(id, ":")

    case Logins.recheck(owners.logins, account) do
      :ok -> {:ok, :logged_in}
      other -> other
    end
  end

  # A start's wait is its owner's row: `Delegates` or `Mains` lets one answer in per reset.
  defp hand(owners, %{kind: "limit", id: "limit:start:" <> key}, choice, who) do
    answer =
      case String.split(key, ":") do
        ["delegate", n] -> Delegates.answer_wait(owners.delegates, int(n), choice, who)
        ["main", n] -> Mains.answer_wait(owners.mains, int(n), choice, who)
      end

    case answer do
      {:refused, why} when why in [:settled, :no_start] -> {:refused, :settled}
      other -> other
    end
  end

  defp hand(owners, %{kind: kind, agent: agent}, choice, who)
       when kind in ["limit", "usage_credits"],
       do: Sessions.answer_limit(owners.sessions, agent, kind, choice, who)

  defp check_filter(filter) when is_list(filter) do
    ok? =
      Enum.all?(filter, fn
        {key, name} when key in [:agent, :subtree] -> is_binary(name)
        {:kind, kind} -> kind in @kinds
        {:hidden, hidden} -> is_boolean(hidden)
        _ -> false
      end)

    if ok?, do: :ok, else: {:refused, {:bad, :filter}}
  end

  defp check_filter(_), do: {:refused, {:bad, :filter}}

  defp filtered(all, filter, rows) do
    Enum.reduce(filter, all, fn
      {:agent, name}, ps ->
        Enum.filter(ps, &(&1.agent == name))

      {:kind, kind}, ps ->
        Enum.filter(ps, &(&1.kind == kind))

      {:hidden, hidden}, ps ->
        Enum.filter(ps, &(&1.hidden != nil == hidden))

      # A start that waits has no agent row yet: its parent places it (F-196).
      {:subtree, name}, ps ->
        tree = subtree(rows, name)
        Enum.filter(ps, &(&1.agent in tree or (&1.parent != nil and &1.parent in tree)))
    end)
  end

  # The agent and every agent under it, by the rows' parent edges.
  defp subtree(rows, name) do
    children = Enum.group_by(rows, & &1.parent, & &1.name)
    walk([name], children, MapSet.new())
  end

  defp walk([], _children, seen), do: seen

  defp walk([name | rest], children, seen) do
    if MapSet.member?(seen, name),
      do: walk(rest, children, seen),
      else: walk(Map.get(children, name, []) ++ rest, children, MapSet.put(seen, name))
  end
end
