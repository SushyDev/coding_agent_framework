defmodule CodingAgentFramework.MCP do
  @moduledoc """
  The agents' tools (`docs/design.md`, "Agents working together"): who calls, the call log, and
  the tools. One process with no name, started by the embedding app, the one writer of
  `CodingAgentFramework.MCP.Table`; a call works in the caller's process, as the endpoint's
  request (`CodingAgentFramework.MCP.Plug`).

  **Who calls.** `issue/2` makes an agent a token and writes its MCP config,
  `<dir>/agents/<agent>.json`, with one `http` server entry, `caf`, that carries the token in
  the `x-caf-token` header. `CodingAgentFramework.ClaudeCLI` names that file at the agent's
  launch (`mcp:`). `who/2` maps a token to its agent; no argument of a call names the caller.

  **A call** (`call/4`) is written `called` before it acts and `answered` with its outcome, a
  refusal included. It answers `{:ok, value}`, `{:refused, reason}` or `{:unknown, reason}`:

  - `message(to, text)`: `Grants.may_message?/3`, then the mailbox's `message/5`;
  - `run(host, argv, timeout, opts)`: `Grants.may_use?/2`, then the jobs' `run/6`, as job
    `mcp-<instance>-<call id>` in the copy of the caller's worktree that `place` names, with
    `timeout` (ms, at most the `:cap`, a day unless the app says) as the job's and the call's.
    `opts` may name `fetch` (paths) and `class` (`heavy` by default, `builder` or `landing`):
    with the app's `lease:` function, of the class and the caller's project, the job asks the
    `Scheduler` for a lease of the units it answers, in that class, all in one request, so a
    landing's slot and lock are one gang lease. The answer is `Jobs`' own, except an unknown one: it is
    `{:unknown, %{job: id, reason: reason}}`, so the caller can match the job's late end,
    which comes as a message, to the call;
  - `start_delegate(project, branch, model, brief)`: `Grants.may_start_delegate?/3`, then the
    delegates' `start_delegate/7` with the caller as parent (the operator names a main session
    as `parent`); answers `%{delegate: name}`, or the start's refusal. The report comes later
    as a message. Both take optional `options`;
  - `run_delegate(project, branch, model, brief, timeout)`: as `start_delegate`, then the
    mailbox's `await/4` on the report, the answer to the brief's uuid, all within `timeout`
    (ms, capped as `run`'s, and under the client's tool timeout less the margin:
    `:tool_timeout` and `:margin`, so the client never gives up first). Answers `%{delegate:
    name, status: status, report: text}`, `status` `finished` for the delegate's reply and
    `failed` for the framework's notice, or at the timeout `{:unknown, %{delegate: name,
    reason: :timeout}}`, the report then due for another transport. A report it took is
    `sending` by the call in `Mailbox` until the answer is written, then `told/3` `:written`
    when the write succeeded, or anything else (due again) when it failed (`answer/5`). A call
    through `call/4` has its answer in hand, so it is told `:written` at once;
  - `start_main(project, name, brief)` (F-141): `Grants.may_start_main?/2` (a main session, or
    the operator), then the mains' `start_main/5`, the brief from the caller; answers `%{main:
    name}` once the session runs, `{:unknown, {:dialog, kind}}` while its start waits on a
    person's answer to a startup dialog, or the start's refusal (`{:running, name}` for a name
    in use or reserved);
  - `ask(questions)`: the mailbox's `ask/4`, which checks the questions and the caller and
    stores the ask for the app; answers `%{ask: id}` at once. The person's answer comes later
    as a message (`Mailbox.answer/4`);
  - `reload()`: `Grants.may_use?/2`, then the tools' names; the endpoint sends the client
    `notifications/tools/list_changed` first;
  - the service tools, each through the services' own function, which makes its own `Grants`
    check, and answers as it does: `service_start(name, argv, opts)` (`start/5` in the copy
    `place` names, on `opts`' `host`, the `:workstation` unless named, with its `forward`, the
    `local` port it is forwarded to (the same port unless named), and `keep`; its `timeout`,
    capped as `run`'s, bounds the whole start), `service_send(name, input)` (`send/5`), `service_restart(name)` (`restart/4`),
    `service_stop(name)` (`stop/4`), `service_hand(name, to)` (`hand/4`). Those open to any
    agent take `Grants.may_use?/2` first: `services()` (`list/1`, each row's name, host,
    owner, state, restarts and ports), `service_logs(name, from)` (`logs/4`), and
    `service_wait(name, until, timeout)` (`wait/4`, `timeout` capped as `run`'s), where `until`
    is `{"line": pattern}` (from the current start's offset), `{"port": n}` or `"exit"`;
  - `agents(all)`: `Grants.may_use?/2`, then the tree as the `Tracker` reads it from its view
    (`Tracker.agents/2`, `CodingAgentFramework.Tracker.Tree`), never a copy kept here; a
    delegate that ended shows only with `all: true`;
  - `look(agent)`, `transcript(agent, from)`: `Grants.may_read?/3`, then the agent in the tree.
    `look`: a delegate's state, held requests, and last lines of its event log (`Stream.log/4`)
    and transcript (`Transcripts.text/4`), each with its own refusal; `transcript`: whole lines
    from byte `from`, and the next offset. A main session is refused until `Screen` and `Mains`.
  - the fix tools, a parent's on its own delegate, or the operator's on any (`Grants.may_fix?/3`;
    no agent fixes a main session, and the operator's fix of one is refused `{:not_built,
    :main_fix}` until `Mains`): `interrupt(agent)`, `answer(agent, dialog, label)` (`dialog` is the open
    `can_use_tool` request's id, `label` `allow` or `deny`), `resume(agent)` (a delegate whose
    process died) and `stop(agent)` (once its report is delivered). Each reads the delegate's
    state (`Delegates.fix_state/3`), claims it in `Acts` (`Acts.claim/6`, act the tool's name),
    then `Delegates.fix/5` acts only while that state is still the delegate's, and the claim
    is settled `verified` when the fix answered `ok` and the state read after has moved, else
    `not_verified`. A second fix of a state is refused `{:claimed, by}` or
    `{:already_claimed, by}`. Answers `%{done: value, claim: id, settled: settle's answer}`,
    or the fix's refusal or unknown.
  - `move(agent, to)`: `Grants.may_fix?/3`, then the mover's `move/4` (`to` optional: by default
    the account with the most allowance left), which claims the act `move` in `Acts` and settles
    it when the move ends. Answers `%{act: id, from: account, to: account}` once the drain began.
  - `answer_startup(agent, kind, label)`: the operator's alone (F-140); any other caller is
    refused `:operator_only`. The startup dialog an interactive start waits on (`kind`
    `trust` or `imports`, as the agent row shows it, `Sessions.Agents.dialog/1`), answered by
    its option's label through the sessions' `answer_dialog/5`, which marks the answer on the
    row before its checked press and never presses it twice. Answers `Sessions`' answer.

  **The operator** calls the same tools through `operate/3`, which writes its row under the
  operator's name, so each act it makes names it as the actor; `issue/2` never makes it a
  token. The design's other tools come in later parts (`docs/build-notes/F-86.md`).

      {:ok, mcp} = MCP.start_link(dir: dir, port: 4791, grants: grants, acts: acts,
        mailbox: {Mailbox, mailbox}, jobs: {Jobs, jobs}, delegates: {Delegates, delegates},
        services: {Services, services}, workstation: "ws", tracker: {Tracker, tracker},
        stream: {Stream, stream}, transcripts: {Transcripts, t}, place: &place/1,
        instance: "a", tool_timeout: 3_600_000, margin: 60_000)
      {:ok, config} = MCP.issue(mcp, "app-fix")
      MCP.call(mcp, "app-fix", "message", %{"to" => "app-main", "text" => "Done."})
      #=> {:ok, {:queued, 3}}
  """

  use GenServer

  alias CodingAgentFramework.Grants
  alias CodingAgentFramework.Acts
  alias CodingAgentFramework.MCP.Table

  @step 5_000
  # The most bytes of a log or a transcript one answer carries.
  @window 16_384
  # A read takes one byte past the window, so `lines/2` can tell a longer line from one that fits.
  @read_max @window + 1
  # The default cap on a `run`'s timeout: a job the caller forgot still ends within a day.
  @day 86_400_000
  @agent ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  # The most a delegate's start may take of a `run_delegate`'s timeout: `Delegates`' own default.
  @start_wait 300_000
  @options %{type: "object", description: "the delegate's own launch options (ClaudeCLI.Options)"}
  @start Map.new(~w(project branch model brief)a, &{&1, %{type: "string"}})
         |> Map.put(:options, @options)
         |> Map.put(:interactive, %{
           type: "boolean",
           description: "runs the terminal interface, so a person can attach and type"
         })
  # `Services` checks a name's form; the tool only needs a string to call it.
  @name %{type: "string", description: "1 to 64 letters, digits, - or _"}
  @timeout %{type: "integer", minimum: 1, description: "ms, at most a day"}
  @row ~w(name host owner state restarts port local)a
  @str %{type: "string"}
  @fixes ~w(interrupt answer resume stop)

  @tools [
    %{
      name: "message",
      description: "Sends a message to an agent along an edge of the tree.",
      inputSchema: %{
        type: "object",
        properties: %{to: %{type: "string"}, text: %{type: "string"}},
        required: ["to", "text"]
      }
    },
    %{
      name: "run",
      description: "Runs a job on a host in a copy of your worktree; answers its exit and log.",
      inputSchema: %{
        type: "object",
        properties: %{
          host: %{type: "string"},
          argv: %{type: "array", items: %{type: "string"}},
          timeout: %{type: "integer", description: "ms, at most a day"},
          opts: %{
            type: "object",
            properties: %{
              fetch: %{type: "array", items: %{type: "string"}},
              class: %{
                type: "string",
                enum: ["heavy", "builder", "landing"],
                description:
                  "the lease's class: a heavy run (default), a builder's suite, or a landing's gates"
              }
            }
          }
        },
        required: ["host", "argv", "timeout"]
      }
    },
    %{
      name: "start_delegate",
      description:
        "Starts a delegate on a branch; answers its name. Its report comes as a message.",
      inputSchema: %{
        type: "object",
        properties: @start,
        required: ["project", "branch", "model", "brief"]
      }
    },
    %{
      name: "run_delegate",
      description: "Starts a delegate and answers its report, or its name at the timeout.",
      inputSchema: %{
        type: "object",
        properties:
          Map.put(@start, :timeout, %{
            type: "integer",
            description: "ms, under the framework's tool timeout less its margin"
          }),
        required: ["project", "branch", "model", "brief", "timeout"]
      }
    },
    %{
      name: "start_main",
      description:
        "Starts a main session of a project under a name not in use, in its checkout; " <>
          "the brief is its first message. Answers its name.",
      inputSchema: %{
        type: "object",
        properties: %{project: @str, name: @name, brief: @str},
        required: ["project", "name", "brief"]
      }
    },
    %{
      name: "service_start",
      description: "Holds argv as a service on a host, in a copy of your worktree.",
      inputSchema: %{
        type: "object",
        properties: %{
          name: @name,
          argv: %{type: "array", items: %{type: "string"}, minItems: 1},
          opts: %{
            type: "object",
            properties: %{
              host: %{type: "string", description: "the workstation unless named"},
              forward: %{type: "integer", minimum: 1, maximum: 65_535},
              local: %{
                type: "integer",
                minimum: 1,
                maximum: 65_535,
                description:
                  "the workstation's port for the forward; the service's port unless named"
              },
              keep: %{type: "boolean", description: "goes to your parent when you end"}
            }
          },
          timeout: Map.put(@timeout, :description, "ms, at most a day; bounds the whole start")
        },
        required: ["name", "argv"]
      }
    },
    %{
      name: "services",
      description: "Each service: name, host, owner, state, restarts, forwarded port.",
      inputSchema: %{type: "object", properties: %{}}
    },
    %{
      name: "service_logs",
      description: "A service's output from a byte offset; answers the text and the next offset.",
      inputSchema: %{
        type: "object",
        properties: %{name: @name, from: %{type: "integer", minimum: 0}},
        required: ["name", "from"]
      }
    },
    %{
      name: "service_send",
      description: "Sends text or keys to your service's terminal (\\n is Enter). Never resent.",
      inputSchema: %{
        type: "object",
        properties: %{name: @name, input: %{type: "string", maxLength: 65_536}},
        required: ["name", "input"]
      }
    },
    %{
      name: "service_wait",
      description:
        "Waits until a log line of the current start matches, a port listens, or the service exits.",
      inputSchema: %{
        type: "object",
        properties: %{
          name: @name,
          until: %{
            oneOf: [
              %{
                type: "object",
                properties: %{line: %{type: "string", description: "a regex"}},
                required: ["line"]
              },
              %{
                type: "object",
                properties: %{port: %{type: "integer", minimum: 1, maximum: 65_535}},
                required: ["port"]
              },
              %{type: "string", enum: ["exit"]}
            ]
          },
          timeout: @timeout
        },
        required: ["name", "until", "timeout"]
      }
    },
    %{
      name: "service_restart",
      description: "Restarts a service you own, or your child owns.",
      inputSchema: %{type: "object", properties: %{name: @name}, required: ["name"]}
    },
    %{
      name: "service_stop",
      description: "Ends a service you own, or your child owns.",
      inputSchema: %{type: "object", properties: %{name: @name}, required: ["name"]}
    },
    %{
      name: "service_hand",
      description: "Hands a service you own to your parent or one of your children.",
      inputSchema: %{
        type: "object",
        properties: %{name: @name, to: %{type: "string"}},
        required: ["name", "to"]
      }
    },
    %{
      name: "agents",
      description:
        "The tree: each agent's name, kind, project, parent, account, state, waits and " <>
          "subagents. A delegate that ended shows only with all: true.",
      inputSchema: %{type: "object", properties: %{all: %{type: "boolean"}}}
    },
    %{
      name: "look",
      description:
        "An agent's last event-log lines, its open requests and its last transcript lines.",
      inputSchema: %{type: "object", properties: %{agent: %{type: "string"}}, required: ["agent"]}
    },
    %{
      name: "transcript",
      description:
        "An agent's transcript from a byte offset; answers the text and the next offset.",
      inputSchema: %{
        type: "object",
        properties: %{agent: %{type: "string"}, from: %{type: "integer", minimum: 0}},
        required: ["agent", "from"]
      }
    },
    %{
      name: "interrupt",
      description: "Interrupts your delegate's turn, under a claim on its current state.",
      inputSchema: %{type: "object", properties: %{agent: @str}, required: ["agent"]}
    },
    %{
      name: "answer",
      description:
        "Answers your delegate's open permission request (dialog: its request id) with allow or deny.",
      inputSchema: %{
        type: "object",
        properties: %{
          agent: @str,
          dialog: @str,
          label: %{type: "string", enum: ["allow", "deny"]}
        },
        required: ["agent", "dialog", "label"]
      }
    },
    %{
      name: "resume",
      description: "Resumes your delegate whose process died, once per state, under a claim.",
      inputSchema: %{type: "object", properties: %{agent: @str}, required: ["agent"]}
    },
    %{
      name: "stop",
      description: "Ends your delegate once its report is delivered, under a claim.",
      inputSchema: %{type: "object", properties: %{agent: @str}, required: ["agent"]}
    },
    %{
      name: "move",
      description:
        "Moves your delegate to another account (to: its name, or the one with the most allowance left): drained, ended once idle, resumed there.",
      inputSchema: %{
        type: "object",
        properties: %{agent: @str, to: @str},
        required: ["agent"]
      }
    },
    %{
      name: "answer_startup",
      description:
        "The operator's: answers the startup dialog (trust or imports) an agent's start waits " <>
          "on, by its option's label, as the agent row shows it.",
      inputSchema: %{
        type: "object",
        properties: %{
          agent: @str,
          kind: %{type: "string", enum: ["trust", "imports"]},
          label: @str
        },
        required: ["agent", "kind", "label"]
      }
    },
    %{
      name: "ask",
      description:
        "Asks a person one to four questions, each with two to four options; answers the " <>
          "ask's id at once. The answer comes later as a message, one line per question.",
      inputSchema: %{
        type: "object",
        properties: %{
          questions: %{
            type: "array",
            minItems: 1,
            maxItems: 4,
            items: %{
              type: "object",
              properties: %{
                header: %{type: "string", description: "a short tag for the question"},
                question: @str,
                options: %{
                  type: "array",
                  minItems: 2,
                  maxItems: 4,
                  items: %{
                    type: "object",
                    properties: %{label: @str, description: @str},
                    required: ["label", "description"]
                  }
                },
                multiSelect: %{type: "boolean", description: "the person may choose several"}
              },
              required: ["header", "question", "options", "multiSelect"]
            }
          }
        },
        required: ["questions"]
      }
    },
    %{
      name: "reload",
      description: "Reloads your own tools.",
      inputSchema: %{type: "object", properties: %{}}
    }
  ]

  @doc """
  Starts the part. Options: `:dir` (a directory of its own: the table and the agents' configs),
  `:port` (where the embedding app serves the endpoint on 127.0.0.1), `:grants`, `:mailbox`,
  `:jobs`, `:delegates`, `:services`, `:tracker` and `:stream` (each `{module, server}`:
  `{CodingAgentFramework.Mailbox, pid}`, `{CodingAgentFramework.Jobs, pid}`,
  `{CodingAgentFramework.Delegates, pid}`, `{CodingAgentFramework.Services, pid}`,
  `{CodingAgentFramework.Tracker, pid}`, `{CodingAgentFramework.Stream, pid}`, or a stand-in
  module with the same functions), `:transcripts` (the host's
  `{CodingAgentFramework.Transcripts, pid}`, or nil), `:workstation` (the host a service starts on
  unless its call names one), and
  `:place`, a function of an agent's name that answers `{:ok, %{project: p, name: n, worktree:
  path}}` (the copy jobs and services run in) or `{:refused, reason}`. `:acts` is the
  instance's `CodingAgentFramework.Acts`, where each fix takes its claim. `:mover` (optional)
  is `{CodingAgentFramework.Mover, pid}`, which the `move` tool calls; without it `move` is
  refused `:no_mover`. `:sessions` (optional) is `{CodingAgentFramework.Sessions, pid}`, which
  `answer_startup` calls; without it that tool is refused `:no_sessions`. `:mains` (optional) is
  `{CodingAgentFramework.Mains, pid}`, which `start_main` calls; without it that tool is refused
  `:no_mains`. `:lease` (optional) is
  a function of a job's class (`:heavy`, `:builder`, `:landing`) and the caller's project that
  answers `{:ok, units}`, the units of each resource the `Scheduler` leases that the job needs,
  or `{:refused, reason}`; without it `run` names no lease. `:instance` (a string, required)
  is this part's name in its jobs' ids, so two of them sharing one `Jobs` never make the same
  id. `:cap` (ms, default a day) is the most a `run`'s or a `service_wait`'s `timeout` may be.
  `:tool_timeout` (ms) is the MCP tool timeout `CodingAgentFramework.ClaudeCLI` sets for every
  agent at launch, and `:margin` (ms, under it) how far under it a `run_delegate`'s `timeout`
  must stay: both required, positive integers.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The tools, as `tools/list` answers them."
  @spec tools() :: [map]
  def tools, do: @tools

  @doc """
  Makes `agent` a new token, in place of any earlier one, and writes its MCP config. Answers
  `{:ok, path}`, `{:refused, {:bad, :agent}}`, or `{:unknown, reason}` when the write fails.
  """
  @spec issue(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:refused, term} | {:unknown, term}
  def issue(mcp, agent) do
    if is_binary(agent) and agent =~ @agent,
      do: ask(mcp, {:issue, agent}),
      else: {:refused, {:bad, :agent}}
  end

  @doc "The agent `token` was made for: `{:ok, agent}` or `{:refused, :unknown_token}`."
  @spec who(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:refused, term} | {:unknown, term}
  def who(mcp, token), do: ask(mcp, {:who, token})

  @doc """
  Calls `tool` with `args` (a JSON object) as `agent`, for a caller that takes the outcome in
  its own process; see the module's doc.
  """
  @spec call(GenServer.server(), String.t(), String.t(), map) ::
          {:ok, term} | {:refused, term} | {:unknown, term}
  def call(mcp, agent, tool, args) do
    {:ok, outcome} = answer(mcp, agent, tool, args, &{:ok, &1})
    outcome
  end

  @doc """
  Calls `tool` with `args` as the operator (`docs/design.md`, "Concepts"): the person or the
  app acting from outside the tree, under the name `Grants` was given. The call takes the same
  path as an agent's, its checks, claims and row in the call log, which names the operator.
  `start_delegate` and `run_delegate` take `parent`, the main session the delegate is under;
  a fix acts as the target's parent would. `{:refused, :no_operator}` when `Grants` has none.
  `CodingAgentFramework.Operator` names each act.

      MCP.operate(mcp, "interrupt", %{"agent" => "app-unit-review"})
      #=> {:ok, %{done: :sent, claim: 4, settled: {:ok, :verified}}}
  """
  @spec operate(GenServer.server(), String.t(), map) ::
          {:ok, term} | {:refused, term} | {:unknown, term}
  def operate(mcp, tool, args), do: call(mcp, :operator, tool, args)

  @doc """
  Calls `tool` as `call/4` does, then writes its outcome with `write`, the endpoint's write of
  the answer to the agent, and answers what `write` answered. `write` answers `{:ok, _}` once
  the answer is written, and anything else when it was not; a report `run_delegate` took is
  then `answered`, or held again. A refusal before the call is written is written too.

      MCP.answer(mcp, "app-main", "run_delegate", args, fn outcome -> send_it(conn, outcome) end)
      #=> {:ok, conn}
  """
  @spec answer(GenServer.server(), String.t(), String.t(), map, (term -> written)) :: written
        when written: term
  def answer(mcp, agent, tool, args, write) do
    case ask(mcp, {:called, agent, tool, JSON.encode!(args)}) do
      {:ok, id, ctx, agent} ->
        {outcome, taken} = taken(act(ctx, agent, id, tool, args))
        # The outcome stands whether or not its row is written; a row left `called` reads `cut`.
        ask(mcp, {:answered, id, JSON.encode!(json(outcome))})
        written = write.(outcome)
        if taken, do: settle(ctx, taken, written)
        written

      not_called ->
        write.(not_called)
    end
  end

  # A report taken is delivered once written and due again otherwise. When `Mailbox` cannot be
  # told, the end of this process, which it watches, makes the row due again.
  defp settle(%{mailbox: {mod, server}}, id, {:ok, _}), do: mod.told(server, id, :written)
  defp settle(%{mailbox: {mod, server}}, id, _failed), do: mod.told(server, id, :failed)

  # The report is the delegate's reply, or the framework's notice of a second kill.
  defp status(%{kind: "reply"}), do: "finished"
  defp status(_notice), do: "failed"

  defp taken({:taken, id, outcome}), do: {outcome, id}
  defp taken(outcome), do: {outcome, nil}

  @doc """
  The caller of job `job`, as `run` named it (`mcp-<instance>-<call id>`), read from the call
  log in `dir` (the `:dir` the part was started with). It asks no process, so the embedding
  app can route a job's late end while `MCP` is not running: `Jobs` hands the ends it owes as
  it starts, before `MCP`, which is given `Jobs`, has started. Answers `{:ok, agent}`,
  `{:refused, {:not_ours, job}}` for an id this instance did not make, `{:refused, {:no_call,
  id}}`, or `{:unknown, reason}`.

      MCP.caller("/srv/caf/parts/mcp", "a", "mcp-a-7")
      #=> {:ok, "app-unit-review"}
  """
  @spec caller(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:refused, term} | {:unknown, term}
  def caller(dir, instance, job) do
    with ["", id] <- String.split(job, "mcp-#{instance}-", parts: 2),
         {id, ""} <- Integer.parse(id) do
      Table.caller(Path.join(dir, "mcp.db"), id)
    else
      _ -> {:refused, {:not_ours, job}}
    end
  end

  @doc "Every call's row, oldest first."
  @spec calls(GenServer.server()) :: [map] | {:unknown, term}
  def calls(mcp), do: ask(mcp, :calls)

  @doc "An outcome as JSON data: atoms as strings, tuples as lists."
  @spec json(term) :: term
  def json({:ok, v}), do: %{"ok" => json(v)}
  def json({:refused, v}), do: %{"refused" => json(v)}
  def json({:unknown, v}), do: %{"unknown" => json(v)}
  def json(v) when is_boolean(v) or is_nil(v) or is_number(v) or is_binary(v), do: v
  def json(v) when is_atom(v), do: Atom.to_string(v)
  def json(v) when is_tuple(v), do: v |> Tuple.to_list() |> json()
  def json(v) when is_list(v), do: Enum.map(v, &json/1)
  def json(v) when is_map(v), do: Map.new(v, fn {k, x} -> {to_string(json(k)), json(x)} end)
  def json(v), do: inspect(v)

  defp act(ctx, caller, _id, "message", %{"to" => to, "text" => text})
       when is_binary(to) and is_binary(text) do
    {mod, server} = ctx.mailbox

    with :ok <- Grants.may_message?(ctx.grants, caller, to),
         do: mod.message(server, caller, to, text, timeout: @step)
  end

  defp act(
         ctx,
         caller,
         id,
         "run",
         %{"host" => host, "argv" => [_ | _] = argv, "timeout" => t} = a
       )
       when is_binary(host) and is_integer(t) and t > 0 and t <= ctx.cap do
    {mod, server} = ctx.jobs
    fetch = get_in(a, ["opts", "fetch"]) || []

    with true <-
           (is_list(fetch) and Enum.all?(argv ++ fetch, &is_binary/1)) or
             {:refused, {:bad, :args}},
         {:ok, class} <- job_class(get_in(a, ["opts", "class"])),
         :ok <- Grants.may_use?(ctx.grants, caller),
         {:ok, %{project: p, name: n, worktree: w}} <- ctx.place.(caller),
         {:ok, lease} <- job_lease(ctx, class, p) do
      job = "mcp-#{ctx.instance}-#{id}"
      where = %{host: host, project: p, name: n}

      case mod.run(server, job, where, w, argv, [timeout: t, fetch: fetch] ++ lease) do
        {:unknown, reason} -> {:unknown, %{job: job, reason: reason}}
        answer -> answer
      end
    end
  end

  defp act(ctx, caller, _id, "start_delegate", args) do
    with {:ok, start} <- start_args(ctx, args, caller),
         {:ok, %{name: name}} <- start_delegate(ctx, caller, start, @start_wait),
         do: {:ok, %{delegate: name}}
  end

  defp act(ctx, caller, _id, "run_delegate", %{"timeout" => t} = args)
       when is_integer(t) and t > 0 and t <= ctx.cap do
    deadline = now() + t
    {mod, server} = ctx.mailbox
    under = ctx.tool_timeout - ctx.margin

    with true <- t < under or {:refused, {:timeout, {:under, under}}},
         {:ok, [parent | _] = start} <- start_args(ctx, args, caller),
         {:ok, %{name: name, brief_uuid: key}} <-
           start_delegate(ctx, caller, start, min(t, @start_wait)) do
      left = deadline - now()
      answer = if left > 0, do: mod.await(server, parent, key, left), else: {:unknown, :timeout}

      case answer do
        {:ok, r} -> {:taken, r.id, {:ok, %{delegate: name, status: status(r), report: r.text}}}
        {:unknown, reason} -> {:unknown, %{delegate: name, reason: reason}}
        refused -> refused
      end
    end
  end

  # A main session's start answers once its session runs, or once it waits on a person.
  defp act(ctx, caller, _id, "start_main", %{"project" => p, "name" => n, "brief" => b})
       when is_binary(p) and is_binary(n) and is_binary(b) do
    with :ok <- Grants.may_start_main?(ctx.grants, caller),
         true <- ctx.mains != nil or {:refused, :no_mains},
         {mod, server} = ctx.mains,
         {:ok, %{name: name}} <-
           mod.start_main(server, p, n, b, from: caller, timeout: @start_wait),
         do: {:ok, %{main: name}}
  end

  # A move is a fix's act (`Grants.may_fix?/3`: a parent's of its delegate, the operator's of
  # any agent, never a main session's own), claimed in `Acts` by `Mover`, which settles it when
  # the move ends.
  defp act(ctx, caller, _id, "move", %{"agent" => agent} = a) when is_binary(agent) do
    with true <- is_nil(a["to"]) or is_binary(a["to"]) or {:refused, {:bad, :args}},
         true <- ctx.mover != nil or {:refused, :no_mover},
         :ok <- Grants.may_fix?(ctx.grants, caller, agent) do
      {mod, server} = ctx.mover
      mod.move(server, caller, agent, to: a["to"])
    end
  end

  # A startup dialog is a person's to answer: the operator's tool alone, never an agent's.
  defp act(ctx, caller, _id, "answer_startup", %{"agent" => agent, "kind" => k, "label" => l})
       when is_binary(agent) and is_binary(k) and is_binary(l) do
    with true <- caller == Grants.operator(ctx.grants) or {:refused, :operator_only},
         true <- ctx.sessions != nil or {:refused, :no_sessions} do
      {mod, server} = ctx.sessions
      mod.answer_dialog(server, agent, k, l)
    end
  end

  # The ask is stored and answered at once: nothing here waits for the person.
  defp act(ctx, caller, _id, "ask", %{"questions" => questions}) do
    {mod, server} = ctx.mailbox

    case mod.ask(server, caller, questions, timeout: @step) do
      {:ok, {:asked, id}} -> {:ok, %{ask: id}}
      other -> other
    end
  end

  defp act(ctx, caller, _id, "reload", _args) do
    with :ok <- Grants.may_use?(ctx.grants, caller),
         do: {:ok, %{tools: Enum.map(@tools, & &1.name)}}
  end

  defp act(_ctx, _caller, _id, "service_start", %{"opts" => o}) when not is_map(o),
    do: {:refused, {:bad, :args}}

  defp act(ctx, caller, _id, "service_start", %{"name" => name, "argv" => [_ | _] = argv} = a) do
    {mod, server} = ctx.services
    opts = Map.get(a, "opts", %{})
    host = Map.get(opts, "host", ctx.workstation)
    forward = Map.get(opts, "forward")
    local = Map.get(opts, "local")
    keep = Map.get(opts, "keep", false)
    timeout = Map.get(a, "timeout")

    with true <-
           (is_binary(name) and Enum.all?([host | argv], &is_binary/1) and is_boolean(keep) and
              (is_nil(forward) or forward in 1..65_535) and
              (is_nil(local) or (forward != nil and local in 1..65_535)) and
              (is_nil(timeout) or (is_integer(timeout) and timeout > 0 and timeout <= ctx.cap))) or
             {:refused, {:bad, :args}},
         {:ok, %{project: p, name: n, worktree: w}} <- ctx.place.(caller) do
      forward = if local, do: {forward, local}, else: forward
      where = [host: host, project: p, copy: n, worktree: w, keep: keep, forward: forward]
      where = if timeout, do: [{:timeout, timeout} | where], else: where
      mod.start(server, caller, name, argv, where)
    end
  end

  defp act(ctx, caller, _id, "services", _args) do
    {mod, server} = ctx.services

    with :ok <- Grants.may_use?(ctx.grants, caller) do
      case mod.list(server) do
        rows when is_list(rows) -> {:ok, Enum.map(rows, &Map.take(&1, @row))}
        unknown -> unknown
      end
    end
  end

  defp act(ctx, caller, _id, "service_logs", %{"name" => name, "from" => from})
       when is_integer(from) and from >= 0 do
    {mod, server} = ctx.services

    with :ok <- service_ok(name),
         :ok <- Grants.may_use?(ctx.grants, caller),
         do: mod.logs(server, name, from, max: @window)
  end

  defp act(ctx, caller, _id, "service_send", %{"name" => name, "input" => input})
       when is_binary(input) do
    {mod, server} = ctx.services
    with :ok <- service_ok(name), do: mod.send(server, caller, name, input)
  end

  defp act(ctx, caller, _id, "service_wait", %{"name" => name, "until" => u, "timeout" => t})
       when is_integer(t) and t > 0 and t <= ctx.cap do
    {mod, server} = ctx.services

    with :ok <- service_ok(name),
         {:ok, until} <- until(u),
         :ok <- Grants.may_use?(ctx.grants, caller),
         do: mod.wait(server, name, until, t)
  end

  defp act(ctx, caller, _id, "service_" <> fix, %{"name" => name} = a)
       when fix in ~w(restart stop hand) do
    {mod, server} = ctx.services

    with :ok <- service_ok(name) do
      case {fix, a["to"]} do
        {"restart", _} -> mod.restart(server, caller, name, [])
        {"stop", _} -> mod.stop(server, caller, name, [])
        {"hand", to} when is_binary(to) -> mod.hand(server, caller, name, to)
        _ -> {:refused, {:bad, :args}}
      end
    end
  end

  defp act(ctx, caller, _id, "agents", args) do
    {mod, server} = ctx.tracker
    all = is_map(args) and args["all"] == true

    with :ok <- Grants.may_use?(ctx.grants, caller),
         {:ok, tree} <- mod.agents(server, timeout: @step, all: all),
         do: {:ok, %{tree | agents: Enum.map(tree.agents, &Map.drop(&1, [:session_id, :host]))}}
  end

  defp act(ctx, caller, _id, "look", %{"agent" => agent}) when is_binary(agent) do
    {mod, server} = ctx.stream

    with {:ok, a} <- close(ctx, caller, agent, :no_screen),
         {:ok, {tmod, t}} <- transcripts(ctx, a) do
      events = mod.log(server, a.session_id, {:last, @window}, timeout: @step)

      transcript =
        tmod.text(t, a.account, a.session_id, {:last, @window}, timeout: @step, max: @read_max)

      [events, transcript] =
        Enum.map([events, transcript], &with({:ok, l} <- lines(&1, true), do: l.text))

      {:ok, %{state: a.state, requests: a.waits_on, events: events, transcript: transcript}}
    end
  end

  defp act(ctx, caller, _id, "transcript", %{"agent" => agent, "from" => from})
       when is_binary(agent) and is_integer(from) and from >= 0 do
    with {:ok, a} <- close(ctx, caller, agent, :no_session),
         {:ok, {mod, t}} <- transcripts(ctx, a),
         do:
           lines(
             mod.text(t, a.account, a.session_id, from, timeout: @step, max: @read_max),
             false
           )
  end

  # Team.tla's ClaimTaken, then FixActs or FixRefused (in `Delegates`, which reads the state
  # again), then the claim settled by the state read after: verified when the fix took and the
  # state moved. A claim left open by an unknown settle is a restart's to close as interrupted.
  defp act(ctx, caller, _id, tool, %{"agent" => agent} = a)
       when tool in @fixes and is_binary(agent) do
    {mod, server} = ctx.delegates

    with {:ok, fix} <- fix(tool, a),
         :ok <- Grants.may_fix?(ctx.grants, caller, agent),
         {:ok, parent} <- as_parent(ctx, caller, agent),
         {:ok, state} <- mod.fix_state(server, parent, agent),
         {:ok, claim} <- Acts.claim(ctx.acts, caller, agent, state, tool) do
      outcome = mod.fix(server, parent, agent, fix, state)

      verdict =
        case {outcome, mod.fix_state(server, parent, agent)} do
          {{:ok, _}, {:ok, read}} when read != state -> :verified
          _ -> :not_verified
        end

      # A fix refused when it acts let its claim go with no act (`Claim.tla`'s LetGo).
      acted = not match?({:refused, _}, outcome)
      settled = Acts.settle(ctx.acts, claim, verdict, answer: outcome, acted: acted)

      case outcome do
        {:ok, done} -> {:ok, %{done: done, claim: claim, settled: settled}}
        other -> other
      end
    end
  end

  defp act(_ctx, _caller, _id, tool, _args) do
    if Enum.any?(@tools, &(&1.name == tool)),
      do: {:refused, {:bad, :args}},
      else: {:refused, {:unknown_tool, tool}}
  end

  # A label is checked before the claim: a bad one never takes the state.
  defp fix("answer", %{"dialog" => d, "label" => l}) when is_binary(d) and l in ~w(allow deny),
    do: {:ok, {:answer, d, l}}

  defp fix("answer", _args), do: {:refused, {:bad, :args}}
  defp fix(tool, _args), do: {:ok, String.to_existing_atom(tool)}

  defp job_class(nil), do: {:ok, :heavy}
  defp job_class("heavy"), do: {:ok, :heavy}
  defp job_class("builder"), do: {:ok, :builder}
  defp job_class("landing"), do: {:ok, :landing}
  defp job_class(_), do: {:refused, {:bad, :class}}

  # The units a job of `class` in `project` asks for, as the app declares them; with no `lease`
  # function the jobs ask for no lease.
  defp job_lease(%{lease: nil}, _class, _project), do: {:ok, []}

  defp job_lease(ctx, class, project) do
    with {:ok, units} <- ctx.lease.(class, project),
         do: {:ok, [lease: %{class: class, module: project, units: units}]}
  end

  defp service_ok(name) do
    if is_binary(name), do: :ok, else: {:refused, {:bad, :args}}
  end

  # A line is looked for from the current start's offset: the tool takes no other.
  defp until(%{"line" => pattern}) when is_binary(pattern), do: {:ok, {:line, pattern}}
  defp until(%{"port" => port}) when port in 1..65_535, do: {:ok, {:port, port}}
  defp until("exit"), do: {:ok, :exit}
  defp until(_), do: {:refused, {:bad, :args}}

  # A close read: `Grants` first, then the agent as the `Tracker`'s tree has it. A main session
  # has no screen and no known session until `Screen` and `Mains` exist (`main`, the refusal).
  defp close(ctx, caller, agent, main) do
    {mod, server} = ctx.tracker

    with :ok <- Grants.may_read?(ctx.grants, caller, agent),
         {:ok, tree} <- mod.agents(server, timeout: @step, all: true) do
      case Enum.find(tree.agents, &(&1.name == agent)) do
        nil -> {:unknown, {:not_in_tree, agent}}
        %{kind: "main"} -> {:refused, main}
        %{session_id: nil, state: state} -> {:refused, {:no_session, state}}
        a -> {:ok, a}
      end
    end
  end

  defp transcripts(ctx, %{account: account}) do
    case ctx.transcripts do
      nil -> {:refused, {:no_transcripts, account}}
      reader -> {:ok, reader}
    end
  end

  # Whole lines only, at most `@window` bytes, so an answer stays small; a read that began inside
  # a line (`look`'s, from before an offset) drops that line's end. A line longer than the
  # window comes in pieces.
  defp lines({:ok, %{bytes: bytes, from: from}}, last?) do
    {bytes, from} =
      case last? and from > 0 and :binary.match(bytes, "\n") do
        {at, 1} ->
          {binary_part(bytes, at + 1, byte_size(bytes) - at - 1), from + at + 1}

        _ ->
          {bytes, from}
      end

    part = binary_part(bytes, 0, min(@window, byte_size(bytes)))

    text =
      case :binary.matches(part, "\n") do
        [] -> if byte_size(bytes) > @window, do: part, else: ""
        found -> binary_part(part, 0, elem(List.last(found), 0) + 1)
      end

    {:ok, %{text: text, from: from, next: from + byte_size(text)}}
  end

  defp lines(other, _last?), do: other

  # An agent's delegate is its own: its `parent` argument is never read. The operator names the
  # main session, which `Grants` then checks.
  defp start_args(ctx, args, caller) do
    parent = if caller == Grants.operator(ctx.grants), do: args["parent"], else: caller
    start = [parent | Enum.map(~w(project branch model brief), &Map.get(args, &1))]

    if Enum.all?(start, &is_binary/1),
      do: {:ok, start ++ [Map.get(args, "options"), Map.get(args, "interactive") == true]},
      else: {:refused, {:bad, :args}}
  end

  # The start's own wait is at most `wait`. `Delegates` checks the options.
  defp start_delegate(ctx, caller, [parent, project, branch, model, brief, options, i], wait) do
    {mod, server} = ctx.delegates
    opts = [timeout: wait, options: options, interactive: i]

    with :ok <- Grants.may_start_delegate?(ctx.grants, caller, parent),
         do: mod.start_delegate(server, parent, project, branch, model, brief, opts)
  end

  # `Delegates` knows a delegate by its parent: the operator's fix acts as that parent would.
  # A main session's own fixes need `Mains`.
  defp as_parent(ctx, caller, agent) do
    if caller == Grants.operator(ctx.grants) do
      case Grants.parent(ctx.grants, agent) do
        {:refused, :main_has_no_parent} -> {:refused, {:not_built, :main_fix}}
        found -> found
      end
    else
      {:ok, caller}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp ask(mcp, request) do
    GenServer.call(mcp, request, @step)
  catch
    :exit, {:noproc, _} -> {:refused, :no_mcp}
    :exit, {:timeout, _} -> {:unknown, {:timeout, @step}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    tool_timeout = Keyword.fetch!(opts, :tool_timeout)
    margin = Keyword.fetch!(opts, :margin)

    with true <-
           (is_integer(margin) and is_integer(tool_timeout) and margin > 0 and
              margin < tool_timeout) or {:refused, {:bad, :tool_timeout}},
         :ok <- File.mkdir_p(Path.join(dir, "agents")),
         {:ok, db} <- Table.open(Path.join(dir, "mcp.db")) do
      ctx =
        Map.new(
          ~w(grants acts mailbox jobs delegates services workstation tracker stream)a ++
            ~w(transcripts place instance)a,
          &{&1, Keyword.fetch!(opts, &1)}
        )

      cap = Keyword.get(opts, :cap, @day)
      ctx = Map.merge(ctx, %{cap: cap, tool_timeout: tool_timeout, margin: margin})
      ctx = Map.put(ctx, :mover, Keyword.get(opts, :mover))
      ctx = Map.put(ctx, :sessions, Keyword.get(opts, :sessions))
      ctx = Map.put(ctx, :mains, Keyword.get(opts, :mains))
      ctx = Map.put(ctx, :lease, Keyword.get(opts, :lease))
      {:ok, %{db: db, dir: dir, port: Keyword.fetch!(opts, :port), ctx: ctx}}
    else
      {:error, reason} -> {:stop, {:mkdir, reason}}
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  # No token ever calls as the operator.
  def handle_call({:issue, agent}, _from, s) when agent == s.ctx.grants.operator,
    do: {:reply, {:refused, {:reserved, agent}}, s}

  def handle_call({:issue, agent}, _from, s) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    path = Path.join([s.dir, "agents", agent <> ".json"])

    server = %{
      "type" => "http",
      "url" => "http://127.0.0.1:#{s.port}/mcp",
      "headers" => %{"x-caf-token" => token}
    }

    tmp = path <> ".tmp"
    text = JSON.encode!(%{"mcpServers" => %{"caf" => server}})

    # The file first: a token is kept only once its agent can read it.
    with :ok <- File.write(tmp, text),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      Table.put_token(s.db, agent, token)
      {:reply, {:ok, path}, s}
    else
      {:error, reason} -> {:reply, {:unknown, {path, reason}}, s}
    end
  end

  def handle_call({:who, token}, _from, s) when is_binary(token) do
    case Table.agent(s.db, token) do
      nil -> {:reply, {:refused, :unknown_token}, s}
      agent -> {:reply, {:ok, agent}, s}
    end
  end

  def handle_call({:who, _}, _from, s), do: {:reply, {:refused, :unknown_token}, s}

  # The operator's name is `Grants`', so its row names it as any agent's row names its agent.
  def handle_call({:called, :operator, tool, args}, from, s) do
    case Grants.operator(s.ctx.grants) do
      nil -> {:reply, {:refused, :no_operator}, s}
      name -> handle_call({:called, name, tool, args}, from, s)
    end
  end

  def handle_call({:called, agent, tool, args}, _from, s),
    do: {:reply, {:ok, Table.called(s.db, agent, tool, args), s.ctx, agent}, s}

  def handle_call({:answered, id, outcome}, _from, s),
    do: {:reply, Table.answered(s.db, id, outcome), s}

  def handle_call(:calls, _from, s), do: {:reply, Table.calls(s.db), s}
end
