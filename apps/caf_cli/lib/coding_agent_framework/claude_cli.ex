defmodule CodingAgentFramework.ClaudeCLI do
  @moduledoc """
  The command line and environment of one Claude Code session, per role and account. Pure: it
  starts nothing. Its output goes to `CodingAgentFramework.Holder.hold/4`, whose `env -i` keeps
  only the variables listed here.

  The flags are those of Claude Code 2.1.322 (`claude --help`), the version devenv pins:

  - `--model <model>` and `--name <name>`;
  - `--settings <file>` (the role's settings file) and `--mcp-config <file>` with
    `--strict-mcp-config`, the files `CodingAgentFramework.Accounts.prepare/3` wrote, and
    after the account's file the agent's own (`mcp:`, from `CodingAgentFramework.MCP.issue/2`),
    which carries who the agent is;
  - `--remote-control <name>` for a main session (role `:parent`) only. A delegate's settings
    file sets `remoteControlAtStartup` to false, since no flag turns Remote Control off;
  - `--resume <id>` when given;
  - `--` and the first prompt last, so a prompt that starts with `-` is not read as a flag and
    no flag that takes an optional or repeated value (`--remote-control`, `--mcp-config`)
    swallows it.

  No `--bg`: a background session dies with its daemon and forks on resume.

  The environment is exactly:

  - `CLAUDE_CONFIG_DIR`: the account's own directory, so nothing comes from `~/.claude`;
  - `HOME`: where Claude Code and the tools it runs (git, gh, ssh) find a person's own files;
  - `PATH`: how its Bash tool finds the programs a session runs;
  - `TERM`: the terminal type its screen is drawn for, which dtach does not set;
  - `LANG`: a UTF-8 locale, so text past ASCII is read and drawn as it is;
  - `MCP_TOOL_TIMEOUT` and `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`, both the launch's
    `:tool_timeout` (ms): how long Claude Code waits on one MCP tool call before it gives up,
    in all and with no byte or progress from the server. Claude Code 2.1.322 reads both from
    its environment as integers; without them it gives an `http` server's call 5 minutes of
    silence and its HTTP request 60 seconds. `CodingAgentFramework.MCP` keeps a
    `run_delegate`'s wait under the same value, less a margin, so the client never gives up
    first;
  - `DISABLE_AUTOUPDATER=1`, last and for every role: devenv pins Claude Code, and a session
    that updates itself runs a version the lock does not name.

  Everything else, such as an inherited `CLAUDECODE`, `CLAUDE_CODE_*` or `TMUX`, stays out.
  `headless/2` has the same environment, and `Holder.hold/4` applies it on a remote host as on
  this one.

      iex> account = CodingAgentFramework.Accounts.Account.at("work", "/caf/accounts/work/claude")
      iex> env = %{home: "/h", path: "/bin", term: "xterm-256color", lang: "C.UTF-8"}
      iex> {:ok, %{argv: argv, env: vars}} = CodingAgentFramework.ClaudeCLI.session(:parent, account,
      ...>   claude: "/run/bin/claude", model: "opus", name: "main", env: env,
      ...>   tool_timeout: 3_600_000)
      iex> argv
      ["/run/bin/claude", "--model", "opus", "--name", "main",
       "--settings", "/caf/accounts/work/claude/framework/parent.settings.json",
       "--mcp-config", "/caf/accounts/work/claude/framework/mcp.json", "--strict-mcp-config",
       "--remote-control", "main"]
      iex> hd(vars)
      {"CLAUDE_CONFIG_DIR", "/caf/accounts/work/claude"}
      iex> List.last(vars)
      {"DISABLE_AUTOUPDATER", "1"}
  """

  alias CodingAgentFramework.Accounts.Account

  @type role :: :parent | :delegate
  @type launch :: %{argv: [String.t()], env: [{String.t(), String.t()}]}

  @env [home: "HOME", path: "PATH", term: "TERM", lang: "LANG"]

  # Set by the framework, not given by the caller, so no launch can leave it out.
  @fixed [{"DISABLE_AUTOUPDATER", "1"}]

  @doc """
  The argv and environment of a session of `role` on `account` (from
  `CodingAgentFramework.Accounts.ready/2`).

  Options: `:claude` (its absolute path, from `Programs`), `:model`, `:name`, `:env` (a map of
  `:home`, `:path`, `:term` and `:lang`), `:tool_timeout` (ms, 1 000 to 2 147 483 647: the MCP
  tool timeout), and optionally `:resume` (a session id) and `:prompt` (the first prompt). A
  delegate needs its brief as `:prompt` unless it resumes.

  Returns `{:ok, %{argv: argv, env: env}}` or `{:refused, reason}`: `:no_account_dir` when
  `account` is not an account with a config directory, `{:missing, option}`, `{:bad, option}`,
  `{:bad_role, role}` or `:delegate_without_brief`.
  """
  @spec session(role, Account.t() | term, keyword) :: {:ok, launch} | {:refused, term}
  def session(role, account, opts)

  def session(role, _account, _opts) when role not in [:parent, :delegate],
    do: {:refused, {:bad_role, role}}

  def session(role, %Account{config_dir: "/" <> _} = account, opts) do
    with {:ok, claude} <- path(opts, :claude),
         {:ok, model} <- word(opts, :model),
         {:ok, name} <- word(opts, :name),
         {:ok, resume} <- optional_word(opts, :resume),
         {:ok, mcp} <- mcp(account, opts),
         {:ok, prompt} <- prompt(role, opts, resume),
         {:ok, env} <- env(account, opts) do
      argv =
        [claude, "--model", model, "--name", name] ++
          ["--settings", account.settings[role]] ++
          ["--mcp-config" | mcp] ++
          ["--strict-mcp-config"] ++
          if(role == :parent, do: ["--remote-control", name], else: []) ++
          if(resume, do: ["--resume", resume], else: []) ++
          if(prompt, do: ["--", prompt], else: [])

      {:ok, %{argv: argv, env: env}}
    end
  end

  def session(_role, _account, _opts), do: {:refused, :no_account_dir}

  # The wrapper of "Headless delegates": stdin is the FIFO opened read-write, so the delegate
  # holds a writer itself and never reads end of file; `exec` makes claude the held process.
  # dtach does not report that pid and a headless session writes no session file with a name
  # (F-49), so the wrapper records its own pid, which `exec` keeps, before claude starts. Each
  # process reads its own FIFO, so a line left waiting for an earlier one never reaches it.
  @wrapper ~S"""
  d=$1 f=$2; shift 2
  printf '%s\n' "$$" > "$d/pid"
  exec 3<>"$f"
  exec "$@" <&3 3<&- >>"$d/events.jsonl" 2>>"$d/stderr.log"
  """

  @doc """
  The argv and environment of a headless delegate on `account`: `-p` with stream-json in and
  out, `--verbose` (without it `-p` with stream-json output exits at once),
  `--replay-user-messages` and `--permission-prompts host`, then `--session-id <id>` for a start
  or `--resume <id>` in its place. No prompt: the first message is a line on stdin.

  Options: `:claude`, `:model`, `:env`, `:tool_timeout` and `:mcp` as for `session/3`, and
  exactly one of `:session_id` and `:resume`.

      iex> account = CodingAgentFramework.Accounts.Account.at("work", "/caf/accounts/work/claude")
      iex> env = %{home: "/h", path: "/bin", term: "dumb", lang: "C.UTF-8"}
      iex> {:ok, %{argv: argv}} = CodingAgentFramework.ClaudeCLI.headless(account,
      ...>   claude: "/run/bin/claude", model: "opus", resume: "s1", env: env,
      ...>   tool_timeout: 3_600_000)
      iex> Enum.take(argv, -9)
      ["--input-format", "stream-json", "--output-format", "stream-json",
       "--replay-user-messages", "--permission-prompts", "host", "--resume", "s1"]
  """
  @spec headless(Account.t() | term, keyword) :: {:ok, launch} | {:refused, term}
  def headless(%Account{config_dir: "/" <> _} = account, opts) do
    with {:ok, claude} <- path(opts, :claude),
         {:ok, model} <- word(opts, :model),
         {:ok, id} <- start_or_resume(opts),
         {:ok, mcp} <- mcp(account, opts),
         {:ok, env} <- env(account, opts) do
      argv =
        [claude, "-p", "--verbose", "--model", model, "--settings", account.settings.delegate] ++
          ["--mcp-config" | mcp] ++
          [
            "--strict-mcp-config",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json"
          ] ++
          ["--replay-user-messages", "--permission-prompts", "host" | id]

      {:ok, %{argv: argv, env: env}}
    end
  end

  def headless(_account, _opts), do: {:refused, :no_account_dir}

  @doc """
  `argv` run by the wrapper that holds a headless delegate's log in `dir`
  (`<home>/streams/<session>/`) and its stdin on `fifo`, this process's own FIFO, which
  `Stream.follow/5` made and answered: the host's `sh` runs it, and dtach holds that. It writes
  its pid to `pid` in `dir` first; `exec` keeps it, so it is the held process's. Pure.

      iex> [sh, "-c", _script, "caf-stream", "/h/streams/s1", "/h/streams/s1/in.0", "/run/bin/claude"] =
      ...>   CodingAgentFramework.ClaudeCLI.wrapper("/run/bin/sh", "/h/streams/s1",
      ...>     "/h/streams/s1/in.0", ["/run/bin/claude"])
      iex> sh
      "/run/bin/sh"
  """
  @spec wrapper(String.t(), String.t(), String.t(), [String.t()]) :: [String.t()]
  def wrapper(sh, dir, fifo, argv), do: [sh, "-c", @wrapper, "caf-stream", dir, fifo | argv]

  # The account's servers, then the agent's own: one value each, before `--strict-mcp-config`
  # ends the list.
  defp mcp(account, opts) do
    case Keyword.get(opts, :mcp) do
      nil ->
        {:ok, [account.mcp_config]}

      "/" <> _ = path ->
        if word?(path), do: {:ok, [account.mcp_config, path]}, else: {:refused, {:bad, :mcp}}

      _ ->
        {:refused, {:bad, :mcp}}
    end
  end

  defp start_or_resume(opts) do
    case {Keyword.has_key?(opts, :session_id), Keyword.has_key?(opts, :resume)} do
      {true, false} -> with {:ok, id} <- word(opts, :session_id), do: {:ok, ["--session-id", id]}
      {false, true} -> with {:ok, id} <- word(opts, :resume), do: {:ok, ["--resume", id]}
      _ -> {:refused, :session_id_or_resume}
    end
  end

  defp path(opts, key) do
    case Keyword.get(opts, key) do
      "/" <> _ = p -> {:ok, p}
      nil -> {:refused, {:missing, key}}
      _ -> {:refused, {:bad, key}}
    end
  end

  # A value that is read as a flag's argument: never empty, never a flag itself, one line.
  defp word(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:refused, {:missing, key}}
      v when is_binary(v) -> if word?(v), do: {:ok, v}, else: {:refused, {:bad, key}}
      _ -> {:refused, {:bad, key}}
    end
  end

  defp optional_word(opts, key),
    do: if(Keyword.has_key?(opts, key), do: word(opts, key), else: {:ok, nil})

  defp word?(v), do: v != "" and not String.starts_with?(v, "-") and not (v =~ ~r/[[:cntrl:]]/)

  defp prompt(role, opts, resume) do
    case Keyword.get(opts, :prompt) do
      p when is_binary(p) and p != "" -> {:ok, p}
      nil when role == :delegate and resume == nil -> {:refused, :delegate_without_brief}
      nil -> {:ok, nil}
      _ -> {:refused, {:bad, :prompt}}
    end
  end

  defp env(account, opts) do
    with {:ok, given} <- given_env(Keyword.get(opts, :env)),
         {:ok, ms} <- tool_timeout(Keyword.get(opts, :tool_timeout)) do
      timeouts = [{"MCP_TOOL_TIMEOUT", ms}, {"CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT", ms}]

      {:ok,
       [{"CLAUDE_CONFIG_DIR", account.config_dir}] ++
         Enum.map(@env, fn {k, v} -> {v, given[k]} end) ++ timeouts ++ @fixed}
    end
  end

  defp given_env(given) when is_map(given) do
    case Enum.reject(@env, fn {key, _} -> is_binary(given[key]) and given[key] != "" end) do
      [] -> {:ok, given}
      missing -> {:refused, {:missing, {:env, Keyword.keys(missing)}}}
    end
  end

  defp given_env(_given), do: {:refused, {:missing, :env}}

  # Claude Code holds a tool timeout in `setTimeout`, which takes at most 2^31 - 1 ms, and reads
  # less than a second as no timeout of the launch's own.
  defp tool_timeout(nil), do: {:refused, {:missing, :tool_timeout}}

  defp tool_timeout(ms) when is_integer(ms) and ms >= 1_000 and ms <= 2_147_483_647,
    do: {:ok, Integer.to_string(ms)}

  defp tool_timeout(_), do: {:refused, {:bad, :tool_timeout}}
end
