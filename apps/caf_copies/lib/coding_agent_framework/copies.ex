defmodule CodingAgentFramework.Copies do
  @moduledoc """
  A host's copy of each worktree, kept in step by rsync before each job or service, and removed
  with the worktree (see "Hosts" in `docs/design.md` and `model/tla/Copy.tla`). One process
  with no name, started by the embedding app, which owns the `copies` table
  (`CodingAgentFramework.Copies.Table`) in its directory.

  A copy lives at `<dir>/copies/<project>/<name>` on its host, where `dir` is the host's
  framework directory: the workstation has copies too, under the framework home. A copy is a
  map: `%{programs: programs, dir: dir, project: project, name: name}`, whose `programs` are the
  host's own (`sh`, `mkdir`, `flock`, `rsync`, `rm`) and name the host.

  **The turn** is the table's row. A run takes it (`take/3`) before its sync, and gives it back
  (`give_back/3`) once its start is settled, which is the caller's act; `starting/3` marks that
  the start is being sent. A second take is refused, naming the holder. A cut sync keeps the
  turn until its host side can no longer take the lock, then frees it by itself. At start, a
  turn whose sync was under way is taken as cut; one taken or synced is freed (its run's call
  ended with the restart and nothing started); one starting is kept for its caller to settle.

  **The sync** (`sync/5`) sends every file git does not ignore: `git ls-files --cached --others
  --exclude-standard`, so edits not yet committed and untracked files are in it. A path an
  earlier sync sent that is gone from the worktree goes with `--delete-missing-args`; a file the
  copy has that no sync sent, such as a build output, stays. Before it sends, it records each
  path named in `:fetch` (size, time and hash) and answers the record, which `fetch/5` checks
  each path against when it brings it back.

  **The host's lock**: rsync's server runs under `flock` of `<copy>.lock` on the host, as its
  `--rsync-path`, so it holds the lock for its whole life, and the next sync takes it within
  `:lock_wait`. The workstation's rsync reaches it through a local stand-in for ssh, so both go
  through the same host side.

      {:ok, copies} = Copies.start_link(dir: dir, programs: programs)
      copy = %{programs: host_programs, dir: "/srv/caf", project: "web", name: "fix-login"}
      {:ok, :taken} = Copies.take(copies, copy, "job-7")
      {:ok, %{record: _}} = Copies.sync(copies, copy, "job-7", worktree, timeout: 60_000, lock_wait: 30_000)
      {:ok, :given} = Copies.give_back(copies, copy, "job-7")
  """

  use GenServer

  alias CodingAgentFramework.{Host, Programs, Shell}
  alias CodingAgentFramework.Copies.Table

  @call 5_000
  @fetch_prefix ".caf-fetch-"
  @removal "copies:remove"
  # $1..$6: mkdir, flock, rsync, the copy, its lock, the wait in seconds; then rsync's server
  # arguments. The lock is taken before the server starts, since it deletes before data comes.
  @host_side "m=$1 f=$2 r=$3 d=$4 l=$5 w=$6; shift 6; \"$m\" -p \"$d\" || exit 1; " <>
               "\"$f\" -E 75 -w \"$w\" \"$l\" \"$r\" \"$@\"; s=$?; " <>
               "[ \"$s\" = 75 ] && echo caf-copies: lock not taken >&2; exit \"$s\""

  @type copy :: %{programs: Programs.t(), dir: String.t(), project: String.t(), name: String.t()}
  @type run :: String.t()

  @doc """
  Starts the part. Options: `:dir`, a directory of this machine of its own (the table and the
  file lists); `:programs`, this machine's `Programs` with `git`, `rsync` and `sh`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The copy's path and its lock's path on its host. Pure."
  @spec place(copy) :: {:ok, {String.t(), String.t()}} | {:refused, term}
  def place(%{dir: dir, project: project, name: name}) do
    if Enum.all?([project, name], &(&1 not in ["", ".", ".."] and not (&1 =~ "/"))) do
      path = Path.join([dir, "copies", project, name])
      {:ok, {path, path <> ".lock"}}
    else
      {:refused, {:bad_name, project, name}}
    end
  end

  @doc "Takes the copy's turn for `run`: `{:ok, :taken}` or `{:refused, {:turn_held, holder}}`."
  @spec take(GenServer.server(), copy, run) :: {:ok, :taken} | {:refused, term} | {:unknown, term}
  def take(copies, copy, run), do: call(copies, {:take, key(copy), run})

  @doc "Marks that `run`, whose sync completed, is sending its start."
  @spec starting(GenServer.server(), copy, run) :: :ok | {:refused, term} | {:unknown, term}
  def starting(copies, copy, run), do: call(copies, {:starting, key(copy), run})

  @doc """
  Gives the turn back once `run`'s start is settled. A cut sync's turn is not given back here:
  `{:refused, {:cut, until}}`, and it frees itself at `until`.
  """
  @spec give_back(GenServer.server(), copy, run) ::
          {:ok, :given} | {:refused, term} | {:unknown, term}
  def give_back(copies, copy, run), do: call(copies, {:give_back, key(copy), run})

  @doc "Every copy's row, for a view or a test."
  @spec turns(GenServer.server()) :: [map] | {:unknown, term}
  def turns(copies), do: call(copies, :turns)

  @doc """
  Brings the copy in step with `worktree`, for `run`, which holds the turn. Options: `:timeout`
  (ms) of the rsync, `:lock_wait` (ms) the host side waits for the lock, `:fetch` the paths to
  record, `:reaper` a `Shell.Reaper`. Answers `{:ok, %{record: %{path => %{size, mtime, hash} |
  :absent}, files: n}}`, or `{:refused, {:sync, reason}}` when the sync was cut: `{:lock, ms}`
  when the host side did not get the lock in time.
  """
  @spec sync(GenServer.server(), copy, run, String.t(), keyword) ::
          {:ok, map} | {:refused, term} | {:unknown, term}
  def sync(copies, copy, run, worktree, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    wait = Keyword.fetch!(opts, :lock_wait)
    until = System.os_time(:millisecond) + timeout + wait

    with {:ok, {path, lock}} <- place(copy),
         {:ok, %{local: local, dir: dir, shim: shim}} <- call(copies, :config),
         {:ok, current} <- list(local, worktree),
         record = record(worktree, Keyword.get(opts, :fetch, [])),
         {:ok, previous} <- call(copies, {:begin, key(copy), run, until, current}) do
      gone = for p <- previous -- current, not exists?(Path.join(worktree, p)), do: p
      files = Path.join(dir, "list-#{System.unique_integer([:positive])}")
      File.write!(files, Enum.join(current ++ gone, <<0>>))
      side = host_side(copy.programs, path, lock, wait)
      {rsh, dest} = reach(copy.programs.host, shim)

      # `--modify-window=-1` compares times to the nanosecond: the quick check of size and whole
      # seconds skips an edit of the same size made in the same second (F-85, new-1).
      args =
        ["-lpt", "--modify-window=-1", "--files-from=" <> files, "--from0"] ++
          ["--delete-missing-args", "-e", rsh] ++
          ["--rsync-path=" <> side, worktree <> "/", dest <> ":" <> path <> "/"]

      outcome =
        Shell.run(local.host, local.paths.rsync, args, Keyword.take(opts, [:reaper, :timeout]))

      File.rm(files)
      finish(copies, copy, run, current, record, wait, outcome)
    end
  end

  @doc """
  Brings each path of `record` (a sync's record) back from the copy into `worktree`, after a
  job's end. One rsync, under the host's lock of the copy, brings the paths into a temporary
  directory in the worktree; then, path by path, the worktree's file is compared with the
  record, and the path is renamed into place only if it still matches. Otherwise the path is a
  conflict: the worktree keeps its edit, and the copy keeps its version. A path the copy does
  not have is left as it is. The temporary directory is removed whether the rsync completed or
  was cut. Options: `:timeout` (ms) of the rsync, `:lock_wait` (ms), `:reaper`.

  Answers `:done`, `{:conflict, paths}`, or `{:unknown, reason}`: the rsync was cut, and
  nothing came in.
  """
  @spec fetch(GenServer.server(), copy, String.t(), map, keyword) ::
          :done | {:conflict, [String.t()]} | {:unknown, term}
  def fetch(copies, copy, worktree, record, opts) do
    with {:ok, {path, lock}} <- place(copy),
         {:ok, %{local: local, dir: dir, shim: shim}} <- call(copies, :config) do
      n = System.unique_integer([:positive])
      temp = Path.join(worktree, "#{@fetch_prefix}#{n}")
      files = Path.join(dir, "fetch-#{n}")
      File.write!(files, Enum.join(Map.keys(record), <<0>>))
      side = host_side(copy.programs, path, lock, Keyword.fetch!(opts, :lock_wait))
      {rsh, dest} = reach(copy.programs.host, shim)

      args =
        ["-lpt", "--files-from=" <> files, "--from0", "--ignore-missing-args", "-e", rsh] ++
          ["--rsync-path=" <> side, dest <> ":" <> path <> "/", temp <> "/"]

      outcome =
        Shell.run(local.host, local.paths.rsync, args, Keyword.take(opts, [:reaper, :timeout]))

      File.rm(files)

      result =
        case outcome do
          {:ok, %{status: 0}} -> into_place(record, temp, worktree)
          other -> {:unknown, {:fetch, other}}
        end

      # A cut rsync may leave part of a file, or its own temporary files, in there.
      File.rm_rf(temp)
      result
    end
  end

  @doc """
  Removes the temporary folders a cut fetch left directly under `worktree` (a restart ends the
  fetch before it removes its own). Only a folder named as `fetch/5` names its own is removed,
  and only directly under `worktree`. Answers the names removed.
  """
  @spec sweep_fetch(String.t()) :: [String.t()]
  def sweep_fetch(worktree) do
    case File.ls(worktree) do
      {:ok, names} ->
        for name <- names,
            fetch_name?(name),
            match?({:ok, _}, File.rm_rf(Path.join(worktree, name))),
            do: name

      {:error, _} ->
        []
    end
  end

  defp fetch_name?(@fetch_prefix <> n), do: n != "" and String.match?(n, ~r/\A\d+\z/)
  defp fetch_name?(_), do: false

  defp into_place(record, temp, worktree) do
    record
    |> Enum.sort()
    |> Enum.reduce_while([], fn {p, recorded}, conflicts ->
      cond do
        not exists?(Path.join(temp, p)) -> {:cont, conflicts}
        record(worktree, [p]) != %{p => recorded} -> {:cont, [p | conflicts]}
        true -> rename(Path.join(temp, p), Path.join(worktree, p), conflicts)
      end
    end)
    |> case do
      [] -> :done
      [_ | _] = conflicts -> {:conflict, Enum.reverse(conflicts)}
      unknown -> unknown
    end
  end

  defp rename(from, to, conflicts) do
    with :ok <- File.mkdir_p(Path.dirname(to)), :ok <- File.rename(from, to) do
      {:cont, conflicts}
    else
      {:error, reason} -> {:halt, {:unknown, {:fetch, {:rename, to, reason}}}}
    end
  end

  @doc """
  Removes the copy from its host, with its lock. It takes the copy's turn first, so it is
  refused while a run holds it. Options: `:timeout` (ms).
  """
  @spec remove(GenServer.server(), copy, keyword) ::
          {:ok, :removed} | {:refused, term} | {:unknown, term}
  def remove(copies, copy, opts) do
    with {:ok, {path, lock}} <- place(copy),
         {:ok, rm} <- Programs.fetch(copy.programs, :rm),
         {:ok, :taken} <- take(copies, copy, @removal) do
      case Shell.run(copy.programs.host, rm, ["-rf", "--", path, lock], opts) do
        {:ok, %{status: 0}} ->
          call(copies, {:delete, key(copy)})

        other ->
          give_back(copies, copy, @removal)
          {:unknown, {:rm, other}}
      end
    end
  end

  defp finish(copies, copy, run, current, record, wait, outcome) do
    {how, answer} =
      case outcome do
        {:ok, %{status: 0}} ->
          {:synced, {:ok, %{record: record, files: length(current)}}}

        {:ok, %{status: status, output: out}} ->
          # The host side said it never took the lock, and has exited: nothing of it is left.
          if out =~ "caf-copies: lock not taken",
            do: {:free, {:refused, {:sync, {:lock, wait}}}},
            else: {:cut, {:refused, {:sync, {:status, status, String.slice(out, -400, 400)}}}}

        {:unknown, reason} ->
          {:cut, {:refused, {:sync, reason}}}

        {:refused, reason} ->
          {:free, {:refused, {:sync, reason}}}
      end

    with :ok <- call(copies, {:finish, key(copy), run, how, current}), do: answer
  end

  defp list(local, worktree) do
    args = ["-C", worktree, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]

    case Shell.run(local.host, local.paths.git, args, timeout: 30_000) do
      {:ok, %{status: 0, output: out}} ->
        {:ok, out |> String.split(<<0>>, trim: true) |> Enum.uniq()}

      other ->
        {:refused, {:git, other}}
    end
  end

  defp record(worktree, paths) do
    Map.new(paths, fn p ->
      file = Path.join(worktree, p)

      case File.stat(file, time: :posix) do
        {:ok, %{type: :regular, size: size, mtime: mtime}} ->
          hash = :crypto.hash(:sha256, File.read!(file)) |> Base.encode16(case: :lower)
          {p, %{size: size, mtime: mtime, hash: hash}}

        _ ->
          {p, :absent}
      end
    end)
  end

  defp exists?(path), do: match?({:ok, _}, File.lstat(path))

  defp host_side(programs, path, lock, wait) do
    %{sh: sh, mkdir: mkdir, flock: flock, rsync: rsync} = programs.paths
    secs = :erlang.float_to_binary(wait / 1000, decimals: 3)

    Enum.map_join(
      [sh, "-c", @host_side, "caf-copies", mkdir, flock, rsync, path, lock, secs],
      " ",
      &Shell.shell_quote/1
    )
  end

  defp reach(%Host{reach: :local}, shim), do: {shim, "localhost"}
  defp reach(%Host{reach: {:ssh, ssh, dest}}, _), do: {ssh <> " -o BatchMode=yes", dest}

  defp key(copy), do: {copy.programs.host.name, copy.project, copy.name}

  defp call(copies, request) do
    GenServer.call(copies, request, @call)
  catch
    :exit, reason -> {:unknown, {:copies, reason}}
  end

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    local = Keyword.fetch!(opts, :programs)

    with {:ok, %{sh: sh}} <- Programs.take(local, [:git, :rsync, :sh]),
         :ok <- File.mkdir_p(dir),
         {:ok, db} <- Table.open(Path.join(dir, "copies.db")) do
      # The workstation's stand-in for ssh: it drops the host name and runs the command, so
      # the host side is the same on every host. Written whole, then renamed into place.
      shim = Path.join(dir, "local-rsh")
      File.write!(shim <> ".new", "#!#{sh}\nshift\nexec #{sh} -c \"$*\"\n")
      File.chmod!(shim <> ".new", 0o755)
      File.rename!(shim <> ".new", shim)
      settle(db)
      {:ok, %{db: db, local: local, dir: dir, shim: shim}}
    else
      {:error, reason} -> {:stop, {:dir, reason}}
      refused -> {:stop, refused}
    end
  end

  # A restart ended every call: a turn taken or synced started nothing and goes back; a sync
  # under way is cut, its host side may still take the lock until its `until`; a start being
  # sent is its caller's to settle by reading the host.
  defp settle(db) do
    for %{state: state} = row <- Table.all(db), state in ~w(taken synced syncing) do
      key = {row.host, row.project, row.name}

      if state == "syncing",
        do: Table.put(db, key, %{row | state: "cut"}),
        else: Table.put(db, key, %{row | state: "free", holder: nil, until: nil})
    end
  end

  @impl true
  def handle_call(:config, _from, s), do: {:reply, {:ok, Map.take(s, [:local, :dir, :shim])}, s}
  def handle_call(:turns, _from, s), do: {:reply, Table.all(s.db), s}

  def handle_call({:take, key, run}, _from, s) do
    row = Table.get(s.db, key)

    if free?(row) do
      Table.put(s.db, key, %{holder: run, state: "taken", sent: row && row.sent})
      {:reply, {:ok, :taken}, s}
    else
      {:reply, {:refused, {:turn_held, row.holder}}, s}
    end
  end

  def handle_call({:begin, key, run, until, current}, _from, s) do
    with_turn(s, key, run, ["taken"], fn row ->
      previous = String.split(row.sent, <<0>>, trim: true)
      sent = Enum.join(Enum.uniq(previous ++ current), <<0>>)
      Table.put(s.db, key, %{row | state: "syncing", until: until, sent: sent})
      {:ok, previous}
    end)
  end

  def handle_call({:finish, key, run, how, current}, _from, s) do
    with_turn(s, key, run, ["syncing"], fn row ->
      case how do
        :synced -> Table.put(s.db, key, %{row | state: "synced", sent: Enum.join(current, <<0>>)})
        :cut -> Table.put(s.db, key, %{row | state: "cut"})
        :free -> Table.put(s.db, key, %{row | state: "free", holder: nil, until: nil})
      end
    end)
  end

  def handle_call({:starting, key, run}, _from, s),
    do: with_turn(s, key, run, ["synced"], &Table.put(s.db, key, %{&1 | state: "starting"}))

  def handle_call({:give_back, key, run}, _from, s) do
    with_turn(s, key, run, ~w(taken synced starting), fn row ->
      Table.put(s.db, key, %{row | state: "free", holder: nil, until: nil})
      {:ok, :given}
    end)
  end

  def handle_call({:delete, key}, _from, s) do
    with_turn(s, key, @removal, ["taken"], fn _ ->
      Table.delete(s.db, key)
      {:ok, :removed}
    end)
  end

  defp with_turn(s, key, run, states, fun) do
    row = Table.get(s.db, key)

    cond do
      row && row.holder == run && row.state in states -> {:reply, fun.(row), s}
      row && row.holder == run && row.state == "cut" -> {:reply, {:refused, {:cut, row.until}}, s}
      true -> {:reply, {:refused, {:turn, row && row.holder, row && row.state}}, s}
    end
  end

  # A cut sync's turn is free once its host side can no longer take the lock.
  defp free?(nil), do: true
  defp free?(%{state: "free"}), do: true
  defp free?(%{state: "cut", until: until}), do: until <= System.os_time(:millisecond)
  defp free?(_), do: false
end
