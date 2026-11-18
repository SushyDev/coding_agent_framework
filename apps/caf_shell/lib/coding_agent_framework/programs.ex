defmodule CodingAgentFramework.Programs do
  @moduledoc """
  The absolute path of every program the framework runs on one host: tmux, dtach, claude, git
  and gh, rsync, ssh and flock (a copy's sync), and the POSIX tools sh, sleep, rm, kill, env,
  ps, cat, tail, head, mkdir and mkfifo (a headless delegate's stdin is a FIFO), wc (a service's log
  offset at its start), nc (a service's port wait), lsof (whether a forward's own ssh holds
  its local port) and curl (a main session's waiter hook, `Intake.waiter_hook/5`).

  The paths are found once, by the host's own shell (`command -v`), so no later call looks a
  program up through a `PATH`: a long `PATH` searched on the VM's file server slowed every file
  call. They can also be given outright with `new/2`. `Holder`, `Tmux.CLI`, `Registry` and `Transcripts` take
  the paths they run from here.

  The library reads no environment: the embedding app hands the paths in. On this machine they can be
  the store paths devenv exports as `CAF_<NAME>`, such as `CAF_TMUX` or `CAF_SH` (see
  `devenv.nix`). A remote host has its own programs, so `find/3` looks them up there, with that
  host's shell, over ssh.

  It also names the host's operating system (`os/1`), which bounds what one launch's argument
  carries (`CodingAgentFramework.ClaudeCLI.prompt_max/1`): `find/3` reads it with `uname -s`
  beside the paths, and `new/3` takes it as `os:`, a local host's being this VM's own
  (`local_os/0`).

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
  defstruct [:host, :paths, os: :unknown]

  @type name ::
          :tmux
          | :dtach
          | :claude
          | :git
          | :gh
          | :rsync
          | :ssh
          | :flock
          | :sh
          | :sleep
          | :rm
          | :kill
          | :env
          | :ps
          | :cat
          | :tail
          | :head
          | :mkdir
          | :mkfifo
          | :nc
          | :wc
          | :lsof
          | :curl
  @type os :: :darwin | :linux | :unknown
  @type t :: %__MODULE__{host: Host.t(), paths: %{name => String.t()}, os: os}

  @names [
    :tmux,
    :dtach,
    :claude,
    :git,
    :gh,
    :rsync,
    :ssh,
    :flock,
    :sh,
    :sleep,
    :rm,
    :kill,
    :env,
    :ps,
    :cat,
    :tail,
    :head,
    :mkdir,
    :mkfifo,
    :nc,
    :wc,
    :lsof,
    :curl
  ]
  # The one fixed path in the library: `find/3` needs a shell to find the rest, sh included.
  @sh "/bin/sh"
  @find ~S"""
  printf 'os\t%s\n' "$(uname -s)"
  for n do
    p=$(command -v "$n") || p=
    case $p in
      /*) ;;
      *)
        # A builtin (kill, echo, test, ...) answers `command -v` with its bare name; the
        # program is then the first executable regular file of that name on the PATH.
        p=
        old=$IFS; IFS=:
        for d in $PATH; do
          if [ -f "${d:-.}/$n" ] && [ -x "${d:-.}/$n" ]; then p="${d:-.}/$n"; break; fi
        done
        IFS=$old
        ;;
    esac
    printf '%s\t%s\n' "$n" "$p"
  done
  """

  @doc "The names a host's programs are known by."
  @spec names() :: [name]
  def names, do: @names

  @doc """
  Takes paths given outright. Each must be absolute; nothing is run. Option `os:` names the
  host's operating system (`os/1`); unless given, a local host's is this VM's own
  (`local_os/0`) and a remote host's `:unknown`.
  """
  @spec new(Host.t(), %{name => String.t()}, keyword) :: {:ok, t} | {:refused, term}
  def new(%Host{} = host, paths, opts \\ []) when is_map(paths) do
    os =
      Keyword.get_lazy(opts, :os, fn ->
        if host.reach == :local, do: local_os(), else: :unknown
      end)

    case Enum.reject(paths, fn {name, path} -> name in @names and absolute?(path) end) do
      [] -> {:ok, %__MODULE__{host: host, paths: paths, os: os}}
      bad -> {:refused, {:bad_paths, Map.new(bad)}}
    end
  end

  @doc """
  The host's operating system: `:darwin`, `:linux`, or `:unknown` (another kernel, or a remote
  host whose paths were given without it).
  """
  @spec os(t) :: os
  def os(%__MODULE__{os: os}), do: os

  @doc """
  This VM's operating system, as `os/1` names it. Every agent runs on the workstation, which is
  where the framework's VM runs.
  """
  @spec local_os() :: os
  def local_os do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, :linux} -> :linux
      _other -> :unknown
    end
  end

  # What `uname -s` prints on each kernel the framework knows.
  defp os_named("Darwin"), do: :darwin
  defp os_named("Linux"), do: :linux
  defp os_named(_other), do: :unknown

  @doc """
  Finds `names` with the host's `/bin/sh`. Every name must resolve to an absolute path.

  `/bin/sh` is the only fixed program path in the library: something must find the rest, and
  POSIX puts a shell there on every host. Every other module runs the paths found here or given.

  A name that is also a shell builtin (`kill`, `echo`, `test`) is looked up on the `PATH` for an
  executable file, in the same shell run. A relative `PATH` entry gives a relative path, which
  is not absolute and so counts as not found.

  Returns `{:refused, {:not_found, names}}` naming each one that did not.
  """
  @spec find(Host.t(), [name], keyword) :: {:ok, t} | {:refused, term} | {:unknown, term}
  def find(%Host{} = host, names, opts \\ [timeout: 10_000]) do
    with [] <- names -- @names,
         {:ok, %{status: 0, output: out}} <-
           Shell.run(host, @sh, ["-c", @find, "sh" | Enum.map(names, &Atom.to_string/1)], opts) do
      lines = for l <- String.split(out, "\n", trim: true), do: String.split(l, "\t", parts: 2)
      os = Enum.find_value(lines, :unknown, fn l -> with ["os", os] <- l, do: os_named(os) end)

      found =
        for [name, path] <- lines,
            name != "os",
            absolute?(path),
            into: %{},
            do: {String.to_existing_atom(name), path}

      case Enum.reject(names, &Map.has_key?(found, &1)) do
        [] -> {:ok, %__MODULE__{host: host, paths: found, os: os}}
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
