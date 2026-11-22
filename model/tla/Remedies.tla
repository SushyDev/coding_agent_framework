------------------------------ MODULE Remedies ------------------------------
(***************************************************************************)
(* The first remedies on the healer's one shape (F-183, F-184;            *)
(* docs/design.md, "Metrics and healing", "One shape for every remedy"):   *)
(* Heal.tla instanced as H with two kinds beside Boxes.tla's stuck turn,   *)
(* and a headless delegate's turns across a background command.           *)
(*                                                                         *)
(* Models CodingAgentFramework.AbsentMains (the `absent_main` entry of     *)
(* CodingAgentFramework.Watch's allow-list, its detector and its resume    *)
(* through CodingAgentFramework.Mains), CodingAgentFramework.              *)
(* StuckBackgrounds (the `stuck_background` entry), the report            *)
(* CodingAgentFramework.Delegates takes from CodingAgentFramework.Stream.  *)
(* Fold across a background command's turn, and that fold's idle read     *)
(* (CodingAgentFramework.Stream.Fold's `waking`, CodingAgentFramework.     *)
(* Stream's `wake:` bound), on which CodingAgentFramework.Mailbox hands a  *)
(* parent's message on (F-204).                                            *)
(*                                                                         *)
(*   a delegate d      its brief's turn may start a background command;    *)
(*                     the turn's result comes while the command runs,     *)
(*                     and is the report (measured on Claude Code          *)
(*                     2.1.322, F-184). The command's end starts a turn of *)
(*                     Claude Code's own, whose result is never a second   *)
(*                     report (OneReport). d ends only with no turn and no *)
(*                     command running (Sessions.stop's turn_running).     *)
(*                     The command's end and its turn's system/init are    *)
(*                     two events, so the fold reads d busy from the end   *)
(*                     until that turn's result (`waking`, then `own`), and *)
(*                     a parent's message, handed on only on an idle read, *)
(*                     never goes into that turn (NoMessageIntoOwnTurn,    *)
(*                     F-196's new-6). A release that starts no turn at a  *)
(*                     command's end (`silent`) is read idle again once a  *)
(*                     bound passes (ReadsIdleAgain). The bound is taken   *)
(*                     longer than the gap between an end and its init, so *)
(*                     it passes only where no init comes.                 *)
(*   stuck_background  d's report was taken while its background command   *)
(*                     runs and uses no CPU time. Its remedy ends the      *)
(*                     command's group by its record, which may help or    *)
(*                     not; no partial report goes (StuckAfterReport: the  *)
(*                     report was taken before the symptom).               *)
(*   absent_main       a declared main session m whose process is gone.    *)
(*                     Its remedy is one resume; once per absence (H's     *)
(*                     OncePerState), and a second absence of m within a   *)
(*                     bound is asked, not resumed (ResumeOncePerBound,    *)
(*                     then H's ActedOrAsked): asked for its bound, so a   *)
(*                     person may answer "act", one resume of their own    *)
(*                     (H's AnswerAct, F-190), which the healer's bound    *)
(*                     does not count. A resume that finds every account   *)
(*                     limited waits as its own row (F-196): its claim     *)
(*                     stays acted, H's "later", until the row ends, and   *)
(*                     is settled from that end (F-203): verified when the *)
(*                     main resumed, refused when a person left it or its  *)
(*                     pick was refused, so the state is asked             *)
(*                     (WaitedEnd, WaitSettled).                           *)
(*                                                                         *)
(* Every property of Heal.tla is checked through H. Left abstract: how the *)
(* CPU time is read, the Scheduler's lease of the resume, and Mailbox's    *)
(* own delivery (Delivery.tla).                                            *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Remedies_<value>.cfg that TLC must fail.                    *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Delegates,    \* the targets of stuck_background
    Mains,        \* the targets of absent_main
    MaxActs,      \* the cap: remedies of one kind per bound
    MaxState, MaxRestarts, MaxBounds,
    MayWait,      \* a resume may find every account limited and wait (a configuration's)
    Break

Breaks == {
    "none",
    "LastResult",   \* the report is read from the latest result, not the brief's own
    "ResumeTwice",  \* a second absence of a main within the bound is resumed again
    "SettleAtWait", \* a resume that waits is settled verified at once, whatever its row's end
    "IdleAtEnd",    \* the fold reads the turn ended at a command's end, before its init
    "NoBound"       \* no bound: a command's end with no init reads busy for ever
}

WaitEnds == {"resumed", "left", "refused"}

ASSUME Break \in Breaks /\ Delegates \cap Mains = {} /\ MayWait \in BOOLEAN

Kind(s) == IF s \in Delegates THEN "stuck_background" ELSE "absent_main"

VARIABLES
    on, st, facts, claims, acting, cdone, acted, twice, cut, res, count, mem, allow,
    dropped, asked, forBound, closed, wrong, restarts, bounds,  \* Heal.tla's
    turn,      \* d -> "brief" (its brief's turn runs), "idle", "waking" (its command ended,
               \*   and the turn of Claude Code's own that the end begins has not yet written
               \*   its init), "own" (that turn runs), "silent" (its command ended and no turn
               \*   comes), "reply" (a turn the parent's message began), "ended"
    bg,        \* d -> a background command of d runs
    fidle,     \* d -> Stream.Fold reads d's turn ended (`idle`), as Mailbox reads it
    msg,       \* d -> the parent's message to d: "none", "due" or "sent"
    joined,    \* d -> the message went in between a command's end and its own turn's end
    reports,   \* d -> the reports taken as the brief's reply
    resumes,   \* m -> the resumes of m claimed in the bound: a fold of the rows (durable)
    waits      \* the resumes that wait at a limit, [k (the claim's state), end] (Mains' rows)

healVars == <<facts, claims, acting, cdone, acted, twice, cut, res, count, mem, allow,
              dropped, asked, forBound, closed, wrong>>
dvars == <<turn, bg, reports, fidle, msg, joined>>
mine == <<turn, bg, reports, resumes, waits, fidle, msg, joined>>
vars == <<on, st, healVars, restarts, bounds, mine>>

H == INSTANCE Heal WITH Symptoms <- Delegates \cup Mains,
                        Kinds <- {"stuck_background", "absent_main"}, Kind <- Kind,
                        Approved <- {"stuck_background", "absent_main"},
                        Actors <- {"healer", "person"}, Break <- "none"

-----------------------------------------------------------------------------
(* A background command's end, as the delegate and the fold see it *)

\* While no turn runs, the end begins a turn of Claude Code's own, whose init comes later, or,
\* on a release that starts none, nothing. The fold reads d busy from the end (`waking`);
\* under IdleAtEnd it still reads the brief's result, the turn ended.
CommandEnds(d) ==
    /\ bg' = [bg EXCEPT ![d] = FALSE]
    /\ \E w \in {"waking", "silent"} :
          turn' = [turn EXCEPT ![d] = IF @ = "idle" THEN w ELSE @]
    /\ fidle' = [fidle EXCEPT ![d] = IF turn[d] = "idle" THEN Break = "IdleAtEnd" ELSE @]

-----------------------------------------------------------------------------
(* The healer: Heal.tla's steps, with these kinds' effects *)

\* A resume is claimed only while its main has none in the bound; a group's end needs no more.
Claim(s) ==
    /\ H!Claim(s)
    /\ s \in Mains => resumes[s] < 1 \/ Break = "ResumeTwice"
    /\ resumes' = IF s \in Mains THEN [resumes EXCEPT ![s] = @ + 1] ELSE resumes
    /\ UNCHANGED <<dvars, waits>>

\* A second absence of a main within the bound, with no claim on it: a person's, asked for its
\* bound.
AskAgain(m) ==
    /\ m \in Mains /\ on[m] /\ H!Key(m) \in facts /\ H!Key(m) \notin asked
    /\ ~H!Held(H!Key(m)) /\ resumes[m] >= 1
    /\ asked' = asked \cup {H!Key(m)}
    /\ forBound' = forBound \cup {H!Key(m)}
    /\ UNCHANGED <<on, st, facts, claims, acting, cdone, acted, twice, cut, res, count, mem,
                   allow, dropped, closed, wrong, mine>>

\* The remedy acts under its claim: Heal.tla's Effect. A delegate's group ended (the symptom
\* gone) is its command's end, which starts a turn of Claude Code's own; a main's is its resume.
Act(c, out) ==
    /\ H!Act(c, out) /\ H!Effect(c, out)
    /\ IF c.t \in Delegates /\ on[c.t] /\ ~on'[c.t]
       THEN CommandEnds(c.t)
       ELSE UNCHANGED <<bg, turn, fidle>>
    /\ UNCHANGED <<reports, resumes, waits, msg, joined>>

\* A main's resume finds every usable account limited: its row waits for the reset, and the
\* claim stays acted, its outcome later. Under SettleAtWait it is verified at once.
ActWaits(c) ==
    /\ MayWait /\ c.t \in Mains
    /\ H!Act(c, IF Break = "SettleAtWait" THEN "verified" ELSE "later")
    /\ waits' = waits \cup {[k |-> <<c.t, c.s>>, end |-> "waiting"]}
    /\ UNCHANGED <<on, st, dvars, resumes>>

\* The healer reads a waited resume's end and settles its claim from it.
SettleWait(w) ==
    /\ w \in waits /\ w.end # "waiting"
    /\ \E r \in res : r.k = w.k /\ H!Settled(r, w.end = "resumed")
    /\ UNCHANGED <<on, st, mine>>

Healer ==
    \/ \E s \in Delegates \cup Mains :
          \/ (H!Detect(s) \/ H!Ask(s)) /\ UNCHANGED <<on, st, mine>>
          \/ Claim(s) /\ UNCHANGED <<on, st>>
          \/ AskAgain(s)
    \/ \E c \in acting, out \in H!Outcomes : Act(c, out)
    \/ \E c \in acting : ActWaits(c)
    \/ \E w \in waits : SettleWait(w)
    \/ \E c \in acting : H!LetGo(c) /\ UNCHANGED <<on, st, mine>>
    \/ \E c \in claims : H!SettleCut(c) /\ UNCHANGED <<on, st, mine>>
    \/ \E r \in res : H!Verify(r) /\ UNCHANGED <<on, st, mine>>

-----------------------------------------------------------------------------
(* The delegate *)

\* Its brief's turn starts a background command.
Background(d) ==
    /\ turn[d] = "brief" /\ ~bg[d]
    /\ bg' = [bg EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, turn, reports, resumes, waits, fidle, msg, joined>>

\* The brief's turn ends with its result, whether a command runs or not: the report, taken.
BriefResult(d) ==
    /\ turn[d] = "brief"
    /\ turn' = [turn EXCEPT ![d] = "idle"] /\ reports' = [reports EXCEPT ![d] = @ + 1]
    /\ fidle' = [fidle EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, bg, resumes, waits, msg, joined>>

\* The command ends by itself. Its end starts a turn of Claude Code's own when none runs; a
\* stuck symptom of it goes with it.
TaskEnds(d) ==
    /\ bg[d] /\ turn[d] # "ended"
    /\ IF on[d] THEN H!Goes(d) ELSE UNCHANGED <<on, st, healVars>>
    /\ CommandEnds(d)
    /\ UNCHANGED <<restarts, bounds, reports, resumes, waits, msg, joined>>

\* The turn of its own writes its system/init; the fold reads it running (an init while the
\* turn reads ended clears `idle`, F-184).
OwnInit(d) ==
    /\ turn[d] = "waking"
    /\ turn' = [turn EXCEPT ![d] = "own"] /\ fidle' = [fidle EXCEPT ![d] = FALSE]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, bg, reports, resumes, waits, msg, joined>>

\* The turn of its own ends with a result that names no brief: never the report. Under
\* LastResult the report is read from the latest result, so it is taken again.
OwnResult(d) ==
    /\ turn[d] = "own"
    /\ turn' = [turn EXCEPT ![d] = "idle"] /\ fidle' = [fidle EXCEPT ![d] = TRUE]
    /\ reports' = IF Break = "LastResult" THEN [reports EXCEPT ![d] = @ + 1] ELSE reports
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, bg, resumes, waits, msg, joined>>

\* Stream's `wake:` bound passes with no init read: the fold reads d idle again, and says why.
Unwake(d) ==
    /\ turn[d] = "silent" /\ Break # "NoBound"
    /\ turn' = [turn EXCEPT ![d] = "idle"] /\ fidle' = [fidle EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, bg, reports, resumes, waits, msg, joined>>

\* The parent sends d a message; Mailbox holds it due.
Send(d) ==
    /\ msg[d] = "none" /\ turn[d] # "ended"
    /\ msg' = [msg EXCEPT ![d] = "due"]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, turn, bg, reports, resumes, waits, fidle, joined>>

\* Mailbox hands it on only when the fold reads the turn ended and no command runs
\* (Sessions.Turn's `:ended`); the mark clears `idle`. Into a turn that is still coming or
\* running it joins that turn, whose result would be read as its reply.
Deliver(d) ==
    /\ msg[d] = "due" /\ fidle[d] /\ ~bg[d] /\ turn[d] # "ended"
    /\ msg' = [msg EXCEPT ![d] = "sent"] /\ fidle' = [fidle EXCEPT ![d] = FALSE]
    /\ joined' = [joined EXCEPT ![d] = turn[d] \in {"waking", "own"}]
    /\ turn' = [turn EXCEPT ![d] = IF @ \in {"idle", "silent"} THEN "reply" ELSE @]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, bg, reports, resumes, waits>>

\* The turn the message began ends with its result, the reply.
ReplyResult(d) ==
    /\ turn[d] = "reply"
    /\ turn' = [turn EXCEPT ![d] = "idle"] /\ fidle' = [fidle EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, bg, reports, resumes, waits, msg, joined>>

\* Its stop: only with its report taken and no turn or command running.
End(d) ==
    /\ turn[d] = "idle" /\ ~bg[d] /\ reports[d] >= 1
    /\ turn' = [turn EXCEPT ![d] = "ended"]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, bg, reports, resumes, waits, fidle, msg, joined>>

-----------------------------------------------------------------------------
(* The world *)

\* A delegate's symptom comes only after its report was taken, while its command runs.
Comes(s) ==
    /\ H!Comes(s)
    /\ s \in Delegates => turn[s] = "idle" /\ bg[s] /\ reports[s] >= 1
    /\ UNCHANGED mine

\* The command used CPU time again.
Goes(s) == H!Goes(s) /\ UNCHANGED mine

\* A waiting resume's row ends (Mains, at the reset, or a person's "leave"): resumed, the main
\* runs again, a new state; left or refused, it stays absent. A main at its last state is not
\* resumed here, since no new state is left to number it.
WaitEnd(w, e) ==
    LET m == w.k[1] IN
    /\ w \in waits /\ w.end = "waiting" /\ e \in WaitEnds
    /\ e = "resumed" => ~(on[m] /\ st[m] = MaxState)
    /\ waits' = (waits \ {w}) \cup {[k |-> w.k, end |-> e]}
    /\ IF e = "resumed" /\ on[m]
       THEN on' = [on EXCEPT ![m] = FALSE] /\ st' = [st EXCEPT ![m] = @ + 1]
       ELSE UNCHANGED <<on, st>>
    /\ UNCHANGED <<healVars, restarts, bounds, dvars, resumes>>

Bound ==
    /\ H!Bound
    /\ resumes' = [m \in Mains |-> 0]
    /\ UNCHANGED <<dvars, waits>>

Init ==
    /\ H!Init
    /\ turn = [d \in Delegates |-> "brief"] /\ bg = [d \in Delegates |-> FALSE]
    /\ reports = [d \in Delegates |-> 0]
    /\ resumes = [m \in Mains |-> 0]
    /\ waits = {}
    /\ fidle = [d \in Delegates |-> FALSE]
    /\ msg = [d \in Delegates |-> "none"] /\ joined = [d \in Delegates |-> FALSE]

Next ==
    \/ Healer /\ UNCHANGED <<restarts, bounds>>
    \/ \E s \in Delegates \cup Mains : Comes(s) \/ Goes(s)
    \/ \E w \in waits, e \in WaitEnds : WaitEnd(w, e)
    \/ \E d \in Delegates :
          \/ Background(d) \/ BriefResult(d) \/ TaskEnds(d) \/ OwnInit(d) \/ OwnResult(d)
          \/ Unwake(d) \/ Send(d) \/ Deliver(d) \/ ReplyResult(d) \/ End(d)
    \/ restarts < MaxRestarts /\ H!Restart /\ restarts' = restarts + 1
       /\ UNCHANGED <<on, st, bounds, mine>>
    \/ Bound
    \/ \E k \in asked, widen \in BOOLEAN :
          H!Answer(k, widen) /\ UNCHANGED <<on, st, restarts, bounds, mine>>
    \* A person's "act" on a prompt asked for its bound: their claim, never the healer's resume.
    \/ \E k \in asked : H!AnswerAct(k) /\ UNCHANGED <<on, st, restarts, bounds, mine>>

Fairness ==
    /\ \A s \in Delegates \cup Mains :
          /\ WF_vars(H!Detect(s) /\ UNCHANGED <<on, st, restarts, bounds, mine>>)
          /\ WF_vars((Claim(s) /\ UNCHANGED <<on, st, restarts, bounds>>)
                     \/ (H!Ask(s) /\ UNCHANGED <<on, st, restarts, bounds, mine>>)
                     \/ (AskAgain(s) /\ UNCHANGED <<restarts, bounds>>))
    /\ WF_vars(\E c \in acting, out \in H!Outcomes : Act(c, out) /\ UNCHANGED <<restarts, bounds>>)
    /\ WF_vars(\E c \in acting : H!LetGo(c) /\ UNCHANGED <<on, st, restarts, bounds, mine>>)
    /\ WF_vars(\E c \in claims : H!SettleCut(c) /\ UNCHANGED <<on, st, restarts, bounds, mine>>)
    /\ WF_vars(\E r \in res : H!Verify(r) /\ UNCHANGED <<on, st, restarts, bounds, mine>>)
    /\ \A d \in Delegates :
          /\ WF_vars(BriefResult(d)) /\ WF_vars(OwnInit(d)) /\ WF_vars(OwnResult(d))
          /\ WF_vars(Unwake(d)) /\ WF_vars(ReplyResult(d))
    \* A wait ends (its reset comes), and the healer reads its end.
    /\ WF_vars(\E w \in waits, e \in WaitEnds : WaitEnd(w, e))
    /\ WF_vars(\E w \in waits : SettleWait(w) /\ UNCHANGED <<restarts, bounds>>)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ H!TypeOK
    /\ turn \in [Delegates -> {"brief", "idle", "waking", "own", "silent", "reply", "ended"}]
    /\ bg \in [Delegates -> BOOLEAN]
    /\ fidle \in [Delegates -> BOOLEAN]
    /\ msg \in [Delegates -> {"none", "due", "sent"}]
    /\ joined \in [Delegates -> BOOLEAN]
    /\ reports \in [Delegates -> 0..2]
    /\ resumes \in [Mains -> Nat]
    /\ waits \subseteq [k : Mains \X (0..MaxState), end : {"waiting"} \cup WaitEnds]

\* A waited resume's end reaches the fault ledger: one left or refused is never verified.
WaitedEnd ==
    \A w \in waits : w.end \in {"left", "refused"} =>
        ~\E r \in res : r.k = w.k /\ r.out = "verified"

\* A waited resume's claim is settled from its row's end, once the row ends.
WaitSettled ==
    \A m \in Mains, n \in 0..MaxState :
        (\E r \in res : r.k = <<m, n>> /\ r.out = "later")
            ~> ~\E r \in res : r.k = <<m, n>> /\ r.out = "later"

\* One report per brief across a background command's turn: the brief's result, once.
OneReport == \A d \in Delegates : reports[d] <= 1

\* No partial report: a delegate's symptom is read only once its report was taken, while its
\* command runs and no turn does.
StuckAfterReport ==
    \A d \in Delegates : on[d] => reports[d] = 1 /\ bg[d] /\ turn[d] = "idle"

\* No message is handed on between a background command's end and the end of the turn it
\* begins (F-196's new-6): it waits for that turn's result.
NoMessageIntoOwnTurn == \A d \in Delegates : ~joined[d]

\* The fold reads what Claude Code runs: busy while a turn runs or is still coming.
ReadBusy == \A d \in Delegates : turn[d] \in {"brief", "waking", "own", "reply"} => ~fidle[d]

\* An ended delegate has no command left to wake it.
EndedQuiet == \A d \in Delegates : turn[d] = "ended" => ~bg[d]

\* A main is resumed at most once in a bound; a second absence in it is asked.
ResumeOncePerBound == \A m \in Mains : resumes[m] <= 1

\* The report is never held up by a background command.
ReportTaken == \A d \in Delegates : <>(reports[d] >= 1)

\* A command's end with no turn after it is read idle again: the wait is bounded.
ReadsIdleAgain == \A d \in Delegates : turn[d] = "silent" ~> fidle[d]

\* Heal.tla's, through H.
OncePerState == H!OncePerState
RecordedFirst == H!RecordedFirst
UnknownNotRetried == H!UnknownNotRetried
CapToPrompt == H!CapToPrompt
NarrowsAlone == H!NarrowsAlone
OnlyApproved == H!OnlyApproved
OnlyOnSymptom == H!OnlyOnSymptom
ActedOrAsked == H!ActedOrAsked
ActOnlyForBound == H!ActOnlyForBound
ClaimsEnd == H!ClaimsEnd

=============================================================================
