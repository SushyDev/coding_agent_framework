defmodule CodingAgentFramework.Mains.Checkout do
  @moduledoc """
  A project's checkout as pure functions of what git prints (`docs/design.md`, "Main sessions";
  `model/tla/Checkout.tla`): where it lives, the git commands of its clone, its reading and its
  pull, and what a reading says. `Mains` runs the commands through `Shell`, each under `env -i`
  with the project's environment, and decides with these.

  The checkout of `project` is `<home>/checkouts/<project>`; its clone is made at
  `<home>/checkouts/.<project>.clone` and renamed into place once whole, so a checkout at its
  path is always a whole one (`Checkout.tla`'s `WholeCheckout`).

  **A reading** is its branch, whether it is clean (`git status --porcelain
  --untracked-files=all` lists nothing), and how far its trunk is ahead of and behind
  `origin/<trunk>` as the last fetch left it. Its `state` is the one word a view shows: `ready`
  (on trunk, clean, level with its remote), `behind` (clean, and a pull would fast-forward it),
  `dirty`, `ahead` (a commit on trunk the remote lacks), `off_trunk`; `cloning`, `absent`,
  `locked` and `failed` come from `Mains` itself (`failed_state/1`). A pull goes only from
  `ready` or `behind`.

      iex> alias CodingAgentFramework.Mains.Checkout
      iex> Checkout.path("/srv/caf", "app")
      "/srv/caf/checkouts/app"
      iex> Checkout.reading("main", "main\\n", "", "0\\t2\\n").state
      "behind"
      iex> Checkout.reading("main", "main\\n", " M lib/a.ex\\n", "0\\t2\\n").state
      "dirty"
      iex> Checkout.pullable?(Checkout.reading("main", "main\\n", "", "1\\t2\\n"))
      false
  """

  @type reading :: %{
          state: String.t(),
          branch: String.t() | nil,
          clean: boolean,
          ahead: non_neg_integer,
          behind: non_neg_integer
        }

  @doc "The checkout's path under the framework home."
  @spec path(String.t(), String.t()) :: String.t()
  def path(home, project), do: Path.join([home, "checkouts", project])

  @doc "git's index lock in the checkout at `path`, which a cut git command may leave."
  @spec lock_path(String.t()) :: String.t()
  def lock_path(path), do: Path.join([path, ".git", "index.lock"])

  @doc "Where its clone is made before it is renamed into place."
  @spec clone_path(String.t(), String.t()) :: String.t()
  def clone_path(home, project), do: Path.join([home, "checkouts", "." <> project <> ".clone"])

  @doc """
  git's arguments for each step: `{:clone, origin, trunk, to}`, `{:head, path, trunk}`,
  `{:branch, path}`, `{:status, path}` (`--no-optional-locks`: a read writes nothing back, so
  it never holds the index lock a person's git in the checkout needs), `{:counts, path, trunk}`,
  `{:fetch, path, trunk}` and `{:merge, path, trunk}` (`--ff-only`: a local commit refuses it,
  and an edit it would overwrite; any other edit is carried, never lost).

      iex> CodingAgentFramework.Mains.Checkout.git({:merge, "/c", "main"})
      ["-C", "/c", "merge", "--ff-only", "--quiet", "refs/remotes/origin/main"]
      iex> CodingAgentFramework.Mains.Checkout.git({:status, "/c"}) |> Enum.take(4)
      ["--no-optional-locks", "-C", "/c", "status"]
  """
  @spec git(tuple) :: [String.t()]
  def git({:clone, origin, trunk, to}),
    do: ["clone", "--quiet", "--branch", trunk, "--origin", "origin", "--", origin, to]

  def git({:head, path, trunk}),
    do: ["-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/" <> trunk]

  def git({:branch, path}), do: ["-C", path, "symbolic-ref", "--quiet", "--short", "HEAD"]
  # A plain `status` takes the index lock to write back the file times it refreshed, so a
  # person's commit in the checkout during a read failed on the lock (F-145).
  def git({:status, path}),
    do: ["--no-optional-locks", "-C", path, "status", "--porcelain", "--untracked-files=all"]

  def git({:counts, path, trunk}),
    do: ["-C", path, "rev-list", "--left-right", "--count", "#{local(trunk)}...#{remote(trunk)}"]

  def git({:fetch, path, trunk}),
    do: [
      "-C",
      path,
      "fetch",
      "--quiet",
      "--no-tags",
      "origin",
      "+#{local(trunk)}:#{remote(trunk)}"
    ]

  def git({:merge, path, trunk}),
    do: ["-C", path, "merge", "--ff-only", "--quiet", remote(trunk)]

  defp local(trunk), do: "refs/heads/" <> trunk
  defp remote(trunk), do: "refs/remotes/origin/" <> trunk

  @doc """
  A reading from git's output: the branch (`symbolic-ref`'s, or nil when HEAD is detached),
  `git status`'s and `rev-list --left-right --count`'s. Answers the reading, or
  `{:refused, {:counts, output}}` when the counts cannot be read.
  """
  @spec reading(String.t(), String.t() | nil, String.t(), String.t()) ::
          reading | {:refused, term}
  def reading(trunk, branch, status, counts) do
    branch = branch && String.trim(branch)

    case Regex.run(~r/\A(\d+)\s+(\d+)\s*\z/, counts) do
      [_, ahead, behind] ->
        r = %{branch: branch, clean: status == "", ahead: int(ahead), behind: int(behind)}
        Map.put(r, :state, state(trunk, r))

      nil ->
        {:refused, {:counts, counts}}
    end
  end

  defp int(s), do: String.to_integer(s)

  defp state(trunk, %{branch: branch}) when branch != trunk, do: "off_trunk"
  defp state(_trunk, %{clean: false}), do: "dirty"
  defp state(_trunk, %{ahead: a}) when a > 0, do: "ahead"
  defp state(_trunk, %{behind: b}) when b > 0, do: "behind"
  defp state(_trunk, _r), do: "ready"

  @doc """
  Whether a pull may go from this reading: on trunk, clean and not ahead (`Checkout.tla`'s
  `Check`). Anything else is a state a person sees, and the pull stays owed.
  """
  @spec pullable?(reading | term) :: boolean
  def pullable?(%{state: state}), do: state in ["ready", "behind"]
  def pullable?(_), do: false

  @doc """
  The state of a checkout whose read or pull failed with `reason` (F-143): `locked` when git
  names the checkout's `index.lock` (a git command a restart or a person cut left it, and
  every git command there fails until it is gone), else `failed`. The framework never removes
  a file in the checkout it did not write: a person clears the lock, and the pull, still owed,
  goes at the read after.

      iex> reason = {:read, {:git, 128, "fatal: Unable to create '/c/.git/index.lock': File exists."}}
      iex> CodingAgentFramework.Mains.Checkout.failed_state(reason)
      "locked"
      iex> CodingAgentFramework.Mains.Checkout.failed_state({:pull, {:git, 128, "fatal: no remote"}})
      "failed"
  """
  @spec failed_state(term) :: String.t()
  def failed_state(reason) do
    if String.contains?(
         inspect(reason, limit: :infinity, printable_limit: :infinity),
         "index.lock"
       ),
       do: "locked",
       else: "failed"
  end
end
