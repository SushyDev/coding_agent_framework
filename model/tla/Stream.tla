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
(*   Stream.Fold  the message and request rows, settled by the events     *)
(*                (Handle) or at the exit (ExitSeen), and the guards of   *)
(*                a write (Mark, EndMarked);                              *)
(*   Stream.Line  the one encoder of the lines;                           *)
(*   Sessions     only as the one who starts the resumed process          *)
(*                (ProcStarts) and asks for the end.                      *)
(* And Claude Code 2.1.322 in -p stream-json mode (F-31's build note):    *)
(* it reads stdin line by line; a line that does not parse ends it; it    *)
(* replays each user line it takes and each answer that settled a request *)
(* (--replay-user-messages); a turn ends with exactly one result; it      *)
(* drops an answer to a request that is no longer pending; it drops a     *)
(* user line whose uuid its transcript holds, and acknowledges it with a  *)
(* replay of that uuid and no turn (skipDuplicate); end_session ends it.  *)
(*                                                                         *)
(* A message line is spooled to a file and written by a claim command,    *)
(* `exec 3<spool && rm spool && cat <&3 >fifo`, which outlives the        *)
(* framework: once the spool is gone the line goes in, by that command.   *)
(* A message line is longer than the pipe's atomic size, so the command   *)
(* writes it in two parts (CatBegins, CatEnds), and a line another writer *)
(* puts between them mixes with it. The command opens the FIFO for        *)
(* writing only once a process reads it: one started while no process    *)
(* reads waits, and goes in to the next process that opens the FIFO, or   *)
(* is ended at its deadline (ClaimTimesOut). A resend is a new line, and  *)
(* a new spool, under its message's same uuid. An answer or an end line   *)
(* is at most the atomic size, so its write is one step here.             *)
(*                                                                         *)
(* Left abstract: the spool write before the claim (a death between them  *)
(* is a death before the claim); time and deadlines; what a line says;    *)
(* turns Claude Code starts on its own (a finished background task, or a  *)
(* cut-off turn it runs again at a resume), which this model leaves out;  *)
(* interrupts, beyond a request's cancel; an answer's or an end's claim   *)
(* waiting through an exit (the resumed process drops such an answer);    *)
(* the cut line a death leaves at the log's end, which ProcStarts drops   *)
(* (F-51's build note, new-2); the parent's delivery of the report        *)
(* (ReportDelivered), which Delegate.tla models.                          *)
(*                                                                         *)
(* Fairness: the framework's steps, the claim commands and Claude Code's  *)
(* reading and writing happen while they stay possible, and a session     *)
(* followed again is started. A request may never be answered, the        *)
(* delegate may exit at any time, a resume and an end may never be asked. *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and   *)
(* has a Break_Stream_<value>.cfg that TLC must fail.                     *)
(*                                                                         *)
(* Defense in depth, with no Break: OneWaiting. Mark writes messages in   *)
(* order, each after the one before it is delivered, so a second message  *)
(* never waits beside the first; and idle is cleared by Mark and set only *)
(* by a result, which comes after the first message's replay. And         *)
(* EndMarked's wait for the turn's end (EndNeverCuts): the report is      *)
(* delivered only while idle, and Mark, which clears idle, clears it.     *)
(*                                                                         *)
(* Open (F-51's build note, new-1): with a restart and a resume, a claim  *)
(* still waiting on the FIFO at the exit goes into the resumed process    *)
(* beside the resend, and the two lines mix (NeverMalformed), so          *)
(* Stream_Resume.cfg has no restart until the design settles it.          *)
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
    "NewUuid",             \* a resend carries a new uuid
    "KeepIdle",            \* a follow again keeps the row's idle
    "NoReportWait"         \* an end is written before the report is delivered
}

ASSUME Break \in Breaks
ASSUME \A c \in {MaxMsgs, MaxReqs, MaxRestarts, MaxResumes} : c \in Nat

Msgs == 1..MaxMsgs
Reqs == 1..MaxReqs
Gens == 1..(MaxResumes + 1)    \* a message's lines: its first and one resend per resume
Lines == Msgs \X Gens
NoU == <<0, 0>>
None == [k |-> "none", id |-> 0, u |-> NoU]
Cut == [k |-> "cut", id |-> 0, u |-> NoU]
Ev(k, id) == [k |-> k, id |-> id, u |-> NoU]

\* The uuid of message m's line g: the message's own, kept on a resend.
UuidOf(m, g) == IF Break = "NewUuid" THEN <<m, g>> ELSE <<m, 1>>

VARIABLES
    \* Claude Code, held by its wrapper
    alive,      \* the delegate's process runs
    lives,      \* processes started: the first, then one per resume
    turn,       \* "idle" or "running"
    pipe,       \* lines in its stdin FIFO, not yet read: [k, id, u, l, whole]
    tail,       \* the event it is writing to the log, or None, or Cut at its exit
    log,        \* the event log: whole lines, [k, id, u]
    heard,      \* the transcript: uuids of the user lines it took, across resumes
    turns,      \* m -> turns that took m
    req,        \* r -> "none", "pending", "answered", "canceled", "gone"
    ansTaken,   \* r -> answers that settled r
    \* on disk, outside the framework
    spool,      \* l -> "none" or "claimed": the spool file is gone, its line goes in
    cat,        \* l -> the claim command: "none", "running", "writing" (part written), "done"
    aspool,     \* r -> "none" or "claimed", for an answer's line
    \* the framework: tables, then memory
    up, restarts, resumes,
    offset,     \* table: events of the log handled
    idle,       \* table: the delegate's turn has ended
    seen,       \* table: the current process was seen live (live_seen)
    gone,       \* table: the delegate's exit is seen
    msg,        \* table: m -> "queued", "writing", "delivered", "undelivered"
    gen,        \* table: m -> its line now: 0 before its mark, then 1, 2 on a resend
    hold,       \* table: r -> "none", "held", "answering", "answered", "canceled", "lost"
    report,     \* table: "none", "ready" (a result handled), "delivered" (to the parent)
    ending,     \* table: the end line: "none", "marked", "claimed"
    reading,    \* memory: an event read but not finished (the Offset Breaks only)
    mine,       \* memory: lines this run of the framework marked or claimed
    wmem,       \* memory: a message line the framework is writing (WriteInFramework)
    begun,      \* memory: message lines the framework began this run (WriteInFramework)
    \* ghosts
    handled,    \* i -> times event i was handled
    written,    \* l -> times line l began to enter the pipe
    awritten,   \* r -> answer lines for r that entered the pipe
    partialRead, malformed, intoRunning, wrong,
    endCut,     \* an end was taken while a turn ran
    endEarly    \* an end was taken before the report was delivered

cc == <<alive, lives, turn, pipe, tail, log, heard, turns, req, ansTaken>>
disk == <<spool, cat, aspool>>
fw == <<up, restarts, resumes, offset, idle, seen, gone, msg, gen, hold, report, ending,
        reading, mine, wmem, begun>>
ghosts == <<handled, written, awritten, partialRead, malformed, intoRunning, wrong, endCut,
            endEarly>>
vars == <<cc, disk, fw, ghosts>>

Settled == {"delivered", "undelivered"}
Line(m) == <<m, gen[m]>>
MsgLine(l, whole) == [k |-> "msg", id |-> l[1], u |-> UuidOf(l[1], l[2]), l |-> l,
                      whole |-> whole]
OtherLine(k, id) == [k |-> k, id |-> id, u |-> NoU, l |-> <<0, 0>>, whole |-> TRUE]

-----------------------------------------------------------------------------
Init ==
    /\ alive = TRUE /\ lives = 1 /\ turn = "idle" /\ pipe = <<>> /\ tail = None
    /\ log = <<>> /\ heard = {}
    /\ turns = [m \in Msgs |-> 0]
    /\ req = [r \in Reqs |-> "none"] /\ ansTaken = [r \in Reqs |-> 0]
    /\ spool = [l \in Lines |-> "none"] /\ cat = [l \in Lines |-> "none"]
    /\ aspool = [r \in Reqs |-> "none"]
    /\ up = TRUE /\ restarts = 0 /\ resumes = 0 /\ offset = 0 /\ idle = TRUE
    /\ seen = FALSE /\ gone = FALSE
    /\ msg = [m \in Msgs |-> "queued"] /\ gen = [m \in Msgs |-> 0]
    /\ hold = [r \in Reqs |-> "none"] /\ report = "none" /\ ending = "none"
    /\ reading = 0 /\ mine = {} /\ wmem = <<0, 0>> /\ begun = {}
    /\ handled = <<>> /\ written = [l \in Lines |-> 0] /\ awritten = [r \in Reqs |-> 0]
    /\ partialRead = FALSE /\ malformed = FALSE /\ intoRunning = FALSE /\ wrong = {}
    /\ endCut = FALSE /\ endEarly = FALSE

-----------------------------------------------------------------------------
(* Claude Code *)

\* Its process ends: the pipe's contents go with it, and a line it was
\* writing to the log stays cut.
Die ==
    /\ alive' = FALSE /\ pipe' = <<>>
    /\ tail' = IF tail = None THEN None ELSE Cut
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
                   awritten, partialRead, intoRunning, wrong, endCut, endEarly>>

\* A message taken starts a turn, or joins the one running; it is replayed.
TakeMsg ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).whole /\ Head(pipe).k = "msg"
    /\ Head(pipe).u \notin heard
    /\ LET m == Head(pipe).id IN
         /\ turns' = [turns EXCEPT ![m] = @ + 1]
         /\ tail' = [k |-> "replay", id |-> m, u |-> Head(pipe).u]
    /\ heard' = heard \cup {Head(pipe).u}
    /\ intoRunning' = (intoRunning \/ turn = "running")
    /\ turn' = "running" /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, lives, log, req, ansTaken, disk, fw, handled, written, awritten,
                   partialRead, malformed, wrong, endCut, endEarly>>

\* A user line whose uuid the transcript holds is not run again: Claude
\* Code acknowledges it with its replay, and starts no turn.
DropMsg ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).whole /\ Head(pipe).k = "msg"
    /\ Head(pipe).u \in heard
    /\ tail' = [k |-> "replay", id |-> Head(pipe).id, u |-> Head(pipe).u]
    /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, lives, turn, log, heard, turns, req, ansTaken, disk, fw, ghosts>>

\* An answer settles its pending request, and is replayed.
TakeAnswer ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).k = "ans"
    /\ LET r == Head(pipe).id IN
         /\ req[r] = "pending"
         /\ req' = [req EXCEPT ![r] = "answered"]
         /\ ansTaken' = [ansTaken EXCEPT ![r] = @ + 1]
         /\ tail' = Ev("areplay", r)
    /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, lives, turn, log, heard, turns, disk, fw, ghosts>>

\* An answer to a request no longer pending is dropped, with no event.
DropAnswer ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).k = "ans"
    /\ req[Head(pipe).id] # "pending"
    /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, lives, turn, tail, log, heard, turns, req, ansTaken, disk, fw, ghosts>>

\* end_session ends the session, and cuts a turn that runs.
TakeEnd ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).k = "end"
    /\ Die
    /\ endCut' = (endCut \/ turn = "running")
    /\ endEarly' = (endEarly \/ report # "delivered")
    /\ UNCHANGED <<lives, turn, log, heard, turns, ansTaken, disk, fw, handled, written,
                   awritten, partialRead, malformed, intoRunning, wrong>>

RequestOpens(r) ==
    /\ alive /\ turn = "running" /\ tail = None /\ req[r] = "none"
    /\ \A q \in Reqs : q < r => req[q] \in {"answered", "canceled", "gone"}
    /\ req' = [req EXCEPT ![r] = "pending"]
    /\ tail' = Ev("request", r)
    /\ UNCHANGED <<alive, lives, turn, pipe, log, heard, turns, ansTaken, disk, fw, ghosts>>

\* Claude Code withdraws a request (an interrupt): from outside.
RequestCancelled(r) ==
    /\ alive /\ tail = None /\ req[r] = "pending"
    /\ req' = [req EXCEPT ![r] = "canceled"]
    /\ tail' = Ev("cancel", r)
    /\ UNCHANGED <<alive, lives, turn, pipe, log, heard, turns, ansTaken, disk, fw, ghosts>>

TurnEnds ==
    /\ alive /\ turn = "running" /\ tail = None /\ \A r \in Reqs : req[r] # "pending"
    /\ turn' = "idle" /\ tail' = Ev("result", 0)
    /\ UNCHANGED <<alive, lives, pipe, log, heard, turns, req, ansTaken, disk, fw, ghosts>>

\* The event's line is finished: one write of a whole line to the log.
EventWritten ==
    /\ tail \notin {None, Cut}
    /\ log' = Append(log, tail) /\ handled' = Append(handled, 0) /\ tail' = None
    /\ UNCHANGED <<alive, lives, turn, pipe, heard, turns, req, ansTaken, disk, fw, written,
                   awritten, partialRead, malformed, intoRunning, wrong, endCut, endEarly>>

\* Sessions starts the resumed process, `--resume <id>`, once the row is
\* followed again: the same FIFO, the same log, the same transcript.
ProcStarts ==
    /\ up /\ ~alive /\ ~gone /\ lives <= resumes
    /\ alive' = TRUE /\ lives' = lives + 1 /\ turn' = "idle" /\ pipe' = <<>> /\ tail' = None
    /\ UNCHANGED <<log, heard, turns, req, ansTaken, disk, fw, ghosts>>

-----------------------------------------------------------------------------
(* A claim command: started by the framework, it does not end with it *)

\* Its FIFO is open, so a process reads it: the line's first part goes in.
CatBegins(l) ==
    /\ cat[l] = "running" /\ alive
    /\ cat' = [cat EXCEPT ![l] = "writing"]
    /\ pipe' = Append(pipe, MsgLine(l, FALSE))
    /\ written' = [written EXCEPT ![l] = @ + 1]
    /\ UNCHANGED <<alive, lives, turn, tail, log, heard, turns, req, ansTaken, spool, aspool,
                   fw, handled, awritten, partialRead, malformed, intoRunning, wrong, endCut,
                   endEarly>>

\* The rest goes in: the line is whole if nothing went in after its first
\* part; else the two mix, and stay a line that does not parse. A process
\* that died took the pipe with it.
CatEnds(l) ==
    /\ cat[l] = "writing"
    /\ cat' = [cat EXCEPT ![l] = "done"]
    /\ pipe' = IF pipe # <<>> /\ pipe[Len(pipe)] = MsgLine(l, FALSE)
                 THEN [pipe EXCEPT ![Len(pipe)] = MsgLine(l, TRUE)] ELSE pipe
    /\ UNCHANGED <<alive, lives, turn, tail, log, heard, turns, req, ansTaken, spool, aspool,
                   fw, ghosts>>

\* A claim waiting on a FIFO no process reads is ended at its deadline,
\* by Shell or, after a restart, by Recoveries.
ClaimTimesOut(l) ==
    /\ cat[l] = "running" /\ ~alive
    /\ cat' = [cat EXCEPT ![l] = "done"]
    /\ UNCHANGED <<cc, spool, aspool, fw, ghosts>>

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; its memory does not *)

FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ reading' = 0 /\ mine' = {} /\ wmem' = <<0, 0>> /\ begun' = {}
    /\ UNCHANGED <<cc, disk, resumes, offset, idle, seen, gone, msg, gen, hold, report, ending,
                   ghosts>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<cc, disk, restarts, resumes, offset, idle, seen, gone, msg, gen, hold,
                   report, ending, reading, mine, wmem, begun, ghosts>>

\* A replay that names message m's line now.
Names(e) == e.k = "replay" /\ gen[e.id] > 0 /\ e.u = UuidOf(e.id, gen[e.id])

\* What handling event e writes to the tables. A replay of a row found
\* undelivered is a line that went in after the exit: its turn runs.
Handle(e) ==
    /\ msg' = IF Names(e) /\ msg[e.id] \in {"writing", "undelivered"}
                THEN [msg EXCEPT ![e.id] = "delivered"] ELSE msg
    /\ idle' = CASE e.k = "result" -> TRUE
                 [] Names(e) /\ msg[e.id] = "undelivered" -> FALSE
                 [] OTHER -> idle
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
                /\ UNCHANGED <<idle, msg, hold, report, handled>>
           ELSE /\ Handle(log[i])
                /\ handled' = [handled EXCEPT ![i] = @ + 1]
                /\ IF Break = "OffsetAfterHandle"
                     THEN reading' = i /\ UNCHANGED offset
                     ELSE offset' = i /\ UNCHANGED reading
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, seen, gone, gen, ending, mine, wmem, begun,
                   written, awritten, partialRead, malformed, intoRunning, wrong, endCut,
                   endEarly>>

ReadFinished ==
    /\ up /\ reading # 0
    /\ reading' = 0
    /\ IF Break = "OffsetAfterHandle"
         THEN offset' = reading /\ UNCHANGED <<idle, msg, hold, report, handled>>
         ELSE /\ Handle(log[reading])
              /\ handled' = [handled EXCEPT ![reading] = @ + 1]
              /\ UNCHANGED offset
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, seen, gone, gen, ending, mine, wmem, begun,
                   written, awritten, partialRead, malformed, intoRunning, wrong, endCut,
                   endEarly>>

\* Under ReadPartial: the reader takes the log's unfinished last line.
ReadUnfinished ==
    /\ Break = "ReadPartial" /\ up /\ offset = Len(log) /\ tail # None /\ ~partialRead
    /\ partialRead' = TRUE
    /\ UNCHANGED <<cc, disk, fw, handled, written, awritten, malformed, intoRunning, wrong,
                   endCut, endEarly>>

\* A read finds the delegate's socket live.
LiveSeen ==
    /\ up /\ alive /\ ~seen /\ ~gone
    /\ seen' = TRUE
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, idle, gone, msg, gen, hold, report,
                   ending, reading, mine, wmem, begun, ghosts>>

\* The row says "writing" before anything is written, and the write's
\* check finds the delegate live. Messages go in order, each once its
\* delegate's turn has ended and every one before it is delivered; one
\* found undelivered goes again, first, as a new line under its uuid.
Mark(m) ==
    /\ up /\ ~gone /\ alive /\ ending = "none"
    /\ msg[m] \in {"queued", "undelivered"} /\ gen[m] < MaxResumes + 1
    /\ idle \/ Break = "NoResultWait"
    /\ \A n \in Msgs : n < m => msg[n] = "delivered"
    /\ msg' = [msg EXCEPT ![m] = "writing"] /\ gen' = [gen EXCEPT ![m] = @ + 1]
    /\ idle' = FALSE /\ report' = "none" /\ seen' = TRUE
    /\ mine' = mine \cup {<<m, gen[m] + 1>>}
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, gone, hold, ending, reading, wmem,
                   begun, ghosts>>

\* Spool the line and start its claim command. A spool already claimed is
\* never claimed again: its line went in, or goes in, by its command.
Claim(m) ==
    /\ up /\ msg[m] = "writing" /\ Break # "WriteInFramework"
    /\ LET l == Line(m) IN
         /\ cat[l] \notin {"running", "writing"}
         /\ \/ spool[l] = "none" /\ (Break # "NoReclaim" \/ l \in mine)
            \/ Break = "NoClaim" /\ spool[l] = "claimed" /\ l \notin mine
         /\ spool' = [spool EXCEPT ![l] = "claimed"] /\ cat' = [cat EXCEPT ![l] = "running"]
         /\ mine' = mine \cup {l}
    /\ UNCHANGED <<cc, aspool, up, restarts, resumes, offset, idle, seen, gone, msg, gen, hold,
                   report, ending, reading, wmem, begun, ghosts>>

\* Under WriteInFramework: the framework writes the line itself, and a
\* restart can cut it.
WriteBegins(m) ==
    /\ Break = "WriteInFramework" /\ up /\ alive /\ msg[m] = "writing" /\ wmem = <<0, 0>>
    /\ Line(m) \notin begun
    /\ pipe' = Append(pipe, MsgLine(Line(m), FALSE))
    /\ written' = [written EXCEPT ![Line(m)] = @ + 1]
    /\ wmem' = Line(m) /\ begun' = begun \cup {Line(m)}
    /\ UNCHANGED <<alive, lives, turn, tail, log, heard, turns, req, ansTaken, disk, up,
                   restarts, resumes, offset, idle, seen, gone, msg, gen, hold, report, ending,
                   reading, mine, handled, awritten, partialRead, malformed, intoRunning, wrong,
                   endCut, endEarly>>

WriteEnds ==
    /\ up /\ wmem # <<0, 0>>
    /\ pipe' = [i \in DOMAIN pipe |-> IF pipe[i] = MsgLine(wmem, FALSE)
                                        THEN MsgLine(wmem, TRUE) ELSE pipe[i]]
    /\ wmem' = <<0, 0>>
    /\ UNCHANGED <<alive, lives, turn, tail, log, heard, turns, req, ansTaken, disk, up,
                   restarts, resumes, offset, idle, seen, gone, msg, gen, hold, report, ending,
                   reading, mine, begun, ghosts>>

\* An answer meant for request a, which its sender saw, takes hold h: the
\* one it names. Under ByNewest it takes whichever is held.
AnswerAsked(a, h) ==
    /\ up /\ ~gone /\ hold[a] # "none" /\ hold[h] = "held"
    /\ h = a \/ (Break = "ByNewest" /\ hold[a] # "held")
    /\ hold' = [hold EXCEPT ![h] = "answering"]
    /\ wrong' = IF h # a THEN wrong \cup {<<a, h>>} ELSE wrong
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, idle, seen, gone, msg, gen, report,
                   ending, reading, mine, wmem, begun, handled, written, awritten, partialRead,
                   malformed, intoRunning, endCut, endEarly>>

\* The answer's line is spooled and claimed; it fits the pipe's atomic
\* size, so it goes in whole in one write.
AnswerClaimed(r) ==
    /\ up /\ hold[r] = "answering" /\ aspool[r] = "none"
    /\ aspool' = [aspool EXCEPT ![r] = "claimed"]
    /\ IF alive
         THEN /\ pipe' = Append(pipe, OtherLine("ans", r))
              /\ awritten' = [awritten EXCEPT ![r] = @ + 1]
         ELSE UNCHANGED <<pipe, awritten>>
    /\ UNCHANGED <<alive, lives, turn, tail, log, heard, turns, req, ansTaken, spool, cat, fw,
                   handled, written, partialRead, malformed, intoRunning, wrong, endCut,
                   endEarly>>

\* The parent's part: the report of the turn that ended is delivered.
ReportDelivered ==
    /\ up /\ idle /\ report = "ready"
    /\ report' = "delivered"
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, idle, seen, gone, msg, gen, hold,
                   ending, reading, mine, wmem, begun, ghosts>>

\* An end is asked: its row is marked once the turn has ended and the
\* report is delivered, and no message is under way.
EndMarked ==
    /\ up /\ ~gone /\ alive /\ ending = "none"
    /\ idle
    /\ report = "delivered" \/ Break = "NoReportWait"
    /\ \A m \in Msgs : msg[m] \in {"queued", "delivered"}
    /\ ending' = "marked"
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, idle, seen, gone, msg, gen, hold,
                   report, reading, mine, wmem, begun, ghosts>>

\* The end's line is spooled and claimed, like an answer's.
EndClaimed ==
    /\ up /\ ending = "marked"
    /\ ending' = "claimed"
    /\ pipe' = IF alive THEN Append(pipe, OtherLine("end", 0)) ELSE pipe
    /\ UNCHANGED <<alive, lives, turn, tail, log, heard, turns, req, ansTaken, disk, up,
                   restarts, resumes, offset, idle, seen, gone, msg, gen, hold, report, reading,
                   mine, wmem, begun, ghosts>>

\* The delegate's pid is gone, after this run's claims have ended. Once
\* the log is read to its end, a message still writing is settled by the
\* transcript, and the holds are lost.
ExitSeen ==
    /\ up /\ ~alive /\ seen /\ ~gone /\ offset = Len(log) /\ reading = 0
    /\ \A l \in mine : cat[l] \notin {"running", "writing"}
    /\ gone' = TRUE
    /\ msg' = [m \in Msgs |->
                 IF msg[m] # "writing" THEN msg[m]
                 ELSE IF UuidOf(m, gen[m]) \in heard /\ Break # "LogOnlyAtExit"
                   THEN "delivered" ELSE "undelivered"]
    /\ hold' = [r \in Reqs |-> IF hold[r] \in {"held", "answering"} THEN "lost" ELSE hold[r]]
    /\ UNCHANGED <<cc, disk, up, restarts, resumes, offset, idle, seen, gen, report, ending,
                   reading, mine, wmem, begun, ghosts>>

\* A resume follows the row again: its offset, messages and requests stay;
\* the new process is not yet seen, and its turn has not begun.
FollowAgain ==
    /\ up /\ gone /\ ~alive /\ resumes < MaxResumes
    /\ gone' = FALSE /\ seen' = FALSE /\ resumes' = resumes + 1 /\ ending' = "none"
    /\ idle' = IF Break = "KeepIdle" THEN idle ELSE TRUE
    /\ UNCHANGED <<cc, disk, up, restarts, offset, msg, gen, hold, report, reading, mine, wmem,
                   begun, ghosts>>

-----------------------------------------------------------------------------
Next ==
    \/ Exit \/ Malformed \/ TakeMsg \/ DropMsg \/ TakeAnswer \/ DropAnswer \/ TakeEnd
    \/ TurnEnds \/ EventWritten \/ ProcStarts
    \/ \E r \in Reqs : RequestOpens(r) \/ RequestCancelled(r) \/ AnswerClaimed(r)
                       \/ \E h \in Reqs : AnswerAsked(r, h)
    \/ \E l \in Lines : CatBegins(l) \/ CatEnds(l) \/ ClaimTimesOut(l)
    \/ \E m \in Msgs : Mark(m) \/ Claim(m) \/ WriteBegins(m)
    \/ FrameworkDies \/ FrameworkStarts \/ Read \/ ReadFinished \/ ReadUnfinished
    \/ WriteEnds \/ LiveSeen \/ ReportDelivered \/ EndMarked \/ EndClaimed \/ ExitSeen
    \/ FollowAgain

Fairness ==
    /\ WF_vars(Malformed) /\ WF_vars(TakeMsg) /\ WF_vars(DropMsg) /\ WF_vars(TakeAnswer)
    /\ WF_vars(DropAnswer) /\ WF_vars(TakeEnd) /\ WF_vars(TurnEnds) /\ WF_vars(EventWritten)
    /\ WF_vars(ProcStarts)
    /\ WF_vars(FrameworkStarts) /\ WF_vars(Read) /\ WF_vars(ReadFinished)
    /\ WF_vars(WriteEnds) /\ WF_vars(LiveSeen) /\ WF_vars(EndClaimed) /\ WF_vars(ExitSeen)
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
    /\ msg \in [Msgs -> {"queued", "writing", "delivered", "undelivered"}]
    /\ gen \in [Msgs -> 0..(MaxResumes + 1)]
    /\ hold \in [Reqs -> {"none", "held", "answering", "answered", "canceled", "lost"}]
    /\ req \in [Reqs -> {"none", "pending", "answered", "canceled", "gone"}]
    /\ spool \in [Lines -> {"none", "claimed"}]
    /\ cat \in [Lines -> {"none", "running", "writing", "done"}]
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

\* Claude Code runs no message twice, across resumes: a resend of a message
\* its transcript holds is dropped.
TakenOnce == \A m \in Msgs : turns[m] <= 1

\* A message goes in only after its delegate's turn ended.
IntoEndedTurn == ~intoRunning

\* At most one message waits for its replay.
OneWaiting == Cardinality({m \in Msgs : msg[m] = "writing"}) <= 1

\* A row's outcome is what the delegate did; an exit's "undelivered" holds
\* until a resume, when a line still waiting may go in.
DeliveredWasTaken == \A m \in Msgs : msg[m] = "delivered" => turns[m] = 1
UndeliveredWasNotTaken == \A m \in Msgs : msg[m] = "undelivered" /\ gone => turns[m] = 0

\* An answer reaches only the request it names, at most once.
OnlyNamedRequest == wrong = {}
AnswerOnce == \A r \in Reqs : awritten[r] <= 1 /\ ansTaken[r] <= 1
AnsweredWasTaken == \A r \in Reqs : hold[r] = "answered" => ansTaken[r] = 1

\* An end never cuts a turn, and goes in only once the report is delivered.
EndNeverCuts == ~endCut
EndAfterReport == ~endEarly

\* A message written is replayed, or found undelivered once the delegate exits.
ReplayedOrFound == \A m \in Msgs : msg[m] = "writing" ~> msg[m] \in Settled

\* A process that exited before a read saw it live: its exit is never seen
\* (F-51's build note, new-3).
Unseen == ~alive /\ ~seen /\ lives > resumes

\* After a resume, a message found undelivered is delivered, or the
\* delegate exits again.
ResentOrGone == \A m \in Msgs :
    (msg[m] = "undelivered" /\ ~gone) ~> (msg[m] = "delivered" \/ gone \/ Unseen)

\* A turn the row says runs ends, waits on a held request, or the delegate exits.
IdleReturns == (~idle /\ ~gone) ~> (idle \/ gone \/ Unseen \/ \E r \in Reqs : hold[r] = "held")

\* An answer under way is settled: answered, canceled, or lost at the exit.
AnswerSettles == \A r \in Reqs : hold[r] = "answering" ~> hold[r] # "answering"

=============================================================================
