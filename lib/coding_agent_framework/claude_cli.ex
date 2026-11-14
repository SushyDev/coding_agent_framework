defmodule CodingAgentFramework.ClaudeCLI do
  @moduledoc """
  The command line and environment of one Claude Code session, per role and account. Pure: it
  starts nothing. Its output goes to `CodingAgentFramework.Holder.hold/4`, whose `env -i` keeps
  only the variables listed here.

  The flags are those of Claude Code 2.1.322 (`claude --help`), the version devenv pins:

  - `--model <model>` and `--name <name>`;
  - `--settings <file>` (the role's settings file) and `--mcp-config <file>` with
    `--strict-mcp-config`, the files `CodingAgentFramework.Accounts.prepare/3` wrote;
  - `--remote-control <name>` for a parent only. A delegate's settings file sets
    `remoteControlAtStartup` to false, since no flag turns Remote Control off;
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
  - `LANG`: a UTF-8 locale, so text past ASCII is read and drawn as it is.

  Everything else, such as an inherited `CLAUDECODE`, `CLAUDE_CODE_*` or `TMUX`, stays out.

      iex> account = CodingAgentFramework.Accounts.Account.at("work", "/caf/accounts/work/claude")
      iex> env = %{home: "/h", path: "/bin", term: "xterm-256color", lang: "C.UTF-8"}
      iex> {:ok, %{argv: argv, env: vars}} = CodingAgentFramework.ClaudeCLI.session(:parent, account,
      ...>   claude: "/run/bin/claude", model: "opus", name: "main", env: env)
      iex> argv
      ["/run/bin/claude", "--model", "opus", "--name", "main",
       "--settings", "/caf/accounts/work/claude/framework/parent.settings.json",
       "--mcp-config", "/caf/accounts/work/claude/framework/mcp.json", "--strict-mcp-config",
       "--remote-control", "main"]
      iex> hd(vars)
      {"CLAUDE_CONFIG_DIR", "/caf/accounts/work/claude"}
  """

  alias CodingAgentFramework.Accounts.Account

  @type role :: :parent | :delegate
  @type launch :: %{argv: [String.t()], env: [{String.t(), String.t()}]}

  @env [home: "HOME", path: "PATH", term: "TERM", lang: "LANG"]

  @doc """
  The argv and environment of a session of `role` on `account` (from
  `CodingAgentFramework.Accounts.ready/2`).

  Options: `:claude` (its absolute path, from `Programs`), `:model`, `:name`, `:env` (a map of
  `:home`, `:path`, `:term` and `:lang`), and optionally `:resume` (a session id) and `:prompt`
  (the first prompt). A delegate needs its brief as `:prompt` unless it resumes.

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
         {:ok, prompt} <- prompt(role, opts, resume),
         {:ok, env} <- env(account, Keyword.get(opts, :env)) do
      argv =
        [claude, "--model", model, "--name", name] ++
          ["--settings", account.settings[role]] ++
          ["--mcp-config", account.mcp_config, "--strict-mcp-config"] ++
          if(role == :parent, do: ["--remote-control", name], else: []) ++
          if(resume, do: ["--resume", resume], else: []) ++
          if(prompt, do: ["--", prompt], else: [])

      {:ok, %{argv: argv, env: env}}
    end
  end

  def session(_role, _account, _opts), do: {:refused, :no_account_dir}

  # The wrapper of "Headless delegates": stdin is the FIFO opened read-write, so the delegate
  # holds a writer itself and never reads end of file; `exec` makes claude the held process.
  @wrapper ~S"""
  d=$1; shift
  exec 3<>"$d/in"
  exec "$@" <&3 3<&- >>"$d/events.jsonl" 2>>"$d/stderr.log"
  """

  @doc """
  The argv and environment of a headless delegate on `account`: `-p` with stream-json in and
  out, `--verbose` (without it `-p` with stream-json output exits at once),
  `--replay-user-messages` and `--permission-prompts host`, then `--session-id <id>` for a start
  or `--resume <id>` in its place. No prompt: the first message is a line on stdin.

  Options: `:claude`, `:model`, `:env` as for `session/3`, and exactly one of `:session_id` and
  `:resume`.

      iex> account = CodingAgentFramework.Accounts.Account.at("work", "/caf/accounts/work/claude")
      iex> env = %{home: "/h", path: "/bin", term: "dumb", lang: "C.UTF-8"}
      iex> {:ok, %{argv: argv}} = CodingAgentFramework.ClaudeCLI.headless(account,
      ...>   claude: "/run/bin/claude", model: "opus", resume: "s1", env: env)
      iex> Enum.take(argv, -9)
      ["--input-format", "stream-json", "--output-format", "stream-json",
       "--replay-user-messages", "--permission-prompts", "host", "--resume", "s1"]
  """
  @spec headless(Account.t() | term, keyword) :: {:ok, launch} | {:refused, term}
  def headless(%Account{config_dir: "/" <> _} = account, opts) do
    with {:ok, claude} <- path(opts, :claude),
         {:ok, model} <- word(opts, :model),
         {:ok, id} <- start_or_resume(opts),
         {:ok, env} <- env(account, Keyword.get(opts, :env)) do
      argv =
        [claude, "-p", "--verbose", "--model", model, "--settings", account.settings.delegate] ++
          ["--mcp-config", account.mcp_config, "--strict-mcp-config"] ++
          ["--input-format", "stream-json", "--output-format", "stream-json"] ++
          ["--replay-user-messages", "--permission-prompts", "host" | id]

      {:ok, %{argv: argv, env: env}}
    end
  end

  def headless(_account, _opts), do: {:refused, :no_account_dir}

  @doc """
  `argv` run by the wrapper that holds a headless delegate's stdin and log in `dir`
  (`<home>/streams/<session>/`, whose FIFO `in` must exist): the host's `sh` runs it, and dtach
  holds that. Pure.

      iex> [sh, "-c", _script, "caf-stream", "/h/streams/s1", "/run/bin/claude"] =
      ...>   CodingAgentFramework.ClaudeCLI.wrapper("/run/bin/sh", "/h/streams/s1", ["/run/bin/claude"])
      iex> sh
      "/run/bin/sh"
  """
  @spec wrapper(String.t(), String.t(), [String.t()]) :: [String.t()]
  def wrapper(sh, dir, argv), do: [sh, "-c", @wrapper, "caf-stream", dir | argv]

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

  defp env(account, given) when is_map(given) do
    case Enum.reject(@env, fn {key, _} -> is_binary(given[key]) and given[key] != "" end) do
      [] ->
        {:ok,
         [
           {"CLAUDE_CONFIG_DIR", account.config_dir}
           | Enum.map(@env, fn {k, v} -> {v, given[k]} end)
         ]}

      missing ->
        {:refused, {:missing, {:env, Keyword.keys(missing)}}}
    end
  end

  defp env(_account, _given), do: {:refused, {:missing, :env}}
end
