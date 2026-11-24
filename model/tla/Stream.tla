------------------------------- MODULE Stream -------------------------------
(***************************************************************************)
(* How a headless delegate is held and spoken to: lines written into its  *)
(* stdin, its events read from a log at a persisted offset, its turns,    *)
(* replays and permission requests, with restarts of the framework        *)
(* between any two steps, the delegate's exit, its resume and its end.    *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                          *)
(*   Stream       the host's one writer for delegates: it marks, spools   *)
(*                and claims each line, reads the event log, and follows  *)
(*                a resumed session again (FollowAgain);                  *)
(*   Stream.Fold  the request rows, and the evidence that settles a       *)
(*                message's row: its replay (Handle), or the transcript   *)
(*                at the exit (ExitSeen); the end's guard (EndMarked);    *)
(*   Mailbox      the message's row, its one mark (Mark) and its settle:  *)
(*                Delivery.tla's, instanced as D, with the stream as the  *)
(*                transport. Stream keeps the line's claim and the        *)
(*                replay, not a message state of its own (R6, R7). Its   *)
(*                IntoEndedTurn and ReplayedOrFound are Delivery's        *)
(*                OnlyIntoEndedTurn and SendingSettles, checked here on   *)
(*                Stream's state; NoResultWait, MsgAfterEnd and           *)
(*                LogOnlyAtExit remove Delivery's guards;                 *)
(*   Stream.Line  the one encoder of the lines;                           *)
(*   ClaudeCLI    the wrapper, which opens the FIFO it is given;          *)
(*   Sessions     only as the one who starts the resumed process          *)
(*                (ProcStarts), tells Stream it held it (HeldTold), and   *)
(*                asks for the end once the report is delivered.          *)
(* And Claude Code 2.1.322 in -p stream-json mode (F-31's build note):    *)
(* it reads stdin line by line; a line that does not parse ends it; it    *)
(* replays each user line it takes and each answer that settled a request *)
(* (--replay-user-messages); a turn ends with exactly one result; it      *)
(* drops an answer to a request that is no longer pending; it drops a     *)
(* user line whose uuid its transcript holds, and acknowledges it with a  *)
(* replay of that uuid and no turn (skipDuplicate); end_session ends it.  *)
(*                                                                         *)
(* Each process has its own FIFO, in.<n> with n the row's resume count:   *)
(* the wrapper opens the one it is given, a follow again makes the next   *)
(* one, and a claim command names the FIFO of the process it was started  *)
(* for (cfifo). A message line is spooled to a file and written by a      *)
(* claim command, `exec 3<spool && rm spool && cat <&3 >fifo`, which      *)
(* outlives the framework: once the spool is gone the line goes in, by    *)
(* that command. A message line is longer than the pipe's atomic size, so *)
(* the command writes it in two parts (CatBegins, CatEnds), and a line    *)
(* another writer puts between them mixes with it. The command opens its  *)
(* FIFO for writing only once a process reads it: one started while none  *)
(* does waits until its deadline (ClaimTimesOut), and never reaches a     *)
(* later process, which reads another FIFO. So "undelivered" at an exit   *)
(* is final, and a resend is a new line, and a new spool, under its       *)
(* message's same uuid. An answer or an end line is at most the atomic    *)
(* size, so its write is one step here.                                   *)
(*                                                                         *)
(* The framework sees an exit only for a process it knows was started     *)
(* (seen, live_seen): Sessions tells it once it held the process          *)
(* (HeldTold), and a read or a write's check that finds the socket live   *)
(* sets it too. A follow again ends the cut line a death left at the      *)
(* log's end with a newline, so it is one line that does not parse and   *)
(* the resumed process's first event is whole.                            *)
(*                                                                         *)
(* Left abstract: the spool write before the claim (a death between them  *)
(* is a death before the claim); time and deadlines; what a line says;    *)
(* turns Claude Code starts on its own (a finished background task, or a  *)
(* cut-off turn it runs again at a resume), which this model leaves out;  *)
(* interrupts, beyond a request's cancel; the parent's delivery of the    *)
(* report (ReportDelivered), which Delegate.tla models, and which         *)
(* Sessions checks before it asks for the end.                            *)
(*                                                                         *)
(* Fairness: the framework's steps, the claim commands and Claude Code's  *)
(* reading and writing happen while they stay possible, and a session     *)
(* followed again is started. A request may never be answered, the        *)
(* delegate may exit at any time, a resume and an end may never be asked. *)
(*                                                                         *)
(* The requests are not Hold.tla's (F-119's build note, new-2): Claude     *)
(* Code holds a request, not the framework, so a restart cuts none, and    *)
(* the row follows the log (a request, an answer's replay, a cancel), not  *)
(* a connection the framework holds; there is no deadline, and an answer   *)
(* is a line whose outcome is read back later. Hold's cut at a restart and *)
(* its mark in memory do not fit that shape, so the requests stay here.    *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and   *)
(* has a Break_Stream_<value>.cfg that TLC must fail.                     *)
(*                                                                         *)
(* Defense in depth, with no Break: OneWaiting. Mark writes messages in   *)
(* order, each after the one before it is delivered, so a second message  *)
(* never waits beside the first; and idle is cleared by Mark and set only *)
(* by a result, which comes after the first message's replay. Stream's    *)
(* guards of EndMarked, behind Sessions' wait for the report: the turn's  *)
(* end (EndNeverCuts), no message under way and none found undelivered   *)
(* (EndLosesNoMessage). The report is delivered only while idle and after *)
(* the last message's turn, and Mark, which clears idle, clears it. They  *)
(* stay for a caller whose word on the report is wrong. And the resend    *)
(* under the same uuid, with Claude Code's drop of a uuid it holds        *)
(* (DropMsg, TakenOnce): with a FIFO per process, a message found         *)
(* undelivered never went in, so the resend is never a duplicate (F-51's  *)
(* build note, new-1 and new-4).                                          *)
(*                                                                         *)
(* Sessions' contract for a headless session's transport (F-163): a line   *)
(* written once, a message taken once across resumes, only into an ended   *)
(* turn (WrittenOnce, TakenOnce, IntoEndedTurn), and the evidence exact:   *)
(* delivered only if taken, undelivered at an exit only if not             *)
(* (DeliveredWasTaken, UndeliveredWasNotTaken), and every line in flight   *)
(* settled (ReplayedOrFound). Boxes.tla's hand is one write into an ended  *)
(* turn and its evidence `ev` is exact: these imply both for the stream    *)
(* transport. The claim command outlives the framework, so here a write    *)
(* may land after the call that started it was cut; Boxes.tla settles a    *)
(* row by the evidence only once no call is under way, and Delivery.tla    *)
(* reads the stream's evidence only once the process the line was for is   *)
(* gone, which covers the late write.                                      *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    MaxMsgs,      \* messages to the delegate, 1..MaxMsgs, in order
    MaxReqs,      \* permission requests of the delegate, 1..MaxReqs, in order
    MaxRestarts,  \* restarts of the framework
    MaxResumes,   \* resumes of the session after its exit
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "OffsetAfterHandle",   \* the offset is saved in a step after the event is handled
    "OffsetBeforeHandle",  \* the offset is saved in a step before the event is handled
    "ReadPartial",         \* the reader takes a line Claude Code has not finished
    "WriteInFramework",    \* the framework writes a message line itself, not by a claim command
    "NoClaim",             \* after a restart, a message is written again without its claim check
    "NoResultWait",        \* a message is written before its delegate's turn ended
    "ByNewest",            \* an answer goes to the held request, not the one it names
    "LogOnlyAtExit",       \* at the exit, a message with no replay read is undelivered
    "NoReclaim",           \* after a restart, a message marked but not claimed is never written
    "KeepIdle",            \* a follow again keeps the row's idle
    "NoReportWait",        \* an end is written before the report is delivered
    "OneFifo",             \* every process reads the one FIFO `in`
    "NoCutEnd",            \* a follow again leaves a cut last line of the log as it is
    "NoHeldSeen",          \* Sessions does not tell Stream it held the process
    "NoWriteSeen",         \* a write's live check does not set seen
    "MsgAfterEnd"          \* a message is marked after an end is
}

ASSUME Break \in Breaks
ASSUME \A c \in {MaxMsgs, MaxReqs, MaxRestarts, MaxResumes} : c \in Nat

Msgs == 1..MaxMsgs
Reqs == 1..MaxReqs
Gens == 1..(MaxResumes + 1)    \* a message's lines: its first and one resend per resume
Lines == Msgs \X Gens
NoU == <<0, 0>>
None == [k |-> "none", id |-> 0, u |-> NoU]
Ev(k, id) == [k |-> k, id |-> id, u |-> NoU]

\* The uuid of message m's line g: the message's own, kept on a resend.
UuidOf(m, g) == <<m, 1>>

VARIABLES
    \* Claude Code, held by its wrapper
    alive,      \* the delegate's process runs
    lives,      \* processes started: the first, then one per resume; process n reads in.<n-1>
    turn,       \* "idle" or "running"
    pipe,       \* lines in its stdin FIFO, not yet read: [k, id, u, l, whole]
    tail,       \* the event it is writing to the log, or None
    cutEnd,     \* the log ends with a line a death cut, with no newline
    log,        \* the event log: lines ended by a newline, [k, id, u]
    heard,      \* the transcript: uuids of the user lines it took, across resumes
    turns,      \* m -> turns that took m
    req,        \* r -> "none", "pending", "answered", "canceled", "gone"
    ansTaken,   \* r -> answers that settled r
    \* on disk, outside the framework
    spool,      \* l -> "none" or "claimed": the spool file is gone, its line goes in
    cat,        \* l -> the claim command: "none", "running", "writing" (part written), "done"
    cfifo,      \* l -> the FIFO its claim command names: in.<cfifo[l]>
    aspool,     \* r -> "none" or "claimed", for an answer's line
    \* the framework: tables, then memory
    up, restarts, resumes,
    offset,     \* table: events of the log handled
    idle,       \* table: the delegate's turn has ended
    seen,       \* table: the current process was seen live (live_seen)
    gone,       \* table: the delegate's exit is seen
    row,        \* table: m -> its row in Mailbox (Delivery.tla): due, sending, delivered;
                \*        due again (`again`) is "undelivered"
    gen,        \* table: m -> its line now: 0 before its mark, then 1, 2 on a resend
    hold,       \* table: r -> "none", "held", "answering", "answered", "canceled", "lost"
    report,     \* table: "none", "ready" (a result handled), "delivered" (to the parent)
    ending,     \* table: the end line: "none", "marked", "claimed"
    reading,    \* memory: an event read but not finished (the Offset Breaks only)
    mine,       \* memory: lines this run of the framework marked or claimed
    wmem,       \* memory: a message line the framework is writing (WriteInFramework)
    begun,      \* memory: message lines the framework began this run (WriteInFramework)
    telling,    \* memory: Sessions held the process and has not yet told Stream
    hand,       \* memory: rows Mailbox marked this run, not yet claimed (Delivery's)
    \* ghosts
    handled,    \* i -> times event i was handled
    written,    \* l -> times line l began to enter the pipe
    awritten,   \* r -> answer lines for r that entered the pipe
    partialRead, malformed, dwrong, wrong,
    endCut,     \* an end was taken while a turn ran
    endEarly,   \* an end was taken before the report was delivered
    endLost,    \* an end was taken while a message was writing or found undelivered
    joined      \* an event joined the cut line a death left

cc == <<alive, lives, turn, pipe, tail, cutEnd, log, heard, turns, req, ansTaken>>
disk == <<spool, cat, cfifo, aspool>>
fw == <<up, restarts, resumes, offset, idle, seen, gone, row, gen, hold, report, ending,
        reading, mine, wmem, begun, telling, hand>>
ghosts == <<handled, written, awritten, partialRead, malformed, dwrong, wrong, endCut,
            endEarly, endLost, joined>>
vars == <<cc, disk, fw, ghosts>>

Parent == "parent"
Dg == "delegate"

D == INSTANCE Delivery WITH
       Ids <- Msgs, Addrs <- {Dg}, Headless <- {Dg}, Senders <- {Parent}, MaxSent <- 0,
       Awaited <- {}, ClientLeaves <- FALSE, SelfTurns <- FALSE, MaxRestarts <- 0,
       MaxEnds <- 0, MaxPrompts <- 0, MaxStops <- 0,
       Break <- CASE Break = "NoResultWait" -> "IntoRunningTurn"
                  [] Break = "MsgAfterEnd" -> "MarkWhileStopping"
                  [] Break = "LogOnlyAtExit" -> "LogOnlyAtExit"
                  [] OTHER -> "none",
       up <- up,
       pr <- [a \in {Dg} |-> IF alive THEN lives ELSE 0],
       idle <- [a \in {Dg} |-> idle],
       stopping <- [a \in {Dg} |-> ending # "none"],
       over <- [a \in {Dg} |-> FALSE],
       turned <- [a \in {Dg} |-> TRUE], Long <- {}, Wide <- {}, Launched <- {},
       row <- row, hand <- hand, wrong <- dwrong,
       claimed <- {}, wire <- [m \in Msgs |-> 0], waiter <- [a \in {Dg} |-> 0],
       call <- [m \in Msgs |-> "none"], tx <- [a \in {Dg} |-> <<>>],
       fold <- [m \in Msgs |-> "none"], rmem <- {}, last <- [a \in {Dg} |-> -1],
       unsure <- {}, lost <- {},
       restarts <- 0, lives <- 0, ends <- 0, prompts <- 0, stops <- 0, readAt <- 0,
       forced <- {}, fcall <- {}

\* A message's row: due, then sending (Stream's "writing"), then delivered;
\* one found undelivered at an exit is due again.
Writing(m) == row[m].st = "sending"
Undelivered(m) == row[m].st = "due" /\ row[m].again
Line(m) == <<m, gen[m]>>
MsgLine(l, whole) == [k |-> "msg", id |-> l[1], u |-> UuidOf(l[1], l[2]), l |-> l,
                      whole |-> whole]
OtherLine(k, id) == [k |-> k, id |-> id, u |-> NoU, l |-> <<0, 0>>, whole |-> TRUE]

-----------------------------------------------------------------------------
Init ==
    /\ alive = TRUE /\ lives = 1 /\ turn = "idle" /\ pipe = <<>> /\ tail = None
    /\ cutEnd = FALSE /\ log = <<>> /\ heard = {}
    /\ turns = [m \in Msgs |-> 0]
    /\ req = [r \in Reqs |-> "none"] /\ ansTaken = [r \in Reqs |-> 0]
    /\ spool = [l \in Lines |-> "none"] /\ cat = [l \in Lines |-> "none"]
    /\ cfifo = [l \in Lines |-> 0] /\ aspool = [r \in Reqs |-> "none"]
    /\ up = TRUE /\ restarts = 0 /\ resumes = 0 /\ offset = 0 /\ idle = TRUE
    /\ seen = FALSE /\ gone = FALSE
    /\ row = [m \in Msgs |-> [D!NoRow EXCEPT !.from = Parent, !.to = Dg, !.kind = "msg",
                                              !.re = m, !.st = "due"]]
    /\ hand = {} /\ gen = [m \in Msgs |-> 0]
    /\ hold = [r \in Reqs |-> "none"] /\ report = "none" /\ ending = "none"
    /\ reading = 0 /\ mine = {} /\ wmem = <<0, 0>> /\ begun = {} /\ telling = TRUE
    /\ handled = <<>> /\ written = [l \in Lines |-> 0] /\ awritten = [r \in Reqs |-> 0]
    /\ partialRead = FALSE /\ malformed = FALSE /\ dwrong = {} /\ wrong = {}
    /\ endCut = FALSE /\ endEarly = FALSE /\ endLost = FALSE /\ joined = FALSE

-----------------------------------------------------------------------------
(* Claude Code *)

\* Its process ends: the pipe's contents go with it, and a line it was
\* writing to the log stays cut, with no newline.
Die ==
    /\ alive' = FALSE /\ pipe' = <<>> /\ tail' = None
    /\ cutEnd' = (cutEnd \/ tail # None)
    /\ req' = [r \in Reqs |-> IF req[r] = "pending" THEN "gone" ELSE req[r]]

\* Killed, or ended: from outside, at any time.
Exit ==
    /\ alive /\ Die
    /\ UNCHANGED <<lives, turn, log, heard, turns, ansTaken, disk, fw, ghosts>>

\* A line that does not parse ends the session (invalid_stream_input).
Malformed ==
    /\ alive /\ Len(pipe) >= 2 /\ ~Head(pipe).whole
    /\ Die /\ malformed' = TRUE
    /\ UNCHANGED <<lives, turn, log, heard, turns, ansTaken, disk, fw, handled, written,
                   awritten, partialRead, dwrong, wrong, endCut, endEarly, endLost, joined>>

\* A message taken starts a turn, or joins the one running; it is replayed.
TakeMsg ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).whole /\ Head(pipe).k = "msg"
    /\ Head(pipe).u \notin heard
    /\ LET m == Head(pipe).id IN
         /\ turns' = [turns EXCEPT ![m] = @ + 1]
         /\ tail' = [k |-> "replay", id |-> m, u |-> Head(pipe).u]
    /\ heard' = heard \cup {Head(pipe).u}
    /\ turn' = "running" /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, lives, cutEnd, log, req, ansTaken, disk, fw, ghosts>>

\* A user line whose uuid the transcript holds is not run again: Claude
\* Code acknowledges it with its replay, and starts no turn.
DropMsg ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).whole /\ Head(pipe).k = "msg"
    /\ Head(pipe).u \in heard
    /\ tail' = [k |-> "replay", id |-> Head(pipe).id, u |-> Head(pipe).u]
    /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, lives, turn, cutEnd, log, heard, turns, req, ansTaken, disk, fw,
                   ghosts>>

\* An answer settles its pending request, and is replayed.
TakeAnswer ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).k = "ans"
    /\ LET r == Head(pipe).id IN
         /\ req[r] = "pending"
         /\ req' = [req EXCEPT ![r] = "answered"]
         /\ ansTaken' = [ansTaken EXCEPT ![r] = @ + 1]
         /\ tail' = Ev("areplay", r)
    /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, lives, turn, cutEnd, log, heard, turns, disk, fw, ghosts>>

\* An answer to a request no longer pending is dropped, with no event.
DropAnswer ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).k = "ans"
    /\ req[Head(pipe).id] # "pending"
    /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, lives, turn, tail, cutEnd, log, heard, turns, req, ansTaken, disk, fw,
                   ghosts>>

\* end_session ends the session, and cuts a turn that runs.
TakeEnd ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).k = "end"
    /\ Die
    /\ endCut' = (endCut \/ turn = "running")
    /\ endEarly' = (endEarly \/ report # "delivered")
    /\ endLost' = (endLost \/ \E m \in Msgs : Writing(m) \/ Undelivered(m))
    /\ UNCHANGED <<lives, turn, log, heard, turns, ansTaken, disk, fw, handled, written,
                   awritten, partialRead, malformed, dwrong, wrong, joined>>

RequestOpens(r) ==
    /\ alive /\ turn = "running" /\ tail = None /\ req[r] = "none"
    /\ \A q \in Reqs : q < r => req[q] \in {"answered", "canceled", "gone"}
    /\ req' = [req EXCEPT ![r] = "pending"]
    /\ tail' = Ev("request", r)
    /\ UNCHANGED <<alive, lives, turn, pipe, cutEnd, log, heard, turns, ansTaken, disk, fw,
                   ghosts>>

\* Claude Code withdraws a request (an interrupt): from outside.
RequestCancelled(r) ==
    /\ alive /\ tail = None /\ req[r] = "pending"
    /\ req' = [req EXCEPT ![r] = "canceled"]
    /\ tail' = Ev("cancel", r)
    /\ UNCHANGED <<alive, lives, turn, pipe, cutEnd, log, heard, turns, ansTaken, disk, fw,
                   ghosts>>

TurnEnds ==
    /\ alive /\ turn = "running" /\ tail = None /\ \A r \in Reqs : req[r] # "pending"
    /\ turn' = "idle" /\ tail' = Ev("result", 0)
    /\ UNCHANGED <<alive, lives, pipe, cutEnd, log, heard, turns, req, ansTaken, disk, fw,
                   ghosts>>

\* The event's line is finished: one write of a whole line to the log. A
\* line a death cut, still without its newline, takes the event in, and
\* the two stay one line that does not parse.
EventWritten ==
    /\ tail # None
    /\ log' = Append(log, IF cutEnd THEN Ev("cut", 0) ELSE tail)
    /\ joined' = (joined \/ cutEnd) /\ cutEnd' = FALSE
    /\ handled' = Append(handled, 0) /\ tail' = None
    /\ UNCHANGED <<alive, lives, turn, pipe, heard, turns, req, ansTaken, disk, fw, written,
                   awritten, partialRead, malformed, dwrong, wrong, endCut, endEarly,
                   endLost>>

\* Sessions starts the resumed process, `--resume <id>`, once the row is
\* followed again: the next FIFO, the same log, the same transcript. It
\* tells Stream once it held the process (HeldTold).
ProcStarts ==
    /\ up /\ ~alive /\ ~gone /\ lives <= resumes
    /\ alive' = TRUE /\ lives' = lives + 1 /\ turn' = "idle" /\ pipe' = <<>>
    /\ telling' = TRUE
    /\ UNCHANGED <<tail, cutEnd, log, heard, turns, req, ansTaken, disk, up, restarts, resumes,
                   offset, idle, seen, gone, row, hand, gen, hold, report, ending, reading, mine,
                   wmem, begun, ghosts>>

-----------------------------------------------------------------------------
(* A claim command: started by the framework, it does not end with it *)

\* A process reads the FIFO the command names; under OneFifo, every
\* process reads the one FIFO.
Reads(l) == alive /\ (cfifo[l] = lives - 1 \/ Break = "OneFifo")

\* Its FIFO is open, so a process reads it: the line's first part goes in.
CatBegins(l) ==
    /\ cat[l] = "running" /\ Reads(l)
    /\ cat' = [cat EXCEPT ![l] = "writing"]
    /\ pipe' = Append(pipe, MsgLine(l, FALSE))
    /\ written' = [written EXCEPT ![l] = @ + 1]
    /\ UNCHANGED <<alive, lives, turn, tail, cutEnd, log, heard, turns, req, ansTaken, spool,
                   cfifo, aspool, fw, handled, awritten, partialRead, malformed, dwrong,
                   wrong, endCut, endEarly, endLost, joined>>

\* The rest goes in: the line is whole if nothing went in after its first
\* part; else the two mix, and stay a line that does not parse. A process
\* that died took the pipe with it.
CatEnds(l) ==
    /\ cat[l] = "writing"
    /\ cat' = [cat EXCEPT ![l] = "done"]
    /\ pipe' = IF pipe # <<>> /\ pipe[Len(pipe)] = MsgLine(l, FALSE)
                 THEN [pipe EXCEPT ![Len(pipe)] = MsgLine(l, TRUE)] ELSE pipe
    /\ UNCHANGED <<alive, lives, turn, tail, cutEnd, log, heard, turns, req, ansTaken, spool,
                   cfifo, aspool, fw, ghosts>>

\* A claim waiting on a FIFO no process reads is ended at its deadline,
\* by Shell or, after a restart, by Recoveries.
ClaimTimesOut(l) ==
    /\ cat[l] = "running" /\ ~Reads(l)
    /\ cat' = [cat EXCEPT ![l] = "done"]
    /\ UNCHANGED <<cc, spool, cfifo, aspool, fw, ghosts>>

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; its memory does not *)

FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ reading' = 0 /\ mine' = {} /\ wmem' = <<0, 0>> /\ begun' = {} /\ telling' = FALSE
    /\ hand' = {}
    /\ UNCHANGED <<cc, disk, resumes, offset, idle, seen, gone, row, gen, hold, report, ending,
                   ghosts>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<cc, disk, restarts, resumes, offset, idle, seen, gone, row, hand, gen, hold,
                   report, ending, reading, mine, wmem, begun, telling, ghosts>>

\* A replay that names message m's line now.
Names(e) == e.k = "replay" /\ gen[e.id] > 0 /\ e.u = UuidOf(e.id, gen[e.id])

\* What handling event e writes to the tables. A line that does not parse
\* writes nothing.
Handle(e) ==
    /\ row' = IF Names(e) /\ Writing(e.id)
                THEN [row EXCEPT ![e.id] = D!Delivered(e.id)] ELSE row
    /\ idle' = IF e.k = "result" THEN TRUE ELSE idle
    /\ report' = IF e.k = "result" THEN "ready" ELSE report
    /\ hold' = CASE e.k = "request" /\ hold[e.id] = "none" ->
                      [hold EXCEPT ![e.id] = "held"]
                 [] e.k = "areplay" /\ hold[e.id] = "answering" ->
                      [hold EXCEPT ![e.id] = "answered"]
                 [] e.k = "cancel" /\ hold[e.id] \in {"held", "answering"} ->
                      [hold EXCEPT ![e.id] = "canceled"]
                 [] OTHER -> hold

\* The design reads the next whole line, handles it and saves the offset
\* in one transaction. The Offset Breaks split it in two.
Read ==
    /\ up /\ reading = 0 /\ offset < Len(log)
    /\ LET i == offset + 1 IN
         IF Break = "OffsetBeforeHandle"
           THEN /\ offset' = i /\ reading' = i
                /\ UNCHANGED <<idle, row, hand, hold, report, handled>>
           ELSE /\ Handle(log[i])
                /\ handled' = [handled EXCEPT ![i] = @ + 1]
                /\ IF Break = "OffsetAfterHandle"
                     THEN reading' = i /\ UNCHANGED offset
                     ELSE offset' = i /\ UNCHANGED reading
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, seen, gone, gen, ending, mine, wmem, begun,
                   hand, telling, written, awritten, partialRead, malformed, dwrong, wrong, endCut,
                   endEarly, endLost, joined>>

ReadFinished ==
    /\ up /\ reading # 0
    /\ reading' = 0
    /\ IF Break = "OffsetAfterHandle"
         THEN offset' = reading /\ UNCHANGED <<idle, row, hand, hold, report, handled>>
         ELSE /\ Handle(log[reading])
              /\ handled' = [handled EXCEPT ![reading] = @ + 1]
              /\ UNCHANGED offset
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, seen, gone, gen, ending, mine, wmem, begun,
                   hand, telling, written, awritten, partialRead, malformed, dwrong, wrong, endCut,
                   endEarly, endLost, joined>>

\* Under ReadPartial: the reader takes the log's unfinished last line.
ReadUnfinished ==
    /\ Break = "ReadPartial" /\ up /\ offset = Len(log) /\ (tail # None \/ cutEnd)
    /\ ~partialRead
    /\ partialRead' = TRUE
    /\ UNCHANGED <<cc, disk, fw, handled, written, awritten, malformed, dwrong, wrong,
                   endCut, endEarly, endLost, joined>>

\* What sets seen leaves the rest of the framework as it was.
SeenOnly == UNCHANGED <<cc, disk, up, restarts, resumes, offset, idle, gone, row, hand, gen, hold,
                        report, ending, reading, mine, wmem, begun, ghosts>>

\* A read finds the delegate's socket live.
LiveSeen ==
    /\ up /\ alive /\ ~seen /\ ~gone
    /\ seen' = TRUE
    /\ UNCHANGED telling /\ SeenOnly

\* Sessions held the process, and tells Stream: a later exit is this
\* process's, whether or not a read saw it live.
HeldTold ==
    /\ up /\ telling /\ Break # "NoHeldSeen"
    /\ telling' = FALSE /\ seen' = (seen \/ ~gone)
    /\ SeenOnly

\* The row says "writing" before anything is written, and the write's
\* check finds the delegate live, which sets seen. Messages go in order,
\* each once its delegate's turn has ended, every one before it is
\* delivered and no end is marked; one found undelivered goes again,
\* first, as a new line under its uuid.
Mark(m) ==
    /\ ~gone /\ gen[m] < MaxResumes + 1
    /\ D!Mark(m, "stream")
    /\ gen' = [gen EXCEPT ![m] = @ + 1]
    /\ idle' = FALSE /\ report' = "none"
    /\ seen' = IF Break = "NoWriteSeen" THEN seen ELSE TRUE
    /\ mine' = mine \cup {<<m, gen[m] + 1>>}
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, gone, hold, ending, reading, wmem,
                   begun, telling, handled, written, awritten, partialRead, malformed, wrong,
                   endCut, endEarly, endLost, joined>>

\* Spool the line and start its claim command, which names the FIFO of
\* the row's resume count now. A spool already claimed is never claimed
\* again: its line went in, or goes in, by its command.
Claim(m) ==
    /\ up /\ Writing(m) /\ Break # "WriteInFramework"
    /\ LET l == Line(m) IN
         /\ cat[l] \notin {"running", "writing"}
         /\ \/ spool[l] = "none" /\ (Break # "NoReclaim" \/ l \in mine)
            \/ Break = "NoClaim" /\ spool[l] = "claimed" /\ l \notin mine
         /\ spool' = [spool EXCEPT ![l] = "claimed"] /\ cat' = [cat EXCEPT ![l] = "running"]
         /\ cfifo' = [cfifo EXCEPT ![l] = resumes]
         /\ mine' = mine \cup {l}
         /\ hand' = hand \ {m}
    /\ UNCHANGED <<cc, aspool, up, restarts, resumes, offset, idle, seen, gone, row, gen, hold,
                   report, ending, reading, wmem, begun, telling, ghosts>>

\* Under WriteInFramework: the framework writes the line itself, and a
\* restart can cut it.
WriteBegins(m) ==
    /\ Break = "WriteInFramework" /\ up /\ alive /\ Writing(m) /\ wmem = <<0, 0>>
    /\ Line(m) \notin begun
    /\ pipe' = Append(pipe, MsgLine(Line(m), FALSE))
    /\ written' = [written EXCEPT ![Line(m)] = @ + 1]
    /\ wmem' = Line(m) /\ begun' = begun \cup {Line(m)}
    /\ UNCHANGED <<alive, lives, turn, tail, cutEnd, log, heard, turns, req, ansTaken, disk, up,
                   restarts, resumes, offset, idle, seen, gone, row, hand, gen, hold, report,
                   ending, reading, mine, telling, handled, awritten, partialRead, malformed,
                   dwrong, wrong, endCut, endEarly, endLost, joined>>

WriteEnds ==
    /\ up /\ wmem # <<0, 0>>
    /\ pipe' = [i \in DOMAIN pipe |-> IF pipe[i] = MsgLine(wmem, FALSE)
                                        THEN MsgLine(wmem, TRUE) ELSE pipe[i]]
    /\ wmem' = <<0, 0>>
    /\ UNCHANGED <<alive, lives, turn, tail, cutEnd, log, heard, turns, req, ansTaken, disk, up,
                   restarts, resumes, offset, idle, seen, gone, row, hand, gen, hold, report,
                   ending, reading, mine, begun, telling, ghosts>>

\* An answer meant for request a, which its sender saw, takes hold h: the
\* one it names. Under ByNewest it takes whichever is held.
AnswerAsked(a, h) ==
    /\ up /\ ~gone /\ hold[a] # "none" /\ hold[h] = "held"
    /\ h = a \/ (Break = "ByNewest" /\ hold[a] # "held")
    /\ hold' = [hold EXCEPT ![h] = "answering"]
    /\ wrong' = IF h # a THEN wrong \cup {<<a, h>>} ELSE wrong
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, idle, seen, gone, row, hand, gen,
                   report, ending, reading, mine, wmem, begun, telling, handled, written, awritten,
                   partialRead, malformed, dwrong, endCut, endEarly, endLost, joined>>

\* The answer's line is spooled and claimed; it fits the pipe's atomic
\* size, so it goes in whole in one write, to its own process or to none.
AnswerClaimed(r) ==
    /\ up /\ hold[r] = "answering" /\ aspool[r] = "none"
    /\ aspool' = [aspool EXCEPT ![r] = "claimed"]
    /\ IF alive
         THEN /\ pipe' = Append(pipe, OtherLine("ans", r))
              /\ awritten' = [awritten EXCEPT ![r] = @ + 1]
         ELSE UNCHANGED <<pipe, awritten>>
    /\ UNCHANGED <<alive, lives, turn, tail, cutEnd, log, heard, turns, req, ansTaken, spool,
                   cat, cfifo, fw, handled, written, partialRead, malformed, dwrong, wrong,
                   endCut, endEarly, endLost, joined>>

\* The parent's part: the report of the turn that ended is delivered.
ReportDelivered ==
    /\ up /\ idle /\ report = "ready"
    /\ report' = "delivered"
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, idle, seen, gone, row, hand, gen, hold,
                   ending, reading, mine, wmem, begun, telling, ghosts>>

\* An end is asked: Sessions checks that the report is delivered; Stream
\* marks the row once the turn has ended and no message is under way or
\* found undelivered.
EndMarked ==
    /\ up /\ ~gone /\ alive /\ ending = "none"
    /\ idle
    /\ report = "delivered" \/ Break = "NoReportWait"
    /\ \A m \in Msgs : ~Writing(m) /\ ~Undelivered(m)
    /\ ending' = "marked"
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, idle, seen, gone, row, hand, gen, hold,
                   report, reading, mine, wmem, begun, telling, ghosts>>

\* The end's line is spooled and claimed, like an answer's.
EndClaimed ==
    /\ up /\ ending = "marked"
    /\ ending' = "claimed"
    /\ pipe' = IF alive THEN Append(pipe, OtherLine("end", 0)) ELSE pipe
    /\ UNCHANGED <<alive, lives, turn, tail, cutEnd, log, heard, turns, req, ansTaken, disk, up,
                   restarts, resumes, offset, idle, seen, gone, row, hand, gen, hold, report,
                   reading, mine, wmem, begun, telling, ghosts>>

\* The delegate's pid is gone, after this run's claims have ended. Once
\* the log is read to its end, a message still writing is settled by the
\* transcript, and the holds are lost.
ExitSeen ==
    /\ up /\ ~alive /\ seen /\ ~gone /\ offset = Len(log) /\ reading = 0
    /\ \A l \in mine : cat[l] \notin {"running", "writing"}
    /\ gone' = TRUE
    /\ row' = [m \in Msgs |->
                 IF ~Writing(m) THEN row[m]
                 ELSE IF UuidOf(m, gen[m]) \in heard /\ Break # "LogOnlyAtExit"
                   THEN D!Delivered(m) ELSE D!DueAgain(m)]
    /\ hold' = [r \in Reqs |-> IF hold[r] \in {"held", "answering"} THEN "lost" ELSE hold[r]]
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, idle, seen, gen, report, ending, hand,
                   reading, mine, wmem, begun, telling, ghosts>>

\* A resume follows the row again: its offset, messages and requests stay;
\* the next FIFO is made, a cut last line of the log is ended with a
\* newline, the new process is not yet seen, and its turn has not begun.
FollowAgain ==
    /\ up /\ gone /\ ~alive /\ resumes < MaxResumes
    /\ gone' = FALSE /\ seen' = FALSE /\ resumes' = resumes + 1 /\ ending' = "none"
    /\ telling' = FALSE
    /\ idle' = IF Break = "KeepIdle" THEN idle ELSE TRUE
    /\ IF cutEnd /\ Break # "NoCutEnd"
         THEN /\ log' = Append(log, Ev("cut", 0)) /\ handled' = Append(handled, 0)
              /\ cutEnd' = FALSE
         ELSE UNCHANGED <<log, handled, cutEnd>>
    /\ UNCHANGED <<alive, lives, turn, pipe, tail, heard, turns, req, ansTaken, disk, up,
                   restarts, offset, row, hand, gen, hold, report, reading, mine, wmem, begun,
                   written, awritten, partialRead, malformed, dwrong, wrong, endCut,
                   endEarly, endLost, joined>>

-----------------------------------------------------------------------------
Next ==
    \/ Exit \/ Malformed \/ TakeMsg \/ DropMsg \/ TakeAnswer \/ DropAnswer \/ TakeEnd
    \/ TurnEnds \/ EventWritten \/ ProcStarts
    \/ \E r \in Reqs : RequestOpens(r) \/ RequestCancelled(r) \/ AnswerClaimed(r)
                       \/ \E h \in Reqs : AnswerAsked(r, h)
    \/ \E l \in Lines : CatBegins(l) \/ CatEnds(l) \/ ClaimTimesOut(l)
    \/ \E m \in Msgs : Mark(m) \/ Claim(m) \/ WriteBegins(m)
    \/ FrameworkDies \/ FrameworkStarts \/ Read \/ ReadFinished \/ ReadUnfinished
    \/ WriteEnds \/ LiveSeen \/ HeldTold \/ ReportDelivered \/ EndMarked \/ EndClaimed
    \/ ExitSeen \/ FollowAgain

Fairness ==
    /\ WF_vars(Malformed) /\ WF_vars(TakeMsg) /\ WF_vars(DropMsg) /\ WF_vars(TakeAnswer)
    /\ WF_vars(DropAnswer) /\ WF_vars(TakeEnd) /\ WF_vars(TurnEnds) /\ WF_vars(EventWritten)
    /\ WF_vars(ProcStarts)
    /\ WF_vars(FrameworkStarts) /\ WF_vars(Read) /\ WF_vars(ReadFinished)
    /\ WF_vars(WriteEnds) /\ WF_vars(LiveSeen) /\ WF_vars(HeldTold) /\ WF_vars(EndClaimed)
    /\ WF_vars(ExitSeen)
    /\ \A r \in Reqs : WF_vars(AnswerClaimed(r))
    /\ \A l \in Lines : WF_vars(CatBegins(l)) /\ WF_vars(CatEnds(l)) /\ WF_vars(ClaimTimesOut(l))
    /\ \A m \in Msgs : WF_vars(Mark(m)) /\ WF_vars(Claim(m)) /\ WF_vars(WriteBegins(m))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ alive \in BOOLEAN /\ turn \in {"idle", "running"} /\ up \in BOOLEAN
    /\ restarts \in 0..MaxRestarts /\ resumes \in 0..MaxResumes /\ lives \in 1..(resumes + 1)
    /\ offset \in 0..Len(log) /\ Len(handled) = Len(log)
    /\ D!TypeOK
    /\ gen \in [Msgs -> 0..(MaxResumes + 1)]
    /\ hold \in [Reqs -> {"none", "held", "answering", "answered", "canceled", "lost"}]
    /\ req \in [Reqs -> {"none", "pending", "answered", "canceled", "gone"}]
    /\ spool \in [Lines -> {"none", "claimed"}]
    /\ cat \in [Lines -> {"none", "running", "writing", "done"}]
    /\ cfifo \in [Lines -> 0..MaxResumes] /\ cutEnd \in BOOLEAN /\ telling \in BOOLEAN
    /\ report \in {"none", "ready", "delivered"} /\ ending \in {"none", "marked", "claimed"}

\* The reader handles no event twice, across restarts and resumes.
NoDoubleRead == \A i \in 1..Len(log) : handled[i] <= 1

\* The reader skips no event: every event below the offset was handled.
NoSkippedEvent == \A i \in 1..offset : handled[i] = 1 \/ reading = i

\* The reader never takes a line Claude Code has not finished.
NoPartialRead == ~partialRead

\* The delegate never reads a cut or mixed line.
NeverMalformed == ~malformed

\* Each line enters the pipe at most once.
WrittenOnce == \A l \in Lines : written[l] <= 1

\* Claude Code runs no message twice, across resumes: a message found
\* undelivered never went in, and a resend of one its transcript holds
\* would be dropped.
TakenOnce == \A m \in Msgs : turns[m] <= 1

\* A message goes in only after its delegate's turn ended.
IntoEndedTurn == D!OnlyIntoEndedTurn

\* At most one message waits for its replay.
OneWaiting == Cardinality({m \in Msgs : Writing(m)}) <= 1

\* A row's outcome is what the delegate did; an exit's "undelivered" is
\* final, since no line waiting for an earlier process reaches a later one.
DeliveredWasTaken == \A m \in Msgs : row[m].st = "delivered" => turns[m] = 1
UndeliveredWasNotTaken == \A m \in Msgs : Undelivered(m) => turns[m] = 0

\* An answer reaches only the request it names, at most once.
OnlyNamedRequest == wrong = {}
AnswerOnce == \A r \in Reqs : awritten[r] <= 1 /\ ansTaken[r] <= 1
AnsweredWasTaken == \A r \in Reqs : hold[r] = "answered" => ansTaken[r] = 1

\* An end never cuts a turn, and goes in only once the report is delivered.
EndNeverCuts == ~endCut
EndAfterReport == ~endEarly

\* An end goes in only when no message is under way or found undelivered.
EndLosesNoMessage == ~endLost

\* No event of a resumed process joins the line a death cut.
NoJoinedEvent == ~joined

\* A message written is replayed, or found undelivered once the delegate exits.
ReplayedOrFound == D!SendingSettles

\* A process whose tell a restart cut, and that exited before a read saw
\* it live: its exit is never seen (F-51's build note, new-3).
Unseen == ~alive /\ ~seen /\ ~telling /\ lives > resumes

\* After a resume, a message found undelivered is delivered, or the
\* delegate exits again.
ResentOrGone == \A m \in Msgs :
    (Undelivered(m) /\ ~gone) ~> (row[m].st = "delivered" \/ gone \/ Unseen)

\* A turn the row says runs ends, waits on a held request, or the delegate exits.
IdleReturns == (~idle /\ ~gone) ~> (idle \/ gone \/ Unseen \/ \E r \in Reqs : hold[r] = "held")

\* An answer under way is settled: answered, canceled, or lost at the exit.
AnswerSettles == \A r \in Reqs : hold[r] = "answering" ~> hold[r] # "answering"

=============================================================================
