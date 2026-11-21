-------------------------------- MODULE Heal --------------------------------
(***************************************************************************)
(* The healer on an allow-list (B8, F-182; docs/design.md, "Metrics and    *)
(* healing"): a symptom read from the facts, a remedy taken only from the  *)
(* allow-list, claimed once per symptom state in the Ledger before it      *)
(* acts, its outcome read after, a cap per kind per bound, and a person's  *)
(* `remedy` prompt for everything else.                                    *)
(*                                                                         *)
(* Models CodingAgentFramework.Watch (the symptom record and the           *)
(* allow-list, F-182), CodingAgentFramework.Recoveries (the healer: its    *)
(* two acts, a lost viewer's reopen and an end owed, are two entries of    *)
(* the list), the healer's rows in CodingAgentFramework.Acts (Claim.tla,   *)
(* instanced as C), and the `remedy` kind of CodingAgentFramework.Prompts. *)
(*                                                                         *)
(* A symptom s is a fact of a target in a state: `on[s]` says it holds,    *)
(* and `st[s]` numbers the target's state, which moves each time the       *)
(* symptom comes or goes, or a remedy fixes it. Each symptom has a kind,   *)
(* Kind(s); the allow-list names, per kind, whether its one remedy may     *)
(* run. The healer:                                                        *)
(*                                                                         *)
(*   Detect  records the symptom's state as a fact (always, first);        *)
(*   Claim   a recorded symptom of an allowed kind, under the cap: the     *)
(*           Ledger's row before the act, counted in the bound;            *)
(*   Act     the remedy, whose answer is ok, refused or unknown;           *)
(*   Verify  an ok is read again after: the symptom gone is recovered;     *)
(*           still there (in any state), the verify failed, and the        *)
(*           kind leaves the allow-list at once (decision 11);             *)
(*   Ask     a `remedy` prompt, once per symptom state, for a state not on *)
(*           the list, past the cap, whose remedy was refused, unknown,    *)
(*           failed its verify, or was cut by a restart.                   *)
(*                                                                         *)
(* Only the operator widens the list (Answer with `widen`, the prompt's    *)
(* "approve"); the healer only narrows it. The cap's count is a fold of    *)
(* the Ledger's rows in the bound, so a restart keeps it; Bound is time    *)
(* passing the bound.                                                      *)
(*                                                                         *)
(* A prompt asked for its bound (the cap reached; Remedies.tla's main      *)
(* absent again within it) offers "act" in place of "approve" (F-189's     *)
(* new-7, F-190): AnswerAct, the remedy once, claimed in the Ledger under  *)
(* the person's own name on the state still read, never counted in the     *)
(* healer's cap. `forBound` is the reason the Watch keeps on the row. One  *)
(* answer is one act (the prompt closes, and the Ledger's one claim per    *)
(* state), and it is never the healer's (ActOnlyForBound, CapToPrompt).    *)
(* In the code the answer and the claim are two steps (Watch.answer/5,     *)
(* then the healer's next check); a cut between them leaves no act, a     *)
(* behavior this spec's one step already covers. A cut between the       *)
(* person's claim and its act is the healer's restart: the claim names    *)
(* its healer (F-192, the row's detail in Acts), so the restart settles   *)
(* it as it settles its own (SettleCut, any claim).                        *)
(*                                                                         *)
(* Left abstract: what a remedy does (Effect, in the instancing spec: a    *)
(* fix that may not help); evidence; which remedy (one per kind).          *)
(*                                                                         *)
(* Boxes.tla instances this module with the stuck turn as its one kind     *)
(* (the first instance): on <- stuck, st <- ep, the Ledger's variables     *)
(* its own, an interrupt the remedy. Its healer is this one's Detect,      *)
(* Claim, Act, Verify and Ask; it checks OnlyApproved, OnlyOnSymptom (as   *)
(* NeverWorking), RecordedFirst and NarrowsAlone through it. Remedies.tla  *)
(* (F-183) instances it with `stuck_background` and `absent_main`, and     *)
(* checks every property here through it.                                  *)
(*                                                                         *)
(* Fairness: the healer's steps happen while possible, a person answers a  *)
(* prompt; symptoms come and go, and restarts and bounds happen, or not.   *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Heal_<value>.cfg that TLC must fail.                        *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Symptoms,     \* the symptoms, each one target's
    Kinds,        \* the symptoms' kinds
    Kind(_),      \* s -> its kind
    Approved,     \* the kinds the config's allow-list names
    Actors,       \* who claims in the Ledger (the healer among them)
    MaxActs,      \* the cap: remedies of one kind per bound
    MaxState,     \* the last state a symptom's target reaches
    MaxRestarts,  \* alone: restarts of the healer
    MaxBounds,    \* alone: bounds that pass
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "InMemory",        \* the remedy's claim is held in memory, with no row before it acts
    "TwoClaims",       \* a second claim is taken on a state that has one
    "RetryUnknown",    \* an unknown outcome is taken as not acted, and claimed again
    "NoCap",           \* no cap: every symptom of an allowed kind is acted on
    "CountInMemory",   \* the cap counts in memory, so a restart starts it again
    "SilentCap",       \* past the cap, nothing is asked
    "WidenOnRestart",  \* a restart reads the allow-list from the config, undoing a narrowing
    "NoNarrow",        \* a remedy whose verify failed stays on the list
    "Unlisted",        \* the healer acts on a kind the list does not allow
    "StaleSymptom",    \* it claims on a fact it recorded before, not the symptom now
    "ActAnyPrompt",    \* "act" is offered on any prompt, one asked off the list among them
    "ActAsHealer",     \* a person's "act" is claimed as the healer's, and counted in its cap
    "CutOwnOnly"       \* a restart settles only the healer's own cut claims, not a person's
}

ASSUME Break \in Breaks
ASSUME Approved \subseteq Kinds /\ \A s \in Symptoms : Kind(s) \in Kinds
ASSUME "healer" \in Actors /\ MaxActs \in Nat

Outcomes == {"ok", "refused", "unknown"}

VARIABLES
    on,        \* s -> the symptom holds (the world's)
    st,        \* s -> its target's state number (the world's)
    facts,     \* the symptom record: the states <<s, n>> recorded (durable)
    claims, acting, cdone, acted, twice, cut,  \* the Ledger (Claim.tla)
    res,       \* the outcomes read, [k |-> <<s, n>>, out] (durable, on the claim's row)
    count,     \* k -> remedies of kind k claimed in the bound: a fold of the rows (durable)
    mem,       \* k -> the same count in memory (CountInMemory reads it)
    allow,     \* k -> its remedy is on the allow-list (durable: the config, then the acts on it)
    dropped,   \* ghost: k -> its remedy failed a verify, with no operator's approval since
    asked,     \* the remedy prompts opened, by state <<s, n>> (durable)
    forBound,  \* the ones asked for their bound: the cap reached (durable: the row's reason)
    closed,    \* the prompts a person answered
    wrong,     \* ghost: the faults a guard failed to stop, by name
    restarts, bounds

healVars == <<facts, res, count, mem, allow, dropped, asked, forBound, closed>>
claimVars == <<claims, acting, cdone, acted, twice, cut>>
vars == <<on, st, healVars, claimVars, wrong, restarts, bounds>>

ClaimBreak == IF Break \in {"InMemory", "TwoClaims"} THEN Break ELSE "none"

C == INSTANCE Claim WITH Targets <- Symptoms, Actors <- Actors, MaxState <- MaxState,
                         Break <- ClaimBreak, now <- st, rows <- claims, acting <- acting,
                         done <- cdone, acted <- acted, twice <- twice, cut <- cut

Key(s) == <<s, st[s]>>

\* The count the healer reads: the Ledger's fold, or under CountInMemory its memory.
Count(k) == IF Break = "CountInMemory" THEN mem[k] ELSE count[k]

\* A claim on state k, open or ended.
Held(k) == \E c \in claims \cup acting \cup cdone : <<c.t, c.s>> = k

\* A claim on k ended with no outcome that may yet be good: refused, unknown, its verify failed,
\* or a restart cut it (settled interrupted, never acted on).
Ended(k) ==
    /\ \E c \in cdone : <<c.t, c.s>> = k
    /\ ~\E r \in res : r.k = k /\ r.out \in {"ok", "recovered"}

\* What makes a recorded symptom a person's: no remedy on the list, the cap reached, or a
\* remedy that ended without helping. Under SilentCap the cap asks nothing.
Needs(k) ==
    LET kd == Kind(k[1]) IN
    \/ ~Held(k) /\ ~allow[kd]
    \/ ~Held(k) /\ Count(kd) >= MaxActs /\ Break # "SilentCap"
    \/ Ended(k)

-----------------------------------------------------------------------------
(* The healer's steps, which an instancing spec takes with its own effects *)

\* Detect and record, always: the symptom's state is a fact before anything acts on it.
Detect(s) ==
    /\ on[s] /\ Key(s) \notin facts
    /\ facts' = facts \cup {Key(s)}
    /\ UNCHANGED <<res, count, mem, allow, dropped, asked, forBound, closed, claimVars, wrong>>

\* A remedy claimed: on a symptom recorded in its state now, of a kind the list allows, under
\* the cap; the Ledger's row first, counted in the bound. Under StaleSymptom any fact recorded
\* of it before stands for the symptom now.
Claim(s) ==
    LET kd == Kind(s) IN
    /\ IF Break = "StaleSymptom" THEN \E n \in 0..st[s] : <<s, n>> \in facts
                                 ELSE on[s] /\ Key(s) \in facts
    /\ allow[kd] \/ Break = "Unlisted"
    /\ Count(kd) < MaxActs \/ Break = "NoCap"
    /\ Key(s) \notin asked
    /\ C!Take("healer", s, "remedy")
    /\ count' = [count EXCEPT ![kd] = @ + 1]
    /\ mem' = [mem EXCEPT ![kd] = @ + 1]
    /\ wrong' = IF allow[kd] THEN wrong ELSE wrong \cup {"not approved"}
    /\ UNCHANGED <<facts, res, allow, dropped, asked, forBound, closed>>

\* The remedy acts under its current claim, and its answer is read: `out`. What it does to the
\* target is the instancing spec's (Effect). Acting on a state with no symptom, or again on a
\* state whose remedy answered unknown, is a fault. The claim is the healer's, or a person's
\* answer "act" (AnswerAct), which the healer takes on that person's claim.
Act(c, out) ==
    LET k == <<c.t, c.s>> IN
    /\ c.by \in {"healer", "person"} /\ out \in Outcomes
    /\ C!Act(c)
    /\ res' = res \cup {[k |-> k, out |-> out]}
    /\ wrong' = wrong \cup (IF on[c.t] THEN {} ELSE {"acted on no symptom"})
                      \cup (IF \E r \in res : r.k = k /\ r.out = "unknown"
                            THEN {"retried unknown"} ELSE {})
    /\ UNCHANGED <<facts, count, mem, allow, dropped, asked, forBound, closed>>

\* Under RetryUnknown an unknown answer is taken as no act: the state's rows go, so it is
\* claimed again.
Forget(r) ==
    /\ Break = "RetryUnknown" /\ r \in res /\ r.out = "unknown"
    /\ \E c \in cdone : <<c.t, c.s>> = r.k
    /\ claims' = {c \in claims : <<c.t, c.s>> # r.k}
    /\ cdone' = {c \in cdone : <<c.t, c.s>> # r.k}
    /\ UNCHANGED <<healVars, acting, acted, twice, cut, wrong>>

\* An ok answer is read again after: the symptom gone is recovered; still there, the verify
\* failed, and the kind's remedy leaves the allow-list at once. The read is of the symptom, not
\* its state: one fixed that came back before the read counts as failed, which only narrows
\* (Recoveries' rule: the first sample after the act decides). Under NoNarrow it stays.
Verify(r) ==
    LET s == r.k[1]
        kd == Kind(s)
        still == on[s]
    IN  /\ r \in res /\ r.out = "ok"
        /\ res' = (res \ {r}) \cup {[k |-> r.k, out |-> IF still THEN "failed" ELSE "recovered"]}
        /\ allow' = IF still /\ Break # "NoNarrow" THEN [allow EXCEPT ![kd] = FALSE] ELSE allow
        /\ dropped' = IF still THEN [dropped EXCEPT ![kd] = TRUE] ELSE dropped
        /\ UNCHANGED <<facts, count, mem, asked, forBound, closed, claimVars, wrong>>

\* A remedy prompt, once per symptom state, for a recorded symptom that needs a person; one
\* asked because the cap is reached is asked for its bound.
Ask(s) ==
    LET k == Key(s) IN
    /\ on[s] /\ k \in facts /\ k \notin asked
    /\ Needs(k)
    /\ asked' = asked \cup {k}
    /\ forBound' = IF ~Held(k) /\ allow[Kind(s)] /\ Count(Kind(s)) >= MaxActs
                   THEN forBound \cup {k} ELSE forBound
    /\ UNCHANGED <<facts, res, count, mem, allow, dropped, closed, claimVars, wrong>>

\* A claim whose state passed is let go; a row a restart cut settles interrupted, the healer's
\* own or a person's that names it (the healer's init, Acts.interrupt/2). Under CutOwnOnly a
\* person's stays open.
LetGo(c) == ~C!Current(c) /\ C!LetGo(c) /\ UNCHANGED <<healVars, wrong>>
SettleCut(c) ==
    /\ c.by = "healer" \/ Break # "CutOwnOnly"
    /\ C!Settle(c) /\ UNCHANGED <<healVars, wrong>>

\* The healer restarts: its calls go, its rows stay (the count and the list's acts among
\* them). Under CountInMemory the count starts again; under WidenOnRestart the list is read
\* from the config, and a kind the healer dropped comes back.
Restart ==
    /\ C!Restart
    /\ mem' = IF Break = "CountInMemory" THEN [k \in Kinds |-> 0] ELSE mem
    /\ allow' = IF Break = "WidenOnRestart" THEN [k \in Kinds |-> k \in Approved] ELSE allow
    /\ wrong' = IF Break = "WidenOnRestart" /\ \E k \in Approved : ~allow[k]
                THEN wrong \cup {"widened"} ELSE wrong
    /\ UNCHANGED <<facts, res, count, dropped, asked, forBound, closed>>

\* A person answers a remedy prompt: leave it, or approve the remedy, which puts the kind back
\* on the allow-list (the operator's widening, the only one).
Answer(k, widen) ==
    LET kd == Kind(k[1]) IN
    /\ k \in asked \ closed
    /\ closed' = closed \cup {k}
    /\ allow' = IF widen THEN [allow EXCEPT ![kd] = TRUE] ELSE allow
    /\ dropped' = IF widen THEN [dropped EXCEPT ![kd] = FALSE] ELSE dropped
    /\ UNCHANGED <<facts, res, count, mem, asked, forBound, claimVars, wrong>>

\* A person answers a prompt asked for its bound with "act": the prompt closes, and the remedy
\* is claimed once under the person's own name, on the state still read, outside the healer's
\* cap. Its act, outcome and verify are Act's and Verify's. Under ActAnyPrompt any prompt offers
\* it; under ActAsHealer the claim is the healer's, counted in its cap.
AnswerAct(k) ==
    LET s == k[1]
        kd == Kind(s)
        by == IF Break = "ActAsHealer" THEN "healer" ELSE "person"
    IN  /\ k \in asked \ closed
        /\ k \in forBound \/ Break = "ActAnyPrompt"
        /\ on[s] /\ Key(s) = k
        /\ closed' = closed \cup {k}
        /\ C!Take(by, s, "remedy")
        /\ count' = IF by = "healer" THEN [count EXCEPT ![kd] = @ + 1] ELSE count
        /\ mem' = IF by = "healer" THEN [mem EXCEPT ![kd] = @ + 1] ELSE mem
        /\ UNCHANGED <<facts, res, allow, dropped, asked, forBound, wrong>>

-----------------------------------------------------------------------------
(* Alone *)

\* The world: a symptom comes or goes, a new state each time.
Comes(s) ==
    /\ ~on[s] /\ st[s] < MaxState
    /\ on' = [on EXCEPT ![s] = TRUE] /\ st' = [st EXCEPT ![s] = @ + 1]
    /\ UNCHANGED <<healVars, claimVars, wrong, restarts, bounds>>

Goes(s) ==
    /\ on[s] /\ st[s] < MaxState
    /\ on' = [on EXCEPT ![s] = FALSE] /\ st' = [st EXCEPT ![s] = @ + 1]
    /\ UNCHANGED <<healVars, claimVars, wrong, restarts, bounds>>

\* What a remedy does: one that answered ok or unknown may have fixed the symptom (a new
\* state), or not; a refused one did nothing.
Effect(c, out) ==
    LET s == c.t IN
    IF out # "refused" /\ on[s] /\ st[s] < MaxState
    THEN \/ on' = [on EXCEPT ![s] = FALSE] /\ st' = [st EXCEPT ![s] = @ + 1]
         \/ UNCHANGED <<on, st>>
    ELSE UNCHANGED <<on, st>>

\* The bound passes: the cap's count starts again.
Bound ==
    /\ bounds < MaxBounds
    /\ bounds' = bounds + 1
    /\ count' = [k \in Kinds |-> 0] /\ mem' = [k \in Kinds |-> 0]
    /\ UNCHANGED <<on, st, facts, res, allow, dropped, asked, forBound, closed, claimVars, wrong,
                   restarts>>

Init ==
    /\ on = [s \in Symptoms |-> FALSE] /\ st = [s \in Symptoms |-> 0]
    /\ facts = {} /\ res = {}
    /\ count = [k \in Kinds |-> 0] /\ mem = [k \in Kinds |-> 0]
    /\ allow = [k \in Kinds |-> k \in Approved] /\ dropped = [k \in Kinds |-> FALSE]
    /\ asked = {} /\ forBound = {} /\ closed = {}
    /\ claims = {} /\ acting = {} /\ cdone = {} /\ acted = {} /\ twice = FALSE /\ cut = {}
    /\ wrong = {} /\ restarts = 0 /\ bounds = 0

Healer ==
    \/ \E s \in Symptoms : (Detect(s) \/ Claim(s) \/ Ask(s)) /\ UNCHANGED <<on, st>>
    \/ \E c \in acting, out \in Outcomes : Act(c, out) /\ Effect(c, out)
    \/ \E c \in acting : LetGo(c) /\ UNCHANGED <<on, st>>
    \/ \E c \in claims : SettleCut(c) /\ UNCHANGED <<on, st>>
    \/ \E r \in res : (Verify(r) \/ Forget(r)) /\ UNCHANGED <<on, st>>

Next ==
    \/ Healer /\ UNCHANGED <<restarts, bounds>>
    \/ \E s \in Symptoms : Comes(s) \/ Goes(s)
    \/ restarts < MaxRestarts /\ Restart /\ restarts' = restarts + 1
       /\ UNCHANGED <<on, st, bounds>>
    \/ Bound
    \/ \E k \in asked, widen \in BOOLEAN : Answer(k, widen) /\ UNCHANGED <<on, st, restarts, bounds>>
    \/ \E k \in asked : AnswerAct(k) /\ UNCHANGED <<on, st, restarts, bounds>>

Fairness ==
    /\ \A s \in Symptoms :
          /\ WF_vars(Detect(s) /\ UNCHANGED <<on, st, restarts, bounds>>)
          /\ WF_vars((Claim(s) \/ Ask(s)) /\ UNCHANGED <<on, st, restarts, bounds>>)
    /\ WF_vars(\E c \in acting, out \in Outcomes :
                  Act(c, out) /\ Effect(c, out) /\ UNCHANGED <<restarts, bounds>>)
    /\ WF_vars(\E c \in acting : LetGo(c) /\ UNCHANGED <<on, st, restarts, bounds>>)
    /\ WF_vars(\E c \in claims : SettleCut(c) /\ UNCHANGED <<on, st, restarts, bounds>>)
    /\ WF_vars(\E r \in res : Verify(r) /\ UNCHANGED <<on, st, restarts, bounds>>)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ on \in [Symptoms -> BOOLEAN] /\ st \in [Symptoms -> 0..MaxState]
    /\ facts \subseteq Symptoms \X (0..MaxState)
    /\ \A r \in res : r.k \in Symptoms \X (0..MaxState)
                     /\ r.out \in Outcomes \cup {"recovered", "failed"}
    /\ count \in [Kinds -> Nat] /\ mem \in [Kinds -> Nat]
    /\ allow \in [Kinds -> BOOLEAN] /\ dropped \in [Kinds -> BOOLEAN]
    /\ asked \subseteq facts /\ forBound \subseteq asked /\ closed \subseteq asked

\* A remedy acts once per symptom state, whoever else claims in the Ledger.
OncePerState == C!OneActPerState /\ C!OneClaimPerState

\* Every state a remedy acted on has its row in the Ledger, written before the act.
RecordedFirst == \A k \in acted : \E c \in claims : <<c.t, c.s>> = k

\* An unknown outcome is never retried: it is a prompt.
UnknownNotRetried == "retried unknown" \notin wrong

\* The cap holds: no kind's remedies in one bound pass it; the next is asked (ActedOrAsked).
CapToPrompt == \A k \in Kinds : count[k] <= MaxActs

\* The list narrows alone and widens only by the operator: no step of the healer puts a
\* kind back, and a remedy whose verify failed is off the list until the operator approves it.
NarrowsAlone == "widened" \notin wrong /\ \A k \in Kinds : dropped[k] => ~allow[k]

\* A remedy runs only for a kind the list allows, when it is claimed ...
OnlyApproved == "not approved" \notin wrong

\* ... and only on a state whose symptom holds (Boxes.tla's NeverWorking).
OnlyOnSymptom == "acted on no symptom" \notin wrong

\* Every symptom state is acted on or asked: it passes (a remedy's fix among the ways), or a
\* person has its prompt.
ActedOrAsked ==
    \A s \in Symptoms, n \in 0..MaxState :
        (on[s] /\ st[s] = n) ~> (st[s] # n \/ <<s, n>> \in asked)

\* A person's act is one per answer of a prompt asked for its bound: never on another prompt,
\* never without the answer (one claim per state, OncePerState, keeps it to one).
ActOnlyForBound == \A c \in claims : c.by = "person" => <<c.t, c.s>> \in forBound \cap closed

\* Every claim ends.
ClaimsEnd == C!ClaimsEnd

\* The one kind of a configuration with one kind.
OneKind(s) == CHOOSE k \in Kinds : TRUE

=============================================================================
