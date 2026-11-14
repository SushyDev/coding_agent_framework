------------------------------- MODULE Agent -------------------------------
(***************************************************************************)
(* One host's agents: its tmux server, the panes on it, the dtach sockets  *)
(* that hold Claude Code processes, the viewers that show them, and the    *)
(* writes the framework sends to a pane.                                   *)
(*                                                                         *)
(* Models these modules of CodingAgentFramework:                           *)
(*   Tmux        the server, its panes, their tags, and the write that     *)
(*               checks a pane's tag and sends in one tmux command         *)
(*               (Tmux.CLI.write/4, built in unit 2);                      *)
(*   Holder      dtach: a process held on a socket, a viewer of it, a      *)
(*               stale socket and its cleaning (built in unit 2);          *)
(*   Control     the one writer per host: a write names a session and a    *)
(*               pane id kept from earlier, and goes out only to that      *)
(*               session's pane (built in unit 3). Its stop and respawn    *)
(*               of a pane go through the same one-command check, and are  *)
(*               writes here;                                              *)
(*   TmuxSampler reads the panes and the held sockets, and reports a held  *)
(*               agent with no viewer (built in F-22). A reading names a   *)
(*               new loss as SamplerReads says; the code keys a loss by    *)
(*               the sampler's generation and the sample at which the row  *)
(*               became unviewed, or Recoveries' last open, if later;      *)
(*   Recoveries  claims a seen loss in its table, then reopens the agent's *)
(*               viewer, once per loss across its own restarts, and with   *)
(*               it starts the server again when it is down (F-23).        *)
(*                                                                         *)
(* A restart of Recoveries between its claim and its act leaves that loss  *)
(* claimed and not acted on: it ends unknown, for a person, and is never   *)
(* acted on again. So LostViewerReopened is checked with no such restart   *)
(* (Agent_Viewers), and OneReopenPerLoss with one (Agent_Claims).          *)
(*                                                                         *)
(* Left abstract: the text of a write and the screen (whether the input    *)
(* box is empty); hooks and the registry; the process check for an         *)
(* untagged pane (every pane here is tagged as it opens); more than one    *)
(* server, host or tmux client; the viewer's size; the unknown outcome of  *)
(* a key that reached nothing. A session is an agent: its socket and its   *)
(* tmux session are both named by its session id.                          *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Agent_<value>.cfg that TLC must fail.                       *)
(*                                                                         *)
(* Defense in depth, with no Break: the refusal of an empty target in      *)
(* Passes. The tag check refuses any pane but the session's own, so the    *)
(* refusal cannot fail on its own; it gives the write a named reason.      *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Agents,           \* session ids; each names its socket and its tmux session
    MaxStarts,        \* processes started over the whole behavior
    MaxServerDeaths,  \* times the tmux server dies
    MaxViewerDeaths,  \* times a viewer pane dies on its own
    MaxWrites,        \* writes asked
    MaxRecoveryRestarts, \* times Recoveries restarts, losing what it held in memory
    Break             \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "NoPaneCheck",          \* a write goes to its kept pane id without checking the tag
    "CheckThenSend",        \* the tag check and the send are two tmux commands
    "CleanLiveSocket",      \* starting an agent removes a socket file that is still live
    "TmuxHoldsAgent",       \* the agent runs in its pane, not under dtach
    "NoReopen",             \* a lost viewer is never reopened
    "SamplerReadsPanesOnly", \* the sampler reads tmux's panes but not the held sockets
    "ClaimInMemory"         \* Recoveries keeps its claims in memory, not in its table
}

ASSUME Break \in Breaks
ASSUME MaxStarts \in Nat /\ MaxServerDeaths \in Nat /\ MaxViewerDeaths \in Nat
ASSUME MaxWrites \in Nat /\ MaxRecoveryRestarts \in Nat

\* A lookup that found no pane yields an empty target. tmux reads an empty
\* target as its current pane, so it is a value of its own, never a pane id.
EmptyTarget == -1

\* A socket path with no file at it.
NoFile == 0

VARIABLES
    serverUp,      \* the framework's tmux server is running
    epoch,         \* how many times the server has started again; ids restart each time
    nextPane,      \* the id tmux gives the next pane, %<nextPane>
    panes,         \* pane id -> the session its tag names (a viewer of that agent)
    procs,         \* running held processes: [pid, socket]
    nextPid,       \* processes started so far; also the last pid given
    socketFile,    \* socket -> the pid that bound the file at its path, or NoFile
    unviewed,      \* the sampler's last reading: held agents with no viewer
    opened,        \* agents Recoveries opened a viewer for since the last reading
    claimed,       \* Recoveries' table: agents whose current loss it has claimed
    acting,        \* claims Recoveries holds in memory and has not acted on yet:
                   \* [agent, old], old once the sampler has read a newer loss
    reopened,      \* history: agents a viewer was opened for in their current loss
    twice,         \* history: a viewer was opened twice for one loss
    recoveryRestarts,
    kept,          \* session -> the pane id a caller kept, and the epoch it was read in
    pending,       \* writes checked but not yet sent (only under CheckThenSend)
    delivered,     \* writes that reached a pane: [session, reached, keptEpoch, epoch]
    serverDeaths, viewerDeaths, writesAsked

\* Recoveries' variables, unchanged by the other steps.
rec == <<opened, claimed, acting, reopened, twice, recoveryRestarts>>

vars == <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, unviewed,
          kept, pending, delivered, serverDeaths, viewerDeaths, writesAsked, rec>>

-----------------------------------------------------------------------------
(* Reading the state *)

\* The agent a held process runs is the one its socket is named for.
Held(a) == \E p \in procs : p.socket = a

\* A socket answers a connection when the process that bound it still runs.
SocketLive(a) == socketFile[a] # NoFile /\ \E p \in procs : p.pid = socketFile[a]
SocketStale(a) == socketFile[a] # NoFile /\ ~SocketLive(a)

HasViewer(a) == \E id \in DOMAIN panes : panes[id] = a

PanesShowing(a) == {id \in DOMAIN panes : panes[id] = a}

\* A function with one more or fewer entries.
With(f, k, v) == [x \in DOMAIN f \cup {k} |-> IF x = k THEN v ELSE f[x]]
Without(f, S) == [x \in DOMAIN f \ S |-> f[x]]

NoPanes == [id \in {} |-> CHOOSE a \in Agents : TRUE]

-----------------------------------------------------------------------------
Init ==
    /\ serverUp = TRUE
    /\ epoch = 0
    /\ nextPane = 0
    /\ panes = NoPanes
    /\ procs = {}
    /\ nextPid = 0
    /\ socketFile = [a \in Agents |-> NoFile]
    /\ unviewed = {}
    /\ opened = {}
    /\ claimed = {}
    /\ acting = {}
    /\ reopened = {}
    /\ twice = FALSE
    /\ recoveryRestarts = 0
    \* Before any lookup the caller holds nothing: an empty target.
    /\ kept = [a \in Agents |-> [pane |-> EmptyTarget, epoch |-> 0]]
    /\ pending = {}
    /\ delivered = {}
    /\ serverDeaths = 0
    /\ viewerDeaths = 0
    /\ writesAsked = 0

-----------------------------------------------------------------------------
(* The tmux server *)

\* The server ends, and every pane with it. Held agents run on: dtach holds
\* them apart from tmux. Under TmuxHoldsAgent they ran in their panes and end
\* too, leaving no socket.
ServerDies ==
    /\ serverUp
    /\ serverDeaths < MaxServerDeaths
    /\ serverUp' = FALSE
    /\ panes' = NoPanes
    /\ serverDeaths' = serverDeaths + 1
    /\ IF Break = "TmuxHoldsAgent"
         THEN /\ procs' = {}
              /\ socketFile' = [a \in Agents |-> NoFile]
         ELSE UNCHANGED <<procs, socketFile>>
    /\ UNCHANGED <<epoch, nextPane, nextPid, unviewed, kept, pending, delivered,
                   viewerDeaths, writesAsked, rec>>

\* Another part starts the server again (a start opening its viewer); a
\* reopen in RecoveryActs does too. A new server counts pane ids from %0, so an
\* id read before this step may name another pane after it.
ServerRestarts ==
    /\ ~serverUp
    /\ serverUp' = TRUE
    /\ epoch' = epoch + 1
    /\ nextPane' = 0
    /\ UNCHANGED <<panes, procs, nextPid, socketFile, unviewed, kept, pending,
                   delivered, serverDeaths, viewerDeaths, writesAsked, rec>>

-----------------------------------------------------------------------------
(* Held agents (dtach) *)

\* `hold`: start a's process under dtach on a's socket. A socket file whose
\* process is gone (stale) is removed first; a live one refuses the start, so
\* no two processes ever hold one socket. Under CleanLiveSocket the live file
\* is removed too, and a second process binds the path.
AgentStarted(a) ==
    /\ nextPid < MaxStarts
    /\ \/ socketFile[a] = NoFile
       \/ SocketStale(a)
       \/ Break = "CleanLiveSocket" /\ SocketLive(a)
    /\ nextPid' = nextPid + 1
    /\ procs' = procs \cup {[pid |-> nextPid + 1, socket |-> a]}
    /\ socketFile' = [socketFile EXCEPT ![a] = nextPid + 1]
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, unviewed, kept, pending,
                   delivered, serverDeaths, viewerDeaths, writesAsked, rec>>

\* A process ends with no other on its socket: its viewers' `dtach -a` see the
\* socket close and exit, and their panes close.
ViewersAfter(p) ==
    IF \E q \in procs : q # p /\ q.socket = p.socket
      THEN panes
      ELSE Without(panes, PanesShowing(p.socket))

\* The agent ends: its own /exit, or a hang-up of its pid. dtach removes the
\* socket file it bound.
AgentExits(p) ==
    /\ procs' = procs \ {p}
    /\ socketFile' = IF socketFile[p.socket] = p.pid
                       THEN [socketFile EXCEPT ![p.socket] = NoFile]
                       ELSE socketFile
    /\ panes' = ViewersAfter(p)
    /\ UNCHANGED <<serverUp, epoch, nextPane, nextPid, unviewed, kept, pending,
                   delivered, serverDeaths, viewerDeaths, writesAsked, rec>>

\* The dtach holding the agent is killed hard: the process is gone, but the
\* socket file stays at its path, refusing connections.
SocketGoesStale(p) ==
    /\ procs' = procs \ {p}
    /\ panes' = ViewersAfter(p)
    /\ UNCHANGED <<serverUp, epoch, nextPane, nextPid, socketFile, unviewed, kept,
                   pending, delivered, serverDeaths, viewerDeaths, writesAsked, rec>>

-----------------------------------------------------------------------------
(* Viewers *)

\* A viewer pane dies on its own (its window is closed, its client killed).
\* The agent it showed runs on.
ViewerDies(id) ==
    /\ viewerDeaths < MaxViewerDeaths
    /\ panes' = Without(panes, {id})
    /\ viewerDeaths' = viewerDeaths + 1
    /\ UNCHANGED <<serverUp, epoch, nextPane, procs, nextPid, socketFile, unviewed,
                   kept, pending, delivered, serverDeaths, writesAsked, rec>>

\* The sampler reads which held agents have no viewer. It must read the held
\* sockets as well as tmux's panes: an agent whose viewer is gone has no pane
\* left to read. Under SamplerReadsPanesOnly it sees only agents with a pane.
\*
\* A reading names a new loss for an agent that was not unviewed in the last
\* reading, or that Recoveries opened a viewer for since: that viewer is gone
\* again. A new loss is not claimed yet, and no viewer was opened for it.
SamplerReads ==
    LET visible == IF Break = "SamplerReadsPanesOnly"
                     THEN {panes[id] : id \in DOMAIN panes}
                     ELSE Agents
        \* The join calls a held socket unviewed only while it is live.
        now == {a \in visible : Held(a) /\ SocketLive(a) /\ ~HasViewer(a)}
        new == {a \in now : a \notin unviewed \/ a \in opened}
    IN  /\ unviewed' = now
        /\ opened' = {}
        /\ claimed' = claimed \ new
        /\ reopened' = reopened \ new
        /\ acting' = {[agent |-> c.agent, old |-> c.old \/ c.agent \in new] : c \in acting}
        /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile,
                       kept, pending, delivered, serverDeaths, viewerDeaths, writesAsked,
                       twice, recoveryRestarts>>

\* Recoveries writes a claim on the loss it read before it acts, and only on a
\* loss not claimed yet, read after its own last open of that agent's viewer.
RecoveryClaims(a) ==
    /\ Break # "NoReopen"
    /\ a \in unviewed
    /\ a \notin opened
    /\ a \notin claimed
    /\ claimed' = claimed \cup {a}
    /\ acting' = acting \cup {[agent |-> a, old |-> FALSE]}
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, unviewed,
                   kept, pending, delivered, serverDeaths, viewerDeaths, writesAsked,
                   opened, reopened, twice, recoveryRestarts>>

\* Recoveries opens the claimed agent's viewer: `tmux new-session` named by the
\* agent, its pane tagged as it opens, running `dtach -a`. It starts the server
\* when it is down, so the new pane is %0 of a new server. tmux refuses a
\* second session of that name. On a socket that is no longer live, `dtach -a`
\* exits at once and its pane closes. The outcome is read from a later sample.
RecoveryActs(c) ==
    LET a == c.agent IN
    /\ c \in acting
    /\ acting' = acting \ {c}
    /\ IF HasViewer(a)
         THEN UNCHANGED <<serverUp, epoch, nextPane, panes, opened, reopened, twice>>
         ELSE /\ opened' = opened \cup {a}
              /\ IF c.old
                   THEN UNCHANGED <<reopened, twice>>
                   ELSE /\ twice' = (twice \/ a \in reopened)
                        /\ reopened' = reopened \cup {a}
              /\ IF ~SocketLive(a)
                   THEN UNCHANGED <<serverUp, epoch, nextPane, panes>>
                 ELSE IF serverUp
                   THEN /\ panes' = With(panes, nextPane, a)
                        /\ nextPane' = nextPane + 1
                        /\ UNCHANGED <<serverUp, epoch>>
                   ELSE /\ serverUp' = TRUE
                        /\ epoch' = epoch + 1
                        /\ panes' = With(panes, 0, a)
                        /\ nextPane' = 1
    /\ UNCHANGED <<procs, nextPid, socketFile, unviewed, kept, pending, delivered,
                   serverDeaths, viewerDeaths, writesAsked, claimed, recoveryRestarts>>

\* Recoveries restarts and loses what it held in memory: a claim it had not
\* acted on is never acted on. Its table stays, unless ClaimInMemory.
RecoveriesRestart ==
    /\ recoveryRestarts < MaxRecoveryRestarts
    /\ recoveryRestarts' = recoveryRestarts + 1
    /\ acting' = {}
    /\ IF Break = "ClaimInMemory"
         THEN /\ claimed' = {}
              /\ opened' = {}
         ELSE UNCHANGED <<claimed, opened>>
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, unviewed,
                   kept, pending, delivered, serverDeaths, viewerDeaths, writesAsked,
                   reopened, twice>>

-----------------------------------------------------------------------------
(* Writes *)

\* A caller looks up a session's pane and keeps its id for a later write. A
\* lookup that finds none, or finds no server, yields the empty target.
\* A lookup after the last write asked is left out: only a write reads it.
PaneLookedUp(a) ==
    /\ writesAsked < MaxWrites
    /\ kept' = [kept EXCEPT ![a] =
                  [pane |-> IF HasViewer(a) THEN CHOOSE id \in PanesShowing(a) : TRUE
                                            ELSE EmptyTarget,
                   epoch |-> epoch]]
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile,
                   unviewed, pending, delivered, serverDeaths, viewerDeaths, writesAsked, rec>>

\* The guards before a write: a target of the form %<n>, a server, a pane at
\* that id, and the pane's tag naming the write's session.
Passes(a, id) ==
    /\ id # EmptyTarget
    /\ serverUp
    /\ id \in DOMAIN panes
    /\ Break = "NoPaneCheck" \/ panes[id] = a

Reached(a, id, from) ==
    [session |-> a, reached |-> panes[id], keptEpoch |-> from, epoch |-> epoch]

\* Control is asked to write to session a at the pane id it kept. In the
\* design the tag check and the send are one tmux command, so tmux checks the
\* pane it sends to. A write that fails a guard is refused and sends nothing.
\* Under CheckThenSend the check passes here and the send comes as its own step.
WriteAsked(a) ==
    LET k == kept[a] IN
    /\ writesAsked < MaxWrites
    /\ writesAsked' = writesAsked + 1
    /\ IF ~Passes(a, k.pane)
         THEN UNCHANGED <<pending, delivered>>
       ELSE IF Break = "CheckThenSend"
         THEN /\ pending' = pending \cup {[session |-> a, pane |-> k.pane, keptEpoch |-> k.epoch]}
              /\ UNCHANGED delivered
         ELSE /\ delivered' = delivered \cup {Reached(a, k.pane, k.epoch)}
              /\ UNCHANGED pending
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile,
                   unviewed, kept, serverDeaths, viewerDeaths, rec>>

\* Under CheckThenSend: the send of a write checked earlier, by pane id alone.
\* A pane gone or a server down makes tmux fail it, and nothing is sent.
WriteSent(w) ==
    /\ pending' = pending \ {w}
    /\ delivered' = IF serverUp /\ w.pane \in DOMAIN panes
                      THEN delivered \cup {Reached(w.session, w.pane, w.keptEpoch)}
                      ELSE delivered
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile,
                   unviewed, kept, serverDeaths, viewerDeaths, writesAsked, rec>>

-----------------------------------------------------------------------------
Next ==
    \/ ServerDies
    \/ ServerRestarts
    \/ \E a \in Agents : AgentStarted(a)
    \/ \E p \in procs : AgentExits(p) \/ SocketGoesStale(p)
    \/ \E id \in DOMAIN panes : ViewerDies(id)
    \/ SamplerReads
    \/ \E a \in Agents : RecoveryClaims(a)
    \/ \E c \in acting : RecoveryActs(c)
    \/ RecoveriesRestart
    \/ \E a \in Agents : PaneLookedUp(a) \/ WriteAsked(a)
    \/ \E w \in pending : WriteSent(w)

\* The framework's own steps are fair: it samples, claims what it read, and
\* acts on its claims. The rest (deaths, exits, starts, writes, a start of the
\* server by another part, a restart of Recoveries) may or may not happen.
Fairness ==
    /\ WF_vars(SamplerReads)
    /\ \A a \in Agents : WF_vars(RecoveryClaims(a))
    /\ WF_vars(\E c \in acting : RecoveryActs(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ serverUp \in BOOLEAN
    /\ epoch \in Nat /\ nextPane \in Nat /\ nextPid \in 0..MaxStarts
    /\ \A id \in DOMAIN panes : id \in Nat /\ panes[id] \in Agents
    /\ \A p \in procs : p.pid \in 1..MaxStarts /\ p.socket \in Agents
    /\ socketFile \in [Agents -> 0..MaxStarts]
    /\ unviewed \subseteq Agents
    /\ opened \subseteq Agents /\ claimed \subseteq Agents /\ reopened \subseteq Agents
    /\ acting \subseteq [agent : Agents, old : BOOLEAN] /\ twice \in BOOLEAN
    /\ recoveryRestarts \in 0..MaxRecoveryRestarts

\* A write reaches only the pane of the session it names.
WriteReachesItsSession ==
    \A w \in delivered : w.reached = w.session

\* A pane id kept from before a restart never reaches another agent's pane.
OldPaneIdNeverReachesAnother ==
    \A w \in delivered : w.keptEpoch < w.epoch => w.reached = w.session

\* No two processes hold one socket.
OneProcessPerSocket ==
    \A p, q \in procs : p.socket = q.socket => p = q

\* Recoveries opens at most one viewer per loss, across its own restarts.
OneReopenPerLoss ==
    ~twice

\* An agent outlives its tmux server: the step in which the server dies ends
\* no process.
AgentOutlivesServer ==
    [][serverUp /\ ~serverUp' => procs' = procs]_vars

\* A lost viewer is reopened, unless its agent ends first.
LostViewerReopened ==
    \A a \in Agents : (Held(a) /\ ~HasViewer(a)) ~> (HasViewer(a) \/ ~Held(a))

\* A held agent with no viewer is seen by the sampler, unless that changes first.
UnviewedAgentSeen ==
    \A a \in Agents : (Held(a) /\ ~HasViewer(a)) ~> (a \in unviewed \/ HasViewer(a) \/ ~Held(a))

=============================================================================
