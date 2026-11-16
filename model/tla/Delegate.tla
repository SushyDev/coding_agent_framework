------------------------------ MODULE Delegate ------------------------------
(***************************************************************************)
(* A parent session, the delegates it starts, and restarts of the         *)
(* framework: the start with its checks and its row written first, the    *)
(* brief, a delegate's finish and its report's path to the parent, a kill *)
(* resumed once and a second kill reported, and the end of a delegate     *)
(* once its report is delivered. A call that waits on a report           *)
(* (run_delegate) takes it before its deadline, writes it to the agent,   *)
(* and says whether the write succeeded; an answer that may not have      *)
(* arrived holds the report again, for a message.                         *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                           *)
(*   Delegates the delegate protocol and its table: each delegate's status, *)
(*             its report (held, sending, delivered) and its resumes, all  *)
(*             durable; its calls of Sessions under way, the Stop events   *)
(*             it has not handled yet and the sends it has under way, in   *)
(*             memory (F-60 and F-62 built it up to a held report; the     *)
(*             delivery and the end are not built yet); the call waiting   *)
(*             on a report (await_report), the take that marks it          *)
(*             answering, answered and release, the watch on the waiting   *)
(*             caller, and the start's hold of an answering report         *)
(*             (F-92, F-95, F-97);                                         *)
(*   MCP       the run_delegate call: it waits, writes the report it took *)
(*             to the agent, and tells Delegates the write's outcome      *)
(*             (F-92, F-95);                                               *)
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
(* The call: the agent's client waits on one run_delegate call for each    *)
(* delegate in Awaited. The take is a step of its own here; the code      *)
(* takes a report in the step that holds it, which is one of these        *)
(* orders. The deadline is Delegates' timer, left abstract as a step that  *)
(* may come at any time while the call waits. The write's outcome is one  *)
(* of three: written (the agent has the answer), failed (a reset           *)
(* connection: the agent does not have it), or the write succeeding to a  *)
(* client that had gone (the kernel took the bytes and no one reads them, *)
(* F-95's new-1). Nothing on the server's side tells the last from the    *)
(* first, so that report is answered and reaches no one: ReportArrives    *)
(* allows this one exception, recorded in lost. A client goes that way    *)
(* when its process ends (ParentStops), or by its own limit when          *)
(* ClientLeaves. The cap of run_delegate's timeout under the client's two *)
(* limits is what makes ClientLeaves false; ReportArrivesUnderCap checks   *)
(* that then, with no parent stop, no report is lost at all. The caller's  *)
(* process may end at any step; Delegates watches it from the take, and    *)
(* holds an answering report again when it ends.                           *)
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
    Awaited,         \* the delegates a run_delegate call waits on, once each
    ClientLeaves,    \* the client may give up on a call before its deadline
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
    "NewUuid",               \* the turn's message is written again under a new uuid
    "TakeLeavesHeld",        \* the take leaves the report held, not answering
    "TakeAfterDeadline",     \* a report is taken after the call's deadline
    "AnsweredOnFailure",     \* a failed write says answered, not release
    "AnsweredFromAny",       \* answered changes a report that is not answering
    "NoCallerWatch",         \* the end of the waiting caller is not watched
    "NoRestartHold"          \* a start leaves an answering report as it is
}

ASSUME Break \in Breaks
ASSUME Cap \in Nat /\ MaxRestarts \in Nat /\ MaxKills \in Nat /\ MaxParentStops \in Nat
ASSUME Awaited \subseteq Delegates /\ ClientLeaves \in BOOLEAN

VARIABLES
    up,           \* the framework runs
    restarts,     \* restarts so far
    parentRuns,   \* a parent process runs
    turn,         \* the parent's turn runs
    parentStops,  \* the parent's process ended so far
    status,       \* table: d -> "none", "refused", "starting", "running", "resuming",
                  \*          "finished", "failed", "ended"
    report,       \* table: d -> "none", "held", "sending", "delivered", "answering",
                  \*          "answered"
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
    resumed,      \* d -> resumes Sessions made
    caller,       \* d -> the run_delegate call: "none", "waiting", "timedout" (answered
                  \*      the timeout), "writing" (took the report), "wrote" or "failed"
                  \*      (the write's outcome, not yet told), "done"
    callerUp,     \* d -> the caller's process runs
    watched,      \* in memory: delegates whose report's caller Delegates watches
    heard,        \* d -> the agent has the report as the call's answer
    lost,         \* d -> a write succeeded to a client that had gone
    unsure        \* d -> an answering report was held again while its write may have
                  \*      reached the agent (the caller's end, a restart)

parentVars == <<parentRuns, turn, parentStops>>
delegateVars == <<status, report, resumes, proc, reply, kills>>
callVars == <<call, sess, marked, pipe, taken, resumed>>
answerVars == <<caller, callerUp, watched, heard, lost, unsure>>
vars == <<up, restarts, parentVars, delegateVars, stops, sending, got, wrong, callVars,
          answerVars>>

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
    /\ caller = [d \in Delegates |-> "none"]
    /\ callerUp = [d \in Delegates |-> FALSE]
    /\ watched = {}
    /\ heard = [d \in Delegates |-> FALSE]
    /\ lost = [d \in Delegates |-> FALSE]
    /\ unsure = [d \in Delegates |-> FALSE]


-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; what it holds in memory does not *)

\* Under HeldInMemory the held reports go with it. Sessions is another
\* process: a call it took runs on. So does a caller that took a report:
\* only a call still waiting ends, with the exit of its request, and the
\* watch on every caller goes.
FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ stops' = {}
    /\ sending' = [d \in Delegates |-> "none"]
    /\ call' = [d \in Delegates |-> "none"]
    /\ report' = IF Break = "HeldInMemory"
                   THEN [d \in Delegates |-> IF report[d] = "held" THEN "none" ELSE report[d]]
                   ELSE report
    /\ caller' = [d \in Delegates |-> IF caller[d] = "waiting" THEN "done" ELSE caller[d]]
    /\ watched' = {}
    /\ UNCHANGED <<parentVars, status, resumes, proc, reply, kills, got, wrong,
                   sess, marked, pipe, taken, resumed, callerUp, heard, lost, unsure>>

\* The start holds every answering report again, before it handles a call:
\* the answer under way may not have reached its agent.
FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ IF Break = "NoRestartHold"
         THEN UNCHANGED <<report, unsure>>
         ELSE /\ report' = [d \in Delegates |-> IF report[d] = "answering" THEN "held"
                                                                          ELSE report[d]]
              /\ unsure' = [d \in Delegates |-> unsure[d] \/ report[d] = "answering"]
    /\ UNCHANGED <<restarts, parentVars, status, resumes, proc, reply, kills, stops, sending,
                   got, wrong, callVars, caller, callerUp, watched, heard, lost>>

-----------------------------------------------------------------------------
(* The parent: its turns, and its process ending and running again (a move) *)

PromptSent ==
    /\ parentRuns /\ ~turn /\ turn' = TRUE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, sending, got,
                   wrong, callVars, answerVars>>

TurnEnds ==
    /\ turn /\ turn' = FALSE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, sending, got,
                   wrong, callVars, answerVars>>

ParentStops ==
    /\ parentRuns /\ parentStops < MaxParentStops
    /\ parentRuns' = FALSE /\ turn' = FALSE /\ parentStops' = parentStops + 1
    /\ UNCHANGED <<up, restarts, delegateVars, stops, sending, got, wrong, callVars, answerVars>>

ParentRuns ==
    /\ ~parentRuns /\ parentRuns' = TRUE
    /\ UNCHANGED <<up, restarts, turn, parentStops, delegateVars, stops, sending, got, wrong,
                   callVars, answerVars>>

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
                   got, wrong, sess, marked, pipe, taken, resumed, answerVars>>

\* Sessions takes the call and writes its own row first (Start.tla).
Called(d) ==
    /\ up /\ call[d] # "none" /\ sess[d] = "none"
    /\ sess' = [sess EXCEPT ![d] = call[d]]
    /\ UNCHANGED <<up, restarts, parentVars, delegateVars, stops, sending, got, wrong,
                   call, marked, pipe, taken, resumed, answerVars>>

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
                   sending, got, wrong, call, marked, taken, answerVars>>

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
                   sess, marked, pipe, taken, resumed, answerVars>>

\* After a restart, a row whose call a restart cut off is settled by
\* Sessions' row of that call, once that row is settled; with none, the call
\* never reached Sessions, and it is not made again.
Settled(d) ==
    /\ up /\ call[d] = "none" /\ status[d] \in {"starting", "resuming"}
    /\ sess[d] \in {"none", "running", "refused"} \/ Break = "SettleEarly"
    /\ Settle(d, sess[d])
    /\ UNCHANGED <<up, restarts, parentVars, resumes, proc, reply, kills, stops, sending, got,
                   wrong, callVars, answerVars>>

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
                   call, sess, taken, resumed, answerVars>>

\* The delegate takes a message line and starts a turn.
InputTaken(d) ==
    /\ proc[d] \in {"waiting", "idle"} /\ pipe[d] > 0
    /\ pipe' = [pipe EXCEPT ![d] = @ - 1]
    /\ proc' = [proc EXCEPT ![d] = "working"]
    /\ reply' = [reply EXCEPT ![d] = FALSE]
    /\ taken' = [taken EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<up, restarts, parentVars, status, report, resumes, kills, stops, sending,
                   got, wrong, call, sess, marked, resumed, answerVars>>

\* Its turn ends with its last reply, and its Stop event (the result in its
\* log) comes. A kill before that line is written loses it; here, with the
\* framework down the event reaches nothing.
DelegateFinishes(d) ==
    /\ proc[d] = "working"
    /\ proc' = [proc EXCEPT ![d] = "idle"]
    /\ reply' = [reply EXCEPT ![d] = TRUE]
    /\ stops' = IF up THEN stops \cup {d} ELSE stops
    /\ UNCHANGED <<up, restarts, parentVars, status, report, resumes, kills, sending, got, wrong,
                   callVars, answerVars>>

DelegateKilled(d) ==
    /\ proc[d] \in {"waiting", "working", "idle"} /\ kills < MaxKills
    /\ proc' = [proc EXCEPT ![d] = "dead"]
    /\ kills' = kills + 1
    /\ UNCHANGED <<up, restarts, parentVars, status, report, resumes, reply, stops, sending,
                   got, wrong, callVars, answerVars>>

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
                   callVars, answerVars>>

\* A restart lost the Stop event: the transcript's last reply is the report.
TranscriptRead(d) ==
    /\ up /\ Break # "NoTranscriptFallback"
    /\ status[d] = "running" /\ reply[d] /\ d \notin stops
    /\ status' = [status EXCEPT ![d] = "finished"]
    /\ report' = [report EXCEPT ![d] = "held"]
    /\ UNCHANGED <<up, restarts, parentVars, resumes, proc, reply, kills, stops, sending,
                   got, wrong, callVars, answerVars>>

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
                   pipe, taken, resumed, answerVars>>

-----------------------------------------------------------------------------
(* Delegates and Control: from a held report into the parent, once *)

\* Once the parent's turn has ended, the row says "sending" before the write.
DeliveryAsked(d) ==
    /\ up /\ report[d] = "held" /\ sending[d] = "none"
    /\ parentRuns /\ ~turn
    /\ report' = [report EXCEPT ![d] = "sending"]
    /\ sending' = [sending EXCEPT ![d] = "asked"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   got, wrong, callVars, answerVars>>

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
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, callVars,
                   answerVars>>

\* The check refused it: the report is held again.
DeliveryRefused(d) ==
    /\ up /\ sending[d] = "asked" /\ ~Typeable
    /\ sending' = [sending EXCEPT ![d] = "none"]
    /\ report' = [report EXCEPT ![d] = "held"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   got, wrong, callVars, answerVars>>

DeliveryMarked(d) ==
    /\ up /\ sending[d] = "sent"
    /\ sending' = [sending EXCEPT ![d] = "none"]
    /\ report' = [report EXCEPT ![d] = "delivered"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   got, wrong, callVars, answerVars>>

\* A restart cut off a send: whether it was typed is read from the parent's
\* transcript, never guessed. Under RedeliverAfterRestart it is sent again.
SendingResolved(d) ==
    /\ up /\ report[d] = "sending" /\ sending[d] = "none"
    /\ report' = [report EXCEPT ![d] = IF got[d] > 0 /\ Break # "RedeliverAfterRestart"
                                         THEN "delivered" ELSE "held"]
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                   sending, got, wrong, callVars, answerVars>>

\* The delegate ends, its process with it, only once its report is delivered
\* or answered.
DelegateEnds(d) ==
    /\ up /\ status[d] \in {"finished", "failed"}
    /\ report[d] \in {"delivered", "answered"} \/ Break = "EndBeforeDelivery"
    /\ status' = [status EXCEPT ![d] = "ended"]
    /\ proc' = [proc EXCEPT ![d] = "none"]
    /\ UNCHANGED <<up, restarts, parentVars, report, resumes, reply, kills, stops, sending,
                   got, wrong, callVars, answerVars>>

-----------------------------------------------------------------------------
(* MCP and Delegates: a call that waits on a report and answers with it *)

answerOthers == <<up, restarts, parentVars, status, resumes, proc, reply, kills, stops,
                  sending, got, wrong, callVars>>

\* In a turn, the agent calls run_delegate on a delegate it started, whose
\* report is not yet taken or sent.
CallWaits(d) ==
    /\ d \in Awaited /\ caller[d] = "none"
    /\ up /\ parentRuns /\ turn
    /\ status[d] \notin {"none", "refused"} /\ report[d] \in {"none", "held"}
    /\ caller' = [caller EXCEPT ![d] = "waiting"]
    /\ callerUp' = [callerUp EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<answerOthers, report, watched, heard, lost, unsure>>

\* Delegates takes a held report for the call that waits on it, only before
\* the call's deadline. In the same step the report is answering, not held,
\* so it is not also sent as a message, and Delegates watches the caller.
Taken(d) ==
    /\ up /\ report[d] = "held"
    /\ caller[d] = "waiting" \/ (Break = "TakeAfterDeadline" /\ caller[d] = "timedout")
    /\ report' = [report EXCEPT ![d] = IF Break = "TakeLeavesHeld" THEN "held" ELSE "answering"]
    /\ caller' = [caller EXCEPT ![d] = IF @ = "waiting" THEN "writing" ELSE @]
    /\ watched' = watched \cup {d}
    /\ UNCHANGED <<answerOthers, callerUp, heard, lost, unsure>>

\* The deadline: the call answers the timeout, and the report, when it is
\* held, goes as a message.
Deadline(d) ==
    /\ up /\ caller[d] = "waiting"
    /\ caller' = [caller EXCEPT ![d] = "timedout"]
    /\ UNCHANGED <<answerOthers, report, callerUp, watched, heard, lost, unsure>>

\* The caller writes the answer. It reaches the agent while the parent
\* process runs; it fails on a reset connection; or it succeeds to a client
\* that had gone, when the parent process ended or, under ClientLeaves, the
\* client gave up first.
Written(d) ==
    /\ callerUp[d] /\ caller[d] = "writing"
    /\ \/ /\ parentRuns
          /\ caller' = [caller EXCEPT ![d] = "wrote"]
          /\ heard' = [heard EXCEPT ![d] = TRUE]
          /\ UNCHANGED lost
       \/ /\ caller' = [caller EXCEPT ![d] = "failed"]
          /\ UNCHANGED <<heard, lost>>
       \/ /\ ~parentRuns \/ ClientLeaves
          /\ caller' = [caller EXCEPT ![d] = "wrote"]
          /\ lost' = [lost EXCEPT ![d] = TRUE]
          /\ UNCHANGED heard
    /\ UNCHANGED <<answerOthers, report, callerUp, watched, unsure>>

\* The caller tells Delegates the write's outcome: answered when it
\* succeeded, release when it failed. Only an answering report changes; one
\* a restart held again stays held. The watch ends.
Told(d) ==
    /\ up /\ callerUp[d] /\ caller[d] \in {"wrote", "failed"}
    /\ caller' = [caller EXCEPT ![d] = "done"]
    /\ watched' = watched \ {d}
    /\ LET ok == caller[d] = "wrote" \/ Break = "AnsweredOnFailure"
       IN report' = [report EXCEPT ![d] =
                       IF @ = "answering" \/ Break = "AnsweredFromAny"
                         THEN IF ok THEN "answered" ELSE "held"
                         ELSE @]
    /\ UNCHANGED <<answerOthers, callerUp, heard, lost, unsure>>

\* Delegates cannot be reached: the caller's word is lost, and the report
\* stays answering until the start holds it again.
TellLost(d) ==
    /\ ~up /\ callerUp[d] /\ caller[d] \in {"wrote", "failed"}
    /\ caller' = [caller EXCEPT ![d] = "done"]
    /\ UNCHANGED <<answerOthers, report, callerUp, watched, heard, lost, unsure>>

\* The caller's process ends, at any step of its call.
CallerEnds(d) ==
    /\ callerUp[d] /\ callerUp' = [callerUp EXCEPT ![d] = FALSE]
    /\ UNCHANGED <<answerOthers, report, caller, watched, heard, lost, unsure>>

\* Delegates sees the end of a caller it watches, and holds its answering
\* report again.
CallerSeen(d) ==
    /\ up /\ d \in watched /\ ~callerUp[d] /\ Break # "NoCallerWatch"
    /\ watched' = watched \ {d}
    /\ report' = [report EXCEPT ![d] = IF @ = "answering" THEN "held" ELSE @]
    /\ unsure' = [unsure EXCEPT ![d] = @ \/ report[d] = "answering"]
    /\ UNCHANGED <<answerOthers, caller, callerUp, heard, lost>>

Answer(d) ==
    \/ CallWaits(d) \/ Taken(d) \/ Deadline(d) \/ Written(d) \/ Told(d) \/ TellLost(d)
    \/ CallerEnds(d) \/ CallerSeen(d)

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
                            \/ Answer(d)

\* Sessions decides a call it took, and a delegate reads its stdin. A call
\* that waits is taken or reaches its deadline, a caller writes and tells,
\* and Delegates sees a caller's end. The agent's call and the caller's end
\* need not happen.
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
    \* Only a delegate in Awaited has a call; naming no other keeps TLC fast.
    /\ \A d \in Awaited :
         /\ WF_vars(Taken(d)) /\ WF_vars(Deadline(d)) /\ WF_vars(Written(d))
         /\ WF_vars(Told(d)) /\ WF_vars(TellLost(d)) /\ WF_vars(CallerSeen(d))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ up \in BOOLEAN /\ parentRuns \in BOOLEAN /\ turn \in BOOLEAN
    /\ status \in [Delegates -> {"none", "refused", "starting", "running", "resuming",
                                 "finished", "failed", "ended"}]
    /\ report \in [Delegates -> {"none", "held", "sending", "delivered", "answering",
                                 "answered"}]
    /\ caller \in [Delegates -> {"none", "waiting", "timedout", "writing", "wrote", "failed",
                                 "done"}]
    /\ watched \subseteq Delegates
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

\* A delegate ends only after its report is delivered or answered.
EndsAfterDelivery ==
    \A d \in Delegates : status[d] = "ended" => report[d] \in {"delivered", "answered"}

\* An answered report is never sent as a message too, and stays answered.
AnsweredNotSent ==
    \A d \in Delegates : report[d] = "answered" => got[d] = 0 /\ sending[d] = "none"
AnsweredStays ==
    [][\A d \in Delegates : report[d] = "answered" => report'[d] = "answered"]_vars

\* A report is answered only after a write that succeeded.
AnsweredWasWritten == \A d \in Delegates : report[d] = "answered" => heard[d] \/ lost[d]

\* The agent has a report both as an answer and as a message only when an
\* answering report was held again while its write may have reached it.
TwiceOnlyIfUnsure == \A d \in Delegates : heard[d] /\ got[d] > 0 => unsure[d]

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

\* Every finished delegate's report, and a second kill's report too, reaches
\* the agent: as a call's answer or as a message, at least once. The model's
\* one exception is a write that succeeded to a client that had gone (lost).
ReportArrives ==
    \A d \in Delegates : (reply[d] \/ status[d] = "failed") ~> got[d] = 1 \/ heard[d] \/ lost[d]

\* With the cap (no ClientLeaves) and no parent stop, there is no exception.
ReportArrivesUnderCap ==
    \A d \in Delegates : (reply[d] \/ status[d] = "failed") ~> got[d] = 1 \/ heard[d]

\* A delegate whose report is delivered or answered ends.
DeliveredDelegateEnds ==
    \A d \in Delegates : report[d] \in {"delivered", "answered"} ~> status[d] = "ended"

\* Every start and resume settles.
CallSettles ==
    \A d \in Delegates : status[d] \in {"starting", "resuming"}
                           ~> status[d] \notin {"starting", "resuming"}

=============================================================================
