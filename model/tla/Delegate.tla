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
(*             one running later, which has no waiter until a turn of it   *)
(*             ends (`parentTurned`). A report may be long (Delivery's     *)
(*             Long is every report), so it reaches a parent with no       *)
(*             waiter as the typed pointer to its file (F-142);            *)
(*             NoPointer leaves it waiting for a person's prompt;          *)
(*   Sessions  the start and the resume of a delegate, which write their   *)
(*             own row first and run on through a restart of Delegates     *)
(*             (Start.tla models them), and are cut by a restart of the    *)
(*             delegate's own agent process, whose row is then adopted;    *)
(*   Recoveries the end of an orphan, a process held with no line;         *)
(*   Delegates.Work what the row's owner answers the Scheduler;            *)
(*   Stream    the turn's message (the brief, or what a resumed process    *)
(*             takes), marked in its table under the uuid Delegates chose  *)
(*             and wrote in its row first, and refused a second time       *)
(*             under that uuid (Stream.tla models it).                     *)
(*                                                                         *)
(* A headless process writes its system/init only after it read its first *)
(* line (Claude Code 2.1.322), and Sessions confirms its start only by     *)
(* that init. So its turn's message is marked before Sessions is called,   *)
(* and Sessions writes it into the FIFO right after the hold, before it    *)
(* waits for the init (F-152; Delivery.tla's stream row for a start).      *)
(* BriefAfterInit writes it only once the row is running: each waits on    *)
(* the other, and the start never settles.                                 *)
(*                                                                         *)
(* Left abstract: the parent's pid, account and transcript copy           *)
(* (Move.tla); the start's account, worktree, setup and dtach steps        *)
(* (Start.tla); the clock: the caller's deadline passes as one step, and   *)
(* the row's deadline, later, is Settled's refusal of a row with no        *)
(* Sessions row once no request of it waits in time; a call's give-up     *)
(* once Sessions took it (the row then waits for Sessions' row, as after a *)
(* restart); the text of a report; the delegate's subagents                *)
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
(* An interactive delegate (Interactive, F-137) runs Claude Code's        *)
(* terminal interface. Its turn's message is not written through Stream:  *)
(* the brief, or a resumed process's word to go on, is marked by launch    *)
(* before Sessions is called, and the start carries it as its prompt      *)
(* argument (Delivery.tla's launch transport checks that mark and its      *)
(* settle). A person may attach and type, so after its first turn it may  *)
(* run turns of a person's; each turn's end posts a Stop. Its report is   *)
(* the reply to the brief's key, read from its transcript: the result of  *)
(* the turn the brief, or the word to go on, started, never a later turn's *)
(* (ReportAnswersTheBrief). Later rows to it go by its waiter or the typed *)
(* write, as to a main session (Delivery.tla's Delivery_Launch).          *)
(*                                                                         *)
(* A delegate idle with no report (F-150, item 14): a turn of its may end *)
(* with nothing the framework reads as its report (TurnEndsBare: an       *)
(* interactive turn with no reply text, say), and nothing is due to it.   *)
(* Delegates tells its parent once per such idle state, by a notice in    *)
(* Mailbox stored under a key of that state, after a bound the app sets   *)
(* (BoundPasses, Delegates' wake, in memory: a restart starts it again).  *)
(* It never kills or nudges the delegate. The state ends when a turn      *)
(* starts, here the resumed process's after a kill, or the delegate ends. *)
(* The notice's own delivery is Delivery.tla's, as any message's.        *)
(* IdleToldOnce and IdleNoticed. Left abstract: a person's turn and a     *)
(* message into an idle delegate (Team.tla), which also end the state.    *)
(*                                                                         *)
(* A delegate's own turn after its report (F-155): a background command   *)
(* of its own wakes it (OwnWakes) and its turn answers no message. Its    *)
(* last reply goes to the parent as a notice in Mailbox, once per such    *)
(* turn, stored under the turn's key (its result's uuid), which Mailbox   *)
(* takes once (`keys`, as F-150's idle notice is); never as the report,   *)
(* which stays the reply of the brief's turn. The notice comes only once  *)
(* the report is handed on, so it never goes before it. TurnToldOnce,     *)
(* TurnNotReport and TurnNoticed. TurnNotReport's guard is ReplyTurn's,    *)
(* which Break_Delegate_LastReply removes.                                *)
(*                                                                         *)
(* A start idempotent per branch (F-150): a second start of a delegate    *)
(* whose session is live answers that delegate and writes nothing, so it  *)
(* is no step here. One whose row has no report and whose process is gone *)
(* does not count as running: a new start of it goes on (StartAgain), as  *)
(* a new row, under the cap that already counts it, and the old row is    *)
(* history, never resumed.                                                 *)
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
(*                                                                         *)
(* The Team box's contract for delegates (F-163): a report kept,           *)
(* delivered once and before its delegate ends (ReportKept,                *)
(* EndsAfterDelivery, ReportArrives), a resume at most once and a second   *)
(* kill reported (ResumedAtMostOnce, SecondKillNotRetried), the cap        *)
(* (CapHeld), nothing held for a refused start (RefusedHoldsNothing),      *)
(* every call settled (CallSettles), an idle delegate told once            *)
(* (IdleToldOnce, IdleNoticed), a turn of its own after its report told    *)
(* once and never as the report (TurnToldOnce, TurnNotReport,              *)
(* TurnNoticed, F-155). Boxes.tla takes a delegate's start and resume as   *)
(* Sessions' and leaves the report to Delivery.tla. The owner's            *)
(* promise the Scheduler's release rests on is checked here, where the     *)
(* owner's statuses are (F-163's new-1): work the owner says ended has no  *)
(* process (WorkEndedIsFree). Delegates.Work answers a refused, finished   *)
(* or failed row ended only once Sessions' row of it is free; with the     *)
(* status alone (StatusEndsWork) a finished delegate's lease goes while    *)
(* its process lives.                                                      *)
(*                                                                         *)
(* The request in Sessions' queue (F-166, F-164's new-1): a call of        *)
(* Sessions is a request in its mailbox until Sessions takes it, and it    *)
(* stays there through Delegates' restart and its call's give-up. The      *)
(* request carries the caller's deadline, which passes before the row's    *)
(* (CallerLate). Sessions refuses a request it takes past that deadline    *)
(* and writes nothing (Called), so a row refused with no Sessions row,     *)
(* at its own deadline, stays without a process: RefusedHoldsNothing is    *)
(* checked against the late take. TakeStale starts it anyway, under a row  *)
(* Delegates already refused.                                              *)
(*                                                                         *)
(* Restarts (F-164): the whole framework's (FrameworkDies, Delegates' own  *)
(* memory: Sessions is another process and its calls run on), and an       *)
(* agent's own process's (B4): a delegate's (RestartAgent), which cuts     *)
(* Delegates' call of it and Sessions' start or resume under way, and the  *)
(* parent's (RestartParent), which cuts a hand of a report to it. Each     *)
(* re-adopts from the row and starts nothing; all are bounded together by *)
(* MaxRestarts.                                                            *)
(*                                                                         *)
(* A start whose lease is queued answers at once (F-170). The start asks  *)
(* the Scheduler for a lease (Schedule.tla's request): granted, it goes on *)
(* as above; queued, exactly one more answer comes later, the lease or a  *)
(* refusal (Schedule.tla's QueuedIsAnswered). For a delegate in Queued the *)
(* caller does not wait for it: the start answers queued at once, and the  *)
(* row says first that its parent is owed the start's outcome (`owed`,     *)
(* durable). Delegates waits for the one more answer in memory (call is    *)
(* "lease"); a restart loses that wait, the Scheduler's answer then        *)
(* reaches no one, and the row is refused at its deadline (Settled). Once  *)
(* the row leaves starting, the outcome (running, or refused with its      *)
(* reason) is told to the parent as a notice stored under the row's key,   *)
(* which Mailbox takes once (`keys`), and the mark is cleared after.       *)
(* StartToldOnce and StartNoticed; StartOwedInMemory forgets the mark at a *)
(* restart, and StartNoKey stores the notice under no key. Left abstract:  *)
(* a caller that waits for a queued lease (the code's default for the      *)
(* operator), whose answer is the outcome itself; the queue's position;    *)
(* a start again (StartAgain), whose lease is granted at once here.        *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Delegates,       \* the delegates the parent may start
    Cap,             \* delegates of the parent at once, not yet ended
    MaxRestarts,     \* restarts of the framework and of an agent's process
    MaxKills,        \* kills of delegate processes
    MaxParentStops,  \* times the parent's process ends: a move, or an exit
    Awaited,         \* the delegates a run_delegate call waits on, once each
    ClientLeaves,    \* the client may give up on a call before its deadline
    Interactive,     \* the delegates started interactive: true
    MaxPersonTurns,  \* turns a person starts in an interactive delegate
    Stalls,          \* the delegates whose turn may end with no report (F-150)
    MaxAgain,        \* starts of a branch again, its row with no report and its process gone
    MaxWakes,        \* turns of a delegate's own, a background command's wake (F-155)
    Queued,          \* the delegates whose start's lease is queued, the caller not waiting (F-170)
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
    "NewUuid",               \* the turn's message is written again under a new uuid
    "LastReply",             \* an interactive delegate's report is its transcript's last reply
    "NoPointer",             \* a report too long to type waits for a waiter (F-132), never typed
    "IdleInMemory",          \* the idle notice's mark is kept in memory, not as Mailbox's key
    "IdlePerDelegate",       \* the idle notice's key names the delegate, not its idle state
    "StartOverLive",         \* a second start of a branch goes on while its session is live
    "BriefAfterInit",        \* a headless start waits for its init before its message
    "StatusEndsWork",        \* the lease's owner says a refused, finished or failed row ended
    "TurnInMemory",          \* an own turn's notice mark is kept in memory, not as Mailbox's key
    "TakeStale",             \* Sessions takes a request whose caller's deadline passed
    "StartOwedInMemory",     \* the parent owed a queued start's outcome is kept in memory only
    "StartNoKey"             \* a queued start's outcome is told under no key Mailbox checks
}

ASSUME Break \in Breaks
ASSUME Interactive \subseteq Delegates /\ MaxPersonTurns \in Nat
ASSUME Cap \in Nat /\ MaxRestarts \in Nat /\ MaxKills \in Nat /\ MaxParentStops \in Nat
ASSUME Awaited \subseteq Delegates /\ ClientLeaves \in BOOLEAN
ASSUME Stalls \subseteq Delegates /\ MaxAgain \in Nat /\ MaxWakes \in Nat
ASSUME Queued \subseteq Delegates

Parent == "parent"

VARIABLES
    up,           \* the framework runs
    restarts,     \* restarts so far
    parentRuns,   \* a parent process runs
    turn,         \* the parent's turn runs
    parentStops,  \* the parent's process ended so far
    parentTurned, \* a turn of the parent's current process has ended
    status,       \* table: d -> "none", "refused", "starting", "running", "resuming",
                  \*          "finished", "failed", "ended"
    held,         \* in memory: delegates whose report waits to be stored (HeldInMemory only)
    resumes,      \* table: d -> resumes so far
    proc,         \* d -> the delegate's process: "none", "waiting" (held, no message taken),
                  \*      "working" (the turn of its message), "person" (a person's turn),
                  \*      "idle" (after its last reply), "stalled" (its turn ended with no
                  \*      report), "own" (a turn its own background command woke), "dead"
    reply,        \* d -> the transcript's last reply, by the turn it ends: "none" (the
                  \*      current message's turn has not replied), "brief" (that turn's),
                  \*      "person" (a person's later turn's), "own" (its own turn's)
    kills,        \* kills so far
    persons,      \* a person's turns so far
    rsrc,         \* table: d -> the turn its report was read from: "none" (a notice),
                  \*          "brief", "person"
    stops,        \* in memory: delegates whose Stop event Intake holds, not yet handled
    call,         \* in memory: d -> "none", "start", "resume": Delegates' call of Sessions;
                  \*            "lease": its wait for a queued lease's one more answer
    queue,        \* Sessions' mailbox: d -> the request of the latest call not yet taken:
                  \*           "none", "start", "resume"
    late,         \* d -> the caller's deadline of that request has passed
    sess,         \* Sessions: d -> its row of the latest call: "none", "start" or "resume"
                  \*           (written, under way), "held" (a headless process held,
                  \*           its init not read), "running", "refused" (free), "orphan"
                  \*           (a process held with no line, for Recoveries)
    marked,       \* Stream's table: d -> the turn's message is marked under the row's uuid
    pipe,         \* d -> message lines in the current process's FIFO, not yet taken
    taken,        \* d -> turn messages the delegate's processes took
    resumed,      \* d -> resumes Sessions made
    idles,        \* d -> its idle states so far: the current one's number
    overdue,      \* in memory: d -> Delegates' wake at the bound came in the current idle state
    told,         \* d -> notices told in the current idle state
    keys,         \* Mailbox's table: the keys the idle notices are stored under
    againStarts,  \* starts of a branch again so far
    woken,        \* d -> its own turns begun so far: the current one's number
    ownDone,      \* the log or transcript: <<d, n>> whose own turn n ended, with its result
    ownTold,      \* <<d, n>> -> notices told of that own turn
    sched,        \* the Scheduler: d -> "none", or "queued" (its request waits in the queue)
    owed,         \* table: d -> the parent is owed the queued start's outcome
    atOnce,       \* ghost: d -> the start answered queued at once
    startTold,    \* ghost: d -> notices told of the queued start's outcome
    \* Delivery's, for the reports: row d is d's report
    row, hand, claimed, wire, waiter, dcall, tx, fold, rmem, last, unsure, lost, wrong

parentVars == <<parentRuns, turn, parentStops, parentTurned>>
delegateVars == <<status, held, resumes, proc, reply, kills, persons, rsrc>>
callVars == <<call, queue, late, sess, marked, pipe, taken, resumed>>
\* Item 14's: the idle notice and the start idempotent per branch (F-150); the
\* queued start's lease and its notice (F-170).
policyVars == <<idles, overdue, told, keys, againStarts, woken, ownDone, ownTold,
                sched, owed, atOnce, startTold>>
leaseVars == <<sched, owed, atOnce, startTold>>
dvars == <<row, hand, claimed, wire, waiter, dcall, tx, fold, rmem, last, unsure, lost, wrong>>
vars == <<up, restarts, parentVars, delegateVars, stops, callVars, policyVars, dvars>>

\* The parent's process Mailbox sees: one number per process.
ParentProc == IF parentRuns THEN parentStops + 1 ELSE 0

D == INSTANCE Delivery WITH
       Ids <- Delegates, Addrs <- {Parent}, Headless <- {}, Senders <- Delegates,
       MaxSent <- 0, Awaited <- Awaited, ClientLeaves <- ClientLeaves, SelfTurns <- FALSE,
       MaxRestarts <- 0, MaxEnds <- 0, MaxPrompts <- 0, MaxStops <- 0,
       Break <- IF Break = "NoPointer" THEN "NoPointer" ELSE "none",
       up <- up,
       pr <- [a \in {Parent} |-> ParentProc],
       idle <- [a \in {Parent} |-> ~turn],
       stopping <- [a \in {Parent} |-> FALSE],
       over <- [a \in {Parent} |-> FALSE],
       turned <- [a \in {Parent} |-> parentTurned], Long <- Delegates, Launched <- {},
       call <- dcall,
       restarts <- 0, lives <- 0, ends <- 0, prompts <- 0, stops <- 0, readAt <- 0,
       forced <- {}, fcall <- {}

\* Delegates that count against the cap: started, or starting, and not yet ended.
Active == {d \in Delegates :
             status[d] \in {"starting", "running", "resuming", "finished", "failed"}}
Counted == IF Break = "CapSkipsStarting"
             THEN {d \in Active : status[d] # "starting"} ELSE Active

\* The turn's message is marked before Sessions is called, for the start to
\* carry or write; under BriefAfterInit a headless one's is not.
MarkedFirst(d) == d \in Interactive \/ Break # "BriefAfterInit"

\* The report is handed to Mailbox: its row is stored.
Stored(d) == row[d].st # "none"

\* Idle with no report: its row is running, with no call under way, and its
\* turn ended with no report, its message taken, so nothing is due to it.
Idle(d) == status[d] = "running" /\ call[d] = "none" /\ proc[d] = "stalled" /\ pipe[d] = 0

\* The key the idle notice is stored under: the delegate's current idle
\* state, which Mailbox takes once. IdlePerDelegate names the delegate only.
IdleKey(d) == IF Break = "IdlePerDelegate" THEN <<d, 0>> ELSE <<d, idles[d]>>

\* What Delegates.Work answers the Scheduler of a delegate's lease (F-163's
\* new-1): ended once the row never called (none) or ended, or once it is
\* refused, finished or failed and Sessions' row of it is free, so no
\* process of it may live. Under StatusEndsWork the status alone answers.
SessionsFree(d) == sess[d] \in {"none", "refused"}
WorkEnded(d) ==
    \/ status[d] \in {"none", "ended"}
    \/ status[d] \in {"refused", "finished", "failed"} /\ (SessionsFree(d) \/ Break = "StatusEndsWork")

\* The key an own turn's notice is stored under: its result's uuid.
TurnKey(d, n) == <<"turn", d, n>>
Turns == Delegates \X (1..MaxWakes)

\* The key a queued start's notice is stored under: its row's.
StartKey(d) == <<"start", d>>

-----------------------------------------------------------------------------
Init ==
    /\ up = TRUE /\ restarts = 0
    /\ parentRuns = TRUE /\ turn = FALSE /\ parentStops = 0 /\ parentTurned = TRUE
    /\ status = [d \in Delegates |-> "none"]
    /\ held = {}
    /\ resumes = [d \in Delegates |-> 0]
    /\ proc = [d \in Delegates |-> "none"]
    /\ reply = [d \in Delegates |-> "none"]
    /\ kills = 0 /\ persons = 0
    /\ rsrc = [d \in Delegates |-> "none"]
    /\ stops = {}
    /\ call = [d \in Delegates |-> "none"]
    /\ queue = [d \in Delegates |-> "none"]
    /\ late = [d \in Delegates |-> FALSE]
    /\ sess = [d \in Delegates |-> "none"]
    /\ marked = [d \in Delegates |-> FALSE]
    /\ pipe = [d \in Delegates |-> 0]
    /\ taken = [d \in Delegates |-> 0]
    /\ resumed = [d \in Delegates |-> 0]
    /\ idles = [d \in Delegates |-> 0]
    /\ overdue = [d \in Delegates |-> FALSE]
    /\ told = [d \in Delegates |-> 0]
    /\ keys = {}
    /\ againStarts = 0
    /\ woken = [d \in Delegates |-> 0] /\ ownDone = {} /\ ownTold = [t \in Turns |-> 0]
    /\ sched = [d \in Delegates |-> "none"] /\ owed = [d \in Delegates |-> FALSE]
    /\ atOnce = [d \in Delegates |-> FALSE] /\ startTold = [d \in Delegates |-> 0]
    /\ row =[d \in Delegates |-> D!NoRow] /\ hand = {} /\ claimed = {}
    /\ wire = [d \in Delegates |-> 0] /\ waiter = [a \in {Parent} |-> 0]
    /\ dcall = [d \in Delegates |-> "none"]
    /\ tx = [a \in {Parent} |-> <<>>] /\ fold = [d \in Delegates |-> "none"]
    /\ rmem = {} /\ last = [a \in {Parent} |-> D!NoResult]
    /\ unsure = {} /\ lost = {} /\ wrong = {}

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; what it holds in memory does not *)

\* Sessions is another process: a call it took runs on, and a request in its
\* mailbox waits there to be taken (F-166). Under HeldInMemory
\* the reports not yet stored go with the memory. The wake at an idle
\* delegate's bound is in memory, so the bound starts again; under
\* IdleInMemory the notices' marks go too, and under TurnInMemory the own
\* turns' notices' marks.
FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ stops' = {}
    /\ call' = [d \in Delegates |-> "none"]
    /\ held' = {}
    /\ overdue' = [d \in Delegates |-> FALSE]
    /\ keys' = CASE Break = "IdleInMemory" -> {}
                 [] Break = "TurnInMemory" -> {k \in keys : k[1] # "turn"}
                 [] OTHER -> keys
    \* The Scheduler is another process: its queue runs on. Under StartOwedInMemory
    \* the parent owed a queued start's outcome is forgotten.
    /\ owed' = IF Break = "StartOwedInMemory" THEN [d \in Delegates |-> FALSE] ELSE owed
    /\ D!Restart
    /\ UNCHANGED <<parentVars, status, resumes, proc, reply, kills, persons, rsrc,
                   queue, late, sess, marked, pipe, taken, resumed, idles, told, againStarts,
                   woken, ownDone, ownTold, sched, atOnce, startTold>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<restarts, parentVars, delegateVars, stops, callVars, policyVars, dvars>>

\* A delegate's agent process crashes and its supervisor starts it again
\* (B4), in one step: nothing reads its memory in between. Delegates' call
\* of it under way answers {:unknown, :restarted}, so the row waits for
\* Settled; a Stop event of it not yet passed on may be lost, for the
\* transcript's reply. Sessions' start or resume under way is cut, and its
\* row adopted at its deadline (Start.tla's Adopt): refused with nothing
\* held, or confirmed once its message went in with the hold, which
\* SessionsDecides and Confirmed still stand for; or an orphan, a headless
\* process held with no line when the crash fell between the hold and the
\* write, which never confirms and which Recoveries ends (OrphanEnded). A
\* request not yet taken goes with the process's mailbox. Delegates' own wait
\* for a queued lease is not the agent's, and runs on.
RestartAgent(d) ==
    /\ up /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ call' = [call EXCEPT ![d] = IF @ = "lease" THEN @ ELSE "none"]
    /\ queue' = [queue EXCEPT ![d] = "none"]
    /\ stops' \in {stops, stops \ {d}}
    /\ \/ UNCHANGED <<sess, proc, resumed>>
       \/ /\ sess[d] \in {"start", "resume"} /\ d \notin Interactive
          /\ sess' = [sess EXCEPT ![d] = "orphan"]
          /\ proc' = [proc EXCEPT ![d] = "waiting"]
          /\ resumed' = [resumed EXCEPT ![d] = IF sess[d] = "resume" THEN @ + 1 ELSE @]
    /\ UNCHANGED <<up, parentVars, status, held, resumes, reply, kills, persons, rsrc, late,
                   marked, pipe, taken, policyVars, dvars>>

\* The parent's agent process crashes and its supervisor starts it again: a
\* hand of a report to the parent under way is cut, its mark kept
\* (Delivery.tla's AgentCut). Its turn and its process outside run on.
RestartParent ==
    /\ up /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ \E went \in BOOLEAN : D!AgentCut(Parent, went)
    /\ UNCHANGED <<up, parentVars, delegateVars, stops, callVars, policyVars>>

\* Recoveries ends an orphan's process by its record, or finds it gone;
\* Sessions' row is then stopped, free.
OrphanEnded(d) ==
    /\ up /\ sess[d] = "orphan"
    /\ sess' = [sess EXCEPT ![d] = "refused"]
    /\ proc' = [proc EXCEPT ![d] = "dead"]
    /\ UNCHANGED <<up, restarts, parentVars, stops, policyVars, dvars, status, held, resumes,
                   reply, kills, persons, rsrc, call, queue, late, marked, pipe, taken, resumed>>

-----------------------------------------------------------------------------
(* The parent: its turns, and its process ending and running again (a move) *)

PromptSent ==
    /\ parentRuns /\ ~turn /\ turn' = TRUE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, parentTurned, delegateVars, stops,
                   callVars, policyVars, dvars>>

TurnEnds ==
    /\ turn /\ turn' = FALSE /\ parentTurned' = TRUE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, delegateVars, stops, callVars,
                   policyVars, dvars>>

ParentStops ==
    /\ parentRuns /\ parentStops < MaxParentStops
    /\ parentRuns' = FALSE /\ turn' = FALSE /\ parentStops' = parentStops + 1
    /\ D!Exited(Parent, FALSE)
    /\ UNCHANGED <<up, restarts, parentTurned, delegateVars, stops, callVars, policyVars>>

ParentRuns ==
    /\ ~parentRuns /\ parentRuns' = TRUE
    /\ parentTurned' = FALSE
    /\ UNCHANGED <<up, restarts, turn, parentStops, delegateVars, stops, callVars, policyVars,
                   dvars>>

-----------------------------------------------------------------------------
(* A delegate's start, its resume, and Sessions' part in them *)

others == <<up, restarts, parentVars, stops, policyVars, dvars>>

\* Delegates calls Sessions: its call waits in memory, and the request, in
\* Sessions' mailbox, carries the caller's deadline, not yet passed.
Request(d, kind) ==
    /\ call' = [call EXCEPT ![d] = kind]
    /\ queue' = [queue EXCEPT ![d] = kind]
    /\ late' = [late EXCEPT ![d] = FALSE]

\* In a turn the parent calls start_delegate. The project and branch
\* checks may refuse it, and the cap must when it is reached. The row is
\* written first, as starting, and its lease asked. Granted, the call of
\* Sessions begins. The brief is marked before the call: by launch for an
\* interactive delegate, whose start carries it, and by stream for a
\* headless one, whose start writes it right after the hold (under
\* BriefAfterInit, only once it runs). Queued, for a delegate in Queued: the
\* row says its parent is owed the outcome, Delegates waits for the lease in
\* memory, and the start answers queued at once.
StartAsked(d) ==
    /\ up /\ parentRuns /\ turn /\ status[d] = "none"
    /\ \/ /\ status' = [status EXCEPT ![d] = "refused"]
          /\ UNCHANGED <<call, queue, late, marked, leaseVars>>
       \/ /\ Cardinality(Counted) < Cap \/ Break = "NoCap"
          /\ status' = [status EXCEPT ![d] = "starting"]
          /\ Request(d, "start")
          /\ marked' = [marked EXCEPT ![d] = MarkedFirst(d)]
          /\ UNCHANGED leaseVars
       \/ /\ d \in Queued /\ (Cardinality(Counted) < Cap \/ Break = "NoCap")
          /\ status' = [status EXCEPT ![d] = "starting"]
          /\ call' = [call EXCEPT ![d] = "lease"]
          /\ sched' = [sched EXCEPT ![d] = "queued"]
          /\ owed' = [owed EXCEPT ![d] = TRUE]
          /\ atOnce' = [atOnce EXCEPT ![d] = TRUE]
          /\ UNCHANGED <<queue, late, marked, startTold>>
    /\ UNCHANGED <<up, restarts, parentVars, stops, idles, overdue, told, keys, againStarts,
                   woken, ownDone, ownTold, dvars, held, resumes, proc, reply, kills, persons,
                   rsrc, sess, pipe, taken, resumed>>

\* The queued lease's one more answer (Schedule.tla's Tell). Delegates waits
\* for it in memory: granted, the call of Sessions begins as StartAsked's
\* does; refused, the row is refused with the reason and nothing held. With
\* no wait in memory (a restart), the answer reaches no one, and the row is
\* refused at its deadline (Settled).
LeaseAnswered(d) ==
    /\ sched[d] = "queued"
    /\ sched' = [sched EXCEPT ![d] = "none"]
    /\ IF call[d] = "lease"
         THEN \/ /\ Request(d, "start")
                 /\ marked' = [marked EXCEPT ![d] = MarkedFirst(d)]
                 /\ UNCHANGED status
              \/ /\ status' = [status EXCEPT ![d] = "refused"]
                 /\ call' = [call EXCEPT ![d] = "none"]
                 /\ UNCHANGED <<queue, late, marked>>
         ELSE UNCHANGED <<status, call, queue, late, marked>>
    /\ UNCHANGED <<up, restarts, parentVars, stops, idles, overdue, told, keys, againStarts,
                   woken, ownDone, ownTold, owed, atOnce, startTold, dvars, held, resumes, proc,
                   reply, kills, persons, rsrc, sess, pipe, taken, resumed>>

\* In a turn the parent starts the branch again. While the delegate's
\* session is live the start answers it and writes nothing: no step. A row
\* with no report whose process is gone does not count as running, so the
\* start goes on, as a new row with its own brief, under the cap that
\* counts it already; the old row is history, and its resume never comes.
\* StartOverLive goes on while the process lives.
StartAgain(d) ==
    /\ up /\ parentRuns /\ turn /\ status[d] = "running" /\ call[d] = "none"
    /\ reply[d] = "none" /\ againStarts < MaxAgain
    /\ againStarts' = againStarts + 1
    /\ proc[d] = "dead" \/ Break = "StartOverLive"
    \* The new row holds no process until Sessions starts one; a live one runs on.
    /\ proc' = [proc EXCEPT ![d] = IF @ = "dead" THEN "none" ELSE @]
    /\ status' = [status EXCEPT ![d] = "starting"]
    /\ resumes' = [resumes EXCEPT ![d] = 0]
    /\ Request(d, "start")
    /\ sess' = [sess EXCEPT ![d] = "none"]
    /\ marked' = [marked EXCEPT ![d] = MarkedFirst(d)]
    /\ taken' = [taken EXCEPT ![d] = 0]
    /\ resumed' = [resumed EXCEPT ![d] = 0]
    /\ UNCHANGED <<up, restarts, parentVars, stops, idles, overdue, told, keys, woken, ownDone,
                   ownTold, leaseVars, dvars, held, reply, kills, persons, rsrc, pipe>>

\* Sessions takes the request from its mailbox, whether Delegates runs or
\* not. In the caller's time it writes its own row first (Start.tla). Past
\* the caller's deadline it answers {:refused, :caller_gone} and writes
\* nothing, so a row Delegates refused with no Sessions row stays without a
\* process. TakeStale takes it as one in time.
Called(d) ==
    /\ queue[d] # "none" /\ sess[d] = "none"
    /\ queue' = [queue EXCEPT ![d] = "none"]
    /\ IF late[d] /\ Break # "TakeStale"
         THEN UNCHANGED sess
         ELSE sess' = [sess EXCEPT ![d] = queue[d]]
    /\ UNCHANGED <<others, delegateVars, call, late, marked, pipe, taken, resumed>>

\* The caller's deadline passes while the request waits in Sessions' mailbox.
\* It comes before the row's, so the row is not refused before it.
CallerLate(d) ==
    /\ queue[d] # "none" /\ ~late[d]
    /\ late' = [late EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<others, delegateVars, call, queue, sess, marked, pipe, taken, resumed>>

\* The caller's wait ends after its deadline: Delegates' call answers
\* {:unknown, {:timeout, wait}}, and the row waits for Settled while the
\* request may still wait in Sessions' mailbox.
CallGivesUp(d) ==
    /\ up /\ call[d] # "none" /\ queue[d] # "none" /\ late[d]
    /\ call' = [call EXCEPT ![d] = "none"]
    /\ UNCHANGED <<others, delegateVars, queue, late, sess, marked, pipe, taken, resumed>>

\* Sessions holds the process, which waits for its first message, or
\* refuses. A resumed process reads a FIFO of its own: no line written for
\* the process before reaches it (Stream.tla). An interactive process
\* starts with its message as the prompt argument the launch marked, and
\* its session file confirms it. A headless process is held first, and
\* the message marked before the call goes into its FIFO in the same step.
SessionsDecides(d) ==
    /\ sess[d] \in {"start", "resume"}
    /\ \/ /\ sess' = [sess EXCEPT ![d] = IF d \in Interactive THEN "running" ELSE "held"]
          /\ proc' = [proc EXCEPT ![d] = "waiting"]
          /\ pipe' = [pipe EXCEPT ![d] = IF marked[d] THEN 1 ELSE 0]
          /\ resumed' = [resumed EXCEPT ![d] = IF sess[d] = "resume" THEN @ + 1 ELSE @]
       \/ /\ sess' = [sess EXCEPT ![d] = "refused"]
          /\ UNCHANGED <<proc, pipe, resumed>>
    /\ UNCHANGED <<others, status, held, resumes, reply, kills, persons, rsrc, call, queue, late,
                   marked, taken>>

\* A held headless process's init, once it read its first line, confirms
\* the start; a process gone first is never confirmed, and the call is
\* refused (no process of it runs).
Confirmed(d) ==
    /\ sess[d] = "held"
    /\ \/ proc[d] \in {"working", "idle"} /\ sess' = [sess EXCEPT ![d] = "running"]
       \/ proc[d] = "dead" /\ sess' = [sess EXCEPT ![d] = "refused"]
    /\ UNCHANGED <<others, delegateVars, call, queue, late, marked, pipe, taken, resumed>>

\* What a settled call writes: a start runs or is refused; a resume runs,
\* or its refusal is the report, as a second kill's is.
Outcome(d, s) ==
    IF status[d] = "starting"
      THEN IF s = "running" THEN "running" ELSE "refused"
      ELSE IF s = "running" THEN "running" ELSE "failed"

\* The report is handed to Mailbox: the reply to the brief, from d to the
\* parent, stored as its row, read from the turn `src` ("none" for the
\* framework's notice). Under HeldInMemory it waits in memory first.
Report(d, src) ==
    /\ rsrc' = [rsrc EXCEPT ![d] = src]
    /\ IF Break = "HeldInMemory"
         THEN held' = held \cup {d} /\ UNCHANGED dvars
         ELSE /\ D!StoreRow(d, d, Parent, "reply", d, d)
              /\ UNCHANGED <<held, hand, claimed, wire, waiter, dcall, tx, fold, rmem, last,
                             unsure, lost, wrong>>

NoReport == UNCHANGED <<held, dvars, rsrc>>

\* The turn the report is read from: the reply to the brief's key, the
\* result of the turn the brief or the word to go on started. LastReply
\* reads the transcript's last reply, whatever turn it ends.
ReplyTurn(d) == IF Break = "LastReply" THEN reply[d] ELSE "brief"

Settle(d, s) ==
    /\ status' = [status EXCEPT ![d] = Outcome(d, s)]
    /\ IF Outcome(d, s) = "failed" THEN Report(d, "none") ELSE NoReport

\* Sessions answered the call under way: its row settled, or, with no row, a
\* request taken past the caller's deadline while the call still waited.
CallAnswered(d) ==
    /\ up /\ call[d] \in {"start", "resume"}
    /\ \/ sess[d] \in {"running", "refused"}
       \/ sess[d] = "none" /\ queue[d] = "none"
    /\ call' = [call EXCEPT ![d] = "none"]
    /\ IF status[d] \in {"starting", "resuming"}
         THEN Settle(d, sess[d]) /\ UNCHANGED resumes
         \* ResumeBeforeRow: the row learns of the resume only now.
         ELSE /\ resumes' = [resumes EXCEPT ![d] = @ + 1]
              /\ UNCHANGED status /\ NoReport
    /\ UNCHANGED <<up, restarts, parentVars, stops, proc, reply, kills, persons, queue, late, sess,
                   marked, pipe, taken, resumed, policyVars>>

\* After a restart or a call's give-up, a row whose call was cut off is
\* settled by Sessions' row of that call, once that row is settled; with
\* none by the row's deadline, which a request waiting in the caller's time
\* has not reached, the call never reached Sessions, and it is not made again.
Settled(d) ==
    /\ up /\ call[d] = "none" /\ status[d] \in {"starting", "resuming"}
    /\ \/ sess[d] \in {"running", "refused"}
       \/ sess[d] = "none" /\ (queue[d] = "none" \/ late[d])
       \/ Break = "SettleEarly"
    /\ Settle(d, sess[d])
    /\ UNCHANGED <<up, restarts, parentVars, stops, resumes, proc, reply, kills, persons, callVars,
                   policyVars>>

\* A headless delegate's message goes in through Stream under the uuid the
\* row holds, which Stream refuses a second time. Under NewUuid each write
\* has a uuid of its own.
InputWritten(d) ==
    /\ up /\ d \notin Interactive /\ status[d] = "running" /\ call[d] = "none"
    /\ proc[d] \in {"waiting", "working", "idle"} /\ pipe[d] = 0
    /\ ~marked[d] \/ Break = "NewUuid"
    /\ marked' = [marked EXCEPT ![d] = TRUE]
    /\ pipe' = [pipe EXCEPT ![d] = 1]
    /\ UNCHANGED <<others, delegateVars, call, queue, late, sess, taken, resumed>>

\* The delegate takes its message and starts a turn.
InputTaken(d) ==
    /\ proc[d] \in {"waiting", "idle"} /\ pipe[d] > 0
    /\ pipe' = [pipe EXCEPT ![d] = @ - 1]
    /\ proc' = [proc EXCEPT ![d] = "working"]
    /\ reply' = [reply EXCEPT ![d] = "none"]
    /\ taken' = [taken EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<others, status, held, resumes, kills, persons, rsrc, call, queue, late, sess,
                   marked, resumed>>

\* A person attached to an interactive delegate types a prompt once its
\* turn has ended: a turn of its own, after the brief's.
PersonTypes(d) ==
    /\ d \in Interactive /\ proc[d] = "idle" /\ persons < MaxPersonTurns
    /\ proc' = [proc EXCEPT ![d] = "person"]
    /\ persons' = persons + 1
    /\ UNCHANGED <<others, status, held, resumes, reply, kills, rsrc, callVars>>

\* Its turn ends with its last reply, and its Stop event (the result in its
\* log, or an interactive session's Stop hook) comes. A kill before that is
\* written loses it; here, with the framework down the event reaches nothing.
\* A headless start reads the init every 200 ms while it waits, and a turn
\* takes longer than that: the init is read before the turn it began ends.
\* A turn that ended and a process that exited within one read would leave
\* the start refused and the reply unread (F-152's build note, new-2).
DelegateFinishes(d) ==
    /\ proc[d] \in {"working", "person"}
    /\ sess[d] # "held"
    /\ proc' = [proc EXCEPT ![d] = "idle"]
    /\ reply' = [reply EXCEPT ![d] = IF proc[d] = "working" THEN "brief" ELSE "person"]
    /\ stops' = IF up THEN stops \cup {d} ELSE stops
    /\ UNCHANGED <<up, restarts, parentVars, status, held, resumes, kills, persons, rsrc, callVars,
                   policyVars, dvars>>

\* Its turn ends with nothing the framework reads as its report (an
\* interactive turn with no reply text): an idle state of its own begins.
\* As in DelegateFinishes, the init is read before a turn ends.
TurnEndsBare(d) ==
    /\ d \in Stalls /\ proc[d] = "working"
    /\ sess[d] # "held"
    /\ proc' = [proc EXCEPT ![d] = "stalled"]
    /\ idles' = [idles EXCEPT ![d] = @ + 1]
    /\ overdue' = [overdue EXCEPT ![d] = FALSE]
    /\ told' = [told EXCEPT ![d] = 0]
    /\ UNCHANGED <<up, restarts, parentVars, status, held, resumes, reply, kills, persons, rsrc,
                   stops, callVars, keys, againStarts, woken, ownDone, ownTold, leaseVars, dvars>>

\* A background command of its own ends and wakes it: a turn that answers no
\* message (F-155). Its row may still be running, its report not yet read.
OwnWakes(d) ==
    /\ proc[d] = "idle" /\ status[d] \in {"running", "finished"} /\ woken[d] < MaxWakes
    /\ proc' = [proc EXCEPT ![d] = "own"]
    /\ woken' = [woken EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<up, restarts, parentVars, status, held, resumes, reply, kills, persons, rsrc,
                   stops, callVars, idles, overdue, told, keys, againStarts, ownDone, ownTold,
                   leaseVars, dvars>>

\* That turn ends with its last reply and its result, which the log or the
\* transcript keeps, and its Stop event comes.
OwnTurnEnds(d) ==
    /\ proc[d] = "own"
    /\ proc' = [proc EXCEPT ![d] = "idle"]
    /\ reply' = [reply EXCEPT ![d] = "own"]
    /\ ownDone' = ownDone \cup {<<d, woken[d]>>}
    /\ stops' = IF up THEN stops \cup {d} ELSE stops
    /\ UNCHANGED <<up, restarts, parentVars, status, held, resumes, kills, persons, rsrc, callVars,
                   idles, overdue, told, keys, againStarts, woken, ownTold, leaseVars, dvars>>

DelegateKilled(d) ==
    /\ proc[d] \in {"waiting", "working", "person", "idle", "stalled", "own"} /\ kills < MaxKills
    /\ proc' = [proc EXCEPT ![d] = "dead"]
    /\ kills' = kills + 1
    /\ UNCHANGED <<others, status, held, resumes, reply, persons, rsrc, callVars>>

-----------------------------------------------------------------------------
(* Delegates: from a finish or a kill to the report handed to Mailbox *)

\* The Stop event is the cue to read the report. Only a running delegate's
\* row changes, so the event and the transcript fallback give one report.
StopHandled(d) ==
    /\ up /\ d \in stops
    /\ stops' = stops \ {d}
    /\ IF status[d] = "running"
         THEN status' = [status EXCEPT ![d] = "finished"] /\ Report(d, ReplyTurn(d))
         ELSE UNCHANGED status /\ NoReport
    /\ UNCHANGED <<up, restarts, parentVars, resumes, proc, reply, kills, persons, callVars,
                   policyVars>>

\* A restart lost the Stop event: the transcript's reply is the report.
TranscriptRead(d) ==
    /\ up /\ Break # "NoTranscriptFallback"
    /\ status[d] = "running" /\ reply[d] # "none" /\ d \notin stops
    /\ status' = [status EXCEPT ![d] = "finished"] /\ Report(d, ReplyTurn(d))
    /\ UNCHANGED <<up, restarts, parentVars, resumes, proc, reply, kills, persons, stops, callVars,
                   policyVars>>

\* Under HeldInMemory: the report waits in memory, then is stored.
HeldStored(d) ==
    /\ up /\ d \in held
    /\ held' = held \ {d}
    /\ D!StoreRow(d, d, Parent, "reply", d, d)
    /\ UNCHANGED <<up, restarts, parentVars, status, resumes, proc, reply, kills, persons, rsrc,
                   stops, callVars, policyVars, hand, claimed, wire, waiter, dcall, tx, fold, rmem,
                   last, unsure, lost, wrong>>

\* A process killed before its last reply is resumed once: the row counts
\* the resume, as resuming, before Sessions is asked, with the next turn's
\* message under a uuid of its own (marked by launch for an interactive
\* one, by stream for a headless one). A second kill is the report.
KillSeen(d) ==
    /\ up /\ status[d] = "running" /\ call[d] = "none" /\ proc[d] = "dead" /\ reply[d] = "none"
    /\ IF resumes[d] = 0 \/ Break = "ResumeAgain"
         THEN /\ Request(d, "resume")
              /\ sess' = [sess EXCEPT ![d] = "none"]
              /\ marked' = [marked EXCEPT ![d] = MarkedFirst(d)]
              /\ IF Break = "ResumeBeforeRow"
                   THEN UNCHANGED <<status, resumes>>
                   ELSE /\ status' = [status EXCEPT ![d] = "resuming"]
                        /\ resumes' = [resumes EXCEPT ![d] = @ + 1]
              /\ NoReport
         ELSE /\ status' = [status EXCEPT ![d] = "failed"]
              /\ Report(d, "none")
              /\ UNCHANGED <<resumes, call, queue, late, sess, marked>>
    /\ UNCHANGED <<up, restarts, parentVars, proc, reply, kills, persons, stops, pipe, taken,
                   resumed, policyVars>>

\* Delegates' wake at the bound the app sets, from when it first read the
\* idle state: kept in memory, so a restart starts it again.
BoundPasses(d) ==
    /\ up /\ Idle(d) /\ ~overdue[d]
    /\ overdue' = [overdue EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<up, restarts, parentVars, delegateVars, stops, callVars, idles, told, keys,
                   againStarts, woken, ownDone, ownTold, leaseVars, dvars>>

\* Past the bound, the parent is told once per idle state: a notice stored
\* in Mailbox under the state's key, which Mailbox takes once. Nothing is
\* done to the delegate.
IdleTold(d) ==
    /\ up /\ Idle(d) /\ overdue[d] /\ IdleKey(d) \notin keys
    /\ keys' = keys \cup {IdleKey(d)}
    /\ told' = [told EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<up, restarts, parentVars, delegateVars, stops, callVars, idles, overdue,
                   againStarts, woken, ownDone, ownTold, leaseVars, dvars>>

\* An own turn's last reply goes to the parent once the report is handed
\* on: a notice stored under the turn's key, which Mailbox takes once.
TurnTold(d, n) ==
    /\ up /\ <<d, n>> \in ownDone /\ Stored(d) /\ TurnKey(d, n) \notin keys
    /\ keys' = keys \cup {TurnKey(d, n)}
    /\ ownTold' = [ownTold EXCEPT ![<<d, n>>] = @ + 1]
    /\ UNCHANGED <<up, restarts, parentVars, delegateVars, stops, callVars, idles, overdue, told,
                   againStarts, woken, ownDone, leaseVars, dvars>>

\* A queued start's outcome, once its row has left starting: a notice to the
\* parent stored under the row's key, which Mailbox takes once. StartNoKey
\* stores it whether or not the key was taken.
StartTold(d) ==
    /\ up /\ owed[d] /\ status[d] # "starting"
    /\ StartKey(d) \notin keys \/ Break = "StartNoKey"
    /\ keys' = keys \cup {StartKey(d)}
    /\ startTold' = [startTold EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<up, restarts, parentVars, delegateVars, stops, callVars, idles, overdue, told,
                   againStarts, woken, ownDone, ownTold, sched, owed, atOnce, dvars>>

\* The row's mark cleared once Mailbox has the notice: a write of its own, so
\* a restart may fall between the two.
StartCleared(d) ==
    /\ up /\ owed[d] /\ StartKey(d) \in keys
    /\ owed' = [owed EXCEPT ![d] = FALSE]
    /\ UNCHANGED <<up, restarts, parentVars, delegateVars, stops, callVars, idles, overdue, told,
                   keys, againStarts, woken, ownDone, ownTold, sched, atOnce, startTold, dvars>>

\* The delegate ends, its process with it, only once its report is delivered.
DelegateEnds(d) ==
    /\ up /\ status[d] \in {"finished", "failed"}
    /\ row[d].st = "delivered" \/ Break = "EndBeforeDelivery"
    /\ status' = [status EXCEPT ![d] = "ended"]
    /\ proc' = [proc EXCEPT ![d] = "none"]
    /\ UNCHANGED <<others, held, resumes, reply, kills, persons, rsrc, callVars>>

-----------------------------------------------------------------------------
(* Mailbox: the report into the parent (Delivery.tla) *)

Mailbox(A) == A /\ UNCHANGED <<up, restarts, parentVars, delegateVars, stops, callVars, policyVars>>

\* Claude Code takes the report: a turn of the parent starts with it.
Takes(d) ==
    /\ D!Take(d) /\ turn' = TRUE
    /\ UNCHANGED <<up, restarts, parentRuns, parentStops, parentTurned, delegateVars, stops,
                   callVars, policyVars>>

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
    \/ CallAnswered(d) \/ CallGivesUp(d) \/ Settled(d) \/ InputWritten(d)
    \/ StopHandled(d) \/ TranscriptRead(d) \/ HeldStored(d) \/ KillSeen(d)
    \/ DelegateEnds(d) \/ BoundPasses(d) \/ IdleTold(d)
    \/ \E n \in 1..MaxWakes : TurnTold(d, n)
    \/ StartTold(d) \/ StartCleared(d)

Next ==
    \/ FrameworkDies \/ FrameworkStarts \/ RestartParent
    \/ PromptSent \/ TurnEnds \/ ParentStops \/ ParentRuns
    \/ Mailbox(D!Connects(Parent))
    \/ \E d \in Delegates : StartAsked(d) \/ StartAgain(d) \/ Called(d) \/ CallerLate(d)
                            \/ LeaseAnswered(d)
                            \/ SessionsDecides(d) \/ Confirmed(d)
                            \/ InputTaken(d) \/ PersonTypes(d) \/ DelegateFinishes(d)
                            \/ TurnEndsBare(d) \/ DelegateKilled(d)
                            \/ RestartAgent(d) \/ OrphanEnded(d)
                            \/ OwnWakes(d) \/ OwnTurnEnds(d)
                            \/ Framework(d)
                            \/ Mailboxes(d)

\* Sessions decides a call it took, and a delegate reads its stdin. A call
\* that waits is taken or reaches its deadline. The agent's call and the
\* handler's end need not happen.
Fairness ==
    /\ WF_vars(FrameworkStarts) /\ WF_vars(ParentRuns) /\ WF_vars(TurnEnds)
    /\ SF_vars(Mailbox(D!Connects(Parent)))
    /\ \A d \in Delegates :
         /\ WF_vars(Called(d)) /\ WF_vars(SessionsDecides(d)) /\ WF_vars(Confirmed(d))
         /\ WF_vars(OrphanEnded(d))
         /\ WF_vars(CallAnswered(d))
         /\ WF_vars(Settled(d)) /\ WF_vars(InputWritten(d)) /\ WF_vars(InputTaken(d))
         /\ WF_vars(StopHandled(d)) /\ WF_vars(TranscriptRead(d)) /\ WF_vars(HeldStored(d))
         /\ WF_vars(KillSeen(d)) /\ WF_vars(DelegateEnds(d))
         /\ WF_vars(BoundPasses(d)) /\ WF_vars(IdleTold(d))
         /\ \A n \in 1..MaxWakes : WF_vars(TurnTold(d, n))
         /\ WF_vars(LeaseAnswered(d)) /\ WF_vars(StartTold(d)) /\ WF_vars(StartCleared(d))
         /\ SF_vars(\E t \in {"waiter", "typed", "call"} : Mailbox(D!Mark(d, t)))
         /\ SF_vars(Mailbox(D!Handed(d))) /\ SF_vars(Takes(d))
         /\ SF_vars(RowSteps(d))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ up \in BOOLEAN /\ parentRuns \in BOOLEAN /\ turn \in BOOLEAN /\ parentTurned \in BOOLEAN
    /\ status \in [Delegates -> {"none", "refused", "starting", "running", "resuming",
                                 "finished", "failed", "ended"}]
    /\ held \subseteq Delegates
    /\ proc \in [Delegates -> {"none", "waiting", "working", "person", "idle", "stalled", "own",
                               "dead"}]
    /\ reply \in [Delegates -> {"none", "brief", "person", "own"}]
    /\ rsrc \in [Delegates -> {"none", "brief", "person", "own"}]
    /\ call \in [Delegates -> {"none", "start", "resume", "lease"}]
    /\ sched \in [Delegates -> {"none", "queued"}] /\ owed \in [Delegates -> BOOLEAN]
    /\ atOnce \in [Delegates -> BOOLEAN] /\ startTold \in [Delegates -> Nat]
    /\ queue \in [Delegates -> {"none", "start", "resume"}]
    /\ late \in [Delegates -> BOOLEAN]
    /\ \A d \in Delegates : queue[d] # "none" => sess[d] = "none"
    /\ sess \in [Delegates -> {"none", "start", "resume", "held", "running", "refused", "orphan"}]
    /\ stops \subseteq Delegates
    /\ idles \in [Delegates -> Nat] /\ overdue \in [Delegates -> BOOLEAN]
    /\ told \in [Delegates -> Nat] /\ againStarts \in Nat
    /\ keys \subseteq (Delegates \X Nat) \cup ({"turn"} \X Delegates \X Nat)
                      \cup ({"start"} \X Delegates)
    /\ woken \in [Delegates -> Nat] /\ ownDone \subseteq Turns /\ ownTold \in [Turns -> Nat]
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

\* An interactive delegate's report is the reply to its brief: never a
\* later turn a person started in it.
ReportAnswersTheBrief == \A d \in Delegates : rsrc[d] # "person"

\* No process runs for a delegate whose start was refused: a held process
\* always has a row that reports it.
RefusedHoldsNothing ==
    \A d \in Delegates : status[d] = "refused" => proc[d] \in {"none", "dead"}

\* The owner's promise the Scheduler's release rests on (Schedule.tla's
\* `work`, Boxes.tla's SeatsHold): work it says ended has no process. A
\* finished delegate's process lives until it ends, so StatusEndsWork fails.
WorkEndedIsFree == \A d \in Delegates : WorkEnded(d) => proc[d] \in {"none", "dead"}

\* Each process takes one turn's message: the brief, or a resumed one's.
OneMessagePerProcess == \A d \in Delegates : taken[d] <= resumed[d] + 1

\* Every finished delegate's report, and a second kill's report too, reaches
\* the parent's transcript: as a call's answer or by the waiter or the typed
\* write. The one exception is a call's write to a client that gave up by
\* its own limit, under ClientLeaves.
ReportArrives ==
    \A d \in Delegates : (reply[d] # "none" \/ status[d] = "failed")
                           ~> (D!InTx(d) \/ <<d, "left">> \in lost)

\* With the cap (no ClientLeaves), there is no exception.
ReportArrivesUnderCap ==
    \A d \in Delegates : (reply[d] # "none" \/ status[d] = "failed") ~> D!InTx(d)

\* A delegate whose report is delivered ends.
DeliveredDelegateEnds ==
    \A d \in Delegates : row[d].st = "delivered" ~> status[d] = "ended"

\* Every start and resume settles.
CallSettles ==
    \A d \in Delegates : status[d] \in {"starting", "resuming"}
                           ~> status[d] \notin {"starting", "resuming"}

\* A delegate idle with no report is told to its parent at most once per
\* idle state, whatever restarts come.
IdleToldOnce == \A d \in Delegates : told[d] <= 1

\* ... and always once the bound passes while the state lasts: it is told,
\* or the state ends (a turn starts, a report, or the delegate ends).
IdleNoticed == \A d \in Delegates : Idle(d) ~> (told[d] >= 1 \/ ~Idle(d))

\* A delegate's own turn is told to its parent at most once, whatever
\* restarts come (F-155) ...
TurnToldOnce == \A t \in Turns : ownTold[t] <= 1

\* ... never as its report: the report is the brief's turn's reply ...
TurnNotReport == \A d \in Delegates : rsrc[d] # "own"

\* ... and always: every own turn that ended is told.
TurnNoticed == \A t \in Turns : t \in ownDone ~> ownTold[t] >= 1

\* A start answered queued at once has its outcome told to its parent at most
\* once, whatever restarts come (F-170) ...
StartToldOnce == \A d \in Delegates : startTold[d] <= 1

\* ... and always: its row leaves starting, and the outcome is told.
StartNoticed == \A d \in Delegates : atOnce[d] ~> startTold[d] >= 1

=============================================================================
