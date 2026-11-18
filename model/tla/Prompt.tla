------------------------------- MODULE Prompt -------------------------------
(***************************************************************************)
(* A prompt (F-162's "Prompts"; B1's third part, F-167): anything that     *)
(* waits on a person or on an agent's parent, one row in Prompts. Its      *)
(* opener stores it under its owner's key, so one state opens one prompt:  *)
(* the asker (the agent whose session asks; its path may end in that       *)
(* session's own subagent, whose hook names it), its kind, its options, a  *)
(* default and a deadline. It is answered once, by its rightful answerer:  *)
(* a person through the app, for every kind; the app's decider, for the    *)
(* kinds the app chose; the asker's parent through steer, for permission,  *)
(* plan and elicitation; never the asker itself, a sibling or any other    *)
(* agent. An answer is checked against the row read before its claim (the  *)
(* prompt still open, its answerer rightful), claimed in the Ledger on the *)
(* row's state (Claim.tla, C) and marked answering, then handed to its     *)
(* owner, the box whose mechanism applies it, and settled by the owner's   *)
(* answer: answered, refused (open again, or the owner's request gone),    *)
(* or unknown (kept, never sent again, for a person). At its deadline a    *)
(* kind that declares a safe default takes it, as the framework's answer;  *)
(* any other is expired and stays shown. A restart keeps every row, cuts   *)
(* the calls, and settles an answering row by its owner's evidence: cut    *)
(* when its answer may have gone, which a person clears once. A held       *)
(* request's owner is Intake's hold (Hold.tla, H): one response, its       *)
(* deadline, its holder's death.                                           *)
(*                                                                         *)
(* Models the Prompts box (B6: the `prompts` table, open/2, answer/3) and, *)
(* alone, the owners it hands answers to: Intake's holds of a              *)
(* PermissionRequest and of a Stop at Claude Code's cap (decision 10: the  *)
(* Stop hold counts blocks in a row and, at the cap, hands the agent to a  *)
(* person as a `stop_cap` prompt in place of being overridden, the         *)
(* override an act of the environment); Team.operate/4 for a `limit` (a    *)
(* move, its outcome known or not; its default the wait); and the asker's  *)
(* supervisor for `restarts` (a budget run out is a prompt, and the answer *)
(* starts the agent process again), with the whole restart and the         *)
(* asker's own (RestartAgent, F-164), which cuts its holds.                *)
(*                                                                         *)
(* Instanced by Dialog.tla (a startup dialog's prompt, its owner Sessions' *)
(* checked press: Open at the pane's read, Answer at the take, Hand and    *)
(* LetGo at the press, Settle at the task's answer, Cut, Readopt and       *)
(* CutAndReadopt at the restarts, Clear at a person's clear) and Team.tla  *)
(* (an ask, kind `question`, its owner Mailbox's answer row: Open at the   *)
(* ask, AnswerNow at the answer, the row stored in the same call). Each    *)
(* gives its own owner and evidence and sets the constants and variables   *)
(* it does not use to constants.                                           *)
(*                                                                         *)
(* Alone, the spec has one asker (`child`), its parent (`main`) and a      *)
(* sibling (`other`); Prompt_Holds has the two held prompts, and           *)
(* Prompt_Owners the limit and the restarts prompt. One stop_cap per run:  *)
(* a tool call resets the count only before the cap's hold.                *)
(*                                                                         *)
(* Left abstract: time (a deadline is a step); the text and the options    *)
(* beyond the cap's two labels; the cue per write; the inbox's reads; the  *)
(* kinds that need a reading first (plan and elicitation are held as a     *)
(* permission is; exit as startup is; login, remedy and policy are left    *)
(* to their units); the Grants claim a parent's answer takes on its        *)
(* child's state (Team.tla's AnswerClaimed). A claim's state is the row's  *)
(* state number, which every status write moves and an answer's mark      *)
(* leaves, so the claim stays current until its owner answers.             *)
(*                                                                         *)
(* Fairness, alone: the framework's steps, Intake's, the owners', and a    *)
(* person's answers and clears happen while possible. The deadline, the    *)
(* app's callback, other answerers, Claude Code's hooks, tool calls and    *)
(* restarts happen or not.                                                 *)
(*                                                                         *)
(* Break: "none" is the design. Every other value removes one guard and    *)
(* has a Break_Prompt_<value>.cfg that TLC must fail; Dialog.tla's         *)
(* AutoAnswer and RetryUnknown and Team.tla's AnswerTwice are this spec's  *)
(* AnyAnswerer, RetryUnknown and AnswerTwice in their instances.           *)
(*                                                                         *)
(* The Prompts box's contract: OneAnswer, OnlyRightful, NotAfterDeadline,  *)
(* DefaultOnlyDeclared, KeptAcrossRestart, NeverOverridden, and the        *)
(* Ledger's OneClaimPerState and NoActOnCutOffClaim on the answers;        *)
(* liveness PromptsEnd (answered, expired, withdrawn, or lost with its     *)
(* owner's request) and Escalated. How they imply what Boxes.tla assumes   *)
(* of Prompts (`pr`, `rp`):                                                *)
(*   pr's statuses are st's, Boxes' unknown being cut here (a restart cut  *)
(*        it, a person clears it); Boxes' Answer is Answer then Hand, its  *)
(*        Told and SettlePrompt are Settle and Readopt by the owner's      *)
(*        evidence, its Clear is Clear;                                    *)
(*   OneAnswer   Took <= 1 here for the owners whose evidence is exact     *)
(*        (a hold, Team.operate/4, a supervisor); for the press, whose     *)
(*        keys may be on their way, Dialog.tla's AtMostOnce (presses sent, *)
(*        once more only after a person's clear) implies Boxes' presses    *)
(*        landed, as before;                                               *)
(*   KeptAcrossRestart   no restart writes a row but to settle it; with    *)
(*        Dialog.tla's KeptAcrossRestart (a row on a dialog the pane shows *)
(*        has its prompt waiting), which is Boxes' with its keys in flight *)
(*        left to the press's unknown;                                     *)
(*   Escalated   rp is st["restarts"] waiting: the same property.          *)
(* Where they differ: after a refused press Boxes.tla opens the prompt     *)
(* again, and Dialog.tla withdraws it, since the dialog never shows        *)
(* again. None of Boxes.tla's properties rests on it: each is about a row  *)
(* still on its dialog (F-167's new-3).                                    *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
    Ps,            \* the prompts, by id: each its owner's key, so one state opens one
    Agents,        \* the agents of the tree
    Parent,        \* a -> a's parent agent, or a value no agent is (a main session's)
    Persons,       \* who answers as a person, through the app
    ParentKinds,   \* the kinds the asker's parent may answer, through steer
    AppKinds,      \* the kinds the app's decider answers
    DefaultKinds,  \* the kinds that declare a safe default, taken at the deadline
    ExpireKinds,   \* the kinds with a deadline and no default: expired at it
    HeldPs,        \* alone: the prompts whose owner is Intake's hold
    Cap,           \* alone: the Stop blocks in a row Claude Code honors (8)
    Budget,        \* alone: the asker's agent process's restart budget
    MaxRestarts,   \* alone: whole restarts and the asker's own, together
    MaxTools,      \* alone: tool calls of the asker that reset its blocks
    Break          \* "none", or the guard removed (see Breaks)

Breaks == {
    "none",
    "AnswerTwice",   \* an answer does not check its prompt is still open: an answered one is taken
    "RetryUnknown",  \* an answer whose outcome is unknown is taken again
    "AnyAnswerer",   \* an answer does not check its answerer: any agent along the tree answers
    "LateAnswer",    \* an answer does not check its prompt is still open: an expired one is taken
    "DefaultAny",    \* the deadline takes a default for a kind that declares none
    "InMemory",      \* an open prompt is kept in memory, so a whole restart loses it
    "NoEvidence",    \* an answering row a restart cut waits for its owner's answer, lost with it
    "SilentGiveUp",  \* a restart budget run out opens no prompt
    "NoCap"          \* the app's callback decides every Stop hold, past Claude Code's cap
}

ASSUME Break \in Breaks

Statuses == {"none", "open", "answering", "answered", "unknown", "cut", "expired", "withdrawn",
             "lost"}
Waiting == {"open", "answering", "unknown", "cut"}
Ends == {"answered", "expired", "withdrawn", "lost"}

VARIABLES
    \* the row, which the instancing specs share
    st,       \* p -> its row's status, one of Statuses
    ep,       \* p -> its row's state number: every status write but an answer's mark moves it
    kind,     \* p -> its kind, the opener's (read only here)
    asker,    \* p -> the agent whose session asks (read only here); its path ends there
    claims, acting, cdone, acted, twice, cut,   \* the answers' claims, as Claim.tla's (C)
    pwrong,   \* ghost: the faults a guard failed to stop
    \* alone: the framework, Intake's holds, the owners, and the asker
    up, restarts,
    hconn, hrow, hmarking, hout, hwrong,        \* Intake's holds, as Hold.tla's (H)
    took,     \* p -> answers its owner applied (ghost, for an owner that is not a hold)
    orec,     \* p -> its owner's record of its answer: none, applied, unsure
    otold,    \* in memory: the prompts whose owner's answer is on its way back
    turn,     \* the asker's turn: working, stop (its Stop hook held), ended
    blocks,   \* Claude Code's count of Stop blocks in a row, no tool call between
    tools,    \* tool calls that reset it
    crashes,  \* the asker's supervisor's count of restarts
    gaveUp    \* that supervisor gave up: no agent process runs for the asker

rowVars == <<st, ep, claims, acting, cdone, acted, twice, cut, pwrong>>
holdVars == <<hconn, hrow, hmarking, hout, hwrong>>
ownVars == <<took, orec, otold>>
askerVars == <<turn, blocks, tools, crashes, gaveUp>>
vars == <<rowVars, kind, asker, up, restarts, holdVars, ownVars, askerVars>>

Answerers == Persons \cup {"app"} \cup Agents

C == INSTANCE Claim WITH
       Targets <- Ps, Actors <- Answerers \cup {"framework"}, MaxState <- 99, now <- ep,
       rows <- claims, acting <- acting, done <- cdone, acted <- acted, twice <- twice,
       cut <- cut, Break <- "none"

H == INSTANCE Hold WITH
       Reqs <- HeldPs, conn <- hconn, row <- hrow, marking <- hmarking, out <- hout,
       wrong <- hwrong, Break <- "none"

-----------------------------------------------------------------------------
(* The row: the steps an instancing spec takes, each with its own guards   *)

\* Who may answer p: a person, for every kind; the app's decider, for the kinds it chose; the
\* asker's parent, for the kinds a parent answers. No other agent: not the asker, not a
\* sibling, not an agent of another subtree.
Rightful(p, who) ==
    \/ who \in Persons
    \/ who = "app" /\ kind[p] \in AppKinds
    \/ who \in Agents /\ who = Parent[asker[p]] /\ kind[p] \in ParentKinds

\* The prompt read before the answer's claim is still open. Each Break takes one status more.
Answerable(p) ==
    \/ st[p] = "open"
    \/ Break = "AnswerTwice" /\ st[p] = "answered"
    \/ Break = "RetryUnknown" /\ st[p] = "unknown"
    \/ Break = "LateAnswer" /\ st[p] = "expired"

Move(p, s) ==
    /\ st' = [st EXCEPT ![p] = s]
    /\ ep' = [ep EXCEPT ![p] = @ + 1]

\* The opener stores the prompt under its owner's key: a second open of that state finds it.
Open(p) ==
    /\ st[p] = "none"
    /\ UNCHANGED <<claims, acting, cdone, acted, twice, cut, pwrong>>
    /\ Move(p, "open")

\* An answer: checked against the prompt read before its claim (still open, its answerer
\* rightful), then claimed on the prompt's state (the Ledger's row, by its answerer) and
\* marked answering; the call that hands it to its owner holds the claim. The state number
\* does not move while answering, so the claim stays current until the owner's answer.
Answer(p, who, label) ==
    /\ Answerable(p)
    /\ Rightful(p, who) \/ Break = "AnyAnswerer"
    /\ C!Take(who, p, label)
    /\ st' = [st EXCEPT ![p] = "answering"]
    /\ pwrong' = pwrong \cup (IF st[p] = "expired" THEN {"late"} ELSE {})
    /\ UNCHANGED ep

\* For an owner that applies the answer in the same call (Mailbox's answer row): the claim,
\* the hand and the owner's answer in one step.
AnswerNow(p, who, label) ==
    /\ Answerable(p)
    /\ Rightful(p, who) \/ Break = "AnyAnswerer"
    /\ C!TakeAndAct(who, p, label)
    /\ Move(p, "answered")
    /\ pwrong' = pwrong \cup (IF st[p] = "expired" THEN {"late"} ELSE {})

\* At its deadline a kind that declares a safe default takes it, as the framework's answer.
\* Under DefaultAny a kind with no default takes one too.
Default(p) ==
    /\ st[p] = "open"
    /\ kind[p] \in DefaultKinds \/ (Break = "DefaultAny" /\ kind[p] \in ExpireKinds)
    /\ C!Take("framework", p, "default")
    /\ st' = [st EXCEPT ![p] = "answering"]
    /\ UNCHANGED <<ep, pwrong>>

\* At its deadline any other kind with one is expired, and stays shown.
Expire(p) ==
    /\ st[p] = "open" /\ kind[p] \in ExpireKinds
    /\ Move(p, "expired")
    /\ UNCHANGED <<claims, acting, cdone, acted, twice, cut, pwrong>>

\* The call hands a claimed answer to its owner, while the claim is current; what the owner
\* does is the instancing spec's.
Hand(c) == C!Act(c) /\ UNCHANGED <<st, ep, pwrong>>

\* The call lets the claim go: the owner's own check refused it before anything went.
LetGo(c) == C!LetGo(c) /\ UNCHANGED <<st, ep, pwrong>>

\* ... and the row says what the owner's refusal says: open again, or the owner's request
\* gone (expired, lost, withdrawn).
Refused(c, to) ==
    /\ st[c.t] = "answering"
    /\ C!LetGo(c)
    /\ Move(c.t, to)
    /\ UNCHANGED pwrong

\* The owner's answer, or once a restart cut the call, the owner's evidence: answered; open
\* again (nothing went); unknown (it may have gone; never sent again); cut (a restart cut it,
\* for a person's clear); or the owner's request gone.
Settle(p, to) ==
    /\ st[p] = "answering" /\ \A c \in acting : c.t # p
    /\ Move(p, to)
    /\ UNCHANGED <<claims, acting, cdone, acted, twice, cut, pwrong>>

\* A person who sees what the owner shows clears a cut answer (open again, or answered when it
\* took) or an unknown one (answered, or withdrawn: never sent again).
Clear(p, to) ==
    /\ \/ st[p] = "cut" /\ to \in {"open", "answered", "withdrawn"}
       \/ st[p] = "unknown" /\ to \in {"answered", "withdrawn"}
    /\ Move(p, to)
    /\ UNCHANGED <<claims, acting, cdone, acted, twice, cut, pwrong>>

\* The owner says no one waits on it any more (a person answered on the pane first, the
\* asker ended, the owner's state passed): withdrawn, read by its owner.
Withdraw(p) ==
    /\ st[p] \in {"open", "cut"}
    /\ Move(p, "withdrawn")
    /\ UNCHANGED <<claims, acting, cdone, acted, twice, cut, pwrong>>

\* The owner's request died with its holder: lost.
Lose(p) ==
    /\ st[p] = "open"
    /\ Move(p, "lost")
    /\ UNCHANGED <<claims, acting, cdone, acted, twice, cut, pwrong>>

\* A restart of Prompts: the calls and the claims they hold go; the rows stay. Under InMemory
\* the open rows go too.
Cut ==
    /\ C!Restart
    /\ st' = IF Break = "InMemory" THEN [p \in Ps |-> IF st[p] = "open" THEN "none" ELSE st[p]]
                                   ELSE st
    /\ UNCHANGED <<ep, pwrong>>

\* An owner that re-reads its marks after a restart settles each answering row by its
\* evidence in one step: to[p] for each.
Readopt(to) ==
    /\ st' = [p \in Ps |-> IF st[p] = "answering" THEN to[p] ELSE st[p]]
    /\ ep' = [p \in Ps |-> IF st[p] = "answering" THEN ep[p] + 1 ELSE ep[p]]
    /\ UNCHANGED <<claims, acting, cdone, acted, twice, cut, pwrong>>

\* ... and an owner whose own process holds the calls: the cut and the re-read in one step.
CutAndReadopt(to) ==
    /\ C!Restart
    /\ st' = [p \in Ps |-> IF st[p] = "answering" THEN to[p] ELSE st[p]]
    /\ ep' = [p \in Ps |-> IF st[p] = "answering" THEN ep[p] + 1 ELSE ep[p]]
    /\ UNCHANGED pwrong

\* A claim a restart cut off ends interrupted.
ClaimSettled(c) == C!Settle(c) /\ UNCHANGED <<st, ep, pwrong>>

-----------------------------------------------------------------------------
(* Alone: a delegate (`child`) asks; its parent is `main`, `other` is a    *)
(* sibling. Four prompts, each with its owner:                             *)
(*   perm      permission, its subagent's PermissionRequest, held by       *)
(*             Intake (H); a parent may answer; expired at the deadline;   *)
(*   cap       stop_cap, the Stop hold at Claude Code's cap (H): go on     *)
(*             ("yes", a block) or let the turn end ("no"); a person only; *)
(*   limit     limit, Team.operate/4 its owner (a move, or nothing), whose *)
(*             outcome may be unsure; its default, the wait;               *)
(*   restarts  restarts, opened by the asker's supervisor past its budget; *)
(*             the answer starts the agent process again.                  *)

AllPs == {"perm", "cap", "limit", "restarts"}
KindOf == [perm |-> "permission", cap |-> "stop_cap", limit |-> "limit", restarts |-> "restarts"]
TreeAgents == {"main", "child", "other"}
TreeParent == [main |-> "person", child |-> "main", other |-> "main"]
AloneHeld == Ps \cap {"perm", "cap"}

\* The labels a prompt offers: only the cap's matter here.
Options(p) == IF kind[p] = "stop_cap" THEN {"yes", "no"} ELSE {"yes"}

\* The label of the answer handed for p's current state.
Label(p) == (CHOOSE c \in cdone : c.t = p /\ c.s = ep[p] /\ <<p, ep[p]>> \in acted).act

Rest == <<kind, asker>>

\* The framework restarts: Prompts' calls, the holds and the owners' answers on their way go,
\* and the asker's agent process starts again under a new budget. A Stop hold cut lets the
\* turn end, as a hook that fails does.
FrameworkDies ==
    /\ up /\ restarts < MaxRestarts
    /\ up' = FALSE /\ restarts' = restarts + 1
    /\ Cut
    /\ H!Cut(HeldPs)
    /\ otold' = {}
    /\ turn' = IF "cap" \in HeldPs /\ hconn["cap"] THEN "ended" ELSE turn
    /\ crashes' = 0 /\ gaveUp' = FALSE
    /\ UNCHANGED <<Rest, hrow, hout, hwrong, took, orec, blocks, tools>>

FrameworkStarts ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<rowVars, Rest, restarts, holdVars, ownVars, askerVars>>

\* The asker's agent process crashes and its supervisor restarts it (RestartAgent): its holds
\* are cut, Prompts and the other owners run on. Past its budget the supervisor gives up and
\* opens a `restarts` prompt; under SilentGiveUp it opens none.
RestartAgent ==
    /\ up /\ restarts < MaxRestarts /\ ~gaveUp
    /\ restarts' = restarts + 1
    /\ crashes' = crashes + 1
    /\ gaveUp' = (crashes + 1 >= Budget)
    /\ IF crashes + 1 >= Budget /\ "restarts" \in Ps /\ Break # "SilentGiveUp"
       THEN Open("restarts")
       ELSE UNCHANGED rowVars
    /\ H!Cut(HeldPs)
    /\ turn' = IF "cap" \in HeldPs /\ hconn["cap"] THEN "ended" ELSE turn
    /\ UNCHANGED <<Rest, up, hrow, hout, hwrong, ownVars, blocks, tools>>

AgentUp == up /\ ~gaveUp

\* Claude Code posts a PermissionRequest of the asker's subagent; Intake holds it.
Requests ==
    /\ AgentUp /\ "perm" \in HeldPs /\ hrow["perm"] = "none" /\ ~hconn["perm"]
    /\ hout["perm"] = <<>>
    /\ H!Opens("perm", TRUE)
    /\ UNCHANGED <<rowVars, Rest, up, restarts, ownVars, askerVars>>

\* The asker's turn reaches its Stop hook. Below the cap the app's callback decides it, in
\* this step: a block, which Claude Code honors below the cap and overrides at it (the
\* environment's act), or a pass. The callback's block that would be the cap's last is held
\* as a `stop_cap` prompt for a person (its pass ends the turn, as below the cap); past the
\* cap the framework blocks no more, and the turn ends. Under NoCap the callback decides
\* every one. Intake.tla models the count Intake keeps (F-157).
StopFires ==
    /\ AgentUp /\ "cap" \in HeldPs /\ turn = "working"
    /\ IF blocks < Cap - 1 \/ Break = "NoCap"
       THEN \/ IF blocks >= Cap
               THEN turn' = "ended" /\ pwrong' = pwrong \cup {"overridden"}
                    /\ UNCHANGED blocks
               ELSE blocks' = blocks + 1 /\ UNCHANGED <<turn, pwrong>>
            \/ turn' = "ended" /\ UNCHANGED <<blocks, pwrong>>
       ELSE IF blocks = Cap - 1 /\ hrow["cap"] = "none" /\ ~hconn["cap"] /\ hout["cap"] = <<>>
       THEN \/ /\ H!Opens("cap", TRUE) /\ turn' = "stop"
               /\ UNCHANGED <<blocks, pwrong>>
            \/ turn' = "ended" /\ UNCHANGED <<blocks, pwrong>>
       ELSE turn' = "ended" /\ UNCHANGED <<blocks, pwrong>>
    /\ IF turn' = "stop" THEN TRUE ELSE UNCHANGED holdVars
    /\ UNCHANGED <<st, ep, claims, acting, cdone, acted, twice, cut, Rest, up, restarts, ownVars,
                   tools, crashes, gaveUp>>

\* A tool call between Stop hooks resets Claude Code's count.
ToolCall ==
    /\ up /\ "cap" \in HeldPs /\ turn = "working" /\ blocks > 0 /\ tools < MaxTools
    /\ hrow["cap"] = "none"
    /\ blocks' = 0 /\ tools' = tools + 1
    /\ UNCHANGED <<rowVars, Rest, up, restarts, holdVars, ownVars, turn, crashes, gaveUp>>

\* Intake writes the hold's row; Sessions opens its prompt.
Held(p) ==
    /\ AgentUp /\ p \in HeldPs /\ H!Held(p)
    /\ UNCHANGED <<rowVars, Rest, up, restarts, ownVars, askerVars>>

Opened(p) ==
    /\ up /\ p \in HeldPs /\ hrow[p] = "held" /\ hconn[p]
    /\ Open(p)
    /\ UNCHANGED <<Rest, up, restarts, holdVars, ownVars, askerVars>>

\* An account reaches its usage limit: the Scheduler opens a `limit` prompt.
AtLimit ==
    /\ up /\ "limit" \in Ps
    /\ Open("limit")
    /\ UNCHANGED <<Rest, up, restarts, holdVars, ownVars, askerVars>>

\* Someone answers, through answer/3 (a person, the app) or steer (an agent).
Answers(p, who, l) ==
    /\ up /\ l \in Options(p)
    /\ Answer(p, who, l)
    /\ UNCHANGED <<Rest, up, restarts, holdVars, ownVars, askerVars>>

\* The deadline. A hold's: the empty response, and the prompt expired, or its default taken
\* while the hold still waits; a Stop hold's lets the turn end. Any other prompt's: its
\* default, or expired.
Deadline(p) ==
    /\ up
    /\ \/ /\ p \in HeldPs /\ st[p] \in {"none", "open", "answering"} /\ AgentUp
          /\ H!Expires(p)
          /\ IF st[p] = "open" THEN Expire(p) ELSE UNCHANGED rowVars
          /\ turn' = IF p = "cap" THEN "ended" ELSE turn
       \/ /\ p \in HeldPs /\ hrow[p] = "held" /\ hconn[p]
          /\ Default(p) /\ UNCHANGED <<holdVars, turn>>
       \/ p \notin HeldPs /\ (Default(p) \/ Expire(p)) /\ UNCHANGED <<holdVars, turn>>
    /\ UNCHANGED <<Rest, up, restarts, ownVars, blocks, tools, crashes, gaveUp>>

\* The hand to a hold: the decision takes the hold the prompt names, while it is held. Else
\* the owner refuses, and the row says why.
HeldTo(p) ==
    CASE hrow[p] \in {"expired", "lost", "answered", "unknown"} -> hrow[p]
      [] hrow[p] = "passed" -> "withdrawn"
      [] OTHER -> "open"

HandHeld(c) ==
    /\ AgentUp /\ c.t \in HeldPs /\ c \in acting
    /\ IF hrow[c.t] = "held"
       THEN Hand(c) /\ H!Asked(c.t, c.t)
       ELSE Refused(c, HeldTo(c.t)) /\ UNCHANGED holdVars
    /\ UNCHANGED <<Rest, up, restarts, ownVars, askerVars>>

\* Intake writes the decision on the request (it closes), then marks the row. The cap's "yes"
\* is a block Claude Code honors: the turn goes on; its "no" lets the turn end.
Decides(p) ==
    /\ AgentUp /\ p \in HeldPs /\ H!Decides(p)
    /\ IF p = "cap" /\ Label(p) = "yes"
       THEN blocks' = blocks + 1 /\ turn' = "working"
       ELSE /\ turn' = IF p = "cap" THEN "ended" ELSE turn
            /\ UNCHANGED blocks
    /\ UNCHANGED <<rowVars, Rest, up, restarts, ownVars, tools, crashes, gaveUp>>

Marked(p) ==
    /\ up /\ p \in HeldPs /\ H!Marked(p)
    /\ UNCHANGED <<rowVars, Rest, up, restarts, ownVars, askerVars>>

\* A hold whose request a cut closed settles: held is lost, deciding unknown.
Settles(p) ==
    /\ up /\ p \in HeldPs /\ H!Settles(p)
    /\ UNCHANGED <<rowVars, Rest, up, restarts, ownVars, askerVars>>

\* Prompts reads its owner's row: an answering prompt settles by it once nothing of its
\* answer is under way; an open one whose hold died is lost.
SettleHeld(p) ==
    /\ up /\ p \in HeldPs
    /\ \/ hrow[p] \in {"answered", "unknown", "lost", "expired", "passed"}
       \/ hrow[p] = "held" /\ hconn[p]
    /\ Settle(p, HeldTo(p))
    /\ UNCHANGED <<Rest, up, restarts, holdVars, ownVars, askerVars>>

LostHeld(p) ==
    /\ up /\ p \in HeldPs /\ hrow[p] = "lost"
    /\ Lose(p)
    /\ UNCHANGED <<Rest, up, restarts, holdVars, ownVars, askerVars>>

\* The hand to any other owner. The limit's move is applied, its outcome known or not (it
\* may also not have applied, and say so unsure). The restarts' owner starts the agent
\* process again while its supervisor has given up, and refuses once it runs again.
HandOwner(c) ==
    LET p == c.t IN
    /\ up /\ p \notin HeldPs /\ c \in acting
    /\ IF p = "restarts" /\ ~gaveUp
       THEN Refused(c, "withdrawn") /\ UNCHANGED <<ownVars, crashes, gaveUp>>
       ELSE /\ Hand(c)
            /\ otold' = otold \cup {p}
            /\ IF p = "restarts"
               THEN /\ took' = [took EXCEPT ![p] = @ + 1]
                    /\ orec' = [orec EXCEPT ![p] = "applied"]
                    /\ gaveUp' = FALSE /\ crashes' = 0
               ELSE /\ \E applied \in BOOLEAN, sure \in BOOLEAN :
                          /\ applied \/ ~sure
                          /\ took' = [took EXCEPT ![p] = IF applied THEN @ + 1 ELSE @]
                          /\ orec' = [orec EXCEPT ![p] = IF sure THEN "applied" ELSE "unsure"]
                    /\ UNCHANGED <<crashes, gaveUp>>
    /\ UNCHANGED <<Rest, up, restarts, holdVars, turn, blocks, tools>>

OwnerTold(p) ==
    /\ up /\ p \in otold
    /\ Settle(p, IF orec[p] = "applied" THEN "answered" ELSE "unknown")
    /\ otold' = otold \ {p}
    /\ UNCHANGED <<Rest, up, restarts, holdVars, took, orec, askerVars>>

\* Once a restart cut the owner's answer, the owner's record is the evidence. Under
\* NoEvidence the row waits for that answer.
SettleOwner(p) ==
    /\ up /\ p \notin HeldPs /\ p \notin otold /\ Break # "NoEvidence"
    /\ Settle(p, CASE orec[p] = "applied" -> "answered"
                   [] orec[p] = "unsure" -> "cut"
                   [] OTHER -> "open")
    /\ UNCHANGED <<Rest, up, restarts, holdVars, ownVars, askerVars>>

\* What its owner applied of p's answers: a hold's decisions written, or the other owners'.
Took(p) == IF p \in HeldPs THEN Cardinality({i \in DOMAIN hout[p] : hout[p][i] = "decision"})
           ELSE took[p]

\* A person clears what the owner could not say, by what took: open again (its record
\* cleared) or answered; an unknown one answered or withdrawn.
Clears(p) ==
    /\ up
    /\ \/ Clear(p, IF Took(p) > 0 THEN "answered" ELSE "open")
       \/ Clear(p, IF Took(p) > 0 THEN "answered" ELSE "withdrawn")
    /\ orec' = IF st'[p] = "open" THEN [orec EXCEPT ![p] = "none"] ELSE orec
    /\ UNCHANGED <<Rest, up, restarts, holdVars, took, otold, askerVars>>

\* The restarts prompt's owner: its agent process runs again (a whole restart started it).
Passed ==
    /\ up /\ "restarts" \in Ps /\ ~gaveUp
    /\ Withdraw("restarts")
    /\ UNCHANGED <<Rest, up, restarts, holdVars, ownVars, askerVars>>

ClaimEnds(c) ==
    /\ up /\ ClaimSettled(c)
    /\ UNCHANGED <<Rest, up, restarts, holdVars, ownVars, askerVars>>

Init ==
    /\ st = [p \in Ps |-> "none"] /\ ep = [p \in Ps |-> 0]
    /\ kind = [p \in Ps |-> KindOf[p]] /\ asker = [p \in Ps |-> "child"]
    /\ claims = {} /\ acting = {} /\ cdone = {} /\ acted = {} /\ twice = FALSE /\ cut = {}
    /\ pwrong = {}
    /\ up = TRUE /\ restarts = 0
    /\ hconn = [p \in HeldPs |-> FALSE] /\ hrow = [p \in HeldPs |-> "none"]
    /\ hmarking = {} /\ hout = [p \in HeldPs |-> <<>>] /\ hwrong = {}
    /\ took = [p \in Ps |-> 0] /\ orec = [p \in Ps |-> "none"] /\ otold = {}
    /\ turn = "working" /\ blocks = 0 /\ tools = 0
    /\ crashes = 0 /\ gaveUp = FALSE

Next ==
    \/ FrameworkDies \/ FrameworkStarts \/ RestartAgent
    \/ Requests \/ StopFires \/ ToolCall \/ AtLimit \/ Passed
    \/ \E p \in Ps : \/ Held(p) \/ Opened(p) \/ Deadline(p) \/ Decides(p) \/ Marked(p)
                     \/ Settles(p) \/ SettleHeld(p) \/ LostHeld(p) \/ OwnerTold(p)
                     \/ SettleOwner(p) \/ Clears(p)
                     \/ \E who \in Answerers, l \in {"yes", "no"} : Answers(p, who, l)
    \/ \E c \in acting : HandHeld(c) \/ HandOwner(c)
    \/ \E c \in claims : ClaimEnds(c)

\* Fairness: the framework's steps and a person's answers and clears happen while possible;
\* the deadline, the app's callback, other answerers, Claude Code's hooks and calls, and
\* restarts happen or not.
Fairness ==
    /\ WF_vars(FrameworkStarts) /\ WF_vars(Passed)
    /\ \A p \in Ps :
          /\ WF_vars(Held(p)) /\ WF_vars(Opened(p)) /\ WF_vars(Decides(p))
          /\ WF_vars(Marked(p)) /\ WF_vars(Settles(p)) /\ WF_vars(SettleHeld(p))
          /\ WF_vars(LostHeld(p)) /\ WF_vars(OwnerTold(p)) /\ WF_vars(SettleOwner(p))
          /\ WF_vars(Clears(p))
          /\ \A who \in Persons : WF_vars(\E l \in {"yes", "no"} : Answers(p, who, l))
    /\ WF_vars(\E c \in acting : HandHeld(c) \/ HandOwner(c))
    /\ WF_vars(\E c \in claims : ClaimEnds(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* What must hold *)

TypeOK ==
    /\ st \in [Ps -> Statuses] /\ ep \in [Ps -> Nat]
    /\ acting \subseteq claims /\ cdone \subseteq claims
    /\ up \in BOOLEAN /\ restarts \in 0..MaxRestarts
    /\ took \in [Ps -> Nat] /\ orec \in [Ps -> {"none", "applied", "unsure"}] /\ otold \subseteq Ps
    /\ turn \in {"working", "stop", "ended"} /\ blocks \in 0..(Cap + 1)
    /\ crashes \in Nat /\ gaveUp \in BOOLEAN

\* A prompt's answer takes effect once.
OneAnswer == \A p \in Ps : Took(p) <= 1

\* Every answer is its rightful answerer's: a person's, the app's for its kinds, the parent's
\* for its kinds, or the framework's default.
OnlyRightful == \A c \in claims \cup acting : c.by = "framework" \/ Rightful(c.t, c.by)

\* No answer is taken once its prompt's deadline passed.
NotAfterDeadline == "late" \notin pwrong

\* The framework answers only by a default its kind declares.
DefaultOnlyDeclared ==
    \A c \in claims \cup acting : c.by = "framework" => kind[c.t] \in DefaultKinds

\* A row once opened stays, through every restart, until it settles.
KeptAcrossRestart == \A p \in Ps : ep[p] > 0 => st[p] # "none"

\* No Stop block of the framework's is overridden: the cap's is a person's.
NeverOverridden == "overridden" \notin pwrong

\* The Ledger's and Intake's, on the prompts' answers and holds.
OneClaimPerState == C!OneClaimPerState
NoActOnCutOffClaim == C!NoActOnCutOffClaim
OneResponse == H!OneResponse
LateDropped == H!LateDropped
OnlyNamed == H!OnlyNamed

\* Liveness. Every prompt shown ends: answered, expired, withdrawn, or lost with its
\* owner's request.
PromptsEnd == \A p \in Ps : st[p] \in Waiting ~> st[p] \in Ends

\* A budget run out is a prompt, and its answer starts the agent process again.
Escalated == gaveUp ~> ~gaveUp

\* Every hold closes and settles; every claim ends.
HoldsEnd == H!RequestsEnd
ClaimsEnd == C!ClaimsEnd

=============================================================================
