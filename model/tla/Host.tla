-------------------------------- MODULE Host --------------------------------
(***************************************************************************)
(* A remote host takes work while it answers and has its programs (F-280). *)
(* Each placement of new work on the host first finds the host's programs *)
(* over ssh, bounded by the placement's timeout, and keeps what it found.  *)
(* The find answers at once in every case: the host's programs, so the    *)
(* work is placed; a program missing, so the work is refused naming it;   *)
(* or no answer within the bound, so the work is refused as the host      *)
(* away. A host that is away or lacks a program is found again on the     *)
(* next placement, so it joins once it answers with every program, with   *)
(* no restart of the framework.                                           *)
(*                                                                         *)
(* Models CodingAgentFramework.Hosts (reach/4 with :place, and the state  *)
(* it keeps), CodingAgentFramework.Copies.Held.context/4, and the          *)
(* placements of CodingAgentFramework.Jobs.run/6 and                      *)
(* CodingAgentFramework.Services.start/5 and restart/3.                   *)
(*                                                                         *)
(* Alone, the spec has one host that goes down and comes up at any time,  *)
(* an operator who adds its missing programs once, and works that are     *)
(* placed on it, end, and are placed again.                               *)
(*                                                                         *)
(* Left abstract: the find's own span (one step here; its bound is the    *)
(* placement's timeout, and a find cut there is no answer); the rsync      *)
(* protocol check, which is one more way to lack a program; a host that   *)
(* goes down after its work was placed, whose work then ends as a host    *)
(* restart's rules in Copy.tla say; and a read of work already placed     *)
(* (reach/4 with :reach), which uses the programs kept and refuses no new *)
(* work.                                                                   *)
(*                                                                         *)
(* Fairness: a work asked for is answered (the find always ends, by its   *)
(* bound). The host's ups and downs and the operator's step happen or not. *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Host_<value>.cfg that TLC must fail.                       *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Works,  \* the works that may be placed on the host
    Break   \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "KeptReady",    \* a host kept ready takes new work without a find
    "StickyAway",   \* a host kept away refuses new work without a find
    "KeepLacking",  \* a host kept lacking a program refuses new work without a find
    "Wait"          \* the find waits for a host that is down instead of its bound
}

ASSUME Break \in Breaks

\* What the framework keeps of the host.
Known == {"unknown", "ready", "away", "lacking"}

\* idle: not asked for; asked: placed, its find not answered yet; placed: runs on the host;
\* away and missing: refused, the host away or a program missing.
Steps == {"idle", "asked", "placed", "away", "missing"}

VARIABLES
    up,      \* the host answers ssh
    lacks,   \* a program the work needs is missing on the host
    known,   \* what the framework keeps of the host, one of Known
    pc,      \* w -> where work w is, one of Steps
    upAll,   \* w -> the host was up at every step since w was asked for
    downAll, \* w -> the host was down at every step since w was asked for
    fullAll  \* w -> the host had every program at every step since w was asked for

vars == <<up, lacks, known, pc, upAll, downAll, fullAll>>

-----------------------------------------------------------------------------

Init ==
    /\ up \in BOOLEAN
    /\ lacks \in BOOLEAN
    /\ known = "unknown"
    /\ pc = [w \in Works |-> "idle"]
    /\ upAll = [w \in Works |-> TRUE]
    /\ downAll = [w \in Works |-> TRUE]
    /\ fullAll = [w \in Works |-> TRUE]

\* The host goes to sleep or off the network, and comes back.
Down ==
    /\ up
    /\ up' = FALSE
    /\ upAll' = [w \in Works |-> FALSE]
    /\ UNCHANGED <<lacks, known, pc, downAll, fullAll>>

Up ==
    /\ ~up
    /\ up' = TRUE
    /\ downAll' = [w \in Works |-> FALSE]
    /\ UNCHANGED <<lacks, known, pc, upAll, fullAll>>

\* The operator adds the missing programs through the host's own package manager.
Install ==
    /\ lacks
    /\ lacks' = FALSE
    /\ UNCHANGED <<up, known, pc, upAll, downAll, fullAll>>

Ask(w) ==
    /\ pc[w] = "idle"
    /\ pc' = [pc EXCEPT ![w] = "asked"]
    /\ upAll' = [upAll EXCEPT ![w] = up]
    /\ downAll' = [downAll EXCEPT ![w] = ~up]
    /\ fullAll' = [fullAll EXCEPT ![w] = ~lacks]
    /\ UNCHANGED <<up, lacks, known>>

\* The find: what the host answers now, kept, and the placement's answer.
Found(w) ==
    IF up /\ ~lacks THEN
        /\ known' = "ready"
        /\ pc' = [pc EXCEPT ![w] = "placed"]
    ELSE IF up THEN
        /\ known' = "lacking"
        /\ pc' = [pc EXCEPT ![w] = "missing"]
    ELSE
        /\ Break # "Wait"
        /\ known' = "away"
        /\ pc' = [pc EXCEPT ![w] = "away"]

\* What a broken placement answers from what is kept, with no find.
FromKept(w) ==
    \/ /\ Break = "KeptReady" /\ known = "ready"
       /\ pc' = [pc EXCEPT ![w] = "placed"]
    \/ /\ Break = "StickyAway" /\ known = "away"
       /\ pc' = [pc EXCEPT ![w] = "away"]
    \/ /\ Break = "KeepLacking" /\ known = "lacking"
       /\ pc' = [pc EXCEPT ![w] = "missing"]

Kept(w) ==
    \/ Break = "KeptReady" /\ known = "ready"
    \/ Break = "StickyAway" /\ known = "away"
    \/ Break = "KeepLacking" /\ known = "lacking"

Place(w) ==
    /\ pc[w] = "asked"
    /\ IF Kept(w)
         THEN FromKept(w) /\ UNCHANGED known
         ELSE Found(w)
    /\ UNCHANGED <<up, lacks, upAll, downAll, fullAll>>

\* The work ends, or its refusal is read; it may be asked for again.
End(w) ==
    /\ pc[w] \in {"placed", "away", "missing"}
    /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<up, lacks, known, upAll, downAll, fullAll>>

Next ==
    \/ Down \/ Up \/ Install
    \/ \E w \in Works : Ask(w) \/ Place(w) \/ End(w)

Spec == Init /\ [][Next]_vars /\ \A w \in Works : WF_vars(Place(w))

-----------------------------------------------------------------------------

TypeOK ==
    /\ up \in BOOLEAN /\ lacks \in BOOLEAN
    /\ known \in Known
    /\ pc \in [Works -> Steps]
    /\ upAll \in [Works -> BOOLEAN]
    /\ downAll \in [Works -> BOOLEAN]
    /\ fullAll \in [Works -> BOOLEAN]

\* No work is placed on a host that was down for the placement's whole span.
NotPlacedAway == \A w \in Works : pc[w] = "placed" => ~downAll[w]

\* A host that was up for the placement's whole span is never answered away.
AwayOnlyDown == \A w \in Works : pc[w] = "away" => ~upAll[w]

\* A host that had every program for the placement's whole span is never answered lacking.
MissingOnlyLacking == \A w \in Works : pc[w] = "missing" => ~fullAll[w]

\* Every placement is answered: placed, or refused at once.
Answered == \A w \in Works : pc[w] = "asked" ~> pc[w] # "asked"

=============================================================================
