# Reading the specs

The specs in this directory are TLA+. This page is enough to read them if you know Elixir.

## What a spec is

A spec describes a system as a **state** and the **steps** that change it. TLC, the model
checker, starts from every initial state and tries every step in every order, up to the bounds a
configuration sets, and checks that nothing it lists goes wrong in any state it reaches.

- `VARIABLES` are the state: like the fields of a GenServer's state, but for the whole system
  (the tmux server, the sockets, the processes), not one process.
- `Init` says what the variables hold at the start.
- An **action** is one step, named after the event: `ServerDies`, `ViewerReopened`. It is a
  formula over the variables now (`panes`) and after the step (`panes'`, read "panes prime"). It
  is like a `handle_info` clause whose guard is its first lines and whose result is the primed
  variables. A step that lists a variable as `UNCHANGED` leaves it as it was.
- `Next` is every action joined with `\/` (or): any enabled step may come next.
- `Spec` is `Init`, then any number of `Next` steps, plus **fairness**: the steps the framework
  itself takes (restarting its server, sampling, reopening) eventually happen when they stay
  possible. Events from outside (a server dying, a process exiting) may or may not happen.

## Notation

| TLA+ | Elixir, roughly |
|---|---|
| `/\`, `\/`, `~` | `and`, `or`, `not` (a list of `/\` lines is all of them) |
| `x = y`, `x # y` | `x == y`, `x != y` |
| `\A a \in S : P` | `Enum.all?(s, fn a -> p end)` |
| `\E a \in S : P` | `Enum.any?(s, fn a -> p end)`; in an action, "for some `a`, this step" |
| `{a \in S : P}` | `for a <- s, p, into: MapSet.new()` |
| `{f(a) : a \in S}` | `MapSet.new(s, &f/1)` |
| `S \cup T`, `S \ T` | `MapSet.union/2`, `MapSet.difference/2` |
| `[a \in S \|-> e]` | `Map.new(s, fn a -> {a, e} end)`: a function is a map with a fixed key set |
| `f[a]`, `DOMAIN f` | `f[a]`, `Map.keys(f)` |
| `[f EXCEPT ![a] = e]` | `%{f \| a => e}` |
| `[pid \|-> 1, socket \|-> a1]` | `%{pid: 1, socket: :a1}` |
| `r.pid` | `r.pid` |
| `LET x == e IN body` | `x = e` then `body` |
| `IF c THEN a ELSE b` | `if c, do: a, else: b` |
| `CHOOSE x \in S : P` | some fixed `x` in `s` with `p`, the same one every time |
| `x == e` | a definition, like a `defp` |

## Properties

- An **invariant** must be true in every reachable state: `OneProcessPerSocket`.
- `[][A]_vars` says every step satisfies `A`: `AgentOutlivesServer` says the step in which
  the server dies ends no process.
- `P ~> Q`, "P leads to Q": whenever `P` holds, `Q` holds then or later. `LostViewerReopened`
  says a held agent with no viewer later has one, or has ended.

## Configurations and `Break`

A `.cfg` file gives the constants (`Agents = {a1, a2}`, the `Max*` bounds) and the invariants
and properties to check. `Agent_*.cfg` checks the design. `Break_Agent_<Bug>.cfg` sets the
`Break` constant, which turns off one guard in the spec, and must make TLC report a violation:
it shows the check would catch that bug. When TLC finds one, its output in
`_build/tlc/<name>.out` lists the states, step by step, that lead to it.

Run them with `devenv shell -- bin/check-model` (see its header).

## `Move.tla`

A parent session moves from account `Home` to the other one. Read it in the order of a move:

- `Drain` (a press, or `UsageRises` to 90 %) sets `phase` to `"draining"`. From then on
  `BgStarted` and `DelegateStarted` are refused (`Draining`).
- `Cleared` is the Mover reading that no background command runs. It is a reading, not a lock:
  only the drain keeps it true until the end.
- `EndAsked` ends the process once its turn has ended; `ProcessExits` is the process going, with
  whatever still runs in it, which goes into `lost`. It sends a `SessionEnd`, held in `ends`
  until `SessionEndArrives` handles it, at any later time.
- `Copied` then `Resumed` start a new process on `target` from the copied transcript.
- Delegates outlive the parent's process: `ReportDelivered` waits for a live one.

`procs` holds the session's processes as `[pid, account, ending]`; `turn` is the pid whose turn
runs, or `0`. `NoStartWhileDraining` is a step property, like `AgentOutlivesServer`: no step taken
while the move runs starts anything. `DelegatesStarted'` is that count after the step.

## `Delegate.tla`

A parent, its delegates, and restarts of the framework. Read it in the order of a report's path:

- `StartAsked` is `start_delegate` in a parent's turn: refused by a check, or by the cap, or
  started.
- `DelegateFinishes` ends the delegate's turn with its last reply (`reply`) and fires its Stop
  hook, which lands in `stops` only while the framework runs. `StopHandled` turns it into a held
  report; when a restart lost it, `TranscriptRead` reads the last reply instead.
- `DelegateKilled` then `KillSeen`: the first kill is resumed, the second is the report.
- `DeliveryAsked` marks the row `"sending"` once the parent's turn has ended. `DeliveryTyped`
  is `Control`'s checked write, or `DeliveryRefused` holds the report again. `DeliveryMarked`
  writes `"delivered"`. A restart in between leaves `"sending"` with nothing in memory, and
  `SendingResolved` reads the parent's transcript (`got`) to settle it.
- `DelegateEnds` waits for `"delivered"`.

`FrameworkDies` clears what the framework holds in memory (`stops`, `sending`); the tables
(`status`, `report`, `resumes`) stay. `got` counts the report in the parent's transcript, and
`wrong` records a report typed where the check must refuse it. `SF_vars`, strong fairness, says a
step that is possible again and again, not always, happens: the user's prompts may take the
parent's turn each time a report waits for it.
