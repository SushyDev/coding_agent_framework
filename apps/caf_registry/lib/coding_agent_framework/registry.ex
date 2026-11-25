defmodule CodingAgentFramework.Registry do
  @moduledoc """
  Reads Claude Code's `<config>/sessions/*.json` for every account the framework holds on one
  host, and writes what it reads to `CodingAgentFramework.Registry.Table`, which it alone
  writes. A reader on `CodingAgentFramework.Reader`.

  The caller's supervision tree starts one `Registry` per host, with no name, over every
  account, so an agent is found whichever account it runs in, and a move between accounts never
  hides one. The files are read through `CodingAgentFramework.Shell`, so a host over ssh is read
  the same way. A held agent's pid comes from here: dtach does not report it.

      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> File.mkdir_p!(Path.join(dir, "sessions"))
      iex> File.write!(Path.join(dir, "sessions/7.json"), ~s({"pid": 7, "sessionId": "s7"}))
      iex> me = self()
      iex> host = CodingAgentFramework.Host.local("laptop", CodingAgentFramework.TestHost.program!(:kill))
      iex> {:ok, reg} = CodingAgentFramework.Registry.start_link(
      ...>   programs: CodingAgentFramework.TestHost.programs(host), accounts: %{"work" => dir},
      ...>   db: Path.join(dir, "registry.db"), notify: &send(me, &1))
      iex> CodingAgentFramework.Registry.rows(reg, "work")
      :unread
      iex> {:ok, %{files: 1, problems: 0, ids: [id]}} = CodingAgentFramework.Registry.read(reg)
      iex> receive do: (cue -> cue)
      %{topic: "registry:laptop:work", ids: [id]}

  Each read lists every account's files and reads them in one shell command, checks every pid
  with one `ps` (`CodingAgentFramework.Holder.Process.liveness/3`), and writes only the rows that
  changed, in one transaction.

  A row's `proc_start` is always in `Holder.Process`' one form, `LC_ALL=C TZ=UTC ps -o lstart=`
  with its runs of spaces made one, the form every check and signal of a start compares. Claude
  Code 2.1.322 writes that form on macOS, and on Linux a start in clock ticks since boot (F-246).
  A start in ticks is turned into the `ps` form here, as it is read (`Holder.Process.from_ticks/3`,
  one shell for every such file): it is the `ps` text when the pid's stat file holds those ticks
  before and after the `ps`. Otherwise the row has no start, and its `alive` says why
  (`:replaced`, `:gone` or `:unknown`). A file that is gone has its row deleted. A file that cannot be
  parsed (half written, not JSON, a required key missing or of the wrong type) is not dropped:
  its row keeps the last good data, if any, and names the problem in `problem`. A read whose
  shell fails writes nothing and answers `{:unknown, reason}`.

  After a write that changed an account's rows, or its first read, it calls `notify` with a cue
  per account that names the topic and the row ids, never the data:
  `%{topic: "registry:<host>:<account>", ids: ids}`. The cue is a plain function so the library
  needs no PubSub; an embedding app passes, for example,
  `&Phoenix.PubSub.broadcast(MyApp.PubSub, &1.topic, &1)`. It must not raise.
  """

  use GenServer

  alias CodingAgentFramework.{Holder, Programs, Reader, Shell, Store}
  alias CodingAgentFramework.Registry.{SessionFile, Table}

  @timeout 10_000
  @account "\0caf-account\0"
  @mark "\0caf-file\0"
  # Per account, a marker, then one listing and every file's bytes, each after a marker no JSON
  # text holds (a raw NUL). `$1` is the host's cat, by its path from `Programs`, so nothing is
  # looked up through PATH; the rest are the accounts' config directories, in order.
  @read ~S"""
  c="$1"; shift
  for a in "$@"; do
    printf '\0caf-account\0'
    d="$a/sessions"
    if [ ! -d "$d" ]; then printf 'nodir'; continue; fi
    printf 'dir'
    for f in "$d"/*.json; do
      [ -f "$f" ] || continue
      printf '\0caf-file\0%s\0' "${f##*/}"
      "$c" -- "$f" 2>/dev/null || printf '\0caf-unreadable'
    done
  done
  """

  @doc """
  Starts a `Registry`. Options: `programs:` (the host's `Programs`, naming its sh, env, ps and
  cat), `accounts:` (each account's name to its config directory on the host), `db:` (this
  instance's SQLite path), and optionally `notify:` (a function of one cue), `timeout:` (ms per
  shell run, default 10 s), `interval:` (ms between reads; without it, reads happen only on
  `read/2`) and `proc:` (the directory read for a start in clock ticks, default `"/proc"`; a
  test names one of its own). It fails to start with `{:no_program, names}` when a program is missing.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The topics of the cues it writes, each as its whole shape, `*` for a word it fills in
  (`CodingAgentFramework.Cues`): `registry:<host>:<account>`.
  """
  @spec writes() :: [String.t()]
  def writes, do: ~w(registry:*:*)

  @doc """
  Reads every account's session files now. Returns `{:ok, %{files: n, problems: n, ids: ids}}`,
  where `ids` are the rows written, or `{:unknown, reason}` when the shell failed.
  """
  @spec read(GenServer.server(), keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def read(registry, opts \\ []), do: call(registry, :read, opts)

  @doc "An account's rows as `Table.rows/3` gives them: `:unread` before its first read."
  @spec rows(GenServer.server(), String.t(), keyword) ::
          :unread | {:ok, map} | {:refused, term} | {:unknown, term}
  def rows(registry, account, opts \\ []), do: call(registry, {:rows, account}, opts)

  @doc """
  The Claude Code processes that may run by the session files of config directories `dirs`, read
  once as a read of a `Registry` reads them, with `programs`' sh, cat, env and ps, and nothing
  written (F-177): for a caller that holds no `Registry` of those directories, such as
  `bin/caf-import`. Each pid is checked by its start time (`Holder.Process.liveness/3`), never by
  its name. Answers `{:ok, %{live: pids, unknown: pids}}`: `unknown` holds a pid `ps` lists
  whose start time is not known, its file half written or naming none, or every pid when `ps`
  failed, so a caller that must be sure counts it as running. Or `{:unknown, reason}` when the
  read failed, and `{:refused, {:no_program, names}}`. Options `timeout:` (ms, default 10 s) and
  `proc:` (as `start_link/1` takes it).
  """
  @spec running(Programs.t(), [Path.t()], keyword) ::
          {:ok, %{live: [pos_integer], unknown: [pos_integer]}}
          | {:refused, term}
          | {:unknown, term}
  def running(%Programs{host: host} = programs, dirs, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    with {:ok, paths} <- Programs.take(programs, [:sh, :env, :ps, :cat]),
         {:ok, by_dir} <- read_files(host, paths, dirs, timeout) do
      procs = for files <- by_dir, {file, bytes} <- files, uniq: true, do: proc(file, bytes)
      procs = Enum.reject(procs, &is_nil(elem(&1, 0)))
      reader = %{host: host, programs: paths, timeout: timeout, proc: proc_dir(opts)}
      alive = Map.new(judged(reader, procs), fn {proc, {alive, _start}} -> {proc, alive} end)
      pids = fn want -> for({{pid, _}, ^want} <- alive, uniq: true, do: pid) |> Enum.sort() end
      {:ok, %{live: pids.(:live), unknown: pids.(:unknown) -- pids.(:live)}}
    end
  end

  # A file that cannot be parsed still names its process: `<pid>.json`, with no start time.
  defp proc(file, bytes) do
    case parse(bytes, nil) do
      {%{pid: pid, proc_start: start}, _problem} when is_integer(pid) -> {pid, start}
      _ -> {file_pid(file), nil}
    end
  end

  defp file_pid(file) do
    case Integer.parse(Path.rootname(file)) do
      {pid, ""} when pid > 0 -> pid
      _ -> nil
    end
  end

  defp proc_dir(opts), do: Keyword.get(opts, :proc, "/proc")

  # Each `{pid, start}` as a file gives it, to whether that process runs and its start in the
  # `ps` form, or nil: a start in ticks by its stat file and `ps`, any other by one `ps`.
  defp judged(_reader, []), do: %{}

  defp judged(reader, procs) do
    {ticks, rest} = Enum.split_with(procs, fn {_, start} -> Holder.Process.ticks?(start) end)
    rest = Enum.map(rest, fn {pid, start} -> {{pid, start}, normal(start)} end)
    opts = Map.to_list(reader.programs) ++ [timeout: reader.timeout, proc: reader.proc]

    checked = for {{pid, _}, start} <- rest, do: {pid, start}
    alive = Holder.Process.liveness(reader.host, checked, opts)
    by_ps = Map.new(rest, fn {{pid, _} = proc, start} -> {proc, {alive[{pid, start}], start}} end)

    by_ticks =
      reader.host
      |> Holder.Process.from_ticks(ticks, opts)
      |> Map.new(fn
        {proc, {:live, start}} -> {proc, {:live, start}}
        {proc, other} -> {proc, {other, nil}}
      end)

    Map.merge(by_ps, by_ticks)
  end

  defp normal(nil), do: nil
  defp normal(start), do: Holder.Process.normal(start)

  defp call(registry, request, opts),
    do: Reader.call(registry, request, Keyword.get(opts, :timeout, 2 * @timeout), :no_registry)

  @impl true
  def init(opts) do
    %Programs{host: host} = programs = Keyword.fetch!(opts, :programs)
    accounts = opts |> Keyword.fetch!(:accounts) |> Enum.sort()

    with {:ok, paths} <- Programs.take(programs, [:sh, :env, :ps, :cat]),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      cache =
        for {account, _} <- accounts,
            {:ok, %{rows: rows}} <- [Table.rows(db, host.name, account)],
            into: %{},
            do: {account, Map.new(rows, &{&1.file, Map.take(&1, Table.data_columns())})}

      state = %{
        host: host,
        accounts: accounts,
        db: db,
        cache: cache,
        programs: paths,
        timeout: Keyword.get(opts, :timeout, @timeout),
        proc: proc_dir(opts)
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

  def handle_call({:rows, account}, _from, state),
    do: {:reply, Table.rows(state.db, state.host.name, account), state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, Reader.tick(state, &read_now/1)}

  defp read_now(state) do
    {names, dirs} = Enum.unzip(state.accounts)

    case read_files(state.host, state.programs, dirs, state.timeout) do
      {:ok, by_dir} -> write(state, names |> Enum.zip(by_dir) |> Map.new())
      other -> {other, state}
    end
  end

  # Each directory's session files, by file name, in one shell command, in the order given.
  defp read_files(host, programs, dirs, timeout) do
    args = ["-c", @read, "sh", programs.cat | dirs]

    case Shell.run(host, programs.sh, args, timeout: timeout) do
      {:ok, %{status: 0, output: out}} ->
        parts = out |> :binary.split(@account, [:global]) |> tl()

        if length(parts) == length(dirs),
          do: {:ok, Enum.map(parts, &files/1)},
          else: {:unknown, {:sh, 0, out}}

      {:ok, %{status: status, output: out}} ->
        {:unknown, {:sh, status, out}}

      other ->
        other
    end
  end

  defp files("nodir"), do: %{}

  defp files("dir" <> rest) do
    for chunk <- :binary.split(rest, @mark, [:global]), chunk != "", into: %{} do
      case :binary.split(chunk, "\0") do
        [name, bytes] -> {name, bytes}
        [name] -> {name, ""}
      end
    end
  end

  defp write(state, by_account) do
    parsed =
      Map.new(by_account, fn {account, files} ->
        cached = Map.get(state.cache, account, %{})
        {account, Map.new(files, fn {file, bytes} -> {file, parse(bytes, cached[file])} end)}
      end)

    procs =
      for {_, files} <- parsed,
          {_, {row, _}} <- files,
          is_integer(row.pid),
          uniq: true,
          do: {row.pid, row.proc_start}

    judged = judged(state, procs)

    rows =
      Map.new(parsed, fn {account, files} ->
        {account,
         Map.new(files, fn {file, {row, problem}} ->
           {live, start} = Map.get(judged, {row.pid, row.proc_start}, {:unknown, nil})
           {file, Map.merge(row, %{problem: problem, alive: live, proc_start: start})}
         end)}
      end)

    at = System.os_time(:millisecond)

    writes =
      for {account, files} <- rows do
        problems = Enum.count(files, fn {_, row} -> row.problem end)
        read = [read_at: at, files: map_size(files), problems: problems]
        changes = Reader.diff(Map.get(state.cache, account, %{}), files)
        {[host: state.host.name, account: account], changes, read}
      end

    results = Reader.write(Table.meta(), state.db, writes)

    for %{scope: [host: host, account: account]} = result <- results,
        do: Reader.cue(state.notify, "registry:#{host}:#{account}", result)

    all = rows |> Map.values() |> Enum.flat_map(&Map.values/1)
    summary = %{files: length(all), problems: Enum.count(all, & &1.problem)}
    {{:ok, Map.put(summary, :ids, Enum.flat_map(results, & &1.ids))}, %{state | cache: rows}}
  end

  # A row's data and its problem as text; a file that cannot be parsed keeps its last good data.
  defp parse(bytes, cached) do
    {bytes, unreadable} =
      case :binary.split(bytes, "\0caf-unreadable") do
        [bytes, _] -> {bytes, true}
        [bytes] -> {bytes, false}
      end

    case {unreadable, SessionFile.parse(bytes)} do
      {true, _} -> {last_good(cached), Store.text(:unreadable)}
      {false, {:ok, row}} -> {Map.drop(row, [:problems]), problems(row.problems)}
      {false, {:malformed, reason}} -> {last_good(cached), Store.text(reason)}
    end
  end

  defp problems([]), do: nil
  defp problems(list), do: Store.text(list)

  defp last_good(nil), do: SessionFile.fields() |> Map.new(&{&1, nil}) |> Map.put(:extra, %{})
  defp last_good(row), do: Map.drop(row, [:problem, :alive])
end
