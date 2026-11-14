------------------------------- MODULE Start -------------------------------
(***************************************************************************)
(* One host's session starts and stops, and restarts of the framework in   *)
(* between any two of their steps: the row written first, the process held *)
(* by dtach, the viewer, the session file Claude Code writes (perhaps      *)
(* late), the start confirmed or unknown at its deadline, and after a      *)
(* restart the adoption of a starting row, the settling of a stopping row  *)
(* and the reading again of an unknown one.                                *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                           *)
(*   Sessions  its table (durable) and its calls under way (in memory):    *)
(*             start, stop, adoption after a restart (built in F-17);      *)
(*   Holder    dtach -n: a socket holds one process, and refuses a second; *)
(*   Registry  the session file, matched by the session's name, and a      *)
(*             process's liveness by its pid and start time;               *)
(*   Recoveries only as the owner of an orphan row (not built).            *)
(*                                                                         *)
(* Left abstract: the viewer's own failures (Agent.tla), the worktree and  *)
(* its removal, which accounts the sessions are on, the text of the        *)
(* command line. Time is one flag per start, `past`: its deadline has      *)
(* passed. The deadline is wall-clock from the row's start, so a restart   *)
(* does not move it. A process exits at any time, by /exit or a crash.     *)
(* Other programs on the host take free pids, so a pid is reused.          *)
(* Delegate.tla's single start step stands for this whole spec.            *)
(*                                                                         *)
(* Fairness: the framework's steps happen while they stay possible, and    *)
(* time passes. Processes and other programs act or not.                   *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Start_<value>.cfg that TLC must fail.                       *)
(*                                                                         *)
(* Defense in depth, with no Break: the hold's refusal of a live socket.   *)
(* The row is written first and a new start needs an ended row, and a row *)
(* ends only once its process is gone, so a start never meets a live      *)
(* socket of its own name. RowEndsOnce rests on the same guards.           *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    S,            \* session names, each its own socket
    NPids,        \* pids on the host, 1..NPids
    MaxStarts,    \* starts of each name
    MaxRestarts,  \* restarts of the framework
    MaxForeign,   \* processes other programs start
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "DecideEarly",  \* the adoption decides before the start's deadline
    "DropOrphan",   \* a live socket with no file past the deadline ends refused, not orphan
    "SettleByPid",  \* a stopping row is settled by its pid alone, without its start time
    "KillByPid",    \* a kill targets the row's pid alone, without its start time
    "HoldFirst",    \* the process is held before its row is written
    "NoReRead"      \* an unknown row is never read again
}

ASSUME Break \in Breaks
ASSUME NPids \in Nat /\ MaxStarts \in Nat /\ MaxRestarts \in Nat /\ MaxForeign \in Nat

Pids == 1..NPids
NoProc == [pid |-> 0, start |-> 0]

VARIABLES
    up,          \* the framework runs
    restarts,    \* restarts so far
    row,         \* table: s -> "none", "starting", "running", "stopping", "stopped",
                 \*          "refused", "unknown", "orphan"
    rowProc,     \* table: s -> the pid and start time the row took from the session file
    starts,      \* table: s -> starts so far
    call,        \* in memory: s -> "none", "hold", "viewer", "wait", "stop"
    past,        \* s -> the current start's deadline has passed
    proc,        \* s -> the process its socket holds, or NoProc
    file,        \* s -> the process the session file of that name names, or NoProc
    foreign,     \* processes of other programs
    clock,       \* start times so far: each process has its own
    onTime,      \* ghost: s -> the session file came before the start's deadline
    ends,        \* ghost: s -> times the current start's row ended
    wrongKills   \* ghost: processes killed that were not the session's own

vars == <<up, restarts, row, rowProc, starts, call, past, proc, file, foreign, clock,
          onTime, ends, wrongKills>>

LiveProcs == ({proc[t] : t \in S} \ {NoProc}) \cup foreign
FreePids == Pids \ {q.pid : q \in LiveProcs}
Live(s) == proc[s] # NoProc
\* Registry's reading: the file of the session's name names its live process.
Confirms(s) == Live(s) /\ file[s] = proc[s]
\* Liveness by pid and start time (Registry.Liveness), or by pid alone.
Alive(q) == q \in LiveProcs
AliveByPid(q) == \E r \in LiveProcs : r.pid = q.pid
Ended == {"none", "stopped", "refused"}

-----------------------------------------------------------------------------
Init ==
    /\ up = TRUE /\ restarts = 0
    /\ row = [s \in S |-> "none"] /\ rowProc = [s \in S |-> NoProc]
    /\ starts = [s \in S |-> 0] /\ call = [s \in S |-> "none"]
    /\ past = [s \in S |-> FALSE] /\ proc = [s \in S |-> NoProc]
    /\ file = [s \in S |-> NoProc] /\ foreign = {} /\ clock = 0
    /\ onTime = [s \in S |-> FALSE] /\ ends = [s \in S |-> 0] /\ wrongKills = {}

\* Writes row s's status; entering an ended status counts as its end.
SetRow(s, st) ==
    /\ row' = [row EXCEPT ![s] = st]
    /\ ends' = IF st \in {"stopped", "refused"} THEN [ends EXCEPT ![s] = @ + 1] ELSE ends

-----------------------------------------------------------------------------
(* The framework: its table survives a restart; its calls do not *)

FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ call' = [s \in S |-> "none"]
    /\ UNCHANGED <<row, rowProc, starts, past, proc, file, foreign, clock, onTime, ends,
                   wrongKills>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<restarts, row, rowProc, starts, call, past, proc, file, foreign, clock,
                   onTime, ends, wrongKills>>

-----------------------------------------------------------------------------
(* The outside: processes, other programs, Claude Code's file, time *)

ProcExits(s) ==
    /\ Live(s) /\ proc' = [proc EXCEPT ![s] = NoProc]
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, call, past, file, foreign, clock,
                   onTime, ends, wrongKills>>

\* Another program starts and takes a free pid, perhaps one a session had.
ForeignStarts ==
    /\ Cardinality(foreign) < MaxForeign
    /\ \E p \in FreePids : foreign' = foreign \cup {[pid |-> p, start |-> clock + 1]}
    /\ clock' = clock + 1
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, call, past, proc, file, onTime, ends,
                   wrongKills>>

\* Claude Code writes its session file, with the session's name, perhaps late.
FileWritten(s) ==
    /\ Live(s) /\ file[s] # proc[s]
    /\ file' = [file EXCEPT ![s] = proc[s]]
    /\ onTime' = [onTime EXCEPT ![s] = ~past[s]]
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, call, past, proc, foreign, clock, ends,
                   wrongKills>>

Tick(s) ==
    /\ row[s] = "starting" /\ ~past[s] /\ past' = [past EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, call, proc, file, foreign, clock,
                   onTime, ends, wrongKills>>

-----------------------------------------------------------------------------
(* A start, in the order it runs *)

\* The row first, as starting. Under HoldFirst the row waits for the viewer.
RowWritten(s) ==
    /\ up /\ call[s] = "none" /\ row[s] \in Ended /\ starts[s] < MaxStarts
    /\ row' = IF Break = "HoldFirst" THEN row ELSE [row EXCEPT ![s] = "starting"]
    /\ rowProc' = [rowProc EXCEPT ![s] = NoProc]
    /\ starts' = [starts EXCEPT ![s] = @ + 1]
    /\ call' = [call EXCEPT ![s] = "hold"]
    /\ past' = [past EXCEPT ![s] = FALSE]
    /\ onTime' = [onTime EXCEPT ![s] = FALSE]
    /\ ends' = [ends EXCEPT ![s] = 0]
    /\ UNCHANGED <<up, restarts, proc, file, foreign, clock, wrongKills>>

\* dtach -n: the process is held; or the hold is refused, with nothing held;
\* or it answers unknown, and the start waits for the file either way.
Held(s) ==
    /\ up /\ call[s] = "hold"
    /\ \/ /\ ~Live(s) /\ FreePids # {}
          /\ \E p \in FreePids : proc' = [proc EXCEPT ![s] = [pid |-> p, start |-> clock + 1]]
          /\ clock' = clock + 1
          /\ call' = [call EXCEPT ![s] = "viewer"]
          /\ UNCHANGED <<row, ends>>
       \/ /\ ~Live(s)
          /\ call' = [call EXCEPT ![s] = "viewer"]
          /\ UNCHANGED <<row, ends, proc, clock>>
       \/ /\ SetRow(s, "refused")
          /\ call' = [call EXCEPT ![s] = "none"]
          /\ UNCHANGED <<proc, clock>>
    /\ UNCHANGED <<up, restarts, rowProc, starts, past, file, foreign, onTime, wrongKills>>

\* The viewer opens, or fails and leaves the process running (Agent.tla).
ViewerOpened(s) ==
    /\ up /\ call[s] = "viewer"
    /\ call' = [call EXCEPT ![s] = "wait"]
    /\ row' = IF Break = "HoldFirst" THEN [row EXCEPT ![s] = "starting"] ELSE row
    /\ UNCHANGED <<up, restarts, rowProc, starts, past, proc, file, foreign, clock, onTime,
                   ends, wrongKills>>

\* The call reads the Registry until its deadline: running, or unknown.
StartDecided(s) ==
    /\ up /\ call[s] = "wait" /\ row[s] = "starting"
    /\ \/ /\ Confirms(s)
          /\ SetRow(s, "running") /\ rowProc' = [rowProc EXCEPT ![s] = file[s]]
       \/ /\ ~Confirms(s) /\ past[s]
          /\ SetRow(s, "unknown") /\ UNCHANGED rowProc
    /\ call' = [call EXCEPT ![s] = "none"]
    /\ UNCHANGED <<up, restarts, starts, past, proc, file, foreign, clock, onTime, wrongKills>>

-----------------------------------------------------------------------------
(* After a restart: a starting row with no call under way *)

\* Adopted when its file names its live process; otherwise, once the start's
\* deadline has passed, an orphan row for a live socket, refused{interrupted}
\* for a dead one.
Adopt(s) ==
    /\ up /\ call[s] = "none" /\ row[s] = "starting"
    /\ \/ /\ Confirms(s)
          /\ SetRow(s, "running") /\ rowProc' = [rowProc EXCEPT ![s] = file[s]]
       \/ /\ ~Confirms(s) /\ (past[s] \/ Break = "DecideEarly")
          /\ IF Live(s) /\ Break # "DropOrphan"
               THEN SetRow(s, "orphan")
               ELSE SetRow(s, "refused")
          /\ UNCHANGED rowProc
    /\ UNCHANGED <<up, restarts, starts, call, past, proc, file, foreign, clock, onTime,
                   wrongKills>>

\* An unknown row is read again until it is running or gone.
ReRead(s) ==
    /\ up /\ call[s] = "none" /\ row[s] = "unknown" /\ Break # "NoReRead"
    /\ \/ /\ Confirms(s)
          /\ SetRow(s, "running") /\ rowProc' = [rowProc EXCEPT ![s] = file[s]]
       \/ /\ ~Live(s)
          /\ SetRow(s, "stopped") /\ UNCHANGED rowProc
    /\ UNCHANGED <<up, restarts, starts, call, past, proc, file, foreign, clock, onTime,
                   wrongKills>>

-----------------------------------------------------------------------------
(* A stop *)

\* /exit is typed (Control's checked write); the process exits when it will.
StopAsked(s) ==
    /\ up /\ call[s] = "none" /\ row[s] = "running"
    /\ row' = [row EXCEPT ![s] = "stopping"]
    /\ call' = [call EXCEPT ![s] = "stop"]
    /\ UNCHANGED <<up, restarts, rowProc, starts, past, proc, file, foreign, clock, onTime,
                   ends, wrongKills>>

\* By the row's pid and start time: stopped when gone; after a restart, with
\* no stop under way, running otherwise.
StopSettled(s) ==
    /\ up /\ row[s] = "stopping" /\ call[s] \in {"none", "stop"}
    /\ LET alive == IF Break = "SettleByPid" THEN AliveByPid(rowProc[s]) ELSE Alive(rowProc[s])
       IN \/ /\ ~alive /\ SetRow(s, "stopped")
          \/ /\ alive /\ call[s] = "none" /\ SetRow(s, "running")
    /\ call' = [call EXCEPT ![s] = "none"]
    /\ UNCHANGED <<up, restarts, rowProc, starts, past, proc, file, foreign, clock, onTime,
                   wrongKills>>

\* The stop's deadline passed with the process alive.
StopTimedOut(s) ==
    /\ up /\ row[s] = "stopping" /\ call[s] = "stop" /\ Alive(rowProc[s])
    /\ SetRow(s, "unknown")
    /\ call' = [call EXCEPT ![s] = "none"]
    /\ UNCHANGED <<up, restarts, rowProc, starts, past, proc, file, foreign, clock, onTime,
                   wrongKills>>

\* A stopping row's process is killed, by its pid and start time.
Kill(s) ==
    /\ up /\ row[s] = "stopping"
    /\ \E q \in LiveProcs :
         /\ q.pid = rowProc[s].pid
         /\ q = rowProc[s] \/ Break = "KillByPid"
         /\ proc' = [t \in S |-> IF proc[t] = q THEN NoProc ELSE proc[t]]
         /\ foreign' = foreign \ {q}
         /\ wrongKills' = IF q = proc[s] THEN wrongKills ELSE wrongKills \cup {q}
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, call, past, file, clock, onTime, ends>>

-----------------------------------------------------------------------------
Next ==
    \/ FrameworkDies \/ FrameworkStarts \/ ForeignStarts
    \/ \E s \in S :
         \/ ProcExits(s) \/ FileWritten(s) \/ Tick(s)
         \/ RowWritten(s) \/ Held(s) \/ ViewerOpened(s) \/ StartDecided(s)
         \/ Adopt(s) \/ ReRead(s)
         \/ StopAsked(s) \/ StopSettled(s) \/ StopTimedOut(s) \/ Kill(s)

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A s \in S :
         /\ WF_vars(Tick(s)) /\ WF_vars(Held(s)) /\ WF_vars(ViewerOpened(s))
         /\ WF_vars(StartDecided(s)) /\ WF_vars(Adopt(s)) /\ WF_vars(ReRead(s))
         /\ WF_vars(StopSettled(s))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ up \in BOOLEAN
    /\ row \in [S -> {"none", "starting", "running", "stopping", "stopped", "refused",
                      "unknown", "orphan"}]
    /\ call \in [S -> {"none", "hold", "viewer", "wait", "stop"}]
    /\ \A s \in S : proc[s] = NoProc \/ proc[s].pid \in Pids
    /\ \A q \in foreign : q.pid \in Pids
    \* a socket holds one process, and a pid names one live process
    /\ \A q, r \in LiveProcs : q.pid = r.pid => q = r

\* No held process is ever without a row that has not ended.
NoHeldWithoutRow == \A s \in S : Live(s) => row[s] \notin Ended

\* A row is written as running only for a live process its session file
\* names, and the row names that process.
RunningOnlyIfLive ==
    [][\A s \in S : row'[s] = "running" /\ row[s] # "running" =>
                      Confirms(s)' /\ rowProc'[s] = proc'[s]]_vars

\* A row ends at most once per start.
RowEndsOnce == \A s \in S : ends[s] <= 1

\* Nothing kills a process but by its own pid and start time.
KillsOwnOnly == wrongKills = {}

\* A start whose live process wrote its file before the deadline is never
\* given up as orphan or refused: the adoption waited for the deadline.
NotGivenUpEarly ==
    \A s \in S : row[s] \in {"orphan", "refused"} /\ Live(s) => ~onTime[s]

\* Every starting row settles.
StartingSettles == \A s \in S : row[s] = "starting" ~> row[s] # "starting"

\* An unknown row whose process is running with its file, or gone, settles.
UnknownSettles ==
    \A s \in S : row[s] = "unknown" /\ (Confirms(s) \/ ~Live(s)) ~> row[s] # "unknown"

=============================================================================
