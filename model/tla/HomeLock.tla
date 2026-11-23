------------------------------ MODULE HomeLock ------------------------------
(***************************************************************************)
(* A home belongs to one tree at a time (F-215). A tree takes the home's   *)
(* lock before it opens anything in the home, and holds it for its whole   *)
(* life. A start on a home another tree holds is refused and touches       *)
(* nothing. A normal stop gives the lock back. A tree can die at any step: *)
(* its lock is then given back by the operating system, which closes the   *)
(* dead holder's file, with no person's step. The lock's file stays, and   *)
(* blocks nothing.                                                         *)
(*                                                                         *)
(* Models CodingAgentFramework.start_link/1 (its take before Home.mark/1   *)
(* and every other open under the home, and its release when a start that *)
(* took the home fails), CodingAgentFramework.Home.Lock (the process that  *)
(* holds the lock for the tree's life, first in the tree and stopped last) *)
(* and CodingAgentFramework.Store.hold/1 (the take: one immediate          *)
(* transaction on `<home>/home.lock` that SQLite either gets at once or    *)
(* refuses, never waiting).                                                *)
(*                                                                         *)
(* Alone, the spec has trees that start on one home, at any time and as    *)
(* often as they like, die at any step, stop, and are started again.       *)
(*                                                                         *)
(* Left abstract: two trees in one VM and two VMs are the same here, since *)
(* SQLite's lock is one between connections in one process and between    *)
(* processes alike. What a refusal names (the holder's record, written     *)
(* right after the take, can name the one before for that instant). The   *)
(* bounded wait in start_link/1 for an instance of the same name that is   *)
(* still exiting: a start that is refused here starts again later.         *)
(*                                                                         *)
(* Fairness: a dead tree's lock is given back, a dead tree is started      *)
(* again, and a tree that starts takes the home while it stays free and    *)
(* opens it once taken. Deaths and stops happen or not.                    *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_HomeLock_<value>.cfg that TLC must fail.                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Trees,  \* the trees that may start on the home
    NoOne,  \* the lock's holder when no tree holds it
    Break   \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "CheckThenTake",  \* the take looks whether the home is free, then takes it in a second step
    "StaleBlocks",    \* the lock is a file a death leaves behind, and a file there is held
    "OpenFirst"       \* a tree opens the home's database before it takes the lock
}

ASSUME Break \in Breaks
ASSUME NoOne \notin Trees

\* idle: not running (never started, refused, stopped, or not yet restarted)
\* checked: saw the home free and has not taken it yet (CheckThenTake only)
\* held: holds the lock and has opened nothing in the home
\* open: has opened the home's database, and runs
\* dead: died at some step; its process is gone
States == {"idle", "checked", "held", "open", "dead"}
Live == {"checked", "held", "open"}
Holding == {"held", "open"}

VARIABLES
    pc,    \* t -> where tree t is, one of States
    lock,  \* the lock's holder as the operating system sees it, or NoOne
    gone,  \* the lock's holder is a process that died: its lock is not given back yet
    file   \* the lock's file is in the home

vars == <<pc, lock, gone, file>>

-----------------------------------------------------------------------------

Init ==
    /\ pc = [t \in Trees |-> "idle"]
    /\ lock = NoOne
    /\ gone = FALSE
    /\ file = FALSE

\* The take: one atomic step that gets the lock or is refused. A refused take
\* changes nothing, so it is no step here. Under StaleBlocks the lock is the
\* file itself: a file there is a held home, whoever made it.
Take(t) ==
    /\ pc[t] = "idle"
    /\ Break # "CheckThenTake"
    /\ lock = NoOne
    /\ Break = "StaleBlocks" => ~file
    /\ lock' = t
    /\ file' = TRUE
    /\ pc' = [pc EXCEPT ![t] = "held"]
    /\ UNCHANGED gone

\* CheckThenTake: the look and the take are two steps, and another tree can
\* take the home between them.
Check(t) ==
    /\ Break = "CheckThenTake"
    /\ pc[t] = "idle" /\ lock = NoOne
    /\ pc' = [pc EXCEPT ![t] = "checked"]
    /\ UNCHANGED <<lock, gone, file>>

TakeChecked(t) ==
    /\ pc[t] = "checked"
    /\ lock' = t
    /\ gone' = FALSE
    /\ file' = TRUE
    /\ pc' = [pc EXCEPT ![t] = "held"]

\* The tree opens the home's database (Home.mark/1 first). Under OpenFirst a
\* tree that has not started yet opens it, before any take.
Open(t) ==
    /\ \/ pc[t] = "held"
       \/ Break = "OpenFirst" /\ pc[t] = "idle"
    /\ pc' = [pc EXCEPT ![t] = "open"]
    /\ UNCHANGED <<lock, gone, file>>

\* A normal stop: every part ends, then the holder closes the lock's file.
\* A start that took the home and is then refused gives it back the same way.
\* Under StaleBlocks the stop removes the file.
Stop(t) ==
    /\ pc[t] \in Holding
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ lock' = IF lock = t THEN NoOne ELSE lock
    /\ file' = IF Break = "StaleBlocks" THEN FALSE ELSE file
    /\ UNCHANGED gone

\* A death at any step of a live tree. Its lock is not given back in this step.
Die(t) ==
    /\ pc[t] \in Live
    /\ pc' = [pc EXCEPT ![t] = "dead"]
    /\ gone' = (gone \/ lock = t)
    /\ UNCHANGED <<lock, file>>

\* The operating system closes the dead holder's file, and with it the lock.
\* The file stays. Under StaleBlocks nothing gives a dead holder's lock back.
Released ==
    /\ gone
    /\ Break # "StaleBlocks"
    /\ lock' = NoOne
    /\ gone' = FALSE
    /\ UNCHANGED <<pc, file>>

\* A dead tree is started again, by its supervisor or a person: a new start,
\* whether or not its old lock was given back yet.
Restart(t) ==
    /\ pc[t] = "dead"
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<lock, gone, file>>

Next ==
    \/ \E t \in Trees :
        \/ Take(t) \/ Check(t) \/ TakeChecked(t) \/ Open(t)
        \/ Stop(t) \/ Die(t) \/ Restart(t)
    \/ Released

Fairness ==
    /\ WF_vars(Released)
    /\ \A t \in Trees :
        /\ WF_vars(Take(t)) /\ WF_vars(Check(t)) /\ WF_vars(TakeChecked(t))
        /\ WF_vars(Open(t)) /\ WF_vars(Restart(t))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ pc \in [Trees -> States]
    /\ lock \in Trees \cup {NoOne}
    /\ gone \in BOOLEAN
    /\ file \in BOOLEAN

\* At most one live tree holds the home.
OneHolder == Cardinality({t \in Trees : pc[t] \in Holding}) <= 1

\* A tree that holds the home holds its lock, as the operating system sees it.
HolderHasLock == \A t \in Trees : pc[t] \in Holding => lock = t /\ ~gone

\* No tree opens the home's database without holding the home.
OpenOnlyHeld == \A t \in Trees : pc[t] = "open" => lock = t /\ ~gone

\* Once the holder is dead, some starter takes the home, with no person's step.
TakenAgain == gone ~> (\E t \in Trees : pc[t] \in Holding)

=============================================================================
