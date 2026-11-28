----------------------------- MODULE RemotePlace -----------------------------
(***************************************************************************)
(* Where a heavy run goes when its entry names hosts in order (F-304).    *)
(* The entry `host: ["r1", "r2", "ws"]` names two other hosts and then     *)
(* the workstation. The plug reads what `Hosts` keeps of each host (no     *)
(* ssh) and takes the first one it does not hold away; the workstation is  *)
(* never away. The run's placement on that host finds the host over ssh;   *)
(* a placement that answers away before anything was sent falls back to    *)
(* the next host the plug does not hold away, once. A job that was sent is *)
(* never moved: its end is its host's, or unknown.                         *)
(*                                                                         *)
(* Models CodingAgentFramework.Runs.Plug (the choice over the entry's      *)
(* hosts, read from `Hosts.held/2`, and the one fallback),                 *)
(* CodingAgentFramework.Runs.Remote (a fallback only on a placement        *)
(* refused `host_away` with no job row), CodingAgentFramework.Hosts (what  *)
(* it keeps, found again at a placement or once its retry is due) and      *)
(* CodingAgentFramework.Jobs (the placement before the row and the lease,  *)
(* the start settled by its reply or by the fence).                        *)
(*                                                                         *)
(* One run alone: other work on the hosts is the environment, which finds  *)
(* a host and keeps the answer at any time. RemoteRun.tla checks the       *)
(* stream and the slot once a job runs; HostSlots.tla the slots per host;  *)
(* Host.tla the placement's find. Here the lease is granted or expires.    *)
(* The workstation is last, so one host is always eligible; an entry of    *)
(* other hosts alone, all held, places its first, as F-296 does.           *)
(*                                                                         *)
(* Fairness: a find answers, a sent start lands or is fenced, a job ends,  *)
(* a host comes back, a lease is granted or expires. Going away gets none. *)
(*                                                                         *)
(* Break: "none" is the design. Every other value changes one rule and has *)
(* a Break_RemotePlace_<value>.cfg that TLC must fail.                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    Break   \* "none", or the rule changed (see Breaks)

Breaks == {
    "none",
    "AskNextEarly",  \* the plug gives a slow placement up and asks the next host while it runs
    "LeaseFirst",    \* the slot is asked before the placement, and kept when it falls back
    "CutAsAway",     \* a start whose reply the host's going away cut is taken as not sent
    "MoveOnAway"     \* a job whose host went away mid-run is started on the next host
}

ASSUME Break \in Breaks

Order == <<"r1", "r2", "ws">>
Local == "ws"
Remote == {"r1", "r2"}
Hosts == Remote \cup {Local}
Steps == {"idle", "finding", "leasing", "starting", "running", "done"}
Jobs == {"none", "sent", "live", "ended", "fenced"}

VARIABLES
    up,       \* r -> the other host answers the workstation
    kept,     \* r -> what `Hosts` keeps of it: "unknown", "ready" or "away"
    step,     \* the run's step
    at,       \* the host the run is at, "none" before its choice
    finding,  \* r -> a placement's find of r is under way for this run
    falls,    \* how many times the run fell back: 0 or 1
    lease,    \* h -> the run holds h's slot
    job,      \* h -> the run's job on h
    ran,      \* how many times the command started, on any host
    out       \* the wrapper's end: "none", "code", "unknown" or "refused"

vars == <<up, kept, step, at, finding, falls, lease, job, ran, out>>

-----------------------------------------------------------------------------

Idx(h) == CHOOSE i \in 1..Len(Order) : Order[i] = h

\* The plug takes a host it does not hold away, from what is kept.
Eligible(h, k) == IF h = Local THEN TRUE ELSE k[h] # "away"

\* The first eligible host from position i on; the workstation is last, so one is.
FirstFrom(i, k) ==
    Order[CHOOSE j \in i..Len(Order) :
            /\ Eligible(Order[j], k)
            /\ \A m \in i..(j - 1) : ~Eligible(Order[m], k)]

\* The step a run takes on arriving at h: the workstation asks its slot; another host is found
\* first, unless the slot is asked first (the Break).
Arrive(h) ==
    IF h = Local \/ Break = "LeaseFirst"
      THEN /\ step' = "leasing"
           /\ UNCHANGED finding
      ELSE /\ step' = "finding"
           /\ finding' = [finding EXCEPT ![h] = TRUE]

\* The one fallback from h, with `k` what is kept then; a second one is refused, nothing ran.
Fall(h, k) ==
    IF falls = 0
      THEN LET n == FirstFrom(Idx(h) + 1, k) IN
           /\ at' = n
           /\ falls' = 1
           /\ Arrive(n)
           /\ UNCHANGED out
      ELSE /\ step' = "done"
           /\ out' = "refused"
           /\ UNCHANGED <<at, falls, finding>>

Init ==
    /\ up \in [Remote -> BOOLEAN]
    /\ kept \in [Remote -> {"unknown", "ready", "away"}]
    /\ step = "idle"
    /\ at = "none"
    /\ finding = [r \in Remote |-> FALSE]
    /\ falls = 0
    /\ lease = [h \in Hosts |-> FALSE]
    /\ job = [h \in Hosts |-> "none"]
    /\ ran = 0
    /\ out = "none"

\* The plug's choice: no ssh, only what `Hosts` keeps.
Choose ==
    /\ step = "idle"
    /\ LET h == FirstFrom(1, kept) IN
       /\ at' = h
       /\ Arrive(h)
    /\ UNCHANGED <<up, kept, falls, lease, job, ran, out>>

\* The placement's find answers within its bound and is kept: the host's answer, or away. Away,
\* nothing was sent, and the run falls back. Found first under its slot (the Break), the start
\* follows.
Found(r) ==
    /\ step = "finding"
    /\ at = r
    /\ finding[r]
    /\ IF up[r]
         THEN /\ kept' = [kept EXCEPT ![r] = "ready"]
              /\ step' = IF Break = "LeaseFirst" THEN "starting" ELSE "leasing"
              /\ finding' = [finding EXCEPT ![r] = FALSE]
              /\ UNCHANGED <<at, falls, out>>
         ELSE /\ kept' = [kept EXCEPT ![r] = "away"]
              /\ LET k == [kept EXCEPT ![r] = "away"] IN
                 IF falls = 0
                   THEN LET n == FirstFrom(Idx(r) + 1, k) IN
                        /\ at' = n
                        /\ falls' = 1
                        /\ UNCHANGED out
                        /\ IF n = Local \/ Break = "LeaseFirst"
                             THEN /\ step' = "leasing"
                                  /\ finding' = [finding EXCEPT ![r] = FALSE]
                             ELSE /\ step' = "finding"
                                  /\ finding' = [finding EXCEPT ![r] = FALSE, ![n] = TRUE]
                   ELSE /\ step' = "done"
                        /\ out' = "refused"
                        /\ finding' = [finding EXCEPT ![r] = FALSE]
                        /\ UNCHANGED <<at, falls>>
    /\ UNCHANGED <<up, lease, job, ran>>

\* A find this run no longer waits on answers, and is kept (only under AskNextEarly).
FoundLate(r) ==
    /\ finding[r]
    /\ at # r
    /\ finding' = [finding EXCEPT ![r] = FALSE]
    /\ kept' = [kept EXCEPT ![r] = IF up[r] THEN "ready" ELSE "away"]
    /\ UNCHANGED <<up, step, at, falls, lease, job, ran, out>>

\* The Break: the plug stops waiting on a slow find and falls back while the find runs on.
GiveUpFind(r) ==
    /\ Break = "AskNextEarly"
    /\ step = "finding"
    /\ at = r
    /\ falls = 0
    /\ Fall(r, kept)
    /\ UNCHANGED <<up, kept, lease, job, ran>>

\* The slot of the host the run is at: granted, or the ask expires (refused, nothing ran).
Grant(h) ==
    /\ step = "leasing"
    /\ at = h
    /\ lease' = [lease EXCEPT ![h] = TRUE]
    /\ IF Break = "LeaseFirst" /\ h # Local
         THEN /\ step' = "finding"
              /\ finding' = [finding EXCEPT ![h] = TRUE]
         ELSE /\ step' = "starting"
              /\ UNCHANGED finding
    /\ UNCHANGED <<up, kept, at, falls, job, ran, out>>

Expire ==
    /\ step = "leasing"
    /\ step' = "done"
    /\ out' = "refused"
    /\ UNCHANGED <<up, kept, at, finding, falls, lease, job, ran>>

\* The start is sent under the slot, whether or not the host answers: it may be cut.
Send(h) ==
    /\ step = "starting"
    /\ at = h
    /\ lease[h]
    /\ job[h] = "none"
    /\ job' = [job EXCEPT ![h] = "sent"]
    /\ UNCHANGED <<up, kept, step, at, finding, falls, lease, ran, out>>

\* A start that was sent lands on its host, or the fence keeps it from running.
Land(h) ==
    /\ job[h] = "sent"
    /\ job' = [job EXCEPT ![h] = "live"]
    /\ ran' = ran + 1
    /\ UNCHANGED <<up, kept, step, at, finding, falls, lease, out>>

Reach(h) == IF h = Local THEN TRUE ELSE up[h]

\* The start is settled by its reply, or by a read of the host: running, or fenced (never ran,
\* refused, no fallback).
Started(h) ==
    /\ step = "starting"
    /\ at = h
    /\ job[h] \in {"live", "ended"}
    /\ Reach(h)
    /\ step' = "running"
    /\ UNCHANGED <<up, kept, at, finding, falls, lease, job, ran, out>>

Fence(h) ==
    /\ step = "starting"
    /\ at = h
    /\ job[h] = "sent"
    /\ Reach(h)
    /\ job' = [job EXCEPT ![h] = "fenced"]
    /\ step' = "done"
    /\ out' = "refused"
    /\ UNCHANGED <<up, kept, at, finding, falls, lease, ran>>

\* The Break: the host away while the start's reply was due, taken as a placement refused away.
CutAsAway(r) ==
    /\ Break = "CutAsAway"
    /\ step = "starting"
    /\ at = r
    /\ r \in Remote
    /\ ~up[r]
    /\ job[r] = "sent"
    /\ falls = 0
    /\ Fall(r, kept)
    /\ UNCHANGED <<up, kept, lease, job, ran>>

Exit(h) ==
    /\ job[h] = "live"
    /\ job' = [job EXCEPT ![h] = "ended"]
    /\ UNCHANGED <<up, kept, step, at, finding, falls, lease, ran, out>>

Finish(h) ==
    /\ step = "running"
    /\ at = h
    /\ job[h] = "ended"
    /\ Reach(h)
    /\ step' = "done"
    /\ out' = "code"
    /\ UNCHANGED <<up, kept, at, finding, falls, lease, job, ran>>

\* The host away mid-run: the run ends unknown, and its job runs on there under its slot.
GiveUp(r) ==
    /\ step = "running"
    /\ at = r
    /\ r \in Remote
    /\ ~up[r]
    /\ IF Break = "MoveOnAway" /\ falls = 0
         THEN Fall(r, kept)
         ELSE /\ step' = "done"
              /\ out' = "unknown"
              /\ UNCHANGED <<at, finding, falls>>
    /\ UNCHANGED <<up, kept, lease, job, ran>>

\* The slot is freed once the job's end is read there, or it never ran.
Release(h) ==
    /\ lease[h]
    /\ job[h] \in {"ended", "fenced"}
    /\ Reach(h)
    /\ lease' = [lease EXCEPT ![h] = FALSE]
    /\ UNCHANGED <<up, kept, step, at, finding, falls, job, ran, out>>

\* Other work finds a host and keeps the answer; a kept away is due to be found again.
Find(r) ==
    /\ kept' = [kept EXCEPT ![r] = IF up[r] THEN "ready" ELSE "away"]
    /\ UNCHANGED <<up, step, at, finding, falls, lease, job, ran, out>>

Due(r) ==
    /\ kept[r] = "away"
    /\ kept' = [kept EXCEPT ![r] = "unknown"]
    /\ UNCHANGED <<up, step, at, finding, falls, lease, job, ran, out>>

Go(r) ==
    /\ up[r]
    /\ up' = [up EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<kept, step, at, finding, falls, lease, job, ran, out>>

Back(r) ==
    /\ ~up[r]
    /\ up' = [up EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<kept, step, at, finding, falls, lease, job, ran, out>>

Next ==
    \/ Choose \/ Expire
    \/ \E r \in Remote :
        \/ Found(r) \/ FoundLate(r) \/ GiveUpFind(r) \/ CutAsAway(r) \/ GiveUp(r)
        \/ Find(r) \/ Due(r) \/ Go(r) \/ Back(r)
    \/ \E h \in Hosts :
        \/ Grant(h) \/ Send(h) \/ Land(h) \/ Started(h) \/ Fence(h) \/ Exit(h) \/ Finish(h)
        \/ Release(h)

\* The steps that need no host to answer, and the ones that do. Grouped, so TLC checks few
\* fairness conditions: each group's steps are on one run, and none starves another for ever.
Moves ==
    \/ Choose \/ Expire
    \/ \E r \in Remote : Found(r)
    \/ \E h \in Hosts : Send(h) \/ Land(h) \/ Exit(h)

Settles ==
    \/ \E r \in Remote : GiveUp(r)
    \/ \E h \in Hosts : Started(h) \/ Fence(h) \/ Finish(h) \/ Release(h)

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Moves) /\ SF_vars(Settles)
    /\ \A r \in Remote : WF_vars(Back(r))

-----------------------------------------------------------------------------

TypeOK ==
    /\ up \in [Remote -> BOOLEAN]
    /\ kept \in [Remote -> {"unknown", "ready", "away"}]
    /\ step \in Steps
    /\ at \in Hosts \cup {"none"}
    /\ finding \in [Remote -> BOOLEAN]
    /\ falls \in 0..1
    /\ lease \in [Hosts -> BOOLEAN]
    /\ job \in [Hosts -> Jobs]
    /\ ran \in 0..3
    /\ out \in {"none", "code", "unknown", "refused"}

\* The hosts the run has something at: a find under way, a slot, or a start sent or running.
Places == {r \in Remote : finding[r]} \cup {h \in Hosts : lease[h] \/ job[h] \in {"sent", "live"}}

\* A run goes to at most one host at a time.
OneHost == Cardinality(Places) <= 1

\* The command starts at most once, on any host.
NeverTwice == ran <= 1

\* A run holds at most one slot.
OneSlot == Cardinality({h \in Hosts : lease[h]}) <= 1

\* A job that was sent stays its host's: the run never moves on from it.
NeverMoved == \A h \in Hosts : job[h] \in {"sent", "live", "ended"} => at = h

\* Every run ends: the job's code, unknown, or refused with nothing run.
RunEnds == step # "idle" ~> step = "done"

\* Every slot is freed, a host away or a fallback included.
SlotFreed == \A h \in Hosts : lease[h] ~> ~lease[h]

=============================================================================
