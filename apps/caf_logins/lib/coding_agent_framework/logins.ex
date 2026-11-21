defmodule CodingAgentFramework.Logins do
  @moduledoc """
  Each account's login, checked with `claude auth status` under the launch's own environment
  and kept a while, read before a start or a resume (F-181; F-177's new-2). Files alone cannot
  tell: on macOS the login is in the Keychain, and an expired or revoked one leaves every file
  in place, so a session started on it waits on Claude Code's own login screen.

  The framework reads no credential: `claude auth status` reads it, as the launch would, and
  prints whether it is logged in (`CodingAgentFramework.Logins.Status`). The embedding app
  gives `run:`, a function of an account's name that runs it there and answers as
  `CodingAgentFramework.Shell.run/4` does; the library builds no command line of its own.

  A check's state is kept for `max_age` ms (default 10 minutes), logged in or refused, in
  `CodingAgentFramework.Logins.Table`; one that could not tell (the run refused, timed out or
  printed what is not its JSON) is written with its problem and kept for no time, so the next
  read checks again. A refused login is a `login` prompt (`CodingAgentFramework.Prompts`)
  from its first refusal until a check finds it logged in: a person logs in (`bin/caf-login`)
  and answers it `check`, which is `recheck/3`. Every write that changes a row's state cues
  `logins:<host>`.

  The caller's supervision tree starts one per instance, with no name.

      {:ok, logins} = Logins.start_link(accounts: accounts, host: "laptop", db: db, run: run)
      Logins.check(logins, "work")
      #=> :ok
      Logins.check(logins, "home")
      #=> {:refused, {:login, :logged_out}}
  """

  use GenServer

  alias CodingAgentFramework.Accounts
  alias CodingAgentFramework.Logins.{Status, Table}

  @max_age 10 * 60 * 1000
  # A check runs Claude Code once; its own run is bounded by the app's `run`.
  @call 60_000

  @doc """
  Starts it. Options: `accounts:` (an `Accounts`), `host:` (for the topic), `db:` (its SQLite
  path), `run:` (a function of an account's name, answering `{:ok, %{status: status, output:
  output}}`, `{:refused, reason}` or `{:unknown, reason}`), and optionally `max_age:` (ms),
  `notify:` (a function of one cue) and `clock:` (a function answering ms).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The topics of the cues it writes (`CodingAgentFramework.Cues`): `logins:<host>`."
  @spec writes() :: [String.t()]
  def writes, do: ~w(logins:*)

  @doc """
  `account`'s login, checked now unless a check younger than `max_age` says it: `:ok` (logged
  in), `{:refused, {:login, :logged_out | :expired}}`, `{:refused, {:unknown_account, name}}`,
  or `{:unknown, reason}` when the check could not tell. Option `:timeout` (ms).
  """
  @spec check(GenServer.server(), String.t(), keyword) ::
          :ok | {:refused, term} | {:unknown, term}
  def check(logins, account, opts \\ []), do: call(logins, {:check, account, false}, opts)

  @doc "As `check/3`, but checked now whatever the last check said: a `login` prompt's answer."
  @spec recheck(GenServer.server(), String.t(), keyword) ::
          :ok | {:refused, term} | {:unknown, term}
  def recheck(logins, account, opts \\ []), do: call(logins, {:check, account, true}, opts)

  @doc """
  Whether a launch may run on `account` now: prepared (`Accounts.ready/2`) and logged in
  (`check/3`). Answers `{:ok, account}` (the `Accounts.Account`), or the refusal of the first
  that fails, or `{:unknown, reason}`: the rule `Mains`, `Delegates` and the `Mover` share, given
  to `CodingAgentFramework.Usage.pick/4` as its `usable:`.
  """
  @spec usable(GenServer.server(), Accounts.t(), String.t()) ::
          {:ok, Accounts.Account.t()} | {:refused, term} | {:unknown, term}
  def usable(logins, accounts, name) do
    with {:ok, account} <- Accounts.ready(accounts, name),
         :ok <- check(logins, name),
         do: {:ok, account}
  end

  defp call(logins, request, opts) do
    timeout = Keyword.get(opts, :timeout, @call)
    GenServer.call(logins, request, timeout)
  catch
    :exit, {:noproc, _} -> {:refused, :no_logins}
    :exit, {:timeout, _} -> {:unknown, {:timeout, Keyword.get(opts, :timeout, @call)}}
    :exit, {reason, _} -> {:unknown, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      {:ok,
       %{
         accounts: Keyword.fetch!(opts, :accounts),
         host: Keyword.fetch!(opts, :host),
         run: Keyword.fetch!(opts, :run),
         max_age: Keyword.get(opts, :max_age, @max_age),
         notify: Keyword.get(opts, :notify, fn _ -> :ok end),
         clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
         db: db
       }}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:check, account, again}, _from, s) do
    reply =
      if account in s.accounts.names,
        do: check_now(s, account, again),
        else: {:refused, {:unknown_account, account}}

    {:reply, reply, s}
  end

  defp check_now(s, account, again) do
    now = s.clock.()
    row = Table.rows(s.db)[account]

    if not again and fresh?(row, now, s.max_age),
      do: outcome(row),
      else: run(s, account, row, now)
  end

  defp fresh?(%{state: state, checked_at: at}, now, max_age) when state != "unknown",
    do: now - at < max_age

  defp fresh?(_row, _now, _max_age), do: false

  defp run(s, account, row, now) do
    fields =
      case s.run.(account) do
        {:ok, %{status: status, output: output}} ->
          case Status.parse(status, output, now) do
            {:ok, %{method: method, expires_at: at}} ->
              %{state: "logged_in", method: method, expires_at: at, problem: nil, refused_at: nil}

            {:refused, why} ->
              %{state: Atom.to_string(why), problem: nil, refused_at: refused_at(row, now)}

            {:malformed, why} ->
              %{state: "unknown", problem: inspect({:malformed, why})}
          end

        {_, reason} ->
          %{state: "unknown", problem: inspect(reason)}
      end

    fields = Map.put(fields, :checked_at, now)
    id = Table.put(s.db, account, fields)

    if row == nil or row.state != fields.state,
      do: s.notify.(%{topic: "logins:#{s.host}", ids: [id]})

    outcome(Map.merge(row || %{}, fields))
  end

  # The first refusal since the account was last logged in opens the prompt; later ones keep it.
  defp refused_at(%{refused_at: at}, _now) when is_integer(at), do: at
  defp refused_at(_row, now), do: now

  defp outcome(%{state: "logged_in"}), do: :ok

  defp outcome(%{state: state}) when state in ["logged_out", "expired"],
    do: {:refused, {:login, String.to_existing_atom(state)}}

  defp outcome(%{problem: problem}), do: {:unknown, {:login_check, problem}}
end
