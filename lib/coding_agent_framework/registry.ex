defmodule CodingAgentFramework.Registry do
  @moduledoc """
  Reads Claude Code's `<config>/sessions/*.json` for one account on one host, and writes what
  it reads to `CodingAgentFramework.Registry.Table`, which it alone writes.

  The caller's supervision tree starts one `Registry` per `{host, account}`, with no name. The
  files are read through `CodingAgentFramework.Shell`, so a host over ssh is read the same way.
  A held agent's pid comes from here: dtach does not report it.

      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> File.mkdir_p!(Path.join(dir, "sessions"))
      iex> File.write!(Path.join(dir, "sessions/7.json"), ~s({"pid": 7, "sessionId": "s7"}))
      iex> me = self()
      iex> host = CodingAgentFramework.Host.local("laptop", CodingAgentFramework.TestHost.program!(:kill))
      iex> {:ok, reg} = CodingAgentFramework.Registry.start_link(
      ...>   programs: CodingAgentFramework.TestHost.programs(host), account: "work",
      ...>   config_dir: dir, db: Path.join(dir, "registry.db"), notify: &send(me, &1))
      iex> CodingAgentFramework.Registry.rows(reg)
      :unread
      iex> {:ok, %{files: 1, problems: 0, ids: [id]}} = CodingAgentFramework.Registry.read(reg)
      iex> receive do: (cue -> cue)
      %{topic: "registry:laptop:work", ids: [id]}

  Each read lists every file and reads it in one shell command, checks every pid with one `ps`
  (`CodingAgentFramework.Registry.Liveness`), and writes only the rows that changed, in one
  transaction. A file that is gone has its row deleted. A file that cannot be parsed (half
  written, not JSON, a required key missing or of the wrong type) is not dropped: its row keeps
  the last good data, if any, and names the problem in `problem`. A read whose shell fails
  writes nothing and answers `{:unknown, reason}`.

  After a write that changed rows, or the first read, it calls `notify` with a cue that names
  the topic and the row ids, never the data: `%{topic: "registry:<host>:<account>", ids: ids}`.
  The cue is a plain function so the library needs no PubSub; a host app passes, for example,
  `&Phoenix.PubSub.broadcast(MyApp.PubSub, &1.topic, &1)`. It must not raise.
  """

  use GenServer

  alias CodingAgentFramework.{Programs, Shell}
  alias CodingAgentFramework.Registry.{Liveness, SessionFile, Table}

  @timeout 10_000
  @mark "\0caf-file\0"
  # One listing and every file's bytes, each after a marker no JSON text holds (a raw NUL).
  @read ~S"""
  d="$1/sessions"
  if [ ! -d "$d" ]; then printf 'nodir'; exit 0; fi
  printf 'dir'
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    printf '\0caf-file\0%s\0' "${f##*/}"
    cat -- "$f" 2>/dev/null || printf '\0caf-unreadable'
  done
  """

  @doc """
  Starts a `Registry`. Options: `programs:` (the host's `Programs`, naming its sh, env and ps),
  `account:` (its name), `config_dir:` (the account's config directory on the host), `db:`
  (this instance's SQLite path), and optionally `notify:` (a function of one cue), `timeout:`
  (ms per shell run, default 10 s) and `interval:` (ms between reads; without it, reads happen
  only on `read/2`). It fails to start with `{:no_program, names}` when a program is missing.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Reads the account's session files now. Returns `{:ok, %{files: n, problems: n, ids: ids}}`,
  where `ids` are the rows written, or `{:unknown, reason}` when the shell failed.
  """
  @spec read(GenServer.server(), keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def read(registry, opts \\ []), do: call(registry, :read, opts)

  @doc "The rows as `Table.rows/3` gives them: `:unread` before the first read."
  @spec rows(GenServer.server(), keyword) ::
          :unread | {:ok, map} | {:refused, term} | {:unknown, term}
  def rows(registry, opts \\ []), do: call(registry, :rows, opts)

  defp call(registry, request, opts) do
    timeout = Keyword.get(opts, :timeout, 2 * @timeout)

    try do
      GenServer.call(registry, request, timeout)
    catch
      :exit, {:noproc, _} -> {:refused, :no_registry}
      :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
      :exit, {reason, _} -> {:unknown, {:exit, reason}}
    end
  end

  @impl true
  def init(opts) do
    %Programs{host: host} = programs = Keyword.fetch!(opts, :programs)
    account = Keyword.fetch!(opts, :account)

    with {:ok, paths} <- Programs.take(programs, [:sh, :env, :ps]),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      cache =
        case Table.rows(db, host.name, account) do
          :unread -> %{}
          {:ok, %{rows: rows}} -> Map.new(rows, &{&1.file, Map.take(&1, Table.data_columns())})
        end

      state = %{
        host: host,
        account: account,
        dir: Keyword.fetch!(opts, :config_dir),
        db: db,
        cache: cache,
        notify: Keyword.get(opts, :notify, fn _ -> :ok end),
        programs: paths,
        timeout: Keyword.get(opts, :timeout, @timeout),
        interval: Keyword.get(opts, :interval)
      }

      if state.interval, do: send(self(), :tick)
      {:ok, state}
    else
      {:refused, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:read, _from, state) do
    {reply, state} = read_now(state)
    {:reply, reply, state}
  end

  def handle_call(:rows, _from, state),
    do: {:reply, Table.rows(state.db, state.host.name, state.account), state}

  @impl true
  def handle_info(:tick, state) do
    {_, state} = read_now(state)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  defp read_now(state) do
    case Shell.run(state.host, state.programs.sh, ["-c", @read, "sh", state.dir],
           timeout: state.timeout
         ) do
      {:ok, %{status: 0, output: "nodir"}} -> write(state, %{})
      {:ok, %{status: 0, output: "dir" <> rest}} -> write(state, files(rest))
      {:ok, %{status: status, output: out}} -> {{:unknown, {:sh, status, out}}, state}
      other -> {other, state}
    end
  end

  defp files(rest) do
    for chunk <- :binary.split(rest, @mark, [:global]), chunk != "", into: %{} do
      case :binary.split(chunk, "\0") do
        [name, bytes] -> {name, bytes}
        [name] -> {name, ""}
      end
    end
  end

  defp write(state, files) do
    parsed = Map.new(files, fn {file, bytes} -> {file, parse(bytes, state.cache[file])} end)

    procs =
      for {_, {row, _}} <- parsed, is_integer(row.pid), uniq: true, do: {row.pid, row.proc_start}

    alive =
      Liveness.check(state.host, procs, Map.to_list(state.programs) ++ [timeout: state.timeout])

    rows =
      Map.new(parsed, fn {file, {row, problem}} ->
        {file,
         Map.merge(row, %{
           problem: problem,
           alive: Map.get(alive, {row.pid, row.proc_start}, :unknown)
         })}
      end)

    changes =
      for({file, row} <- rows, state.cache[file] != row, do: {:put, file, row}) ++
        for file <- Map.keys(state.cache), not Map.has_key?(rows, file), do: {:delete, file}

    summary = %{
      read_at: System.os_time(:millisecond),
      files: map_size(rows),
      problems: Enum.count(rows, fn {_, row} -> row.problem end)
    }

    {:ok, %{ids: ids, first: first}} =
      Table.write(state.db, state.host.name, state.account, changes, summary)

    if ids != [] or first,
      do: state.notify.(%{topic: "registry:#{state.host.name}:#{state.account}", ids: ids})

    {{:ok, %{files: summary.files, problems: summary.problems, ids: ids}}, %{state | cache: rows}}
  end

  # A row's data and its problem as text; a file that cannot be parsed keeps its last good data.
  defp parse(bytes, cached) do
    {bytes, unreadable} =
      case :binary.split(bytes, "\0caf-unreadable") do
        [bytes, _] -> {bytes, true}
        [bytes] -> {bytes, false}
      end

    case {unreadable, SessionFile.parse(bytes)} do
      {true, _} -> {last_good(cached), inspect(:unreadable)}
      {false, {:ok, row}} -> {Map.drop(row, [:problems]), problems(row.problems)}
      {false, {:malformed, reason}} -> {last_good(cached), inspect(reason)}
    end
  end

  defp problems([]), do: nil
  defp problems(list), do: inspect(list)

  defp last_good(nil), do: SessionFile.fields() |> Map.new(&{&1, nil}) |> Map.put(:extra, %{})
  defp last_good(row), do: Map.drop(row, [:problem, :alive])
end
