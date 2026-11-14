-------------------------------- MODULE Team --------------------------------
(***************************************************************************)
(* The agents of one project, their messages, their claims on each other   *)
(* and their services, and restarts of the framework: a message stored,    *)
(* then typed once into an ended turn; a fix under a claim on the target's *)
(* current state; a service owned by one agent and ended or kept when its  *)
(* owner ends. An agent of a second project calls too, and is refused.     *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework (none built yet):          *)
(*   Mailbox   the messages table: each row's addressee, where it goes,    *)
(*             and queued, sending, delivered (durable); the sends under   *)
(*             way (in memory). It types through Control's checked write,  *)
(*             with the same sending mark and settle as a delegate's       *)
(*             report (Delegate.tla);                                      *)
(*   Grants    who may act on whom, and the claims table (durable); the    *)
(*             fix a claim's call runs (in memory);                        *)
(*   Services  each service's owner, its keep flag, and its end with its   *)
(*             owner (durable);                                            *)
(*   MCP       the calls: message, interrupt, respawn, stop,               *)
(*             service_start and a hand-on, each with its caller's fixed   *)
(*             identity.                                                   *)
(*                                                                         *)
(* Left abstract: the text of a message and the line that says it was      *)
(* sent on to the parent; the screen and the input box (Control's write    *)
(* checks them in one step); reading tools, which change nothing; the      *)
(* answer tool (Intake.tla); a service's own process, logs, waits,         *)
(* restarts and fixes, and its claims, which work as an agent's do; how a  *)
(* stuck agent is seen. A parent's move is its process dying and a respawn *)
(* (Move.tla). A delegate's own end, once its report is delivered, is one  *)
(* step (Delegate.tla). A caller's own state is not checked: a call may    *)
(* come from a subagent while the caller's main turn is stuck. A person    *)
(* prompts the parent only; a delegate's turns come from its brief,        *)
(* messages and respawns, to keep the state small. A message               *)
(* enters the transcript in the step it is typed. A fix either helps or    *)
(* not, in the step it acts. The number of each agent's state (`epoch`)    *)
(* stands for what the framework reads of it; it moves when the agent      *)
(* sticks, dies, is fixed or ends.                                         *)
(*                                                                         *)
(* Fairness: the framework's steps happen while they stay possible, and a  *)
(* working turn ends unless the agent sticks. Prompts may take a target's  *)
(* turn each time a message waits for it, so the ask and the typed write   *)
(* are strongly fair, as in Delegate.tla. Agents' calls happen or not.     *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Team_<value>.cfg that TLC must fail.                        *)
(*                                                                         *)
(* Defense in depth, with no Break: Redirected's check that the row still  *)
(* goes to its addressee, behind ParentNeverStopped (the parent never ends,*)
(* so a message sent on to it is never sent on again); FixActs' check of   *)
(* the target's process for an interrupt or a respawn, behind its check of *)
(* the claimed state's number (stuck and dead are left only by steps that  *)
(* move it). For a stop the process check is Control's checked write, as   *)
(* the /exit of Move.tla.                                                  *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Agents,       \* the project's agents: its parent and its delegates
    Parent,       \* the project's parent session
    Foreign,      \* agents of another project
    Services,     \* the project's service names
    MaxMsgs,      \* messages sent, all senders together
    MaxFaults,    \* times an agent sticks or dies, all agents together
    MaxRestarts,  \* restarts of the framework
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "IntoRunningTurn",       \* a message is typed without checking that the turn has ended
    "RedeliverAfterRestart", \* a send cut off by a restart is queued again unread
    "RedirectUnsettled",     \* a row cut off while sending is sent on to the parent unsettled
    "NoRedirect",            \* a message to an ended delegate is never sent on
    "NoOrder",               \* a message is typed before an earlier one to the same addressee
    "TwoClaims",             \* a claim does not check for one on the same state
    "ClaimInMemory",         \* claims are held in memory, not in the table
    "StaleFix",              \* a fix acts without checking that the claimed state is current
    "SelfFix",               \* an agent may claim itself
    "StopParent",            \* an agent may stop the parent
    "CrossProject",          \* a call to another project's agent is not refused
    "OwnerClearedFirst",     \* an ended owner is cleared before its service ends
    "NoOwnerWatch"           \* a service whose owner ended is not ended
}

ASSUME Break \in Breaks
ASSUME Parent \in Agents /\ Agents \cap Foreign = {}
ASSUME MaxMsgs \in Nat /\ MaxFaults \in Nat /\ MaxRestarts \in Nat

None == "none"
All == Agents \cup Foreign
Delegates == Agents \ {Parent}
Project(a) == IF a \in Foreign THEN "other" ELSE "own"
Ids == 1..MaxMsgs
MaxEpoch == 2 * MaxFaults + 1
Kinds == {"interrupt", "respawn", "stop"}
Needs == [interrupt |-> "stuck", respawn |-> "dead", stop |-> "idle"]
NoMsg == [from |-> Parent, to |-> Parent, dest |-> Parent, st |-> "none"]

VARIABLES
    up,        \* the framework runs
    restarts,  \* restarts so far
    proc,      \* a -> "working", "idle", "stuck", "dead", "ended"
    epoch,     \* a -> the number of a's state
    faults,    \* sticks and deaths so far
    msgs,      \* table: i -> [from, to (addressee), dest (where it goes), st]
    msend,     \* in memory: i -> "none", "asked" (row says sending), "sent" (typed, row not marked)
    inbox,     \* a -> the message ids in a's transcript, in order
    claims,    \* table: the claims, [by, t, ep, kind]
    done,      \* table: the claims whose call has ended
    calls,     \* in memory: the claims whose fix is under way
    fixed,     \* ghost: the states <<t, ep>> a fix acted on
    svc,       \* table: s -> "none", "running", "ended"
    owner,     \* table: s -> its owner, or None
    keep,      \* table: s -> kept for the owner's parent when the owner ends
    wrong      \* ghost: what a guard should have refused

agentVars == <<proc, epoch, faults>>
msgVars == <<msgs, msend, inbox>>
claimVars == <<claims, done, calls, fixed>>
svcVars == <<svc, owner, keep>>
vars == <<up, restarts, agentVars, msgVars, claimVars, svcVars, wrong>>

Sent == {i \in Ids : msgs[i].st # "none"}
Live(a) == IF a \in Foreign THEN TRUE ELSE proc[a] # "ended"

-----------------------------------------------------------------------------
Init ==
    /\ up = TRUE /\ restarts = 0
    /\ proc = [a \in Agents |-> IF a = Parent THEN "idle" ELSE "working"]
    /\ epoch = [a \in Agents |-> 0] /\ faults = 0
    /\ msgs = [i \in Ids |-> NoMsg] /\ msend = [i \in Ids |-> "none"]
    /\ inbox = [a \in Agents |-> <<>>]
    /\ claims = {} /\ done = {} /\ calls = {} /\ fixed = {}
    /\ svc = [s \in Services |-> "none"] /\ owner = [s \in Services |-> None]
    /\ keep = [s \in Services |-> FALSE]
    /\ wrong = {}

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; what it holds in memory does not *)

FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ msend' = [i \in Ids |-> "none"]
    /\ calls' = {}
    /\ IF Break = "ClaimInMemory" THEN claims' = {} /\ done' = {} ELSE UNCHANGED <<claims, done>>
    /\ UNCHANGED <<agentVars, msgs, inbox, fixed, svcVars, wrong>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<restarts, agentVars, msgVars, claimVars, svcVars, wrong>>

-----------------------------------------------------------------------------
(* The agents: turns, a person's prompt to the parent; sticking, dying, ending *)

\* A delegate starts on its brief; its later turns come from messages and
\* respawns.
Prompted(a) ==
    /\ a = Parent /\ proc[a] = "idle" /\ proc' = [proc EXCEPT ![a] = "working"]
    /\ UNCHANGED <<up, restarts, epoch, faults, msgVars, claimVars, svcVars, wrong>>

TurnEnds(a) ==
    /\ proc[a] = "working" /\ proc' = [proc EXCEPT ![a] = "idle"]
    /\ UNCHANGED <<up, restarts, epoch, faults, msgVars, claimVars, svcVars, wrong>>

Faults(a) ==
    /\ faults < MaxFaults
    /\ \/ (proc[a] = "working" /\ proc' = [proc EXCEPT ![a] = "stuck"])
       \/ (proc[a] \in {"working", "idle", "stuck"} /\ proc' = [proc EXCEPT ![a] = "dead"])
    /\ epoch' = [epoch EXCEPT ![a] = @ + 1] /\ faults' = faults + 1
    /\ UNCHANGED <<up, restarts, msgVars, claimVars, svcVars, wrong>>

\* A delegate ends once its report is delivered (Delegate.tla).
DelegateEnds(d) ==
    /\ d \in Delegates /\ proc[d] = "idle"
    /\ proc' = [proc EXCEPT ![d] = "ended"] /\ epoch' = [epoch EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<up, restarts, faults, msgVars, claimVars, svcVars, wrong>>

-----------------------------------------------------------------------------
(* Mailbox: a message stored, then typed into an ended turn, once *)

\* Grants: messages are open within the project, and refused across.
Send(c, t) ==
    /\ up /\ c # t /\ Live(c) /\ {c, t} \cap Agents # {}
    /\ Project(c) = Project(t) \/ Break = "CrossProject"
    /\ Cardinality(Sent) < MaxMsgs
    /\ LET i == Cardinality(Sent) + 1
       IN msgs' = [msgs EXCEPT ![i] = [from |-> c, to |-> t, dest |-> t, st |-> "queued"]]
    /\ wrong' = wrong \cup (IF Project(c) = Project(t) THEN {} ELSE {"project"})
    /\ UNCHANGED <<up, restarts, agentVars, msend, inbox, claimVars, svcVars>>

Earlier(i) == {j \in 1..(i - 1) : msgs[j].from = msgs[i].from /\ msgs[j].to = msgs[i].to}
NextInOrder(i) == Break = "NoOrder" \/ \A j \in Earlier(i) : msgs[j].st = "delivered"

\* Once the target's turn has ended, the row says "sending" before the write.
DeliveryAsked(i) ==
    /\ up /\ msgs[i].st = "queued" /\ msend[i] = "none" /\ msgs[i].dest \in Agents
    /\ proc[msgs[i].dest] = "idle" /\ NextInOrder(i)
    /\ msgs' = [msgs EXCEPT ![i].st = "sending"] /\ msend' = [msend EXCEPT ![i] = "asked"]
    /\ UNCHANGED <<up, restarts, agentVars, inbox, claimVars, svcVars, wrong>>

Typeable(a) ==
    proc[a] = "idle" \/ (Break = "IntoRunningTurn" /\ proc[a] \in {"working", "stuck"})

\* Control's checked write: the message is the target's new turn.
DeliveryTyped(i) ==
    LET a == msgs[i].dest IN
    /\ up /\ msend[i] = "asked" /\ Typeable(a)
    /\ msend' = [msend EXCEPT ![i] = "sent"]
    /\ inbox' = [inbox EXCEPT ![a] = Append(@, i)]
    /\ proc' = [proc EXCEPT ![a] = "working"]
    /\ wrong' = wrong \cup (IF proc[a] = "idle" THEN {} ELSE {"running turn"})
    /\ UNCHANGED <<up, restarts, epoch, faults, msgs, claimVars, svcVars>>

DeliveryRefused(i) ==
    /\ up /\ msend[i] = "asked" /\ ~Typeable(msgs[i].dest)
    /\ msend' = [msend EXCEPT ![i] = "none"] /\ msgs' = [msgs EXCEPT ![i].st = "queued"]
    /\ UNCHANGED <<up, restarts, agentVars, inbox, claimVars, svcVars, wrong>>

DeliveryMarked(i) ==
    /\ up /\ msend[i] = "sent"
    /\ msend' = [msend EXCEPT ![i] = "none"] /\ msgs' = [msgs EXCEPT ![i].st = "delivered"]
    /\ UNCHANGED <<up, restarts, agentVars, inbox, claimVars, svcVars, wrong>>

InTranscript(i, a) == \E k \in DOMAIN inbox[a] : inbox[a][k] = i

\* A restart cut off a send: the target's transcript says whether it went in.
SendingSettled(i) ==
    /\ up /\ msgs[i].st = "sending" /\ msend[i] = "none"
    /\ msgs' = [msgs EXCEPT ![i].st =
                  IF InTranscript(i, msgs[i].dest) /\ Break # "RedeliverAfterRestart"
                    THEN "delivered" ELSE "queued"]
    /\ UNCHANGED <<up, restarts, agentVars, msend, inbox, claimVars, svcVars, wrong>>

\* A message to a delegate that has ended goes to the parent instead, from
\* a settled row only.
Redirected(i) ==
    /\ up /\ Break # "NoRedirect"
    /\ msgs[i].to \in Delegates /\ proc[msgs[i].to] = "ended" /\ msgs[i].dest = msgs[i].to
    /\ \/ msgs[i].st = "queued"
       \/ (Break = "RedirectUnsettled" /\ msgs[i].st = "sending" /\ msend[i] = "none")
    /\ msgs' = [msgs EXCEPT ![i].dest = Parent, ![i].st = "queued"]
    /\ UNCHANGED <<up, restarts, agentVars, msend, inbox, claimVars, svcVars, wrong>>

-----------------------------------------------------------------------------
(* Grants: a fix takes a claim on the target's current state first *)

Kind(t) == CASE proc[t] = "stuck" -> "interrupt"
             [] proc[t] = "dead" -> "respawn"
             [] OTHER -> "stop"

ClaimTaken(c, t) ==
    LET r == [by |-> c, t |-> t, ep |-> epoch[t], kind |-> Kind(t)] IN
    /\ up /\ Live(c) /\ t \in Agents /\ r \notin claims
    /\ proc[t] \in {"stuck", "dead", "idle"}
    /\ c # t \/ Break = "SelfFix"
    /\ r.kind # "stop" \/ t # Parent \/ Break = "StopParent"
    /\ Project(c) = Project(t) \/ Break = "CrossProject"
    /\ (~\E q \in claims : q.t = t /\ q.ep = epoch[t]) \/ Break = "TwoClaims"
    /\ claims' = claims \cup {r} /\ calls' = calls \cup {r}
    /\ wrong' = wrong \cup (IF c = t THEN {"self"} ELSE {})
                      \cup (IF r.kind = "stop" /\ t = Parent THEN {"parent"} ELSE {})
                      \cup (IF Project(c) = Project(t) THEN {} ELSE {"project"})
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, done, fixed, svcVars>>

CanAct(r) == (epoch[r.t] = r.ep \/ Break = "StaleFix") /\ proc[r.t] = Needs[r.kind]

\* The fix acts on the state it claimed. An interrupt or a respawn may not
\* help; the state is then still claimed.
FixActs(r) ==
    /\ up /\ r \in calls /\ CanAct(r)
    /\ \/ /\ proc' = [proc EXCEPT ![r.t] = CASE r.kind = "interrupt" -> "idle"
                                             [] r.kind = "respawn" -> "working"
                                             [] OTHER -> "ended"]
          /\ epoch' = [epoch EXCEPT ![r.t] = @ + 1]
       \/ (r.kind # "stop" /\ UNCHANGED <<proc, epoch>>)
    /\ calls' = calls \ {r} /\ done' = done \cup {r}
    /\ fixed' = fixed \cup {<<r.t, epoch[r.t]>>}
    /\ wrong' = wrong \cup (IF <<r.t, epoch[r.t]>> \in fixed THEN {"twice"} ELSE {})
                      \cup (IF epoch[r.t] = r.ep THEN {} ELSE {"stale"})
    /\ UNCHANGED <<up, restarts, faults, msgVars, claims, svcVars>>

FixRefused(r) ==
    /\ up /\ r \in calls /\ ~CanAct(r)
    /\ calls' = calls \ {r} /\ done' = done \cup {r}
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claims, fixed, svcVars, wrong>>

\* A restart cut off the call: the claim ends, and its fix is never sent again.
ClaimSettled(r) ==
    /\ up /\ r \in claims \ done /\ r \notin calls
    /\ done' = done \cup {r}
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claims, calls, fixed, svcVars, wrong>>

-----------------------------------------------------------------------------
(* Services: one owner; ended with it, or kept for its parent, or handed on *)

ServiceStarts(a, s) ==
    /\ up /\ svc[s] = "none" /\ proc[a] # "ended"
    /\ svc' = [svc EXCEPT ![s] = "running"] /\ owner' = [owner EXCEPT ![s] = a]
    /\ keep' \in {[keep EXCEPT ![s] = k] : k \in BOOLEAN}
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, wrong>>

ServiceHanded(s, b) ==
    /\ up /\ svc[s] = "running" /\ owner[s] \in Agents /\ owner[s] # b
    /\ proc[owner[s]] # "ended" /\ proc[b] # "ended"
    /\ owner' = [owner EXCEPT ![s] = b]
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, svc, keep, wrong>>

ServiceOwnerEnded(s) ==
    /\ up /\ svc[s] = "running" /\ owner[s] \in Agents /\ proc[owner[s]] = "ended"
    /\ keep[s] \/ Break # "NoOwnerWatch"
    /\ IF keep[s]
         THEN owner' = [owner EXCEPT ![s] = Parent] /\ UNCHANGED svc
         ELSE /\ owner' = [owner EXCEPT ![s] = None]
              /\ svc' = IF Break = "OwnerClearedFirst" THEN svc ELSE [svc EXCEPT ![s] = "ended"]
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, keep, wrong>>

-----------------------------------------------------------------------------
Next ==
    \/ FrameworkDies \/ FrameworkStarts
    \/ \E a \in Agents : Prompted(a) \/ TurnEnds(a) \/ Faults(a) \/ DelegateEnds(a)
    \/ \E c, t \in All : Send(c, t) \/ ClaimTaken(c, t)
    \/ \E i \in Ids : \/ DeliveryAsked(i) \/ DeliveryTyped(i) \/ DeliveryRefused(i)
                      \/ DeliveryMarked(i) \/ SendingSettled(i) \/ Redirected(i)
    \/ \E r \in claims : FixActs(r) \/ FixRefused(r) \/ ClaimSettled(r)
    \/ \E s \in Services : ServiceOwnerEnded(s)
                           \/ \E a \in Agents : ServiceStarts(a, s) \/ ServiceHanded(s, a)

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A a \in Agents : WF_vars(TurnEnds(a))
    /\ \A i \in Ids :
         /\ SF_vars(DeliveryAsked(i)) /\ SF_vars(DeliveryTyped(i))
         /\ WF_vars(DeliveryTyped(i) \/ DeliveryRefused(i))
         /\ WF_vars(DeliveryMarked(i)) /\ WF_vars(SendingSettled(i)) /\ WF_vars(Redirected(i))
    /\ WF_vars(\E r \in claims : FixActs(r) \/ FixRefused(r))
    /\ WF_vars(\E r \in claims : ClaimSettled(r))
    /\ \A s \in Services : WF_vars(ServiceOwnerEnded(s))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ proc \in [Agents -> {"working", "idle", "stuck", "dead", "ended"}]
    /\ epoch \in [Agents -> 0..MaxEpoch]
    /\ msend \in [Ids -> {"none", "asked", "sent"}]
    /\ \A i \in Ids : msgs[i].st \in {"none", "queued", "sending", "delivered"}
    /\ claims \subseteq [by : All, t : Agents, ep : 0..MaxEpoch, kind : Kinds]
    /\ calls \subseteq claims \ done /\ done \subseteq claims
    /\ svc \in [Services -> {"none", "running", "ended"}]
    /\ owner \in [Services -> Agents \cup {None}]

Count(i) == Cardinality(UNION {{<<a, k>> : k \in {n \in DOMAIN inbox[a] : inbox[a][n] = i}}
                                : a \in Agents})

\* Each message is in one transcript at most once, wherever it went.
DeliveredAtMostOnce == \A i \in Ids : Count(i) <= 1

\* Only into a turn that has ended.
OnlyIntoEndedTurn == "running turn" \notin wrong

\* A sender's messages to one addressee arrive in the order sent.
InOrder ==
    \A a \in Agents : \A k, l \in DOMAIN inbox[a] :
        LET m == msgs[inbox[a][k]]  n == msgs[inbox[a][l]] IN
        k < l /\ m.from = n.from /\ m.to = n.to => inbox[a][k] < inbox[a][l]

\* At most one claim holds a target's state, and a state is fixed at most once.
OneClaimPerState == \A q, r \in claims : q.t = r.t /\ q.ep = r.ep => q = r
OneFixPerState == "twice" \notin wrong
FixOnClaimedState == "stale" \notin wrong

NoSelfFix == "self" \notin wrong
ParentNeverStopped == "parent" \notin wrong /\ proc[Parent] # "ended"
SameProjectOnly == "project" \notin wrong

\* A running service has one owner of the project; an ended one has none.
OneOwner ==
    \A s \in Services : /\ svc[s] = "running" => owner[s] \in Agents
                        /\ svc[s] # "running" => owner[s] = None

\* The agent a message is for now: its addressee, or the addressee's parent
\* once the addressee has ended.
Recipient(i) == IF msgs[i].to \notin Delegates THEN Parent
                ELSE IF proc[msgs[i].to] = "ended" THEN Parent ELSE msgs[i].to
Waiting(i) == msgs[i].st \in {"queued", "sending"} /\ msgs[i].to \in Agents

\* A message to a live agent, one whose turn ends again and again, is delivered.
MessageDelivered ==
    \A i \in Ids : []<>(proc[Recipient(i)] = "idle")
                     => [](Waiting(i) => <>(msgs[i].st = "delivered"))

\* A claim's call ends: its fix verified, or the claim released.
\* Claims are bounded and a claim never leaves `done`, so this says each
\* claim's call ends.
ClaimEnds == <>[](claims = done)

\* A service whose owner ended without keeping it ends.
ServiceEndsWithOwner ==
    \A s \in Services :
        (svc[s] = "running" /\ owner[s] \in Agents /\ proc[owner[s]] = "ended" /\ ~keep[s])
            ~> svc[s] = "ended"

=============================================================================
