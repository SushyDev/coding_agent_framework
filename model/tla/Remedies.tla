------------------------------ MODULE Remedies ------------------------------
(***************************************************************************)
(* The first remedies on the healer's one shape (F-183; docs/design.md,   *)
(* "Metrics and healing", "One shape for every remedy"; "The delegate     *)
(* protocol", a `partial` report): Heal.tla instanced as H with two kinds  *)
(* beside Boxes.tla's stuck turn.                                          *)
(*                                                                         *)
(* Models CodingAgentFramework.AbsentMains (the `absent_main` entry of     *)
(* CodingAgentFramework.Watch's allow-list, its detector and its resume    *)
(* through CodingAgentFramework.Mains), and, ahead of its code (F-183's    *)
(* new-1), the `stuck_background` entry with the `partial` report's row in *)
(* CodingAgentFramework.Mailbox.                                           *)
(*                                                                         *)
(*   stuck_background  a delegate d whose turn ended with its report owed  *)
(*                     while a background command of it hangs. Its remedy  *)
(*                     hands the parent d's last reply as a `partial`      *)
(*                     report, under the remedy's claim, and ends the hung *)
(*                     command's group by its record, which may help or    *)
(*                     not. d's own report is still owed: when d writes    *)
(*                     it, the parent takes it, whatever partial went      *)
(*                     before (ReportTaken), and a state's partial goes    *)
(*                     once (PartialOnce).                                 *)
(*   absent_main       a declared main session m whose process is gone.    *)
(*                     Its remedy is one resume; once per absence (H's     *)
(*                     OncePerState), and a second absence of m within a   *)
(*                     bound is asked, not resumed (ResumeOncePerBound,    *)
(*                     then H's ActedOrAsked).                             *)
(*                                                                         *)
(* Every property of Heal.tla is checked through H. Left abstract: how the *)
(* reply is read, the process tree's CPU time, the Scheduler's lease of    *)
(* the resume, and Mailbox's own delivery (Delivery.tla).                  *)
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
    "PartialStands",  \* a partial report takes the brief's reply: d's own report is not taken
    "PartialTwice",   \* the partial is handed at each read of the state, not under the claim
    "ResumeTwice"     \* a second absence of a main within the bound is resumed again
}

ASSUME Break \in Breaks /\ Delegates \cap Mains = {}

Kind(s) == IF s \in Delegates THEN "stuck_background" ELSE "absent_main"

VARIABLES
    on, st, facts, claims, acting, cdone, acted, twice, cut, res, count, mem, allow,
    dropped, asked, closed, wrong, restarts, bounds,  \* Heal.tla's
    hands,     \* <<d, n>> -> the partial reports handed for d's state n (Mailbox's row)
    made,      \* d -> d wrote its own report, the brief's reply
    took,      \* d -> its parent took that report
    resumes    \* m -> the resumes of m claimed in the bound: a fold of the rows (durable)

healVars == <<facts, claims, acting, cdone, acted, twice, cut, res, count, mem, allow,
              dropped, asked, closed, wrong>>
mine == <<hands, made, took, resumes>>
vars == <<on, st, healVars, restarts, bounds, mine>>

H == INSTANCE Heal WITH Symptoms <- Delegates \cup Mains,
                        Kinds <- {"stuck_background", "absent_main"}, Kind <- Kind,
                        Approved <- {"stuck_background", "absent_main"},
                        Actors <- {"healer"}, Break <- "none"

States == (Delegates \cup Mains) \X (0..MaxState)

-----------------------------------------------------------------------------
(* The healer: Heal.tla's steps, with these kinds' effects *)

\* A resume is claimed only while its main has none in the bound; a partial needs no more.
Claim(s) ==
    /\ H!Claim(s)
    /\ s \in Mains => resumes[s] < 1 \/ Break = "ResumeTwice"
    /\ resumes' = IF s \in Mains THEN [resumes EXCEPT ![s] = @ + 1] ELSE resumes
    /\ UNCHANGED <<hands, made, took>>

\* A second absence of a main within the bound, with no claim on it: a person's.
AskAgain(m) ==
    /\ m \in Mains /\ on[m] /\ H!Key(m) \in facts /\ H!Key(m) \notin asked
    /\ ~H!Held(H!Key(m)) /\ resumes[m] >= 1
    /\ asked' = asked \cup {H!Key(m)}
    /\ UNCHANGED <<on, st, facts, claims, acting, cdone, acted, twice, cut, res, count, mem,
                   allow, dropped, closed, wrong, mine>>

\* The remedy acts under its claim. A delegate's: the partial report handed (unless the hand
\* was refused) and the hung group ended, which may end the symptom; a main's: the resume,
\* which may bring it back. Either is Heal.tla's Effect.
Act(c, out) ==
    /\ H!Act(c, out) /\ H!Effect(c, out)
    /\ hands' = IF c.t \in Delegates /\ out # "refused"
                THEN [hands EXCEPT ![<<c.t, c.s>>] = @ + 1] ELSE hands
    /\ UNCHANGED <<made, took, resumes>>

\* Under PartialTwice the detector hands the partial at each read of a recorded state.
HandOnRead(d) ==
    /\ Break = "PartialTwice" /\ d \in Delegates /\ on[d] /\ H!Key(d) \in facts
    /\ hands[H!Key(d)] < 2
    /\ hands' = [hands EXCEPT ![H!Key(d)] = @ + 1]
    /\ UNCHANGED <<on, st, healVars, made, took, resumes>>

Healer ==
    \/ \E s \in Delegates \cup Mains :
          \/ (H!Detect(s) \/ H!Ask(s)) /\ UNCHANGED <<on, st, mine>>
          \/ Claim(s) /\ UNCHANGED <<on, st>>
          \/ AskAgain(s)
          \/ HandOnRead(s)
    \/ \E c \in acting, out \in H!Outcomes : Act(c, out)
    \/ \E c \in acting : H!LetGo(c) /\ UNCHANGED <<on, st, mine>>
    \/ \E c \in claims : H!SettleCut(c) /\ UNCHANGED <<on, st, mine>>
    \/ \E r \in res : H!Verify(r) /\ UNCHANGED <<on, st, mine>>

-----------------------------------------------------------------------------
(* The world *)

\* A delegate's symptom comes only while its report is owed.
Comes(s) == H!Comes(s) /\ (s \in Delegates => ~made[s]) /\ UNCHANGED mine
Goes(s) == H!Goes(s) /\ UNCHANGED mine

\* The delegate writes its own report once its background command is done (no symptom).
Write(d) ==
    /\ ~on[d] /\ ~made[d]
    /\ made' = [made EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, hands, took, resumes>>

\* The parent takes d's own report, as the brief's reply. Under PartialStands a partial
\* handed before has taken that place.
Take(d) ==
    /\ made[d] /\ ~took[d]
    /\ Break = "PartialStands" => \A n \in 0..MaxState : hands[<<d, n>>] = 0
    /\ took' = [took EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<on, st, healVars, restarts, bounds, hands, made, resumes>>

Bound ==
    /\ H!Bound
    /\ resumes' = [m \in Mains |-> 0]
    /\ UNCHANGED <<hands, made, took>>

Init ==
    /\ H!Init
    /\ hands = [k \in States |-> 0]
    /\ made = [d \in Delegates |-> FALSE] /\ took = [d \in Delegates |-> FALSE]
    /\ resumes = [m \in Mains |-> 0]

Next ==
    \/ Healer /\ UNCHANGED <<restarts, bounds>>
    \/ \E s \in Delegates \cup Mains : Comes(s) \/ Goes(s)
    \/ \E d \in Delegates : Write(d) \/ Take(d)
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
    /\ \A d \in Delegates : WF_vars(Take(d))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ H!TypeOK
    /\ hands \in [States -> 0..2]
    /\ made \in [Delegates -> BOOLEAN] /\ took \in [Delegates -> BOOLEAN]
    /\ resumes \in [Mains -> Nat]

\* A delegate's state gets one partial report at most: the hand is the remedy's act, once.
PartialOnce == \A k \in States : hands[k] <= 1

\* A main is resumed at most once in a bound; a second absence in it is asked.
ResumeOncePerBound == \A m \in Mains : resumes[m] <= 1

\* A partial never stands in for the report: d's own report, once written, is taken.
ReportTaken == \A d \in Delegates : made[d] ~> took[d]

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
