-------------------------------- MODULE Dialog --------------------------------
(***************************************************************************)
(* A startup dialog (F-140): an interactive start that stops before its    *)
(* first turn on Claude Code's own dialogs, the folder trust dialog and    *)
(* the external imports dialog, shown in that order. Neither sends a hook  *)
(* event and no session file exists while one is shown, so the start reads *)
(* its pane: the agent row says `dialog`, with the dialog's kind, and      *)
(* waits on a person; the start's deadline does not end it, and its lease  *)
(* stays held. The answer comes from outside, by the option's label: a     *)
(* person's (the app's view, the operator's MCP), or the app's callback    *)
(* for a kind it chose to answer; nothing answers on its own. The answer   *)
(* is marked on the row before its press goes, and the press is checked:   *)
(* the pane must still show that dialog, or nothing goes. The press runs  *)
(* in a task whose answer comes back as a message (F-144), so Sessions     *)
(* answers other calls meanwhile, the mark `pressing`. A press is sent at  *)
(* most once per dialog: one whose outcome is unknown is never sent again, *)
(* and one a restart cut (`cut`) only once more, after a person who saw    *)
(* the pane still show that dialog cleared it (`cleared`). A person may    *)
(* stop a row on a dialog, by SIGTERM to its held program's record; it is  *)
(* then stopped, as "No, exit" leaves it. Past the dialogs the program     *)
(* writes its session file and the start goes on as before. Each answer is *)
(* a row in Acts (F-144), claimed on the dialog's mark; the marks here are *)
(* that claim's states, so it is not modeled apart.                        *)
(*                                                                         *)
(* Models Sessions' read of a starting session's pane and its answer       *)
(* (`Sessions.answer_dialog/5`), a person's clear (`clear_dialog/4`) and   *)
(* stop (`stop/3` of a row on a dialog), the Inlet's checked press         *)
(* (`Inlet.choose/5`), the callback the app may give (`dialog:`), and the  *)
(* status lists of `Sessions.Table` the Scheduler's lease reads.           *)
(*                                                                         *)
(* Left abstract: time (a deadline is a step); what a label says beyond    *)
(* "yes" and "no" (the trust dialog's "no" exits; the imports dialog's     *)
(* goes on with imports off); the session file's contents; other           *)
(* sessions. A person at the viewer may answer the dialog shown at any     *)
(* step, as a person can. The program draws its first screen before the    *)
(* start's deadline: a pane still blank then is a start that failed, as    *)
(* before this spec, and is left out.                                      *)
(*                                                                         *)
(* Fairness: Sessions' steps (its reads, the press of a marked answer,     *)
(* the confirm, the settle) and Recoveries' end of an orphan happen while  *)
(* possible; a person, the app's view and restarts happen or not.          *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Dialog_<value>.cfg that TLC must fail.                      *)
(*                                                                         *)
(* Sessions' contract for a startup dialog, and today the Prompts box's    *)
(* for the kind `startup` (F-163): a press only when asked, only on the    *)
(* dialog named, at most once and once more only after a person's clear    *)
(* (OnlyAsked, OnNamed, AtMostOnce); a row on a dialog never ended as an   *)
(* orphan; its lease held while its process lives (LeaseWhileLive); the    *)
(* start goes on past the dialogs (GoesOn). Boxes.tla's ShowDialog,        *)
(* Answer, Press, Told, SettlePrompt and Clear are this spec's read, its   *)
(* mark (`pressing` is Prompts' answering), its checked press, its         *)
(* message back and a person's clear; its `keys` in flight are the         *)
(* press's outcome left unknown here. Boxes.tla's OneAnswer counts         *)
(* presses that land, so AtMostOnce (presses sent, the cut one included)   *)
(* implies it. KeptAcrossRestart holds here because the mark is a durable  *)
(* field of the row; Prompt.tla (B1) will own it as a row of Prompts. Its  *)
(* LeaseWhileLive is Boxes.tla's for the dialog statuses.                  *)
(*                                                                         *)
(* Restarts (F-164): the whole one (Restart, then Recover) and the agent's *)
(* own process's (RestartAgent, B4's), both bounded by MaxRestarts. With   *)
(* one agent here they lose the same memory, since the press's task is     *)
(* the agent process's; the agent's own restart differs in what runs on:   *)
(* Prompts, whose answer on its way may reach the new process, and the     *)
(* Scheduler and Recoveries, which never stop.                             *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Dialogs,      \* the kinds the program shows, in order, e.g. <<"trust", "imports">>
    Auto,         \* the kinds the app's callback answers ("yes"); {} by default: it asks
    MaxRestarts,  \* restarts of Sessions and of the agent's own process
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "AutoAnswer",    \* Sessions answers the trust dialog by itself, as F-137 did
    "Unchecked",     \* the press goes without the pane read to show the dialog it names
    "RetryUnknown",  \* an answer whose press is unknown, or cut by a restart, is pressed again
    "DeadlineEnds",  \* the start's deadline ends a row whose pane shows a dialog, as an orphan
    "DialogFree",    \* a row on a dialog counts as free, so its lease is released
    "NoRead",        \* the pane is read only while the start's call waits, not after an answer
    "ClearTwice"     \* a press a restart cut may be cleared again after its second try
}

ASSUME Break \in Breaks

\* The order 2.1.322 shows them in (F-140's captures), for the configurations.
TrustThenImports == <<"trust", "imports">>

N == Len(Dialogs)
Kinds == {Dialogs[i] : i \in 1..N}
Labels == {"yes", "no"}
Statuses == {"starting", "dialog", "running", "orphan", "stopped"}
Marks == {"none", "pressing", "sent", "unknown", "cut", "cleared"}

ASSUME Auto \subseteq Kinds

VARIABLES
    at,        \* the program: 0 nothing drawn, i a dialog Dialogs[i], N+1 past them (its file written)
    live,      \* the program's process lives
    status,    \* the agent row's status
    shown,     \* the agent row's dialog: a kind, or "none"
    mark,      \* the agent row: k -> its answer's mark
    up,        \* Sessions runs
    restarts,
    call,      \* a person's answer on its way to Sessions: {} or {[kind, label]}
    pending,   \* in memory: the answers marked pressing whose task has not pressed yet
    results,   \* in memory: the tasks' answers not yet taken: [kind, mark]
    cleared,   \* the agent row: the kinds whose cut press a person cleared, once
    lease,     \* the Scheduler's lease of the start: "held" or "released"
    sent,      \* ghost: k -> the presses sent for k
    asked,     \* ghost: the kinds a person or the app's callback asked to answer
    wrong,     \* ghost: kinds whose press landed on another screen
    unasked,   \* ghost: kinds pressed that no one asked to answer
    killedOn   \* ghost: what the screen showed when Recoveries ended the process

vars == <<at, live, status, shown, mark, up, restarts, call, pending, results, cleared, lease,
          sent, asked, wrong, unasked, killedOn>>

OnDialog == at \in 1..N
Shows(k) == OnDialog /\ Dialogs[at] = k

\* What a press with `label` does to the screen it lands on: the trust dialog's "no" exits.
Lands(label) ==
    IF Dialogs[at] = "trust" /\ label = "no"
    THEN live' = FALSE /\ at' = at
    ELSE at' = at + 1 /\ live' = live

-----------------------------------------------------------------------------
(* The program *)

Draw ==
    /\ live /\ at = 0
    /\ at' = 1
    /\ UNCHANGED <<live, status, shown, mark, up, restarts, call, pending, results, cleared, lease, sent,
                   asked, wrong, unasked, killedOn>>

\* A person at the viewer answers the dialog shown, by its own keys.
ViewerPress(label) ==
    /\ live /\ OnDialog
    /\ Lands(label)
    /\ UNCHANGED <<status, shown, mark, up, restarts, call, pending, results, cleared, lease, sent, asked,
                   wrong, unasked, killedOn>>

-----------------------------------------------------------------------------
(* Sessions *)

\* The pane read while the row has no session file: a dialog shown is the row's. Under NoRead
\* only the start's call reads it.
Read ==
    /\ up /\ live /\ OnDialog
    /\ status \in {"starting", "dialog"}
    /\ Break = "NoRead" => status = "starting"
    /\ shown # Dialogs[at]
    /\ status' = "dialog"
    /\ shown' = Dialogs[at]
    /\ UNCHANGED <<at, live, mark, up, restarts, call, pending, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* The app's callback, at a dialog it reads: an answer for a kind it chose, marked first.
\* Under AutoAnswer Sessions answers the trust dialog with no one asking.
Callback ==
    /\ up /\ status = "dialog" /\ shown # "none" /\ mark[shown] = "none"
    /\ shown \in Auto \/ (Break = "AutoAnswer" /\ shown = "trust")
    /\ mark' = [mark EXCEPT ![shown] = "pressing"]
    /\ pending' = pending \cup {[kind |-> shown, label |-> "yes"]}
    /\ asked' = IF shown \in Auto THEN asked \cup {shown} ELSE asked
    /\ UNCHANGED <<at, live, status, shown, up, restarts, call, results, cleared, lease, sent,
                   wrong, unasked, killedOn>>

\* A person reads the row's dialog in a view and answers it by a label.
Answer(label) ==
    /\ status = "dialog" /\ shown # "none" /\ call = {}
    /\ call' = {[kind |-> shown, label |-> label]}
    /\ asked' = asked \cup {shown}
    /\ UNCHANGED <<at, live, status, shown, mark, up, restarts, pending, results, cleared, lease, sent, wrong,
                   unasked, killedOn>>

\* Sessions takes the answer: marked pressing when its kind has no mark, or a person cleared
\* its cut press, else refused (an answer already sent, or unknown, is never sent twice). The
\* press goes to a task. Under RetryUnknown an unknown one is taken again.
Take(c) ==
    /\ up /\ c \in call
    /\ call' = {}
    /\ IF \/ mark[c.kind] \in {"none", "cleared"}
          \/ Break = "RetryUnknown" /\ mark[c.kind] = "unknown"
       THEN /\ mark' = [mark EXCEPT ![c.kind] = "pressing"]
            /\ pending' = pending \cup {c}
       ELSE UNCHANGED <<mark, pending>>
    /\ UNCHANGED <<at, live, status, shown, up, restarts, results, cleared, lease, sent, asked,
                   wrong, unasked, killedOn>>

\* The task's checked press, in one step: the pane must show the dialog the answer names, or
\* nothing goes. A press that goes lands on what the pane shows; its outcome is known (sent)
\* or not (unknown), and an unknown one may not have landed. Its answer comes back as a
\* message; until Sessions takes it the mark stays pressing. Under Unchecked the press goes
\* whatever the pane shows.
Press(p) ==
    /\ up /\ p \in pending
    /\ pending' = pending \ {p}
    /\ IF live /\ (Shows(p.kind) \/ (Break = "Unchecked" /\ OnDialog))
       THEN /\ sent' = [sent EXCEPT ![p.kind] = @ + 1]
            /\ wrong' = IF Dialogs[at] # p.kind THEN wrong \cup {p.kind} ELSE wrong
            /\ unasked' = IF p.kind \notin asked THEN unasked \cup {p.kind} ELSE unasked
            /\ \/ Lands(p.label) /\ results' = results \cup {[kind |-> p.kind, mark |-> "sent"]}
               \/ Lands(p.label) /\ results' = results \cup {[kind |-> p.kind, mark |-> "unknown"]}
               \/ UNCHANGED <<at, live>>
                  /\ results' = results \cup {[kind |-> p.kind, mark |-> "unknown"]}
       ELSE /\ results' = results \cup {[kind |-> p.kind, mark |-> "none"]}
            /\ UNCHANGED <<at, live, sent, wrong, unasked>>
    /\ UNCHANGED <<status, shown, mark, up, restarts, call, cleared, lease, asked, killedOn>>

\* Sessions takes the task's answer: sent or unknown stays marked; a refusal, which pressed
\* nothing, takes the mark away.
Pressed(r) ==
    /\ up /\ r \in results
    /\ results' = results \ {r}
    /\ mark' = [mark EXCEPT ![r.kind] = r.mark]
    /\ UNCHANGED <<at, live, status, shown, up, restarts, call, pending, cleared, lease, sent,
                   asked, wrong, unasked, killedOn>>

\* A person who saw the pane still show the dialog, its first option selected, clears a press
\* a restart cut, once: it may be answered once more, and that press is checked as any.
\* Under ClearTwice a press cut after its clear is cut again, so it may be cleared again.
Clear(k) ==
    /\ up /\ live /\ status = "dialog" /\ Shows(k) /\ mark[k] = "cut"
    /\ mark' = [mark EXCEPT ![k] = "cleared"]
    /\ cleared' = cleared \cup {k}
    /\ UNCHANGED <<at, live, status, shown, up, restarts, call, pending, results, lease, sent,
                   asked, wrong, unasked, killedOn>>

\* A person stops a row on a dialog: SIGTERM to its held program's record. The process exits,
\* or outlives the stop's deadline and the row waits as before.
Stop ==
    /\ up /\ live /\ status = "dialog"
    /\ live' \in BOOLEAN
    /\ UNCHANGED <<at, status, shown, mark, up, restarts, call, pending, results, cleared, lease,
                   sent, asked, wrong, unasked, killedOn>>

\* Past the dialogs the session file names the process: the start goes on, as before.
Confirm ==
    /\ up /\ live /\ at = N + 1
    /\ status \in {"starting", "dialog"}
    /\ status' = "running" /\ shown' = "none"
    /\ UNCHANGED <<at, live, mark, up, restarts, call, pending, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* The start's deadline, with no session file: the pane is read in the same step, and a
\* dialog makes the row wait on a person; anything else is an orphan, for Recoveries. Under
\* DeadlineEnds the pane is not read.
Deadline ==
    /\ up /\ live /\ status = "starting" /\ at \in 1..N
    /\ IF OnDialog /\ Break # "DeadlineEnds"
       THEN status' = "dialog" /\ shown' = Dialogs[at]
       ELSE status' = "orphan" /\ shown' = shown
    /\ UNCHANGED <<at, live, mark, up, restarts, call, pending, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* Recoveries ends an orphan's process.
Kill ==
    /\ live /\ status = "orphan"
    /\ live' = FALSE
    /\ killedOn' = killedOn \cup {IF OnDialog THEN Dialogs[at] ELSE "screen"}
    /\ UNCHANGED <<at, status, shown, mark, up, restarts, call, pending, results, cleared, lease, sent, asked,
                   wrong, unasked>>

\* The process gone (its socket dead): stopped, so its name is free.
Settle ==
    /\ up /\ ~live /\ status # "stopped"
    /\ status' = "stopped" /\ shown' = "none"
    /\ UNCHANGED <<at, live, mark, up, restarts, call, pending, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* The Scheduler releases the lease once the row's owner says the work ended: its row free.
\* Under DialogFree a row on a dialog counts as free.
Release ==
    /\ lease = "held"
    /\ status = "stopped" \/ (Break = "DialogFree" /\ status = "dialog")
    /\ lease' = "released"
    /\ UNCHANGED <<at, live, status, shown, mark, up, restarts, call, pending, results, cleared,
                   sent, asked, wrong, unasked, killedOn>>

\* A restart: the call under way, the answers not pressed and the tasks' answers not taken
\* are lost (a task ends with Sessions); the row stays.
Restart ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ call' = {} /\ pending' = {} /\ results' = {}
    /\ UNCHANGED <<at, live, status, shown, mark, cleared, lease, sent, asked, wrong, unasked,
                   killedOn>>

\* What the row's marks say once Sessions reads them again: an answer marked pressing may
\* have gone, so it is cut, never pressed again unless a person clears it, and a press cut
\* after its clear is unknown. Under RetryUnknown it is cleared, to be answered again; under
\* ClearTwice it is cut again.
Readopted ==
    [k \in Kinds |->
       IF mark[k] = "pressing"
       THEN CASE Break = "RetryUnknown" -> "none"
              [] k \in cleared /\ Break # "ClearTwice" -> "unknown"
              [] OTHER -> "cut"
       ELSE mark[k]]

Recover ==
    /\ ~up
    /\ up' = TRUE
    /\ mark' = Readopted
    /\ UNCHANGED <<at, live, status, shown, restarts, call, pending, results, cleared, lease, sent, asked,
                   wrong, unasked, killedOn>>

\* The agent's own process crashes and its supervisor starts it again, in one step (B4;
\* F-164): nothing reads its memory in between. Its press tasks end with it, so the answers
\* not pressed and the tasks' answers not taken are lost. A person's answer on its way is lost
\* with it, or reaches the new process, since Prompts runs on; the Scheduler and Recoveries run
\* on too. The row stays, and the init reads its marks again, as Recover does.
RestartAgent ==
    /\ up /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ call' \in {call, {}}
    /\ pending' = {} /\ results' = {}
    /\ mark' = Readopted
    /\ UNCHANGED <<at, live, status, shown, up, cleared, lease, sent, asked, wrong, unasked,
                   killedOn>>

-----------------------------------------------------------------------------

Init ==
    /\ at = 0 /\ live = TRUE
    /\ status = "starting" /\ shown = "none"
    /\ mark = [k \in Kinds |-> "none"]
    /\ up = TRUE /\ restarts = 0
    /\ call = {} /\ pending = {} /\ results = {} /\ cleared = {}
    /\ lease = "held"
    /\ sent = [k \in Kinds |-> 0]
    /\ asked = {} /\ wrong = {} /\ unasked = {} /\ killedOn = {}

Next ==
    \/ Draw \/ Read \/ Callback \/ Confirm \/ Deadline \/ Kill \/ Settle \/ Release
    \/ Restart \/ Recover \/ RestartAgent \/ Stop
    \/ \E l \in Labels : ViewerPress(l) \/ Answer(l)
    \/ \E p \in pending : Press(p)
    \/ \E r \in results : Pressed(r)
    \/ \E c \in call : Take(c)
    \/ \E k \in Kinds : Clear(k)

Fairness ==
    /\ WF_vars(Draw) /\ WF_vars(Read) /\ WF_vars(Callback) /\ WF_vars(\E c \in call : Take(c))
    /\ WF_vars(Confirm) /\ WF_vars(Kill) /\ WF_vars(Settle) /\ WF_vars(Release)
    /\ WF_vars(Recover)
    /\ WF_vars(\E p \in pending : Press(p)) /\ WF_vars(\E r \in results : Pressed(r))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ at \in 0..(N + 1) /\ live \in BOOLEAN
    /\ status \in Statuses /\ shown \in Kinds \cup {"none"}
    /\ mark \in [Kinds -> Marks]
    /\ up \in BOOLEAN /\ restarts \in 0..MaxRestarts
    /\ call \subseteq [kind : Kinds, label : Labels] /\ Cardinality(call) <= 1
    /\ pending \subseteq [kind : Kinds, label : Labels]
    /\ results \subseteq [kind : Kinds, mark : {"none", "sent", "unknown"}]
    /\ cleared \subseteq Kinds
    /\ lease \in {"held", "released"}

\* Nothing answers a dialog unless a person or the app's callback asked for that kind.
OnlyAsked == unasked = {}

\* A press lands only on the dialog it names.
OnNamed == wrong = {}

\* A dialog's answer is pressed at most once, whatever its outcome, and once more only after
\* a person cleared a press a restart cut.
AtMostOnce == \A k \in Kinds : sent[k] <= IF k \in cleared THEN 2 ELSE 1

\* A process waiting on a dialog is never ended as an orphan.
NotEndedOnDialog == killedOn \cap Kinds = {}

\* The start's lease is held while its process lives.
LeaseWhileLive == lease = "released" => ~live

\* A dialog the pane shows becomes the row's, after any answer, so a view shows the one shown.
DialogShown ==
    \A i \in 1..N : (at = i /\ live) ~> (shown = Dialogs[i] \/ at # i \/ ~live)

\* Past the dialogs, the start goes on: the row runs.
GoesOn == (at = N + 1 /\ live) ~> (status = "running" \/ ~live)

=============================================================================
