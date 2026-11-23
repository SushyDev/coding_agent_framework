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
(* Each dialog a start shows is its own read and its own prompt (F-206):   *)
(* the row keeps an answer by the read that found its dialog, not by its   *)
(* kind, so a start that shows several menus one after another asks a      *)
(* person each, and presses each at most once. The trust and imports       *)
(* dialogs show once a start, so for them a read and a kind are one key.   *)
(*                                                                         *)
(* Models Sessions' read of a starting session's pane and its answer       *)
(* (`Sessions.answer_dialog/5`), a person's clear (`clear_dialog/4`) and   *)
(* stop (`stop/3` of a row on a dialog), the Inlet's checked press         *)
(* (`Inlet.choose/5`), the callback the app may give (`dialog:`), the      *)
(* status lists of `Sessions.Table` the Scheduler's lease reads, and       *)
(* `Sessions.Dialog`'s reads (`seen/3`, a start's menu by its `at`).       *)
(*                                                                         *)
(* Left abstract: time (a deadline is a step); what a label says beyond    *)
(* "yes" and "no" (the trust dialog's "no" exits; the imports dialog's     *)
(* goes on with imports off); the session file's contents; other           *)
(* sessions. The dialogs a start shows one after another differ from each  *)
(* other (a start's menus by their titles, as an onboarding's steps do),   *)
(* so each draw is one read: `Dialogs[i]` is read `i`. The same menu drawn *)
(* again after its press was sent is a new read in the code, as in         *)
(* Menu.tla. A person at the viewer may answer the dialog shown at any     *)
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
(*                                                                         *)
(* An end asked mid-start (F-231; with Ends): the operator's end of a main *)
(* session, or a stop of a delegate, asked while the row waits on a        *)
(* dialog. It answers the dialog shown by its exit option, the trust       *)
(* dialog's "No, exit", as a person's answer is: a prompt's answer, its    *)
(* press checked (AskEnd, EndPress). A dialog with no exit option (the     *)
(* imports dialog, a start's menu), one whose answer is marked, or a       *)
(* process still live after the press, gets SIGTERM to its held program's  *)
(* record (EndTerm), as a person's Stop. Once the process is gone the row  *)
(* is ended (EndDone), and the start that waited is refused, `ended`. From *)
(* the ask on the row is never confirmed running: a session asked to end   *)
(* runs no later turn (NoTurnAfterEnd), and an asked end ends (EndEnds),   *)
(* or answers unknown: its process outlived the TERM (EndOutlived), or a   *)
(* restart cut the call, which a person may ask again. Models              *)
(* `Sessions.end_main/3` and `stop/3` of a row on a dialog, and            *)
(* `Mains.end_main/3`, which asks it of a start that waits on a dialog.    *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Dialogs,      \* the kinds the program shows, in order, e.g. <<"trust", "imports">>; a
                  \* start's menu ("menu") may show more than once
    Auto,         \* the kinds the app's callback answers ("yes"); {} by default: it asks
    MaxRestarts,  \* restarts of Sessions and of the agent's own process
    Ends,         \* whether an end may be asked of the row on a dialog (F-231)
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
    "PromptInMemory", \* an open prompt is kept in memory, so a whole restart loses it
    "ByKind",        \* answers are kept by kind (F-203): a read whose kind has a prompt opens none
    "EndRefused"     \* an end asked while the start waits on a dialog is refused, as before F-231
}

ASSUME Break \in Breaks

\* The order 2.1.322 shows them in (F-140's captures), for the configurations.
TrustThenImports == <<"trust", "imports">>

\* A new account's onboarding: the trust dialog, then two menus no rule names (F-206).
TrustThenMenus == <<"trust", "menu", "menu">>

N == Len(Dialogs)
Reads == 1..N
Kinds == {Dialogs[i] : i \in Reads}
Labels == {"yes", "no"}
Statuses == {"starting", "dialog", "running", "orphan", "stopped", "ended"}

\* The end's own steps: asked, its exit press under way, its TERM owed or sent; then ended,
\* refused (EndRefused only), unknown (the process outlived the TERM) or cut (a restart).
Ending == {"asked", "pressed", "term", "termed"}
EndStates == {"none", "ended", "refused", "unknown", "cut"} \cup Ending

ASSUME Auto \subseteq Kinds

\* No app's callback answers a start's menu: it has no default, so only a person's answer
\* presses it (OnlyRightful).
ASSUME "menu" \notin Auto

VARIABLES
    at,        \* the program: 0 nothing drawn, i a dialog Dialogs[i] (read i), N+1 past them
    live,      \* the program's process lives
    status,    \* the agent row's status
    shown,     \* the agent row's dialog: the read that found it, or 0 for none
    up,        \* Sessions runs
    restarts,
    call,      \* a person's answer on its way to Sessions: {} or {[read, label]}
    \* read i's prompt, as Prompt.tla's row (P): its answer's mark
    pst,       \* the row: i -> its status: answering is pressing, answered is sent
    pep,       \* the row: i -> the number of its state
    pclaims,   \* Acts: the answers' claims, [by, t (the read), s, act (the label), n]
    pending,   \* in memory: the claims marked answering whose task has not pressed yet
    pdone, pacted, ptwice, pcut, pwrong,   \* Prompt's and Claim's own, ghosts but pdone
    results,   \* in memory: the tasks' answers not yet taken: [read, mark]
    cleared,   \* the agent row: the reads whose cut press a person cleared, once
    lease,     \* the Scheduler's lease of the start: "held" or "released"
    sent,      \* ghost: i -> the presses sent for read i
    asked,     \* ghost: the reads a person or the app's callback asked to answer
    wrong,     \* ghost: reads whose press landed on another screen
    unasked,   \* ghost: reads pressed that no one asked to answer
    killedOn,  \* ghost: the read the screen showed when Recoveries ended the process, 0 none
    ending,    \* the end asked of the row (F-231): one of EndStates
    endRead    \* the read the end's exit press answers, 0 for none

pRow == <<pst, pep, pclaims, pending, pdone, pacted, ptwice, pcut, pwrong>>
endVars == <<ending, endRead>>

vars == <<at, live, status, shown, up, restarts, call, pRow, results, cleared, lease,
          sent, asked, wrong, unasked, killedOn, endVars>>

\* The prompt of each read: a person answers it, or the app's callback for a kind it chose.
\* Its owner is this spec: the press, and the evidence a restart settles it by.
P == INSTANCE Prompt WITH
       Ps <- Reads, Agents <- {"agent"}, Parent <- [a \in {"agent"} |-> "none"],
       Persons <- {"person"}, ParentKinds <- {}, AppKinds <- Auto, DefaultKinds <- {},
       ExpireKinds <- {}, HeldPs <- {}, Cap <- 0, Budget <- 1, MaxRestarts <- MaxRestarts,
       MaxTools <- 0,
       Break <- CASE Break = "AutoAnswer" -> "AnyAnswerer"
                  [] Break = "RetryUnknown" -> "RetryUnknown"
                  [] Break = "PromptInMemory" -> "InMemory"
                  [] OTHER -> "none",
       st <- pst, ep <- pep, kind <- [i \in Reads |-> Dialogs[i]],
       asker <- [i \in Reads |-> "agent"],
       claims <- pclaims, acting <- pending, cdone <- pdone, acted <- pacted, twice <- ptwice,
       cut <- pcut, pwrong <- pwrong,
       up <- up, restarts <- restarts,
       hconn <- [p \in {} |-> FALSE], hrow <- [p \in {} |-> "none"], hmarking <- {},
       hout <- [p \in {} |-> <<>>], hwrong <- {},
       took <- [i \in Reads |-> 0], orec <- [i \in Reads |-> "none"], otold <- {},
       told <- [i \in Reads |-> 0],
       turn <- "working", blocks <- 0, tools <- 0, crashes <- 0, gaveUp <- FALSE

OnDialog == at \in Reads
\* The pane shows read i's dialog: its kind, and for a menu its title and options.
Shows(i) == at = i

\* What a press with `label` does to the screen it lands on: the trust dialog's "no" exits.
Lands(label) ==
    IF Dialogs[at] = "trust" /\ label = "no"
    THEN live' = FALSE /\ at' = at
    ELSE at' = at + 1 /\ live' = live

\* The dialog the pane shows becomes the row's, and its read's prompt opens once. Under ByKind
\* a read opens none when another of its kind has one: its answer, kept by kind, is marked.
ByKindMarked == \E j \in Reads : j # at /\ Dialogs[j] = Dialogs[at] /\ pst[j] # "none"

OpensShown ==
    IF pst[at] = "none" /\ ~(Break = "ByKind" /\ ByKindMarked) THEN P!Open(at) ELSE UNCHANGED pRow

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
    /\ shown # at
    /\ status' = "dialog"
    /\ shown' = at
    /\ OpensShown
    /\ UNCHANGED <<at, live, up, restarts, call, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* The app's callback, at a dialog it reads: an answer for a kind it chose, marked first.
\* Under AutoAnswer Sessions answers the trust dialog with no one asking.
Callback ==
    /\ up /\ status = "dialog" /\ shown # 0 /\ pst[shown] = "open" /\ shown \notin cleared
    /\ Dialogs[shown] \in Auto \/ (Break = "AutoAnswer" /\ Dialogs[shown] = "trust")
    /\ P!Answer(shown, IF Dialogs[shown] \in Auto THEN "app" ELSE "sessions", "yes")
    /\ asked' = IF Dialogs[shown] \in Auto THEN asked \cup {shown} ELSE asked
    /\ UNCHANGED <<at, live, status, shown, up, restarts, call, results, cleared, lease, sent,
                   wrong, unasked, killedOn>>

\* A person reads the row's dialog in a view and answers it by a label: the answer names its
\* read (the prompt's id).
Answer(label) ==
    /\ status = "dialog" /\ shown # 0 /\ call = {}
    /\ call' = {[read |-> shown, label |-> label]}
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
    /\ IF P!Answerable(c.read)
       THEN P!Answer(c.read, "person", c.label)
       ELSE UNCHANGED pRow
    /\ UNCHANGED <<at, live, status, shown, up, restarts, results, cleared, lease, sent, asked,
                   wrong, unasked, killedOn>>

\* The task's checked press, in one step: the pane must show the dialog the answer names (its
\* kind; a menu's title and options), or nothing goes (the claim let go). A press that goes is
\* the claim's act: it lands on what the pane shows; its outcome is known (sent) or not
\* (unknown), and an unknown one may not have landed. Its answer comes back as a message; until Sessions takes it the prompt stays
\* answering. Under Unchecked the press goes whatever the pane shows.
Press(p) ==
    /\ up /\ p \in pending
    /\ IF live /\ (Shows(p.t) \/ (Break = "Unchecked" /\ OnDialog))
       THEN /\ P!Hand(p)
            /\ sent' = [sent EXCEPT ![p.t] = @ + 1]
            /\ wrong' = IF at # p.t THEN wrong \cup {p.t} ELSE wrong
            /\ unasked' = IF p.t \notin asked THEN unasked \cup {p.t} ELSE unasked
            /\ \/ Lands(p.act) /\ results' = results \cup {[read |-> p.t, mark |-> "sent"]}
               \/ Lands(p.act) /\ results' = results \cup {[read |-> p.t, mark |-> "unknown"]}
               \/ UNCHANGED <<at, live>>
                  /\ results' = results \cup {[read |-> p.t, mark |-> "unknown"]}
       ELSE /\ P!LetGo(p)
            /\ results' = results \cup {[read |-> p.t, mark |-> "none"]}
            /\ UNCHANGED <<at, live, sent, wrong, unasked>>
    /\ UNCHANGED <<status, shown, up, restarts, call, cleared, lease, asked, killedOn>>

\* Sessions takes the task's answer, Prompt's Settle: sent is answered, unknown stays unknown.
\* A refusal pressed nothing: the pane no longer shows that dialog (a person's keys at the
\* viewer moved it on, or the process exited), and it never shows it again, so the prompt is
\* withdrawn, read by its owner.
Pressed(r) ==
    /\ up /\ r \in results
    /\ results' = results \ {r}
    /\ P!Settle(r.read, CASE r.mark = "sent" -> "answered"
                          [] r.mark = "unknown" -> "unknown"
                          [] OTHER -> "withdrawn")
    /\ UNCHANGED <<at, live, status, shown, up, restarts, call, cleared, lease, sent, asked,
                   wrong, unasked, killedOn>>

\* A person who saw the pane still show the dialog, its first option selected, clears a press
\* a restart cut, once: its prompt is open again, and that press is checked as any. Under
\* ClearTwice a press cut after its clear is cut again, so it may be cleared again.
Clear(i) ==
    /\ up /\ live /\ status = "dialog" /\ Shows(i) /\ pst[i] = "cut"
    /\ P!Clear(i, "open")
    /\ cleared' = cleared \cup {i}
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
\* A row whose end is under way is never confirmed: its call holds the row (F-231).
Confirm ==
    /\ up /\ live /\ at = N + 1
    /\ status \in {"starting", "dialog"}
    /\ ending \notin Ending
    /\ status' = "running" /\ shown' = 0
    /\ UNCHANGED <<at, live, up, restarts, call, pRow, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* The start's deadline, with no session file: the pane is read in the same step, and a
\* dialog makes the row wait on a person; anything else is an orphan, for Recoveries. Under
\* DeadlineEnds the pane is not read.
Deadline ==
    /\ up /\ live /\ status = "starting" /\ at \in Reads
    /\ IF OnDialog /\ Break # "DeadlineEnds"
       THEN status' = "dialog" /\ shown' = at /\ OpensShown
       ELSE status' = "orphan" /\ shown' = shown /\ UNCHANGED pRow
    /\ UNCHANGED <<at, live, up, restarts, call, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* Recoveries ends an orphan's process.
Kill ==
    /\ live /\ status = "orphan"
    /\ live' = FALSE
    /\ killedOn' = killedOn \cup {IF OnDialog THEN at ELSE 0}
    /\ UNCHANGED <<at, status, shown, up, restarts, call, pRow, results, cleared, lease, sent,
                   asked, wrong, unasked>>

\* The process gone (its socket dead): stopped, so its name is free.
Settle ==
    /\ up /\ ~live /\ status \notin {"stopped", "ended"}
    /\ status' = "stopped" /\ shown' = 0
    /\ UNCHANGED <<at, live, up, restarts, call, pRow, results, cleared, lease, sent, asked, wrong,
                   unasked, killedOn>>

\* The Scheduler releases the lease once the row's owner says the work ended: its row free.
\* Under DialogFree a row on a dialog counts as free.
Release ==
    /\ lease = "held"
    /\ status \in {"stopped", "ended"} \/ (Break = "DialogFree" /\ status = "dialog")
    /\ lease' = "released"
    /\ UNCHANGED <<at, live, status, shown, up, restarts, call, pRow, results, cleared, sent,
                   asked, wrong, unasked, killedOn>>

\* An end under way is the call's, in memory: a restart cuts it, and its caller is told
\* unknown. A person may ask it again.
CutEnd ==
    /\ ending' = IF ending \in Ending THEN "cut" ELSE ending
    /\ UNCHANGED endRead

\* A restart: the call under way, the answers not pressed (their claims, Prompt's Cut) and
\* the tasks' answers not taken are lost (a task ends with Sessions); the row stays.
Restart ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ call' = {} /\ results' = {}
    /\ P!Cut
    /\ CutEnd
    /\ UNCHANGED <<at, live, status, shown, cleared, lease, sent, asked, wrong, unasked,
                   killedOn>>

\* The evidence an answering prompt settles by once Sessions reads its row again: its press
\* may have gone, so it is cut, never pressed again unless a person clears it, and a press cut
\* after its clear is unknown. Under RetryUnknown it is open again, to be answered again;
\* under ClearTwice it is cut again.
Readopted ==
    [i \in Reads |->
       CASE Break = "RetryUnknown" -> "open"
         [] i \in cleared /\ Break # "ClearTwice" -> "unknown"
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
    /\ CutEnd
    /\ UNCHANGED <<at, live, status, shown, up, cleared, lease, sent, asked, wrong, unasked,
                   killedOn>>

-----------------------------------------------------------------------------
(* An end asked mid-start (F-231) *)

Others == <<at, live, status, shown, up, restarts, call, pRow, results, cleared, lease, sent,
            asked, wrong, unasked, killedOn>>

\* The operator's end of the main session, or a stop, asked of the row on a dialog; again
\* after a restart cut one. One whose process outlived its TERM is left, as a stop's
\* `no_exit` is, to a person: asked again and again it would TERM a process that ignores it.
AskEnd ==
    /\ Ends /\ status = "dialog" /\ ending \in {"none", "cut"}
    /\ ending' = "asked" /\ endRead' = 0
    /\ UNCHANGED Others

\* The trust dialog shown, its answer open: its exit option, as a person's answer, marked and
\* its press checked as any. Anything else gets SIGTERM. Under EndRefused it is refused, as
\* `{:starting, name}` was.
HasExit(i) == i # 0 /\ Dialogs[i] = "trust" /\ P!Answerable(i)

EndPress ==
    /\ up /\ ending = "asked" /\ status = "dialog"
    /\ IF Break = "EndRefused"
       THEN ending' = "refused" /\ UNCHANGED <<endRead, Others>>
       ELSE IF HasExit(shown)
       THEN /\ P!Answer(shown, "person", "no")
            /\ asked' = asked \cup {shown}
            /\ ending' = "pressed" /\ endRead' = shown
            /\ UNCHANGED <<at, live, status, shown, up, restarts, call, results, cleared, lease,
                           sent, wrong, unasked, killedOn>>
       ELSE ending' = "term" /\ UNCHANGED <<endRead, Others>>

\* The press answered, and the process still lives: it pressed nothing, or not in time.
EndAfterPress ==
    /\ up /\ ending = "pressed" /\ pst[endRead] # "answering" /\ live
    /\ ending' = "term"
    /\ UNCHANGED <<endRead, Others>>

\* SIGTERM to the held program's record: the process exits, or outlives it.
EndTerm ==
    /\ up /\ ending = "term"
    /\ ending' = "termed" /\ live' \in {FALSE, live}
    /\ UNCHANGED <<endRead, at, status, shown, up, restarts, call, pRow, results, cleared,
                   lease, sent, asked, wrong, unasked, killedOn>>

\* The stop's deadline with the process alive: the end answers unknown, and the row waits on
\* its dialog as before.
EndOutlived ==
    /\ up /\ ending = "termed" /\ live
    /\ ending' = "unknown"
    /\ UNCHANGED <<endRead, Others>>

\* The process gone, its press answered: the row is ended, its name never starts again.
EndDone ==
    /\ up /\ ending \in Ending /\ status = "stopped"
    /\ ending = "pressed" => pst[endRead] # "answering"
    /\ status' = "ended" /\ ending' = "ended"
    /\ UNCHANGED <<endRead, at, live, shown, up, restarts, call, pRow, results, cleared, lease,
                   sent, asked, wrong, unasked, killedOn>>

EndSteps == EndPress \/ EndAfterPress \/ EndTerm \/ EndOutlived \/ EndDone

-----------------------------------------------------------------------------

Init ==
    /\ at = 0 /\ live = TRUE
    /\ status = "starting" /\ shown = 0
    /\ up = TRUE /\ restarts = 0
    /\ call = {}
    /\ pst = [i \in Reads |-> "none"] /\ pep = [i \in Reads |-> 0]
    /\ pclaims = {} /\ pending = {} /\ pdone = {} /\ pacted = {} /\ ptwice = FALSE
    /\ pcut = {} /\ pwrong = {}
    /\ results = {} /\ cleared = {}
    /\ lease = "held"
    /\ sent = [i \in Reads |-> 0]
    /\ asked = {} /\ wrong = {} /\ unasked = {} /\ killedOn = {}
    /\ ending = "none" /\ endRead = 0

\* The steps before F-231 leave the end as it is; a restart cuts it.
Kept ==
    \/ Draw \/ Read \/ Callback \/ Confirm \/ Deadline \/ Kill \/ Settle \/ Release
    \/ Recover \/ Stop
    \/ \E l \in Labels : ViewerPress(l) \/ Answer(l)
    \/ \E p \in pending : Press(p)
    \/ \E r \in results : Pressed(r)
    \/ \E c \in call : Take(c)
    \/ \E i \in Reads : Clear(i)

Next ==
    \/ Kept /\ UNCHANGED endVars
    \/ Restart \/ RestartAgent
    \/ AskEnd \/ EndSteps

\* A step before F-231, the end left as it is.
K(A) == A /\ UNCHANGED endVars

Fairness ==
    /\ WF_vars(K(Draw)) /\ WF_vars(K(Read)) /\ WF_vars(K(Callback))
    /\ WF_vars(K(\E c \in call : Take(c)))
    /\ WF_vars(K(Confirm)) /\ WF_vars(K(Kill)) /\ WF_vars(K(Settle)) /\ WF_vars(K(Release))
    /\ WF_vars(K(Recover))
    /\ WF_vars(K(\E p \in pending : Press(p))) /\ WF_vars(K(\E r \in results : Pressed(r)))
    /\ WF_vars(EndSteps)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ at \in 0..(N + 1) /\ live \in BOOLEAN
    /\ status \in Statuses /\ shown \in 0..N
    /\ pst \in [Reads -> P!Statuses] /\ pep \in [Reads -> Nat]
    /\ up \in BOOLEAN /\ restarts \in 0..MaxRestarts
    /\ call \subseteq [read : Reads, label : Labels] /\ Cardinality(call) <= 1
    /\ pending \subseteq pclaims
    /\ results \subseteq [read : Reads, mark : {"none", "sent", "unknown"}]
    /\ cleared \subseteq Reads
    /\ lease \in {"held", "released"}
    /\ ending \in EndStates /\ endRead \in 0..N

\* Nothing answers a dialog unless a person or the app's callback asked for that read.
OnlyAsked == unasked = {}

\* ... and Prompt's: every answer's claim is a person's, or the app's for a kind it chose; a
\* start's menu's, a person's only.
OnlyRightful == P!OnlyRightful

\* A press lands only on the dialog it names.
OnNamed == wrong = {}

\* Each read's answer is pressed at most once, whatever its outcome, and once more only after
\* a person cleared a press a restart cut.
AtMostOnce == \A i \in Reads : sent[i] <= IF i \in cleared THEN 2 ELSE 1

\* A process waiting on a dialog is never ended as an orphan.
NotEndedOnDialog == killedOn \cap Reads = {}

\* The start's lease is held while its process lives.
LeaseWhileLive == lease = "released" => ~live

\* A row on a dialog the pane still shows has its prompt waiting, across either restart: open,
\* answering, or its press cut or unknown (Boxes.tla's, with its keys in flight the press's
\* unknown here). Each read its own: a second menu of one start waits on a person too.
KeptAcrossRestart ==
    \A i \in Reads : status = "dialog" /\ shown = i /\ live /\ Shows(i) => pst[i] \in P!Waiting

\* A dialog the pane shows becomes the row's, after any answer, so a view shows the one shown.
DialogShown ==
    \A i \in Reads : (at = i /\ live) ~> (shown = i \/ at # i \/ ~live)

\* Past the dialogs, the start goes on: the row runs.
GoesOn == (at = N + 1 /\ live) ~> (status = "running" \/ ~live)

\* A session asked to end runs no later turn: from the ask until it is answered, the row is
\* never confirmed running, and once ended it never runs again (F-231).
NoTurnAfterEnd == ending \in Ending \cup {"ended"} => status # "running"

\* An asked end ends: the row ended, or the end answered unknown (the process outlived its
\* TERM, or a restart cut the call). Never refused (F-231).
EndEnds == ending = "asked" ~> ending \in {"ended", "unknown", "cut"}

=============================================================================
