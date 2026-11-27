--------------------------------- MODULE Inbox --------------------------------
(***************************************************************************)
(* The inbox's reads, its `prompts` cue and a prompt's `closed` fact       *)
(* around one answer (F-295). Prompt.tla takes the answer as a claim, a    *)
(* hand to its owner and a settle, and leaves the inbox's reads and cues   *)
(* abstract; this spec is those reads, against an owner that applies the   *)
(* answer and cues at once, before the caller settles the answer's row in  *)
(* Acts (the Mailbox since F-289: an ask's answer row is stored and cued   *)
(* in the call, its settle pass later).                                    *)
(*                                                                         *)
(* One ask, answered by a person through the inbox. The caller claims the  *)
(* answer's row, hands the answer to the owner (the prompt leaves the      *)
(* owner's rows, and the owner cues), settles the row with the owner's     *)
(* answer, and then cues `prompts` with the prompt's id itself and has the *)
(* inbox read again. The inbox reads on each cue: it lists the prompt open *)
(* while its owner shows it, and `answering` while it is gone from its     *)
(* owner but its answer's row, which the inbox's last read listed, is not  *)
(* settled; it cues `prompts` when what it lists moved, and writes the     *)
(* `closed` fact, once, when a prompt its last read listed is no longer    *)
(* listed, its closer read from the answer's row: the person once the row  *)
(* settled, else the framework's guess. A page of closed prompts           *)
(* (`answered/3`) writes the fact of a close no read saw only for a prompt *)
(* no answer's row names, open or taken. The reader (the embedding app)    *)
(* reads on each `prompts` cue: the prompt listed, else its closed record. *)
(* A restart of the inbox loses what its last read listed and its pending  *)
(* reads; the caller's cue is the caller's, so it is not lost.             *)
(*                                                                         *)
(* Models `Prompts.answer/5` (its claim, hand, settle and cue), the read   *)
(* `Prompts.list/1` with the answering prompts its last read listed, the  *)
(* reread on a cue (`closes/2`'s fact) and `Prompts.answered/3`'s page.    *)
(*                                                                         *)
(* Left abstract: the other kinds (each owner's row leaves the same way:   *)
(* an Intake hold answered, a dialog pressed); a second answer (Prompt.tla *)
(* and Team.tla's AnswerOnce); a caller that dies before its settle (its   *)
(* row stays claimed, and the prompt answering, until the next start       *)
(* closes the row interrupted); time.                                      *)
(*                                                                         *)
(* Break: "none" is the design. Each other value removes one guard, and    *)
(* its Break_Inbox_<value>.cfg must fail: "CueBeforeSettle" lists the      *)
(* prompt gone as soon as its owner lets it go, as before F-295; "Fact     *)
(* BeforeSettle" lets a page write the fact of a prompt whose row has not  *)
(* settled; "NoCueAfterSettle" leaves the cue after the settle to the      *)
(* ledger's cue, which nothing wires.                                      *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxRestarts,  \* the inbox's restarts
    Break         \* "none", or the guard removed

Breaks == {"none", "CueBeforeSettle", "FactBeforeSettle", "NoCueAfterSettle"}
ASSUME Break \in Breaks /\ MaxRestarts \in Nat

VARIABLES
    owner,     \* the owner's row: "open" (the ask shown) or "gone" (its answer stored)
    row,       \* the answer's row in Acts: "none", "claimed", "settled"
    pc,        \* the caller of answer/5: "idle", "claimed", "handed", "settled", "done"
    known,     \* the inbox's last read listed the prompt (`seen`), so a gone one is its own
    shown,     \* what the inbox's last read listed it as: "none", "open", "answering"
    dirty,     \* a cue to the inbox not yet read
    cued,      \* a `prompts` cue naming the prompt, not yet read by the reader
    card,      \* the reader's view: "none", "open", "answering", "answered", "closed", "gone"
    fact,      \* the closed fact: "none", "person", "framework"
    restarts

vars == <<owner, row, pc, known, shown, dirty, cued, card, fact, restarts>>

\* What the inbox lists now: its owner's row, and an answering prompt its last read listed.
Listed ==
    IF owner = "open" THEN "open"
    ELSE IF row = "claimed" /\ known /\ Break # "CueBeforeSettle" THEN "answering"
    ELSE "none"

\* Who closed it, read from the answer's row: the person once it settled, else a guess.
Closer == IF row = "settled" THEN "person" ELSE "framework"

\* What the reader finds: the prompt listed, else its closed record (`answered/3`): the
\* answer's row once settled, its open row as `answering`, else the fact's closer.
View ==
    IF Listed # "none" THEN Listed
    ELSE IF row = "settled" THEN "answered"
    ELSE IF row = "claimed" /\ Break \notin {"CueBeforeSettle", "FactBeforeSettle"}
         THEN "answering"
    ELSE IF fact = "framework" THEN "closed"
    ELSE "gone"

-----------------------------------------------------------------------------
(* The caller of answer/5 *)

Claim ==
    /\ pc = "idle" /\ Listed = "open"
    /\ row' = "claimed" /\ pc' = "claimed"
    /\ UNCHANGED <<owner, known, shown, dirty, cued, card, fact, restarts>>

\* The owner applies the answer and cues at once.
Hand ==
    /\ pc = "claimed"
    /\ owner' = "gone" /\ pc' = "handed" /\ dirty' = TRUE
    /\ UNCHANGED <<row, known, shown, cued, card, fact, restarts>>

Settle ==
    /\ pc = "handed"
    /\ row' = "settled" /\ pc' = "settled"
    /\ UNCHANGED <<owner, known, shown, dirty, cued, card, fact, restarts>>

\* The caller cues `prompts` with the id and has the inbox read again, once its row settled.
CueSettled ==
    /\ pc = "settled"
    /\ pc' = "done"
    /\ IF Break = "NoCueAfterSettle"
       THEN UNCHANGED <<dirty, cued>>
       ELSE dirty' = TRUE /\ cued' = TRUE
    /\ UNCHANGED <<owner, row, known, shown, card, fact, restarts>>

-----------------------------------------------------------------------------
(* The inbox *)

\* A read on a cue: what moved is cued, and a prompt its last read listed and this one does
\* not has its closed fact written.
Read ==
    /\ dirty
    /\ LET l == Listed IN
         /\ cued' = (cued \/ l # shown)
         /\ shown' = l
         /\ known' = (l # "none")
         /\ fact' = IF known /\ l = "none" /\ fact = "none" THEN Closer ELSE fact
    /\ dirty' = FALSE
    /\ UNCHANGED <<owner, row, pc, card, restarts>>

\* A page of closed prompts writes the fact of a close no read saw (past a restart) only for a
\* prompt no answer's row names: one whose row is taken is read from that row, and one whose
\* row is open waits for its settle. So in this spec a page writes no fact but under its break.
Page ==
    /\ Listed = "none" /\ owner = "gone" /\ fact = "none"
    /\ row # "settled"
    /\ row # "claimed" \/ Break = "FactBeforeSettle"
    /\ fact' = Closer
    /\ UNCHANGED <<owner, row, pc, known, shown, dirty, cued, card, restarts>>

\* The inbox's process ends and starts again: what its last read listed and its pending reads
\* are lost; its first read is a read on a cue.
Restart ==
    /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ known' = FALSE /\ shown' = "none" /\ dirty' = TRUE
    /\ UNCHANGED <<owner, row, pc, cued, card, fact>>

-----------------------------------------------------------------------------
(* The reader *)

Look ==
    /\ cued
    /\ cued' = FALSE /\ card' = View
    /\ UNCHANGED <<owner, row, pc, known, shown, dirty, fact, restarts>>

-----------------------------------------------------------------------------

Init ==
    /\ owner = "open" /\ row = "none" /\ pc = "idle"
    /\ known = FALSE /\ shown = "none" /\ dirty = TRUE /\ cued = FALSE
    /\ card = "none" /\ fact = "none" /\ restarts = 0

Next == Claim \/ Hand \/ Settle \/ CueSettled \/ Read \/ Page \/ Restart \/ Look

Fairness ==
    /\ WF_vars(Claim) /\ WF_vars(Hand) /\ WF_vars(Settle) /\ WF_vars(CueSettled)
    /\ WF_vars(Read) /\ WF_vars(Look)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ owner \in {"open", "gone"} /\ row \in {"none", "claimed", "settled"}
    /\ pc \in {"idle", "claimed", "handed", "settled", "done"}
    /\ known \in BOOLEAN /\ dirty \in BOOLEAN /\ cued \in BOOLEAN
    /\ shown \in {"none", "open", "answering"}
    /\ card \in {"none", "open", "answering", "answered", "closed", "gone"}
    /\ fact \in {"none", "person", "framework"} /\ restarts \in 0..MaxRestarts

\* A reader on a cue finds the prompt open, answering or answered: never only gone, and never
\* closed by anyone but who answered it.
NeverOnlyGone == card \notin {"gone", "closed"}

\* The closed fact, written once and kept, names who answered.
FactNamesAnswerer == fact \in {"none", "person"}

\* The reader's last read finds it answered. (Its fact is written by the read after the
\* settle, or, past a restart, by the first page that holds it.)
ReaderSeesAnswered == <>[](card = "answered")

=============================================================================
