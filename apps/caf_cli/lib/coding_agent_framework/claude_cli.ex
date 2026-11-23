defmodule CodingAgentFramework.ClaudeCLI do
  @moduledoc """
  The command line and environment of one Claude Code session, per role and account. Pure: it
  starts nothing. Its output goes to `CodingAgentFramework.Holder.hold/4`, whose `env -i` keeps
  only the variables listed here.

  The flags are those of Claude Code 2.1.322 (`claude --help`), the version devenv pins:

  - `--model <model>` and `--name <name>`, and `--effort <level>` after them when the launch
    names an `:effort` (`efforts/0`, the levels `claude --help` lists);
  - `--settings <file>` (the role's settings file) and `--mcp-config <file>` with
    `--strict-mcp-config`, the files `CodingAgentFramework.Accounts.prepare/3` wrote, and
    after the account's file the agent's own (`mcp:`, from `CodingAgentFramework.MCP.issue/2`),
    which carries who the agent is;
  - the agent's own `:options` (`CodingAgentFramework.ClaudeCLI.Options.argv/1`), and its own
    `:settings` file in the account's place when it has a settings overlay;
  - `--remote-control <name>` for a main session (role `:parent`) only. A delegate's settings
    file sets `remoteControlAtStartup` to false, since no flag turns Remote Control off;
  - `--resume <id>` when given;
  - `--` and the first prompt last, so a prompt that starts with `-` is not read as a flag and
    no flag that takes an optional or repeated value (`--remote-control`, `--mcp-config`)
    swallows it.

  No `--bg`: a background session dies with its daemon and forks on resume.

  The environment is exactly:

  - `CLAUDE_CONFIG_DIR`: the account's own directory, so nothing comes from `~/.claude`;
  - `HOME`: the person's home, where macOS's `security` finds the Keychain; gh, git and ssh
    keep their state in the framework home instead (`:tools` below);
  - `PATH`: how its Bash tool finds the programs a session runs, and on macOS how Claude Code
    finds `security`, which reads its login from the Keychain (in 2.1.322), so the launch's
    `PATH` must hold `/usr/bin`;
  - `TERM`: the terminal type its screen is drawn for, which dtach does not set;
  - `LANG`: a UTF-8 locale, so text past ASCII is read and drawn as it is;
  - `USER`, the launch env's `:user` (the OS user's name, which the app gives), when given: on
    macOS the Keychain item holding the login has the OS user as its account, and Claude Code
    2.1.322 finds it by `USER` with no fallback (`LOGNAME` or the OS user name does not do), so
    without it `claude auth status` answers `loggedIn: false`. A non-empty name with no control
    character, else `{:bad, :user}`. The app requires it on macOS;
  - the CA bundle the embedding app gives as the launch env's `:ca` (a map of variable name to
    an absolute path, such as `NODE_EXTRA_CA_CERTS`), sorted by name: Claude Code runs on Node,
    which reads its own bundle, and a machine whose certificates come from devenv or Nix has them
    in none of the places Node looks, so without it no session reaches the API
    (`UNABLE_TO_GET_ISSUER_CERT_LOCALLY`, F-151). The library never reads its own environment;
  - where the tools a session runs keep their state, the launch env's `:tools`, as the app gives
    them (`{name, value}` pairs in order, from `CodingAgentFramework.ToolHome.env/2`):
    `GH_CONFIG_DIR`, `GIT_CONFIG_GLOBAL`, the `XDG_*_HOME` directories and `GIT_SSH_COMMAND`, all
    under the framework home, so gh, git and ssh write nothing in the person's own folders
    (F-155). None may be a name the launch sets itself;
  - `MCP_TOOL_TIMEOUT` and `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`, both the launch's
    `:tool_timeout` (ms): how long Claude Code waits on one MCP tool call before it gives up,
    in all and with no byte or progress from the server. Claude Code 2.1.322 reads both from
    its environment as integers; without them it gives an `http` server's call 5 minutes of
    silence and its HTTP request 60 seconds. `CodingAgentFramework.MCP` keeps a
    `run_delegate`'s wait under the same value, less a margin, so the client never gives up
    first;
  - the `env` of the agent's own options, sorted by name;
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
  alias CodingAgentFramework.ClaudeCLI.Options

  @type role :: :parent | :delegate
  @type launch :: %{argv: [String.t()], env: [{String.t(), String.t()}]}

  @env [home: "HOME", path: "PATH", term: "TERM", lang: "LANG"]

  # What `claude --help` lists for `--effort` in 2.1.322; one list, so a start's refusal and the
  # launch check the same levels.
  @efforts ~w(low medium high xhigh max)

  # Set by the framework, not given by the caller, so no launch can leave it out.
  @fixed [{"DISABLE_AUTOUPDATER", "1"}]

  @doc """
  The levels `--effort` takes, as `claude --help` lists them on the pinned release.

      iex> CodingAgentFramework.ClaudeCLI.efforts()
      ["low", "medium", "high", "xhigh", "max"]
  """
  @spec efforts() :: [String.t()]
  def efforts, do: @efforts

  @doc """
  The argv and environment of a session of `role` on `account` (from
  `CodingAgentFramework.Accounts.ready/2`).

  Options: `:claude` (its absolute path, from `Programs`), `:model`, `:name`, `:env` (a map of
  `:home`, `:path`, `:term`, `:lang` and optionally `:user`), `:tool_timeout` (ms, 1 000 to 2 147 483 647: the MCP
  tool timeout), and optionally `:resume` (a session id), `:prompt` (the first prompt),
  `:effort` (one of `efforts/0`; nil is none), `:options` and `:settings`. A delegate needs its
  brief as `:prompt` unless it resumes.

  Returns `{:ok, %{argv: argv, env: env}}` or `{:refused, reason}`: `:no_account_dir` when
  `account` is not an account with a config directory, `{:missing, option}`, `{:bad, option}`,
  `{:bad_role, role}`, `:delegate_without_brief` or `{:bad_option, option, why}`.
  """
  @spec session(role, Account.t() | term, keyword) :: {:ok, launch} | {:refused, term}
  def session(role, account, opts)

  def session(role, _account, _opts) when role not in [:parent, :delegate],
    do: {:refused, {:bad_role, role}}

  def session(role, %Account{config_dir: "/" <> _} = account, opts) do
    with {:ok, claude} <- path(opts, :claude),
         {:ok, model} <- word(opts, :model),
         {:ok, name} <- word(opts, :name),
         {:ok, effort} <- effort(opts),
         {:ok, resume} <- optional_word(opts, :resume),
         {:ok, mcp} <- mcp(account, opts),
         {:ok, prompt} <- prompt(role, opts, resume),
         {:ok, own} <- own(account.settings[role], opts),
         {:ok, env} <- env(account, opts, own.options) do
      argv =
        [claude, "--model", model, "--name", name] ++
          effort ++
          own.argv ++
          ["--mcp-config" | mcp] ++
          ["--strict-mcp-config"] ++
          if(role == :parent, do: ["--remote-control", name], else: []) ++
          if(resume, do: ["--resume", resume], else: []) ++
          if(prompt, do: ["--", prompt], else: [])

      {:ok, %{argv: argv, env: env}}
    end
  end

  def session(_role, _account, _opts), do: {:refused, :no_account_dir}

  @doc """
  The argv and environment of `claude auth status --json` on `account`: the same environment a
  session's launch has (options `:claude`, `:env` and `:tool_timeout`, as `session/3`'s), so it
  reads the very login the launch would (`CodingAgentFramework.Logins`). Pure.

      iex> account = CodingAgentFramework.Accounts.Account.at("work", "/caf/accounts/work/claude")
      iex> env = %{home: "/h", path: "/bin", term: "xterm-256color", lang: "C.UTF-8"}
      iex> {:ok, %{argv: argv, env: [first | _]}} = CodingAgentFramework.ClaudeCLI.auth_status(account,
      ...>   claude: "/run/bin/claude", env: env, tool_timeout: 3_600_000)
      iex> {argv, first}
      {["/run/bin/claude", "auth", "status", "--json"], {"CLAUDE_CONFIG_DIR", "/caf/accounts/work/claude"}}
  """
  @spec auth_status(Account.t(), keyword) :: {:ok, launch} | {:refused, term}
  def auth_status(%Account{config_dir: "/" <> _} = account, opts) do
    with {:ok, claude} <- path(opts, :claude),
         {:ok, env} <- env(account, opts, %{}),
         do: {:ok, %{argv: [claude, "auth", "status", "--json"], env: env}}
  end

  def auth_status(_account, _opts), do: {:refused, :no_account_dir}

  # The wrapper of "Headless delegates": stdin is the FIFO opened read-write, so the delegate
  # holds a writer itself and never reads end of file; `exec` makes claude the held process.
  # The pid is `Holder.Process`'s record, with its start time, written by the hold around this
  # (F-118's new-4). Each process reads its own FIFO, so a line left waiting for an earlier one
  # never reaches it.
  @wrapper ~S"""
  d=$1 f=$2; shift 2
  exec 3<>"$f"
  exec "$@" <&3 3<&- >>"$d/events.jsonl" 2>>"$d/stderr.log"
  """

  @doc """
  The argv and environment of a headless delegate on `account`: `-p` with stream-json in and
  out, `--verbose` (without it `-p` with stream-json output exits at once),
  `--replay-user-messages`, `--permission-prompts host` and `--permission-prompt-tool stdio`
  (without it the pinned Claude Code denies what would prompt, `permission_denied`, and sends
  no `can_use_tool`, F-221), then `--session-id <id>` for a start
  or `--resume <id>` in its place. No prompt: the first message is a line on stdin.

  Options: `:claude`, `:model`, `:env`, `:tool_timeout`, `:mcp` and `:effort` as for `session/3`,
  and exactly one of `:session_id` and `:resume`; `:options` and `:settings` as well.

      iex> account = CodingAgentFramework.Accounts.Account.at("work", "/caf/accounts/work/claude")
      iex> env = %{home: "/h", path: "/bin", term: "dumb", lang: "C.UTF-8"}
      iex> {:ok, %{argv: argv}} = CodingAgentFramework.ClaudeCLI.headless(account,
      ...>   claude: "/run/bin/claude", model: "opus", resume: "s1", env: env,
      ...>   tool_timeout: 3_600_000)
      iex> Enum.take(argv, -11)
      ["--input-format", "stream-json", "--output-format", "stream-json",
       "--replay-user-messages", "--permission-prompts", "host",
       "--permission-prompt-tool", "stdio", "--resume", "s1"]
  """
  @spec headless(Account.t() | term, keyword) :: {:ok, launch} | {:refused, term}
  def headless(%Account{config_dir: "/" <> _} = account, opts) do
    with {:ok, claude} <- path(opts, :claude),
         {:ok, model} <- word(opts, :model),
         {:ok, effort} <- effort(opts),
         {:ok, id} <- start_or_resume(opts),
         {:ok, mcp} <- mcp(account, opts),
         {:ok, own} <- own(account.settings.delegate, opts),
         {:ok, env} <- env(account, opts, own.options) do
      argv =
        [claude, "-p", "--verbose", "--model", model] ++
          effort ++
          own.argv ++
          ["--mcp-config" | mcp] ++
          [
            "--strict-mcp-config",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json"
          ] ++
          ["--replay-user-messages", "--permission-prompts", "host"] ++
          ["--permission-prompt-tool", "stdio" | id]

      {:ok, %{argv: argv, env: env}}
    end
  end

  def headless(_account, _opts), do: {:refused, :no_account_dir}

  @doc """
  `argv` run by the wrapper that holds a headless delegate's log in `dir`
  (`<home>/streams/<session>/`) and its stdin on `fifo`, this process's own FIFO, which
  `Stream.follow/5` made and answered: the host's `sh` runs it, and dtach holds that, under
  `Holder.Process`'s record; `exec` keeps the pid, so it is the held process's. Pure.

      iex> [sh, "-c", _script, "caf-stream", "/h/streams/s1", "/h/streams/s1/in.0", "/run/bin/claude"] =
      ...>   CodingAgentFramework.ClaudeCLI.wrapper("/run/bin/sh", "/h/streams/s1",
      ...>     "/h/streams/s1/in.0", ["/run/bin/claude"])
      iex> sh
      "/run/bin/sh"
  """
  @spec wrapper(String.t(), String.t(), String.t(), [String.t()]) :: [String.t()]
  def wrapper(sh, dir, fifo, argv), do: [sh, "-c", @wrapper, "caf-stream", dir, fifo | argv]

  # The launch's prompt from a file (F-137): read into the last argument, after `--`, so no
  # shell string ever holds it; the file goes once read, and a read that fails starts nothing.
  @prompted ~S"""
  c=$1 r=$2 f=$3; shift 3
  p=$("$c" -- "$f") || exit 1
  "$r" -f -- "$f"
  exec "$@" -- "$p"
  """

  # The longest prompt a launch carries, in bytes, per operating system. macOS takes about 1 MiB
  # of arguments and environment together (`getconf ARG_MAX` is 1 048 576; one argument of
  # 900 000 bytes passed and one of 1 100 000 did not, measured for F-137), so half of it leaves
  # room for the rest. Linux takes more in all but refuses any one argument over
  # `MAX_ARG_STRLEN`, 131 072 bytes with its closing NUL (32 pages of 4 KiB), with E2BIG; 4 KiB
  # under it leaves a margin.
  @prompt_max %{darwin: 524_288, linux: 126_976}

  @doc """
  The longest prompt, in bytes, a launch carries as its argument (`prompted/5`) on a host of
  operating system `os` (`CodingAgentFramework.Programs.os/1`): `{:ok, bytes}`, or
  `{:refused, {:os, os}}` for one whose limit was never measured. A longer first row goes as a
  pointer to its file (`CodingAgentFramework.Mailbox.launch/4`).

      iex> CodingAgentFramework.ClaudeCLI.prompt_max(:linux)
      {:ok, 126_976}
      iex> CodingAgentFramework.ClaudeCLI.prompt_max(:unknown)
      {:refused, {:os, :unknown}}
  """
  @spec prompt_max(atom) :: {:ok, pos_integer} | {:refused, {:os, atom}}
  def prompt_max(os) do
    case Map.fetch(@prompt_max, os) do
      {:ok, max} -> {:ok, max}
      :error -> {:refused, {:os, os}}
    end
  end

  @doc """
  `argv` (a session's, with no prompt) run by a wrapper that reads its first prompt from
  `file`, with the host's `cat`, removes the file, and execs `argv` with `--` and the prompt as
  its last argument. The launch's prompt (Delivery's `launch` transport) goes this way, so a
  long or multi-line text is never part of a shell string. Pure.

      iex> [sh, "-c", _script, "caf-prompt", "/bin/cat", "/bin/rm", "/d/p", "/run/bin/claude"] =
      ...>   CodingAgentFramework.ClaudeCLI.prompted("/bin/sh", "/bin/cat", "/bin/rm", "/d/p",
      ...>     ["/run/bin/claude"])
      iex> sh
      "/bin/sh"
  """
  @spec prompted(String.t(), String.t(), String.t(), String.t(), [String.t()]) :: [String.t()]
  def prompted(sh, cat, rm, file, argv),
    do: [sh, "-c", @prompted, "caf-prompt", cat, rm, file | argv]

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

  # `--effort <level>` when the launch names one; nil is none.
  defp effort(opts) do
    case Keyword.get(opts, :effort) do
      nil -> {:ok, []}
      level when level in @efforts -> {:ok, ["--effort", level]}
      _ -> {:refused, {:bad, :effort}}
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

  # An overlay's file holds the account's settings too: `--settings` takes one (F-110, new-1).
  defp own(account_settings, opts) do
    with {:ok, options} <- Options.check(Keyword.get(opts, :options)),
         file = Keyword.get(opts, :settings, !options[:settings] && account_settings),
         true <- file != false or {:refused, {:missing, :settings}},
         true <- match?("/" <> _, file) or {:refused, {:bad, :settings}},
         do: {:ok, %{options: options, argv: ["--settings", file] ++ Options.argv(options)}}
  end

  defp env(account, opts, options) do
    with {:ok, given} <- given_env(Keyword.get(opts, :env)),
         {:ok, user} <- user(Map.get(given, :user)),
         {:ok, ca} <- ca(Map.get(given, :ca, %{})),
         {:ok, tools} <- tools(Map.get(given, :tools, [])),
         {:ok, ms} <- tool_timeout(Keyword.get(opts, :tool_timeout)) do
      timeouts = [{"MCP_TOOL_TIMEOUT", ms}, {"CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT", ms}]

      {:ok,
       [{"CLAUDE_CONFIG_DIR", account.config_dir}] ++
         Enum.map(@env, fn {k, v} -> {v, given[k]} end) ++
         user ++
         ca ++ tools ++ timeouts ++ Enum.sort(Map.get(options, :env, %{})) ++ @fixed}
    end
  end

  # The names the launch sets itself, which the tools' state may not set again.
  @own ~w(CLAUDE_CONFIG_DIR HOME PATH TERM LANG USER MCP_TOOL_TIMEOUT
          CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT DISABLE_AUTOUPDATER)

  # Where the tools an agent runs keep their state (F-155), as the app gives it: `{name, value}`
  # pairs, in order, each name of capitals, digits and `_` and none the launch sets itself.
  defp tools(tools) when is_list(tools) do
    if Enum.all?(tools, fn
         {k, v} when is_binary(k) and is_binary(v) ->
           k =~ ~r/\A[A-Z][A-Z0-9_]*\z/ and k not in @own and not (v =~ ~r/[[:cntrl:]]/)

         _ ->
           false
       end),
       do: {:ok, tools},
       else: {:refused, {:bad, :tools}}
  end

  defp tools(_), do: {:refused, {:bad, :tools}}

  # The OS user's name, as the app gives it: optional here (the app requires it on macOS).
  defp user(nil), do: {:ok, []}

  defp user(name) when is_binary(name) do
    if name != "" and not (name =~ ~r/[[:cntrl:]]/),
      do: {:ok, [{"USER", name}]},
      else: {:refused, {:bad, :user}}
  end

  defp user(_), do: {:refused, {:bad, :user}}

  # The CA bundle's variables, as the app gives them: a name of capitals, digits and `_`, and an
  # absolute path with no control character.
  defp ca(ca) when is_map(ca) do
    if Enum.all?(ca, fn {k, v} ->
         is_binary(k) and k =~ ~r/\A[A-Z][A-Z0-9_]*\z/ and is_binary(v) and
           String.starts_with?(v, "/") and not (v =~ ~r/[[:cntrl:]]/)
       end),
       do: {:ok, Enum.sort(ca)},
       else: {:refused, {:bad, :ca}}
  end

  defp ca(_), do: {:refused, {:bad, :ca}}

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
