defmodule CodingAgentFramework.Programs do
  @moduledoc """
  The absolute path of every program the framework runs on one host: tmux, dtach, claude, git
  and gh, and the POSIX tools sh, sleep, rm, kill, env, ps, cat, tail, mkdir and mkfifo (a
  headless delegate's stdin is a FIFO).

  The paths are found once, by the host's own shell (`command -v`), so no later call looks a
  program up through a `PATH`: a long `PATH` searched on the VM's file server slowed every file
  call. They can also be given outright with `new/2`. `Holder`, `Tmux.CLI`, `Registry` and `Transcripts` take
  the paths they run from here.

  The library reads no environment: the host app hands the paths in. On this machine they can be
  the store paths devenv exports as `CAF_<NAME>`, such as `CAF_TMUX` or `CAF_SH` (see
  `devenv.nix`). A remote host has its own programs, so `find/3` looks them up there, with that
  host's shell, over ssh.

      iex> host = CodingAgentFramework.Host.local("laptop", "/run/bin/kill")
      iex> {:ok, programs} = CodingAgentFramework.Programs.new(host, %{tmux: "/run/bin/tmux"})
      iex> CodingAgentFramework.Programs.fetch(programs, :tmux)
      {:ok, "/run/bin/tmux"}
      iex> CodingAgentFramework.Programs.fetch(programs, :gh)
      {:refused, {:no_program, :gh}}
      iex> CodingAgentFramework.Programs.take(programs, [:tmux, :rm, :sh])
      {:refused, {:no_program, [:rm, :sh]}}
  """

  alias CodingAgentFramework.{Host, Shell}

  @enforce_keys [:host, :paths]
  defstruct [:host, :paths]

  @type name ::
          :tmux
          | :dtach
          | :claude
          | :git
          | :gh
          | :sh
          | :sleep
          | :rm
          | :kill
          | :env
          | :ps
          | :cat
          | :tail
          | :mkdir
          | :mkfifo
  @type t :: %__MODULE__{host: Host.t(), paths: %{name => String.t()}}

  @names [
    :tmux,
    :dtach,
    :claude,
    :git,
    :gh,
    :sh,
    :sleep,
    :rm,
    :kill,
    :env,
    :ps,
    :cat,
    :tail,
    :mkdir,
    :mkfifo
  ]
  # The one fixed path in the library: `find/3` needs a shell to find the rest, sh included.
  @sh "/bin/sh"
  @find ~S"""
  for n do
    if p=$(command -v "$n"); then printf '%s\t%s\n' "$n" "$p"; else printf '%s\t\n' "$n"; fi
  done
  """

  @doc "The names a host's programs are known by."
  @spec names() :: [name]
  def names, do: @names

  @doc """
  Takes paths given outright. Each must be absolute; nothing is run.
  """
  @spec new(Host.t(), %{name => String.t()}) :: {:ok, t} | {:refused, term}
  def new(%Host{} = host, paths) when is_map(paths) do
    case Enum.reject(paths, fn {name, path} -> name in @names and absolute?(path) end) do
      [] -> {:ok, %__MODULE__{host: host, paths: paths}}
      bad -> {:refused, {:bad_paths, Map.new(bad)}}
    end
  end

  @doc """
  Finds `names` with the host's `/bin/sh`. Every name must resolve to an absolute path.

  `/bin/sh` is the only fixed program path in the library: something must find the rest, and
  POSIX puts a shell there on every host. Every other module runs the paths found here or given.

  Returns `{:refused, {:not_found, names}}` naming each one that did not.
  """
  @spec find(Host.t(), [name], keyword) :: {:ok, t} | {:refused, term} | {:unknown, term}
  def find(%Host{} = host, names, opts \\ [timeout: 10_000]) do
    with [] <- names -- @names,
         {:ok, %{status: 0, output: out}} <-
           Shell.run(host, @sh, ["-c", @find, "sh" | Enum.map(names, &Atom.to_string/1)], opts) do
      found =
        for line <- String.split(out, "\n", trim: true),
            [name, path] <- [String.split(line, "\t", parts: 2)],
            absolute?(path),
            into: %{},
            do: {String.to_existing_atom(name), path}

      case Enum.reject(names, &Map.has_key?(found, &1)) do
        [] -> {:ok, %__MODULE__{host: host, paths: found}}
        missing -> {:refused, {:not_found, missing}}
      end
    else
      unknown_names when is_list(unknown_names) -> {:refused, {:unknown_names, unknown_names}}
      {:ok, %{status: status, output: out}} -> {:unknown, {:sh, status, out}}
      other -> other
    end
  end

  @doc "The path of one program, or a refusal naming it."
  @spec fetch(t, name) :: {:ok, String.t()} | {:refused, {:no_program, name}}
  def fetch(%__MODULE__{paths: paths}, name) do
    case Map.fetch(paths, name) do
      {:ok, path} -> {:ok, path}
      :error -> {:refused, {:no_program, name}}
    end
  end

  @doc """
  The paths of several programs as a map, or one refusal naming every one that is missing.
  """
  @spec take(t, [name]) :: {:ok, %{name => String.t()}} | {:refused, {:no_program, [name]}}
  def take(%__MODULE__{paths: paths}, names) do
    case Enum.reject(names, &Map.has_key?(paths, &1)) do
      [] -> {:ok, Map.take(paths, names)}
      missing -> {:refused, {:no_program, missing}}
    end
  end

  defp absolute?(path), do: is_binary(path) and Path.type(path) == :absolute
end
