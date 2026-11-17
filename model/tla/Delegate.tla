------------------------------ MODULE Delegate ------------------------------
(***************************************************************************)
(* A parent session, the delegates it starts, and restarts of the         *)
(* framework: the start with its checks and its row written first, the    *)
(* brief, a delegate's finish, a kill resumed once and a second kill       *)
(* reported, the report handed to Mailbox, and the end of a delegate once  *)
(* its report is delivered. The report is a row of Delivery.tla's          *)
(* (instanced as D): the reply to the brief, to the parent, by its waiter, *)
(* the typed write, or the answer of a run_delegate call that waits on it. *)
(* Mailbox's mark and settle, the call's write and its restart policy are  *)
(* Delivery's; this spec checks that the protocol hands every report on    *)
(* once and ends a delegate only after it is delivered.                    *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                           *)
(*   Delegates the delegate protocol and its table: each delegate's status *)
(*             and its resumes, durable; its calls of Sessions under way   *)
(*             and the Stop events it has not handled yet, in memory; the  *)
(*             report handed to Mailbox once (`taken`, R7);                *)
(*   Mailbox   the report's row, to the parent (Delivery.tla);             *)
(*   Parents   whether a parent process runs and whether its turn runs;    *)
(*             a move (Move.tla) is the parent's process ending and a new  *)
(*             one running later;                                          *)
(*   Sessions  the start and the resume of a delegate, which write their   *)
(*             own row first and run on through a restart of Delegates     *)
(*             (Start.tla models them);                                    *)
(*   Stream    the turn's message (the brief, or what a resumed process    *)
(*             takes), marked in its table under the uuid Delegates chose  *)
(*             and wrote in its row first, and refused a second time       *)
(*             under that uuid (Stream.tla models it).                     *)
(*                                                                         *)
(* Left abstract: the parent's pid, account and transcript copy           *)
(* (Move.tla); the start's account, worktree, setup and dtach steps        *)
(* (Start.tla); the deadline a starting row waits for before it is        *)
(* refused with no Sessions row of its call: the call and Sessions' own    *)
(* row are one step here; the text of a report; the delegate's subagents  *)
(* and tokens; messages to a delegate and its replies (Team.tla,          *)
(* Delivery.tla). A delegate takes one turn's message per process and     *)
(* finishes once. The Stop event stands for the result in the delegate's  *)
(* event log, which a kill before its line is written loses. The          *)
(* framework reads the parent's transcript exactly. A run_delegate call   *)
(* is made in a parent's turn, on a delegate in Awaited; the handler that  *)
(* waits is Delivery's, and the client's own limit is ClientLeaves. A     *)
(* waiter leaves only with its process or a restart: its own deadline is   *)
(* Delivery.tla's, where the typed write takes its place.                 *)
(*                                                                         *)
(* What moved to Delivery.tla (R6): the report's sending mark and its      *)
(* settle from the parent's transcript, the typed write (DeliveryTyped),   *)
(* the call's take, write and tell, and with them DeliveredAtMostOnce,     *)
(* OnlyIntoEndedTurn, AnsweredNotSent, AnsweredStays, AnsweredWasWritten   *)
(* and TwiceOnlyIfUnsure, and their Breaks. This spec still checks the     *)
(* first two and Delivery's DeliveredWasTaken on its own state.            *)
(*                                                                         *)
(* Fairness: the framework's steps happen while they stay possible; the    *)
(* parent runs again after it stops and its turns end; Mailbox's as in     *)
(* Delivery.tla.                                                           *)
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
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Delegates,       \* the delegates the parent may start
    Cap,             \* delegates of the parent at once, not yet ended
    MaxRestarts,     \* restarts of the framework
    MaxKills,        \* kills of delegate processes
    MaxParentStops,  \* times the parent's process ends: a move, or an exit
    Awaited,         \* the delegates a run_delegate call waits on, once each
    ClientLeaves,    \* the client may give up on a call before its deadline
    Break            \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "EndBeforeDelivery",     \* a finished delegate is ended before its report is delivered
    "ResumeAgain",           \* every kill is resumed, the second too
    "HeldInMemory",          \* a report not yet stored is kept in memory, not in the table
    "NoTranscriptFallback",  \* a lost Stop event is not replaced by the transcript's last reply
    "NoCap",                 \* a start does not check the cap
    "CapSkipsStarting",      \* the cap counts no start still under way
    "SettleEarly",           \* after a restart, a row is settled while Sessions' call still runs
    "ResumeBeforeRow",       \* the resume is asked before the row counts it
    "NewUuid"                \* the turn's message is written again under a new uuid
}

ASSUME Break \in Breaks
ASSUME Cap \in Nat /\ MaxRestarts \in Nat /\ MaxKills \in Nat /\ MaxParentStops \in Nat
ASSUME Awaited \subseteq Delegates /\ ClientLeaves \in BOOLEAN

Parent == "parent"

VARIABLES
    up,           \* the framework runs
    restarts,     \* restarts so far
    parentRuns,   \* a parent process runs
    turn,         \* the parent's turn runs
    parentStops,  \* the parent's process ended so far
    status,       \* table: d -> "none", "refused", "starting", "running", "resuming",
                  \*          "finished", "failed", "ended"
    held,         \* in memory: delegates whose report waits to be stored (HeldInMemory only)
    resumes,      \* table: d -> resumes so far
    proc,         \* d -> the delegate's process: "none", "waiting" (held, no message taken),
                  \*      "working", "idle" (after its last reply), "dead"
    reply,        \* d -> the delegate's transcript ends with its last reply
    kills,        \* kills so far
    stops,        \* in memory: delegates whose Stop event Intake holds, not yet handled
    call,         \* in memory: d -> "none", "start", "resume": Delegates' call of Sessions
    sess,         \* Sessions: d -> its row of the latest call: "none", "start" or "resume"
                  \*           (written, under way), "running", "refused"
    marked,       \* Stream's table: d -> the turn's message is marked under the row's uuid
    pipe,         \* d -> message lines in the current process's FIFO, not yet taken
    taken,        \* d -> turn messages the delegate's processes took
    resumed,      \* d -> resumes Sessions made
    \* Delivery's, for the reports: row d is d's report
    row, hand, claimed, wire, waiter, dcall, tx, fold, rmem, last, unsure, lost, wrong

parentVars == <<parentRuns, turn, parentStops>>
delegateVars == <<status, held, resumes, proc, reply, kills>>
callVars == <<call, sess, marked, pipe, taken, resumed>>
dvars == <<row, hand, claimed, wire, waiter, dcall, tx, fold, rmem, last, unsure, lost, wrong>>
vars == <<up, restarts, parentVars, delegateVars, stops, callVars, dvars>>

\* The parent's process Mailbox sees: one number per process.
ParentProc == IF parentRuns THEN parentStops + 1 ELSE 0

D == INSTANCE Delivery WITH
       Ids <- Delegates, Addrs <- {Parent}, Headless <- {}, Senders <- Delegates,
       MaxSent <- 0, Awaited <- Awaited, ClientLeaves <- ClientLeaves, SelfTurns <- FALSE,
       MaxRestarts <- 0, MaxEnds <- 0, MaxPrompts <- 0, MaxStops <- 0, Break <- "none",
       up <- up,
       pr <- [a \in {Parent} |-> ParentProc],
       idle <- [a \in {Parent} |-> ~turn],
       stopping <- [a \in {Parent} |-> FALSE],
       over <- [a \in {Parent} |-> FALSE],
       call <- dcall,
       restarts <- 0, lives <- 0, ends <- 0, prompts <- 0, stops <- 0, readAt <- 0

\* Delegates that count against the cap: started, or starting, and not yet ended.
Active == {d \in Delegates :
             status[d] \in {"starting", "running", "resuming", "finished", "failed"}}
Counted == IF Break = "CapSkipsStarting"
             THEN {d \in Active : status[d] # "starting"} ELSE Active

\* The report is handed to Mailbox: its row is stored.
Stored(d) == row[d].st # "none"

-----------------------------------------------------------------------------
Init ==
    /\ up = TRUE /\ restarts = 0
    /\ parentRuns = TRUE /\ turn = FALSE /\ parentStops = 0
    /\ status = [d \in Delegates |-> "none"]
    /\ held = {}
    /\ resumes = [d \in Delegates |-> 0]
    /\ proc = [d \in Delegates |-> "none"]
    /\ reply = [d \in Delegates |-> FALSE]
    /\ kills = 0
    /\ stops = {}
    /\ call = [d \in Delegates |-> "none"]
    /\ sess = [d \in Delegates |-> "none"]
    /\ marked = [d \in Delegates |-> FALSE]
    /\ pipe = [d \in Delegates |-> 0]
    /\ taken = [d \in Delegates |-> 0]
    /\ resumed = [d \in Delegates |-> 0]
    /\ row = [d \in Delegates |-> D!NoRow] /\ hand = {} /\ claimed = {}
    /\ wire = [d \in Delegates |-> 0] /\ waiter = [a \in {Parent} |-> 0]
    /\ dcall = [d \in Delegates |-> "none"]
    /\ tx = [a \in {Parent} |-> <<>>] /\ fold = [d \in Delegates |-> "none"]
    /\ rmem = {} /\ last = [a \in {Parent} |-> D!NoResult]
    /\ unsure = {} /\ lost = {} /\ wrong = {}

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; what it holds in memory does not *)

\* Sessions is another process: a call it took runs on. Under HeldInMemory
\* the reports not yet stored go with the memory.
FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ stops' = {}
    /\ call' = [d \in Delegates |-> "none"]
    /\ held' = {}
    /\ D!Restart
    /\ UNCHANGED <<parentVars, status, resumes, proc, reply, kills,
                   sess, marked, pipe, taken, resumed>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<restarts, parentVars, delegateVars, stops, callVars, dvars>>

-----------------------------------------------------------------------------
(* The parent: its turns, and its process ending and running again (a move) *)

PromptSent ==
    /\ parentRuns /\ ~turn /\ turn' = TRUE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, callVars, dvars>>

TurnEnds ==
    /\ turn /\ turn' = FALSE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, callVars, dvars>>

ParentStops ==
    /\ parentRuns /\ parentStops < MaxParentStops
    /\ parentRuns' = FALSE /\ turn' = FALSE /\ parentStops' = parentStops + 1
    /\ D!Exited(Parent, FALSE)
    /\ UNCHANGED <<up, restarts, delegateVars, stops, callVars>>

ParentRuns ==
    /\ ~parentRuns /\ parentRuns' = TRUE
    /\ UNCHANGED <<up, restarts, turn, parentStops, delegateVars, stops, callVars, dvars>>

-----------------------------------------------------------------------------
(* A delegate's start, its resume, and Sessions' part in them *)

others == <<up, restarts, parentVars, stops, dvars>>

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
    /\ UNCHANGED <<others, held, resumes, proc, reply, kills, sess, marked, pipe, taken, resumed>>

\* Sessions takes the call and writes its own row first (Start.tla).
Called(d) ==
    /\ up /\ call[d] # "none" /\ sess[d] = "none"
    /\ sess' = [sess EXCEPT ![d] = call[d]]
    /\ UNCHANGED <<others, delegateVars, call, marked, pipe, taken, resumed>>

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
    /\ UNCHANGED <<others, status, held, resumes, reply, kills, call, marked, taken>>

\* What a settled call writes: a start runs or is refused; a resume runs,
\* or its refusal is the report, as a second kill's is.
Outcome(d, s) ==
    IF status[d] = "starting"
      THEN IF s = "running" THEN "running" ELSE "refused"
      ELSE IF s = "running" THEN "running" ELSE "failed"

\* The report is handed to Mailbox: the reply to the brief, from d to the
\* parent, stored as its row. Under HeldInMemory it waits in memory first.
Report(d) ==
    IF Break = "HeldInMemory"
      THEN held' = held \cup {d} /\ UNCHANGED dvars
      ELSE /\ D!StoreRow(d, d, Parent, "reply", d, d)
           /\ UNCHANGED <<held, hand, claimed, wire, waiter, dcall, tx, fold, rmem, last, unsure,
                          lost, wrong>>

NoReport == UNCHANGED <<held, dvars>>

Settle(d, s) ==
    /\ status' = [status EXCEPT ![d] = Outcome(d, s)]
    /\ IF Outcome(d, s) = "failed" THEN Report(d) ELSE NoReport

\* Sessions answered the call under way.
CallAnswered(d) ==
    /\ up /\ call[d] # "none" /\ sess[d] \in {"running", "refused"}
    /\ call' = [call EXCEPT ![d] = "none"]
    /\ IF status[d] \in {"starting", "resuming"}
         THEN Settle(d, sess[d]) /\ UNCHANGED resumes
         \* ResumeBeforeRow: the row learns of the resume only now.
         ELSE /\ resumes' = [resumes EXCEPT ![d] = @ + 1]
              /\ UNCHANGED status /\ NoReport
    /\ UNCHANGED <<up, restarts, parentVars, stops, proc, reply, kills, sess, marked, pipe, taken,
                   resumed>>

\* After a restart, a row whose call a restart cut off is settled by
\* Sessions' row of that call, once that row is settled; with none, the call
\* never reached Sessions, and it is not made again.
Settled(d) ==
    /\ up /\ call[d] = "none" /\ status[d] \in {"starting", "resuming"}
    /\ sess[d] \in {"none", "running", "refused"} \/ Break = "SettleEarly"
    /\ Settle(d, sess[d])
    /\ UNCHANGED <<up, restarts, parentVars, stops, resumes, proc, reply, kills, callVars>>

\* The turn's message goes in through Stream under the uuid the row holds,
\* which Stream refuses a second time. Under NewUuid each write has a uuid
\* of its own.
InputWritten(d) ==
    /\ up /\ status[d] = "running" /\ call[d] = "none"
    /\ proc[d] \in {"waiting", "working", "idle"} /\ pipe[d] = 0
    /\ ~marked[d] \/ Break = "NewUuid"
    /\ marked' = [marked EXCEPT ![d] = TRUE]
    /\ pipe' = [pipe EXCEPT ![d] = 1]
    /\ UNCHANGED <<others, delegateVars, call, sess, taken, resumed>>

\* The delegate takes a message line and starts a turn.
InputTaken(d) ==
    /\ proc[d] \in {"waiting", "idle"} /\ pipe[d] > 0
    /\ pipe' = [pipe EXCEPT ![d] = @ - 1]
    /\ proc' = [proc EXCEPT ![d] = "working"]
    /\ reply' = [reply EXCEPT ![d] = FALSE]
    /\ taken' = [taken EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<others, status, held, resumes, kills, call, sess, marked, resumed>>

\* Its turn ends with its last reply, and its Stop event (the result in its
\* log) comes. A kill before that line is written loses it; here, with the
\* framework down the event reaches nothing.
DelegateFinishes(d) ==
    /\ proc[d] = "working"
    /\ proc' = [proc EXCEPT ![d] = "idle"]
    /\ reply' = [reply EXCEPT ![d] = TRUE]
    /\ stops' = IF up THEN stops \cup {d} ELSE stops
    /\ UNCHANGED <<up, restarts, parentVars, status, held, resumes, kills, callVars, dvars>>

DelegateKilled(d) ==
    /\ proc[d] \in {"waiting", "working", "idle"} /\ kills < MaxKills
    /\ proc' = [proc EXCEPT ![d] = "dead"]
    /\ kills' = kills + 1
    /\ UNCHANGED <<others, status, held, resumes, reply, callVars>>

-----------------------------------------------------------------------------
(* Delegates: from a finish or a kill to the report handed to Mailbox *)

\* The Stop event holds the last message. Only a running delegate's row
\* changes, so the event and the transcript fallback give one report.
StopHandled(d) ==
    /\ up /\ d \in stops
    /\ stops' = stops \ {d}
    /\ IF status[d] = "running"
         THEN status' = [status EXCEPT ![d] = "finished"] /\ Report(d)
         ELSE UNCHANGED status /\ NoReport
    /\ UNCHANGED <<up, restarts, parentVars, resumes, proc, reply, kills, callVars>>

\* A restart lost the Stop event: the transcript's last reply is the report.
TranscriptRead(d) ==
    /\ up /\ Break # "NoTranscriptFallback"
    /\ status[d] = "running" /\ reply[d] /\ d \notin stops
    /\ status' = [status EXCEPT ![d] = "finished"] /\ Report(d)
    /\ UNCHANGED <<up, restarts, parentVars, resumes, proc, reply, kills, stops, callVars>>

\* Under HeldInMemory: the report waits in memory, then is stored.
HeldStored(d) ==
    /\ up /\ d \in held
    /\ held' = held \ {d}
    /\ D!StoreRow(d, d, Parent, "reply", d, d)
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops, callVars,
                   hand, claimed, wire, waiter, dcall, tx, fold, rmem, last, unsure, lost, wrong>>

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
              /\ NoReport
         ELSE /\ status' = [status EXCEPT ![d] = "failed"]
              /\ Report(d)
              /\ UNCHANGED <<resumes, call, sess, marked>>
    /\ UNCHANGED <<up, restarts, parentVars, proc, reply, kills, stops, pipe, taken, resumed>>

\* The delegate ends, its process with it, only once its report is delivered.
DelegateEnds(d) ==
    /\ up /\ status[d] \in {"finished", "failed"}
    /\ row[d].st = "delivered" \/ Break = "EndBeforeDelivery"
    /\ status' = [status EXCEPT ![d] = "ended"]
    /\ proc' = [proc EXCEPT ![d] = "none"]
    /\ UNCHANGED <<others, held, resumes, reply, kills, callVars>>

-----------------------------------------------------------------------------
(* Mailbox: the report into the parent (Delivery.tla) *)

Mailbox(A) == A /\ UNCHANGED <<up, restarts, parentVars, delegateVars, stops, callVars>>

\* Claude Code takes the report: a turn of the parent starts with it.
Takes(d) ==
    /\ D!Take(d) /\ turn' = TRUE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, callVars>>

\* In a turn, the agent calls run_delegate on a delegate it started, whose
\* report is not yet in flight.
CallWaits(d) ==
    /\ parentRuns /\ turn /\ status[d] \notin {"none", "refused"}
    /\ row[d].st \in {"none", "due"}
    /\ Mailbox(D!CallWaits(d))

\* One report's steps after its mark and hand-on, but the take (see
\* Delivery.tla).
RowSteps(d) ==
    Mailbox(\/ D!Refused(d) \/ D!Unknown(d) \/ D!SettleSeen(d, D!InTx(d))
               \/ D!Deadline(d) \/ D!Written(d) \/ D!Told(d) \/ D!CallerSeen(d)
               \/ D!SettleCut(d))

Mailboxes(d) ==
    \/ \E t \in {"waiter", "typed", "call"} : Mailbox(D!Mark(d, t))
    \/ Mailbox(D!Handed(d))
    \/ Takes(d) \/ RowSteps(d)
    \/ CallWaits(d) \/ Mailbox(D!CallerEnds(d))

-----------------------------------------------------------------------------
Framework(d) ==
    \/ Called(d) \/ CallAnswered(d) \/ Settled(d) \/ InputWritten(d)
    \/ StopHandled(d) \/ TranscriptRead(d) \/ HeldStored(d) \/ KillSeen(d)
    \/ DelegateEnds(d)

Next ==
    \/ FrameworkDies \/ FrameworkStarts
    \/ PromptSent \/ TurnEnds \/ ParentStops \/ ParentRuns
    \/ Mailbox(D!Connects(Parent))
    \/ \E d \in Delegates : StartAsked(d) \/ SessionsDecides(d) \/ InputTaken(d)
                            \/ DelegateFinishes(d) \/ DelegateKilled(d) \/ Framework(d)
                            \/ Mailboxes(d)

\* Sessions decides a call it took, and a delegate reads its stdin. A call
\* that waits is taken or reaches its deadline. The agent's call and the
\* handler's end need not happen.
Fairness ==
    /\ WF_vars(FrameworkStarts) /\ WF_vars(ParentRuns) /\ WF_vars(TurnEnds)
    /\ SF_vars(Mailbox(D!Connects(Parent)))
    /\ \A d \in Delegates :
         /\ WF_vars(Called(d)) /\ WF_vars(SessionsDecides(d)) /\ WF_vars(CallAnswered(d))
         /\ WF_vars(Settled(d)) /\ WF_vars(InputWritten(d)) /\ WF_vars(InputTaken(d))
         /\ WF_vars(StopHandled(d)) /\ WF_vars(TranscriptRead(d)) /\ WF_vars(HeldStored(d))
         /\ WF_vars(KillSeen(d)) /\ WF_vars(DelegateEnds(d))
         /\ SF_vars(\E t \in {"waiter", "typed", "call"} : Mailbox(D!Mark(d, t)))
         /\ SF_vars(Mailbox(D!Handed(d))) /\ SF_vars(Takes(d))
         /\ SF_vars(RowSteps(d))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ up \in BOOLEAN /\ parentRuns \in BOOLEAN /\ turn \in BOOLEAN
    /\ status \in [Delegates -> {"none", "refused", "starting", "running", "resuming",
                                 "finished", "failed", "ended"}]
    /\ held \subseteq Delegates
    /\ proc \in [Delegates -> {"none", "waiting", "working", "idle", "dead"}]
    /\ call \in [Delegates -> {"none", "start", "resume"}]
    /\ sess \in [Delegates -> {"none", "start", "resume", "running", "refused"}]
    /\ stops \subseteq Delegates
    /\ turn => parentRuns
    /\ D!TypeOK

\* Delivery's, on the reports: each in the parent's transcript once (but a
\* call's write that may have reached it), only into an ended turn, and
\* delivered only on its evidence.
DeliveredAtMostOnce == D!AtMostOnce
OnlyIntoEndedTurn == D!OnlyIntoEndedTurn
DeliveredWasTaken == D!DeliveredWasTaken

\* A delegate ends only after its report is delivered.
EndsAfterDelivery == \A d \in Delegates : status[d] = "ended" => row[d].st = "delivered"

\* A finished or failed delegate's report is never dropped, by a restart
\* or otherwise.
ReportKept ==
    \A d \in Delegates : status[d] \in {"finished", "failed", "ended"} => Stored(d) \/ d \in held

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

\* Every finished delegate's report, and a second kill's report too, reaches
\* the parent's transcript: as a call's answer or by the waiter or the typed
\* write. The one exception is a call's write to a client that gave up by
\* its own limit, under ClientLeaves.
ReportArrives ==
    \A d \in Delegates : (reply[d] \/ status[d] = "failed")
                           ~> (D!InTx(d) \/ <<d, "left">> \in lost)

\* With the cap (no ClientLeaves), there is no exception.
ReportArrivesUnderCap ==
    \A d \in Delegates : (reply[d] \/ status[d] = "failed") ~> D!InTx(d)

\* A delegate whose report is delivered ends.
DeliveredDelegateEnds ==
    \A d \in Delegates : row[d].st = "delivered" ~> status[d] = "ended"

\* Every start and resume settles.
CallSettles ==
    \A d \in Delegates : status[d] \in {"starting", "resuming"}
                           ~> status[d] \notin {"starting", "resuming"}

=============================================================================
