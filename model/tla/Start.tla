------------------------------- MODULE Start -------------------------------
(***************************************************************************)
(* One host's session starts and stops, and restarts of the framework in   *)
(* between any two of their steps: the row written first, the worktree     *)
(* checked or added and its setup run, the process held by dtach, the      *)
(* viewer, the session file Claude Code writes (perhaps late), the start   *)
(* confirmed or unknown at its deadline, and after a restart the adoption  *)
(* of a starting row (with the removal of its worktree), the settling of a *)
(* stopping row and the reading again of an unknown one.                   *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                           *)
(*   Sessions  its table (durable) and its calls under way (in memory):    *)
(*             start, stop, adoption after a restart (built in F-17), and  *)
(*             a start's worktree and setup (F-55);                        *)
(*   Sessions.Worktree the checks of a worktree at a start's path: absent, *)
(*             a worktree on the start's branch, clean or not, or taken;   *)
(*   git       `worktree list` and `status` (the checks), `worktree add`,  *)
(*             with `-b` when the branch does not exist, which at a taken  *)
(*             path fails and still leaves the new branch behind, and      *)
(*             `worktree remove`;                                          *)
(*   Shell.Reaper the setup's process group, which ends with the caller,   *)
(*             so a restart of the framework ends a setup under way;       *)
(*   Holder    dtach -n: a socket holds one process, and refuses a second; *)
(*   Registry  the session file, matched by the session's name, and a      *)
(*             process's liveness by its pid and start time;               *)
(*   Recoveries only as the owner of an orphan row and of a stop past its  *)
(*             deadline, which it kills by pid and start time (not built). *)
(*                                                                         *)
(* Worktrees: with `Worktrees` FALSE a session runs in the directory it is *)
(* given, and the worktree steps are off; the configurations of F-17 and   *)
(* F-25 check that. With it TRUE every start checks the path of its        *)
(* worktree, adds it when absent and runs the project's setup in it, and   *)
(* each start of a name may be a resume, which takes the worktree dirty    *)
(* (the work of the killed delegate) and refuses an absent one. A path is  *)
(* "none" (free), "tree" (a worktree of the project on the start's         *)
(* branch) or "other" (a directory, or a worktree on another branch).      *)
(* `Shared` puts every session on one path: another agent that runs in the *)
(* same directory. A person or a program may take a free path, and anyone  *)
(* may change files in a tree (`MaxOutside` such events); a cut add, which *)
(* leaves a half checkout, is such a dirty tree. `ready` says the last     *)
(* setup run in a tree finished: a setup that fails, passes its deadline   *)
(* or is cut leaves it FALSE, so every start runs the setup again.         *)
(* In git's terms (design, "The worktree"): the path is                    *)
(* <home>/worktrees/<project>/<name>; "tree" is the path listed by `git    *)
(* worktree list --porcelain` with the start's branch, never the branch's  *)
(* existence; `dirty` is `git status --porcelain --untracked-files=all`    *)
(* listing a file, so ignored build state does not count; a path is held   *)
(* by a row that has not ended whose cwd it is.                            *)
(*                                                                         *)
(* Left abstract: the viewer's own failures (Agent.tla), which accounts    *)
(* the sessions are on, the text of the command line, the worktree's path  *)
(* and the project's data, and the setup's commands, which are one step    *)
(* that finishes or fails. Time is one flag per start, `past`: its         *)
(* deadline has passed. The deadline is wall-clock from the row's start,   *)
(* so a restart does not move it. A process exits at any time, by /exit or *)
(* a crash. Other programs on the host take free pids, so a pid is reused. *)
(* Delegate.tla's single start step stands for this whole spec.            *)
(*                                                                         *)
(* Fairness: the framework's steps happen while they stay possible, and    *)
(* time passes. Processes, other programs and people act or not.           *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Start_<value>.cfg that TLC must fail.                       *)
(*                                                                         *)
(* Defense in depth, with no Break: the hold's refusal of a live socket.   *)
(* The row is written first and a new start needs an ended row, and a row *)
(* ends only once its process is gone, so a start never meets a live      *)
(* socket of its own name. RowEndsOnce rests on the same guards. The       *)
(* removal's check that no other row holds the path, behind the check     *)
(* RowWritten makes: a row holds its path from its write until it ends.    *)
(* In the code, git's own refusal to remove a dirty worktree (no --force)  *)
(* is defense in depth behind the clean check of Adopt.                    *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    S,            \* session names, each its own socket
    NPids,        \* pids on the host, 1..NPids
    MaxStarts,    \* starts of each name
    MaxRestarts,  \* restarts of the framework
    MaxForeign,   \* processes other programs start
    Worktrees,    \* starts add or reuse a worktree and run the setup in it
    Shared,       \* every session's worktree is at one path
    Before,       \* what a path may hold at first: a subset of {"none", "tree", "other"}
    MaxOutside,   \* paths taken and trees changed by people and other programs
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "DecideEarly",      \* the adoption decides before the start's deadline
    "DropOrphan",       \* a live socket with no file past the deadline ends refused, not orphan
    "SettleByPid",      \* a stopping row is settled by its pid alone, without its start time
    "KillByPid",        \* a kill targets the row's pid alone, without its start time
    "HoldFirst",        \* the process is held before its row is written
    "NoReRead",         \* an unknown row is never read again
    "NoHeldCheck",      \* a start takes a path another row that has not ended holds
    "ReuseDirty",       \* a start reuses a worktree with changes in it
    "ReuseOther",       \* a start reuses a path that is not a worktree on its branch
    "ReuseSkipsSetup",  \* a start that reuses a worktree does not run the setup
    "BranchAsWorktree", \* a failed add is taken as done because its branch exists
    "RemoveDirty",      \* the removal after a restart does not check that the tree is clean
    "RemoveOrphan",     \* the removal also takes an orphan's worktree
    "SetupOutlives"     \* the setup runs without the reaper, so a restart leaves it running
}

ASSUME Break \in Breaks
ASSUME NPids \in Nat /\ MaxStarts \in Nat /\ MaxRestarts \in Nat /\ MaxForeign \in Nat
ASSUME Worktrees \in BOOLEAN /\ Shared \in BOOLEAN /\ MaxOutside \in Nat
ASSUME Before \subseteq {"none", "tree", "other"} /\ Before # {}

Pids == 1..NPids
NoProc == [pid |-> 0, start |-> 0]
\* Each session's worktree path, named by a session; Shared puts all on one.
PathOf(s) == IF Shared THEN CHOOSE t \in S : TRUE ELSE s
Paths == {PathOf(s) : s \in S}

VARIABLES
    up,          \* the framework runs
    restarts,    \* restarts so far
    row,         \* table: s -> "none", "starting", "running", "stopping", "stopped",
                 \*          "refused", "unknown", "orphan"
    rowProc,     \* table: s -> the pid and start time the row took from the session file
    starts,      \* table: s -> starts so far
    resume,      \* table: s -> the current start is a resume
    call,        \* in memory: s -> "none", "check", "add", "setup", "setting", "hold",
                 \*              "viewer", "wait", "stop"
    past,        \* s -> the current start's deadline has passed
    proc,        \* s -> the process its socket holds, or NoProc
    file,        \* s -> the process the session file of that name names, or NoProc
    foreign,     \* processes of other programs
    clock,       \* start times so far: each process has its own
    late,        \* table: s -> the stop's deadline passed with its process alive
    wt,          \* disk: p -> "none", "tree" or "other"
    dirty,       \* disk: p -> the tree has changes (`git status` lists files)
    ready,       \* disk: p -> the last setup run in the tree finished
    branch,      \* git: p -> the branch of p's starts exists
    setupRuns,   \* p -> a setup's processes run in p
    outside,     \* paths taken and trees changed so far
    onTime,      \* ghost: s -> the session file came before the start's deadline
    ends,        \* ghost: s -> times the current start's row ended
    wrongKills,  \* ghost: processes killed that were not the session's own
    touched,     \* ghost: a tree was reused, set up or removed while busy
    offTree,     \* ghost: a setup or a process ran in a path that is not a tree
    removedDirty, \* ghost: a tree with changes was removed
    reusedDirty  \* ghost: a new start (not a resume) reused a tree with changes

trees == <<wt, dirty, ready, branch, setupRuns, outside>>
treeGhosts == <<touched, offTree, removedDirty, reusedDirty>>
vars == <<up, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign, clock,
          late, onTime, ends, wrongKills, trees, treeGhosts>>

LiveProcs == ({proc[t] : t \in S} \ {NoProc}) \cup foreign
FreePids == Pids \ {q.pid : q \in LiveProcs}
Live(s) == proc[s] # NoProc
\* Registry's reading: the file of the session's name names its live process.
Confirms(s) == Live(s) /\ file[s] = proc[s]
\* Liveness by pid and start time (Registry.Liveness), or by pid alone.
Alive(q) == q \in LiveProcs
AliveByPid(q) == \E r \in LiveProcs : r.pid = q.pid
Ended == {"none", "stopped", "refused"}
\* Another session's row that has not ended holds the same path.
HeldByOther(s) == \E t \in S \ {s} : PathOf(t) = PathOf(s) /\ row[t] \notin Ended
\* A process or a setup runs in path p.
Busy(p) == (\E t \in S : PathOf(t) = p /\ Live(t)) \/ setupRuns[p]

-----------------------------------------------------------------------------
Init ==
    /\ up = TRUE /\ restarts = 0
    /\ row = [s \in S |-> "none"] /\ rowProc = [s \in S |-> NoProc]
    /\ starts = [s \in S |-> 0] /\ resume = [s \in S |-> FALSE] /\ call = [s \in S |-> "none"]
    /\ past = [s \in S |-> FALSE] /\ proc = [s \in S |-> NoProc]
    /\ file = [s \in S |-> NoProc] /\ foreign = {} /\ clock = 0 /\ late = [s \in S |-> FALSE]
    /\ onTime = [s \in S |-> FALSE] /\ ends = [s \in S |-> 0] /\ wrongKills = {}
    /\ wt \in [Paths -> Before]
    /\ dirty \in [Paths -> BOOLEAN] /\ ready \in [Paths -> BOOLEAN]
    /\ branch \in [Paths -> BOOLEAN]
    /\ \A p \in Paths :
         /\ wt[p] # "tree" => ~dirty[p] /\ ~ready[p]
         /\ wt[p] = "tree" => branch[p]
         /\ ~Worktrees => ~branch[p]
    /\ setupRuns = [p \in Paths |-> FALSE] /\ outside = 0
    /\ touched = FALSE /\ offTree = FALSE /\ removedDirty = FALSE /\ reusedDirty = FALSE

\* Writes row s's status; entering an ended status counts as its end.
SetRow(s, st) ==
    /\ row' = [row EXCEPT ![s] = st]
    /\ ends' = IF st \in {"stopped", "refused"} THEN [ends EXCEPT ![s] = @ + 1] ELSE ends

\* The worktree at s's path is removed, after a restart, when it is a tree
\* on s's branch, clean, and no other row holds it; the branch stays.
Remove(s) ==
    LET p == PathOf(s) IN
    IF /\ Worktrees /\ wt[p] = "tree"
       /\ (~dirty[p] \/ Break = "RemoveDirty")
       /\ ~HeldByOther(s)
      THEN /\ wt' = [wt EXCEPT ![p] = "none"]
           /\ dirty' = [dirty EXCEPT ![p] = FALSE] /\ ready' = [ready EXCEPT ![p] = FALSE]
           /\ removedDirty' = (removedDirty \/ dirty[p])
           /\ touched' = (touched \/ Busy(p))
           /\ UNCHANGED <<branch, setupRuns, outside, offTree, reusedDirty>>
      ELSE UNCHANGED <<trees, treeGhosts>>

-----------------------------------------------------------------------------
(* The framework: its table survives a restart; its calls do not, and the  *)
(* reaper ends a setup under way with them                                 *)

FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ call' = [s \in S |-> "none"]
    /\ setupRuns' = IF Break = "SetupOutlives" THEN setupRuns ELSE [p \in Paths |-> FALSE]
    /\ UNCHANGED <<late, row, rowProc, starts, resume, past, proc, file, foreign, clock, onTime,
                   ends, wrongKills, wt, dirty, ready, branch, outside, treeGhosts>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<late, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, onTime, ends, wrongKills, trees, treeGhosts>>

-----------------------------------------------------------------------------
(* The outside: processes, other programs, people, Claude Code's file, time *)

ProcExits(s) ==
    /\ Live(s) /\ proc' = [proc EXCEPT ![s] = NoProc]
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, file, foreign,
                   clock, onTime, ends, wrongKills, trees, treeGhosts>>

\* Another program starts and takes a free pid, perhaps one a session had.
ForeignStarts ==
    /\ Cardinality(foreign) < MaxForeign
    /\ \E p \in FreePids : foreign' = foreign \cup {[pid |-> p, start |-> clock + 1]}
    /\ clock' = clock + 1
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, proc, file,
                   onTime, ends, wrongKills, trees, treeGhosts>>

\* Claude Code writes its session file, with the session's name, perhaps late.
FileWritten(s) ==
    /\ Live(s) /\ file[s] # proc[s]
    /\ file' = [file EXCEPT ![s] = proc[s]]
    /\ onTime' = [onTime EXCEPT ![s] = ~past[s]]
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, proc, foreign,
                   clock, ends, wrongKills, trees, treeGhosts>>

Tick(s) ==
    /\ row[s] = "starting" /\ ~past[s] /\ past' = [past EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, proc, file, foreign,
                   clock, onTime, ends, wrongKills, trees, treeGhosts>>

\* A person or a program makes a directory at a free path.
PathTaken(p) ==
    /\ outside < MaxOutside /\ wt[p] = "none"
    /\ wt' = [wt EXCEPT ![p] = "other"] /\ outside' = outside + 1
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, late, onTime, ends, wrongKills, dirty, ready, branch, setupRuns,
                   treeGhosts>>

\* Someone changes files in a tree: its agent, a person, or an add cut midway.
TreeChanged(p) ==
    /\ outside < MaxOutside /\ wt[p] = "tree" /\ ~dirty[p]
    /\ dirty' = [dirty EXCEPT ![p] = TRUE] /\ outside' = outside + 1
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, late, onTime, ends, wrongKills, wt, ready, branch, setupRuns,
                   treeGhosts>>

\* A setup a restart left running (SetupOutlives only) ends by itself.
LeftSetupEnds(p) ==
    /\ setupRuns[p] /\ \A s \in S : PathOf(s) = p => call[s] # "setting"
    /\ setupRuns' = [setupRuns EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, late, onTime, ends, wrongKills, wt, dirty, ready, branch, outside,
                   treeGhosts>>

-----------------------------------------------------------------------------
(* A start, in the order it runs *)

\* The row first, as starting, with its path; a worktree start first checks
\* that no other row that has not ended holds the path. A later start of a
\* name may be a resume. Under HoldFirst the row waits for the viewer.
RowWritten(s) ==
    /\ up /\ call[s] = "none" /\ row[s] \in Ended /\ starts[s] < MaxStarts
    /\ Worktrees => (~HeldByOther(s) \/ Break = "NoHeldCheck")
    /\ row' = IF Break = "HoldFirst" THEN row ELSE [row EXCEPT ![s] = "starting"]
    /\ rowProc' = [rowProc EXCEPT ![s] = NoProc]
    /\ starts' = [starts EXCEPT ![s] = @ + 1]
    /\ \E r \in IF Worktrees /\ starts[s] > 0 THEN BOOLEAN ELSE {FALSE} :
         resume' = [resume EXCEPT ![s] = r]
    /\ call' = [call EXCEPT ![s] = IF Worktrees THEN "check" ELSE "hold"]
    /\ past' = [past EXCEPT ![s] = FALSE]
    /\ onTime' = [onTime EXCEPT ![s] = FALSE]
    /\ ends' = [ends EXCEPT ![s] = 0]
    /\ UNCHANGED <<late, up, restarts, proc, file, foreign, clock, wrongKills, trees, treeGhosts>>

\* The checks of the path (git worktree list, git status): absent, so it is
\* added; a tree on the branch, reused when clean or for a resume; anything
\* else refused. A resume needs its tree.
Checked(s) ==
    /\ up /\ call[s] = "check"
    /\ LET p == PathOf(s)
           reuse == /\ \/ wt[p] = "tree"
                       \/ wt[p] = "other" /\ Break = "ReuseOther"
                    /\ ~dirty[p] \/ resume[s] \/ Break = "ReuseDirty"
       IN \/ /\ wt[p] = "none" /\ ~resume[s]
             /\ call' = [call EXCEPT ![s] = "add"]
             /\ UNCHANGED <<row, ends, treeGhosts>>
          \/ /\ reuse
             /\ call' = [call EXCEPT ![s] = IF Break = "ReuseSkipsSetup" THEN "hold" ELSE "setup"]
             /\ touched' = (touched \/ Busy(p))
             /\ reusedDirty' = (reusedDirty \/ (dirty[p] /\ ~resume[s]))
             /\ UNCHANGED <<row, ends, offTree, removedDirty>>
          \/ /\ ~reuse /\ (wt[p] # "none" \/ resume[s])
             /\ SetRow(s, "refused") /\ call' = [call EXCEPT ![s] = "none"]
             /\ UNCHANGED treeGhosts
    /\ UNCHANGED <<late, up, restarts, rowProc, starts, resume, past, proc, file, foreign, clock,
                   onTime, wrongKills, trees>>

\* git worktree add: with -b when the branch does not exist. At a path taken
\* since the check it fails, and a -b leaves its new branch behind.
Added(s) ==
    /\ up /\ call[s] = "add"
    /\ LET p == PathOf(s) IN
       \/ /\ wt[p] = "none"
          /\ wt' = [wt EXCEPT ![p] = "tree"] /\ branch' = [branch EXCEPT ![p] = TRUE]
          /\ call' = [call EXCEPT ![s] = "setup"]
          /\ UNCHANGED <<row, ends>>
       \/ /\ wt[p] # "none"
          /\ branch' = [branch EXCEPT ![p] = TRUE] /\ UNCHANGED wt
          \* The design reads the worktree list, never the branch, for what the add did.
          /\ IF Break = "BranchAsWorktree" /\ branch'[p]
               THEN call' = [call EXCEPT ![s] = "setup"] /\ UNCHANGED <<row, ends>>
               ELSE SetRow(s, "refused") /\ call' = [call EXCEPT ![s] = "none"]
    /\ UNCHANGED <<late, up, restarts, rowProc, starts, resume, past, proc, file, foreign, clock,
                   onTime, wrongKills, dirty, ready, setupRuns, outside, treeGhosts>>

\* The project's setup starts in the path; what it builds is not ready yet.
SetupStarts(s) ==
    /\ up /\ call[s] = "setup"
    /\ LET p == PathOf(s) IN
       /\ setupRuns' = [setupRuns EXCEPT ![p] = TRUE]
       /\ ready' = [ready EXCEPT ![p] = FALSE]
       /\ touched' = (touched \/ Busy(p))
       /\ offTree' = (offTree \/ wt[p] # "tree")
    /\ call' = [call EXCEPT ![s] = "setting"]
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, past, proc, file, foreign,
                   clock, onTime, ends, wrongKills, wt, dirty, branch, outside, removedDirty,
                   reusedDirty>>

\* The setup finishes, and the start goes on to the hold; or it fails or
\* passes its deadline, and the start is refused, the tree left as it is.
SetupEnds(s) ==
    /\ up /\ call[s] = "setting"
    /\ LET p == PathOf(s) IN
       /\ setupRuns' = [setupRuns EXCEPT ![p] = FALSE]
       /\ \/ /\ ready' = [ready EXCEPT ![p] = TRUE]
             /\ call' = [call EXCEPT ![s] = "hold"]
             /\ UNCHANGED <<row, ends>>
          \/ /\ SetRow(s, "refused") /\ call' = [call EXCEPT ![s] = "none"]
             /\ UNCHANGED ready
    /\ UNCHANGED <<late, up, restarts, rowProc, starts, resume, past, proc, file, foreign, clock,
                   onTime, wrongKills, wt, dirty, branch, outside, treeGhosts>>

\* dtach -n: the process is held; or the hold is refused, with nothing held;
\* or it answers unknown, and the start waits for the file either way.
Held(s) ==
    /\ up /\ call[s] = "hold"
    /\ \/ /\ ~Live(s) /\ FreePids # {}
          /\ \E p \in FreePids : proc' = [proc EXCEPT ![s] = [pid |-> p, start |-> clock + 1]]
          /\ clock' = clock + 1
          /\ call' = [call EXCEPT ![s] = "viewer"]
          /\ offTree' = (offTree \/ (Worktrees /\ wt[PathOf(s)] # "tree"))
          /\ UNCHANGED <<row, ends>>
       \/ /\ ~Live(s)
          /\ call' = [call EXCEPT ![s] = "viewer"]
          /\ UNCHANGED <<row, ends, proc, clock, offTree>>
       \/ /\ SetRow(s, "refused")
          /\ call' = [call EXCEPT ![s] = "none"]
          /\ UNCHANGED <<proc, clock, offTree>>
    /\ UNCHANGED <<late, up, restarts, rowProc, starts, resume, past, file, foreign, onTime,
                   wrongKills, trees, touched, removedDirty, reusedDirty>>

\* The viewer opens, or fails and leaves the process running (Agent.tla).
ViewerOpened(s) ==
    /\ up /\ call[s] = "viewer"
    /\ call' = [call EXCEPT ![s] = "wait"]
    /\ row' = IF Break = "HoldFirst" THEN [row EXCEPT ![s] = "starting"] ELSE row
    /\ UNCHANGED <<late, up, restarts, rowProc, starts, resume, past, proc, file, foreign, clock,
                   onTime, ends, wrongKills, trees, treeGhosts>>

\* The call reads the Registry until its deadline: running, or unknown.
StartDecided(s) ==
    /\ up /\ call[s] = "wait" /\ row[s] = "starting"
    /\ \/ /\ Confirms(s)
          /\ SetRow(s, "running") /\ rowProc' = [rowProc EXCEPT ![s] = file[s]]
       \/ /\ ~Confirms(s) /\ past[s]
          /\ SetRow(s, "unknown") /\ UNCHANGED rowProc
    /\ call' = [call EXCEPT ![s] = "none"]
    /\ UNCHANGED <<late, up, restarts, starts, resume, past, proc, file, foreign, clock, onTime,
                   wrongKills, trees, treeGhosts>>

-----------------------------------------------------------------------------
(* After a restart: a starting row with no call under way *)

\* Adopted when its file names its live process; otherwise, once the start's
\* deadline has passed, an orphan row for a live socket, refused{interrupted}
\* for a dead one, whose worktree is removed when clean and held by no one.
Adopt(s) ==
    /\ up /\ call[s] = "none" /\ row[s] = "starting"
    /\ \/ /\ Confirms(s)
          /\ SetRow(s, "running") /\ rowProc' = [rowProc EXCEPT ![s] = file[s]]
          /\ UNCHANGED <<trees, treeGhosts>>
       \/ /\ ~Confirms(s) /\ (past[s] \/ Break = "DecideEarly")
          /\ IF Live(s) /\ Break # "DropOrphan"
               THEN /\ SetRow(s, "orphan")
                    /\ IF Break = "RemoveOrphan" THEN Remove(s)
                       ELSE UNCHANGED <<trees, treeGhosts>>
               ELSE SetRow(s, "refused") /\ Remove(s)
          /\ UNCHANGED rowProc
    /\ UNCHANGED <<late, up, restarts, starts, resume, call, past, proc, file, foreign, clock,
                   onTime, wrongKills>>

\* An unknown row is read again until it is running or gone.
ReRead(s) ==
    /\ up /\ call[s] = "none" /\ row[s] = "unknown" /\ Break # "NoReRead"
    /\ \/ /\ Confirms(s)
          /\ SetRow(s, "running") /\ rowProc' = [rowProc EXCEPT ![s] = file[s]]
       \/ /\ ~Live(s)
          /\ SetRow(s, "stopped") /\ UNCHANGED rowProc
    /\ UNCHANGED <<late, up, restarts, starts, resume, call, past, proc, file, foreign, clock,
                   onTime, wrongKills, trees, treeGhosts>>

-----------------------------------------------------------------------------
(* A stop *)

\* /exit is typed (Control's checked write); the process exits when it will.
StopAsked(s) ==
    /\ up /\ call[s] = "none" /\ row[s] = "running"
    /\ row' = [row EXCEPT ![s] = "stopping"]
    /\ call' = [call EXCEPT ![s] = "stop"]
    /\ late' = [late EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<up, restarts, rowProc, starts, resume, past, proc, file, foreign, clock, onTime,
                   ends, wrongKills, trees, treeGhosts>>

\* By the row's pid and start time: stopped when gone; after a restart, with
\* no stop under way, running otherwise, unless the stop's deadline passed:
\* that row stays stopping for Recoveries.
StopSettled(s) ==
    /\ up /\ row[s] = "stopping" /\ call[s] \in {"none", "stop"}
    /\ LET alive == IF Break = "SettleByPid" THEN AliveByPid(rowProc[s]) ELSE Alive(rowProc[s])
       IN \/ /\ ~alive /\ SetRow(s, "stopped")
          \/ /\ alive /\ call[s] = "none" /\ ~late[s] /\ SetRow(s, "running")
    /\ call' = [call EXCEPT ![s] = "none"]
    /\ UNCHANGED <<late, up, restarts, rowProc, starts, resume, past, proc, file, foreign, clock,
                   onTime, wrongKills, trees, treeGhosts>>

\* The stop's deadline passed with the process alive: the row stays stopping,
\* marked late, with no call under way.
StopTimedOut(s) ==
    /\ up /\ row[s] = "stopping" /\ call[s] = "stop" /\ Alive(rowProc[s])
    /\ late' = [late EXCEPT ![s] = TRUE]
    /\ call' = [call EXCEPT ![s] = "none"]
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, resume, past, proc, file, foreign, clock,
                   onTime, ends, wrongKills, trees, treeGhosts>>

\* Recoveries kills a stop past its deadline, by the row's pid and start time.
Kill(s) ==
    /\ up /\ row[s] = "stopping" /\ late[s]
    /\ \E q \in LiveProcs :
         /\ q.pid = rowProc[s].pid
         /\ q = rowProc[s] \/ Break = "KillByPid"
         /\ proc' = [t \in S |-> IF proc[t] = q THEN NoProc ELSE proc[t]]
         /\ foreign' = foreign \ {q}
         /\ wrongKills' = IF q = proc[s] THEN wrongKills ELSE wrongKills \cup {q}
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, file, clock,
                   onTime, ends, trees, treeGhosts>>

-----------------------------------------------------------------------------
Next ==
    \/ FrameworkDies \/ FrameworkStarts \/ ForeignStarts
    \/ \E p \in Paths : PathTaken(p) \/ TreeChanged(p) \/ LeftSetupEnds(p)
    \/ \E s \in S :
         \/ ProcExits(s) \/ FileWritten(s) \/ Tick(s)
         \/ RowWritten(s) \/ Checked(s) \/ Added(s) \/ SetupStarts(s) \/ SetupEnds(s)
         \/ Held(s) \/ ViewerOpened(s) \/ StartDecided(s)
         \/ Adopt(s) \/ ReRead(s)
         \/ StopAsked(s) \/ StopSettled(s) \/ StopTimedOut(s) \/ Kill(s)

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A s \in S :
         /\ WF_vars(Tick(s)) /\ WF_vars(Checked(s)) /\ WF_vars(Added(s))
         /\ WF_vars(SetupStarts(s)) /\ WF_vars(SetupEnds(s))
         /\ WF_vars(Held(s)) /\ WF_vars(ViewerOpened(s))
         /\ WF_vars(StartDecided(s)) /\ WF_vars(Adopt(s)) /\ WF_vars(ReRead(s))
         /\ WF_vars(StopSettled(s))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ up \in BOOLEAN
    /\ row \in [S -> {"none", "starting", "running", "stopping", "stopped", "refused",
                      "unknown", "orphan"}]
    /\ call \in [S -> {"none", "check", "add", "setup", "setting", "hold", "viewer", "wait",
                       "stop"}]
    /\ late \in [S -> BOOLEAN] /\ resume \in [S -> BOOLEAN]
    /\ wt \in [Paths -> {"none", "tree", "other"}]
    /\ dirty \in [Paths -> BOOLEAN] /\ ready \in [Paths -> BOOLEAN]
    /\ branch \in [Paths -> BOOLEAN] /\ setupRuns \in [Paths -> BOOLEAN]
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

\* A worktree a live process or a running setup is in is never reused, set
\* up again or removed.
BusyTreeUntouched == ~touched

\* A removed worktree was clean.
RemovedWasClean == ~removedDirty

\* A new start reuses only a clean worktree; a resume takes its own as it is.
ReusedWasClean == ~reusedDirty

\* A setup or a held process runs only in a worktree on its branch: a branch
\* a failed add left behind is not taken for a worktree.
OnlyInTrees == ~offTree

\* A held process runs in a worktree whose last setup finished.
StartsInReadyTree ==
    Worktrees => \A s \in S : Live(s) => wt[PathOf(s)] = "tree" /\ ready[PathOf(s)]

\* Every starting row settles.
StartingSettles == \A s \in S : row[s] = "starting" ~> row[s] # "starting"

\* An unknown row whose process is running with its file, or gone, settles.
UnknownSettles ==
    \A s \in S : row[s] = "unknown" /\ (Confirms(s) \/ ~Live(s)) ~> row[s] # "unknown"

=============================================================================
