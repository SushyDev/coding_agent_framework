------------------------------- MODULE Checkout -------------------------------
(***************************************************************************)
(* A project's checkout (F-141): the framework's own clone of the          *)
(* project's repository under its home, made once, on trunk, where its     *)
(* main sessions run and from which every worktree is made. After each     *)
(* landing the framework pulls trunk there, fast-forward only and only     *)
(* while the checkout is clean; anything else is a state a person sees.    *)
(*                                                                         *)
(* The clone is made under a temporary name and renamed into place once    *)
(* it is whole, so a checkout at its path is always a whole one: a         *)
(* restart in the middle of a clone leaves only the temporary directory,   *)
(* which the next start removes. A pull is owed after a landing and after  *)
(* every start of Mains (a landing while it was down told nobody); it is   *)
(* cleared before its fetch, so a landing during the pull owes the next    *)
(* one, and it stays owed while the checkout is not clean, so the next     *)
(* read after a person cleans it pulls. The merge is git's                 *)
(* `merge --ff-only`, which refuses a local commit, and an edit the merge  *)
(* would overwrite, and carries any other: an edit made between the clean  *)
(* check and the merge is never lost.                                      *)
(*                                                                         *)
(* Models Mains' clone, its pull (`Mains.landed/2`, its read loop) and     *)
(* the readiness Sessions and Delegates rely on before they make a         *)
(* worktree or start a main session in the checkout.                       *)
(*                                                                         *)
(* Left abstract: the commits themselves (trunk is a count, linear on the  *)
(* remote, since stacks land into it); which files an edit touches (a      *)
(* merge with an edit is refused or carries it); git's own atomicity of a  *)
(* ref update; a merge a restart cut, which may leave git's lock file for  *)
(* a person (F-141's findings); time. A person edits, commits on trunk     *)
(* and cleans up at any step.                                              *)
(*                                                                         *)
(* Fairness: Mains' steps happen while possible; landings, a person's      *)
(* acts and restarts happen or not.                                        *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Checkout_<value>.cfg that TLC must fail.                    *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxLandings,  \* landings into the remote's trunk
    MaxRestarts,  \* restarts of Mains
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "CloneInPlace",   \* the clone writes the checkout's own path, so a cut clone looks made
    "ResetHard",      \* the pull resets trunk to the remote's, discarding what is not committed
    "ClearAfter",     \* the owed pull is cleared after the merge, not before the fetch
    "NoPullAtStart",  \* a start of Mains owes no pull: a landing while it was down is lost
    "ClearOnDirty"    \* a pull refused for a checkout that is not clean is no longer owed
}

ASSUME Break \in Breaks
ASSUME MaxLandings \in Nat /\ MaxRestarts \in Nat

VARIABLES
    remote,    \* the remote's trunk: how many commits
    final,     \* the checkout's path: "absent", "partial" (only by CloneInPlace) or "made"
    tmp,       \* the clone's temporary path: "none", "partial" or "whole"
    local,     \* the checkout's trunk: how many of the remote's commits it has
    tracking,  \* origin/<trunk> in the checkout, as the last fetch read it
    dirty,     \* an edit not committed in the checkout
    ahead,     \* a commit on trunk in the checkout that the remote does not have
    owed,      \* in memory: a pull is owed
    pull,      \* the pull under way: "idle", "fetched" or "checked"
    up,        \* Mains runs
    restarts,
    lost,      \* ghost: an edit or a local commit the framework discarded
    half,      \* ghost: a checkout used while it was not whole
    back       \* ghost: the checkout's trunk moved backward

vars == <<remote, final, tmp, local, tracking, dirty, ahead, owed, pull, up, restarts, lost,
          half, back>>

\* What Mains takes for a checkout it may use: one at its path (CloneInPlace cannot tell a
\* whole one from a cut one; the design's is whole, since only the rename puts one there).
Ready == IF Break = "CloneInPlace" THEN final # "absent" ELSE final = "made"

-----------------------------------------------------------------------------
(* The remote and a person *)

\* A delegate's stack lands into the remote's trunk. Mains is told while it runs.
Land ==
    /\ remote < MaxLandings
    /\ remote' = remote + 1
    /\ owed' = IF up THEN TRUE ELSE owed
    /\ UNCHANGED <<final, tmp, local, tracking, dirty, ahead, pull, up, restarts, lost, half,
                   back>>

\* A person (or a main session, against the rule) edits a file in the checkout, or cleans it.
Edit ==
    /\ final # "absent" /\ ~dirty
    /\ dirty' = TRUE
    /\ UNCHANGED <<remote, final, tmp, local, tracking, ahead, owed, pull, up, restarts, lost,
                   half, back>>

Clean ==
    /\ dirty
    /\ dirty' = FALSE
    /\ UNCHANGED <<remote, final, tmp, local, tracking, ahead, owed, pull, up, restarts, lost,
                   half, back>>

\* A person commits on trunk in the checkout, or takes the commit back.
Commit ==
    /\ final # "absent" /\ ~ahead
    /\ ahead' = TRUE
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, owed, pull, up, restarts, lost,
                   half, back>>

Uncommit ==
    /\ ahead
    /\ ahead' = FALSE
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, owed, pull, up, restarts, lost,
                   half, back>>

-----------------------------------------------------------------------------
(* Mains: the clone, made once *)

\* No checkout at its path: the clone starts under its temporary name (CloneInPlace: at the
\* path itself).
CloneStart ==
    /\ up /\ ~Ready /\ final \in {"absent"} /\ tmp = "none"
    /\ IF Break = "CloneInPlace"
       THEN final' = "partial" /\ tmp' = tmp
       ELSE tmp' = "partial" /\ final' = final
    /\ UNCHANGED <<remote, local, tracking, dirty, ahead, owed, pull, up, restarts, lost, half,
                   back>>

\* The clone's fetch reads the remote's trunk as it is now.
CloneDone ==
    /\ up
    /\ \/ /\ tmp = "partial"
          /\ tmp' = "whole" /\ final' = final
       \/ /\ Break = "CloneInPlace" /\ final = "partial"
          /\ final' = "made" /\ tmp' = tmp
    /\ local' = remote /\ tracking' = remote
    /\ UNCHANGED <<remote, dirty, ahead, owed, pull, up, restarts, lost, half, back>>

\* A whole clone is renamed into place: from here the checkout is made, once.
Rename ==
    /\ up /\ tmp = "whole" /\ final = "absent"
    /\ final' = "made" /\ tmp' = "none"
    /\ UNCHANGED <<remote, local, tracking, dirty, ahead, owed, pull, up, restarts, lost, half,
                   back>>

\* A worktree made from the checkout, or a main session started in it: only once it is ready.
Use ==
    /\ up /\ Ready
    /\ half' = (half \/ final # "made")
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, ahead, owed, pull, up, restarts,
                   lost, back>>

-----------------------------------------------------------------------------
(* Mains: the pull *)

\* The fetch, with the owed pull cleared first, so a landing from here owes the next one.
Fetch ==
    /\ up /\ Ready /\ owed /\ pull = "idle"
    /\ owed' = (Break = "ClearAfter")
    /\ tracking' = remote
    /\ pull' = "fetched"
    /\ UNCHANGED <<remote, final, tmp, local, dirty, ahead, up, restarts, lost, half, back>>

\* Only while clean: no edit, and trunk not ahead of the remote; else a state a view shows,
\* and the pull stays owed for the read after a person cleans it.
Check ==
    /\ up /\ pull = "fetched"
    /\ IF dirty \/ ahead
       THEN /\ pull' = "idle"
            /\ owed' = (owed \/ Break # "ClearOnDirty")
       ELSE pull' = "checked" /\ owed' = owed
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, ahead, up, restarts, lost, half,
                   back>>

\* git's `merge --ff-only`: a local commit refuses it; an edit made since the check is either
\* in the way (refused) or carried. A refusal leaves the pull owed. ResetHard takes the
\* remote's trunk whatever the checkout holds.
Merge ==
    /\ up /\ pull = "checked"
    /\ pull' = "idle"
    /\ IF Break = "ResetHard"
       THEN /\ local' = tracking /\ dirty' = FALSE /\ ahead' = FALSE
            /\ lost' = (lost \/ dirty \/ ahead)
            /\ owed' = (owed /\ Break # "ClearAfter")
       ELSE /\ UNCHANGED <<dirty, ahead, lost>>
            /\ \/ /\ ~ahead
                  /\ local' = tracking
                  /\ owed' = (owed /\ Break # "ClearAfter")
               \/ /\ ahead \/ dirty
                  /\ local' = local
                  /\ owed' = TRUE
    /\ back' = (back \/ local' < local)
    /\ UNCHANGED <<remote, final, tmp, tracking, up, restarts, half>>

-----------------------------------------------------------------------------
(* Restarts *)

\* Mains ends: the pull under way and the owed pull are lost; what is on disk stays.
Restart ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ owed' = FALSE /\ pull' = "idle"
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, ahead, lost, half, back>>

\* Back up: a clone the restart cut is removed and made again; every checkout is owed a pull.
Recover ==
    /\ ~up
    /\ up' = TRUE
    /\ tmp' = "none"
    /\ owed' = (Break # "NoPullAtStart")
    /\ UNCHANGED <<remote, final, local, tracking, dirty, ahead, pull, restarts, lost, half,
                   back>>

-----------------------------------------------------------------------------

Init ==
    /\ remote = 0 /\ final = "absent" /\ tmp = "none"
    /\ local = 0 /\ tracking = 0 /\ dirty = FALSE /\ ahead = FALSE
    /\ owed = FALSE /\ pull = "idle"
    /\ up = TRUE /\ restarts = 0
    /\ lost = FALSE /\ half = FALSE /\ back = FALSE

Next ==
    \/ Land \/ Edit \/ Clean \/ Commit \/ Uncommit
    \/ CloneStart \/ CloneDone \/ Rename \/ Use
    \/ Fetch \/ Check \/ Merge
    \/ Restart \/ Recover

Fairness ==
    /\ WF_vars(CloneStart) /\ WF_vars(CloneDone) /\ WF_vars(Rename)
    /\ WF_vars(Fetch) /\ WF_vars(Check) /\ WF_vars(Merge) /\ WF_vars(Recover)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ remote \in 0..MaxLandings
    /\ final \in {"absent", "partial", "made"} /\ tmp \in {"none", "partial", "whole"}
    /\ local \in 0..MaxLandings /\ tracking \in 0..MaxLandings
    /\ dirty \in BOOLEAN /\ ahead \in BOOLEAN /\ owed \in BOOLEAN
    /\ pull \in {"idle", "fetched", "checked"}
    /\ up \in BOOLEAN /\ restarts \in 0..MaxRestarts

\* Nothing a person left in the checkout, an edit or a commit, is discarded by a pull.
NoLostEdit == ~lost

\* A worktree or a main session only ever uses a whole checkout.
WholeCheckout == ~half

\* The checkout's trunk only moves forward, and never past the remote's.
Forward == ~back /\ local <= remote /\ tracking <= remote

\* The checkout is made once, and stays: a whole clone reaches its path.
Made == <>[](final = "made")

\* Once the remote stops moving and the checkout stays clean, it holds the remote's trunk.
CaughtUp == <>[](~dirty /\ ~ahead) => <>[](local = remote)

=============================================================================
