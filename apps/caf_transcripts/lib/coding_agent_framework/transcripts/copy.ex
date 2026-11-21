defmodule CodingAgentFramework.Transcripts.Copy do
  @moduledoc """
  One conversation copied from one account's config directory to another's, as Claude Code
  2.1.322 keeps it: `projects/<cwd>/<session id>.jsonl`, the directory of that name beside it,
  and `session-env/<session id>` (F-133's new-4). Each is copied whole under a temporary name and
  renamed into place, and the transcript's size is checked against the source's. A copy, never a
  move: the source keeps its files.

  `Mover` copies a moving session's conversation with it once the old process is gone (F-133),
  and `Mains` a stopped main session's before it resumes on another account than its row's
  (F-177). The caller makes sure no process of the session runs, so the transcript is final.

      iex> alias CodingAgentFramework.{Transcripts, Transcripts.Copy}
      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> {from, to} = {Path.join(dir, "a"), Path.join(dir, "b")}
      iex> {:ok, file} = Transcripts.path(from, "/srv/app", "s1")
      iex> File.mkdir_p!(Path.dirname(file))
      iex> File.write!(file, "{}\\n")
      iex> Copy.copy(from, to, "/srv/app", "s1")
      :ok
      iex> File.read!(Path.join(to, "projects/-srv-app/s1.jsonl"))
      "{}\\n"
      iex> Copy.copy(from, to, "/srv/app", "s2")
      {:refused, {:no_transcript, :enoent}}
  """

  alias CodingAgentFramework.Transcripts

  @doc """
  Copies session `session_id`, started in `cwd`, from config directory `from` to `to`. Answers
  `:ok`, or `{:refused, reason}`: `{:no_transcript, posix}` when the source has none, `{:size,
  bytes}` when the copy's size is not the source's, or the step that failed (`{:mkdir, posix}`,
  `{:copy, posix}`, `{:rename, posix}`, `{:copy_dir, posix}`), and `Transcripts.path/3`'s.
  """
  @spec copy(Path.t(), Path.t(), Path.t(), String.t()) :: :ok | {:refused, term}
  def copy(from, to, cwd, session_id) do
    with {:ok, source} <- Transcripts.path(from, cwd, session_id),
         {:ok, copy} <- Transcripts.path(to, cwd, session_id),
         :ok <- copy_file(source, copy),
         :ok <- copy_dir(Path.rootname(source), Path.rootname(copy)) do
      env = Path.join("session-env", session_id)
      copy_any(Path.join(from, env), Path.join(to, env))
    end
  end

  # `session-env/<session id>` is a directory or a file; a session with none has nothing to copy.
  defp copy_any(source, copy) do
    cond do
      File.dir?(source) -> copy_dir(source, copy)
      File.regular?(source) -> copy_file(source, copy)
      true -> :ok
    end
  end

  defp copy_file(source, copy) do
    tmp = copy <> ".copying"

    with {:ok, %{size: size}} <- File.stat(source) |> named(:no_transcript),
         :ok <- File.mkdir_p(Path.dirname(copy)) |> named(:mkdir),
         :ok <- File.cp(source, tmp) |> named(:copy),
         :ok <- File.rename(tmp, copy) |> named(:rename),
         {:ok, %{size: ^size}} <- File.stat(copy) |> named(:copied) do
      :ok
    else
      {:ok, %{size: other}} -> {:refused, {:size, other}}
      refused -> refused
    end
  end

  defp copy_dir(source, copy) do
    if File.dir?(source) do
      tmp = copy <> ".copying"
      File.rm_rf(tmp)

      with :ok <- File.mkdir_p(Path.dirname(copy)) |> named(:mkdir),
           {:ok, _} <- File.cp_r(source, tmp) |> named(:copy_dir),
           {:ok, _} <- File.rm_rf(copy) |> named(:copy_dir),
           :ok <- File.rename(tmp, copy) |> named(:copy_dir),
           do: :ok
    else
      :ok
    end
  end

  defp named({:error, reason}, what), do: {:refused, {what, reason}}
  defp named({:error, reason, _file}, what), do: {:refused, {what, reason}}
  defp named(ok, _what), do: ok
end
