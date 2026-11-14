------------------------------- MODULE Shell -------------------------------
(***************************************************************************)
(* One command Shell runs, the process group it runs in, and how that      *)
(* group ends.                                                             *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                           *)
(*   Shell   its wrapper: the port's sh leads a process group of its own   *)
(*           (OTP starts every port program with setsid). It starts a      *)
(*           watcher in that group, then runs the command in it. The       *)
(*           watcher blocks reading the port's stdin. At end of file it    *)
(*           sends TERM to the group, waits a grace, then sends KILL. When *)
(*           the command exits on its own, the sh kills the watcher by its *)
(*           pid (its own child, not yet reaped) and exits with the        *)
(*           command's status;                                             *)
(*   Holder  dtach -n: the held process calls setsid, so it leaves the     *)
(*           group.                                                        *)
(*                                                                         *)
(* The port's stdin closes on a timeout (Shell closes the port), when the  *)
(* port's owner dies, or when the VM dies: the three are one step here,    *)
(* PortCloses. The command starts one child in the group, which ignores    *)
(* TERM (the worst case), and may hold one process. Another program may    *)
(* take the group's id once no process has it: the pid of the sh, which    *)
(* is the group's id, is free once the sh is reaped and the group is       *)
(* empty.                                                                  *)
(*                                                                         *)
(* Left abstract: output and status (passed through unchanged), the grace's *)
(* length. The watcher reading end of file and sending TERM is one step:   *)
(* in the code they are two system calls, and if the command exits on its *)
(* own between them, the sh kills the watcher first and the group is left *)
(* as a command that exits on its own leaves it. A command that exits on  *)
(* its own leaves its children running, as before this unit.              *)
(*                                                                         *)
(* Fairness: the watcher's and the sh's steps happen while they stay       *)
(* possible. The command, its children and other programs act or not.     *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Shell_<value>.cfg that TLC must fail.                       *)
(***************************************************************************)

CONSTANTS Break

Breaks == {
    "none",
    "ProgramOnly",    \* the kill reaches the command by its pid, not its group
    "HeldStays",      \* the held process does not leave the group
    "WatchOutside"    \* the watcher is not in the group it kills
}

ASSUME Break \in Breaks

\* sh: the port's sh and the group's leader; held: what dtach holds; foreign:
\* another program's process.
Procs == {"sh", "watch", "cmd", "child", "held", "foreign"}
Ours == Procs \ {"foreign"}

VARIABLES
    alive,     \* [Procs -> BOOLEAN]
    member,    \* [Procs -> BOOLEAN]: in the group whose id is the sh's pid
    started,   \* the command's child and held process started (a set)
    stdin,     \* "open" or "closed": the port's stdin
    phase,     \* the watcher: "reading", "grace", "done", or "stopped" by the sh
    ended,     \* how the command ended: "running", "own", "signal"
    hit        \* the processes a kill reached that it must not reach

vars == <<alive, member, started, stdin, phase, ended, hit>>

TypeOK ==
    /\ alive \in [Procs -> BOOLEAN]
    /\ member \in [Procs -> BOOLEAN]
    /\ started \subseteq {"child", "held"}
    /\ stdin \in {"open", "closed"}
    /\ phase \in {"reading", "grace", "done", "stopped"}
    /\ ended \in {"running", "own", "signal"}
    /\ hit \subseteq Procs

Init ==
    /\ alive = [p \in Procs |-> p \in {"sh", "watch", "cmd"}]
    /\ member = [p \in Procs |->
                   p \in {"sh", "cmd"} \/ (p = "watch" /\ Break # "WatchOutside")]
    /\ started = {}
    /\ stdin = "open"
    /\ phase = "reading"
    /\ ended = "running"
    /\ hit = {}

\* The group exists while any process is in it.
GroupLives == \E p \in Procs : alive[p] /\ member[p]

\* Who a signal to the group reaches: every live member, ours or not. With
\* ProgramOnly, the command alone, by its pid.
Reached ==
    IF Break = "ProgramOnly"
    THEN {p \in {"cmd"} : alive[p]}
    ELSE {p \in Procs : alive[p] /\ member[p]}

Wrong(r) == r \cap {"held", "foreign"}

CmdStartsChild ==
    /\ alive["cmd"] /\ "child" \notin started
    /\ started' = started \cup {"child"}
    /\ alive' = [alive EXCEPT !["child"] = TRUE]
    /\ member' = [member EXCEPT !["child"] = TRUE]
    /\ UNCHANGED <<stdin, phase, ended, hit>>

\* dtach -n forks, and its master calls setsid: a new session and group.
CmdHolds ==
    /\ alive["cmd"] /\ "held" \notin started
    /\ started' = started \cup {"held"}
    /\ alive' = [alive EXCEPT !["held"] = TRUE]
    /\ member' = [member EXCEPT !["held"] = (Break = "HeldStays")]
    /\ UNCHANGED <<stdin, phase, ended, hit>>

CmdExits ==
    /\ alive["cmd"]
    /\ alive' = [alive EXCEPT !["cmd"] = FALSE]
    /\ ended' = "own"
    /\ UNCHANGED <<member, started, stdin, phase, hit>>

Exits(p) ==
    /\ p \in {"child", "held", "foreign"} /\ alive[p]
    /\ alive' = [alive EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<member, started, stdin, phase, ended, hit>>

\* A timeout, the owner's death or the VM's.
PortCloses ==
    /\ stdin = "open"
    /\ stdin' = "closed"
    /\ UNCHANGED <<alive, member, started, phase, ended, hit>>

\* The sh sees the command end on its own and kills the watcher by its pid.
\* The watcher is the sh's child and lives (its own KILL would have ended the
\* sh too), so the pid is not reused.
ShStandsDown ==
    /\ alive["sh"] /\ ~alive["cmd"]
    /\ alive' = [alive EXCEPT !["sh"] = FALSE, !["watch"] = FALSE]
    /\ phase' = IF phase = "reading" THEN "stopped" ELSE phase
    /\ UNCHANGED <<member, started, stdin, ended, hit>>

\* End of file: TERM to the group. The watcher ignores it; the child is
\* modeled as ignoring it too, so only the KILL ends it.
WatchTerms ==
    /\ alive["watch"] /\ phase = "reading" /\ stdin = "closed"
    /\ LET r == Reached \ {"watch", "child"}
       IN /\ alive' = [p \in Procs |-> alive[p] /\ p \notin r]
          /\ ended' = IF "cmd" \in r THEN "signal" ELSE ended
          /\ hit' = hit \cup Wrong(r)
    /\ phase' = "grace"
    /\ UNCHANGED <<member, started, stdin>>

\* After the grace: KILL to the group, which ends the watcher too when it is
\* a member.
WatchKills ==
    /\ alive["watch"] /\ phase = "grace"
    /\ LET r == Reached \cup {"watch"}
       IN /\ alive' = [p \in Procs |-> alive[p] /\ p \notin r]
          /\ hit' = hit \cup Wrong(r)
          /\ ended' = IF "cmd" \in r /\ ended = "running" THEN "signal" ELSE ended
    /\ phase' = "done"
    /\ UNCHANGED <<member, started, stdin>>

\* Another program takes the group's id: only once the sh is gone (reaped at
\* once) and no process is in the group.
ForeignTakesId ==
    /\ ~alive["sh"] /\ ~GroupLives /\ ~alive["foreign"]
    /\ alive' = [alive EXCEPT !["foreign"] = TRUE]
    /\ member' = [member EXCEPT !["foreign"] = TRUE]
    /\ UNCHANGED <<started, stdin, phase, ended, hit>>

Next ==
    \/ CmdStartsChild \/ CmdHolds \/ CmdExits
    \/ \E p \in Procs : Exits(p)
    \/ PortCloses \/ ShStandsDown \/ WatchTerms \/ WatchKills
    \/ ForeignTakesId

Fairness == WF_vars(ShStandsDown) /\ WF_vars(WatchTerms) /\ WF_vars(WatchKills)

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
\* Once the watcher is done, no process of ours is left in the group.
GroupEnded == phase = "done" => \A p \in Ours : ~(alive[p] /\ member[p])

\* A kill never reaches a held process or another program's.
KillsOwnOnly == hit = {}

\* The sh stands the watcher down only after the command exited on its own.
StoodDownOnlyAfterOwnExit == phase = "stopped" => ended = "own"

\* Once the port closes, the watcher finishes or was stood down, and the
\* command does not run.
CloseEnds == stdin = "closed" ~> (phase \in {"done", "stopped"} /\ ~alive["cmd"])
=============================================================================
