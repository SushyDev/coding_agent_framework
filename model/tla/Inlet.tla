------------------------------- MODULE Inlet -------------------------------
(***************************************************************************)
(* The Inlet's queue (F-249). One Inlet runs the writes and presses on one *)
(* host, one at a time. Each call carries its deadline, an absolute time   *)
(* on the instance's clock, and each kind of call has its own bound: the   *)
(* longest it runs once started. A call starts only while its bound still  *)
(* fits before its deadline. A call still queued when that last start      *)
(* time comes is answered busy at once, while another call runs, and      *)
(* never starts later. A call that has started runs to its own bound, so   *)
(* it ends by its deadline. Either way the caller has its answer by its    *)
(* deadline, and it waits that long and a margin, so it never gives up     *)
(* first.                                                                  *)
(*                                                                         *)
(* Models CodingAgentFramework.Inlet (its call wrapper, which sets the     *)
(* deadline and waits it and a margin; its queue, its timer for each       *)
(* queued call's last start, and its run of one call at a time in a task)  *)
(* and the callers that pass a deadline: CodingAgentFramework.Sessions (a  *)
(* press's `timeout:`, `press_wait/1`) and CodingAgentFramework.Mailbox    *)
(* (a typed write).                                                        *)
(*                                                                         *)
(* Alone, the spec has callers that each call once, at any time, and a     *)
(* clock that ticks while nothing in the Inlet is due. A call's run ends   *)
(* at any time up to its bound, as a press ends as soon as each read sees  *)
(* its keys.                                                               *)
(*                                                                         *)
(* Left abstract: what a call does to the screen (Dialog.tla's Press,      *)
(* Delivery.tla's typed), and its outcome other than busy. A caller that   *)
(* dies. `press_bound/1`, which the Inlet's own process answers outside    *)
(* the queue and so never waits in it. The margin is one tick of the       *)
(* clock: the reply's way back to the caller.                              *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Inlet_<value>.cfg that TLC must fail.                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences, TLC

CONSTANTS
    Callers,  \* the callers into one Inlet, each with one call
    Bound,    \* c -> the ticks c's call runs at most once started
    Timeout,  \* c -> the ticks from c's call to its deadline
    MaxTime,  \* the clock stops here, to keep the state space finite
    Break     \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "StartLate",  \* a call starts when its turn comes, whatever its deadline
    "InProcess"   \* the Inlet runs a call in its own process: it answers nothing while one runs
}

ASSUME Break \in Breaks
ASSUME \A c \in Callers : Bound[c] \in Nat \ {0} /\ Timeout[c] \in Nat

\* idle: not called yet
\* queued: called, waiting for its turn
\* running: started; the screen may change
\* done: ran, and answered with its outcome
\* busy: answered busy; it never ran
States == {"idle", "queued", "running", "done", "busy"}

VARIABLES
    now,       \* the instance's clock
    pc,        \* c -> where c's call is, one of States
    deadline,  \* c -> c's deadline, set as it calls
    started,   \* c -> when c's call started, once it has
    queue      \* the calls waiting, oldest first

vars == <<now, pc, deadline, started, queue>>

Running == {c \in Callers : pc[c] = "running"}

\* The last time c's call may start and still end by its deadline.
LastStart(c) == deadline[c] - Bound[c]

-----------------------------------------------------------------------------

Init ==
    /\ now = 0
    /\ pc = [c \in Callers |-> "idle"]
    /\ deadline = [c \in Callers |-> 0]
    /\ started = [c \in Callers |-> 0]
    /\ queue = <<>>

\* The call wrapper sets the deadline from the caller's timeout, and the
\* Inlet queues the call.
Call(c) ==
    /\ pc[c] = "idle"
    /\ pc' = [pc EXCEPT ![c] = "queued"]
    /\ deadline' = [deadline EXCEPT ![c] = now + Timeout[c]]
    /\ queue' = Append(queue, c)
    /\ UNCHANGED <<now, started>>

\* The oldest call's turn: it starts while its bound fits before its deadline.
Start ==
    /\ queue # <<>>
    /\ Running = {}
    /\ LET c == Head(queue) IN
        /\ Break = "StartLate" \/ now + Bound[c] <= deadline[c]
        /\ pc' = [pc EXCEPT ![c] = "running"]
        /\ started' = [started EXCEPT ![c] = now]
        /\ queue' = Tail(queue)
    /\ UNCHANGED <<now, deadline>>

\* A queued call whose bound no longer fits: answered busy at once, without
\* touching the screen, by the Inlet's timer or at its turn. Under InProcess
\* the Inlet's process is in the running call, and answers only after it.
Busy(c) ==
    /\ Break # "StartLate"
    /\ pc[c] = "queued"
    /\ now >= LastStart(c)
    /\ Break = "InProcess" => Running = {}
    /\ pc' = [pc EXCEPT ![c] = "busy"]
    /\ queue' = SelectSeq(queue, LAMBDA x : x # c)
    /\ UNCHANGED <<now, deadline, started>>

\* The running call ends, at any time up to its bound, and answers.
Finish(c) ==
    /\ pc[c] = "running"
    /\ now > started[c]
    /\ pc' = [pc EXCEPT ![c] = "done"]
    /\ UNCHANGED <<now, deadline, started, queue>>

\* What the Inlet must do now, before the clock moves on.
Due ==
    \/ \E c \in Running : now >= started[c] + Bound[c]
    \/ Running = {} /\ queue # <<>>
    \/ \E c \in Callers : ENABLED Busy(c)

Tick ==
    /\ now < MaxTime
    /\ ~Due
    /\ now' = now + 1
    /\ UNCHANGED <<pc, deadline, started, queue>>

Next ==
    \/ \E c \in Callers : Call(c) \/ Busy(c) \/ Finish(c)
    \/ Start
    \/ Tick

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ now \in 0..MaxTime
    /\ pc \in [Callers -> States]
    /\ deadline \in [Callers -> Nat]
    /\ started \in [Callers -> Nat]
    /\ queue \in Seq(Callers)

\* The Inlet runs one call at a time.
OneAtATime == \A a, b \in Running : a = b

\* A call starts only while its bound fits before its deadline.
StartsInTime ==
    \A c \in Callers : pc[c] \in {"running", "done"} => started[c] + Bound[c] <= deadline[c]

\* No caller is still waiting past its deadline: its answer, busy or the run's,
\* came by then, and it waits the deadline and a margin.
AnsweredByDeadline ==
    \A c \in Callers : pc[c] \in {"queued", "running"} => now <= deadline[c]

\* The configurations' callers: a long call and a short one, each with a
\* timeout one tick over its bound, or two over.
LongShort == ("long" :> 4) @@ ("short" :> 2)
Tight == ("long" :> 5) @@ ("short" :> 3)
Loose == ("long" :> 6) @@ ("short" :> 4)

=============================================================================
