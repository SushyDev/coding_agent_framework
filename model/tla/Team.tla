-------------------------------- MODULE Team --------------------------------
(***************************************************************************)
(* The tree of two projects: each project's main session and its           *)
(* delegates, their messages, their claims on each other, their services,  *)
(* and restarts of the framework. A message goes along an edge of the      *)
(* tree only: a main session to its delegates and to the other main        *)
(* session, a delegate to its main session. It is stored, then typed once  *)
(* into an ended turn. One to a delegate that ended first is not typed:    *)
(* its row says so, and the sender reads that in place of delivered. A fix *)
(* is a main session's act on its own delegate, under a claim on the       *)
(* delegate's current state. A service is owned by                         *)
(* one agent, fixed by its owner or the owner's parent, handed to the      *)
(* owner's parent or a child, and ended or kept when its owner ends.       *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework (only Grants' checks are   *)
(* built, F-73):                                                           *)
(*   Grants    the tree's edges, by which it decides whether a caller may  *)
(*             message, fix or hand to a target; the claims table          *)
(*             (durable); the fix a claim's call runs (in memory);         *)
(*   Mailbox   the messages table: each row's sender, addressee, and       *)
(*             queued, sending, delivered or ended (durable); the sends    *)
(*             under way (in memory). It writes into a main session        *)
(*             through Control's checked write, and into a delegate        *)
(*             through Stream under a uuid, with the same sending mark     *)
(*             and settle as a delegate's report (Delegate.tla);           *)
(*   Services  each service's owner, its keep flag, its fixes and hand-ons,*)
(*             and its end with its owner (durable);                       *)
(*   MCP       the calls: message, interrupt, resume, stop, service_start, *)
(*             service_restart, service_stop and service_hand, each with   *)
(*             its caller's fixed identity.                                *)
(*                                                                         *)
(* Left abstract: the text of a message, and how its sender reads its row; *)
(* the screen and the input box (Control's write checks them in one step); *)
(* reading tools, which change nothing; the answer tool (Intake.tla);      *)
(* subagents, which the framework does not reach, so a delegate has no     *)
(* child here; a service's own                                             *)
(* process, logs, waits and host, and the claim its fix takes, which works *)
(* as an agent's does (a restart and a stop are one step that may end it); *)
(* how a stuck agent is seen; a person's acts on a main session (a stop or *)
(* a move), so a main session never ends. A delegate's own end, once its   *)
(* report is delivered, is one step (Delegate.tla). A caller's own state is*)
(* not checked: a call may come from a subagent while the caller's main    *)
(* turn is stuck, so one caller may make the same call twice at once. A    *)
(* person prompts a main session only; a delegate's turns come from its    *)
(* brief, messages and resumes, to keep the state small. A message enters  *)
(* the transcript in the step it is typed. A fix either helps or not, in   *)
(* the step it acts. The number of each agent's state (`epoch`) stands for *)
(* what the framework reads of it; it moves when the agent sticks, dies, is*)
(* fixed or ends. An interrupt takes a stuck delegate, a resume a dead one,*)
(* a stop an idle one.                                                     *)
(*                                                                         *)
(* Fairness: the framework's steps happen while they stay possible, and a  *)
(* working turn ends unless the agent sticks. Prompts may take a target's  *)
(* turn each time a message waits for it, so the ask and the typed write   *)
(* are strongly fair, as in Delegate.tla. Agents' calls happen or not.     *)
(*                                                                         *)
(* Break: "none" is the design. Every other value is one wrong guard and   *)
(* has a Break_Team_<value>.cfg that TLC must fail. Grants' fix check is   *)
(* one relation, "the caller is the target's main session": no agent fixes *)
(* itself and none fixes a main session, because a main session has no    *)
(* parent. SiblingFix, SelfFix and FixMain each widen that relation by one *)
(* wrong case, as a mistaken check would.                                  *)
(*                                                                         *)
(* Defense in depth, with no Break: FixActs' check of the target's process *)
(* for an interrupt or a resume, behind its check of the claimed state's   *)
(* number (stuck and dead are left only by steps that move it). For a stop *)
(* the process check is Control's checked write, as the /exit of Move.tla. *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Projects,     \* each project's agents: its main session and its delegates
    Mains,        \* the main sessions, one in each project
    Services,     \* the service names
    MaxMsgs,      \* messages sent, all senders together
    MaxFaults,    \* times an agent sticks or dies, all agents together
    MaxRestarts,  \* restarts of the framework
    Break         \* "none", or the guard made wrong (see Breaks)

Breaks == {
    "none",
    "IntoRunningTurn",       \* a message is typed without checking that the turn has ended
    "RedeliverAfterRestart", \* a send cut off by a restart is queued again unread
    "EndedUnsettled",        \* a row cut off while sending is marked ended, unsettled
    "NoEndedMark",           \* a message to an ended delegate is never marked ended
    "NoOrder",               \* a message is typed before an earlier one to the same addressee
    "OffEdge",               \* a message is stored without checking that it goes along an edge
    "TwoClaims",             \* a claim does not check for one on the same state
    "ClaimInMemory",         \* claims are held in memory, not in the table
    "StaleFix",              \* a fix acts without checking that the claimed state is current
    "SiblingFix",            \* a delegate may fix another delegate of its main session
    "SelfFix",               \* an agent may fix itself
    "FixMain",               \* a fix is granted along any edge, so a main session may be fixed
    "ServiceFixAnyone",      \* any agent may restart or stop a service
    "HandToSibling",         \* a service may be handed to a sibling of its owner
    "HandByOther",           \* an agent other than the owner may hand a service on
    "OwnerClearedFirst",     \* an ended owner is cleared before its service ends
    "NoOwnerWatch"           \* a service whose owner ended is not ended
}

Agents == UNION Projects
Delegates == Agents \ Mains

ASSUME Break \in Breaks
ASSUME \A P \in Projects : Cardinality(P \cap Mains) = 1
ASSUME \A P, Q \in Projects : P # Q => P \cap Q = {}
ASSUME Mains \subseteq Agents
ASSUME MaxMsgs \in Nat /\ MaxFaults \in Nat /\ MaxRestarts \in Nat

None == "none"
Ids == 1..MaxMsgs
MaxEpoch == 2 * MaxFaults + 1
Kinds == {"interrupt", "resume", "stop"}
Needs == [interrupt |-> "stuck", resume |-> "dead", stop |-> "idle"]
AnyMain == CHOOSE m \in Mains : TRUE
NoMsg == [from |-> AnyMain, to |-> AnyMain, st |-> "none"]

\* The tree. A main session is a root; a delegate's parent is its main session.
Main(a) == CHOOSE m \in Mains : \E P \in Projects : {a, m} \subseteq P
IsChild(t, c) == t \in Delegates /\ Main(t) = c
Siblings(a, b) == a # b /\ a \in Delegates /\ b \in Delegates /\ Main(a) = Main(b)

\* Grants: the edges a message goes along.
Edge(c, t) == \/ c \in Mains /\ t \in Mains /\ c # t
              \/ IsChild(t, c)
              \/ IsChild(c, t)

\* Grants: a fix is a parent's act on its own child. Each Break widens it by one case.
MayFix(c, t) == \/ IsChild(t, c)
                \/ Break = "SiblingFix" /\ Siblings(c, t)
                \/ Break = "SelfFix" /\ c = t
                \/ Break = "FixMain" /\ Edge(c, t)

\* Grants: a service is fixed by its owner or the owner's parent.
MayFixService(c, o) == c = o \/ IsChild(o, c) \/ Break = "ServiceFixAnyone"

\* Grants: the owner hands a service to its parent or one of its children.
MayHand(c, o, b) == /\ c = o \/ Break = "HandByOther"
                    /\ \/ IsChild(o, b) \/ IsChild(b, o)
                       \/ Break = "HandToSibling" /\ Siblings(o, b)

VARIABLES
    up,        \* the framework runs
    restarts,  \* restarts so far
    proc,      \* a -> "working", "idle", "stuck", "dead", "ended"
    epoch,     \* a -> the number of a's state
    faults,    \* sticks and deaths so far
    msgs,      \* table: i -> [from, to (addressee), st]
    msend,     \* in memory: i -> "none", "asked" (row says sending), "sent" (typed, row not marked)
    inbox,     \* a -> the message ids in a's transcript, in order
    claims,    \* table: the claims, [by, t, ep, kind, n]
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
Live(a) == proc[a] # "ended"

-----------------------------------------------------------------------------
Init ==
    /\ up = TRUE /\ restarts = 0
    /\ proc = [a \in Agents |-> IF a \in Mains THEN "idle" ELSE "working"]
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
(* The agents: turns, a person's prompt to a main session; sticking, dying, ending *)

\* A delegate starts on its brief; its later turns come from messages and
\* resumes.
Prompted(a) ==
    /\ a \in Mains /\ proc[a] = "idle" /\ proc' = [proc EXCEPT ![a] = "working"]
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
(* Mailbox: a message along an edge, stored, then typed into an ended turn, once *)

Send(c, t) ==
    /\ up /\ Live(c)
    /\ Edge(c, t) \/ (Break = "OffEdge" /\ c # t)
    /\ Cardinality(Sent) < MaxMsgs
    /\ LET i == Cardinality(Sent) + 1
       IN msgs' = [msgs EXCEPT ![i] = [from |-> c, to |-> t, st |-> "queued"]]
    /\ UNCHANGED <<up, restarts, agentVars, msend, inbox, claimVars, svcVars, wrong>>

Earlier(i) == {j \in 1..(i - 1) : msgs[j].from = msgs[i].from /\ msgs[j].to = msgs[i].to}
NextInOrder(i) == Break = "NoOrder" \/ \A j \in Earlier(i) : msgs[j].st = "delivered"

\* Once the target's turn has ended, the row says "sending" before the write.
DeliveryAsked(i) ==
    /\ up /\ msgs[i].st = "queued" /\ msend[i] = "none"
    /\ proc[msgs[i].to] = "idle" /\ NextInOrder(i)
    /\ msgs' = [msgs EXCEPT ![i].st = "sending"] /\ msend' = [msend EXCEPT ![i] = "asked"]
    /\ UNCHANGED <<up, restarts, agentVars, inbox, claimVars, svcVars, wrong>>

Typeable(a) ==
    proc[a] = "idle" \/ (Break = "IntoRunningTurn" /\ proc[a] \in {"working", "stuck"})

\* Control's checked write: the message is the target's new turn.
DeliveryTyped(i) ==
    LET a == msgs[i].to IN
    /\ up /\ msend[i] = "asked" /\ Typeable(a)
    /\ msend' = [msend EXCEPT ![i] = "sent"]
    /\ inbox' = [inbox EXCEPT ![a] = Append(@, i)]
    /\ proc' = [proc EXCEPT ![a] = "working"]
    /\ wrong' = wrong \cup (IF proc[a] = "idle" THEN {} ELSE {"running turn"})
    /\ UNCHANGED <<up, restarts, epoch, faults, msgs, claimVars, svcVars>>

DeliveryRefused(i) ==
    /\ up /\ msend[i] = "asked" /\ ~Typeable(msgs[i].to)
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
                  IF InTranscript(i, msgs[i].to) /\ Break # "RedeliverAfterRestart"
                    THEN "delivered" ELSE "queued"]
    /\ UNCHANGED <<up, restarts, agentVars, msend, inbox, claimVars, svcVars, wrong>>

\* A message to a delegate that has ended is not delivered: its row says the
\* delegate ended before it went in, from a settled row only.
EndedFirst(i) ==
    /\ up /\ Break # "NoEndedMark"
    /\ msgs[i].to \in Delegates /\ proc[msgs[i].to] = "ended"
    /\ \/ msgs[i].st = "queued"
       \/ (Break = "EndedUnsettled" /\ msgs[i].st = "sending" /\ msend[i] = "none")
    /\ msgs' = [msgs EXCEPT ![i].st = "ended"]
    /\ UNCHANGED <<up, restarts, agentVars, msend, inbox, claimVars, svcVars, wrong>>

-----------------------------------------------------------------------------
(* Grants: a parent's fix takes a claim on its child's current state first *)

Kind(t) == CASE proc[t] = "stuck" -> "interrupt"
             [] proc[t] = "dead" -> "resume"
             [] OTHER -> "stop"

\* The caller's calls already on this state: a second one is `n` = 2.
Calls(c, t) == {q \in claims : q.by = c /\ q.t = t /\ q.ep = epoch[t]}

ClaimTaken(c, t) ==
    LET r == [by |-> c, t |-> t, ep |-> epoch[t], kind |-> Kind(t),
              n |-> Cardinality(Calls(c, t)) + 1] IN
    /\ up /\ Live(c) /\ r.n <= 2
    /\ proc[t] \in {"stuck", "dead", "idle"}
    /\ MayFix(c, t)
    /\ (~\E q \in claims : q.t = t /\ q.ep = epoch[t]) \/ Break = "TwoClaims"
    /\ claims' = claims \cup {r} /\ calls' = calls \cup {r}
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, done, fixed, svcVars, wrong>>

CanAct(r) == (epoch[r.t] = r.ep \/ Break = "StaleFix") /\ proc[r.t] = Needs[r.kind]

\* The fix acts on the state it claimed. An interrupt or a resume may not
\* help; the state is then still claimed.
FixActs(r) ==
    /\ up /\ r \in calls /\ CanAct(r)
    /\ \/ /\ proc' = [proc EXCEPT ![r.t] = CASE r.kind = "interrupt" -> "idle"
                                             [] r.kind = "resume" -> "working"
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
(* Services: one owner; fixed by it or its parent; handed along an edge; *)
(* ended with the owner, or kept for its parent                          *)

ServiceStarts(a, s) ==
    /\ up /\ svc[s] = "none" /\ Live(a)
    /\ svc' = [svc EXCEPT ![s] = "running"] /\ owner' = [owner EXCEPT ![s] = a]
    /\ keep' \in {[keep EXCEPT ![s] = k] : k \in BOOLEAN}
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, wrong>>

\* A restart or a stop: a stop ends the service; a restart leaves it running.
ServiceFixed(c, s) ==
    /\ up /\ svc[s] = "running" /\ Live(c) /\ MayFixService(c, owner[s])
    /\ \/ svc' = [svc EXCEPT ![s] = "ended"] /\ owner' = [owner EXCEPT ![s] = None]
       \/ UNCHANGED <<svc, owner>>
    /\ wrong' = wrong \cup (IF c = owner[s] \/ IsChild(owner[s], c) THEN {} ELSE {"service fix"})
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, keep>>

ServiceHanded(c, s, b) ==
    LET o == owner[s] IN
    /\ up /\ svc[s] = "running" /\ o \in Agents /\ o # b
    /\ Live(c) /\ Live(o) /\ Live(b) /\ MayHand(c, o, b)
    /\ owner' = [owner EXCEPT ![s] = b]
    /\ wrong' = wrong \cup (IF c = o /\ (IsChild(o, b) \/ IsChild(b, o)) THEN {} ELSE {"hand"})
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, svc, keep>>

\* A kept service goes to its owner's parent; a main session never ends, so
\* the owner here is a delegate.
ServiceOwnerEnded(s) ==
    /\ up /\ svc[s] = "running" /\ owner[s] \in Agents /\ proc[owner[s]] = "ended"
    /\ keep[s] \/ Break # "NoOwnerWatch"
    /\ IF keep[s]
         THEN owner' = [owner EXCEPT ![s] = Main(owner[s])] /\ UNCHANGED svc
         ELSE /\ owner' = [owner EXCEPT ![s] = None]
              /\ svc' = IF Break = "OwnerClearedFirst" THEN svc ELSE [svc EXCEPT ![s] = "ended"]
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, keep, wrong>>

-----------------------------------------------------------------------------
Next ==
    \/ FrameworkDies \/ FrameworkStarts
    \/ \E a \in Agents : Prompted(a) \/ TurnEnds(a) \/ Faults(a) \/ DelegateEnds(a)
    \/ \E c, t \in Agents : Send(c, t) \/ ClaimTaken(c, t)
    \/ \E i \in Ids : \/ DeliveryAsked(i) \/ DeliveryTyped(i) \/ DeliveryRefused(i)
                      \/ DeliveryMarked(i) \/ SendingSettled(i) \/ EndedFirst(i)
    \/ \E r \in claims : FixActs(r) \/ FixRefused(r) \/ ClaimSettled(r)
    \/ \E s \in Services : \/ ServiceOwnerEnded(s)
                           \/ \E a \in Agents : ServiceStarts(a, s) \/ ServiceFixed(a, s)
                           \/ \E c, b \in Agents : ServiceHanded(c, s, b)

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A a \in Agents : WF_vars(TurnEnds(a))
    /\ \A i \in Ids :
         /\ SF_vars(DeliveryAsked(i)) /\ SF_vars(DeliveryTyped(i))
         /\ WF_vars(DeliveryTyped(i) \/ DeliveryRefused(i))
         /\ WF_vars(DeliveryMarked(i)) /\ WF_vars(SendingSettled(i)) /\ WF_vars(EndedFirst(i))
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
    /\ \A i \in Ids : msgs[i].st \in {"none", "queued", "sending", "delivered", "ended"}
    /\ claims \subseteq [by : Agents, t : Agents, ep : 0..MaxEpoch, kind : Kinds, n : 1..2]
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

\* Every delivered message went along an edge, to its addressee.
AlongEdges ==
    \A a \in Agents : \A k \in DOMAIN inbox[a] :
        LET m == msgs[inbox[a][k]] IN Edge(m.from, m.to) /\ a = m.to

\* A row that says its delegate ended first is true: the message is in no
\* transcript, so its sender is not told it was lost when it went in.
EndedNotDelivered == \A i \in Ids : msgs[i].st = "ended" => Count(i) = 0

\* At most one claim holds a child's state, and a state is fixed at most once.
OneClaimPerState == \A q, r \in claims : q.t = r.t /\ q.ep = r.ep => q = r
OneFixPerState == "twice" \notin wrong
FixOnClaimedState == "stale" \notin wrong

\* Only a parent fixes, and only its own child.
OnlyParentFixes == \A r \in claims : IsChild(r.t, r.by)
NoSelfFix == \A r \in claims : r.by # r.t
MainNeverFixed == /\ \A r \in claims : r.t \notin Mains
                  /\ \A m \in Mains : proc[m] # "ended"

\* A running service has one owner; an ended one has none.
OneOwner ==
    \A s \in Services : /\ svc[s] = "running" => owner[s] \in Agents
                        /\ svc[s] # "running" => owner[s] = None

\* Only the owner or the owner's parent fixes a service.
ServiceFixedByOwnerOrParent == "service fix" \notin wrong

\* A service is handed only by its owner, to the owner's parent or a child.
HandedAlongEdge == "hand" \notin wrong

Waiting(i) == msgs[i].st \in {"queued", "sending"}

\* A message to a live agent, one whose turn ends again and again, is delivered.
MessageDelivered ==
    \A i \in Ids : []<>(proc[msgs[i].to] = "idle")
                     => [](Waiting(i) => <>(msgs[i].st = "delivered"))

\* A message waiting for a delegate that has ended settles: it went in
\* before the end, or its row says the delegate ended first.
EndedMarked ==
    \A i \in Ids : [](Waiting(i) /\ proc[msgs[i].to] = "ended"
                      => <>(msgs[i].st \in {"delivered", "ended"}))

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
