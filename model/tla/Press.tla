--------------------------------- MODULE Press --------------------------------
(***************************************************************************)
(* The Inlet's checked press of a dialog, step by step, against a program *)
(* that draws its dialog and then, on a timer, draws it again once         *)
(* (F-246). Claude Code 2.1.322's trust dialog, measured: about 150 ms     *)
(* after its first draw the program sets the selection back to its first  *)
(* option. A key before then moves the marker on the screen but not the   *)
(* choice the program holds; an Enter before then is dropped. With no key *)
(* the second draw writes nothing, since nothing on the screen changes, so *)
(* it cannot be read: only time tells it has passed. A press made on the   *)
(* first draw is lost, and an Enter after the reset confirms the first     *)
(* option, the trust dialog's "No, exit", while the screen had shown the   *)
(* one answered.                                                           *)
(*                                                                         *)
(* The press: the pane is read and must show the dialog; it is read again  *)
(* until its reading has stayed the same for the settle bound (S ticks);   *)
(* then the keys go; the pane is read until the marker is on the label     *)
(* answered; Enter goes; the pane is read until the dialog has left. Each  *)
(* read has a bound: past it, a press with no key sent is refused, one     *)
(* with keys sent is unknown. The settle bound is longer than the time the *)
(* program takes to draw its dialog again (R), which `Inlet.settle/0`'s    *)
(* default holds over the measured time with room for a loaded host.       *)
(*                                                                         *)
(* Models `Inlet.choose/5` (its settle, keys, read-back, Enter and leave   *)
(* read) and the program's dialog. Dialog.tla and Menu.tla take this whole *)
(* press as one step (their Press, Check and Back).                        *)
(*                                                                         *)
(* Left abstract: what a label does past the dialog (it leaves); a person  *)
(* at the viewer (Dialog.tla, Menu.tla); restarts (the same); time, as     *)
(* ticks of one clock the program's timer and the Inlet's bounds share.    *)
(*                                                                         *)
(* Break: "none" is the design. "FirstDraw" presses at the Inlet's first   *)
(* read, with no settle, as before F-246; Break_Press_FirstDraw.cfg must   *)
(* fail.                                                                   *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS
    R,       \* the program draws its dialog again by this many ticks after its first draw
    S,       \* the Inlet's settle bound, in ticks
    MaxAge,  \* the ticks the run lasts; the Inlet's read bounds end there
    Break    \* "none" or "FirstDraw"

ASSUME Break \in {"none", "FirstDraw"}
ASSUME R \in Nat /\ R >= 1 /\ S \in Nat /\ MaxAge \in Nat /\ MaxAge > S

\* The options in order, the selection starting on the first; the press answers "yes".
First == "no"
Want == "yes"
Labels == {First, Want}

VARIABLES
    phase,   \* the program's dialog: "none" (not drawn), "first", "again" (drawn again), "gone"
    sel,     \* the option the marker is drawn on
    held,    \* the option the program holds, which an Enter confirms
    age,     \* ticks since the dialog's first draw
    chosen,  \* the option the program took, or "none"
    pc,      \* the Inlet: "idle", "settle", "back", "enter", "leave", "done"
    waited,  \* ticks the Inlet has read the dialog the same, up to S
    result,  \* the press's answer: "none", "ok", "refused", "unknown"
    keys,    \* ghost: key sends
    enters   \* ghost: Enter sends

vars == <<phase, sel, held, age, chosen, pc, waited, result, keys, enters>>
inlet == <<pc, waited, result, keys, enters>>

Shown == phase \in {"first", "again"}

-----------------------------------------------------------------------------
(* The program *)

Draw ==
    /\ phase = "none"
    /\ phase' = "first" /\ sel' = First /\ held' = First /\ age' = 0
    /\ UNCHANGED <<chosen, inlet>>

\* Time passes. The program's timer fires by R: past it, no tick until the dialog is drawn again.
Tick ==
    /\ phase # "none" /\ age < MaxAge
    /\ ~(phase = "first" /\ age = R)
    /\ age' = age + 1
    /\ waited' = IF pc = "settle" /\ waited < S THEN waited + 1 ELSE waited
    /\ UNCHANGED <<phase, sel, held, chosen, pc, result, keys, enters>>

\* The second draw: the selection back on the first option, on the screen and in the program.
\* With no key before it, the screen does not change, so the Inlet's reading does not either.
Redraw ==
    /\ phase = "first" /\ age >= 1
    /\ phase' = "again" /\ sel' = First /\ held' = First
    /\ UNCHANGED <<age, chosen, inlet>>

-----------------------------------------------------------------------------
(* The Inlet's press *)

\* The first read: the dialog shown, or nothing goes.
Look ==
    /\ pc = "idle"
    /\ IF Shown
       THEN pc' = "settle" /\ waited' = 0 /\ UNCHANGED result
       ELSE pc' = "done" /\ result' = "refused" /\ UNCHANGED waited
    /\ UNCHANGED <<phase, sel, held, age, chosen, keys, enters>>

\* The keys, once the dialog has read the same for S ticks. On the first draw they move the
\* marker only. Under FirstDraw they go at once.
Keys ==
    /\ pc = "settle" /\ Shown
    /\ waited >= S \/ Break = "FirstDraw"
    /\ sel' = Want
    /\ held' = IF phase = "again" THEN Want ELSE held
    /\ keys' = keys + 1
    /\ pc' = "back"
    /\ UNCHANGED <<phase, age, chosen, waited, result, enters>>

\* The settle's bound passed (or the dialog left) with no key sent: refused.
Unsettled ==
    /\ pc = "settle" /\ (age = MaxAge \/ ~Shown)
    /\ waited < S \/ ~Shown
    /\ pc' = "done" /\ result' = "refused"
    /\ UNCHANGED <<phase, sel, held, age, chosen, waited, keys, enters>>

\* The read-back: the marker on the label, or, past the bound, unknown with no Enter.
Back ==
    /\ pc = "back"
    /\ IF Shown /\ sel = Want
       THEN pc' = "enter" /\ UNCHANGED result
       ELSE /\ age = MaxAge \/ ~Shown
            /\ pc' = "done" /\ result' = "unknown"
    /\ UNCHANGED <<phase, sel, held, age, chosen, waited, keys, enters>>

\* Enter: the program confirms the option it holds, or drops it on the first draw.
Enter ==
    /\ pc = "enter"
    /\ enters' = enters + 1
    /\ pc' = "leave"
    /\ IF phase = "again"
       THEN phase' = "gone" /\ chosen' = held
       ELSE UNCHANGED <<phase, chosen>>
    /\ UNCHANGED <<sel, held, age, waited, result, keys>>

\* The leave read: the dialog gone is sent; still shown at the bound, unknown.
Leave ==
    /\ pc = "leave"
    /\ IF phase = "gone"
       THEN result' = "ok"
       ELSE age = MaxAge /\ result' = "unknown"
    /\ pc' = "done"
    /\ UNCHANGED <<phase, sel, held, age, chosen, waited, keys, enters>>

-----------------------------------------------------------------------------

Init ==
    /\ phase = "none" /\ sel = First /\ held = First /\ age = 0 /\ chosen = "none"
    /\ pc = "idle" /\ waited = 0 /\ result = "none" /\ keys = 0 /\ enters = 0

Next == Draw \/ Tick \/ Redraw \/ Look \/ Keys \/ Unsettled \/ Back \/ Enter \/ Leave

Fairness ==
    /\ WF_vars(Draw) /\ WF_vars(Tick) /\ WF_vars(Redraw)
    /\ WF_vars(Look) /\ WF_vars(Keys) /\ WF_vars(Unsettled) /\ WF_vars(Back)
    /\ WF_vars(Enter) /\ WF_vars(Leave)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ phase \in {"none", "first", "again", "gone"}
    /\ sel \in Labels /\ held \in Labels /\ chosen \in Labels \cup {"none"}
    /\ age \in 0..MaxAge /\ waited \in 0..S
    /\ pc \in {"idle", "settle", "back", "enter", "leave", "done"}
    /\ result \in {"none", "ok", "refused", "unknown"}

\* The program never takes an option other than the one answered.
RightChoice == chosen \in {"none", Want}

\* A press answered ok took the option answered.
OkIsTaken == result = "ok" => chosen = Want

\* Keys and Enter go at most once a press: nothing is pressed again.
Once == keys <= 1 /\ enters <= 1

\* A refused press sent nothing.
RefusedSentNothing == result = "refused" => keys = 0 /\ enters = 0

\* Every press is answered.
Answered == <>(pc = "done")

=============================================================================
