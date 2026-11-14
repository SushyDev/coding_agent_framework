defmodule CodingAgentFramework.Programs do
  @moduledoc """
  The absolute path of tmux, dtach, claude, git and gh on one host.

  The paths are found once, by the host's own shell (`command -v`), so no later call looks a
  program up through a `PATH`: a long `PATH` searched on the VM's file server slowed every file
  call. They can also be given outright with `new/2`.

      iex> host = CodingAgentFramework.Host.local("laptop")
      iex> {:ok, programs} = CodingAgentFramework.Programs.new(host, %{tmux: "/usr/bin/tmux"})
      iex> CodingAgentFramework.Programs.fetch(programs, :tmux)
      {:ok, "/usr/bin/tmux"}
      iex> CodingAgentFramework.Programs.fetch(programs, :gh)
      {:refused, {:no_program, :gh}}
  """

  alias CodingAgentFramework.{Host, Shell}

  @enforce_keys [:host, :paths]
  defstruct [:host, :paths]

  @type name :: :tmux | :dtach | :claude | :git | :gh
  @type t :: %__MODULE__{host: Host.t(), paths: %{name => String.t()}}

  @names [:tmux, :dtach, :claude, :git, :gh]
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

  defp absolute?(path), do: is_binary(path) and Path.type(path) == :absolute
end
