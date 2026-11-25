--------------------------------- MODULE Reply --------------------------------
(***************************************************************************)
(* An interactive delegate's turns after its report, as its transcript    *)
(* shows them, and the framework's reading of them (F-257). Claude Code   *)
(* writes the transcript; the framework reads it at any moment and stores *)
(* what it reads in Mailbox, one row per key. A turn begins with a user   *)
(* line: a background command's wake (a `<task-notification>` with no    *)
(* delivery mark), or a parent's message handed to the waiter into an     *)
(* idle session (a user line with the message's mark). A message handed  *)
(* to the waiter while a turn runs, a turn of its own that a wake began   *)
(* after the waiter was held, joins that turn as a `queued_command`       *)
(* attachment with its mark, and opens none (measured for F-127). A turn  *)
(* ends with its reply, or the process ends in it.                        *)
(*                                                                         *)
(* The reading: each turn after the report's that has ended (a later      *)
(* turn began, the session reads idle, or the process is gone) answers    *)
(* every message whose mark is in it, its opener's or a queued one's: its *)
(* reply under the message's key, or with the process gone and no reply,  *)
(* the framework's notice under that key. A turn a wake began is told as  *)
(* a turn of its own, under its reply's uuid, only when no message's mark *)
(* is in it.                                                               *)
(*                                                                         *)
(* Models the reading of `Transcripts.Fold.turns/2` and `Delegates`       *)
(* (`answer_turns`, `tell_turns`), and `Mailbox.answered/4`'s key. The     *)
(* waiter is Hold.tla's and Delivery.tla's, its take of a row here one    *)
(* step; Delivery.tla's Answerable stores the reply of a headless         *)
(* session's turn, read from its Stream fold, which this spec leaves out. *)
(*                                                                         *)
(* Left abstract: the report's turn and the report (Delegate.tla's         *)
(* ReportAnswersTheBrief; here the report is taken once the first turn    *)
(* ended); a person's turn, which no message is in and which is not       *)
(* told; a resume after the process's end; restarts, since the reading is *)
(* of the transcript alone and each row goes in under its key once; the   *)
(* text of a reply, which is its line's place in the transcript.          *)
(*                                                                         *)
(* Break: "none" is the design. "NoReply" reads no reply to a message, as *)
(* before F-257: ReplyArrives fails. "OpenerOnly" judges a turn its own   *)
(* by its opener alone, as before F-257: a message queued into a turn of  *)
(* its own is told as that turn, and NotToldAsOwn fails. Each has a        *)
(* Break_Reply_<value>.cfg that TLC must fail.                            *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Msgs,      \* the parent's messages to the delegate, ids > 0
    MaxWakes,  \* turns a background command of its own begins
    Break      \* "none", "NoReply" or "OpenerOnly"

ASSUME Break \in {"none", "NoReply", "OpenerOnly"}
ASSUME Msgs \subseteq Nat \ {0} /\ MaxWakes \in Nat

VARIABLES
    log,      \* the transcript: a sequence of entries
    running,  \* a turn runs
    alive,    \* the process runs
    held,     \* a waiter is held: since the last turn's end, until it takes a row
    due,      \* the messages not yet handed to the waiter
    wakes,    \* turns a wake began
    rows      \* Mailbox's rows the reading stored: [key, kind, text]

vars == <<log, running, alive, held, due, wakes, rows>>

Open(by, m) == [k |-> "open", by |-> by, m |-> m]
Queued(m) == [k |-> "queued", by |-> "none", m |-> m]
ReplyLine == [k |-> "reply", by |-> "none", m |-> 0]

-----------------------------------------------------------------------------
(* The transcript's turns *)

Openers == {i \in 1..Len(log) : log[i].k = "open"}

\* The line after turn i's last: the next opener, or one past the end.
After(i) ==
    LET later == {j \in Openers : j > i}
    IN IF later = {} THEN Len(log) + 1
       ELSE CHOOSE j \in later : \A x \in later : j <= x

Lines(i) == i..(After(i) - 1)

Closed(i) == After(i) <= Len(log)

\* Ended: a later turn began, the session reads idle, or the process is gone.
Ended(i) == Closed(i) \/ ~running \/ ~alive

\* The messages whose marks are in turn i: its opener's and each queued one's.
Marks(i) == {log[j].m : j \in {x \in Lines(i) : log[x].k \in {"open", "queued"} /\ log[x].m # 0}}

\* What the reading takes as turn i's messages.
ReadMarks(i) == IF Break = "OpenerOnly" THEN {log[i].m} \ {0} ELSE Marks(i)

\* The uuid of turn i's reply: its line's place, or 0 for none.
ReplyOf(i) ==
    LET r == {j \in Lines(i) : log[j].k = "reply"}
    IN IF r = {} THEN 0 ELSE CHOOSE j \in r : \A x \in r : j >= x

Own(i) == log[i].by = "wake" /\ ReadMarks(i) = {}

\* The turns after the report's.
Later == Openers \ {1}

-----------------------------------------------------------------------------
(* Claude Code *)

\* A background command of its own ends: a turn begins, once the report's turn ended.
Wake ==
    /\ alive /\ ~running /\ wakes < MaxWakes
    /\ log' = Append(log, Open("wake", 0))
    /\ running' = TRUE /\ wakes' = wakes + 1
    /\ UNCHANGED <<alive, held, due, rows>>

\* The waiter takes message m: into an idle session it begins a turn; into a running turn (a
\* wake began it while the waiter was held) it is queued into that turn.
Take(m) ==
    /\ alive /\ held /\ m \in due
    /\ IF running
         THEN log' = Append(log, Queued(m)) /\ UNCHANGED running
         ELSE log' = Append(log, Open("msg", m)) /\ running' = TRUE
    /\ held' = FALSE /\ due' = due \ {m}
    /\ UNCHANGED <<alive, wakes, rows>>

\* The turn ends with its reply; the turn's end starts the next waiter.
TurnEnds ==
    /\ alive /\ running
    /\ log' = Append(log, ReplyLine)
    /\ running' = FALSE /\ held' = TRUE
    /\ UNCHANGED <<alive, due, wakes, rows>>

\* The process ends, in a turn or not; its waiter goes with it.
Exit ==
    /\ alive
    /\ alive' = FALSE /\ held' = FALSE
    /\ UNCHANGED <<log, running, due, wakes, rows>>

-----------------------------------------------------------------------------
(* The framework's reading, at any moment *)

\* What the reading stores now: each ended turn's answers to its messages, and each ended turn of
\* its own with a reply, under its reply's uuid.
Answers ==
    {[key |-> <<"msg", m>>, kind |-> "reply", text |-> ReplyOf(i)] :
        <<i, m>> \in {<<i, m>> \in Later \X Msgs :
                        Break # "NoReply" /\ Ended(i) /\ m \in ReadMarks(i) /\ ReplyOf(i) # 0}}
    \cup
    {[key |-> <<"msg", m>>, kind |-> "notice", text |-> 0] :
        <<i, m>> \in {<<i, m>> \in Later \X Msgs :
                        Break # "NoReply" /\ ~alive /\ ~Closed(i) /\ m \in ReadMarks(i)
                        /\ ReplyOf(i) = 0}}
    \cup
    {[key |-> <<"turn", ReplyOf(i)>>, kind |-> "own", text |-> ReplyOf(i)] :
        i \in {i \in Later : Ended(i) /\ Own(i) /\ ReplyOf(i) # 0}}

Keys == {r.key : r \in rows}

\* Mailbox's unique key: a row under a key stored before is not stored again.
Read ==
    /\ \E r \in Answers : r.key \notin Keys
    /\ rows' = rows \cup {r \in Answers : r.key \notin Keys}
    /\ UNCHANGED <<log, running, alive, held, due, wakes>>

-----------------------------------------------------------------------------

Init ==
    /\ log = <<Open("brief", 0)>>
    /\ running = TRUE /\ alive = TRUE /\ held = FALSE
    /\ due = Msgs /\ wakes = 0 /\ rows = {}

Next == Wake \/ (\E m \in Msgs : Take(m)) \/ TurnEnds \/ Exit \/ Read

Fairness == WF_vars(TurnEnds) /\ WF_vars(Read)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ running \in BOOLEAN /\ alive \in BOOLEAN /\ held \in BOOLEAN
    /\ due \subseteq Msgs /\ wakes \in 0..MaxWakes
    /\ \A r \in rows : r.kind \in {"reply", "notice", "own"}

\* The turn message m's mark is in, once it went in.
TurnOf(m) == CHOOSE i \in Openers : m \in Marks(i)

\* One row per message: a reply or the notice in its place, never both.
OneAnswer == \A m \in Msgs : Cardinality({r \in rows : r.key = <<"msg", m>>}) <= 1

\* A reply to m is the reply of the turn m went into.
ReplyIsItsTurns ==
    \A r \in rows : r.kind = "reply" =>
        \E m \in Msgs : r.key = <<"msg", m>> /\ m \notin due /\ r.text = ReplyOf(TurnOf(m))

\* A turn told as its own holds no message: its reply is never a message's reply told as a turn.
NotToldAsOwn ==
    \A r \in rows : r.kind = "own" =>
        \A i \in Openers : ReplyOf(i) = r.text => Marks(i) = {}

\* Each message that went in is answered: its reply, or the notice once the process ended first.
ReplyArrives == \A m \in Msgs : (m \notin due) ~> (\E r \in rows : r.key = <<"msg", m>>)

\* Each turn of its own with a reply, no message in it, is told.
OwnTold ==
    \A i \in 2..(2 * (Cardinality(Msgs) + MaxWakes) + 2) :
        (i \in Openers /\ log[i].by = "wake" /\ Marks(i) = {} /\ ReplyOf(i) # 0)
            ~> (\E r \in rows : r.key = <<"turn", ReplyOf(i)>>)

=============================================================================
