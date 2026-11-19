------------------------------- MODULE Intake -------------------------------
(***************************************************************************)
(* How hook events reach the framework, and how a PermissionRequest hook   *)
(* is held until it is answered: events fired by Claude Code, stored,      *)
(* acknowledged, sent twice or lost, with restarts of the framework; and   *)
(* one session's permission dialogs, one at a time, each with its hook.    *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework (none built yet):         *)
(*   Intake  the HTTP endpoint every account's settings name as an http    *)
(*           hook: it writes an event's row, then answers the request; it  *)
(*           holds a PermissionRequest's request open, its row "held",     *)
(*           until an answer, or until its own deadline, which comes       *)
(*           before Claude Code's timeout for the hook;                    *)
(*   MCP     answer(agent, dialog, label), which names one held request    *)
(*           by its id (the agent's claim is Team.tla's).                  *)
(* And Claude Code 2.1.322: it posts each event once and never retries; a  *)
(* refused or failed post loses that event; the dialog is on the screen    *)
(* while the hook runs, the first answer closes it, and a later one is     *)
(* dropped; a hook that fails, times out or answers no decision leaves     *)
(* the dialog to a person; a person's answer does not end the hook.        *)
(*                                                                         *)
(* Left abstract: time (the framework's deadline before Claude Code's     *)
(* timeout is an ordering of steps, HookTimesOut's guard); what an event   *)
(* says and who reads it (each event is an id, and "twice" is the same id  *)
(* posted again); the label of an answer; the transcript and the screen.   *)
(* A dialog opens only after the one before it closed.                     *)
(*                                                                         *)
(* Fairness: the framework's steps happen while they stay possible, and    *)
(* Claude Code's timeout ends a hook. Agents and people may never answer.  *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Intake_<value>.cfg that TLC must fail.                      *)
(*                                                                         *)
(* Each hold is Hold.tla's: HP for PermissionRequest, whose decider is an *)
(* answer that names the dialog, and HT for PreToolUse, whose decider is   *)
(* the app's callback. Hold owns the row, the request held open, the one   *)
(* response, the deadline, the late decision dropped and the settle after  *)
(* a restart; this spec says what Claude Code reads of each response.      *)
(*                                                                         *)
(* Defense in depth, with no Break: SentAtMostOnce (Hold's OneResponse).   *)
(* AnswerAsked takes only a "held" row, and AnswerWritten closes the       *)
(* request; each alone keeps a second answer off one hook.                 *)
(*                                                                         *)
(* PreToolUse (F-111): each tool call posts once and is held while the     *)
(* app's callback, in a process of its own, is asked. Intake hands the     *)
(* plug exactly one response: the callback's decision (its row says        *)
(* deciding first) or an empty body, for a pass or at Intake's deadline,   *)
(* which comes before the hook's timeout. A decision after that is         *)
(* dropped. A restart cuts the request, and Claude Code goes on with no    *)
(* decision; the row then settles as a permission's does (R5: one hold).   *)
(* The plug's write of what it is handed is one step with the hand here.   *)
(* Left abstract: which decision (allow, deny, ask are one "decision"),    *)
(* and a second post of one call, which the code answers from the row.    *)
(* Defense in depth, with no Break: DecidedHasRow, since the row says      *)
(* deciding before the decision is handed out.                             *)
(*                                                                         *)
(* The waiter (F-114, F-123): one session's asyncRewake Stop hooks. Each   *)
(* turn's end starts a program that posts to Intake and waits; Intake      *)
(* holds it (HW), with no row of its own: its "row" here is Intake's       *)
(* memory of the hold, and the call that hands it text answers Mailbox     *)
(* (mail) from it: answered is {:ok, :sent}, unknown is {:unknown, _}.     *)
(* The decider is Mailbox's due text, one in flight per session, handed    *)
(* only to the session's waiter (cur) while it is held; with none,         *)
(* deliver is refused and nothing changes. The response is chunked: a      *)
(* heartbeat of whitespace every few seconds, and the text as the last     *)
(* chunk. The program can die unseen (a compaction, the session's exit);   *)
(* a write to its connection may still succeed, so text written there is   *)
(* not read, and only the transcript says what was. The next heartbeat     *)
(* fails and cuts the hold (Hold's Cut). Every Stop event starts a waiter, *)
(* a blocked one too (measured on 2.1.322, F-157: nine blocked Stops left  *)
(* nine live waiters), so a session has several live connections. Intake   *)
(* keeps the newest as the session's waiter, and answers each older one    *)
(* still held empty at once (Superseded): its program exits 0 and wakes    *)
(* nothing. A waiter whose text is in flight is not replaced: a newer one  *)
(* waits behind it and takes its place once its hold ends. The deadline   *)
(* is hours and the heartbeat seconds, so a death is found before the      *)
(* deadline: the guard of WaiterExpires. Sessions are apart, so the spec   *)
(* has one.                                                                *)
(* Left abstract: the heartbeat's period and the one sent at a second      *)
(* waiter's arrival (both are HeartbeatFails, enabled while a death is     *)
(* unseen); what the text says; Mailbox's settle from the transcript       *)
(* (Delivery.tla), so a row it was told unknown stays so here.             *)
(*                                                                         *)
(* The Stop hold (F-157, decision 10): with the app's `stop` callback,     *)
(* each of the session's Stop hooks is held (HS) and the callback decides  *)
(* it: a pass lets the turn end, a block sends the agent back with a       *)
(* reason. Claude Code honors at most Cap blocks in a row with no tool     *)
(* call between and overrides the next (measured: 8 on 2.1.322); the      *)
(* override is the environment's act here (StopRead). Intake keeps its own *)
(* count of the session's blocks in a row in its table, written with the   *)
(* block's row before the response goes out, and reset by a PostToolUse   *)
(* post and by a Stop it passes, which ends the turn: Claude Code starts  *)
(* the next turn, a person's prompt's or a wake's, with its count at 0    *)
(* (measured on 2.1.322, F-171). It may count more than Claude Code (a     *)
(* post lost while down, a turn ended while down), never fewer while a     *)
(* turn runs. Below Cap - 1 the callback's block is handed. At             *)
(* Cap - 1 a block is not handed: the hold becomes a `stop_cap` prompt     *)
(* (Prompt.tla), whose person's "go on" is the last block Claude Code      *)
(* honors and whose "end" lets the turn end (F-167's new-1). At Cap or     *)
(* more the hold passes at once, recorded capped. A pause (per agent or    *)
(* per project, set by the app or the operator) keeps the callback from    *)
(* deciding: a Stop held while paused is asked once the pause lifts, or    *)
(* ends at the deadline. Left abstract: the reason's text; a pause that    *)
(* answers with the app's word in place of holding (it is one more         *)
(* decider of the hold, counted as the callback's block or pass is); the   *)
(* waiter each Stop starts, which the waiter's section models alone.       *)
(*                                                                         *)
(* Sessions' contract for hooks (F-163): an event acknowledged only once   *)
(* stored, stored once (AckedIsStored, StoredOnce); each hold one          *)
(* response, only to the request it names, a late decision dropped, and    *)
(* every hold settles (Hold.tla's, instanced: SentAtMostOnce,              *)
(* OnlyNamedDialog, LateDropped, HoldSettles, and the tool and waiter      *)
(* kinds' own); a waiter's text read at most once (ReadOnce). Boxes.tla    *)
(* folds the waiter into Sessions' hand; the held permission request is a  *)
(* prompt of Prompt.tla's (B1), which instances Hold. No gap for           *)
(* Boxes.tla.                                                              *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
    Events,       \* hook events other than PermissionRequest, by id
    MaxPosts,     \* posts of one event: more than one is a duplicate
    MaxDialogs,   \* permission dialogs of the session, 1..MaxDialogs, in order
    MaxCalls,     \* tool calls of the session, each with its PreToolUse hook
    MaxWaiters,   \* waiters of the session, started in order, each at a turn's end
    MaxTexts,     \* texts Mailbox has due for the session
    MaxStops,     \* Stop hooks of the session, in order, each held for the app's callback
    MaxToolCalls, \* tool calls of the session, each resetting Claude Code's count of blocks
    MaxPauses,    \* pauses set (and lifted) on the session's agent or project
    Cap,          \* Stop blocks in a row Claude Code honors (8 on 2.1.322)
    MaxRestarts,  \* restarts of the framework
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "AckBeforeStore",   \* the request is answered before the event's row is written
    "NoDedupe",         \* a duplicate post writes a second row for one event
    "ByAgent",          \* an answer goes to the agent's newest held hook, not the one it names
    "NoOwnDeadline",    \* the framework keeps a hold past Claude Code's timeout
    "NoExpiry",         \* the framework never releases a hold no one answers
    "TrustAnswering",   \* after a restart, a row still "deciding" is taken as answered
    "TypeWhenNoHold",   \* a dialog whose hold is gone is answered by typed keys
    "TwoResponses",     \* the tool deadline fires after the decision was handed out
    "LateSent",         \* a decision after the tool deadline is still handed out
    "NoHeartbeat",      \* a waiter's hold writes nothing until its end
    "RefuseSecond",     \* a second waiter is answered empty while the first is held
    "RefuseUnknown",    \* text whose write was cut is told refused, not unknown
    "NoCap",            \* the callback's block is handed at every count, past Claude Code's cap
    "CountInMemory",    \* the count of blocks is kept in memory, so a restart forgets it
    "IgnorePause"       \* a Stop held while paused is decided by the callback
}

ASSUME Break \in Breaks
ASSUME MaxPosts \in Nat /\ MaxDialogs \in Nat /\ MaxCalls \in Nat /\ MaxRestarts \in Nat
ASSUME MaxWaiters \in Nat /\ MaxTexts \in Nat
ASSUME MaxStops \in Nat /\ MaxToolCalls \in Nat /\ MaxPauses \in Nat /\ Cap \in Nat \ {0}

Dialogs == 1..MaxDialogs
Calls == 1..MaxCalls
Waiters == 1..MaxWaiters
Texts == 1..MaxTexts
Stops == 1..MaxStops

VARIABLES
    up,        \* the framework runs
    restarts,  \* restarts so far
    posts,     \* e -> posts of e so far
    inflight,  \* e -> its requests open at the framework, no row written yet
    toStore,   \* e -> requests answered, row not yet written (AckBeforeStore only)
    toAck,     \* e -> requests whose row is written, not yet answered
    rows,      \* table: e -> rows of e
    acked,     \* e -> requests Claude Code got a 200 for
    dialog,    \* p -> "none", "open", "closed"
    outcome,   \* p -> "none", "hook", "person", "keys": what closed it
    hook,      \* p -> "none", "waiting", "answered", "released", "failed", "timedout"
    \* p's hold, as Hold.tla's variables (HP)
    conn,      \* in memory: p -> the framework holds p's request open
    hold,      \* table: p -> its row (Hold's Rows)
    written,   \* in memory: holds whose answer is written, row not yet marked
    sent,      \* p -> the responses written on p's request, in order
    heard,     \* p -> the answer was read by a hook still waiting for it
    typed,     \* dialogs answered by typed keys
    wrong,     \* answers that took another dialog's hold: [meant, got]
    call,      \* c -> "none", "waiting", "decided", "passed", "failed": what c's
               \*      PreToolUse hook read
    cb,        \* c -> "none", "asked", "decision", "pass", "used": the callback
    \* c's hold, as Hold.tla's variables (HT)
    tconn,     \* in memory: c -> the plug holds c's request open
    trow,      \* table: c -> its row (Hold's Rows)
    tmarking,  \* in memory: calls whose decision went out, row not yet marked
    handed,    \* c -> what Intake handed the plug for c, in order: "decision" or "empty"
    twrong,    \* decisions that took another call's hold: none, as each names its own
    prog,      \* w -> "none", "waiting", "woke" (read text, exit 2), "idle" (read
               \*      nothing, exit 0), "failed" (read an error), "gone" (ended unseen)
    \* w's hold, as Hold.tla's variables (HW)
    wconn,     \* in memory: Intake holds w's request open
    wrow,      \* in memory: w's hold (Hold's Rows); no table row
    wmarking,  \* in memory: waiters whose text was written, not yet marked
    wout,      \* w -> what was written on w's request, in order: "decision" (text) or "empty"
    wwrong,    \* text that took another waiter's hold: none, as it takes the session's
    cur,       \* the session's waiter in Intake's map, or 0
    gave,      \* w -> the text handed to w, or 0
    mail,      \* t -> "due", "sending", "sent", "unknown": Mailbox's row, by deliver's answer
    read,      \* t -> how many programs read t (and woke their session with it)
    superseded, \* ghost: waiters answered empty because a newer one was live
    turn,      \* the session's turn: "working", "stopping" (its Stop hook runs), "ended"
    stp,       \* s -> "none", "waiting", "blocked", "passed", "failed": what Stop hook s read
    scb,       \* s -> "none", "asked", "paused", "block", "pass", "used": the callback
    capq,      \* the Stops held as a `stop_cap` prompt, decided by a person
    \* s's hold, as Hold.tla's variables (HS)
    sconn,     \* in memory: Intake holds s's request open
    srow,      \* table: s's row (Hold's Rows)
    smarking,  \* in memory: Stops whose decision went out, row not yet marked
    sout,      \* s -> what Intake handed s's request, in order: "decision" or "empty"
    swrong,    \* decisions that took another Stop's hold: none, as each names its own
    ccBlocks,  \* Claude Code's count of blocks in a row, no tool call between
    fBlocks,   \* table: Intake's count of the session's blocks in a row
    toolsRun,  \* tool calls so far
    paused,    \* table: the session's agent or project is paused
    pauses,    \* pauses set so far
    faults     \* ghost: "overridden" (a block of the framework's overridden), "whilePaused"

eventVars == <<posts, inflight, toStore, toAck, rows, acked>>
dialogVars == <<dialog, outcome, hook, conn, hold, written, sent, heard, typed, wrong>>
toolVars == <<call, cb, tconn, trow, tmarking, handed, twrong>>
waiterVars == <<prog, wconn, wrow, wmarking, wout, wwrong, cur, gave, mail, read, superseded>>
stopVars == <<turn, stp, scb, capq, sconn, srow, smarking, sout, swrong, ccBlocks, fBlocks,
              toolsRun, paused, pauses, faults>>
vars == <<up, restarts, eventVars, dialogVars, toolVars, waiterVars, stopVars>>

\* PermissionRequest's holds, and PreToolUse's.
HP == INSTANCE Hold WITH
        Reqs <- Dialogs, conn <- conn, row <- hold, marking <- written, out <- sent,
        wrong <- wrong,
        Break <- CASE Break = "ByAgent" -> "NotNamed"
                   [] Break = "NoExpiry" -> "NoDeadline"
                   [] Break = "TrustAnswering" -> "TrustDeciding"
                   [] OTHER -> "none"
HT == INSTANCE Hold WITH
        Reqs <- Calls, conn <- tconn, row <- trow, marking <- tmarking, out <- handed,
        wrong <- twrong,
        Break <- CASE Break = "TwoResponses" -> "TwoResponses"
                   [] Break = "LateSent" -> "LateSent"
                   [] OTHER -> "none"
HW == INSTANCE Hold WITH
        Reqs <- Waiters, conn <- wconn, row <- wrow, marking <- wmarking, out <- wout,
        wrong <- wwrong, Break <- "none"
HS == INSTANCE Hold WITH
        Reqs <- Stops, conn <- sconn, row <- srow, marking <- smarking, out <- sout,
        wrong <- swrong, Break <- "none"

-----------------------------------------------------------------------------
Init ==
    /\ up = TRUE /\ restarts = 0
    /\ posts = [e \in Events |-> 0]
    /\ inflight = [e \in Events |-> 0]
    /\ toStore = [e \in Events |-> 0]
    /\ toAck = [e \in Events |-> 0]
    /\ rows = [e \in Events |-> 0]
    /\ acked = [e \in Events |-> 0]
    /\ dialog = [p \in Dialogs |-> "none"]
    /\ outcome = [p \in Dialogs |-> "none"]
    /\ hook = [p \in Dialogs |-> "none"]
    /\ conn = [p \in Dialogs |-> FALSE]
    /\ hold = [p \in Dialogs |-> "none"]
    /\ written = {}
    /\ sent = [p \in Dialogs |-> <<>>]
    /\ heard = [p \in Dialogs |-> FALSE]
    /\ typed = {}
    /\ wrong = {}
    /\ call = [c \in Calls |-> "none"]
    /\ cb = [c \in Calls |-> "none"]
    /\ tconn = [c \in Calls |-> FALSE]
    /\ trow = [c \in Calls |-> "none"]
    /\ tmarking = {}
    /\ handed = [c \in Calls |-> <<>>]
    /\ twrong = {}
    /\ prog = [w \in Waiters |-> "none"]
    /\ wconn = [w \in Waiters |-> FALSE]
    /\ wrow = [w \in Waiters |-> "none"]
    /\ wmarking = {}
    /\ wout = [w \in Waiters |-> <<>>]
    /\ wwrong = {}
    /\ cur = 0
    /\ gave = [w \in Waiters |-> 0]
    /\ mail = [t \in Texts |-> "due"]
    /\ read = [t \in Texts |-> 0]
    /\ superseded = {}
    /\ turn = "working"
    /\ stp = [s \in Stops |-> "none"]
    /\ scb = [s \in Stops |-> "none"]
    /\ capq = {}
    /\ sconn = [s \in Stops |-> FALSE]
    /\ srow = [s \in Stops |-> "none"]
    /\ smarking = {}
    /\ sout = [s \in Stops |-> <<>>]
    /\ swrong = {}
    /\ ccBlocks = 0 /\ fBlocks = 0 /\ toolsRun = 0
    /\ paused = FALSE /\ pauses = 0
    /\ faults = {}

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; open requests do not *)

\* Every open request is cut: Claude Code reads an error, so a held hook
\* fails and its dialog stays on the screen.
FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ inflight' = [e \in Events |-> 0]
    /\ toStore' = [e \in Events |-> 0]
    /\ toAck' = [e \in Events |-> 0]
    /\ HP!Cut(Dialogs)
    /\ hook' = [p \in Dialogs |-> IF conn[p] /\ hook[p] = "waiting" THEN "failed" ELSE hook[p]]
    /\ HT!Cut(Calls)
    /\ call' = [c \in Calls |-> IF tconn[c] /\ call[c] = "waiting" THEN "failed" ELSE call[c]]
    /\ HW!Cut(Waiters)
    /\ prog' = [w \in Waiters |-> IF wconn[w] /\ prog[w] = "waiting" THEN "failed" ELSE prog[w]]
    /\ cur' = 0
    /\ HS!Cut(Stops)
    \* A Stop hook that fails lets the turn end (onFailure continue).
    /\ stp' = [s \in Stops |-> IF sconn[s] /\ stp[s] = "waiting" THEN "failed" ELSE stp[s]]
    /\ turn' = IF \E s \in Stops : sconn[s] /\ stp[s] = "waiting" THEN "ended" ELSE turn
    /\ fBlocks' = IF Break = "CountInMemory" THEN 0 ELSE fBlocks
    /\ UNCHANGED <<posts, rows, acked, dialog, outcome, heard, typed, cb>>
    /\ UNCHANGED <<wrow, wout, wwrong, gave, mail, read, superseded>>
    /\ UNCHANGED <<scb, capq, srow, sout, swrong, ccBlocks, toolsRun, paused, pauses, faults>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<toolVars, waiterVars, stopVars>>
    /\ UNCHANGED <<restarts, eventVars, dialogVars>>

-----------------------------------------------------------------------------
(* Events: posted, stored, then acknowledged *)

\* Claude Code posts the event. With the framework down the post is refused
\* and the event is lost; a reader of the transcript or the process stands in.
Posted(e) ==
    /\ posts[e] < MaxPosts
    /\ posts' = [posts EXCEPT ![e] = @ + 1]
    /\ inflight' = IF up THEN [inflight EXCEPT ![e] = @ + 1] ELSE inflight
    /\ UNCHANGED <<toolVars, waiterVars, stopVars>>
    /\ UNCHANGED <<up, restarts, toStore, toAck, rows, acked, dialogVars>>

\* The row is written once per event: a second post of it finds the row.
Stored(e) ==
    /\ up /\ inflight[e] > 0 /\ Break # "AckBeforeStore"
    /\ inflight' = [inflight EXCEPT ![e] = @ - 1]
    /\ toAck' = [toAck EXCEPT ![e] = @ + 1]
    /\ rows' = [rows EXCEPT ![e] = IF @ = 0 \/ Break = "NoDedupe" THEN @ + 1 ELSE @]
    /\ UNCHANGED <<toolVars, waiterVars, stopVars>>
    /\ UNCHANGED <<up, restarts, posts, toStore, acked, dialogVars>>

Acked(e) ==
    /\ up /\ toAck[e] > 0
    /\ toAck' = [toAck EXCEPT ![e] = @ - 1]
    /\ acked' = [acked EXCEPT ![e] = @ + 1]
    /\ UNCHANGED <<toolVars, waiterVars, stopVars>>
    /\ UNCHANGED <<up, restarts, posts, inflight, toStore, rows, dialogVars>>

\* Under AckBeforeStore: the 200 goes out first, the row after.
AckedFirst(e) ==
    /\ up /\ inflight[e] > 0 /\ Break = "AckBeforeStore"
    /\ inflight' = [inflight EXCEPT ![e] = @ - 1]
    /\ toStore' = [toStore EXCEPT ![e] = @ + 1]
    /\ acked' = [acked EXCEPT ![e] = @ + 1]
    /\ UNCHANGED <<toolVars, waiterVars, stopVars>>
    /\ UNCHANGED <<up, restarts, posts, toAck, rows, dialogVars>>

StoredLate(e) ==
    /\ up /\ toStore[e] > 0
    /\ toStore' = [toStore EXCEPT ![e] = @ - 1]
    /\ rows' = [rows EXCEPT ![e] = IF @ = 0 THEN @ + 1 ELSE @]
    /\ UNCHANGED <<toolVars, waiterVars, stopVars>>
    /\ UNCHANGED <<up, restarts, posts, inflight, toAck, acked, dialogVars>>

-----------------------------------------------------------------------------
(* Claude Code: a dialog, its hook, a person, and the hook's timeout *)

\* The dialog shows and its hook posts at once. With the framework down
\* the post fails, and the dialog waits for a person.
DialogOpens(p) ==
    /\ dialog[p] = "none" /\ \A q \in Dialogs : q < p => dialog[q] = "closed"
    /\ dialog' = [dialog EXCEPT ![p] = "open"]
    /\ hook' = [hook EXCEPT ![p] = IF up THEN "waiting" ELSE "failed"]
    /\ HP!Opens(p, up)
    /\ UNCHANGED <<toolVars, waiterVars, stopVars>>
    /\ UNCHANGED <<up, restarts, eventVars, outcome, heard, typed>>

\* A person answers on the screen or by Remote Control. The hook goes on
\* waiting; whatever it reads later is dropped.
PersonAnswers(p) ==
    /\ dialog[p] = "open"
    /\ dialog' = [dialog EXCEPT ![p] = "closed"]
    /\ outcome' = [outcome EXCEPT ![p] = "person"]
    /\ UNCHANGED <<toolVars, waiterVars, stopVars>>
    /\ UNCHANGED <<up, restarts, eventVars, hook, conn, hold, written, sent, heard, typed, wrong>>

\* Claude Code stops waiting. The framework's deadline comes first, so this
\* happens only to a hook the framework has let go of, which is none.
HookTimesOut(p) ==
    /\ hook[p] = "waiting"
    /\ hold[p] \notin {"none", "held", "deciding"} \/ Break \in {"NoOwnDeadline", "NoExpiry"}
    /\ hook' = [hook EXCEPT ![p] = "timedout"]
    /\ UNCHANGED <<toolVars, waiterVars, stopVars>>
    /\ UNCHANGED <<up, restarts, eventVars, dialog, outcome, conn, hold, written, sent, heard,
                   typed, wrong>>

-----------------------------------------------------------------------------
(* Intake: a held hook, its answer, its deadline, and a restart (HP) *)

PermissionOnly == UNCHANGED <<toolVars, waiterVars, stopVars>> /\ UNCHANGED <<up, restarts, eventVars>>

HoldStored(p) ==
    /\ up /\ HP!Held(p)
    /\ PermissionOnly /\ UNCHANGED <<dialog, outcome, hook, heard, typed>>

\* An answer meant for dialog m, which its sender saw, takes hold h: the
\* one it names. Under ByAgent it takes whichever hold is held.
AnswerAsked(m, h) ==
    /\ up /\ dialog[m] # "none" /\ HP!Asked(m, h)
    /\ PermissionOnly /\ UNCHANGED <<dialog, outcome, hook, heard, typed>>

\* The decision is the response to the hook's request, which then closes.
\* A hook still waiting reads it; a dialog still open closes by it.
AnswerWritten(p) ==
    /\ up /\ HP!Decides(p)
    /\ heard' = [heard EXCEPT ![p] = (hook[p] = "waiting")]
    /\ hook' = [hook EXCEPT ![p] = IF @ = "waiting" THEN "answered" ELSE @]
    /\ IF hook[p] = "waiting" /\ dialog[p] = "open"
         THEN /\ dialog' = [dialog EXCEPT ![p] = "closed"]
              /\ outcome' = [outcome EXCEPT ![p] = "hook"]
         ELSE UNCHANGED <<dialog, outcome>>
    /\ PermissionOnly /\ UNCHANGED typed

AnswerMarked(p) ==
    /\ up /\ HP!Marked(p)
    /\ PermissionOnly /\ UNCHANGED <<dialog, outcome, hook, heard, typed>>

\* The framework's own deadline: it answers "no decision", and the dialog
\* waits for a person.
HoldExpires(p) ==
    /\ up /\ HP!Expires(p)
    /\ hook' = [hook EXCEPT ![p] = IF @ = "waiting" THEN "released" ELSE @]
    /\ PermissionOnly /\ UNCHANGED <<dialog, outcome, heard, typed>>

\* After a restart a request is gone with its process: a held row is lost,
\* and one deciding is unknown, since the answer may not have gone out.
HoldSettled(p) ==
    /\ up /\ HP!Settles(p)
    /\ PermissionOnly /\ UNCHANGED <<dialog, outcome, hook, heard, typed>>

\* Under TypeWhenNoHold: with no hold to answer through, keys are typed.
AnswerTyped(p) ==
    /\ Break = "TypeWhenNoHold" /\ up /\ dialog[p] = "open" /\ hold[p] # "held"
    /\ dialog' = [dialog EXCEPT ![p] = "closed"]
    /\ outcome' = [outcome EXCEPT ![p] = "keys"]
    /\ typed' = typed \cup {p}
    /\ UNCHANGED <<toolVars, waiterVars, stopVars>>
    /\ UNCHANGED <<up, restarts, eventVars, hook, conn, hold, written, sent, heard, wrong>>

-----------------------------------------------------------------------------
(* PreToolUse: one response per request, the callback's decision or none (HT) *)

ToolOnly == UNCHANGED <<up, restarts, eventVars, dialogVars, waiterVars, stopVars>>

\* What the hook reads of a response handed while its request is open.
Reads(c, what) ==
    call' = [call EXCEPT ![c] = IF tconn[c] /\ call[c] = "waiting" THEN what ELSE call[c]]

\* Claude Code posts c's hook and waits. With the framework down the post
\* fails, and the tool call goes on with no decision (onFailure continue).
ToolPosted(c) ==
    /\ call[c] = "none"
    /\ call' = [call EXCEPT ![c] = IF up THEN "waiting" ELSE "failed"]
    /\ HT!Opens(c, up)
    /\ ToolOnly /\ UNCHANGED cb

\* Intake writes the request's row, starts its deadline, and asks the
\* callback in a process of its own.
ToolHeld(c) ==
    /\ up /\ HT!Held(c)
    /\ cb' = [cb EXCEPT ![c] = "asked"]
    /\ ToolOnly /\ UNCHANGED call

\* The callback answers whenever it does, or never: its process outlives
\* a deadline, and its answer may come after a restart.
CallbackAnswers(c) ==
    /\ cb[c] = "asked"
    /\ \E a \in {"decision", "pass"} : cb' = [cb EXCEPT ![c] = a]
    /\ ToolOnly /\ UNCHANGED <<call, tconn, trow, tmarking, handed, twrong>>

\* A decision takes the call's hold, while it is held: the row says
\* deciding. One that comes after the deadline or a restart is dropped.
DecisionTaken(c) ==
    /\ up /\ cb[c] = "decision" /\ HT!Asked(c, c)
    /\ cb' = [cb EXCEPT ![c] = "used"]
    /\ ToolOnly /\ UNCHANGED call

\* The decision is handed out, and the plug writes it. Under LateSent one
\* after the deadline is handed out too.
DecisionHanded(c) ==
    /\ up /\ HT!Decides(c)
    /\ Reads(c, "decided")
    /\ ToolOnly /\ UNCHANGED cb

ToolMarked(c) ==
    /\ up /\ HT!Marked(c)
    /\ ToolOnly /\ UNCHANGED <<call, cb>>

\* A pass: an empty body.
PassHanded(c) ==
    /\ up /\ cb[c] = "pass" /\ HT!Passed(c)
    /\ cb' = [cb EXCEPT ![c] = "used"]
    /\ Reads(c, "passed")
    /\ ToolOnly

\* Intake's deadline: an empty body. Under TwoResponses it fires on a call
\* already answered.
ToolDeadline(c) ==
    /\ up /\ HT!Expires(c)
    /\ Reads(c, "passed")
    /\ ToolOnly /\ UNCHANGED cb

\* After a restart the row of a cut request settles.
ToolSettled(c) ==
    /\ up /\ HT!Settles(c)
    /\ ToolOnly /\ UNCHANGED <<call, cb>>

-----------------------------------------------------------------------------
(* The waiter: one session's asyncRewake Stop hooks, each a hold (HW) *)

WaiterOnly == UNCHANGED <<up, restarts, eventVars, dialogVars, toolVars, stopVars, superseded>>

\* Intake keeps w as a hold: its text not yet written, or written and not
\* yet marked. Once its hold ends, the session takes its next waiter.
Live(w) == w # 0 /\ wrow[w] \in {"held", "deciding"}

\* The waiters held behind the session's one, and the newest of a set.
Behind == {w \in Waiters : wconn[w] /\ wrow[w] = "held" /\ w # cur}
Newest(S) == CHOOSE w \in S : \A v \in S : v <= w

\* What a program still waiting reads of an empty response: exit 0.
Idles(w) == prog' = [prog EXCEPT ![w] = IF @ = "waiting" THEN "idle" ELSE @]

\* A turn ends and Claude Code starts its waiter, which posts the Stop
\* hook's input and waits. Each starts after the one before it, which may
\* still run. With the framework down the post fails, and it exits 0.
WaiterStarts(w) ==
    /\ prog[w] = "none" /\ \A v \in Waiters : v < w => prog[v] # "none"
    /\ prog' = [prog EXCEPT ![w] = IF up THEN "waiting" ELSE "failed"]
    /\ HW!Opens(w, up)
    /\ WaiterOnly /\ UNCHANGED <<cur, gave, mail, read>>

\* Intake holds it: status 200 at once, then heartbeats. It is the
\* session's waiter, the newest, unless the session's waiter has text in
\* flight (or came later); then it waits behind it.
WaiterHeld(w) ==
    /\ up /\ HW!Held(w)
    /\ cur' = IF Live(cur) /\ (wrow[cur] = "deciding" \/ cur > w) THEN cur ELSE w
    /\ WaiterOnly /\ UNCHANGED <<prog, gave, mail, read>>

\* An older waiter still held, once a newer one is live, is answered empty
\* at once: its program exits 0 and wakes nothing.
Superseded(w) ==
    /\ up /\ w # cur /\ wconn[w] /\ wrow[w] = "held"
    /\ \E v \in Waiters : v > w /\ wconn[v] /\ wrow[v] \in {"held", "deciding"}
    /\ HW!Passed(w)
    /\ Idles(w)
    /\ superseded' = superseded \cup {w}
    /\ UNCHANGED <<up, restarts, eventVars, dialogVars, toolVars, stopVars>>
    /\ UNCHANGED <<cur, gave, mail, read>>

\* Under RefuseSecond: a waiter behind the session's one is answered empty.
TurnedAway(w) ==
    /\ Break = "RefuseSecond" /\ up /\ Live(cur) /\ w # cur /\ HW!Passed(w)
    /\ Idles(w)
    /\ WaiterOnly /\ UNCHANGED <<cur, gave, mail, read>>

\* Claude Code ends the program (a compaction, the session's exit, its
\* timeout), or its connection drops. Intake does not see it yet.
ProgramDies(w) ==
    /\ prog[w] = "waiting"
    /\ prog' = [prog EXCEPT ![w] = "gone"]
    /\ WaiterOnly /\ UNCHANGED <<wconn, wrow, wmarking, wout, wwrong, cur, gave, mail, read>>

\* A heartbeat to a connection whose program is gone fails, and the hold is
\* cut. One to a live program, or one that still succeeds, changes nothing.
HeartbeatFails(w) ==
    /\ up /\ Break # "NoHeartbeat"
    /\ wconn[w] /\ wrow[w] = "held" /\ prog[w] = "gone"
    /\ HW!Cut({w})
    /\ WaiterOnly /\ UNCHANGED <<prog, cur, gave, mail, read>>

\* Mailbox hands due text t to the session (deliver), one in flight. Intake
\* takes the session's waiter while it is held. With none, deliver is
\* refused, and nothing changes.
TextAsked(t) ==
    /\ up /\ mail[t] = "due" /\ \A u \in Texts : mail[u] # "sending"
    /\ Live(cur) /\ HW!Asked(cur, cur)
    /\ gave' = [gave EXCEPT ![cur] = t]
    /\ mail' = [mail EXCEPT ![t] = "sending"]
    /\ WaiterOnly /\ UNCHANGED <<prog, cur, read>>

\* The text is the last chunk, and the response ends. A program still
\* waiting reads it and exits 2, which wakes its session. To a program gone
\* unseen the write may still succeed, and no one reads it.
TextWritten(w) ==
    /\ up /\ HW!Decides(w)
    /\ IF prog[w] = "waiting"
         THEN /\ prog' = [prog EXCEPT ![w] = "woke"]
              /\ read' = [read EXCEPT ![gave[w]] = @ + 1]
         ELSE UNCHANGED <<prog, read>>
    /\ WaiterOnly /\ UNCHANGED <<cur, gave, mail>>

\* The plug tells Intake the write succeeded: deliver answers {:ok, :sent}.
TextMarked(w) ==
    /\ up /\ HW!Marked(w)
    /\ mail' = [mail EXCEPT ![gave[w]] = "sent"]
    /\ WaiterOnly /\ UNCHANGED <<prog, cur, gave, read>>

\* Intake's deadline, under the hook's timeout: an empty last chunk. A death
\* is found by a heartbeat first; under NoHeartbeat only the deadline finds it.
WaiterExpires(w) ==
    /\ up /\ (prog[w] # "gone" \/ Break = "NoHeartbeat") /\ HW!Expires(w)
    /\ Idles(w)
    /\ WaiterOnly /\ UNCHANGED <<cur, gave, mail, read>>

\* A cut hold ends: held is lost, and deciding unknown, since its text may
\* have been read: deliver answers {:unknown, _}, or, after a restart, its
\* call ended with Intake. Under RefuseUnknown it answers refused, and the
\* text is due again.
WaiterSettles(w) ==
    /\ up /\ HW!Settles(w)
    /\ mail' = IF wrow[w] = "deciding"
                 THEN [mail EXCEPT ![gave[w]] = IF Break = "RefuseUnknown" THEN "due" ELSE "unknown"]
                 ELSE mail
    /\ WaiterOnly /\ UNCHANGED <<prog, cur, gave, read>>

\* The session's waiter's hold ended: the newest held behind it takes its
\* place, or the session has none.
WaiterReplaced ==
    /\ up /\ cur # 0 /\ ~Live(cur)
    /\ cur' = IF Behind = {} THEN 0 ELSE Newest(Behind)
    /\ WaiterOnly /\ UNCHANGED <<prog, wconn, wrow, wmarking, wout, wwrong, gave, mail, read>>

-----------------------------------------------------------------------------
(* The Stop hold: the app's callback, Claude Code's cap, a pause (HS)      *)

StopOnly == UNCHANGED <<up, restarts, eventVars, dialogVars, toolVars, waiterVars>>

\* What Claude Code does with a response to Stop s's open request: a block
\* sends the agent back, honored while its count is under the cap and
\* overridden past it (the environment's act); an empty body ends the turn.
StopRead(s, what) ==
    /\ IF sconn[s] /\ stp[s] = "waiting"
         THEN /\ stp' = [stp EXCEPT ![s] = what]
              /\ IF what = "blocked" /\ ccBlocks < Cap
                   THEN turn' = "working" /\ ccBlocks' = ccBlocks + 1 /\ UNCHANGED faults
                   ELSE /\ turn' = "ended" /\ UNCHANGED ccBlocks
                        /\ faults' = IF what = "blocked" THEN faults \cup {"overridden"} ELSE faults
         ELSE UNCHANGED <<stp, turn, ccBlocks, faults>>

\* The turn reaches its Stop hook, which posts and waits. With the
\* framework down the post fails, and the turn ends.
StopFires(s) ==
    /\ turn = "working" /\ stp[s] = "none" /\ \A t \in Stops : t < s => stp[t] # "none"
    /\ stp' = [stp EXCEPT ![s] = IF up THEN "waiting" ELSE "failed"]
    /\ turn' = IF up THEN "stopping" ELSE "ended"
    /\ HS!Opens(s, up)
    /\ StopOnly
    /\ UNCHANGED <<scb, capq, srow, smarking, sout, swrong, ccBlocks, fBlocks, toolsRun, paused,
                   pauses, faults>>

\* Intake writes the row and starts the deadline. The callback is asked in a
\* process of its own, unless the session's agent or project is paused.
StopHeld(s) ==
    /\ up /\ HS!Held(s)
    /\ scb' = [scb EXCEPT ![s] = IF paused /\ Break # "IgnorePause" THEN "paused" ELSE "asked"]
    /\ StopOnly
    /\ UNCHANGED <<turn, stp, capq, ccBlocks, fBlocks, toolsRun, paused, pauses, faults>>

\* The callback answers whenever it does, or never.
StopCallback(s) ==
    /\ scb[s] = "asked"
    /\ \E a \in {"block", "pass"} : scb' = [scb EXCEPT ![s] = a]
    /\ StopOnly
    /\ UNCHANGED <<turn, stp, capq, sconn, srow, smarking, sout, swrong, ccBlocks, fBlocks,
                   toolsRun, paused, pauses, faults>>

\* The callback's answer is taken while the hold is held and nothing is
\* paused. A pass, or any answer at the cap or past it, is an empty body (at
\* the cap, recorded capped). A block below Cap - 1 is handed, the count
\* written with the row's deciding. A block at Cap - 1 is held as a
\* `stop_cap` prompt for a person. Under NoCap every block is handed.
StopTaken(s) ==
    /\ up /\ scb[s] \in {"block", "pass"} /\ srow[s] = "held" /\ sconn[s] /\ s \notin capq
    /\ ~paused \/ Break = "IgnorePause"
    /\ scb' = [scb EXCEPT ![s] = "used"]
    /\ CASE scb[s] = "block" /\ (fBlocks < Cap - 1 \/ Break = "NoCap") ->
              /\ HS!Asked(s, s) /\ fBlocks' = fBlocks + 1
              /\ faults' = IF paused THEN faults \cup {"whilePaused"} ELSE faults
              /\ UNCHANGED <<turn, stp, capq, ccBlocks>>
         [] scb[s] = "block" /\ fBlocks = Cap - 1 ->
              /\ capq' = capq \cup {s}
              /\ faults' = IF paused THEN faults \cup {"whilePaused"} ELSE faults
              /\ UNCHANGED <<turn, stp, sconn, srow, smarking, sout, swrong, fBlocks, ccBlocks>>
         [] OTHER ->
              /\ HS!Passed(s) /\ StopRead(s, "passed") /\ fBlocks' = 0
              /\ UNCHANGED capq
    /\ StopOnly /\ UNCHANGED <<toolsRun, paused, pauses>>

\* A person answers the `stop_cap` prompt: "go on" is the last block Claude
\* Code honors, "end" lets the turn end.
CapAnswered(s) ==
    /\ up /\ s \in capq /\ srow[s] = "held" /\ sconn[s]
    /\ \/ HS!Asked(s, s) /\ fBlocks' = fBlocks + 1 /\ UNCHANGED <<turn, stp, ccBlocks, faults>>
       \/ HS!Passed(s) /\ StopRead(s, "passed") /\ fBlocks' = 0
    /\ StopOnly /\ UNCHANGED <<scb, capq, toolsRun, paused, pauses>>

\* The block is the response, and the request closes.
StopHanded(s) ==
    /\ up /\ HS!Decides(s)
    /\ StopRead(s, "blocked")
    /\ StopOnly /\ UNCHANGED <<scb, capq, fBlocks, toolsRun, paused, pauses>>

StopMarked(s) ==
    /\ up /\ HS!Marked(s)
    /\ StopOnly
    /\ UNCHANGED <<turn, stp, scb, capq, ccBlocks, fBlocks, toolsRun, paused, pauses, faults>>

\* Intake's deadline, under the hook's timeout: an empty body, the turn ends,
\* and Intake's count with it.
StopDeadline(s) ==
    /\ up /\ HS!Expires(s)
    /\ StopRead(s, "passed") /\ fBlocks' = 0
    /\ StopOnly /\ UNCHANGED <<scb, capq, toolsRun, paused, pauses>>

StopSettled(s) ==
    /\ up /\ HS!Settles(s)
    /\ StopOnly
    /\ UNCHANGED <<turn, stp, scb, capq, ccBlocks, fBlocks, toolsRun, paused, pauses, faults>>

\* A tool call runs: Claude Code's count is reset, and the PostToolUse post
\* resets Intake's, unless the framework is down and the post is lost.
ToolRuns ==
    /\ turn = "working" /\ toolsRun < MaxToolCalls
    /\ toolsRun' = toolsRun + 1
    /\ ccBlocks' = 0
    /\ fBlocks' = IF up THEN 0 ELSE fBlocks
    /\ StopOnly
    /\ UNCHANGED <<turn, stp, scb, capq, sconn, srow, smarking, sout, swrong, paused, pauses,
                   faults>>

\* A person's prompt or a wake starts a new turn, and Claude Code's count
\* starts again at 0 (measured on 2.1.322, F-171).
NewTurn ==
    /\ turn = "ended" /\ \E s \in Stops : stp[s] = "none"
    /\ turn' = "working"
    /\ ccBlocks' = 0
    /\ StopOnly
    /\ UNCHANGED <<stp, scb, capq, sconn, srow, smarking, sout, swrong, fBlocks, toolsRun, paused,
                   pauses, faults>>

\* The app or the operator pauses the session's agent or project, or lifts
\* the pause: the Stops held while it was on are asked of the callback.
PauseSet ==
    /\ up /\ ~paused /\ pauses < MaxPauses
    /\ paused' = TRUE /\ pauses' = pauses + 1
    /\ StopOnly
    /\ UNCHANGED <<turn, stp, scb, capq, sconn, srow, smarking, sout, swrong, ccBlocks, fBlocks,
                   toolsRun, faults>>

PauseLifted ==
    /\ up /\ paused
    /\ paused' = FALSE
    /\ scb' = [s \in Stops |-> IF scb[s] = "paused" THEN "asked" ELSE scb[s]]
    /\ StopOnly
    /\ UNCHANGED <<turn, stp, capq, sconn, srow, smarking, sout, swrong, ccBlocks, fBlocks,
                   toolsRun, pauses, faults>>

-----------------------------------------------------------------------------
Next ==
    \/ FrameworkDies \/ FrameworkStarts
    \/ \E c \in Calls :
         \/ ToolPosted(c) \/ ToolHeld(c) \/ CallbackAnswers(c) \/ DecisionTaken(c)
         \/ DecisionHanded(c) \/ ToolMarked(c) \/ PassHanded(c) \/ ToolDeadline(c)
         \/ ToolSettled(c)
    \/ \E e \in Events : Posted(e) \/ Stored(e) \/ Acked(e) \/ AckedFirst(e) \/ StoredLate(e)
    \/ \E p \in Dialogs :
         \/ DialogOpens(p) \/ PersonAnswers(p) \/ HookTimesOut(p) \/ HoldStored(p)
         \/ AnswerWritten(p) \/ AnswerMarked(p) \/ HoldExpires(p) \/ HoldSettled(p)
         \/ AnswerTyped(p)
         \/ \E h \in Dialogs : AnswerAsked(p, h)
    \/ \E w \in Waiters :
         \/ WaiterStarts(w) \/ WaiterHeld(w) \/ TurnedAway(w) \/ ProgramDies(w)
         \/ HeartbeatFails(w) \/ TextWritten(w) \/ TextMarked(w) \/ WaiterExpires(w)
         \/ WaiterSettles(w)
    \/ \E t \in Texts : TextAsked(t)
    \/ WaiterReplaced
    \/ \E w \in Waiters : Superseded(w)
    \/ \E s \in Stops :
         \/ StopFires(s) \/ StopHeld(s) \/ StopCallback(s) \/ StopTaken(s) \/ CapAnswered(s)
         \/ StopHanded(s) \/ StopMarked(s) \/ StopDeadline(s) \/ StopSettled(s)
    \/ ToolRuns \/ NewTurn \/ PauseSet \/ PauseLifted

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A e \in Events : WF_vars(Stored(e)) /\ WF_vars(Acked(e)) /\ WF_vars(AckedFirst(e))
                         /\ WF_vars(StoredLate(e))
    /\ \A p \in Dialogs : WF_vars(HookTimesOut(p)) /\ WF_vars(HoldStored(p))
                          /\ WF_vars(AnswerWritten(p)) /\ WF_vars(AnswerMarked(p))
                          /\ WF_vars(HoldExpires(p)) /\ WF_vars(HoldSettled(p))
    /\ \A c \in Calls : WF_vars(ToolHeld(c)) /\ WF_vars(DecisionHanded(c))
                        /\ WF_vars(ToolMarked(c)) /\ WF_vars(ToolDeadline(c))
                        /\ WF_vars(ToolSettled(c))
    /\ \A w \in Waiters : WF_vars(WaiterHeld(w)) /\ WF_vars(TurnedAway(w))
                          /\ WF_vars(HeartbeatFails(w)) /\ WF_vars(TextWritten(w))
                          /\ WF_vars(TextMarked(w)) /\ WF_vars(WaiterExpires(w))
                          /\ WF_vars(WaiterSettles(w)) /\ WF_vars(Superseded(w))
    /\ WF_vars(WaiterReplaced)
    /\ \A s \in Stops : WF_vars(StopHeld(s)) /\ WF_vars(StopTaken(s)) /\ WF_vars(StopHanded(s))
                        /\ WF_vars(StopMarked(s)) /\ WF_vars(StopDeadline(s))
                        /\ WF_vars(StopSettled(s))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ up \in BOOLEAN /\ restarts \in 0..MaxRestarts
    /\ \A e \in Events : posts[e] \in 0..MaxPosts /\ inflight[e] \in Nat /\ rows[e] \in Nat
    /\ dialog \in [Dialogs -> {"none", "open", "closed"}]
    /\ outcome \in [Dialogs -> {"none", "hook", "person", "keys"}]
    /\ hook \in [Dialogs -> {"none", "waiting", "answered", "released", "failed", "timedout"}]
    /\ HP!TypeOK /\ typed \subseteq Dialogs /\ heard \in [Dialogs -> BOOLEAN]
    /\ \A p \in Dialogs : conn[p] => up
    /\ \A p \in Dialogs : (outcome[p] = "none") = (dialog[p] # "closed")
    /\ call \in [Calls -> {"none", "waiting", "decided", "passed", "failed"}]
    /\ cb \in [Calls -> {"none", "asked", "decision", "pass", "used"}]
    /\ HT!TypeOK
    /\ \A c \in Calls : tconn[c] => up
    /\ prog \in [Waiters -> {"none", "waiting", "woke", "idle", "failed", "gone"}]
    /\ HW!TypeOK /\ cur \in 0..MaxWaiters
    /\ gave \in [Waiters -> 0..MaxTexts]
    /\ mail \in [Texts -> {"due", "sending", "sent", "unknown"}]
    /\ read \in [Texts -> Nat]
    /\ \A w \in Waiters : wconn[w] => up
    /\ superseded \subseteq Waiters
    /\ turn \in {"working", "stopping", "ended"}
    /\ stp \in [Stops -> {"none", "waiting", "blocked", "passed", "failed"}]
    /\ scb \in [Stops -> {"none", "asked", "paused", "block", "pass", "used"}]
    /\ capq \subseteq Stops /\ HS!TypeOK
    /\ ccBlocks \in 0..Cap /\ fBlocks \in Nat /\ toolsRun \in 0..MaxToolCalls
    /\ paused \in BOOLEAN /\ pauses \in 0..MaxPauses
    /\ \A s \in Stops : sconn[s] => up

\* A 200 goes back only for an event whose row is written.
AckedIsStored == \A e \in Events : acked[e] > 0 => rows[e] > 0

\* An event posted twice has one row.
StoredOnce == \A e \in Events : rows[e] <= 1

\* At most one answer goes to one hook.
SentAtMostOnce == HP!OneResponse

\* An answer reaches only the dialog it names.
OnlyNamedDialog == HP!OnlyNamed

\* A row says answered only when a hook still waiting read the answer.
AnsweredWasHeard == \A p \in Dialogs : hold[p] = "answered" => heard[p]

\* A dialog is answered by its hook or by a person, never by typed keys.
NeverTyped == typed = {}

\* Every request of an event ends.
RequestsEnd == \A e \in Events : inflight[e] + toAck[e] + toStore[e] > 0
                                   ~> inflight[e] + toAck[e] + toStore[e] = 0

\* Every hold ends: answered, expired, or settled after a restart; and its
\* request closes.
HoldSettles == HP!RequestsEnd

\* Intake hands one response for each tool call's request.
OneResponse == HT!OneResponse

\* A decision goes out only before the deadline's empty body: a late one is dropped.
LateDropped == HT!LateDropped

\* A decision Claude Code read has its row.
DecidedHasRow == \A c \in Calls : call[c] = "decided" => trow[c] \in {"deciding", "answered", "unknown"}

\* Every held tool call's request ends, with or without a decision, and its
\* row settles.
ToolRequestsEnd == HT!RequestsEnd

\* A waiter's request gets one response: its text, or an empty one.
WaiterOneResponse == HW!OneResponse

\* Text is read at most once: no text deliver was told unknown is handed again.
ReadOnce == \A t \in Texts : read[t] <= 1

\* A waiter's request ends empty only at its deadline, or once a newer one
\* is live: a newer waiter is never turned away for an older one.
EmptyOnlyAtDeadline ==
    \A w \in Waiters : wout[w] = <<"empty">> => wrow[w] = "expired" \/ w \in superseded

\* Every waiter's request ends, and its hold settles.
WaiterRequestsEnd == HW!RequestsEnd

\* A program gone unseen is found: its request ends by a heartbeat, its
\* text or a restart, never left to the deadline.
DeathFound == \A w \in Waiters :
                (wconn[w] /\ prog[w] = "gone") ~> (~wconn[w] /\ wrow[w] # "expired")

\* A waiter held is the session's, unless its hold ends first.
WaiterTaken == \A w \in Waiters :
                 (wconn[w] /\ wrow[w] = "held")
                   ~> (cur = w \/ wrow[w] \in {"answered", "expired", "passed", "lost", "unknown"})

\* Every Stop's request gets one response, a late decision dropped.
StopOneResponse == HS!OneResponse
StopLateDropped == HS!LateDropped

\* No block of the framework's is overridden: at the cap's last honored
\* block a person decides, and past it the hold passes.
NeverOverridden == "overridden" \notin faults

\* While a turn runs, Intake never counts fewer blocks in a row than Claude
\* Code. A turn that ended holds no Stop, and the next starts at 0.
CountKept == turn # "ended" => fBlocks >= ccBlocks

\* No Stop is decided by the app's callback while its agent or project is paused.
NotWhilePaused == "whilePaused" \notin faults

\* Every Stop's request ends, and its hold settles.
StopRequestsEnd == HS!RequestsEnd

=============================================================================
