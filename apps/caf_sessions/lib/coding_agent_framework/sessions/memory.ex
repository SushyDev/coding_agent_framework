defmodule CodingAgentFramework.Sessions.Memory do
  @moduledoc """
  One agent memory per checkout or worktree, whatever account a session runs on (F-155).

  Claude Code keeps a working directory's memory in each account's
  `<config>/projects/<encoded cwd>/memory/` (`CodingAgentFramework.Transcripts.project_dir/2`),
  so a move, which copies the transcript to another account, would leave the memory behind.
  The memory lives once in the framework home instead, at `<home>/memory/<encoded cwd>/`, and
  each account's `memory` is a symlink to it, written before every start or resume on that
  account (`link/3`):

  - no `memory` on the account: the link is made;
  - the link already names the home's folder: nothing changes;
  - a real folder: its entries are moved into the home's folder once, if that holds none, and
    the folder gives way to the link; if both hold files, nothing is moved and the link is
    refused, `{:both, account_dir, home_dir}`, for a person to merge;
  - anything else (a file, a link elsewhere) is refused and left as it is.

  Nothing is ever written over: a folder is moved entry by entry with `rename`, which refuses
  an entry already there, and both folders are under the home, so a rename never copies.

      iex> CodingAgentFramework.Sessions.Memory.dir("/caf", "/caf/checkouts/demo")
      {:ok, "/caf/memory/-caf-checkouts-demo"}
  """

  alias CodingAgentFramework.Transcripts

  @doc "The home's memory folder of working directory `cwd`."
  @spec dir(Path.t(), Path.t()) :: {:ok, Path.t()} | {:refused, :long_cwd}
  def dir(home, cwd) do
    with {:ok, dir} <- Transcripts.project_dir(home, cwd),
         do: {:ok, Path.join([home, "memory", Path.basename(dir)])}
  end

  @doc """
  Links account `config_dir`'s memory of `cwd` to the home's folder (see the module doc).
  Answers `:ok`, or `{:refused, reason}`: `{:both, account_dir, home_dir}`, `{:not_a_folder,
  path}`, `{:links_elsewhere, path, target}`, `:long_cwd` or `{:file, path, why}`.
  """
  @spec link(Path.t(), Path.t(), Path.t()) :: :ok | {:refused, term}
  def link(home, config_dir, cwd) do
    with {:ok, shared} <- dir(home, cwd),
         {:ok, project} <- Transcripts.project_dir(config_dir, cwd),
         :ok <- mkdir(shared),
         :ok <- mkdir(project) do
      place(Path.join(project, "memory"), shared)
    end
  end

  defp place(link, shared) do
    case File.lstat(link) do
      {:error, :enoent} -> symlink(shared, link)
      {:ok, %{type: :symlink}} -> linked(link, shared)
      {:ok, %{type: :directory}} -> take(link, shared)
      {:ok, _} -> {:refused, {:not_a_folder, link}}
      {:error, why} -> {:refused, {:file, link, why}}
    end
  end

  defp linked(link, shared) do
    case File.read_link(link) do
      {:ok, ^shared} -> :ok
      {:ok, other} -> {:refused, {:links_elsewhere, link, other}}
      {:error, why} -> {:refused, {:file, link, why}}
    end
  end

  # The account's own folder, from before the link: moved once into an empty home folder.
  defp take(link, shared) do
    with {:ok, mine} <- ls(link),
         {:ok, theirs} <- ls(shared) do
      cond do
        mine != [] and theirs != [] ->
          {:refused, {:both, link, shared}}

        true ->
          with :ok <- move(link, shared, mine), :ok <- rmdir(link), do: symlink(shared, link)
      end
    end
  end

  defp move(from, to, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case File.rename(Path.join(from, entry), Path.join(to, entry)) do
        :ok -> {:cont, :ok}
        {:error, why} -> {:halt, {:refused, {:file, Path.join(from, entry), why}}}
      end
    end)
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> {:ok, Enum.sort(entries)}
      {:error, why} -> {:refused, {:file, dir, why}}
    end
  end

  defp mkdir(dir), do: result(File.mkdir_p(dir), dir)
  defp rmdir(dir), do: result(File.rmdir(dir), dir)
  defp symlink(target, link), do: result(File.ln_s(target, link), link)

  defp result(:ok, _path), do: :ok
  defp result({:error, why}, path), do: {:refused, {:file, path, why}}
end
