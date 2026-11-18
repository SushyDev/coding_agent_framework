-------------------------------- MODULE Team --------------------------------
(***************************************************************************)
(* The tree of two projects: each project's main session and its           *)
(* delegates, their messages, their claims on each other, their services,  *)
(* and restarts of the framework. A message goes along an edge of the      *)
(* tree only: a main session to its delegates and to the other main        *)
(* session, a delegate to its main session. It is a row of Delivery.tla's  *)
(* (instanced as D): stored, then into an ended turn once, by the stream   *)
(* to a delegate and the waiter to a main session; one to a delegate that  *)
(* ended first says so, and its sender reads that in place of delivered.   *)
(* A message into a delegate is a turn of its own, and Delivery stores its *)
(* reply, or the framework's notice when the process ends first, for its   *)
(* sender (F-79). A fix is a main session's act on its own delegate, under *)
(* a claim on the delegate's current state. The operator, a person or the  *)
(* app acting from outside the tree, is a parent of every main session and *)
(* so of every agent: it messages any agent and fixes any agent, a main    *)
(* session as its parent, through the same checks, claims and Mailbox     *)
(* order, and every row it writes names it (F-109). A reply to its message *)
(* is kept for it, never delivered. No agent messages the operator: an    *)
(* agent reaches it by an ask (`ask`, F-138), a row from the agent to the  *)
(* operator kept for the app, as a reply to it is, and never delivered.    *)
(* The ask is one step that leaves the agent's turn as it is: the tool     *)
(* answers at once. The operator answers an ask once, with a row to the    *)
(* asking agent under the ask's key, delivered as any row is, or settled   *)
(* ended when that agent ended first. It owns no service, and no fix's    *)
(* stop ends a main session: only its end does (`end_main`, F-143), the    *)
(* operator's act alone, refused while any of its delegates has not ended, *)
(* taken once the main session is idle (SIGTERM, as any stop) or its       *)
(* process is gone. The row keeps the end asked (a mark, durable, F-144):  *)
(* a stop that answered unknown, its process outliving the stop's          *)
(* deadline, leaves the mark, and the settle ends the row once the process *)
(* is gone, with no second call; no resume takes a row with the mark, and  *)
(* Mailbox marks no row to it, as to any row stopping. A service is owned by one agent, fixed by its owner or *)
(* the owner's parent, handed to the owner's parent or a child, and ended  *)
(* or kept when its owner ends: kept for a delegate's main session, and    *)
(* ended with a main session, kept or not, since the operator owns nothing.*)
(*                                                                         *)
(* A delegate's start may be refused once its call reached Sessions        *)
(* (StartsRefused): its process ran and was stopped before its first turn  *)
(* took anything, as a headless start whose init never came in the first   *)
(* end-to-end run (F-153), and none of it runs again. It has no report and *)
(* no process, so no fix takes it, a stop among them; Delegates' settle    *)
(* ends its row, as a failed delegate's, and its main session's end waits  *)
(* on it no more (RefusedEnds; RefusedKept leaves it refused).             *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework (only Grants' checks are   *)
(* built, F-73):                                                           *)
(*   Grants    the tree's edges, by which it decides whether a caller may  *)
(*             message, fix or hand to a target; the claims table          *)
(*             (durable); the fix a claim's call runs (in memory);         *)
(*   Mailbox   the rows: messages, replies and notices (Delivery.tla), and *)
(*             asks and their answers;                                     *)
(*   Stream    the fold of a delegate's log, which Delivery reads;         *)
(*   Services  each service's owner, its keep flag, its fixes and hand-ons,*)
(*             and its end with its owner (durable);                       *)
(*   Sessions  a main session's end (`end_main`): its check of the         *)
(*             delegates and its stop, in one process;                     *)
(*   Delegates a refused start's end, at its settle;                       *)
(*   MCP       the calls: message, interrupt, answer, resume, stop,        *)
(*             service_start, service_restart, service_stop, service_hand  *)
(*             and ask, each with its caller's fixed identity; the         *)
(*             operator's acts                                             *)
(*             (`Operator`) go through the same calls under its name, and  *)
(*             its answer to an ask through `Mailbox.answer`; each fix's   *)
(*             check of the state it claims (`Delegates.fix_check/2`,     *)
(*             `Mains.fix_check/2`).                                       *)
(*                                                                         *)
(* What moved to Delivery.tla (R6): the sending mark and its settle, the  *)
(* typed write (DeliveryTyped), the order, the ended mark, the replies and *)
(* notices, and with them DeliveredAtMostOnce, OnlyIntoEndedTurn, InOrder, *)
(* EndedNotDelivered, ReplyOnce, ReplyOrNotice, ReplyNamesMessage and      *)
(* ReplyOrNoticeComes, and their Breaks. This spec still checks them on    *)
(* its own state, with the edges (AlongEdges) and MessageDelivered.        *)
(*                                                                         *)
(* Every row may be long (Delivery's Long is every row), and a main       *)
(* session's turns say when its waiter could connect (`turned`), so a row  *)
(* to a main session with no waiter, after a restart cut it, is typed as   *)
(* a pointer to its file (F-142); NoPointer leaves it waiting.             *)
(*                                                                         *)
(* Left abstract: the text of a message, and how its sender reads its row; *)
(* a main session's waiter itself (Delivery.tla, Delegate.tla);            *)
(* reading tools, which change nothing; the hold's own single answer and  *)
(* its deadline (Hold.tla, Intake.tla);                                    *)
(* subagents, which the framework does not reach, so a delegate has no     *)
(* child here; a service's own                                             *)
(* process, logs, waits and host, and the claim its fix takes, which works *)
(* as an agent's does (a restart and a stop are one step that may end it); *)
(* how a stuck agent is seen; a person's other acts on a main session (a  *)
(* stop or a move), which leave it as it is here. A delegate's own end,   *)
(* once its report is delivered, is one step (Delegate.tla). A caller's    *)
(* own state is                                                            *)
(* not checked: a call may come from a subagent while the caller's main    *)
(* turn is stuck, so one caller may make the same call twice at once. A    *)
(* person prompts a main session only; a delegate's turns come from its    *)
(* brief, messages, resumes and, when SelfTurns, turns it starts by itself *)
(* (off in the configurations that do not check replies, to keep their     *)
(* state small). A fix either helps or not, in the step it acts. The       *)
(* number of each agent's state (`epoch`) stands for what the framework    *)
(* reads of it; it moves when the agent sticks, dies, is fixed or ends.    *)
(* `life` numbers an agent's processes: a resume starts a new one. An      *)
(* interrupt takes a stuck delegate, a resume a dead one, a stop an idle   *)
(* one.                                                                    *)
(*                                                                         *)
(* Fairness: the framework's steps happen while they stay possible, and a  *)
(* working turn ends unless the agent sticks; Mailbox's as in Delivery.tla.*)
(* Agents' calls happen or not.                                            *)
(*                                                                         *)
(* Break: "none" is the design. Every other value is one wrong guard and   *)
(* has a Break_Team_<value>.cfg that TLC must fail. Grants' fix check is   *)
(* one relation, "the caller is the target's main session": no agent fixes *)
(* itself and none fixes a main session, because a main session has no    *)
(* parent. SiblingFix, SelfFix and FixMain each widen that relation by one *)
(* wrong case, as a mistaken check would. The operator's Breaks each let   *)
(* its acts skip one guard a parent's take, as an app-level path that      *)
(* copied the checks wrongly would, or widen what it may do by one wrong   *)
(* case (a stop of a main session, a service handed to it). Its message    *)
(* takes Mailbox's one mark, as every sender's does, so there is no path   *)
(* of its own to break there.                                              *)
(*                                                                         *)
(* A claim is Claim.tla's (Cl): its row, the call that holds it, the check *)
(* that its state is current, a restart that cuts it, and the properties   *)
(* OneClaimPerState, OneFixPerState (Claim's OneActPerState), ClaimEnds    *)
(* and NoActOnCutOffClaim. A state is the agent's `epoch`. The operator's  *)
(* Breaks instance Claim with a bug for its own claims only.               *)
(*                                                                         *)
(* An ask is a prompt (Prompt.tla, instanced as Q; F-167), kind          *)
(* `question`: the ask opens its row, and the operator's answer is         *)
(* Prompt's AnswerNow, the row read open, the answer claimed on its state  *)
(* and the answer row stored in one call, so the prompt's status is the    *)
(* guard that lets in the first answer only (AnswerTwice is Prompt's).     *)
(* AskAnsweredRightly and AskClaimOnce are Prompt's OnlyRightful and       *)
(* OneClaimPerState. A held request's answer (AnswerClaimed) is not a      *)
(* prompt here yet: its claim is Grants' on the child's state.             *)
(*                                                                         *)
(* An answer of a held permission request (`answer`, F-147) is one more    *)
(* fix kind. Intake holds a request while its agent's turn waits on it     *)
(* (Hold.tla): the ids of the requests held for a session are part of the  *)
(* state a fix reads, so a request that arrives, or one a person answers   *)
(* on the screen first, moves it. The answer names a request, and its call *)
(* checks that the state holds it before the claim is taken (AnswerClaimed,*)
(* F-148), as it checks its label: a claim kept after a refusal would      *)
(* refuse the next answer, with the right id, until the state moved.       *)
(* AnswerNotHeld takes the claim on any id. The act takes one request out  *)
(* of those held and leaves the process as it is. MaxRequests is 0 in the  *)
(* configurations that do not check it, to keep their state small.         *)
(*                                                                         *)
(* The caller names its fix. What the fix needs of the state it claims is  *)
(* checked before the claim is taken (Needed, F-149), as the answer's id   *)
(* is: an interrupt a stuck agent, a resume a dead one whose end is not    *)
(* asked, a stop an idle one. A fix refused that way takes no claim, so    *)
(* the next fix of that state is taken. A fix refused when it acts, by     *)
(* what it meets then (a stop whose agent took a turn since: the code's    *)
(* report not yet delivered), still lets its claim go and keeps the state. *)
(* ClaimBeforeCheck claims any fix on any state, and leaves the check to   *)
(* the act.                                                                *)
(*                                                                         *)
(* Defense in depth, with no Break: FixActs' check of the target's process *)
(* for an interrupt or a resume, behind its check of the claimed state's   *)
(* number (stuck and dead are left only by steps that move it). For a stop *)
(* the process check is the end by the delegate's own pid and start time.  *)
(*                                                                         *)
(* The Team box's contract (F-163): every act on an agent under the        *)
(* Ledger's claim, once per state, only on the state claimed and only      *)
(* where that state needs it (OneClaimPerState, OneFixPerState,            *)
(* FixOnClaimedState, FixClaimsChecked, ClaimedStateNeedsFix); only a      *)
(* parent or the operator acts, no agent on itself, none on a main         *)
(* session but the operator (OnlyParentFixes, NoSelfFix,                   *)
(* MainFixedByOperatorOnly); messages only along edges (AlongEdges); asks  *)
(* kept and answered once (OperatorRowsKept, AnswerOnce, AnswerToAsker);   *)
(* services with one owner, ended with it (OneOwner,                       *)
(* ServiceEndsWithOwner). Boxes.tla's FixClaim is this spec's Needed and   *)
(* claim, and its healer acts through the same operate/4 as the operator   *)
(* does here, so OnlyParentFixes covers it as the operator. No gap for     *)
(* Boxes.tla.                                                              *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Projects,     \* each project's agents: its main session and its delegates
    Mains,        \* the main sessions, one in each project
    Services,     \* the service names
    MaxMsgs,      \* messages sent, all senders together
    MaxAsks,      \* asks made, all agents together
    MaxRequests,  \* permission requests Intake holds over the run, all agents together
    MaxFaults,    \* times an agent sticks or dies, all agents together
    MaxRestarts,  \* restarts of the framework
    SelfTurns,    \* a delegate may start a turn by itself
    Operators,    \* {} or {the operator}: a person or the app, outside the tree
    StopsUnknown, \* a main session's stop may answer unknown: its process outlives the deadline
    StartsRefused, \* a delegate's start may be refused once its call reached Sessions (F-153)
    Break         \* "none", or the guard made wrong (see Breaks)

Breaks == {
    "none",
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
    "OperatorTwoClaims",     \* the operator's claim does not check for one on the same state
    "OperatorStaleFix",      \* the operator's fix acts without checking the claimed state
    "OperatorStopsMain",     \* the operator's stop is granted on a main session
    "HandToOperator",        \* a main session may hand a service to the operator, its parent
    "MessageToOperator",     \* an agent's message may go to the operator, as an ask does
    "AnswerTwice",           \* an ask's answer does not check for one stored before
    "AnswerToOther",         \* an ask's answer may go to an agent other than the asker
    "EndWithDelegates",      \* a main session's end is not refused while a delegate of it lives
    "EndBusy",               \* a main session's end does not wait for it to be idle
    "EndByAgent",            \* a main session may end another main session
    "MainKeeps",             \* a kept service of an ended main session is kept, for no one
    "NoPointer",             \* a row too long to type waits for a waiter (F-132), never typed
    "EndInMemory",           \* the end asked is held by its call only, so a restart forgets it
    "ResumeEnding",          \* a resume takes a main session whose end is asked
    "AnswerNotHeld",         \* an answer's claim is taken on a request its state does not hold
    "ClaimBeforeCheck",      \* a fix is claimed before its check of the claimed state
    "RefusedKept"            \* a delegate whose start was refused is never ended (F-153)
}

Agents == UNION Projects
Delegates == Agents \ Mains
Actors == Agents \cup Operators   \* who calls: an agent, or the operator

ASSUME Break \in Breaks
ASSUME \A P \in Projects : Cardinality(P \cap Mains) = 1
ASSUME \A P, Q \in Projects : P # Q => P \cap Q = {}
ASSUME Mains \subseteq Agents
ASSUME MaxMsgs \in Nat /\ MaxAsks \in Nat /\ MaxRequests \in Nat /\ MaxFaults \in Nat /\ MaxRestarts \in Nat /\ SelfTurns \in BOOLEAN /\ StopsUnknown \in BOOLEAN
ASSUME StartsRefused \in BOOLEAN
\* The operator's name is reserved: no agent holds it.
ASSUME Cardinality(Operators) <= 1 /\ Operators \cap Agents = {}

None == "none"
Ids == 1..(2 * (MaxMsgs + MaxAsks))   \* each message or ask, and its answer
MaxEpoch == 2 * MaxFaults + 2 * MaxRequests + 1
Kinds == {"interrupt", "resume", "stop"}
Needs == [interrupt |-> "stuck", resume |-> "dead", stop |-> "idle"]
Reqs == 1..MaxRequests   \* a request's id is the count of requests made when it was

\* The tree. A main session is a root; a delegate's parent is its main session.
Main(a) == CHOOSE m \in Mains : \E P \in Projects : {a, m} \subseteq P
IsChild(t, c) == t \in Delegates /\ Main(t) = c
Siblings(a, b) == a # b /\ a \in Delegates /\ b \in Delegates /\ Main(a) = Main(b)

\* Grants: the edges a message goes along. The operator, a parent of every
\* main session, reaches every agent; no agent messages it.
Edge(c, t) == \/ c \in Operators /\ t \in Agents
              \/ Break = "MessageToOperator" /\ c \in Agents /\ t \in Operators
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
    proc,      \* a -> "working", "idle", "stuck", "dead", "ended", "refused" (a delegate's start)
    epoch,     \* a -> the number of a's state
    life,      \* a -> the number of a's process
    faults,    \* sticks and deaths so far
    turned,    \* a -> a turn of a's current process has ended
    held,      \* a -> the ids of the requests Intake holds for a's session: part of its state
    reqs,      \* requests made so far, all agents together
    \* The claims, as Claim.tla's variables (Cl)
    claims,    \* table: the claims, [by (an actor), t, s (t's epoch), act (the fix), n]
    done,      \* table: the claims whose call has ended
    calls,     \* in memory: the claims whose fix is under way
    fixed,     \* ghost: the states <<t, epoch>> a fix acted on
    twice,     \* ghost: a fix acted on a state a fix acted on before
    cut,       \* ghost: the states whose claim a restart cut off before any fix
    svc,       \* table: s -> "none", "running", "ended"
    owner,     \* table: s -> its owner, or None
    keep,      \* table: s -> kept for the owner's parent when the owner ends
    wrong,     \* ghost: what a guard should have refused
    ending,    \* table: the main sessions whose end is asked and whose row is not ended yet
    \* Delivery's, for the messages, replies and notices
    row, hand, claimed, wire, waiter, dcall, tx, fold, rmem, last, unsure, dlost, dwrong,
    \* Prompt.tla's row of each ask (Q), and its answers' claims
    qst, qclaims

agentVars == <<proc, epoch, life, faults, turned, held, reqs>>
claimVars == <<claims, done, calls, fixed, twice, cut>>
svcVars == <<svc, owner, keep>>
dvars == <<row, hand, claimed, wire, waiter, dcall, tx, fold, rmem, last, unsure, dlost, dwrong>>
qvars == <<qst, qclaims>>
vars == <<up, restarts, agentVars, claimVars, svcVars, wrong, ending, dvars, qvars>>

\* The operator is outside the tree, and never ends. An IF, since TLC splits a
\* disjunction in an action and would read `proc` of the operator. A delegate
\* whose start was refused has no process to call from.
Live(a) == IF a \in Operators THEN TRUE ELSE proc[a] \notin {"ended", "refused"}

\* No process of the agent runs again: it ended, or its start was refused.
Over(a) == proc[a] \in {"ended", "refused"}

D == INSTANCE Delivery WITH
       Ids <- Ids, Addrs <- Agents, Headless <- Delegates, Senders <- Actors, MaxSent <- 0,
       Awaited <- {}, ClientLeaves <- FALSE, SelfTurns <- SelfTurns, MaxRestarts <- 0,
       MaxEnds <- 0, MaxPrompts <- 0, MaxStops <- 0,
       Break <- IF Break = "NoPointer" THEN "NoPointer" ELSE "none",
       up <- up,
       pr <- [a \in Agents |-> IF proc[a] \in {"dead", "ended", "refused"} THEN 0 ELSE life[a]],
       idle <- [a \in Agents |-> proc[a] = "idle"],
       stopping <- [a \in Agents |-> a \in ending],
       over <- [a \in Agents |-> Over(a)],
       turned <- turned, Long <- Ids, Launched <- {},
       call <- dcall, lost <- dlost, wrong <- dwrong,
       restarts <- 0, lives <- 0, ends <- 0, prompts <- 0, stops <- 0, readAt <- 0

Msgs == {i \in Ids : row[i].kind = "msg"}
Asks == {i \in Ids : row[i].kind = "ask"}
AnswerRows(k) == {j \in Ids : row[j].kind = "answer" /\ row[j].re = k}

\* The claims, under the bug a Break puts in the claims of the actor `by`.
ClaimBreak(by) ==
    CASE Break = "TwoClaims" \/ (Break = "OperatorTwoClaims" /\ by \in Operators) -> "TwoClaims"
      [] Break = "StaleFix" \/ (Break = "OperatorStaleFix" /\ by \in Operators) -> "Stale"
      [] Break = "ClaimInMemory" -> "InMemory"
      [] OTHER -> "none"

Cl(b) == INSTANCE Claim WITH
           Targets <- Agents, Actors <- Actors, MaxState <- MaxEpoch, now <- epoch,
           rows <- claims, acting <- calls, done <- done, acted <- fixed, twice <- twice,
           cut <- cut, Break <- b

\* An ask is a prompt of kind `question` (Prompt.tla), its row by the ask's id: a person
\* answers it, through the app (the operator), and its owner, Mailbox, stores the answer row
\* in the same call, so the claim, the hand and the owner's answer are one step (AnswerNow).
\* No deadline, no default, no parent: the operator is its one answerer here. Since each
\* answer is claimed and acted on in one step, the claims are also the ones done and acted on,
\* and the row's state number is its count of writes: open, then one per answer. The state
\* stays as small as before (F-167).
QAsked(i) == {c \in qclaims : c.t = i}
Q == INSTANCE Prompt WITH
       Ps <- Ids, Agents <- Agents, Parent <- [a \in Agents |-> None], Persons <- Operators,
       ParentKinds <- {}, AppKinds <- {}, DefaultKinds <- {}, ExpireKinds <- {}, HeldPs <- {},
       Cap <- 0, Budget <- 1, MaxRestarts <- 0, MaxTools <- 0,
       Break <- IF Break = "AnswerTwice" THEN "AnswerTwice" ELSE "none",
       st <- qst,
       ep <- [i \in Ids |-> IF qst[i] = "none" THEN 0 ELSE 1 + Cardinality(QAsked(i))],
       kind <- [i \in Ids |-> "question"], asker <- [i \in Ids |-> row[i].from],
       claims <- qclaims, acting <- {}, cdone <- qclaims,
       acted <- {<<c.t, c.s>> : c \in qclaims}, twice <- FALSE, cut <- {}, pwrong <- {},
       up <- up, restarts <- restarts,
       hconn <- [p \in {} |-> FALSE], hrow <- [p \in {} |-> "none"], hmarking <- {},
       hout <- [p \in {} |-> <<>>], hwrong <- {},
       took <- [i \in Ids |-> 0], orec <- [i \in Ids |-> "none"], otold <- {},
       turn <- "working", blocks <- 0, tools <- 0, crashes <- 0, gaveUp <- FALSE

-----------------------------------------------------------------------------
Init ==
    /\ up = TRUE /\ restarts = 0
    /\ proc = [a \in Agents |-> IF a \in Mains THEN "idle" ELSE "working"]
    /\ epoch = [a \in Agents |-> 0] /\ life = [a \in Agents |-> 1] /\ faults = 0
    /\ turned = [a \in Agents |-> TRUE]
    /\ held = [a \in Agents |-> {}] /\ reqs = 0
    /\ claims = {} /\ done = {} /\ calls = {} /\ fixed = {} /\ twice = FALSE /\ cut = {}
    /\ svc = [s \in Services |-> "none"] /\ owner = [s \in Services |-> None]
    /\ keep = [s \in Services |-> FALSE]
    /\ wrong = {} /\ ending = {}
    /\ row = [i \in Ids |-> D!NoRow] /\ hand = {} /\ claimed = {}
    /\ wire = [i \in Ids |-> 0] /\ waiter = [a \in Agents |-> 0]
    /\ dcall = [i \in Ids |-> "none"]
    /\ tx = [a \in Agents |-> <<>>] /\ fold = [i \in Ids |-> "none"]
    /\ rmem = {} /\ last = [a \in Agents |-> D!NoResult]
    /\ unsure = {} /\ dlost = {} /\ dwrong = {}
    /\ qst = [i \in Ids |-> "none"] /\ qclaims = {}

-----------------------------------------------------------------------------
(* The framework: its tables survive a restart; what it holds in memory does not *)

FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ Cl("none")!Restart
    /\ D!Restart
    /\ ending' = IF Break = "EndInMemory" THEN {} ELSE ending
    /\ UNCHANGED <<agentVars, svcVars, qvars, wrong>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<restarts, agentVars, claimVars, svcVars, qvars, wrong, ending, dvars>>

-----------------------------------------------------------------------------
(* The agents: turns, a person's prompt to a main session; sticking, dying, ending *)

\* A delegate starts on its brief; its later turns come from messages,
\* resumes, and turns it starts by itself.
Prompted(a) ==
    /\ a \in Mains /\ proc[a] = "idle" /\ proc' = [proc EXCEPT ![a] = "working"]
    /\ UNCHANGED <<up, restarts, epoch, life, faults, turned, held, reqs, claimVars, svcVars, qvars, wrong, ending, dvars>>

\* A delegate starts a turn by itself (F-31's new-2): its result names no row.
SelfStarts(d) ==
    /\ SelfTurns /\ d \in Delegates /\ proc[d] = "idle"
    /\ proc' = [proc EXCEPT ![d] = "working"]
    /\ UNCHANGED <<up, restarts, epoch, life, faults, turned, held, reqs, claimVars, svcVars, qvars, wrong, ending, dvars>>

\* `a`'s turn ends with a result, which names the rows whose turn it is.
TurnEnds(a) ==
    /\ proc[a] = "working" /\ proc' = [proc EXCEPT ![a] = "idle"]
    /\ turned' = [turned EXCEPT ![a] = TRUE]
    /\ D!Result(a)
    /\ UNCHANGED <<up, restarts, epoch, life, faults, held, reqs, claimVars, svcVars, qvars, wrong, ending>>

\* An agent sticks, or its process ends. A row whose turn it was then has
\* no result, and never will: the fold reads the exit.
Faults(a) ==
    /\ faults < MaxFaults
    /\ \/ /\ proc[a] = "working" /\ proc' = [proc EXCEPT ![a] = "stuck"]
          /\ UNCHANGED dvars
       \/ /\ proc[a] \in {"working", "idle", "stuck"} /\ proc' = [proc EXCEPT ![a] = "dead"]
          /\ D!Exited(a, FALSE)
    /\ epoch' = [epoch EXCEPT ![a] = @ + 1] /\ faults' = faults + 1
    /\ UNCHANGED <<up, restarts, life, turned, held, reqs, claimVars, svcVars, qvars, wrong, ending>>

\* Claude Code asks for a permission: Intake holds a PermissionRequest of the session (Hold.tla).
\* The requests held are part of the state a fix reads (`Mains.fix_state/3`), so one moves it.
Requests(a) ==
    /\ up /\ proc[a] = "working" /\ reqs < MaxRequests
    /\ held' = [held EXCEPT ![a] = @ \cup {reqs + 1}] /\ reqs' = reqs + 1
    /\ epoch' = [epoch EXCEPT ![a] = @ + 1]
    /\ UNCHANGED <<up, restarts, proc, life, faults, turned, claimVars, svcVars, qvars, wrong, ending, dvars>>

\* A person answers a request on the screen, before any fix does: it is held no more, and the
\* state moves.
PersonAnswers(a) ==
    /\ up /\ held[a] # {}
    /\ \E i \in held[a] : held' = [held EXCEPT ![a] = @ \ {i}]
    /\ epoch' = [epoch EXCEPT ![a] = @ + 1]
    /\ UNCHANGED <<up, restarts, proc, life, faults, turned, reqs, claimVars, svcVars, qvars, wrong, ending, dvars>>

\* A delegate ends once its report is delivered (Delegate.tla).
DelegateEnds(d) ==
    /\ d \in Delegates /\ proc[d] = "idle"
    /\ proc' = [proc EXCEPT ![d] = "ended"] /\ epoch' = [epoch EXCEPT ![d] = @ + 1]
    /\ D!Exited(d, FALSE)
    /\ UNCHANGED <<up, restarts, life, faults, turned, held, reqs, claimVars, svcVars, qvars, wrong, ending>>

\* A delegate's start refused once its call reached Sessions (F-153): its
\* process ran and was stopped before its first turn took anything (a
\* headless start whose init never came), and none of it runs again. It has
\* no report, and no fix takes it: it has no process. Rows due to it are
\* marked ended, as to one that ended (`Over`).
StartRefused(d) ==
    /\ StartsRefused /\ d \in Delegates /\ proc[d] = "working" /\ life[d] = 1
    /\ epoch[d] = 0 /\ tx[d] = <<>>
    /\ proc' = [proc EXCEPT ![d] = "refused"] /\ epoch' = [epoch EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<up, restarts, life, faults, turned, held, reqs, claimVars, svcVars, qvars, wrong, ending, dvars>>

\* Delegates' settle: a refused start's agent row is ended once no process of
\* it may live, as a failed delegate's is, so it holds its main session's end
\* no more. RefusedKept leaves it, as the first end-to-end run's code did.
RefusedEnded(d) ==
    /\ up /\ proc[d] = "refused" /\ Break # "RefusedKept"
    /\ proc' = [proc EXCEPT ![d] = "ended"]
    /\ UNCHANGED <<up, restarts, epoch, life, faults, turned, held, reqs, claimVars, svcVars, qvars, wrong, ending, dvars>>

\* A main session's end (F-143), the operator's alone: refused while any of
\* its delegates has not ended, so none is left with no parent; SIGTERM once
\* it is idle, as any stop, or nothing to send once its process is gone. Its
\* row is then ended, and what it owns ends with it.
MayEnd(c, m) == c \in Operators \/ (Break = "EndByAgent" /\ c \in Mains /\ c # m)
LiveDelegates(m) == {d \in Delegates : Main(d) = m /\ proc[d] # "ended"}

\* The end asked: the checks and the mark in one step, then the SIGTERM. The
\* row is ended in that step when the process is gone, or exits within the
\* stop's deadline; else the stop answers unknown and the row keeps the mark.
MainEnds(c, m) ==
    /\ up /\ m \in Mains /\ m \notin ending /\ Live(c) /\ MayEnd(c, m)
    /\ LiveDelegates(m) = {} \/ Break = "EndWithDelegates"
    /\ proc[m] \in {"idle", "dead"} \/ (Break = "EndBusy" /\ proc[m] \in {"working", "stuck"})
    /\ wrong' = wrong \cup (IF c \in Operators THEN {} ELSE {"end by agent"})
                       \cup (IF proc[m] \in {"idle", "dead"} THEN {} ELSE {"end busy"})
    /\ \/ /\ proc' = [proc EXCEPT ![m] = "ended"] /\ epoch' = [epoch EXCEPT ![m] = @ + 1]
          /\ IF proc[m] = "dead" THEN UNCHANGED dvars ELSE D!Exited(m, FALSE)
          /\ UNCHANGED ending
       \/ /\ StopsUnknown /\ proc[m] # "dead"
          /\ ending' = ending \cup {m}
          /\ UNCHANGED <<proc, epoch, dvars>>
    /\ UNCHANGED <<up, restarts, life, faults, turned, held, reqs, claimVars, svcVars, qvars>>

\* The SIGTERM that outlived the stop's deadline takes, or Recoveries ends
\* the process by its record (`no_exit`): it exits.
EndTerm(m) ==
    /\ m \in ending /\ proc[m] \in {"working", "idle", "stuck"}
    /\ proc' = [proc EXCEPT ![m] = "dead"] /\ epoch' = [epoch EXCEPT ![m] = @ + 1]
    /\ D!Exited(m, FALSE)
    /\ UNCHANGED <<up, restarts, life, faults, turned, held, reqs, claimVars, svcVars, qvars, wrong, ending>>

\* Sessions' settle: a row whose end is asked is ended once its process is gone.
EndSettled(m) ==
    /\ up /\ m \in ending /\ proc[m] = "dead"
    /\ proc' = [proc EXCEPT ![m] = "ended"]
    /\ ending' = ending \ {m}
    /\ UNCHANGED <<up, restarts, epoch, life, faults, turned, held, reqs, claimVars, svcVars, qvars, wrong, dvars>>

-----------------------------------------------------------------------------
(* Mailbox: a message along an edge, stored, then into an ended turn, once *)

Mailbox(A) == A /\ UNCHANGED <<up, restarts, agentVars, claimVars, svcVars, qvars, wrong, ending>>

Send(c, t) ==
    /\ Live(c)
    /\ Edge(c, t) \/ (Break = "OffEdge" /\ c # t)
    /\ Cardinality(Msgs) < MaxMsgs
    /\ Mailbox(D!Store(D!NextId, c, t, "msg"))

\* The ask and its answer write the prompt's row (Q) as well as Mailbox's.
AskStep(A) == A /\ UNCHANGED <<up, restarts, agentVars, claimVars, svcVars, wrong, ending>>

\* An agent asks a person: a row to the operator, kept for the app, never
\* delivered (Delivery's StoreRow keeps a row to no session), and the prompt
\* it opens. One step, and the agent's turn goes on as it was.
Ask(a) ==
    /\ Live(a) /\ Operators # {}
    /\ Cardinality(Asks) < MaxAsks
    /\ Q!Open(D!NextId)
    /\ AskStep(D!Store(D!NextId, a, CHOOSE o \in Operators : TRUE, "ask"))

\* The operator answers ask i, Prompt's AnswerNow: the prompt read still open,
\* the answer claimed on its state, and one row to the asker under the ask's
\* key, so the first answer only goes in. It is due as any row is, and settled
\* ended when the asker ended first. Under AnswerTwice the prompt's check
\* takes an answered one.
Answers(o, i, t) ==
    /\ up /\ o \in Operators /\ row[i].kind = "ask" /\ D!NextId \in Ids
    /\ t = row[i].from \/ Break = "AnswerToOther"
    /\ Q!AnswerNow(i, o, "answer")
    /\ AskStep(/\ D!StoreRow(D!NextId, o, t, "answer", i, D!NoResult)
               /\ UNCHANGED <<hand, claimed, wire, waiter, dcall, tx, fold, rmem, last, unsure,
                              dlost, dwrong>>)

\* Claude Code takes a row: a turn starts with it, or a stream line joins
\* the one running.
Takes(i) ==
    LET a == row[i].to IN
    /\ D!Take(i)
    /\ proc' = [proc EXCEPT ![a] = IF @ = "idle" THEN "working" ELSE @]
    /\ UNCHANGED <<up, restarts, epoch, life, faults, turned, held, reqs, claimVars, svcVars, qvars, wrong, ending>>

\* The transport by the target: the stream to a delegate, the typed write to
\* a main session. Its waiter is Delivery.tla's and Delegate.tla's; one
\* transport per kind keeps this spec's state small, and the edges, the
\* order and the replies are the same over any.
Transport(i) == IF row[i].to \in Delegates THEN "stream" ELSE "typed"

Settle(i) ==
    \/ D!SettleReplay(i) \/ D!SettleExit(i, D!InTx(i)) \/ D!SettleSeen(i, D!InTx(i))

RowSteps(i) ==
    Mailbox(\/ D!Refused(i) \/ D!Reclaim(i) \/ Settle(i) \/ D!EndedFirst(i)
            \/ D!ReplyStored(i) \/ D!NoticeStored(i))

Mailboxes(i) ==
    \/ Mailbox(D!Mark(i, Transport(i))) \/ Mailbox(D!Handed(i)) \/ Takes(i) \/ RowSteps(i)

-----------------------------------------------------------------------------
(* Grants: a parent's fix takes a claim on its child's current state first *)

\* A stop ends a delegate only: a main session's end is a person's, outside Grants.
Stoppable(t, k) == t \in Delegates \/ k # "stop" \/ Break = "OperatorStopsMain"

\* What fix k needs of t's state, read from the state it claims (`Delegates.fix_check/2`,
\* `Mains.fix_check/2`): a resume of a delegate refused `:live`, of a main session
\* `{:not_stopped, status}` (a row whose end is asked is `stopping`); a stop refused for its
\* report; an interrupt of a process that is gone.
Needed(t, k) == /\ proc[t] = Needs[k]
                /\ k # "resume" \/ t \notin ending \/ Break = "ResumeEnding"

\* The claim on t's state now, for the fix k its caller names (Cl!Take), taken only once the
\* state needs it (F-149): a claim kept after a refusal would refuse the state's next fix, the
\* one it needs, as already claimed until the state moved. ClaimBeforeCheck takes it on any.
ClaimTaken(c, t, k) ==
    /\ up /\ Live(c)
    /\ Needed(t, k) \/ Break = "ClaimBeforeCheck"
    /\ MayFix(c, t) /\ Stoppable(t, k)
    /\ Cl(ClaimBreak(c))!Take(c, t, k)
    /\ wrong' = wrong \cup (IF Needed(t, k) THEN {} ELSE {"claim before check"})
    /\ UNCHANGED <<up, restarts, agentVars, svcVars, qvars, ending, dvars>>

\* The answer of request i of t, as the operator or t's parent makes it (`answer`, F-147), claimed
\* on t's state now. The request it names must be one the state holds, checked before the claim
\* is taken, as its label is (F-148): a claim kept after a refusal would leave the next answer,
\* with the right id, refused as already claimed until the state moved. AnswerNotHeld takes the
\* claim on any id.
AnswerClaimed(c, t, i) ==
    /\ up /\ Live(c) /\ MayFix(c, t)
    /\ i \in held[t] \/ Break = "AnswerNotHeld"
    /\ Cl(ClaimBreak(c))!Take(c, t, "answer")
    /\ wrong' = wrong \cup (IF i \in held[t] THEN {} ELSE {"answer not held"})
    /\ UNCHANGED <<up, restarts, agentVars, svcVars, qvars, ending, dvars>>

\* The claim is current, and the target is in the state its fix needs: an answer's, a request
\* still held. A row whose end is asked is never resumed: Sessions starts no name stopping or
\* ended. An answer does not need the process to be a given one, nor a row not ending.
CanAct(r) == /\ Cl(ClaimBreak(r.by))!Current(r)
             /\ IF r.act = "answer" THEN held[r.t] # {} ELSE proc[r.t] = Needs[r.act]
             /\ r.act = "answer" \/ r.t \notin ending \/ Break = "ResumeEnding"


\* The fix acts on the state it claimed. An interrupt or a resume may not
\* help; the state is then still claimed. An interrupt that helps ends the
\* turn with a result (`error_during_execution`) that names its row; a
\* resume starts a new process, whose turn names none; a stop takes an idle
\* agent. An answer takes one request out of those held, and leaves the process as it is.
FixActs(r) ==
    /\ up /\ CanAct(r) /\ Cl(ClaimBreak(r.by))!Act(r)
    /\ \/ /\ proc' = [proc EXCEPT ![r.t] = CASE r.act = "interrupt" -> "idle"
                                             [] r.act = "resume" -> "working"
                                             [] r.act = "answer" -> @
                                             [] OTHER -> "ended"]
          /\ IF r.act = "answer"
               THEN \E i \in held[r.t] : held' = [held EXCEPT ![r.t] = @ \ {i}]
               ELSE held' = held
          /\ epoch' = [epoch EXCEPT ![r.t] = @ + 1]
          /\ life' = [life EXCEPT ![r.t] = IF r.act = "resume" THEN @ + 1 ELSE @]
          \* A resume's new process has had no turn yet; an interrupt ends one.
          /\ turned' = [turned EXCEPT ![r.t] = CASE r.act = "resume" -> FALSE
                                                 [] r.act = "interrupt" -> TRUE
                                                 [] OTHER -> @]
          /\ CASE r.act = "interrupt" -> D!Result(r.t)
               [] r.act = "stop" -> D!Exited(r.t, FALSE)
               [] OTHER -> UNCHANGED dvars
       \/ (r.act # "stop" /\ UNCHANGED <<proc, epoch, life, turned, held, dvars>>)
    /\ wrong' = wrong \cup (IF epoch[r.t] = r.s THEN {} ELSE {"stale"})
                       \cup (IF r.act # "answer" /\ r.t \in ending THEN {"resume ending"} ELSE {})
    /\ UNCHANGED <<up, restarts, faults, reqs, svcVars, qvars, ending>>

FixRefused(r) ==
    /\ up /\ ~CanAct(r) /\ Cl("none")!LetGo(r)
    /\ UNCHANGED <<up, restarts, agentVars, svcVars, qvars, wrong, ending, dvars>>

\* A restart cut off the call: the claim ends, and its fix is never sent again.
ClaimSettled(r) ==
    /\ up /\ Cl("none")!Settle(r)
    /\ UNCHANGED <<up, restarts, agentVars, svcVars, qvars, wrong, ending, dvars>>

-----------------------------------------------------------------------------
(* Services: one owner; fixed by it or its parent; handed along an edge; *)
(* ended with the owner, or kept for its parent                          *)

svcOthers == <<up, restarts, agentVars, claimVars, ending, dvars, qvars>>

ServiceStarts(a, s) ==
    /\ up /\ svc[s] = "none" /\ Live(a)
    /\ svc' = [svc EXCEPT ![s] = "running"] /\ owner' = [owner EXCEPT ![s] = a]
    /\ keep' \in {[keep EXCEPT ![s] = k] : k \in BOOLEAN}
    /\ UNCHANGED <<svcOthers, wrong>>

\* A restart or a stop: a stop ends the service; a restart leaves it running.
ServiceFixed(c, s) ==
    /\ up /\ svc[s] = "running" /\ Live(c) /\ MayFixService(c, owner[s])
    /\ \/ svc' = [svc EXCEPT ![s] = "ended"] /\ owner' = [owner EXCEPT ![s] = None]
       \/ UNCHANGED <<svc, owner>>
    /\ wrong' = wrong \cup (IF c = owner[s] \/ IsChild(owner[s], c) \/ c \in Operators
                              THEN {} ELSE {"service fix"})
    /\ UNCHANGED <<svcOthers, keep>>

ServiceHanded(c, s, b) ==
    LET o == owner[s] IN
    /\ up /\ svc[s] = "running" /\ o \in Agents /\ o # b
    /\ Live(c) /\ Live(o) /\ Live(b) /\ MayHand(c, o, b)
    /\ owner' = [owner EXCEPT ![s] = b]
    /\ wrong' = wrong \cup (IF c = o /\ (IsChild(o, b) \/ IsChild(b, o)) THEN {} ELSE {"hand"})
    /\ UNCHANGED <<svcOthers, svc, keep>>

\* A kept service goes to a delegate's main session; one a main session kept
\* ends with it, since the operator owns nothing.
Kept(s) == keep[s] /\ (owner[s] \in Delegates \/ Break = "MainKeeps")

ServiceOwnerEnded(s) ==
    /\ up /\ svc[s] = "running" /\ owner[s] \in Agents /\ proc[owner[s]] = "ended"
    /\ Kept(s) \/ Break # "NoOwnerWatch"
    /\ IF Kept(s)
         THEN owner' = [owner EXCEPT ![s] = Main(owner[s])] /\ UNCHANGED svc
         ELSE /\ owner' = [owner EXCEPT ![s] = None]
              /\ svc' = IF Break = "OwnerClearedFirst" THEN svc ELSE [svc EXCEPT ![s] = "ended"]
    /\ UNCHANGED <<svcOthers, keep, wrong>>

-----------------------------------------------------------------------------
Next ==
    \/ FrameworkDies \/ FrameworkStarts
    \/ \E a \in Agents : \/ Prompted(a) \/ SelfStarts(a) \/ TurnEnds(a) \/ Faults(a)
                         \/ DelegateEnds(a) \/ Requests(a) \/ PersonAnswers(a)
                         \/ StartRefused(a) \/ RefusedEnded(a)
    \/ \E c \in Actors, t \in Agents : Send(c, t) \/ \E k \in Kinds : ClaimTaken(c, t, k)
    \/ \E c \in Actors, t \in Agents, i \in Reqs : AnswerClaimed(c, t, i)
    \/ \E c \in Agents, o \in Operators : Send(c, o)
    \/ \E a \in Agents : Ask(a)
    \/ \E c \in Actors, m \in Mains : MainEnds(c, m)
    \/ \E m \in Mains : EndTerm(m) \/ EndSettled(m)
    \/ \E o \in Operators, i \in Ids, t \in Agents : Answers(o, i, t)
    \/ \E i \in Ids : Mailboxes(i)
    \/ \E r \in calls : FixActs(r) \/ FixRefused(r)
    \/ \E r \in claims : ClaimSettled(r)
    \/ \E s \in Services : \/ ServiceOwnerEnded(s)
                           \/ \E a \in Agents : ServiceStarts(a, s)
                           \/ \E a \in Actors : ServiceFixed(a, s)
                           \/ \E c \in Agents, b \in Actors : ServiceHanded(c, s, b)

Fairness ==
    /\ WF_vars(FrameworkStarts)
    /\ \A a \in Agents : WF_vars(TurnEnds(a))
    /\ \A i \in Ids :
         SF_vars(Mailboxes(i)) /\ SF_vars(Mailbox(D!Handed(i)))
    /\ WF_vars(\E r \in calls : FixActs(r) \/ FixRefused(r))
    /\ WF_vars(\E r \in claims : ClaimSettled(r))
    /\ \A s \in Services : WF_vars(ServiceOwnerEnded(s))
    /\ \A m \in Mains : WF_vars(EndTerm(m)) /\ WF_vars(EndSettled(m))
    /\ \A d \in Delegates : WF_vars(RefusedEnded(d))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ proc \in [Agents -> {"working", "idle", "stuck", "dead", "ended", "refused"}]
    /\ epoch \in [Agents -> 0..MaxEpoch] /\ turned \in [Agents -> BOOLEAN]
    /\ held \in [Agents -> SUBSET Reqs] /\ reqs \in 0..MaxRequests
    /\ claims \subseteq
         [by : Actors, t : Agents, s : 0..MaxEpoch, act : Kinds \cup {"answer"}, n : 1..2]
    /\ calls \subseteq claims \ done /\ done \subseteq claims
    /\ twice \in BOOLEAN /\ cut \subseteq Agents \X (0..MaxEpoch)
    /\ svc \in [Services -> {"none", "running", "ended"}]
    /\ owner \in [Services -> Agents \cup {None}]
    /\ ending \subseteq Mains
    /\ qst \in [Ids -> Q!Statuses]
    /\ \A i \in Ids : row[i].st # "none" => row[i].from \in Actors \cup {D!Framework} \cup Agents
    /\ D!TypeOK

\* Delivery's, on the messages: each in one transcript at most once, only
\* into an ended turn, in order per sender and addressee; a row that says
\* its delegate ended first is true; one answer per message, the result
\* that names it.
DeliveredAtMostOnce == D!AtMostOnce
OnlyIntoEndedTurn == D!OnlyIntoEndedTurn
InOrder == D!InOrder
EndedNotDelivered == D!EndedNotDelivered
ReplyOnce == D!ReplyOnce
ReplyOrNotice == D!ReplyOrNotice
ReplyNamesMessage == D!ReplyNamesItsRow

\* Every delivered message went along an edge, to its addressee.
AlongEdges ==
    \A a \in Agents : \A k \in DOMAIN tx[a] :
        LET m == row[tx[a][k]] IN
        m.kind = "msg" => Edge(m.from, m.to) /\ a = m.to

\* A reply or a notice goes from a delegate to its message's sender: its
\* main session, or the operator, which keeps it.
ReplyToSender ==
    \A j \in Ids : row[j].kind \in {"reply", "notice"} =>
        /\ row[row[j].re].to \in Delegates
        /\ row[j].to = row[row[j].re].from

\* Every row to the operator is kept for the app, never delivered: an ask
\* from an agent, or a reply or a notice to its own message. No message goes
\* to it.
OperatorRowsKept ==
    \A i \in Ids : row[i].to \in Operators =>
        /\ row[i].st = "kept" /\ row[i].kind \in {"ask", "reply", "notice"}
        /\ row[i].kind = "ask" => row[i].from \in Agents

\* An ask has at most one answer.
AnswerOnce == \A k \in Ids : Cardinality(AnswerRows(k)) <= 1

\* Prompt's, on the asks: each answer's claim is a person's (the operator's), one per state.
AskAnsweredRightly == Q!OnlyRightful
AskClaimOnce == Q!OneClaimPerState

\* An answer is the operator's, to the agent that asked.
AnswerToAsker ==
    \A j \in Ids : row[j].kind = "answer" =>
        /\ row[row[j].re].kind = "ask" /\ row[j].from \in Operators
        /\ row[j].to = row[row[j].re].from

\* At most one claim holds a child's state, and a state is fixed at most once.
OneClaimPerState == Cl("none")!OneClaimPerState
OneFixPerState == Cl("none")!OneActPerState
FixOnClaimedState == "stale" \notin wrong

\* An answer's claim is taken only on a request its state holds, so an id the state does not
\* hold takes nothing (F-148); and no claim on a state now stands with no request held in it.
AnswerClaimsHeld == "answer not held" \notin wrong
AnswerStateHoldsRequest ==
    \A r \in claims : r.act = "answer" /\ epoch[r.t] = r.s => held[r.t] # {}

\* A fix is claimed only on a state that needs it (F-149), so one the state refuses takes no
\* claim; and no claim of an interrupt or a resume stands on a state now that does not need it.
\* A stop's idle may pass with no move of the state, so a stop refused when it acts is not one.
FixClaimsChecked == "claim before check" \notin wrong
ClaimedStateNeedsFix ==
    \A r \in claims : r.act \in {"interrupt", "resume"} /\ epoch[r.t] = r.s => proc[r.t] = Needs[r.act]

\* Only a parent fixes, and only its own child; the operator is a parent of
\* every main session, and so of every agent.
OnlyParentFixes == \A r \in claims : IsChild(r.t, r.by) \/ r.by \in Operators
NoSelfFix == \A r \in claims : r.by # r.t
\* No agent fixes a main session, only the operator; no fix stops one: only
\* its end does.
MainFixedByOperatorOnly == \A r \in claims : r.t \in Mains => r.by \in Operators /\ r.act # "stop"

\* A main session's end is the operator's, taken idle or with its process
\* gone, and leaves no delegate of it that has not ended.
MainEndedByOperator == "end by agent" \notin wrong
MainEndedIdle == "end busy" \notin wrong
NoDelegateWithoutParent == \A d \in Delegates : proc[Main(d)] = "ended" => proc[d] = "ended"

\* No resume takes a main session whose end is asked.
NoResumeOfEnding == "resume ending" \notin wrong

\* An end asked ends the row, with no second call, across a restart.
EndAskedEnds == \A m \in Mains : m \in ending ~> proc[m] = "ended"

\* A delegate whose start was refused ends, so its main session may end: none
\* is left neither running nor ended, which the end would wait on forever.
RefusedEnds == \A d \in Delegates : proc[d] = "refused" ~> proc[d] = "ended"

\* A running service has one owner; an ended one has none.
OneOwner ==
    \A s \in Services : /\ svc[s] = "running" => owner[s] \in Agents
                        /\ svc[s] # "running" => owner[s] = None

\* Only the owner or the owner's parent fixes a service.
ServiceFixedByOwnerOrParent == "service fix" \notin wrong

\* A service is handed only by its owner, to the owner's parent or a child.
HandedAlongEdge == "hand" \notin wrong

Waiting(i) == row[i].st \in {"due", "sending"}

\* A message to a live agent, one whose turn ends again and again, is delivered.
MessageDelivered ==
    \A i \in Ids, a \in Agents :
        []<>(proc[a] = "idle") => [](Waiting(i) /\ row[i].to = a => <>(row[i].st = "delivered"))

\* A row to an agent that has ended settles: it went in before the end, or
\* its row says the agent ended first (Delivery's Arrives).
EndedMarked ==
    \A i \in Ids : [](Waiting(i) /\ row[i].to \in Agents /\ proc[row[i].to] = "ended"
                      => <>(row[i].st \in {"delivered", "ended"}))

\* A claim's call ends: its fix verified, or the claim released.
ClaimEnds == Cl("none")!ClaimsEnd

\* A claim a restart cut off is never acted on.
NoActOnCutOffClaim == Cl("none")!NoActOnCutOffClaim

\* A service whose owner ended without keeping it ends, and one an ended main
\* session owned, kept or not.
ServiceEndsWithOwner ==
    \A s \in Services :
        (svc[s] = "running" /\ owner[s] \in Agents /\ proc[owner[s]] = "ended"
            /\ (~keep[s] \/ owner[s] \in Mains))
            ~> svc[s] = "ended"

\* A delivered message whose turn ends, with a result or with the process's
\* end, gets its reply or its notice.
ReplyOrNoticeComes == D!AnswerComes

=============================================================================
