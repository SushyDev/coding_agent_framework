------------------------------- MODULE Shell -------------------------------
(***************************************************************************)
(* One command Shell runs, the process group it leads, and the three ways *)
(* that group is ended: a timeout, its owner's death and the VM's death.   *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                           *)
(*   Shell         runs the program directly. OTP starts every port        *)
(*                 program with setsid, so the command leads a group whose *)
(*                 id is its pid. On a timeout it sends TERM to the group, *)
(*                 waits a grace for the command's exit, and sends KILL to *)
(*                 the group only if the exit did not come. When it takes  *)
(*                 the command's exit it drops the group from its reaper;  *)
(*   Shell.Reaper  one per host, given to Shell.run or not. It holds each  *)
(*                 running command's group with its owner, monitors the    *)
(*                 owner, and when the owner dies first it sends TERM to   *)
(*                 the group, then KILL after the grace. It keeps one sh   *)
(*                 watcher for the VM, fed each group it holds and each it *)
(*                 drops; at end of its stdin (the VM died) the watcher    *)
(*                 sends TERM to every group it still holds, waits the     *)
(*                 grace, and sends KILL;                                  *)
(*   Holder        dtach -n: the held process calls setsid, so it leaves   *)
(*                 the group.                                              *)
(*                                                                         *)
(* The command may start one child in its group and may hold one process.  *)
(* Which of the command and its child ignore TERM is chosen at the start:  *)
(* every case is checked. Another program may take the group's id once     *)
(* the id is free: the command is gone, the group is empty, and the        *)
(* framework knows the command ended (known).                              *)
(*                                                                         *)
(* known is the one assumption about time. In the code the command is      *)
(* reaped by OTP a moment before Shell takes its exit status, and the      *)
(* reaper's KILL comes a grace after its TERM. A freed pid is not handed   *)
(* out again within that time: macOS and Linux hand out pids in order and *)
(* come back to one only after tens of thousands of forks. So the model    *)
(* frees the id only once the part that kills by it has heard of the end  *)
(* (Shell took the exit) or finished its kill (the reaper or the watcher). *)
(*                                                                         *)
(* Left abstract: output and status (passed through unchanged), the       *)
(* grace's length, and messages. Shell.run registers the group with the   *)
(* reaper as it starts the command, in one step; the reaper writes each    *)
(* change to the watcher as it makes it, and the watcher reads all that    *)
(* was written before its stdin closed, so the reaper and the watcher     *)
(* hold the same groups: one variable, held. A command that exits on its  *)
(* own leaves its children running, as before F-35; so does one that a    *)
(* timeout's TERM ends within the grace, as Shell then sends no KILL.      *)
(*                                                                         *)
(* Fairness: Shell's, the reaper's and the watcher's steps happen while    *)
(* they stay possible. The command, its children, the owner, the VM and    *)
(* other programs act or not.                                              *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Shell_<value>.cfg that TLC must fail.                       *)
(***************************************************************************)

CONSTANTS Break

Breaks == {
    "none",
    "ProgramOnly",    \* a kill reaches the command by its pid, not its group
    "HeldStays",      \* the held process does not leave the group
    "KillAfterEnd",   \* Shell does not drop the group when the command ends
    "NoReaper"        \* Shell.run is given no reaper
}

ASSUME Break \in Breaks

\* held: what dtach holds; foreign: another program's process.
Procs == {"cmd", "child", "held", "foreign"}
Ours == Procs \ {"foreign"}

VARIABLES
    alive,     \* [Procs -> BOOLEAN]
    member,    \* [Procs -> BOOLEAN]: in the group whose id is the command's pid
    started,   \* the command's child and held process started (a set)
    ignores,   \* the processes that ignore TERM
    owner,     \* Shell.run in the owner: "waiting", "grace" (TERM sent), "done", "dead"
    held,      \* the reaper and its watcher hold the group
    reaper,    \* for this group: "watching", "grace" (TERM sent), "off"
    vm,        \* "up" or "dead"
    watcher,   \* "reading", "grace" (TERM sent), "done"
    known,     \* the framework knows the command ended: its id may be freed
    killed,    \* a KILL was sent to the group (a ghost)
    hit        \* the processes a kill reached that it must not reach (a ghost)

vars == <<alive, member, started, ignores, owner, held, reaper, vm, watcher, known,
          killed, hit>>

TypeOK ==
    /\ alive \in [Procs -> BOOLEAN]
    /\ member \in [Procs -> BOOLEAN]
    /\ started \subseteq {"child", "held"}
    /\ ignores \subseteq {"cmd", "child"}
    /\ owner \in {"waiting", "grace", "done", "dead"}
    /\ held \in BOOLEAN
    /\ reaper \in {"watching", "grace", "off"}
    /\ vm \in {"up", "dead"}
    /\ watcher \in {"reading", "grace", "done"}
    /\ known \in BOOLEAN
    /\ killed \in BOOLEAN
    /\ hit \subseteq Procs

Init ==
    /\ alive = [p \in Procs |-> p = "cmd"]
    /\ member = [p \in Procs |-> p = "cmd"]
    /\ started = {}
    /\ ignores \in SUBSET {"cmd", "child"}
    /\ owner = "waiting"
    /\ held = (Break # "NoReaper")
    /\ reaper = "watching"
    /\ vm = "up"
    /\ watcher = "reading"
    /\ known = FALSE
    /\ killed = FALSE
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

\* TERM and KILL to the group, as one step each.
Term ==
    LET r == Reached \ ignores
    IN /\ alive' = [p \in Procs |-> alive[p] /\ p \notin r]
       /\ hit' = hit \cup Wrong(r)

Kill ==
    /\ alive' = [p \in Procs |-> alive[p] /\ p \notin Reached]
    /\ hit' = hit \cup Wrong(Reached)
    /\ killed' = TRUE

CmdStartsChild ==
    /\ alive["cmd"] /\ "child" \notin started
    /\ started' = started \cup {"child"}
    /\ alive' = [alive EXCEPT !["child"] = TRUE]
    /\ member' = [member EXCEPT !["child"] = TRUE]
    /\ UNCHANGED <<ignores, owner, held, reaper, vm, watcher, known, killed, hit>>

\* dtach -n forks, and its master calls setsid: a new session and group.
CmdHolds ==
    /\ alive["cmd"] /\ "held" \notin started
    /\ started' = started \cup {"held"}
    /\ alive' = [alive EXCEPT !["held"] = TRUE]
    /\ member' = [member EXCEPT !["held"] = (Break = "HeldStays")]
    /\ UNCHANGED <<ignores, owner, held, reaper, vm, watcher, known, killed, hit>>

Exits(p) ==
    /\ alive[p]
    /\ alive' = [alive EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<member, started, ignores, owner, held, reaper, vm, watcher, known,
                   killed, hit>>

\* Shell takes the command's exit status and drops the group from its reaper,
\* in the wait or in a timeout's grace. No KILL follows.
ShellTakesExit ==
    /\ owner \in {"waiting", "grace"} /\ ~alive["cmd"]
    /\ owner' = "done"
    /\ known' = TRUE
    /\ held' = IF Break = "KillAfterEnd" THEN held ELSE FALSE
    /\ UNCHANGED <<alive, member, started, ignores, reaper, vm, watcher, killed, hit>>

\* The timeout passed: TERM to the group, then the grace.
ShellTimesOut ==
    /\ owner = "waiting"
    /\ Term
    /\ owner' = "grace"
    /\ UNCHANGED <<member, started, ignores, held, reaper, vm, watcher, known, killed>>

\* The grace passed with no exit taken: KILL to the group, then Shell closes
\* the port, drops the group and answers the timeout.
ShellKills ==
    /\ owner = "grace"
    /\ Kill
    /\ owner' = "done"
    /\ known' = TRUE
    /\ held' = IF Break = "KillAfterEnd" THEN held ELSE FALSE
    /\ UNCHANGED <<member, started, ignores, reaper, vm, watcher>>

\* The owner dies, in Shell.run or after it. Its port closes; the command
\* runs on.
OwnerDies ==
    /\ owner # "dead" /\ vm = "up"
    /\ owner' = "dead"
    /\ UNCHANGED <<alive, member, started, ignores, held, reaper, vm, watcher, known,
                   killed, hit>>

\* The reaper sees the owner's death while it holds the group.
ReaperTerms ==
    /\ vm = "up" /\ owner = "dead" /\ held /\ reaper = "watching"
    /\ Term
    /\ reaper' = "grace"
    /\ UNCHANGED <<member, started, ignores, owner, held, vm, watcher, known, killed>>

\* After the grace: KILL to the group, then the reaper drops it.
ReaperKills ==
    /\ vm = "up" /\ reaper = "grace"
    /\ Kill
    /\ reaper' = "off"
    /\ held' = FALSE
    /\ known' = TRUE
    /\ UNCHANGED <<member, started, ignores, owner, vm, watcher>>

\* The VM dies, the owner and the reaper with it, and the watcher's stdin
\* closes.
VmDies ==
    /\ vm = "up"
    /\ vm' = "dead"
    /\ owner' = "dead"
    /\ UNCHANGED <<alive, member, started, ignores, held, reaper, watcher, known, killed,
                   hit>>

WatcherTerms ==
    /\ vm = "dead" /\ watcher = "reading"
    /\ IF held THEN Term ELSE UNCHANGED <<alive, hit>>
    /\ watcher' = "grace"
    /\ UNCHANGED <<member, started, ignores, owner, held, reaper, vm, known, killed>>

WatcherKills ==
    /\ watcher = "grace"
    /\ IF held THEN Kill /\ known' = TRUE ELSE UNCHANGED <<alive, hit, killed, known>>
    /\ watcher' = "done"
    /\ UNCHANGED <<member, started, ignores, owner, held, reaper, vm>>

\* Another program takes the group's id, once it is free.
ForeignTakesId ==
    /\ ~alive["cmd"] /\ ~GroupLives /\ known /\ ~alive["foreign"] /\ ~member["foreign"]
    /\ alive' = [alive EXCEPT !["foreign"] = TRUE]
    /\ member' = [member EXCEPT !["foreign"] = TRUE]
    /\ UNCHANGED <<started, ignores, owner, held, reaper, vm, watcher, known, killed, hit>>

Next ==
    \/ CmdStartsChild \/ CmdHolds
    \/ \E p \in Procs : Exits(p)
    \/ ShellTakesExit \/ ShellTimesOut \/ ShellKills
    \/ OwnerDies \/ ReaperTerms \/ ReaperKills
    \/ VmDies \/ WatcherTerms \/ WatcherKills
    \/ ForeignTakesId

Fairness ==
    /\ WF_vars(ShellTakesExit) /\ WF_vars(ShellKills)
    /\ WF_vars(ReaperTerms) /\ WF_vars(ReaperKills)
    /\ WF_vars(WatcherTerms) /\ WF_vars(WatcherKills)

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
\* Once a KILL went to the group, no process of ours is left in it.
GroupEnded == killed => \A p \in Ours : ~(alive[p] /\ member[p])

\* A kill never reaches a held process or another program's.
KillsOwnOnly == hit = {}

\* Shell answers a command it timed out.
TimeoutAnswers == owner = "grace" ~> owner \in {"done", "dead"}

\* A timeout, the owner's death and the VM's death each end the command.
Ends == (owner \in {"grace", "dead"}) ~> ~alive["cmd"]
=============================================================================
