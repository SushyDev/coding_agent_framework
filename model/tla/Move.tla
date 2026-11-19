-------------------------------- MODULE Move --------------------------------
(***************************************************************************)
(* A main session moving from one Claude account to another: the drain,   *)
(* the wait for its background commands, its end by SIGTERM once an idle  *)
(* read finds its turn ended, the exit of its process, the copy of its    *)
(* transcript, the resume on the other account, and the old process's     *)
(* SessionEnd arriving late. Rows to the session (a delegate's report, a  *)
(* message) are Delivery.tla's: due while no process of the session runs, *)
(* never marked for a row that is stopping, delivered once, to the        *)
(* process that runs, and settled against the transcript of the account   *)
(* the session's row names, which after the move is the copy. The         *)
(* framework restarts at any step.                                        *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework (Mover is built, F-133;   *)
(* the idle read of background commands and the resume's launch, F-142):  *)
(*   Usage    each account's allowance: below 90 %, at 90 % (drain), at    *)
(*            the limit;                                                   *)
(*   Mover    drains the session, asks Sessions to stop it, waits for the  *)
(*            exit, copies the transcript, and resumes it on the other     *)
(*            account, the first due row as the resume's prompt (launch);  *)
(*            its phase is a row, so a restart goes on from it;            *)
(*   Sessions the session's row: its process and account, stopping while  *)
(*            the stop runs; the stop (the row says stopping, an idle read *)
(*            in memory, then the SIGTERM by pid and start time); and the  *)
(*            SessionEnd hook, which ends the row only when it names the   *)
(*            row's current process. The idle read is the session file's  *)
(*            status, which says `idle` only once the turn and every       *)
(*            background command of it have ended (`shell` while one runs, *)
(*            Claude Code 2.1.322), so the read waits for `bg`;            *)
(*   Mailbox  rows to the session, by the waiter, the typed write or the   *)
(*            launch (Delivery.tla, instanced as D). Any row may be long   *)
(*            (a report): it is typed as a pointer to its file. A waiter   *)
(*            connects only once a turn of the current process has ended   *)
(*            (`turned`).                                                  *)
(*                                                                         *)
(* A resumed process has no waiter until a turn of it ends, so the first   *)
(* row due at the resume goes in as its prompt; a later one is typed.      *)
(*                                                                         *)
(* A prompt through Remote Control may start a turn between the idle read *)
(* and the SIGTERM. The SIGTERM cuts it; what it wrote stays in the old   *)
(* account's transcript, and the copy after the exit keeps it. A row's    *)
(* turn is never cut that way: the idle read waits until no row to the    *)
(* session is sending, and none is marked while the row is stopping.      *)
(*                                                                         *)
(* Left abstract: Remote Control and the session's name; the delegates'   *)
(* own accounts, subagents and restarts (Delegate.tla), so a delegate     *)
(* ends with its report stored; run_delegate calls (Delivery.tla's call   *)
(* transport; the drain also waits for none under way); the allowance's   *)
(* weekly reset. The old process may crash once its stop is asked. One   *)
(* move per behavior: the session starts on Home and may move once.       *)
(*                                                                         *)
(* Fairness: the Mover's and Sessions' steps happen while possible, and   *)
(* it drains at 90 %; turns, background commands and a process asked to   *)
(* end each end in time; Mailbox's as in Delivery.tla. Prompts, usage,    *)
(* starts, delegates, crashes and restarts happen or not.                 *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and   *)
(* has a Break_Move_<value>.cfg that TLC must fail.                       *)
(*                                                                         *)
(* Defense in depth, with no Break: none in this spec.                    *)
(*                                                                         *)
(* Sessions' contract, its move (F-163): one process at a time             *)
(* (OneAccountAtATime), the whole transcript kept across the move          *)
(* (TranscriptKept, DeliveredIsKept), a late SessionEnd never ending the   *)
(* moved session, and with Delivery.tla's state a row once across the      *)
(* move, never into a turn the end cuts, only to its own process           *)
(* (OnceAcrossMove, NotCutByEnd, OnlyToItsProcess). Boxes.tla's move is a  *)
(* stop and a resume under one lease, with the evidence `ev` unchanged     *)
(* across it: TranscriptKept and DeliveredIsKept are what let it leave     *)
(* the account and the copy out.                                          *)
(*                                                                         *)
(* Restarts (F-164): the whole framework's, and the session's own agent    *)
(* process's (RestartAgent, B4's), at any step of the move, both bounded  *)
(* by MaxRestarts. The agent process holds the stop's idle read and the    *)
(* write of a row handed to the session; the Mover's phase and Sessions'   *)
(* row are rows, and Mailbox's own memory runs on. So its crash loses the  *)
(* read, which the stop makes again, and cuts the hand under way, whose    *)
(* mark is kept (Delivery.tla's AgentCut).                                 *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Accounts,      \* the two Claude accounts
    Home,          \* the account the session starts on
    Main,          \* the session
    Senders,       \* who messages it (another main session, say)
    MaxPrompts,    \* prompts a person sends over the whole behavior
    MaxBg,         \* background commands started
    MaxDelegates,  \* delegates started
    MaxMsgs,       \* messages sent to the session
    MaxCrashes,    \* crashes of the old process once its stop is asked
    MaxRestarts,   \* restarts of the framework and of the session's agent process
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "NoDrain",           \* draining does not stop new background commands and delegates
    "NoIdleRead",        \* the SIGTERM is sent without an idle read
    "ShellIsIdle",       \* the idle read takes the file's `shell` for `idle`
    "LateEndEndsNew",    \* a SessionEnd ends the row whatever process it names
    "ResumeBeforeEnd",   \* the copy and resume do not wait for the old process to exit
    "CopyBeforeEnd",     \* the transcript is copied before the process is ended
    "MarkWhileEnding",   \* Mailbox marks and hands on rows while the session's row is stopping
    "StopWhileSending",  \* the idle read does not wait for rows to the session sending
    "SettleOnTarget"     \* a row is settled against the target's transcript before the copy
}

ASSUME Break \in Breaks
ASSUME Home \in Accounts /\ Cardinality(Accounts) = 2
ASSUME \A c \in {MaxPrompts, MaxBg, MaxDelegates, MaxMsgs, MaxCrashes, MaxRestarts} : c \in Nat

\* Allowance levels.
Ok == 0
DrainLevel == 1   \* 90 % of the weekly allowance
Limit == 2

Phases == {"idle", "draining", "clear", "stopping", "ending", "moved"}
Ids == 1..(MaxDelegates + MaxMsgs)
Delegates == 1..MaxDelegates
PromptMark == 0   \* a prompt's turn in a transcript; a row is its id

VARIABLES
    up, restarts,  \* the framework runs; restarts so far
    level,         \* account -> its allowance level
    procs,         \* the session's Claude Code processes: [pid, account, ending]
    nextPid,       \* the last pid given
    turn,          \* the pid whose turn runs, or 0
    bg,            \* running background commands: [id, pid], children of that process
    bgCount,       \* background commands started so far; also the last id given
    delegates,     \* d -> "none", "running", "reported" (its report stored as a row)
    prompts,       \* prompts sent
    msgs,          \* messages sent
    crashes,       \* crashes so far
    transcript,    \* account -> the session's transcript there: rows and prompts' turns
    phase,         \* the Mover's phase (a row)
    target,        \* the account it moves to
    copied,        \* the transcript is copied to the target
    resumedWith,   \* the transcript the resumed session started from, or <<>>
    record,        \* Sessions' row: [pid, account, status: running, stopping, ended]
    readAt,        \* Sessions, in memory: the pid whose idle read the stop made, or 0
    ends,          \* SessionEnd hooks sent and not yet handled: the pids they name
    lost,          \* ghost: work a move cut off: [kind, id]
    turned,        \* a turn of the current process has ended
    \* Delivery's, for the rows to the session
    row, hand, claimed, wire, waiter, call, tx, fold, rmem, last, unsure, dlost, wrong

dvars == <<row, hand, claimed, wire, waiter, call, tx, fold, rmem, last, unsure, dlost, wrong>>
work == <<level, procs, nextPid, turn, bg, bgCount, delegates, prompts, msgs, crashes>>
mover == <<transcript, phase, target, copied, resumedWith, record, readAt, ends, lost, turned>>

vars == <<up, restarts, work, mover, dvars>>

Live == {p \in procs : ~p.ending}
Pids == {p.pid : p \in procs}
Here == record.account

\* The process Mailbox sees: the row's, while it runs.
Current == IF record.pid \in Pids THEN record.pid ELSE 0
AccountOf(pid) == (CHOOSE p \in procs : p.pid = pid).account

D == INSTANCE Delivery WITH
       Ids <- Ids, Addrs <- {Main}, Headless <- {}, Senders <- Senders, MaxSent <- 0,
       Awaited <- {}, ClientLeaves <- FALSE, SelfTurns <- FALSE, MaxRestarts <- 0, MaxEnds <- 0,
       MaxPrompts <- 0, MaxStops <- 0,
       Break <- CASE Break = "MarkWhileEnding" -> "MarkWhileStopping"
                  [] Break = "StopWhileSending" -> "StopWhileSending"
                  [] OTHER -> "none",
       up <- up,
       pr <- [a \in {Main} |-> Current],
       idle <- [a \in {Main} |-> turn = 0],
       stopping <- [a \in {Main} |-> record.status = "stopping" /\ Current # 0],
       over <- [a \in {Main} |-> FALSE],
       turned <- [a \in {Main} |-> turned], Long <- Ids, Launched <- {},
       lost <- dlost,
       restarts <- 0, lives <- 0, ends <- 0, prompts <- 0, stops <- 0, readAt <- 0,
       forced <- {}, fcall <- {}

\* Starts are refused from the drain on until the session has moved.
Draining == phase \in {"draining", "clear", "stopping", "ending"} /\ Break # "NoDrain"

DelegatesStarted == Cardinality({d \in Delegates : delegates[d] # "none"})

-----------------------------------------------------------------------------
Init ==
    /\ up = TRUE /\ restarts = 0
    /\ level = [a \in Accounts |-> Ok]
    /\ procs = {[pid |-> 1, account |-> Home, ending |-> FALSE]}
    /\ nextPid = 1 /\ turn = 0
    /\ bg = {} /\ bgCount = 0
    /\ delegates = [d \in Delegates |-> "none"]
    /\ prompts = 0 /\ msgs = 0 /\ crashes = 0
    /\ transcript = [a \in Accounts |-> <<>>]
    /\ phase = "idle" /\ target = Home /\ copied = FALSE /\ resumedWith = <<>>
    /\ record = [pid |-> 1, account |-> Home, status |-> "running"]
    /\ readAt = 0 /\ ends = {} /\ lost = {} /\ turned = TRUE
    /\ row = [i \in Ids |-> D!NoRow] /\ hand = {} /\ claimed = {}
    /\ wire = [i \in Ids |-> 0] /\ waiter = [a \in {Main} |-> 0]
    /\ call = [i \in Ids |-> "none"]
    /\ tx = [a \in {Main} |-> <<>>] /\ fold = [i \in Ids |-> "none"]
    /\ rmem = {} /\ last = [a \in {Main} |-> D!NoResult]
    /\ unsure = {} /\ dlost = {} /\ wrong = {}

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; its memory does not *)

FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1 /\ readAt' = 0
    /\ D!Restart
    /\ UNCHANGED <<work, transcript, phase, target, copied, resumedWith, record, ends, lost,
                   turned>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<restarts, work, mover, dvars>>

\* The session's agent process crashes and its supervisor starts it again,
\* in one step: nothing reads its memory in between. The idle read made
\* there is lost and a hand to the session under way is cut; its init
\* re-adopts the process from the row, never starting one.
RestartAgent ==
    /\ up /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1 /\ readAt' = 0
    /\ \E went \in BOOLEAN : D!AgentCut(Main, went)
    /\ UNCHANGED <<up, work, transcript, phase, target, copied, resumedWith, record, ends, lost,
                   turned>>

-----------------------------------------------------------------------------
(* Usage, and the session's own work *)

UsageRises ==
    /\ level[Here] < Limit
    /\ level' = [level EXCEPT ![Here] = @ + 1]
    /\ UNCHANGED <<up, restarts, procs, nextPid, turn, bg, bgCount, delegates, prompts, msgs,
                   crashes, mover, dvars>>

\* A person sends a prompt, in the terminal or through Remote Control, at
\* any time the turn has ended, between the idle read and the SIGTERM too.
\* The transcript holds it from its start.
PromptSent(p) ==
    /\ prompts < MaxPrompts
    /\ ~p.ending /\ turn = 0 /\ level[p.account] < Limit
    /\ prompts' = prompts + 1 /\ turn' = p.pid
    /\ transcript' = [transcript EXCEPT ![p.account] = Append(@, PromptMark)]
    /\ UNCHANGED <<up, restarts, level, procs, nextPid, bg, bgCount, delegates, msgs, crashes,
                   phase, target, copied, resumedWith, record, readAt, ends, lost, turned,
                   dvars>>

TurnEnds(p) ==
    /\ turn = p.pid /\ turn' = 0
    /\ turned' = (turned \/ p.pid = Current)
    /\ D!Result(Main)
    /\ UNCHANGED <<up, restarts, level, procs, nextPid, bg, bgCount, delegates, prompts, msgs,
                   crashes, transcript, phase, target, copied, resumedWith, record, readAt, ends,
                   lost>>

BgStarted(p) ==
    /\ bgCount < MaxBg /\ turn = p.pid /\ level[p.account] < Limit /\ ~Draining
    /\ bgCount' = bgCount + 1 /\ bg' = bg \cup {[id |-> bgCount + 1, pid |-> p.pid]}
    /\ UNCHANGED <<up, restarts, level, procs, nextPid, turn, delegates, prompts, msgs, crashes,
                   mover, dvars>>

BgEnds(b) ==
    /\ bg' = bg \ {b}
    /\ UNCHANGED <<up, restarts, level, procs, nextPid, turn, bgCount, delegates, prompts, msgs,
                   crashes, mover, dvars>>

-----------------------------------------------------------------------------
(* Delegates and messages: rows to the session *)

DelegateStarted(p, d) ==
    /\ up /\ delegates[d] = "none" /\ turn = p.pid /\ level[p.account] < Limit /\ ~Draining
    /\ delegates' = [delegates EXCEPT ![d] = "running"]
    /\ UNCHANGED <<up, restarts, level, procs, nextPid, turn, bg, bgCount, prompts, msgs,
                   crashes, mover, dvars>>

\* A delegate finishes in its own process; its report is stored as a row.
DelegateReports(d) ==
    /\ delegates[d] = "running"
    /\ delegates' = [delegates EXCEPT ![d] = "reported"]
    /\ D!Store(D!NextId, d, Main, "msg")
    /\ UNCHANGED <<up, restarts, level, procs, nextPid, turn, bg, bgCount, prompts, msgs,
                   crashes, mover>>

MessageSent(s) ==
    /\ msgs < MaxMsgs /\ msgs' = msgs + 1
    /\ D!Store(D!NextId, s, Main, "msg")
    /\ UNCHANGED <<up, restarts, level, procs, nextPid, turn, bg, bgCount, delegates, prompts,
                   crashes, mover>>

\* Mailbox's own steps, which change no state of the session's.
Mailbox(A) == A /\ UNCHANGED <<up, restarts, work, mover>>

\* Claude Code takes a row: a turn starts with it, in the transcript of the
\* account its process runs on.
Takes(i) ==
    /\ D!Take(i)
    /\ turn' = Current
    /\ transcript' = [transcript EXCEPT ![AccountOf(Current)] = Append(@, i)]
    /\ UNCHANGED <<up, restarts, level, procs, nextPid, bg, bgCount, delegates, prompts, msgs,
                   crashes, phase, target, copied, resumedWith, record, readAt, ends, lost,
                   turned>>

\* The transcript the framework reads for a row: the one on the account the
\* session's row names, which after the resume is the copy.
Read == IF Break = "SettleOnTarget" THEN transcript[target] ELSE transcript[Here]
Has(i) == \E k \in DOMAIN Read : Read[k] = i

-----------------------------------------------------------------------------
(* The move *)

\* Drain: a press, or the session's account at 90 % (Fairness).
Drain ==
    /\ up /\ phase = "idle"
    /\ \E a \in Accounts \ {Here} : level[a] = Ok /\ target' = a
    /\ phase' = "draining"
    /\ UNCHANGED <<up, restarts, work, transcript, copied, resumedWith, record, readAt, ends,
                   lost, turned, dvars>>

\* The drain is clear: no run_delegate call of the session waits (left
\* abstract). Background commands are read by the stop's idle read. Under
\* CopyBeforeEnd the transcript is copied here.
Cleared ==
    /\ up /\ phase = "draining"
    /\ phase' = "clear"
    /\ IF Break = "CopyBeforeEnd"
         THEN /\ transcript' = [transcript EXCEPT ![target] = transcript[Here]]
              /\ copied' = TRUE
         ELSE UNCHANGED <<transcript, copied>>
    /\ UNCHANGED <<up, restarts, work, target, resumedWith, record, readAt, ends, lost, turned,
                   dvars>>

\* Sessions' stop: the row says stopping first.
StopAsked ==
    /\ up /\ phase = "clear" /\ record.status = "running"
    /\ record' = [record EXCEPT !.status = "stopping"]
    /\ phase' = "stopping"
    /\ UNCHANGED <<up, restarts, work, transcript, target, copied, resumedWith, readAt, ends,
                   lost, turned, dvars>>

\* The idle read: the session file says idle, so the turn and every
\* background command have ended (`shell` while one runs), and no row to the
\* session is sending. Under NoIdleRead it reads nothing; under ShellIsIdle
\* it takes `shell` for `idle`.
IdleRead ==
    /\ up /\ phase = "stopping" /\ readAt = 0 /\ Current # 0
    /\ \/ Break = "NoIdleRead"
       \/ /\ turn = 0 /\ (bg = {} \/ Break = "ShellIsIdle")
          /\ Break = "StopWhileSending" \/ ~\E i \in Ids : row[i].st = "sending"
    /\ readAt' = Current
    /\ UNCHANGED <<up, restarts, work, transcript, phase, target, copied, resumedWith, record,
                   ends, lost, turned, dvars>>

\* The SIGTERM, a step of its own after the read, by the row's pid.
Term ==
    /\ up /\ phase = "stopping" /\ readAt # 0 /\ readAt = Current
    /\ procs' = {IF p.pid = readAt THEN [p EXCEPT !.ending = TRUE] ELSE p : p \in procs}
    /\ phase' = "ending" /\ readAt' = 0
    /\ UNCHANGED <<up, restarts, level, nextPid, turn, bg, bgCount, delegates, prompts, msgs,
                   crashes, transcript, target, copied, resumedWith, record, ends, lost,
                   turned, dvars>>

\* The process exits: by the SIGTERM, with whatever runs in it, or by a
\* crash once its stop was asked. A turn the SIGTERM cuts is lost to the
\* session but kept in the transcript; a background command the SIGTERM
\* ends is lost to the move (a crash would have ended it anyway). It
\* sends its SessionEnd, which may arrive at any later time.
Exits(p, why) ==
    /\ \/ why = "term" /\ p.ending
       \/ why = "crash" /\ ~p.ending /\ crashes < MaxCrashes /\ phase \in {"stopping", "ending"}
    /\ procs' = procs \ {p}
    /\ crashes' = IF why = "crash" THEN crashes + 1 ELSE crashes
    /\ lost' = IF why = "term"
                 THEN lost \cup {[kind |-> "bg", id |-> b.id] : b \in {c \in bg : c.pid = p.pid}}
                 ELSE lost
    /\ bg' = {b \in bg : b.pid # p.pid}
    /\ turn' = IF turn = p.pid THEN 0 ELSE turn
    /\ ends' = ends \cup {p.pid}
    /\ IF p.pid = Current THEN D!Exited(Main, why = "term") ELSE UNCHANGED dvars
    /\ UNCHANGED <<up, restarts, level, nextPid, bgCount, delegates, prompts, msgs, transcript,
                   phase, target, copied, resumedWith, record, readAt, turned>>

\* The old process has exited, so its transcript is final: copy it.
Copied ==
    /\ up /\ phase \in {"stopping", "ending"} /\ ~copied
    /\ procs = {} \/ Break = "ResumeBeforeEnd"
    /\ transcript' = [transcript EXCEPT ![target] = transcript[Here]]
    /\ copied' = TRUE
    /\ UNCHANGED <<up, restarts, work, phase, target, resumedWith, record, readAt, ends, lost,
                   turned, dvars>>

\* The first row due is marked by launch before the resume (Mailbox.launch),
\* once the old process is gone: the row is free, no longer stopping.
LaunchMarked(i) ==
    /\ up /\ phase \in {"stopping", "ending"} /\ copied /\ procs = {}
    /\ Mailbox(D!Mark(i, "launch"))

\* Resume on the target, with --resume; the row names the new process, whose
\* turn has not ended yet.
NewProc ==
    /\ nextPid' = nextPid + 1
    /\ procs' = procs \cup {[pid |-> nextPid + 1, account |-> target, ending |-> FALSE]}
    /\ record' = [pid |-> nextPid + 1, account |-> target, status |-> "running"]
    /\ resumedWith' = transcript[target]
    /\ phase' = "moved" /\ turned' = FALSE
    /\ UNCHANGED <<up, restarts, level, turn, bg, bgCount, delegates, prompts, msgs, crashes,
                   transcript, target, copied, readAt, ends, lost>>

\* The resume carries the row marked by launch as its prompt.
ResumedWith(i) ==
    /\ up /\ phase \in {"stopping", "ending"} /\ copied /\ procs = {}
    /\ D!Launch(i, nextPid + 1)
    /\ NewProc

\* A resume with no prompt, when no row to the session is due or in flight.
ResumedBare ==
    /\ up /\ phase \in {"stopping", "ending"} /\ copied
    /\ procs = {} \/ Break = "ResumeBeforeEnd"
    /\ \/ Break \in {"ResumeBeforeEnd"}
       \/ ~\E i \in Ids : row[i].st \in {"due", "sending"}
    /\ NewProc
    /\ UNCHANGED dvars

Resumed == ResumedBare \/ \E i \in Ids : ResumedWith(i)

\* Sessions ends the row only when the hook names the row's process.
SessionEndArrives(pid) ==
    /\ up /\ pid \in ends
    /\ ends' = ends \ {pid}
    /\ record' = IF pid = record.pid \/ Break = "LateEndEndsNew"
                   THEN [record EXCEPT !.status = "ended"] ELSE record
    /\ UNCHANGED <<up, restarts, work, transcript, phase, target, copied, resumedWith, readAt,
                   lost, turned, dvars>>

-----------------------------------------------------------------------------
Next ==
    \/ FrameworkDies \/ FrameworkStarts \/ RestartAgent \/ UsageRises
    \/ \E p \in procs : \/ PromptSent(p) \/ TurnEnds(p) \/ BgStarted(p)
                        \/ Exits(p, "term") \/ Exits(p, "crash")
                        \/ \E d \in Delegates : DelegateStarted(p, d)
    \/ \E b \in bg : BgEnds(b)
    \/ \E d \in Delegates : DelegateReports(d)
    \/ \E s \in Senders : MessageSent(s)
    \/ Drain \/ Cleared \/ StopAsked \/ IdleRead \/ Term \/ Copied \/ Resumed
    \/ \E pid \in ends : SessionEndArrives(pid)
    \/ Mailbox(D!Connects(Main)) \/ Mailbox(D!WaiterEnds(Main))
    \/ \E i \in Ids : \/ \E t \in {"waiter", "typed"} : Mailbox(D!Mark(i, t))
                      \/ LaunchMarked(i)
                      \/ Mailbox(D!Handed(i) \/ D!Unknown(i))
                      \/ Mailbox(D!Refused(i) /\ row[i].via # "launch")
                      \/ Takes(i)
                      \/ Mailbox(D!SettleSeen(i, Has(i)))

\* A resume is not refused here: Mover.ex goes back to the old account then,
\* and a refused launch makes its row due again for the next one.
Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ WF_vars(level[Here] >= DrainLevel /\ Drain)
    /\ WF_vars(Cleared) /\ WF_vars(StopAsked) /\ WF_vars(IdleRead) /\ WF_vars(Term)
    /\ WF_vars(Copied) /\ WF_vars(Resumed) /\ WF_vars(\E i \in Ids : LaunchMarked(i))
    /\ WF_vars(\E p \in procs : Exits(p, "term"))
    /\ WF_vars(\E p \in procs : TurnEnds(p))
    /\ WF_vars(\E b \in bg : BgEnds(b))
    /\ WF_vars(Mailbox(D!Connects(Main)))
    /\ \A i \in Ids :
         /\ SF_vars(\E t \in {"waiter", "typed"} : Mailbox(D!Mark(i, t)))
         /\ SF_vars(Mailbox(D!Handed(i))) /\ WF_vars(Mailbox(D!Refused(i)))
         /\ SF_vars(Takes(i)) /\ WF_vars(Mailbox(D!SettleSeen(i, Has(i))))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ level \in [Accounts -> Ok..Limit]
    /\ \A p \in procs : p.pid \in 1..nextPid /\ p.account \in Accounts
    /\ turn \in 0..nextPid
    /\ delegates \in [Delegates -> {"none", "running", "reported"}]
    /\ phase \in Phases /\ target \in Accounts /\ copied \in BOOLEAN
    /\ turned \in BOOLEAN
    /\ record.status \in {"running", "stopping", "ended"}
    /\ D!TypeOK

\* A session runs on one account at a time: never two processes of it.
OneAccountAtATime == Cardinality(procs) <= 1

\* No background command is cut off by a move.
NothingLost == lost = {}

\* The resumed session has the whole transcript of the old one, a turn the
\* SIGTERM cut included.
TranscriptKept == phase = "moved" => resumedWith = transcript[Home]

\* A late SessionEnd never ends the moved session.
LateEndNeverEndsMoved == record.status = "ended" => Live = {}

\* No new delegate or background command starts once draining began.
NoStartWhileDraining ==
    [][(phase \in {"draining", "clear", "stopping", "ending"}) =>
         (bgCount' = bgCount /\ DelegatesStarted' = DelegatesStarted)]_vars

\* Each row goes into the session once, across the move and restarts.
OnceAcrossMove == D!AtMostOnce

\* No row's turn is cut by the end: nothing goes into the old process once
\* its idle read is made, and only the process the row names takes it.
NotCutByEnd == D!NotCutByStop
OnlyToItsProcess == D!OnlyToItsProcess
OnlyIntoEndedTurn == D!OnlyIntoEndedTurn

\* A delivered row is in the transcript the session's row names: the copy,
\* after the move.
DeliveredIsKept == \A i \in Ids : row[i].st = "delivered" => Has(i)

\* A drained session moves.
DrainedParentMoves == phase = "draining" ~> phase = "moved"

\* Every row to the session is delivered, held through the move: a row due
\* at the resume goes in as its prompt, a later one by the waiter or, long as
\* it may be, the typed pointer.
RowsArrive == D!Arrives

=============================================================================
