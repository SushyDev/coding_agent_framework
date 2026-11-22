defmodule CodingAgentFramework.Accounts do
  @moduledoc """
  The Claude accounts of one framework instance, each with its own config directory
  `<home>/accounts/<account>/claude` under the instance's home. The embedding app gives the home and
  the account names; the library reads no environment, and never reads or writes `~/.claude` or
  anything outside the home.

  `prepare/3` writes what an account's sessions run with, from data, before any launch. Claude
  Code keeps files of its own in a config directory and rewrites them from memory, so a write
  there is erased by its next save. In Claude Code 2.1.322 these are `.claude.json` (its global
  state, which also holds MCP servers added with `claude mcp add`), `.credentials.json`,
  `settings.json` (written when a person changes a setting in a session), and the state it
  keeps in `projects/`, `sessions/`, `todos/`, `logs/` and the like. The framework touches none
  of them. It writes only its own files under `<config>/framework/`, which Claude Code reads
  because each launch names them (`CodingAgentFramework.ClaudeCLI`) and never writes:

  - `parent.settings.json` and `delegate.settings.json`: the account's settings and hooks,
    loaded with `--settings`. They differ only in `remoteControlAtStartup`: true for a main session
    and false for a delegate, since 2.1.322 has a flag to turn Remote Control on but none to
    turn it off. Both set `autoContinueAtUsageLimit` true, whatever the caller's settings say:
    at a usage limit under 24 hours away an interactive session waits and goes on by itself, as
    `Limit.tla`'s own wait does (`docs/design.md`, "Usage limits"). The hooks need no matcher
    of their own for a limit: Intake's post every `StopFailure` and `Notification`;
  - `mcp.json`: the MCP servers, loaded with `--mcp-config` and `--strict-mcp-config`, so no
    server from `.claude.json` joins them;
  - `agents/<agent>.settings.json`: an agent's own settings over the account's (`overlay/5`),
    which `Sessions` writes for every delegate, with `includeGitInstructions: false` under them
    (F-200);
  - `statusline.sh`, when `prepare/3` is given the host's `Programs`: the settings' `statusLine`
    command. Claude Code hands it a JSON text with the account's rate limits; it copies a text
    that has the weekly window to `usage_file/2`, which `CodingAgentFramework.Usage` reads, and
    prints nothing.

  This module works on this machine's file system; see `docs/build-notes/F-15.md`.

      iex> {:ok, accounts} = CodingAgentFramework.Accounts.new("/srv/caf", ["work", "home"])
      iex> CodingAgentFramework.Accounts.config_dir(accounts, "work")
      {:ok, "/srv/caf/accounts/work/claude"}
      iex> CodingAgentFramework.Accounts.config_dir(accounts, "other")
      {:refused, {:unknown_account, "other"}}
  """

  alias CodingAgentFramework.Accounts.Account
  alias CodingAgentFramework.{Intake, Programs}

  @enforce_keys [:home, :names]
  defstruct [:home, :names]

  @type t :: %__MODULE__{home: String.t(), names: [String.t()]}

  @name ~r/\A[a-z0-9][a-z0-9_-]{0,31}\z/
  # An agent's name, as a file name.
  @agent ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  @rules ~w(allow deny ask additionalDirectories)

  @doc """
  The accounts `names` under `home`, an absolute path. Nothing is written.

  Returns `{:refused, {:bad_home, home}}` or `{:refused, {:bad_names, names}}` naming each name
  that is not lowercase letters, digits, `_` and `-` (it becomes a directory name).
  """
  @spec new(String.t(), [String.t()]) :: {:ok, t} | {:refused, term}
  def new(home, names) when is_list(names) do
    cond do
      not (is_binary(home) and Path.type(home) == :absolute) ->
        {:refused, {:bad_home, home}}

      (bad = Enum.reject(names, &(is_binary(&1) and &1 =~ @name))) != [] ->
        {:refused, {:bad_names, bad}}

      true ->
        {:ok, %__MODULE__{home: Path.expand(home), names: Enum.uniq(names)}}
    end
  end

  @doc "An account's config directory, whether or not it exists yet."
  @spec config_dir(t, String.t()) :: {:ok, String.t()} | {:refused, {:unknown_account, term}}
  def config_dir(%__MODULE__{} = accounts, name) do
    if name in accounts.names,
      do: {:ok, Path.join([accounts.home, "accounts", name, "claude"])},
      else: {:refused, {:unknown_account, name}}
  end

  @doc """
  The file an account's status line command writes, `<home>/usage/<account>.json`, outside its
  config directory so that no file there is one Claude Code might write.
  """
  @spec usage_file(t, String.t()) :: {:ok, String.t()} | {:refused, {:unknown_account, term}}
  def usage_file(%__MODULE__{} = accounts, name) do
    with {:ok, _} <- config_dir(accounts, name),
         do: {:ok, Path.join([accounts.home, "usage", name <> ".json"])}
  end

  @doc """
  Creates the account's config directory and writes its framework files from `data`:
  `:settings` (a map of Claude Code settings), `:hooks` (the settings' `hooks` map) and
  `:mcp_servers` (a map of server name to its config) and `:programs` (the host's `Programs`,
  for the status line command, which needs its sh and cat) and `:intake` (`%{port: port, secret:
  secret}`, and `tools:`, the tool callbacks the app gives `Intake`: the http hooks of
  `CodingAgentFramework.Intake.hooks/4`, after any `:hooks` of the same event), each optional. A file is written whole to a temporary name and renamed, so a
  launch never reads half of one.

  Returns `{:ok, account}` (see `ready/2`), or `{:refused, reason}` for an unknown account or
  data that is not JSON, or `{:unknown, {path, reason}}` when a write fails.
  """
  @spec prepare(t, String.t(), map) :: {:ok, Account.t()} | {:refused, term} | {:unknown, term}
  def prepare(%__MODULE__{} = accounts, name, data) when is_map(data) do
    settings = Map.get(data, :settings, %{})
    hooks = intake_hooks(Map.get(data, :hooks), name, Map.get(data, :intake))
    settings = if hooks, do: Map.put(settings, "hooks", hooks), else: settings

    with {:ok, dir} <- config_dir(accounts, name),
         account = Account.at(name, dir),
         {:ok, line} <- status_line(accounts, name, dir, Map.get(data, :programs)),
         settings = Map.merge(settings, line.settings),
         {:ok, files} <- encode(account, settings, Map.get(data, :mcp_servers, %{})),
         :ok <- mkdir(Path.join(dir, "framework")),
         :ok <- Enum.reduce_while(line.dirs, :ok, &halt_unless_ok(mkdir(&1), &2)),
         :ok <- write_all(line.files ++ files) do
      {:ok, account}
    end
  end

  @doc """
  The account, once `prepare/3` wrote its files: what `CodingAgentFramework.ClaudeCLI` launches
  with. An account whose config directory or files are missing is refused with
  `{:not_prepared, name}`, so a launch never falls back to `~/.claude`.
  """
  @spec ready(t, String.t()) :: {:ok, Account.t()} | {:refused, term}
  def ready(%__MODULE__{} = accounts, name) do
    with {:ok, dir} <- config_dir(accounts, name) do
      account = Account.at(name, dir)

      if Enum.all?(Account.files(account), &File.regular?/1),
        do: {:ok, account},
        else: {:refused, {:not_prepared, name}}
    end
  end

  @doc """
  Writes agent `name`'s own settings file, `<config>/framework/agents/<name>.settings.json`:
  the account's `role` settings with `settings` (checked by `ClaudeCLI.Options`) over them. The
  `permissions` rule lists (`allow`, `deny`, `ask`, `additionalDirectories`) add to the
  account's, and so do the `hooks` of each event (the account's first, as `prepare/3` puts
  Intake's after the caller's), so a main session's waiter never drops Intake's hooks; any
  other key replaces it. `defaults` (a map, none by default) sit under the account's file: a key
  the account's file or `settings` gives wins over it, so a default is only what nobody said
  (a delegate's `includeGitInstructions: false`, F-200). Answers `{:ok, path}`,
  `{:refused, {:bad, :name}}`, `{:refused, {:not_prepared, account}}` or
  `{:unknown, {path, reason}}`.
  """
  @spec overlay(Account.t(), :parent | :delegate, String.t(), map, map) ::
          {:ok, String.t()} | {:refused, term} | {:unknown, term}
  def overlay(account, role, name, settings, defaults \\ %{})

  def overlay(%Account{} = account, role, name, settings, defaults)
      when role in [:parent, :delegate] and is_map(settings) and is_map(defaults) do
    dir = Path.join([account.config_dir, "framework", "agents"])

    with true <- (is_binary(name) and name =~ @agent) or {:refused, {:bad, :name}},
         path = Path.join(dir, name <> ".settings.json"),
         {:ok, text} <- File.read(account.settings[role]),
         {:ok, %{} = base} <- JSON.decode(text),
         base = Map.merge(defaults, base),
         :ok <- mkdir(dir),
         :ok <- write_all([{path, JSON.encode!(Map.merge(base, settings, &merge/3))}]) do
      {:ok, path}
    else
      {:error, :enoent} -> {:refused, {:not_prepared, account.name}}
      {outcome, _} = failed when outcome in [:refused, :unknown] -> failed
      other -> {:unknown, {account.settings[role], other}}
    end
  end

  def overlay(_account, _role, _name, _settings, _defaults), do: {:refused, {:bad, :overlay}}

  defp merge("permissions", %{} = account, %{} = own) do
    Map.merge(account, own, fn
      key, a, b when key in @rules and is_list(a) and is_list(b) -> Enum.uniq(a ++ b)
      _key, _a, b -> b
    end)
  end

  # F-123's new-2: an overlay's hooks add to the account's, per event.
  defp merge("hooks", %{} = account, %{} = own),
    do: Map.merge(account, own, fn _event, a, b -> List.wrap(a) ++ List.wrap(b) end)

  defp merge(_key, _account, own), do: own

  @doc """
  Whether the account looks logged in, read from which files exist. No file is opened.

  - `{:ok, :logged_out}`: Claude Code never ran there, since it writes `.claude.json` at its
    first start;
  - `{:ok, :looks_logged_in}`: `.credentials.json` exists (Claude Code's file store of a login,
    where no keychain is used);
  - `{:unknown, :login_not_readable}`: Claude Code ran there, but its login is in the system
    keychain or nowhere, and telling which means reading a credential;
  - `{:refused, …}` for an unknown account or no config directory.
  """
  @spec login(t, String.t()) ::
          {:ok, :logged_out | :looks_logged_in} | {:refused, term} | {:unknown, term}
  def login(%__MODULE__{} = accounts, name) do
    with {:ok, dir} <- config_dir(accounts, name) do
      cond do
        not File.dir?(dir) -> {:refused, {:no_config_dir, name}}
        File.exists?(Path.join(dir, ".credentials.json")) -> {:ok, :looks_logged_in}
        not File.exists?(Path.join(dir, ".claude.json")) -> {:ok, :logged_out}
        true -> {:unknown, :login_not_readable}
      end
    end
  end

  defp encode(account, settings, mcp_servers) do
    settings = Map.put(settings, "autoContinueAtUsageLimit", true)

    files = [
      {account.settings.parent, Map.put(settings, "remoteControlAtStartup", true)},
      {account.settings.delegate, Map.put(settings, "remoteControlAtStartup", false)},
      {account.mcp_config, %{"mcpServers" => mcp_servers}}
    ]

    try do
      {:ok, Enum.map(files, fn {path, value} -> {path, JSON.encode!(value)} end)}
    rescue
      e -> {:refused, {:not_json, Exception.message(e)}}
    end
  end

  # Intake's http hooks go after any the caller gives for the same event.
  defp intake_hooks(hooks, _name, nil), do: hooks

  defp intake_hooks(hooks, name, %{port: port, secret: secret} = intake) do
    ours = Intake.hooks(port, name, secret, Map.get(intake, :tools, []))
    Map.merge(hooks || %{}, ours, fn _, own, ours -> own ++ ours end)
  end

  defp status_line(_accounts, _name, _dir, nil), do: {:ok, %{settings: %{}, dirs: [], files: []}}

  defp status_line(accounts, name, dir, programs) do
    with {:ok, %{sh: sh, cat: cat}} <- Programs.take(programs, [:sh, :cat]),
         {:ok, file} <- usage_file(accounts, name) do
      script = Path.join([dir, "framework", "statusline.sh"])

      # Kept only when it has the weekly window: a session's text before its first answer from
      # the API has none, and must not replace a reading. `"seven_day"` with its closing quote
      # matches no longer key.
      text = """
      #!#{sh}
      # Written by coding_agent_framework for Usage; see CodingAgentFramework.Accounts.
      t=$(#{sh_word(cat)}) || exit 0
      case "$t" in *'"seven_day"'*) printf '%s' "$t" > #{sh_word(file)} ;; esac
      """

      command = %{"type" => "command", "command" => "#{sh_word(sh)} #{sh_word(script)}"}

      {:ok,
       %{
         settings: %{"statusLine" => command},
         dirs: [Path.dirname(file)],
         files: [{script, text}]
       }}
    end
  end

  # One sh word: single quotes, with each quote inside closed, escaped and opened again.
  defp sh_word(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"

  defp halt_unless_ok(:ok, :ok), do: {:cont, :ok}
  defp halt_unless_ok(other, :ok), do: {:halt, other}

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:unknown, {dir, reason}}
    end
  end

  defp write_all(files) do
    Enum.reduce_while(files, :ok, fn {path, text}, :ok ->
      tmp = path <> ".tmp"

      with :ok <- File.write(tmp, text), :ok <- File.rename(tmp, path) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:unknown, {path, reason}}}
      end
    end)
  end
end
