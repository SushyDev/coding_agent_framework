defmodule CodingAgentFramework.ToolHome do
  @moduledoc """
  Where every program the framework runs keeps its state: inside the framework home, never in
  the person's own folders (F-155). A pure module: `env/2` and `ssh_options/1` only name paths,
  and `prepare/2`, which the embedding app calls once at its start, writes the home's files. It
  starts nothing.

  **The environment** (`env/2`) every agent's launch, every job and every service sets beside
  its own:

  - `GH_CONFIG_DIR`, `<home>/gh`: the GitHub CLI's login is the home's own, as each Claude
    account's is (`bin/caf-login --gh <home>`);
  - `GIT_CONFIG_GLOBAL`, `<home>/git/config`, which `prepare/2` writes, and
    `GIT_CONFIG_NOSYSTEM=1`, so no system file adds a credential helper or an author;
  - `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME`, each
    `<home>/xdg/<kind>`, where gh, git and most other tools keep their files;
  - `GIT_SSH_COMMAND`: the ssh `env/2` is given, with `ssh_options/1`.

  **Every ssh** the framework runs to a host takes `ssh_options/1`: `-F <home>/ssh/config` and
  `-o UserKnownHostsFile=<home>/ssh/known_hosts`, so a host's key is learned into the home.

  **The git config** `prepare/2` writes, whole, renamed into place:

  - the author it is given (`user.name`, `user.email`), so agents commit under a name of the
    app's own, distinct from the person, while `gh` pushes with the person's own login: the
    credential helper for `https://github.com` is the home's `gh auth git-credential`;
  - SSH signing with the home's own key file, made for it by `bin/caf-login --git` and never one
    of the person's keys: `gpg.format ssh`, `user.signingkey` the key's path (no ssh agent, so a
    headless session signs), `gpg.ssh.program` the given `ssh-keygen`, `commit.gpgsign` and
    `tag.gpgsign` true, and `gpg.ssh.allowedSignersFile` (`<home>/git/allowed_signers`, each
    author's email with its key), so `git log --show-signature` verifies;
  - a project's override (author, key, or both) in `<home>/git/projects/<project>.config`,
    included for every repository whose git directory is under the project's checkout
    (`includeIf "gitdir:<checkout>/"`), which holds each of its worktrees' git directories. The
    checkout's path is written with its symlinks resolved, as far as it exists: git matches the
    git directory it found, whose path is physical.

  `<home>/ssh/config` and `<home>/ssh/known_hosts` are made empty when missing and never
  written again: a person names a host's user and key there.

      iex> env = CodingAgentFramework.ToolHome.env("/srv/caf", "/run/bin/ssh")
      iex> List.keyfind(env, "GH_CONFIG_DIR", 0)
      {"GH_CONFIG_DIR", "/srv/caf/gh"}
      iex> List.keyfind(env, "GIT_SSH_COMMAND", 0)
      {"GIT_SSH_COMMAND", ~s('/run/bin/ssh' '-F' '/srv/caf/ssh/config' '-o' 'UserKnownHostsFile="/srv/caf/ssh/known_hosts"')}
  """

  alias CodingAgentFramework.Shell

  @type author :: %{name: String.t(), email: String.t(), signing_key: Path.t()}
  @type project :: %{
          required(:checkout) => Path.t(),
          optional(:name) => String.t(),
          optional(:email) => String.t(),
          optional(:signing_key) => Path.t()
        }

  @xdg ~w(config cache data state)

  @doc """
  The environment under `home` every launch, job and service sets, with `ssh` (an absolute
  path) as git's ssh. Pure.
  """
  @spec env(Path.t(), Path.t()) :: [{String.t(), String.t()}]
  def env(home, ssh) do
    xdg =
      for kind <- @xdg, do: {"XDG_#{String.upcase(kind)}_HOME", Path.join([home, "xdg", kind])}

    command = Enum.map_join([ssh | ssh_options(home)], " ", &Shell.shell_quote/1)

    [
      {"GH_CONFIG_DIR", Path.join(home, "gh")},
      {"GIT_CONFIG_GLOBAL", git_config(home)},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_SSH_COMMAND", command}
    ] ++ xdg
  end

  @doc """
  The options every ssh the framework runs takes before its destination: the home's ssh config
  and known hosts. ssh reads several known hosts files from one value split on whitespace, so
  the path goes between double quotes, which ssh takes as one word (F-169): a home with a space,
  such as macOS's `~/Library/Application Support/<app>`, keeps one file. A home holding a
  double quote, a backslash or a `%` (an ssh token) is refused by `prepare/2`.

      iex> CodingAgentFramework.ToolHome.ssh_options("/srv/caf")
      ["-F", "/srv/caf/ssh/config", "-o", ~s(UserKnownHostsFile="/srv/caf/ssh/known_hosts")]
  """
  @spec ssh_options(Path.t()) :: [String.t()]
  def ssh_options(home) do
    ssh = Path.join(home, "ssh")

    [
      "-F",
      Path.join(ssh, "config"),
      "-o",
      ~s(UserKnownHostsFile=") <> Path.join(ssh, "known_hosts") <> ~s(")
    ]
  end

  @doc """
  The home's git config file (`GIT_CONFIG_GLOBAL`).

      iex> CodingAgentFramework.ToolHome.git_config("/srv/caf")
      "/srv/caf/git/config"
  """
  @spec git_config(Path.t()) :: Path.t()
  def git_config(home), do: Path.join([home, "git", "config"])

  @doc """
  The path of a signing key file of the home: `<home>/git/<name>`, `signing_key` by default,
  which `bin/caf-login --git` makes.

      iex> CodingAgentFramework.ToolHome.signing_key("/srv/caf")
      "/srv/caf/git/signing_key"
  """
  @spec signing_key(Path.t(), String.t()) :: Path.t()
  def signing_key(home, name \\ "signing_key"), do: Path.join([home, "git", name])

  @doc """
  Writes the home's tool files: the directories `env/2` names, `<home>/ssh/config` and
  `known_hosts` when missing, and the git config with its allowed signers and each project's
  override, each whole under a temporary name and renamed. Options: `:author` (`author`, each
  field required; nil, the default, names none: git then refuses a commit outside a project
  with an author of its own, by `user.useConfigOnly`, and never guesses one from the machine),
  `:projects` (project name to `project`, default none; with no home author each field is
  required), `:gh` and `:ssh_keygen` (absolute paths).

  Answers `:ok`, or `{:refused, reason}` before any git file is written: `{:bad_home, home}`
  (not absolute, or holding a control character, `"`, `\\` or `%`), `{:bad, field}`, `{:no_signing_key, path}` (a key or its `.pub` missing: `bin/caf-login --git`
  makes it), or `{:file, path, why}`.
  """
  @spec prepare(Path.t(), keyword) :: :ok | {:refused, term}
  def prepare(home, opts) do
    projects = Keyword.get(opts, :projects, %{})

    with :ok <- home(home),
         {:ok, author} <- author(Keyword.get(opts, :author)),
         {:ok, gh} <- absolute(opts, :gh),
         {:ok, keygen} <- absolute(opts, :ssh_keygen),
         {:ok, projects} <- projects(projects, author),
         {:ok, signers} <- signers(Enum.reject([author | Map.values(projects)], &is_nil/1)),
         :ok <- dirs(home),
         :ok <- touch(Path.join([home, "ssh", "config"])),
         :ok <- touch(Path.join([home, "ssh", "known_hosts"])),
         :ok <- write(Path.join([home, "git", "allowed_signers"]), signers),
         :ok <- write_projects(home, projects) do
      write(git_config(home), global(home, author, gh, keygen, projects))
    end
  end

  # A space is fine: every program takes the home as one argument, and ssh between quotes.
  # What would break ssh's quoting or be read as its token is refused.
  defp home(home) do
    if is_binary(home) and Path.type(home) == :absolute and not (home =~ ~r/[[:cntrl:]"\\%]/),
      do: :ok,
      else: {:refused, {:bad_home, home}}
  end

  defp author(%{name: name, email: email, signing_key: key}) do
    cond do
      not text?(name) -> {:refused, {:bad, :name}}
      not email?(email) -> {:refused, {:bad, :email}}
      not key?(key) -> {:refused, {:bad, :signing_key}}
      true -> {:ok, %{name: name, email: email, signing_key: key}}
    end
  end

  defp author(nil), do: {:ok, nil}
  defp author(_), do: {:refused, {:bad, :author}}

  defp absolute(opts, key) do
    case Keyword.get(opts, key) do
      "/" <> _ = path -> if key?(path), do: {:ok, path}, else: {:refused, {:bad, key}}
      _ -> {:refused, {:bad, key}}
    end
  end

  # A project's override takes the home's author for each field it does not name.
  defp projects(projects, author) when is_map(projects) do
    Enum.reduce_while(Enum.sort(projects), {:ok, %{}}, fn {name, p}, {:ok, acc} ->
      with true <- name =~ ~r/\A[a-z0-9][a-z0-9_-]*\z/ or {:refused, {:bad, {:project, name}}},
           %{checkout: "/" <> _ = checkout} <- p,
           true <- key?(checkout) or {:refused, {:bad, {:checkout, name}}},
           own = Map.take(p, [:name, :email, :signing_key]),
           {:ok, merged} <- author(Map.merge(author || %{}, own)) do
        {:cont, {:ok, Map.put(acc, name, Map.put(merged, :checkout, physical(checkout)))}}
      else
        {:refused, _} = refused -> {:halt, refused}
        _ -> {:halt, {:refused, {:bad, {:checkout, name}}}}
      end
    end)
  end

  defp projects(_, _), do: {:refused, {:bad, :projects}}

  # Each author's email with its key, once: what `git log --show-signature` checks against.
  defp signers(authors) do
    authors
    |> Enum.map(&{&1.email, &1.signing_key})
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn {email, key}, {:ok, acc} ->
      with true <- File.regular?(key) or {:refused, {:no_signing_key, key}},
           {:ok, pub} <- File.read(key <> ".pub") do
        [type, body | _] = String.split(String.trim(pub), " ")
        {:cont, {:ok, [acc, email, ~s( namespaces="git" ), type, " ", body, "\n"]}}
      else
        {:refused, _} = refused -> {:halt, refused}
        {:error, _} -> {:halt, {:refused, {:no_signing_key, key <> ".pub"}}}
      end
    end)
  end

  defp dirs(home) do
    dirs =
      [Path.join(home, "gh"), Path.join([home, "git", "projects"]), Path.join(home, "ssh")] ++
        for(kind <- @xdg, do: Path.join([home, "xdg", kind]))

    Enum.reduce_while(dirs, :ok, fn dir, :ok ->
      case File.mkdir_p(dir) do
        :ok -> {:cont, :ok}
        {:error, why} -> {:halt, {:refused, {:file, dir, why}}}
      end
    end)
  end

  # Made once, empty, and never written again: a person's edits stay.
  defp touch(path) do
    case File.write(path, "", [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, why} -> {:refused, {:file, path, why}}
    end
  end

  defp write_projects(home, projects) do
    Enum.reduce_while(projects, :ok, fn {name, p}, :ok ->
      case write(project_config(home, name), [identity(p) | signed()]) do
        :ok -> {:cont, :ok}
        refused -> {:halt, refused}
      end
    end)
  end

  defp project_config(home, name), do: Path.join([home, "git", "projects", name <> ".config"])

  defp global(home, author, gh, keygen, projects) do
    helper = "!" <> Shell.shell_quote(gh) <> " auth git-credential"

    [
      "# Written by the framework at each start (CodingAgentFramework.ToolHome); edits go.\n",
      identity(author),
      section("gpg", nil, format: "ssh"),
      section("gpg", "ssh",
        program: keygen,
        allowedSignersFile: Path.join([home, "git", "allowed_signers"])
      ),
      if(author, do: signed(), else: []),
      for host <- ["https://github.com", "https://gist.github.com"] do
        # The empty helper first drops any helper named before this file.
        section("credential", host, helper: "", helper: helper)
      end,
      for {name, p} <- Enum.sort(projects) do
        section("includeIf", "gitdir:" <> p.checkout <> "/", path: project_config(home, name))
      end
    ]
  end

  defp identity(nil), do: section("user", nil, useConfigOnly: "true")

  defp identity(a),
    do: section("user", nil, name: a.name, email: a.email, signingkey: a.signing_key)

  defp signed, do: [section("commit", nil, gpgsign: "true"), section("tag", nil, gpgsign: "true")]

  defp section(name, sub, pairs) do
    head = if sub, do: "[#{name} #{quote_value(sub)}]\n", else: "[#{name}]\n"
    [head | for({k, v} <- pairs, do: "\t#{k} = #{quote_value(v)}\n")]
  end

  # git's own quoting: within double quotes, a backslash and a double quote are escaped.
  defp quote_value(v),
    do: ~s(") <> String.replace(v, ["\\", ~s(")], &("\\" <> &1)) <> ~s(")

  defp write(path, iodata) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, iodata),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, why} -> {:refused, {:file, path, why}}
    end
  end

  # `path` with each symlink among the parts that exist resolved, the rest kept as given.
  defp physical(path), do: path |> Path.split() |> Enum.reduce(&resolve(&2, &1, 0))

  defp resolve(at, part, depth) do
    next = Path.join(at, part)

    case File.read_link(next) do
      {:ok, target} when depth < 40 ->
        target
        |> Path.expand(at)
        |> Path.split()
        |> Enum.reduce(&resolve(&2, &1, depth + 1))

      _ ->
        next
    end
  end

  defp text?(v), do: is_binary(v) and v != "" and not (v =~ ~r/[[:cntrl:]]/)
  defp key?(v), do: is_binary(v) and Path.type(v) == :absolute and text?(v)
  defp email?(v), do: text?(v) and v =~ ~r/\A[^\s<>@]+@[^\s<>@]+\z/
end
