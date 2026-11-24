------------------------------- MODULE Reload -------------------------------
(***************************************************************************)
(* The operator's reload of an interactive session's plugins (F-233) into  *)
(* a session whose waiter holds its turn (F-241). Every turn's end starts  *)
(* the session's waiter, an `asyncRewake` Stop hook that runs on after the *)
(* turn ended: Intake holds it, and a text handed to it wakes the session  *)
(* with a turn of its own, whatever is in the box. So a reload typed while *)
(* a waiter holds can have a woken turn start between its keys and its     *)
(* Enter, and its Enter go into that running turn. A reload must reach     *)
(* exactly these sessions: every idle session the framework delivers to   *)
(* by the waiter has one held.                                             *)
(*                                                                         *)
(* The design: in one step of Mailbox, the reload is refused while a turn  *)
(* runs, and refused `message_due` while a row to the session is open      *)
(* (queued or sending), so the row goes first by the waiter, which carries *)
(* a text of any length. Else the waiter's hold ends with a pass (Hold's   *)
(* Passed, by its decider: the program exits 0 and wakes nothing), and no  *)
(* waiter holds until a turn of the session ends. The reload then waits,   *)
(* bounded, for the turn idle with no waiter and an empty box, and is      *)
(* typed in one step of the Inlet, keys then Enter, as a typed row is. A   *)
(* row that comes meanwhile has no waiter to go to, so it is typed too, in *)
(* a step of the Inlet of its own: before the reload or after it, never    *)
(* into it. At the bound with nothing typed the reload is unknown.         *)
(*                                                                         *)
(* Models Mailbox.reload_plugins/3 (its checks and the pass in Mailbox's   *)
(* step, the wait and the write in its task), Intake.pass_waiter/4, and    *)
(* Inlet's one write at a time (Inlet.type/4, Inlet.reload_plugins/3). Of  *)
(* Delivery.tla it keeps only what the reload meets: rows in order, one in *)
(* flight, by the waiter while one holds, else typed into an idle turn.    *)
(*                                                                         *)
(* Left abstract: time (the reload's bound is a step it may take while it  *)
(* waits); the screen, but for what the keys put in the box; the result    *)
(* line (F-233); restarts (Delivery.tla); rows too long to type (F-240).   *)
(* Assumed, to check on the real program: `/reload-plugins` runs no turn,  *)
(* so its Enter starts no Stop hook and no waiter.                         *)
(*                                                                         *)
(* Fairness: Mailbox's, Intake's, the Inlet's and Claude Code's own steps  *)
(* happen while they stay possible. Rows, a person's prompts, the          *)
(* operator's reloads and a waiter's own deadline happen or not.           *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Reload_<value>.cfg that TLC must fail.                      *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Msgs,        \* the rows to the session, by id, in the order they are due
    MaxPrompts,  \* a person's prompts
    MaxReloads,  \* the operator's reloads
    Break        \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "TypeWhileHeld",  \* the reload is typed while the waiter holds: no pass
    "PassWithDue",    \* the waiter is passed with a row to the session open
    "NoBound",        \* the reload waits for the hold's end with no bound
    "NoInletStep"     \* a typed row's keys go while the reload's are in the box
}

ASSUME Break \in Breaks
ASSUME MaxPrompts \in Nat /\ MaxReloads \in Nat

Rows == {"none", "queued", "sending", "delivered"}
Reloads == {"none", "waiting", "typing", "ok", "refused", "unknown"}
Answered == {"ok", "refused", "unknown"}

VARIABLES
    turn,     \* Claude Code: the session's turn, "idle" or "running"
    waiter,   \* Intake: the session's waiter, "none", "held" or "deciding" (text in flight)
    row,      \* Mailbox's table: m -> its status
    via,      \* Mailbox's table: m -> "waiter", "typed" or "" while unsent
    box,      \* the screen: whose keys are in the box, "row", "reload" or "" for none
    inlet,    \* the Inlet: the writes ("row", "reload") whose keys went and whose Enter has not
    reload,   \* the operator's reload in hand: its state
    reloads,  \* how many reloads were asked
    prompts,  \* how many prompts a person typed
    passedDue,\* ghost: the rows open when a pass ended the waiter's hold
    wrong     \* ghost: what went wrong

vars == <<turn, waiter, row, via, box, inlet, reload, reloads, prompts, passedDue, wrong>>

Open == {m \in Msgs : row[m] \in {"queued", "sending"}}

\* Mailbox's order: the first row due goes, and only while none is in flight.
First(m) ==
    /\ row[m] = "queued"
    /\ \A k \in Msgs : k < m => row[k] # "queued"
    /\ \A k \in Msgs : row[k] # "sending"

\* Keys typed into the box: noted when another write's keys are still in it.
Keys(w) ==
    /\ box' = w
    /\ inlet' = inlet \cup {w}
    /\ wrong' = IF box # "" THEN wrong \cup {"keys into another write"} ELSE wrong

\* An Enter: the box's text goes in, and starts a turn unless it is the
\* reload (a local command). Noted when the turn already runs.
Enter(w, starts) ==
    /\ w \in inlet
    /\ inlet' = inlet \ {w}
    /\ box' = ""
    /\ turn' = IF starts THEN "running" ELSE turn
    /\ wrong' = IF turn = "running" THEN wrong \cup {"enter into a running turn"} ELSE wrong

-----------------------------------------------------------------------------
(* Rows and their two transports *)

Due(m) ==
    /\ row[m] = "none"
    /\ row' = [row EXCEPT ![m] = "queued"]
    /\ UNCHANGED <<turn, waiter, via, box, inlet, reload, reloads, prompts, passedDue, wrong>>

\* Mailbox hands the first row to the waiter that holds (Intake.deliver).
Hand(m) ==
    /\ First(m) /\ waiter = "held"
    /\ waiter' = "deciding"
    /\ row' = [row EXCEPT ![m] = "sending"]
    /\ via' = [via EXCEPT ![m] = "waiter"]
    /\ UNCHANGED <<turn, box, inlet, reload, reloads, prompts, passedDue, wrong>>

\* The waiter's program exits 2 with the text: Claude Code wakes the session
\* with it, a turn of its own, or queues it into the one running. The box's
\* keys stay where they are.
Wakes(m) ==
    /\ waiter = "deciding" /\ row[m] = "sending" /\ via[m] = "waiter"
    /\ waiter' = "none"
    /\ turn' = "running"
    /\ row' = [row EXCEPT ![m] = "delivered"]
    /\ UNCHANGED <<via, box, inlet, reload, reloads, prompts, passedDue, wrong>>

\* With no waiter, Mailbox types the first row (Inlet.type/4): in the
\* Inlet's one step, into an idle turn with an empty box, no other write in
\* it. Under NoInletStep it goes while another write's keys are in the box.
TypedKeys(m) ==
    /\ First(m) /\ waiter = "none" /\ turn = "idle"
    /\ (inlet = {} /\ box = "") \/ (Break = "NoInletStep" /\ inlet # {})
    /\ Keys("row")
    /\ row' = [row EXCEPT ![m] = "sending"]
    /\ via' = [via EXCEPT ![m] = "typed"]
    /\ UNCHANGED <<turn, waiter, reload, reloads, prompts, passedDue>>

\* Its Enter, in the same step of the Inlet; the transcript's user line
\* settles the row (abstract: at once).
TypedEnter(m) ==
    /\ row[m] = "sending" /\ via[m] = "typed"
    /\ Enter("row", TRUE)
    /\ row' = [row EXCEPT ![m] = "delivered"]
    /\ UNCHANGED <<waiter, via, reload, reloads, prompts, passedDue>>

-----------------------------------------------------------------------------
(* Claude Code and a person *)

\* A turn ends: its Stop hook starts the session's next waiter.
TurnEnds ==
    /\ turn = "running" /\ inlet = {}
    /\ turn' = "idle"
    /\ waiter' = IF waiter = "none" THEN "held" ELSE waiter
    /\ UNCHANGED <<row, via, box, inlet, reload, reloads, prompts, passedDue, wrong>>

\* A person's prompt starts a turn.
Prompt ==
    /\ prompts < MaxPrompts /\ turn = "idle" /\ box = ""
    /\ turn' = "running"
    /\ prompts' = prompts + 1
    /\ UNCHANGED <<waiter, row, via, box, inlet, reload, reloads, passedDue, wrong>>

\* The waiter's own deadline: its response ends empty.
WaiterExpires ==
    /\ waiter = "held"
    /\ waiter' = "none"
    /\ UNCHANGED <<turn, row, via, box, inlet, reload, reloads, prompts, passedDue, wrong>>

-----------------------------------------------------------------------------
(* The reload *)

\* The operator asks; Mailbox's one step: refused while a turn runs, or
\* while a row is open with the waiter there for it (`message_due`); else
\* the waiter that holds is passed and the reload waits for its write.
\* Under PassWithDue the open rows are not looked at; under TypeWhileHeld
\* the waiter is not passed.
Asks ==
    /\ reload \in {"none"} \cup Answered /\ reloads < MaxReloads
    /\ reloads' = reloads + 1
    /\ IF turn = "running"
          THEN reload' = "refused" /\ UNCHANGED <<waiter, passedDue>>
       ELSE IF waiter = "deciding" \/ (waiter = "held" /\ Open # {} /\ Break # "PassWithDue")
          THEN reload' = "refused" /\ UNCHANGED <<waiter, passedDue>>
       ELSE IF waiter = "held" /\ Break # "TypeWhileHeld"
          THEN /\ waiter' = "none"
               /\ passedDue' = passedDue \cup Open
               /\ reload' = "waiting"
       ELSE reload' = "waiting" /\ UNCHANGED <<waiter, passedDue>>
    /\ UNCHANGED <<turn, row, via, box, inlet, prompts, wrong>>

\* The reload's keys: in the Inlet's one step, into an idle turn with no
\* waiter and an empty box (Inlet.reload_plugins/3's turn and screen).
ReloadKeys ==
    /\ reload = "waiting" /\ turn = "idle" /\ inlet = {} /\ box = ""
    /\ waiter = "none" \/ Break = "TypeWhileHeld"
    /\ Keys("reload")
    /\ reload' = "typing"
    /\ UNCHANGED <<turn, waiter, row, via, reloads, prompts, passedDue>>

\* Its Enter: a local command, which starts no turn and no waiter.
ReloadEnter ==
    /\ reload = "typing"
    /\ Enter("reload", FALSE)
    /\ reload' = "ok"
    /\ UNCHANGED <<waiter, row, via, reloads, prompts, passedDue>>

\* The bound passed while it waited: unknown, nothing typed.
ReloadBound ==
    /\ reload = "waiting" /\ Break # "NoBound"
    /\ reload' = "unknown"
    /\ UNCHANGED <<turn, waiter, row, via, box, inlet, reloads, prompts, passedDue, wrong>>

-----------------------------------------------------------------------------

Init ==
    /\ turn \in {"idle", "running"}
    /\ waiter = "none"
    /\ row = [m \in Msgs |-> "none"]
    /\ via = [m \in Msgs |-> ""]
    /\ box = ""
    /\ inlet = {}
    /\ reload = "none"
    /\ reloads = 0
    /\ prompts = 0
    /\ passedDue = {}
    /\ wrong = {}

Next ==
    \/ \E m \in Msgs : Due(m) \/ Hand(m) \/ Wakes(m) \/ TypedKeys(m) \/ TypedEnter(m)
    \/ TurnEnds \/ Prompt \/ WaiterExpires
    \/ Asks \/ ReloadKeys \/ ReloadEnter \/ ReloadBound

Fairness ==
    /\ \A m \in Msgs : /\ WF_vars(Hand(m)) /\ WF_vars(Wakes(m))
                       /\ WF_vars(TypedKeys(m)) /\ WF_vars(TypedEnter(m))
    /\ WF_vars(TurnEnds)
    /\ WF_vars(ReloadKeys) /\ WF_vars(ReloadEnter) /\ WF_vars(ReloadBound)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ turn \in {"idle", "running"}
    /\ waiter \in {"none", "held", "deciding"}
    /\ row \in [Msgs -> Rows]
    /\ via \in [Msgs -> {"", "waiter", "typed"}]
    /\ box \in {"", "row", "reload"}
    /\ inlet \subseteq {"row", "reload"}
    /\ reload \in Reloads
    /\ reloads \in 0..MaxReloads /\ prompts \in 0..MaxPrompts
    /\ passedDue \subseteq Msgs

\* The reload's Enter, and a typed row's, go into an idle turn only: no
\* woken turn starts between a write's keys and its Enter.
IntoIdleTurn == "enter into a running turn" \notin wrong

\* A typed row is never typed into the reload, nor the reload into a row.
OneWriteInBox == "keys into another write" \notin wrong

\* The waiter is passed only with no row open: a row due goes first by it.
DueFirst == passedDue = {}

\* Every row due is delivered, by the waiter or typed: none is lost.
Arrives == \A m \in Msgs : row[m] = "queued" ~> row[m] = "delivered"

\* Every reload is answered.
ReloadAnswered == reload \in {"waiting", "typing"} ~> reload \in Answered

=============================================================================
