defmodule CodingAgentFramework.Transcripts do
  @moduledoc """
  Reads the transcripts of the sessions on one host, of every account the framework holds, each
  from where the last read stopped, and writes what it folds to
  `CodingAgentFramework.Transcripts.Table`, which it alone writes. A reader on
  `CodingAgentFramework.Reader`. The caller's supervision tree starts one per host, with no
  name, so a session is found whichever account it runs in.

  A transcript is `<config>/projects/<project>/<session id>.jsonl` (see `path/3`); a hook's
  `transcript_path` names it too. Each read runs the host's `tail -c +<byte>` (with `head -c` when
  it takes a bounded part) through
  `CodingAgentFramework.Shell`, so a host over ssh is read the same way and a restart never reads
  a whole log again: the offset is in the table. A session with no stored fold is read the first
  time from at most its last `first_read:` bytes, from a whole line, and its fold says
  `partial: true` (F-244): a long-running session is not folded from its first byte. What a read answers per session is in
  `CodingAgentFramework.Transcripts.Fold`.

      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> file = Path.join(dir, "s1.jsonl")
      iex> File.write!(file, ~s({"type":"user","promptId":"p1","message":{"content":"go"}}\\n))
      iex> me = self()
      iex> host = CodingAgentFramework.TestHost.host()
      iex> {:ok, t} = CodingAgentFramework.Transcripts.start_link(
      ...>   programs: CodingAgentFramework.TestHost.programs(host), accounts: ["work"],
      ...>   db: Path.join(dir, "t.db"), notify: &send(me, &1))
      iex> {:ok, %{ids: [id], failed: []}} =
      ...>   CodingAgentFramework.Transcripts.read(t, [{"work", "s1", file}])
      iex> receive do: (cue -> cue)
      %{topic: "transcripts:test:work", ids: [id]}
      iex> {:ok, row} = CodingAgentFramework.Transcripts.session(t, "work", "s1")
      iex> {row.offset, hd(row.prompts).prompt_id}
      {59, "p1"}

  **A subagent's own file** (F-237): Claude Code 2.1.322 writes each subagent's entries to
  `<session id>/subagents/agent-<agent id>.jsonl` beside the transcript, and its
  `agent-<agent id>.meta.json` with the parent's `Agent` call's id, both when it starts. Each
  read lists that directory (one `wc -c` over its files), reads each file that changed from its
  own stored offset, and folds it into the session's fold (`Fold.take_file/3`), so its calls are
  in `agent_tools` under its agent id; a new file's meta gives the subagent's `agent_id` while
  it runs. A file never read whose meta says `finished: true` is not read: its calls are absent
  and its entry says `not_read: :finished`. The first read of a running one takes at most its
  last `first_read:` bytes, from a whole line, and its entry says `partial: true`. A file that disappears keeps what was read of it, and its `files` entry says
  `no_file`; a line of it the fold cannot read is a problem naming the file.

  A read whose shell fails leaves that session as it was and names it in `failed`. A file
  that shrank or was replaced is folded again from its start, and its row says `rewritten` and
  counts it in `rewrites`. After a write that changed an account's rows, or its first read,
  `notify` gets a cue with the account's topic and the row ids, never the data, as `Registry`'s
  does: `%{topic: "transcripts:<host>:<account>", ids: ids}`.
  """

  use GenServer

  alias CodingAgentFramework.{Programs, Reader, Shell}
  alias CodingAgentFramework.Transcripts.{Fold, Table}

  @timeout 10_000
  @first_read 1_048_576
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
  # A main file's first read: its size from the host's wc (`$3`), then from one byte before its
  # last `$4` bytes, so a line that starts at the bound is kept whole, to its end; the byte it
  # starts at is printed first. A file that grows between the two runs only gives more bytes.
  @last ~S"""
  [ -f "$1" ] || { printf 'nofile'; exit 0; }
  [ -r "$1" ] || exit 1
  s=$("$3" -c < "$1") || exit 1
  f=$(($s > $4 ? $s - $4 - 1 : 0))
  printf 'file%s\n' "$f"
  exec "$2" -c "+$((f + 1))" "$1"
  """
  # `$1` is a session's `subagents/` directory, `$2` the host's wc. Each subagent's file with its
  # size, in one run however many there are. A file removed between the glob and wc is left out
  # (its complaint goes to /dev/null), so the reader sees it gone, as on its next read.
  @list ~S"""
  d="$1"; w="$2"
  set -- "$d"/agent-*.jsonl
  [ -f "$1" ] || { printf 'none'; exit 0; }
  printf 'list\n'
  "$w" -c -- "$@" 2>/dev/null
  exit 0
  """

  @doc """
  Starts a `Transcripts`. Options: `programs:` (the host's, naming sh, tail, head and wc),
  `accounts:` (the names of the accounts it reads), `db:` (this instance's SQLite path), and
  optionally `notify:` (a function of one cue), `timeout:` (ms per shell run, default 10 s),
  `first_read:` (the bytes the first read of a main transcript or a subagent's file takes at
  most, from its end; default 1 MB) and `interval:` (ms between reads of every known session; without it, reads happen
  only on `read/3`). It fails to start with `{:no_program, names}`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The topics of the cues it writes, each as its whole shape, `*` for a word it fills in
  (`CodingAgentFramework.Cues`): `transcripts:<host>:<account>`.
  """
  @spec writes() :: [String.t()]
  def writes, do: ~w(transcripts:*:*)

  @doc """
  The transcript's path for a session started in `cwd`: every character other than a letter or
  digit becomes `-`. Claude Code shortens a name over 200 characters and adds a hash this does
  not compute, so such a `cwd` is refused; the hook's `transcript_path` names that file.

      iex> CodingAgentFramework.Transcripts.path("/h/accounts/a/claude", "/src/my_app", "s1")
      {:ok, "/h/accounts/a/claude/projects/-src-my-app/s1.jsonl"}
  """
  @spec path(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:refused, term}
  def path(config_dir, cwd, session_id) do
    with {:ok, dir} <- project_dir(config_dir, cwd),
         do: {:ok, Path.join(dir, session_id <> ".jsonl")}
  end

  @doc """
  The directory Claude Code keeps a working directory's sessions in, for an account's config
  directory: `<config>/projects/<cwd, each character other than a letter or a digit as ->`.
  Its `memory/` is that directory's agent memory (F-155). `{:refused, :long_cwd}` past 200
  characters, where Claude Code shortens the name in a way not read here.

      iex> CodingAgentFramework.Transcripts.project_dir("/caf/accounts/a/claude", "/caf/checkouts/demo")
      {:ok, "/caf/accounts/a/claude/projects/-caf-checkouts-demo"}
  """
  @spec project_dir(Path.t(), Path.t()) :: {:ok, Path.t()} | {:refused, :long_cwd}
  def project_dir(config_dir, cwd) do
    case String.replace(cwd, ~r/[^a-zA-Z0-9]/, "-") do
      key when byte_size(key) <= 200 -> {:ok, Path.join([config_dir, "projects", key])}
      _ -> {:refused, :long_cwd}
    end
  end

  @doc """
  Reads these `{account, session_id, path}` transcripts now, or every session read before with
  `:known`. Answers `{:ok, %{ids: ids, failed: [{account, session_id, reason}]}}`; a session id a
  move copied is in two accounts, so a failure names both. A read records a read
  of each account it names, and `:known` of every account.
  """
  @spec read(GenServer.server(), [{String.t(), String.t(), String.t()}] | :known, keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def read(transcripts, sessions \\ :known, opts \\ []),
    do: call(transcripts, {:read, sessions}, opts)

  @doc "An account's rows as `Table.rows/3` gives them: `:unread` before its first read."
  @spec rows(GenServer.server(), String.t(), keyword) ::
          :unread | {:ok, map} | {:refused, term} | {:unknown, term}
  def rows(transcripts, account, opts \\ []), do: call(transcripts, {:rows, account}, opts)

  @doc "One session's row, `{:refused, :unknown_session}` for one never read."
  @spec session(GenServer.server(), String.t(), String.t(), keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def session(transcripts, account, session_id, opts \\ []),
    do: call(transcripts, {:session, {account, session_id}}, opts)

  @doc """
  Whether a prompt holding both `mark` and `text` appears in the transcript of the session
  `{account, session_id}` after
  byte `offset`: how a report marked "sending" is settled from the parent's transcript. It reads
  the file through `Shell` and changes no row. Answers `{:ok, boolean}`.
  """
  @spec contains(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer,
          keyword
        ) :: {:ok, boolean} | {:refused, term} | {:unknown, term}
  def contains(transcripts, account, session_id, mark, text, offset, opts \\ []),
    do: call(transcripts, {:contains, {account, session_id}, mark, text, offset}, opts)

  @doc """
  The account's session's transcript from byte `from`, as it is now: `{:ok, %{bytes: bytes, from: from}}`.
  With `{:last, n}` in place of `from`, from `n` bytes before the offset read so far. It changes
  no row; `{:refused, :unknown_session}` for one never read, `{:refused, :no_file}`. Option
  `:max` (bytes): the host reads at most that many, so a long transcript does not move whole;
  without it the read runs to the end.

      Transcripts.text(transcripts, "work", "s1", 0)
      #=> {:ok, %{bytes: "{\\"type\\":\\"user\\",…}\\n", from: 0}}
  """
  @spec text(
          GenServer.server(),
          String.t(),
          String.t(),
          non_neg_integer | {:last, pos_integer},
          keyword
        ) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def text(transcripts, account, session_id, from, opts \\ []),
    do: call(transcripts, {:text, {account, session_id}, from, Keyword.get(opts, :max)}, opts)

  defp call(transcripts, request, opts),
    do:
      Reader.call(
        transcripts,
        request,
        Keyword.get(opts, :timeout, 6 * @timeout),
        :no_transcripts
      )

  @impl true
  def init(opts) do
    %Programs{host: host} = programs = Keyword.fetch!(opts, :programs)

    with {:ok, paths} <- Programs.take(programs, [:sh, :tail, :head, :wc]),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      state = %{
        host: host,
        accounts: opts |> Keyword.fetch!(:accounts) |> Enum.sort(),
        db: db,
        folds: Table.folds(db, host.name),
        programs: paths,
        timeout: Keyword.get(opts, :timeout, @timeout),
        first_read: Keyword.get(opts, :first_read, @first_read)
      }

      {:ok, Map.merge(state, Reader.loop(opts))}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:read, sessions}, _from, state) do
    {reply, state} = read_now(state, sessions)
    {:reply, reply, state}
  end

  def handle_call({:rows, account}, _from, state),
    do: {:reply, Table.rows(state.db, state.host.name, account), state}

  def handle_call({:session, {account, sid}}, _from, state) do
    reply =
      with {:ok, %{rows: rows}} <- Table.rows(state.db, state.host.name, account),
           %{} = row <- Enum.find(rows, &(&1.session_id == sid)) do
        {:ok, row}
      else
        _ -> {:refused, :unknown_session}
      end

    {:reply, reply, state}
  end

  def handle_call({:contains, key, mark, text, offset}, _from, state) do
    reply =
      case state.folds[key] do
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

  def handle_call({:text, key, from, max}, _from, state) do
    reply =
      with %{path: path, fold: fold} <- state.folds[key] || {:refused, :unknown_session},
           at = with({:last, n} <- from, do: max(fold.offset - n, 0)),
           {:ok, bytes} <- tail(state, path, at, max) do
        {:ok, %{bytes: bytes, from: at}}
      else
        :no_file -> {:refused, :no_file}
        other -> other
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, Reader.tick(state, &read_now(&1, :known))}

  # Reads each session, then writes, per account it read, the rows that changed and the read.
  defp read_now(state, :known) do
    sessions = for {{account, sid}, s} <- state.folds, do: {account, sid, s.path}
    read_now(state, sessions, state.accounts)
  end

  defp read_now(state, sessions),
    do: read_now(state, sessions, sessions |> Enum.map(&elem(&1, 0)) |> Enum.uniq())

  defp read_now(state, sessions, accounts) do
    {puts, failed, folds} =
      Enum.reduce(sessions, {%{}, [], state.folds}, fn {account, sid, path},
                                                       {puts, failed, folds} ->
        key = {account, sid}
        before = Map.get(folds, key, %{path: path, fold: Fold.new(), rewrites: 0, problem: nil})

        case read_one(state, %{before | path: path}) do
          {:ok, ^before} ->
            {puts, failed, folds}

          {:ok, s} ->
            {Map.update(puts, account, [{sid, s}], &[{sid, s} | &1]), failed,
             Map.put(folds, key, s)}

          {_, reason} ->
            {puts, [{account, sid, reason} | failed], folds}
        end
      end)

    writes =
      for account <- Enum.uniq(accounts ++ Map.keys(puts)),
          do: {account, puts |> Map.get(account, []) |> Enum.reverse()}

    results = Table.write(state.db, state.host.name, writes, System.os_time(:millisecond))

    for %{scope: [host: host, account: account]} = result <- results,
        do: Reader.cue(state.notify, "transcripts:#{host}:#{account}", result)

    ids = Enum.flat_map(results, & &1.ids)
    {{:ok, %{ids: ids, failed: Enum.reverse(failed)}}, %{state | folds: folds}}
  end

  defp read_one(state, s) do
    case main(state, s.path, s.fold) do
      {:ok, fold} ->
        subagent_files(state, %{s | fold: fold, problem: nil})

      :rewritten ->
        with {:ok, s} <- again(state, s), do: subagent_files(state, s)

      :no_file when s.fold.offset == 0 ->
        {:ok, %{s | problem: "no_file"}}

      :no_file ->
        {:ok, %{s | fold: Fold.new(), rewrites: s.rewrites + 1, problem: "no_file"}}

      other ->
        other
    end
  end

  # A fold that has read nothing, with no stored fold or after the file was rewritten or gone,
  # takes at most the file's last `first_read` bytes (F-244); one with an offset goes on from it.
  defp main(state, path, %{offset: 0}) do
    with {:ok, from, bytes} <- last(state, path), do: Fold.take_from(from, bytes)
  end

  defp main(state, path, fold) do
    with {:ok, bytes} <- tail(state, path, Fold.read_from(fold)), do: Fold.take(fold, bytes)
  end

  defp again(state, s) do
    case main(state, s.path, Fold.new()) do
      {:ok, fold} ->
        {:ok, %{s | fold: fold, rewrites: s.rewrites + 1, problem: "rewritten"}}

      :no_file ->
        {:ok, %{s | fold: Fold.new(), rewrites: s.rewrites + 1, problem: "no_file"}}

      other ->
        other
    end
  end

  defp subagent_files(_state, %{problem: "no_file"} = s), do: {:ok, s}

  defp subagent_files(state, s) do
    dir = Path.join(Path.rootname(s.path), "subagents")

    with {:ok, listed} <- list(state, dir),
         {:ok, fold} <- read_files(state, dir, s.fold, listed) do
      gone =
        for {agent, f} <- fold.files,
            f.problem != "no_file",
            not is_map_key(listed, agent),
            do: agent

      {:ok, %{s | fold: Enum.reduce(gone, fold, &Fold.file_problem(&2, &1, "no_file"))}}
    end
  end

  defp read_files(state, dir, fold, listed) do
    Enum.reduce_while(Enum.sort(listed), {:ok, fold}, fn {agent, size}, {:ok, fold} ->
      case read_file(state, dir, fold, agent, size) do
        {:ok, fold} -> {:cont, {:ok, fold}}
        other -> {:halt, other}
      end
    end)
  end

  # A new file's meta is read first, so a subagent that finished before the fold read its file
  # is not read; one marked so is looked at again only once it grows. A file whose size is its
  # offset has nothing new; a running one's meta is read again while it grows and names no
  # call yet, so a meta not yet whole is tried again.
  defp read_file(state, dir, fold, agent, size) do
    path = Path.join(dir, "agent-#{agent}.jsonl")
    meta = Path.join(dir, "agent-#{agent}.meta.json")

    case fold.files[agent] do
      %{not_read: :finished, size: ^size} ->
        {:ok, fold}

      known when known == nil or known.not_read == :finished ->
        with {:ok, fold} <- meta(state, meta, fold, agent),
             do: first(state, path, fold, agent, size)

      known ->
        with {:ok, fold} <- grow(state, path, fold, agent, size) do
          if size != known.offset and fold.files[agent].tool_use_id == nil,
            do: meta(state, meta, fold, agent),
            else: {:ok, fold}
        end
    end
  end

  defp first(state, path, fold, agent, size) do
    if match?(%{finished: true}, fold.files[agent]),
      do: {:ok, Fold.skip_file(fold, agent, size)},
      else: bounded(state, path, fold, agent, size)
  end

  # At most the file's last `first_read` bytes, as `text/5`'s `{:last, n}` reads the main file's
  # last part; from one byte before them, so a line that starts at the bound is kept whole.
  defp bounded(state, path, fold, agent, size) do
    from = max(size - state.first_read - 1, 0)

    case tail(state, path, from) do
      {:ok, bytes} -> Fold.take_file_from(fold, agent, from, bytes)
      :no_file -> {:ok, Fold.file_problem(fold, agent, "no_file")}
      other -> other
    end
  end

  defp grow(state, path, fold, agent, size) do
    case fold.files[agent] do
      # One that was gone is read through its seam, so a file made again at the same size is
      # still found to be another.
      %{offset: ^size, problem: problem} when problem != "no_file" ->
        {:ok, fold}

      _ ->
        case tail(state, path, Fold.file_read_from(fold, agent)) do
          {:ok, bytes} ->
            case Fold.take_file(fold, agent, bytes) do
              {:ok, fold} -> {:ok, fold}
              :rewritten -> grow_again(state, path, fold, agent, size)
            end

          :no_file ->
            {:ok, Fold.file_problem(fold, agent, "no_file")}

          other ->
            other
        end
    end
  end

  defp grow_again(state, path, fold, agent, size) do
    with {:ok, fold} <- bounded(state, path, Fold.restart_file(fold, agent), agent, size) do
      if fold.files[agent].problem == "no_file",
        do: {:ok, fold},
        else: {:ok, Fold.file_problem(fold, agent, "rewritten")}
    end
  end

  defp meta(state, path, fold, agent) do
    case tail(state, path, 0) do
      {:ok, bytes} ->
        case Fold.file_meta(fold, agent, bytes) do
          {:ok, fold} -> {:ok, fold}
          :unreadable -> {:ok, fold}
        end

      :no_file ->
        {:ok, fold}

      other ->
        other
    end
  end

  # `%{agent_id => bytes}` of each `agent-<id>.jsonl` in `dir`; none without the directory.
  defp list(state, dir) do
    case Shell.run(state.host, state.programs.sh, ["-c", @list, "sh", dir, state.programs.wc],
           timeout: state.timeout
         ) do
      {:ok, %{status: 0, output: "none"}} ->
        {:ok, %{}}

      {:ok, %{status: 0, output: "list\n" <> out}} ->
        sizes =
          for line <- String.split(out, "\n", trim: true),
              [size, file] <- [String.split(String.trim_leading(line), " ", parts: 2)],
              [_, agent] <- [Regex.run(~r/^agent-(.+)\.jsonl$/, Path.basename(file))],
              {n, ""} <- [Integer.parse(size)],
              into: %{},
              do: {agent, n}

        {:ok, sizes}

      {:ok, %{status: status, output: out}} ->
        {:unknown, {:sh, status, String.slice(out, 0, 200)}}

      other ->
        other
    end
  end

  defp last(state, path) do
    args = [
      "-c",
      @last,
      "sh",
      path,
      state.programs.tail,
      state.programs.wc,
      Integer.to_string(state.first_read)
    ]

    case Shell.run(state.host, state.programs.sh, args, timeout: state.timeout) do
      {:ok, %{status: 0, output: "nofile"}} ->
        :no_file

      {:ok, %{status: 0, output: "file" <> out} = result} ->
        with [at, bytes] <- :binary.split(out, "\n"),
             {from, ""} <- Integer.parse(at) do
          {:ok, from, bytes}
        else
          _ -> {:unknown, {:sh, result.status, String.slice(out, 0, 200)}}
        end

      {:ok, %{status: status, output: out}} ->
        {:unknown, {:sh, status, String.slice(out, 0, 200)}}

      other ->
        other
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
