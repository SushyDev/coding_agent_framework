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
(* a prompt (Prompt.tla, instanced as P; F-167): the row's mark is the     *)
(* prompt's status (`pressing` is answering, `sent` answered, then         *)
(* unknown and cut; a cleared press is open again), and its row in Acts    *)
(* is the prompt's claim on its state. A press refused, the pane no        *)
(* longer showing its dialog, withdraws the prompt: the dialog never       *)
(* shows again. A numbered menu no rule names that a start meets (F-203,   *)
(* kind `start_menu`) is one more such dialog, which the app's callback    *)
(* never answers; its checked press reads the marker back before Enter.    *)
(* No step changes: this spec's two dialogs stand for any number of kinds. *)
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
(* implies it. Its KeptAcrossRestart is Boxes.tla's: a row on a dialog     *)
(* the pane shows has its prompt waiting. The row is Prompt.tla's now:     *)
(* Open at the read, Answer at the take, Hand and LetGo at the press,      *)
(* Settle at the task's answer, Cut, Readopt and CutAndReadopt at the      *)
(* restarts, Clear at a person's clear, and its OnlyRightful is checked    *)
(* here; the evidence a restart settles by (Readopted) stays this spec's.  *)
(* AutoAnswer and RetryUnknown are Prompt's AnyAnswerer and RetryUnknown,  *)
(* PromptInMemory its InMemory. Its LeaseWhileLive is Boxes.tla's for the  *)
(* dialog statuses.                                                        *)
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
    "ClearTwice",    \* a press a restart cut may be cleared again after its second try
    "PromptInMemory" \* an open prompt is kept in memory, so a whole restart loses it
}

ASSUME Break \in Breaks

\* The order 2.1.322 shows them in (F-140's captures), for the configurations.
TrustThenImports == <<"trust", "imports">>

N == Len(Dialogs)
Kinds == {Dialogs[i] : i \in 1..N}
Labels == {"yes", "no"}
Statuses == {"starting", "dialog", "running", "orphan", "stopped"}

ASSUME Auto \subseteq Kinds

VARIABLES
    at,        \* the program: 0 nothing drawn, i a dialog Dialogs[i], N+1 past them (its file written)
    live,      \* the program's process lives
    status,    \* the agent row's status
    shown,     \* the agent row's dialog: a kind, or "none"
    up,        \* Sessions runs
    restarts,
    call,      \* a person's answer on its way to Sessions: {} or {[kind, label]}
    \* k's prompt, as Prompt.tla's row (P): its answer's mark
    pst,       \* the row: k -> its status: answering is pressing, answered is sent
    pep,       \* the row: k -> the number of its state
    pclaims,   \* Acts: the answers' claims, [by, t (the kind), s, act (the label), n]
    pending,   \* in memory: the claims marked answering whose task has not pressed yet
    pdone, pacted, ptwice, pcut, pwrong,   \* Prompt's and Claim's own, ghosts but pdone
    results,   \* in memory: the tasks' answers not yet taken: [kind, mark]
    cleared,   \* the agent row: the kinds whose cut press a person cleared, once
    lease,     \* the Scheduler's lease of the start: "held" or "released"
    sent,      \* ghost: k -> the presses sent for k
    asked,     \* ghost: the kinds a person or the app's callback asked to answer
    wrong,     \* ghost: kinds whose press landed on another screen
    unasked,   \* ghost: kinds pressed that no one asked to answer
    killedOn   \* ghost: what the screen showed when Recoveries ended the process

pRow == <<pst, pep, pclaims, pending, pdone, pacted, ptwice, pcut, pwrong>>

vars == <<at, live, status, shown, up, restarts, call, pRow, results, cleared, lease,
          sent, asked, wrong, unasked, killedOn>>

\* The prompt of each dialog: a person answers it, or the app's callback for a kind it chose.
\* Its owner is this spec: the press, and the evidence a restart settles it by.
P == INSTANCE Prompt WITH
       Ps <- Kinds, Agents <- {"agent"}, Parent <- [a \in {"agent"} |-> "none"],
       Persons <- {"person"}, ParentKinds <- {}, AppKinds <- Auto, DefaultKinds <- {},
       ExpireKinds <- {}, HeldPs <- {}, Cap <- 0, Budget <- 1, MaxRestarts <- MaxRestarts,
       MaxTools <- 0,
       Break <- CASE Break = "AutoAnswer" -> "AnyAnswerer"
                  [] Break = "RetryUnknown" -> "RetryUnknown"
                  [] Break = "PromptInMemory" -> "InMemory"
                  [] OTHER -> "none",
       st <- pst, ep <- pep, kind <- [k \in Kinds |-> k], asker <- [k \in Kinds |-> "agent"],
       claims <- pclaims, acting <- pending, cdone <- pdone, acted <- pacted, twice <- ptwice,
       cut <- pcut, pwrong <- pwrong,
       up <- up, restarts <- restarts,
       hconn <- [p \in {} |-> FALSE], hrow <- [p \in {} |-> "none"], hmarking <- {},
       hout <- [p \in {} |-> <<>>], hwrong <- {},
       took <- [k \in Kinds |-> 0], orec <- [k \in Kinds |-> "none"], otold <- {},
       told <- [k \in Kinds |-> 0],
       turn <- "working", blocks <- 0, tools <- 0, crashes <- 0, gaveUp <- FALSE

OnDialog == at \in 1..N
Shows(k) == OnDialog /\ Dialogs[at] = k

\* What a press with `label` does to the screen it lands on: the trust dialog's "no" exits.
Lands(label) ==
    IF Dialogs[at] = "trust" /\ label = "no"
    THEN live' = FALSE /\ at' = at
    ELSE at' = at + 1 /\ live' = live

\* The dialog the pane shows becomes the row's, and its prompt opens once.
OpensShown ==
    IF pst[Dialogs[at]] = "none" THEN P!Open(Dialogs[at]) ELSE UNCHANGED pRow

-----------------------------------------------------------------------------
(* The program *)

Draw ==
    /\ live /\ at = 0
    /\ at' = 1
    /\ UNCHANGED <<live, status, shown, up, restarts, call, pRow, results, cleared, lease, sent,
                   asked, wrong, unasked, killedOn>>

\* A person at the viewer answers the dialog shown, by its own keys.
ViewerPress(label) ==
    /\ live /\ OnDialog
    /\ Lands(label)
    /\ UNCHANGED <<status, shown, up, restarts, call, pRow, results, cleared, lease, sent, asked,
                   wrong, unasked, killedOn>>

-----------------------------------------------------------------------------
(* Sessions *)

\* The pane read while the row has no session file: a dialog shown is the row's, and opens its
\* prompt. Under NoRead only the start's call reads it.
Read ==
    /\ up /\ live /\ OnDialog
    /\ status \in {"starting", "dialog"}
    /\ Break = "NoRead" => status = "starting"
    /\ shown # Dialogs[at]
    /\ status' = "dialog"
    /\ shown' = Dialogs[at]
    /\ OpensShown
    /\ UNCHANGED <<at, live, up, restarts, call, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* The app's callback, at a dialog it reads: an answer for a kind it chose, marked first.
\* Under AutoAnswer Sessions answers the trust dialog with no one asking.
Callback ==
    /\ up /\ status = "dialog" /\ shown # "none" /\ pst[shown] = "open" /\ shown \notin cleared
    /\ shown \in Auto \/ (Break = "AutoAnswer" /\ shown = "trust")
    /\ P!Answer(shown, IF shown \in Auto THEN "app" ELSE "sessions", "yes")
    /\ asked' = IF shown \in Auto THEN asked \cup {shown} ELSE asked
    /\ UNCHANGED <<at, live, status, shown, up, restarts, call, results, cleared, lease, sent,
                   wrong, unasked, killedOn>>

\* A person reads the row's dialog in a view and answers it by a label.
Answer(label) ==
    /\ status = "dialog" /\ shown # "none" /\ call = {}
    /\ call' = {[kind |-> shown, label |-> label]}
    /\ asked' = asked \cup {shown}
    /\ UNCHANGED <<at, live, status, shown, up, restarts, pRow, results, cleared, lease, sent,
                   wrong, unasked, killedOn>>

\* Sessions takes the answer: marked answering (Prompt's Answer, its claim taken) when its
\* prompt is open, a cut press a person cleared among them, else refused (an answer already
\* sent, or unknown, is never sent twice). The press goes to a task. Under RetryUnknown an
\* unknown one is taken again.
Take(c) ==
    /\ up /\ c \in call
    /\ call' = {}
    /\ IF P!Answerable(c.kind)
       THEN P!Answer(c.kind, "person", c.label)
       ELSE UNCHANGED pRow
    /\ UNCHANGED <<at, live, status, shown, up, restarts, results, cleared, lease, sent, asked,
                   wrong, unasked, killedOn>>

\* The task's checked press, in one step: the pane must show the dialog the answer names, or
\* nothing goes (the claim let go). A press that goes is the claim's act: it lands on what the
\* pane shows; its outcome is known (sent) or not (unknown), and an unknown one may not have
\* landed. Its answer comes back as a message; until Sessions takes it the prompt stays
\* answering. Under Unchecked the press goes whatever the pane shows.
Press(p) ==
    /\ up /\ p \in pending
    /\ IF live /\ (Shows(p.t) \/ (Break = "Unchecked" /\ OnDialog))
       THEN /\ P!Hand(p)
            /\ sent' = [sent EXCEPT ![p.t] = @ + 1]
            /\ wrong' = IF Dialogs[at] # p.t THEN wrong \cup {p.t} ELSE wrong
            /\ unasked' = IF p.t \notin asked THEN unasked \cup {p.t} ELSE unasked
            /\ \/ Lands(p.act) /\ results' = results \cup {[kind |-> p.t, mark |-> "sent"]}
               \/ Lands(p.act) /\ results' = results \cup {[kind |-> p.t, mark |-> "unknown"]}
               \/ UNCHANGED <<at, live>>
                  /\ results' = results \cup {[kind |-> p.t, mark |-> "unknown"]}
       ELSE /\ P!LetGo(p)
            /\ results' = results \cup {[kind |-> p.t, mark |-> "none"]}
            /\ UNCHANGED <<at, live, sent, wrong, unasked>>
    /\ UNCHANGED <<status, shown, up, restarts, call, cleared, lease, asked, killedOn>>

\* Sessions takes the task's answer, Prompt's Settle: sent is answered, unknown stays unknown.
\* A refusal pressed nothing: the pane no longer shows that dialog (a person's keys at the
\* viewer moved it on, or the process exited), and it never shows it again, so the prompt is
\* withdrawn, read by its owner.
Pressed(r) ==
    /\ up /\ r \in results
    /\ results' = results \ {r}
    /\ P!Settle(r.kind, CASE r.mark = "sent" -> "answered"
                          [] r.mark = "unknown" -> "unknown"
                          [] OTHER -> "withdrawn")
    /\ UNCHANGED <<at, live, status, shown, up, restarts, call, cleared, lease, sent, asked,
                   wrong, unasked, killedOn>>

\* A person who saw the pane still show the dialog, its first option selected, clears a press
\* a restart cut, once: its prompt is open again, and that press is checked as any. Under
\* ClearTwice a press cut after its clear is cut again, so it may be cleared again.
Clear(k) ==
    /\ up /\ live /\ status = "dialog" /\ Shows(k) /\ pst[k] = "cut"
    /\ P!Clear(k, "open")
    /\ cleared' = cleared \cup {k}
    /\ UNCHANGED <<at, live, status, shown, up, restarts, call, results, lease, sent, asked,
                   wrong, unasked, killedOn>>

\* A person stops a row on a dialog: SIGTERM to its held program's record. The process exits,
\* or outlives the stop's deadline and the row waits as before.
Stop ==
    /\ up /\ live /\ status = "dialog"
    /\ live' \in BOOLEAN
    /\ UNCHANGED <<at, status, shown, up, restarts, call, pRow, results, cleared, lease, sent,
                   asked, wrong, unasked, killedOn>>

\* Past the dialogs the session file names the process: the start goes on, as before.
Confirm ==
    /\ up /\ live /\ at = N + 1
    /\ status \in {"starting", "dialog"}
    /\ status' = "running" /\ shown' = "none"
    /\ UNCHANGED <<at, live, up, restarts, call, pRow, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* The start's deadline, with no session file: the pane is read in the same step, and a
\* dialog makes the row wait on a person; anything else is an orphan, for Recoveries. Under
\* DeadlineEnds the pane is not read.
Deadline ==
    /\ up /\ live /\ status = "starting" /\ at \in 1..N
    /\ IF OnDialog /\ Break # "DeadlineEnds"
       THEN status' = "dialog" /\ shown' = Dialogs[at] /\ OpensShown
       ELSE status' = "orphan" /\ shown' = shown /\ UNCHANGED pRow
    /\ UNCHANGED <<at, live, up, restarts, call, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* Recoveries ends an orphan's process.
Kill ==
    /\ live /\ status = "orphan"
    /\ live' = FALSE
    /\ killedOn' = killedOn \cup {IF OnDialog THEN Dialogs[at] ELSE "screen"}
    /\ UNCHANGED <<at, status, shown, up, restarts, call, pRow, results, cleared, lease, sent,
                   asked, wrong, unasked>>

\* The process gone (its socket dead): stopped, so its name is free.
Settle ==
    /\ up /\ ~live /\ status # "stopped"
    /\ status' = "stopped" /\ shown' = "none"
    /\ UNCHANGED <<at, live, up, restarts, call, pRow, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* The Scheduler releases the lease once the row's owner says the work ended: its row free.
\* Under DialogFree a row on a dialog counts as free.
Release ==
    /\ lease = "held"
    /\ status = "stopped" \/ (Break = "DialogFree" /\ status = "dialog")
    /\ lease' = "released"
    /\ UNCHANGED <<at, live, status, shown, up, restarts, call, pRow, results, cleared, sent,
                   asked, wrong, unasked, killedOn>>

\* A restart: the call under way, the answers not pressed (their claims, Prompt's Cut) and
\* the tasks' answers not taken are lost (a task ends with Sessions); the row stays.
Restart ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ call' = {} /\ results' = {}
    /\ P!Cut
    /\ UNCHANGED <<at, live, status, shown, cleared, lease, sent, asked, wrong, unasked,
                   killedOn>>

\* The evidence an answering prompt settles by once Sessions reads its row again: its press
\* may have gone, so it is cut, never pressed again unless a person clears it, and a press cut
\* after its clear is unknown. Under RetryUnknown it is open again, to be answered again;
\* under ClearTwice it is cut again.
Readopted ==
    [k \in Kinds |->
       CASE Break = "RetryUnknown" -> "open"
         [] k \in cleared /\ Break # "ClearTwice" -> "unknown"
         [] OTHER -> "cut"]

Recover ==
    /\ ~up
    /\ up' = TRUE
    /\ P!Readopt(Readopted)
    /\ UNCHANGED <<at, live, status, shown, restarts, call, results, cleared, lease, sent, asked,
                   wrong, unasked, killedOn>>

\* The agent's own process crashes and its supervisor starts it again, in one step (B4;
\* F-164): nothing reads its memory in between. Its press tasks end with it, so the answers
\* not pressed and the tasks' answers not taken are lost. A person's answer on its way is lost
\* with it, or reaches the new process, since Prompts runs on; the Scheduler and Recoveries run
\* on too. The row stays, and the init reads its prompts again, as Recover does.
RestartAgent ==
    /\ up /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ call' \in {call, {}}
    /\ results' = {}
    /\ P!CutAndReadopt(Readopted)
    /\ UNCHANGED <<at, live, status, shown, up, cleared, lease, sent, asked, wrong, unasked,
                   killedOn>>

-----------------------------------------------------------------------------

Init ==
    /\ at = 0 /\ live = TRUE
    /\ status = "starting" /\ shown = "none"
    /\ up = TRUE /\ restarts = 0
    /\ call = {}
    /\ pst = [k \in Kinds |-> "none"] /\ pep = [k \in Kinds |-> 0]
    /\ pclaims = {} /\ pending = {} /\ pdone = {} /\ pacted = {} /\ ptwice = FALSE
    /\ pcut = {} /\ pwrong = {}
    /\ results = {} /\ cleared = {}
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
    /\ pst \in [Kinds -> P!Statuses] /\ pep \in [Kinds -> Nat]
    /\ up \in BOOLEAN /\ restarts \in 0..MaxRestarts
    /\ call \subseteq [kind : Kinds, label : Labels] /\ Cardinality(call) <= 1
    /\ pending \subseteq pclaims
    /\ results \subseteq [kind : Kinds, mark : {"none", "sent", "unknown"}]
    /\ cleared \subseteq Kinds
    /\ lease \in {"held", "released"}

\* Nothing answers a dialog unless a person or the app's callback asked for that kind.
OnlyAsked == unasked = {}

\* ... and Prompt's: every answer's claim is a person's, or the app's for a kind it chose.
OnlyRightful == P!OnlyRightful

\* A press lands only on the dialog it names.
OnNamed == wrong = {}

\* A dialog's answer is pressed at most once, whatever its outcome, and once more only after
\* a person cleared a press a restart cut.
AtMostOnce == \A k \in Kinds : sent[k] <= IF k \in cleared THEN 2 ELSE 1

\* A process waiting on a dialog is never ended as an orphan.
NotEndedOnDialog == killedOn \cap Kinds = {}

\* The start's lease is held while its process lives.
LeaseWhileLive == lease = "released" => ~live

\* A row on a dialog the pane still shows has its prompt waiting, across either restart: open,
\* answering, or its press cut or unknown (Boxes.tla's, with its keys in flight the press's
\* unknown here).
KeptAcrossRestart ==
    \A k \in Kinds : status = "dialog" /\ shown = k /\ live /\ Shows(k) => pst[k] \in P!Waiting

\* A dialog the pane shows becomes the row's, after any answer, so a view shows the one shown.
DialogShown ==
    \A i \in 1..N : (at = i /\ live) ~> (shown = Dialogs[i] \/ at # i \/ ~live)

\* Past the dialogs, the start goes on: the row runs.
GoesOn == (at = N + 1 /\ live) ~> (status = "running" \/ ~live)

=============================================================================
