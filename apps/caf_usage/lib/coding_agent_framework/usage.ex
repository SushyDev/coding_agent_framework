defmodule CodingAgentFramework.Usage do
  @moduledoc """
  Each account's weekly allowance: the share used and when it resets, and `pick/3`, the account
  with the most left.

  The framework reads no credential and calls no API for it. Claude Code hands its `statusLine`
  command a JSON text with the account's rate limits (`CodingAgentFramework.Usage.Reading`), and
  the command `CodingAgentFramework.Accounts.prepare/3` writes copies that text to
  `Accounts.usage_file/2`, `<home>/usage/<account>.json`. `Usage` reads those files and writes
  what it reads to `CodingAgentFramework.Usage.Table`, which it alone writes. A reading is as old
  as the last session on that account that drew its status line; `seen_at` is the file's change
  time in ms, so a view shows its age.

  The caller's supervision tree starts one `Usage` per instance, with no name. Each read writes
  only the rows that changed, in one transaction. A file that cannot be parsed keeps its row's
  last good reading, if any, and names the problem in `problem`; a file that is gone has its row
  deleted. After a write that changed rows, or the first read, it calls `notify` with a cue per
  account, naming the topic and row ids, never the data: `%{topic: "usage:<host>:<account>",
  ids: ids}`. It must not raise.

      iex> {:ok, accounts} = CodingAgentFramework.Accounts.new(CodingAgentFramework.TestHost.test_dir(), ["work"])
      iex> db = Path.join(accounts.home, "usage.db")
      iex> {:ok, usage} = CodingAgentFramework.Usage.start_link(accounts: accounts, host: "laptop", db: db)
      iex> CodingAgentFramework.Usage.readings(usage)
      :unread
      iex> {:ok, _} = CodingAgentFramework.Usage.read(usage)
      iex> {:ok, %{readings: readings}} = CodingAgentFramework.Usage.readings(usage)
      iex> CodingAgentFramework.Usage.pick(readings, ["work"])
      {:ok, "work"}
  """

  use GenServer

  alias CodingAgentFramework.{Accounts, Reader, Store}
  alias CodingAgentFramework.Usage.{Reading, Table}

  @doc """
  The account among `among` with the most allowance left at `now` (Unix seconds), judged by
  `Reading.status/3` with `max_age` seconds (default 6 hours): the least share used among
  current and assumed readings, a current one before an assumed one at the same share, then the
  first name. A reading whose window has reset is assumed at 0 %, however old. An account with no
  reading is assumed at 0 % too, as a reset week is: nothing on it has run, so a new home can
  start its first session, whose status line gives the first reading. A reading of another
  shape, or one not reset but older than `max_age`, is not known, so it is never picked; with
  none known the answer is `{:refused, :none_known}`. Pure and total over `readings`, a map of
  account to reading as `readings/2` gives it.

      iex> old = 1_000_000
      iex> readings = %{"a" => %{used: 80.0, resets_at: 200, seen_at: old},
      ...>              "b" => %{used: 30.0, resets_at: 200, seen_at: old},
      ...>              "c" => %{used: 5.0, resets_at: 50, seen_at: old}, "d" => :junk}
      iex> CodingAgentFramework.Usage.pick(readings, ["a", "b", "c", "d"], 100)
      {:ok, "c"}
      iex> CodingAgentFramework.Usage.pick(readings, ["a", "b", "d"], 100)
      {:ok, "b"}
      iex> CodingAgentFramework.Usage.pick(readings, ["a", "b"], 100 + 6 * 3600 + 900)
      {:ok, "a"}
      iex> later = %{"a" => %{used: 80.0, resets_at: 99_999, seen_at: old}}
      iex> CodingAgentFramework.Usage.pick(later, ["a"], 100 + 6 * 3600 + 900)
      {:refused, :none_known}
      iex> CodingAgentFramework.Usage.pick(later, ["a", "new"], 100 + 6 * 3600 + 900)
      {:ok, "new"}
      iex> CodingAgentFramework.Usage.pick(%{"b" => %{used: 0.0, resets_at: 99_999, seen_at: old}}, ["a", "b"], 100)
      {:ok, "b"}
  """
  @spec pick(map, [term], integer, integer) :: {:ok, term} | {:refused, :none_known}
  def pick(readings, among, now \\ System.os_time(:second), max_age \\ Reading.max_age())

  def pick(readings, among, now, max_age) when is_map(readings) and is_list(among) do
    known =
      for account <- Enum.uniq(among),
          {kind, used} <- [known(Map.get(readings, account), now, max_age)],
          do: {used, if(kind == :current, do: 0, else: 1), account}

    case Enum.min(known, fn -> nil end) do
      nil -> {:refused, :none_known}
      {_, _, account} -> {:ok, account}
    end
  end

  def pick(_, _, _, _), do: {:refused, :none_known}

  defp known(nil, _now, _max_age), do: {:assumed, 0.0}
  defp known(reading, now, max_age), do: Reading.status(reading, now, max_age)

  @doc """
  Starts `Usage`. Options: `accounts:` (an `Accounts`), `host:` (this host's name, for the
  topics), `db:` (this instance's SQLite path), and optionally `notify:` (a function of one cue)
  and `interval:` (ms between reads; without it, reads happen only on `read/2`).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Reads every account's file now. Returns `{:ok, %{readings: n, problems: n, ids: ids}}`, where
  `ids` are the `{account, id}` of the rows written.
  """
  @spec read(GenServer.server(), keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def read(usage, opts \\ []), do: call(usage, :read, opts)

  @doc """
  `:unread` before the first read; then when it last read and each account's reading by name:
  `used`, `resets_at`, `seen_at` and `problem`. An account with no file has no entry.
  """
  @spec readings(GenServer.server(), keyword) ::
          :unread | {:ok, map} | {:refused, term} | {:unknown, term}
  def readings(usage, opts \\ []), do: call(usage, :readings, opts)

  defp call(usage, request, opts),
    do: Reader.call(usage, request, Keyword.get(opts, :timeout, 10_000), :no_usage)

  @impl true
  def init(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      cache =
        case Table.rows(db) do
          :unread -> %{}
          {:ok, %{rows: rows}} -> by_account(rows)
        end

      state = %{
        accounts: Keyword.fetch!(opts, :accounts),
        host: Keyword.fetch!(opts, :host),
        db: db,
        cache: cache
      }

      {:ok, Map.merge(state, Reader.loop(opts))}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:read, _from, state) do
    {reply, state} = read_now(state)
    {:reply, reply, state}
  end

  def handle_call(:readings, _from, state) do
    reply =
      with {:ok, %{read_at: at, rows: rows}} <- Table.rows(state.db) do
        {:ok, %{read_at: at, readings: by_account(rows)}}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, Reader.tick(state, &read_now/1)}

  defp read_now(state) do
    rows =
      for name <- state.accounts.names,
          {:ok, path} <- [Accounts.usage_file(state.accounts, name)],
          row <- [row(path, state.cache[name])],
          row != :none,
          into: %{},
          do: {name, row}

    {:ok, %{ids: ids, first: first}} =
      Table.write(state.db, Reader.diff(state.cache, rows), System.os_time(:millisecond))

    for name <- state.accounts.names,
        mine <- [for({^name, id} <- ids, do: id)],
        do: Reader.cue(state.notify, "usage:#{state.host}:#{name}", %{ids: mine, first: first})

    problems = Enum.count(rows, fn {_, row} -> row.problem end)
    {{:ok, %{readings: map_size(rows), problems: problems, ids: ids}}, %{state | cache: rows}}
  end

  # The file's change time first, then its bytes, so the age shown is never younger than them.
  # Both calls bypass the VM's file server.
  defp row(path, cached) do
    with {:ok, info} <- :prim_file.read_file_info(path, [{:time, :posix}]),
         {:ok, bytes} <- :prim_file.read_file(path) do
      case Reading.parse(bytes) do
        {:ok, reading} ->
          Map.merge(reading, %{seen_at: File.Stat.from_record(info).mtime * 1000, problem: nil})

        {:malformed, reason} ->
          %{last_good(cached) | problem: Store.text(reason)}
      end
    else
      {:error, :enoent} -> :none
      {:error, reason} -> %{last_good(cached) | problem: Store.text({:unreadable, reason})}
    end
  end

  defp last_good(nil),
    do: %{
      used: nil,
      resets_at: nil,
      five_used: nil,
      five_resets_at: nil,
      seen_at: nil,
      problem: nil
    }

  defp last_good(row), do: row

  defp by_account(rows), do: Map.new(rows, &{&1.account, Map.take(&1, Table.data_columns())})
end
