------------------------------ MODULE Schedule ------------------------------
(***************************************************************************)
(* Leases from one scheduler: every agent start, heavy run and landing     *)
(* asks for one first. A lease is a durable row; a grant is one write      *)
(* transaction that checks capacity and inserts the row; a release is a    *)
(* compare-and-set on the lease id, so it happens once. After a restart a  *)
(* row is released only when its process has ended, never because time     *)
(* passed. The lease id grows strictly, so it is a fencing token.          *)
(*                                                                         *)
(* A request is answered at once: granted, queued, or refused with a       *)
(* reason. A queued request gets one more answer, granted or refused, and  *)
(* no position updates. Requests are idempotent by request id: the queue   *)
(* is in memory, so a requester waiting through a restart asks again with  *)
(* the same id, and is handed the lease it already has, never a second.    *)
(*                                                                         *)
(* Models the Scheduler (planned, after R12): its `leases` table          *)
(* (durable: `leases`, whose length is the last id given out); its queue  *)
(* per class, the rotation across modules in each class, each queued       *)
(* request's deadline as a tick-down timer, the answer it owes each        *)
(* requester, and the monitors on the holders' processes (all in memory,   *)
(* gone at a restart); and Holder.Process's liveness of a lease's holder   *)
(* by its record (pid and start time), which outlives the scheduler.       *)
(*                                                                         *)
(* The classes, in order: 1 a person's main session, 2 a landing's gates,  *)
(* 3 a builder, 4 a heavy run. No class takes back another's lease. A      *)
(* class is served only when no waiting request of a higher class can be   *)
(* granted; inside a class the modules that ask take turns, and one        *)
(* module's requests go in the order they came. Aging is left abstract:    *)
(* it reorders only inside a class, which `ClassOrder` checks, and a       *)
(* request that waits too long is refused at its deadline.                 *)
(*                                                                         *)
(* Pressure and each account's budget are the environment: they change at  *)
(* any step, so the spec holds for every history of them, and the          *)
(* thresholds behind them are measured, not modeled. `high` admits no new  *)
(* heavy run; `severe` admits nothing new but a person's main session,    *)
(* which is always admitted. A spent budget is refused at once, and a      *)
(* queued request whose budget is spent is refused then. A refusal is      *)
(* final for its id and holds nothing. Pressure that bars a request's     *)
(* class refuses it at once as well; a queued one it bars waits for its    *)
(* deadline. `high`'s bar on heavy runs has no property of its own: it is  *)
(* the same guard as `severe`'s, which `NoStartUnderSevere` checks.        *)
(*                                                                         *)
(* A lease names its holder's process, here the requester's, alive from   *)
(* before it asks and ending at any step after. The lease lasts as long as *)
(* that process: the monitor releases it at the process's end, and after a *)
(* restart the reclaimer reads each unreleased row, releases it if the     *)
(* process ended and monitors it again if not.                             *)
(*                                                                         *)
(* Neither Claim nor Hold is instanced. A lease is not a claim: a claim is *)
(* one per state of a target, acted on once while current, while a lease  *)
(* is units of a resource counted against a capacity, held as long as a    *)
(* process lives. A queued request is not a hold: a hold has a durable row *)
(* and exactly one response, and settles lost or unknown after a cut; a    *)
(* queued request has no row, may be answered queued and then once more,  *)
(* and after a restart is asked again under its id rather than settled.    *)
(*                                                                         *)
(* Left abstract: the reason a refusal names and its retry time (one       *)
(* "refused"); the landing's hold on the next free slot and any backfill   *)
(* (a lower class may take what a higher waiting request cannot use);     *)
(* how the scheduler reads pressure and budgets; the holder's record,      *)
(* which here exists when the request is made.                             *)
(*                                                                         *)
(* Fairness: the scheduler's steps (Insert, Tell, Expire, Tick, Release,   *)
(* Reclaim) and a waiting requester's asking again after a restart. First  *)
(* requests, a process's end, pressure and budgets get none. A restart is  *)
(* never fair, and MaxCrashes bounds it.                                   *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Schedule_<value>.cfg that TLC must fail.                    *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Shape,            \* the table of requests: "Safety", "Mains" or "Liveness"
    QueueBound,       \* the most requests one class's queue holds
    MaxWait,          \* a queued request's deadline, in ticks
    MaxCrashes,       \* the most restarts of the scheduler in one behavior
    Break             \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "NoCapacityCheck",    \* a grant does not check capacity
    "CountInMemory",      \* a grant counts the leases this run monitors, not the rows
    "NotIdempotent",      \* a request asked again does not look for its lease
    "RefuseBeforeLookup", \* a request asked again is checked for refusal before its lease is looked up
    "NoCompareAndSet",    \* a release writes whether or not the row was released
    "ReclaimByTime",      \* after a restart a row is released whether or not its process ended
    "Piecemeal",          \* a landing takes the resources that are free now, the rest later
    "NoDeadline",         \* a queued request is never refused at its deadline
    "NoClassOrder",       \* a grant does not look at higher classes
    "NoSevereGate",       \* a grant does not look at severe pressure
    "NoBudgetGate",       \* a grant does not look at the account's budget
    "NoReask",            \* a requester waiting through a restart does not ask again
    "NoReclaim"           \* after a restart no row is read again
}

ASSUME Break \in Breaks
ASSUME Shape \in {"Safety", "Mains", "Liveness"}
ASSUME QueueBound \in Nat \ {0} /\ MaxWait \in Nat \ {0} /\ MaxCrashes \in Nat

Main == 1
Landing == 2
Builder == 3
Heavy == 4
Classes == {Main, Landing, Builder, Heavy}

Resources == {"seat", "slot", "lock"}
Need(seat, slot, lock) == [seat |-> seat, slot |-> slot, lock |-> lock]

\* Each request by id: its class, the module that asks, its account, and the
\* units of each resource it needs. A landing needs a slot and the lock.
Table ==
    CASE Shape = "Safety" ->
           << [class |-> Landing, module |-> 1, account |-> "a1", units |-> Need(0, 1, 1)],
              [class |-> Heavy,   module |-> 1, account |-> "a1", units |-> Need(0, 1, 0)],
              [class |-> Heavy,   module |-> 2, account |-> "a1", units |-> Need(0, 1, 0)] >>
      [] Shape = "Mains" ->
           << [class |-> Main,    module |-> 1, account |-> "a1", units |-> Need(1, 0, 0)],
              [class |-> Builder, module |-> 2, account |-> "a1", units |-> Need(1, 0, 0)] >>
      [] Shape = "Liveness" ->
           << [class |-> Landing, module |-> 1, account |-> "a1", units |-> Need(0, 1, 1)],
              [class |-> Heavy,   module |-> 2, account |-> "a1", units |-> Need(0, 1, 0)] >>

Capacity == [seat |-> 1, slot |-> 1, lock |-> 1]

Reqs == 1..Len(Table)
Accounts == {Table[r].account : r \in Reqs}
NModules == LET ms == {Table[r].module : r \in Reqs} IN CHOOSE m \in ms : \A k \in ms : k <= m

Answers == {"idle", "asking", "queued", "granted", "refused"}

VARIABLES
    leases,     \* durable: the rows, by id, [req, units, n (ghost: its releases)]
    queue,      \* in memory: class -> its queued requests, in the order they came
    rot,        \* in memory: class -> the module whose turn it is
    wait,       \* in memory: r -> the ticks left before its deadline, while queued
    pending,    \* in memory: r -> the answer owed to its requester: "none", "queued", "granted", "refused"
    monitored,  \* in memory: the lease ids whose holder this run monitors
    ans,        \* the requester's: r -> the last answer it read ("asking" before any)
    proc,       \* the holder's process: r -> "live" or "ended"
    pressure,   \* environment: "ok", "high" or "severe"
    budgetOk,   \* environment: account -> its budget has room
    crashes     \* the restarts so far

vars == <<leases, queue, rot, wait, pending, monitored, ans, proc, pressure, budgetOk, crashes>>

-----------------------------------------------------------------------------
(* Reading the state *)

Ids == 1..Len(leases)
Released(i) == leases[i].n > 0
HasLease(r) == \E i \in Ids : leases[i].req = r

\* The units of x held by the unreleased leases among ids I.
HeldIn(x, I) ==
    LET f[k \in 0..Len(leases)] ==
          IF k = 0 THEN 0
          ELSE f[k - 1] + (IF k \in I /\ ~Released(k) THEN leases[k].units[x] ELSE 0)
    IN f[Len(leases)]

Held(x) == HeldIn(x, Ids)

InQueue(r) == \E k \in 1..Len(queue[Table[r].class]) : queue[Table[r].class][k] = r
Queued == {r \in Reqs : InQueue(r)}
Remove(s, r) == SelectSeq(s, LAMBDA q : q # r)

\* The design's own reading of whether r may be granted now.
Fits(r) == \A x \in Resources : Held(x) + Table[r].units[x] <= Capacity[x]
SevereBars(r) == pressure = "severe" /\ Table[r].class # Main
HighBars(r) == pressure = "high" /\ Table[r].class = Heavy
Admitted(r) == ~SevereBars(r) /\ ~HighBars(r) /\ budgetOk[Table[r].account]
CanGrant(r) == Fits(r) /\ Admitted(r)

\* The grant's reading, with a guard removed under a Break.
GrantFits(r) ==
    CASE Break = "NoCapacityCheck" -> TRUE
      [] Break = "CountInMemory" ->
           \A x \in Resources : HeldIn(x, monitored) + Table[r].units[x] <= Capacity[x]
      [] Break = "Piecemeal" ->
           \E x \in Resources : Table[r].units[x] > 0 /\ Held(x) + Table[r].units[x] <= Capacity[x]
      [] OTHER -> Fits(r)

\* What the grant takes: all of r's units, or under Piecemeal what is free now.
Taken(r) ==
    IF Break = "Piecemeal"
    THEN [x \in Resources |-> IF Held(x) + Table[r].units[x] <= Capacity[x]
                              THEN Table[r].units[x] ELSE 0]
    ELSE Table[r].units

GrantAdmits(r) ==
    /\ ~HighBars(r)
    /\ ~SevereBars(r) \/ Break = "NoSevereGate"
    /\ budgetOk[Table[r].account] \/ Break = "NoBudgetGate"

CanInsert(r) == GrantFits(r) /\ GrantAdmits(r)

\* A waiting request of a higher class that could be granted now.
HigherWaits(r) == \E q \in Queued : Table[q].class < Table[r].class /\ CanInsert(q)

\* r is next in its class: its module comes first in the rotation among the
\* modules with a request that could be granted, and r is that module's first.
NextInClass(r) ==
    LET c == Table[r].class
        E == {q \in Queued : Table[q].class = c /\ CanInsert(q)}
        d(q) == (Table[q].module - rot[c] + NModules) % NModules
        at(q) == CHOOSE k \in 1..Len(queue[c]) : queue[c][k] = q
    IN  /\ \A q \in E : d(r) <= d(q)
        /\ \A q \in E : Table[q].module = Table[r].module => at(r) <= at(q)

-----------------------------------------------------------------------------
(* The scheduler *)

Init ==
    /\ leases = <<>>
    /\ queue = [c \in Classes |-> <<>>]
    /\ rot = [c \in Classes |-> 1]
    /\ wait = [r \in Reqs |-> 0]
    /\ pending = [r \in Reqs |-> "none"]
    /\ monitored = {}
    /\ ans = [r \in Reqs |-> "idle"]
    /\ proc = [r \in Reqs |-> "live"]
    /\ pressure = "ok"
    /\ budgetOk = [a \in Accounts |-> TRUE]
    /\ crashes = 0

\* The scheduler takes r's request and decides its first answer at once: the
\* lease r already has; refused for a spent budget, a bar of pressure or a
\* full queue; or queued, with its deadline started. Under NotIdempotent the
\* lease is not looked for; under RefuseBeforeLookup it is looked for last.
Receive(r) ==
    LET c == Table[r].class
        refused == ~budgetOk[Table[r].account] \/ SevereBars(r) \/ HighBars(r)
                   \/ Len(queue[c]) >= QueueBound
        found == HasLease(r) /\ Break # "NotIdempotent"
        answer(a) == pending' = [pending EXCEPT ![r] = a] /\ UNCHANGED <<queue, wait>>
    IN  IF found /\ Break # "RefuseBeforeLookup" THEN answer("granted")
        ELSE IF refused THEN answer("refused")
        ELSE IF found THEN answer("granted")
        ELSE /\ queue' = [queue EXCEPT ![c] = Append(@, r)]
             /\ wait' = [wait EXCEPT ![r] = MaxWait]
             /\ pending' = [pending EXCEPT ![r] = "queued"]

\* A requester asks for the first time.
Ask(r) ==
    /\ ans[r] = "idle" /\ proc[r] = "live"
    /\ ans' = [ans EXCEPT ![r] = "asking"]
    /\ Receive(r)
    /\ UNCHANGED <<leases, rot, monitored, proc, pressure, budgetOk, crashes>>

\* A requester still waiting after a restart asks again under the same id.
\* Only a restart leaves a waiting requester that the scheduler does not hold.
Reask(r) ==
    /\ Break # "NoReask"
    /\ ans[r] \in {"asking", "queued"} /\ proc[r] = "live"
    /\ ~InQueue(r) /\ pending[r] = "none"
    /\ Receive(r)
    /\ UNCHANGED <<leases, rot, monitored, ans, proc, pressure, budgetOk, crashes>>

\* The grant: one transaction that checks capacity and inserts the row,
\* with all of a landing's resources. Its id is the next, and its holder is
\* monitored from now.
Insert(r) ==
    LET c == Table[r].class
        id == Len(leases) + 1
    IN  /\ InQueue(r)
        /\ CanInsert(r)
        /\ ~HigherWaits(r) \/ Break = "NoClassOrder"
        /\ NextInClass(r)
        /\ leases' = Append(leases, [req |-> r, units |-> Taken(r), n |-> 0])
        /\ queue' = [queue EXCEPT ![c] = Remove(@, r)]
        /\ wait' = [wait EXCEPT ![r] = 0]
        /\ pending' = [pending EXCEPT ![r] = "granted"]
        /\ monitored' = monitored \cup {id}
        /\ rot' = [rot EXCEPT ![c] = (Table[r].module % NModules) + 1]
        /\ UNCHANGED <<ans, proc, pressure, budgetOk, crashes>>

\* The answer owed reaches the requester: one message.
Tell(r) ==
    /\ pending[r] # "none"
    /\ ans' = [ans EXCEPT ![r] = pending[r]]
    /\ pending' = [pending EXCEPT ![r] = "none"]
    /\ UNCHANGED <<leases, queue, rot, wait, monitored, proc, pressure, budgetOk, crashes>>

\* Time passes for every queued request. It cannot pass a deadline: a timer
\* at 1 is answered first (Expire). Under NoDeadline it can.
Tick ==
    /\ Queued # {}
    /\ \A q \in Queued : wait[q] > (IF Break = "NoDeadline" THEN 0 ELSE 1)
    /\ wait' = [q \in Reqs |-> IF q \in Queued THEN wait[q] - 1 ELSE wait[q]]
    /\ UNCHANGED <<leases, queue, rot, pending, monitored, ans, proc, pressure, budgetOk, crashes>>

\* A queued request is refused at its deadline, or once its budget is spent.
Expire(r) ==
    /\ InQueue(r)
    /\ \/ wait[r] = 1 /\ Break # "NoDeadline"
       \/ ~budgetOk[Table[r].account]
    /\ queue' = [queue EXCEPT ![Table[r].class] = Remove(@, r)]
    /\ wait' = [wait EXCEPT ![r] = 0]
    /\ pending' = [pending EXCEPT ![r] = "refused"]
    /\ UNCHANGED <<leases, rot, monitored, ans, proc, pressure, budgetOk, crashes>>

\* The compare-and-set on the lease id: it writes only an unreleased row.
\* Under NoCompareAndSet it writes any.
Unreleased(i) == ~Released(i) \/ Break = "NoCompareAndSet"
ReleaseRow(i) == leases' = [leases EXCEPT ![i].n = @ + 1]

\* The monitor sees the holder's process end, and releases its lease.
Release(i) ==
    /\ i \in monitored /\ Unreleased(i)
    /\ proc[leases[i].req] = "ended"
    /\ ReleaseRow(i)
    /\ monitored' = monitored \ {i}
    /\ UNCHANGED <<queue, rot, wait, pending, ans, proc, pressure, budgetOk, crashes>>

\* After a restart, the reclaimer reads a row no monitor watches: released if
\* its process ended (by its pid and start time), else monitored again.
\* Under ReclaimByTime it is released whatever its process.
Reclaim(i) ==
    /\ Break # "NoReclaim"
    /\ i \in Ids /\ i \notin monitored /\ Unreleased(i)
    /\ IF proc[leases[i].req] = "ended" \/ Break = "ReclaimByTime"
       THEN ReleaseRow(i) /\ UNCHANGED monitored
       ELSE monitored' = monitored \cup {i} /\ UNCHANGED leases
    /\ UNCHANGED <<queue, rot, wait, pending, ans, proc, pressure, budgetOk, crashes>>

\* A restart: the queue, the timers, the answers owed and the monitors go;
\* the rows, the requesters and the holders' processes stay.
Crash ==
    /\ crashes < MaxCrashes
    /\ crashes' = crashes + 1
    /\ queue' = [c \in Classes |-> <<>>]
    /\ rot' = [c \in Classes |-> 1]
    /\ wait' = [r \in Reqs |-> 0]
    /\ pending' = [r \in Reqs |-> "none"]
    /\ monitored' = {}
    /\ UNCHANGED <<leases, ans, proc, pressure, budgetOk>>

-----------------------------------------------------------------------------
(* The environment *)

\* A holder's process ends, at any step after it asked.
ProcessEnds(r) ==
    /\ proc[r] = "live" /\ ans[r] # "idle"
    /\ proc' = [proc EXCEPT ![r] = "ended"]
    /\ UNCHANGED <<leases, queue, rot, wait, pending, monitored, ans, pressure, budgetOk, crashes>>

Pressure(p) ==
    /\ p # pressure
    /\ pressure' = p
    /\ UNCHANGED <<leases, queue, rot, wait, pending, monitored, ans, proc, budgetOk, crashes>>

Budget(a) ==
    /\ budgetOk' = [budgetOk EXCEPT ![a] = ~@]
    /\ UNCHANGED <<leases, queue, rot, wait, pending, monitored, ans, proc, pressure, crashes>>

Next ==
    \/ \E r \in Reqs : Ask(r) \/ Reask(r) \/ Insert(r) \/ Tell(r) \/ Expire(r) \/ ProcessEnds(r)
    \/ Tick
    \/ \E i \in Ids : Release(i) \/ Reclaim(i)
    \/ Crash
    \/ \E p \in {"ok", "high", "severe"} : Pressure(p)
    \/ \E a \in Accounts : Budget(a)

Fairness ==
    /\ \A r \in Reqs : /\ WF_vars(Reask(r)) /\ WF_vars(Insert(r))
                       /\ WF_vars(Tell(r)) /\ WF_vars(Expire(r))
    /\ WF_vars(Tick)
    /\ WF_vars(\E i \in Ids : Release(i))
    /\ WF_vars(\E i \in Ids : Reclaim(i))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ \A i \in Ids : /\ leases[i].req \in Reqs
                      /\ leases[i].units \in [Resources -> 0..1]
                      /\ leases[i].n \in Nat
    /\ \A c \in Classes : \A k \in 1..Len(queue[c]) : Table[queue[c][k]].class = c
    /\ rot \in [Classes -> 1..NModules]
    /\ wait \in [Reqs -> 0..MaxWait]
    /\ pending \in [Reqs -> {"none", "queued", "granted", "refused"}]
    /\ monitored \subseteq Ids
    /\ ans \in [Reqs -> Answers]
    /\ proc \in [Reqs -> {"live", "ended"}]
    /\ pressure \in {"ok", "high", "severe"}
    /\ budgetOk \in [Accounts -> BOOLEAN]
    /\ crashes \in 0..MaxCrashes

\* For every resource, the units the unreleased rows hold never pass its capacity.
CapacityHolds == \A x \in Resources : Held(x) <= Capacity[x]

\* Each request id has at most one lease, across restarts.
NoDoubleGrant == \A i, j \in Ids : leases[i].req = leases[j].req => i = j

\* Each lease is released at most once, and only after its process ended.
ReleaseOnce ==
    \A i \in Ids : /\ leases[i].n <= 1
                   /\ Released(i) => proc[leases[i].req] = "ended"

\* A lease holds all of its request's resources, or (released) none.
GangAtomic == \A i \in Ids : ~Released(i) => leases[i].units = Table[leases[i].req].units

\* No queued request's timer reaches zero: each is answered by its deadline.
AnsweredByDeadline == \A r \in Queued : wait[r] > 0

\* A refusal is final and holds nothing: its requester records a refusal,
\* never a run that started (and so never one that failed).
RefusedIsNotFailed == \A r \in Reqs : ans[r] = "refused" => ~HasLease(r)

\* The request a step grants a new lease to, if it does.
NewLease == Len(leases') > Len(leases)
NewReq == leases'[Len(leases')].req

\* A grant goes to a class only when no waiting request of a higher class
\* could be granted.
ClassOrder ==
    [][NewLease =>
         ~\E q \in Queued : Table[q].class < Table[NewReq].class /\ CanGrant(q)]_vars

\* No new lease under severe pressure but a person's main session's.
NoStartUnderSevere ==
    [][NewLease => pressure # "severe" \/ Table[NewReq].class = Main]_vars

\* No new lease on an account whose budget is spent.
NoStartWithoutBudget == [][NewLease => budgetOk[Table[NewReq].account]]_vars

\* Every waiting requester is answered, granted or refused, unless its
\* process ends first.
QueuedIsAnswered ==
    \A r \in Reqs : ans[r] \in {"asking", "queued"}
                      ~> (ans[r] \in {"granted", "refused"} \/ proc[r] = "ended")

\* Every lease whose process ended is released, by the monitor or the reclaimer.
EndedIsReleased ==
    \A r \in Reqs : (\E i \in Ids : leases[i].req = r /\ ~Released(i) /\ proc[r] = "ended")
                      ~> (\A i \in Ids : leases[i].req = r => Released(i))

=============================================================================
