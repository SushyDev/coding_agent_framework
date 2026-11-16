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
(* Defense in depth, with no Break: SentAtMostOnce. AnswerAsked takes only *)
(* a "held" row, and AnswerWritten closes the request; each alone keeps a  *)
(* second answer off one hook.                                             *)
(*                                                                         *)
(* PreToolUse (F-111): each tool call posts once and is held while the     *)
(* app's callback, in a process of its own, is asked. Intake hands the     *)
(* plug exactly one response: the callback's decision (its row written     *)
(* first) or an empty body, for a pass or at Intake's deadline, which     *)
(* comes before the hook's timeout. A decision after that is dropped. A   *)
(* restart cuts the request, and Claude Code goes on with no decision.    *)
(* Left abstract: which decision (allow, deny, ask are one "decision"),    *)
(* and a second post of one call, which the code answers from the row.    *)
(* Defense in depth, with no Break: DecidedHasRow, since Intake writes the *)
(* row in the step that hands the decision out.                            *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
    Events,       \* hook events other than PermissionRequest, by id
    MaxPosts,     \* posts of one event: more than one is a duplicate
    MaxDialogs,   \* permission dialogs of the session, 1..MaxDialogs, in order
    MaxCalls,     \* tool calls of the session, each with its PreToolUse hook
    MaxRestarts,  \* restarts of the framework
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "AckBeforeStore",   \* the request is answered before the event's row is written
    "NoDedupe",         \* a duplicate post writes a second row for one event
    "ByAgent",          \* an answer goes to the agent's newest held hook, not the one it names
    "NoOwnDeadline",    \* the framework keeps a hold past Claude Code's timeout
    "NoExpiry",         \* the framework never releases a hold no one answers
    "TrustAnswering",   \* after a restart, a row still "answering" is taken as answered
    "TypeWhenNoHold",   \* a dialog whose hold is gone is answered by typed keys
    "TwoResponses",     \* the tool deadline fires after the decision was handed out
    "LateSent"          \* a decision after the tool deadline is still handed out
}

ASSUME Break \in Breaks
ASSUME MaxPosts \in Nat /\ MaxDialogs \in Nat /\ MaxCalls \in Nat /\ MaxRestarts \in Nat

Dialogs == 1..MaxDialogs
Calls == 1..MaxCalls

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
    conn,      \* in memory: p -> the framework holds p's request open
    hold,      \* table: p -> "none", "held", "answering", "answered", "expired",
               \*            "lost", "unknown"
    written,   \* in memory: holds whose answer is written, row not yet marked
    sent,      \* p -> answers written on p's request
    heard,     \* p -> the answer was read by a hook still waiting for it
    typed,     \* dialogs answered by typed keys
    wrong,     \* answers that took another dialog's hold: [meant, got]
    call,      \* c -> "none", "waiting", "decided", "passed", "failed": what c's
               \*      PreToolUse hook read
    tconn,     \* in memory: c -> the plug holds c's request open
    entry,     \* in memory: c -> "none", "open" (asking), "done", "gone" (a restart)
    cb,        \* c -> "none", "asked", "decision", "pass", "used": the callback
    trow,      \* table: c -> its decision's row is written
    handed     \* c -> what Intake handed the plug for c: "decision" or "empty"

eventVars == <<posts, inflight, toStore, toAck, rows, acked>>
dialogVars == <<dialog, outcome, hook, conn, hold, written, sent, heard, typed, wrong>>
toolVars == <<call, tconn, entry, cb, trow, handed>>
vars == <<up, restarts, eventVars, dialogVars, toolVars>>

Settled == {"none", "answered", "expired", "lost", "unknown"}

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
    /\ sent = [p \in Dialogs |-> 0]
    /\ heard = [p \in Dialogs |-> FALSE]
    /\ typed = {}
    /\ wrong = {}
    /\ call = [c \in Calls |-> "none"]
    /\ tconn = [c \in Calls |-> FALSE]
    /\ entry = [c \in Calls |-> "none"]
    /\ cb = [c \in Calls |-> "none"]
    /\ trow = [c \in Calls |-> FALSE]
    /\ handed = [c \in Calls |-> <<>>]

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
    /\ conn' = [p \in Dialogs |-> FALSE]
    /\ hook' = [p \in Dialogs |-> IF conn[p] /\ hook[p] = "waiting" THEN "failed" ELSE hook[p]]
    /\ written' = {}
    /\ tconn' = [c \in Calls |-> FALSE]
    /\ call' = [c \in Calls |-> IF tconn[c] /\ call[c] = "waiting" THEN "failed" ELSE call[c]]
    /\ entry' = [c \in Calls |-> IF entry[c] = "open" THEN "gone" ELSE entry[c]]
    /\ UNCHANGED <<posts, rows, acked, dialog, outcome, hold, sent, heard, typed, wrong>>
    /\ UNCHANGED <<cb, trow, handed>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<restarts, eventVars, dialogVars>>

-----------------------------------------------------------------------------
(* Events: posted, stored, then acknowledged *)

\* Claude Code posts the event. With the framework down the post is refused
\* and the event is lost; a reader of the transcript or the process stands in.
Posted(e) ==
    /\ posts[e] < MaxPosts
    /\ posts' = [posts EXCEPT ![e] = @ + 1]
    /\ inflight' = IF up THEN [inflight EXCEPT ![e] = @ + 1] ELSE inflight
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, toStore, toAck, rows, acked, dialogVars>>

\* The row is written once per event: a second post of it finds the row.
Stored(e) ==
    /\ up /\ inflight[e] > 0 /\ Break # "AckBeforeStore"
    /\ inflight' = [inflight EXCEPT ![e] = @ - 1]
    /\ toAck' = [toAck EXCEPT ![e] = @ + 1]
    /\ rows' = [rows EXCEPT ![e] = IF @ = 0 \/ Break = "NoDedupe" THEN @ + 1 ELSE @]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, posts, toStore, acked, dialogVars>>

Acked(e) ==
    /\ up /\ toAck[e] > 0
    /\ toAck' = [toAck EXCEPT ![e] = @ - 1]
    /\ acked' = [acked EXCEPT ![e] = @ + 1]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, posts, inflight, toStore, rows, dialogVars>>

\* Under AckBeforeStore: the 200 goes out first, the row after.
AckedFirst(e) ==
    /\ up /\ inflight[e] > 0 /\ Break = "AckBeforeStore"
    /\ inflight' = [inflight EXCEPT ![e] = @ - 1]
    /\ toStore' = [toStore EXCEPT ![e] = @ + 1]
    /\ acked' = [acked EXCEPT ![e] = @ + 1]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, posts, toAck, rows, dialogVars>>

StoredLate(e) ==
    /\ up /\ toStore[e] > 0
    /\ toStore' = [toStore EXCEPT ![e] = @ - 1]
    /\ rows' = [rows EXCEPT ![e] = IF @ = 0 THEN @ + 1 ELSE @]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, posts, inflight, toAck, acked, dialogVars>>

-----------------------------------------------------------------------------
(* Claude Code: a dialog, its hook, a person, and the hook's timeout *)

\* The dialog shows and its hook posts at once. With the framework down
\* the post fails, and the dialog waits for a person.
DialogOpens(p) ==
    /\ dialog[p] = "none" /\ \A q \in Dialogs : q < p => dialog[q] = "closed"
    /\ dialog' = [dialog EXCEPT ![p] = "open"]
    /\ hook' = [hook EXCEPT ![p] = IF up THEN "waiting" ELSE "failed"]
    /\ conn' = [conn EXCEPT ![p] = up]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, eventVars, outcome, hold, written, sent, heard, typed, wrong>>

\* A person answers on the screen or by Remote Control. The hook goes on
\* waiting; whatever it reads later is dropped.
PersonAnswers(p) ==
    /\ dialog[p] = "open"
    /\ dialog' = [dialog EXCEPT ![p] = "closed"]
    /\ outcome' = [outcome EXCEPT ![p] = "person"]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, eventVars, hook, conn, hold, written, sent, heard, typed, wrong>>

\* Claude Code stops waiting. The framework's deadline comes first, so this
\* happens only to a hook the framework has let go of, which is none.
HookTimesOut(p) ==
    /\ hook[p] = "waiting"
    /\ hold[p] \notin {"none", "held", "answering"} \/ Break \in {"NoOwnDeadline", "NoExpiry"}
    /\ hook' = [hook EXCEPT ![p] = "timedout"]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, eventVars, dialog, outcome, conn, hold, written, sent, heard,
                   typed, wrong>>

-----------------------------------------------------------------------------
(* Intake: a held hook, its answer, its deadline, and a restart *)

HoldStored(p) ==
    /\ up /\ conn[p] /\ hold[p] = "none"
    /\ hold' = [hold EXCEPT ![p] = "held"]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, eventVars, dialog, outcome, hook, conn, written, sent, heard,
                   typed, wrong>>

\* An answer meant for dialog m, which its sender saw, takes hold h: the
\* one it names. Under ByAgent it takes whichever hold is held.
AnswerAsked(m, h) ==
    /\ up /\ dialog[m] # "none" /\ hold[h] = "held"
    /\ h = m \/ (Break = "ByAgent" /\ hold[m] # "held")
    /\ hold' = [hold EXCEPT ![h] = "answering"]
    /\ wrong' = IF h # m THEN wrong \cup {[meant |-> m, got |-> h]} ELSE wrong
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, eventVars, dialog, outcome, hook, conn, written, sent, heard,
                   typed>>

\* The decision is the response to the hook's request, which then closes.
\* A hook still waiting reads it; a dialog still open closes by it.
AnswerWritten(p) ==
    /\ up /\ hold[p] = "answering" /\ conn[p] /\ p \notin written
    /\ written' = written \cup {p}
    /\ conn' = [conn EXCEPT ![p] = FALSE]
    /\ sent' = [sent EXCEPT ![p] = @ + 1]
    /\ heard' = [heard EXCEPT ![p] = (hook[p] = "waiting")]
    /\ hook' = [hook EXCEPT ![p] = IF @ = "waiting" THEN "answered" ELSE @]
    /\ IF hook[p] = "waiting" /\ dialog[p] = "open"
         THEN /\ dialog' = [dialog EXCEPT ![p] = "closed"]
              /\ outcome' = [outcome EXCEPT ![p] = "hook"]
         ELSE UNCHANGED <<dialog, outcome>>
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, eventVars, hold, typed, wrong>>

AnswerMarked(p) ==
    /\ up /\ p \in written
    /\ written' = written \ {p}
    /\ hold' = [hold EXCEPT ![p] = "answered"]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, eventVars, dialog, outcome, hook, conn, sent, heard, typed,
                   wrong>>

\* The framework's own deadline: it answers "no decision", and the dialog
\* waits for a person.
HoldExpires(p) ==
    /\ up /\ hold[p] = "held" /\ conn[p] /\ Break # "NoExpiry"
    /\ hold' = [hold EXCEPT ![p] = "expired"]
    /\ conn' = [conn EXCEPT ![p] = FALSE]
    /\ hook' = [hook EXCEPT ![p] = IF @ = "waiting" THEN "released" ELSE @]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, eventVars, dialog, outcome, written, sent, heard, typed, wrong>>

\* After a restart a request is gone with its process: a held row is lost,
\* and one answering is unknown, since the answer may not have gone out.
HoldSettled(p) ==
    /\ up /\ hold[p] \in {"held", "answering"} /\ ~conn[p] /\ p \notin written
    /\ hold' = [hold EXCEPT ![p] = IF @ = "held" THEN "lost"
                                   ELSE IF Break = "TrustAnswering" THEN "answered"
                                   ELSE "unknown"]
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, eventVars, dialog, outcome, hook, conn, written, sent, heard,
                   typed, wrong>>

\* Under TypeWhenNoHold: with no hold to answer through, keys are typed.
AnswerTyped(p) ==
    /\ Break = "TypeWhenNoHold" /\ up /\ dialog[p] = "open" /\ hold[p] # "held"
    /\ dialog' = [dialog EXCEPT ![p] = "closed"]
    /\ outcome' = [outcome EXCEPT ![p] = "keys"]
    /\ typed' = typed \cup {p}
    /\ UNCHANGED toolVars
    /\ UNCHANGED <<up, restarts, eventVars, hook, conn, hold, written, sent, heard, wrong>>

-----------------------------------------------------------------------------
(* PreToolUse: one response per request, the callback's decision or none *)

\* Claude Code posts c's hook and waits. With the framework down the post
\* fails, and the tool call goes on with no decision (onFailure continue).
ToolPosted(c) ==
    /\ call[c] = "none"
    /\ call' = [call EXCEPT ![c] = IF up THEN "waiting" ELSE "failed"]
    /\ tconn' = [tconn EXCEPT ![c] = up]
    /\ UNCHANGED <<up, restarts, eventVars, dialogVars, entry, cb, trow, handed>>

\* Intake keeps an entry for the request, starts its deadline, and asks the
\* callback in a process of its own.
ToolHeld(c) ==
    /\ up /\ tconn[c] /\ entry[c] = "none"
    /\ entry' = [entry EXCEPT ![c] = "open"]
    /\ cb' = [cb EXCEPT ![c] = "asked"]
    /\ UNCHANGED <<up, restarts, eventVars, dialogVars, call, tconn, trow, handed>>

\* The callback answers whenever it does, or never: its process outlives
\* a deadline, and its answer may come after a restart.
CallbackAnswers(c) ==
    /\ cb[c] = "asked"
    /\ \E a \in {"decision", "pass"} : cb' = [cb EXCEPT ![c] = a]
    /\ UNCHANGED <<up, restarts, eventVars, dialogVars, call, tconn, entry, trow, handed>>

\* A decision on an open entry: its row, then the decision handed out, in
\* one step of Intake. Under LateSent a decision after the deadline is too.
DecisionHanded(c) ==
    /\ up /\ cb[c] = "decision"
    /\ entry[c] = "open" \/ (Break = "LateSent" /\ entry[c] = "done")
    /\ cb' = [cb EXCEPT ![c] = "used"]
    /\ trow' = [trow EXCEPT ![c] = TRUE]
    /\ entry' = [entry EXCEPT ![c] = "done"]
    /\ handed' = [handed EXCEPT ![c] = Append(@, "decision")]
    /\ UNCHANGED <<up, restarts, eventVars, dialogVars, call, tconn>>

\* A pass: an empty body, and no row.
PassHanded(c) ==
    /\ up /\ cb[c] = "pass" /\ entry[c] = "open"
    /\ cb' = [cb EXCEPT ![c] = "used"]
    /\ entry' = [entry EXCEPT ![c] = "done"]
    /\ handed' = [handed EXCEPT ![c] = Append(@, "empty")]
    /\ UNCHANGED <<up, restarts, eventVars, dialogVars, call, tconn, trow>>

\* Intake's deadline: an empty body, and no row. Under TwoResponses it fires
\* on an entry already answered.
ToolDeadline(c) ==
    /\ up
    /\ entry[c] = "open" \/ (Break = "TwoResponses" /\ entry[c] = "done" /\ Len(handed[c]) = 1)
    /\ entry' = [entry EXCEPT ![c] = "done"]
    /\ handed' = [handed EXCEPT ![c] = Append(@, "empty")]
    /\ UNCHANGED <<up, restarts, eventVars, dialogVars, call, tconn, cb, trow>>

\* The plug writes what it was handed first as the response; the request
\* closes, and Claude Code reads it.
ToolAnswered(c) ==
    /\ up /\ tconn[c] /\ handed[c] # <<>>
    /\ tconn' = [tconn EXCEPT ![c] = FALSE]
    /\ call' = [call EXCEPT ![c] = IF Head(handed[c]) = "decision" THEN "decided" ELSE "passed"]
    /\ UNCHANGED <<up, restarts, eventVars, dialogVars, entry, cb, trow, handed>>

-----------------------------------------------------------------------------
Next ==
    \/ FrameworkDies \/ FrameworkStarts
    \/ \E c \in Calls :
         \/ ToolPosted(c) \/ ToolHeld(c) \/ CallbackAnswers(c) \/ DecisionHanded(c)
         \/ PassHanded(c) \/ ToolDeadline(c) \/ ToolAnswered(c)
    \/ \E e \in Events : Posted(e) \/ Stored(e) \/ Acked(e) \/ AckedFirst(e) \/ StoredLate(e)
    \/ \E p \in Dialogs :
         \/ DialogOpens(p) \/ PersonAnswers(p) \/ HookTimesOut(p) \/ HoldStored(p)
         \/ AnswerWritten(p) \/ AnswerMarked(p) \/ HoldExpires(p) \/ HoldSettled(p)
         \/ AnswerTyped(p)
         \/ \E h \in Dialogs : AnswerAsked(p, h)

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A e \in Events : WF_vars(Stored(e)) /\ WF_vars(Acked(e)) /\ WF_vars(AckedFirst(e))
                         /\ WF_vars(StoredLate(e))
    /\ \A p \in Dialogs : WF_vars(HookTimesOut(p)) /\ WF_vars(HoldStored(p))
                          /\ WF_vars(AnswerWritten(p)) /\ WF_vars(AnswerMarked(p))
                          /\ WF_vars(HoldExpires(p)) /\ WF_vars(HoldSettled(p))
    /\ \A c \in Calls : WF_vars(ToolHeld(c)) /\ WF_vars(ToolDeadline(c))
                        /\ WF_vars(ToolAnswered(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ up \in BOOLEAN /\ restarts \in 0..MaxRestarts
    /\ \A e \in Events : posts[e] \in 0..MaxPosts /\ inflight[e] \in Nat /\ rows[e] \in Nat
    /\ dialog \in [Dialogs -> {"none", "open", "closed"}]
    /\ outcome \in [Dialogs -> {"none", "hook", "person", "keys"}]
    /\ hook \in [Dialogs -> {"none", "waiting", "answered", "released", "failed", "timedout"}]
    /\ hold \in [Dialogs -> {"none", "held", "answering", "answered", "expired", "lost",
                             "unknown"}]
    /\ conn \in [Dialogs -> BOOLEAN] /\ written \subseteq Dialogs /\ typed \subseteq Dialogs
    /\ \A p \in Dialogs : conn[p] => up
    /\ \A p \in Dialogs : (outcome[p] = "none") = (dialog[p] # "closed")
    /\ call \in [Calls -> {"none", "waiting", "decided", "passed", "failed"}]
    /\ tconn \in [Calls -> BOOLEAN] /\ trow \in [Calls -> BOOLEAN]
    /\ entry \in [Calls -> {"none", "open", "done", "gone"}]
    /\ cb \in [Calls -> {"none", "asked", "decision", "pass", "used"}]
    /\ \A c \in Calls : tconn[c] => up

\* A 200 goes back only for an event whose row is written.
AckedIsStored == \A e \in Events : acked[e] > 0 => rows[e] > 0

\* An event posted twice has one row.
StoredOnce == \A e \in Events : rows[e] <= 1

\* At most one answer goes to one hook.
SentAtMostOnce == \A p \in Dialogs : sent[p] <= 1

\* An answer reaches only the dialog it names.
OnlyNamedDialog == wrong = {}

\* A row says answered only when a hook still waiting read the answer.
AnsweredWasHeard == \A p \in Dialogs : hold[p] = "answered" => heard[p]

\* A dialog is answered by its hook or by a person, never by typed keys.
NeverTyped == typed = {}

\* Every request of an event ends.
RequestsEnd == \A e \in Events : inflight[e] + toAck[e] + toStore[e] > 0
                                   ~> inflight[e] + toAck[e] + toStore[e] = 0

\* Every hold ends: answered, expired, or settled after a restart.
HoldSettles == \A p \in Dialogs : hold[p] \in {"held", "answering"} ~> hold[p] \in Settled

\* Intake hands one response for each tool call's request.
OneResponse == \A c \in Calls : Len(handed[c]) <= 1

\* A decision goes out only before the deadline's empty body: a late one is dropped.
LateDropped == \A c \in Calls : \A i \in 1..Len(handed[c]) : handed[c][i] = "decision" => i = 1

\* A decision Claude Code read has its row.
DecidedHasRow == \A c \in Calls : call[c] = "decided" => trow[c]

\* Every held tool call's request ends, with or without a decision.
ToolRequestsEnd == \A c \in Calls : tconn[c] ~> ~tconn[c]

=============================================================================
