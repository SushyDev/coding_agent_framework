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
(* StuckBackgrounds (the `stuck_background` entry), and the report         *)
(* CodingAgentFramework.Delegates takes from CodingAgentFramework.Stream.  *)
(* Fold across a background command's turn.                                *)
(*                                                                         *)
(*   a delegate d      its brief's turn may start a background command;    *)
(*                     the turn's result comes while the command runs,     *)
(*                     and is the report (measured on Claude Code          *)
(*                     2.1.322, F-184). The command's end starts a turn of *)
(*                     Claude Code's own, whose result is never a second   *)
(*                     report (OneReport). d ends only with no turn and no *)
(*                     command running (Sessions.stop's turn_running).     *)
(*   stuck_background  d's report was taken while its background command   *)
(*                     runs and uses no CPU time. Its remedy ends the      *)
(*                     command's group by its record, which may help or    *)
(*                     not; no partial report goes (StuckAfterReport: the  *)
(*                     report was taken before the symptom).               *)
(*   absent_main       a declared main session m whose process is gone.    *)
(*                     Its remedy is one resume; once per absence (H's     *)
(*                     OncePerState), and a second absence of m within a   *)
(*                     bound is asked, not resumed (ResumeOncePerBound,    *)
(*                     then H's ActedOrAsked).                             *)
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
    Break

Breaks == {
    "none",
    "LastResult",   \* the report is read from the latest result, not the brief's own
    "ResumeTwice"   \* a second absence of a main within the bound is resumed again
}

ASSUME Break \in Breaks /\ Delegates \cap Mains = {}

Kind(s) == IF s \in Delegates THEN "stuck_background" ELSE "absent_main"

VARIABLES
    on, st, facts, claims, acting, cdone, acted, twice, cut, res, count, mem, allow,
    dropped, asked, closed, wrong, restarts, bounds,  \* Heal.tla's
    turn,      \* d -> "brief" (its brief's turn runs), "idle", "own" (a turn of its own), "ended"
    bg,        \* d -> a background command of d runs
    reports,   \* d -> the reports taken as the brief's reply
    resumes    \* m -> the resumes of m claimed in the bound: a fold of the rows (durable)

healVars == <<facts, claims, acting, cdone, acted, twice, cut, res, count, mem, allow,
              dropped, asked, closed, wrong>>
dvars == <<turn, bg, reports>>
mine == <<turn, bg, reports, resumes>>
vars == <<on, st, healVars, restarts, bounds, mine>>

H == INSTANCE Heal WITH Symptoms <- Delegates \cup Mains,
                        Kinds <- {"stuck_background", "absent_main"}, Kind <- Kind,
                        Approved <- {"stuck_background", "absent_main"},
                        Actors <- {"healer"}, Break <- "none"

-----------------------------------------------------------------------------
(* The healer: Heal.tla's steps, with these kinds' effects *)

\* A resume is claimed only while its main has none in the bound; a group's end needs no more.
Claim(s) ==
    /\ H!Claim(s)
    /\ s \in Mains => resumes[s] < 1 \/ Break = "ResumeTwice"
    /\ resumes' = IF s \in Mains THEN [resumes EXCEPT ![s] = @ + 1] ELSE resumes
    /\ UNCHANGED dvars

\* A second absence of a main within the bound, with no claim on it: a person's.
AskAgain(m) ==
    /\ m \in Mains /\ on[m] /\ H!Key(m) \in facts /\ H!Key(m) \notin asked
    /\ ~H!Held(H!Key(m)) /\ resumes[m] >= 1
    /\ asked' = asked \cup {H!Key(m)}
    /\ UNCHANGED <<on, st, facts, claims, acting, cdone, acted, twice, cut, res, count, mem,
                   allow, dropped, closed, wrong, mine>>

\* The remedy acts under its claim: Heal.tla's Effect. A delegate's group ended (the symptom
\* gone) is its command's end, which starts a turn of Claude Code's own; a main's is its resume.
Act(c, out) ==
    /\ H!Act(c, out) /\ H!Effect(c, out)
    /\ IF c.t \in Delegates /\ on[c.t] /\ ~on'[c.t]
       THEN bg' = [bg EXCEPT ![c.t] = FALSE] /\ turn' = [turn EXCEPT ![c.t] = "own"]
       ELSE UNCHANGED <<bg, turn>>
    /\ UNCHANGED <<reports, resumes>>

Healer ==
    \/ \E s \in Delegates \cup Mains :
          \/ (H!Detect(s) \/ H!Ask(s)) /\ UNCHANGED <<on, st, mine>>
          \/ Claim(s) /\ UNCHANGED <<on, st>>
          \/ AskAgain(s)
    \/ \E c \in acting, out \in H!Outcomes : Act(c, out)
    \/ \E c \in acting : H!LetGo(c) /\ UNCHANGED <<on, st, mine>>
    \/ \E c \in claims : H!SettleCut(c) /\ UNCHANGED <<on, st, mine>>
    \/ \E r \in res : H!Verify(r) /\ UNCHANGED <<on, st, mine>>

-----------------------------------------------------------------------------
(* The delegate *)

\* Its brief's turn starts a background command.
Background(d) ==
    /\ turn[d] = "brief" /\ ~bg[d]
    /\ bg' = [bg EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, turn, reports, resumes>>

\* The brief's turn ends with its result, whether a command runs or not: the report, taken.
BriefResult(d) ==
    /\ turn[d] = "brief"
    /\ turn' = [turn EXCEPT ![d] = "idle"] /\ reports' = [reports EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, bg, resumes>>

\* The command ends by itself. Its end starts a turn of Claude Code's own when none runs; a
\* stuck symptom of it goes with it.
TaskEnds(d) ==
    /\ bg[d] /\ turn[d] # "ended"
    /\ IF on[d] THEN H!Goes(d) ELSE UNCHANGED <<on, st, healVars>>
    /\ bg' = [bg EXCEPT ![d] = FALSE]
    /\ turn' = [turn EXCEPT ![d] = IF @ = "idle" THEN "own" ELSE @]
    /\ UNCHANGED <<restarts, bounds, reports, resumes>>

\* The turn of its own ends with a result that names no brief: never the report. Under
\* LastResult the report is read from the latest result, so it is taken again.
OwnResult(d) ==
    /\ turn[d] = "own"
    /\ turn' = [turn EXCEPT ![d] = "idle"]
    /\ reports' = IF Break = "LastResult" THEN [reports EXCEPT ![d] = @ + 1] ELSE reports
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, bg, resumes>>

\* Its stop: only with its report taken and no turn or command running.
End(d) ==
    /\ turn[d] = "idle" /\ ~bg[d] /\ reports[d] >= 1
    /\ turn' = [turn EXCEPT ![d] = "ended"]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, bg, reports, resumes>>

-----------------------------------------------------------------------------
(* The world *)

\* A delegate's symptom comes only after its report was taken, while its command runs.
Comes(s) ==
    /\ H!Comes(s)
    /\ s \in Delegates => turn[s] = "idle" /\ bg[s] /\ reports[s] >= 1
    /\ UNCHANGED mine

\* The command used CPU time again.
Goes(s) == H!Goes(s) /\ UNCHANGED mine

Bound ==
    /\ H!Bound
    /\ resumes' = [m \in Mains |-> 0]
    /\ UNCHANGED dvars

Init ==
    /\ H!Init
    /\ turn = [d \in Delegates |-> "brief"] /\ bg = [d \in Delegates |-> FALSE]
    /\ reports = [d \in Delegates |-> 0]
    /\ resumes = [m \in Mains |-> 0]

Next ==
    \/ Healer /\ UNCHANGED <<restarts, bounds>>
    \/ \E s \in Delegates \cup Mains : Comes(s) \/ Goes(s)
    \/ \E d \in Delegates : Background(d) \/ BriefResult(d) \/ TaskEnds(d) \/ OwnResult(d) \/ End(d)
    \/ restarts < MaxRestarts /\ H!Restart /\ restarts' = restarts + 1
       /\ UNCHANGED <<on, st, bounds, mine>>
    \/ Bound
    \/ \E k \in asked, widen \in BOOLEAN :
          H!Answer(k, widen) /\ UNCHANGED <<on, st, restarts, bounds, mine>>

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
    /\ \A d \in Delegates : WF_vars(BriefResult(d)) /\ WF_vars(OwnResult(d))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ H!TypeOK
    /\ turn \in [Delegates -> {"brief", "idle", "own", "ended"}]
    /\ bg \in [Delegates -> BOOLEAN]
    /\ reports \in [Delegates -> 0..2]
    /\ resumes \in [Mains -> Nat]

\* One report per brief across a background command's turn: the brief's result, once.
OneReport == \A d \in Delegates : reports[d] <= 1

\* No partial report: a delegate's symptom is read only once its report was taken, while its
\* command runs and no turn does.
StuckAfterReport ==
    \A d \in Delegates : on[d] => reports[d] = 1 /\ bg[d] /\ turn[d] = "idle"

\* An ended delegate has no command left to wake it.
EndedQuiet == \A d \in Delegates : turn[d] = "ended" => ~bg[d]

\* A main is resumed at most once in a bound; a second absence in it is asked.
ResumeOncePerBound == \A m \in Mains : resumes[m] <= 1

\* The report is never held up by a background command.
ReportTaken == \A d \in Delegates : <>(reports[d] >= 1)

\* Heal.tla's, through H.
OncePerState == H!OncePerState
RecordedFirst == H!RecordedFirst
UnknownNotRetried == H!UnknownNotRetried
CapToPrompt == H!CapToPrompt
NarrowsAlone == H!NarrowsAlone
OnlyApproved == H!OnlyApproved
OnlyOnSymptom == H!OnlyOnSymptom
ActedOrAsked == H!ActedOrAsked
ClaimsEnd == H!ClaimsEnd

=============================================================================
