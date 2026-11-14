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
(*               session's pane (not built yet);                           *)
(*   TmuxSampler reads the panes and the held sockets, and reports a held  *)
(*               agent with no viewer (not built yet);                     *)
(*   Recoveries  reopens a seen agent's viewer, and with it starts the     *)
(*               server again (ServerRestarts' fairness; not built yet).   *)
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
    Break             \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "NoPaneCheck",          \* a write goes to its kept pane id without checking the tag
    "CheckThenSend",        \* the tag check and the send are two tmux commands
    "CleanLiveSocket",      \* starting an agent removes a socket file that is still live
    "TmuxHoldsAgent",       \* the agent runs in its pane, not under dtach
    "NoReopen",             \* a lost viewer is never reopened
    "SamplerReadsPanesOnly" \* the sampler reads tmux's panes but not the held sockets
}

ASSUME Break \in Breaks
ASSUME MaxStarts \in Nat /\ MaxServerDeaths \in Nat /\ MaxViewerDeaths \in Nat
ASSUME MaxWrites \in Nat

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
    kept,          \* session -> the pane id a caller kept, and the epoch it was read in
    pending,       \* writes checked but not yet sent (only under CheckThenSend)
    delivered,     \* writes that reached a pane: [session, reached, keptEpoch, epoch]
    serverDeaths, viewerDeaths, writesAsked

vars == <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, unviewed,
          kept, pending, delivered, serverDeaths, viewerDeaths, writesAsked>>

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
                   viewerDeaths, writesAsked>>

\* The framework starts its server again. A new server counts pane ids from %0,
\* so an id read before this step may name another pane after it.
ServerRestarts ==
    /\ ~serverUp
    /\ serverUp' = TRUE
    /\ epoch' = epoch + 1
    /\ nextPane' = 0
    /\ UNCHANGED <<panes, procs, nextPid, socketFile, unviewed, kept, pending,
                   delivered, serverDeaths, viewerDeaths, writesAsked>>

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
                   delivered, serverDeaths, viewerDeaths, writesAsked>>

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
                   delivered, serverDeaths, viewerDeaths, writesAsked>>

\* The dtach holding the agent is killed hard: the process is gone, but the
\* socket file stays at its path, refusing connections.
SocketGoesStale(p) ==
    /\ procs' = procs \ {p}
    /\ panes' = ViewersAfter(p)
    /\ UNCHANGED <<serverUp, epoch, nextPane, nextPid, socketFile, unviewed, kept,
                   pending, delivered, serverDeaths, viewerDeaths, writesAsked>>

-----------------------------------------------------------------------------
(* Viewers *)

\* A viewer pane dies on its own (its window is closed, its client killed).
\* The agent it showed runs on.
ViewerDies(id) ==
    /\ viewerDeaths < MaxViewerDeaths
    /\ panes' = Without(panes, {id})
    /\ viewerDeaths' = viewerDeaths + 1
    /\ UNCHANGED <<serverUp, epoch, nextPane, procs, nextPid, socketFile, unviewed,
                   kept, pending, delivered, serverDeaths, writesAsked>>

\* The sampler reads which held agents have no viewer. It must read the held
\* sockets as well as tmux's panes: an agent whose viewer is gone has no pane
\* left to read. Under SamplerReadsPanesOnly it sees only agents with a pane.
SamplerReads ==
    LET visible == IF Break = "SamplerReadsPanesOnly"
                     THEN {panes[id] : id \in DOMAIN panes}
                     ELSE Agents
    IN  /\ unviewed' = {a \in visible : Held(a) /\ ~HasViewer(a)}
        /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile,
                       kept, pending, delivered, serverDeaths, viewerDeaths, writesAsked>>

\* A seen agent's viewer is reopened, once for the loss the sampler read. Its
\* tmux session is named by the agent, so tmux refuses a second one, and the
\* new pane carries its tag from the command that creates it.
ViewerReopened(a) ==
    /\ Break # "NoReopen"
    /\ a \in unviewed
    /\ serverUp
    /\ SocketLive(a)
    /\ ~HasViewer(a)
    /\ panes' = With(panes, nextPane, a)
    /\ nextPane' = nextPane + 1
    /\ unviewed' = unviewed \ {a}
    /\ UNCHANGED <<serverUp, epoch, procs, nextPid, socketFile, kept, pending,
                   delivered, serverDeaths, viewerDeaths, writesAsked>>

\* The reopen finds nothing to do or cannot run: no server, no live socket, or
\* a viewer already there. The reading is spent; the next one decides again.
ViewerReopenRefused(a) ==
    /\ a \in unviewed
    /\ ~serverUp \/ ~SocketLive(a) \/ HasViewer(a)
    /\ unviewed' = unviewed \ {a}
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, kept,
                   pending, delivered, serverDeaths, viewerDeaths, writesAsked>>

-----------------------------------------------------------------------------
(* Writes *)

\* A caller looks up a session's pane and keeps its id for a later write. A
\* lookup that finds none, or finds no server, yields the empty target.
PaneLookedUp(a) ==
    /\ kept' = [kept EXCEPT ![a] =
                  [pane |-> IF HasViewer(a) THEN CHOOSE id \in PanesShowing(a) : TRUE
                                            ELSE EmptyTarget,
                   epoch |-> epoch]]
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile,
                   unviewed, pending, delivered, serverDeaths, viewerDeaths, writesAsked>>

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
                   unviewed, kept, serverDeaths, viewerDeaths>>

\* Under CheckThenSend: the send of a write checked earlier, by pane id alone.
\* A pane gone or a server down makes tmux fail it, and nothing is sent.
WriteSent(w) ==
    /\ pending' = pending \ {w}
    /\ delivered' = IF serverUp /\ w.pane \in DOMAIN panes
                      THEN delivered \cup {Reached(w.session, w.pane, w.keptEpoch)}
                      ELSE delivered
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile,
                   unviewed, kept, serverDeaths, viewerDeaths, writesAsked>>

-----------------------------------------------------------------------------
Next ==
    \/ ServerDies
    \/ ServerRestarts
    \/ \E a \in Agents : AgentStarted(a)
    \/ \E p \in procs : AgentExits(p) \/ SocketGoesStale(p)
    \/ \E id \in DOMAIN panes : ViewerDies(id)
    \/ SamplerReads
    \/ \E a \in Agents : ViewerReopened(a) \/ ViewerReopenRefused(a)
    \/ \E a \in Agents : PaneLookedUp(a) \/ WriteAsked(a)
    \/ \E w \in pending : WriteSent(w)

\* The framework's own steps are fair: it restarts its server, samples, and
\* acts on what it read. The rest (deaths, exits, starts, writes) may or may
\* not happen.
Fairness ==
    /\ WF_vars(ServerRestarts)
    /\ WF_vars(SamplerReads)
    /\ \A a \in Agents : WF_vars(ViewerReopened(a)) /\ WF_vars(ViewerReopenRefused(a))

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

\* A write reaches only the pane of the session it names.
WriteReachesItsSession ==
    \A w \in delivered : w.reached = w.session

\* A pane id kept from before a restart never reaches another agent's pane.
OldPaneIdNeverReachesAnother ==
    \A w \in delivered : w.keptEpoch < w.epoch => w.reached = w.session

\* No two processes hold one socket.
OneProcessPerSocket ==
    \A p, q \in procs : p.socket = q.socket => p = q

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
