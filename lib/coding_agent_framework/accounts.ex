defmodule CodingAgentFramework.Accounts do
  @moduledoc """
  The Claude accounts of one framework instance, each with its own config directory
  `<home>/accounts/<account>/claude` under the instance's home. The host app gives the home and
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
    loaded with `--settings`. They differ only in `remoteControlAtStartup`: true for a parent
    and false for a delegate, since 2.1.322 has a flag to turn Remote Control on but none to
    turn it off;
  - `mcp.json`: the MCP servers, loaded with `--mcp-config` and `--strict-mcp-config`, so no
    server from `.claude.json` joins them.

  This module works on this machine's file system; see `docs/build-notes/F-15.md`.

      iex> {:ok, accounts} = CodingAgentFramework.Accounts.new("/srv/caf", ["work", "home"])
      iex> CodingAgentFramework.Accounts.config_dir(accounts, "work")
      {:ok, "/srv/caf/accounts/work/claude"}
      iex> CodingAgentFramework.Accounts.config_dir(accounts, "other")
      {:refused, {:unknown_account, "other"}}
  """

  alias CodingAgentFramework.Accounts.Account

  @enforce_keys [:home, :names]
  defstruct [:home, :names]

  @type t :: %__MODULE__{home: String.t(), names: [String.t()]}

  @name ~r/\A[a-z0-9][a-z0-9_-]{0,31}\z/

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
  Creates the account's config directory and writes its framework files from `data`:
  `:settings` (a map of Claude Code settings), `:hooks` (the settings' `hooks` map) and
  `:mcp_servers` (a map of server name to its config), each optional. A file is written whole
  to a temporary name and renamed, so a launch never reads half of one.

  Returns `{:ok, account}` (see `ready/2`), or `{:refused, reason}` for an unknown account or
  data that is not JSON, or `{:unknown, {path, reason}}` when a write fails.
  """
  @spec prepare(t, String.t(), map) :: {:ok, Account.t()} | {:refused, term} | {:unknown, term}
  def prepare(%__MODULE__{} = accounts, name, data) when is_map(data) do
    settings = Map.get(data, :settings, %{})
    hooks = Map.get(data, :hooks)
    settings = if hooks, do: Map.put(settings, "hooks", hooks), else: settings

    with {:ok, dir} <- config_dir(accounts, name),
         account = Account.at(name, dir),
         {:ok, files} <- encode(account, settings, Map.get(data, :mcp_servers, %{})),
         :ok <- mkdir(Path.join(dir, "framework")),
         :ok <- write_all(files) do
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
