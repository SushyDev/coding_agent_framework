------------------------------- MODULE Boxes -------------------------------
(***************************************************************************)
(* The seven boxes composed by their contracts (F-162, "Contracts and one  *)
(* composed spec"; B1's first part, F-163). Each box is here only as what  *)
(* it promises at its interface and what it assumes of the boxes it calls; *)
(* how it keeps a promise is its own spec's, named below. The spec checks  *)
(* the faults that show only where two protocols meet:                     *)
(*                                                                         *)
(*   a delivery during a move   Mailbox marks and hands a row while        *)
(*        Sessions stops the session and resumes it (a move is a stop and  *)
(*        a resume; the account and the transcript's copy are Move.tla's): *)
(*        NotCutByStop, OnlyToItsProcess;                                  *)
(*   a lease across a dialog    the Scheduler's lease of a start that      *)
(*        waits on a person at a startup dialog, a prompt in Prompts:      *)
(*        LeaseWhileLive, SeatsHold;                                       *)
(*   a prompt across a restart  a person's answer marked, handed to its    *)
(*        owner (Sessions' press, in the agent process) and settled by the *)
(*        owner's evidence, with either restart between: OneAnswer,        *)
(*        KeptAcrossRestart;                                               *)
(*   a remedy racing a fix      the Watch's healer and a parent (Team)     *)
(*        acting on one agent's state, both through the Ledger's claim:    *)
(*        OneActPerState, NeverWorking;                                    *)
(*   one agent's restart and the whole one   an agent process crashes      *)
(*        alone (Restart(a)), or the framework restarts: OneProcess (a     *)
(*        restart re-adopts, never relaunches), AtMostOnce (a hand a crash *)
(*        cut answers unknown, and the mark is kept), OwnBudget (an        *)
(*        agent's restart budget is its own), and liveness Escalated (a    *)
(*        budget run out is a prompt).                                     *)
(*   a usage limit (F-178)   a running turn of the addressee ends at the   *)
(*        account's limit, which Usage records until its reset: the        *)
(*        Scheduler admits no start or resume meanwhile, and Mailbox marks *)
(*        no row into the turn before the reset: NoStartOnLimited,         *)
(*        NoRowIntoLimit. How each remedy goes on is Limit.tla's; here     *)
(*        the gate and the mark meet a dialog, a stop, a move and the      *)
(*        restarts. MaxLimits is 0 but in Boxes_Limit, so the other        *)
(*        configurations keep their state counts.                          *)
(*                                                                         *)
(* The contracts, by box, and the spec that keeps each (its header says    *)
(* how its properties imply what is assumed here, and what it does not):  *)
(*                                                                         *)
(*   Ledger (base, Claim.tla)  a claim once per state, acted on only while *)
(*        current, cut by a restart: instanced here as L, whole.           *)
(*   Sessions (Start, Agent, Move, Dialog, Stream, Intake with Hold)  the  *)
(*        agent row written first; a live process only under a row that   *)
(*        has not ended; a stop's SIGTERM only after an idle read, with    *)
(*        nothing sending to the session; `hand` writes a row only into an *)
(*        ended turn of the process it was marked for, else refuses; a     *)
(*        dialog's press only on the dialog it names, at most once; a      *)
(*        restart re-adopts from the row; a turn ended at a usage limit is *)
(*        `limited`, never ended (Limit.tla). Here: `row`, `live`, `gen`,  *)
(*        `turn`, `stuck`, `ep`, the agent process's memory (`task`,       *)
(*        `stopRead`, `call`'s hand) and its budget.                       *)
(*   Mailbox (Delivery)  one row in flight per addressee, marked only into *)
(*        a running row's ended turn, or a limited one past its reset,     *)
(*        refused undoes the mark, unknown keeps it, settled only by the   *)
(*        evidence: `mst`, `mgen`, `call`.                                 *)
(*   Prompts (Prompt.tla, F-167, which Dialog.tla's answer and Team.tla's  *)
(*        ask instance)  one prompt per state, a row; an answer marked     *)
(*        answering before it is handed; a cut answer settled by the       *)
(*        owner's evidence, unknown kept for a person, never sent again:   *)
(*        `pr`, `rp`. Prompt.tla's header says how its properties imply    *)
(*        OneAnswer, KeptAcrossRestart and Escalated here.                 *)
(*   Team (Team, Delegate, Checkout)  every act through operate/4 under a  *)
(*        Ledger claim, its need checked against the state the claim takes *)
(*        (Team.tla's Needed): the parent's fix here.                      *)
(*   Scheduler (Schedule)  a lease within capacity, released once and only *)
(*        when the owner of its row says the work ended: `lease`; none     *)
(*        granted on an account Usage's record says limited (Limit.tla's   *)
(*        NoStartOnLimited; Schedule.tla's budget gate is the same gate):  *)
(*        `acct`.                                                          *)
(*   Hosts (Copy, Shell)  a job runs only under its unreleased lease       *)
(*        (Schedule.tla's NoRunUnleased, shape Fence). No interaction the  *)
(*        design names here needs more of Hosts; it is left out.           *)
(*   Watch (Heal.tla, B1's later part)  a remedy only through operate/4,   *)
(*        under the Ledger's claim, its precondition read before the claim *)
(*        and never on a working agent: `seen`, the healer's acts.         *)
(*                                                                         *)
(* One agent's restart against the contract specs (F-164). RestartAgent    *)
(* here is the step each of them has, named the same, beside its whole     *)
(* restart and bounded with it by MaxRestarts; each effect of it here is   *)
(* checked there against the mechanism:                                    *)
(*   task := none, SettlePrompt   Dialog.tla's RestartAgent: the press     *)
(*        tasks end, a mark pressing is read again as cut or unknown, and  *)
(*        AtMostOnce (so OneAnswer) holds;                                 *)
(*   CutCalls, mark kept (UnknownUndoes)   Delivery.tla's AgentCut, whose  *)
(*        write may have gone before the crash: AtMostOnce and             *)
(*        SendingSettles hold, and AgentCutUndoes fails; Move.tla and      *)
(*        Delegate.tla cut a hand to the session and to the parent by it;  *)
(*   stopRead := FALSE   Move.tla's RestartAgent loses the idle read, and  *)
(*        the stop reads again (NotCutByEnd);                              *)
(*   no relaunch (OneProcess, Relaunch)   Start.tla's RestartAgent: the    *)
(*        init re-adopts by Adopt, ReRead and the cues, never by a hold,   *)
(*        and NoHeldWithoutRow holds; Delegate.tla's adopts a start cut    *)
(*        under way, an orphan for Recoveries when no line went in;        *)
(*   Release's WorkEnded   Delegate.tla's WorkEndedIsFree, the owner's     *)
(*        promise checked where its statuses are (StatusEndsWork fails).   *)
(* The budget (OwnBudget, Escalated) is this spec's alone: there a restart *)
(* is bounded, not budgeted, as the design says ("How the specs meet OTP"). *)
(*                                                                         *)
(* Seams for B1's later parts. Prompts' `pr` and `rp` are the state        *)
(* Prompt.tla refines (F-167: Boxes' unknown is its cut, its Answer        *)
(* Prompt's Answer then Hand); the healer's steps are Heal.tla's           *)
(* (OnlyApproved, the cap and ActedOrAsked are left to it); Delivery.tla's *)
(* subscription adds a row's way to become due, which this spec leaves     *)
(* out.                                                                    *)
(*                                                                         *)
(* Left abstract: accounts and the transcript's copy (a move is a stop and *)
(* a resume, and the evidence `ev` is the row's transcript, which          *)
(* Move.tla's TranscriptKept keeps across it); the start's worktree,       *)
(* setup, hold and adoption (Start.tla: one step, Start); the lease's      *)
(* queue, classes and gates (a request is granted or not asked); how a     *)
(* row's text goes in (every transport is one `hand`); the senders, edges *)
(* and order (Team.tla, Delivery.tla); which dialog and which label; the   *)
(* allow-list and the cap (Heal.tla); hooks; time. One sender, so rows     *)
(* are marked oldest first. A fix is an interrupt of a stuck turn, and it  *)
(* may not help (the state stays). An agent is started once and may be    *)
(* resumed until `MaxGen` processes; it shows at most one dialog.          *)
(*                                                                         *)
(* Fairness: the boxes' steps happen while possible; Claude Code's turns   *)
(* end unless stuck, and keys sent land; a person answers an open prompt,  *)
(* clears an unknown one and answers a `restarts` prompt. Starts, stops,  *)
(* resumes, ends, crashes, a stuck turn, the healer's and the parent's    *)
(* acts, and restarts happen or not.                                       *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard of one *)
(* box's contract and has a Break_Boxes_<value>.cfg that TLC must fail.    *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Agents,       \* the agents
    Addressee,    \* the agent every row goes to
    NIds,         \* rows to it, 1..NIds, stored in that order
    Cap,          \* the seats the Scheduler grants
    MaxGen,       \* processes per agent: its start and its resumes
    MaxStuck,     \* stuck turns per agent
    Budget,       \* an agent process's restart budget (crashes before it gives up)
    MaxCrashes,   \* crashes of each agent process
    MaxWhole,     \* restarts of the whole framework
    MaxLimits,    \* times the account reaches its usage limit (0: never)
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "MarkWhileStopping", \* Mailbox marks a row for a session whose row is stopping
    "NoProcessCheck",    \* Sessions' hand writes into a process the row was not marked for
    "DialogEndsWork",    \* the owner says a start on a dialog ended, so its lease goes
    "ReopenCut",         \* Prompts reopens an answer a restart cut, with no person's clear
    "PromptInMemory",    \* an open prompt is kept in memory, so the whole restart loses it
    "HealerOwnClaim",    \* the healer acts under a claim of its own, not the Ledger's
    "StaleSymptom",      \* the healer claims on the symptom it read, not the state it claims
    "Relaunch",          \* an agent process's restart starts its program again
    "UnknownUndoes",     \* Mailbox takes a hand a crash cut (unknown) as refused
    "SharedBudget",      \* one agent's crash counts against every agent's budget
    "SilentGiveUp",      \* a budget run out opens no prompt
    "StartOnLimited",    \* the Scheduler grants a start or a resume on a limited account
    "MarkIntoLimited"    \* Mailbox marks a row into a turn ended at a limit before its reset
}

ASSUME Break \in Breaks
ASSUME Addressee \in Agents /\ Cap \in Nat /\ Budget \in Nat \ {0} /\ MaxLimits \in Nat

Ids == 1..NIds
Actors == {"parent", "healer"}

VARIABLES
    \* Sessions: the agent row (durable) and the process outside the BEAM
    row,       \* a -> none, starting, dialog, running, stopping, stopped, ended
    live,      \* a -> the processes of a that run (0 or 1; 2 is a relaunch's fault)
    gen,       \* a -> the number of a's newest process, which its row names
    turn,      \* a -> the newest process's turn: "ended", or running: "row" (a row started it) or
               \* "person", or "limited" (ended at a usage limit)
    stuck,     \* a -> its running turn is stuck
    ep,        \* a -> the number of a's state as the framework reads it, a claim's state
    \* Sessions: the agent process's memory, lost when it restarts
    task,      \* a -> a press it was handed: "none", "press" (to send), "told" (sent, to tell)
    stopRead,  \* a -> a stop's idle read is made, its SIGTERM not yet sent
    gaveUp,    \* a -> its supervisor gave up: no agent process runs for it
    crashes,   \* a -> its supervisor's count of restarts
    \* the outside: keys a press sent that have not landed
    keys,      \* a -> keys in flight
    \* Mailbox
    mst,       \* i -> none, due, sending, delivered, ended (durable)
    mgen,      \* i -> the process the mark is for (durable)
    call,      \* i -> Mailbox's hand of i through Sessions: "none", "asked", "handing"
    ev,        \* the evidence: the rows the addressee's transcript holds
    \* Scheduler
    lease,     \* a -> "none", "held", "released"
    \* Prompts
    pr,        \* a -> its dialog's prompt: none, open, answering, unknown, answered, withdrawn
    rp,        \* a -> a `restarts` prompt is open for it
    \* Usage: the account's record (F-178, Limit.tla)
    acct,      \* "open", or "limited" until its reset
    limits,    \* the limits so far
    \* Ledger (Claim.tla), and the Watch's memory
    claims, acting, cdone, acted, twice, cut,
    seen,      \* the agents the healer read a symptom of (in memory)
    whole,     \* restarts of the whole framework so far
    \* ghosts
    tx,        \* i -> times i went into a transcript
    applied,   \* a -> presses that landed on a's session
    own,       \* a -> crashes of a's own agent process
    wrong      \* the faults a guard failed to stop, by name

sessVars == <<row, live, gen, turn, stuck, ep>>
memVars == <<task, stopRead, gaveUp, crashes, keys>>
mailVars == <<mst, mgen, call, ev, tx>>
claimVars == <<claims, acting, cdone, acted, twice, cut>>
limVars == <<acct, limits>>
vars == <<sessVars, memVars, mailVars, lease, pr, rp, claimVars, seen, whole, limVars, applied, own,
          wrong>>

\* The Ledger: Claim.tla whole, on each agent's state number.
L == INSTANCE Claim WITH Targets <- Agents, Actors <- Actors, MaxState <- 0, Break <- "none",
                          now <- ep, rows <- claims, acting <- acting, done <- cdone,
                          acted <- acted, twice <- twice, cut <- cut

\* The agent process runs: supervised, its budget not run out.
Up(a) == ~gaveUp[a]

\* The Scheduler's gate on Usage's record (F-178): no start or resume while the account is
\* limited. Under StartOnLimited it admits one anyway.
Admits == acct = "open" \/ Break = "StartOnLimited"

\* A turn Mailbox may mark a row into: an ended one, or one ended at a limit once its reset
\* passed (the word to go on comes first, as Limit.tla's GoOn stores it then). Under
\* MarkIntoLimited, one ended at a limit before its reset too.
Open(a) ==
    \/ turn[a] = "ended"
    \/ turn[a] = "limited" /\ (acct = "open" \/ Break = "MarkIntoLimited")

-----------------------------------------------------------------------------
(* Sessions and the Scheduler: a start under a lease, a dialog, a stop and  *)
(* a resume, the settle of a row whose process is gone, an end             *)

Seats == {a \in Agents : lease[a] = "held"}

\* Sessions writes the row starting, the Scheduler grants a seat within its
\* capacity, and the program is held: one step here (Start.tla, Schedule.tla).
Start(a) ==
    /\ row[a] = "none" /\ lease[a] = "none" /\ Cardinality(Seats) < Cap /\ Up(a)
    /\ Admits
    /\ row' = [row EXCEPT ![a] = "starting"]
    /\ lease' = [lease EXCEPT ![a] = "held"]
    /\ live' = [live EXCEPT ![a] = 1]
    /\ gen' = [gen EXCEPT ![a] = 1]
    /\ UNCHANGED <<turn, stuck, ep, memVars, mailVars, pr, rp, claimVars, seen, whole, limVars,
                   applied, own, wrong>>

\* The pane shows a startup dialog: the row says so and a prompt opens for it.
ShowDialog(a) ==
    /\ row[a] = "starting" /\ live[a] > 0 /\ pr[a] = "none" /\ Up(a)
    /\ row' = [row EXCEPT ![a] = "dialog"]
    /\ pr' = [pr EXCEPT ![a] = "open"]
    /\ UNCHANGED <<live, gen, turn, stuck, ep, memVars, mailVars, lease, rp, claimVars, seen,
                   whole, limVars, applied, own, wrong>>

\* The session file names the process: the row runs, its turn ended.
Confirm(a) ==
    /\ row[a] = "starting" /\ live[a] > 0 /\ Up(a)
    /\ row' = [row EXCEPT ![a] = "running"]
    /\ UNCHANGED <<live, gen, turn, stuck, ep, memVars, mailVars, lease, pr, rp, claimVars, seen,
                   whole, limVars, applied, own, wrong>>

\* No row is sending to a.
NoneSending(a) == \A i \in Ids : a = Addressee => mst[i] # "sending"

\* A stop: the row says stopping and the idle read finds the turn ended and
\* nothing sending to it; the SIGTERM comes after (Term). Asked again after a
\* restart cut it.
StopRead(a) ==
    /\ row[a] \in {"running", "stopping"} /\ live[a] > 0 /\ ~stopRead[a] /\ Up(a)
    /\ turn[a] \in {"ended", "limited"} /\ NoneSending(a)
    /\ row' = [row EXCEPT ![a] = "stopping"]
    /\ stopRead' = [stopRead EXCEPT ![a] = TRUE]
    /\ UNCHANGED <<live, gen, turn, stuck, ep, task, gaveUp, crashes, keys, mailVars, lease, pr,
                   rp, claimVars, seen, whole, limVars, applied, own, wrong>>

\* The SIGTERM, by the record's pid and start time. It cuts a turn that runs.
Term(a) ==
    /\ stopRead[a] /\ Up(a)
    /\ live' = [live EXCEPT ![a] = 0]
    /\ stopRead' = [stopRead EXCEPT ![a] = FALSE]
    /\ stuck' = [stuck EXCEPT ![a] = FALSE]
    /\ ep' = [ep EXCEPT ![a] = IF stuck[a] THEN @ + 1 ELSE @]
    /\ turn' = [turn EXCEPT ![a] = "ended"]
    /\ wrong' = IF turn[a] = "row" THEN wrong \cup {"cut by stop"} ELSE wrong
    /\ UNCHANGED <<row, gen, task, gaveUp, crashes, keys, mailVars, lease, pr, rp, claimVars,
                   seen, whole, limVars, applied, own>>

\* Claude Code exits by itself.
Exits(a) ==
    /\ live[a] = 1
    /\ live' = [live EXCEPT ![a] = 0]
    /\ stuck' = [stuck EXCEPT ![a] = FALSE]
    /\ ep' = [ep EXCEPT ![a] = IF stuck[a] THEN @ + 1 ELSE @]
    /\ turn' = [turn EXCEPT ![a] = "ended"]
    /\ UNCHANGED <<row, gen, memVars, mailVars, lease, pr, rp, claimVars, seen, whole, limVars,
                   applied, own, wrong>>

\* A row whose process is gone settles stopped; its dialog's prompt, if one
\* waits, is withdrawn (Start.tla's settles, Prompts' withdrawn).
Settle(a) ==
    /\ row[a] \in {"starting", "dialog", "running", "stopping"} /\ live[a] = 0 /\ Up(a)
    /\ ~stopRead[a]
    /\ row' = [row EXCEPT ![a] = "stopped"]
    /\ pr' = [pr EXCEPT ![a] = IF @ \in {"open", "answering", "unknown"} THEN "withdrawn" ELSE @]
    /\ task' = [task EXCEPT ![a] = "none"]
    /\ UNCHANGED <<live, gen, turn, stuck, ep, stopRead, gaveUp, crashes, keys, mailVars, lease,
                   rp, claimVars, seen, whole, limVars, applied, own, wrong>>

\* A resume, a move's on the other account among them, under the same lease.
Resume(a) ==
    /\ row[a] = "stopped" /\ lease[a] = "held" /\ gen[a] < MaxGen /\ Up(a) /\ Admits
    /\ row' = [row EXCEPT ![a] = "running"]
    /\ live' = [live EXCEPT ![a] = 1]
    /\ gen' = [gen EXCEPT ![a] = @ + 1]
    /\ turn' = [turn EXCEPT ![a] = "ended"]
    /\ UNCHANGED <<stuck, ep, memVars, mailVars, lease, pr, rp, claimVars, seen, whole, limVars,
                   applied, own, wrong>>

\* Done for good.
End(a) ==
    /\ row[a] = "stopped" /\ Up(a)
    /\ row' = [row EXCEPT ![a] = "ended"]
    /\ UNCHANGED <<live, gen, turn, stuck, ep, memVars, mailVars, lease, pr, rp, claimVars, seen,
                   whole, limVars, applied, own, wrong>>

\* What the owner of a lease's row answers the Scheduler: the work ended.
\* Under DialogEndsWork a start on a dialog counts as ended (its deadline
\* passed), though its process lives.
WorkEnded(a) == row[a] = "ended" \/ (Break = "DialogEndsWork" /\ row[a] = "dialog")

Release(a) ==
    /\ lease[a] = "held" /\ WorkEnded(a)
    /\ lease' = [lease EXCEPT ![a] = "released"]
    /\ UNCHANGED <<sessVars, memVars, mailVars, pr, rp, claimVars, seen, whole, limVars, applied,
                   own, wrong>>

-----------------------------------------------------------------------------
(* Claude Code's turns *)

TurnEnds(a) ==
    /\ live[a] > 0 /\ turn[a] \notin {"ended", "limited"} /\ ~stuck[a]
    /\ turn' = [turn EXCEPT ![a] = "ended"]
    /\ UNCHANGED <<row, live, gen, stuck, ep, memVars, mailVars, lease, pr, rp, claimVars, seen,
                   whole, limVars, applied, own, wrong>>

\* A person's prompt starts a turn (Remote Control, or at the viewer).
PersonTurn(a) ==
    /\ row[a] \in {"running", "stopping"} /\ live[a] > 0 /\ turn[a] = "ended"
    /\ turn' = [turn EXCEPT ![a] = "person"]
    /\ UNCHANGED <<row, live, gen, stuck, ep, memVars, mailVars, lease, pr, rp, claimVars, seen,
                   whole, limVars, applied, own, wrong>>

\* A turn sticks: a new state, which the Watch and the parent may act on.
Sticks(a) ==
    /\ live[a] > 0 /\ turn[a] \notin {"ended", "limited"} /\ ~stuck[a] /\ ep[a] < 2 * MaxStuck
    /\ stuck' = [stuck EXCEPT ![a] = TRUE]
    /\ ep' = [ep EXCEPT ![a] = @ + 1]
    /\ UNCHANGED <<row, live, gen, turn, memVars, mailVars, lease, pr, rp, claimVars, seen,
                   whole, limVars, applied, own, wrong>>

\* It goes on by itself: a new state again, a working one.
Unsticks(a) ==
    /\ stuck[a]
    /\ stuck' = [stuck EXCEPT ![a] = FALSE]
    /\ ep' = [ep EXCEPT ![a] = @ + 1]
    /\ UNCHANGED <<row, live, gen, turn, memVars, mailVars, lease, pr, rp, claimVars, seen,
                   whole, limVars, applied, own, wrong>>

\* A turn that runs ends at the account's usage limit, and Usage's record says the account is
\* limited until its reset (Limit.tla: Hit and Read in one step). The turn is `limited`, not
\* ended: Claude Code's menu or its own wait shows, or a headless result is an error.
HitLimit(a) ==
    /\ limits < MaxLimits /\ live[a] > 0 /\ turn[a] \in {"row", "person"} /\ ~stuck[a]
    /\ turn' = [turn EXCEPT ![a] = "limited"]
    /\ acct' = "limited" /\ limits' = limits + 1
    /\ UNCHANGED <<row, live, gen, stuck, ep, memVars, mailVars, lease, pr, rp, claimVars, seen,
                   whole, applied, own, wrong>>

\* Time reaches the reset the record names.
ResetLimit ==
    /\ acct = "limited"
    /\ acct' = "open"
    /\ UNCHANGED <<sessVars, memVars, mailVars, lease, pr, rp, claimVars, seen, whole, limits,
                   applied, own, wrong>>

-----------------------------------------------------------------------------
(* Mailbox, and Sessions' hand *)

\* The oldest row to the addressee that is due, with none in flight to it.
\* The design marks only into a running row's ended turn; under
\* MarkWhileStopping a stopping row takes one too.
Mark(i) ==
    LET a == Addressee IN
    /\ mst[i] = "due" /\ \A j \in Ids : j < i => mst[j] # "due"
    /\ NoneSending(a)
    /\ \/ row[a] = "running"
       \/ Break = "MarkWhileStopping" /\ row[a] = "stopping"
    /\ live[a] > 0 /\ Open(a)
    /\ mst' = [mst EXCEPT ![i] = "sending"]
    /\ mgen' = [mgen EXCEPT ![i] = gen[a]]
    /\ call' = [call EXCEPT ![i] = "asked"]
    /\ UNCHANGED <<sessVars, memVars, ev, tx, lease, pr, rp, claimVars, seen, whole, limVars,
                   applied, own, wrong>>

\* Sessions' hand, in the agent process: it writes the row into an ended turn
\* of the process the mark names, and the answer goes back (Answered); else
\* it refuses, and the mark is undone. Under NoProcessCheck it writes into
\* whatever process runs.
HandOk(i) ==
    LET a == Addressee IN
    /\ live[a] > 0 /\ Open(a)
    /\ gen[a] = mgen[i] \/ Break = "NoProcessCheck"

Hand(i) ==
    LET a == Addressee IN
    /\ call[i] = "asked" /\ Up(a)
    /\ IF HandOk(i)
       THEN /\ call' = [call EXCEPT ![i] = "handing"]
            /\ tx' = [tx EXCEPT ![i] = @ + 1]
            /\ ev' = ev \cup {i}
            /\ turn' = [turn EXCEPT ![a] = "row"]
            /\ wrong' = wrong \cup (IF gen[a] # mgen[i] THEN {"other process"} ELSE {})
                               \cup (IF turn[a] = "limited" /\ acct = "limited"
                                     THEN {"into a limit"} ELSE {})
            /\ UNCHANGED mst
       ELSE /\ call' = [call EXCEPT ![i] = "none"]
            /\ mst' = [mst EXCEPT ![i] = "due"]
            /\ UNCHANGED <<tx, ev, turn, wrong>>
    /\ UNCHANGED <<row, live, gen, stuck, ep, memVars, mgen, lease, pr, rp, claimVars, seen,
                   whole, limVars, applied, own>>

\* The hand's answer, sent, reaches Mailbox; the mark stays for the evidence.
Answered(i) ==
    /\ call[i] = "handing"
    /\ call' = [call EXCEPT ![i] = "none"]
    /\ UNCHANGED <<sessVars, memVars, mst, mgen, ev, tx, lease, pr, rp, claimVars, seen, whole,
                   limVars, applied, own, wrong>>

\* A row in flight with no call under way settles by the evidence alone.
SettleRow(i) ==
    /\ mst[i] = "sending" /\ call[i] = "none"
    /\ mst' = [mst EXCEPT ![i] = IF i \in ev THEN "delivered" ELSE "due"]
    /\ UNCHANGED <<sessVars, memVars, mgen, call, ev, tx, lease, pr, rp, claimVars, seen, whole,
                   limVars, applied, own, wrong>>

\* A row due to a session that ended for good says so.
EndedRow(i) ==
    /\ mst[i] = "due" /\ row[Addressee] = "ended"
    /\ mst' = [mst EXCEPT ![i] = "ended"]
    /\ UNCHANGED <<sessVars, memVars, mgen, call, ev, tx, lease, pr, rp, claimVars, seen, whole,
                   limVars, applied, own, wrong>>

-----------------------------------------------------------------------------
(* Prompts and the dialog's press *)

\* A person answers an open prompt: Prompts marks it answering, and hands the
\* answer to its owner through Team.operate/4 and Sessions.steer/3, which the
\* agent process takes as a press to send. With no agent process it is
\* refused, and the prompt stays open.
Answer(a) ==
    /\ pr[a] = "open" /\ Up(a)
    /\ pr' = [pr EXCEPT ![a] = "answering"]
    /\ task' = [task EXCEPT ![a] = "press"]
    /\ UNCHANGED <<sessVars, stopRead, gaveUp, crashes, keys, mailVars, lease, rp, claimVars, seen,
                   whole, limVars, applied, own, wrong>>

\* The checked press: only while the pane still shows the dialog.
Press(a) ==
    /\ task[a] = "press" /\ Up(a) /\ row[a] = "dialog" /\ live[a] > 0
    /\ keys' = [keys EXCEPT ![a] = @ + 1]
    /\ task' = [task EXCEPT ![a] = "told"]
    /\ UNCHANGED <<sessVars, stopRead, gaveUp, crashes, mailVars, lease, pr, rp, claimVars, seen,
                   whole, limVars, applied, own, wrong>>

\* The checked press refused: the dialog is gone. Told as refused.
PressRefused(a) ==
    /\ task[a] = "press" /\ Up(a) /\ ~(row[a] = "dialog" /\ live[a] > 0)
    /\ task' = [task EXCEPT ![a] = "none"]
    /\ pr' = [pr EXCEPT ![a] = IF @ = "answering" THEN "open" ELSE @]
    /\ UNCHANGED <<sessVars, stopRead, gaveUp, crashes, keys, mailVars, lease, rp, claimVars,
                   seen, whole, limVars, applied, own, wrong>>

\* Keys sent land: the dialog passes and the start goes on, or, past it,
\* they land on the session itself.
Lands(a) ==
    /\ keys[a] > 0
    /\ keys' = [keys EXCEPT ![a] = @ - 1]
    /\ applied' = [applied EXCEPT ![a] = @ + 1]
    /\ row' = [row EXCEPT ![a] = IF @ = "dialog" /\ live[a] > 0 THEN "running" ELSE @]
    /\ UNCHANGED <<live, gen, turn, stuck, ep, task, stopRead, gaveUp, crashes, mailVars, lease,
                   pr, rp, claimVars, seen, whole, limVars, own, wrong>>

\* The owner tells Prompts the press went: answered.
Told(a) ==
    /\ task[a] = "told" /\ Up(a)
    /\ task' = [task EXCEPT ![a] = "none"]
    /\ pr' = [pr EXCEPT ![a] = IF @ = "answering" THEN "answered" ELSE @]
    /\ UNCHANGED <<sessVars, stopRead, gaveUp, crashes, keys, mailVars, lease, rp, claimVars,
                   seen, whole, limVars, applied, own, wrong>>

\* An answer a restart cut, settled by the owner's evidence: the dialog gone,
\* answered; still shown, unknown, since keys may be on their way, for a
\* person. Under ReopenCut it opens again at once.
SettlePrompt(a) ==
    /\ pr[a] = "answering" /\ task[a] = "none"
    /\ pr' = [pr EXCEPT ![a] = IF row[a] # "dialog" THEN "answered"
                               ELSE IF Break = "ReopenCut" THEN "open" ELSE "unknown"]
    /\ UNCHANGED <<sessVars, memVars, mailVars, lease, rp, claimVars, seen, whole, limVars, applied,
                   own, wrong>>

\* A person who sees the pane still show the dialog, nothing on its way,
\* clears the unknown answer: the prompt is open again.
Clear(a) ==
    /\ pr[a] = "unknown" /\ keys[a] = 0
    /\ pr' = [pr EXCEPT ![a] = IF row[a] = "dialog" THEN "open" ELSE "answered"]
    /\ UNCHANGED <<sessVars, memVars, mailVars, lease, rp, claimVars, seen, whole, limVars, applied,
                   own, wrong>>

-----------------------------------------------------------------------------
(* Team and the Watch: a parent's fix and the healer's remedy, one Ledger *)

Interrupt(a, helps) ==
    IF helps
    THEN /\ stuck' = [stuck EXCEPT ![a] = FALSE]
         /\ ep' = [ep EXCEPT ![a] = @ + 1]
         /\ turn' = [turn EXCEPT ![a] = "ended"]
    ELSE UNCHANGED <<stuck, ep, turn>>

\* Team.operate/4 for the parent: the need (a stuck turn) checked on the
\* state the claim takes, then the Ledger's claim.
FixClaim(a) ==
    /\ stuck[a]
    /\ L!Take("parent", a, "interrupt")
    /\ UNCHANGED <<sessVars, memVars, mailVars, lease, pr, rp, seen, whole, limVars, applied, own,
                   wrong>>

\* The Watch reads a symptom from the facts: a stuck turn.
Detect(a) ==
    /\ stuck[a] /\ a \notin seen
    /\ seen' = seen \cup {a}
    /\ UNCHANGED <<sessVars, memVars, mailVars, lease, pr, rp, claimVars, whole, limVars, applied,
                   own, wrong>>

\* The healer's remedy through Team.operate/4: its precondition checked
\* against the state the claim takes. Under StaleSymptom the symptom read
\* before stands for it.
HealClaim(a) ==
    /\ a \in seen
    /\ stuck[a] \/ Break = "StaleSymptom"
    /\ Break # "HealerOwnClaim"
    /\ L!Take("healer", a, "interrupt")
    /\ seen' = seen \ {a}
    /\ UNCHANGED <<sessVars, memVars, mailVars, lease, pr, rp, whole, limVars, applied, own, wrong>>

\* Under HealerOwnClaim the healer keeps its own record of what it did, and
\* acts on the symptom with no claim in the Ledger.
HealOwn(a) ==
    LET k == <<a, ep[a]>> IN
    /\ Break = "HealerOwnClaim" /\ a \in seen /\ stuck[a] /\ Up(a) /\ live[a] > 0
    /\ seen' = seen \ {a}
    /\ acted' = acted \cup {k}
    /\ twice' = (twice \/ k \in acted)
    /\ \E helps \in BOOLEAN : Interrupt(a, helps)
    /\ UNCHANGED <<row, live, gen, memVars, mailVars, lease, pr, rp, claims, acting, cdone, cut,
                   whole, limVars, applied, own, wrong>>

\* A claimed fix or remedy acts through Sessions (the agent process): an
\* interrupt, which may not help. It never acts on a working turn: a
\* healer's act on a turn that is not stuck is the fault NeverWorking names.
FixAct(c) ==
    /\ Up(c.t) /\ live[c.t] > 0
    /\ L!Act(c)
    /\ \E helps \in BOOLEAN : Interrupt(c.t, helps)
    /\ wrong' = IF c.by = "healer" /\ ~stuck[c.t] THEN wrong \cup {"healed working"} ELSE wrong
    /\ UNCHANGED <<row, live, gen, memVars, mailVars, lease, pr, rp, seen, whole, limVars, applied,
                   own>>

\* A claim whose state passed, or whose agent has no process to act on, is let go.
FixLetGo(c) ==
    /\ ~L!Current(c) \/ ~Up(c.t) \/ live[c.t] = 0
    /\ L!LetGo(c)
    /\ UNCHANGED <<sessVars, memVars, mailVars, lease, pr, rp, seen, whole, limVars, applied, own,
                   wrong>>

FixSettle(c) ==
    /\ L!Settle(c)
    /\ UNCHANGED <<sessVars, memVars, mailVars, lease, pr, rp, seen, whole, limVars, applied, own,
                   wrong>>

-----------------------------------------------------------------------------
(* Restarts: one agent process's, and the whole framework's *)

\* The calls to a's agent process under way answer {:unknown, :restarted}:
\* Mailbox keeps the mark, for the evidence. Under UnknownUndoes it makes
\* the row due again.
CutCalls(A) ==
    /\ call' = [i \in Ids |-> IF Addressee \in A THEN "none" ELSE call[i]]
    /\ mst' = [i \in Ids |-> IF Addressee \in A /\ call[i] # "none" /\ Break = "UnknownUndoes"
                             THEN "due" ELSE mst[i]]

\* One agent process crashes and its supervisor restarts it: its memory goes,
\* its row and the process outside stay, and its init re-adopts from the
\* row. Past its budget it gives up, and Sessions opens a `restarts` prompt.
\* Under SharedBudget the count is every agent's; under Relaunch the init
\* starts the program of a running row again; under SilentGiveUp no prompt.
RestartAgent(a) ==
    /\ Up(a) /\ own[a] < MaxCrashes
    /\ own' = [own EXCEPT ![a] = @ + 1]
    /\ LET n == [b \in Agents |-> IF b = a \/ Break = "SharedBudget" THEN crashes[b] + 1
                                  ELSE crashes[b]]
       IN  /\ crashes' = n
           /\ gaveUp' = [b \in Agents |-> gaveUp[b] \/ n[b] >= Budget]
           /\ rp' = [b \in Agents |-> rp[b] \/ (n[b] >= Budget /\ ~gaveUp[b]
                                                /\ Break # "SilentGiveUp")]
    /\ task' = [task EXCEPT ![a] = "none"]
    /\ stopRead' = [stopRead EXCEPT ![a] = FALSE]
    /\ CutCalls({a})
    /\ IF Break = "Relaunch" /\ row[a] = "running" /\ live[a] > 0 /\ gen[a] < MaxGen
       THEN /\ live' = [live EXCEPT ![a] = @ + 1]
            /\ gen' = [gen EXCEPT ![a] = @ + 1]
       ELSE UNCHANGED <<live, gen>>
    /\ UNCHANGED <<row, turn, stuck, ep, keys, mgen, ev, tx, lease, pr, claimVars, seen, whole,
                   limVars, applied, wrong>>

\* A person answers the `restarts` prompt: the agent process starts again
\* under a new budget, and re-adopts.
AnswerRestarts(a) ==
    /\ rp[a]
    /\ rp' = [rp EXCEPT ![a] = FALSE]
    /\ gaveUp' = [gaveUp EXCEPT ![a] = FALSE]
    /\ crashes' = [crashes EXCEPT ![a] = 0]
    /\ UNCHANGED <<sessVars, task, stopRead, keys, mailVars, lease, pr, claimVars, seen, whole,
                   limVars, applied, own, wrong>>

\* The whole framework restarts: every process's memory goes (the agent
\* processes', Mailbox's calls, the healer's symptoms read, the Ledger's
\* calls), every row stays, each agent process starts again under a new
\* budget and re-adopts. Under PromptInMemory the open prompts go too.
RestartAll ==
    /\ whole < MaxWhole
    /\ whole' = whole + 1
    /\ task' = [a \in Agents |-> "none"]
    /\ stopRead' = [a \in Agents |-> FALSE]
    /\ gaveUp' = [a \in Agents |-> FALSE]
    /\ crashes' = [a \in Agents |-> 0]
    /\ rp' = [a \in Agents |-> FALSE]
    /\ CutCalls(Agents)
    /\ seen' = {}
    /\ L!Restart
    /\ pr' = [a \in Agents |-> IF Break = "PromptInMemory" /\ pr[a] = "open" THEN "none"
                               ELSE pr[a]]
    /\ UNCHANGED <<sessVars, keys, mgen, ev, tx, lease, applied, own, wrong, limVars>>

-----------------------------------------------------------------------------

Init ==
    /\ row = [a \in Agents |-> "none"]
    /\ live = [a \in Agents |-> 0]
    /\ gen = [a \in Agents |-> 0]
    /\ turn = [a \in Agents |-> "ended"]
    /\ stuck = [a \in Agents |-> FALSE]
    /\ ep = [a \in Agents |-> 0]
    /\ task = [a \in Agents |-> "none"]
    /\ stopRead = [a \in Agents |-> FALSE]
    /\ gaveUp = [a \in Agents |-> FALSE]
    /\ crashes = [a \in Agents |-> 0]
    /\ keys = [a \in Agents |-> 0]
    /\ mst = [i \in Ids |-> "due"]
    /\ mgen = [i \in Ids |-> 0]
    /\ call = [i \in Ids |-> "none"]
    /\ ev = {}
    /\ lease = [a \in Agents |-> "none"]
    /\ pr = [a \in Agents |-> "none"]
    /\ rp = [a \in Agents |-> FALSE]
    /\ claims = {} /\ acting = {} /\ cdone = {} /\ acted = {} /\ twice = FALSE /\ cut = {}
    /\ seen = {}
    /\ whole = 0
    /\ acct = "open" /\ limits = 0
    /\ tx = [i \in Ids |-> 0]
    /\ applied = [a \in Agents |-> 0]
    /\ own = [a \in Agents |-> 0]
    /\ wrong = {}

\* The addressee lives the whole life. Every other agent only takes a seat,
\* runs, ends and gives it back, and its agent process's budget may be
\* spent by another's crash (SharedBudget): what the seats and the budgets
\* need of it, which keeps the state small.
Next ==
    \/ LET a == Addressee IN
          \/ ShowDialog(a) \/ Confirm(a) \/ Term(a) \/ Settle(a) \/ Release(a)
          \/ Press(a) \/ PressRefused(a) \/ Told(a) \/ SettlePrompt(a)
          \/ Start(a) \/ StopRead(a) \/ Exits(a) \/ Resume(a) \/ End(a)
          \/ TurnEnds(a) \/ PersonTurn(a) \/ Sticks(a) \/ Unsticks(a) \/ Lands(a)
          \/ Answer(a) \/ Clear(a) \/ AnswerRestarts(a)
          \/ FixClaim(a) \/ Detect(a) \/ HealClaim(a) \/ HealOwn(a)
          \/ RestartAgent(a) \/ HitLimit(a)
    \/ \E a \in Agents \ {Addressee} :
          \/ Start(a) \/ Confirm(a) \/ Exits(a) \/ Settle(a) \/ End(a) \/ Release(a)
          \/ AnswerRestarts(a)
    \/ \E i \in Ids : Mark(i) \/ Hand(i) \/ Answered(i) \/ SettleRow(i) \/ EndedRow(i)
    \/ \E c \in acting : FixAct(c) \/ FixLetGo(c)
    \/ \E c \in claims : FixSettle(c)
    \/ RestartAll
    \/ ResetLimit

\* The boxes' steps, the end of a turn that is not stuck, keys landing and a
\* person's answers are weakly fair. The mark is strongly fair: a person's
\* turn may take its chance away again and again.
Fairness ==
    /\ \A a \in Agents :
          /\ WF_vars(ShowDialog(a)) /\ WF_vars(Confirm(a)) /\ WF_vars(Term(a))
          /\ WF_vars(Settle(a)) /\ WF_vars(Release(a)) /\ WF_vars(Press(a))
          /\ WF_vars(PressRefused(a)) /\ WF_vars(Told(a)) /\ WF_vars(SettlePrompt(a))
          /\ WF_vars(TurnEnds(a)) /\ WF_vars(Lands(a))
          /\ WF_vars(Answer(a)) /\ WF_vars(Clear(a)) /\ WF_vars(AnswerRestarts(a))
    /\ \A i \in Ids : /\ SF_vars(Mark(i)) /\ WF_vars(Hand(i)) /\ WF_vars(Answered(i))
                      /\ WF_vars(SettleRow(i)) /\ WF_vars(EndedRow(i))
    /\ WF_vars(\E c \in acting : FixAct(c) \/ FixLetGo(c))
    /\ WF_vars(\E c \in claims : FixSettle(c))
    /\ WF_vars(ResetLimit)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ row \in [Agents -> {"none", "starting", "dialog", "running", "stopping", "stopped",
                           "ended"}]
    /\ live \in [Agents -> 0..2] /\ gen \in [Agents -> 0..MaxGen]
    /\ turn \in [Agents -> {"ended", "row", "person", "limited"}] /\ stuck \in [Agents -> BOOLEAN]
    /\ ep \in [Agents -> Nat]
    /\ task \in [Agents -> {"none", "press", "told"}] /\ stopRead \in [Agents -> BOOLEAN]
    /\ gaveUp \in [Agents -> BOOLEAN] /\ crashes \in [Agents -> Nat] /\ keys \in [Agents -> Nat]
    /\ mst \in [Ids -> {"due", "sending", "delivered", "ended"}]
    /\ mgen \in [Ids -> 0..MaxGen] /\ call \in [Ids -> {"none", "asked", "handing"}]
    /\ ev \subseteq Ids
    /\ lease \in [Agents -> {"none", "held", "released"}]
    /\ pr \in [Agents -> {"none", "open", "answering", "unknown", "answered", "withdrawn"}]
    /\ rp \in [Agents -> BOOLEAN]
    /\ seen \subseteq Agents /\ whole \in 0..MaxWhole
    /\ acct \in {"open", "limited"} /\ limits \in 0..MaxLimits

\* A delivery during a move. No turn a row started is cut by a stop's
\* SIGTERM: Mailbox marks nothing for a stopping row, and the idle read
\* waits for nothing sending.
NotCutByStop == "cut by stop" \notin wrong

\* ... and a row goes only into the process it was marked for, never the
\* resumed one.
OnlyToItsProcess == "other process" \notin wrong

\* A lease across a dialog. A process lives only under its lease, a start
\* waiting on a person included; so the seats taken never pass the capacity.
LeaseWhileLive == \A a \in Agents : live[a] > 0 => lease[a] = "held"
SeatsHold == Cardinality({a \in Agents : live[a] > 0}) <= Cap

\* A prompt across a restart. Its answer lands at most once, whichever
\* restart cuts it.
OneAnswer == \A a \in Agents : applied[a] <= 1

\* ... and a session waiting on a dialog always has its prompt, or an answer
\* whose keys are on their way.
KeptAcrossRestart ==
    \A a \in Agents : row[a] = "dialog" /\ live[a] > 0 =>
        pr[a] \in {"open", "answering", "unknown"} \/ keys[a] > 0

\* A remedy racing a fix. One act per state, whoever acts: the parent or
\* the healer, both under the Ledger's claim.
OneActPerState == L!OneActPerState

\* ... and the healer never acts on a working agent.
NeverWorking == "healed working" \notin wrong

\* The Ledger's own, across the whole restart.
OneClaimPerState == L!OneClaimPerState
NoActOnCutOffClaim == L!NoActOnCutOffClaim

\* One agent's restart and the whole one. A restart re-adopts and never
\* relaunches: no agent has two processes.
OneProcess == \A a \in Agents : live[a] <= 1

\* ... a row goes into a transcript at most once: a hand a crash cut keeps
\* its mark, and the evidence settles it.
AtMostOnce == \A i \in Ids : tx[i] <= 1

\* ... and an agent process's budget is its own: it gives up only after its
\* own crashes.
OwnBudget == \A a \in Agents : gaveUp[a] => own[a] >= Budget

\* A usage limit (F-178, Limit.tla). The Scheduler admits no start and no resume on an account
\* its record says limited, and Mailbox hands no row into a turn ended at the limit before its
\* reset.
NoStartOnLimited == [][\A a \in Agents : gen'[a] > gen[a] => acct = "open"]_vars
NoRowIntoLimit == "into a limit" \notin wrong

\* Liveness. A budget run out is a prompt, and the person's answer starts
\* the agent process again.
Escalated == \A a \in Agents : gaveUp[a] ~> ~gaveUp[a]

\* A session on a dialog goes on past it, or its process ends.
DialogPasses == \A a \in Agents : row[a] = "dialog" ~> row[a] # "dialog"

\* A lease whose work ended is released.
EndedIsReleased == \A a \in Agents : row[a] = "ended" ~> lease[a] = "released"

\* A row in flight settles.
SendingSettles == \A i \in Ids : mst[i] = "sending" ~> mst[i] # "sending"

\* Every claim ends.
ClaimsEnd == L!ClaimsEnd

=============================================================================
