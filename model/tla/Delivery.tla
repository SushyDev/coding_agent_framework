------------------------------ MODULE Delivery ------------------------------
(***************************************************************************)
(* Mailbox's one mark and settle. Everything the framework hands an agent  *)
(* is one row: a message, a delegate's reply or the framework's notice in  *)
(* its place, a resumed process's word to go on, and the report, which is *)
(* the reply to the brief. Mailbox picks the oldest due row per addressee, *)
(* in order per sender and addressee, a row made due again going first,    *)
(* one row in flight per addressee. It marks the row sending, with its     *)
(* transport and the process it is for, then hands it on. A refusal undoes *)
(* the mark; anything else keeps it until the evidence settles it. Only    *)
(* the transport differs:                                                  *)
(*                                                                         *)
(*   stream  a headless session's FIFO line (Stream.tla has the spool, the *)
(*           claim and the FIFO per process). Settled by the replay the    *)
(*           fold reads while its process runs; once that process is gone, *)
(*           by the transcript: there, delivered; not there, undelivered,  *)
(*           which is final, and the row is due again first. A restart     *)
(*           leaves the claim on disk; a line not yet claimed is claimed   *)
(*           again (Reclaim).                                              *)
(*   waiter  the answer to an interactive session's waiting Stop hook      *)
(*           (Hold.tla's waiter kind in Intake). Claude Code queues it and *)
(*           takes it: into a turn of its own once its turn has ended, or  *)
(*           into a person's turn still running, at its next tool          *)
(*           boundary (measured for F-127). Nothing is typed, so a waiter's*)
(*           row is marked into an ended turn or a running one. Settled by *)
(*           the transcript's take: the line there, delivered; not there   *)
(*           and no answer still on its way to a turn, due again. A        *)
(*           restart settles it the same way.                              *)
(*   typed   the Inlet's checked write, for an interactive session with no *)
(*           waiter, into an ended turn only. A row in Long (more than one *)
(*           line, or wider than the box) is written to a file the session *)
(*           may read, and the line typed names it (F-142); which line is  *)
(*           typed is left abstract. Refused when the check fails; unknown *)
(*           keeps the mark, and is never typed again; settled as waiter,  *)
(*           once the turn that took it has ended.                         *)
(*                                                                         *)
(* A waiter connects only once a turn of its process has ended (`turned`): *)
(* each turn's end starts the next one, and nothing starts one before the  *)
(* first turn. A new interactive process's first row goes by launch        *)
(* (F-137); a row to a session with no waiter, long or not, goes by the    *)
(* typed write, so none waits for a person's prompt. Since the pointer     *)
(* (F-142) a first row would arrive by the typed write too: the launch is  *)
(* the quicker path, with no screen to read, and no Break of its own.      *)
(*   launch  the prompt argument of an interactive session's start (and of *)
(*           its resume): the first row to it goes in as the start itself, *)
(*           and Claude Code runs it as the session's first turn. Marked   *)
(*           before the start; a start refused undoes the mark, under the  *)
(*           same key; settled as waiter, by the transcript's user line.   *)
(*   call    the answer of a waiting run_delegate, inside the turn that    *)
(*           called. Delivered when the endpoint's write succeeded and the *)
(*           calling process still runs; a failed write, the end of the    *)
(*           handler that waits, or a restart makes it due again, for the  *)
(*           waiter. A write that may have reached the agent before that is *)
(*           recorded (unsure): the one case of a text it gets twice.      *)
(*                                                                         *)
(* A headless session's turn that a row started ends with a result that   *)
(* names it, or with its process's end. Mailbox stores the reply to the   *)
(* row's key (`re`) from the result that names the row, or the            *)
(* framework's notice when the process ended first; one of them per key,  *)
(* kept by the table's key. A brief whose turn the process's end cut is   *)
(* not answered by a notice: the resumed process gets a row to go on      *)
(* under the brief's key, so the report is the reply to the brief across  *)
(* a resume, and a second end in that turn gives the notice (the second   *)
(* kill's report).                                                         *)
(*                                                                         *)
(* A session whose row is stopping gets no row: Mailbox does not mark one *)
(* for it, and Sessions' idle read before the SIGTERM waits until no row  *)
(* to it is sending (F-118's new-2; F-122's new-1). A session that ended  *)
(* for good gets none either: a due row says it ended first.              *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework (R7 and R8 build them):    *)
(*   Mailbox   the table of rows (durable); the mark, the hand-on in       *)
(*             memory, one module per transport with its restart policy;   *)
(*             the replies and notices, keyed by the answered row;         *)
(*   Intake    only whether a waiter of the session's current process is  *)
(*             connected (Hold.tla checks the hold itself);                *)
(*   Inlet     the typed write's check and its three answers;              *)
(*   MCP       the run_delegate call: it waits, the row is taken for it,   *)
(*             the endpoint writes, and the handler tells the outcome;     *)
(*   Sessions  the addressee's process, its turn, its stopping row and its *)
(*             end, which an instancing spec gives with its own state.     *)
(*                                                                         *)
(* Instanced by Delegate.tla (the report to the parent, by waiter, typed   *)
(* or call), Team.tla (messages along the tree's edges, and replies),      *)
(* Stream.tla (the stream transport's mark and settle) and Move.tla (rows  *)
(* to a main session across a move). The steps an instancing spec takes   *)
(* change only this module's own variables; the addressee's (`up`, `pr`, *)
(* `idle`, `stopping`, `over`) are read, and the instancing spec changes  *)
(* them in the same step (a take starts a turn, say).                     *)
(*                                                                         *)
(* Alone, the spec has senders that store rows, interactive and headless  *)
(* addressees whose processes end and are resumed, person's prompts,      *)
(* turns a headless session starts by itself, a stop by SIGTERM after an  *)
(* idle read, a session's end for good, run_delegate calls, and restarts. *)
(*                                                                         *)
(* Left abstract: time, but for one bound: an answer handed to a waiter, *)
(* or keys typed, reach a turn or never will by the time the framework     *)
(* reads the transcript for it (`wire` empty for the row; F-122's new-2).  *)
(* What a text says. The log's offset and the claim command (Stream.tla).  *)
(* Accounts and the transcript's copy (Move.tla). Who may send what       *)
(* (Team.tla). The waiter's own deadline and its one response (Hold.tla). *)
(*                                                                         *)
(* Fairness, alone: the framework's steps, Claude Code's take of a text,  *)
(* turns' ends, resumes and a stop once asked happen while possible; the  *)
(* mark and the hand-on are strongly fair, since a prompt or a waiter's   *)
(* timeout may take away their chance again and again. Stores, prompts,   *)
(* ends, calls and restarts happen or not.                                *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and   *)
(* has a Break_Delivery_<value>.cfg that TLC must fail.                   *)
(*                                                                         *)
(* Defense in depth, with no Break: a row made due again goes before the  *)
(* other rows to its addressee. Per sender and addressee it is already    *)
(* the oldest, and one row in flight per addressee keeps it so; going     *)
(* first keeps a resend in the turn it was meant for (Stream.tla).        *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Ids,           \* the rows, 1..n, taken in order
    Addrs,         \* the sessions rows go to
    Headless,      \* the headless ones, by stream; the others are interactive
    Senders,       \* alone: who stores rows (beside replies and notices)
    MaxSent,       \* alone: rows the senders store; the rest are answers and resumes
    Awaited,       \* rows a run_delegate call may wait on
    ClientLeaves,  \* the client may give up on a call before its deadline
    SelfTurns,     \* alone: a headless session may start a turn by itself
    MaxRestarts,   \* alone: restarts of the framework
    MaxEnds,       \* alone: processes that end by themselves (a crash, a kill)
    MaxPrompts,    \* alone: a person's prompts
    MaxStops,      \* alone: stops by SIGTERM
    Long,          \* rows too long for the typed write
    Launched,      \* alone: interactive sessions with no process at first, started by launch
    Break          \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "IntoRunningTurn",       \* a row is marked while its addressee's turn runs
    "MarkWhileStopping",     \* a row is marked for a session whose row is stopping
    "StopWhileSending",      \* the stop's idle read does not wait for rows sending
    "AnyProcess",            \* a text handed for one process reaches the next one
    "NoOrder",               \* the oldest due row per sender is not the one picked
    "RedeliverAfterRestart", \* a restart makes a waiter's or typed row due again, unread
    "SettleEarly",           \* a waiter's row is due again while its answer is on its way
    "UnknownUndone",         \* an unknown typed write undoes the mark
    "LogOnlyAtExit",         \* at a stream's exit, no replay read is undelivered, transcript unread
    "AnsweredOnFailure",     \* a call's failed write is delivered
    "CallerNotChecked",      \* a call's write is delivered though its process ended
    "NoCallerWatch",         \* the end of the handler that waits is not watched
    "NoRestartHold",         \* a restart leaves a call's row sending
    "TakeAfterDeadline",     \* a row is taken for a call past its deadline
    "EndedUnsettled",        \* a row still sending is marked ended, unsettled
    "NoEndedMark",           \* a due row to a session that ended is never marked ended
    "ReplyInMemory",         \* a reply's once-check is a set in memory, not the table's key
    "ReplyAndNotice",        \* a notice is read from the process's end, not the fold
    "SelfReply",             \* a reply is the last result since the row, whatever it names
    "NoNotice",              \* a row whose turn ended with no result gets no notice
    "ResumeOwnKey",          \* a resumed process's row is keyed by itself, not the brief
    "NoPointer"              \* a long row is not typed: it waits for a waiter (F-132)
}

ASSUME Break \in Breaks
ASSUME Headless \subseteq Addrs /\ Awaited \subseteq Ids /\ Long \subseteq Ids
ASSUME Launched \subseteq Addrs \ Headless
ASSUME ClientLeaves \in BOOLEAN /\ SelfTurns \in BOOLEAN

Framework == "framework"
Nobody == "nobody"
OwnTurn == 0     \* a result that names no row: a turn a session started by itself
NoResult == -1   \* no result since the last row went in
Transports == {"stream", "waiter", "typed", "launch", "call"}
NoRow == [from |-> Nobody, to |-> Nobody, kind |-> "none", re |-> 0, src |-> NoResult,
          st |-> "none", via |-> "none", at |-> 0, again |-> FALSE]

VARIABLES
    \* The addressee: an instancing spec gives its own state for these.
    up,        \* the framework runs
    pr,        \* a -> the number of a's process that runs, or 0
    idle,      \* a -> a's turn has ended
    stopping,  \* a -> a's row in Sessions says stopping
    over,      \* a -> a's session ended for good
    turned,    \* a -> a turn of a's current process has ended
    \* Mailbox and its transports
    row,       \* table: i -> [from, to, kind, re (its key), src, st, via, at, again]
    hand,      \* memory: rows marked whose transport has not answered yet
    claimed,   \* disk: stream rows whose line is claimed (the spool is gone)
    wire,      \* outside: i -> copies of i's text on their way to a turn
    waiter,    \* Intake: a -> the process whose waiter is connected, or 0
    call,      \* MCP: i -> "none", "waiting", "timedout", "writing", "wrote", "failed",
               \*      "gone" (its handler ended), "done"
    \* the evidence
    tx,        \* a -> the rows in a's transcript, in order
    fold,      \* the fold of a headless log: i -> "none", "turn", "result", "exited"
    \* what the wrong readers hold (ReplyInMemory, SelfReply only)
    rmem,      \* memory: rows answered
    last,      \* a -> the last result's name since a row went in
    \* ghosts
    unsure,    \* rows made due again while a call's write may have reached the agent
    lost,      \* <<i, why>>: a call's write succeeded to a client that had gone
    wrong,     \* what a guard should have refused
    \* alone only: the sessions, Sessions' stop, and restarts
    restarts, lives, ends, prompts, stops, readAt

dvars == <<row, hand, claimed, wire, waiter, call, tx, fold, rmem, last, unsure, lost, wrong>>
avars == <<up, pr, idle, stopping, over, turned>>
alone == <<restarts, lives, ends, prompts, stops, readAt>>
vars == <<avars, dvars, alone>>

-----------------------------------------------------------------------------
(* Reading the table *)

Stored == {i \in Ids : row[i].st # "none"}
NextId == Cardinality(Stored) + 1
To(a) == {i \in Ids : row[i].to = a}
InTx(i) == row[i].to \in Addrs /\ \E k \in DOMAIN tx[row[i].to] : tx[row[i].to][k] = i
Count(i) == Cardinality(UNION {{<<a, k>> : k \in {n \in DOMAIN tx[a] : tx[a][n] = i}}
                                : a \in Addrs})
Answered(k) == {j \in Ids : row[j].kind \in {"reply", "notice"} /\ row[j].re = k}
InTurn(a) == {i \in To(a) : fold[i] = "turn"}
LastIn(a) == IF tx[a] = <<>> THEN 0 ELSE tx[a][Len(tx[a])]

\* Row j goes before row i: due to the same addressee, made due again while
\* i was not, or else from the same sender and older.
Precedes(j, i) ==
    /\ j # i /\ row[j].to = row[i].to /\ row[j].st = "due" /\ Break # "NoOrder"
    /\ \/ row[j].again /\ ~row[i].again
       \/ row[j].again = row[i].again /\ row[j].from = row[i].from /\ j < i

\* The row Mailbox picks for its addressee: no row to it in flight, none before it.
First(i) ==
    /\ row[i].st = "due"
    /\ ~\E j \in To(row[i].to) : row[j].st = "sending"
    /\ ~\E j \in Ids : Precedes(j, i)

\* What the transport needs to reach i's addressee, a, at its process p now.
Reaches(i, t) ==
    LET a == row[i].to IN
    CASE t = "stream" -> a \in Headless
      [] t = "waiter" -> a \notin Headless /\ waiter[a] = pr[a]
      [] t = "typed"  -> a \notin Headless /\ waiter[a] # pr[a]
                         /\ (i \notin Long \/ Break # "NoPointer")
      [] t = "launch" -> a \notin Headless
      [] t = "call"   -> /\ i \in Awaited
                         /\ \/ call[i] = "waiting"
                            \/ Break = "TakeAfterDeadline" /\ call[i] = "timedout"

\* The hand-on is possible: the process it was marked for still takes it,
\* and its row is not stopping. A launch is the start: no process runs.
Open(i) ==
    LET a == row[i].to  p == row[i].at IN
    /\ ~stopping[a] \/ Break = "MarkWhileStopping"
    /\ CASE row[i].via = "stream" -> pr[a] = p
         [] row[i].via = "waiter" -> waiter[a] = p
         [] row[i].via = "launch" -> pr[a] = 0 /\ ~over[a]
         [] OTHER                 -> pr[a] = p /\ idle[a] /\ waiter[a] # p

Due(i) == [row[i] EXCEPT !.st = "due", !.via = "none", !.at = 0]
DueAgain(i) == [Due(i) EXCEPT !.again = TRUE]
Delivered(i) == [row[i] EXCEPT !.st = "delivered"]

-----------------------------------------------------------------------------
(* The steps an instancing spec takes: each changes only this module's     *)
(* variables, and reads the addressee's.                                   *)

\* A row stored: due to a session, or kept for one that is no session (the
\* operator reads its replies; it is no agent's addressee).
StoreRow(j, f, t, k, r, s) ==
    row' = [row EXCEPT ![j] = [NoRow EXCEPT !.from = f, !.to = t, !.kind = k, !.re = r,
                                            !.src = s,
                                            !.st = IF t \in Addrs THEN "due" ELSE "kept"]]

Store(i, f, t, k) ==
    /\ up /\ row[i].st = "none" /\ i = NextId
    /\ StoreRow(i, f, t, k, i, NoResult)
    /\ UNCHANGED <<hand, claimed, wire, waiter, call, tx, fold, rmem, last, unsure, lost, wrong>>

\* The mark: the row says sending, with its transport and the process it is
\* for, before anything goes out. Into an ended turn only (a call answers
\* inside the turn that called, and Claude Code queues a waiter's answer into
\* a running turn), and never to a session whose row is stopping. A launch
\* is marked while no process runs, for the one its start makes.
Mark(i, t) ==
    LET a == row[i].to IN
    /\ up /\ a \in Addrs /\ First(i) /\ (pr[a] = 0) = (t = "launch") /\ ~over[a]
    /\ idle[a] \/ t \in {"call", "waiter"} \/ Break = "IntoRunningTurn"
    /\ ~stopping[a] \/ Break = "MarkWhileStopping"
    /\ Reaches(i, t)
    /\ row' = [row EXCEPT ![i].st = "sending", ![i].via = t, ![i].at = pr[a]]
    /\ hand' = hand \cup {i}
    /\ call' = IF t = "call" /\ call[i] = "waiting" THEN [call EXCEPT ![i] = "writing"] ELSE call
    /\ wrong' = wrong \cup (IF idle[a] \/ t \in {"call", "waiter"} THEN {} ELSE {"running turn"})
    /\ UNCHANGED <<claimed, wire, waiter, tx, fold, rmem, last, unsure, lost>>

\* The transport hands it on: a stream line claimed for its process's FIFO,
\* a waiter of its process answered, or the Inlet's write done.
Handed(i) ==
    LET a == row[i].to IN
    /\ up /\ i \in hand /\ row[i].via \in {"stream", "waiter", "typed"} /\ Open(i)
    /\ hand' = hand \ {i}
    /\ wire' = [wire EXCEPT ![i] = @ + 1]
    /\ claimed' = IF row[i].via = "stream" THEN claimed \cup {i} ELSE claimed
    /\ waiter' = IF row[i].via = "waiter" THEN [waiter EXCEPT ![a] = 0] ELSE waiter
    /\ UNCHANGED <<row, call, tx, fold, rmem, last, unsure, lost, wrong>>

\* launch: the start is the hand-on. The row's text is the start's prompt
\* argument, for the process p the start makes (the instancing spec starts
\* it in the same step: a new process, idle, no turn of it ended yet).
Launch(i, p) ==
    /\ up /\ i \in hand /\ row[i].via = "launch" /\ Open(i)
    /\ hand' = hand \ {i}
    /\ wire' = [wire EXCEPT ![i] = @ + 1]
    /\ row' = [row EXCEPT ![i].at = p]
    /\ UNCHANGED <<claimed, waiter, call, tx, fold, rmem, last, unsure, lost, wrong>>

\* The transport refuses: nothing went out, and the mark is undone. A start
\* may be refused whatever its check read (a setup that failed, say).
Refused(i) ==
    /\ up /\ i \in hand
    /\ \/ row[i].via \in {"stream", "waiter", "typed"} /\ ~Open(i)
       \/ row[i].via = "launch"
    /\ hand' = hand \ {i}
    /\ row' = [row EXCEPT ![i] = Due(i)]
    /\ UNCHANGED <<claimed, wire, waiter, call, tx, fold, rmem, last, unsure, lost, wrong>>

\* The Inlet answers unknown: the keys may have gone in. The mark stays, for
\* the evidence; under UnknownUndone it is undone.
Unknown(i) ==
    /\ up /\ i \in hand /\ row[i].via = "typed" /\ Open(i)
    /\ hand' = hand \ {i}
    /\ wire' \in {wire, [wire EXCEPT ![i] = @ + 1]}
    /\ row' = IF Break = "UnknownUndone" THEN [row EXCEPT ![i] = Due(i)] ELSE row
    /\ UNCHANGED <<claimed, waiter, call, tx, fold, rmem, last, unsure, lost, wrong>>

\* After a restart, a stream row whose line is not claimed is claimed again:
\* the spool is still there, so nothing of it went in.
Reclaim(i) ==
    /\ up /\ row[i].st = "sending" /\ row[i].via = "stream" /\ i \notin hand /\ i \notin claimed
    /\ hand' = hand \cup {i}
    /\ UNCHANGED <<row, claimed, wire, waiter, call, tx, fold, rmem, last, unsure, lost, wrong>>

\* Claude Code takes a text handed to its process: it goes into the
\* transcript and a turn starts with it (the instancing spec starts it). A
\* stream line joins a running turn, and so does a waiter's answer, queued
\* until the turn's next tool boundary; typed keys start a turn once the
\* session's own has ended.
Take(i) ==
    LET a == row[i].to IN
    /\ wire[i] > 0 /\ pr[a] # 0 /\ (pr[a] = row[i].at \/ Break = "AnyProcess")
    /\ row[i].via \in {"stream", "waiter"} \/ idle[a]
    /\ wire' = [wire EXCEPT ![i] = @ - 1]
    /\ tx' = [tx EXCEPT ![a] = Append(@, i)]
    /\ fold' = [fold EXCEPT ![i] = "turn"]
    /\ last' = IF Break = "SelfReply" THEN [last EXCEPT ![a] = NoResult] ELSE last
    /\ wrong' = wrong \cup (IF pr[a] # row[i].at THEN {"other process"} ELSE {})
    /\ UNCHANGED <<row, hand, claimed, waiter, call, rmem, unsure, lost>>

\* stream: the replay of the line, read by the fold while its process runs.
SettleReplay(i) ==
    LET a == row[i].to IN
    /\ up /\ row[i].st = "sending" /\ row[i].via = "stream" /\ i \notin hand
    /\ InTx(i) /\ pr[a] = row[i].at
    /\ row' = [row EXCEPT ![i] = Delivered(i)]
    /\ claimed' = claimed \ {i}
    /\ UNCHANGED <<hand, wire, waiter, call, tx, fold, rmem, last, unsure, lost, wrong>>

\* stream: its process is gone with no replay read; the transcript decides.
\* Not there, the row is undelivered, which is final: due again, first.
SettleExit(i, has) ==
    LET a == row[i].to IN
    /\ up /\ row[i].st = "sending" /\ row[i].via = "stream" /\ i \notin hand
    /\ pr[a] # row[i].at
    /\ row' = [row EXCEPT ![i] = IF has /\ Break # "LogOnlyAtExit" THEN Delivered(i)
                                                                  ELSE DueAgain(i)]
    /\ claimed' = claimed \ {i}
    /\ wire' = [wire EXCEPT ![i] = 0]
    /\ UNCHANGED <<hand, waiter, call, tx, fold, rmem, last, unsure, lost, wrong>>

\* waiter, typed and launch: the transcript (`has`): a waiter's take line (a
\* dequeue or a remove) and a launch's user line at once, a typed write's
\* once the turn that took it has ended. There, delivered; not there, due
\* again once no answer of it is on its way to a turn, or the process it was
\* for is gone (a launch whose start a restart cut never made it).
SettleSeen(i, has) ==
    LET a == row[i].to  gone == pr[a] # row[i].at IN
    /\ up /\ row[i].st = "sending" /\ row[i].via \in {"waiter", "typed", "launch"}
    /\ i \notin hand
    /\ \/ has /\ (idle[a] \/ gone \/ row[i].via \in {"waiter", "launch"})
          /\ row' = [row EXCEPT ![i] = Delivered(i)]
       \/ ~has /\ (wire[i] = 0 \/ gone \/ Break = "SettleEarly")
          /\ row' = [row EXCEPT ![i] = DueAgain(i)]
    /\ wire' = IF gone THEN [wire EXCEPT ![i] = 0] ELSE wire
    /\ UNCHANGED <<hand, claimed, waiter, call, tx, fold, rmem, last, unsure, lost, wrong>>

-----------------------------------------------------------------------------
(* The call transport: a run_delegate that waits on a row *)

callOthers == <<claimed, wire, waiter, fold, rmem, last, wrong>>

\* The agent calls run_delegate, in a turn (the instancing spec's guard).
CallWaits(i) ==
    /\ up /\ i \in Awaited /\ call[i] = "none"
    /\ call' = [call EXCEPT ![i] = "waiting"]
    /\ UNCHANGED <<row, hand, tx, unsure, lost, callOthers>>

\* The call's deadline: it answers the timeout, and the row goes another way.
Deadline(i) ==
    /\ up /\ call[i] = "waiting"
    /\ call' = [call EXCEPT ![i] = "timedout"]
    /\ UNCHANGED <<row, hand, tx, unsure, lost, callOthers>>

\* The endpoint writes the answer. The agent has it while the calling
\* process runs; the write fails on a reset connection; or it succeeds to a
\* client that had gone, its process ended or, under ClientLeaves, given up.
Written(i) ==
    LET a == row[i].to  runs == pr[a] = row[i].at IN
    /\ call[i] = "writing"
    /\ \/ /\ runs
          /\ call' = [call EXCEPT ![i] = "wrote"]
          /\ tx' = [tx EXCEPT ![a] = Append(@, i)]
          /\ UNCHANGED lost
       \/ /\ call' = [call EXCEPT ![i] = "failed"]
          /\ UNCHANGED <<tx, lost>>
       \/ /\ ~runs \/ ClientLeaves
          /\ call' = [call EXCEPT ![i] = "wrote"]
          /\ lost' = lost \cup {<<i, IF runs THEN "left" ELSE "gone">>}
          /\ UNCHANGED tx
    /\ UNCHANGED <<row, hand, unsure, callOthers>>

\* The handler tells the outcome: delivered when the write succeeded and the
\* calling process still runs after it; due again otherwise.
Told(i) ==
    LET a == row[i].to
        ok == \/ call[i] = "wrote" /\ (pr[a] = row[i].at \/ Break = "CallerNotChecked")
              \/ Break = "AnsweredOnFailure"
    IN
    /\ up /\ i \in hand /\ row[i].via = "call" /\ call[i] \in {"wrote", "failed"}
    /\ hand' = hand \ {i}
    /\ call' = [call EXCEPT ![i] = "done"]
    /\ row' = [row EXCEPT ![i] = IF ok THEN Delivered(i) ELSE DueAgain(i)]
    /\ unsure' = IF ~ok /\ call[i] = "wrote" THEN unsure \cup {i} ELSE unsure
    /\ UNCHANGED <<tx, lost, callOthers>>

\* The handler that waits ends, at any step of its call.
CallerEnds(i) ==
    /\ call[i] \in {"waiting", "writing", "wrote", "failed"}
    /\ call' = [call EXCEPT ![i] = "gone"]
    /\ UNCHANGED <<row, hand, tx, unsure, lost, callOthers>>

\* Mailbox watches the handler from the take: at its end the row is due
\* again, and its write may have reached the agent.
CallerSeen(i) ==
    /\ up /\ Break # "NoCallerWatch"
    /\ call[i] = "gone" /\ i \in hand /\ row[i].via = "call" /\ row[i].st = "sending"
    /\ hand' = hand \ {i}
    /\ call' = [call EXCEPT ![i] = "done"]
    /\ row' = [row EXCEPT ![i] = DueAgain(i)]
    /\ unsure' = unsure \cup {i}
    /\ UNCHANGED <<tx, lost, callOthers>>

\* A restart ended the call it was taken for: due again, for the waiter.
SettleCut(i) ==
    /\ up /\ Break # "NoRestartHold"
    /\ row[i].st = "sending" /\ row[i].via = "call" /\ i \notin hand
    /\ row' = [row EXCEPT ![i] = DueAgain(i)]
    /\ UNCHANGED <<hand, call, tx, unsure, lost, callOthers>>

-----------------------------------------------------------------------------
(* The waiter, the fold, a restart and a session's end *)

\* A turn's end starts the session's next waiter, which connects: never
\* before a turn of the process has ended.
Connects(a) ==
    /\ up /\ a \notin Headless /\ pr[a] # 0 /\ idle[a] /\ turned[a] /\ waiter[a] # pr[a]
    /\ waiter' = [waiter EXCEPT ![a] = pr[a]]
    /\ UNCHANGED <<row, hand, claimed, wire, call, tx, fold, rmem, last, unsure, lost, wrong>>

\* The waiter's own deadline, or its program gone.
WaiterEnds(a) ==
    /\ waiter[a] # 0
    /\ waiter' = [waiter EXCEPT ![a] = 0]
    /\ UNCHANGED <<row, hand, claimed, wire, call, tx, fold, rmem, last, unsure, lost, wrong>>

\* a's turn ends with a result, which names the rows whose turn it was.
Result(a) ==
    /\ fold' = [i \in Ids |-> IF i \in InTurn(a) THEN "result" ELSE fold[i]]
    /\ last' = IF Break = "SelfReply"
                 THEN [last EXCEPT ![a] = IF InTurn(a) = {} THEN OwnTurn
                                                            ELSE CHOOSE i \in InTurn(a) : TRUE]
                 ELSE last
    /\ UNCHANGED <<row, hand, claimed, wire, waiter, call, tx, rmem, unsure, lost, wrong>>

\* a's process ends: a turn it ran has no result, and never will; its
\* waiter's connection closes with it. A stop's SIGTERM (`term`) that cuts
\* a turn a row started has cut a delivery.
Exited(a, term) ==
    /\ fold' = [i \in Ids |-> IF i \in InTurn(a) THEN "exited" ELSE fold[i]]
    /\ waiter' = [waiter EXCEPT ![a] = 0]
    /\ wrong' = wrong \cup (IF term /\ InTurn(a) # {} THEN {"cut"} ELSE {})
    /\ UNCHANGED <<row, hand, claimed, wire, call, tx, rmem, last, unsure, lost>>

\* What a restart does to Mailbox: its memory goes, the waiters' and the
\* calls' connections end with the node. Under RedeliverAfterRestart a row a
\* restart left sending by waiter or typed is made due again, unread.
Restart ==
    /\ hand' = {}
    /\ waiter' = [a \in Addrs |-> 0]
    /\ call' = [i \in Ids |-> IF call[i] \in {"none", "timedout", "done"} THEN call[i] ELSE "done"]
    /\ unsure' = unsure \cup {i \in Ids : call[i] \in {"wrote", "gone"} /\ row[i].via = "call"
                                          /\ row[i].st = "sending"}
    /\ rmem' = {}
    /\ row' = IF Break = "RedeliverAfterRestart"
                THEN [i \in Ids |-> IF row[i].st = "sending"
                                         /\ row[i].via \in {"waiter", "typed", "launch"}
                                      THEN DueAgain(i) ELSE row[i]]
                ELSE row
    /\ UNCHANGED <<claimed, wire, tx, fold, last, lost, wrong>>

\* A due row to a session that ended for good is marked ended: it never went
\* in. Under EndedUnsettled a row still sending is marked too.
EndedFirst(i) ==
    /\ up /\ Break # "NoEndedMark"
    /\ row[i].to \in Addrs /\ over[row[i].to]
    /\ \/ row[i].st = "due"
       \/ Break = "EndedUnsettled" /\ row[i].st = "sending" /\ i \notin hand
    /\ row' = [row EXCEPT ![i].st = "ended"]
    /\ UNCHANGED <<hand, claimed, wire, waiter, call, tx, fold, rmem, last, unsure, lost, wrong>>

-----------------------------------------------------------------------------
(* Replies and notices, one per key; a resumed process's row to go on *)

\* The result Mailbox takes as row i's reply: the one the fold keeps on i.
\* SelfReply reads the last result since i went in, whatever it names.
ReplySource(i) ==
    IF Break = "SelfReply"
      THEN IF LastIn(row[i].to) = i THEN last[row[i].to] ELSE NoResult
      ELSE IF fold[i] = "result" THEN i ELSE NoResult

Answerable(i) ==
    /\ up /\ row[i].to \in Headless /\ row[i].st = "delivered"
    /\ row[i].kind \in {"msg", "brief", "resume"}
    /\ NextId \in Ids

answerOthers == <<hand, claimed, wire, waiter, call, tx, fold, last, unsure, lost, wrong>>

\* The reply: from the session to the row's sender, under the row's key.
ReplyStored(i) ==
    LET src == ReplySource(i) IN
    /\ Answerable(i) /\ src # NoResult
    /\ IF Break = "ReplyInMemory" THEN i \notin rmem ELSE Answered(row[i].re) = {}
    /\ StoreRow(NextId, row[i].to, row[row[i].re].from, "reply", row[i].re, src)
    /\ rmem' = IF Break = "ReplyInMemory" THEN rmem \cup {i} ELSE rmem
    /\ UNCHANGED answerOthers

\* The process ended in i's turn with no result: the framework's notice,
\* under the same key. ReplyAndNotice reads the process's end after i, not
\* the fold, and checks only for a notice.
NoticeStored(i) ==
    LET a == row[i].to IN
    /\ Answerable(i) /\ Break # "NoNotice" /\ row[i].kind \in {"msg", "resume"}
    /\ IF Break = "ReplyAndNotice"
         THEN /\ pr[a] # row[i].at /\ LastIn(a) = i /\ fold[i] # "turn"
              /\ ~\E j \in Answered(row[i].re) : row[j].kind = "notice"
         ELSE fold[i] = "exited" /\ Answered(row[i].re) = {}
    /\ StoreRow(NextId, Framework, row[row[i].re].from, "notice", row[i].re, NoResult)
    /\ UNCHANGED <<rmem>> /\ UNCHANGED answerOthers

\* A brief whose turn its process's end cut: the resumed process gets a row
\* to go on, under the brief's key, so its result is the report.
GoOn(i) ==
    LET a == row[i].to IN
    /\ Answerable(i) /\ row[i].kind = "brief" /\ fold[i] = "exited" /\ pr[a] # 0
    /\ ~\E j \in To(a) : row[j].kind = "resume" /\ row[j].re = row[i].re
    /\ Answered(row[i].re) = {}
    /\ StoreRow(NextId, Framework, a, "resume",
                IF Break = "ResumeOwnKey" THEN NextId ELSE row[i].re, NoResult)
    /\ UNCHANGED <<rmem>> /\ UNCHANGED answerOthers

-----------------------------------------------------------------------------
(* Alone: senders, sessions, Sessions' stop, restarts *)

Init ==
    /\ up = TRUE /\ restarts = 0
    /\ pr = [a \in Addrs |-> IF a \in Launched THEN 0 ELSE 1]
    /\ lives = [a \in Addrs |-> IF a \in Launched THEN 0 ELSE 1]
    /\ idle = [a \in Addrs |-> TRUE] /\ stopping = [a \in Addrs |-> FALSE]
    /\ over = [a \in Addrs |-> FALSE] /\ turned = [a \in Addrs |-> FALSE]
    /\ ends = 0 /\ prompts = 0 /\ stops = 0 /\ readAt = [a \in Addrs |-> 0]
    /\ row = [i \in Ids |-> NoRow] /\ hand = {} /\ claimed = {}
    /\ wire = [i \in Ids |-> 0] /\ waiter = [a \in Addrs |-> 0]
    /\ call = [i \in Ids |-> "none"]
    /\ tx = [a \in Addrs |-> <<>>] /\ fold = [i \in Ids |-> "none"]
    /\ rmem = {} /\ last = [a \in Addrs |-> NoResult]
    /\ unsure = {} /\ lost = {} /\ wrong = {}

Mailbox(A) == A /\ UNCHANGED <<avars, alone>>

\* A sender stores a row; the first to a headless session is its brief.
Sends(i, s, a) ==
    /\ i <= MaxSent /\ ~over[a]
    /\ Store(i, s, a, IF a \in Headless \cup Launched /\ To(a) = {} THEN "brief" ELSE "msg")
    /\ UNCHANGED <<avars, alone>>

\* A take starts a turn; a call's write goes into the turn that called.
Takes(i) == Take(i) /\ idle' = [idle EXCEPT ![row[i].to] = FALSE]
            /\ UNCHANGED <<up, pr, stopping, over, turned, alone>>

Prompted(a) ==
    /\ a \notin Headless /\ pr[a] # 0 /\ idle[a] /\ prompts < MaxPrompts
    /\ idle' = [idle EXCEPT ![a] = FALSE] /\ prompts' = prompts + 1
    /\ UNCHANGED <<up, pr, stopping, over, turned, dvars, restarts, lives, ends, stops, readAt>>

SelfStarts(a) ==
    /\ SelfTurns /\ a \in Headless /\ pr[a] # 0 /\ idle[a]
    /\ idle' = [idle EXCEPT ![a] = FALSE]
    /\ UNCHANGED <<up, pr, stopping, over, turned, dvars, alone>>

TurnEnds(a) ==
    /\ pr[a] # 0 /\ ~idle[a]
    /\ idle' = [idle EXCEPT ![a] = TRUE] /\ turned' = [turned EXCEPT ![a] = TRUE] /\ Result(a)
    /\ UNCHANGED <<up, pr, stopping, over, alone>>

\* The process ends, by itself (Ends) or by the stop's SIGTERM (Term).
ProcEnds(a, term) ==
    /\ pr' = [pr EXCEPT ![a] = 0] /\ idle' = [idle EXCEPT ![a] = TRUE]
    /\ turned' = [turned EXCEPT ![a] = FALSE]
    /\ readAt' = [readAt EXCEPT ![a] = 0] /\ Exited(a, term)

Ends(a) ==
    /\ pr[a] # 0 /\ ends < MaxEnds /\ ends' = ends + 1 /\ ProcEnds(a, FALSE)
    /\ UNCHANGED <<up, stopping, over, restarts, lives, prompts, stops>>

\* Sessions starts a new process of the session, its turn not begun. A
\* launched session starts only by a launch, which carries its first row.
NewProcess(a) ==
    /\ lives' = [lives EXCEPT ![a] = @ + 1] /\ pr' = [pr EXCEPT ![a] = lives[a] + 1]
    /\ idle' = [idle EXCEPT ![a] = TRUE] /\ stopping' = [stopping EXCEPT ![a] = FALSE]
    /\ turned' = [turned EXCEPT ![a] = FALSE]

Resumed(a) ==
    /\ up /\ pr[a] = 0 /\ ~over[a] /\ a \notin Launched
    /\ NewProcess(a)
    /\ UNCHANGED <<up, over, dvars, restarts, ends, prompts, stops, readAt>>

Launches(i) ==
    LET a == row[i].to IN
    /\ a \in Addrs /\ Launch(i, lives[a] + 1) /\ NewProcess(a)
    /\ UNCHANGED <<up, over, restarts, ends, prompts, stops, readAt>>

\* The stop: the row says stopping first; the idle read waits until the
\* turn has ended and no row to the session is sending; then the SIGTERM,
\* a step of its own, which cuts a turn a prompt started in between.
StopAsked(a) ==
    /\ up /\ pr[a] # 0 /\ ~stopping[a] /\ stops < MaxStops
    /\ stopping' = [stopping EXCEPT ![a] = TRUE] /\ stops' = stops + 1
    /\ UNCHANGED <<up, pr, idle, over, turned, dvars, restarts, lives, ends, prompts, readAt>>

IdleRead(a) ==
    /\ up /\ stopping[a] /\ pr[a] # 0 /\ idle[a] /\ readAt[a] = 0
    /\ Break = "StopWhileSending" \/ ~\E i \in To(a) : row[i].st = "sending"
    /\ readAt' = [readAt EXCEPT ![a] = pr[a]]
    /\ UNCHANGED <<avars, dvars, restarts, lives, ends, prompts, stops>>

Term(a) ==
    /\ readAt[a] # 0 /\ readAt[a] = pr[a] /\ ProcEnds(a, TRUE)
    /\ UNCHANGED <<up, stopping, over, restarts, lives, ends, prompts, stops>>

\* A headless session ends for good (a delegate's end): rows still due to
\* it are marked ended; one in flight is settled first.
Over(a) ==
    /\ up /\ a \in Headless /\ ~over[a] /\ pr[a] # 0
    /\ over' = [over EXCEPT ![a] = TRUE] /\ ProcEnds(a, FALSE)
    /\ UNCHANGED <<up, stopping, restarts, lives, ends, prompts, stops>>

FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1 /\ readAt' = [a \in Addrs |-> 0]
    /\ Restart
    /\ UNCHANGED <<pr, idle, stopping, over, turned, lives, ends, prompts, stops>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<pr, idle, stopping, over, turned, dvars, alone>>

\* The agent calls run_delegate in a turn, on a row stored for it.
CallMade(i) ==
    /\ row[i].st \in {"due", "sending"} /\ row[i].to \notin Headless
    /\ pr[row[i].to] # 0 /\ ~idle[row[i].to]
    /\ Mailbox(CallWaits(i))

Settle(i) ==
    \/ SettleReplay(i) \/ SettleExit(i, InTx(i)) \/ SettleSeen(i, InTx(i))

Next ==
    \/ FrameworkDies \/ FrameworkStarts
    \/ \E a \in Addrs : \/ Prompted(a) \/ SelfStarts(a) \/ TurnEnds(a) \/ Ends(a)
                        \/ Resumed(a) \/ StopAsked(a) \/ IdleRead(a) \/ Term(a) \/ Over(a)
                        \/ Mailbox(Connects(a)) \/ Mailbox(WaiterEnds(a))
    \/ \E i \in Ids : \/ \E s \in Senders, a \in Addrs : Sends(i, s, a)
                      \/ \E t \in Transports : Mailbox(Mark(i, t))
                      \/ Mailbox(Handed(i) \/ Refused(i) \/ Unknown(i) \/ Reclaim(i))
                      \/ Launches(i)
                      \/ Takes(i) \/ Mailbox(Settle(i))
                      \/ CallMade(i)
                      \/ Mailbox(Deadline(i) \/ Written(i) \/ Told(i) \/ CallerEnds(i)
                                 \/ CallerSeen(i) \/ SettleCut(i))
                      \/ Mailbox(EndedFirst(i))
                      \/ Mailbox(ReplyStored(i) \/ NoticeStored(i) \/ GoOn(i))

\* One row's steps after its mark and hand-on, but the take: each is the
\* next one the row can take, so one fairness for them all is enough, and
\* keeps TLC fast. The take is strongly fair: a prompt may take the turn
\* each time an answer waits for it.
RowSteps(i) ==
    Mailbox(\/ Refused(i) \/ Reclaim(i) \/ Settle(i) \/ Deadline(i) \/ Written(i) \/ Told(i)
               \/ CallerSeen(i) \/ SettleCut(i) \/ EndedFirst(i) \/ ReplyStored(i)
               \/ NoticeStored(i) \/ GoOn(i))

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A a \in Addrs : /\ WF_vars(TurnEnds(a) \/ Resumed(a) \/ IdleRead(a) \/ Term(a))
                        /\ WF_vars(Mailbox(Connects(a)))
    /\ \A i \in Ids : /\ SF_vars(\E t \in Transports : Mailbox(Mark(i, t)))
                     /\ SF_vars(Mailbox(Handed(i))) /\ SF_vars(Takes(i))
                     /\ SF_vars(Launches(i))
                     /\ WF_vars(RowSteps(i))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ \A i \in Ids : /\ row[i].st \in {"none", "due", "sending", "delivered", "ended", "kept"}
                      /\ row[i].via \in Transports \cup {"none"}
                      /\ row[i].kind \in {"none", "msg", "brief", "resume", "reply", "notice",
                                         "ask", "answer"}
    /\ hand \subseteq Ids /\ claimed \subseteq Ids /\ unsure \subseteq Ids
    /\ wire \in [Ids -> 0..2]
    /\ call \in [Ids -> {"none", "waiting", "timedout", "writing", "wrote", "failed", "gone",
                         "done"}]
    /\ fold \in [Ids -> {"none", "turn", "result", "exited"}]

\* Each row is in a transcript at most once. The one exception is a call's
\* write that may have reached the agent before its row was due again.
AtMostOnce == \A i \in Ids : Count(i) <= 1 \/ i \in unsure

\* A row is marked only when its addressee's turn has ended, but for a call
\* (it answers inside the turn that called) and a waiter (Claude Code queues
\* its answer into a running turn; nothing is typed). IntoRunningTurn breaks
\* it through the typed write and the stream.
OnlyIntoEndedTurn == "running turn" \notin wrong

\* No turn a row started is cut by a stop's SIGTERM: nothing goes into a
\* session whose row is stopping once its idle read is made.
NotCutByStop == "cut" \notin wrong

\* A text reaches only the process it was marked for.
OnlyToItsProcess == "other process" \notin wrong

\* A sender's rows to one addressee go in in the order stored.
InOrder ==
    \A a \in Addrs : \A k, l \in DOMAIN tx[a] :
        LET m == tx[a][k]  n == tx[a][l] IN
        k < l /\ row[m].from = row[n].from => m <= n

\* A row is delivered only on its evidence: it is in the transcript, but
\* for a call's write to a client that gave up by its own limit.
DeliveredWasTaken ==
    \A i \in Ids : row[i].st = "delivered" => InTx(i) \/ <<i, "left">> \in lost

\* A row that says its session ended first is in no transcript.
EndedNotDelivered == \A i \in Ids : row[i].st = "ended" => Count(i) = 0

\* One answer per key: at most one reply, and never a reply and a notice.
ReplyOnce == \A k \in Ids : Cardinality({j \in Answered(k) : row[j].kind = "reply"}) <= 1
ReplyOrNotice == \A k \in Ids : \A j, l \in Answered(k) : row[j].kind = row[l].kind

\* A reply is the result that names a row under its key, never a turn the
\* session started by itself.
ReplyNamesItsRow ==
    \A j \in Ids : row[j].kind = "reply" => row[j].src > 0 /\ row[row[j].src].re = row[j].re

\* Every answer is keyed by a message or a brief: the report is the reply
\* to the brief, across a resume.
AnswersTheBrief ==
    \A j \in Ids : row[j].kind \in {"reply", "notice"} => row[row[j].re].kind \in {"msg", "brief"}

\* A row in flight settles.
SendingSettles == \A i \in Ids : row[i].st = "sending" ~> row[i].st # "sending"

\* A due row is delivered, or marked ended once its session ended. None
\* waits for a person's prompt: a long row is typed as a pointer (F-142).
\* NoPointer breaks it.
Arrives == \A i \in Ids : row[i].st = "due" ~> row[i].st \in {"delivered", "ended"}

\* A delivered row whose turn ends, with a result or with its process's
\* end, is answered under its key, unless its session ended for good.
AnswerComes ==
    \A i \in Ids : (row[i].st = "delivered" /\ row[i].kind \in {"msg", "brief", "resume"}
                    /\ row[i].to \in Headless /\ fold[i] \in {"result", "exited"})
                       ~> (Answered(row[i].re) # {} \/ (row[i].to \in Addrs /\ over[row[i].to]))

=============================================================================
