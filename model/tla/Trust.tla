--------------------------------- MODULE Trust --------------------------------
(***************************************************************************)
(* The trust mark the framework writes into an account's `.claude.json`   *)
(* before a start in a worktree it made (F-255), against a Claude Code     *)
(* that runs on the same account and writes the same file.                 *)
(*                                                                         *)
(* Claude Code 2.1.322, measured: each write replaces the whole file (a    *)
(* new inode) from a read of the file made just before it, its own change  *)
(* applied over what it read. It takes `<file>.lock`, a directory made by  *)
(* mkdir, around that read and write. When it cannot take the lock it      *)
(* tries again, and after a bounded wait (about 1.4 s seen) it reads and   *)
(* writes without the lock. A plain read-modify-write by another writer    *)
(* therefore loses whatever the program wrote between that writer's read   *)
(* and its write, and the program's write loses a mark written between     *)
(* the program's read and its write.                                       *)
(*                                                                         *)
(* The framework's write: mkdir the lock, or refuse at once when it is     *)
(* held; read the file; write it whole with the mark added; remove the     *)
(* lock. It holds the lock for at most H ticks, fewer than the K ticks the *)
(* program waits before its unlocked write (H < K). Then the start goes    *)
(* on, marked or not: a refused write leaves the dialog to the press.      *)
(*                                                                         *)
(* Models `CodingAgentFramework.Accounts.trust/3` and the start that calls *)
(* it (`Sessions`' tree task), and the program's writes of `.claude.json`. *)
(*                                                                         *)
(* Left abstract: the file's text (a set of keys); a program that breaks a *)
(* stale lock (10 s, past K); a framework that dies holding its lock (the  *)
(* program breaks it as stale); more than one program on the account (each *)
(* takes the same lock).                                                   *)
(*                                                                         *)
(* Break: "none" is the design. "Plain" writes the mark with no lock, a    *)
(* plain read-modify-write; Break_Trust_Plain.cfg must fail. And           *)
(* Break_Trust_LongHold.cfg holds the lock as long as the program waits    *)
(* (H >= K), so the program writes without it; it must fail too.          *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS
    H,      \* the most ticks the framework holds the lock
    K,      \* the ticks the program waits on a held lock before it writes without it
    MaxT,   \* the ticks the run lasts
    Break   \* "none" or "Plain"

ASSUME Break \in {"none", "Plain"}
ASSUME H \in Nat /\ K \in Nat /\ K >= 1 /\ MaxT \in Nat

\* The keys the program writes, one per write, in order; the framework's mark.
Prog == <<"p1", "p2">>
Mark == "mark"
Keys == {Prog[i] : i \in 1..Len(Prog)} \cup {Mark}

VARIABLES
    file,     \* the keys the file holds
    lock,     \* who holds `<file>.lock`: "free", "prog", "caf"
    now,      \* ticks so far
    ppc,      \* the program: "want", "read", "write", "unlock", "fbread", "fbwrite", "done"
    pnext,    \* the index in Prog of the program's next write
    pbuf,     \* what the program read
    pwait,    \* ticks the program has waited on the held lock
    cpc,      \* the framework: "idle", "read", "write", "unlock", "done"
    cbuf,     \* what the framework read
    chold,    \* ticks the framework has held the lock
    result,   \* the write's answer: "none", "ok", "refused"
    launched, \* the start went on past the write
    wrote     \* ghost: the keys the program has written

vars == <<file, lock, now, ppc, pnext, pbuf, pwait, cpc, cbuf, chold, result, launched, wrote>>
prog == <<ppc, pnext, pbuf, pwait, wrote>>
caf == <<cpc, cbuf, chold, result, launched>>

-----------------------------------------------------------------------------
(* Time *)

\* The framework's hold is bounded: at H ticks held, no tick until it lets the lock go.
Tick ==
    /\ now < MaxT
    /\ ~(lock = "caf" /\ chold >= H)
    /\ now' = now + 1
    /\ chold' = IF lock = "caf" THEN chold + 1 ELSE chold
    /\ pwait' = IF ppc = "want" /\ lock # "free" THEN pwait + 1 ELSE pwait
    /\ UNCHANGED <<file, lock, ppc, pnext, pbuf, cpc, cbuf, result, launched, wrote>>

-----------------------------------------------------------------------------
(* The program *)

PLock ==
    /\ ppc = "want" /\ lock = "free"
    /\ lock' = "prog" /\ ppc' = "read" /\ pwait' = 0
    /\ UNCHANGED <<file, now, pnext, pbuf, wrote, caf>>

\* Its wait on a held lock ran out: it reads and writes without the lock.
PFallback ==
    /\ ppc = "want" /\ lock # "free" /\ pwait >= K
    /\ ppc' = "fbread" /\ pwait' = 0
    /\ UNCHANGED <<file, lock, now, pnext, pbuf, wrote, caf>>

PRead ==
    /\ ppc \in {"read", "fbread"}
    /\ pbuf' = file
    /\ ppc' = IF ppc = "read" THEN "write" ELSE "fbwrite"
    /\ UNCHANGED <<file, lock, now, pnext, pwait, wrote, caf>>

\* The whole file replaced: what it read, with its own key.
PWrite ==
    /\ ppc \in {"write", "fbwrite"}
    /\ file' = pbuf \cup {Prog[pnext]}
    /\ wrote' = wrote \cup {Prog[pnext]}
    /\ ppc' = IF ppc = "write" THEN "unlock"
              ELSE IF pnext = Len(Prog) THEN "done" ELSE "want"
    /\ pnext' = IF ppc = "fbwrite" /\ pnext < Len(Prog) THEN pnext + 1 ELSE pnext
    /\ UNCHANGED <<lock, now, pbuf, pwait, caf>>

PUnlock ==
    /\ ppc = "unlock"
    /\ lock' = "free"
    /\ ppc' = IF pnext = Len(Prog) THEN "done" ELSE "want"
    /\ pnext' = IF pnext < Len(Prog) THEN pnext + 1 ELSE pnext
    /\ UNCHANGED <<file, now, pbuf, pwait, wrote, caf>>

-----------------------------------------------------------------------------
(* The framework's write, then its start *)

\* mkdir of the lock: taken, or refused at once when held. Plain takes no lock.
CLock ==
    /\ cpc = "idle"
    /\ IF Break = "Plain"
       THEN cpc' = "read" /\ UNCHANGED <<lock, result>>
       ELSE IF lock = "free"
            THEN lock' = "caf" /\ cpc' = "read" /\ UNCHANGED result
            ELSE cpc' = "done" /\ result' = "refused" /\ UNCHANGED lock
    /\ chold' = 0
    /\ UNCHANGED <<file, now, cbuf, launched, prog>>

CRead ==
    /\ cpc = "read"
    /\ cbuf' = file /\ cpc' = "write"
    /\ UNCHANGED <<file, lock, now, chold, result, launched, prog>>

CWrite ==
    /\ cpc = "write"
    /\ file' = cbuf \cup {Mark}
    /\ IF Break = "Plain"
       THEN cpc' = "done" /\ result' = "ok"
       ELSE cpc' = "unlock" /\ UNCHANGED result
    /\ UNCHANGED <<lock, now, cbuf, chold, launched, prog>>

CUnlock ==
    /\ cpc = "unlock"
    /\ lock' = "free" /\ cpc' = "done" /\ result' = "ok"
    /\ UNCHANGED <<file, now, cbuf, chold, launched, prog>>

\* The start goes on once the write answered, marked or not.
Launch ==
    /\ cpc = "done" /\ ~launched
    /\ launched' = TRUE
    /\ UNCHANGED <<file, lock, now, cpc, cbuf, chold, result, prog>>

-----------------------------------------------------------------------------

Init ==
    /\ file = {} /\ lock = "free" /\ now = 0
    /\ ppc = "want" /\ pnext = 1 /\ pbuf = {} /\ pwait = 0
    /\ cpc = "idle" /\ cbuf = {} /\ chold = 0 /\ result = "none" /\ launched = FALSE
    /\ wrote = {}

Next ==
    \/ Tick
    \/ PLock \/ PFallback \/ PRead \/ PWrite \/ PUnlock
    \/ CLock \/ CRead \/ CWrite \/ CUnlock \/ Launch

Fairness ==
    /\ WF_vars(PLock) /\ WF_vars(PFallback) /\ WF_vars(PRead) /\ WF_vars(PWrite)
    /\ WF_vars(PUnlock) /\ WF_vars(CLock) /\ WF_vars(CRead) /\ WF_vars(CWrite)
    /\ WF_vars(CUnlock) /\ WF_vars(Launch) /\ WF_vars(Tick)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ file \subseteq Keys /\ pbuf \subseteq Keys /\ cbuf \subseteq Keys
    /\ lock \in {"free", "prog", "caf"}
    /\ ppc \in {"want", "read", "write", "unlock", "fbread", "fbwrite", "done"}
    /\ pnext \in 1..Len(Prog)
    /\ cpc \in {"idle", "read", "write", "unlock", "done"}
    /\ result \in {"none", "ok", "refused"}
    /\ launched \in BOOLEAN
    /\ wrote \subseteq Keys

\* No key the program wrote is lost.
NoKeyLost == wrote \subseteq file

\* A write answered ok leaves the mark in the file, past any later write of the program.
MarkKept == result = "ok" => Mark \in file

\* The start goes on only once the write answered; marked when it answered ok.
MarkBeforeStart == launched => (cpc = "done" /\ (result = "ok" => Mark \in file))

\* A refused write wrote nothing.
RefusedWroteNothing == result = "refused" => Mark \notin file

\* The write is answered and the start goes on, whatever the program does.
Started == <>launched

=============================================================================
