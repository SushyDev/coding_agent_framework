-------------------------------- MODULE Copy --------------------------------
(***************************************************************************)
(* A host's copy of one worktree, and the jobs and services that run in    *)
(* it: the sync that brings the copy in step before each start, the start  *)
(* held by dtach on the host, a job's log, exit or timeout and its fetch   *)
(* back, a service ended by its owner, by its owner's end or by a restart. *)
(* The ssh connection to the host drops at any step and comes back or      *)
(* not, and the framework restarts at any step.                            *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework (none built yet):          *)
(*   Copies    the copy's turn (durable): taken by a run before its sync   *)
(*             and given back once its start is settled, so two runs on    *)
(*             one copy take turns; the sync itself (rsync over ssh, in    *)
(*             memory), the record it takes of each named fetch path       *)
(*             before it sends, and whether it completed;                  *)
(*   Jobs      each job's row (durable): asked, syncing, synced, starting, *)
(*             running, then its end as read from the host (exited with    *)
(*             its code, timed out, or lost); the run call (in memory),    *)
(*             which waits for that end, fetches each named path the       *)
(*             worktree still holds as the sync recorded it, answers the   *)
(*             others as a conflict, and answers;                          *)
(*   Services  each service's row, owner and keep flag (durable); its      *)
(*             start, which is a run like a job's; its end when its owner  *)
(*             ends without keep, and its restart (an end, then a start);  *)
(*   Shell     over ssh: one connection per host, which a drop or a        *)
(*             restart of the framework cuts. A command cut in flight may  *)
(*             still have run on the host; the local rsync ends with its   *)
(*             caller (Shell.Reaper);                                      *)
(*   the host's side of a sync: rsync's server, under a lock of the copy   *)
(*             it holds for its whole life. It may wait for the lock and   *)
(*             write on after its local side ended, until it notices; the  *)
(*             next sync takes the lock under its deadline;                *)
(*   Holder    dtach -n on the host: a held job or service outlives the    *)
(*             connection and the framework. A job's wrapper on the host   *)
(*             ends what is left of the job's process group when its       *)
(*             command exits, before it reaps the command, then writes the *)
(*             exit code (or "timeout") to a file and exits; at the job's  *)
(*             timeout it ends the group.                                  *)
(*   Services  a service's forward (F-89's design, not built yet, F-91):   *)
(*             an ssh -N -L with ExitOnForwardFailure, held by dtach on    *)
(*             the workstation, started once the service's start is       *)
(*             settled; the start answers once the forward is open, and a *)
(*             forward that fails there ends the service, whose start then *)
(*             answers refused. A service's end or restart ends its        *)
(*             forward first, and sends its own end once the forward's     *)
(*             socket reads dead;                                          *)
(*   Recoveries a forward whose socket reads dead while its service runs: *)
(*             claimed (the row says reopening, durable, with the state    *)
(*             it claims: the service's start and the forward's open      *)
(*             count), then reopened once if the claim is still current;   *)
(*             a reopen that fails, or a claim a restart cut off, waits    *)
(*             for a person (the row says failed).                         *)
(*                                                                         *)
(* The forward is open when its own ssh listens on the local port (the     *)
(* listener's pid is the forward's), not when the port listens: another    *)
(* program may hold it (OpenByPort). Its ssh binds the local port without  *)
(* the service listening, so the forward need not start first. Its own ssh *)
(* drops (FwdDrops) apart from Shell's connection, and fails to connect    *)
(* while that connection is down. A dtach -n of the forward is local: a    *)
(* restart of the framework before its answer ends it held or never held.  *)
(*                                                                         *)
(* Runs are Jobs and Svcs: each job is asked once; a service is started    *)
(* once and restarted up to MaxSvcRestarts times. A run that has asked     *)
(* waits for the copy's turn, syncs, sends its start, and gives the turn   *)
(* back once the start is settled: the start's reply, or after a cut the   *)
(* host's read. A cut sync is refused at once, and gives the turn back     *)
(* once its host side can no longer take the lock. `whole` says no sync   *)
(* is writing the copy or was cut while writing since the last one         *)
(* completed. `fresh[r]` is a ghost: a sync that began after r asked has   *)
(* completed since.                                                        *)
(*                                                                         *)
(* A command in flight (`cmd` "busy") is cut by a drop ("cut") or ended by *)
(* a restart ("none"). A start or an end that was sent may land on the     *)
(* host after the cut (`inflight`), up to its deadline; past it, it never  *)
(* lands (NeverLands). That is the one assumption about time beside the    *)
(* deadline flags: the host runs a command it got within the command's     *)
(* deadline, or never. A sync's host side (`hs`) is the same kind of       *)
(* command, and the lock (`lock`) is what keeps it apart from the next.    *)
(*                                                                         *)
(* Assumed, not modeled (F-72's build note, Findings): a host does not     *)
(* restart; a wrapper killed before it writes the exit file takes the      *)
(* job's group with it; the fetch's compare of one path and its write of   *)
(* that path are one step. A service does not exit by itself. A start      *)
(* that dtach refuses is a refused answer like a cut sync, and is left     *)
(* out. The order of the wrapper's end of the group before its reap of     *)
(* the command, so a kill never reaches a reused id, is Shell.tla's.       *)
(*                                                                         *)
(* Left abstract: the files of a sync (the host's side takes the lock and  *)
(* begins writing in one step, completes in one, and a cut leaves the copy *)
(* partly synced), the log and its offset (read by the same reads), the    *)
(* job's argv, the port numbers (a forward's local port is free, its       *)
(* own, or another program's), the message an unknown answer is followed  *)
(* by, and claims (Team.tla; a forward's reopen, under one, is not cut by  *)
(* the service's end or restart). Time is a flag per job, `past`:          *)
(* its timeout has passed, at any step after its run asked; the call and   *)
(* the host's wrapper keep that one deadline. A call's own deadline is the *)
(* job's timeout, or for a service start any time; at it, with the         *)
(* connection down, the call answers unknown{dropped}, or the end it read  *)
(* with its fetch unknown (GiveUp). The lock's deadline passes at any      *)
(* step another sync's host side holds the lock. The worktree has paths,   *)
(* which the agent edits at any time (Edit), and the fetch writes back.    *)
(*                                                                         *)
(* Allowed by the design, not checked (F-70's build note, new-1): a later  *)
(* run's sync changes files under a job or service still running.          *)
(*                                                                         *)
(* Fairness: the framework's and the host's steps happen while they stay   *)
(* possible, and time passes. The connection's return, drops, the agents'  *)
(* calls and edits, a job's own exit, a wrapper killed, an owner's end,    *)
(* restarts of the framework, a forward's drop and another program taking  *)
(* its port happen or not. A forward's ssh binds or fails while it can.    *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Copy_<value>.cfg that TLC must fail.                        *)
(*                                                                         *)
(* Defense in depth, with no Break: SyncBegins' check that no command of   *)
(* the run is in flight, behind the row: a run in "asked" has sent         *)
(* nothing. EndSent's check that the socket is live, behind EndConfirmed,  *)
(* which takes a dead one first: a second kill would reach nothing of      *)
(* ours, as the kill is by the service's own pid and start time.           *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Jobs,           \* job names, each asked once
    Svcs,           \* service names
    Paths,          \* the worktree's paths
    Fetched,        \* the paths each job's run names in fetch:
    Codes,          \* the exit codes a job may end with, as strings
    MaxDrops,       \* drops of the ssh connection
    MaxRestarts,    \* restarts of the framework
    MaxEdits,       \* the agent's edits of the worktree
    MaxLost,        \* job wrappers killed on the host before they write the exit file
    MaxSvcRestarts, \* service_restart calls
    Fwds,           \* the services started with forward:, whose port is forwarded
    MaxFwdDrops,    \* drops of a forward's own ssh
    MaxFwdFails,    \* a forward's ssh that fails to connect while the connection is up
    MaxTaken,       \* another program taking a forward's local port
    Break           \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "SkipSync",             \* a run whose copy is whole from an earlier sync starts without its own
    "StartOnCut",           \* a sync that a drop cut is taken as complete
    "NoTurn",               \* a run syncs while another run's sync or start is under way
    "TurnInMemory",         \* the copy's turn is held in memory, so a restart frees it
    "SettleEarly",          \* a cut start is settled before its deadline, while it may still land
    "DropAsExit",           \* a dropped connection's ssh status (255) is answered as the job's exit
    "SocketAsExit",         \* a dead socket is read as exit 0, without the exit file
    "ReadFileFirst",        \* the exit file is read before the socket, in two reads
    "EndAtDeadline",        \* the timeout is taken as the job's end, before the host ended it
    "FetchAll",             \* the fetch copies the whole copy back, not the named paths
    "TimeoutFromFramework", \* the framework ends a job at its timeout over ssh, not the host's wrapper
    "ReadInCall",           \* a job is read only while its call waits, so a restart leaves it unread
    "NoGiveUp",             \* a call has no deadline of its own while the connection is down
    "EndOnce",              \* a service's end is marked ended when sent, without reading the host
    "EndInMemory",          \* the end of an owner's service is held in memory, so a restart loses it
    "StartBeforeEnd",       \* a restart starts the new process without the old one's end confirmed
    "FetchBlind",           \* the fetch writes a named path without checking the record
    "RecordAfterSync",      \* the record is taken once the sync completes, not before it sends
    "NoHostLock",           \* the host's side of a sync writes without the copy's lock
    "NoGroupEnd",           \* the wrapper reaps the command and leaves the rest of its group
    "CutBeforeDeadline",    \* a cut sync gives the turn back while its host side may still lock
    "ForwardEarly",         \* the forward starts before its service's start is settled
    "ServiceEndFirst",      \* the service's end is sent before its forward is read dead
    "OpenByPort",           \* a forward is taken as open when its local port listens
    "FailKeepsService",     \* a forward that fails at the start refuses the start, the service left held
    "ActWithoutCheck",      \* a reopen acts on its claim without reading that the service still runs
    "RetryFailed",          \* a reopen that failed is taken as a new loss, not sent to a person
    "ReopenInMemory",       \* a reopen is held in memory: the row still says open while it runs
    "NoReopen"              \* Recoveries does not reopen a dropped forward
}

ASSUME Break \in Breaks
ASSUME Jobs \cap Svcs = {} /\ Fetched \subseteq Paths /\ Fwds \subseteq Svcs
ASSUME "none" \notin Codes /\ "timeout" \notin Codes
ASSUME /\ MaxDrops \in Nat /\ MaxRestarts \in Nat /\ MaxEdits \in Nat /\ MaxLost \in Nat
       /\ MaxSvcRestarts \in Nat /\ MaxFwdDrops \in Nat /\ MaxFwdFails \in Nat /\ MaxTaken \in Nat

None == "none"
Runs == Jobs \cup Svcs

\* The row's states. Final: a job's end, read from the host.
Rows == {"idle", "asked", "syncing", "synced", "starting", "running", "exited", "timedout",
         "lost", "refused", "ending", "restarting", "ended"}
Final == {"exited", "timedout", "lost"}
\* What a job's exit file on the host holds.
FileVals == Codes \cup {None, "timeout"}
\* A code an answer may carry: "0" is what SocketAsExit makes up, "255" ssh's own status.
CodeVals == Codes \cup {None, "0", "255"}
\* run's answers, as "Hosts" lists them: ok, unknown{timeout}, unknown{dropped},
\* unknown{no_exit}, refused{sync}; "restart" is the MCP bridge's error, and
\* "started" a service's start. A fetch is none, done, conflict or unknown.
Kinds == {None, "ok", "timeout", "no_exit", "refused", "dropped", "restart", "started"}
Answers == [k : Kinds, code : CodeVals, fetch : {None, "done", "conflict", "unknown"}]
Say(k) == [k |-> k, code |-> None, fetch |-> None]
\* A forward as its service's row says: none yet for this start, starting,
\* open (and its local port reported), reopening under Recoveries' claim, or
\* failed, a reopen that failed, waiting for a person.
FwdRows == {None, "starting", "open", "reopening", "failed"}
\* No forward command under way, and no claim: a service's first start is gen 1.
NoCmd == 0
NoClaim == <<0, 0>>

VARIABLES
    \* The workstation, durable
    row,        \* [Runs -> Rows]
    rcode,      \* [Runs -> CodeVals]: the exit code the row read
    turn,       \* the run holding the copy's turn, or None
    owner,      \* [Svcs -> {None, "agent", "parent"}]
    keep,       \* [Svcs -> BOOLEAN]
    alive,      \* the services' owner agent has not ended
    \* The framework's memory
    call,       \* [Runs -> {None, "waiting", "fetching"}]
    cmd,        \* [Runs -> {None, "busy", "cut"}]: the run's ssh command
    rd,         \* [Runs -> {None, "dead", "nofile"} \cup Codes \cup {"timeout"}]: a read under way
    fetchLeft,  \* [Runs -> SUBSET Paths]
    skipped,    \* [Jobs -> SUBSET Paths]: the fetch's conflicts so far
    stale,      \* [Jobs -> SUBSET Paths]: paths whose worktree file is no longer what the
                \* record of j's sync says (its size, time and hash); no fetch reads it after
                \* its call ended
    \* The connection and the framework
    up,         \* the ssh connection to the host is up
    fw,         \* "up" or "down"
    \* The host
    inflight,   \* [Runs -> {None, "start", "end"}]: a command sent that may still land
    held,       \* [Runs -> 0..2]: the run's processes dtach holds (a job's is its wrapper)
    grp,        \* [Jobs -> BOOLEAN]: the job's process group has a process left
    hs,         \* [Runs -> {None, "waiting", "writing"}]: the host's side of the run's sync
    lock,       \* the run whose sync's host side holds the copy's lock, or None
    file,       \* [Runs -> FileVals]: a job's exit file
    past,       \* [Runs -> BOOLEAN]: a job's timeout has passed
    whole,      \* the copy's last sync completed and none wrote it since
    \* Counters
    drops, restarts, edits, lost, svcRestarts,
    \* Ghosts, for the properties; the framework never reads them
    answer,     \* [Runs -> Answers]: the call's last answer
    fresh,      \* [Runs -> BOOLEAN]
    cover,      \* [Runs -> SUBSET Runs]: the runs that had asked when r's sync began
    badStart,   \* runs that started on a copy not whole or not fresh for them
    fetched,    \* the fetch's writes: [r, p, ended]
    since,      \* [Jobs -> SUBSET Paths]: paths the agent edited after j's sync began
    clobbered,  \* paths a fetch wrote over such an edit
    \* A service's forward. The service's row, durable:
    gen,        \* [Svcs -> Nat]: the row's count of its starts, its pid and start time
    frow,       \* [Svcs -> FwdRows]: the forward of the current start, as the row says
    opens,      \* [Svcs -> Nat]: the forward's opens for the current start
    \* The framework's memory:
    fcmd,       \* [Svcs -> Nat]: a local dtach -n of the forward under way, and the
                \* start (the row's gen) it was sent for, or NoCmd
    facting,    \* [Svcs -> Nat \X Nat]: the loss Recoveries claimed and has not acted on, or NoClaim
    \* The workstation:
    fproc,      \* [Svcs -> {None, "pending", "bound"}]: the forward's ssh, held by dtach;
                \* "pending" until it listens on its local port
    port,       \* [Svcs -> {"free", "fwd", "other"}]: who listens on the forward's local port
    fdrops, ffails, taken,
    \* Ghosts:
    fto,        \* [Svcs -> Nat]: the start the held forward was started for
    reopened,   \* [Svcs -> SUBSET (Nat \X Nat)]: the states a reopen acted on
    twice,      \* a reopen acted on a state a reopen acted on before
    badReport   \* services whose row reported a forward open while its ssh did not hold the port

fvars == <<gen, frow, opens, fcmd, facting, fproc, port, fdrops, ffails, taken, fto, reopened,
           twice, badReport>>

vars == <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale, up, fw,
          inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
          svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered, fvars>>

TypeOK ==
    /\ row \in [Runs -> Rows]
    /\ rcode \in [Runs -> CodeVals]
    /\ turn \in Runs \cup {None}
    /\ owner \in [Svcs -> {None, "agent", "parent"}]
    /\ keep \in [Svcs -> BOOLEAN]
    /\ alive \in BOOLEAN
    /\ call \in [Runs -> {None, "waiting", "fetching"}]
    /\ cmd \in [Runs -> {None, "busy", "cut"}]
    /\ rd \in [Runs -> {None, "dead", "nofile", "timeout"} \cup Codes]
    /\ fetchLeft \in [Runs -> SUBSET Paths]
    /\ skipped \in [Jobs -> SUBSET Paths]
    /\ stale \in [Jobs -> SUBSET Paths]
    /\ up \in BOOLEAN /\ fw \in {"up", "down"}
    /\ inflight \in [Runs -> {None, "start", "end"}]
    /\ held \in [Runs -> 0..2]
    /\ grp \in [Jobs -> BOOLEAN]
    /\ hs \in [Runs -> {None, "waiting", "writing"}]
    /\ lock \in Runs \cup {None}
    /\ file \in [Runs -> FileVals]
    /\ past \in [Runs -> BOOLEAN]
    /\ whole \in BOOLEAN
    /\ answer \in [Runs -> Answers]
    /\ fresh \in [Runs -> BOOLEAN]
    /\ cover \in [Runs -> SUBSET Runs]
    /\ since \in [Jobs -> SUBSET Paths]
    /\ gen \in [Svcs -> Nat] /\ frow \in [Svcs -> FwdRows] /\ opens \in [Svcs -> Nat]
    /\ fcmd \in [Svcs -> Nat] /\ facting \in [Svcs -> Nat \X Nat]
    /\ fproc \in [Svcs -> {None, "pending", "bound"}]
    /\ port \in [Svcs -> {"free", "fwd", "other"}]
    /\ fto \in [Svcs -> Nat] /\ reopened \in [Svcs -> SUBSET (Nat \X Nat)]
    /\ twice \in BOOLEAN /\ badReport \subseteq Svcs

Init ==
    /\ row = [r \in Runs |-> "idle"]
    /\ rcode = [r \in Runs |-> None]
    /\ turn = None
    /\ owner = [s \in Svcs |-> None]
    /\ keep = [s \in Svcs |-> FALSE]
    /\ alive = TRUE
    /\ call = [r \in Runs |-> None]
    /\ cmd = [r \in Runs |-> None]
    /\ rd = [r \in Runs |-> None]
    /\ fetchLeft = [r \in Runs |-> {}]
    /\ skipped = [j \in Jobs |-> {}]
    /\ stale = [j \in Jobs |-> {}]
    /\ up = TRUE /\ fw = "up"
    /\ inflight = [r \in Runs |-> None]
    /\ held = [r \in Runs |-> 0]
    /\ grp = [j \in Jobs |-> FALSE]
    /\ hs = [r \in Runs |-> None]
    /\ lock = None
    /\ file = [r \in Runs |-> None]
    /\ past = [r \in Runs |-> FALSE]
    /\ whole = FALSE
    /\ drops = 0 /\ restarts = 0 /\ edits = 0 /\ lost = 0 /\ svcRestarts = 0
    /\ answer = [r \in Runs |-> Say(None)]
    /\ fresh = [r \in Runs |-> FALSE]
    /\ cover = [r \in Runs |-> {}]
    /\ badStart = {} /\ fetched = {}
    /\ since = [j \in Jobs |-> {}]
    /\ clobbered = {}
    /\ gen = [s \in Svcs |-> 0] /\ frow = [s \in Svcs |-> None] /\ opens = [s \in Svcs |-> 0]
    /\ fcmd = [s \in Svcs |-> NoCmd] /\ facting = [s \in Svcs |-> NoClaim]
    /\ fproc = [s \in Svcs |-> None] /\ port = [s \in Svcs |-> "free"]
    /\ fdrops = 0 /\ ffails = 0 /\ taken = 0
    /\ fto = [s \in Svcs |-> 0] /\ reopened = [s \in Svcs |-> {}]
    /\ twice = FALSE /\ badReport = {}

Link == up /\ fw = "up"

\* The turn goes back once the run's start is settled.
Release(r) == turn' = IF turn = r THEN None ELSE turn

\* A cut sync's host side can no longer take the lock: it holds it, has
\* exited, or its lock deadline has passed (HostGivesUp). The framework knows
\* the last by the time; the spec reads `hs` for it.
LockSettled(r) == hs[r] # "waiting" \/ Break = "CutBeforeDeadline"

\* A cut sync gives the turn back now, or once its host side cannot lock (TurnBack).
ReleaseCut(r) == IF LockSettled(r) THEN Release(r) ELSE UNCHANGED turn

\* An answer ends the call.
Answer(r, a) ==
    /\ answer' = [answer EXCEPT ![r] = a]
    /\ call' = [call EXCEPT ![r] = None]

\* The record of a job's named paths: from now on, a change to one is stale.
Record(r) == stale' = IF r \in Jobs THEN [stale EXCEPT ![r] = {}] ELSE stale

\* A service's end is sent once its forward's socket reads dead, with no
\* start of the forward under way.
FwdGone(s) ==
    \/ s \notin Fwds
    \/ fproc[s] = None /\ fcmd[s] = NoCmd
    \/ Break = "ServiceEndFirst"

\* The state a reopen is once per: the service's held process (the row's
\* start) and the forward's open count.
Key(s) == <<gen[s], opens[s]>>

----------------------------------------------------------------------------
\* The agent's calls

AskJob(j) ==
    /\ fw = "up" /\ row[j] = "idle"
    /\ row' = [row EXCEPT ![j] = "asked"]
    /\ call' = [call EXCEPT ![j] = "waiting"]
    /\ fresh' = [fresh EXCEPT ![j] = FALSE]
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* service_start, with keep: or without.
AskService(s) ==
    /\ fw = "up" /\ alive /\ row[s] = "idle"
    /\ row' = [row EXCEPT ![s] = "asked"]
    /\ call' = [call EXCEPT ![s] = "waiting"]
    /\ fresh' = [fresh EXCEPT ![s] = FALSE]
    /\ owner' = [owner EXCEPT ![s] = "agent"]
    /\ \E k \in BOOLEAN : keep' = [keep EXCEPT ![s] = k]
    /\ UNCHANGED <<rcode, turn, alive, cmd, rd, fetchLeft, skipped, stale, up, fw, inflight, held,
                   grp, hs, lock, file, past, whole, drops, restarts, edits, lost, svcRestarts,
                   answer, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* service_restart by its owner: the row says restarting before the end is sent.
AskRestart(s) ==
    /\ fw = "up" /\ alive /\ owner[s] = "agent" /\ row[s] = "running" /\ call[s] = None
    /\ svcRestarts < MaxSvcRestarts
    /\ row' = [row EXCEPT ![s] = IF Break = "StartBeforeEnd" THEN "asked" ELSE "restarting"]
    /\ call' = [call EXCEPT ![s] = "waiting"]
    /\ fresh' = [fresh EXCEPT ![s] = FALSE]
    /\ svcRestarts' = svcRestarts + 1
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   answer, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The agent, or a subagent, edits a path of the worktree: the file no longer
\* matches any job's record of it.
Edit(p) ==
    /\ edits < MaxEdits
    /\ edits' = edits + 1
    /\ stale' = [j \in Jobs |-> stale[j] \cup {p}]
    /\ since' = [j \in Jobs |-> since[j] \cup {p}]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered>>
    /\ UNCHANGED fvars

----------------------------------------------------------------------------
\* The sync and the start

\* The run takes the turn (written before rsync starts), records its named
\* paths, and starts rsync, whose host side first waits for the copy's lock.
SyncBegins(r) ==
    /\ Link /\ row[r] = "asked" /\ call[r] = "waiting" /\ cmd[r] = None
    /\ turn = None \/ Break = "NoTurn"
    /\ row' = [row EXCEPT ![r] = "syncing"]
    /\ turn' = r
    /\ cmd' = [cmd EXCEPT ![r] = "busy"]
    /\ hs' = [hs EXCEPT ![r] = "waiting"]
    /\ cover' = [cover EXCEPT ![r] = {q \in Runs : ~fresh[q]}]
    /\ IF Break = "RecordAfterSync" THEN UNCHANGED stale ELSE Record(r)
    /\ since' = IF r \in Jobs THEN [since EXCEPT ![r] = {}] ELSE since
    /\ UNCHANGED <<rcode, owner, keep, alive, call, rd, fetchLeft, skipped, up, fw, inflight, held,
                   grp, lock, file, past, whole, drops, restarts, edits, lost, svcRestarts, answer,
                   fresh, badStart, fetched, clobbered>>
    /\ UNCHANGED fvars

\* Under SkipSync, a copy whole from an earlier sync is taken as in step.
SyncSkipped(r) ==
    /\ Break = "SkipSync"
    /\ Link /\ row[r] = "asked" /\ call[r] = "waiting" /\ cmd[r] = None /\ turn = None /\ whole
    /\ row' = [row EXCEPT ![r] = "synced"]
    /\ turn' = r
    /\ UNCHANGED <<rcode, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The host's side takes the copy's lock and begins writing the copy. It may
\* do so after its local side ended, until it notices.
HostLocks(r) ==
    /\ hs[r] = "waiting"
    /\ lock = None \/ Break = "NoHostLock"
    /\ hs' = [hs EXCEPT ![r] = "writing"]
    /\ lock' = IF Break = "NoHostLock" THEN lock ELSE r
    /\ whole' = FALSE
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   up, fw, inflight, held, grp, file, past, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The lock's deadline passes while another sync's host side holds it: the
\* host's side exits non-zero, and the local rsync with it.
HostGivesUp(r) ==
    /\ hs[r] = "waiting" /\ lock \notin {None, r} /\ cmd[r] = "busy"
    /\ hs' = [hs EXCEPT ![r] = None]
    /\ cmd' = [cmd EXCEPT ![r] = "cut"]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, rd, fetchLeft, skipped, stale, up,
                   fw, inflight, held, grp, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* A host side whose local side ended (a drop, a restart, or its own give-up)
\* notices and exits, and the lock goes with it.
HostSideEnds(r) ==
    /\ hs[r] # None /\ cmd[r] # "busy"
    /\ hs' = [hs EXCEPT ![r] = None]
    /\ lock' = IF lock = r THEN None ELSE lock
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   up, fw, inflight, held, grp, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* rsync completed: the host's side wrote every file and exits, freeing the lock.
SyncCompletes(r) ==
    /\ row[r] = "syncing" /\ cmd[r] = "busy" /\ hs[r] = "writing"
    /\ row' = [row EXCEPT ![r] = "synced"]
    /\ cmd' = [cmd EXCEPT ![r] = None]
    /\ hs' = [hs EXCEPT ![r] = None]
    /\ lock' = IF lock = r THEN None ELSE lock
    /\ whole' = \A q \in Runs \ {r} : hs[q] # "writing"
    /\ fresh' = [q \in Runs |-> fresh[q] \/ q \in cover[r]]
    /\ IF Break = "RecordAfterSync" THEN Record(r) ELSE UNCHANGED stale
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, rd, fetchLeft, skipped, up, fw, inflight,
                   held, grp, file, past, drops, restarts, edits, lost, svcRestarts, answer, cover,
                   badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* rsync exited non-zero: the copy stays partly synced, and nothing ran. The
\* refusal is answered at once; only the turn waits for the host's side.
SyncCut(r) ==
    /\ fw = "up" /\ row[r] = "syncing" /\ cmd[r] = "cut"
    /\ cmd' = [cmd EXCEPT ![r] = None]
    /\ IF Break = "StartOnCut"
       THEN /\ row' = [row EXCEPT ![r] = "synced"]
            /\ UNCHANGED <<turn, call, answer>>
       ELSE /\ row' = [row EXCEPT ![r] = "refused"]
            /\ ReleaseCut(r)
            /\ IF call[r] = "waiting" THEN Answer(r, Say("refused"))
                                      ELSE UNCHANGED <<call, answer>>
    /\ UNCHANGED <<rcode, owner, keep, alive, rd, fetchLeft, skipped, stale, up, fw, inflight, held,
                   grp, hs, lock, file, past, whole, drops, restarts, edits, lost, svcRestarts,
                   fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The start's row is written, then `ssh host dtach -n …` is sent.
StartSent(r) ==
    /\ Link /\ row[r] = "synced" /\ call[r] = "waiting" /\ cmd[r] = None
    /\ row' = [row EXCEPT ![r] = "starting"]
    /\ cmd' = [cmd EXCEPT ![r] = "busy"]
    /\ inflight' = [inflight EXCEPT ![r] = "start"]
    /\ IF r \in Fwds
       THEN /\ gen' = [gen EXCEPT ![r] = gen[r] + 1]
            /\ frow' = [frow EXCEPT ![r] = None]
            /\ opens' = [opens EXCEPT ![r] = 0]
       ELSE UNCHANGED <<gen, frow, opens>>
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, rd, fetchLeft, skipped, stale, up, fw,
                   held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED <<fcmd, facting, fproc, port, fdrops, ffails, taken, fto, reopened, twice,
                   badReport>>

\* The host runs a command it got: a start holds a process (a job's command
\* in a process group of its own), an end kills one.
Lands(r) ==
    /\ inflight[r] # None
    /\ inflight' = [inflight EXCEPT ![r] = None]
    /\ IF inflight[r] = "start"
       THEN /\ held' = [held EXCEPT ![r] = held[r] + 1]
            /\ grp' = IF r \in Jobs THEN [grp EXCEPT ![r] = TRUE] ELSE grp
            /\ badStart' = IF whole /\ fresh[r] THEN badStart ELSE badStart \cup {r}
       ELSE /\ held' = [held EXCEPT ![r] = IF held[r] > 0 THEN held[r] - 1 ELSE 0]
            /\ UNCHANGED <<grp, badStart>>
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   up, fw, hs, lock, file, past, whole, drops, restarts, edits, lost, svcRestarts,
                   answer, fresh, cover, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* A command cut before the host ran it, past its deadline, never runs.
NeverLands(r) ==
    /\ inflight[r] # None /\ cmd[r] # "busy"
    /\ inflight' = [inflight EXCEPT ![r] = None]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   up, fw, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* dtach -n answered 0 over the connection: the process is held.
StartReplies(r) ==
    /\ fw = "up" /\ row[r] = "starting" /\ cmd[r] = "busy" /\ inflight[r] = None
    /\ row' = [row EXCEPT ![r] = "running"]
    /\ cmd' = [cmd EXCEPT ![r] = None]
    /\ Release(r)
    /\ IF r \in Svcs \ Fwds /\ call[r] = "waiting" THEN Answer(r, Say("started"))
                                            ELSE UNCHANGED <<call, answer>>
    /\ UNCHANGED <<rcode, owner, keep, alive, rd, fetchLeft, skipped, stale, up, fw, inflight, held,
                   grp, hs, lock, file, past, whole, drops, restarts, edits, lost, svcRestarts,
                   fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* A cut command whose deadline passed: the framework may act on its row again.
CutCleared(r) ==
    /\ fw = "up" /\ cmd[r] = "cut" /\ inflight[r] = None
    /\ row[r] # "syncing" /\ call[r] # "fetching"
    /\ cmd' = [cmd EXCEPT ![r] = None]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, rd, fetchLeft, skipped, stale, up,
                   fw, inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits,
                   lost, svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* A start whose reply a drop or a restart cut is settled by reading the host,
\* once its deadline has passed: held, or never started.
SettleStarting(r) ==
    /\ Link /\ row[r] = "starting" /\ cmd[r] = None
    /\ inflight[r] = None \/ Break = "SettleEarly"
    /\ Break = "ReadInCall" => call[r] # None
    /\ LET ran == held[r] > 0 \/ file[r] # None
       IN /\ row' = [row EXCEPT ![r] = IF ran THEN "running" ELSE "refused"]
          /\ IF call[r] = "waiting" /\ ~ran THEN Answer(r, Say("refused"))
             ELSE IF call[r] = "waiting" /\ r \in Svcs \ Fwds THEN Answer(r, Say("started"))
             ELSE UNCHANGED <<call, answer>>
    /\ Release(r)
    /\ UNCHANGED <<rcode, owner, keep, alive, cmd, rd, fetchLeft, skipped, stale, up, fw, inflight,
                   held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* A row before its start whose call ended (a restart, or a give-up) is
\* refused; a sync a restart cut gives the turn back as SyncCut does.
SettleUnasked(r) ==
    /\ fw = "up" /\ call[r] = None /\ cmd[r] = None
    /\ row[r] \in {"asked", "syncing", "synced"}
    /\ row' = [row EXCEPT ![r] = "refused"]
    /\ ReleaseCut(r)
    /\ UNCHANGED <<rcode, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* A refused run still holding the turn gives it back once its sync's host
\* side can no longer take the lock.
TurnBack(r) ==
    /\ fw = "up" /\ turn = r /\ row[r] = "refused" /\ hs[r] # "waiting"
    /\ Release(r)
    /\ UNCHANGED <<row, rcode, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

----------------------------------------------------------------------------
\* A job on the host

Tick(j) ==
    /\ ~past[j] /\ (row[j] \in {"starting", "running"} \/ held[j] > 0 \/ call[j] # None)
    /\ past' = [past EXCEPT ![j] = TRUE]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   up, fw, inflight, held, grp, hs, lock, file, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The command exits, leaving a child in its group or not. Its wrapper ends
\* what is left of the group before it reaps the command, writes the code,
\* then exits, and dtach removes the socket. Under NoGroupEnd a child lives on.
JobExits(j, c) ==
    /\ held[j] > 0
    /\ held' = [held EXCEPT ![j] = 0]
    /\ grp' = IF Break = "NoGroupEnd" THEN grp ELSE [grp EXCEPT ![j] = FALSE]
    /\ file' = [file EXCEPT ![j] = c]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   up, fw, inflight, hs, lock, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The wrapper on the host ends the job's group at its timeout and writes "timeout".
HostTimesOut(j) ==
    /\ Break # "TimeoutFromFramework"
    /\ past[j] /\ held[j] > 0
    /\ held' = [held EXCEPT ![j] = 0]
    /\ grp' = [grp EXCEPT ![j] = FALSE]
    /\ file' = [file EXCEPT ![j] = "timeout"]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   up, fw, inflight, hs, lock, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* Under TimeoutFromFramework, the framework sends the end over ssh instead.
FrameworkTimesOut(j) ==
    /\ Break = "TimeoutFromFramework"
    /\ Link /\ past[j] /\ held[j] > 0
    /\ held' = [held EXCEPT ![j] = 0]
    /\ grp' = [grp EXCEPT ![j] = FALSE]
    /\ file' = [file EXCEPT ![j] = "timeout"]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   up, fw, inflight, hs, lock, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The wrapper is killed on the host before it writes the exit file; its
\* group goes with it (assumed: F-72's build note).
WrapperLost(j) ==
    /\ held[j] > 0 /\ lost < MaxLost
    /\ held' = [held EXCEPT ![j] = 0]
    /\ grp' = [grp EXCEPT ![j] = FALSE]
    /\ lost' = lost + 1
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   up, fw, inflight, hs, lock, file, past, whole, drops, restarts, edits,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The row a read of the exit file makes.
Ended(j, v) ==
    /\ row' = [row EXCEPT ![j] = CASE v = "timeout" -> "timedout"
                                   [] v \in {None, "nofile"} -> "lost"
                                   [] OTHER -> "exited"]
    /\ rcode' = [rcode EXCEPT ![j] = IF v \in Codes THEN v ELSE None]

ReadCan(j) ==
    /\ Link /\ j \in Jobs /\ row[j] = "running" /\ cmd[j] = None
    /\ Break = "ReadInCall" => call[j] # None

\* The socket read dead (a live one changes nothing). The file is written
\* before the socket goes, so it is read after.
ReadSocket(j) ==
    /\ ReadCan(j) /\ Break # "ReadFileFirst" /\ rd[j] = None /\ held[j] = 0
    /\ IF Break = "SocketAsExit"
       THEN /\ row' = [row EXCEPT ![j] = "exited"]
            /\ rcode' = [rcode EXCEPT ![j] = "0"]
            /\ UNCHANGED rd
       ELSE /\ rd' = [rd EXCEPT ![j] = "dead"]
            /\ UNCHANGED <<row, rcode>>
    /\ UNCHANGED <<turn, owner, keep, alive, call, cmd, fetchLeft, skipped, stale, up, fw, inflight,
                   held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

ReadFile(j) ==
    /\ ReadCan(j) /\ rd[j] = "dead"
    /\ Ended(j, file[j])
    /\ rd' = [rd EXCEPT ![j] = None]
    /\ UNCHANGED <<turn, owner, keep, alive, call, cmd, fetchLeft, skipped, stale, up, fw, inflight,
                   held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* Under ReadFileFirst: the file first, kept in memory, then the socket.
ReadFileEarly(j) ==
    /\ Break = "ReadFileFirst" /\ ReadCan(j) /\ rd[j] = None
    /\ rd' = [rd EXCEPT ![j] = IF file[j] = None THEN "nofile" ELSE file[j]]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, fetchLeft, skipped, stale, up,
                   fw, inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits,
                   lost, svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

ReadSocketLate(j) ==
    /\ Break = "ReadFileFirst" /\ ReadCan(j) /\ rd[j] \notin {None, "dead"}
    /\ IF held[j] = 0 THEN Ended(j, rd[j]) ELSE UNCHANGED <<row, rcode>>
    /\ rd' = [rd EXCEPT ![j] = None]
    /\ UNCHANGED <<turn, owner, keep, alive, call, cmd, fetchLeft, skipped, stale, up, fw, inflight,
                   held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* Under EndAtDeadline, the framework takes the timeout as the job's end.
DeadlineTaken(j) ==
    /\ Break = "EndAtDeadline"
    /\ fw = "up" /\ j \in Jobs /\ row[j] = "running" /\ past[j]
    /\ row' = [row EXCEPT ![j] = "timedout"]
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale, up,
                   fw, inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits,
                   lost, svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* What the call answers for a job's end, with the fetch's outcome.
EndAnswer(j, f) ==
    [k |-> CASE row[j] = "exited" -> "ok" [] row[j] = "timedout" -> "timeout"
                [] OTHER -> "no_exit",
     code |-> rcode[j], fetch |-> f]

\* No fetch: the call answers the end it read.
AnswerJob(j) ==
    /\ fw = "up" /\ j \in Jobs /\ call[j] = "waiting" /\ row[j] \in Final
    /\ Fetched = {} \/ row[j] = "lost"
    /\ Answer(j, EndAnswer(j, None))
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* rsync of the named paths, from the copy into the worktree, after the end was read.
FetchBegins(j) ==
    /\ Link /\ j \in Jobs /\ call[j] = "waiting" /\ cmd[j] = None
    /\ row[j] \in {"exited", "timedout"} /\ Fetched # {}
    /\ call' = [call EXCEPT ![j] = "fetching"]
    /\ cmd' = [cmd EXCEPT ![j] = "busy"]
    /\ fetchLeft' = [fetchLeft EXCEPT ![j] = IF Break = "FetchAll" THEN Paths ELSE Fetched]
    /\ skipped' = [skipped EXCEPT ![j] = {}]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, rd, stale, up, fw, inflight, held, grp, hs,
                   lock, file, past, whole, drops, restarts, edits, lost, svcRestarts, answer,
                   fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* One path: written into the worktree (rsync writes it whole, then renames it)
\* if the worktree's file is still what the record says, or else a conflict,
\* and the copy's version stays on the host. A write changes the file under
\* every other job's record.
FetchPath(j, p) ==
    /\ call[j] = "fetching" /\ cmd[j] = "busy" /\ p \in fetchLeft[j]
    /\ fetchLeft' = [fetchLeft EXCEPT ![j] = fetchLeft[j] \ {p}]
    /\ IF p \in stale[j] /\ Break # "FetchBlind"
       THEN /\ skipped' = [skipped EXCEPT ![j] = skipped[j] \cup {p}]
            /\ UNCHANGED <<stale, fetched, clobbered>>
       ELSE /\ fetched' = fetched \cup {[r |-> j, p |-> p, ended |-> held[j] = 0 /\ ~grp[j]]}
            /\ clobbered' = IF p \in since[j] THEN clobbered \cup {p} ELSE clobbered
            /\ stale' = [q \in Jobs |-> IF q = j THEN stale[q] ELSE stale[q] \cup {p}]
            /\ UNCHANGED skipped
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, up, fw, inflight, held, grp,
                   hs, lock, file, past, whole, drops, restarts, edits, lost, svcRestarts, answer,
                   fresh, cover, badStart, since>>
    /\ UNCHANGED fvars

FetchDone(j) ==
    /\ call[j] = "fetching" /\ cmd[j] = "busy" /\ fetchLeft[j] = {}
    /\ Answer(j, EndAnswer(j, IF skipped[j] = {} THEN "done" ELSE "conflict"))
    /\ cmd' = [cmd EXCEPT ![j] = None]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* A drop cut the fetch: the end is answered, and the fetch as unknown.
FetchCut(j) ==
    /\ fw = "up" /\ call[j] = "fetching" /\ cmd[j] = "cut"
    /\ Answer(j, EndAnswer(j, "unknown"))
    /\ cmd' = [cmd EXCEPT ![j] = None]
    /\ fetchLeft' = [fetchLeft EXCEPT ![j] = {}]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, rd, skipped, stale, up, fw, inflight, held,
                   grp, hs, lock, file, past, whole, drops, restarts, edits, lost, svcRestarts,
                   fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The call's deadline with the connection down: unknown{dropped}, or the end
\* already read with its fetch unknown. A job's call waits for its timeout; one
\* that has not started its run may give up at any time.
GiveUp(r) ==
    /\ Break # "NoGiveUp"
    /\ fw = "up" /\ ~up /\ call[r] = "waiting"
    /\ r \in Svcs \/ past[r] \/ row[r] \in {"asked", "syncing", "synced"}
    /\ Answer(r, IF r \in Jobs /\ row[r] \in Final THEN EndAnswer(r, "unknown")
                 ELSE IF Break = "DropAsExit" /\ r \in Jobs
                 THEN [k |-> "ok", code |-> "255", fetch |-> None]
                 ELSE Say("dropped"))
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

----------------------------------------------------------------------------
\* A service's end

\* The agent that owns the services ends (Sessions' row, durable).
OwnerEnds ==
    /\ Svcs # {} /\ alive
    /\ alive' = FALSE
    /\ UNCHANGED <<row, rcode, turn, owner, keep, call, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* Services reads the owner's end: a kept service goes to the owner's parent,
\* and any other is ended. One whose start is under way is taken once settled.
OwnerSeen(s) ==
    /\ fw = "up" /\ ~alive /\ owner[s] = "agent"
    /\ row[s] \in {"running", "restarting", "refused"}
    /\ IF keep[s]
       THEN /\ owner' = [owner EXCEPT ![s] = "parent"]
            /\ UNCHANGED row
       ELSE /\ owner' = [owner EXCEPT ![s] = None]
            /\ row' = [row EXCEPT ![s] = IF row[s] = "refused" THEN "refused" ELSE "ending"]
    /\ UNCHANGED <<rcode, turn, keep, alive, call, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The end over ssh: the service's process, by its pid and start time, read
\* live on the host. Under EndOnce the row is marked ended as it is sent.
EndSent(s) ==
    /\ Link /\ row[s] \in {"ending", "restarting"} /\ cmd[s] = None /\ inflight[s] = None
    /\ held[s] > 0 /\ FwdGone(s)
    /\ cmd' = [cmd EXCEPT ![s] = "busy"]
    /\ inflight' = [inflight EXCEPT ![s] = "end"]
    /\ row' = IF Break = "EndOnce" /\ row[s] = "ending" THEN [row EXCEPT ![s] = "ended"] ELSE row
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, rd, fetchLeft, skipped, stale, up, fw,
                   held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* After an end, a restart's row is asked again, and goes for the turn.
AfterEnd(s) == row' = [row EXCEPT ![s] = CASE row[s] = "restarting" -> "asked"
                                           [] row[s] = "ending" -> "ended"
                                           [] OTHER -> row[s]]

\* The end's reply: the process is gone and its socket with it.
EndReplies(s) ==
    /\ fw = "up" /\ s \in Svcs /\ cmd[s] = "busy" /\ inflight[s] = None
    /\ row[s] \in {"ending", "restarting", "ended"}
    /\ cmd' = [cmd EXCEPT ![s] = None]
    /\ AfterEnd(s)
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* With no command in flight, a socket read dead confirms the end: after a
\* cut end, after a restart, or when the process was gone already.
EndConfirmed(s) ==
    /\ Link /\ row[s] \in {"ending", "restarting"} /\ cmd[s] = None /\ inflight[s] = None
    /\ held[s] = 0 /\ FwdGone(s)
    /\ AfterEnd(s)
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale, up,
                   fw, inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits,
                   lost, svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* A restart call whose service the owner's end ended answers refused.
EndedCallAnswered(s) ==
    /\ fw = "up" /\ s \in Svcs /\ call[s] = "waiting" /\ row[s] = "ended"
    /\ Answer(s, Say("refused"))
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

----------------------------------------------------------------------------
\* A service's forward, on the workstation: ssh -N -L held by dtach

FwdOthers == <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale, up,
               fw, inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
               svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>

\* Once the service's start is settled, the row says starting, then the
\* forward's dtach -n runs on the workstation.
FwdStartSent(s) ==
    /\ fw = "up" /\ s \in Fwds /\ frow[s] = None /\ fcmd[s] = NoCmd /\ fproc[s] = None
    /\ row[s] = "running" \/ (Break = "ForwardEarly" /\ row[s] = "starting")
    /\ frow' = [frow EXCEPT ![s] = "starting"]
    /\ fcmd' = [fcmd EXCEPT ![s] = gen[s]]
    /\ UNCHANGED FwdOthers
    /\ UNCHANGED <<gen, opens, facting, fproc, port, fdrops, ffails, taken, fto, reopened, twice,
                   badReport>>

\* dtach -n answered: the ssh is held, not yet listening. A restart of the
\* framework before this step ends the local dtach -n, which then never holds.
FwdLands(s) ==
    /\ fcmd[s] # NoCmd
    /\ fcmd' = [fcmd EXCEPT ![s] = NoCmd]
    /\ fproc' = [fproc EXCEPT ![s] = "pending"]
    /\ fto' = [fto EXCEPT ![s] = fcmd[s]]
    /\ UNCHANGED FwdOthers
    /\ UNCHANGED <<gen, frow, opens, facting, port, fdrops, ffails, taken, reopened, twice,
                   badReport>>

\* The ssh connects and listens on the local port, if it is free.
SshBinds(s) ==
    /\ fproc[s] = "pending" /\ port[s] = "free" /\ up
    /\ fproc' = [fproc EXCEPT ![s] = "bound"]
    /\ port' = [port EXCEPT ![s] = "fwd"]
    /\ UNCHANGED FwdOthers
    /\ UNCHANGED <<gen, frow, opens, fcmd, facting, fdrops, ffails, taken, fto, reopened, twice,
                   badReport>>

\* With ExitOnForwardFailure the ssh exits when the port is taken, and ssh
\* exits when it cannot connect; dtach's socket goes with it.
SshFails(s) ==
    /\ fproc[s] = "pending"
    /\ port[s] # "free" \/ ~up \/ ffails < MaxFwdFails
    /\ fproc' = [fproc EXCEPT ![s] = None]
    /\ ffails' = IF port[s] = "free" /\ up THEN ffails + 1 ELSE ffails
    /\ UNCHANGED FwdOthers
    /\ UNCHANGED <<gen, frow, opens, fcmd, facting, port, fdrops, taken, fto, reopened, twice,
                   badReport>>

\* The forward's own ssh drops, at any time.
FwdDrops(s) ==
    /\ fproc[s] = "bound" /\ fdrops < MaxFwdDrops
    /\ fproc' = [fproc EXCEPT ![s] = None]
    /\ port' = [port EXCEPT ![s] = "free"]
    /\ fdrops' = fdrops + 1
    /\ UNCHANGED FwdOthers
    /\ UNCHANGED <<gen, frow, opens, fcmd, facting, ffails, taken, fto, reopened, twice, badReport>>

\* Another program on the workstation takes the local port while it is free.
OtherTakes(s) ==
    /\ s \in Fwds /\ port[s] = "free" /\ taken < MaxTaken
    /\ port' = [port EXCEPT ![s] = "other"]
    /\ taken' = taken + 1
    /\ UNCHANGED FwdOthers
    /\ UNCHANGED <<gen, frow, opens, fcmd, facting, fproc, fdrops, ffails, fto, reopened, twice,
                   badReport>>

\* Is the forward open, as the framework reads it: its own ssh listens on the
\* local port (the listener's pid is the forward's). Under OpenByPort, any
\* listener on the port.
FwdReadsOpen(s) ==
    IF Break = "OpenByPort" THEN fproc[s] # None /\ port[s] # "free" ELSE fproc[s] = "bound"

\* The framework reads a forward's start or reopen: open, and the row
\* reports the local port; or its socket dead. A start whose forward failed
\* ends the service, and its call answers refused once it is ended
\* (EndedCallAnswered). A reopen that failed waits for a person.
FwdSettles(s) ==
    /\ fw = "up" /\ s \in Fwds /\ row[s] = "running"
    /\ frow[s] \in {"starting", "reopening"} /\ fcmd[s] = NoCmd /\ facting[s] = NoClaim
    /\ FwdReadsOpen(s) \/ fproc[s] = None
    /\ IF FwdReadsOpen(s)
       THEN /\ frow' = [frow EXCEPT ![s] = "open"]
            /\ opens' = [opens EXCEPT ![s] = opens[s] + 1]
            /\ badReport' = IF port[s] = "fwd" /\ fproc[s] = "bound" THEN badReport
                            ELSE badReport \cup {s}
            /\ IF frow[s] = "starting" /\ call[s] = "waiting" THEN Answer(s, Say("started"))
                                                              ELSE UNCHANGED <<call, answer>>
            /\ UNCHANGED row
       ELSE /\ UNCHANGED <<opens, badReport>>
            /\ IF frow[s] = "reopening"
               THEN /\ frow' = [frow EXCEPT ![s] = IF Break = "RetryFailed" THEN "open"
                                                                       ELSE "failed"]
                    /\ UNCHANGED <<row, call, answer>>
               ELSE IF Break = "FailKeepsService"
               THEN /\ row' = [row EXCEPT ![s] = "refused"]
                    /\ frow' = [frow EXCEPT ![s] = None]
                    /\ IF call[s] = "waiting" THEN Answer(s, Say("refused"))
                                              ELSE UNCHANGED <<call, answer>>
               ELSE /\ row' = [row EXCEPT ![s] = "ending"]
                    /\ UNCHANGED <<frow, call, answer>>
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, skipped, stale, up, fw,
                   inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits, lost,
                   svcRestarts, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED <<gen, fcmd, facting, fproc, port, fdrops, ffails, taken, fto, reopened, twice>>

\* A forward whose socket reads dead while its service runs and its row says
\* open is a loss. Recoveries claims it: the row says reopening, durable,
\* before it acts. Under ReopenInMemory only Recoveries' memory says so.
FwdLost(s) == s \in Fwds /\ row[s] = "running" /\ frow[s] = "open" /\ fproc[s] = None

FwdLossClaimed(s) ==
    /\ Break # "NoReopen"
    /\ fw = "up" /\ FwdLost(s) /\ fcmd[s] = NoCmd /\ facting[s] = NoClaim
    /\ facting' = [facting EXCEPT ![s] = Key(s)]
    /\ frow' = IF Break = "ReopenInMemory" THEN frow ELSE [frow EXCEPT ![s] = "reopening"]
    /\ UNCHANGED FwdOthers
    /\ UNCHANGED <<gen, opens, fcmd, fproc, port, fdrops, ffails, taken, fto, reopened, twice,
                   badReport>>

\* The claim is still current: the row runs the start it was claimed for,
\* with the same open count. Under ActWithoutCheck, only that the row runs:
\* a claim made before a restart of the service then acts on the new start.
ClaimCurrent(s) ==
    /\ row[s] = "running"
    /\ facting[s] = Key(s) \/ Break = "ActWithoutCheck"

\* The act, under its claim, reads the claim still current and runs dtach -n.
FwdReopens(s) ==
    /\ fw = "up" /\ facting[s] # NoClaim /\ ClaimCurrent(s)
    /\ facting' = [facting EXCEPT ![s] = NoClaim]
    /\ fcmd' = [fcmd EXCEPT ![s] = facting[s][1]]
    /\ reopened' = [reopened EXCEPT ![s] = reopened[s] \cup {facting[s]}]
    /\ twice' = (twice \/ facting[s] \in reopened[s])
    /\ UNCHANGED FwdOthers
    /\ UNCHANGED <<gen, frow, opens, fproc, port, fdrops, ffails, taken, fto, badReport>>

\* The act reads the claim no longer current (the service ended or
\* restarted): it does nothing. The row's next start clears the reopening
\* (StartSent).
FwdReopenMoot(s) ==
    /\ fw = "up" /\ facting[s] # NoClaim /\ ~ClaimCurrent(s)
    /\ facting' = [facting EXCEPT ![s] = NoClaim]
    /\ UNCHANGED FwdOthers
    /\ UNCHANGED <<gen, frow, opens, fcmd, fproc, port, fdrops, ffails, taken, fto, reopened,
                   twice, badReport>>

\* The service's end, or its restart, ends its forward first: by the
\* forward's pid and start time, on the workstation.
FwdEnd(s) ==
    /\ fw = "up" /\ s \in Fwds /\ row[s] \in {"ending", "restarting"}
    /\ fproc[s] # None /\ fcmd[s] = NoCmd
    /\ fproc' = [fproc EXCEPT ![s] = None]
    /\ port' = [port EXCEPT ![s] = IF port[s] = "fwd" THEN "free" ELSE port[s]]
    /\ UNCHANGED FwdOthers
    /\ UNCHANGED <<gen, frow, opens, fcmd, facting, fdrops, ffails, taken, fto, reopened, twice,
                   badReport>>

----------------------------------------------------------------------------
\* The connection and the framework

Drop ==
    /\ up /\ drops < MaxDrops
    /\ up' = FALSE
    /\ cmd' = [r \in Runs |-> IF cmd[r] = "busy" THEN "cut" ELSE cmd[r]]
    /\ drops' = drops + 1
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, rd, fetchLeft, skipped, stale, fw,
                   inflight, held, grp, hs, lock, file, past, whole, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

Reconnect ==
    /\ fw = "up" /\ ~up
    /\ up' = TRUE
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   fw, inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits,
                   lost, svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

\* The framework's node dies: its memory, its calls (each agent's MCP bridge
\* answers its call with an error) and its connection go; the reaper ends the
\* local rsync. Tables, the host (a sync's host side among it) and what is in
\* flight to it stay.
FrameworkDies ==
    /\ fw = "up" /\ restarts < MaxRestarts
    /\ fw' = "down" /\ up' = FALSE
    /\ restarts' = restarts + 1
    /\ cmd' = [r \in Runs |-> None]
    /\ rd' = [r \in Runs |-> None]
    /\ fetchLeft' = [r \in Runs |-> {}]
    /\ skipped' = [j \in Jobs |-> {}]
    /\ call' = [r \in Runs |-> None]
    /\ answer' = [r \in Runs |-> IF call[r] # None THEN Say("restart") ELSE answer[r]]
    /\ turn' = IF Break = "TurnInMemory" THEN None ELSE turn
    /\ row' = IF Break = "EndInMemory"
              THEN [r \in Runs |-> IF row[r] = "ending" THEN "running" ELSE row[r]]
              ELSE row
    /\ fcmd' = [s \in Svcs |-> NoCmd]
    /\ facting' = [s \in Svcs |-> NoClaim]
    /\ UNCHANGED <<rcode, owner, keep, alive, stale, inflight, held, grp, hs, lock, file, past,
                   whole, drops, edits, lost, svcRestarts, fresh, cover, badStart, fetched, since,
                   clobbered>>
    /\ UNCHANGED <<gen, frow, opens, fproc, port, fdrops, ffails, taken, fto, reopened, twice,
                   badReport>>

FrameworkStarts ==
    /\ fw = "down"
    /\ fw' = "up"
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, skipped, stale,
                   up, inflight, held, grp, hs, lock, file, past, whole, drops, restarts, edits,
                   lost, svcRestarts, answer, fresh, cover, badStart, fetched, since, clobbered>>
    /\ UNCHANGED fvars

----------------------------------------------------------------------------

Next ==
    \/ \E j \in Jobs : AskJob(j)
    \/ \E s \in Svcs : AskService(s) \/ AskRestart(s)
    \/ \E p \in Paths : Edit(p)
    \/ \E r \in Runs :
        \/ SyncBegins(r) \/ SyncSkipped(r) \/ SyncCompletes(r) \/ SyncCut(r)
        \/ HostLocks(r) \/ HostGivesUp(r) \/ HostSideEnds(r)
        \/ StartSent(r) \/ Lands(r) \/ NeverLands(r) \/ StartReplies(r) \/ CutCleared(r)
        \/ SettleStarting(r) \/ SettleUnasked(r) \/ TurnBack(r) \/ GiveUp(r)
    \/ \E j \in Jobs :
        \/ Tick(j) \/ HostTimesOut(j) \/ FrameworkTimesOut(j) \/ WrapperLost(j)
        \/ \E c \in Codes : JobExits(j, c)
        \/ ReadSocket(j) \/ ReadFile(j) \/ ReadFileEarly(j) \/ ReadSocketLate(j)
        \/ DeadlineTaken(j)
        \/ AnswerJob(j) \/ FetchBegins(j) \/ FetchDone(j) \/ FetchCut(j)
        \/ \E p \in Paths : FetchPath(j, p)
    \/ OwnerEnds
    \/ \E s \in Svcs : OwnerSeen(s) \/ EndSent(s) \/ EndReplies(s) \/ EndConfirmed(s)
                     \/ EndedCallAnswered(s)
    \/ \E s \in Svcs :
        \/ FwdStartSent(s) \/ FwdLands(s) \/ SshBinds(s) \/ SshFails(s) \/ FwdDrops(s)
        \/ OtherTakes(s) \/ FwdSettles(s) \/ FwdLossClaimed(s) \/ FwdReopens(s)
        \/ FwdReopenMoot(s) \/ FwdEnd(s)
    \/ Drop \/ Reconnect \/ FrameworkDies \/ FrameworkStarts

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A r \in Runs :
         /\ WF_vars(SyncBegins(r)) /\ WF_vars(SyncSkipped(r)) /\ WF_vars(SyncCompletes(r))
         /\ WF_vars(SyncCut(r)) /\ WF_vars(HostLocks(r)) /\ WF_vars(HostGivesUp(r))
         /\ WF_vars(HostSideEnds(r)) /\ WF_vars(StartSent(r)) /\ WF_vars(Lands(r))
         /\ WF_vars(NeverLands(r)) /\ WF_vars(StartReplies(r)) /\ WF_vars(CutCleared(r))
         /\ WF_vars(SettleStarting(r)) /\ WF_vars(SettleUnasked(r)) /\ WF_vars(TurnBack(r))
         /\ WF_vars(GiveUp(r))
    /\ \A j \in Jobs :
         /\ WF_vars(Tick(j)) /\ WF_vars(HostTimesOut(j)) /\ WF_vars(FrameworkTimesOut(j))
         /\ WF_vars(ReadSocket(j)) /\ WF_vars(ReadFile(j))
         /\ WF_vars(ReadFileEarly(j)) /\ WF_vars(ReadSocketLate(j)) /\ WF_vars(DeadlineTaken(j))
         /\ WF_vars(AnswerJob(j)) /\ WF_vars(FetchBegins(j)) /\ WF_vars(FetchDone(j))
         /\ WF_vars(FetchCut(j)) /\ \A p \in Paths : WF_vars(FetchPath(j, p))
    /\ \A s \in Svcs :
         /\ WF_vars(OwnerSeen(s)) /\ WF_vars(EndSent(s)) /\ WF_vars(EndReplies(s))
         /\ WF_vars(EndConfirmed(s)) /\ WF_vars(EndedCallAnswered(s))
         /\ WF_vars(FwdStartSent(s)) /\ WF_vars(FwdLands(s)) /\ WF_vars(SshBinds(s))
         /\ WF_vars(SshFails(s)) /\ WF_vars(FwdSettles(s)) /\ WF_vars(FwdLossClaimed(s))
         /\ WF_vars(FwdReopens(s)) /\ WF_vars(FwdReopenMoot(s)) /\ WF_vars(FwdEnd(s))

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
\* Safety

\* A job or service starts only on a copy whose last sync completed after the
\* run asked, and that no sync has written since.
StartsOnSyncedCopy == badStart = {}

\* The copy is written by one sync at a time, counting the host's side of a
\* sync whose local side a drop or a restart ended.
OneSyncWrites == Cardinality({r \in Runs : hs[r] = "writing"}) <= 1

\* Every held process is one the framework tracks under a live row.
NoUntrackedProcess ==
    \A r \in Runs : held[r] > 0 => row[r] \in {"starting", "running", "ending", "restarting"}

\* An answer or a row says only what the host holds: ok carries the job's own
\* exit code, timeout comes once the host ended the job at its timeout, and
\* no_exit once the job is gone with no exit file. Nothing else answers an end.
AnswerIsReal ==
    \A j \in Jobs :
        /\ answer[j].k = "ok" => row[j] = "exited" /\ answer[j].code = file[j]
        /\ answer[j].k = "timeout" => held[j] = 0 /\ file[j] = "timeout"
        /\ answer[j].k = "no_exit" => held[j] = 0 /\ file[j] = None
        /\ row[j] = "exited" => held[j] = 0 /\ rcode[j] = file[j]
        /\ row[j] = "timedout" => held[j] = 0 /\ file[j] = "timeout"
        /\ row[j] = "lost" => held[j] = 0 /\ file[j] = None

\* Nothing of a job is left to write in the copy once its end is read: no
\* child its command left in the group runs during the fetch or after.
JobGoneAtEnd == \A j \in Jobs : row[j] \in Final => ~grp[j]

\* A fetch writes only the paths its run named, and only after its job ended.
FetchOnlyNamed == \A f \in fetched : f.p \in Fetched
FetchOnlyAfterEnd == \A f \in fetched : f.ended

\* No edit is lost: a fetch never writes a path the agent edited after the
\* job's sync began. A sync is not a snapshot, so such an edit may not have
\* reached the copy; the spec counts it as not sent.
NoEditLost == clobbered = {}

\* A service has at most one process, and an ended row has none.
OneProcess == \A r \in Runs : held[r] <= 1
EndedIsEnded == \A s \in Svcs : row[s] = "ended" => held[s] = 0

\* A forward is held only while its service's current start is: started
\* for it, and its process still held on the host.
ForwardOnlyToCurrent ==
    \A s \in Fwds : fproc[s] # None => held[s] > 0 /\ fto[s] = gen[s]

\* No forward outlives its service: once the service's end is done, or its
\* start refused, its forward is ended too.
ForwardEndsWithService ==
    \A s \in Fwds : row[s] \in {"ended", "refused"} => fproc[s] = None

\* The local port a row reports is one its forward's own ssh held when the
\* row said open.
PortIsTheForwards == badReport = {}

\* A dropped forward is reopened at most once per state: the service's held
\* process and the forward's open count. A reopen that failed waits for a
\* person, and is not acted on again.
OneReopenPerState == ~twice

\* Liveness

\* A running service whose forward dropped gets one reopen: its forward is
\* held again, or the reopen failed and waits for a person, unless the
\* service stops running first.
ForwardReopened ==
    \A s \in Fwds : FwdLost(s) ~> (fproc[s] # None \/ row[s] # "running" \/ frow[s] = "failed")

\* Every call is answered: with the host's answer, or unknown at its deadline.
RunAnswered == \A r \in Runs : call[r] # None ~> call[r] = None

\* A job is never left running past its timeout, whatever the connection does.
JobEndsAtTimeout == \A j \in Jobs : (past[j] /\ held[j] > 0) ~> held[j] = 0

\* Once the connection comes back for good, every job's row gets its real end
\* from the host, across restarts and calls that answered unknown.
ConnectionReturns == <>[]up
JobSettles ==
    ConnectionReturns =>
        \A j \in Jobs : row[j] \in {"starting", "running"} ~> row[j] \in Final \cup {"refused"}

\* A service whose owner ended without keep is ended, once the connection is back.
ServiceEndsWithOwner ==
    ConnectionReturns =>
        \A s \in Svcs : (~alive /\ ~keep[s] /\ held[s] > 0) ~> held[s] = 0
=============================================================================
