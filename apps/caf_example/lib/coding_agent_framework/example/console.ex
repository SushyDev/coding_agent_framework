defmodule CodingAgentFramework.Example.Console do
  @moduledoc """
  The operator's console: short functions over the operator's tools, for a person at the IEx
  shell `bin/caf-example <config>` opens. Each prints a short plain reading and answers `:ok`;
  the act itself is `CodingAgentFramework.Operator`'s, through `MCP`, with the same checks,
  claims and call log as an agent's tool, so the console decides nothing of its own.

  `start/1` reads the config file (`CodingAgentFramework.Example.ConfigFile`), starts the tree
  in a process of its own (`CodingAgentFramework.Example.Run`) and answers it: every other
  function takes it first. The shell imports this module and names it `caf`:

      agents(caf)                                    # the tree and each agent's state
      dialogs(caf)                                   # startup dialogs that wait on a person
      answer_dialog(caf, "demo-main", "trust", "Yes, I trust this folder")
      start_main(caf, "demo", "demo-main", "Read the README and wait.")
      start_delegate(caf, "demo-main", "demo", "unit/readme", "Add a line to the README.")
      run_delegate(caf, "demo-main", "demo", "unit/count", "Count the files.", timeout: 600_000)
      message(caf, "demo-main", "Say hello.")        # then status(caf, id)
      look(caf, "demo-main")                         # its last transcript lines
      answer_request(caf, "demo-unit-readme", "req-1", "allow")   # a delegate's permission
      requests(caf, "demo-main")                     # a main session's held requests
      answer_request(caf, "demo-main", "41", "allow")             # and the answer to one
      stop_delegate(caf, "demo-unit-readme")         # once its report is delivered
      prompts(caf)                                   # everything that waits on a person
      prompts(caf, subtree: "demo-main", kind: "permission")
      answer(caf, "permission:41", "allow")          # as the config's operator, once
      symptoms(caf, status: ["open", "asked"])       # what the healer read
      limited(caf)                                   # the accounts at a usage limit
      acts(caf, actor: "absent_mains:ws")            # the ledger's acts
      usage(caf)                                     # each account's reading
      groups(caf, "demo-unit-readme")                # its process groups, as the healer reads them
      asks(caf)                                      # then answer_ask(caf, id, ["Rebase"])
      move(caf, "demo-main", "two")
      end_main(caf, "demo-main")
      leases(caf)                                    # held leases and refusals
      faults(caf)                                    # the fault ledger
      checkout(caf)                                  # each project's checkout
      attach(caf, "demo-main")                       # the command that opens its viewer

  It reads the agent rows through `Sessions.Agents`, the held hook events through
  `Intake.Table`, and the rest through each part's own functions; it opens no part's table.
  """

  alias CodingAgentFramework.{Acts, Mailbox, Mains, MCP, Operator, Scheduler, Sessions, Shell}
  alias CodingAgentFramework.{StuckBackgrounds, Usage}
  alias CodingAgentFramework.Config
  alias CodingAgentFramework.Example.{ConfigFile, Run}
  alias CodingAgentFramework.Intake.Table, as: IntakeTable
  alias CodingAgentFramework.Sessions.Agents

  @doc """
  Reads the config file at `path` and starts the app from it. Answers `{:ok, caf}`, or the
  refusal, which it prints. `env` is the environment devenv's programs are read from.
  """
  @spec start(String.t(), %{String.t() => String.t()}) :: {:ok, pid} | {:refused | :unknown, term}
  def start(path, env \\ System.get_env()) do
    with {:ok, config} <- ConfigFile.read(path, env),
         {:ok, caf} <- Run.start(config) do
      banner(caf, config)
      {:ok, caf}
    else
      answer ->
        say("caf: not started: #{text(answer)}")
        answer
    end
  end

  @doc """
  The start the shell of `bin/caf-example` makes (its dot file, `console.iex.exs`), once per VM
  (F-153's new-5). IEx evaluates the dot file again in each new shell it starts, as after an
  interrupt (Ctrl+G, then `i` and `c`), and a second start fails on the ports the first one
  holds: that shell gets the app the first one started, and nothing starts twice. Answers
  `start/2`'s answer the first time, then `{:ok, caf}` of that start, whether it still runs or
  not, and says which. The one start is the VM's, so it is kept in `:persistent_term`; `start/2`
  keeps nothing, and a test VM starts as many as it likes.
  """
  @spec shell(String.t(), %{String.t() => String.t()}) :: {:ok, pid} | {:refused | :unknown, term}
  def shell(path, env \\ System.get_env()) do
    case :persistent_term.get({__MODULE__, :shell}, nil) do
      nil ->
        with {:ok, caf} <- start(path, env) do
          :persistent_term.put({__MODULE__, :shell}, caf)
          {:ok, caf}
        end

      caf ->
        runs = if Process.alive?(caf), do: "runs", else: "has stopped"
        say("caf: this shell's app #{runs}, started once; `caf` names it again")
        {:ok, caf}
    end
  end

  @doc "Stops the app. The held agents run on; the next start adopts them."
  @spec stop(pid) :: :ok
  def stop(caf), do: Run.stop(caf)

  @doc "The tree: each agent, its kind, parent, account and state, and why it waits."
  @spec agents(pid, boolean) :: :ok
  def agents(caf, all \\ false) do
    case operate(caf, "agents", %{"all" => all}) do
      {:ok, %{agents: tree}} ->
        rows = Map.new(Agents.rows(info(caf).agents), &{&1.name, &1})
        if tree == [], do: say("no agents")

        for a <- tree do
          indent = if a.parent, do: "  ", else: ""
          under = if a.parent, do: "#{a.kind} of #{a.parent}", else: "#{a.kind} of #{a.project}"
          say("#{indent}#{a.name}: #{under}, on #{a.account || "no account"}, " <> state(a, rows))
        end

        :ok

      other ->
        show(other)
    end
  end

  @doc "Each startup dialog an agent's start waits on, its options, and how to answer it."
  @spec dialogs(pid) :: :ok
  def dialogs(caf) do
    shown = for row <- Agents.rows(info(caf).agents), d = Agents.dialog(row), do: {row.name, d}
    if shown == [], do: say("no startup dialog waits")

    for {name, d} <- shown do
      say("#{name} waits on the #{d.kind} dialog:")

      for {label, i} <- Enum.with_index(d.options, 1),
          do: say("  #{i}. #{label}#{if label == d.selected, do: "  (selected)"}")

      for path <- List.wrap(d[:paths]), do: say("  imports #{path}")
      for {kind, a} <- d.answers || %{}, do: say("  #{kind}: #{a[:label]} (#{a[:mark]})")
      say(~s|  answer_dialog(caf, "#{name}", "#{d.kind}", "<label>")|)
    end

    :ok
  end

  @doc "Answers `agent`'s startup dialog `kind` by its option's `label`: the operator's alone."
  @spec answer_dialog(pid, String.t(), String.t(), String.t()) :: :ok
  def answer_dialog(caf, agent, kind, label),
    do: show(Operator.answer_startup(mcp(caf), agent, kind, label))

  @doc """
  Answers `agent`'s held permission request `request` with `"allow"` or `"deny"`, under a
  claim: a delegate's (`agents/2` names a headless one's), or a main session's, which goes to
  the request `Intake` holds for it (`requests/2` names each). A person may answer it on the
  screen first.
  """
  @spec answer_request(pid, String.t(), String.t(), String.t()) :: :ok
  def answer_request(caf, agent, request, label),
    do: show(Operator.answer(mcp(caf), agent, request, label))

  @doc """
  The permission requests main session `agent` holds: each request's id, its tool and input,
  and how to answer it.
  """
  @spec requests(pid, String.t()) :: :ok
  def requests(caf, agent) do
    case Mains.fix_state(part(caf, :mains), agent) do
      {:ok, %{held: []}} ->
        say("#{agent} holds no permission request")

      {:ok, %{held: held}} ->
        rows = IntakeTable.rows_by_id(info(caf).intake, Enum.map(held, &String.to_integer/1))

        for r <- rows do
          {tool, input} = asked(r.data)
          say("request #{r.id}: #{tool} #{input}")
          say(~s|  answer_request(caf, "#{agent}", "#{r.id}", "allow")  # or "deny"|)
        end

        :ok

      other ->
        show(other)
    end
  end

  @doc "Ends delegate `agent` once its report is delivered, under a claim."
  @spec stop_delegate(pid, String.t()) :: :ok
  def stop_delegate(caf, agent), do: show(Operator.stop(mcp(caf), agent))

  @doc "Starts main session `name` of `project`, `brief` its first message."
  @spec start_main(pid, String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def start_main(caf, project, name, brief, model \\ nil),
    do: show(Operator.start_main(mcp(caf), project, name, brief, model))

  @doc "Ends main session `name` for good, once every delegate of it has ended."
  @spec end_main(pid, String.t()) :: :ok
  def end_main(caf, name), do: show(Operator.end_main(mcp(caf), name))

  @doc """
  Starts a delegate of main session `parent` on `branch`; its report goes to `parent`.
  Options: `model:` (`"opus"`), `interactive:` (false), `effort:` (none: `"low"`, `"medium"`,
  `"high"`, `"xhigh"` or `"max"`).
  """
  @spec start_delegate(pid, String.t(), String.t(), String.t(), String.t(), keyword) :: :ok
  def start_delegate(caf, parent, project, branch, brief, opts \\ []),
    do: show(operate(caf, "start_delegate", delegate(parent, project, branch, brief, opts)))

  @doc """
  The operator's `run_delegate`: starts a delegate of `parent` and waits up to `timeout:` ms
  (10 minutes by default) for its report, which comes to the operator, not to `parent`. It
  waits in a process of its own and prints the report when it comes, so the shell stays free.
  """
  @spec run_delegate(pid, String.t(), String.t(), String.t(), String.t(), keyword) :: :ok
  def run_delegate(caf, parent, project, branch, brief, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 600_000)
    args = Map.put(delegate(parent, project, branch, brief, opts), "timeout", timeout)
    mcp = mcp(caf)

    spawn(fn ->
      say("run_delegate #{branch}: " <> text(MCP.operate(mcp, "run_delegate", args)))
    end)

    say("run_delegate #{branch}: waiting up to #{div(timeout, 1000)} s; the report prints here")
  end

  @doc "Sends `text` to agent `to`; prints the message's id for `status/2`."
  @spec message(pid, String.t(), String.t()) :: :ok
  def message(caf, to, text) do
    case Operator.message(mcp(caf), to, text) do
      {:ok, {:queued, id}} -> say("queued as message #{id}; status(caf, #{id}) follows it")
      other -> show(other)
    end
  end

  @doc "Where message `id` is (its status and transport), and its reply with the reply's text."
  @spec status(pid, integer) :: :ok
  def status(caf, id) do
    mailbox = part(caf, :mailbox)

    case Mailbox.status(mailbox, id) do
      {:ok, m} ->
        say("message #{id} from #{m.from} to #{m.to}: #{m.status}#{via(m)}")
        pointer = Path.join(Sessions.due_dir(info(caf).config.home, m.to), "#{id}.md")

        if m.via == "typed" and File.exists?(pointer),
          do: say("  typed as a pointer to #{pointer}")

        case Mailbox.reply(mailbox, id) do
          {:ok, r} ->
            say("  #{r.kind} #{r.id} from #{r.from}: #{r.status}")
            for line <- lines(r.text), do: say("  | " <> line)

          {:refused, :no_answer} ->
            say("  no reply yet")

          other ->
            say("  reply: #{text(other)}")
        end

      other ->
        show(other)
    end
  end

  @doc "What `agent` shows: its state, held requests, and its last transcript lines."
  @spec look(pid, String.t()) :: :ok
  def look(caf, agent) do
    case operate(caf, "look", %{"agent" => agent}) do
      {:ok, l} ->
        say("#{agent}: #{l.state}")
        for r <- List.wrap(l.requests), do: say("  waits on #{r[:tool]} (#{r[:request]})")
        for line <- lines(l.transcript), do: say("  | " <> line)
        :ok

      other ->
        show(other)
    end
  end

  @doc "The asks no one has answered, each question with its options."
  @spec asks(pid) :: :ok
  def asks(caf) do
    case Mailbox.open_asks(part(caf, :mailbox)) do
      {:ok, asks} ->
        if asks == [], do: say("no open asks")

        for a <- asks do
          say("ask #{a.id} from #{a.from}:")

          for q <- a.questions do
            many = if q["multiSelect"], do: " (several may be chosen)", else: ""
            say("  #{q["header"]}: #{q["question"]}#{many}")
            for o <- q["options"], do: say("    - #{o["label"]}: #{o["description"]}")
          end
        end

        :ok

      other ->
        show(other)
    end
  end

  @doc """
  Answers ask `id`, one entry per question: a label, a list of labels, or `{labels, text}`
  with the person's own text. The answer goes to the agent that asked, once.

      answer_ask(caf, 12, ["Rebase", {["Yes"], "and push after"}])
  """
  @spec answer_ask(pid, integer, list) :: :ok
  def answer_ask(caf, id, answers) do
    answers =
      for a <- answers do
        case a do
          {labels, text} -> %{"labels" => List.wrap(labels), "text" => text}
          labels -> %{"labels" => List.wrap(labels), "text" => ""}
        end
      end

    case Mailbox.answer(part(caf, :mailbox), id, answers) do
      {:ok, {:queued, m}} -> say("answered; the answer is message #{m}, status(caf, #{m})")
      other -> show(other)
    end
  end

  @doc """
  The prompts open now, oldest first (`CodingAgentFramework.prompts/2`): each one's id, kind,
  agent, status and text, and how to answer it. `filter`: `agent:`, `subtree:`, `kind:`.

      prompts(caf, subtree: "demo-main")
  """
  @spec prompts(pid, keyword) :: :ok
  def prompts(caf, filter \\ []) do
    case CodingAgentFramework.prompts(info(caf).config.instance, filter) do
      {:ok, prompts} ->
        if prompts == [], do: say("no prompt waits")

        for p <- prompts do
          say("#{p.id}: #{p.kind} of #{p.agent || "no agent"}, #{p.status}")
          for line <- lines(p.text), do: say("  | " <> line)
          say(~s|  answer(caf, "#{p.id}", #{choices(p)})|)
        end

        :ok

      other ->
        show(other)
    end
  end

  @doc """
  Answers prompt `id` with `choice` as the config's operator, once
  (`CodingAgentFramework.answer/4`; `Prompts.answer/5` says each kind's choices). A second
  answer is refused `settled`.
  """
  @spec answer(pid, String.t(), term) :: :ok
  def answer(caf, id, choice) do
    c = info(caf).config
    show(CodingAgentFramework.answer(c.instance, id, choice, c.operator))
  end

  @doc """
  The symptoms the `Watch` keeps, oldest first (`CodingAgentFramework.symptoms/2`): each one's
  id, kind, target, status, and why it waits on a person or how it was answered. `filter`:
  `kind:`, `target:`, `state:`, `source:`, `status:`.
  """
  @spec symptoms(pid, keyword) :: :ok
  def symptoms(caf, filter \\ []) do
    case CodingAgentFramework.symptoms(info(caf).config.instance, filter) do
      {:ok, rows} ->
        if rows == [], do: say("no symptoms")

        for s <- rows do
          asked = if s.reason, do: ", asked: #{s.reason} (its remedy #{s.remedy})", else: ""
          answer = if s.answer, do: ", answered #{s.answer} by #{s.answered_by}", else: ""
          say("symptom #{s.id}: #{s.kind} of #{s.target}, #{s.status}#{asked}#{answer}")
          say("  state #{s.state}, from #{s.source}")
        end

        :ok

      other ->
        show(other)
    end
  end

  @doc """
  The accounts at a usage limit now (`CodingAgentFramework.limited/1`): each one's window and
  reset, and its agents with how long each has waited.
  """
  @spec limited(pid) :: :ok
  def limited(caf) do
    case CodingAgentFramework.limited(info(caf).config.instance) do
      {:ok, []} ->
        say("no account is at a usage limit")

      {:ok, readings} ->
        for r <- readings do
          say("#{r.account}: limited (#{r.window}) until #{r.until}")

          for a <- r.agents,
              do: say("  #{a.agent}, waiting #{div(a.waited, 60_000)} min, until #{a.until}")
        end

        :ok

      other ->
        show(other)
    end
  end

  @doc """
  The ledger's acts within `filter` (`Acts.rows/3`'s: `actor:`, `target:`, `act:`, `status:`,
  …), the last 30: each one's actor, act, target, state and end.
  """
  @spec acts(pid, keyword) :: :ok
  def acts(caf, filter \\ []) do
    case Acts.rows(part(caf, :acts), filter) do
      {:ok, rows} ->
        if rows == [], do: say("no acts")
        if length(rows) > 30, do: say("#{length(rows) - 30} earlier acts not shown")

        for r <- Enum.take(rows, -30) do
          end_ = if r.outcome, do: "#{r.status} #{r.outcome}", else: r.status
          why = if r[:reason], do: ": #{r.reason}", else: ""
          say("act #{r.id}: #{r.actor} #{r.act} #{r.target}, #{end_}#{why}")
          if r.state, do: say("  state #{r.state}")
        end

        :ok

      other ->
        show(other)
    end
  end

  @doc """
  Each account's usage reading (`Usage.readings/2`): how much of its windows is used and when
  they reset, where the reading came from, and its limit when it has one.
  """
  @spec usage(pid) :: :ok
  def usage(caf) do
    case Usage.readings(part(caf, :usage)) do
      {:ok, %{readings: readings}} when readings == %{} ->
        say("no account has a reading")

      {:ok, %{readings: readings}} ->
        for {name, r} <- Enum.sort(readings) do
          five = if r[:five_used], do: ", five hours #{r.five_used} %", else: ""
          say("#{name}: #{r[:used]} % used, resets #{r[:resets_at]}#{five}, from #{r[:source]}")

          if r[:limited_until],
            do: say("  limited (#{r[:limit_window]}) until #{r.limited_until}")
        end

        :ok

      :unread ->
        say("usage not read yet")

      other ->
        show(other)
    end
  end

  @doc """
  The process groups `agent`'s process started, with each one's CPU time, read as
  `stuck_background`'s healer reads them (`StuckBackgrounds.Groups.read/3`), by the agent row's
  record and the tree's own holder (`CodingAgentFramework.processes/1`). On macOS it answers
  `unknown: :no_proc`.
  """
  @spec groups(pid, String.t()) :: :ok
  def groups(caf, agent) do
    %{config: c, agents: agents} = info(caf)

    with %{pid: pid, proc_start: start} when is_integer(pid) <-
           Agents.get(agents, agent) || {:refused, :no_agent},
         {:ok, procs} <- CodingAgentFramework.processes(c),
         {:ok, groups} <- StuckBackgrounds.Groups.read(procs, %{pid: pid, start: start}) do
      if groups == [], do: say("#{agent} (pid #{pid}) leads no group of its own")
      for g <- groups, do: say("group #{g.pid}, started #{g.start}: #{g.cpu} ticks of CPU time")
      :ok
    else
      %{} -> say("#{agent} has no process recorded")
      other -> show(other)
    end
  end

  @doc "Moves `agent` to account `to`, or with nil to the usable one with the most room."
  @spec move(pid, String.t(), String.t() | nil) :: :ok
  def move(caf, agent, to \\ nil), do: show(Operator.move(mcp(caf), agent, to))

  @doc """
  The leases still held, and every refusal; with `all` every lease ever written. A lease names
  the account its grant was read against, `asked on work`, which is not where a delegate a
  resume or a move put on another account runs now: its agent row names that (F-211).

      lease 3: builder for app asked on work, seat 1: held by delegate laptop:12
  """
  @spec leases(pid, boolean) :: :ok
  def leases(caf, all \\ false) do
    rows = Scheduler.leases(part(caf, :scheduler))

    case rows do
      rows when is_list(rows) ->
        shown = if all, do: rows, else: Enum.filter(rows, &(open?(&1) or refused?(&1)))
        if shown == [], do: say("no lease held, none refused")
        for l <- shown, do: say(lease(l))
        :ok

      other ->
        show(other)
    end
  end

  @doc "The fault ledger: every act that failed, ended unknown, or that a restart cut."
  @spec faults(pid) :: :ok
  def faults(caf) do
    case Acts.faults(part(caf, :acts)) do
      {:ok, rows} ->
        if rows == [], do: say("no faults")

        for r <- rows do
          end_ = if r.status == "interrupted", do: "interrupted", else: r.outcome
          why = if r[:reason], do: ": #{r.reason}", else: ""
          cleared = if r[:cleared_at], do: " (cleared)", else: ""
          say("act #{r.id}: #{r.actor} #{r.act} #{r.target}, #{end_}#{why}#{cleared}")
        end

        :ok

      other ->
        show(other)
    end
  end

  @doc "Each project's checkout: its state, branch, whether it is clean, ahead and behind."
  @spec checkout(pid) :: :ok
  def checkout(caf) do
    c = info(caf).config
    mains = part(caf, :mains)

    for project <- Enum.sort(Map.keys(c.projects)) do
      case Mains.checkout(mains, project) do
        {:ok, r} ->
          reason = if r[:reason], do: ": #{r.reason}", else: ""

          read =
            if r[:branch],
              do:
                ", on #{r.branch}, clean #{r[:clean]}, ahead #{r[:ahead]}, behind #{r[:behind]}",
              else: ""

          say("#{project}: #{r.state}#{reason}#{read}")
          say("  #{r[:path]}")

        other ->
          say("#{project}: #{text(other)}")
      end
    end

    :ok
  end

  @doc """
  The command that opens `agent`'s viewer in another terminal: a main session's own screen, or
  a headless delegate's event log. Detach with tmux's prefix and `d`; the agent runs on. The
  target is quoted, `-t '=name'`: zsh reads a word that starts with `=` as a command's path
  (F-153's new-4).
  """
  @spec attach(pid, String.t()) :: :ok
  def attach(caf, agent) do
    c = info(caf).config
    socket = Shell.shell_quote(Config.path(c, "tmux.sock"))
    say("#{Shell.shell_quote(c.programs.tmux)} -S #{socket} attach -t '=#{agent}'")
  end

  defp banner(caf, c) do
    say("caf: started at #{c.home}, instance #{c.instance}, as #{c.operator}")

    for a <- c.accounts,
        do: say("  account #{a}: #{Config.path(c, "accounts/#{a}/claude")}")

    say("  hooks on 127.0.0.1:#{c.ports.intake}, tools on 127.0.0.1:#{c.ports.mcp}")
    checkout(caf)
    say("caf: the console is ready; `h CodingAgentFramework.Example.Console` lists it")
  end

  defp state(a, rows) do
    row = rows[a.name] || %{}
    status = if row[:status] in [nil, "running", a.state], do: "", else: " (row #{row.status})"
    dialog = with %{kind: k} <- Agents.dialog(row), do: ", on the #{k} dialog"
    move = with phase when is_binary(phase) <- row[:move], do: ", moving: #{phase}"
    waits = for w <- List.wrap(a[:waits_on]), do: ", waits on #{w[:tool]} (#{w[:request]})"
    subs = if a[:subagents] in [nil, []], do: "", else: ", #{length(a.subagents)} subagents"
    Enum.join([a.state, status, dialog || "", move || "" | waits] ++ [subs])
  end

  # How a prompt is answered: one of its labels, or for an ask one answer per question.
  defp choices(%{kind: "ask"}), do: "[<one label per question>]"
  defp choices(%{options: options}), do: Enum.map_join(options, " | ", &inspect/1)

  defp delegate(parent, project, branch, brief, opts) do
    args = %{
      "parent" => parent,
      "project" => project,
      "branch" => branch,
      "brief" => brief,
      "model" => Keyword.get(opts, :model, "opus"),
      "interactive" => Keyword.get(opts, :interactive, false)
    }

    if effort = opts[:effort], do: Map.put(args, "effort", effort), else: args
  end

  defp via(%{via: nil}), do: ""
  defp via(%{via: via, attempt: a}), do: " by #{via}#{if a, do: " (#{a})", else: ""}"

  defp open?(l), do: l.outcome == "granted" and is_nil(l[:released_at])
  defp refused?(l), do: l.outcome == "refused"

  defp lease(l) do
    units = Enum.map_join(l.units || %{}, ", ", fn {k, n} -> "#{k} #{n}" end)
    holder = with {kind, key} <- l[:holder], do: "#{kind} #{key}"
    asked = l[:account] || "any"
    head = "lease #{l.id}: #{l.class} for #{l.module} asked on #{asked}, #{units}"

    cond do
      refused?(l) -> "#{head}: refused #{l.reason}, retry at #{l[:retry_at]}"
      open?(l) -> "#{head}: held by #{holder}"
      true -> "#{head}: released by #{l[:released_by]}"
    end
  end

  # The tool and input of a held request, from the hook's body as Intake keeps it.
  defp asked(data) do
    case is_binary(data) && JSON.decode(data) do
      {:ok, %{"tool_name" => tool} = body} ->
        {tool, inspect(body["tool_input"], limit: 10, printable_limit: 300)}

      _ ->
        {"(no tool named)", ""}
    end
  end

  defp lines(nil), do: []
  defp lines(text) when is_binary(text), do: text |> String.split("\n") |> Enum.take(-20)
  defp lines(other), do: [inspect(other)]

  defp operate(caf, tool, args), do: MCP.operate(mcp(caf), tool, args)
  defp mcp(caf), do: part(caf, :mcp)
  defp info(caf), do: Run.info(caf)

  # A tree that gave up has no parts: say so plainly, rather than as a missing key.
  defp part(caf, key) do
    case info(caf) do
      %{parts: %{^key => pid}} -> pid
      %{down: down} -> raise "caf: the app is down (#{inspect(down)}); quit and start it again"
    end
  end

  defp show(answer), do: say(text(answer))

  defp text({:ok, value}), do: "ok: " <> inspect(value, limit: 20, printable_limit: 2_000)
  defp text({:refused, why}), do: "refused: " <> inspect(why)
  defp text({:unknown, why}), do: "unknown: " <> inspect(why)
  defp text(other), do: inspect(other)

  defp say(line), do: IO.puts(line)
end
