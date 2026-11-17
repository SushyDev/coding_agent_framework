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
(*   TmuxSampler reads the panes, then the held sockets, and reports a     *)
(*               held agent with no viewer (built in F-22). A viewer       *)
(*               opened between its two reads shows as lost for that one   *)
(*               reading (SamplerReadsAround). A reading names a new loss  *)
(*               as Reading says; the code keys a loss by the sampler's    *)
(*               generation and the sample at which the row became         *)
(*               unviewed, or Recoveries' last open or clear, if later;    *)
(*   Sessions    a start holds its agent, then opens its viewer;           *)
(*   Recoveries  claims a loss that two readings in a row read, in its     *)
(*               table, then reopens the agent's viewer, once per loss     *)
(*               across its own restarts, and with it starts the server    *)
(*               again when it is down (F-23). A third loss of one agent   *)
(*               within the window ends failed{repeating}, and its losses  *)
(*               are not acted on until a person clears it.                *)
(*                                                                         *)
(* Recoveries' claim is Claim.tla's (RC): its row, the call that holds it, *)
(* a restart that cuts it, and the properties OneReopenPerLoss (Claim's    *)
(* OneActPerState) and NoActOnCutOffClaim. A loss has no number here, so a *)
(* reading that names a new loss passes the old one (RC!Passes): its rows  *)
(* go, and a claim of it still in memory is let go. In the code the claim  *)
(* and the act are one call, with no reading between them; here they are   *)
(* two steps, and the reading between them stands for nothing the code     *)
(* does. A claim is taken for its act: a reopen, or, for the third loss    *)
(* since a person cleared the agent, the end failed{repeating}, which the  *)
(* act writes with no open, as the code's act does.                        *)
(*                                                                         *)
(* A restart of Recoveries between its claim and its act leaves that loss  *)
(* claimed and not acted on: it ends unknown, for a person, and is never   *)
(* acted on again (NoActOnCutOffClaim). So LostViewerReopened is checked   *)
(* with no such restart (Agent_Viewers, Agent_LateViewers), and            *)
(* OneReopenPerLoss and NoActOnCutOffClaim with one (Agent_Claims).        *)
(*                                                                         *)
(* Two readings in a row can still both read a loss that a start's viewer  *)
(* ends: the first before the start opens it, the second with the open     *)
(* between its reads. Recoveries then acts on an agent that has a viewer;  *)
(* tmux refuses the session's name, and that refusal counts as an open, so *)
(* a later loss is a new one (RecoveryActs).                               *)
(*                                                                         *)
(* The bound on repeating losses changes the reopen's fairness: a lost     *)
(* viewer is reopened unless its agent ends or is waiting for a person.    *)
(* Time is left out, so every loss here falls within the window: the case  *)
(* in which the bound stops the reopen. A sample too old to act on is a    *)
(* check that claims nothing (it writes a skipped row, which a later claim *)
(* takes over); the model leaves it out with time.                         *)
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
(* refusal cannot fail on its own; it gives the write a named reason. The  *)
(* same for `a \notin opened` in RecoveryClaims, behind the claim's row    *)
(* for OneReopenPerLoss: a second claim of one loss needs the first's row  *)
(* gone, and only a reading that names a new loss takes it out (Passes),   *)
(* which also clears what was acted on.                                    *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Agents,           \* session ids; each names its socket and its tmux session
    MaxStarts,        \* processes started over the whole behavior
    MaxServerDeaths,  \* times the tmux server dies
    MaxViewerDeaths,  \* times a viewer pane dies on its own
    MaxWrites,        \* writes asked
    MaxRecoveryRestarts, \* times Recoveries restarts, losing what it held in memory
    MaxLateViewers,   \* starts whose viewer opens in a later step than the hold
    Break             \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "NoPaneCheck",          \* a write goes to its kept pane id without checking the tag
    "CheckThenSend",        \* the tag check and the send are two tmux commands
    "CleanLiveSocket",      \* starting an agent removes a socket file that is still live
    "TmuxHoldsAgent",       \* the agent runs in its pane, not under dtach
    "NoReopen",             \* a lost viewer is never reopened
    "SamplerReadsPanesOnly", \* the sampler reads tmux's panes but not the held sockets
    "ClaimInMemory",        \* Recoveries keeps its claims in memory, not in its table
    "ClaimTwice",           \* Recoveries claims a loss it has claimed, after a restart
    "OneReading"            \* Recoveries acts on a loss after one reading
}

ASSUME Break \in Breaks
ASSUME MaxStarts \in Nat /\ MaxServerDeaths \in Nat /\ MaxViewerDeaths \in Nat
ASSUME MaxWrites \in Nat /\ MaxRecoveryRestarts \in Nat /\ MaxLateViewers \in Nat

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
    unviewed,      \* the sampler's last reading: held agents with no viewer, read
                   \* after Recoveries' last open of their viewer
    opened,        \* agents Recoveries opened a viewer for (or a person cleared)
                   \* since the last reading ended
    agreed,        \* Recoveries' memory: agents the last two readings read in one loss
    fresh,         \* Recoveries restarted since the last reading: it holds no reading
    wrongOnce,     \* history: agents in a loss whose one reading was wrong when it ended
    starting,      \* agents a start has held and not yet opened a viewer for
    lateViewers,   \* starts that opened their viewer in a later step
    losses,        \* agent -> the losses Recoveries claimed since a person cleared it
    repeating,     \* agents whose losses wait for a person (failed{repeating})
    \* Recoveries' claims, as Claim.tla's variables (RC); a loss is state 0
    claims,        \* its table: the claims of each agent's current loss
    acting,        \* the claims it holds in memory and has not acted on yet
    done,          \* its table: the claims acted on or let go
    reopened,      \* history: the losses <<agent, 0>> an act ran on
    twice,         \* history: an act ran twice on one loss
    cutOff,        \* history: the losses whose claim a restart of Recoveries cut off,
                   \* until a reading names a new loss for them
    recoveryRestarts,
    kept,          \* session -> the pane id a caller kept, and the epoch it was read in
    pending,       \* writes checked but not yet sent (only under CheckThenSend)
    delivered,     \* writes that reached a pane: [session, reached, keptEpoch, epoch]
    serverDeaths, viewerDeaths, writesAsked

\* Recoveries' variables, unchanged by the other steps.
claimVars == <<claims, acting, done, reopened, twice, cutOff>>
rec == <<opened, claimVars, recoveryRestarts, agreed, fresh, losses, repeating>>

\* The starts' viewers not yet opened.
starts == <<starting, lateViewers>>

\* The sampler's reading, and its history.
smp == <<unviewed, wrongOnce>>

vars == <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, smp, starts,
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

\* Recoveries' claims. A loss is not numbered: each agent's state is 0, and a
\* reading that names a new loss passes the old one.
RC == INSTANCE Claim WITH
        Targets <- Agents, Actors <- {"recoveries"}, MaxState <- 0,
        now <- [a \in Agents |-> 0], rows <- claims, acting <- acting, done <- done,
        acted <- reopened, twice <- twice, cut <- cutOff,
        Break <- CASE Break = "ClaimInMemory" -> "InMemory"
                   [] Break = "ClaimTwice" -> "TwoClaims"
                   [] OTHER -> "none"

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
    /\ agreed = {}
    /\ fresh = FALSE
    /\ wrongOnce = {}
    /\ starting = {}
    /\ lateViewers = 0
    /\ losses = [a \in Agents |-> 0]
    /\ repeating = {}
    /\ claims = {} /\ acting = {} /\ done = {} /\ reopened = {} /\ twice = FALSE
    /\ cutOff = {}
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
    /\ UNCHANGED <<epoch, nextPane, nextPid, smp, starts, kept, pending, delivered,
                   viewerDeaths, writesAsked, rec>>

\* Another part starts the server again; a viewer opened while it is down
\* starts it too (OpenViewer). A new server counts pane ids from %0, so an id
\* read before this step may name another pane after it.
ServerRestarts ==
    /\ ~serverUp
    /\ serverUp' = TRUE
    /\ epoch' = epoch + 1
    /\ nextPane' = 0
    /\ UNCHANGED <<panes, procs, nextPid, socketFile, smp, starts, kept, pending,
                   delivered, serverDeaths, viewerDeaths, writesAsked, rec>>

-----------------------------------------------------------------------------
(* Opening a viewer *)

\* A viewer of a opens: `tmux new-session` named by the agent, its pane tagged
\* as it opens, running `dtach -a`. It starts the server when it is down, so
\* the new pane is %0 of a new server. The caller checks first that a has no
\* viewer: tmux refuses a second session of that name.
OpenPane(a) ==
    IF serverUp
      THEN /\ panes' = With(panes, nextPane, a)
           /\ nextPane' = nextPane + 1
           /\ UNCHANGED <<serverUp, epoch>>
      ELSE /\ serverUp' = TRUE
           /\ epoch' = epoch + 1
           /\ panes' = With(panes, 0, a)
           /\ nextPane' = 1

\* On a socket that is no longer live, `dtach -a` exits at once and its pane
\* closes.
OpenViewer(a) ==
    IF ~SocketLive(a) THEN UNCHANGED <<serverUp, epoch, nextPane, panes>> ELSE OpenPane(a)

-----------------------------------------------------------------------------
(* Held agents (dtach) *)

\* `hold`: start a's process under dtach on a's socket. A socket file whose
\* process is gone (stale) is removed first; a live one refuses the start, so
\* no two processes ever hold one socket. Under CleanLiveSocket the live file
\* is removed too, and a second process binds the path. The start then opens
\* the agent's viewer: here, in the same step, or, up to MaxLateViewers times,
\* in a later step of its own (StartOpensViewer), which may fall between the
\* sampler's two reads. The late open is what a configuration that does not
\* study that race leaves out.
AgentStarted(a) ==
    /\ nextPid < MaxStarts
    /\ \/ socketFile[a] = NoFile
       \/ SocketStale(a)
       \/ Break = "CleanLiveSocket" /\ SocketLive(a)
    /\ nextPid' = nextPid + 1
    /\ procs' = procs \cup {[pid |-> nextPid + 1, socket |-> a]}
    /\ socketFile' = [socketFile EXCEPT ![a] = nextPid + 1]
    /\ \/ /\ IF HasViewer(a) THEN UNCHANGED <<serverUp, epoch, nextPane, panes>>
                                ELSE OpenPane(a)
          /\ UNCHANGED starts
       \/ /\ lateViewers < MaxLateViewers
          /\ lateViewers' = lateViewers + 1
          /\ starting' = starting \cup {a}
          /\ UNCHANGED <<serverUp, epoch, nextPane, panes>>
    /\ UNCHANGED <<smp, kept, pending, delivered, serverDeaths, viewerDeaths, writesAsked,
                   rec>>

\* A process ends with no other on its socket: its viewers' `dtach -a` see the
\* socket close and exit, and their panes close.
ViewersAfter(p) ==
    IF \E q \in procs : q # p /\ q.socket = p.socket
      THEN panes
      ELSE Without(panes, PanesShowing(p.socket))

\* The agent ends: by itself, or by a signal to its pid (Sessions' stop is
\* SIGTERM once it is idle). dtach removes the socket file it bound.
AgentExits(p) ==
    /\ procs' = procs \ {p}
    /\ socketFile' = IF socketFile[p.socket] = p.pid
                       THEN [socketFile EXCEPT ![p.socket] = NoFile]
                       ELSE socketFile
    /\ panes' = ViewersAfter(p)
    /\ UNCHANGED <<serverUp, epoch, nextPane, nextPid, smp, starts, kept, pending,
                   delivered, serverDeaths, viewerDeaths, writesAsked, rec>>

\* The dtach holding the agent is killed hard: the process is gone, but the
\* socket file stays at its path, refusing connections.
SocketGoesStale(p) ==
    /\ procs' = procs \ {p}
    /\ panes' = ViewersAfter(p)
    /\ UNCHANGED <<serverUp, epoch, nextPane, nextPid, socketFile, smp, starts, kept,
                   pending, delivered, serverDeaths, viewerDeaths, writesAsked, rec>>

-----------------------------------------------------------------------------
(* Viewers *)

\* A start opens the viewer of the agent it held (Sessions). It may come
\* between the sampler's two reads.
StartOpensViewer(a) ==
    /\ a \in starting
    /\ starting' = starting \ {a}
    /\ IF HasViewer(a)
         THEN UNCHANGED <<serverUp, epoch, nextPane, panes>>
         ELSE OpenViewer(a)
    /\ UNCHANGED <<procs, nextPid, socketFile, smp, kept, pending, delivered,
                   serverDeaths, viewerDeaths, writesAsked, rec, lateViewers>>

\* A viewer pane dies on its own (its window is closed, its client killed).
\* The agent it showed runs on.
ViewerDies(id) ==
    /\ viewerDeaths < MaxViewerDeaths
    /\ panes' = Without(panes, {id})
    /\ viewerDeaths' = viewerDeaths + 1
    /\ UNCHANGED <<serverUp, epoch, nextPane, procs, nextPid, socketFile, smp, starts,
                   kept, pending, delivered, serverDeaths, writesAsked, rec>>

\* The sampler reads tmux's panes, then the held sockets, and joins them: a
\* held agent with no viewer has no pane left to read, so only the sockets
\* show it. The join calls a held socket unviewed only while it is live.
\* Under SamplerReadsPanesOnly it sees only agents with a pane.
\*
\* A reading names a new loss for an agent not read in the last reading, or
\* opened for since: that viewer is gone again. A new loss is not claimed yet,
\* and no viewer was opened for it. Recoveries agrees on a loss the last
\* reading read too, unless it restarted since and so holds no last reading.
\* `wrong` holds the agents whose viewer opened between the two reads.
Reading(paneRead, wrong) ==
    LET visible == IF Break = "SamplerReadsPanesOnly" THEN paneRead ELSE Agents
        now == {a \in visible : Held(a) /\ SocketLive(a) /\ a \notin paneRead}
        new == {a \in now : a \notin unviewed \/ a \in opened}
    IN  /\ unviewed' = now
        /\ agreed' = IF fresh THEN {} ELSE now \ new
        /\ fresh' = FALSE
        /\ wrongOnce' = new \cap wrong
        /\ opened' = {}
        \* The old loss passes: a claim of the new loss is a new claim, not the
        \* one a restart cut off, and a claim of the old one is let go.
        /\ RC!Passes(new)
        /\ UNCHANGED <<procs, nextPid, socketFile, kept, pending, delivered, serverDeaths,
                       viewerDeaths, writesAsked, recoveryRestarts, losses, repeating>>

\* A reading with nothing between its two reads. A step between them that
\* closes a viewer, ends an agent or opens a viewer for Recoveries reads the
\* same as that step before or after the reading: Recoveries does not act on
\* a reading begun before its own open (`read_at`), and a pane or socket gone
\* reads as gone.
SamplerReads ==
    /\ Reading({panes[id] : id \in DOMAIN panes}, {})
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, starts>>

\* A reading with a start's viewer opening between its two reads: the panes
\* read shows no viewer of a, and the sockets read shows a held. The reading
\* is wrong for a. One such open per reading is modeled.
SamplerReadsAround(a) ==
    /\ a \in starting
    /\ starting' = starting \ {a}
    /\ ~HasViewer(a)
    /\ OpenViewer(a)
    /\ UNCHANGED lateViewers
    /\ Reading({panes[id] : id \in DOMAIN panes}, {a})

\* Recoveries writes a claim on the loss it read before it acts, and only on a
\* loss not claimed yet (RC!Take), that the last two readings read, both after
\* its own last open of that agent's viewer. Under OneReading one reading is
\* enough. The claim of a third loss since a person last cleared the agent is
\* for the end failed{repeating}, with no open; the agent's losses then wait
\* for a person.
RecoveryClaims(a) ==
    /\ Break # "NoReopen"
    /\ IF Break = "OneReading" THEN a \in unviewed ELSE a \in agreed
    /\ a \notin opened
    /\ a \notin repeating
    /\ RC!Take("recoveries", a, IF losses[a] = 2 THEN "repeating" ELSE "reopen")
    /\ losses' = IF losses[a] = 2 THEN losses ELSE [losses EXCEPT ![a] = @ + 1]
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, smp,
                   starts, kept, pending, delivered, serverDeaths, viewerDeaths,
                   writesAsked, opened, recoveryRestarts, agreed, fresh, repeating>>

\* Recoveries opens the claimed agent's viewer. The outcome is read from a
\* later sample. When a viewer opened since the readings (a start's), tmux
\* refuses the session's name; that refusal shows a viewer existed, so it
\* counts as an open: a loss read after it is a new loss. Without that, the
\* start's viewer dying before the next reading would leave this loss
\* claimed and the agent unviewed for good.
\*
\* The act of a claim for the end failed{repeating} writes it, and opens nothing.
RecoveryActs(c) ==
    LET a == c.t IN
    /\ RC!Act(c)
    /\ IF c.act = "repeating"
         THEN /\ repeating' = repeating \cup {a}
              /\ UNCHANGED <<serverUp, epoch, nextPane, panes, opened>>
         ELSE /\ opened' = opened \cup {a}
              /\ IF HasViewer(a) THEN UNCHANGED <<serverUp, epoch, nextPane, panes>>
                                  ELSE OpenViewer(a)
              /\ UNCHANGED repeating
    /\ UNCHANGED <<procs, nextPid, socketFile, smp, starts, kept, pending, delivered,
                   serverDeaths, viewerDeaths, writesAsked, recoveryRestarts, agreed, fresh,
                   losses>>

\* A person clears an agent whose losses repeated (Recoveries.clear/2). A loss
\* read after the clear is a new loss, as after an open.
PersonClears(a) ==
    /\ a \in repeating
    /\ repeating' = repeating \ {a}
    /\ losses' = [losses EXCEPT ![a] = 0]
    /\ opened' = opened \cup {a}
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, smp,
                   starts, kept, pending, delivered, serverDeaths, viewerDeaths,
                   writesAsked, claimVars, recoveryRestarts, agreed, fresh>>

\* Recoveries restarts and loses what it held in memory: a claim it had not
\* acted on is never acted on (RC!Restart cuts it off), and the last reading
\* it agreed with is gone. Its table stays. Under ClaimInMemory its claims
\* had no rows, and its last opens, in memory too, go with it.
RecoveriesRestart ==
    /\ recoveryRestarts < MaxRecoveryRestarts
    /\ recoveryRestarts' = recoveryRestarts + 1
    /\ RC!Restart
    /\ agreed' = {}
    /\ fresh' = TRUE
    /\ opened' = IF Break = "ClaimInMemory" THEN {} ELSE opened
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, smp,
                   starts, kept, pending, delivered, serverDeaths, viewerDeaths,
                   writesAsked, losses, repeating>>

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
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, smp,
                   starts, pending, delivered, serverDeaths, viewerDeaths, writesAsked,
                   rec>>

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
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, smp,
                   starts, kept, serverDeaths, viewerDeaths, rec>>

\* Under CheckThenSend: the send of a write checked earlier, by pane id alone.
\* A pane gone or a server down makes tmux fail it, and nothing is sent.
WriteSent(w) ==
    /\ pending' = pending \ {w}
    /\ delivered' = IF serverUp /\ w.pane \in DOMAIN panes
                      THEN delivered \cup {Reached(w.session, w.pane, w.keptEpoch)}
                      ELSE delivered
    /\ UNCHANGED <<serverUp, epoch, nextPane, panes, procs, nextPid, socketFile, smp,
                   starts, kept, serverDeaths, viewerDeaths, writesAsked, rec>>

-----------------------------------------------------------------------------
Next ==
    \/ ServerDies
    \/ ServerRestarts
    \/ \E a \in Agents : AgentStarted(a) \/ StartOpensViewer(a)
    \/ \E p \in procs : AgentExits(p) \/ SocketGoesStale(p)
    \/ \E id \in DOMAIN panes : ViewerDies(id)
    \/ SamplerReads
    \/ \E a \in Agents : SamplerReadsAround(a)
    \/ \E a \in Agents : RecoveryClaims(a) \/ PersonClears(a)
    \/ \E c \in acting : RecoveryActs(c)
    \/ RecoveriesRestart
    \/ \E a \in Agents : PaneLookedUp(a) \/ WriteAsked(a)
    \/ \E w \in pending : WriteSent(w)

\* The framework's own steps are fair: a start opens its viewer, the sampler
\* samples, and Recoveries claims what it read and acts on its claims. The
\* rest (deaths, exits, starts, writes, a start of the server by another part,
\* a restart of Recoveries, a person's clear) may or may not happen.
Fairness ==
    /\ \A a \in Agents : WF_vars(StartOpensViewer(a))
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
    /\ unviewed \subseteq Agents /\ agreed \subseteq Agents /\ fresh \in BOOLEAN
    /\ wrongOnce \subseteq Agents /\ starting \subseteq Agents
    /\ lateViewers \in 0..MaxLateViewers
    /\ losses \in [Agents -> 0..2] /\ repeating \subseteq Agents
    /\ opened \subseteq Agents
    /\ claims \subseteq [by : {"recoveries"}, t : Agents, s : {0}, act : {"reopen", "repeating"},
                         n : {1}]
    /\ acting \subseteq claims /\ done \subseteq claims /\ acting \cap done = {}
    /\ reopened \subseteq Agents \X {0} /\ twice \in BOOLEAN /\ cutOff \subseteq Agents \X {0}
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

\* Recoveries acts at most once per loss, across its own restarts: it opens at
\* most one viewer for it.
OneReopenPerLoss == RC!OneActPerState

\* Recoveries never acts on a loss that one reading alone read, when that
\* reading was wrong: a viewer opened between its two reads.
NoActOnOneWrongReading ==
    \A c \in acting : c.t \notin wrongOnce

\* A claim that a restart of Recoveries cut off is never acted on, until a
\* reading names a new loss for its agent.
NoActOnCutOffClaim == RC!NoActOnCutOffClaim

\* An agent outlives its tmux server: the step in which the server dies ends
\* no process.
AgentOutlivesServer ==
    [][serverUp /\ ~serverUp' => procs' = procs]_vars

\* A lost viewer is reopened, unless its agent ends first, or its losses
\* repeated and wait for a person.
LostViewerReopened ==
    \A a \in Agents :
        (Held(a) /\ ~HasViewer(a)) ~> (HasViewer(a) \/ ~Held(a) \/ a \in repeating)

\* A held agent with no viewer is seen by the sampler, unless that changes first.
UnviewedAgentSeen ==
    \A a \in Agents : (Held(a) /\ ~HasViewer(a)) ~> (a \in unviewed \/ HasViewer(a) \/ ~Held(a))

=============================================================================
