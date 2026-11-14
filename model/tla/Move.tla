-------------------------------- MODULE Move --------------------------------
(***************************************************************************)
(* A parent session moving from one Claude account to another: the drain,  *)
(* the wait for its turn to end, the end of its process, the copy of its   *)
(* transcript, the resume on the other account, and the old process's     *)
(* SessionEnd hook arriving late. The parent runs background commands in   *)
(* its own process and starts delegates, which run in processes of their   *)
(* own and report back to it.                                              *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework (none built yet):          *)
(*   Usage    each account's allowance: below 90 %, at 90 % (drain), at    *)
(*            the limit;                                                   *)
(*   Mover    drains the parent, reads that no background command runs,   *)
(*            ends its process once the turn has ended, copies the         *)
(*            transcript, and resumes it on the other account;             *)
(*   Sessions the session's record: its process and account, and the      *)
(*            SessionEnd hook, which ends the record only when it names    *)
(*            the session's current process;                               *)
(*   Parents  what the parent holds: its background commands and its       *)
(*            delegates, whose reports wait for a live parent process.     *)
(*                                                                         *)
(* Left abstract: the screen (the end is typed through Control's checked   *)
(* write, which types only when the turn has ended and the input box is    *)
(* empty, so the check and the end are one step here); the session's name, *)
(* Remote Control and worktrees; the delegates' own accounts, their        *)
(* subagents and restarts of the framework (Delegate.tla); a process that  *)
(* dies on its own; the allowance's weekly reset. One move per behavior:   *)
(* the session starts on Home and may move to the other account once.      *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Move_<value>.cfg that TLC must fail.                        *)
(*                                                                         *)
(* Defense in depth, with no Break: none in this spec.                     *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Accounts,      \* the two Claude accounts
    Home,          \* the account the parent starts on
    MaxPrompts,    \* prompts the user sends over the whole behavior
    MaxBg,         \* background commands started
    MaxDelegates,  \* delegates started
    Break          \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "NoDrain",          \* draining does not stop new background commands and delegates
    "NoTurnWait",       \* the process is ended without waiting for its turn to end
    "LateEndEndsNew",   \* a SessionEnd ends the record whatever process it names
    "ResumeBeforeEnd",  \* the copy and resume do not wait for the old process to exit
    "CopyBeforeEnd",    \* the transcript is copied before the process is ended
    "ReportDuringMove"  \* a delegate's report is delivered while no parent process runs
}

ASSUME Break \in Breaks
ASSUME Home \in Accounts /\ Cardinality(Accounts) = 2
ASSUME MaxPrompts \in Nat /\ MaxBg \in Nat /\ MaxDelegates \in Nat

\* Allowance levels.
Ok == 0
DrainLevel == 1   \* 90 % of the weekly allowance
Limit == 2

Phases == {"idle", "draining", "clear", "ending", "moved"}

VARIABLES
    level,        \* account -> its allowance level
    procs,        \* the session's Claude Code processes: [pid, account, ending]
    nextPid,      \* the last pid given
    turn,         \* the pid whose turn runs, or 0 when no turn runs
    bg,           \* running background commands: [id, pid], children of that process
    bgCount,      \* background commands started so far; also the last id given
    delegates,    \* delegate id -> "none", "running", "reported", "delivered" or "lost"
    prompts,      \* prompts the user has sent
    transcript,   \* account -> turns in the session's transcript in that account's config
    phase,        \* the Mover's phase
    target,       \* the account the Mover moves to
    copied,       \* the Mover has copied the transcript to the target
    resumedWith,  \* the turns the resumed session started from, or -1
    record,       \* Sessions' record: [pid, account, status]
    ends,         \* SessionEnd hooks sent and not yet handled: the pids they name
    lost          \* work a move cut off: [kind, id]

vars == <<level, procs, nextPid, turn, bg, bgCount, delegates, prompts, transcript,
          phase, target, copied, resumedWith, record, ends, lost>>

-----------------------------------------------------------------------------
(* Reading the state *)

Live == {p \in procs : ~p.ending}

\* Starts are refused from the drain on until the session has moved.
Draining == phase \in {"draining", "clear", "ending"} /\ Break # "NoDrain"

\* The account the session's record says it runs on.
Here == record.account

DelegatesStarted == Cardinality({d \in DOMAIN delegates : delegates[d] # "none"})

-----------------------------------------------------------------------------
Init ==
    /\ level = [a \in Accounts |-> Ok]
    /\ procs = {[pid |-> 1, account |-> Home, ending |-> FALSE]}
    /\ nextPid = 1
    /\ turn = 0
    /\ bg = {}
    /\ bgCount = 0
    /\ delegates = [d \in 1..MaxDelegates |-> "none"]
    /\ prompts = 0
    /\ transcript = [a \in Accounts |-> 0]
    /\ phase = "idle"
    /\ target = Home
    /\ copied = FALSE
    /\ resumedWith = -1
    /\ record = [pid |-> 1, account |-> Home, status |-> "running"]
    /\ ends = {}
    /\ lost = {}

-----------------------------------------------------------------------------
(* Usage *)

\* The account the session runs on uses its allowance: to 90 %, then to the
\* limit. At the limit Claude Code starts no new turn.
UsageRises ==
    /\ level[Here] < Limit
    /\ level' = [level EXCEPT ![Here] = @ + 1]
    /\ UNCHANGED <<procs, nextPid, turn, bg, bgCount, delegates, prompts, transcript,
                   phase, target, copied, resumedWith, record, ends, lost>>

-----------------------------------------------------------------------------
(* The parent's own work *)

\* The user sends a prompt (in the terminal or through Remote Control). A
\* process that was asked to end takes none.
PromptSent(p) ==
    /\ prompts < MaxPrompts
    /\ ~p.ending /\ turn = 0 /\ level[p.account] < Limit
    /\ prompts' = prompts + 1
    /\ turn' = p.pid
    /\ UNCHANGED <<level, procs, nextPid, bg, bgCount, delegates, transcript, phase,
                   target, copied, resumedWith, record, ends, lost>>

\* The turn ends, at the limit too, and adds to the transcript.
TurnEnds(p) ==
    /\ turn = p.pid
    /\ turn' = 0
    /\ transcript' = [transcript EXCEPT ![p.account] = @ + 1]
    /\ UNCHANGED <<level, procs, nextPid, bg, bgCount, delegates, prompts, phase,
                   target, copied, resumedWith, record, ends, lost>>

\* In a turn, the parent starts a background command: a child of its process.
BgStarted(p) ==
    /\ bgCount < MaxBg
    /\ turn = p.pid /\ level[p.account] < Limit
    /\ ~Draining
    /\ bgCount' = bgCount + 1
    /\ bg' = bg \cup {[id |-> bgCount + 1, pid |-> p.pid]}
    /\ UNCHANGED <<level, procs, nextPid, turn, delegates, prompts, transcript, phase,
                   target, copied, resumedWith, record, ends, lost>>

BgEnds(b) ==
    /\ bg' = bg \ {b}
    /\ UNCHANGED <<level, procs, nextPid, turn, bgCount, delegates, prompts, transcript,
                   phase, target, copied, resumedWith, record, ends, lost>>

-----------------------------------------------------------------------------
(* Delegates: processes of their own, which a move of the parent does not end *)

\* In a turn, the parent calls start_delegate and gets its answer.
DelegateStarted(p, d) ==
    /\ delegates[d] = "none"
    /\ turn = p.pid /\ level[p.account] < Limit
    /\ ~Draining
    /\ delegates' = [delegates EXCEPT ![d] = "running"]
    /\ UNCHANGED <<level, procs, nextPid, turn, bg, bgCount, prompts, transcript, phase,
                   target, copied, resumedWith, record, ends, lost>>

DelegateEnds(d) ==
    /\ delegates[d] = "running"
    /\ delegates' = [delegates EXCEPT ![d] = "reported"]
    /\ UNCHANGED <<level, procs, nextPid, turn, bg, bgCount, prompts, transcript, phase,
                   target, copied, resumedWith, record, ends, lost>>

\* The report is typed into the parent as a new turn, only when a parent
\* process runs, is not ending, and its turn has ended. Otherwise it waits.
\* Under ReportDuringMove it is sent while no process runs, and is lost.
ReportDelivered(d) ==
    /\ delegates[d] = "reported"
    /\ turn = 0
    /\ \/ \E p \in Live : /\ turn' = p.pid
                          /\ delegates' = [delegates EXCEPT ![d] = "delivered"]
                          /\ UNCHANGED lost
       \/ /\ Break = "ReportDuringMove" /\ Live = {}
          /\ delegates' = [delegates EXCEPT ![d] = "lost"]
          /\ lost' = lost \cup {[kind |-> "delegate", id |-> d]}
          /\ UNCHANGED turn
    /\ UNCHANGED <<level, procs, nextPid, bg, bgCount, prompts, transcript, phase,
                   target, copied, resumedWith, record, ends>>

-----------------------------------------------------------------------------
(* The move *)

\* Drain: a press, or the session's account at 90 % (Fairness). From here on
\* no new background command or delegate starts.
Drain ==
    /\ phase = "idle"
    /\ \E a \in Accounts \ {Here} : level[a] = Ok /\ target' = a
    /\ phase' = "draining"
    /\ UNCHANGED <<level, procs, nextPid, turn, bg, bgCount, delegates, prompts,
                   transcript, copied, resumedWith, record, ends, lost>>

\* The Mover reads that no background command of the parent runs. Running
\* delegates do not hold the move: they outlive the parent's process. Under
\* CopyBeforeEnd the transcript is copied here.
Cleared ==
    /\ phase = "draining"
    /\ bg = {}
    /\ phase' = "clear"
    /\ IF Break = "CopyBeforeEnd"
         THEN /\ transcript' = [transcript EXCEPT ![target] = transcript[Here]]
              /\ copied' = TRUE
         ELSE UNCHANGED <<transcript, copied>>
    /\ UNCHANGED <<level, procs, nextPid, turn, bg, bgCount, delegates, prompts, target,
                   resumedWith, record, ends, lost>>

\* The Mover ends the process, once its turn has ended and its input box is
\* empty. Under NoTurnWait it ends it mid-turn.
EndAsked(p) ==
    /\ phase = "clear"
    /\ ~p.ending
    /\ turn = 0 \/ Break = "NoTurnWait"
    /\ procs' = (procs \ {p}) \cup {[p EXCEPT !.ending = TRUE]}
    /\ phase' = "ending"
    /\ UNCHANGED <<level, nextPid, turn, bg, bgCount, delegates, prompts, transcript,
                   target, copied, resumedWith, record, ends, lost>>

\* The process exits, with its turn and its background commands. It sends
\* its SessionEnd hook, which may arrive at any later time.
ProcessExits(p) ==
    /\ p.ending
    /\ procs' = procs \ {p}
    /\ lost' = lost \cup {[kind |-> "bg", id |-> b.id] : b \in {c \in bg : c.pid = p.pid}}
                    \cup (IF turn = p.pid THEN {[kind |-> "turn", id |-> p.pid]} ELSE {})
    /\ bg' = {b \in bg : b.pid # p.pid}
    /\ turn' = IF turn = p.pid THEN 0 ELSE turn
    /\ ends' = ends \cup {p.pid}
    /\ UNCHANGED <<level, nextPid, bgCount, delegates, prompts, transcript, phase, target,
                   copied, resumedWith, record>>

\* The old process has exited, so the transcript is final: copy it to the
\* target account. Under ResumeBeforeEnd the Mover does not wait for the exit.
Copied ==
    /\ phase = "ending" /\ ~copied
    /\ procs = {} \/ Break = "ResumeBeforeEnd"
    /\ transcript' = [transcript EXCEPT ![target] = transcript[Here]]
    /\ copied' = TRUE
    /\ UNCHANGED <<level, procs, nextPid, turn, bg, bgCount, delegates, prompts, phase,
                   target, resumedWith, record, ends, lost>>

\* Resume the session on the target with --resume, its name and Remote
\* Control on; the record now names the new process.
Resumed ==
    /\ phase = "ending" /\ copied
    /\ procs = {} \/ Break = "ResumeBeforeEnd"
    /\ nextPid' = nextPid + 1
    /\ procs' = procs \cup {[pid |-> nextPid + 1, account |-> target, ending |-> FALSE]}
    /\ record' = [pid |-> nextPid + 1, account |-> target, status |-> "running"]
    /\ resumedWith' = transcript[target]
    /\ phase' = "moved"
    /\ UNCHANGED <<level, turn, bg, bgCount, delegates, prompts, transcript, target,
                   copied, ends, lost>>

\* Sessions handles a SessionEnd hook: it ends the record only when the hook
\* names the record's process. An old process's hook that arrives after the
\* resume names a pid the record no longer holds, and is ignored.
SessionEndArrives(pid) ==
    /\ ends' = ends \ {pid}
    /\ record' = IF pid = record.pid \/ Break = "LateEndEndsNew"
                   THEN [record EXCEPT !.status = "ended"]
                   ELSE record
    /\ UNCHANGED <<level, procs, nextPid, turn, bg, bgCount, delegates, prompts,
                   transcript, phase, target, copied, resumedWith, lost>>

-----------------------------------------------------------------------------
Next ==
    \/ UsageRises
    \/ \E p \in procs : PromptSent(p) \/ TurnEnds(p) \/ BgStarted(p)
                        \/ EndAsked(p) \/ ProcessExits(p)
    \/ \E b \in bg : BgEnds(b)
    \/ \E p \in procs, d \in DOMAIN delegates : DelegateStarted(p, d)
    \/ \E d \in DOMAIN delegates : DelegateEnds(d) \/ ReportDelivered(d)
    \/ Drain \/ Cleared \/ Copied \/ Resumed
    \/ \E pid \in ends : SessionEndArrives(pid)

\* The Mover's steps are fair, and it drains at 90 %. A turn, a background
\* command and a process asked to end each end in time. Prompts, usage,
\* starts and delegates may or may not happen.
Fairness ==
    /\ WF_vars(level[Here] >= DrainLevel /\ Drain)
    /\ WF_vars(Cleared) /\ WF_vars(Copied) /\ WF_vars(Resumed)
    /\ WF_vars(\E p \in procs : EndAsked(p))
    /\ WF_vars(\E p \in procs : ProcessExits(p))
    /\ WF_vars(\E p \in procs : TurnEnds(p))
    /\ WF_vars(\E b \in bg : BgEnds(b))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ level \in [Accounts -> Ok..Limit]
    /\ \A p \in procs : p.pid \in 1..nextPid /\ p.account \in Accounts
    /\ turn \in 0..nextPid
    /\ \A b \in bg : b.id \in 1..MaxBg
    /\ delegates \in [1..MaxDelegates -> {"none", "running", "reported", "delivered", "lost"}]
    /\ phase \in Phases /\ target \in Accounts /\ copied \in BOOLEAN
    /\ record.status \in {"running", "ended"}

\* A session runs on one account at a time: never two processes of it.
OneAccountAtATime ==
    Cardinality(procs) <= 1

\* Nothing that runs is lost: no turn, background command or delegate's
\* report is cut off by a move.
NothingLost ==
    lost = {}

\* The resumed session has the whole transcript of the old one.
TranscriptKept ==
    phase = "moved" => resumedWith = transcript[Home]

\* A late SessionEnd never ends the moved session: the record is ended only
\* when no process of the session runs but one that was asked to end.
LateEndNeverEndsMoved ==
    record.status = "ended" => Live = {}

\* No new delegate or background command starts once draining began.
NoStartWhileDraining ==
    [][(phase \in {"draining", "clear", "ending"}) =>
         (bgCount' = bgCount /\ DelegatesStarted' = DelegatesStarted)]_vars

\* A drained parent moves.
DrainedParentMoves ==
    phase = "draining" ~> phase = "moved"

=============================================================================
