--------------------------------- MODULE Inbox --------------------------------
(***************************************************************************)
(* The inbox's reads, its `prompts` cue and a prompt's `closed` fact       *)
(* around one answer (F-295, F-297). Prompt.tla takes the answer as a      *)
(* claim, a hand to its owner and a settle, and leaves the inbox's reads   *)
(* and cues abstract; this spec is those reads, against an owner that      *)
(* applies the answer and cues at once, before the caller settles the      *)
(* answer's row in Acts (the Mailbox since F-289: an ask's answer row is   *)
(* stored and cued in the call, its settle pass later).                    *)
(*                                                                         *)
(* One ask, answered by a person through the inbox. The caller claims the  *)
(* answer's row, hands the answer to the owner (the prompt leaves the      *)
(* owner's rows, and the owner cues), settles the row with the owner's     *)
(* answer, and then has the inbox read again, naming the prompt, and cues  *)
(* `prompts` with its id itself. The inbox reads on each cue: it lists the *)
(* prompt open while its owner shows it, and `answering` while it is gone  *)
(* from its owner but its answer's row, which the inbox knows, is open; it *)
(* cues `prompts` when what it lists moved, and writes the `closed` fact,  *)
(* once, when a prompt it knows is no longer listed, its closer read from  *)
(* the answer's row: the person once the row settled, `unknown` with the   *)
(* person as actor once the row was interrupted (F-297), else the          *)
(* framework's guess. A page of closed prompts (`answered/3`) writes the   *)
(* fact of a close no read saw only for a prompt no open answer's row      *)
(* names and no settled one: an interrupted one's fact is `unknown`. The   *)
(* reader (the embedding app) reads on each `prompts` cue: the prompt      *)
(* listed, else its closed record.                                         *)
(*                                                                         *)
(* The caller may die between the hand and the settle (F-297): its row     *)
(* stays claimed, and the prompt answering, until the next start of the    *)
(* framework closes the row interrupted (Acts at its start) and starts the *)
(* inbox again. The caller's read after its settle names the prompt, so    *)
(* one answered between two reads is the inbox's too. A restart of the     *)
(* inbox loses what it knows and its pending reads (that one among them);  *)
(* its first read, before any call it takes, rebuilds what it knows from   *)
(* the answer rows: each open one, and each settled or interrupted one     *)
(* whose prompt has no `closed` fact (F-297). It takes an open or an       *)
(* interrupted one as listed `answering`, as before the start, so that     *)
(* read cues the one a dead caller left; a settled one is cued by its      *)
(* caller, whose cue is its own, so it is not lost.                        *)
(*                                                                         *)
(* Models `Prompts.answer/5` (its claim, hand, settle, read and cue), the  *)
(* read `Prompts.list/1` with the answering prompts it knows, the reread   *)
(* on a cue (`closes/2`'s fact), the first read after a start              *)
(* (`rebuild/1`), `Prompts.answered/3`'s page, and `Acts`' start.          *)
(*                                                                         *)
(* Left abstract: the other kinds (each owner's row leaves the same way:   *)
(* an Intake hold answered, a dialog pressed); a second answer (Prompt.tla *)
(* and Team.tla's AnswerOnce); a caller that dies before its hand (the     *)
(* prompt stays open with its owner, for the next answer, whose row is     *)
(* claimed after the interrupted one, so the interrupted one is not taken  *)
(* as its closer); time.                                                   *)
(*                                                                         *)
(* Break: "none" is the design. Each other value removes one guard, and    *)
(* its Break_Inbox_<value>.cfg must fail: "CueBeforeSettle" lists the      *)
(* prompt gone as soon as its owner lets it go, as before F-295; "Fact     *)
(* BeforeSettle" lets a page write the fact of a prompt whose row has not  *)
(* settled; "NoCueAfterSettle" leaves the cue after the settle to the      *)
(* ledger's cue, which nothing wires; "GuessInterrupted" names the         *)
(* framework's guess as the closer of an interrupted row, as before F-297; *)
(* "ForgetPastRestart" starts the inbox knowing nothing, as before F-297.  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxRestarts,  \* the inbox's restarts
    Break         \* "none", or the guard removed

Breaks == {"none", "CueBeforeSettle", "FactBeforeSettle", "NoCueAfterSettle",
           "GuessInterrupted", "ForgetPastRestart"}
ASSUME Break \in Breaks /\ MaxRestarts \in Nat

VARIABLES
    owner,     \* the owner's row: "open" (the ask shown) or "gone" (its answer stored)
    row,       \* the answer's row in Acts: "none", "claimed", "settled", "interrupted"
    pc,        \* the caller of answer/5: "idle", "claimed", "handed", "settled", "done", "dead"
    known,     \* the inbox knows the prompt (`seen`), so a gone one is its own
    shown,     \* what the inbox's last read listed it as: "none", "open", "answering"
    dirty,     \* a cue to the inbox not yet read
    starting,  \* the inbox's first read after its start is still to come
    cued,      \* a `prompts` cue naming the prompt, not yet read by the reader
    card,      \* the reader's view: "none", "open", "answering", "answered", "unknown",
               \* "closed", "gone"
    fact,      \* the closed fact: "none", "person", "unknown" (the person as actor), "framework"
    restarts

vars == <<owner, row, pc, known, shown, dirty, starting, cued, card, fact, restarts>>

\* What the inbox lists now: its owner's row, and an answering prompt it knows.
Listed ==
    IF owner = "open" THEN "open"
    ELSE IF row = "claimed" /\ known /\ Break # "CueBeforeSettle" THEN "answering"
    ELSE "none"

\* Who closed it, read from the answer's row: the person once it settled, `unknown` by the
\* person once it was interrupted, else a guess.
Closer ==
    CASE row = "settled" -> "person"
      [] row = "interrupted" /\ Break # "GuessInterrupted" -> "unknown"
      [] OTHER -> "framework"

\* What the inbox knows at its start (`rebuild/1`): a prompt whose answer row is open, or
\* settled or interrupted with no `closed` fact yet.
Rebuilt(r) ==
    /\ Break # "ForgetPastRestart"
    /\ \/ r = "claimed"
       \/ r \in {"settled", "interrupted"} /\ fact = "none"

\* What it lists such a prompt as before its first read: `answering`, as before the start,
\* for a row its caller will not cue.
Reshown(r) == IF Rebuilt(r) /\ r # "settled" THEN "answering" ELSE "none"

\* What the reader finds: the prompt listed, else its closed record (`answered/3`): the
\* answer's row once settled or interrupted, its open row as `answering`, else the fact's closer.
View ==
    IF Listed # "none" THEN Listed
    ELSE IF row = "settled" THEN "answered"
    ELSE IF row = "interrupted" THEN "unknown"
    ELSE IF row = "claimed" /\ Break \notin {"CueBeforeSettle", "FactBeforeSettle"}
         THEN "answering"
    ELSE IF fact = "framework" THEN "closed"
    ELSE "gone"

-----------------------------------------------------------------------------
(* The caller of answer/5 *)

Claim ==
    /\ pc = "idle" /\ Listed = "open"
    /\ row' = "claimed" /\ pc' = "claimed"
    /\ UNCHANGED <<owner, known, shown, dirty, starting, cued, card, fact, restarts>>

\* The owner applies the answer and cues at once.
Hand ==
    /\ pc = "claimed"
    /\ owner' = "gone" /\ pc' = "handed" /\ dirty' = TRUE
    /\ UNCHANGED <<row, known, shown, starting, cued, card, fact, restarts>>

Settle ==
    /\ pc = "handed"
    /\ row' = "settled" /\ pc' = "settled"
    /\ UNCHANGED <<owner, known, shown, dirty, starting, cued, card, fact, restarts>>

\* The caller ends between the hand and the settle: its row stays claimed.
Die ==
    /\ pc = "handed"
    /\ pc' = "dead"
    /\ UNCHANGED <<owner, row, known, shown, dirty, starting, cued, card, fact, restarts>>

\* The caller has the inbox read again, naming the prompt (`{:settled, prompt}`: one no read
\* listed, answered between two reads, is its own then), and cues `prompts` with its id, once
\* its row settled.
CueSettled ==
    /\ pc = "settled"
    /\ pc' = "done"
    /\ IF Break = "NoCueAfterSettle"
       THEN UNCHANGED <<known, dirty, cued>>
       ELSE known' = TRUE /\ dirty' = TRUE /\ cued' = TRUE
    /\ UNCHANGED <<owner, row, shown, starting, card, fact, restarts>>

-----------------------------------------------------------------------------
(* The inbox *)

\* A read on a cue: what moved is cued, and a prompt it knows that this read does not list
\* has its closed fact written.
Read ==
    /\ dirty
    /\ LET l == Listed IN
         /\ cued' = (cued \/ l # shown)
         /\ shown' = l
         /\ known' = (l # "none")
         /\ fact' = IF known /\ l = "none" /\ fact = "none" THEN Closer ELSE fact
    /\ dirty' = FALSE /\ starting' = FALSE
    /\ UNCHANGED <<owner, row, pc, card, restarts>>

\* A page of closed prompts writes the fact of a close no read saw only for a prompt whose
\* answer's row is neither open nor settled: one whose row settled is read from that row, and
\* one whose row is open waits for its settle. It is a call, taken after the start's first read.
Page ==
    /\ ~starting
    /\ Listed = "none" /\ owner = "gone" /\ fact = "none"
    /\ row # "settled"
    /\ row # "claimed" \/ Break = "FactBeforeSettle"
    /\ fact' = Closer
    /\ UNCHANGED <<owner, row, pc, known, shown, dirty, starting, cued, card, restarts>>

\* The inbox's process ends and starts again: what its last read listed and its pending reads
\* are lost, and it starts knowing what the answer rows say; its first read is a read on a cue.
Restart ==
    /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ known' = Rebuilt(row) /\ shown' = Reshown(row)
    /\ dirty' = TRUE /\ starting' = TRUE
    /\ UNCHANGED <<owner, row, pc, cued, card, fact>>

\* The next start of the framework, after the caller died: Acts closes its claimed row
\* interrupted, and the inbox starts again as in Restart.
Start ==
    /\ pc = "dead" /\ row = "claimed"
    /\ row' = "interrupted"
    /\ known' = Rebuilt("interrupted") /\ shown' = Reshown("interrupted")
    /\ dirty' = TRUE /\ starting' = TRUE
    /\ UNCHANGED <<owner, pc, cued, card, fact, restarts>>

-----------------------------------------------------------------------------
(* The reader *)

Look ==
    /\ cued
    /\ cued' = FALSE /\ card' = View
    /\ UNCHANGED <<owner, row, pc, known, shown, dirty, starting, fact, restarts>>

-----------------------------------------------------------------------------

Init ==
    /\ owner = "open" /\ row = "none" /\ pc = "idle"
    /\ known = FALSE /\ shown = "none" /\ dirty = TRUE /\ starting = TRUE /\ cued = FALSE
    /\ card = "none" /\ fact = "none" /\ restarts = 0

Next ==
    Claim \/ Hand \/ Settle \/ Die \/ CueSettled \/ Read \/ Page \/ Restart \/ Start \/ Look

\* The next start comes (Start): until it does, a dead caller's prompt reads answering.
Fairness ==
    /\ WF_vars(Claim) /\ WF_vars(Hand) /\ WF_vars(Settle) /\ WF_vars(CueSettled)
    /\ WF_vars(Read) /\ WF_vars(Look) /\ WF_vars(Start)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ owner \in {"open", "gone"} /\ row \in {"none", "claimed", "settled", "interrupted"}
    /\ pc \in {"idle", "claimed", "handed", "settled", "done", "dead"}
    /\ known \in BOOLEAN /\ dirty \in BOOLEAN /\ starting \in BOOLEAN /\ cued \in BOOLEAN
    /\ shown \in {"none", "open", "answering"}
    /\ card \in {"none", "open", "answering", "answered", "unknown", "closed", "gone"}
    /\ fact \in {"none", "person", "unknown", "framework"} /\ restarts \in 0..MaxRestarts

\* A reader on a cue finds the prompt open, answering, answered or unknown: never only gone,
\* and never closed by anyone but who answered it.
NeverOnlyGone == card \notin {"gone", "closed"}

\* The closed fact, written once and kept, names who answered, or says `unknown` with who
\* answered as its actor once the answer's row was interrupted: never a guess.
FactNamesAnswerer ==
    /\ fact \in {"none", "person", "unknown"}
    /\ fact = "person" => row = "settled"
    /\ fact = "unknown" => row = "interrupted"

\* Every closed prompt gets its fact once its answer's row is closed, written by the inbox's
\* own reads (the page is the reader's, and need not come).
ClosedHasFact == (owner = "gone" /\ row \in {"settled", "interrupted"}) ~> fact # "none"

\* The reader's last read finds it answered, or `unknown` once its caller died. (Its fact is
\* written by the read after the settle, or by the start's first read after the interrupt.)
ReaderSeesAnswered == <>[](card = IF pc = "dead" THEN "unknown" ELSE "answered")

=============================================================================
