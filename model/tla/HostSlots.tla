------------------------------ MODULE HostSlots ------------------------------
(***************************************************************************)
(* Heavy slots per host (F-292). Each host has slots of its own, counted   *)
(* against that host's capacity: the workstation one, another host two.    *)
(* A request names its host, and its grant reads and takes only that       *)
(* host's slot and reads only that host's pressure, so one host's runs     *)
(* never hold or bar another's. Work placed on another host first finds    *)
(* the host (Host.tla): a host away refuses the work at once, before any   *)
(* request, so it never queues and never holds a slot.                     *)
(*                                                                         *)
(* Models CodingAgentFramework.Scheduler (a resource declared for a host,  *)
(* `{name, host}`; a request's `where: %{host: name}`, the units it         *)
(* resolves to that host's, and the pressure gate read only for the        *)
(* Scheduler's own host), CodingAgentFramework.Jobs.run/6 (it places the   *)
(* job on its host before it asks, and names the host in the request),     *)
(* CodingAgentFramework.Runs.Plug (it names the host its wrappers run on,  *)
(* its own), and CodingAgentFramework.Hosts (a host away).                 *)
(*                                                                         *)
(* Alone, the spec has the workstation with one slot and another host with *)
(* two, three heavy runs asked for on the other host and two on the        *)
(* workstation, each asked once. Schedule.tla checks one host's leases in  *)
(* full (classes, the hold, rotation, restarts, deadlines, the fence);     *)
(* here every run is of one class, the queue's order is left out, and a    *)
(* deadline or a caller gone is one step that refuses a queued request.    *)
(*                                                                         *)
(* Pressure is the environment, per host, and changes at any step: the     *)
(* spec holds for every history of each host's level. The code reads the   *)
(* workstation's and takes another host's as `ok` (decided, F-292): one    *)
(* such history. Whether a host is away is the environment too; the        *)
(* workstation is never away. A host that goes away after its work was     *)
(* placed is Copy.tla's: its work ends, and its lease is released then;    *)
(* for an agent's heavy command run there, RemoteRun.tla's (F-296).        *)
(*                                                                         *)
(* Fairness: the grant and the refusal at a deadline (a deadline always    *)
(* comes). Asks, ends, pressure and a host's going get none.               *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_HostSlots_<value>.cfg that TLC must fail.                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Break   \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "OtherHostSlot",   \* a run on another host takes the workstation's slot, as before F-292
    "SharedPressure",  \* every grant reads the workstation's pressure
    "NoPlace"          \* a run is asked for without a find of its host
}

ASSUME Break \in Breaks

Local == "ws"
Hosts == {"ws", "mac"}
Cap == [h \in Hosts |-> IF h = Local THEN 1 ELSE 2]
Reqs == 1..5
HostOf == [r \in Reqs |-> IF r <= 3 THEN "mac" ELSE Local]

\* idle: not asked; queued; granted: runs, holding a slot; ended: its work ended and its
\* lease was released; refused: at its deadline or its caller gone; away: refused at once,
\* its host away.
States == {"idle", "queued", "granted", "ended", "refused", "away"}

VARIABLES
    req,       \* r -> one of States
    lease,     \* r -> the host whose slot r's lease holds, as its row says, or "none"
    up,        \* h -> the host answers (the workstation always does)
    pressure,  \* h -> "ok", or "high", which admits no new heavy run there
    awayAsked  \* ghost: r -> r's host was away when r was asked

vars == <<req, lease, up, pressure, awayAsked>>

-----------------------------------------------------------------------------

\* The slots of host h the unreleased leases hold.
Held(h) == Cardinality({r \in Reqs : lease[r] = h})

\* The host whose slot r's grant reads and takes, and the host whose pressure it reads.
SlotOf(r) == IF Break = "OtherHostSlot" THEN Local ELSE HostOf[r]
PressureOf(r) == IF Break = "SharedPressure" THEN Local ELSE HostOf[r]

Init ==
    /\ req = [r \in Reqs |-> "idle"]
    /\ lease = [r \in Reqs |-> "none"]
    /\ up = [h \in Hosts |-> TRUE]
    /\ pressure = [h \in Hosts |-> "ok"]
    /\ awayAsked = [r \in Reqs |-> FALSE]

\* A run is asked for: on another host its placement finds the host first, and a host away
\* refuses it at once, before any request. Under NoPlace the request goes in unfound.
Ask(r) ==
    /\ req[r] = "idle"
    /\ awayAsked' = [awayAsked EXCEPT ![r] = ~up[HostOf[r]]]
    /\ req' = [req EXCEPT ![r] = IF ~up[HostOf[r]] /\ Break # "NoPlace" THEN "away" ELSE "queued"]
    /\ UNCHANGED <<lease, up, pressure>>

\* The grant: one step that reads the slots its host's leases hold and that host's pressure.
Grant(r) ==
    /\ req[r] = "queued"
    /\ Held(SlotOf(r)) < Cap[SlotOf(r)]
    /\ pressure[PressureOf(r)] = "ok"
    /\ req' = [req EXCEPT ![r] = "granted"]
    /\ lease' = [lease EXCEPT ![r] = SlotOf(r)]
    /\ UNCHANGED <<up, pressure, awayAsked>>

\* A queued request is refused at its deadline, or once its caller is gone; it holds nothing.
Expire(r) ==
    /\ req[r] = "queued"
    /\ req' = [req EXCEPT ![r] = "refused"]
    /\ UNCHANGED <<lease, up, pressure, awayAsked>>

\* The run's work ends, and its owner's word releases the lease.
End(r) ==
    /\ req[r] = "granted"
    /\ req' = [req EXCEPT ![r] = "ended"]
    /\ lease' = [lease EXCEPT ![r] = "none"]
    /\ UNCHANGED <<up, pressure, awayAsked>>

\* Another host goes to sleep or off the network, and comes back.
Away(h) ==
    /\ h # Local
    /\ up' = [up EXCEPT ![h] = ~@]
    /\ UNCHANGED <<req, lease, pressure, awayAsked>>

Pressure(h) ==
    /\ pressure' = [pressure EXCEPT ![h] = IF @ = "ok" THEN "high" ELSE "ok"]
    /\ UNCHANGED <<req, lease, up, awayAsked>>

Next ==
    \/ \E r \in Reqs : Ask(r) \/ Grant(r) \/ Expire(r) \/ End(r)
    \/ \E h \in Hosts : Away(h) \/ Pressure(h)

Spec == Init /\ [][Next]_vars /\ \A r \in Reqs : WF_vars(Grant(r)) /\ WF_vars(Expire(r))

-----------------------------------------------------------------------------

TypeOK ==
    /\ req \in [Reqs -> States]
    /\ lease \in [Reqs -> Hosts \cup {"none"}]
    /\ up \in [Hosts -> BOOLEAN] /\ up[Local]
    /\ pressure \in [Hosts -> {"ok", "high"}]
    /\ awayAsked \in [Reqs -> BOOLEAN]

\* Each host's held slots never pass its capacity.
CapacityHolds == \A h \in Hosts : Held(h) <= Cap[h]

\* A lease holds only a slot of its own request's host: a run on one host never takes another's.
OwnHost == \A r \in Reqs : lease[r] \in {"none", HostOf[r]}

\* Only a granted run holds a slot.
OnlyGrantedHold == \A r \in Reqs : lease[r] # "none" <=> req[r] = "granted"

\* A host's slots are independent: a queued run whose own host has a free slot and admits
\* it can be granted now, whatever the other host holds or reads.
HostUnaffected ==
    \A r \in Reqs :
        (req[r] = "queued" /\ Held(HostOf[r]) < Cap[HostOf[r]] /\ pressure[HostOf[r]] = "ok")
            => ENABLED Grant(r)

\* A run asked for while its host was away is refused at once, and so never holds a slot.
AwayRefusedAtOnce == \A r \in Reqs : awayAsked[r] => req[r] = "away" /\ lease[r] = "none"

\* No new heavy run on a host whose own pressure is high.
NoHeavyUnderHigh ==
    [][\A r \in Reqs : lease[r] = "none" /\ lease'[r] # "none" => pressure[HostOf[r]] = "ok"]_vars

\* Every queued run is answered: granted, or refused at its deadline.
QueuedIsAnswered == \A r \in Reqs : req[r] = "queued" ~> req[r] # "queued"

=============================================================================
