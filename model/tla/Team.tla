-------------------------------- MODULE Team --------------------------------
(***************************************************************************)
(* The tree of two projects: each project's main session and its           *)
(* delegates, their messages, their claims on each other, their services,  *)
(* and restarts of the framework. A message goes along an edge of the      *)
(* tree only: a main session to its delegates and to the other main        *)
(* session, a delegate to its main session. It is stored, then typed once  *)
(* into an ended turn. One to a delegate that ended first is not typed:    *)
(* its row says so, and the sender reads that in place of delivered. A     *)
(* message typed into a delegate is a turn of its own: the result that     *)
(* names it is the delegate's reply, stored once as a message to its main  *)
(* session; when the delegate's process ends first, with no result, a      *)
(* notice from the framework goes there in its place (F-79). A fix         *)
(* is a main session's act on its own delegate, under a claim on the       *)
(* delegate's current state. The operator, a person or the app acting from *)
(* outside the tree, is a parent of every main session and so of every     *)
(* agent: it messages any agent and fixes any agent, a main session as its *)
(* parent, through the same checks, claims and Mailbox order, and every    *)
(* row it writes names it (F-109). It owns no service, and no stop ends a  *)
(* main session. A service is owned by                                     *)
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
(*             and settle as a delegate's report (Delegate.tla). It stores *)
(*             each delivered message's reply or notice once, keyed by     *)
(*             the message (`reply_to`, durable);                          *)
(*   Stream    the fold of a delegate's log: each message's turn, and the  *)
(*             result or the exit that ended it, kept on the message the   *)
(*             result names (read again from the log after a restart);     *)
(*   Services  each service's owner, its keep flag, its fixes and hand-ons,*)
(*             and its end with its owner (durable);                       *)
(*   MCP       the calls: message, interrupt, resume, stop, service_start, *)
(*             service_restart, service_stop and service_hand, each with   *)
(*             its caller's fixed identity; the operator's acts            *)
(*             (`Operator`) go through the same calls under its name.      *)
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
(* brief, messages, resumes and, when SelfTurns, turns it starts by itself *)
(* (off in the configurations that do not check replies, to keep their     *)
(* state small). A turn's result names its message, or none: the brief's   *)
(* and a resume's are Delegates' (Delegate.tla), and a delegate is idle    *)
(* only after its brief's result, so no other result is ever its report.   *)
(* A reply's text and subtype, and its own delivery to the main session    *)
(* (that of any message), are left abstract. A message enters              *)
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
(* wrong case, as a mistaken check would. The operator's Breaks each let   *)
(* its acts skip one guard a parent's take, as an app-level path that      *)
(* copied the checks wrongly would, or widen what it may do by one wrong   *)
(* case (a stop of a main session, a service handed to it). `rmem` and     *)
(* `last` are what                                                         *)
(* ReplyInMemory's and SelfReply's wrong readers hold; the design never    *)
(* writes them.                                                            *)
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
    SelfTurns,    \* a delegate may start a turn by itself
    Operators,    \* {} or {the operator}: a person or the app, outside the tree
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
    "NoOwnerWatch",          \* a service whose owner ended is not ended
    "ReplyInMemory",         \* a reply's once-check is a set held in memory, not the table's key
    "ReplyAndNotice",        \* a notice read from the process's end, not the fold, keyed apart
    "SelfReply",             \* a reply is the last result since the message, whatever it names
    "NoNotice",              \* a message whose turn ended with no result gets no notice
    "OperatorTwoClaims",     \* the operator's claim does not check for one on the same state
    "OperatorStaleFix",      \* the operator's fix acts without checking the claimed state
    "OperatorIntoRunningTurn", \* the operator's message is typed without checking the turn
    "OperatorStopsMain",     \* the operator's stop is granted on a main session
    "HandToOperator"         \* a main session may hand a service to the operator, its parent
}

Agents == UNION Projects
Delegates == Agents \ Mains
Actors == Agents \cup Operators   \* who calls: an agent, or the operator

ASSUME Break \in Breaks
ASSUME \A P \in Projects : Cardinality(P \cap Mains) = 1
ASSUME \A P, Q \in Projects : P # Q => P \cap Q = {}
ASSUME Mains \subseteq Agents
ASSUME MaxMsgs \in Nat /\ MaxFaults \in Nat /\ MaxRestarts \in Nat /\ SelfTurns \in BOOLEAN
\* The operator's name is reserved: no agent holds it.
ASSUME Cardinality(Operators) <= 1 /\ Operators \cap Agents = {}

None == "none"
Ids == 1..MaxMsgs
MaxEpoch == 2 * MaxFaults + 1
Kinds == {"interrupt", "resume", "stop"}
Needs == [interrupt |-> "stuck", resume |-> "dead", stop |-> "idle"]
AnyMain == CHOOSE m \in Mains : TRUE
OwnTurn == 0     \* the name of a result that names no message of Mailbox's
NoResult == -1   \* no result since the last message was typed
NoMsg == [from |-> AnyMain, to |-> AnyMain, st |-> "none"]

\* The tree. A main session is a root; a delegate's parent is its main session.
Main(a) == CHOOSE m \in Mains : \E P \in Projects : {a, m} \subseteq P
IsChild(t, c) == t \in Delegates /\ Main(t) = c
Siblings(a, b) == a # b /\ a \in Delegates /\ b \in Delegates /\ Main(a) = Main(b)

\* Grants: the edges a message goes along. The operator, a parent of every
\* main session, reaches every agent; no agent messages it.
Edge(c, t) == \/ c \in Operators /\ t \in Agents
              \/ c \in Mains /\ t \in Mains /\ c # t
              \/ IsChild(t, c)
              \/ IsChild(c, t)

\* Grants: a fix is a parent's act on its own child; the operator's on any
\* agent. Each Break widens it by one case.
MayFix(c, t) == \/ c \in Operators
                \/ IsChild(t, c)
                \/ Break = "SiblingFix" /\ Siblings(c, t)
                \/ Break = "SelfFix" /\ c = t
                \/ Break = "FixMain" /\ Edge(c, t)

\* Grants: a service is fixed by its owner or the owner's parent, or the operator.
MayFixService(c, o) == c = o \/ IsChild(o, c) \/ c \in Operators \/ Break = "ServiceFixAnyone"

\* Grants: the owner hands a service to its parent or one of its children,
\* never to the operator, which owns nothing.
MayHand(c, o, b) == /\ c = o \/ Break = "HandByOther"
                    /\ \/ IsChild(o, b) \/ IsChild(b, o)
                       \/ Break = "HandToSibling" /\ Siblings(o, b)
                       \/ Break = "HandToOperator" /\ o \in Mains /\ b \in Operators

VARIABLES
    up,        \* the framework runs
    restarts,  \* restarts so far
    proc,      \* a -> "working", "idle", "stuck", "dead", "ended"
    epoch,     \* a -> the number of a's state
    faults,    \* sticks and deaths so far
    msgs,      \* table: i -> [from (an actor), to (addressee), st]
    msend,     \* in memory: i -> "none", "asked" (row says sending), "sent" (typed, row not marked)
    inbox,     \* a -> the message ids in a's transcript, in order
    claims,    \* table: the claims, [by (an actor), t, ep, kind, n]
    done,      \* table: the claims whose call has ended
    calls,     \* in memory: the claims whose fix is under way
    fixed,     \* ghost: the states <<t, ep>> a fix acted on
    svc,       \* table: s -> "none", "running", "ended"
    owner,     \* table: s -> its owner, or None
    keep,      \* table: s -> kept for the owner's parent when the owner ends
    fold,      \* the fold (from the log): i -> "none", "turn", "result", "exited"
    answers,   \* table: replies and notices, [re, kind, to, src]
    rmem,      \* in memory: the ids replied to, read only when Break = "ReplyInMemory"
    last,      \* a -> the last result's name since a message was typed (SelfReply only)
    wrong      \* ghost: what a guard should have refused

agentVars == <<proc, epoch, faults>>
msgVars == <<msgs, msend, inbox>>
replyVars == <<fold, answers, rmem, last>>
claimVars == <<claims, done, calls, fixed>>
svcVars == <<svc, owner, keep>>
vars == <<up, restarts, agentVars, msgVars, claimVars, svcVars, replyVars, wrong>>

Sent == {i \in Ids : msgs[i].st # "none"}
\* The operator is outside the tree, and never ends. An IF, since TLC splits a
\* disjunction in an action and would read `proc` of the operator.
Live(a) == IF a \in Operators THEN TRUE ELSE proc[a] # "ended"

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
    /\ fold = [i \in Ids |-> "none"] /\ answers = {} /\ rmem = {}
    /\ last = [a \in Agents |-> NoResult]
    /\ wrong = {}

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; what it holds in memory does not *)

FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ msend' = [i \in Ids |-> "none"]
    /\ calls' = {}
    /\ IF Break = "ClaimInMemory" THEN claims' = {} /\ done' = {} ELSE UNCHANGED <<claims, done>>
    /\ rmem' = {}
    /\ UNCHANGED <<agentVars, msgs, inbox, fixed, svcVars, fold, answers, last, wrong>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<restarts, agentVars, msgVars, claimVars, svcVars, wrong, replyVars>>

-----------------------------------------------------------------------------
(* The agents: turns, a person's prompt to a main session; sticking, dying, ending *)

\* A delegate starts on its brief; its later turns come from messages,
\* resumes, and turns it starts by itself.
Prompted(a) ==
    /\ a \in Mains /\ proc[a] = "idle" /\ proc' = [proc EXCEPT ![a] = "working"]
    /\ UNCHANGED <<up, restarts, epoch, faults, msgVars, claimVars, svcVars, wrong, replyVars>>

\* A delegate starts a turn by itself (F-31's new-2): its result names no
\* message of Mailbox's.
SelfStarts(d) ==
    /\ SelfTurns /\ d \in Delegates /\ proc[d] = "idle"
    /\ proc' = [proc EXCEPT ![d] = "working"]
    /\ UNCHANGED <<up, restarts, epoch, faults, msgVars, claimVars, svcVars, wrong, replyVars>>

\* The message whose turn `a` is in, if any: typed, with no result yet.
InTurn(a) == {i \in Ids : msgs[i].to = a /\ fold[i] = "turn"}

\* `a`'s turn ends with a result. It names the message whose turn it is, or
\* none (OwnTurn): a brief, a resume, a turn the delegate started.
Result(a) ==
    /\ fold' = [i \in Ids |-> IF i \in InTurn(a) THEN "result" ELSE fold[i]]
    /\ last' = IF Break = "SelfReply"
                 THEN [last EXCEPT ![a] = IF InTurn(a) = {} THEN OwnTurn
                                                            ELSE CHOOSE i \in InTurn(a) : TRUE]
                 ELSE last

TurnEnds(a) ==
    /\ proc[a] = "working" /\ proc' = [proc EXCEPT ![a] = "idle"]
    /\ Result(a)
    /\ UNCHANGED <<up, restarts, epoch, faults, msgVars, claimVars, svcVars, answers, rmem, wrong>>

\* An agent sticks, or its process ends. A message whose turn it was then
\* has no result, and never will: the fold reads the exit.
Faults(a) ==
    /\ faults < MaxFaults
    /\ \/ /\ proc[a] = "working" /\ proc' = [proc EXCEPT ![a] = "stuck"]
          /\ UNCHANGED fold
       \/ /\ proc[a] \in {"working", "idle", "stuck"} /\ proc' = [proc EXCEPT ![a] = "dead"]
          /\ fold' = [i \in Ids |-> IF i \in InTurn(a) THEN "exited" ELSE fold[i]]
    /\ epoch' = [epoch EXCEPT ![a] = @ + 1] /\ faults' = faults + 1
    /\ UNCHANGED <<up, restarts, msgVars, claimVars, svcVars, answers, rmem, last, wrong>>

\* A delegate ends once its report is delivered (Delegate.tla).
DelegateEnds(d) ==
    /\ d \in Delegates /\ proc[d] = "idle"
    /\ proc' = [proc EXCEPT ![d] = "ended"] /\ epoch' = [epoch EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<up, restarts, faults, msgVars, claimVars, svcVars, wrong, replyVars>>

-----------------------------------------------------------------------------
(* Mailbox: a message along an edge, stored, then typed into an ended turn, once *)

Send(c, t) ==
    /\ up /\ Live(c)
    /\ Edge(c, t) \/ (Break = "OffEdge" /\ c # t)
    /\ Cardinality(Sent) < MaxMsgs
    /\ LET i == Cardinality(Sent) + 1
       IN msgs' = [msgs EXCEPT ![i] = [from |-> c, to |-> t, st |-> "queued"]]
    /\ UNCHANGED <<up, restarts, agentVars, msend, inbox, claimVars, svcVars, wrong, replyVars>>

Earlier(i) == {j \in 1..(i - 1) : msgs[j].from = msgs[i].from /\ msgs[j].to = msgs[i].to}
NextInOrder(i) == Break = "NoOrder" \/ \A j \in Earlier(i) : msgs[j].st = "delivered"

\* Once the target's turn has ended, the row says "sending" before the write.
DeliveryAsked(i) ==
    /\ up /\ msgs[i].st = "queued" /\ msend[i] = "none"
    /\ proc[msgs[i].to] = "idle" /\ NextInOrder(i)
    /\ msgs' = [msgs EXCEPT ![i].st = "sending"] /\ msend' = [msend EXCEPT ![i] = "asked"]
    /\ UNCHANGED <<up, restarts, agentVars, inbox, claimVars, svcVars, wrong, replyVars>>

Typeable(a) ==
    proc[a] = "idle" \/ (Break = "IntoRunningTurn" /\ proc[a] \in {"working", "stuck"})

\* Message i may go in now: the same check whoever sent it.
TypeableNow(i) ==
    \/ Typeable(msgs[i].to)
    \/ /\ Break = "OperatorIntoRunningTurn" /\ msgs[i].from \in Operators
       /\ proc[msgs[i].to] \in {"working", "stuck"}

\* Control's checked write: the message is the target's new turn.
DeliveryTyped(i) ==
    LET a == msgs[i].to IN
    /\ up /\ msend[i] = "asked" /\ TypeableNow(i)
    /\ msend' = [msend EXCEPT ![i] = "sent"]
    /\ inbox' = [inbox EXCEPT ![a] = Append(@, i)]
    /\ proc' = [proc EXCEPT ![a] = "working"]
    /\ wrong' = wrong \cup (IF proc[a] = "idle" THEN {} ELSE {"running turn"})
    /\ fold' = IF a \in Delegates THEN [fold EXCEPT ![i] = "turn"] ELSE fold
    /\ last' = IF Break = "SelfReply" THEN [last EXCEPT ![a] = NoResult] ELSE last
    /\ UNCHANGED <<up, restarts, epoch, faults, msgs, claimVars, svcVars, answers, rmem>>

DeliveryRefused(i) ==
    /\ up /\ msend[i] = "asked" /\ ~TypeableNow(i)
    /\ msend' = [msend EXCEPT ![i] = "none"] /\ msgs' = [msgs EXCEPT ![i].st = "queued"]
    /\ UNCHANGED <<up, restarts, agentVars, inbox, claimVars, svcVars, wrong, replyVars>>

DeliveryMarked(i) ==
    /\ up /\ msend[i] = "sent"
    /\ msend' = [msend EXCEPT ![i] = "none"] /\ msgs' = [msgs EXCEPT ![i].st = "delivered"]
    /\ UNCHANGED <<up, restarts, agentVars, inbox, claimVars, svcVars, wrong, replyVars>>

InTranscript(i, a) == \E k \in DOMAIN inbox[a] : inbox[a][k] = i

\* A restart cut off a send: the target's transcript says whether it went in.
SendingSettled(i) ==
    /\ up /\ msgs[i].st = "sending" /\ msend[i] = "none"
    /\ msgs' = [msgs EXCEPT ![i].st =
                  IF InTranscript(i, msgs[i].to) /\ Break # "RedeliverAfterRestart"
                    THEN "delivered" ELSE "queued"]
    /\ UNCHANGED <<up, restarts, agentVars, msend, inbox, claimVars, svcVars, wrong, replyVars>>

\* A message to a delegate that has ended is not delivered: its row says the
\* delegate ended before it went in, from a settled row only.
EndedFirst(i) ==
    /\ up /\ Break # "NoEndedMark"
    /\ msgs[i].to \in Delegates /\ proc[msgs[i].to] = "ended"
    /\ \/ msgs[i].st = "queued"
       \/ (Break = "EndedUnsettled" /\ msgs[i].st = "sending" /\ msend[i] = "none")
    /\ msgs' = [msgs EXCEPT ![i].st = "ended"]
    /\ UNCHANGED <<up, restarts, agentVars, msend, inbox, claimVars, svcVars, wrong, replyVars>>

-----------------------------------------------------------------------------
(* Mailbox: a delegate's reply to a delivered message, or the framework's *)
(* notice that its turn ended with no result; one per message            *)

Answered(i) == {r \in answers : r.re = i}

\* The last message typed into `a`, if any.
LastTyped(a) == IF inbox[a] = <<>> THEN 0 ELSE inbox[a][Len(inbox[a])]

\* The result Mailbox takes as message i's reply, if one is there: the one
\* the fold keeps on i. SelfReply reads the last result since i was typed,
\* whatever it names.
ReplySource(i) ==
    IF Break = "SelfReply"
      THEN IF LastTyped(msgs[i].to) = i THEN last[msgs[i].to] ELSE NoResult
      ELSE IF fold[i] = "result" THEN i ELSE NoResult

\* The reply is a message from the delegate to its main session, stored once:
\* the table's key on the answered message refuses a second row.
ReplyStored(i) ==
    LET d == msgs[i].to  src == ReplySource(i) IN
    /\ up /\ d \in Delegates /\ msgs[i].st = "delivered" /\ src # NoResult
    /\ IF Break = "ReplyInMemory" THEN i \notin rmem ELSE Answered(i) = {}
    /\ answers' = answers \cup {[re |-> i, kind |-> "reply", to |-> Main(d), src |-> src]}
    /\ rmem' = IF Break = "ReplyInMemory" THEN rmem \cup {i} ELSE rmem
    /\ wrong' = wrong \cup (IF \E r \in Answered(i) : r.kind = "reply" THEN {"reply twice"} ELSE {})
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, svcVars, fold, last>>

\* The delegate's process ended during i's turn with no result: a notice from
\* the framework to the main session, under the same key. ReplyAndNotice reads
\* the end of the process after i, not the fold, and checks only notices.
NoticeStored(i) ==
    LET d == msgs[i].to IN
    /\ up /\ Break # "NoNotice" /\ d \in Delegates /\ msgs[i].st = "delivered"
    /\ IF Break = "ReplyAndNotice"
         THEN /\ proc[d] \in {"dead", "ended"} /\ LastTyped(d) = i /\ fold[i] # "turn"
              /\ ~\E r \in Answered(i) : r.kind = "notice"
         ELSE fold[i] = "exited" /\ Answered(i) = {}
    /\ answers' = answers \cup {[re |-> i, kind |-> "notice", to |-> Main(d), src |-> NoResult]}
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, svcVars, fold, rmem, last, wrong>>

-----------------------------------------------------------------------------
(* Grants: a parent's fix takes a claim on its child's current state first *)

Kind(t) == CASE proc[t] = "stuck" -> "interrupt"
             [] proc[t] = "dead" -> "resume"
             [] OTHER -> "stop"

\* The caller's calls already on this state: a second one is `n` = 2.
Calls(c, t) == {q \in claims : q.by = c /\ q.t = t /\ q.ep = epoch[t]}

\* A stop ends a delegate only: a main session's end is a person's, outside Grants.
Stoppable(t) == t \in Delegates \/ Kind(t) # "stop" \/ Break = "OperatorStopsMain"

ClaimTaken(c, t) ==
    LET r == [by |-> c, t |-> t, ep |-> epoch[t], kind |-> Kind(t),
              n |-> Cardinality(Calls(c, t)) + 1] IN
    /\ up /\ Live(c) /\ r.n <= 2
    /\ proc[t] \in {"stuck", "dead", "idle"}
    /\ MayFix(c, t) /\ Stoppable(t)
    /\ \/ ~\E q \in claims : q.t = t /\ q.ep = epoch[t]
       \/ Break = "TwoClaims"
       \/ Break = "OperatorTwoClaims" /\ c \in Operators
    /\ claims' = claims \cup {r} /\ calls' = calls \cup {r}
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, done, fixed, svcVars, wrong, replyVars>>

CanAct(r) ==
    /\ \/ epoch[r.t] = r.ep \/ Break = "StaleFix"
       \/ Break = "OperatorStaleFix" /\ r.by \in Operators
    /\ proc[r.t] = Needs[r.kind]

\* The fix acts on the state it claimed. An interrupt or a resume may not
\* help; the state is then still claimed. An interrupt that helps ends the
\* turn with a result (`error_during_execution`) that names its message; a
\* resume's turn names none; a stop takes an idle agent.
FixActs(r) ==
    /\ up /\ r \in calls /\ CanAct(r)
    /\ \/ /\ proc' = [proc EXCEPT ![r.t] = CASE r.kind = "interrupt" -> "idle"
                                             [] r.kind = "resume" -> "working"
                                             [] OTHER -> "ended"]
          /\ epoch' = [epoch EXCEPT ![r.t] = @ + 1]
          /\ IF r.kind = "interrupt" THEN Result(r.t) ELSE UNCHANGED <<fold, last>>
       \/ (r.kind # "stop" /\ UNCHANGED <<proc, epoch, fold, last>>)
    /\ calls' = calls \ {r} /\ done' = done \cup {r}
    /\ fixed' = fixed \cup {<<r.t, epoch[r.t]>>}
    /\ wrong' = wrong \cup (IF <<r.t, epoch[r.t]>> \in fixed THEN {"twice"} ELSE {})
                      \cup (IF epoch[r.t] = r.ep THEN {} ELSE {"stale"})
    /\ UNCHANGED <<up, restarts, faults, msgVars, claims, svcVars, answers, rmem>>

FixRefused(r) ==
    /\ up /\ r \in calls /\ ~CanAct(r)
    /\ calls' = calls \ {r} /\ done' = done \cup {r}
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claims, fixed, svcVars, wrong, replyVars>>

\* A restart cut off the call: the claim ends, and its fix is never sent again.
ClaimSettled(r) ==
    /\ up /\ r \in claims \ done /\ r \notin calls
    /\ done' = done \cup {r}
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claims, calls, fixed, svcVars, replyVars,
                   wrong>>

-----------------------------------------------------------------------------
(* Services: one owner; fixed by it or its parent; handed along an edge; *)
(* ended with the owner, or kept for its parent                          *)

ServiceStarts(a, s) ==
    /\ up /\ svc[s] = "none" /\ Live(a)
    /\ svc' = [svc EXCEPT ![s] = "running"] /\ owner' = [owner EXCEPT ![s] = a]
    /\ keep' \in {[keep EXCEPT ![s] = k] : k \in BOOLEAN}
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, wrong, replyVars>>

\* A restart or a stop: a stop ends the service; a restart leaves it running.
ServiceFixed(c, s) ==
    /\ up /\ svc[s] = "running" /\ Live(c) /\ MayFixService(c, owner[s])
    /\ \/ svc' = [svc EXCEPT ![s] = "ended"] /\ owner' = [owner EXCEPT ![s] = None]
       \/ UNCHANGED <<svc, owner>>
    /\ wrong' = wrong \cup (IF c = owner[s] \/ IsChild(owner[s], c) \/ c \in Operators
                              THEN {} ELSE {"service fix"})
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, keep, replyVars>>

ServiceHanded(c, s, b) ==
    LET o == owner[s] IN
    /\ up /\ svc[s] = "running" /\ o \in Agents /\ o # b
    /\ Live(c) /\ Live(o) /\ Live(b) /\ MayHand(c, o, b)
    /\ owner' = [owner EXCEPT ![s] = b]
    /\ wrong' = wrong \cup (IF c = o /\ (IsChild(o, b) \/ IsChild(b, o)) THEN {} ELSE {"hand"})
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, svc, keep, replyVars>>

\* A kept service goes to its owner's parent; a main session never ends, so
\* the owner here is a delegate.
ServiceOwnerEnded(s) ==
    /\ up /\ svc[s] = "running" /\ owner[s] \in Agents /\ proc[owner[s]] = "ended"
    /\ keep[s] \/ Break # "NoOwnerWatch"
    /\ IF keep[s]
         THEN owner' = [owner EXCEPT ![s] = Main(owner[s])] /\ UNCHANGED svc
         ELSE /\ owner' = [owner EXCEPT ![s] = None]
              /\ svc' = IF Break = "OwnerClearedFirst" THEN svc ELSE [svc EXCEPT ![s] = "ended"]
    /\ UNCHANGED <<up, restarts, agentVars, msgVars, claimVars, keep, wrong, replyVars>>

-----------------------------------------------------------------------------
Next ==
    \/ FrameworkDies \/ FrameworkStarts
    \/ \E a \in Agents : \/ Prompted(a) \/ SelfStarts(a) \/ TurnEnds(a) \/ Faults(a)
                         \/ DelegateEnds(a)
    \/ \E c \in Actors, t \in Agents : Send(c, t) \/ ClaimTaken(c, t)
    \/ \E i \in Ids : \/ DeliveryAsked(i) \/ DeliveryTyped(i) \/ DeliveryRefused(i)
                      \/ DeliveryMarked(i) \/ SendingSettled(i) \/ EndedFirst(i)
                      \/ ReplyStored(i) \/ NoticeStored(i)
    \/ \E r \in claims : FixActs(r) \/ FixRefused(r) \/ ClaimSettled(r)
    \/ \E s \in Services : \/ ServiceOwnerEnded(s)
                           \/ \E a \in Agents : ServiceStarts(a, s)
                           \/ \E a \in Actors : ServiceFixed(a, s)
                           \/ \E c \in Agents, b \in Actors : ServiceHanded(c, s, b)

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A a \in Agents : WF_vars(TurnEnds(a))
    /\ \A i \in Ids :
         /\ SF_vars(DeliveryAsked(i)) /\ SF_vars(DeliveryTyped(i))
         /\ WF_vars(DeliveryTyped(i) \/ DeliveryRefused(i))
         /\ WF_vars(DeliveryMarked(i)) /\ WF_vars(SendingSettled(i)) /\ WF_vars(EndedFirst(i))
         /\ WF_vars(ReplyStored(i)) /\ WF_vars(NoticeStored(i))
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
    /\ \A i \in Ids : msgs[i].from \in Actors /\ msgs[i].to \in Agents
    /\ claims \subseteq [by : Actors, t : Agents, ep : 0..MaxEpoch, kind : Kinds, n : 1..2]
    /\ calls \subseteq claims \ done /\ done \subseteq claims
    /\ svc \in [Services -> {"none", "running", "ended"}]
    /\ owner \in [Services -> Agents \cup {None}]
    /\ fold \in [Ids -> {"none", "turn", "result", "exited"}]
    /\ answers \subseteq [re : Ids, kind : {"reply", "notice"}, to : Agents,
                          src : {NoResult, OwnTurn} \cup Ids]
    /\ rmem \subseteq Ids
    /\ last \in [Agents -> {NoResult, OwnTurn} \cup Ids]

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

\* Only a parent fixes, and only its own child; the operator is a parent of
\* every main session, and so of every agent.
OnlyParentFixes == \A r \in claims : IsChild(r.t, r.by) \/ r.by \in Operators
NoSelfFix == \A r \in claims : r.by # r.t
\* No agent fixes a main session, only the operator; no fix ends one.
MainFixedByOperatorOnly == /\ \A r \in claims : r.t \in Mains => r.by \in Operators
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

\* A message is answered once: a reply is stored at most once, across
\* restarts, and a message never has both a reply and a notice.
ReplyOnce == "reply twice" \notin wrong
ReplyOrNotice == \A i \in Ids : \A r, q \in Answered(i) : r.kind = q.kind

\* A reply or a notice goes from a delegate to its main session only.
ReplyToMain == \A r \in answers : msgs[r.re].to \in Delegates /\ r.to = Main(msgs[r.re].to)

\* A reply is the result that names its message, never one that names none
\* (a brief, a resume, a turn the delegate started by itself).
ReplyNamesMessage == \A r \in answers : r.kind = "reply" => r.src = r.re

\* A delivered message whose turn ends, with a result or with the process's
\* end, gets its reply or its notice.
ReplyOrNoticeComes ==
    \A i \in Ids : (msgs[i].to \in Delegates /\ fold[i] \in {"result", "exited"})
                       ~> Answered(i) # {}

=============================================================================
