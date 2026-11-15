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
(*             memory) and whether it completed;                           *)
(*   Jobs      each job's row (durable): asked, syncing, synced, starting, *)
(*             running, then its end as read from the host (exited with    *)
(*             its code, timed out, or lost); the run call (in memory),    *)
(*             which waits for that end, fetches the named paths and       *)
(*             answers;                                                    *)
(*   Services  each service's row, owner and keep flag (durable); its      *)
(*             start, which is a run like a job's; its end when its owner  *)
(*             ends without keep, and its restart (an end, then a start);  *)
(*   Shell     over ssh: one connection per host, which a drop or a        *)
(*             restart of the framework cuts. A command cut in flight may  *)
(*             still have run on the host; the local rsync ends with its   *)
(*             caller (Shell.Reaper);                                      *)
(*   Holder    dtach -n on the host: a held job or service outlives the    *)
(*             connection and the framework. A job's wrapper on the host   *)
(*             writes its exit code (or "timeout") to a file before it     *)
(*             exits, and ends the job's process group at its timeout.     *)
(*                                                                         *)
(* Runs are Jobs and Svcs: each job is asked once; a service is started    *)
(* once and restarted up to MaxSvcRestarts times. A run that has asked     *)
(* waits for the copy's turn, syncs, sends its start, and gives the turn   *)
(* back once the start is settled: the start's reply, or after a cut the   *)
(* host's read. `whole` says no sync is writing the copy or was cut since  *)
(* the last one completed. `fresh[r]` is a ghost: a sync that began after  *)
(* r asked has completed since.                                            *)
(*                                                                         *)
(* A command in flight (`cmd` "busy") is cut by a drop ("cut") or ended by *)
(* a restart ("none"). A start or an end that was sent may land on the     *)
(* host after the cut (`inflight`), up to its deadline; past it, it never  *)
(* lands (NeverLands). That is the one assumption about time beside the    *)
(* deadline flags: the host runs a command it got within the command's     *)
(* deadline, or never.                                                     *)
(*                                                                         *)
(* Assumed, not modeled (F-70's build note, Findings): once the local      *)
(* rsync has ended, by a drop or by a restart, the host's side of that     *)
(* sync writes nothing more into the copy; a host does not restart; a      *)
(* job's end is its command's exit, not that of children it left in its   *)
(* group. A service does not exit by itself. A start that dtach refuses    *)
(* is a refused answer like a cut sync, and is left out.                   *)
(*                                                                         *)
(* Left abstract: the files of a sync (one step begins it, one completes   *)
(* it, a cut leaves the copy partly synced), the log and its offset (read  *)
(* by the same reads), the job's argv, the ports a service forwards, and   *)
(* claims (Team.tla). Time is a flag per job, `past`: its timeout has      *)
(* passed, at any step after its run asked; the call and the host's        *)
(* wrapper keep that one deadline. A call's own deadline is the job's      *)
(* timeout, or for a service start any time; at it, with the connection    *)
(* down, the call answers unknown{dropped}, or the end it read with its    *)
(* fetch cut (GiveUp). The worktree has paths, which the agent             *)
(* edits at any time (Edit), and the fetch writes back.                    *)
(*                                                                         *)
(* Open, not checked by any configuration (F-70's build note): a sync      *)
(* that changes files under a running job or service (NoChangeUnderRun),   *)
(* and a fetch that writes over an edit the agent made during the job      *)
(* (NoEditLost). The design does not settle either; the spec lets both     *)
(* happen and records them in ghosts.                                      *)
(*                                                                         *)
(* Fairness: the framework's and the host's steps happen while they stay   *)
(* possible, and time passes. The connection's return, drops, the agents'  *)
(* calls and edits, a job's own exit, a wrapper killed, an owner's end and *)
(* restarts of the framework happen or not.                                *)
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
    "StartBeforeEnd"        \* a restart starts the new process without the old one's end confirmed
}

ASSUME Break \in Breaks
ASSUME Jobs \cap Svcs = {} /\ Fetched \subseteq Paths
ASSUME "none" \notin Codes /\ "timeout" \notin Codes
ASSUME /\ MaxDrops \in Nat /\ MaxRestarts \in Nat /\ MaxEdits \in Nat /\ MaxLost \in Nat
       /\ MaxSvcRestarts \in Nat

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
Kinds == {None, "ok", "timeout", "lost", "refused", "dropped", "restart", "started"}
Answers == [k : Kinds, code : CodeVals, fetch : {None, "done", "cut"}]
Say(k) == [k |-> k, code |-> None, fetch |-> None]

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
    writers,    \* the runs whose rsync is writing the copy
    \* The connection and the framework
    up,         \* the ssh connection to the host is up
    fw,         \* "up" or "down"
    \* The host
    inflight,   \* [Runs -> {None, "start", "end"}]: a command sent that may still land
    held,       \* [Runs -> 0..2]: the run's processes dtach holds
    file,       \* [Runs -> FileVals]: a job's exit file
    past,       \* [Runs -> BOOLEAN]: a job's timeout has passed
    whole,      \* the copy's last sync completed and none wrote it since
    \* The agent's worktree
    edited,     \* [Paths -> BOOLEAN]: edited since the last sync began
    \* Counters
    drops, restarts, edits, lost, svcRestarts,
    \* Ghosts, for the properties; the framework never reads them
    answer,     \* [Runs -> Answers]: the call's last answer
    fresh,      \* [Runs -> BOOLEAN]
    cover,      \* [Runs -> SUBSET Runs]: the runs that had asked when r's sync began
    badStart,   \* runs that started on a copy not whole or not fresh for them
    fetched,    \* the fetch's writes: [r, p, ended]
    clobbered,  \* paths a fetch wrote over an edit made since the sync began
    under       \* runs with a held process while another sync began

vars == <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up, fw,
          inflight, held, file, past, whole, edited, drops, restarts, edits, lost, svcRestarts,
          answer, fresh, cover, badStart, fetched, clobbered, under>>

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
    /\ writers \subseteq Runs
    /\ up \in BOOLEAN /\ fw \in {"up", "down"}
    /\ inflight \in [Runs -> {None, "start", "end"}]
    /\ held \in [Runs -> 0..2]
    /\ file \in [Runs -> FileVals]
    /\ past \in [Runs -> BOOLEAN]
    /\ whole \in BOOLEAN
    /\ edited \in [Paths -> BOOLEAN]
    /\ answer \in [Runs -> Answers]
    /\ fresh \in [Runs -> BOOLEAN]
    /\ cover \in [Runs -> SUBSET Runs]

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
    /\ writers = {}
    /\ up = TRUE /\ fw = "up"
    /\ inflight = [r \in Runs |-> None]
    /\ held = [r \in Runs |-> 0]
    /\ file = [r \in Runs |-> None]
    /\ past = [r \in Runs |-> FALSE]
    /\ whole = FALSE
    /\ edited = [p \in Paths |-> FALSE]
    /\ drops = 0 /\ restarts = 0 /\ edits = 0 /\ lost = 0 /\ svcRestarts = 0
    /\ answer = [r \in Runs |-> Say(None)]
    /\ fresh = [r \in Runs |-> FALSE]
    /\ cover = [r \in Runs |-> {}]
    /\ badStart = {} /\ fetched = {} /\ clobbered = {} /\ under = {}

Link == up /\ fw = "up"

\* The turn goes back once the run's start is settled.
Release(r) == turn' = IF turn = r THEN None ELSE turn

\* An answer ends the call.
Answer(r, a) ==
    /\ answer' = [answer EXCEPT ![r] = a]
    /\ call' = [call EXCEPT ![r] = None]

----------------------------------------------------------------------------
\* The agent's calls

AskJob(j) ==
    /\ fw = "up" /\ row[j] = "idle"
    /\ row' = [row EXCEPT ![j] = "asked"]
    /\ call' = [call EXCEPT ![j] = "waiting"]
    /\ fresh' = [fresh EXCEPT ![j] = FALSE]
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, cover, badStart, fetched, clobbered, under>>

\* service_start, with keep: or without.
AskService(s) ==
    /\ fw = "up" /\ alive /\ row[s] = "idle"
    /\ row' = [row EXCEPT ![s] = "asked"]
    /\ call' = [call EXCEPT ![s] = "waiting"]
    /\ fresh' = [fresh EXCEPT ![s] = FALSE]
    /\ owner' = [owner EXCEPT ![s] = "agent"]
    /\ \E k \in BOOLEAN : keep' = [keep EXCEPT ![s] = k]
    /\ UNCHANGED <<rcode, turn, alive, cmd, rd, fetchLeft, writers, up, fw, inflight, held,
                   file, past, whole, edited, drops, restarts, edits, lost, svcRestarts,
                   answer, cover, badStart, fetched, clobbered, under>>

\* service_restart by its owner: the row says restarting before the end is sent.
AskRestart(s) ==
    /\ fw = "up" /\ alive /\ owner[s] = "agent" /\ row[s] = "running" /\ call[s] = None
    /\ svcRestarts < MaxSvcRestarts
    /\ row' = [row EXCEPT ![s] = IF Break = "StartBeforeEnd" THEN "asked" ELSE "restarting"]
    /\ call' = [call EXCEPT ![s] = "waiting"]
    /\ fresh' = [fresh EXCEPT ![s] = FALSE]
    /\ svcRestarts' = svcRestarts + 1
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   answer, cover, badStart, fetched, clobbered, under>>

Edit(p) ==
    /\ edits < MaxEdits
    /\ edited' = [edited EXCEPT ![p] = TRUE]
    /\ edits' = edits + 1
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up,
                   fw, inflight, held, file, past, whole, drops, restarts, lost, svcRestarts,
                   answer, fresh, cover, badStart, fetched, clobbered, under>>

----------------------------------------------------------------------------
\* The sync and the start

\* The run takes the turn (written before rsync starts) and rsync begins
\* writing the copy. The sync reads the worktree as it goes.
SyncBegins(r) ==
    /\ Link /\ row[r] = "asked" /\ call[r] = "waiting" /\ cmd[r] = None
    /\ turn = None \/ Break = "NoTurn"
    /\ row' = [row EXCEPT ![r] = "syncing"]
    /\ turn' = r
    /\ cmd' = [cmd EXCEPT ![r] = "busy"]
    /\ writers' = writers \cup {r}
    /\ whole' = FALSE
    /\ cover' = [cover EXCEPT ![r] = {q \in Runs : ~fresh[q]}]
    /\ edited' = [p \in Paths |-> FALSE]
    /\ under' = under \cup {q \in Runs : held[q] > 0}
    /\ UNCHANGED <<rcode, owner, keep, alive, call, rd, fetchLeft, up, fw, inflight, held, file,
                   past, drops, restarts, edits, lost, svcRestarts, answer, fresh, badStart,
                   fetched, clobbered>>

\* Under SkipSync, a copy whole from an earlier sync is taken as in step.
SyncSkipped(r) ==
    /\ Break = "SkipSync"
    /\ Link /\ row[r] = "asked" /\ call[r] = "waiting" /\ cmd[r] = None /\ turn = None /\ whole
    /\ row' = [row EXCEPT ![r] = "synced"]
    /\ turn' = r
    /\ UNCHANGED <<rcode, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

SyncCompletes(r) ==
    /\ row[r] = "syncing" /\ cmd[r] = "busy"
    /\ row' = [row EXCEPT ![r] = "synced"]
    /\ cmd' = [cmd EXCEPT ![r] = None]
    /\ writers' = writers \ {r}
    /\ whole' = (writers' = {})
    /\ fresh' = [q \in Runs |-> fresh[q] \/ q \in cover[r]]
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, rd, fetchLeft, up, fw, inflight, held,
                   file, past, edited, drops, restarts, edits, lost, svcRestarts, answer, cover,
                   badStart, fetched, clobbered, under>>

\* rsync exited non-zero: the copy stays partly synced, and nothing ran.
SyncCut(r) ==
    /\ fw = "up" /\ row[r] = "syncing" /\ cmd[r] = "cut"
    /\ cmd' = [cmd EXCEPT ![r] = None]
    /\ writers' = writers \ {r}
    /\ IF Break = "StartOnCut"
       THEN /\ row' = [row EXCEPT ![r] = "synced"]
            /\ UNCHANGED <<turn, call, answer>>
       ELSE /\ row' = [row EXCEPT ![r] = "refused"]
            /\ Release(r)
            /\ IF call[r] = "waiting" THEN Answer(r, Say("refused"))
                                      ELSE UNCHANGED <<call, answer>>
    /\ UNCHANGED <<rcode, owner, keep, alive, rd, fetchLeft, up, fw, inflight, held, file, past,
                   whole, edited, drops, restarts, edits, lost, svcRestarts, fresh, cover,
                   badStart, fetched, clobbered, under>>

\* The start's row is written, then `ssh host dtach -n …` is sent.
StartSent(r) ==
    /\ Link /\ row[r] = "synced" /\ call[r] = "waiting" /\ cmd[r] = None
    /\ row' = [row EXCEPT ![r] = "starting"]
    /\ cmd' = [cmd EXCEPT ![r] = "busy"]
    /\ inflight' = [inflight EXCEPT ![r] = "start"]
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, rd, fetchLeft, writers, up, fw, held,
                   file, past, whole, edited, drops, restarts, edits, lost, svcRestarts, answer,
                   fresh, cover, badStart, fetched, clobbered, under>>

\* The host runs a command it got: a start holds a process, an end kills one.
Lands(r) ==
    /\ inflight[r] # None
    /\ inflight' = [inflight EXCEPT ![r] = None]
    /\ IF inflight[r] = "start"
       THEN /\ held' = [held EXCEPT ![r] = held[r] + 1]
            /\ badStart' = IF whole /\ fresh[r] THEN badStart ELSE badStart \cup {r}
       ELSE /\ held' = [held EXCEPT ![r] = IF held[r] > 0 THEN held[r] - 1 ELSE 0]
            /\ UNCHANGED badStart
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up,
                   fw, file, past, whole, edited, drops, restarts, edits, lost, svcRestarts,
                   answer, fresh, cover, fetched, clobbered, under>>

\* A command cut before the host ran it, past its deadline, never runs.
NeverLands(r) ==
    /\ inflight[r] # None /\ cmd[r] # "busy"
    /\ inflight' = [inflight EXCEPT ![r] = None]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up,
                   fw, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

\* dtach -n answered 0 over the connection: the process is held.
StartReplies(r) ==
    /\ fw = "up" /\ row[r] = "starting" /\ cmd[r] = "busy" /\ inflight[r] = None
    /\ row' = [row EXCEPT ![r] = "running"]
    /\ cmd' = [cmd EXCEPT ![r] = None]
    /\ Release(r)
    /\ IF r \in Svcs /\ call[r] = "waiting" THEN Answer(r, Say("started"))
                                            ELSE UNCHANGED <<call, answer>>
    /\ UNCHANGED <<rcode, owner, keep, alive, rd, fetchLeft, writers, up, fw, inflight, held,
                   file, past, whole, edited, drops, restarts, edits, lost, svcRestarts, fresh,
                   cover, badStart, fetched, clobbered, under>>

\* A cut command whose deadline passed: the framework may act on its row again.
CutCleared(r) ==
    /\ fw = "up" /\ cmd[r] = "cut" /\ inflight[r] = None
    /\ row[r] # "syncing" /\ call[r] # "fetching"
    /\ cmd' = [cmd EXCEPT ![r] = None]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

\* A start whose reply a drop or a restart cut is settled by reading the host,
\* once its deadline has passed: held, or never started.
SettleStarting(r) ==
    /\ Link /\ row[r] = "starting" /\ cmd[r] = None
    /\ inflight[r] = None \/ Break = "SettleEarly"
    /\ Break = "ReadInCall" => call[r] # None
    /\ LET ran == held[r] > 0 \/ file[r] # None
       IN /\ row' = [row EXCEPT ![r] = IF ran THEN "running" ELSE "refused"]
          /\ IF call[r] = "waiting" /\ ~ran THEN Answer(r, Say("refused"))
             ELSE IF call[r] = "waiting" /\ r \in Svcs THEN Answer(r, Say("started"))
             ELSE UNCHANGED <<call, answer>>
    /\ Release(r)
    /\ UNCHANGED <<rcode, owner, keep, alive, cmd, rd, fetchLeft, writers, up, fw, inflight, held,
                   file, past, whole, edited, drops, restarts, edits, lost, svcRestarts, fresh,
                   cover, badStart, fetched, clobbered, under>>

\* A row before its start whose call ended (a restart, or a give-up) is refused.
SettleUnasked(r) ==
    /\ fw = "up" /\ call[r] = None /\ cmd[r] = None
    /\ row[r] \in {"asked", "syncing", "synced"}
    /\ row' = [row EXCEPT ![r] = "refused"]
    /\ Release(r)
    /\ UNCHANGED <<rcode, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

----------------------------------------------------------------------------
\* A job on the host

Tick(j) ==
    /\ ~past[j] /\ (row[j] \in {"starting", "running"} \/ held[j] > 0 \/ call[j] # None)
    /\ past' = [past EXCEPT ![j] = TRUE]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up,
                   fw, inflight, held, file, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

\* The command exits; its wrapper writes the code, then exits, and dtach removes the socket.
JobExits(j, c) ==
    /\ held[j] > 0
    /\ held' = [held EXCEPT ![j] = 0]
    /\ file' = [file EXCEPT ![j] = c]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up,
                   fw, inflight, past, whole, edited, drops, restarts, edits, lost, svcRestarts,
                   answer, fresh, cover, badStart, fetched, clobbered, under>>

\* The wrapper on the host ends the job's group at its timeout and writes "timeout".
HostTimesOut(j) ==
    /\ Break # "TimeoutFromFramework"
    /\ past[j] /\ held[j] > 0
    /\ held' = [held EXCEPT ![j] = 0]
    /\ file' = [file EXCEPT ![j] = "timeout"]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up,
                   fw, inflight, past, whole, edited, drops, restarts, edits, lost, svcRestarts,
                   answer, fresh, cover, badStart, fetched, clobbered, under>>

\* Under TimeoutFromFramework, the framework sends the end over ssh instead.
FrameworkTimesOut(j) ==
    /\ Break = "TimeoutFromFramework"
    /\ Link /\ past[j] /\ held[j] > 0
    /\ held' = [held EXCEPT ![j] = 0]
    /\ file' = [file EXCEPT ![j] = "timeout"]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up,
                   fw, inflight, past, whole, edited, drops, restarts, edits, lost, svcRestarts,
                   answer, fresh, cover, badStart, fetched, clobbered, under>>

\* The wrapper is killed on the host before it writes the exit file.
WrapperLost(j) ==
    /\ held[j] > 0 /\ lost < MaxLost
    /\ held' = [held EXCEPT ![j] = 0]
    /\ lost' = lost + 1
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up,
                   fw, inflight, file, past, whole, edited, drops, restarts, edits, svcRestarts,
                   answer, fresh, cover, badStart, fetched, clobbered, under>>

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
    /\ UNCHANGED <<turn, owner, keep, alive, call, cmd, fetchLeft, writers, up, fw, inflight,
                   held, file, past, whole, edited, drops, restarts, edits, lost, svcRestarts,
                   answer, fresh, cover, badStart, fetched, clobbered, under>>

ReadFile(j) ==
    /\ ReadCan(j) /\ rd[j] = "dead"
    /\ Ended(j, file[j])
    /\ rd' = [rd EXCEPT ![j] = None]
    /\ UNCHANGED <<turn, owner, keep, alive, call, cmd, fetchLeft, writers, up, fw, inflight,
                   held, file, past, whole, edited, drops, restarts, edits, lost, svcRestarts,
                   answer, fresh, cover, badStart, fetched, clobbered, under>>

\* Under ReadFileFirst: the file first, kept in memory, then the socket.
ReadFileEarly(j) ==
    /\ Break = "ReadFileFirst" /\ ReadCan(j) /\ rd[j] = None
    /\ rd' = [rd EXCEPT ![j] = IF file[j] = None THEN "nofile" ELSE file[j]]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

ReadSocketLate(j) ==
    /\ Break = "ReadFileFirst" /\ ReadCan(j) /\ rd[j] \notin {None, "dead"}
    /\ IF held[j] = 0 THEN Ended(j, rd[j]) ELSE UNCHANGED <<row, rcode>>
    /\ rd' = [rd EXCEPT ![j] = None]
    /\ UNCHANGED <<turn, owner, keep, alive, call, cmd, fetchLeft, writers, up, fw, inflight,
                   held, file, past, whole, edited, drops, restarts, edits, lost, svcRestarts,
                   answer, fresh, cover, badStart, fetched, clobbered, under>>

\* Under EndAtDeadline, the framework takes the timeout as the job's end.
DeadlineTaken(j) ==
    /\ Break = "EndAtDeadline"
    /\ fw = "up" /\ j \in Jobs /\ row[j] = "running" /\ past[j]
    /\ row' = [row EXCEPT ![j] = "timedout"]
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

\* What the call answers for a job's end, with the fetch's outcome.
EndAnswer(j, f) ==
    [k |-> CASE row[j] = "exited" -> "ok" [] row[j] = "timedout" -> "timeout" [] OTHER -> "lost",
     code |-> rcode[j], fetch |-> f]

\* No fetch: the call answers the end it read.
AnswerJob(j) ==
    /\ fw = "up" /\ j \in Jobs /\ call[j] = "waiting" /\ row[j] \in Final
    /\ Fetched = {} \/ row[j] = "lost"
    /\ Answer(j, EndAnswer(j, None))
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, fresh, cover, badStart, fetched, clobbered, under>>

\* rsync of the named paths, from the copy into the worktree, after the end was read.
FetchBegins(j) ==
    /\ Link /\ j \in Jobs /\ call[j] = "waiting" /\ cmd[j] = None
    /\ row[j] \in {"exited", "timedout"} /\ Fetched # {}
    /\ call' = [call EXCEPT ![j] = "fetching"]
    /\ cmd' = [cmd EXCEPT ![j] = "busy"]
    /\ fetchLeft' = [fetchLeft EXCEPT ![j] = IF Break = "FetchAll" THEN Paths ELSE Fetched]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, rd, writers, up, fw, inflight, held,
                   file, past, whole, edited, drops, restarts, edits, lost, svcRestarts, answer,
                   fresh, cover, badStart, fetched, clobbered, under>>

\* One path written into the worktree (rsync writes each whole, then renames it).
FetchPath(j, p) ==
    /\ call[j] = "fetching" /\ cmd[j] = "busy" /\ p \in fetchLeft[j]
    /\ fetchLeft' = [fetchLeft EXCEPT ![j] = fetchLeft[j] \ {p}]
    /\ fetched' = fetched \cup {[r |-> j, p |-> p, ended |-> held[j] = 0]}
    /\ clobbered' = IF edited[p] THEN clobbered \cup {p} ELSE clobbered
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, under>>

FetchDone(j) ==
    /\ call[j] = "fetching" /\ cmd[j] = "busy" /\ fetchLeft[j] = {}
    /\ Answer(j, EndAnswer(j, "done"))
    /\ cmd' = [cmd EXCEPT ![j] = None]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, fresh, cover, badStart, fetched, clobbered, under>>

\* A drop cut the fetch: the end is answered, and the fetch as cut.
FetchCut(j) ==
    /\ fw = "up" /\ call[j] = "fetching" /\ cmd[j] = "cut"
    /\ Answer(j, EndAnswer(j, "cut"))
    /\ cmd' = [cmd EXCEPT ![j] = None]
    /\ fetchLeft' = [fetchLeft EXCEPT ![j] = {}]
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, rd, writers, up, fw, inflight, held,
                   file, past, whole, edited, drops, restarts, edits, lost, svcRestarts, fresh,
                   cover, badStart, fetched, clobbered, under>>

\* The call's deadline with the connection down: unknown{dropped}, or the end
\* already read with its fetch cut. A job's call waits for its timeout; one that
\* has not started its run may give up at any time.
GiveUp(r) ==
    /\ Break # "NoGiveUp"
    /\ fw = "up" /\ ~up /\ call[r] = "waiting"
    /\ r \in Svcs \/ past[r] \/ row[r] \in {"asked", "syncing", "synced"}
    /\ Answer(r, IF r \in Jobs /\ row[r] \in Final THEN EndAnswer(r, "cut")
                 ELSE IF Break = "DropAsExit" /\ r \in Jobs
                 THEN [k |-> "ok", code |-> "255", fetch |-> None]
                 ELSE Say("dropped"))
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, fresh, cover, badStart, fetched, clobbered, under>>

----------------------------------------------------------------------------
\* A service's end

\* The agent that owns the services ends (Sessions' row, durable).
OwnerEnds ==
    /\ Svcs # {} /\ alive
    /\ alive' = FALSE
    /\ UNCHANGED <<row, rcode, turn, owner, keep, call, cmd, rd, fetchLeft, writers, up,
                   fw, inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

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
    /\ UNCHANGED <<rcode, turn, keep, alive, call, cmd, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

\* The end over ssh: the service's process, by its pid and start time, read
\* live on the host. Under EndOnce the row is marked ended as it is sent.
EndSent(s) ==
    /\ Link /\ row[s] \in {"ending", "restarting"} /\ cmd[s] = None /\ inflight[s] = None
    /\ held[s] > 0
    /\ cmd' = [cmd EXCEPT ![s] = "busy"]
    /\ inflight' = [inflight EXCEPT ![s] = "end"]
    /\ row' = IF Break = "EndOnce" /\ row[s] = "ending" THEN [row EXCEPT ![s] = "ended"] ELSE row
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, rd, fetchLeft, writers, up, fw, held,
                   file, past, whole, edited, drops, restarts, edits, lost, svcRestarts, answer,
                   fresh, cover, badStart, fetched, clobbered, under>>

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
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

\* With no command in flight, a socket read dead confirms the end: after a
\* cut end, after a restart, or when the process was gone already.
EndConfirmed(s) ==
    /\ Link /\ row[s] \in {"ending", "restarting"} /\ cmd[s] = None /\ inflight[s] = None
    /\ held[s] = 0
    /\ AfterEnd(s)
    /\ UNCHANGED <<rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

\* A restart call whose service the owner's end ended answers refused.
EndedCallAnswered(s) ==
    /\ fw = "up" /\ s \in Svcs /\ call[s] = "waiting" /\ row[s] = "ended"
    /\ Answer(s, Say("refused"))
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, cmd, rd, fetchLeft, writers, up, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, fresh, cover, badStart, fetched, clobbered, under>>

----------------------------------------------------------------------------
\* The connection and the framework

Drop ==
    /\ up /\ drops < MaxDrops
    /\ up' = FALSE
    /\ cmd' = [r \in Runs |-> IF cmd[r] = "busy" THEN "cut" ELSE cmd[r]]
    /\ drops' = drops + 1
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, rd, fetchLeft, writers, fw,
                   inflight, held, file, past, whole, edited, restarts, edits, lost, svcRestarts,
                   answer, fresh, cover, badStart, fetched, clobbered, under>>

Reconnect ==
    /\ fw = "up" /\ ~up
    /\ up' = TRUE
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, fw,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

\* The framework's node dies: its memory, its calls (each agent's MCP bridge
\* answers its call with an error) and its connection go; the reaper ends the
\* local rsync. Tables, the host and what is in flight to it stay.
FrameworkDies ==
    /\ fw = "up" /\ restarts < MaxRestarts
    /\ fw' = "down" /\ up' = FALSE
    /\ restarts' = restarts + 1
    /\ cmd' = [r \in Runs |-> None]
    /\ rd' = [r \in Runs |-> None]
    /\ fetchLeft' = [r \in Runs |-> {}]
    /\ writers' = {}
    /\ call' = [r \in Runs |-> None]
    /\ answer' = [r \in Runs |-> IF call[r] # None THEN Say("restart") ELSE answer[r]]
    /\ turn' = IF Break = "TurnInMemory" THEN None ELSE turn
    /\ row' = IF Break = "EndInMemory"
              THEN [r \in Runs |-> IF row[r] = "ending" THEN "running" ELSE row[r]]
              ELSE row
    /\ UNCHANGED <<rcode, owner, keep, alive, inflight, held, file, past, whole, edited, drops,
                   edits, lost, svcRestarts, fresh, cover, badStart, fetched, clobbered, under>>

FrameworkStarts ==
    /\ fw = "down"
    /\ fw' = "up"
    /\ UNCHANGED <<row, rcode, turn, owner, keep, alive, call, cmd, rd, fetchLeft, writers, up,
                   inflight, held, file, past, whole, edited, drops, restarts, edits, lost,
                   svcRestarts, answer, fresh, cover, badStart, fetched, clobbered, under>>

----------------------------------------------------------------------------

Next ==
    \/ \E j \in Jobs : AskJob(j)
    \/ \E s \in Svcs : AskService(s) \/ AskRestart(s)
    \/ \E p \in Paths : Edit(p)
    \/ \E r \in Runs :
        \/ SyncBegins(r) \/ SyncSkipped(r) \/ SyncCompletes(r) \/ SyncCut(r)
        \/ StartSent(r) \/ Lands(r) \/ NeverLands(r) \/ StartReplies(r) \/ CutCleared(r)
        \/ SettleStarting(r) \/ SettleUnasked(r) \/ GiveUp(r)
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
    \/ Drop \/ Reconnect \/ FrameworkDies \/ FrameworkStarts

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A r \in Runs :
         /\ WF_vars(SyncBegins(r)) /\ WF_vars(SyncSkipped(r)) /\ WF_vars(SyncCompletes(r))
         /\ WF_vars(SyncCut(r)) /\ WF_vars(StartSent(r)) /\ WF_vars(Lands(r))
         /\ WF_vars(NeverLands(r)) /\ WF_vars(StartReplies(r)) /\ WF_vars(CutCleared(r))
         /\ WF_vars(SettleStarting(r)) /\ WF_vars(SettleUnasked(r)) /\ WF_vars(GiveUp(r))
    /\ \A j \in Jobs :
         /\ WF_vars(Tick(j)) /\ WF_vars(HostTimesOut(j)) /\ WF_vars(FrameworkTimesOut(j))
         /\ WF_vars(ReadSocket(j)) /\ WF_vars(ReadFile(j))
         /\ WF_vars(ReadFileEarly(j)) /\ WF_vars(ReadSocketLate(j)) /\ WF_vars(DeadlineTaken(j))
         /\ WF_vars(AnswerJob(j)) /\ WF_vars(FetchBegins(j)) /\ WF_vars(FetchDone(j))
         /\ WF_vars(FetchCut(j)) /\ \A p \in Paths : WF_vars(FetchPath(j, p))
    /\ \A s \in Svcs :
         /\ WF_vars(OwnerSeen(s)) /\ WF_vars(EndSent(s)) /\ WF_vars(EndReplies(s))
         /\ WF_vars(EndConfirmed(s)) /\ WF_vars(EndedCallAnswered(s))

Spec == Init /\ [][Next]_vars /\ Fairness

----------------------------------------------------------------------------
\* Safety

\* A job or service starts only on a copy whose last sync completed after the
\* run asked, and that no sync has written since.
StartsOnSyncedCopy == badStart = {}

\* Every held process is one the framework tracks under a live row.
NoUntrackedProcess ==
    \A r \in Runs : held[r] > 0 => row[r] \in {"starting", "running", "ending", "restarting"}

\* An answer or a row says only what the host holds: ok carries the job's own
\* exit code, timeout comes once the host ended the job at its timeout, and lost
\* once the job is gone with no exit file. Nothing else answers an end.
AnswerIsReal ==
    \A j \in Jobs :
        /\ answer[j].k = "ok" => row[j] = "exited" /\ answer[j].code = file[j]
        /\ answer[j].k = "timeout" => held[j] = 0 /\ file[j] = "timeout"
        /\ answer[j].k = "lost" => held[j] = 0 /\ file[j] = None
        /\ row[j] = "exited" => held[j] = 0 /\ rcode[j] = file[j]
        /\ row[j] = "timedout" => held[j] = 0 /\ file[j] = "timeout"
        /\ row[j] = "lost" => held[j] = 0 /\ file[j] = None

\* A fetch writes only the paths its run named, and only after its job ended.
FetchOnlyNamed == \A f \in fetched : f.p \in Fetched
FetchOnlyAfterEnd == \A f \in fetched : f.ended

\* A service has at most one process, and an ended row has none.
OneProcess == \A r \in Runs : held[r] <= 1
EndedIsEnded == \A s \in Svcs : row[s] = "ended" => held[s] = 0

\* Open (F-70's build note): not in any configuration.
NoChangeUnderRun == under = {}
NoEditLost == clobbered = {}

\* Liveness

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
