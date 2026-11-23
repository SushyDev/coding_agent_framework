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
  - `start_delegate(project, branch, model, brief)`: `Grants.may_start_delegate?/3`, then the
    delegates' `start_delegate/7` with the caller as parent (the operator names a main session
    as `parent`); answers `%{delegate: name}`, with `already: true` when the branch's delegate
    was running already and is answered in place of a new one, or the start's refusal. The
    report comes later as a message. Both take optional `options` and `effort` (how hard the
    model thinks, launched as `--effort`, kept on the delegate's row for its resumes, and
    refused `{:effort, value}` for a level `Delegates` does not know, F-200). The tool's schema
    offers the levels as an `enum`, the list the app gave as `efforts:` (F-219). With
    `wait: false`, the default for an agent (it keeps working), a start whose lease is queued
    answers `%{delegate: name, queued: position}` at once, and its outcome comes later as a
    notice from `framework`, once (F-170); the operator's start waits for the lease unless it
    says `wait: false`. A start that finds every usable account at a usage limit answers
    `%{delegate: name, waiting: until}` at once, whatever `wait`, and its outcome comes as that
    notice too (F-196);
  - `run_delegate(project, branch, model, brief, timeout)`: as `start_delegate`, then the
    mailbox's `await/4` on the report, the answer to the brief's uuid, all within `timeout`
    (ms, at most the `:cap`, a day unless the app says, and under the client's tool timeout less the margin:
    `:tool_timeout` and `:margin`, so the client never gives up first). Answers `%{delegate:
    name, status: status, report: text}`, `status` `finished` for the delegate's reply and
    `failed` for the framework's notice, or at the timeout `{:unknown, %{delegate: name,
    reason: :timeout}}`, the report then due for another transport. A start that waits at a
    usage limit answers `%{delegate: name, waiting: until}` at once, as `start_delegate` does,
    since no report comes before the reset; it comes later as a message (F-203). A report it
    took is `sending` by the call in `Mailbox` until the answer is written, then `told/3`
    `:written` when the write succeeded, or anything else (due again) when it failed
    (`answer/5`). A call through `call/4` has its answer in hand, so it is told `:written` at
    once;
  - `start_main(project, name, brief)` (F-141): `Grants.may_start_main?/2` (a main session, or
    the operator), then the mains' `start_main/5`, the brief from the caller; answers `%{main:
    name}` once the session runs, `{:unknown, {:dialog, kind}}` while its start waits on a
    person's answer to a startup dialog, `%{main: name, waiting: until}` while it waits at a
    usage limit (F-196; its outcome a notice from `framework` to the caller), or the start's
    refusal (`{:running, name}` for a name in use or reserved);
  - `ask(questions)`: the mailbox's `ask/4`, which checks the questions and the caller and
    stores the ask for the app; answers `%{ask: id}` at once. The person's answer comes later
    as a message (`Mailbox.answer/4`), or its withdrawal with the reason (`Mailbox.withdraw/4`);
  - `withdraw(ask, reason)`: the operator's alone (F-172); any other caller is refused
    `:operator_only`. The inbox's answer of the ask's prompt with `{:withdraw, reason}`
    (`Prompts.answer/5`, F-179), which `Mailbox.withdraw/4` settles: a person dismissed the ask
    in the app, and the agent reads the reason once, in the answer's place. Answers `Mailbox`'s
    answer, refused `:settled` once the ask was answered or withdrawn;
  - `reload()`: `Grants.may_use?/2`, then the tools' names; the endpoint sends the client
    `notifications/tools/list_changed` first;
  - the service tools, each through the services' own function, which makes its own `Grants`
    check, and answers as it does: `service_start(name, argv, opts)` (`start/5` in the copy
    `place` names, on `opts`' `host`, the `:workstation` unless named, with its `forward`, the
    `local` port it is forwarded to (the same port unless named), and `keep`; its `timeout`,
    at most the `:cap`, bounds the whole start), `service_send(name, input)` (`send/5`), `service_restart(name)` (`restart/4`),
    `service_stop(name)` (`stop/4`), `service_hand(name, to)` (`hand/4`). Those open to any
    agent take `Grants.may_use?/2` first: `services()` (`list/1`, each row's name, host,
    owner, state, restarts and ports), `service_logs(name, from)` (`logs/4`), and
    `service_wait(name, until, timeout)` (`wait/4`, `timeout` at most the `:cap`), where `until`
    is `{"line": pattern}` (from the current start's offset), `{"port": n}` or `"exit"`;
  - `agents(all)`: `Grants.may_use?/2`, then the tree as the `Tracker` reads it from its view
    (`Tracker.agents/2`, `CodingAgentFramework.Tracker.Tree`), never a copy kept here; a
    delegate that ended shows only with `all: true`;
  - `look(agent)`, `transcript(agent, from)`: `Grants.may_read?/3`, then the agent in the tree.
    `look`: a delegate's state, held requests, and last lines of its event log (`Stream.log/4`)
    and transcript (`Transcripts.text/4`), each with its own refusal; `transcript`: whole lines
    from byte `from`, and the next offset. A main session is refused until `Screen` and `Mains`.
  - the fix tools, a parent's on its own delegate, or the operator's on any (`Grants.may_fix?/3`;
    no agent fixes a main session; the operator's resume of one claims `Mains.fix_state/3`'s
    state and calls `Mains.resume_main/3` with it, F-144, its answer of one's held permission
    request calls `Mains.answer/5` the same way, F-147, and its other fixes of one are refused
    `{:not_built, :main_fix}`): `interrupt(agent)`, `answer(agent, dialog, label)` (`dialog`
    is the open request's id: a headless delegate's `can_use_tool` request, or the
    `PermissionRequest` row `Intake` holds for an interactive delegate or a main session;
    `label` `allow` or `deny`), `resume(agent)` (a delegate whose
    process died) and `stop(agent)` (once its report is delivered). Each reads the delegate's
    state (`Delegates.fix_state/3`), checks an answer's `dialog` against that state's `held`
    (an id it does not hold is refused `{:not_held, id}` with no claim, F-148, so the next
    answer, with the right id, is taken), checks what the fix needs of that state
    (`Delegates.fix_check/2`, `Mains.fix_check/2`: a resume refused `:live` or `{:not_stopped,
    status}`, a stop `{:report, status}`, takes no claim, F-149, so the state's next fix is
    taken), claims it in `Acts` (`Acts.claim/6`, act the tool's
    name), then `Delegates.fix/5` acts only while that state is still the delegate's, and the claim
    is settled `verified` when the fix answered `ok` and the state read after has moved, else
    `not_verified`. A second fix of a state is refused `{:claimed, by}` or
    `{:already_claimed, by}`, but for a state whose fix was refused when it acted: that fix
    acted on nothing, so its claim leaves the state free for the next (F-231). Answers
    `%{done: value, claim: id, settled: settle's answer}`, or the fix's refusal or unknown.
  - `move(agent, to)`: `Grants.may_fix?/3`, then the mover's `move/4` (`to` optional: by default
    the usable account with the most room), which claims the act `move` in `Acts` and settles
    it when the move ends. Answers `%{act: id, from: account, to: account}` once the drain began.
  - `answer_startup(agent, kind, label)`: the operator's alone (F-140); any other caller is
    refused `:operator_only`. The startup dialog an interactive start waits on (`kind`
    `trust` or `imports`, as the agent row shows it, `Sessions.Agents.dialog/1`), answered by
    its option's label as the inbox's prompt (`Prompts.answer_startup/5`, F-179), whose owner
    `Sessions.answer_dialog/5` writes it as an act in `Acts`, actor the operator, marks it on
    the row before its checked press and never presses it twice. Answers `Sessions`' answer,
    or `{:refused, :settled}` for a dialog answered or gone, `{:refused, :no_prompt}` for one
    the agent never showed.
  - `reload_plugins(agent)`: the operator's alone (F-233); any other caller is refused
    `:operator_only`. A row in `Acts` with no state (a reload moves none, and may be made
    again), then the mailbox's `reload_plugins/3`: `/reload-plugins` typed into an interactive
    agent's idle session as a typed message is, and its result line read. Answers `%{done:
    :reloaded, act: id}`, or refused `:headless` (a headless delegate has no screen, and loads
    its plugins at its next start), a session not idle, a dialog shown or a box not empty, and
    unknown with no result line within its bound. The row is settled by that answer.
  - `end_main(name)`: the operator's alone (F-143); any other caller is refused
    `:operator_only`. The mains' `end_main/3`: refused while a delegate of it has not ended
    (`{:delegates, names}`), else the session stopped once idle and its agent row `ended`, so
    the app ends what it owns. Answers `Mains`' answer.

  **The app's tools** (F-154, `extensions:`) are served beside these, each under its bundle's
  name, and each call is a row as any other's. A start's `meta` (the app's own metadata on
  the agent row, `start_delegate`, `run_delegate` and `start_main`) is the operator's alone:
  an agent's call that names it is refused `{:operator_only, :meta}`.

  An agent runs a heavy command with its own `Bash`, which the framework's `PreToolUse` policy
  puts under a lease (`CodingAgentFramework.Runs`, F-171); there is no `run` tool, and an app's
  landing runs through `CodingAgentFramework.Jobs` itself.

  **The operator** calls the same tools through `operate/3`, which writes its row under the
  operator's name, so each act it makes names it as the actor; `issue/2` never makes it a
  token. The operator's own tools (`answer_startup`, `end_main`, `withdraw`, `reload_plugins`) are refused
  `:operator_only` to any other caller, and no agent's list names them (`tools/2`). The
  design's other tools come in later parts (`docs/build-notes/F-86.md`).

      {:ok, mcp} = MCP.start_link(dir: dir, port: 4791, grants: grants, acts: acts,
        mailbox: {Mailbox, mailbox}, delegates: {Delegates, delegates},
        services: {Services, services}, workstation: "ws", tracker: {Tracker, tracker},
        stream: {Stream, stream}, transcripts: {Transcripts, t}, place: &place/1,
        tool_timeout: 3_600_000, margin: 60_000, efforts: ClaudeCLI.efforts())
      {:ok, config} = MCP.issue(mcp, "app-fix")
      MCP.call(mcp, "app-fix", "message", %{"to" => "app-main", "text" => "Done."})
      #=> {:ok, {:queued, 3}}
  """

  use GenServer

  alias CodingAgentFramework.{Acts, Extension, Grants}
  alias CodingAgentFramework.MCP.Table

  @step 5_000
  # The most bytes of a log or a transcript one answer carries.
  @window 16_384
  # A read takes one byte past the window, so `lines/2` can tell a longer line from one that fits.
  @read_max @window + 1
  # The default cap on a call's timeout: a wait the caller forgot still ends within a day.
  @day 86_400_000
  @agent ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  # The most a delegate's start may take of a `run_delegate`'s timeout: `Delegates`' own default.
  @start_wait 300_000
  @options %{type: "object", description: "the delegate's own launch options (ClaudeCLI.Options)"}
  # `Delegates` checks the level against `ClaudeCLI.efforts/0`; this part, which does not use
  # `caf_cli`, is handed that list as `efforts:` and `tools/1` adds it as the schema's `enum`, so
  # the levels are not copied here and the client can check one before the call.
  @effort %{
    type: "string",
    description:
      "how hard the model thinks, as `claude --effort` takes it; by default no flag goes in"
  }
  @wait %{
    type: "boolean",
    description:
      "wait for a seat when none is free; by default the start answers its place in the " <>
        "queue at once and its outcome comes as a message"
  }
  @start Map.new(~w(project branch model brief)a, &{&1, %{type: "string"}})
         |> Map.put(:options, @options)
         |> Map.put(:effort, @effort)
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
  @force %{
    type: "boolean",
    description:
      "the operator's: end it without waiting for a message in flight to it, which then " <>
        "settles unknown"
  }

  # The operator's alone: each is refused `:operator_only` to an agent, and listed to none.
  @operator ~w(answer_startup end_main withdraw reload_plugins)

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
      name: "start_delegate",
      description:
        "Starts a delegate on a branch; answers its name, and its place in the queue while " <>
          "no seat is free. Its report comes as a message.",
      inputSchema: %{
        type: "object",
        properties: Map.put(@start, :wait, @wait),
        required: ["project", "branch", "model", "brief"]
      }
    },
    %{
      name: "run_delegate",
      description:
        "Starts a delegate and answers its report, or its name at the timeout. A start that " <>
          "waits for a usage limit's reset answers its name and the reset at once; its " <>
          "report comes later as a message.",
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
        properties: %{project: @str, name: @name, brief: @str, model: @str},
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
      inputSchema: %{
        type: "object",
        properties: %{agent: @str, force: @force},
        required: ["agent"]
      }
    },
    %{
      name: "move",
      description:
        "Moves your delegate to another account (to: its name, or the usable one with the most room): drained, ended once idle, resumed there.",
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
      name: "end_main",
      description:
        "The operator's: ends a main session for good, once every delegate of it has ended; " <>
          "what it owns ends with it.",
      inputSchema: %{
        type: "object",
        properties: %{name: @str, force: @force},
        required: ["name"]
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
      name: "withdraw",
      description:
        "The operator's: withdraws an agent's open ask a person dismissed, with the reason " <>
          "the agent reads in the answer's place.",
      inputSchema: %{
        type: "object",
        properties: %{ask: %{type: "integer"}, reason: @str},
        required: ["ask", "reason"]
      }
    },
    %{
      name: "reload_plugins",
      description:
        "The operator's: types /reload-plugins into an interactive agent's idle session, " <>
          "checked as a typed message is, and reads its result line.",
      inputSchema: %{type: "object", properties: %{agent: @str}, required: ["agent"]}
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
  `:delegates`, `:services`, `:tracker` and `:stream` (each `{module, server}`:
  `{CodingAgentFramework.Mailbox, pid}`, `{CodingAgentFramework.Delegates, pid}`, `{CodingAgentFramework.Services, pid}`,
  `{CodingAgentFramework.Tracker, pid}`, `{CodingAgentFramework.Stream, pid}`, or a stand-in
  module with the same functions), `:transcripts` (the host's
  `{CodingAgentFramework.Transcripts, pid}`, or nil), `:workstation` (the host a service starts on
  unless its call names one), and
  `:place`, a function of an agent's name that answers `{:ok, %{project: p, name: n, worktree:
  path}}` (the copy services run in) or `{:refused, reason}`. `:acts` is the
  instance's `CodingAgentFramework.Acts`, where each fix takes its claim. `:mover` (optional)
  is `{CodingAgentFramework.Mover, pid}`, which the `move` tool calls; without it `move` is
  refused `:no_mover`. `:prompts` (optional) is `{CodingAgentFramework.Prompts, pid}`, the
  inbox `answer_startup` and `withdraw` answer through (F-179); without it those tools are
  refused `:no_prompts`. `:mains` (optional) is
  `{CodingAgentFramework.Mains, pid}`, which `start_main` calls; without it that tool is refused
  `:no_mains`. `:cap` (ms, default a day) is the most a `run_delegate`'s, a `service_start`'s
  or a `service_wait`'s `timeout` may be.
  `:tool_timeout` (ms) is the MCP tool timeout `CodingAgentFramework.ClaudeCLI` sets for every
  agent at launch, and `:margin` (ms, under it) how far under it a `run_delegate`'s `timeout`
  must stay: both required, positive integers. `:efforts` (F-219) is the levels a delegate's
  `effort` may be, a list of strings, never empty, required: any other (or none) stops the
  start `{:bad, :efforts}`. The embedding app hands it `CodingAgentFramework.ClaudeCLI.efforts/0`,
  since this part does not use `caf_cli`, and every tool's `effort` offers it as an `enum`
  (`tools/1`); `Delegates` still checks the value. `:extensions` (optional, F-154) is the app's
  bundles (`CodingAgentFramework.Extension`), checked whole at start, which stops with the
  first refusal: their tools are served beside the framework's, each listed and called only
  where its scope holds the caller (`Grants.may_call?/3`), and called as `Extension.run/4`
  within its `timeout`, or `:tool_timeout` less `:margin`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The framework's own tools, as `tools/list` answers them, each `effort` property offering
  `efforts` as its `enum`.

      iex> tools = CodingAgentFramework.MCP.tools(["low", "high"])
      iex> Enum.find(tools, &(&1.name == "start_delegate")).inputSchema.properties.effort.enum
      ["low", "high"]
  """
  @spec tools([String.t()]) :: [map]
  def tools(efforts) when is_list(efforts), do: Enum.map(@tools, &offer(&1, efforts))

  defp offer(%{inputSchema: %{properties: %{effort: _}}} = tool, efforts),
    do: put_in(tool, [:inputSchema, :properties, :effort, :enum], efforts)

  defp offer(tool, _efforts), do: tool

  @doc """
  The tools `agent` sees, as its `tools/list` answers them: the framework's but the operator's
  own (`answer_startup`, `end_main`, `withdraw`, `reload_plugins`, which only the operator sees), then the app's
  that its scope holds (`Grants.may_call?/3`), in the order the app gave them. An agent the tree
  does not hold sees none of the app's.

      MCP.tools(mcp, "app-fix") |> Enum.map(& &1.name) |> Enum.take(-1)
      #=> ["board_cards"]
  """
  @spec tools(GenServer.server(), String.t()) :: [map] | {:refused, term} | {:unknown, term}
  def tools(mcp, agent) do
    with {:ok, ctx} <- ask(mcp, :ctx), do: listed(ctx, agent)
  end

  defp listed(ctx, agent) do
    own =
      if agent == Grants.operator(ctx.grants),
        do: ctx.tools,
        else: Enum.reject(ctx.tools, &(&1.name in @operator))

    own ++ app_tools(ctx, agent)
  end

  @doc """
  The check `start_link/1` runs on its `extensions:`, beside this endpoint's own tools and
  under its deadline (`tool_timeout` less `margin`), so an app's config can be checked whole
  before anything starts (`CodingAgentFramework.Config.new/1`). Answers the bundles' tools,
  as `CodingAgentFramework.Extension.check/3` does, or its refusal.

      iex> CodingAgentFramework.MCP.extensions([%{name: "message"}], 3_600_000, 60_000)
      {:refused, {:extension, "message", :clashes}}
  """
  @spec extensions(term, pos_integer, pos_integer) :: {:ok, [map]} | {:refused, term}
  def extensions(extensions, tool_timeout, margin),
    do: Extension.check(extensions, Enum.map(@tools, & &1.name), tool_timeout - margin)

  defp app_tools(ctx, agent) do
    for t <- ctx.app_tools,
        Grants.may_call?(ctx.grants, agent, t.scope) == :ok,
        do: %{name: t.name, description: t.description, inputSchema: t.schema}
  end

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

  defp act(ctx, caller, _id, "start_delegate", args) do
    with {:ok, wait} <- lease_wait(ctx, caller, args),
         {:ok, start} <- start_args(ctx, args, caller),
         {:ok, %{name: name} = started} <- start_delegate(ctx, caller, start, @start_wait, wait),
         do: {:ok, Map.merge(%{delegate: name}, Map.take(started, [:already, :queued, :waiting]))}
  end

  defp act(ctx, caller, _id, "run_delegate", %{"timeout" => t} = args)
       when is_integer(t) and t > 0 and t <= ctx.cap do
    deadline = now() + t
    {mod, server} = ctx.mailbox
    under = ctx.tool_timeout - ctx.margin

    with true <- t < under or {:refused, {:timeout, {:under, under}}},
         {:ok, [parent | _] = start} <- start_args(ctx, args, caller),
         {:ok, %{name: name} = started} <-
           start_delegate(ctx, caller, start, min(t, @start_wait), true) do
      case started do
        # A reset hours away outlasts any await (F-203, from F-196's new-3): the start's answer
        # is the tool's, and the report comes later as a message, as for `start_delegate`.
        %{waiting: until} -> {:ok, %{delegate: name, waiting: until}}
        %{brief_uuid: key} -> await(mod, server, parent, name, key, deadline - now())
      end
    end
  end

  # A main session's start answers once its session runs, or once it waits on a person.
  defp act(ctx, caller, _id, "start_main", %{"project" => p, "name" => n, "brief" => b} = a)
       when is_binary(p) and is_binary(n) and is_binary(b) do
    with true <- is_nil(a["model"]) or is_binary(a["model"]) or {:refused, {:bad, :args}},
         {:ok, meta} <- app_meta(ctx, caller, a),
         :ok <- Grants.may_start_main?(ctx.grants, caller),
         true <- ctx.mains != nil or {:refused, :no_mains},
         {mod, server} = ctx.mains,
         opts = [from: caller, model: a["model"], timeout: @start_wait, meta: meta],
         {:ok, %{name: name} = started} <- mod.start_main(server, p, n, b, opts),
         do: {:ok, Map.merge(%{main: name}, Map.take(started, [:waiting]))}
  end

  # A main session's end is the operator's alone (Team.tla's MainEnds): no agent ends one.
  defp act(ctx, caller, _id, "end_main", %{"name" => name} = a) when is_binary(name) do
    with true <- caller == Grants.operator(ctx.grants) or {:refused, :operator_only},
         true <- ctx.mains != nil or {:refused, :no_mains},
         {:ok, force} <- force(a) do
      {mod, server} = ctx.mains
      if force, do: forced(ctx, caller, name), else: mod.end_main(server, name)
    end
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
  # It is the inbox's one answer (F-179): the dialog's prompt, answered once.
  defp act(ctx, caller, _id, "answer_startup", %{"agent" => agent, "kind" => k, "label" => l})
       when is_binary(agent) and is_binary(k) and is_binary(l) do
    with true <- caller == Grants.operator(ctx.grants) or {:refused, :operator_only},
         true <- ctx.prompts != nil or {:refused, :no_prompts} do
      {mod, server} = ctx.prompts
      # The answer's row in `Acts` names the operator as its actor (F-140's new-6).
      mod.answer_startup(server, agent, k, l, caller)
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

  # A person's dismissal of an ask, through the app: the operator's alone (F-172). The answer and
  # the withdrawal race in `Mailbox` to one settle.
  defp act(ctx, caller, _id, "withdraw", %{"ask" => ask, "reason" => reason})
       when is_integer(ask) and is_binary(reason) do
    with true <- caller == Grants.operator(ctx.grants) or {:refused, :operator_only},
         true <- ctx.prompts != nil or {:refused, :no_prompts} do
      {mod, server} = ctx.prompts
      mod.answer(server, "ask:#{ask}", {:withdraw, reason}, caller)
    end
  end

  # F-233: the operator's reload of an interactive session's plugins, through `Mailbox`, which
  # checks it as a typed message. A reload moves no state of the agent's and may be made again,
  # so it claims none: the act is a row in `Acts` before it acts, each call an act of its own (as
  # a forced end's), settled by its answer.
  defp act(ctx, caller, _id, "reload_plugins", %{"agent" => agent}) when is_binary(agent) do
    with true <- caller == Grants.operator(ctx.grants) or {:refused, :operator_only},
         {:ok, act} <- Acts.claim(ctx.acts, caller, agent, nil, "reload_plugins") do
      {mod, server} = ctx.mailbox
      outcome = mod.reload_plugins(server, agent, [])
      Acts.answered(ctx.acts, act, outcome)
      with {:ok, done} <- outcome, do: {:ok, %{done: done, act: act}}
    end
  end

  defp act(ctx, caller, _id, "reload", _args) do
    with :ok <- Grants.may_use?(ctx.grants, caller),
         do: {:ok, %{tools: Enum.map(listed(ctx, caller), & &1.name)}}
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
  # The operator's resume of a main session (F-143's new-1) claims its state read from
  # `Mains`, which resumes it only while that state is still its own. An answer's request is
  # checked against the state's `held` before the claim, as its label is (F-148), and what each
  # fix needs of the state, by the part that acts (`fix_check/2`, `Team.tla`'s Needed, F-149): a
  # settled claim keeps its state, so one taken for a fix the state refuses would refuse the
  # state's next fix, the one it needs, until the state moved.
  defp act(ctx, caller, _id, tool, %{"agent" => agent} = a)
       when tool in @fixes and is_binary(agent) do
    with {:ok, fix} <- fix(tool, a),
         :ok <- forced_by(ctx, caller, fix),
         :ok <- Grants.may_fix?(ctx.grants, caller, agent),
         {:ok, by} <- fixer(ctx, caller, agent, tool),
         {:ok, state} <- by.state.(),
         :ok <- held(fix, state),
         :ok <- by.check.(fix, state),
         {:ok, claim} <- Acts.claim(ctx.acts, caller, agent, state, tool, forced_detail(fix)) do
      outcome = by.fix.(fix, state)

      verdict =
        case {outcome, by.state.()} do
          {{:ok, _}, {:ok, read}} when read != state -> :verified
          _ -> :not_verified
        end

      # A fix refused when it acts let its claim go with no act (`Claim.tla`'s LetGo), and its
      # state is free for the next fix (Free, F-231's new-6): it has nothing to repeat or guard.
      acted = not match?({:refused, _}, outcome)
      fields = [answer: outcome, acted: acted, free: not acted]
      settled = Acts.settle(ctx.acts, claim, verdict, fields)

      case outcome do
        {:ok, done} when fix == {:stop, :force} ->
          with {:ok, ids} <- unknown_rows(ctx, caller, agent),
               do: {:ok, %{done: done, claim: claim, settled: settled, unknown: ids}}

        {:ok, done} ->
          {:ok, %{done: done, claim: claim, settled: settled}}

        other ->
          other
      end
    end
  end

  # An app's tool (F-154): its scope's check, then its function within its deadline, the
  # client's tool timeout less the margin unless the tool names a shorter one.
  defp act(%{app: app} = ctx, caller, _id, tool, args) when is_map_key(app, tool) do
    %{^tool => t} = app

    with :ok <- Grants.may_call?(ctx.grants, caller, t.scope),
         do: Extension.run(t, caller, args, t.timeout || ctx.tool_timeout - ctx.margin)
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

  defp fix("stop", args) do
    with {:ok, force} <- force(args), do: {:ok, if(force, do: {:stop, :force}, else: :stop)}
  end

  defp fix(tool, _args), do: {:ok, String.to_existing_atom(tool)}

  defp force(args) do
    case Map.get(args, "force", false) do
      force when is_boolean(force) -> {:ok, force}
      _ -> {:refused, {:bad, :args}}
    end
  end

  # A forced stop or end is the operator's alone (`Team.tla`'s ForcedByOperator, F-170).
  defp forced_by(ctx, caller, {:stop, :force}) do
    if caller == Grants.operator(ctx.grants), do: :ok, else: {:refused, {:operator_only, :force}}
  end

  defp forced_by(_ctx, _caller, _fix), do: :ok

  # A forced act says so on its claim, before it acts: `Mailbox` reads it as the evidence that
  # settles the rows left sending unknown, at its own settle (F-172).
  defp forced_detail({:stop, :force}), do: [detail: %{force: true}]
  defp forced_detail(_fix), do: []

  # The operator's forced end of a main session (F-170, `Team.tla`'s MainEnds with `f`): the act
  # is a row in `Acts` before it acts, with no state to claim (each call is an act of its own);
  # then the end, which waits for no row to the session; then each row left `sending` to it is
  # settled `unknown` in `Mailbox`, each settle a row in `Acts`. Answers `%{done: :ended, act:
  # id, unknown: ids}`, or the end's refusal or unknown, which settles nothing in `Mailbox`: a
  # later forced end of the ended row settles them.
  defp forced(ctx, caller, name) do
    {mod, server} = ctx.mains

    with {:ok, act} <-
           Acts.claim(ctx.acts, caller, name, nil, "end_main", forced_detail({:stop, :force})) do
      outcome = mod.end_main(server, name, force: true)
      outcome = with {:ok, done} <- outcome, do: with_unknown(ctx, caller, name, done, act)
      Acts.answered(ctx.acts, act, outcome)
      outcome
    end
  end

  defp with_unknown(ctx, caller, name, done, act) do
    with {:ok, ids} <- unknown_rows(ctx, caller, name),
         do: {:ok, %{done: done, act: act, unknown: ids}}
  end

  # Mailbox's ForceSettled: each row still sending to an agent whose end was forced, settled
  # unknown, and each settle recorded in `Acts`, actor the operator.
  defp unknown_rows(ctx, caller, agent) do
    {mod, server} = ctx.mailbox

    with {:ok, ids} <- mod.ended_while_sending(server, agent, timeout: @step) do
      for id <- ids do
        Acts.record(ctx.acts, caller, agent, "settle", :unknown,
          reason: :ended_while_sending,
          detail: %{row: id}
        )
      end

      {:ok, ids}
    end
  end

  # `Team.tla`'s AnswerClaimed: the id an answer names is one the state holds, else no claim is
  # taken. A state that names no `held` holds none.
  defp held({:answer, request, _label}, state) do
    if request in Map.get(state, :held, []), do: :ok, else: {:refused, {:not_held, request}}
  end

  defp held(_fix, _state), do: :ok

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

    with true <- Enum.all?(start, &is_binary/1) or {:refused, {:bad, :args}},
         {:ok, meta} <- app_meta(ctx, caller, args),
         do:
           {:ok,
            start ++
              [
                Map.get(args, "options"),
                Map.get(args, "interactive") == true,
                meta,
                Map.get(args, "effort")
              ]}
  end

  # The app's metadata on the agent a start makes (F-154) is the operator's to give, never an
  # agent's: an agent's call that names it is refused, not run without it.
  defp app_meta(ctx, caller, args) do
    cond do
      not Map.has_key?(args, "meta") -> {:ok, nil}
      caller == Grants.operator(ctx.grants) -> {:ok, args["meta"]}
      true -> {:refused, {:operator_only, :meta}}
    end
  end

  # Whether a start waits for a queued lease (F-170): an agent keeps working unless it asks to
  # wait; the operator's call waits unless it says not to.
  defp lease_wait(ctx, caller, args) do
    case Map.get(args, "wait") do
      nil -> {:ok, caller == Grants.operator(ctx.grants)}
      wait when is_boolean(wait) -> {:ok, wait}
      _ -> {:refused, {:bad, :args}}
    end
  end

  # The report of a delegate that started, within what is `left` of the tool's timeout.
  defp await(mod, server, parent, name, key, left) do
    answer = if left > 0, do: mod.await(server, parent, key, left), else: {:unknown, :timeout}

    case answer do
      {:ok, r} -> {:taken, r.id, {:ok, %{delegate: name, status: status(r), report: r.text}}}
      {:unknown, reason} -> {:unknown, %{delegate: name, reason: reason}}
      refused -> refused
    end
  end

  # The start's own wait is at most `timeout`. `Delegates` checks the options and the metadata.
  defp start_delegate(ctx, caller, start, timeout, wait) do
    [parent, project, branch, model, brief, options, i, m, effort] = start
    {mod, server} = ctx.delegates

    opts = [
      timeout: timeout,
      options: options,
      interactive: i,
      meta: m,
      wait: wait,
      effort: effort
    ]

    with :ok <- Grants.may_start_delegate?(ctx.grants, caller, parent),
         do: mod.start_delegate(server, parent, project, branch, model, brief, opts)
  end

  # Who reads the target's state and acts: `Delegates` for a delegate, as its parent; `Mains`
  # for the operator's resume and answer of a main session. Its other fixes are not built.
  defp fixer(ctx, caller, agent, tool) do
    case as_parent(ctx, caller, agent) do
      {:ok, parent} ->
        {mod, server} = ctx.delegates

        {:ok,
         %{
           state: fn -> mod.fix_state(server, parent, agent) end,
           check: &mod.fix_check/2,
           fix: fn fix, state -> mod.fix(server, parent, agent, fix, state) end
         }}

      {:refused, {:not_built, :main_fix}} when tool == "resume" and ctx.mains != nil ->
        {mod, server} = ctx.mains

        {:ok,
         %{
           state: fn -> mod.fix_state(server, agent) end,
           check: &mod.fix_check/2,
           fix: fn :resume, state ->
             with {:ok, %{name: name}} <-
                    mod.resume_main(server, agent, state: state, timeout: @start_wait),
                  do: {:ok, %{resumed: name}}
           end
         }}

      # F-146's new-5: a main session's held permission request, through Intake under the claim.
      {:refused, {:not_built, :main_fix}} when tool == "answer" and ctx.mains != nil ->
        {mod, server} = ctx.mains

        {:ok,
         %{
           state: fn -> mod.fix_state(server, agent) end,
           check: &mod.fix_check/2,
           fix: fn {:answer, request, label}, state ->
             mod.answer(server, agent, request, label, state: state)
           end
         }}

      refused ->
        refused
    end
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

  # A list with a string in it and nothing else; a tail that is no list is not one either.
  defp efforts?([_ | _] = list), do: strings?(list)
  defp efforts?(_), do: false

  defp strings?([]), do: true
  defp strings?([s | rest]) when is_binary(s), do: strings?(rest)
  defp strings?(_), do: false

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

    efforts = Keyword.get(opts, :efforts)

    with true <-
           (is_integer(margin) and is_integer(tool_timeout) and margin > 0 and
              margin < tool_timeout) or {:refused, {:bad, :tool_timeout}},
         true <- efforts?(efforts) or {:refused, {:bad, :efforts}},
         ext = Keyword.get(opts, :extensions, []),
         {:ok, app} <- extensions(ext, tool_timeout, margin),
         :ok <- File.mkdir_p(Path.join(dir, "agents")),
         {:ok, db} <- Table.open(Path.join(dir, "mcp.db")) do
      ctx =
        Map.new(
          ~w(grants acts mailbox delegates services workstation tracker stream)a ++
            ~w(transcripts place)a,
          &{&1, Keyword.fetch!(opts, &1)}
        )

      cap = Keyword.get(opts, :cap, @day)
      ctx = Map.merge(ctx, %{cap: cap, tool_timeout: tool_timeout, margin: margin})
      ctx = Map.put(ctx, :tools, tools(efforts))
      ctx = Map.put(ctx, :mover, Keyword.get(opts, :mover))
      ctx = Map.put(ctx, :prompts, Keyword.get(opts, :prompts))
      ctx = Map.put(ctx, :mains, Keyword.get(opts, :mains))
      ctx = Map.merge(ctx, %{app_tools: app, app: Map.new(app, &{&1.name, &1})})
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
  def handle_call(:ctx, _from, s), do: {:reply, {:ok, s.ctx}, s}
end
