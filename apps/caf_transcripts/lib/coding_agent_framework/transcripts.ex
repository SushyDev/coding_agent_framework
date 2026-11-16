defmodule CodingAgentFramework.Transcripts do
  @moduledoc """
  Reads the transcripts of one account's sessions on one host, each from where the last read
  stopped, and writes what it folds to `CodingAgentFramework.Transcripts.Table`, which it alone
  writes. The caller's supervision tree starts one per `{host, account}`, with no name.

  A transcript is `<config>/projects/<project>/<session id>.jsonl` (see `path/3`); a hook's
  `transcript_path` names it too. Each read runs the host's `tail -c +<byte>` (with `head -c` when
  it takes a bounded part) through
  `CodingAgentFramework.Shell`, so a host over ssh is read the same way and a restart never reads
  a whole log again: the offset is in the table. What a read answers per session is in
  `CodingAgentFramework.Transcripts.Fold`.

      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> file = Path.join(dir, "s1.jsonl")
      iex> File.write!(file, ~s({"type":"user","promptId":"p1","message":{"content":"go"}}\\n))
      iex> me = self()
      iex> host = CodingAgentFramework.TestHost.host()
      iex> {:ok, t} = CodingAgentFramework.Transcripts.start_link(
      ...>   programs: CodingAgentFramework.TestHost.programs(host), account: "work",
      ...>   db: Path.join(dir, "t.db"), notify: &send(me, &1))
      iex> {:ok, %{ids: [id], failed: []}} = CodingAgentFramework.Transcripts.read(t, [{"s1", file}])
      iex> receive do: (cue -> cue)
      %{topic: "transcripts:test:work", ids: [id]}
      iex> {:ok, row} = CodingAgentFramework.Transcripts.session(t, "s1")
      iex> {row.offset, hd(row.prompts).prompt_id}
      {59, "p1"}

  A read whose shell fails leaves that session as it was and names it in `failed`. A file
  that shrank or was replaced is folded again from its start, and its row says `rewritten` and
  counts it in `rewrites`. After a write that changed rows, or the first read, `notify` gets a
  cue with the topic and the row ids, never the data, as `Registry`'s does.
  """

  use GenServer

  alias CodingAgentFramework.{Programs, Shell}
  alias CodingAgentFramework.Transcripts.{Fold, Table}

  @timeout 10_000
  # `$2` is the host's tail, by its path from `Programs`; `-c +N` prints from byte N (POSIX).
  # With a bound (`$4`, bytes, and `$5`, the host's head) only that many bytes are read; a pipe
  # hides the tail's own status, so a file that cannot be read is refused before it; the tail's
  # broken-pipe complaint, once head has its bytes, goes to /dev/null, not into the text.
  @read ~S"""
  [ -f "$1" ] || { printf 'nofile'; exit 0; }
  [ -r "$1" ] || exit 1
  printf 'file'
  if [ -n "$4" ]; then "$2" -c "+$3" "$1" 2>/dev/null | "$5" -c "$4"; else exec "$2" -c "+$3" "$1"; fi
  """

  @doc """
  Starts a `Transcripts`. Options: `programs:` (the host's, naming sh, tail and head), `account:`,
  `db:` (this instance's SQLite path), and optionally `notify:` (a function of one cue) and
  `timeout:` (ms per shell run, default 10 s). It fails to start with `{:no_program, names}`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The transcript's path for a session started in `cwd`: every character other than a letter or
  digit becomes `-`. Claude Code shortens a name over 200 characters and adds a hash this does
  not compute, so such a `cwd` is refused; the hook's `transcript_path` names that file.

      iex> CodingAgentFramework.Transcripts.path("/h/accounts/a/claude", "/src/my_app", "s1")
      {:ok, "/h/accounts/a/claude/projects/-src-my-app/s1.jsonl"}
  """
  @spec path(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:refused, term}
  def path(config_dir, cwd, session_id) do
    case String.replace(cwd, ~r/[^a-zA-Z0-9]/, "-") do
      key when byte_size(key) <= 200 ->
        {:ok, Path.join([config_dir, "projects", key, session_id <> ".jsonl"])}

      _ ->
        {:refused, :long_cwd}
    end
  end

  @doc """
  Reads these `{session_id, path}` transcripts now, or every session read before with
  `:known`. Answers `{:ok, %{ids: ids, failed: [{session_id, reason}]}}`.
  """
  @spec read(GenServer.server(), [{String.t(), String.t()}] | :known, keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def read(transcripts, sessions \\ :known, opts \\ []),
    do: call(transcripts, {:read, sessions}, opts)

  @doc "Every row as `Table.rows/3` gives them: `:unread` before the first read."
  @spec rows(GenServer.server(), keyword) ::
          :unread | {:ok, map} | {:refused, term} | {:unknown, term}
  def rows(transcripts, opts \\ []), do: call(transcripts, :rows, opts)

  @doc "One session's row, `{:refused, :unknown_session}` for one never read."
  @spec session(GenServer.server(), String.t(), keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def session(transcripts, session_id, opts \\ []),
    do: call(transcripts, {:session, session_id}, opts)

  @doc """
  Whether a prompt holding both `mark` and `text` appears in the session's transcript after
  byte `offset`: how a report marked "sending" is settled from the parent's transcript. It reads
  the file through `Shell` and changes no row. Answers `{:ok, boolean}`.
  """
  @spec contains(GenServer.server(), String.t(), String.t(), String.t(), non_neg_integer, keyword) ::
          {:ok, boolean} | {:refused, term} | {:unknown, term}
  def contains(transcripts, session_id, mark, text, offset, opts \\ []),
    do: call(transcripts, {:contains, session_id, mark, text, offset}, opts)

  @doc """
  The session's transcript from byte `from`, as it is now: `{:ok, %{bytes: bytes, from: from}}`.
  With `{:last, n}` in place of `from`, from `n` bytes before the offset read so far. It changes
  no row; `{:refused, :unknown_session}` for one never read, `{:refused, :no_file}`. Option
  `:max` (bytes): the host reads at most that many, so a long transcript does not move whole;
  without it the read runs to the end.

      Transcripts.text(transcripts, "s1", 0)
      #=> {:ok, %{bytes: "{\\"type\\":\\"user\\",…}\\n", from: 0}}
  """
  @spec text(GenServer.server(), String.t(), non_neg_integer | {:last, pos_integer}, keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def text(transcripts, session_id, from, opts \\ []),
    do: call(transcripts, {:text, session_id, from, Keyword.get(opts, :max)}, opts)

  defp call(transcripts, request, opts) do
    timeout = Keyword.get(opts, :timeout, 6 * @timeout)

    try do
      GenServer.call(transcripts, request, timeout)
    catch
      :exit, {:noproc, _} -> {:refused, :no_transcripts}
      :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
      :exit, {reason, _} -> {:unknown, {:exit, reason}}
    end
  end

  @impl true
  def init(opts) do
    %Programs{host: host} = programs = Keyword.fetch!(opts, :programs)
    account = Keyword.fetch!(opts, :account)

    with {:ok, paths} <- Programs.take(programs, [:sh, :tail, :head]),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      folds = Table.folds(db, host.name, account)

      {:ok,
       %{
         host: host,
         account: account,
         db: db,
         folds: folds,
         notify: Keyword.get(opts, :notify, fn _ -> :ok end),
         programs: paths,
         timeout: Keyword.get(opts, :timeout, @timeout)
       }}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:read, :known}, from, state),
    do: handle_call({:read, Enum.map(state.folds, fn {sid, s} -> {sid, s.path} end)}, from, state)

  def handle_call({:read, sessions}, _from, state) do
    {puts, failed, folds} =
      Enum.reduce(sessions, {[], [], state.folds}, fn {sid, path}, {puts, failed, folds} ->
        before = Map.get(folds, sid, %{path: path, fold: Fold.new(), rewrites: 0, problem: nil})

        case read_one(state, %{before | path: path}) do
          {:ok, ^before} ->
            {puts, failed, folds}

          {:ok, s} ->
            {[{sid, s.path, s.fold, s.rewrites, s.problem} | puts], failed,
             Map.put(folds, sid, s)}

          {_, reason} ->
            {puts, [{sid, reason} | failed], folds}
        end
      end)

    {:ok, %{ids: ids, first: first}} =
      Table.write(
        state.db,
        state.host.name,
        state.account,
        Enum.reverse(puts),
        System.os_time(:millisecond)
      )

    if ids != [] or first,
      do: state.notify.(%{topic: "transcripts:#{state.host.name}:#{state.account}", ids: ids})

    {:reply, {:ok, %{ids: ids, failed: Enum.reverse(failed)}}, %{state | folds: folds}}
  end

  def handle_call(:rows, _from, state),
    do: {:reply, Table.rows(state.db, state.host.name, state.account), state}

  def handle_call({:session, sid}, _from, state) do
    reply =
      with {:ok, %{rows: rows}} <- Table.rows(state.db, state.host.name, state.account),
           %{} = row <- Enum.find(rows, &(&1.session_id == sid)) do
        {:ok, row}
      else
        _ -> {:refused, :unknown_session}
      end

    {:reply, reply, state}
  end

  def handle_call({:contains, sid, mark, text, offset}, _from, state) do
    reply =
      case state.folds[sid] do
        nil ->
          {:refused, :unknown_session}

        %{path: path} ->
          case tail(state, path, offset) do
            {:ok, bytes} -> {:ok, Fold.contains?(bytes, mark, text)}
            :no_file -> {:ok, false}
            other -> other
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:text, sid, from, max}, _from, state) do
    reply =
      with %{path: path, fold: fold} <- state.folds[sid] || {:refused, :unknown_session},
           at = with({:last, n} <- from, do: max(fold.offset - n, 0)),
           {:ok, bytes} <- tail(state, path, at, max) do
        {:ok, %{bytes: bytes, from: at}}
      else
        :no_file -> {:refused, :no_file}
        other -> other
      end

    {:reply, reply, state}
  end

  defp read_one(state, s) do
    case tail(state, s.path, Fold.read_from(s.fold)) do
      {:ok, bytes} ->
        case Fold.take(s.fold, bytes) do
          {:ok, fold} -> {:ok, %{s | fold: fold, problem: nil}}
          :rewritten -> again(state, s)
        end

      :no_file when s.fold.offset == 0 ->
        {:ok, %{s | problem: "no_file"}}

      :no_file ->
        {:ok, %{s | fold: Fold.new(), rewrites: s.rewrites + 1, problem: "no_file"}}

      other ->
        other
    end
  end

  defp again(state, s) do
    with {:ok, bytes} <- tail(state, s.path, 0),
         {:ok, fold} <- Fold.take(Fold.new(), bytes) do
      {:ok, %{s | fold: fold, rewrites: s.rewrites + 1, problem: "rewritten"}}
    else
      :no_file -> {:ok, %{s | fold: Fold.new(), rewrites: s.rewrites + 1, problem: "no_file"}}
      other -> other
    end
  end

  # `max` nil reads to the end: a fold must see every new event, and `contains` every prompt.
  defp tail(state, path, from, max \\ nil) do
    args = [
      "-c",
      @read,
      "sh",
      path,
      state.programs.tail,
      Integer.to_string(from + 1),
      if(max, do: Integer.to_string(max), else: ""),
      state.programs.head
    ]

    case Shell.run(state.host, state.programs.sh, args, timeout: state.timeout) do
      {:ok, %{status: 0, output: "nofile"}} ->
        :no_file

      {:ok, %{status: 0, output: "file" <> bytes}} ->
        {:ok, bytes}

      {:ok, %{status: status, output: out}} ->
        {:unknown, {:sh, status, String.slice(out, 0, 200)}}

      other ->
        other
    end
  end
end
