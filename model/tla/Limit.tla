-------------------------------- MODULE Limit --------------------------------
(***************************************************************************)
(* An account's usage limit (F-178), taken as the account's state with     *)
(* bounded remedies. Claude Code ends a turn at a limit with one record    *)
(* (a transcript line `apiError: "usage_limit_reached"` whose              *)
(* `quotaLimits` names the window and its reset, and, headless, the       *)
(* stream's `rate_limit_event` beside its result; never `StopFailure`,     *)
(* whose input carries no reset: F-181's new-1).                           *)
(* From any agent's record the framework marks the account limited until   *)
(* that reset, refuses every start, resume and lease on it until then, and *)
(* marks the agent `limited`, never idle. Then, by what the agent shows:   *)
(*                                                                         *)
(*   Claude Code's own wait   interactive, the reset under 24 h away, the  *)
(*        setting `autoContinueAtUsageLimit` on (the framework writes it   *)
(*        in every account's settings), and fewer than three automatic     *)
(*        continuations in a row: Claude Code waits and goes on by itself  *)
(*        at the reset. The framework only watches: a turn after the       *)
(*        reset clears the mark; the wait ended with no turn (Esc, an      *)
(*        exit) is taken as the menu's stop; a wait still shown past the   *)
(*        reset is a person's prompt, never a word typed into it.          *)
(*   the menu   otherwise: "Stop and wait for limit to reset", "Wait here, *)
(*        then continue automatically", and usage credits. The framework   *)
(*        presses "stop and wait" once, checked on the screen, found by    *)
(*        its label. Where the record says the account can spend           *)
(*        (`overageStatus`), it opens a `usage_credits` prompt first,      *)
(*        whose default at its deadline is the stop: credits only by a     *)
(*        person's answer. A press whose outcome is unknown is never sent  *)
(*        again; the menu still shown after it is a person's prompt.       *)
(*   headless   no wait: the turn ends with the limit. A delegate's        *)
(*        limited result is never its report (F-186's new-1): the turn its *)
(*        brief began is still open, and the word at the reset goes on     *)
(*        with it; Delegates resumes a gone process with that word, under  *)
(*        its lease, and does not count it as the resume after a kill      *)
(*        (Delegate.tla's).                                                *)
(*                                                                         *)
(* At the reset each limited agent whose own wait did not go on gets one   *)
(* word to go on through Mailbox, under a key of the agent and the limit,  *)
(* so it is stored once per limit; Mailbox hands it into an ended turn, or *)
(* by `launch` as a resume's prompt when the process is gone, under a      *)
(* lease the gate grants only once the account's limit passed. The agent   *)
(* row counts the go-ons in a row that each hit a limit again; past        *)
(* Bound of them the agent is a `limit` prompt, with no deadline. Its      *)
(* answers: go on, move (below), or leave it to the person (F-186), after  *)
(* which nothing acts on that limit until a turn runs or a new record.     *)
(*                                                                         *)
(* The move (F-181, decided by the operator): before the reset, where it   *)
(* is more than `move_after` away and another usable account has room, a   *)
(* delegate moves on its own, once per limit, the claim on its row first:  *)
(* one move through the Mover, resumed on the other account. A move        *)
(* refused, failed or unknown leaves it to a `limit` prompt, never to a    *)
(* second move. A main session never moves on its own: its `limit` prompt *)
(* offers the move beside the wait, and only a person's answer moves it.   *)
(*                                                                         *)
(* Models Usage (the account's record: `limited_until`, read from any      *)
(* agent's evidence), the Scheduler's gate on it, Sessions' turn state     *)
(* (`limited`, its remedy's phase on the agent row, and the checked press  *)
(* of the menu), Mailbox's word to go on (its key, and the hand into an    *)
(* ended turn or by `launch`), Intake (the `StopFailure` hook and the      *)
(* Notification hook's `quota_auto_resume_*`, read here as the turn and    *)
(* the screen they report), and the screen reader (Screen's kinds          *)
(* `usage_limit_menu` and `usage_limit_wait`). Prompts' two kinds are rows *)
(* here (`cp`, `pp`); their answer's claim is Prompt.tla's. The code       *)
(* (F-186): Limits, the healer that reads each record onto the row and     *)
(* takes each phase; Sessions.Limit, the row's field; Sessions'            *)
(* put_limit, answer_limit and press_limit. And (F-187) Delegates.Turn's   *)
(* reading of a headless delegate's turn, and Delegates.go_on, the word's  *)
(* resume of a delegate (F-191: an interactive one's too, read from its    *)
(* transcript). And (F-191) Away and MoveAct: Limits' remedy `move` of     *)
(* kind `limit_far` (its claim, `mv`, the act on the row's limit, once per *)
(* limit; a main's limit prompt with `move_to`, Sessions.Limit's answer    *)
(* "move"), Mover.room (`room`) and Mover.move with that claim; the        *)
(* move's own steps, from a live process or a gone one, are Move.tla's.    *)
(*                                                                         *)
(* A start refused at a limit (F-196, F-193's new-1): new work, a          *)
(* delegate's start, a main's start or a resume that must leave its        *)
(* account, picks its account (Usage.pick inside Delegates and Mains)      *)
(* among the usable ones; another with room takes it. When every usable    *)
(* one is limited the pick refuses, and the start's owner writes its row   *)
(* `waiting` with the soonest reset: the start's `limit` prompt (Prompts'  *)
(* `limit:start:<row>`), answered `wait`, its default at its deadline (the *)
(* reset plus a margin), or `leave`, the row refused `left`. At the reset  *)
(* plus the margin the owner picks again and asks for its lease again,     *)
(* under the row's own request id; a newer limit makes the row wait again  *)
(* for that reset. A restart keeps the row, and its timer is set again     *)
(* from it. The code: Delegates' and Mains' `waiting` rows and their       *)
(* timers (Delegates.Wait), and Prompts' reading of them. The parent's     *)
(* notice is Delegate.tla's (F-170), as a queued start's.                  *)
(*                                                                         *)
(* Left abstract: time but the reset's order (a reset is one step, and the *)
(* framework's clock reads it as the record's `resetsAt` passed); the      *)
(* windows' kinds (five-hour, weekly, a model family's: one window here,   *)
(* which may close again after its reset); the other accounts, as one      *)
(* that has room or not and never limits here, and the move as one step    *)
(* (its drain, end, copy and resume are Move.tla's); every row             *)
(* to the agent but the word (Mailbox holds the others for a limited       *)
(* agent until the reset, as it holds the word); the statusline's numbers  *)
(* (evidence of the same record, earlier); a person's answer's claim and   *)
(* the prompts' restarts (Prompt.tla's). The press is one step, its check  *)
(* and its keys, as Dialog.tla's is. The framework's restart loses its     *)
(* memory only: a word stored whose agent row is not yet written.          *)
(*                                                                         *)
(* Fairness: the framework's steps, Mailbox's hand, a working turn's hit   *)
(* in a closed window, Claude Code's own wait at the reset, a prompt's     *)
(* deadline, and time reaching the reset. A window's closing, a turn's     *)
(* normal end, a person's acts (at the viewer, or a prompt's answer), a    *)
(* wait gone stale and restarts happen or not.                             *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Limit_<value>.cfg that TLC must fail.                       *)
(*                                                                         *)
(* The boxes' contracts this adds (Boxes.tla composes them): the           *)
(* Scheduler grants nothing on an account its record says limited          *)
(* (NoStartOnLimited, Boxes' StartOnLimited); Sessions' turn state         *)
(* `limited` is not an ended turn, and Mailbox marks into it only once the *)
(* limit's reset passed (Boxes' MarkIntoLimited); Prompts gains the kind   *)
(* `usage_credits`, owned by Sessions' checked press, as `startup` is.     *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Agents,       \* the agents on the account
    Headless,     \* the headless ones; the rest are interactive
    Mains,        \* the main sessions; the rest are delegates
    Others,       \* another account exists that a move may go to
    CanSpend,     \* the account's record allows usage credits (`overageStatus`)
    MaxLimits,    \* the most times the account's window closes in one behavior
    Bound,        \* go-ons in a row that each hit a limit again, before a person's prompt
    AutoMax,      \* Claude Code's automatic continuations in a row (3 on 2.1.322)
    MaxOutside,   \* a person's acts at the viewer and answers, and stale waits, in all
    MaxRestarts,  \* restarts of the framework
    Starts,       \* a start of new work is asked for in the behavior (F-196)
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "DefaultSpends",   \* the usage_credits prompt's default at its deadline is the credits
    "NoGate",          \* the Scheduler grants a lease whatever the account's record says
    "IgnoreOwnWait",   \* at the reset a word goes to every limited agent, its own wait or not
    "NoKey",           \* the word is stored with no key, so a restart stores it again
    "TrustOwnWait",    \* Claude Code's own wait is trusted to go on: its end is not watched
    "RetryUnknown",    \* a press whose outcome is unknown is pressed again
    "Unchecked",       \* the press goes without the screen read to show the menu
    "NoBound",         \* go-ons that hit the limit again are not counted
    "MoveMain",        \* a main session is moved as a delegate is, on the framework's own
    "MoveTwice",       \* the move's claim is not checked, so a limit may be moved from twice
    "LimitReport",     \* a headless delegate's result at a limit is taken as its report
    "NoRepick"         \* a waiting start goes at its reset on the pick it was refused by
}

ASSUME Break \in Breaks
ASSUME Headless \subseteq Agents /\ Mains \subseteq Agents /\ Others \in BOOLEAN
ASSUME CanSpend \in BOOLEAN /\ Starts \in BOOLEAN
ASSUME MaxLimits \in Nat \ {0} /\ Bound \in Nat \ {0} /\ AutoMax \in Nat
ASSUME MaxOutside \in Nat /\ MaxRestarts \in Nat

Interactive == Agents \ Headless
Limits == 0..MaxLimits
Labels == {"stop", "spend"}

\* The remedy's phase on the agent row, while it is `limited`:
\*   look      the screen is to be read
\*   own       Claude Code's own wait shows: watched
\*   credits   the usage_credits prompt is open, the menu waiting on it
\*   press     a press of `label` to send, checked
\*   unknown   a press whose outcome is unknown
\*   idle      the turn ended, nothing on the screen to answer: waiting for the reset
\*   send      the word to go on is owed, and counted
\*   word      the word to go on is stored, its turn not yet seen
\*   prompt    a person's `limit` prompt is open
\*   left      a person answered it "leave": theirs until a turn runs or a new record
\*   move      a move to another account is claimed, its act to run
\*   moved     the move ran: the agent runs on the other account
Steps == {"none", "look", "own", "credits", "press", "unknown", "idle", "send", "word",
          "prompt", "left", "move", "moved"}

\* A start of new work (F-196), its owner's row:
\*   none      not asked for
\*   new       asked for, its account to pick; no row yet
\*   waiting   the pick refused at a limit: the row waits for the soonest reset, `sAt`
\*   again     the reset passed: its owner picks again, under the row's own request id
\*   granted   it started on this account
\*   there     it started on another account, which had room
\*   left      a person answered its prompt "leave": the row is refused
\*   cut       a restart cut it before its row was written; its caller is answered unknown
StartRows == {"none", "new", "waiting", "again", "granted", "there", "left", "cut"}

VARIABLES
    \* the account's window, the environment
    n,          \* the limits so far: the window closed n times
    win,        \* "open" or "closed"
    near,       \* the current limit's reset is under 24 h away
    far,        \* ... and more than `move_after` away (only where Others)
    room,       \* another usable account has room (only where Others)
    \* Claude Code, per agent
    cc,         \* a -> its turn: "working", "done" (ended), "hit" (ended at a limit), "idle"
                \* (ended at a limit, the menu or the wait left)
    screen,     \* a -> "input", "menu" or "wait"; a headless agent's is "input"
    live,       \* a -> its process lives
    autos,      \* a -> automatic continuations in a row
    stale,      \* a -> its own wait shows but will not go on
    hits,       \* a -> limit records it wrote (its transcript, its StopFailure, its stream)
    hitLim,     \* a -> the limit its last record names
    menus,      \* a -> menus it showed
    outside,    \* a person's acts and stale waits so far
    \* the framework, durable
    rec,        \* Usage: the account's record, the limit it is limited by until its reset (0: none)
    seen,       \* Sessions: a -> the records of a it read
    lim,        \* Sessions: a -> the limit a's row is `limited` for (0: not limited)
    step,       \* Sessions: a -> the remedy's phase (Steps)
    label,      \* Sessions: a -> the label of the press to send
    byPerson,   \* Sessions: a -> that label is a person's answer
    cp,         \* Prompts: a -> its usage_credits prompt is open
    pp,         \* Prompts: a -> its limit prompt is open
    goes,       \* Sessions: a -> go-ons in a row since a turn ended by itself or a person answered
    noted,      \* Sessions: a -> the limit of the last word the row counted (0: none)
    due,        \* Mailbox: a -> words to go on due to a
    wkey,       \* Mailbox: a -> the limit of the word stored under a's key (0: none)
    req,        \* Scheduler: another start's request: "none", "asked", "granted", "refused"
    where,      \* Sessions: a -> "here", or "there" once moved to the other account
    mv,         \* Acts: a -> the limit whose move was claimed (or asked of a person; 0: none)
    mvBy,       \* Sessions: a -> the claimed move is a person's answer
    reported,   \* Delegates: a -> its report was taken (a headless delegate's)
    sr,         \* Delegates or Mains: the start's row (StartRows)
    sAt,        \* ... the limit whose reset its row waits for (0: none)
    sp,         \* Prompts: the start's limit prompt is open
    \* the framework, in memory
    pend,       \* a -> the limit of a word stored whose agent row does not yet say so (0: none)
    restarts,
    \* ghosts
    stored,     \* a -> k -> words to go on stored for a at limit k
    ownGone,    \* a -> the limits at which Claude Code's own wait went on
    pressedOn,  \* a -> the menu of a the framework last pressed (0: none)
    streak,     \* a -> the framework's go-ons since a turn ended by itself or a person answered
    grants,     \* leases granted on the account
    moves,      \* a -> k -> the framework's own moves of a at limit k
    wrong       \* the faults a guard failed to stop, by name

ccVars == <<cc, screen, live, autos, stale, hits, hitLim, menus>>
rowVars == <<seen, lim, step, label, byPerson, cp, pp, goes, noted>>
moveVars == <<far, room, where, mv, mvBy>>
ghosts == <<stored, ownGone, pressedOn, streak, grants, moves, wrong>>
startVars == <<sr, sAt, sp>>
vars == <<n, win, near, ccVars, outside, rec, rowVars, due, wkey, req, pend, restarts, ghosts,
          moveVars, reported, startVars>>

\* Every action but Report and the start's leaves the report and the start as they are.
Kept(A) == A /\ UNCHANGED <<reported, startVars>>

-----------------------------------------------------------------------------
(* Reading the state *)

\* The reset of limit k has passed: its window opened again, or a later one closed.
Passed(k) == n > k \/ win = "open"

\* Usage's record says the account is limited now: until its reset.
Limited == rec > 0 /\ ~Passed(rec)

\* The Scheduler's gate.
Admit == ~Limited \/ Break = "NoGate"

\* An ended turn Mailbox may hand a row into: the input box shows and the turn ended,
\* at a limit for a headless agent (its stream's result).
TurnOver(a) ==
    /\ live[a] /\ screen[a] = "input"
    /\ cc[a] \in {"done", "idle"} \/ (a \in Headless /\ cc[a] = "hit")

Max(x, y) == IF x >= y THEN x ELSE y

\* Every limit record of a is read: an act is decided on the newest evidence (Team.tla's Needed).
Current(a) == seen[a] = hits[a]

-----------------------------------------------------------------------------
(* The account and Claude Code *)

\* The account's use reaches a limit: the window closes until a reset, under 24 h away or not.
Close ==
    /\ win = "open" /\ n < MaxLimits
    /\ win' = "closed" /\ n' = n + 1
    /\ near' \in BOOLEAN
    /\ far' \in IF Others THEN BOOLEAN ELSE {FALSE}
    /\ UNCHANGED <<ccVars, outside, rec, rowVars, due, wkey, req, pend, restarts, ghosts, room,
                   where, mv, mvBy>>

\* Time reaches the reset.
Reset ==
    /\ win = "closed"
    /\ win' = "open"
    /\ UNCHANGED <<n, near, ccVars, outside, rec, rowVars, due, wkey, req, pend, restarts, ghosts, moveVars>>

\* A turn that runs while the window is closed ends at the limit, and its record is written.
\* An interactive session waits by itself where it can, or shows the menu.
Hit(a) ==
    /\ live[a] /\ cc[a] = "working" /\ win = "closed" /\ where[a] = "here"
    /\ cc' = [cc EXCEPT ![a] = "hit"]
    /\ hits' = [hits EXCEPT ![a] = @ + 1]
    /\ hitLim' = [hitLim EXCEPT ![a] = n]
    /\ LET s == IF a \in Headless THEN "input"
                ELSE IF near /\ autos[a] < AutoMax THEN "wait" ELSE "menu"
       IN  /\ screen' = [screen EXCEPT ![a] = s]
           /\ menus' = [menus EXCEPT ![a] = IF s = "menu" THEN @ + 1 ELSE @]
    /\ UNCHANGED <<n, win, near, live, autos, stale, outside, rec, rowVars, due, wkey, req, pend,
                   restarts, ghosts, moveVars>>

\* A turn ends by itself.
TurnEnds(a) ==
    /\ live[a] /\ cc[a] = "working"
    /\ cc' = [cc EXCEPT ![a] = "done"]
    /\ autos' = [autos EXCEPT ![a] = 0]
    /\ streak' = [streak EXCEPT ![a] = 0]
    /\ UNCHANGED <<n, win, near, screen, live, stale, hits, hitLim, menus, outside, rec, rowVars,
                   due, wkey, req, pend, restarts, stored, ownGone, pressedOn, grants, wrong, moveVars, moves>>

\* Claude Code's own wait goes on at the reset: the turn continues, no message resent.
AutoGo(a) ==
    /\ live[a] /\ screen[a] = "wait" /\ ~stale[a] /\ Passed(hitLim[a])
    /\ screen' = [screen EXCEPT ![a] = "input"]
    /\ cc' = [cc EXCEPT ![a] = "working"]
    /\ autos' = [autos EXCEPT ![a] = @ + 1]
    /\ ownGone' = [ownGone EXCEPT ![a] = @ \cup {hitLim[a]}]
    /\ UNCHANGED <<n, win, near, live, stale, hits, hitLim, menus, outside, rec, rowVars, due, wkey,
                   req, pend, restarts, stored, pressedOn, streak, grants, wrong, moveVars, moves>>

\* The outside: a person's acts and a stale wait, bounded together.
Outside == outside < MaxOutside /\ outside' = outside + 1

\* The wait shows but will not go on (`quota_auto_resume_stale`, or nothing at all).
GoesStale(a) ==
    /\ Outside
    /\ live[a] /\ screen[a] = "wait" /\ ~stale[a]
    /\ stale' = [stale EXCEPT ![a] = TRUE]
    /\ UNCHANGED <<n, win, near, cc, screen, live, autos, hits, hitLim, menus, rec, rowVars, due,
                   wkey, req, pend, restarts, ghosts, moveVars>>

\* A person at the viewer presses Esc on the wait: it ends, the turn ended.
Esc(a) ==
    /\ Outside
    /\ live[a] /\ screen[a] = "wait"
    /\ screen' = [screen EXCEPT ![a] = "input"]
    /\ cc' = [cc EXCEPT ![a] = "idle"]
    /\ stale' = [stale EXCEPT ![a] = FALSE]
    /\ UNCHANGED <<n, win, near, live, autos, hits, hitLim, menus, rec, rowVars, due, wkey, req,
                   pend, restarts, ghosts, moveVars>>

\* What an option of the menu does, whoever presses it.
Apply(a, l) ==
    CASE l = "stop" ->
           screen' = [screen EXCEPT ![a] = "input"] /\ cc' = [cc EXCEPT ![a] = "idle"]
      [] l = "wait" ->
           screen' = [screen EXCEPT ![a] = "wait"] /\ UNCHANGED cc
      [] l = "spend" ->
           screen' = [screen EXCEPT ![a] = "input"] /\ cc' = [cc EXCEPT ![a] = "working"]

\* A person at the viewer answers the menu first, by any option it shows.
Choose(a, l) ==
    /\ Outside
    /\ live[a] /\ screen[a] = "menu"
    /\ l = "spend" => CanSpend
    /\ Apply(a, l)
    /\ UNCHANGED <<n, win, near, live, autos, stale, hits, hitLim, menus, rec, rowVars, due, wkey,
                   req, pend, restarts, ghosts, moveVars>>

\* A person types a prompt into an ended turn.
Type(a) ==
    /\ Outside
    /\ a \in Interactive /\ live[a] /\ screen[a] = "input" /\ cc[a] \in {"done", "idle"}
    /\ cc' = [cc EXCEPT ![a] = "working"]
    /\ UNCHANGED <<n, win, near, screen, live, autos, stale, hits, hitLim, menus, rec, rowVars, due,
                   wkey, req, pend, restarts, ghosts, moveVars>>

\* The process ends, its turn not running: a person exits, or a headless process ends.
Exit(a) ==
    /\ Outside
    /\ live[a] /\ cc[a] # "working"
    /\ live' = [live EXCEPT ![a] = FALSE]
    /\ screen' = [screen EXCEPT ![a] = "input"]
    /\ stale' = [stale EXCEPT ![a] = FALSE]
    /\ UNCHANGED <<n, win, near, cc, autos, hits, hitLim, menus, rec, rowVars, due, wkey, req, pend,
                   restarts, ghosts, moveVars>>

\* Another start, resume or lease on the account is asked for.
Ask ==
    /\ req = "none"
    /\ req' = "asked"
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, rowVars, due, wkey, pend, restarts, ghosts, moveVars>>

-----------------------------------------------------------------------------
(* The framework *)

\* Sessions reads a's new limit record: Usage takes it as the account's, limited until its
\* reset, and a's row is `limited`, its screen to be read. An open limit prompt stays, and so
\* does a press whose outcome is unknown: a record read late never makes it pressable again.
\* The prompt is the row's step, so its step stays too (F-186's new-3): nothing acts on the
\* row until the person answers or a turn runs.
Read(a) ==
    /\ hits[a] > seen[a]
    /\ seen' = [seen EXCEPT ![a] = hits[a]]
    /\ rec' = Max(rec, hitLim[a])
    /\ lim' = [lim EXCEPT ![a] = hitLim[a]]
    /\ step' = [step EXCEPT ![a] = IF @ \in {"unknown", "prompt"} THEN @ ELSE "look"]
    /\ cp' = [cp EXCEPT ![a] = FALSE]
    /\ UNCHANGED <<n, win, near, ccVars, outside, label, byPerson, pp, goes, noted, due, wkey, req,
                   pend, restarts, ghosts, moveVars>>

\* The screen read: Claude Code's own wait is watched; the menu is pressed, or first asked of
\* a person where the account can spend; an ended turn waits for the reset.
Look(a) ==
    /\ step[a] = "look" /\ cc[a] \notin {"working", "done"} /\ Current(a)
    /\ CASE a \in Headless \/ ~live[a] \/ screen[a] = "input" ->
              step' = [step EXCEPT ![a] = "idle"] /\ UNCHANGED <<label, byPerson, cp>>
         [] screen[a] = "wait" ->
              step' = [step EXCEPT ![a] = "own"] /\ UNCHANGED <<label, byPerson, cp>>
         [] screen[a] = "menu" /\ CanSpend ->
              /\ step' = [step EXCEPT ![a] = "credits"]
              /\ cp' = [cp EXCEPT ![a] = TRUE]
              /\ UNCHANGED <<label, byPerson>>
         [] screen[a] = "menu" ->
              /\ step' = [step EXCEPT ![a] = "press"]
              /\ label' = [label EXCEPT ![a] = "stop"]
              /\ byPerson' = [byPerson EXCEPT ![a] = FALSE]
              /\ UNCHANGED cp
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, pp, goes, noted, due, wkey, req,
                   pend, restarts, ghosts, moveVars>>

\* A person answers the usage_credits prompt.
AnswerCredits(a, l) ==
    /\ Outside
    /\ step[a] = "credits" /\ cp[a]
    /\ cp' = [cp EXCEPT ![a] = FALSE]
    /\ step' = [step EXCEPT ![a] = "press"]
    /\ label' = [label EXCEPT ![a] = l]
    /\ byPerson' = [byPerson EXCEPT ![a] = TRUE]
    /\ UNCHANGED <<n, win, near, ccVars, rec, seen, lim, pp, goes, noted, due, wkey, req, pend,
                   restarts, ghosts, moveVars>>

\* Its deadline takes the default, the stop, as the framework's. Under DefaultSpends, credits.
CreditsDefault(a) ==
    /\ step[a] = "credits" /\ cp[a]
    /\ cp' = [cp EXCEPT ![a] = FALSE]
    /\ step' = [step EXCEPT ![a] = "press"]
    /\ label' = [label EXCEPT ![a] = IF Break = "DefaultSpends" THEN "spend" ELSE "stop"]
    /\ byPerson' = [byPerson EXCEPT ![a] = FALSE]
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, pp, goes, noted, due, wkey, req,
                   pend, restarts, ghosts, moveVars>>

\* The menu is gone before the answer (a person at the viewer, an exit): withdrawn, and the
\* screen read again.
CreditsGone(a) ==
    /\ step[a] = "credits" /\ ~(live[a] /\ screen[a] = "menu")
    /\ cp' = [cp EXCEPT ![a] = FALSE]
    /\ step' = [step EXCEPT ![a] = "look"]
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, label, byPerson, pp, goes, noted,
                   due, wkey, req, pend, restarts, ghosts, moveVars>>

\* The checked press, in one step: the screen must show the menu, or nothing goes and the
\* screen is read again. A press that goes lands, with its outcome known or not, or does not
\* land, unknown. Under Unchecked it goes whatever the screen shows.
Press(a) ==
    /\ step[a] = "press" /\ Current(a)
    /\ IF live[a] /\ (screen[a] = "menu" \/ Break = "Unchecked")
       THEN /\ pressedOn' = [pressedOn EXCEPT ![a] = menus[a]]
            /\ wrong' = wrong
                 \cup (IF pressedOn[a] = menus[a] THEN {"pressed twice"} ELSE {})
                 \cup (IF screen[a] # "menu" THEN {"pressed off the menu"} ELSE {})
                 \cup (IF label[a] = "spend" /\ ~byPerson[a] THEN {"spent unasked"} ELSE {})
            /\ \/ /\ screen[a] = "menu" /\ Apply(a, label[a])
                  /\ step' = [step EXCEPT ![a] = "idle"]
               \/ /\ screen[a] = "menu" /\ Apply(a, label[a])
                  /\ step' = [step EXCEPT ![a] = "unknown"]
               \/ /\ UNCHANGED <<cc, screen>>
                  /\ step' = [step EXCEPT ![a] = "unknown"]
       ELSE /\ step' = [step EXCEPT ![a] = "look"]
            /\ UNCHANGED <<cc, screen, pressedOn, wrong>>
    /\ UNCHANGED <<n, win, near, live, autos, stale, hits, hitLim, menus, outside, rec, seen, lim,
                   label, byPerson, cp, pp, goes, noted, due, wkey, req, pend, restarts, stored,
                   ownGone, streak, grants, moveVars, moves>>

\* A press whose outcome is unknown is never sent again: the screen read shows where it went.
\* The menu still shown is a person's prompt. Under RetryUnknown it is pressed again.
Unsure(a) ==
    /\ step[a] = "unknown"
    /\ IF live[a] /\ screen[a] = "menu"
       THEN IF Break = "RetryUnknown"
            THEN step' = [step EXCEPT ![a] = "press"] /\ UNCHANGED pp
            ELSE step' = [step EXCEPT ![a] = "prompt"] /\ pp' = [pp EXCEPT ![a] = TRUE]
       ELSE step' = [step EXCEPT ![a] = "look"] /\ UNCHANGED pp
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, label, byPerson, cp, goes, noted,
                   due, wkey, req, pend, restarts, ghosts, moveVars>>

\* Claude Code's own wait, watched: ended with no turn (Esc, an exit), it is the menu's stop;
\* still shown once the reset passed, a person's prompt (the margin is left abstract: this step
\* may come before the wait goes on, and its prompt is then withdrawn). Under TrustOwnWait
\* nothing watches it.
Abandoned(a) ==
    /\ Break # "TrustOwnWait"
    /\ step[a] = "own" /\ cc[a] \notin {"working", "done"}
    /\ ~live[a] \/ screen[a] # "wait"
    /\ step' = [step EXCEPT ![a] = "look"]
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, label, byPerson, cp, pp, goes,
                   noted, due, wkey, req, pend, restarts, ghosts, moveVars>>

Overdue(a) ==
    /\ Break # "TrustOwnWait"
    /\ step[a] = "own" /\ live[a] /\ screen[a] = "wait" /\ Passed(lim[a])
    /\ step' = [step EXCEPT ![a] = "prompt"]
    /\ pp' = [pp EXCEPT ![a] = TRUE]
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, label, byPerson, cp, goes, noted,
                   due, wkey, req, pend, restarts, ghosts, moveVars>>

\* At the reset, the agent row says first that a word to go on is owed, and counts it once per
\* limit; past Bound go-ons in a row, a person's prompt instead. Under IgnoreOwnWait a word goes
\* while Claude Code's own wait shows; under NoBound the go-ons are not counted.
GoOn(a) ==
    /\ step[a] = "idle" \/ (Break = "IgnoreOwnWait" /\ step[a] = "own")
    /\ cc[a] \notin {"working", "done"}
    /\ Passed(lim[a]) /\ Current(a)
    /\ IF goes[a] >= Bound /\ Break # "NoBound"
       THEN /\ step' = [step EXCEPT ![a] = "prompt"]
            /\ pp' = [pp EXCEPT ![a] = TRUE]
            /\ UNCHANGED <<goes, noted, streak>>
       ELSE /\ step' = [step EXCEPT ![a] = "send"]
            /\ goes' = [goes EXCEPT ![a] = IF noted[a] # lim[a] THEN @ + 1 ELSE @]
            /\ noted' = [noted EXCEPT ![a] = lim[a]]
            /\ streak' = [streak EXCEPT ![a] = @ + 1]
            /\ UNCHANGED pp
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, label, byPerson, cp, due, wkey,
                   req, pend, restarts, stored, ownGone, pressedOn, grants, wrong, moveVars, moves>>

\* Mailbox stores the word under a's key for the limit, then the agent row says it is on its
\* way; a restart between the two sends it again, and the key stores nothing more. Under NoKey
\* every send stores a row.
Send(a) ==
    /\ step[a] = "send" /\ pend[a] = 0 /\ Current(a)
    /\ cc[a] \notin {"working", "done"}
    /\ IF wkey[a] # lim[a] \/ Break = "NoKey"
       THEN /\ due' = [due EXCEPT ![a] = @ + 1]
            /\ wkey' = [wkey EXCEPT ![a] = lim[a]]
            /\ stored' = [stored EXCEPT ![a][lim[a]] = @ + 1]
       ELSE UNCHANGED <<due, wkey, stored>>
    /\ pend' = [pend EXCEPT ![a] = lim[a]]
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, rowVars, req, restarts, ownGone, pressedOn,
                   streak, grants, wrong, moveVars, moves>>

\* Mailbox's answer comes back: the row says the word of that limit is on its way.
Sent(a) ==
    /\ pend[a] > 0
    /\ pend' = [pend EXCEPT ![a] = 0]
    /\ step' = [step EXCEPT ![a] = IF @ = "send" /\ lim[a] = pend[a] THEN "word" ELSE @]
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, label, byPerson, cp, pp, goes,
                   noted, due, wkey, req, restarts, ghosts, moveVars>>

\* Mailbox hands a word into an ended turn; to a process that is gone, by `launch`, as the
\* prompt of a resume, under a lease the gate admits.
Deliver(a) ==
    /\ due[a] > 0
    /\ \/ /\ TurnOver(a)
          /\ UNCHANGED <<live, grants, wrong>>
       \/ /\ ~live[a] /\ Admit
          /\ live' = [live EXCEPT ![a] = TRUE]
          /\ grants' = grants + 1
          /\ wrong' = IF Limited THEN wrong \cup {"resumed while limited"} ELSE wrong
    /\ due' = [due EXCEPT ![a] = @ - 1]
    /\ cc' = [cc EXCEPT ![a] = "working"]
    /\ screen' = [screen EXCEPT ![a] = "input"]
    /\ UNCHANGED <<n, win, near, autos, stale, hits, hitLim, menus, outside, rec, rowVars, wkey,
                   req, pend, restarts, stored, ownGone, pressedOn, streak, moveVars, moves>>

\* A turn ran after the limit: a's own wait, the word, a person. The row is no longer limited,
\* and its open prompts are withdrawn.
Continued(a) ==
    /\ lim[a] > 0 /\ cc[a] \in {"working", "done"}
    /\ lim' = [lim EXCEPT ![a] = 0]
    /\ step' = [step EXCEPT ![a] = "none"]
    /\ cp' = [cp EXCEPT ![a] = FALSE]
    /\ pp' = [pp EXCEPT ![a] = FALSE]
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, label, byPerson, goes, noted, due,
                   wkey, req, pend, restarts, ghosts, moveVars>>

\* A turn that ended by itself ends the go-ons in a row.
Ended(a) ==
    /\ lim[a] = 0 /\ cc[a] = "done" /\ goes[a] > 0
    /\ goes' = [goes EXCEPT ![a] = 0]
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, step, label, byPerson, cp, pp,
                   noted, due, wkey, req, pend, restarts, ghosts, moveVars>>

\* A person answers the limit prompt, "go on": the go-ons in a row start again, and the screen
\* is read again. A person who saw the menu still shown after a press whose outcome is unknown
\* clears that press by this answer, so the menu may be pressed once more.
AnswerLimit(a) ==
    /\ Outside
    /\ pp[a]
    /\ pp' = [pp EXCEPT ![a] = FALSE]
    /\ goes' = [goes EXCEPT ![a] = 0]
    /\ streak' = [streak EXCEPT ![a] = 0]
    /\ step' = [step EXCEPT ![a] = IF @ = "prompt" THEN "look" ELSE @]
    /\ pressedOn' = [pressedOn EXCEPT ![a] = 0]
    /\ UNCHANGED <<n, win, near, ccVars, rec, seen, lim, label, byPerson, cp, noted, due, wkey, req,
                   pend, restarts, stored, ownGone, grants, wrong, moveVars, moves>>

\* A person answers the limit prompt "leave": the limit is theirs, and nothing acts on it until
\* a turn runs (Continued) or a new record is read (Read).
Leave(a) ==
    /\ Outside
    /\ pp[a] /\ step[a] = "prompt"
    /\ pp' = [pp EXCEPT ![a] = FALSE]
    /\ step' = [step EXCEPT ![a] = "left"]
    /\ UNCHANGED <<n, win, near, ccVars, rec, seen, lim, label, byPerson, cp, goes, noted, due,
                   wkey, req, pend, restarts, ghosts, moveVars>>

\* Another usable account has room, or no longer has: another agent's use, its reset. Its
\* room is its own, never its usage credits.
Rooms ==
    /\ Others
    /\ room' = ~room
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, rowVars, due, wkey, req, pend, restarts,
                   ghosts, far, where, mv, mvBy>>

\* Before the reset, an agent whose limit's reset is more than `move_after` away (`far`), with
\* another usable account that has room, is moved: the agent row says first that this limit's
\* move is claimed (the act's row in Acts), once per limit. A delegate moves on its own; a main
\* session never does: its limit prompt opens, offering the move beside the wait. Under MoveMain
\* a main moves as a delegate does; under MoveTwice the claim is not checked.
Away(a) ==
    /\ Others
    /\ step[a] \in {"idle", "own"} /\ cc[a] \notin {"working", "done"}
    /\ ~Passed(lim[a]) /\ far /\ room /\ Current(a)
    /\ mv[a] # lim[a] \/ Break = "MoveTwice"
    /\ mv' = [mv EXCEPT ![a] = lim[a]]
    /\ IF a \in Mains /\ Break # "MoveMain"
       THEN /\ step' = [step EXCEPT ![a] = "prompt"]
            /\ pp' = [pp EXCEPT ![a] = TRUE]
            /\ UNCHANGED mvBy
       ELSE /\ step' = [step EXCEPT ![a] = "move"]
            /\ mvBy' = [mvBy EXCEPT ![a] = FALSE]
            /\ UNCHANGED pp
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, label, byPerson, cp, goes, noted,
                   due, wkey, req, pend, restarts, ghosts, far, room, where>>

\* A person answers a limit prompt "move": the move is theirs, a main's or a delegate's.
AnswerMove(a) ==
    /\ Outside
    /\ Others /\ pp[a] /\ step[a] = "prompt"
    /\ pp' = [pp EXCEPT ![a] = FALSE]
    /\ step' = [step EXCEPT ![a] = "move"]
    /\ mvBy' = [mvBy EXCEPT ![a] = TRUE]
    /\ goes' = [goes EXCEPT ![a] = 0]
    /\ streak' = [streak EXCEPT ![a] = 0]
    /\ UNCHANGED <<n, win, near, ccVars, rec, seen, lim, label, byPerson, cp, noted, due, wkey, req,
                   pend, restarts, stored, ownGone, pressedOn, grants, wrong, far, room, where, mv,
                   moves>>

\* The Mover's one move, decided on the newest record: drained, ended, the conversation
\* copied, resumed on the other account under its name and session id, where it runs. Refused
\* (no account with room) or failed, it stays here, limited and idle, and a limit prompt tells a
\* person. Unknown, it may have moved: a person's prompt, never a second move.
Moved(a) ==
    /\ where' = [where EXCEPT ![a] = "there"]
    /\ live' = [live EXCEPT ![a] = TRUE]
    /\ cc' = [cc EXCEPT ![a] = "working"]
    /\ screen' = [screen EXCEPT ![a] = "input"]
    /\ stale' = [stale EXCEPT ![a] = FALSE]

MoveAct(a) ==
    /\ step[a] = "move" /\ cc[a] \notin {"working", "done"} /\ Current(a)
    /\ moves' = [moves EXCEPT ![a][lim[a]] = IF mvBy[a] THEN @ ELSE @ + 1]
    /\ wrong' = wrong \cup (IF a \in Mains /\ ~mvBy[a] THEN {"moved a main unasked"} ELSE {})
    /\ \/ /\ room /\ Moved(a)
          /\ step' = [step EXCEPT ![a] = "moved"]
          /\ UNCHANGED pp
       \/ /\ step' = [step EXCEPT ![a] = "prompt"]
          /\ pp' = [pp EXCEPT ![a] = TRUE]
          /\ UNCHANGED <<cc, screen, live, stale, where>>
       \/ /\ room /\ Moved(a)
          /\ step' = [step EXCEPT ![a] = "prompt"]
          /\ pp' = [pp EXCEPT ![a] = TRUE]
    /\ UNCHANGED <<n, win, near, autos, hits, hitLim, menus, outside, rec, seen, lim, label,
                   byPerson, cp, goes, noted, due, wkey, req, pend, restarts, stored, ownGone,
                   pressedOn, streak, grants, far, room, mv, mvBy>>

\* Delegates reads a headless delegate's turn from its stream: the `result` that ends the turn
\* its brief (or its word to go on) began is its report, and its work ends there. A result at a
\* limit (`api_error: "usage_limit_reached"`) is not one (F-186's new-1): the turn is still
\* open, and the word at the reset goes on with it. Under LimitReport it is taken as the report.
Report(a) ==
    /\ a \in Headless \ Mains /\ ~reported[a]
    /\ cc[a] = "done" \/ (Break = "LimitReport" /\ cc[a] = "hit")
    /\ reported' = [reported EXCEPT ![a] = TRUE]
    /\ wrong' = IF cc[a] = "hit" THEN wrong \cup {"reported a limit"} ELSE wrong
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, rowVars, due, wkey, req, pend, restarts,
                   stored, ownGone, pressedOn, streak, grants, moves, moveVars, startVars>>

\* A start of new work is asked for: a delegate's, a main's, or a resume that must leave its
\* account.
StartAsked ==
    /\ Starts /\ sr = "none"
    /\ sr' = "new"
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, rowVars, due, wkey, req, pend, restarts,
                   ghosts, moveVars, reported, sAt, sp>>

\* Its owner picks its account on Usage's record (Usage.pick): another usable account with
\* room takes it; this one only while its record says it is not limited. Refused at a limit
\* (StartRefusedAtLimit), the row is written `waiting` for the soonest reset, its limit prompt
\* open. A row picked again at its reset that meets a newer limit waits for that one.
Pick ==
    /\ sr \in {"new", "again"}
    /\ CASE Others /\ room ->
              sr' = "there" /\ UNCHANGED <<sAt, sp, grants>>
         [] Limited ->
              /\ sr' = "waiting" /\ sAt' = rec /\ sp' = TRUE
              /\ UNCHANGED grants
         [] OTHER ->
              sr' = "granted" /\ grants' = grants + 1 /\ UNCHANGED <<sAt, sp>>
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, rowVars, due, wkey, req, pend, restarts,
                   stored, ownGone, pressedOn, streak, wrong, moveVars, moves, reported>>

\* A person answers the start's limit prompt "wait": the row waits for its reset as it would.
AnswerWait ==
    /\ Outside
    /\ sr = "waiting" /\ sp
    /\ sp' = FALSE
    /\ UNCHANGED <<n, win, near, ccVars, rec, rowVars, due, wkey, req, pend, restarts, ghosts,
                   moveVars, reported, sr, sAt>>

\* ... or "leave": the row is refused, `left`, and nothing starts.
AnswerLeave ==
    /\ Outside
    /\ sr = "waiting" /\ sp
    /\ sr' = "left" /\ sp' = FALSE
    /\ UNCHANGED <<n, win, near, ccVars, rec, rowVars, due, wkey, req, pend, restarts, ghosts,
                   moveVars, reported, sAt>>

\* Its deadline, the reset plus the margin, takes the default, the wait, as the framework's.
WaitDefault ==
    /\ sr = "waiting" /\ sp /\ Passed(sAt)
    /\ sp' = FALSE
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, rowVars, due, wkey, req, pend, restarts,
                   ghosts, moveVars, reported, sr, sAt>>

\* At the reset plus the margin, its prompt answered or its default taken, the owner picks again
\* under the row's own request id (Pick). Under NoRepick it starts on the pick it was refused by.
StartAtReset ==
    /\ sr = "waiting" /\ ~sp /\ Passed(sAt)
    /\ IF Break = "NoRepick"
       THEN sr' = "granted" /\ grants' = grants + 1
       ELSE sr' = "again" /\ UNCHANGED grants
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, rowVars, due, wkey, req, pend, restarts,
                   stored, ownGone, pressedOn, streak, wrong, moveVars, moves, reported, sAt, sp>>

\* The Scheduler answers the other request at once: granted only where the gate admits.
Answer ==
    /\ req = "asked"
    /\ IF Admit
       THEN req' = "granted" /\ grants' = grants + 1
       ELSE req' = "refused" /\ UNCHANGED grants
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, rowVars, due, wkey, pend, restarts, stored,
                   ownGone, pressedOn, streak, wrong, moveVars, moves>>

\* A restart of the framework: its memory goes, every row stays.
Restart ==
    /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ pend' = [a \in Agents |-> 0]
    \* A move claimed and not yet acted on: the claim a restart cut is a person's prompt
    \* (Heal.tla's Ask), never acted on again.
    /\ step' = [a \in Agents |-> IF step[a] = "move" THEN "prompt" ELSE step[a]]
    /\ pp' = [a \in Agents |-> pp[a] \/ step[a] = "move"]
    \* A start's row stays: a waiting one's timer is set again from it, and one picked again
    \* at its reset waits to be picked again. A start whose row was not yet written is cut.
    /\ sr' = CASE sr = "new" -> "cut" [] sr = "again" -> "waiting" [] OTHER -> sr
    /\ UNCHANGED <<n, win, near, ccVars, outside, rec, seen, lim, label, byPerson, cp, goes, noted,
                   due, wkey, req, ghosts, moveVars, reported, sAt, sp>>

-----------------------------------------------------------------------------

Init ==
    /\ n = 0 /\ win = "open" /\ near = FALSE /\ far = FALSE
    /\ room \in IF Others THEN BOOLEAN ELSE {FALSE}
    /\ where = [a \in Agents |-> "here"]
    /\ mv = [a \in Agents |-> 0]
    /\ mvBy = [a \in Agents |-> FALSE]
    /\ reported = [a \in Agents |-> FALSE]
    /\ moves =[a \in Agents |-> [k \in Limits |-> 0]]
    /\ cc = [a \in Agents |-> "working"]
    /\ screen = [a \in Agents |-> "input"]
    /\ live = [a \in Agents |-> TRUE]
    /\ autos = [a \in Agents |-> 0]
    /\ stale = [a \in Agents |-> FALSE]
    /\ hits = [a \in Agents |-> 0]
    /\ hitLim = [a \in Agents |-> 0]
    /\ menus = [a \in Agents |-> 0]
    /\ outside = 0
    /\ rec = 0
    /\ seen = [a \in Agents |-> 0]
    /\ lim = [a \in Agents |-> 0]
    /\ step = [a \in Agents |-> "none"]
    /\ label = [a \in Agents |-> "stop"]
    /\ byPerson = [a \in Agents |-> FALSE]
    /\ cp = [a \in Agents |-> FALSE]
    /\ pp = [a \in Agents |-> FALSE]
    /\ goes = [a \in Agents |-> 0]
    /\ noted = [a \in Agents |-> 0]
    /\ due = [a \in Agents |-> 0]
    /\ wkey = [a \in Agents |-> 0]
    /\ req = "none"
    /\ pend = [a \in Agents |-> 0]
    /\ restarts = 0
    /\ sr = "none" /\ sAt = 0 /\ sp = FALSE
    /\ stored = [a \in Agents |-> [k \in Limits |-> 0]]
    /\ ownGone = [a \in Agents |-> {}]
    /\ pressedOn = [a \in Agents |-> 0]
    /\ streak = [a \in Agents |-> 0]
    /\ grants = 0
    /\ wrong = {}

Framework(a) ==
    \/ Read(a) \/ Look(a) \/ CreditsDefault(a) \/ CreditsGone(a) \/ Press(a) \/ Unsure(a)
    \/ Abandoned(a) \/ Overdue(a) \/ GoOn(a) \/ Send(a) \/ Sent(a) \/ Deliver(a) \/ Continued(a)
    \/ Ended(a) \/ Away(a) \/ MoveAct(a)

Person(a) ==
    \/ GoesStale(a) \/ Esc(a) \/ Type(a) \/ Exit(a) \/ AnswerLimit(a) \/ AnswerMove(a) \/ Leave(a)
    \/ \E l \in {"stop", "wait", "spend"} : Choose(a, l)
    \/ \E l \in Labels : AnswerCredits(a, l)

Start == StartAsked \/ Pick \/ AnswerWait \/ AnswerLeave \/ WaitDefault \/ StartAtReset

Next ==
    \/ Kept(Close \/ Reset \/ Ask \/ Answer \/ Rooms)
    \/ Restart \/ Start
    \/ \E a \in Agents :
          \/ Kept(Hit(a) \/ TurnEnds(a) \/ AutoGo(a) \/ Framework(a) \/ Person(a))
          \/ Report(a)

Fairness ==
    /\ WF_vars(Kept(Reset)) /\ WF_vars(Kept(Answer))
    /\ WF_vars(Pick) /\ WF_vars(WaitDefault) /\ WF_vars(StartAtReset)
    /\ \A a \in Agents :
          /\ WF_vars(Kept(Hit(a))) /\ WF_vars(Kept(AutoGo(a)))
          /\ WF_vars(Kept(Read(a))) /\ WF_vars(Kept(Look(a))) /\ WF_vars(Kept(CreditsDefault(a)))
          /\ WF_vars(Kept(CreditsGone(a))) /\ WF_vars(Kept(Press(a))) /\ WF_vars(Kept(Unsure(a)))
          /\ WF_vars(Kept(Abandoned(a))) /\ WF_vars(Kept(Overdue(a))) /\ WF_vars(Kept(GoOn(a)))
          /\ WF_vars(Kept(Send(a))) /\ WF_vars(Kept(Sent(a))) /\ WF_vars(Kept(Deliver(a)))
          /\ WF_vars(Kept(Continued(a))) /\ WF_vars(Kept(Ended(a))) /\ WF_vars(Kept(Away(a)))
          /\ WF_vars(Kept(MoveAct(a)))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ n \in Limits /\ win \in {"open", "closed"} /\ near \in BOOLEAN
    /\ cc \in [Agents -> {"working", "done", "hit", "idle"}]
    /\ screen \in [Agents -> {"input", "menu", "wait"}]
    /\ live \in [Agents -> BOOLEAN] /\ autos \in [Agents -> Nat]
    /\ stale \in [Agents -> BOOLEAN]
    /\ hits \in [Agents -> Nat] /\ hitLim \in [Agents -> Limits] /\ menus \in [Agents -> Nat]
    /\ outside \in 0..MaxOutside
    /\ rec \in Limits /\ seen \in [Agents -> Nat] /\ lim \in [Agents -> Limits]
    /\ step \in [Agents -> Steps] /\ label \in [Agents -> Labels]
    /\ byPerson \in [Agents -> BOOLEAN] /\ cp \in [Agents -> BOOLEAN] /\ pp \in [Agents -> BOOLEAN]
    /\ goes \in [Agents -> Nat] /\ due \in [Agents -> Nat] /\ wkey \in [Agents -> Limits]
    /\ req \in {"none", "asked", "granted", "refused"}
    /\ noted \in [Agents -> Limits]
    /\ pend \in [Agents -> Limits] /\ restarts \in 0..MaxRestarts
    /\ far \in BOOLEAN /\ room \in BOOLEAN /\ where \in [Agents -> {"here", "there"}]
    /\ mv \in [Agents -> Limits] /\ mvBy \in [Agents -> BOOLEAN]
    /\ reported \in [Agents -> BOOLEAN]
    /\ sr \in StartRows /\ sAt \in Limits /\ sp \in BOOLEAN

\* The start's limit prompt is its waiting row's: open only while the row waits, and a row
\* waits only for a limit Usage read.
StartPromptIsRow == /\ sp => sr = "waiting"
                    /\ sr = "waiting" => sAt > 0

\* A headless delegate's result at a limit is never its report.
LimitNotReport == "reported a limit" \notin wrong

\* No usage credits but by a person's answer: the framework presses the credits only as a
\* person answered its usage_credits prompt.
NeverSpends == "spent unasked" \notin wrong

\* No start, resume or lease is granted on an account its record says limited.
NoStartOnLimited == [][grants' > grants => ~Limited]_vars

\* ... and a word's resume is never admitted while the account is limited.
NoResumeOnLimited == "resumed while limited" \notin wrong

\* At most one word to go on per agent per limit, and none to an agent whose own wait went on
\* at that limit.
GoOnOnce ==
    \A a \in Agents : \A k \in Limits :
        /\ stored[a][k] <= 1
        /\ k \in ownGone[a] => stored[a][k] = 0

\* The menu is pressed at most once each time it shows, and only while it shows; once more
\* only after a person who saw it still shown cleared a press whose outcome is unknown.
MenuPressedOnce == {"pressed twice", "pressed off the menu"} \cap wrong = {}

\* The framework's go-ons in a row, with no turn ended by itself and no person's answer
\* between, never pass Bound.
BoundedRetries == \A a \in Agents : streak[a] <= Bound

\* A main session is moved only by a person's answer of its limit prompt.
NeverMovesMain == "moved a main unasked" \notin wrong

\* The framework moves an agent at most once per limit; a refused, failed or unknown move
\* leaves it to a person.
MoveOnce == \A a \in Agents : \A k \in Limits : moves[a][k] <= 1

\* Liveness: every agent marked limited, once its limit's reset passed, goes on or is a
\* person's prompt, or a person took it ("leave").
NoAgentLeftLimited == \A a \in Agents : lim[a] > 0 ~> (lim[a] = 0 \/ pp[a] \/ step[a] = "left")

\* Liveness: every limit record is read: the agent's row says so.
RecordRead == \A a \in Agents : hits[a] > seen[a] ~> hits[a] = seen[a]

\* Liveness: a start refused at a limit is, after its reset, granted here or on another account,
\* or left by a person.
StartWaitEnds == sr = "waiting" ~> sr \in {"granted", "there", "left"}

=============================================================================
