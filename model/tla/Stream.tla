------------------------------- MODULE Stream -------------------------------
(***************************************************************************)
(* How a headless delegate is held and spoken to: lines written into its  *)
(* stdin, its events read from a log at a persisted offset, its turns,    *)
(* replays and permission requests, with restarts of the framework        *)
(* between any two steps and the delegate's exit.                         *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                          *)
(*   Stream       the host's one writer for delegates: it marks, spools   *)
(*                and claims each line, and reads the event log;          *)
(*   Stream.Fold  the message and request rows, settled by the events     *)
(*                (Handle) or at the exit (ExitSeen);                     *)
(*   Stream.Line  the one encoder of the lines.                           *)
(* And Claude Code 2.1.322 in -p stream-json mode (F-31's build note):    *)
(* it reads stdin line by line; a line that does not parse ends it; it    *)
(* replays each user line it takes and each answer that settled a request *)
(* (--replay-user-messages); a turn ends with exactly one result; it      *)
(* drops an answer to a request that is no longer pending.                *)
(*                                                                         *)
(* A message line is spooled to a file and written by a claim command,    *)
(* `exec 3<spool && rm spool && cat <&3 >fifo`, which outlives the        *)
(* framework: once the spool is gone the line goes in whole. An answer    *)
(* line is spooled and claimed the same way; it is at most the pipe's     *)
(* atomic size, so its write is one step here.                            *)
(*                                                                         *)
(* Left abstract: the spool write before the claim (a death between them  *)
(* is a death before the claim); time and deadlines; what a line says;    *)
(* the transcript, read as `turns` (a taken message is in it); turns      *)
(* Claude Code starts on its own (a finished background task), which      *)
(* this model leaves out; interrupts, beyond a request's cancel; the      *)
(* resume after an exit, which Delegate.tla and Start.tla model.          *)
(*                                                                         *)
(* Fairness: the framework's steps, the claim commands and Claude Code's  *)
(* reading and writing happen while they stay possible. A request may     *)
(* never be answered, and the delegate may exit at any time.              *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and   *)
(* has a Break_Stream_<value>.cfg that TLC must fail.                     *)
(*                                                                         *)
(* Defense in depth, with no Break: OneWaiting. Mark writes messages in   *)
(* order, each after the one before it is settled, so a second message    *)
(* never waits beside the first; and idle is cleared by Mark and set only *)
(* by a result, which comes after the first message's replay.             *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    MaxMsgs,      \* messages to the delegate, 1..MaxMsgs, in order
    MaxReqs,      \* permission requests of the delegate, 1..MaxReqs, in order
    MaxRestarts,  \* restarts of the framework
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
    "NoReclaim"            \* after a restart, a message marked but not claimed is never written
}

ASSUME Break \in Breaks
ASSUME MaxMsgs \in Nat /\ MaxReqs \in Nat /\ MaxRestarts \in Nat

Msgs == 1..MaxMsgs
Reqs == 1..MaxReqs
None == [k |-> "none", id |-> 0]
Cut == [k |-> "cut", id |-> 0]
Ev(k, id) == [k |-> k, id |-> id]

VARIABLES
    \* Claude Code, held by its wrapper
    alive,      \* the delegate's process runs
    turn,       \* "idle" or "running"
    pipe,       \* lines in its stdin FIFO, not yet read: [k, id, whole]
    tail,       \* the event it is writing to the log, or None, or Cut at its exit
    log,        \* the event log: whole lines, [k, id]
    turns,      \* m -> turns that took m (the transcript holds m once taken)
    req,        \* r -> "none", "pending", "answered", "canceled", "gone"
    ansTaken,   \* r -> answers that settled r
    \* on disk, outside the framework
    spool,      \* m -> "none" or "claimed": the spool file is gone, its line goes in
    cat,        \* m -> the claim command: "none", "running", "done"
    aspool,     \* r -> "none" or "claimed", for an answer's line
    \* the framework: tables, then memory
    up, restarts,
    offset,     \* table: events of the log handled
    idle,       \* table: the last turn event handled is a result
    gone,       \* table: the delegate's exit is seen
    msg,        \* table: m -> "queued", "writing", "delivered", "undelivered"
    hold,       \* table: r -> "none", "held", "answering", "answered", "canceled", "lost"
    reading,    \* memory: an event read but not finished (the Offset Breaks only)
    mine,       \* memory: messages this run of the framework marked or claimed
    wmem,       \* memory: a message line the framework is writing (WriteInFramework)
    begun,      \* memory: message lines the framework began this run (WriteInFramework)
    \* ghosts
    handled,    \* i -> times event i was handled
    written,    \* m -> lines of m that entered the pipe
    awritten,   \* r -> answer lines for r that entered the pipe
    partialRead, malformed, intoRunning, wrong

cc == <<alive, turn, pipe, tail, log, turns, req, ansTaken>>
disk == <<spool, cat, aspool>>
fw == <<up, restarts, offset, idle, gone, msg, hold, reading, mine, wmem, begun>>
ghosts == <<handled, written, awritten, partialRead, malformed, intoRunning, wrong>>
vars == <<cc, disk, fw, ghosts>>

Settled == {"delivered", "undelivered"}

-----------------------------------------------------------------------------
Init ==
    /\ alive = TRUE /\ turn = "idle" /\ pipe = <<>> /\ tail = None /\ log = <<>>
    /\ turns = [m \in Msgs |-> 0]
    /\ req = [r \in Reqs |-> "none"] /\ ansTaken = [r \in Reqs |-> 0]
    /\ spool = [m \in Msgs |-> "none"] /\ cat = [m \in Msgs |-> "none"]
    /\ aspool = [r \in Reqs |-> "none"]
    /\ up = TRUE /\ restarts = 0 /\ offset = 0 /\ idle = TRUE /\ gone = FALSE
    /\ msg = [m \in Msgs |-> "queued"] /\ hold = [r \in Reqs |-> "none"]
    /\ reading = 0 /\ mine = {} /\ wmem = 0 /\ begun = {}
    /\ handled = <<>> /\ written = [m \in Msgs |-> 0] /\ awritten = [r \in Reqs |-> 0]
    /\ partialRead = FALSE /\ malformed = FALSE /\ intoRunning = FALSE /\ wrong = {}

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
    /\ UNCHANGED <<turn, log, turns, ansTaken, disk, fw, ghosts>>

\* A line that does not parse ends the session (invalid_stream_input).
Malformed ==
    /\ alive /\ Len(pipe) >= 2 /\ ~Head(pipe).whole
    /\ Die /\ malformed' = TRUE
    /\ UNCHANGED <<turn, log, turns, ansTaken, disk, fw, handled, written, awritten,
                   partialRead, intoRunning, wrong>>

\* A message taken starts a turn, or joins the one running; it is replayed.
TakeMsg ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).whole /\ Head(pipe).k = "msg"
    /\ LET m == Head(pipe).id IN
         /\ turns' = [turns EXCEPT ![m] = @ + 1]
         /\ tail' = Ev("replay", m)
    /\ intoRunning' = (intoRunning \/ turn = "running")
    /\ turn' = "running" /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, log, req, ansTaken, disk, fw, handled, written, awritten,
                   partialRead, malformed, wrong>>

\* An answer settles its pending request, and is replayed.
TakeAnswer ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).k = "ans"
    /\ LET r == Head(pipe).id IN
         /\ req[r] = "pending"
         /\ req' = [req EXCEPT ![r] = "answered"]
         /\ ansTaken' = [ansTaken EXCEPT ![r] = @ + 1]
         /\ tail' = Ev("areplay", r)
    /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, turn, log, turns, disk, fw, ghosts>>

\* An answer to a request no longer pending is dropped, with no event.
DropAnswer ==
    /\ alive /\ tail = None /\ pipe # <<>> /\ Head(pipe).k = "ans"
    /\ req[Head(pipe).id] # "pending"
    /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<alive, turn, tail, log, turns, req, ansTaken, disk, fw, ghosts>>

RequestOpens(r) ==
    /\ alive /\ turn = "running" /\ tail = None /\ req[r] = "none"
    /\ \A q \in Reqs : q < r => req[q] \in {"answered", "canceled"}
    /\ req' = [req EXCEPT ![r] = "pending"]
    /\ tail' = Ev("request", r)
    /\ UNCHANGED <<alive, turn, pipe, log, turns, ansTaken, disk, fw, ghosts>>

\* Claude Code withdraws a request (an interrupt): from outside.
RequestCancelled(r) ==
    /\ alive /\ tail = None /\ req[r] = "pending"
    /\ req' = [req EXCEPT ![r] = "canceled"]
    /\ tail' = Ev("cancel", r)
    /\ UNCHANGED <<alive, turn, pipe, log, turns, ansTaken, disk, fw, ghosts>>

TurnEnds ==
    /\ alive /\ turn = "running" /\ tail = None /\ \A r \in Reqs : req[r] # "pending"
    /\ turn' = "idle" /\ tail' = Ev("result", 0)
    /\ UNCHANGED <<alive, pipe, log, turns, req, ansTaken, disk, fw, ghosts>>

\* The event's line is finished: one write of a whole line to the log.
EventWritten ==
    /\ tail \notin {None, Cut}
    /\ log' = Append(log, tail) /\ handled' = Append(handled, 0) /\ tail' = None
    /\ UNCHANGED <<alive, turn, pipe, turns, req, ansTaken, disk, fw, written, awritten,
                   partialRead, malformed, intoRunning, wrong>>

-----------------------------------------------------------------------------
(* A claim command: started by the framework, it does not end with it *)

CatWrites(m) ==
    /\ cat[m] = "running"
    /\ cat' = [cat EXCEPT ![m] = "done"]
    /\ IF alive
         THEN /\ pipe' = Append(pipe, [k |-> "msg", id |-> m, whole |-> TRUE])
              /\ written' = [written EXCEPT ![m] = @ + 1]
         ELSE UNCHANGED <<pipe, written>>
    /\ UNCHANGED <<alive, turn, tail, log, turns, req, ansTaken, spool, aspool, fw, handled,
                   awritten, partialRead, malformed, intoRunning, wrong>>

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; its memory does not *)

FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ reading' = 0 /\ mine' = {} /\ wmem' = 0 /\ begun' = {}
    /\ UNCHANGED <<cc, disk, offset, idle, gone, msg, hold, ghosts>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<cc, disk, restarts, offset, idle, gone, msg, hold, reading, mine, wmem,
                   begun, ghosts>>

\* What handling event e writes to the tables.
Handle(e) ==
    /\ msg' = IF e.k = "replay" /\ msg[e.id] = "writing"
                THEN [msg EXCEPT ![e.id] = "delivered"] ELSE msg
    /\ idle' = (idle \/ e.k = "result")
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
                /\ UNCHANGED <<idle, msg, hold, handled>>
           ELSE /\ Handle(log[i])
                /\ handled' = [handled EXCEPT ![i] = @ + 1]
                /\ IF Break = "OffsetAfterHandle"
                     THEN reading' = i /\ UNCHANGED offset
                     ELSE offset' = i /\ UNCHANGED reading
    /\ UNCHANGED <<cc, disk, up, restarts, gone, mine, wmem, begun, written, awritten,
                   partialRead, malformed, intoRunning, wrong>>

ReadFinished ==
    /\ up /\ reading # 0
    /\ reading' = 0
    /\ IF Break = "OffsetAfterHandle"
         THEN offset' = reading /\ UNCHANGED <<idle, msg, hold, handled>>
         ELSE /\ Handle(log[reading])
              /\ handled' = [handled EXCEPT ![reading] = @ + 1]
              /\ UNCHANGED offset
    /\ UNCHANGED <<cc, disk, up, restarts, gone, mine, wmem, begun, written, awritten,
                   partialRead, malformed, intoRunning, wrong>>

\* Under ReadPartial: the reader takes the log's unfinished last line.
ReadUnfinished ==
    /\ Break = "ReadPartial" /\ up /\ offset = Len(log) /\ tail # None /\ ~partialRead
    /\ partialRead' = TRUE
    /\ UNCHANGED <<cc, disk, fw, handled, written, awritten, malformed, intoRunning, wrong>>

\* The row says "writing" before anything is written. Messages go in order,
\* each once its delegate's turn has ended.
Mark(m) ==
    /\ up /\ ~gone /\ msg[m] = "queued"
    /\ idle \/ Break = "NoResultWait"
    /\ \A n \in Msgs : n < m => msg[n] \in Settled
    /\ msg' = [msg EXCEPT ![m] = "writing"] /\ idle' = FALSE /\ mine' = mine \cup {m}
    /\ UNCHANGED <<cc, disk, up, restarts, offset, gone, hold, reading, wmem, begun, ghosts>>

\* Spool the line and start its claim command. A spool already claimed is
\* never claimed again: its line went in, or goes in, whole.
Claim(m) ==
    /\ up /\ msg[m] = "writing" /\ Break # "WriteInFramework" /\ cat[m] # "running"
    /\ \/ spool[m] = "none" /\ (Break # "NoReclaim" \/ m \in mine)
       \/ Break = "NoClaim" /\ spool[m] = "claimed" /\ m \notin mine
    /\ spool' = [spool EXCEPT ![m] = "claimed"] /\ cat' = [cat EXCEPT ![m] = "running"]
    /\ mine' = mine \cup {m}
    /\ UNCHANGED <<cc, aspool, up, restarts, offset, idle, gone, msg, hold, reading, wmem, begun,
                   ghosts>>

\* Under WriteInFramework: the framework writes the line itself, and a
\* restart can cut it.
WriteBegins(m) ==
    /\ Break = "WriteInFramework" /\ up /\ alive /\ msg[m] = "writing" /\ wmem = 0
    /\ m \notin begun
    /\ pipe' = Append(pipe, [k |-> "msg", id |-> m, whole |-> FALSE])
    /\ written' = [written EXCEPT ![m] = @ + 1]
    /\ wmem' = m /\ begun' = begun \cup {m}
    /\ UNCHANGED <<alive, turn, tail, log, turns, req, ansTaken, disk, up, restarts, offset,
                   idle, gone, msg, hold, reading, mine, handled, awritten, partialRead, malformed,
                   intoRunning, wrong>>

WriteEnds ==
    /\ up /\ wmem # 0
    /\ pipe' = [i \in DOMAIN pipe |-> IF pipe[i].id = wmem /\ pipe[i].k = "msg"
                                        THEN [pipe[i] EXCEPT !.whole = TRUE] ELSE pipe[i]]
    /\ wmem' = 0
    /\ UNCHANGED <<alive, turn, tail, log, turns, req, ansTaken, disk, up, restarts, offset,
                   idle, gone, msg, hold, reading, mine, begun, ghosts>>

\* An answer meant for request a, which its sender saw, takes hold h: the
\* one it names. Under ByNewest it takes whichever is held.
AnswerAsked(a, h) ==
    /\ up /\ ~gone /\ hold[a] # "none" /\ hold[h] = "held"
    /\ h = a \/ (Break = "ByNewest" /\ hold[a] # "held")
    /\ hold' = [hold EXCEPT ![h] = "answering"]
    /\ wrong' = IF h # a THEN wrong \cup {<<a, h>>} ELSE wrong
    /\ UNCHANGED <<cc, disk, up, restarts, offset, idle, gone, msg, reading, mine, wmem, begun,
                   handled, written, awritten, partialRead, malformed, intoRunning>>

\* The answer's line is spooled and claimed; it fits the pipe's atomic
\* size, so it goes in whole in one write.
AnswerClaimed(r) ==
    /\ up /\ hold[r] = "answering" /\ aspool[r] = "none"
    /\ aspool' = [aspool EXCEPT ![r] = "claimed"]
    /\ IF alive
         THEN /\ pipe' = Append(pipe, [k |-> "ans", id |-> r, whole |-> TRUE])
              /\ awritten' = [awritten EXCEPT ![r] = @ + 1]
         ELSE UNCHANGED <<pipe, awritten>>
    /\ UNCHANGED <<alive, turn, tail, log, turns, req, ansTaken, spool, cat, fw, handled,
                   written, partialRead, malformed, intoRunning, wrong>>

\* The delegate's pid is gone. Once the log is read to its end, a message
\* still writing is settled by the transcript, and the holds are lost.
ExitSeen ==
    /\ up /\ ~alive /\ ~gone /\ offset = Len(log) /\ reading = 0
    /\ gone' = TRUE
    /\ msg' = [m \in Msgs |->
                 IF msg[m] # "writing" THEN msg[m]
                 ELSE IF turns[m] > 0 /\ Break # "LogOnlyAtExit" THEN "delivered"
                 ELSE "undelivered"]
    /\ hold' = [r \in Reqs |-> IF hold[r] \in {"held", "answering"} THEN "lost" ELSE hold[r]]
    /\ UNCHANGED <<cc, disk, up, restarts, offset, idle, reading, mine, wmem, begun, ghosts>>

-----------------------------------------------------------------------------
Next ==
    \/ Exit \/ Malformed \/ TakeMsg \/ TakeAnswer \/ DropAnswer \/ TurnEnds \/ EventWritten
    \/ \E r \in Reqs : RequestOpens(r) \/ RequestCancelled(r) \/ AnswerClaimed(r)
                       \/ \E h \in Reqs : AnswerAsked(r, h)
    \/ \E m \in Msgs : CatWrites(m) \/ Mark(m) \/ Claim(m) \/ WriteBegins(m)
    \/ FrameworkDies \/ FrameworkStarts \/ Read \/ ReadFinished \/ ReadUnfinished
    \/ WriteEnds \/ ExitSeen

Fairness ==
    /\ WF_vars(Malformed) /\ WF_vars(TakeMsg) /\ WF_vars(TakeAnswer) /\ WF_vars(DropAnswer)
    /\ WF_vars(TurnEnds) /\ WF_vars(EventWritten)
    /\ WF_vars(FrameworkStarts) /\ WF_vars(Read) /\ WF_vars(ReadFinished)
    /\ WF_vars(WriteEnds) /\ WF_vars(ExitSeen)
    /\ \A r \in Reqs : WF_vars(AnswerClaimed(r))
    /\ \A m \in Msgs : WF_vars(CatWrites(m)) /\ WF_vars(Mark(m)) /\ WF_vars(Claim(m))
                       /\ WF_vars(WriteBegins(m))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ alive \in BOOLEAN /\ turn \in {"idle", "running"} /\ up \in BOOLEAN
    /\ restarts \in 0..MaxRestarts /\ offset \in 0..Len(log) /\ Len(handled) = Len(log)
    /\ msg \in [Msgs -> {"queued", "writing", "delivered", "undelivered"}]
    /\ hold \in [Reqs -> {"none", "held", "answering", "answered", "canceled", "lost"}]
    /\ req \in [Reqs -> {"none", "pending", "answered", "canceled", "gone"}]
    /\ spool \in [Msgs -> {"none", "claimed"}] /\ cat \in [Msgs -> {"none", "running", "done"}]

\* The reader handles no event twice, across restarts.
NoDoubleRead == \A i \in 1..Len(log) : handled[i] <= 1

\* The reader skips no event: every event below the offset was handled.
NoSkippedEvent == \A i \in 1..offset : handled[i] = 1 \/ reading = i

\* The reader never takes a line Claude Code has not finished.
NoPartialRead == ~partialRead

\* The delegate never reads a cut line.
NeverMalformed == ~malformed

\* Each message's line enters the pipe at most once, and is taken at most once.
WrittenOnce == \A m \in Msgs : written[m] <= 1
TakenOnce == \A m \in Msgs : turns[m] <= 1

\* A message goes in only after its delegate's turn ended.
IntoEndedTurn == ~intoRunning

\* At most one message waits for its replay.
OneWaiting == Cardinality({m \in Msgs : msg[m] = "writing"}) <= 1

\* A row's outcome is what the delegate did.
DeliveredWasTaken == \A m \in Msgs : msg[m] = "delivered" => turns[m] = 1
UndeliveredWasNotTaken == \A m \in Msgs : msg[m] = "undelivered" => turns[m] = 0

\* An answer reaches only the request it names, at most once.
OnlyNamedRequest == wrong = {}
AnswerOnce == \A r \in Reqs : awritten[r] <= 1 /\ ansTaken[r] <= 1
AnsweredWasTaken == \A r \in Reqs : hold[r] = "answered" => ansTaken[r] = 1

\* A message written is replayed, or found undelivered once the delegate exits.
ReplayedOrFound == \A m \in Msgs : msg[m] = "writing" ~> msg[m] \in Settled

\* An answer under way is settled: answered, canceled, or lost at the exit.
AnswerSettles == \A r \in Reqs : hold[r] = "answering" ~> hold[r] # "answering"

=============================================================================
