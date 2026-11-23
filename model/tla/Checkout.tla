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
(* A checkout an earlier build made under the project's name (F-156, with  *)
(* Old) is renamed to the project's directory once no session's process   *)
(* may live in it or its worktrees, and before anything clones one there:  *)
(* a rename under a running session moves its files away, and a clone     *)
(* beside the old checkout makes two. After the rename every worktree     *)
(* names the checkout's git directory at the old path until `git worktree *)
(* repair`, which each read does while one is stale, so a restart between *)
(* the rename and the repair still repairs.                                *)
(*                                                                         *)
(* A checkout's directory has one owner on a home (F-229, with Taken): a  *)
(* home an earlier config used may hold the project's path in another     *)
(* project's row of the checkouts table, and the directory there may be a *)
(* clone of another origin with the same name. Mains refuses a path       *)
(* another project's row holds, and reads a directory's origin before it  *)
(* takes it: another origin is a failed checkout a person decides about,  *)
(* never cloned over, pulled or used.                                      *)
(*                                                                         *)
(* Models Mains' clone, its pull (`Mains.landed/2`, its read loop), the   *)
(* old checkout's rename (`Mains.Rename`) and the readiness Sessions and  *)
(* Delegates rely on before they make a worktree or start a main session  *)
(* in the checkout.                                                        *)
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
(*                                                                         *)
(* The Team box's contract for a project's checkout (F-163): no edit       *)
(* lost, a whole checkout only, trunk only forward, made once and caught   *)
(* up (NoLostEdit, WholeCheckout, Forward, Made, CaughtUp); and, from      *)
(* F-156, one checkout of a project, and no session's files moved under   *)
(* it (OneCheckout, NoSessionMoved); from F-229, only its own checkout    *)
(* (OwnCheckout). Boxes.tla                                                *)
(* leaves the checkout inside a start; no interaction it checks needs      *)
(* more. No gap.                                                           *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxLandings,  \* landings into the remote's trunk
    MaxRestarts,  \* restarts of Mains
    Old,          \* an earlier build left a checkout under the project's name (F-156)
    Taken,        \* an earlier config on the home may hold the project's path (F-229)
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "CloneInPlace",   \* the clone writes the checkout's own path, so a cut clone looks made
    "ResetHard",      \* the pull resets trunk to the remote's, discarding what is not committed
    "ClearAfter",     \* the owed pull is cleared after the merge, not before the fetch
    "NoPullAtStart",  \* a start of Mains owes no pull: a landing while it was down is lost
    "ClearOnDirty",   \* a pull refused for a checkout that is not clean is no longer owed
    "RenameWhileRunning", \* the old checkout is renamed while a session may run in it
    "CloneBesideOld", \* a clone is made while the old checkout is still there
    "NoRepair",       \* the worktrees are used after the rename with no repair
    "NoOwner",        \* a path another project's row holds is taken (F-229)
    "NoOriginCheck"   \* a directory at the path is taken without reading its origin (F-229)
}

ASSUME Break \in Breaks
ASSUME MaxLandings \in Nat /\ MaxRestarts \in Nat /\ Old \in BOOLEAN /\ Taken \in BOOLEAN

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
    back,      \* ghost: the checkout's trunk moved backward
    old,       \* the checkout under the project's name: "none" or "made"
    inOld,     \* a session's process may live in the old checkout or its worktrees
    links,     \* the worktrees' links to the checkout's git directory: "ok" or "stale"
    moved,     \* ghost: a rename moved a session's files while it might run
    two,       \* ghost: the project had two checkouts at once
    owner,     \* the checkouts table: "other" when another project's row holds the path
    origin,    \* the origin of what is at the path: "own" or "other" (another project's)
    foreign    \* ghost: the project used or pulled a checkout not its own

oldVars == <<old, inOld, links, moved, two>>

homeVars == <<owner, origin, foreign>>

vars == <<remote, final, tmp, local, tracking, dirty, ahead, owed, pull, up, restarts, lost,
          half, back, old, inOld, links, moved, two, owner, origin, foreign>>

\* F-229: no other project's row holds the checkout's path (NoOwner: whatever holds it).
Owned == owner = "none" \/ Break = "NoOwner"

\* F-229: what is at the path is a clone of the project's origin (NoOriginCheck: unread).
OriginOK == origin = "own" \/ Break = "NoOriginCheck"

\* What Mains takes for a checkout it may use: one at its path (CloneInPlace cannot tell a
\* whole one from a cut one; the design's is whole, since only the rename puts one there),
\* that no other project holds, of the project's own origin.
Ready ==
    /\ IF Break = "CloneInPlace" THEN final # "absent" ELSE final = "made"
    /\ Owned /\ OriginOK

-----------------------------------------------------------------------------
(* The remote and a person *)

\* A delegate's stack lands into the remote's trunk. Mains is told while it runs.
Land ==
    /\ remote < MaxLandings
    /\ remote' = remote + 1
    /\ owed' = IF up THEN TRUE ELSE owed
    /\ UNCHANGED <<final, tmp, local, tracking, dirty, ahead, pull, up, restarts, lost, half,
                   back,
                   oldVars, homeVars>>

\* A person (or a main session, against the rule) edits a file in the checkout, or cleans it.
Edit ==
    /\ final # "absent" /\ ~dirty
    /\ dirty' = TRUE
    /\ UNCHANGED <<remote, final, tmp, local, tracking, ahead, owed, pull, up, restarts, lost,
                   half, back,
                   oldVars, homeVars>>

Clean ==
    /\ dirty
    /\ dirty' = FALSE
    /\ UNCHANGED <<remote, final, tmp, local, tracking, ahead, owed, pull, up, restarts, lost,
                   half, back,
                   oldVars, homeVars>>

\* A person commits on trunk in the checkout, or takes the commit back.
Commit ==
    /\ final # "absent" /\ ~ahead
    /\ ahead' = TRUE
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, owed, pull, up, restarts, lost,
                   half, back,
                   oldVars, homeVars>>

Uncommit ==
    /\ ahead
    /\ ahead' = FALSE
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, owed, pull, up, restarts, lost,
                   half, back,
                   oldVars, homeVars>>

-----------------------------------------------------------------------------
(* Mains: the clone, made once *)

\* No checkout at its path: the clone starts under its temporary name (CloneInPlace: at the
\* path itself).
CloneStart ==
    /\ up /\ ~Ready /\ final \in {"absent"} /\ tmp = "none" /\ Owned
    /\ (old = "none" \/ Break = "CloneBesideOld")
    /\ IF Break = "CloneInPlace"
       THEN final' = "partial" /\ tmp' = tmp
       ELSE tmp' = "partial" /\ final' = final
    /\ UNCHANGED <<remote, local, tracking, dirty, ahead, owed, pull, up, restarts, lost, half,
                   back,
                   oldVars, homeVars>>

\* The clone's fetch reads the remote's trunk as it is now.
CloneDone ==
    /\ up
    /\ \/ /\ tmp = "partial"
          /\ tmp' = "whole" /\ final' = final
       \/ /\ Break = "CloneInPlace" /\ final = "partial"
          /\ final' = "made" /\ tmp' = tmp
    /\ local' = remote /\ tracking' = remote
    /\ UNCHANGED <<remote, dirty, ahead, owed, pull, up, restarts, lost, half, back,
                   oldVars, homeVars>>

\* A whole clone is renamed into place: from here the checkout is made, once.
Rename ==
    /\ up /\ tmp = "whole" /\ final = "absent"
    /\ final' = "made" /\ tmp' = "none"
    /\ two' = (two \/ old = "made")
    /\ UNCHANGED <<remote, local, tracking, dirty, ahead, owed, pull, up, restarts, lost, half,
                   back, old, inOld, links, moved, homeVars>>

\* A worktree made from the checkout, or a main session started in it: only once it is ready,
\* and its worktrees' links name it (NoRepair: whatever they name).
Use ==
    /\ up /\ Ready /\ (links = "ok" \/ Break = "NoRepair")
    /\ half' = (half \/ final # "made" \/ links # "ok")
    /\ foreign' = (foreign \/ owner # "none" \/ origin # "own")
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, ahead, owed, pull, up, restarts,
                   lost, back, owner, origin,
                   oldVars>>

-----------------------------------------------------------------------------
(* Mains: a checkout an earlier build named by its project (F-156) *)

\* A session that ran in the old checkout or its worktrees ends: a person's act, or its exit.
\* No session starts there again: a start needs the checkout at its new path (Ready).
OldEnds ==
    /\ inOld
    /\ inOld' = FALSE
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, ahead, owed, pull, up, restarts,
                   lost, half, back, old, links, moved, two, homeVars>>

\* The accounts' conversations, the home's memory and then the checkout itself go to the new
\* path, once no session's process may live there (RenameWhileRunning: whatever runs). The
\* steps before the checkout's own rename are redone after a restart, so they are one step
\* here; the read after it pulls, and its worktrees' links are stale.
RenameOld ==
    /\ up /\ old = "made" /\ final = "absent" /\ tmp = "none" /\ Owned
    /\ (~inOld \/ Break = "RenameWhileRunning")
    /\ old' = "none" /\ final' = "made" /\ links' = "stale"
    /\ moved' = (moved \/ inOld)
    /\ owed' = TRUE
    /\ UNCHANGED <<remote, tmp, local, tracking, dirty, ahead, pull, up, restarts, lost, half,
                   back, inOld, two, homeVars>>

\* `git worktree repair`, at each read while a worktree's link is stale, so a restart between
\* the rename and the repair repairs too (NoRepair: never).
Repair ==
    /\ up /\ final = "made" /\ links = "stale" /\ Break # "NoRepair" /\ Owned /\ OriginOK
    /\ links' = "ok"
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, ahead, owed, pull, up, restarts,
                   lost, half, back, old, inOld, moved, two, homeVars>>

-----------------------------------------------------------------------------
(* Mains: the pull *)

\* The fetch, with the owed pull cleared first, so a landing from here owes the next one.
Fetch ==
    /\ up /\ Ready /\ owed /\ pull = "idle"
    /\ owed' = (Break = "ClearAfter")
    /\ tracking' = remote
    /\ pull' = "fetched"
    /\ foreign' = (foreign \/ owner # "none" \/ origin # "own")
    /\ UNCHANGED <<remote, final, tmp, local, dirty, ahead, up, restarts, lost, half, back,
                   owner, origin, oldVars>>

\* Only while clean: no edit, and trunk not ahead of the remote; else a state a view shows,
\* and the pull stays owed for the read after a person cleans it.
Check ==
    /\ up /\ pull = "fetched"
    /\ IF dirty \/ ahead
       THEN /\ pull' = "idle"
            /\ owed' = (owed \/ Break # "ClearOnDirty")
       ELSE pull' = "checked" /\ owed' = owed
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, ahead, up, restarts, lost, half,
                   back,
                   oldVars, homeVars>>

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
       ELSE /\ UNCHANGED <<dirty, ahead, lost,
                   oldVars, homeVars>>
            /\ \/ /\ ~ahead
                  /\ local' = tracking
                  /\ owed' = (owed /\ Break # "ClearAfter")
               \/ /\ ahead \/ dirty
                  /\ local' = local
                  /\ owed' = TRUE
    /\ back' = (back \/ local' < local)
    /\ UNCHANGED <<remote, final, tmp, tracking, up, restarts, half,
                   oldVars, homeVars>>

-----------------------------------------------------------------------------
(* Restarts *)

\* Mains ends: the pull under way and the owed pull are lost; what is on disk stays.
Restart ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ owed' = FALSE /\ pull' = "idle"
    /\ UNCHANGED <<remote, final, tmp, local, tracking, dirty, ahead, lost, half, back,
                   oldVars, homeVars>>

\* Back up: a clone the restart cut is removed and made again; every checkout is owed a pull.
Recover ==
    /\ ~up
    /\ up' = TRUE
    /\ tmp' = "none"
    /\ owed' = (Break # "NoPullAtStart")
    /\ UNCHANGED <<remote, final, local, tracking, dirty, ahead, pull, restarts, lost, half,
                   back,
                   oldVars, homeVars>>

-----------------------------------------------------------------------------

Init ==
    /\ remote = 0 /\ final \in (IF Taken THEN {"absent", "made"} ELSE {"absent"}) /\ tmp = "none"
    /\ local = 0 /\ tracking = 0 /\ dirty = FALSE /\ ahead = FALSE
    /\ owed = FALSE /\ pull = "idle"
    /\ up = TRUE /\ restarts = 0
    /\ lost = FALSE /\ half = FALSE /\ back = FALSE
    /\ old = (IF Old THEN "made" ELSE "none")
    /\ inOld \in (IF Old THEN BOOLEAN ELSE {FALSE})
    /\ links = "ok" /\ moved = FALSE /\ two = FALSE
    \* F-229: a home an earlier config used may hold the path in another project's row, and a
    \* directory there may be a clone of another origin (one with the same last path part).
    /\ owner \in (IF Taken THEN {"none", "other"} ELSE {"none"})
    /\ origin \in (IF Taken /\ final = "made" THEN {"own", "other"} ELSE {"own"})
    /\ foreign = FALSE

Next ==
    \/ Land \/ Edit \/ Clean \/ Commit \/ Uncommit
    \/ CloneStart \/ CloneDone \/ Rename \/ Use
    \/ Fetch \/ Check \/ Merge
    \/ OldEnds \/ RenameOld \/ Repair
    \/ Restart \/ Recover

Fairness ==
    /\ WF_vars(CloneStart) /\ WF_vars(CloneDone) /\ WF_vars(Rename)
    /\ WF_vars(Fetch) /\ WF_vars(Check) /\ WF_vars(Merge) /\ WF_vars(Recover)
    /\ WF_vars(RenameOld) /\ WF_vars(Repair)

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
    /\ old \in {"none", "made"} /\ inOld \in BOOLEAN /\ links \in {"ok", "stale"}
    /\ owner \in {"none", "other"} /\ origin \in {"own", "other"} /\ foreign \in BOOLEAN

\* Nothing a person left in the checkout, an edit or a commit, is discarded by a pull.
NoLostEdit == ~lost

\* A worktree or a main session only ever uses a whole checkout.
WholeCheckout == ~half

\* The checkout's trunk only moves forward, and never past the remote's.
Forward == ~back /\ local <= remote /\ tracking <= remote

\* The project's own path: no other project holds it, and nothing of another origin is there
\* (F-229). Neither changes in a behavior (only a person frees a path), so the properties take
\* it as <>[]Mine: with the plain `Mine /\ ...`, TLC 2.18 reported Checkout_Design violated
\* by a two-state trace with no loop (F-229's build note).
Mine == owner = "none" /\ origin = "own"

\* The checkout is made once, and stays: a whole clone, or the old checkout once no session
\* runs in it, reaches its path. A path not its own is refused, and so is never made.
Made == (<>[]Mine /\ <>[](~inOld)) => (<>[](final = "made"))

\* A project never has two checkouts: no clone is made beside the old one (F-156).
OneCheckout == ~two

\* No rename moves the files of a session whose process may live (F-156).
NoSessionMoved == ~moved

\* A project never uses or pulls a checkout another project holds, or one of another origin:
\* a path a row of another project holds is refused, and so is a directory of another origin
\* (F-229). A person decides; the framework never clones over it or changes it.
OwnCheckout == ~foreign

\* Once the remote stops moving and the checkout stays clean, it holds the remote's trunk; an
\* old checkout a session holds is neither renamed nor pulled until it ends (F-156).
CaughtUp == (<>[]Mine /\ <>[](~dirty /\ ~ahead /\ ~inOld)) => <>[](local = remote)

=============================================================================
