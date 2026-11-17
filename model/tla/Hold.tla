-------------------------------- MODULE Hold --------------------------------
(***************************************************************************)
(* A request held open with a deadline. The requester opens it and waits;  *)
(* the holder keeps the request open (in memory) and its row (durable).    *)
(* A decision meant for one request takes only the hold it names, and its  *)
(* row says "deciding" before anything goes out. The holder hands the      *)
(* request exactly one response: the decision, then the row says answered; *)
(* or an empty one, at its own deadline (before the requester's timeout)   *)
(* or for a pass. A decision after that is dropped. A request whose holder *)
(* dies, or that a restart cuts, closes with no response; its row then     *)
(* settles: a held one is lost, and a deciding one unknown, since its      *)
(* decision may have gone out.                                             *)
(*                                                                         *)
(* Models the one structure of Intake's holds (R5). Intake.tla instances   *)
(* it for PermissionRequest (the decider an agent's or a person's answer,  *)
(* which names the dialog) and for PreToolUse (the decider the app's       *)
(* callback); the Stop and waiter kinds come with their code. Each         *)
(* instancing spec says who opens a request, what the requester reads of   *)
(* each response, and when its holder is up.                               *)
(*                                                                         *)
(* Alone, the spec has two requests, a decider that answers any request it *)
(* saw or never answers, holders that die at any step, and restarts.       *)
(*                                                                         *)
(* Left abstract: time (the deadline is a step the holder takes while the  *)
(* request is held); what a decision says (allow, deny, a label are one    *)
(* "decision"); the requester's own timeout, which the deadline comes      *)
(* before.                                                                 *)
(*                                                                         *)
(* Fairness, alone: the holder's steps happen while they stay possible.    *)
(* Requesters, deciders, holders' deaths and restarts happen or not.       *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Hold_<value>.cfg that TLC must fail.                        *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Reqs,   \* the requests, by id
    Break   \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "NotNamed",      \* a decision takes whichever hold is held, not the one it names
    "NoDeadline",    \* the holder never answers a request no one decides
    "TwoResponses",  \* the deadline fires on a request already answered
    "LateSent",      \* a decision after the deadline is still handed out
    "TrustDeciding"  \* after a cut, a row still deciding is taken as answered
}

ASSUME Break \in Breaks

Rows == {"none", "held", "deciding", "answered", "expired", "passed", "lost", "unknown"}
Settled == {"answered", "expired", "passed", "lost", "unknown"}

VARIABLES
    conn,     \* in memory: r -> the holder holds r's request open
    row,      \* the table: r -> its row, one of Rows
    marking,  \* in memory: the requests whose decision went out, the row not yet marked
    out,      \* ghost: r -> the responses handed to r's request, in order: "decision" or "empty"
    wrong     \* ghost: decisions that took a hold other than the one they named: [meant, got]

holdVars == <<conn, row, marking, out, wrong>>

-----------------------------------------------------------------------------
(* The steps an instancing spec takes, each with its own guards and effects *)

\* The requester posts r; the holder holds it open when it is up (`ok`).
Opens(r, ok) ==
    /\ conn' = [conn EXCEPT ![r] = ok]
    /\ UNCHANGED <<row, marking, out, wrong>>

\* The holder writes r's row, and starts its deadline.
Held(r) ==
    /\ conn[r] /\ row[r] = "none"
    /\ row' = [row EXCEPT ![r] = "held"]
    /\ UNCHANGED <<conn, marking, out, wrong>>

\* A decision meant for m takes hold h: the one it names, while held. Under
\* NotNamed it takes another that is held, when m's is not. Under LateSent
\* it takes m's after the deadline.
Asked(m, h) ==
    /\ \/ row[h] = "held" /\ (h = m \/ (Break = "NotNamed" /\ row[m] # "held"))
       \/ Break = "LateSent" /\ h = m /\ row[h] = "expired"
    /\ row' = [row EXCEPT ![h] = "deciding"]
    /\ wrong' = IF h # m THEN wrong \cup {[meant |-> m, got |-> h]} ELSE wrong
    /\ UNCHANGED <<conn, marking, out>>

\* The decision is the response to r's request, which closes; the row is
\* marked after (Marked). Under LateSent it goes to a request already closed.
Decides(r) ==
    /\ row[r] = "deciding" /\ r \notin marking
    /\ conn[r] \/ Break = "LateSent"
    /\ out' = [out EXCEPT ![r] = Append(@, "decision")]
    /\ conn' = [conn EXCEPT ![r] = FALSE]
    /\ marking' = marking \cup {r}
    /\ UNCHANGED <<row, wrong>>

Marked(r) ==
    /\ r \in marking
    /\ marking' = marking \ {r}
    /\ row' = [row EXCEPT ![r] = "answered"]
    /\ UNCHANGED <<conn, out, wrong>>

\* An empty response to a held request, which closes, and the row's end.
\* Under TwoResponses it goes to a request already answered.
Empty(r, end) ==
    /\ \/ row[r] = "held" /\ conn[r]
       \/ Break = "TwoResponses" /\ row[r] \notin {"none", "held"} /\ Len(out[r]) = 1
    /\ out' = [out EXCEPT ![r] = Append(@, "empty")]
    /\ conn' = [conn EXCEPT ![r] = FALSE]
    /\ row' = [row EXCEPT ![r] = IF row[r] = "held" THEN end ELSE row[r]]
    /\ UNCHANGED <<marking, wrong>>

\* The holder's own deadline, before the requester's timeout.
Expires(r) == Break # "NoDeadline" /\ Empty(r, "expired")

\* The decider passes: an empty response, like the deadline's.
Passed(r) == Empty(r, "passed")

\* The holders of the requests in R die (a restart: all of them): each
\* request closes with no response, and the requester reads an error.
Cut(R) ==
    /\ conn' = [r \in DOMAIN conn |-> IF r \in R THEN FALSE ELSE conn[r]]
    /\ marking' = marking \ R
    /\ UNCHANGED <<row, out, wrong>>

\* A row whose request was cut: held is lost, deciding unknown. Under
\* TrustDeciding deciding is taken as answered.
Settles(r) ==
    /\ row[r] \in {"held", "deciding"} /\ ~conn[r] /\ r \notin marking
    /\ row' = [row EXCEPT ![r] = IF row[r] = "held" THEN "lost"
                                 ELSE IF Break = "TrustDeciding" THEN "answered"
                                 ELSE "unknown"]
    /\ UNCHANGED <<conn, marking, out, wrong>>

-----------------------------------------------------------------------------
(* Alone *)

Init ==
    /\ conn = [r \in Reqs |-> FALSE]
    /\ row = [r \in Reqs |-> "none"]
    /\ marking = {}
    /\ out = [r \in Reqs |-> <<>>]
    /\ wrong = {}

\* Each request is posted once.
Posts(r) == row[r] = "none" /\ ~conn[r] /\ out[r] = <<>> /\ Opens(r, TRUE)

Next ==
    \/ \E r \in Reqs : Posts(r) \/ Held(r) \/ Decides(r) \/ Marked(r) \/ Expires(r)
                       \/ Passed(r) \/ Settles(r) \/ Cut({r})
    \/ \E m, h \in Reqs : Asked(m, h)
    \/ Cut(Reqs)

Fairness ==
    \A r \in Reqs : /\ WF_holdVars(Held(r)) /\ WF_holdVars(Decides(r))
                    /\ WF_holdVars(Marked(r)) /\ WF_holdVars(Expires(r))
                    /\ WF_holdVars(Settles(r))

Spec == Init /\ [][Next]_holdVars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ conn \in [Reqs -> BOOLEAN] /\ row \in [Reqs -> Rows] /\ marking \subseteq Reqs
    /\ \A r \in Reqs : \A i \in 1..Len(out[r]) : out[r][i] \in {"decision", "empty"}
    /\ wrong \subseteq [meant : Reqs, got : Reqs]

\* The holder hands each request one response.
OneResponse == \A r \in Reqs : Len(out[r]) <= 1

\* A decision goes out only as the first response: a late one is dropped.
LateDropped == \A r \in Reqs : \A i \in 1..Len(out[r]) : out[r][i] = "decision" => i = 1

\* A decision takes only the hold it names.
OnlyNamed == wrong = {}

\* A row says answered only when its decision went out.
AnsweredWasSent ==
    \A r \in Reqs : row[r] = "answered" => \E i \in 1..Len(out[r]) : out[r][i] = "decision"

\* Every open request closes, and every held row settles.
RequestsEnd ==
    \A r \in Reqs : /\ conn[r] ~> ~conn[r]
                    /\ row[r] \in {"held", "deciding"} ~> row[r] \in Settled

=============================================================================
