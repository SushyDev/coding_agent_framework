------------------------------ MODULE Delegate ------------------------------
(***************************************************************************)
(* A parent session, the delegates it starts, and restarts of the         *)
(* framework: the start with its checks, a delegate's finish and its      *)
(* report's path to the parent, a kill resumed once and a second kill     *)
(* reported, and the end of a delegate once its report is delivered.      *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                           *)
(*   Delegates the delegate protocol and its table: each delegate's status, *)
(*             its report (held, sending, delivered) and its resumes, all  *)
(*             durable; the Stop events it has not handled yet and the     *)
(*             sends it has under way, in memory (not built yet);          *)
(*   Parents   whether a parent process runs and whether its turn runs;    *)
(*             a move (Move.tla) is the parent's process ending and a new  *)
(*             one running later (not built yet);                          *)
(*   Sessions  the resume of a killed delegate with --resume (not built);  *)
(*   Control   the checked write that types a report into the parent only  *)
(*             when its process runs and its turn has ended, in the same   *)
(*             step as that check (built in unit 3).                       *)
(*                                                                         *)
(* Left abstract: the screen and the input box (Control's write checks     *)
(* them in one step, as in Agent.tla and Move.tla); the parent's pid,      *)
(* account and transcript copy (Move.tla); the start's account, worktree,  *)
(* setup and dtach steps, which are one step here, so a restart in the     *)
(* middle of a start is not modeled; the text of a report; the delegate's  *)
(* subagents and tokens; messages to a delegate (Team.tla). A delegate     *)
(* takes one brief and finishes once. The report enters the parent's       *)
(* transcript in the step it is typed, and the framework reads the         *)
(* parent's transcript exactly.                                            *)
(*                                                                         *)
(* Fairness: the framework's steps happen while they stay possible; the    *)
(* parent runs again after it stops and its turns end. A report is typed   *)
(* when the parent's turn has ended, which the user's prompts may keep     *)
(* taking away, so the ask and the typed send are strongly fair: a send    *)
(* possible again and again happens.                                       *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Delegate_<value>.cfg that TLC must fail.                    *)
(*                                                                         *)
(* Defense in depth, with no Break: StopHandled's check that the row still *)
(* says "running", and TranscriptRead's wait for no held Stop event. Each  *)
(* alone keeps a Stop event and the fallback from giving two reports; with *)
(* both removed, a late Stop event revives an ended delegate.              *)
(* The wait in DeliveryAsked for a parent whose turn has ended is not a    *)
(* safety guard (Control's check in DeliveryTyped is), but the liveness    *)
(* needs it: without it a prompt can take every turn the ask waited for.   *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Delegates,       \* the delegates the parent may start
    Cap,             \* delegates of the parent at once, not yet ended
    MaxRestarts,     \* restarts of the framework
    MaxKills,        \* kills of delegate processes
    MaxParentStops,  \* times the parent's process ends: a move, or an exit
    Break            \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "RedeliverAfterRestart", \* a send cut off by a restart is sent again without reading the parent's transcript
    "IntoRunningTurn",       \* the report is typed without checking that the parent's turn has ended
    "NoParentCheck",         \* the report is typed without checking that a parent process runs
    "EndBeforeDelivery",     \* a finished delegate is ended before its report is delivered
    "ResumeAgain",           \* every kill is resumed, the second too
    "HeldInMemory",          \* a held report is kept in memory, not in the table
    "NoTranscriptFallback",  \* a lost Stop event is not replaced by the transcript's last reply
    "NoCap"                  \* a start does not check the cap
}

ASSUME Break \in Breaks
ASSUME Cap \in Nat /\ MaxRestarts \in Nat /\ MaxKills \in Nat /\ MaxParentStops \in Nat

VARIABLES
    up,           \* the framework runs
    restarts,     \* restarts so far
    parentRuns,   \* a parent process runs
    turn,         \* the parent's turn runs
    parentStops,  \* the parent's process ended so far
    status,       \* table: d -> "none", "refused", "running", "finished", "failed", "ended"
    report,       \* table: d -> "none", "held", "sending", "delivered"
    resumes,      \* table: d -> resumes so far
    proc,         \* d -> the delegate's process: "none", "working", "idle", "dead"
    reply,        \* d -> the delegate's transcript ends with its last reply
    kills,        \* kills so far
    stops,        \* in memory: delegates whose Stop event Intake holds, not yet handled
    sending,      \* in memory: d -> "none", "asked" (row written), "sent" (typed, row not marked)
    got,          \* d -> times the report is in the parent's transcript
    wrong         \* reports typed where Control's check must refuse them: [d, why]

parentVars == <<parentRuns, turn, parentStops>>
delegateVars == <<status, report, resumes, proc, reply, kills>>
vars == <<up, restarts, parentVars, delegateVars, stops, sending, got, wrong>>

\* Delegates that count against the cap: started and not yet ended.
Active == {d \in Delegates : status[d] \in {"running", "finished", "failed"}}

-----------------------------------------------------------------------------
Init ==
    /\ up = TRUE /\ restarts = 0
    /\ parentRuns = TRUE /\ turn = FALSE /\ parentStops = 0
    /\ status = [d \in Delegates |-> "none"]
    /\ report = [d \in Delegates |-> "none"]
    /\ resumes = [d \in Delegates |-> 0]
    /\ proc = [d \in Delegates |-> "none"]
    /\ reply = [d \in Delegates |-> FALSE]
    /\ kills = 0
    /\ stops = {}
    /\ sending = [d \in Delegates |-> "none"]
    /\ got = [d \in Delegates |-> 0]
    /\ wrong = {}

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; what it holds in memory does not *)

\* Under HeldInMemory the held reports go with it.
FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ stops' = {}
    /\ sending' = [d \in Delegates |-> "none"]
    /\ report' = IF Break = "HeldInMemory"
                   THEN [d \in Delegates |-> IF report[d] = "held" THEN "none" ELSE report[d]]
                   ELSE report
    /\ UNCHANGED <<parentVars, status, resumes, proc, reply, kills, got, wrong>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<restarts, parentVars, delegateVars, stops, sending, got, wrong>>

-----------------------------------------------------------------------------
(* The parent: its turns, and its process ending and running again (a move) *)

PromptSent ==
    /\ parentRuns /\ ~turn /\ turn' = TRUE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, sending, got, wrong>>

TurnEnds ==
    /\ turn /\ turn' = FALSE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, sending, got, wrong>>

ParentStops ==
    /\ parentRuns /\ parentStops < MaxParentStops
    /\ parentRuns' = FALSE /\ turn' = FALSE /\ parentStops' = parentStops + 1
    /\ UNCHANGED <<up, restarts, delegateVars, stops, sending, got, wrong>>

ParentRuns ==
    /\ ~parentRuns /\ parentRuns' = TRUE
    /\ UNCHANGED <<up, restarts, turn, parentStops, delegateVars, stops, sending, got, wrong>>

-----------------------------------------------------------------------------
(* A delegate's start and its own process *)

\* In a turn the parent calls start_delegate. The project, branch and
\* worktree checks may refuse it, and the cap must when it is reached.
StartAsked(d) ==
    /\ up /\ parentRuns /\ turn /\ status[d] = "none"
    /\ \/ /\ status' = [status EXCEPT ![d] = "refused"]
          /\ UNCHANGED proc
       \/ /\ Cardinality(Active) < Cap \/ Break = "NoCap"
          /\ status' = [status EXCEPT ![d] = "running"]
          /\ proc' = [proc EXCEPT ![d] = "working"]
    /\ UNCHANGED <<up, restarts, parentVars, report, resumes, reply, kills, stops, sending,
                   got, wrong>>

\* Its turn ends with its last reply, and its Stop hook fires. With the
\* framework down the hook reaches nothing, and the event is lost.
DelegateFinishes(d) ==
    /\ proc[d] = "working"
    /\ proc' = [proc EXCEPT ![d] = "idle"]
    /\ reply' = [reply EXCEPT ![d] = TRUE]
    /\ stops' = IF up THEN stops \cup {d} ELSE stops
    /\ UNCHANGED <<up, restarts, parentVars, status, report, resumes, kills, sending, got, wrong>>

DelegateKilled(d) ==
    /\ proc[d] \in {"working", "idle"} /\ kills < MaxKills
    /\ proc' = [proc EXCEPT ![d] = "dead"]
    /\ kills' = kills + 1
    /\ UNCHANGED <<up, restarts, parentVars, status, report, resumes, reply, stops, sending,
                   got, wrong>>

-----------------------------------------------------------------------------
(* Delegates: from a finish or a kill to a held report *)

\* The Stop event holds the last message. Only a running delegate's row
\* changes, so the event and the transcript fallback give one report.
StopHandled(d) ==
    /\ up /\ d \in stops
    /\ stops' = stops \ {d}
    /\ IF status[d] = "running"
         THEN /\ status' = [status EXCEPT ![d] = "finished"]
              /\ report' = [report EXCEPT ![d] = "held"]
         ELSE UNCHANGED <<status, report>>
    /\ UNCHANGED <<restarts, parentVars, resumes, proc, reply, kills, up, sending, got, wrong>>

\* A restart lost the Stop event: the transcript's last reply is the report.
TranscriptRead(d) ==
    /\ up /\ Break # "NoTranscriptFallback"
    /\ status[d] = "running" /\ reply[d] /\ d \notin stops
    /\ status' = [status EXCEPT ![d] = "finished"]
    /\ report' = [report EXCEPT ![d] = "held"]
    /\ UNCHANGED <<up, restarts, parentVars, resumes, proc, reply, kills, stops, sending,
                   got, wrong>>

\* A process killed before its last reply is resumed once; a second kill
\* is the report.
KillSeen(d) ==
    /\ up /\ status[d] = "running" /\ proc[d] = "dead" /\ ~reply[d]
    /\ IF resumes[d] = 0 \/ Break = "ResumeAgain"
         THEN /\ proc' = [proc EXCEPT ![d] = "working"]
              /\ resumes' = [resumes EXCEPT ![d] = @ + 1]
              /\ UNCHANGED <<status, report>>
         ELSE /\ status' = [status EXCEPT ![d] = "failed"]
              /\ report' = [report EXCEPT ![d] = "held"]
              /\ UNCHANGED <<proc, resumes>>
    /\ UNCHANGED <<up, restarts, parentVars, reply, kills, stops, sending, got, wrong>>

-----------------------------------------------------------------------------
(* Delegates and Control: from a held report into the parent, once *)

\* Once the parent's turn has ended, the row says "sending" before the write.
DeliveryAsked(d) ==
    /\ up /\ report[d] = "held" /\ sending[d] = "none"
    /\ parentRuns /\ ~turn
    /\ report' = [report EXCEPT ![d] = "sending"]
    /\ sending' = [sending EXCEPT ![d] = "asked"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   got, wrong>>

Typeable == /\ parentRuns \/ Break = "NoParentCheck"
            /\ ~turn \/ Break = "IntoRunningTurn"

\* Control's checked write: a running parent process whose turn has ended
\* takes the report as a new turn. A report typed with no parent process is
\* lost.
DeliveryTyped(d) ==
    /\ up /\ sending[d] = "asked" /\ Typeable
    /\ sending' = [sending EXCEPT ![d] = "sent"]
    /\ got' = IF parentRuns THEN [got EXCEPT ![d] = @ + 1] ELSE got
    /\ turn' = parentRuns
    /\ wrong' = wrong \cup (IF parentRuns THEN {} ELSE {[d |-> d, why |-> "no parent"]})
                      \cup (IF turn THEN {[d |-> d, why |-> "running turn"]} ELSE {})
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops>>

\* The check refused it: the report is held again.
DeliveryRefused(d) ==
    /\ up /\ sending[d] = "asked" /\ ~Typeable
    /\ sending' = [sending EXCEPT ![d] = "none"]
    /\ report' = [report EXCEPT ![d] = "held"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   got, wrong>>

DeliveryMarked(d) ==
    /\ up /\ sending[d] = "sent"
    /\ sending' = [sending EXCEPT ![d] = "none"]
    /\ report' = [report EXCEPT ![d] = "delivered"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   got, wrong>>

\* A restart cut off a send: whether it was typed is read from the parent's
\* transcript, never guessed. Under RedeliverAfterRestart it is sent again.
SendingResolved(d) ==
    /\ up /\ report[d] = "sending" /\ sending[d] = "none"
    /\ report' = [report EXCEPT ![d] = IF got[d] > 0 /\ Break # "RedeliverAfterRestart"
                                         THEN "delivered" ELSE "held"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   sending, got, wrong>>

\* The delegate ends, its process with it, only once its report is delivered.
DelegateEnds(d) ==
    /\ up /\ status[d] \in {"finished", "failed"}
    /\ report[d] = "delivered" \/ Break = "EndBeforeDelivery"
    /\ status' = [status EXCEPT ![d] = "ended"]
    /\ proc' = [proc EXCEPT ![d] = "none"]
    /\ UNCHANGED <<up, restarts, parentVars, report, resumes, reply, kills, stops, sending,
                   got, wrong>>

-----------------------------------------------------------------------------
Framework(d) ==
    \/ StopHandled(d) \/ TranscriptRead(d) \/ KillSeen(d) \/ DeliveryAsked(d)
    \/ DeliveryTyped(d) \/ DeliveryRefused(d) \/ DeliveryMarked(d) \/ SendingResolved(d)
    \/ DelegateEnds(d)

Next ==
    \/ FrameworkDies \/ FrameworkStarts
    \/ PromptSent \/ TurnEnds \/ ParentStops \/ ParentRuns
    \/ \E d \in Delegates : StartAsked(d) \/ DelegateFinishes(d) \/ DelegateKilled(d)
                            \/ Framework(d)

Fairness ==
    /\ WF_vars(FrameworkStarts) /\ WF_vars(ParentRuns) /\ WF_vars(TurnEnds)
    /\ \A d \in Delegates :
         /\ WF_vars(StopHandled(d)) /\ WF_vars(TranscriptRead(d)) /\ WF_vars(KillSeen(d))
         /\ SF_vars(DeliveryAsked(d)) /\ SF_vars(DeliveryTyped(d))
         /\ WF_vars(DeliveryTyped(d) \/ DeliveryRefused(d))
         /\ WF_vars(DeliveryMarked(d)) /\ WF_vars(SendingResolved(d))
         /\ WF_vars(DelegateEnds(d))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ up \in BOOLEAN /\ parentRuns \in BOOLEAN /\ turn \in BOOLEAN
    /\ status \in [Delegates -> {"none", "refused", "running", "finished", "failed", "ended"}]
    /\ report \in [Delegates -> {"none", "held", "sending", "delivered"}]
    /\ proc \in [Delegates -> {"none", "working", "idle", "dead"}]
    /\ sending \in [Delegates -> {"none", "asked", "sent"}]
    /\ stops \subseteq Delegates
    /\ turn => parentRuns

\* Each report is in the parent's transcript at most once.
DeliveredAtMostOnce == \A d \in Delegates : got[d] <= 1

\* Only into a running parent process whose turn has ended.
OnlyIntoEndedTurn == wrong = {}

\* A delegate ends only after its report is delivered.
EndsAfterDelivery == \A d \in Delegates : status[d] = "ended" => report[d] = "delivered"

\* A finished or failed delegate's report is never dropped, by a restart
\* or otherwise.
ReportKept ==
    \A d \in Delegates : status[d] \in {"finished", "failed", "ended"} => report[d] # "none"

\* A killed delegate is resumed at most once, and a second kill is reported,
\* not retried.
ResumedAtMostOnce == \A d \in Delegates : resumes[d] <= 1
SecondKillNotRetried ==
    \A d \in Delegates : status[d] = "failed" => resumes[d] = 1 /\ proc[d] = "dead"

CapHeld == Cardinality(Active) <= Cap

\* Every finished delegate's report arrives in the parent, and a second
\* kill's report too.
ReportArrives ==
    \A d \in Delegates : (reply[d] \/ status[d] = "failed") ~> got[d] = 1

\* A delegate whose report is delivered ends.
DeliveredDelegateEnds ==
    \A d \in Delegates : report[d] = "delivered" ~> status[d] = "ended"

=============================================================================
