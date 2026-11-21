defmodule CodingAgentFramework.Usage do
  @moduledoc """
  Each account's allowance and its usage limit: the one reader of both (`docs/design.md`,
  "Usage limits" and "Allowance"; `model/tla/Limit.tla`'s `Read`), and `pick/4`, the account
  with the most room.

  The framework reads no credential and calls no API for it. Its sources, all Claude Code's:

  - **The status line**, its main source: Claude Code hands its `statusLine` command a JSON
    text with the account's two windows after every answer (`CodingAgentFramework.Usage.Reading`),
    and the command `CodingAgentFramework.Accounts.prepare/3` writes copies that text to
    `Accounts.usage_file/2`, `<home>/usage/<account>.json`, from any interactive session on the
    account. `seen_at` is the file's change time in ms.
  - **A headless session's stream**, read from the host's `Stream` on its cues when given one: its
    latest `rate_limit_event`, whose `unifiedWindows` holds both windows after an answer, and
    which names the limit at a rejection. A headless session draws no status line.
  - **A limit record**, an exact fact (`CodingAgentFramework.Usage.Limit`): from the stream's
    event, from a transcript's line (`Transcripts`' fold's `limit`, read from its table on each
    `transcripts:` cue when given `transcripts_db:`, every mode), and from any reader that hands
    one to `take/4`. The `StopFailure` hook's input is not one: it carries no reset (F-181's
    new-1), so it is evidence of the agent's turn only, `Sessions`'. It sets the
    account's `limited_until` (the reset), `limit_window`, `can_spend` and `evidence` (where it
    came from); a later reset replaces it, and one read late never shortens it.

  Of the two windows' sources the newer wins (`source` names it). A window past its reset has
  the whole room again with no session needed (`CodingAgentFramework.Usage.Room`), so no
  reading goes stale: an idle account's reading is old and still right.

  `Usage` writes what it reads to `CodingAgentFramework.Usage.Table`, which it alone writes.
  The caller's supervision tree starts one `Usage` per instance, with no name. Each read writes
  only the rows that changed, in one transaction. A file that cannot be parsed keeps its row's
  last good reading, if any, and names the problem in `problem`; an account with no file and no
  other fact has no row. After a write that changed rows, or the first read, it calls `notify`
  with a cue per account, naming the topic and row ids, never the data: `%{topic:
  "usage:<host>:<account>", ids: ids}`. It must not raise.

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

  alias CodingAgentFramework.{Accounts, Reader, Store, Transcripts}
  alias CodingAgentFramework.Usage.{Limit, Reading, Room, Table}

  @windows ~w(used resets_at five_used five_resets_at)a
  @limit ~w(limited_until limit_window can_spend evidence)a

  @doc """
  The account new work goes to (a start, a resume that must leave its account; F-181, decided
  by the operator): among the usable accounts of `among`, the one with the most room at `now`
  (Unix seconds), the tighter of its two windows by `Room.room/3`, the first in `among` at the
  same room. An account with no reading has the whole room. A spent one, by its windows or its
  limit, is never picked, and credits never count as room. `Mains`, `Delegates` and the `Mover`
  share it; the `Scheduler`'s gate reads the same room (`Usage.Allowance`).

  Options: `usable:`, a function of an account's name answering `{:ok, _}` or `:ok` for one a
  launch may run on now and anything else for one it may not (the rule they share is
  `CodingAgentFramework.Logins.usable/3`: prepared and logged in), by default every account;
  `full_at:`, as `Room.room/3`'s.

  Answers `{:ok, account}`; `{:refused, {:none_usable, reasons}}`, each account's answer, when
  none is usable; `{:refused, {:allowance, retry_at}}` when every usable one is spent,
  `retry_at` (ms) the earliest one has room again; `{:refused, :no_account}` for an empty
  `among`. Pure but for `usable`, and total over `readings`, a map of account to reading as
  `readings/2` gives it.

      iex> readings = %{"a" => %{used: 80.0, resets_at: 200},
      ...>              "b" => %{used: 30.0, resets_at: 200, five_used: 90.0, five_resets_at: 150},
      ...>              "c" => %{used: 50.0, resets_at: 200}}
      iex> CodingAgentFramework.Usage.pick(readings, ["a", "b", "c"], 100)
      {:ok, "c"}
      iex> CodingAgentFramework.Usage.pick(readings, ["a", "b"], 160)
      {:ok, "b"}
      iex> CodingAgentFramework.Usage.pick(readings, ["a", "new"], 100)
      {:ok, "new"}
      iex> CodingAgentFramework.Usage.pick(%{"a" => %{used: 10.0, resets_at: 200, limited_until: 150}}, ["a"], 100)
      {:refused, {:allowance, 150_000}}
      iex> CodingAgentFramework.Usage.pick(readings, ["a", "c"], 100, usable: &if(&1 == "c", do: {:refused, :x}, else: :ok))
      {:ok, "a"}
      iex> CodingAgentFramework.Usage.pick(readings, ["c"], 100, usable: fn _ -> {:refused, :x} end)
      {:refused, {:none_usable, %{"c" => {:refused, :x}}}}
  """
  @spec pick(map, [term], integer, keyword) ::
          {:ok, term} | {:refused, {:allowance, integer} | {:none_usable, map} | :no_account}
  def pick(readings, among, now \\ System.os_time(:second), opts \\ [])

  def pick(readings, among, now, opts) when is_map(readings) and is_list(among) do
    usable = Keyword.get(opts, :usable, fn _ -> :ok end)
    checked = for account <- Enum.uniq(among), do: {account, usable.(account)}
    ok = for {account, answer} <- checked, answer == :ok or match?({:ok, _}, answer), do: account

    rooms =
      for {account, i} <- Enum.with_index(ok),
          do: {account, i, Room.room(Map.get(readings, account), now, opts)}

    open = for {account, i, {:room, room}} <- rooms, do: {-room, i, account}
    spent = for {_, _, {:spent, at}} <- rooms, do: at

    cond do
      open != [] -> {:ok, open |> Enum.min() |> elem(2)}
      spent != [] -> {:refused, {:allowance, Enum.min(spent)}}
      checked != [] -> {:refused, {:none_usable, Map.new(checked)}}
      true -> {:refused, :no_account}
    end
  end

  def pick(_, _, _, _), do: {:refused, :no_account}

  @doc """
  Starts `Usage`. Options: `accounts:` (an `Accounts`), `host:` (this host's name, for the
  topics), `db:` (this instance's SQLite path), and optionally `stream:` (`{module, server}`: the
  host's `CodingAgentFramework.Stream` and its process, whose `rows/2` it reads at each of its
  cues), `transcripts_db:` (the SQLite path of the host's `Transcripts`, whose rows of an
  account it reads at each of that account's cues), `notify:` (a function of one cue) and `interval:` (ms between reads
  of the files; without it, reads happen only on `read/2`).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The topics of the cues it writes, each as its whole shape, `*` for a word it fills in
  (`CodingAgentFramework.Cues`): `usage:<host>:<account>`.
  """
  @spec writes() :: [String.t()]
  def writes, do: ~w(usage:*:*)

  @doc """
  What `Usage` reads, for `Cues`: the host's stream (a headless session's readings and limit)
  and its transcripts (any session's limit).
  """
  @spec reads() :: %{topics: [String.t()], cue: (pid, map -> :ok)}
  def reads, do: %{topics: ~w(stream transcripts), cue: &cue/2}

  @doc """
  A cue of what `Usage` reads: it reads the `Stream`'s rows, or the account's `Transcripts`
  rows, again. Never waits.
  """
  @spec cue(GenServer.server(), map) :: :ok
  def cue(usage, %{topic: "stream:" <> _}), do: GenServer.cast(usage, :stream)

  def cue(usage, %{topic: "transcripts:" <> rest}) do
    case String.split(rest, ":") do
      [_host, account] -> GenServer.cast(usage, {:transcripts, account})
      _ -> :ok
    end
  end

  def cue(_usage, _cue), do: :ok

  @doc """
  Reads every account's file now. Returns `{:ok, %{readings: n, problems: n, ids: ids}}`, where
  `ids` are the `{account, id}` of the rows written.
  """
  @spec read(GenServer.server(), keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def read(usage, opts \\ []), do: call(usage, :read, opts)

  @doc """
  Takes one fact about `account`'s usage from a reader, `fact` a map of `at:` (when it was
  written, ms), `evidence:` (where it came from: a map of strings, such as `%{"source" =>
  "transcript", "session" => id}`), and either or both of `limit:` (a limit record, a decoded
  `quotaLimits` or `rate_limit_info` map) and `windows:` (a `rate_limit_event`'s
  `unifiedWindows`). A record that is not a rejection, or windows older than the account's, add
  nothing. Answers `{:ok, %{ids: ids}}` (the rows written, none when nothing changed), or
  `{:refused, reason}` for an unknown account or a malformed fact.

      Usage.take(usage, "work", %{at: 1_795_243_405_000, evidence: %{"source" => "transcript"},
        limit: %{"status" => "rejected", "resetsAt" => 1_795_254_036, "rateLimitType" => "five_hour"}})
      #=> {:ok, %{ids: [{"work", 1}]}}
  """
  @spec take(GenServer.server(), String.t(), map, keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def take(usage, account, fact, opts \\ []), do: call(usage, {:take, account, fact}, opts)

  @doc """
  `:unread` before the first read; then when it last read and each account's reading by name:
  `used`, `resets_at`, `five_used`, `five_resets_at`, `seen_at`, `source` (`"status_line"` or
  `"stream"`), `problem`, and its limit, `limited_until`, `limit_window`, `can_spend` (a
  boolean) and `evidence` (a map, or nil). An account with no fact has no entry.
  """
  @spec readings(GenServer.server(), keyword) ::
          :unread | {:ok, map} | {:refused, term} | {:unknown, term}
  def readings(usage, opts \\ []), do: call(usage, :readings, opts)

  defp call(usage, request, opts),
    do: Reader.call(usage, request, Keyword.get(opts, :timeout, 10_000), :no_usage)

  @impl true
  def init(opts) do
    with {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)),
         {:ok, transcripts} <- transcripts_db(opts[:transcripts_db]) do
      cache =
        case Table.rows(db) do
          :unread -> %{}
          {:ok, %{rows: rows}} -> Map.new(rows, &{&1.account, Map.take(&1, Table.data_columns())})
        end

      state = %{
        accounts: Keyword.fetch!(opts, :accounts),
        host: Keyword.fetch!(opts, :host),
        stream: Keyword.get(opts, :stream),
        transcripts: transcripts,
        clock: Keyword.get(opts, :clock, fn -> System.os_time(:second) end),
        db: db,
        cache: cache,
        # The stream's last event taken per session, so an unchanged one is not taken again;
        # and each transcript's last limit line taken, by its uuid.
        streamed: %{},
        lines: %{}
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

  def handle_call({:take, account, fact}, _from, state) do
    with true <- account in state.accounts.names or {:refused, {:unknown_account, account}},
         {:ok, row} <- taken(state.cache[account], fact, state.clock.()) do
      {ids, state} = write(state, %{account => row}, false)
      {:reply, {:ok, %{ids: ids}}, state}
    else
      refused -> {:reply, refused, state}
    end
  end

  def handle_call(:readings, _from, state) do
    reply =
      with {:ok, %{read_at: at, rows: rows}} <- Table.rows(state.db),
           do: {:ok, %{read_at: at, readings: Map.new(rows, &{&1.account, shown(&1)})}}

    {:reply, reply, state}
  end

  defp transcripts_db(nil), do: {:ok, nil}
  defp transcripts_db(path), do: Transcripts.Table.open(path)

  @impl true
  def handle_cast({:transcripts, _account}, %{transcripts: nil} = state), do: {:noreply, state}

  def handle_cast({:transcripts, account}, state) do
    with true <- account in state.accounts.names,
         {:ok, %{rows: rows}} <- Transcripts.Table.rows(state.transcripts, state.host, account) do
      {:noreply, take_lines(state, account, rows)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_cast(:stream, %{stream: nil} = state), do: {:noreply, state}

  def handle_cast(:stream, state) do
    {module, stream} = state.stream

    case module.rows(stream, timeout: 5_000) do
      {:ok, %{rows: rows}} -> {:noreply, take_stream(state, rows)}
      _ -> {:noreply, state}
    end
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

    {ids, state} = write(state, rows, true)
    problems = Enum.count(rows, fn {_, row} -> row.problem end)
    {{:ok, %{readings: map_size(rows), problems: problems, ids: ids}}, state}
  end

  # Writes `rows` (account to row) over the cache: all of them when `whole` (a read of the
  # files, which deletes a row it no longer finds), else only those named.
  defp write(state, rows, whole) do
    next = if whole, do: rows, else: Map.merge(state.cache, rows)

    {:ok, %{ids: ids, first: first}} =
      Table.write(state.db, Reader.diff(state.cache, next), System.os_time(:millisecond))

    for name <- state.accounts.names,
        mine <- [for({^name, id} <- ids, do: id)],
        do: Reader.cue(state.notify, "usage:#{state.host}:#{name}", %{ids: mine, first: first})

    {ids, %{state | cache: next}}
  end

  # The file's change time first, then its bytes, so the age shown is never younger than them.
  # Both calls bypass the VM's file server. The windows a newer stream reading gave are kept, and
  # so is the limit; an account whose file is gone keeps a row while it has either.
  defp row(path, cached) do
    with {:ok, info} <- :prim_file.read_file_info(path, [{:time, :posix}]),
         {:ok, bytes} <- :prim_file.read_file(path) do
      mtime = File.Stat.from_record(info).mtime * 1000

      case Reading.parse(bytes) do
        {:ok, reading} ->
          if newer_stream?(cached, mtime),
            do: %{cached | problem: nil},
            else:
              Map.merge(
                base(cached),
                Map.merge(reading, %{seen_at: mtime, source: "status_line", problem: nil})
              )

        {:malformed, reason} ->
          %{base(cached) | problem: Store.text(reason)}
      end
    else
      {:error, :enoent} -> kept(cached)
      {:error, reason} -> %{base(cached) | problem: Store.text({:unreadable, reason})}
    end
  end

  defp newer_stream?(%{source: "stream", seen_at: at}, mtime) when is_integer(at), do: at > mtime
  defp newer_stream?(_cached, _mtime), do: false

  defp kept(%{source: "stream"} = cached), do: %{cached | problem: nil}
  defp kept(%{limited_until: at} = cached) when is_integer(at), do: %{cached | problem: nil}
  defp kept(_cached), do: :none

  defp base(nil),
    do: Map.new(Table.data_columns(), &{&1, nil})

  defp base(row), do: row

  # A fact over the account's row: its windows where newer, its limit where it replaces.
  defp taken(cached, %{at: at, evidence: evidence} = fact, now)
       when is_integer(at) and is_map(evidence) do
    row = base(cached)

    with {:ok, row} <- take_windows(row, fact[:windows], at),
         {:ok, row} <- take_limit(row, fact[:limit], evidence, now),
         do: {:ok, row}
  end

  defp taken(_cached, _fact, _now), do: {:refused, {:bad, :fact}}

  defp take_windows(row, nil, _at), do: {:ok, row}

  defp take_windows(row, unified, at) do
    case Reading.windows(unified) do
      {:ok, w} when w == %{} -> {:ok, row}
      {:ok, _w} when is_integer(row.seen_at) and row.seen_at >= at -> {:ok, row}
      {:ok, w} -> {:ok, Map.merge(row, Map.merge(w, %{seen_at: at, source: "stream"}))}
      {:malformed, reason} -> {:refused, {:malformed, reason}}
    end
  end

  defp take_limit(row, nil, _evidence, _now), do: {:ok, row}

  defp take_limit(row, record, evidence, now) do
    case Limit.parse(record) do
      {:ok, limit} ->
        if Limit.replaces?(limit, row, now) do
          {:ok,
           Map.merge(row, %{
             limited_until: limit.limited_until,
             limit_window: limit.window,
             can_spend: if(limit.can_spend, do: 1, else: 0),
             evidence: JSON.encode!(evidence)
           })}
        else
          {:ok, row}
        end

      :none ->
        {:ok, row}

      {:malformed, reason} ->
        {:refused, {:malformed, reason}}
    end
  end

  # Each headless session's latest `rate_limit_event`, once, on the account its transcript is
  # under. A row's write time stands for the event's.
  defp take_stream(state, rows) do
    Enum.reduce(rows, state, fn row, state ->
      info = Map.get(row, :rate_limit)

      with true <- is_map(info) and state.streamed[row.session] != info,
           {:ok, account} <- account_of(state.accounts, row.transcript),
           fact = %{
             at: row.written_at,
             evidence: %{"source" => "stream", "session" => row.session},
             limit: info,
             windows: info["unifiedWindows"]
           },
           {:ok, new} <- taken(state.cache[account], fact, state.clock.()) do
        {_ids, state} = write(state, %{account => new}, false)
        %{state | streamed: Map.put(state.streamed, row.session, info)}
      else
        _ -> %{state | streamed: Map.put(state.streamed, row.session, info)}
      end
    end)
  end

  # Each transcript's last limit line, once, on the account it is under; its own time is the
  # fact's, or the row's write time where it has none.
  defp take_lines(state, account, rows) do
    Enum.reduce(rows, state, fn row, state ->
      key = {account, row.session_id}

      with %{record: %{} = record, uuid: uuid} = line <- Map.get(row, :limit),
           true <- state.lines[key] != uuid do
        evidence = %{"source" => "transcript", "session" => row.session_id, "line" => uuid}
        fact = %{at: line_time(line.at, row.written_at), evidence: evidence, limit: record}
        state = %{state | lines: Map.put(state.lines, key, uuid)}

        case taken(state.cache[account], fact, state.clock.()) do
          {:ok, new} -> state |> write(%{account => new}, false) |> elem(1)
          _ -> state
        end
      else
        _ -> state
      end
    end)
  end

  defp line_time(at, written_at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _} -> DateTime.to_unix(time, :millisecond)
      _ -> written_at
    end
  end

  defp line_time(_at, written_at), do: written_at

  defp account_of(accounts, path) when is_binary(path) do
    Enum.find_value(accounts.names, {:refused, :no_account}, fn name ->
      {:ok, dir} = Accounts.config_dir(accounts, name)
      if String.starts_with?(path, dir <> "/"), do: {:ok, name}
    end)
  end

  defp account_of(_accounts, _path), do: {:refused, :no_account}

  defp shown(row) do
    evidence =
      case row.evidence && JSON.decode(row.evidence) do
        {:ok, map} -> map
        _ -> nil
      end

    row
    |> Map.take(@windows ++ @limit ++ ~w(seen_at source problem)a)
    |> Map.merge(%{can_spend: row.can_spend in [1, true], evidence: evidence})
  end
end
