------------------------------ MODULE RemoteRun ------------------------------
(***************************************************************************)
(* A heavy command run on another host (F-296). An agent's `caf-run` asks *)
(* the plug, the plug runs the command there as a job (Jobs.run/6), under *)
(* that host's slot, streams the job's log back line by line and ends     *)
(* with the job's exit code. The host may go away at any step, the agent  *)
(* may interrupt its wrapper at any step, and the wrapper's stream may be *)
(* cut at any step.                                                        *)
(*                                                                         *)
(* Models CodingAgentFramework.Runs.Plug (the remote path: the run in a   *)
(* process of its own, the log read from an offset and sent as lines, the *)
(* end line only after the log's last line, the give-up once the host     *)
(* reads away for its bound, and the run's process ended when the wrapper  *)
(* is gone), CodingAgentFramework.Runs (the wrapper's `ended` line and its *)
(* exit codes), and CodingAgentFramework.Jobs (a caller's process that     *)
(* ends leaves the row owed; an owed row is settled from the host once it  *)
(* answers; the lease's holder is the row, released once it holds the     *)
(* job's end).                                                             *)
(*                                                                         *)
(* Alone, the spec has one other host with one slot and two runs on it.   *)
(* The placement, the lease and the start are one step (Grant): Host.tla  *)
(* checks the placement, HostSlots.tla the slot per host, and             *)
(* Schedule.tla's Fence shape a start that lands late. A job on the host  *)
(* runs on while the host is away from the workstation: away is a lost    *)
(* connection or a host asleep, not a host that ended its jobs.           *)
(*                                                                         *)
(* The exit the wrapper gives: the job's own code; "unknown" (69) once    *)
(* the host was away for the plug's bound or the stream was cut; "refused" *)
(* (75) when nothing ran; "killed" when the agent ended it (Ctrl-C).       *)
(*                                                                         *)
(* Fairness: the job ends (its exit or the host's timeout), the host comes *)
(* back, a deadline comes; the stream, the end, the give-up and the settle *)
(* each happen if they stay possible often enough. Going away, a cut and   *)
(* an interrupt get none.                                                  *)
(*                                                                         *)
(* Break: "none" is the design. Every other value changes one rule and has *)
(* a Break_RemoteRun_<value>.cfg that TLC must fail.                       *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Break   \* "none", or the rule changed (see Breaks)

Breaks == {
    "none",
    "FreeOnAway",     \* the give-up releases the slot while the job may still run on the host
    "KeepSlot",       \* the give-up leaves the row to nobody, so its slot is never freed
    "ReportSuccess",  \* the give-up exits 0, as if the job had passed
    "CodeBeforeLog"   \* the end line goes once the run answers, before the log's last lines
}

ASSUME Break \in Breaks

Runs == 1..2
Cap == 1
Lines == 2
Codes == {"0", "1"}
Outs == Codes \cup {"none", "unknown", "refused", "killed"}

VARIABLES
    w,      \* r -> "idle", "queued", "running" or "done": the wrapper and its ask
    out,    \* r -> the wrapper's exit (Outs), "none" until it exits
    job,    \* r -> "none", "live" or "ended": the job on the host
    code,   \* r -> the code the job exited with, or "none"
    wrote,  \* r -> the lines the job wrote to its log on the host
    sent,   \* r -> the lines the plug streamed to the wrapper
    row,    \* r -> Jobs' row: "none", "run" (its call watches), "owed" or "ended"
    lease,  \* r -> r's lease holds the host's slot
    up      \* the host answers the workstation

vars == <<w, out, job, code, wrote, sent, row, lease, up>>

-----------------------------------------------------------------------------

Held == Cardinality({r \in Runs : lease[r]})

Init ==
    /\ w = [r \in Runs |-> "idle"]
    /\ out = [r \in Runs |-> "none"]
    /\ job = [r \in Runs |-> "none"]
    /\ code = [r \in Runs |-> "none"]
    /\ wrote = [r \in Runs |-> 0]
    /\ sent = [r \in Runs |-> 0]
    /\ row = [r \in Runs |-> "none"]
    /\ lease = [r \in Runs |-> FALSE]
    /\ up = TRUE

\* The wrapper asks. A host away refuses the placement at once: nothing ran (75).
Ask(r) ==
    /\ w[r] = "idle"
    /\ IF up
         THEN w' = [w EXCEPT ![r] = "queued"] /\ UNCHANGED out
         ELSE w' = [w EXCEPT ![r] = "done"] /\ out' = [out EXCEPT ![r] = "refused"]
    /\ UNCHANGED <<job, code, wrote, sent, row, lease, up>>

\* Placed, leased and started in one step: the row is the lease's holder.
Grant(r) ==
    /\ w[r] = "queued"
    /\ up
    /\ Held < Cap
    /\ w' = [w EXCEPT ![r] = "running"]
    /\ lease' = [lease EXCEPT ![r] = TRUE]
    /\ row' = [row EXCEPT ![r] = "run"]
    /\ job' = [job EXCEPT ![r] = "live"]
    /\ UNCHANGED <<out, code, wrote, sent, up>>

\* A queued ask ends at its wait: refused, nothing ran.
Expire(r) ==
    /\ w[r] = "queued"
    /\ w' = [w EXCEPT ![r] = "done"]
    /\ out' = [out EXCEPT ![r] = "refused"]
    /\ UNCHANGED <<job, code, wrote, sent, row, lease, up>>

\* The job writes a line on the host, whether or not the host answers the workstation.
Write(r) ==
    /\ job[r] = "live"
    /\ wrote[r] < Lines
    /\ wrote' = [wrote EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<w, out, job, code, sent, row, lease, up>>

\* The job exits on the host with a code.
Exit(r) ==
    /\ job[r] = "live"
    /\ \E c \in Codes : code' = [code EXCEPT ![r] = c]
    /\ job' = [job EXCEPT ![r] = "ended"]
    /\ UNCHANGED <<w, out, wrote, sent, row, lease, up>>

\* The plug reads one more line of the log and sends it.
Stream(r) ==
    /\ w[r] = "running"
    /\ up
    /\ sent[r] < wrote[r]
    /\ sent' = [sent EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<w, out, job, code, wrote, row, lease, up>>

\* The run answers the job's end, which its call writes to the row; the plug sends the end line
\* once the log is read to its end, and the wrapper exits with the job's code.
Finish(r) ==
    /\ w[r] = "running"
    /\ up
    /\ job[r] = "ended"
    /\ sent[r] = wrote[r] \/ Break = "CodeBeforeLog"
    /\ w' = [w EXCEPT ![r] = "done"]
    /\ out' = [out EXCEPT ![r] = code[r]]
    /\ row' = [row EXCEPT ![r] = "ended"]
    /\ UNCHANGED <<job, code, wrote, sent, lease, up>>

\* The host read away for the plug's bound: the plug ends the run's process, which leaves the
\* row owed, and the wrapper exits 69.
GiveUp(r) ==
    /\ w[r] = "running"
    /\ ~up
    /\ w' = [w EXCEPT ![r] = "done"]
    /\ out' = [out EXCEPT ![r] = IF Break = "ReportSuccess" THEN "0" ELSE "unknown"]
    /\ row' = [row EXCEPT ![r] = CASE Break = "FreeOnAway" -> "ended"
                                   [] Break = "KeepSlot" -> "run"
                                   [] OTHER -> "owed"]
    /\ UNCHANGED <<job, code, wrote, sent, lease, up>>

\* The wrapper's stream is cut (the framework restarted, the ask's bound passed): the run's
\* process is gone, the row owed, and the wrapper exits 69, never running the command again.
Cut(r) ==
    /\ w[r] = "running"
    /\ w' = [w EXCEPT ![r] = "done"]
    /\ out' = [out EXCEPT ![r] = "unknown"]
    /\ row' = [row EXCEPT ![r] = "owed"]
    /\ UNCHANGED <<job, code, wrote, sent, lease, up>>

\* The agent's Ctrl-C ends the wrapper. Queued, its ask leaves the queue; running, the plug's
\* next write fails, it ends the run's process, and the job runs on to its own end, owed.
Interrupt(r) ==
    /\ w[r] \in {"queued", "running"}
    /\ w' = [w EXCEPT ![r] = "done"]
    /\ out' = [out EXCEPT ![r] = "killed"]
    /\ row' = [row EXCEPT ![r] = IF w[r] = "running" THEN "owed" ELSE @]
    /\ UNCHANGED <<job, code, wrote, sent, lease, up>>

\* Jobs settles an owed row from the host once it answers and the job has ended.
Settle(r) ==
    /\ row[r] = "owed"
    /\ up
    /\ job[r] = "ended"
    /\ row' = [row EXCEPT ![r] = "ended"]
    /\ UNCHANGED <<w, out, job, code, wrote, sent, lease, up>>

\* The Scheduler reads the row's end and releases the lease.
Release(r) ==
    /\ lease[r]
    /\ row[r] = "ended"
    /\ lease' = [lease EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<w, out, job, code, wrote, sent, row, up>>

Go ==
    /\ up
    /\ up' = FALSE
    /\ UNCHANGED <<w, out, job, code, wrote, sent, row, lease>>

Back ==
    /\ ~up
    /\ up' = TRUE
    /\ UNCHANGED <<w, out, job, code, wrote, sent, row, lease>>

Next ==
    \/ \E r \in Runs :
        \/ Ask(r) \/ Grant(r) \/ Expire(r) \/ Write(r) \/ Exit(r) \/ Stream(r)
        \/ Finish(r) \/ GiveUp(r) \/ Cut(r) \/ Interrupt(r) \/ Settle(r) \/ Release(r)
    \/ Go \/ Back

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(Back)
    /\ \A r \in Runs :
        /\ WF_vars(Expire(r)) /\ WF_vars(Exit(r)) /\ WF_vars(Release(r))
        /\ SF_vars(Stream(r)) /\ SF_vars(Finish(r)) /\ SF_vars(GiveUp(r)) /\ SF_vars(Settle(r))

-----------------------------------------------------------------------------

TypeOK ==
    /\ w \in [Runs -> {"idle", "queued", "running", "done"}]
    /\ out \in [Runs -> Outs]
    /\ job \in [Runs -> {"none", "live", "ended"}]
    /\ code \in [Runs -> Codes \cup {"none"}]
    /\ wrote \in [Runs -> 0..Lines]
    /\ sent \in [Runs -> 0..Lines]
    /\ row \in [Runs -> {"none", "run", "owed", "ended"}]
    /\ lease \in [Runs -> BOOLEAN]
    /\ up \in BOOLEAN

\* The jobs running on the host never pass its slots, a host away or not.
HostCapacity == Cardinality({r \in Runs : job[r] = "live"}) <= Cap

\* A job runs on the host only under its unreleased lease.
NoRunUnleased == \A r \in Runs : job[r] = "live" => lease[r]

\* A wrapper exits with a code only when the job exited with that code.
TrueCode == \A r \in Runs : out[r] \in Codes => job[r] = "ended" /\ code[r] = out[r]

\* A wrapper exits with the job's code only once every line of the log reached it.
WholeStream == \A r \in Runs : out[r] \in Codes => sent[r] = wrote[r]

\* Every wrapper exits.
WrapperEnds == \A r \in Runs : w[r] \in {"queued", "running"} ~> w[r] = "done"

\* Every slot is freed, a host away, a cut or an interrupt included: once the job's end is read.
SlotFreed == \A r \in Runs : lease[r] ~> ~lease[r]

=============================================================================
