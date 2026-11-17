------------------------------- MODULE Claim -------------------------------
(***************************************************************************)
(* A claim before an act: an actor's hold on one target in one state,     *)
(* taken so that one act runs on that state. Its row is written before    *)
(* the act, and no second claim is taken on a state that has one. The     *)
(* call that acts holds the claim in memory, and acts only while the       *)
(* claim's state is still the target's; else it lets the claim go. A       *)
(* restart cuts the call: the row stays, the act never runs, and the row   *)
(* ends interrupted, for a person (Settle).                                *)
(*                                                                         *)
(* Models the rule of Acts (R10): Grants' claims and Recoveries' rows, one *)
(* row per state under one unique index. Agent.tla (Recoveries' reopen of  *)
(* a lost viewer), Team.tla (a parent's fix of a child), Copy.tla          *)
(* (Recoveries' reopen of a forward) and Start.tla (Recoveries' end of a   *)
(* process, which may fail and wait for a person's clear) instance it.     *)
(* Each gives its own                                                      *)
(* numbering of a target's states (`now`, never changed here), the act's   *)
(* name, and what the act does and needs beside a current claim. A spec   *)
(* that does not number its states says when they pass (Passes).          *)
(*                                                                         *)
(* Alone, the spec has targets whose state moves on at any step, two       *)
(* actors, and restarts at any step. An act may leave the state as it is   *)
(* (a fix that did not help).                                              *)
(*                                                                         *)
(* Left abstract: who may claim what (Grants, in the instancing spec);    *)
(* what an act does; the outcome a later check reads.                     *)
(*                                                                         *)
(* Fairness, alone: a claim in memory acts or is let go, and a row a      *)
(* restart cut off settles. Actors claim or not, and states move or not.  *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Claim_<value>.cfg that TLC must fail.                       *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Targets,   \* what a claim is on
    Actors,    \* who claims
    MaxState,  \* alone: the last state a target reaches
    Break      \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "TwoClaims",  \* a claim does not check for one on the same state
    "InMemory",   \* a claim is held in memory only, with no row
    "Stale"       \* the act runs without checking that its claim's state is current
}

ASSUME Break \in Breaks

VARIABLES
    now,     \* t -> t's state now: the instancing spec's, which no step here changes
    rows,    \* the table: the claims, [by, t, s (the state), act, n]
    acting,  \* in memory: the claims this run took and has neither acted on nor let go
    done,    \* the table: the claims whose act ran, that were let go, or that settled
    acted,   \* ghost: the states <<t, s>> an act ran on
    twice,   \* ghost: an act ran on a state an act ran on before
    cut      \* ghost: the states whose claim a restart cut off before any act on them

claimVars == <<rows, acting, done, acted, twice, cut>>

\* The claims on t's state s, in the table or in memory.
On(t, s) == {c \in rows \cup acting : c.t = t /\ c.s = s}

-----------------------------------------------------------------------------
(* The steps an instancing spec takes, each with its own guards and effects *)

\* `by` claims t in its state now, for `act`: the row first, then the call
\* that acts holds it. A state with a claim takes no second one. Under
\* InMemory only the call holds it; under TwoClaims a second is taken.
Take(by, t, act) ==
    LET c == [by |-> by, t |-> t, s |-> now[t], act |-> act, n |-> Cardinality(On(t, now[t])) + 1]
    IN  /\ On(t, now[t]) = {} \/ (Break = "TwoClaims" /\ c.n <= 2)
        /\ rows' = IF Break = "InMemory" THEN rows ELSE rows \cup {c}
        /\ acting' = acting \cup {c}
        /\ UNCHANGED <<done, acted, twice, cut>>

\* For a spec that leaves out a restart between the claim and its act: the
\* claim and the act in one step, as the code's one call takes them. The
\* row is written and done at once, and the act runs on the state claimed.
TakeAndAct(by, t, act) ==
    LET c == [by |-> by, t |-> t, s |-> now[t], act |-> act, n |-> Cardinality(On(t, now[t])) + 1]
        k == <<t, now[t]>>
    IN  /\ On(t, now[t]) = {} \/ (Break = "TwoClaims" /\ c.n <= 2)
        /\ rows' = IF Break = "InMemory" THEN rows ELSE rows \cup {c}
        /\ done' = IF Break = "InMemory" THEN done ELSE done \cup {c}
        /\ acted' = acted \cup {k}
        /\ twice' = (twice \/ k \in acted)
        /\ UNCHANGED <<acting, cut>>

\* The claim's state is still the target's. Under Stale any claim is.
Current(c) == c.s = now[c.t] \/ Break = "Stale"

\* The act, under a current claim. It acts on the target as it is now.
Act(c) ==
    LET k == <<c.t, now[c.t]>> IN
    /\ c \in acting /\ Current(c)
    /\ acting' = acting \ {c}
    /\ done' = done \cup {c}
    /\ acted' = acted \cup {k}
    /\ twice' = (twice \/ k \in acted)
    /\ UNCHANGED <<rows, cut>>

\* The call lets its claim go with no act: its state passed, or the act's
\* own check refused it.
LetGo(c) ==
    /\ c \in acting
    /\ acting' = acting \ {c}
    /\ done' = done \cup {c}
    /\ UNCHANGED <<rows, acted, twice, cut>>

\* A restart: the calls and their claims in memory go; the table stays.
Restart ==
    /\ acting' = {}
    /\ cut' = cut \cup ({<<c.t, c.s>> : c \in acting} \ acted)
    /\ UNCHANGED <<rows, done, acted, twice>>

\* A row whose call a restart cut off ends interrupted, never acted on.
Settle(c) ==
    /\ c \in rows \ done /\ c \notin acting
    /\ done' = done \cup {c}
    /\ UNCHANGED <<rows, acting, acted, twice, cut>>

\* For a spec that does not number its states: the states of the targets in
\* T pass, and nothing of them is read again. Their rows go, and a claim of
\* one still in memory is let go.
Passes(T) ==
    /\ rows' = {c \in rows : c.t \notin T}
    /\ acting' = {c \in acting : c.t \notin T}
    /\ done' = {c \in done : c.t \notin T}
    /\ acted' = {k \in acted : k[1] \notin T}
    /\ cut' = {k \in cut : k[1] \notin T}
    /\ UNCHANGED twice

-----------------------------------------------------------------------------
(* Alone *)

Init ==
    /\ now = [t \in Targets |-> 0]
    /\ rows = {} /\ acting = {} /\ done = {} /\ acted = {} /\ twice = FALSE /\ cut = {}

Moves(t) ==
    /\ now[t] < MaxState
    /\ now' = [now EXCEPT ![t] = @ + 1]
    /\ UNCHANGED claimVars

Next ==
    \/ \E by \in Actors, t \in Targets : Take(by, t, "act") /\ UNCHANGED now
    \/ \E c \in acting : (Act(c) \/ (~Current(c) /\ LetGo(c))) /\ UNCHANGED now
    \/ \E c \in rows : Settle(c) /\ UNCHANGED now
    \/ Restart /\ UNCHANGED now
    \/ \E t \in Targets : Moves(t)

vars == <<now, claimVars>>

Fairness ==
    /\ WF_vars(\E c \in acting : (Act(c) \/ (~Current(c) /\ LetGo(c))) /\ UNCHANGED now)
    /\ WF_vars(\E c \in rows : Settle(c) /\ UNCHANGED now)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ now \in [Targets -> 0..MaxState]
    /\ rows \subseteq [by : Actors, t : Targets, s : 0..MaxState, act : {"act"}, n : 1..2]
    /\ acting \subseteq rows /\ done \subseteq rows /\ acting \cap done = {}
    /\ acted \subseteq Targets \X (0..MaxState) /\ cut \subseteq Targets \X (0..MaxState)
    /\ twice \in BOOLEAN

\* At most one claim holds a state.
OneClaimPerState == \A c, d \in rows \cup acting \cup done : c.t = d.t /\ c.s = d.s => c = d

\* At most one act runs on a state.
OneActPerState == ~twice

\* A claim a restart cut off is never acted on: no act runs on its state.
NoActOnCutOffClaim == cut \cap acted = {}

\* Every claim ends: its act ran, it was let go, or its row settled.
ClaimsEnd == <>[](rows \cup acting \subseteq done)

=============================================================================
