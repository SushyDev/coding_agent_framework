------------------------------ MODULE Delegate ------------------------------
(***************************************************************************)
(* A parent session, the delegates it starts, and restarts of the         *)
(* framework: the start with its checks and its row written first, the    *)
(* brief, a delegate's finish and its report's path to the parent, a kill *)
(* resumed once and a second kill reported, and the end of a delegate     *)
(* once its report is delivered.                                          *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                           *)
(*   Delegates the delegate protocol and its table: each delegate's status, *)
(*             its report (held, sending, delivered) and its resumes, all  *)
(*             durable; its calls of Sessions under way, the Stop events   *)
(*             it has not handled yet and the sends it has under way, in   *)
(*             memory (F-60 and F-62 built it up to a held report; the     *)
(*             delivery and the end are not built yet);                    *)
(*   Parents   whether a parent process runs and whether its turn runs;    *)
(*             a move (Move.tla) is the parent's process ending and a new  *)
(*             one running later (not built yet);                          *)
(*   Sessions  the start and the resume of a delegate, which write their   *)
(*             own row first and run on through a restart of Delegates     *)
(*             (Start.tla models them);                                    *)
(*   Stream    the turn's message (the brief, or what a resumed process    *)
(*             takes), marked in its table under the uuid Delegates chose  *)
(*             and wrote in its row first, and refused a second time       *)
(*             under that uuid (Stream.tla models it);                     *)
(*   Control   the checked write that types a report into the parent only  *)
(*             when its process runs and its turn has ended, in the same   *)
(*             step as that check (built in unit 3).                       *)
(*                                                                         *)
(* Left abstract: the screen and the input box (Control's write checks     *)
(* them in one step, as in Agent.tla and Move.tla); the parent's pid,      *)
(* account and transcript copy (Move.tla); the start's account, worktree,  *)
(* setup and dtach steps (Start.tla); the deadline a starting row waits    *)
(* for before it is refused with no Sessions row of its call: the call     *)
(* and Sessions' own row are one step here; the text of a report; the     *)
(* delegate's subagents and tokens; messages to a delegate (Team.tla). A  *)
(* delegate takes one turn's message per process and finishes once. The   *)
(* Stop event stands for the result in the delegate's event log, which a  *)
(* kill before its line is written loses. The report enters the parent's  *)
(* transcript in the step it is typed, and the framework reads the        *)
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
(* KillSeen's and InputWritten's checks that no call of Sessions is under *)
(* way: in the design a row with a call under way says starting or        *)
(* resuming, which their checks for "running" refuse; ResumeBeforeRow      *)
(* needs KillSeen's, to ask the resume once.                              *)
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
    "NoCap",                 \* a start does not check the cap
    "CapSkipsStarting",      \* the cap counts no start still under way
    "SettleEarly",           \* after a restart, a row is settled while Sessions' call still runs
    "ResumeBeforeRow",       \* the resume is asked before the row counts it
    "NewUuid"                \* the turn's message is written again under a new uuid
}

ASSUME Break \in Breaks
ASSUME Cap \in Nat /\ MaxRestarts \in Nat /\ MaxKills \in Nat /\ MaxParentStops \in Nat

VARIABLES
    up,           \* the framework runs
    restarts,     \* restarts so far
    parentRuns,   \* a parent process runs
    turn,         \* the parent's turn runs
    parentStops,  \* the parent's process ended so far
    status,       \* table: d -> "none", "refused", "starting", "running", "resuming",
                  \*          "finished", "failed", "ended"
    report,       \* table: d -> "none", "held", "sending", "delivered"
    resumes,      \* table: d -> resumes so far
    proc,         \* d -> the delegate's process: "none", "waiting" (held, no message taken),
                  \*      "working", "idle" (after its last reply), "dead"
    reply,        \* d -> the delegate's transcript ends with its last reply
    kills,        \* kills so far
    stops,        \* in memory: delegates whose Stop event Intake holds, not yet handled
    sending,      \* in memory: d -> "none", "asked" (row written), "sent" (typed, row not marked)
    got,          \* d -> times the report is in the parent's transcript
    wrong,        \* reports typed where Control's check must refuse them: [d, why]
    call,         \* in memory: d -> "none", "start", "resume": Delegates' call of Sessions
    sess,         \* Sessions: d -> its row of the latest call: "none", "start" or "resume"
                  \*           (written, under way), "running", "refused"
    marked,       \* Stream's table: d -> the turn's message is marked under the row's uuid
    pipe,         \* d -> message lines in the current process's FIFO, not yet taken
    taken,        \* d -> turn messages the delegate's processes took
    resumed       \* d -> resumes Sessions made

parentVars == <<parentRuns, turn, parentStops>>
delegateVars == <<status, report, resumes, proc, reply, kills>>
callVars == <<call, sess, marked, pipe, taken, resumed>>
vars == <<up, restarts, parentVars, delegateVars, stops, sending, got, wrong, callVars>>

\* Delegates that count against the cap: started, or starting, and not yet ended.
Active == {d \in Delegates :
             status[d] \in {"starting", "running", "resuming", "finished", "failed"}}
Counted == IF Break = "CapSkipsStarting"
             THEN {d \in Active : status[d] # "starting"} ELSE Active

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
    /\ call = [d \in Delegates |-> "none"]
    /\ sess = [d \in Delegates |-> "none"]
    /\ marked = [d \in Delegates |-> FALSE]
    /\ pipe = [d \in Delegates |-> 0]
    /\ taken = [d \in Delegates |-> 0]
    /\ resumed = [d \in Delegates |-> 0]


-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; what it holds in memory does not *)

\* Under HeldInMemory the held reports go with it. Sessions is another
\* process: a call it took runs on.
FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ stops' = {}
    /\ sending' = [d \in Delegates |-> "none"]
    /\ call' = [d \in Delegates |-> "none"]
    /\ report' = IF Break = "HeldInMemory"
                   THEN [d \in Delegates |-> IF report[d] = "held" THEN "none" ELSE report[d]]
                   ELSE report
    /\ UNCHANGED <<parentVars, status, resumes, proc, reply, kills, got, wrong,
                   sess, marked, pipe, taken, resumed>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<restarts, parentVars, delegateVars, stops, sending, got, wrong, callVars>>

-----------------------------------------------------------------------------
(* The parent: its turns, and its process ending and running again (a move) *)

PromptSent ==
    /\ parentRuns /\ ~turn /\ turn' = TRUE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, sending, got,
                   wrong, callVars>>

TurnEnds ==
    /\ turn /\ turn' = FALSE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, sending, got,
                   wrong, callVars>>

ParentStops ==
    /\ parentRuns /\ parentStops < MaxParentStops
    /\ parentRuns' = FALSE /\ turn' = FALSE /\ parentStops' = parentStops + 1
    /\ UNCHANGED <<up, restarts, delegateVars, stops, sending, got, wrong, callVars>>

ParentRuns ==
    /\ ~parentRuns /\ parentRuns' = TRUE
    /\ UNCHANGED <<up, restarts, turn, parentStops, delegateVars, stops, sending, got, wrong,
                   callVars>>

-----------------------------------------------------------------------------
(* A delegate's start, its resume, and Sessions' part in them *)

\* In a turn the parent calls start_delegate. The project and branch
\* checks may refuse it, and the cap must when it is reached. The row is
\* written first, as starting, and the call of Sessions begins.
StartAsked(d) ==
    /\ up /\ parentRuns /\ turn /\ status[d] = "none"
    /\ \/ /\ status' = [status EXCEPT ![d] = "refused"]
          /\ UNCHANGED call
       \/ /\ Cardinality(Counted) < Cap \/ Break = "NoCap"
          /\ status' = [status EXCEPT ![d] = "starting"]
          /\ call' = [call EXCEPT ![d] = "start"]
    /\ UNCHANGED <<up, restarts, parentVars, report, resumes, proc, reply, kills, stops, sending,
                   got, wrong, sess, marked, pipe, taken, resumed>>

\* Sessions takes the call and writes its own row first (Start.tla).
Called(d) ==
    /\ up /\ call[d] # "none" /\ sess[d] = "none"
    /\ sess' = [sess EXCEPT ![d] = call[d]]
    /\ UNCHANGED <<up, restarts, parentVars, delegateVars, stops, sending, got, wrong,
                   call, marked, pipe, taken, resumed>>

\* Sessions holds the process, which waits for its first message, or
\* refuses. A resumed process reads a FIFO of its own: no line written for
\* the process before reaches it (Stream.tla).
SessionsDecides(d) ==
    /\ sess[d] \in {"start", "resume"}
    /\ \/ /\ sess' = [sess EXCEPT ![d] = "running"]
          /\ proc' = [proc EXCEPT ![d] = "waiting"]
          /\ pipe' = [pipe EXCEPT ![d] = 0]
          /\ resumed' = [resumed EXCEPT ![d] = IF sess[d] = "resume" THEN @ + 1 ELSE @]
       \/ /\ sess' = [sess EXCEPT ![d] = "refused"]
          /\ UNCHANGED <<proc, pipe, resumed>>
    /\ UNCHANGED <<up, restarts, parentVars, status, report, resumes, reply, kills, stops,
                   sending, got, wrong, call, marked, taken>>

\* What a settled call writes: a start runs or is refused; a resume runs,
\* or its refusal is the report, as a second kill's is.
Outcome(d, s) ==
    IF status[d] = "starting"
      THEN IF s = "running" THEN "running" ELSE "refused"
      ELSE IF s = "running" THEN "running" ELSE "failed"

Settle(d, s) ==
    /\ status' = [status EXCEPT ![d] = Outcome(d, s)]
    /\ report' = [report EXCEPT ![d] = IF Outcome(d, s) = "failed" THEN "held" ELSE @]

\* Sessions answered the call under way.
CallAnswered(d) ==
    /\ up /\ call[d] # "none" /\ sess[d] \in {"running", "refused"}
    /\ call' = [call EXCEPT ![d] = "none"]
    /\ IF status[d] \in {"starting", "resuming"}
         THEN Settle(d, sess[d]) /\ UNCHANGED resumes
         \* ResumeBeforeRow: the row learns of the resume only now.
         ELSE /\ resumes' = [resumes EXCEPT ![d] = @ + 1]
              /\ UNCHANGED <<status, report>>
    /\ UNCHANGED <<up, restarts, parentVars, proc, reply, kills, stops, sending, got, wrong,
                   sess, marked, pipe, taken, resumed>>

\* After a restart, a row whose call a restart cut off is settled by
\* Sessions' row of that call, once that row is settled; with none, the call
\* never reached Sessions, and it is not made again.
Settled(d) ==
    /\ up /\ call[d] = "none" /\ status[d] \in {"starting", "resuming"}
    /\ sess[d] \in {"none", "running", "refused"} \/ Break = "SettleEarly"
    /\ Settle(d, sess[d])
    /\ UNCHANGED <<up, restarts, parentVars, resumes, proc, reply, kills, stops, sending, got,
                   wrong, callVars>>

\* The turn's message goes in through Stream under the uuid the row holds,
\* which Stream refuses a second time. Under NewUuid each write has a uuid
\* of its own.
InputWritten(d) ==
    /\ up /\ status[d] = "running" /\ call[d] = "none"
    /\ proc[d] \in {"waiting", "working", "idle"} /\ pipe[d] = 0
    /\ ~marked[d] \/ Break = "NewUuid"
    /\ marked' = [marked EXCEPT ![d] = TRUE]
    /\ pipe' = [pipe EXCEPT ![d] = 1]
    /\ UNCHANGED <<up, restarts, parentVars, delegateVars, stops, sending, got, wrong,
                   call, sess, taken, resumed>>

\* The delegate takes a message line and starts a turn.
InputTaken(d) ==
    /\ proc[d] \in {"waiting", "idle"} /\ pipe[d] > 0
    /\ pipe' = [pipe EXCEPT ![d] = @ - 1]
    /\ proc' = [proc EXCEPT ![d] = "working"]
    /\ reply' = [reply EXCEPT ![d] = FALSE]
    /\ taken' = [taken EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<up, restarts, parentVars, status, report, resumes, kills, stops, sending,
                   got, wrong, call, sess, marked, resumed>>

\* Its turn ends with its last reply, and its Stop event (the result in its
\* log) comes. A kill before that line is written loses it; here, with the
\* framework down the event reaches nothing.
DelegateFinishes(d) ==
    /\ proc[d] = "working"
    /\ proc' = [proc EXCEPT ![d] = "idle"]
    /\ reply' = [reply EXCEPT ![d] = TRUE]
    /\ stops' = IF up THEN stops \cup {d} ELSE stops
    /\ UNCHANGED <<up, restarts, parentVars, status, report, resumes, kills, sending, got, wrong,
                   callVars>>

DelegateKilled(d) ==
    /\ proc[d] \in {"waiting", "working", "idle"} /\ kills < MaxKills
    /\ proc' = [proc EXCEPT ![d] = "dead"]
    /\ kills' = kills + 1
    /\ UNCHANGED <<up, restarts, parentVars, status, report, resumes, reply, stops, sending,
                   got, wrong, callVars>>

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
    /\ UNCHANGED <<restarts, parentVars, resumes, proc, reply, kills, up, sending, got, wrong,
                   callVars>>

\* A restart lost the Stop event: the transcript's last reply is the report.
TranscriptRead(d) ==
    /\ up /\ Break # "NoTranscriptFallback"
    /\ status[d] = "running" /\ reply[d] /\ d \notin stops
    /\ status' = [status EXCEPT ![d] = "finished"]
    /\ report' = [report EXCEPT ![d] = "held"]
    /\ UNCHANGED <<up, restarts, parentVars, resumes, proc, reply, kills, stops, sending,
                   got, wrong, callVars>>

\* A process killed before its last reply is resumed once: the row counts
\* the resume, as resuming, before Sessions is asked, with the next turn's
\* message under a uuid of its own. A second kill is the report.
KillSeen(d) ==
    /\ up /\ status[d] = "running" /\ call[d] = "none" /\ proc[d] = "dead" /\ ~reply[d]
    /\ IF resumes[d] = 0 \/ Break = "ResumeAgain"
         THEN /\ call' = [call EXCEPT ![d] = "resume"]
              /\ sess' = [sess EXCEPT ![d] = "none"]
              /\ marked' = [marked EXCEPT ![d] = FALSE]
              /\ IF Break = "ResumeBeforeRow"
                   THEN UNCHANGED <<status, resumes>>
                   ELSE /\ status' = [status EXCEPT ![d] = "resuming"]
                        /\ resumes' = [resumes EXCEPT ![d] = @ + 1]
              /\ UNCHANGED report
         ELSE /\ status' = [status EXCEPT ![d] = "failed"]
              /\ report' = [report EXCEPT ![d] = "held"]
              /\ UNCHANGED <<resumes, call, sess, marked>>
    /\ UNCHANGED <<up, restarts, parentVars, proc, reply, kills, stops, sending, got, wrong,
                   pipe, taken, resumed>>

-----------------------------------------------------------------------------
(* Delegates and Control: from a held report into the parent, once *)

\* Once the parent's turn has ended, the row says "sending" before the write.
DeliveryAsked(d) ==
    /\ up /\ report[d] = "held" /\ sending[d] = "none"
    /\ parentRuns /\ ~turn
    /\ report' = [report EXCEPT ![d] = "sending"]
    /\ sending' = [sending EXCEPT ![d] = "asked"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   got, wrong, callVars>>

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
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, callVars>>

\* The check refused it: the report is held again.
DeliveryRefused(d) ==
    /\ up /\ sending[d] = "asked" /\ ~Typeable
    /\ sending' = [sending EXCEPT ![d] = "none"]
    /\ report' = [report EXCEPT ![d] = "held"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   got, wrong, callVars>>

DeliveryMarked(d) ==
    /\ up /\ sending[d] = "sent"
    /\ sending' = [sending EXCEPT ![d] = "none"]
    /\ report' = [report EXCEPT ![d] = "delivered"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   got, wrong, callVars>>

\* A restart cut off a send: whether it was typed is read from the parent's
\* transcript, never guessed. Under RedeliverAfterRestart it is sent again.
SendingResolved(d) ==
    /\ up /\ report[d] = "sending" /\ sending[d] = "none"
    /\ report' = [report EXCEPT ![d] = IF got[d] > 0 /\ Break # "RedeliverAfterRestart"
                                         THEN "delivered" ELSE "held"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   sending, got, wrong, callVars>>

\* The delegate ends, its process with it, only once its report is delivered.
DelegateEnds(d) ==
    /\ up /\ status[d] \in {"finished", "failed"}
    /\ report[d] = "delivered" \/ Break = "EndBeforeDelivery"
    /\ status' = [status EXCEPT ![d] = "ended"]
    /\ proc' = [proc EXCEPT ![d] = "none"]
    /\ UNCHANGED <<up, restarts, parentVars, report, resumes, reply, kills, stops, sending,
                   got, wrong, callVars>>

-----------------------------------------------------------------------------
Framework(d) ==
    \/ Called(d) \/ CallAnswered(d) \/ Settled(d) \/ InputWritten(d)
    \/ StopHandled(d) \/ TranscriptRead(d) \/ KillSeen(d) \/ DeliveryAsked(d)
    \/ DeliveryTyped(d) \/ DeliveryRefused(d) \/ DeliveryMarked(d) \/ SendingResolved(d)
    \/ DelegateEnds(d)

Next ==
    \/ FrameworkDies \/ FrameworkStarts
    \/ PromptSent \/ TurnEnds \/ ParentStops \/ ParentRuns
    \/ \E d \in Delegates : StartAsked(d) \/ SessionsDecides(d) \/ InputTaken(d)
                            \/ DelegateFinishes(d) \/ DelegateKilled(d) \/ Framework(d)

\* Sessions decides a call it took, and a delegate reads its stdin.
Fairness ==
    /\ WF_vars(FrameworkStarts) /\ WF_vars(ParentRuns) /\ WF_vars(TurnEnds)
    /\ \A d \in Delegates :
         /\ WF_vars(Called(d)) /\ WF_vars(SessionsDecides(d)) /\ WF_vars(CallAnswered(d))
         /\ WF_vars(Settled(d)) /\ WF_vars(InputWritten(d)) /\ WF_vars(InputTaken(d))
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
    /\ status \in [Delegates -> {"none", "refused", "starting", "running", "resuming",
                                 "finished", "failed", "ended"}]
    /\ report \in [Delegates -> {"none", "held", "sending", "delivered"}]
    /\ proc \in [Delegates -> {"none", "waiting", "working", "idle", "dead"}]
    /\ sending \in [Delegates -> {"none", "asked", "sent"}]
    /\ call \in [Delegates -> {"none", "start", "resume"}]
    /\ sess \in [Delegates -> {"none", "start", "resume", "running", "refused"}]
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
ResumedAtMostOnce == \A d \in Delegates : resumes[d] <= 1 /\ resumed[d] <= 1
SecondKillNotRetried ==
    \A d \in Delegates : status[d] = "failed" => resumes[d] = 1 /\ proc[d] = "dead"

CapHeld == Cardinality(Active) <= Cap

\* No process runs for a delegate whose start was refused: a held process
\* always has a row that reports it.
RefusedHoldsNothing == \A d \in Delegates : status[d] = "refused" => proc[d] = "none"

\* Each process takes one turn's message: the brief, or a resumed one's.
OneMessagePerProcess == \A d \in Delegates : taken[d] <= resumed[d] + 1

\* Every finished delegate's report arrives in the parent, and a second
\* kill's report too.
ReportArrives ==
    \A d \in Delegates : (reply[d] \/ status[d] = "failed") ~> got[d] = 1

\* A delegate whose report is delivered ends.
DeliveredDelegateEnds ==
    \A d \in Delegates : report[d] = "delivered" ~> status[d] = "ended"

\* Every start and resume settles.
CallSettles ==
    \A d \in Delegates : status[d] \in {"starting", "resuming"}
                           ~> status[d] \notin {"starting", "resuming"}

=============================================================================
