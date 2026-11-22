--------------------------------- MODULE Menu ---------------------------------
(***************************************************************************)
(* A numbered menu on a running interactive session's screen (F-198): any  *)
(* menu of Claude Code's that no rule names, drawn with its numbered       *)
(* options, the marker on one, and "Enter to confirm · Esc to cancel". It  *)
(* sends no hook event, so Sessions reads the pane: a menu read becomes    *)
(* the agent row's, which Prompts shows as a `dialog` prompt, its options  *)
(* the labels plus `esc`. It has no default and no deadline: nothing       *)
(* answers it but a person. A person's answer is marked on the row before  *)
(* its press goes, and the press is checked and read back: the pane must   *)
(* still show that menu, or no key goes; the keys that move the marker go; *)
(* the pane is read again, and only with the marker on the label answered  *)
(* does Enter go. `esc` is Escape, checked the same way. A press whose      *)
(* outcome is unknown (the marker never read on the label, or the menu     *)
(* still shown after Enter) is never sent again: the person answers at the *)
(* viewer. The row's menu goes once a read finds the menu gone, whoever    *)
(* answered it, so its prompt leaves the inbox.                            *)
(*                                                                         *)
(* Models Sessions' read of a running row's pane for a menu, its answer    *)
(* (`Sessions.answer_menu/5`) and its press in a task, the Inlet's checked *)
(* press with its read-back (`Inlet.choose/5` with `{:menu, title}`, its   *)
(* `:esc`), and the row's `menu` field (`Sessions.Menu`), whose mark is    *)
(* the prompt's status in `Prompts`: none open, pressing answering,       *)
(* unknown kept for a person, sent gone.                                   *)
(*                                                                         *)
(* Left abstract: time; what a menu asks and what its options do (a label  *)
(* is a label); the rest of the screen. A menu's identity is its content   *)
(* (`Menus`: the code's title and options), so the same menu shown again   *)
(* before a read is one menu to the row, as the code reads it. A person    *)
(* at the viewer may move the marker or answer the menu at any step, and   *)
(* a key of the framework's may land on the marker or not.                 *)
(*                                                                         *)
(* Fairness: Sessions' steps (its reads, the take, the press, the read-    *)
(* back, the task's answer, the recover) happen while possible; a person,  *)
(* the program's draws and restarts happen or not.                         *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Menu_<value>.cfg that TLC must fail.                        *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Menus,        \* the menus the program may draw, by content, e.g. {"m1", "m2"}
    Labels,       \* each menu's options, in order; the marker starts on the first, e.g. <<"a", "b">>
    MaxDraws,     \* how many times the program draws a menu
    MaxRestarts,  \* restarts of Sessions
    Break         \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "Default",      \* Sessions answers a menu's first option when no one answered it
    "Unchecked",    \* the press goes without the pane read to show the menu it names
    "NoReadBack",   \* Enter goes after the keys without the marker read on the label
    "RetryUnknown", \* an answer whose press is unknown is pressed again
    "KeepGone"      \* the row's menu stays after a read finds the menu gone
}

ASSUME Break \in Breaks

\* Two options, for the configurations: one move of the marker, and Esc.
AB == <<"a", "b">>

Ls == {Labels[i] : i \in 1..Len(Labels)}
First == Labels[1]
Choices == Ls \cup {"esc"}
Marks == {"none", "pressing", "sent", "unknown"}
None == [m |-> "none", mark |-> "none", label |-> "none"]
NoMenu == [m |-> "none", sel |-> "none", n |-> 0]

VARIABLES
    screen,    \* the pane: the menu drawn, [m, sel (the marker's label), n (its draw)], or NoMenu
    draws,     \* the menus drawn so far
    row,       \* the agent row's menu: None, or [m, mark, label (the answer marked)]
    up,        \* Sessions runs
    restarts,
    call,      \* a person's answer on its way to Sessions: {} or {[m, label]}
    task,      \* the press in flight: {} or {[m, label, by, step]}, step "check" or "back"
    results,   \* the task's answer not yet taken: {} or {[m, mark]}
    sent,      \* ghost: n -> the presses whose keys went on draw n
    confirmed, \* ghost: the [n, label, by] each Enter or Escape of the framework's answered
    wrongs     \* ghost: draws a framework press landed on as another menu, or whose Enter
               \* confirmed a label other than the one answered

vars == <<screen, draws, row, up, restarts, call, task, results, sent, confirmed, wrongs>>

Draws == 1..MaxDraws
Shows(m) == screen.m # "none" /\ screen.m = m

\* A key the framework sent that ends the menu (Enter or Escape) lands, or not; one that lands
\* answers it, and its outcome is read (the menu left) or not.
Ends(t, label) ==
    \/ /\ screen' = NoMenu
       /\ confirmed' = confirmed \cup {[n |-> screen.n, label |-> label, by |-> t.by]}
       /\ results' \in {{[m |-> t.m, mark |-> "sent"]}, {[m |-> t.m, mark |-> "unknown"]}}
    \/ /\ results' = {[m |-> t.m, mark |-> "unknown"]}
       /\ UNCHANGED <<screen, confirmed>>

-----------------------------------------------------------------------------
(* The program and a person at the viewer *)

\* A menu is drawn, the marker on its first option.
Draw(m) ==
    /\ screen.m = "none" /\ draws < MaxDraws
    /\ draws' = draws + 1
    /\ screen' = [m |-> m, sel |-> First, n |-> draws + 1]
    /\ UNCHANGED <<row, up, restarts, call, task, results, sent, confirmed, wrongs>>

\* A person moves the marker at the viewer.
ViewerMove(l) ==
    /\ screen.m # "none" /\ screen.sel # l
    /\ screen' = [screen EXCEPT !.sel = l]
    /\ UNCHANGED <<draws, row, up, restarts, call, task, results, sent, confirmed, wrongs>>

\* A person answers the menu at the viewer (Enter or Esc): it leaves.
ViewerAnswer ==
    /\ screen.m # "none"
    /\ screen' = NoMenu
    /\ UNCHANGED <<draws, row, up, restarts, call, task, results, sent, confirmed, wrongs>>

-----------------------------------------------------------------------------
(* Sessions *)

\* The pane read while no press of the row's menu is under way: a menu shown becomes the
\* row's, unmarked, when it is another menu than the row's or the row's was sent; a screen
\* with no menu takes the row's away. Under KeepGone a menu gone is left on the row.
Read ==
    /\ up /\ row.mark # "pressing"
    /\ IF screen.m # "none"
       THEN /\ row.m # screen.m \/ row.mark = "sent"
            /\ row' = [m |-> screen.m, mark |-> "none", label |-> "none"]
       ELSE /\ row # None /\ Break # "KeepGone"
            /\ row' = None
    /\ UNCHANGED <<screen, draws, up, restarts, call, task, results, sent, confirmed, wrongs>>

\* An answer may be taken: the row's menu is unmarked (under RetryUnknown, or unknown).
Open == row # None /\ (row.mark = "none" \/ (Break = "RetryUnknown" /\ row.mark = "unknown"))

\* A person reads the row's menu in the inbox and answers it by a label or `esc`.
Answer(l) ==
    /\ Open /\ call = {}
    /\ call' = {[m |-> row.m, label |-> l]}
    /\ UNCHANGED <<screen, draws, row, up, restarts, task, results, sent, confirmed, wrongs>>

\* Marked pressing, its press in a task.
Mark(m, l, by) ==
    /\ row' = [row EXCEPT !.mark = "pressing", !.label = l]
    /\ task' = {[m |-> m, label |-> l, by |-> by, step |-> "check"]}

\* Sessions takes the answer when the row shows that menu and it may be taken; else refused,
\* and nothing goes.
Take(c) ==
    /\ up /\ c \in call /\ task = {}
    /\ call' = {}
    /\ IF Open /\ row.m = c.m THEN Mark(c.m, c.label, "person") ELSE UNCHANGED <<row, task>>
    /\ UNCHANGED <<screen, draws, up, restarts, results, sent, confirmed, wrongs>>

\* Under Default, Sessions answers an unmarked menu itself, its first option.
Default ==
    /\ Break = "Default" /\ up /\ task = {} /\ row # None /\ row.mark = "none"
    /\ Mark(row.m, First, "sessions")
    /\ UNCHANGED <<screen, draws, up, restarts, call, results, sent, confirmed, wrongs>>

\* The task's first step: the pane must show the menu the answer names, or nothing goes
\* (refused). Escape ends it; for a label the keys that move the marker go, and land or not (a
\* key lost, a person's key between). Under Unchecked the keys go whatever menu the pane shows.
Check(t) ==
    /\ up /\ t \in task /\ t.step = "check"
    /\ IF Shows(t.m) \/ (Break = "Unchecked" /\ screen.m # "none")
       THEN /\ sent' = [sent EXCEPT ![screen.n] = @ + 1]
            /\ wrongs' = IF screen.m # t.m THEN wrongs \cup {screen.n} ELSE wrongs
            /\ IF t.label = "esc"
               THEN task' = {} /\ Ends(t, "esc")
               ELSE /\ screen' \in {screen, [screen EXCEPT !.sel = t.label]}
                    /\ task' = {[t EXCEPT !.step = "back"]}
                    /\ UNCHANGED <<confirmed, results>>
       ELSE /\ task' = {}
            /\ results' = {[m |-> t.m, mark |-> "none"]}
            /\ UNCHANGED <<screen, sent, confirmed, wrongs>>
    /\ UNCHANGED <<draws, row, up, restarts, call>>

\* The read-back: Enter goes only once the pane shows that menu with the marker on the label
\* answered; else no Enter goes, and the press is unknown (its keys went). Under NoReadBack
\* Enter goes on whatever the marker is on.
Back(t) ==
    /\ up /\ t \in task /\ t.step = "back"
    /\ task' = {}
    /\ IF (Shows(t.m) /\ screen.sel = t.label) \/ (Break = "NoReadBack" /\ screen.m # "none")
       THEN /\ wrongs' = IF screen.sel # t.label THEN wrongs \cup {screen.n} ELSE wrongs
            /\ Ends(t, screen.sel)
       ELSE /\ results' = {[m |-> t.m, mark |-> "unknown"]}
            /\ UNCHANGED <<screen, confirmed, wrongs>>
    /\ UNCHANGED <<draws, row, up, restarts, call, sent>>

\* Sessions takes the task's answer: sent or unknown stays marked; a refusal, which pressed
\* nothing, takes the mark back, and the next read finds what the pane shows.
Pressed(r) ==
    /\ up /\ r \in results
    /\ results' = {}
    /\ row' = IF row.m = r.m /\ row.mark = "pressing"
              THEN IF r.mark = "none"
                   THEN [row EXCEPT !.mark = "none", !.label = "none"]
                   ELSE [row EXCEPT !.mark = r.mark]
              ELSE row
    /\ UNCHANGED <<screen, draws, up, restarts, call, task, sent, confirmed, wrongs>>

\* A restart: the call under way, the task and its answer are lost (the task ends with
\* Sessions); the row stays.
Restart ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ call' = {} /\ task' = {} /\ results' = {}
    /\ UNCHANGED <<screen, draws, row, sent, confirmed, wrongs>>

\* Recover: a press marked pressing may have gone, so it is unknown, never pressed again.
Recover ==
    /\ ~up
    /\ up' = TRUE
    /\ row' = IF row.mark = "pressing" THEN [row EXCEPT !.mark = "unknown"] ELSE row
    /\ UNCHANGED <<screen, draws, restarts, call, task, results, sent, confirmed, wrongs>>

-----------------------------------------------------------------------------

Init ==
    /\ screen = NoMenu /\ draws = 0
    /\ row = None
    /\ up = TRUE /\ restarts = 0
    /\ call = {} /\ task = {} /\ results = {}
    /\ sent = [n \in Draws |-> 0] /\ confirmed = {} /\ wrongs = {}

Next ==
    \/ \E m \in Menus : Draw(m)
    \/ \E l \in Ls : ViewerMove(l)
    \/ ViewerAnswer \/ Read \/ Default \/ Restart \/ Recover
    \/ \E l \in Choices : Answer(l)
    \/ \E c \in call : Take(c)
    \/ \E t \in task : Check(t) \/ Back(t)
    \/ \E r \in results : Pressed(r)

\* Read is strong-fair: answers taken again and again, each refused, mark the row pressing
\* between reads, and the code reads the pane again after each press's answer.
Fairness ==
    /\ SF_vars(Read) /\ WF_vars(Recover) /\ WF_vars(\E c \in call : Take(c))
    /\ WF_vars(\E t \in task : Check(t)) /\ WF_vars(\E t \in task : Back(t))
    /\ WF_vars(\E r \in results : Pressed(r))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ screen.m = "none" \/ (screen.m \in Menus /\ screen.sel \in Ls /\ screen.n \in Draws)
    /\ draws \in 0..MaxDraws
    /\ row = None \/ (row.m \in Menus /\ row.mark \in Marks /\ row.label \in Choices \cup {"none"})
    /\ up \in BOOLEAN /\ restarts \in 0..MaxRestarts
    /\ Cardinality(call) <= 1 /\ Cardinality(task) <= 1 /\ Cardinality(results) <= 1

\* No default: every key of the framework's that answers a menu comes from a person's answer.
OnlyAsked == \A c \in confirmed : c.by = "person"

\* A press lands only on the menu it names, and Enter confirms only the label answered.
OnNamed == wrongs = {}

\* A menu's draw is pressed at most once, whatever the outcome.
AtMostOnce == \A n \in Draws : sent[n] <= 1

\* The row's menu goes once the pane no longer shows a menu, so its prompt leaves the inbox.
LeavesWhenGone == (screen.m = "none" /\ row # None) ~> (row = None \/ screen.m # "none")

\* A menu the pane shows becomes the row's.
MenuShown == \A m \in Menus : Shows(m) ~> (row.m = m \/ ~Shows(m))

=============================================================================
