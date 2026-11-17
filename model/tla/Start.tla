------------------------------- MODULE Start -------------------------------
(***************************************************************************)
(* One host's session starts and stops, and restarts of the framework in   *)
(* between any two of their steps: the row written first, the worktree     *)
(* checked or added and its setup run, the process held by dtach, the      *)
(* viewer, the session file Claude Code writes (perhaps late), the start   *)
(* confirmed or unknown at its deadline, and after a restart the adoption  *)
(* of a starting row (with the removal of its worktree), the settling of a *)
(* stopping row and the reading again of an unknown one, and at any time   *)
(* the settling of a running row whose process exited by itself. A socket  *)
(* ends apart from its process (F-64): dtach exits a moment after it, or   *)
(* is killed hard and leaves a stale socket while its process runs on.     *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                           *)
(*   Sessions  its table (durable) and its calls under way (in memory):    *)
(*             start, stop, adoption after a restart (built in F-17), and  *)
(*             a start's worktree and setup (F-55), and the settling of a  *)
(*             running row whose process is gone as stopped, with reason   *)
(*             exited (F-61); the settles of running and stopping rows     *)
(*             with no call under way run only at a cue (F-64);            *)
(*   Sessions.Worktree the checks of a worktree at a start's path: absent, *)
(*             a worktree on the start's branch, clean or not, or taken;   *)
(*   git       `worktree list` and `status` (the checks), `worktree add`,  *)
(*             with `-b` when the branch does not exist, which at a taken  *)
(*             path fails and still leaves the new branch behind, and      *)
(*             `worktree remove`;                                          *)
(*   Shell.Reaper the setup's process group, which ends with the caller,   *)
(*             so a restart of the framework ends a setup under way;       *)
(*   Holder    dtach -n: a socket holds one process, and refuses a second; *)
(*             a socket read as live or dead (absent or stale); dtach      *)
(*             exits after its process, and may be killed hard before;     *)
(*   Holder.Process (F-118) the held program's record: the pid and start   *)
(*             time its wrapper writes before it execs the program, so     *)
(*             every hold has one (`pidFile`); a process's liveness by its *)
(*             pid and start time; a signal sent only to the process with  *)
(*             the record's pid and start time;                            *)
(*   Registry  the session file, matched by the session's name, with its   *)
(*             `status` (`busy` while a turn runs); its cue when the       *)
(*             process a file names is gone;                               *)
(*   TmuxSampler its cue when a held socket goes away (absent or stale);   *)
(*   Recoveries the end of an orphan row's process and of one a stop's     *)
(*             deadline passed with, by the row's record: TERM, then KILL, *)
(*             one act here (F-118), under a claim in Acts (Claim.tla's,   *)
(*             RC). The KILL may fail: the process outlives it, the act    *)
(*             settles `unknown`, and the row waits for a person, whose    *)
(*             clear (Recoveries.clear/2) makes its state new, so the end  *)
(*             is tried once more (F-128). A state is the row's record and *)
(*             its clears, as the code's key is the record and the time of *)
(*             the last clear. A restart that cuts a claim leaves the row  *)
(*             waiting for a person in the same way. With `SplitEnds`      *)
(*             FALSE the claim and the end are one step, as the code's one *)
(*             call takes them, and no restart falls between; only the     *)
(*             configuration that studies the failed end (Start_FailedEnds)*)
(*             splits them, which keeps the others small. A name's claims  *)
(*             pass when its row settles stopped: its next start has a new *)
(*             record, so no later state is one of them.                   *)
(*                                                                         *)
(* The failed end is here, not in Agent.tla beside the clear of a viewer   *)
(* lost a third time: this spec has the rows Recoveries ends, their        *)
(* records and the KILL, so it needs only the claim's variables and the    *)
(* clears. Agent.tla has no row, record or end, and its one Claim instance *)
(* numbers no states; it would need all of these and a second instance.   *)
(*                                                                         *)
(* A stop (F-118, "Ending a session") is SIGTERM to the row's process, by  *)
(* its pid and start time, once its session file reads idle; Claude Code   *)
(* keeps its transcript and exits 143 when it will. The read of the file   *)
(* and the signal are one step here: a turn that a delivery starts between *)
(* them is the delivery's to rule out (Delivery.tla, R6). A turn starts    *)
(* and ends only while the row is running, which is all the stop reads.    *)
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
(* so a restart does not move it. A process exits at any time, after a     *)
(* SIGTERM or by itself, or never: then Recoveries ends it. Other programs *)
(* on the host take free pids, so a pid is reused.                         *)
(* Delegate.tla's single start step stands for this whole spec.            *)
(*                                                                         *)
(* Cues (F-64): `cued` is a cue Sessions has not handled yet. The Registry *)
(* cues when the process a file names exits or is killed, the sampler when *)
(* a socket goes away (absent or stale), and the framework's start settles *)
(* every row. A cue reaches nothing while the framework is down, and a     *)
(* restart loses one not handled. RunningSettled and StopSettled with no   *)
(* stop under way run only at a cue, and handle it; CueIdle handles a cue  *)
(* they cannot act on. A cue for any other row is dropped (Cueable): Adopt *)
(* and ReRead keep the fairness of F-17 (F-64's new-1).                    *)
(*                                                                         *)
(* A socket apart from its process (F-64): `sock` says dtach answers on    *)
(* the socket. DtachExits is dtach ending once its process has, and        *)
(* DtachKilled a hard kill of dtach (`MaxHardKills` of them), which leaves *)
(* a stale socket while the process runs on, unheld. Assumed: a hard kill  *)
(* comes only once the session file names the process. One before, with    *)
(* the process left running and no file yet, leaves a process no reader    *)
(* of the framework can find (F-64's new-2).                               *)
(*                                                                         *)
(* Fairness: the framework's steps happen while they stay possible, dtach  *)
(* exits once its process has, and time passes. Processes, other programs  *)
(* and people act or not: a person may never clear a failed end. A KILL    *)
(* fails only while the name's clears are fewer than `MaxClears`, which    *)
(* bounds the failures; with it 0 every KILL ends its process.             *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Start_<value>.cfg that TLC must fail.                       *)
(*                                                                         *)
(* Defense in depth, with no Break: the hold's refusal of a live socket.   *)
(* The row is written first and a new start needs an ended row, and a row  *)
(* ends only once its process is gone and its socket is dead, so a start   *)
(* never meets a live socket of its own name, nor a process of its name    *)
(* still running unheld (Held's ~Live, which NoHeldWithoutRow covers).     *)
(* RowEndsOnce rests on the same guards. The removal's check that no other *)
(* row holds the path, behind the check RowWritten makes: a row holds its  *)
(* path from its write until it ends. In the code, git's own refusal to    *)
(* remove a dirty worktree (no --force) is defense in depth behind the     *)
(* clean check of Adopt.                                                   *)
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
    MaxHardKills, \* dtach masters killed hard, each leaving a stale socket
    MaxClears,    \* a person's clears of each name's ends; a KILL fails only while fewer
    SplitEnds,    \* Recoveries' claim and its end are two steps, so a restart may cut between
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "DecideEarly",        \* the adoption decides before the start's deadline
    "DropOrphan",         \* a live socket with no file past the deadline ends refused, not orphan
    "SettleByPid",        \* a stopping row is settled by its pid alone, without its start time
    "SettleRunningByPid", \* a running row is settled by its pid alone, without its start time
    "KillByPid",          \* a kill targets the row's pid alone, without its start time
    "HoldFirst",          \* the process is held before its row is written
    "NoReRead",           \* an unknown row is never read again
    "NoHeldCheck",        \* a start takes a path another row that has not ended holds
    "ReuseDirty",         \* a start reuses a worktree with changes in it
    "ReuseOther",         \* a start reuses a path that is not a worktree on its branch
    "ReuseSkipsSetup",    \* a start that reuses a worktree does not run the setup
    "BranchAsWorktree",   \* a failed add is taken as done because its branch exists
    "RemoveDirty",        \* the removal after a restart does not check that the tree is clean
    "RemoveOrphan",       \* the removal also takes an orphan's worktree
    "SetupOutlives",      \* the setup runs without the reaper, so a restart leaves it running
    \* F-64: a socket apart from its process
    "SettleRunningBySocket",   \* a running row is settled by its socket alone
    "SettleRunningByLiveness", \* a running row is settled by its pid and start time alone
    "StopByLiveness",     \* a stopping row is settled by its pid and start time alone
    "ReReadBySocket",     \* an unknown row is stopped on a dead socket while its file names a live one
    "AdoptBySocket",      \* a starting row is refused on a dead socket while its file names a live one
    "NoSocketCue",        \* the sampler does not cue Sessions when a held socket goes away
    \* F-118: the end by SIGTERM, and Recoveries' end of an orphan
    "StopWhileBusy",      \* the stop's SIGTERM is sent while the session file reads busy
    "TermByPid",          \* the stop's SIGTERM targets the row's pid alone, without its start time
    "OrphanKept",         \* Recoveries ends a late stop's process but not an orphan's
    \* F-128: a failed end waits for a person
    "EndAgain",           \* a state whose end failed is claimed and ended again, with no clear
    "NoTryAfterClear"     \* Recoveries does not end a row again once a person cleared it
}

ASSUME Break \in Breaks
ASSUME NPids \in Nat /\ MaxStarts \in Nat /\ MaxRestarts \in Nat /\ MaxForeign \in Nat
ASSUME Worktrees \in BOOLEAN /\ Shared \in BOOLEAN /\ MaxOutside \in Nat /\ MaxHardKills \in Nat
ASSUME MaxClears \in Nat /\ SplitEnds \in BOOLEAN
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
    proc,        \* s -> the process of s's name, held or left running by a killed dtach, or NoProc
    sock,        \* s -> dtach answers on s's socket (live); FALSE when absent or stale
    cued,        \* in memory: s -> a cue for s came and Sessions has not handled it
    hardKills,   \* dtach masters killed hard so far
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
    reusedDirty, \* ghost: a new start (not a resume) reused a tree with changes
    busy,        \* s -> the process's turn runs: its session file reads busy
    pidFile,     \* s -> the record the wrapper of s's last hold wrote, or NoProc
    cutTurns,    \* ghost: a SIGTERM reached a process in the middle of a turn
    clears,      \* table (Acts): s -> a person's clears of s's ends so far
    \* Recoveries' claims of an end, as Claim.tla's variables (RC); a state is
    \* the row's record and its clears
    claims,      \* table (Acts): the claims of an end
    acting,      \* in memory: the claims Recoveries holds and has not acted on yet
    done,        \* table (Acts): the claims acted on, let go, or settled interrupted
    acted,       \* ghost: the states an end ran on
    twice,       \* ghost: an end ran on a state an end ran on before
    cutOff       \* ghost: the states whose claim a restart cut off before any end

trees == <<wt, dirty, ready, branch, setupRuns, outside>>
socks == <<sock, cued, hardKills>>
treeGhosts == <<touched, offTree, removedDirty, reusedDirty>>
records == <<busy, pidFile, cutTurns>>
claimVars == <<claims, acting, done, acted, twice, cutOff>>
endVars == <<clears, claimVars>>
vars == <<up, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign, clock,
          late, onTime, ends, wrongKills, trees, treeGhosts, socks, records, endVars>>

LiveProcs == ({proc[t] : t \in S} \ {NoProc}) \cup foreign
FreePids == Pids \ {q.pid : q \in LiveProcs}
Live(s) == proc[s] # NoProc
\* Registry's reading: the file of the session's name names its live process.
Named(s) == Live(s) /\ file[s] = proc[s]
\* A start is confirmed by that file while its socket is live.
Confirms(s) == sock[s] /\ Named(s)
\* Liveness by pid and start time (Registry.Liveness), or by pid alone.
Alive(q) == q \in LiveProcs
AliveByPid(q) == \E r \in LiveProcs : r.pid = q.pid
Ended == {"none", "stopped", "refused"}
\* Another session's row that has not ended holds the same path.
HeldByOther(s) == \E t \in S \ {s} : PathOf(t) = PathOf(s) /\ row[t] \notin Ended
\* A process or a setup runs in path p.
Busy(p) == (\E t \in S : PathOf(t) = p /\ Live(t)) \/ setupRuns[p]

\* Recoveries' claim of an end, in Acts (Claim.tla). The state of s's end is
\* the row's record and the person's clears of s, as the code's key is the
\* record and the time of the last clear: a clear makes the state new, and
\* nothing else does while the row waits. Under EndAgain a second claim is
\* taken on a state that has one.
RC == INSTANCE Claim WITH
        Targets <- S, Actors <- {"recoveries"}, MaxState <- 0,
        now <- [t \in S |-> <<rowProc[t], clears[t]>>],
        rows <- claims, acting <- acting, done <- done, acted <- acted, twice <- twice,
        cut <- cutOff,
        Break <- IF Break = "EndAgain" THEN "TwoClaims" ELSE "none"
EndState(s) == <<rowProc[s], clears[s]>>

\* A row Recoveries ends: a stop past its deadline, or an orphan, whose
\* record names a live process (by pid alone under KillByPid). Under
\* NoTryAfterClear a row a person cleared is not ended again.
EndOwed(s) ==
    /\ \/ row[s] = "stopping" /\ late[s]
       \/ row[s] = "orphan" /\ Break # "OrphanKept"
    /\ \E q \in LiveProcs : q.pid = rowProc[s].pid /\ (q = rowProc[s] \/ Break = "KillByPid")
    /\ clears[s] = 0 \/ Break # "NoTryAfterClear"

\* The end of s's state ended with its process alive: the KILL failed
\* (`unknown`), or a restart cut its claim (interrupted). No second end runs
\* on that state; the row waits for a person's clear.
WaitsForPerson(s) ==
    /\ (row[s] = "stopping" /\ late[s]) \/ row[s] = "orphan"
    /\ Alive(rowProc[s])
    /\ \E c \in RC!On(s, EndState(s)) : c \in done

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
    /\ sock = [s \in S |-> FALSE] /\ cued = [s \in S |-> FALSE] /\ hardKills = 0
    /\ busy = [s \in S |-> FALSE] /\ pidFile = [s \in S |-> NoProc] /\ cutTurns = FALSE
    /\ clears = [s \in S |-> 0]
    /\ claims = {} /\ acting = {} /\ done = {} /\ acted = {} /\ twice = FALSE /\ cutOff = {}

\* Writes row s's status; entering an ended status counts as its end.
SetRow(s, st) ==
    /\ row' = [row EXCEPT ![s] = st]
    /\ ends' = IF st \in {"stopped", "refused"} THEN [ends EXCEPT ![s] = @ + 1] ELSE ends

\* A cue settles only a running or stopping row with no call under way here:
\* Adopt and ReRead do not wait for one. A cue for any other row settles
\* nothing, so the model drops it, which keeps the search small.
Cueable(s) == call[s] = "none" /\ row[s] \in {"running", "stopping", "orphan"}
\* A reader's cue for s, when c holds; one that comes while the framework is
\* down reaches nothing.
Cue(s, c) == cued' = [cued EXCEPT ![s] = @ \/ (up /\ c /\ Cueable(s))]
\* Sessions handled s's cue.
Handled(s) == cued' = [cued EXCEPT ![s] = FALSE]

\* A signal to the process with pid and start time `q0` (Holder.Process): the
\* check and the signal run in one shell on the host, so a pid another program
\* took is not reached. Under the Break `brk` the pid alone is matched. A
\* process other than s's own that it reaches ends (a wrong kill); s's own ends
\* when it will, or at once when `final` holds (KILL).
Signal(s, q0, brk, final) ==
    LET hit == {q \in LiveProcs : q.pid = q0.pid /\ (q = q0 \/ Break = brk)}
        gone == IF final THEN hit ELSE hit \ {proc[s]}
    IN /\ proc' = [t \in S |-> IF proc[t] \in gone THEN NoProc ELSE proc[t]]
       /\ busy' = [t \in S |-> busy[t] /\ proc[t] \notin gone]
       /\ foreign' = foreign \ gone
       /\ wrongKills' = wrongKills \cup (hit \ {proc[s]})
       /\ cutTurns' = (cutTurns \/ (proc[s] \in hit /\ busy[s]))

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
    /\ cued' = [s \in S |-> FALSE]
    /\ RC!Restart
    /\ UNCHANGED <<late, row, rowProc, starts, resume, past, proc, file, foreign, clock, onTime,
                   ends, wrongKills, wt, dirty, ready, branch, outside, treeGhosts, sock,
                   hardKills, records, clears>>

\* Sessions settles every row when it starts: a cue for each.
FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ cued' = [s \in S |-> Cueable(s)]
    /\ UNCHANGED <<late, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, onTime, ends, wrongKills, trees, treeGhosts, sock, hardKills,
                   records, endVars>>

-----------------------------------------------------------------------------
(* The outside: processes, dtach, other programs, people, Claude Code's     *)
(* file, time                                                              *)

\* The process ends; its socket stays live until dtach exits. The Registry
\* cues when a file named it.
ProcExits(s) ==
    /\ Live(s) /\ proc' = [proc EXCEPT ![s] = NoProc]
    /\ busy' = [busy EXCEPT ![s] = FALSE]
    /\ Cue(s, Named(s))
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, file, foreign,
                   clock, onTime, ends, wrongKills, trees, treeGhosts, sock, hardKills, pidFile,
                   cutTurns, endVars>>

\* A turn starts in a running session (a message went in), and its session
\* file reads busy; it ends, and the file reads idle.
TurnStarts(s) ==
    /\ Named(s) /\ row[s] = "running" /\ ~busy[s]
    /\ busy' = [busy EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, late, onTime, ends, wrongKills, trees, treeGhosts, socks, pidFile,
                   cutTurns, endVars>>

TurnEnds(s) ==
    /\ busy[s] /\ busy' = [busy EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, late, onTime, ends, wrongKills, trees, treeGhosts, socks, pidFile,
                   cutTurns, endVars>>

\* dtach exits once its process has, and removes its socket; the sampler
\* sees the socket go and cues.
DtachExits(s) ==
    /\ sock[s] /\ ~Live(s)
    /\ sock' = [sock EXCEPT ![s] = FALSE]
    /\ Cue(s, Break # "NoSocketCue")
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, proc, file,
                   foreign, clock, onTime, ends, wrongKills, trees, treeGhosts, hardKills,
                   records, endVars>>

\* dtach is killed hard: its socket is left stale, and its process runs on,
\* unheld, until it exits. Only once a file names the process (assumed).
DtachKilled(s) ==
    /\ hardKills < MaxHardKills /\ sock[s] /\ Named(s)
    /\ sock' = [sock EXCEPT ![s] = FALSE] /\ hardKills' = hardKills + 1
    /\ Cue(s, Break # "NoSocketCue")
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, proc, file,
                   foreign, clock, onTime, ends, wrongKills, trees, treeGhosts, records, endVars>>

\* Another program starts and takes a free pid, perhaps one a session had.
ForeignStarts ==
    /\ Cardinality(foreign) < MaxForeign
    /\ \E p \in FreePids : foreign' = foreign \cup {[pid |-> p, start |-> clock + 1]}
    /\ clock' = clock + 1
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, proc, file,
                   onTime, ends, wrongKills, trees, treeGhosts, socks, records, endVars>>

\* Claude Code writes its session file, with the session's name, perhaps late.
FileWritten(s) ==
    /\ Live(s) /\ file[s] # proc[s]
    /\ file' = [file EXCEPT ![s] = proc[s]]
    /\ onTime' = [onTime EXCEPT ![s] = ~past[s]]
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, proc, foreign,
                   clock, ends, wrongKills, trees, treeGhosts, socks, records, endVars>>

Tick(s) ==
    /\ row[s] = "starting" /\ ~past[s] /\ past' = [past EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, proc, file, foreign,
                   clock, onTime, ends, wrongKills, trees, treeGhosts, socks, records, endVars>>

\* A person or a program makes a directory at a free path.
PathTaken(p) ==
    /\ outside < MaxOutside /\ wt[p] = "none"
    /\ wt' = [wt EXCEPT ![p] = "other"] /\ outside' = outside + 1
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, late, onTime, ends, wrongKills, dirty, ready, branch, setupRuns,
                   treeGhosts, socks, records, endVars>>

\* Someone changes files in a tree: its agent, a person, or an add cut midway.
TreeChanged(p) ==
    /\ outside < MaxOutside /\ wt[p] = "tree" /\ ~dirty[p]
    /\ dirty' = [dirty EXCEPT ![p] = TRUE] /\ outside' = outside + 1
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, late, onTime, ends, wrongKills, wt, ready, branch, setupRuns,
                   treeGhosts, socks, records, endVars>>

\* A setup a restart left running (SetupOutlives only) ends by itself.
LeftSetupEnds(p) ==
    /\ setupRuns[p] /\ \A s \in S : PathOf(s) = p => call[s] # "setting"
    /\ setupRuns' = [setupRuns EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, late, onTime, ends, wrongKills, wt, dirty, ready, branch, outside,
                   treeGhosts, socks, records, endVars>>

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
    /\ UNCHANGED <<late, up, restarts, proc, file, foreign, clock, wrongKills, trees, treeGhosts,
                   socks, records, endVars>>

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
                   onTime, wrongKills, trees, socks, records, endVars>>

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
                   onTime, wrongKills, dirty, ready, setupRuns, outside, treeGhosts, socks,
                   records, endVars>>

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
                   reusedDirty, socks, records, endVars>>

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
                   onTime, wrongKills, wt, dirty, branch, outside, treeGhosts, socks,
                   records, endVars>>

\* dtach -n: the process is held on a live socket; or the hold is refused,
\* with nothing held; or it answers unknown, and the start waits for the
\* file either way. dtach refuses a live socket; a name's process left
\* running by a killed dtach is gone before its row ends (NoHeldWithoutRow).
\* Holder.Process removes the last hold's record first, and the wrapper writes
\* the new process's before it execs the program: one step here.
Held(s) ==
    /\ up /\ call[s] = "hold"
    /\ \/ /\ ~Live(s) /\ ~sock[s] /\ FreePids # {}
          /\ \E p \in FreePids :
               /\ proc' = [proc EXCEPT ![s] = [pid |-> p, start |-> clock + 1]]
               /\ pidFile' = [pidFile EXCEPT ![s] = [pid |-> p, start |-> clock + 1]]
          /\ sock' = [sock EXCEPT ![s] = TRUE]
          /\ clock' = clock + 1
          /\ call' = [call EXCEPT ![s] = "viewer"]
          /\ offTree' = (offTree \/ (Worktrees /\ wt[PathOf(s)] # "tree"))
          /\ UNCHANGED <<row, ends>>
       \/ /\ ~Live(s)
          /\ call' = [call EXCEPT ![s] = "viewer"]
          /\ pidFile' = [pidFile EXCEPT ![s] = NoProc]
          /\ UNCHANGED <<row, ends, proc, clock, offTree, sock>>
       \/ /\ SetRow(s, "refused")
          /\ call' = [call EXCEPT ![s] = "none"]
          /\ pidFile' = [pidFile EXCEPT ![s] = NoProc]
          /\ UNCHANGED <<proc, clock, offTree, sock>>
    /\ UNCHANGED <<late, up, restarts, rowProc, starts, resume, past, file, foreign, onTime,
                   wrongKills, trees, touched, removedDirty, reusedDirty, cued, hardKills, busy,
                   cutTurns, endVars>>

\* The viewer opens, or fails and leaves the process running (Agent.tla).
ViewerOpened(s) ==
    /\ up /\ call[s] = "viewer"
    /\ call' = [call EXCEPT ![s] = "wait"]
    /\ row' = IF Break = "HoldFirst" THEN [row EXCEPT ![s] = "starting"] ELSE row
    /\ UNCHANGED <<late, up, restarts, rowProc, starts, resume, past, proc, file, foreign, clock,
                   onTime, ends, wrongKills, trees, treeGhosts, socks, records, endVars>>

\* The call reads the Registry until its deadline: running, or unknown.
StartDecided(s) ==
    /\ up /\ call[s] = "wait" /\ row[s] = "starting"
    /\ \/ /\ Confirms(s)
          /\ SetRow(s, "running") /\ rowProc' = [rowProc EXCEPT ![s] = file[s]]
       \/ /\ ~Confirms(s) /\ past[s]
          /\ SetRow(s, "unknown") /\ UNCHANGED rowProc
    /\ call' = [call EXCEPT ![s] = "none"]
    /\ UNCHANGED <<late, up, restarts, starts, resume, past, proc, file, foreign, clock, onTime,
                   wrongKills, trees, treeGhosts, socks, records, endVars>>

-----------------------------------------------------------------------------
(* After a restart: a starting row with no call under way *)

\* Adopted when its file names its live process and its socket is live;
\* otherwise, once the start's deadline has passed, an orphan row for a live
\* socket, with the record its wrapper wrote (Holder.Process), and one with
\* the file's pid and start time for a dead socket while the file names a
\* live process (dtach killed hard); refused{interrupted} for the rest, whose
\* worktree is removed when clean and held by no one.
Adopt(s) ==
    /\ up /\ call[s] = "none" /\ row[s] = "starting"
    /\ \/ /\ Confirms(s)
          /\ SetRow(s, "running") /\ rowProc' = [rowProc EXCEPT ![s] = file[s]]
          /\ UNCHANGED <<trees, treeGhosts>>
       \/ /\ ~Confirms(s) /\ (past[s] \/ Break = "DecideEarly")
          /\ LET unheld == ~sock[s] /\ Named(s)
             IN IF \/ sock[s] /\ Break # "DropOrphan"
                   \/ unheld /\ Break # "AdoptBySocket"
                  THEN /\ SetRow(s, "orphan")
                       /\ rowProc' = [rowProc EXCEPT ![s] = IF unheld THEN file[s]
                                                                          ELSE pidFile[s]]
                       /\ IF Break = "RemoveOrphan" THEN Remove(s)
                          ELSE UNCHANGED <<trees, treeGhosts>>
                  ELSE SetRow(s, "refused") /\ Remove(s) /\ UNCHANGED rowProc
    /\ UNCHANGED <<late, up, restarts, starts, resume, call, past, proc, file, foreign, clock,
                   onTime, wrongKills, socks, records, endVars>>

\* An unknown row is read again until it is running or gone: running when
\* confirmed; on a dead socket, an orphan with the file's pid and start time
\* while the file names a live process, stopped otherwise.
ReRead(s) ==
    /\ up /\ call[s] = "none" /\ row[s] = "unknown" /\ Break # "NoReRead"
    /\ \/ /\ Confirms(s)
          /\ SetRow(s, "running") /\ rowProc' = [rowProc EXCEPT ![s] = file[s]]
       \/ /\ ~sock[s] /\ Named(s) /\ Break # "ReReadBySocket"
          /\ SetRow(s, "orphan") /\ rowProc' = [rowProc EXCEPT ![s] = file[s]]
       \/ /\ ~sock[s] /\ (~Named(s) \/ Break = "ReReadBySocket")
          /\ SetRow(s, "stopped") /\ UNCHANGED rowProc
    /\ UNCHANGED <<late, up, restarts, starts, resume, call, past, proc, file, foreign, clock,
                   onTime, wrongKills, trees, treeGhosts, socks, records, endVars>>

-----------------------------------------------------------------------------
(* A stop *)

\* SIGTERM, once the session file that names the row's process reads idle, to
\* that process by its pid and start time; it exits when it will. A process
\* already gone is sent nothing, and the row settles.
StopAsked(s) ==
    /\ up /\ call[s] = "none" /\ row[s] = "running"
    /\ file[s] = rowProc[s] /\ (~busy[s] \/ Break = "StopWhileBusy")
    /\ Signal(s, rowProc[s], "TermByPid", FALSE)
    /\ row' = [row EXCEPT ![s] = "stopping"]
    /\ call' = [call EXCEPT ![s] = "stop"]
    /\ late' = [late EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<up, restarts, rowProc, starts, resume, past, file, clock, onTime,
                   ends, trees, treeGhosts, socks, pidFile, endVars>>

\* A stopping row's process is gone by the row's pid and start time, and its
\* socket is dead.
StopGone(s) == ~IF Break = "SettleByPid" THEN AliveByPid(rowProc[s]) ELSE Alive(rowProc[s])
StopDead(s) == ~sock[s] \/ Break = "StopByLiveness"
\* What a cue's settle decides of a stopping row with no stop under way.
StopDecides(s) ==
    /\ call[s] = "none" /\ row[s] = "stopping"
    /\ (StopGone(s) /\ StopDead(s)) \/ (~StopGone(s) /\ ~late[s])

\* Stopped when its process is gone and its socket is dead; with no stop
\* under way (after a restart or the stop's deadline), at a cue, and running
\* when its process is alive, unless the stop was late: that row stays
\* stopping for Recoveries. Within the stop, its own reads until its deadline.
StopSettled(s) ==
    /\ up /\ row[s] = "stopping"
    /\ call[s] = "stop" \/ (call[s] = "none" /\ cued[s])
    /\ \/ StopGone(s) /\ StopDead(s) /\ SetRow(s, "stopped")
       \/ ~StopGone(s) /\ call[s] = "none" /\ ~late[s] /\ SetRow(s, "running")
    /\ call' = [call EXCEPT ![s] = "none"]
    /\ IF call[s] = "none" THEN Handled(s) ELSE UNCHANGED cued
    /\ IF row'[s] = "stopped" THEN RC!Passes({s}) ELSE UNCHANGED claimVars
    /\ UNCHANGED <<late, up, restarts, rowProc, starts, resume, past, proc, file, foreign, clock,
                   onTime, wrongKills, trees, treeGhosts, sock, hardKills, records, clears>>

\* The stop's deadline passed with the process alive, or gone while its
\* socket is still live: the row stays stopping, with no call under way, and
\* is marked late (for Recoveries) only when its process is alive.
StopTimedOut(s) ==
    /\ up /\ row[s] = "stopping" /\ call[s] = "stop" /\ (Alive(rowProc[s]) \/ sock[s])
    /\ late' = [late EXCEPT ![s] = Alive(rowProc[s])]
    /\ call' = [call EXCEPT ![s] = "none"]
    /\ UNCHANGED <<up, restarts, row, rowProc, starts, resume, past, proc, file, foreign, clock,
                   onTime, ends, wrongKills, trees, treeGhosts, socks, records, endVars>>

\* Recoveries' end of s's process, by the row's record (Holder.Process):
\* TERM, then KILL at its own deadline; one step here. The KILL ends it, and
\* the Registry or the sampler cues, as at an exit; or the process outlives
\* it (a KILL fails only while s's clears are fewer than MaxClears), and the
\* act settles `unknown`.
EndRuns(s) ==
    \/ /\ Signal(s, rowProc[s], "KillByPid", TRUE)
       /\ Cue(s, TRUE)
    \/ /\ clears[s] < MaxClears
       /\ UNCHANGED <<proc, foreign, wrongKills, cued, busy, cutTurns>>

\* Recoveries claims the end of a row it owes one, in Acts, once per state.
\* With SplitEnds the end is its own later step (Kill), so a restart may cut
\* the claim; without, the claim and the end are one step.
EndClaimed(s) ==
    /\ up /\ EndOwed(s)
    /\ IF SplitEnds
         THEN /\ RC!Take("recoveries", s, "end")
              /\ UNCHANGED <<proc, foreign, wrongKills, cued, busy, cutTurns>>
         ELSE RC!TakeAndAct("recoveries", s, "end") /\ EndRuns(s)
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, file, clock,
                   onTime, ends, trees, treeGhosts, sock, hardKills, pidFile, clears>>

\* With SplitEnds: the end of a claim taken earlier. A claim whose state
\* passed, or whose row no longer owes an end, is let go.
Kill(c) ==
    LET s == c.t IN
    /\ up
    /\ \/ EndOwed(s) /\ RC!Act(c) /\ EndRuns(s)
       \/ /\ ~(EndOwed(s) /\ RC!Current(c)) /\ RC!LetGo(c)
          /\ UNCHANGED <<proc, foreign, wrongKills, cued, busy, cutTurns>>
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, file, clock,
                   onTime, ends, trees, treeGhosts, sock, hardKills, pidFile, clears>>

\* A claim a restart cut off ends interrupted once the framework is up again
\* (Acts closes the open rows of other starts), never acted on.
EndSettled(c) ==
    /\ up /\ RC!Settle(c)
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, proc, file,
                   foreign, clock, onTime, ends, wrongKills, trees, treeGhosts, socks, records,
                   clears>>

\* A person clears a row whose end waits for them (Recoveries.clear/2): its
\* state is new, so Recoveries claims and tries its end once more.
PersonClears(s) ==
    /\ WaitsForPerson(s) /\ clears[s] < MaxClears
    /\ clears' = [clears EXCEPT ![s] = @ + 1]
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, proc, file,
                   foreign, clock, onTime, ends, wrongKills, trees, treeGhosts, socks, records,
                   claimVars>>

-----------------------------------------------------------------------------
(* A running row whose process exited by itself, and an orphan row whose   *)
(* process exited or Recoveries ended                                      *)

\* Its process is gone by the row's pid and start time, and its socket is
\* dead: each half has a Break.
RunningGone(s) ==
    \/ Break = "SettleRunningBySocket"
    \/ ~IF Break = "SettleRunningByPid" THEN AliveByPid(rowProc[s]) ELSE Alive(rowProc[s])
RunningDead(s) == ~sock[s] \/ Break = "SettleRunningByLiveness"
RunningDecides(s) ==
    call[s] = "none" /\ row[s] \in {"running", "orphan"} /\ RunningGone(s) /\ RunningDead(s)

\* At a cue, with no call under way: stopped (reason exited, or ended for an
\* orphan) once its process is gone and its socket is dead, so its name can be
\* started or resumed. A pid another program took does not keep the row.
RunningSettled(s) ==
    /\ up /\ cued[s] /\ RunningDecides(s)
    /\ SetRow(s, "stopped") /\ Handled(s)
    /\ RC!Passes({s})
    /\ UNCHANGED <<late, up, restarts, rowProc, starts, resume, call, past, proc, file, foreign,
                   clock, onTime, wrongKills, trees, treeGhosts, sock, hardKills, records, clears>>

\* A cue whose settle decides nothing: a socket dtach has not removed yet, a
\* live process, or a row with a call under way. The next cue reads again.
CueIdle(s) ==
    /\ up /\ cued[s] /\ ~StopDecides(s) /\ ~RunningDecides(s)
    /\ Handled(s)
    /\ UNCHANGED <<late, up, restarts, row, rowProc, starts, resume, call, past, proc, file,
                   foreign, clock, onTime, ends, wrongKills, trees, treeGhosts, sock, hardKills,
                   records, endVars>>

-----------------------------------------------------------------------------
Next ==
    \/ FrameworkDies \/ FrameworkStarts \/ ForeignStarts
    \/ \E p \in Paths : PathTaken(p) \/ TreeChanged(p) \/ LeftSetupEnds(p)
    \/ \E s \in S :
         \/ ProcExits(s) \/ DtachExits(s) \/ DtachKilled(s) \/ FileWritten(s) \/ Tick(s)
         \/ TurnStarts(s) \/ TurnEnds(s)
         \/ RowWritten(s) \/ Checked(s) \/ Added(s) \/ SetupStarts(s) \/ SetupEnds(s)
         \/ Held(s) \/ ViewerOpened(s) \/ StartDecided(s)
         \/ Adopt(s) \/ ReRead(s)
         \/ StopAsked(s) \/ StopSettled(s) \/ StopTimedOut(s)
         \/ EndClaimed(s) \/ PersonClears(s)
         \/ RunningSettled(s) \/ CueIdle(s)
    \/ \E c \in acting : Kill(c)
    \/ \E c \in claims : EndSettled(c)

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A s \in S :
         /\ WF_vars(Tick(s)) /\ WF_vars(DtachExits(s))
         /\ WF_vars(Checked(s)) /\ WF_vars(Added(s))
         /\ WF_vars(SetupStarts(s)) /\ WF_vars(SetupEnds(s))
         /\ WF_vars(Held(s)) /\ WF_vars(ViewerOpened(s))
         /\ WF_vars(StartDecided(s)) /\ WF_vars(Adopt(s)) /\ WF_vars(ReRead(s))
         /\ WF_vars(StopSettled(s)) /\ WF_vars(RunningSettled(s)) /\ WF_vars(CueIdle(s))
         /\ WF_vars(EndClaimed(s))
    /\ WF_vars(\E c \in acting : Kill(c))
    /\ WF_vars(\E c \in claims : EndSettled(c))

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
    /\ sock \in [S -> BOOLEAN] /\ cued \in [S -> BOOLEAN] /\ busy \in [S -> BOOLEAN]
    /\ \A s \in S : proc[s] = NoProc \/ proc[s].pid \in Pids
    /\ \A s \in S : pidFile[s] = NoProc \/ pidFile[s].pid \in Pids
    /\ \A q \in foreign : q.pid \in Pids
    /\ clears \in [S -> 0..MaxClears]
    /\ acting \subseteq claims /\ done \subseteq claims /\ acting \cap done = {}
    /\ twice \in BOOLEAN
    \* a socket holds one process, and a pid names one live process
    /\ \A q, r \in LiveProcs : q.pid = r.pid => q = r

\* No process of a name, held or left running by a killed dtach, and no live
\* socket, is ever without a row that has not ended: so a resume after a
\* stop's answer never meets a live socket.
NoHeldWithoutRow == \A s \in S : Live(s) \/ sock[s] => row[s] \notin Ended

\* A row is written as running only for a live process its session file
\* names, and the row names that process.
RunningOnlyIfLive ==
    [][\A s \in S : row'[s] = "running" /\ row[s] # "running" =>
                      Named(s)' /\ rowProc'[s] = proc'[s]]_vars

\* A row ends at most once per start.
RowEndsOnce == \A s \in S : ends[s] <= 1

\* Nothing signals a process but by its own pid and start time: the stop's
\* SIGTERM, and Recoveries' end of an orphan or a late stop.
KillsOwnOnly == wrongKills = {}

\* Recoveries ends a row's process at most once per state, across restarts:
\* an end that failed is tried again only after a person's clear (F-128).
OneEndPerState == RC!OneActPerState

\* An end whose claim a restart cut off never runs on that state.
NoEndOnCutOffClaim == RC!NoActOnCutOffClaim

\* A stop's SIGTERM never reaches a process whose turn runs (F-118).
TermsOnlyIdle == ~cutTurns

\* A start whose live, held process wrote its file before the deadline is
\* never given up as orphan or refused: the adoption waited for the deadline.
\* One whose dtach was killed is an orphan however early its file came.
NotGivenUpEarly ==
    \A s \in S : row[s] \in {"orphan", "refused"} /\ Live(s) /\ sock[s] => ~onTime[s]

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

\* An unknown row whose process is running with its file, or gone, or whose
\* socket is dead, settles.
UnknownSettles ==
    \A s \in S : row[s] = "unknown" /\ (Confirms(s) \/ ~Live(s) \/ ~sock[s]) ~> row[s] # "unknown"

\* A running row whose process is gone, by pid and start time, settles: a
\* delegate killed before its last reply can be resumed. Its socket may live
\* on a moment; the sampler's cue settles it then (F-64).
RunningSettles == \A s \in S : row[s] = "running" /\ ~Alive(rowProc[s]) ~> row[s] # "running"

\* A stopping row whose process is gone settles, though its socket outlived
\* the process and the stop's own reads (F-64).
StoppingSettles ==
    \A s \in S : row[s] = "stopping" /\ ~Alive(rowProc[s]) ~> row[s] # "stopping"

\* An orphan row with a record, and a stop past its deadline, end: Recoveries
\* ends the process, and the cues settle the row, so its name is free again
\* (F-118); or the end failed, or a restart cut its claim, and the row waits
\* for a person (F-128). After the person's clear, the same holds again: the
\* end is tried once more. An orphan that has no record (a delegate's whose
\* wrapper wrote none) is the code's, not this spec's: every hold here writes
\* one.
OrphanEnds ==
    \A s \in S : row[s] = "orphan" /\ rowProc[s] # NoProc ~> row[s] \in Ended \/ WaitsForPerson(s)
LateStopEnds ==
    \A s \in S : row[s] = "stopping" /\ late[s] ~> row[s] # "stopping" \/ WaitsForPerson(s)

=============================================================================
