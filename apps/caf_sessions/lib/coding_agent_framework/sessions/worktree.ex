defmodule CodingAgentFramework.Sessions.Worktree do
  @moduledoc """
  The checks of a start's worktree (`docs/design.md`, "The worktree"; `model/tla/Start.tla`'s
  `Checked`, `Added` and `Remove`), as pure functions of what git prints. `Sessions` runs the
  commands through `Shell` and decides with these.

  A project is data: `%{name, repo, trunk, setup, setup_timeout, env}`. The worktree of session
  `name` lives at `<root>/<project>/<name>`, where `root` is the physical path of
  `<home>/worktrees`, since git prints worktree paths with symlinks resolved.

      iex> alias CodingAgentFramework.Sessions.Worktree
      iex> {:ok, p} = Worktree.project(%{name: "app", repo: "/src/app", trunk: "main",
      ...>   setup: [["/usr/bin/make", "deps"]], setup_timeout: 60_000, env: %{"HOME" => "/h"}})
      iex> Worktree.path("/srv/caf/worktrees", p, "reviewer")
      "/srv/caf/worktrees/app/reviewer"
      iex> Worktree.branch("framework/f-55-worktrees")
      :ok
      iex> Worktree.branch("-x")
      {:refused, {:bad, :branch}}
  """

  @type project :: %{
          name: String.t(),
          repo: String.t(),
          trunk: String.t(),
          setup: [[String.t()]],
          setup_timeout: pos_integer,
          env: %{String.t() => String.t()}
        }
  # What `git worktree list` says of a path: not listed, or listed on a branch or detached.
  @type listed :: :absent | {:branch, String.t()} | :detached

  @component ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @keys [:name, :repo, :trunk, :setup, :setup_timeout, :env]

  @doc "Checks a project's data. Every command's program and the repository are absolute."
  @spec project(map) :: {:ok, project} | {:refused, term}
  def project(%{} = data) do
    p = Map.take(data, @keys)

    cond do
      map_size(p) != length(@keys) -> {:refused, {:missing, :project, @keys -- Map.keys(p)}}
      not (is_binary(p.name) and p.name =~ @component) -> {:refused, {:bad, :project}}
      not absolute?(p.repo) -> {:refused, {:bad, :repo}}
      branch(p.trunk) != :ok -> {:refused, {:bad, :trunk}}
      not (is_list(p.setup) and Enum.all?(p.setup, &command?/1)) -> {:refused, {:bad, :setup}}
      not (is_integer(p.setup_timeout) and p.setup_timeout > 0) -> {:refused, {:bad, :setup}}
      not env?(p.env) -> {:refused, {:bad, :env}}
      true -> {:ok, p}
    end
  end

  def project(_), do: {:refused, {:bad, :project}}

  @doc """
  Checks a branch name: a plain ref name, stricter than `git check-ref-format --branch`, so it
  is never read as an option or a revision.
  """
  @spec branch(term) :: :ok | {:refused, {:bad, :branch}}
  def branch(name) when is_binary(name) do
    parts = String.split(name, "/")

    if name =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/ and
         Enum.all?(
           parts,
           &(&1 != "" and not String.starts_with?(&1, ".") and
               not String.ends_with?(&1, [".", ".lock"]))
         ) and
         not String.contains?(name, ".."),
       do: :ok,
       else: {:refused, {:bad, :branch}}
  end

  def branch(_), do: {:refused, {:bad, :branch}}

  @doc "The path of session `name`'s worktree of `project` under `root`."
  @spec path(String.t(), project, String.t()) :: String.t()
  def path(root, project, name), do: Path.join([root, project.name, name])

  @doc "Whether a session's name can be a path component."
  @spec name?(String.t()) :: boolean
  def name?(name), do: is_binary(name) and name =~ @component

  @doc "The `env -i` arguments before a git or setup command: the project's environment only."
  @spec env_args(project) :: [String.t()]
  def env_args(project),
    do: ["-i" | Enum.map(Enum.sort(project.env), fn {k, v} -> "#{k}=#{v}" end)]

  @doc "git's arguments: `:list`, `{:status, path}`, `{:branch?, b}`, `{:add, …}`, `{:remove, path}`."
  @spec git(project, term) :: [String.t()]
  def git(p, :list), do: ["-C", p.repo, "worktree", "list", "--porcelain", "-z"]
  def git(_p, {:status, path}), do: ["-C", path, "status", "--porcelain", "--untracked-files=all"]

  def git(p, {:branch?, b}),
    do: ["-C", p.repo, "show-ref", "--verify", "--quiet", "refs/heads/" <> b]

  def git(p, {:add, path, b, true}), do: ["-C", p.repo, "worktree", "add", "--", path, b]

  def git(p, {:add, path, b, false}),
    do: ["-C", p.repo, "worktree", "add", "-b", b, "--", path, p.trunk]

  def git(p, {:remove, path}), do: ["-C", p.repo, "worktree", "remove", "--", path]

  @doc """
  What `git worktree list --porcelain -z` says of `path`.

      iex> out = "worktree /r\\0HEAD 1\\0branch refs/heads/main\\0\\0worktree /w/a\\0HEAD 1\\0detached\\0\\0"
      iex> CodingAgentFramework.Sessions.Worktree.listed(out, "/r")
      {:branch, "main"}
      iex> CodingAgentFramework.Sessions.Worktree.listed(out, "/w/a")
      :detached
      iex> CodingAgentFramework.Sessions.Worktree.listed(out, "/w/b")
      :absent
  """
  @spec listed(String.t(), String.t()) :: listed
  def listed(output, path) do
    output
    |> String.split("\0\0", trim: true)
    |> Enum.map(&String.split(&1, "\0", trim: true))
    |> Enum.find_value(:absent, fn
      ["worktree " <> ^path | fields] ->
        Enum.find_value(fields, :detached, fn
          "branch refs/heads/" <> b -> {:branch, b}
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  @doc """
  `Checked`: what a start does at its path. `status` is `git status`'s output for a listed path
  (nil when not listed). A free path is added; a tree on the branch is reused when clean, or for
  a resume, which takes it as it is; anything else is refused. A resume needs its tree.

      iex> CodingAgentFramework.Sessions.Worktree.decide(:absent, nil, "b", false)
      :add
      iex> CodingAgentFramework.Sessions.Worktree.decide({:branch, "b"}, " M x\\n", "b", false)
      {:refused, {:worktree, :dirty}}
      iex> CodingAgentFramework.Sessions.Worktree.decide({:branch, "b"}, " M x\\n", "b", true)
      :reuse
  """
  @spec decide(listed, String.t() | nil, String.t(), boolean) :: :add | :reuse | {:refused, term}
  def decide(:absent, _status, _branch, false), do: :add
  def decide(:absent, _status, _branch, true), do: {:refused, {:worktree, :absent}}
  def decide({:branch, b}, status, b, resume?) when status == "" or resume?, do: :reuse
  def decide({:branch, b}, _status, b, _resume?), do: {:refused, {:worktree, :dirty}}
  def decide({:branch, other}, _status, _b, _resume?), do: {:refused, {:worktree, {:on, other}}}
  def decide(:detached, _status, _b, _resume?), do: {:refused, {:worktree, :detached}}

  @doc """
  `Remove`'s check after a restart: only a tree listed on the row's branch, clean, and held by no
  other row is removed; anything else is kept, and the answer says why.

      iex> CodingAgentFramework.Sessions.Worktree.removal({:branch, "b"}, "", "b", false)
      :remove
      iex> CodingAgentFramework.Sessions.Worktree.removal({:branch, "b"}, "?? new\\n", "b", false)
      {:keep, "dirty"}
  """
  @spec removal(listed, String.t() | nil, String.t(), boolean) :: :remove | {:keep, String.t()}
  def removal(:absent, _status, _branch, _held?), do: {:keep, "absent"}
  def removal({:branch, b}, "", b, false), do: :remove
  def removal({:branch, b}, "", b, true), do: {:keep, "held"}
  def removal({:branch, b}, _status, b, _held?), do: {:keep, "dirty"}
  def removal(_listed, _status, _branch, _held?), do: {:keep, "not on the branch"}

  defp command?([program | args]), do: absolute?(program) and Enum.all?(args, &is_binary/1)
  defp command?(_), do: false

  defp env?(env),
    do:
      is_map(env) and
        Enum.all?(env, fn {k, v} ->
          is_binary(k) and k =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/ and is_binary(v)
        end)

  defp absolute?(path), do: is_binary(path) and Path.type(path) == :absolute
end
