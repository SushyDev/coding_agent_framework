----------------------------- MODULE Background -----------------------------
(***************************************************************************)
(* An interactive session's background commands, as the tree shows them    *)
(* (F-259). A command starts only during a turn. At a turn's end Claude    *)
(* Code posts the `Stop` hook, whose input lists every background command *)
(* still running, and may list some that already ended (it is not trusted  *)
(* to empty itself). Then the session file's status says `shell` while a   *)
(* command runs after the turn and `idle` once none does, each with the    *)
(* time it changed (measured on Claude Code 2.1.322, F-142 and F-259).     *)
(*                                                                         *)
(* The tree reads the two sources as the `Tracker`'s view last read them,  *)
(* each on its own: either read can lag. It shows a count, or `unknown`    *)
(* where neither source can know. A file read whose status changed after   *)
(* the newest `Stop` read says the count now: `idle` none, `shell` at      *)
(* least one. Otherwise the newest `Stop` read says it. With no `Stop`     *)
(* read and no such file read, the count is `unknown`, never none.         *)
(*                                                                         *)
(* The tree never shows none while a command runs that began before the    *)
(* evidence it read: a command that began after both reads is one no       *)
(* source could have told it of yet. A `busy` read is no such evidence: a  *)
(* turn says nothing of the commands before it. The session may have run   *)
(* commands before the framework kept any `Stop` of it, and a file read   *)
(* in a turn cannot tell of them: that is the `unknown`.                   *)
(*                                                                         *)
(* Models CodingAgentFramework.Tracker.Background (its interactive read)   *)
(* and the `background` of CodingAgentFramework.Tracker.Tree's agents.     *)
(*                                                                         *)
(* Left abstract: a headless delegate, whose task events come in one       *)
(* ordered log that a read takes as a prefix, so a fold that lists none    *)
(* ran every end it read after its start. The process groups a Linux host *)
(* reads, which the tree shows beside the count and decides nothing by.    *)
(* Both sources' times are one host's clock, as the session's `Intake` and *)
(* `Registry` share it. A `Stop` whose post the table kept as an earlier  *)
(* one's (F-259's new-2).                                                  *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Background_<value>.cfg that TLC must fail.                  *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    Commands,  \* the background commands the session may start, each once
    MaxTime,   \* the clock stops here, to keep the state space finite
    Break      \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "StaleFile",     \* a file read older than the newest Stop read still says the count
    "UnknownAsNone"  \* no Stop read and no current file read shows none, not unknown
}

ASSUME Break \in Breaks

None == -1

\* When a command that ran before any kept Stop began: before every evidence.
Before == -2

\* What the tree shows where no source can know: a number no count is.
Unknown == -1

VARIABLES
    now,      \* the host's clock; every step moves it
    turn,     \* "running", "ending" (its Stop posted, the file not yet changed), "ended"
    run,      \* the commands running
    done,     \* the commands that ended
    began,    \* c -> when c started, None before
    stop,     \* the newest Stop posted: [at, list], at = None before any
    file,     \* the session file: [status, at]
    vStop,    \* the newest Stop the view read
    vFile     \* the session file as the view read it

vars == <<now, turn, run, done, began, stop, file, vStop, vFile>>

NoStop == [at |-> None, list |-> {}]

-----------------------------------------------------------------------------

\* The session may already be in a turn, with commands of its own running
\* from before any Stop the framework kept.
Init ==
    /\ now = 1
    /\ turn \in {"running", "ended"}
    /\ run \in SUBSET Commands
    /\ done = {}
    /\ began = [c \in Commands |-> IF c \in run THEN Before ELSE None]
    /\ stop = NoStop
    /\ file = [status |-> IF turn = "running" THEN "busy"
                          ELSE IF run = {} THEN "idle" ELSE "shell",
               at |-> 0]
    /\ vStop = NoStop
    /\ vFile = [status |-> "unread", at |-> None]

Tick == now' = now + 1

\* A person's prompt, or a command's end, begins a turn.
StartTurn ==
    /\ turn = "ended"
    /\ turn' = "running"
    /\ file' = [status |-> "busy", at |-> now]
    /\ Tick
    /\ UNCHANGED <<run, done, began, stop, vStop, vFile>>

\* A background `Bash` call of the turn.
Launch(c) ==
    /\ turn = "running"
    /\ began[c] = None
    /\ run' = run \cup {c}
    /\ began' = [began EXCEPT ![c] = now]
    /\ Tick
    /\ UNCHANGED <<turn, done, stop, file, vStop, vFile>>

\* The turn ends: its Stop lists every command running, and maybe some that
\* ended (Claude Code's list is not trusted to empty itself).
EndTurn ==
    /\ turn = "running"
    /\ \E stale \in SUBSET done :
        stop' = [at |-> now, list |-> run \cup stale]
    /\ turn' = "ending"
    /\ Tick
    /\ UNCHANGED <<run, done, began, file, vStop, vFile>>

\* After the Stop, the file says whether a command runs on.
Settle ==
    /\ turn = "ending"
    /\ turn' = "ended"
    /\ file' = [status |-> IF run = {} THEN "idle" ELSE "shell", at |-> now]
    /\ Tick
    /\ UNCHANGED <<run, done, began, stop, vStop, vFile>>

\* A command ends, however. After the turn, the last one's end makes the
\* file `idle`.
Finish(c) ==
    /\ c \in run
    /\ run' = run \ {c}
    /\ done' = done \cup {c}
    /\ file' = IF turn = "ended" /\ run' = {}
                 THEN [status |-> "idle", at |-> now]
                 ELSE file
    /\ Tick
    /\ UNCHANGED <<turn, began, stop, vStop, vFile>>

\* The view reads each source on its own, at any time.
ReadStop ==
    /\ vStop # stop
    /\ vStop' = stop
    /\ Tick
    /\ UNCHANGED <<turn, run, done, began, stop, file, vFile>>

ReadFile ==
    /\ vFile # file
    /\ vFile' = file
    /\ Tick
    /\ UNCHANGED <<turn, run, done, began, stop, file, vStop>>

Next ==
    /\ now < MaxTime
    /\ \/ StartTurn \/ EndTurn \/ Settle \/ ReadStop \/ ReadFile
       \/ \E c \in Commands : Launch(c) \/ Finish(c)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* What the tree shows *)

Max(a, b) == IF a >= b THEN a ELSE b

\* A file read that says the count now: its status changed after the newest
\* Stop read, and it is a turn's end, not a turn.
FileSays ==
    /\ vFile.status \in {"idle", "shell"}
    /\ vFile.at > vStop.at \/ Break = "StaleFile"

Shown ==
    IF FileSays
      THEN IF vFile.status = "idle" THEN 0 ELSE Max(1, Cardinality(vStop.list))
    ELSE IF vStop.at # None
      THEN Cardinality(vStop.list)
    ELSE IF Break = "UnknownAsNone" THEN 0 ELSE Unknown

\* The newest time the view's evidence of background commands speaks for:
\* its Stop read, and its file read when that is a turn's end.
Horizon ==
    Max(vStop.at, IF vFile.status \in {"idle", "shell"} THEN vFile.at ELSE None)

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ now \in 0..MaxTime
    /\ turn \in {"running", "ending", "ended"}
    /\ run \subseteq Commands /\ done \subseteq Commands /\ run \cap done = {}
    /\ began \in [Commands -> {Before, None} \cup 0..MaxTime]
    /\ Shown \in Nat \cup {Unknown}

\* The tree never shows none while a command runs that began before the
\* evidence it read.
NoNoneWhileRunning ==
    Shown = 0 => \A c \in run : began[c] > Horizon

\* Once every command ended and the view read the file after the last Stop,
\* the tree shows none: the file empties a Stop's stale list.
EmptiesAtEnd ==
    (turn = "ended" /\ run = {} /\ vFile = file /\ vStop = stop) => Shown = 0

=============================================================================
