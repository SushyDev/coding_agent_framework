defmodule CodingAgentFramework.Mains.Rename do
  @moduledoc """
  What a checkout's rename moves beside the checkout itself (F-156, `Checkout.tla`'s
  `RenameOld` and `Repair`). An earlier build made a project's checkout at
  `<home>/checkouts/<project>`; it now lives at `<home>/checkouts/<dir>`, and Claude Code keys
  what it keeps of a working directory by that directory's path:

  - each account's `<config>/projects/<encoded cwd>/`, the main sessions' conversations, so a
    resume in the new checkout finds them (`CodingAgentFramework.Transcripts.project_dir/2`);
  - the home's one memory folder of the checkout, `<home>/memory/<encoded cwd>/` (F-155).

  `moves/4` plans each folder's move and refuses one whose entry is already there; `move_all/1`
  moves entry by entry with `rename`, never over anything, and drops the account's `memory`
  link (the framework's own, which `Sessions.Memory.link/3` makes again at the next start).
  A restart part way leaves the rest for the next try: what moved is gone from the old folder.

  Then the checkout is renamed, and every worktree made from it names its git directory at the
  old path: `stale_worktrees/1` finds them, and `git worktree repair` links them again.
  """

  alias CodingAgentFramework.Sessions.Memory
  alias CodingAgentFramework.Transcripts

  @doc """
  The moves from `old` to `new` of the accounts' conversations (each of `config_dirs`) and of
  the home's memory: `{:ok, [{from, to}]}` for each folder that exists, or `{:refused, {:both,
  path}}` when an entry of one is already at its new place.
  """
  @spec moves(Path.t(), [Path.t()], Path.t(), Path.t()) ::
          {:ok, [{Path.t(), Path.t()}]} | {:refused, term}
  def moves(home, config_dirs, old, new) do
    memory =
      with {:ok, from} <- Memory.dir(home, old),
           {:ok, to} <- Memory.dir(home, new),
           do: {:ok, {from, to}}

    pairs =
      Enum.map(config_dirs, fn dir ->
        with {:ok, from} <- Transcripts.project_dir(dir, old),
             {:ok, to} <- Transcripts.project_dir(dir, new),
             do: {:ok, {from, to}}
      end) ++ [memory]

    Enum.reduce_while(pairs, {:ok, []}, fn
      {:ok, {from, to}}, {:ok, acc} ->
        case clash(from, to) do
          :ok -> {:cont, {:ok, if(File.dir?(from), do: acc ++ [{from, to}], else: acc)}}
          refused -> {:halt, refused}
        end

      refused, _acc ->
        {:halt, refused}
    end)
  end

  defp clash(from, to) do
    with {:ok, entries} <- ls(from) do
      case Enum.find(entries, &(not link?(from, &1) and exists?(Path.join(to, &1)))) do
        nil -> :ok
        entry -> {:refused, {:both, Path.join(to, entry)}}
      end
    end
  end

  @doc "Moves each folder's entries to its new place, then removes the old folder."
  @spec move_all([{Path.t(), Path.t()}]) :: :ok | {:refused, term}
  def move_all(moves) do
    Enum.reduce_while(moves, :ok, fn {from, to}, :ok ->
      case move(from, to) do
        :ok -> {:cont, :ok}
        refused -> {:halt, refused}
      end
    end)
  end

  defp move(from, to) do
    with {:ok, entries} <- ls(from),
         :ok <- File.mkdir_p(to) |> named(to) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        path = Path.join(from, entry)

        result =
          if link?(from, entry),
            do: File.rm(path) |> named(path),
            else: File.rename(path, Path.join(to, entry)) |> named(path)

        if result == :ok, do: {:cont, :ok}, else: {:halt, result}
      end)
      |> then(fn
        :ok -> File.rmdir(from) |> named(from)
        refused -> refused
      end)
    end
  end

  # The account's memory link (F-155): the framework's own, made again at the next start.
  defp link?(from, entry),
    do: entry == "memory" and match?({:ok, %{type: :symlink}}, File.lstat(Path.join(from, entry)))

  defp exists?(path), do: match?({:ok, _}, File.lstat(path))

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> {:ok, Enum.sort(entries)}
      {:error, :enoent} -> {:ok, []}
      {:error, why} -> {:refused, {:file, dir, why}}
    end
  end

  defp named(:ok, _path), do: :ok
  defp named({:error, why}, path), do: {:refused, {:file, path, why}}

  @doc """
  The worktrees of the checkout at `repo` whose `.git` file names a git directory that is not
  there: a worktree made before the checkout's rename. Each is read from the checkout's
  `.git/worktrees/<name>/gitdir`, which names the worktree's `.git`.
  """
  @spec stale_worktrees(Path.t()) :: [Path.t()]
  def stale_worktrees(repo) do
    root = Path.join([repo, ".git", "worktrees"])

    for name <- list(root),
        {:ok, text} <- [File.read(Path.join([root, name, "gitdir"]))],
        dot_git = String.trim(text),
        {:ok, "gitdir: " <> named} <- [File.read(dot_git)],
        not File.dir?(String.trim(named)),
        do: Path.dirname(dot_git)
  end

  defp list(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.sort(entries)
      _ -> []
    end
  end
end
