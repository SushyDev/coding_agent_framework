defmodule CodingAgentFramework.Hosts do
  @moduledoc """
  Keeps what the framework knows of each remote host, and finds a host's programs when work is
  placed there (`docs/design.md`, "Hosts"; `model/tla/Host.tla`; F-280).

  The app declares each host by how it is reached and its framework directory. Nothing is
  found at the tree's start, so a host that is asleep or off the network then delays nothing.
  Each placement of new work on a host (`reach/4` with `:place`) finds its programs over ssh
  with `CodingAgentFramework.Programs.find/3`, bounded by the placement's timeout, and keeps
  the answer:

    * every program `needs/1` names, and an rsync new enough for a copy: the host is `ready`,
      and the answer is the host as `CodingAgentFramework.Copies.Held` reads it;
    * a program missing: `{:refused, {:no_program, host, names}}`, naming every one;
    * an rsync too old: `{:refused, {:old_rsync, host, version}}`, `version` the first line of
      its `--version`;
    * no answer within the bound: `{:refused, {:host_away, host}}`.

  A host that was away or lacking is found again on its next placement, so it joins once it
  answers with every program, with no restart. A placement on a ready host finds it again too,
  since only a find tells that the host still answers: that is one ssh per placement, and one
  more for the rsync's version when the host has not been found ready with that rsync.

  A read of work already placed (`:reach`) takes the programs kept while the host is ready,
  so it costs no ssh. A host not ready is found again at most once each `:retry` ms (30 s by
  default) for such reads, which run in a part's own process on its interval; between, the
  read answers `{:unknown, {:host_away, host}}` or the kept refusal.

  Each find runs in the caller's process, so one host's find never waits on another's.

      {:ok, hosts} = Hosts.start_link(hosts: %{"mac" => %{host: mac, dir: "/Users/me/caf"}})
      Hosts.reach(hosts, "mac", :place, 5_000)
      #=> {:ok, %{programs: programs, dir: "/Users/me/caf", env: [], ssh_env: []}}
  """

  use GenServer

  alias CodingAgentFramework.{Host, Programs, Shell}

  @call 5_000
  @retry 30_000
  # What a job, a service and a copy run on a host: the copy's sync (`rsync` under `flock`,
  # `mkdir`, `sh`), the hold (`dtach`, `env`, `rm`), the records (`ps`, `kill`, `sleep`), the
  # logs (`tail`, `head`, `wc`) and a service's port wait (`nc`).
  @needs [:sh, :mkdir, :rm, :flock, :rsync, :dtach, :env, :ps, :kill, :sleep, :tail, :head] ++
           [:wc, :nc]
  # `--modify-window=-1`, the copy's comparison of times to the nanosecond, came in rsync
  # 3.1.3; its protocol is 31.
  @rsync {3, 1, 3}

  @type mode :: :place | :reach
  @type entry :: %{
          programs: Programs.t(),
          dir: String.t(),
          env: [{String.t(), String.t()}],
          ssh_env: [{String.t(), String.t()}]
        }

  @doc """
  The programs work needs on `host`: one list for every kind of work, with `systemd_run` on a
  host whose `scope` is `:systemd_user`.

      iex> host = CodingAgentFramework.Host.ssh("mac", "/bin/ssh", "mac", "/bin/kill")
      iex> :dtach in CodingAgentFramework.Hosts.needs(host)
      true
  """
  @spec needs(Host.t()) :: [Programs.name()]
  def needs(%Host{scope: :systemd_user}), do: @needs ++ [:systemd_run]
  def needs(%Host{}), do: @needs

  @doc """
  Starts the part. Options: `:hosts`, each host's name to `%{host: host, dir: dir}`, `host`
  reached over ssh (`CodingAgentFramework.Host.ssh/5`) and `dir` its framework directory, and
  optionally `env`, the environment every program held there runs in before its own, and
  `ssh_env`, the environment a forward's ssh runs in; `:retry` (ms).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The host `name` as work reads it, or why new work cannot go there. `:place` always finds the
  host's programs, bounded by `timeout`; `:reach` takes the ones kept (see the module doc).
  """
  @spec reach(GenServer.server(), String.t(), mode, pos_integer) ::
          {:ok, entry} | {:refused, term} | {:unknown, term}
  def reach(hosts, name, mode, timeout) when mode in [:place, :reach] do
    with {:ok, %{decl: decl, kept: kept}} <- call(hosts, {:get, name}) do
      case {mode, kept} do
        {:reach, %{state: :ready, entry: entry}} -> {:ok, entry}
        {:reach, %{due: false} = kept} -> from_kept(name, kept)
        _ -> find(hosts, name, decl, kept, timeout)
      end
    end
  end

  @doc """
  Whether new work may be sent to host `name`, from what is kept alone, with no ssh (F-304):
  `{:ok, state}` (`:unknown` or `:ready`) when a placement there is worth a find, or the kept
  refusal (`{:refused, {:host_away, name}}`, `{:refused, {:no_program, name, names}}`, …) while
  the host is held away or lacking. A held host whose `:retry` is due reads `{:ok, :unknown}`,
  so the next placement finds it again and it joins. `{:refused, {:no_host, name}}` for a host
  not declared; `{:unknown, reason}` when the part does not answer.
  """
  @spec held(GenServer.server(), String.t()) ::
          {:ok, :unknown | :ready} | {:refused, term} | {:unknown, term}
  def held(hosts, name) do
    with {:ok, %{kept: kept}} <- call(hosts, {:get, name}) do
      case kept do
        %{state: :ready} -> {:ok, :ready}
        %{due: false, answer: {:refused, _} = refused} -> refused
        _ -> {:ok, :unknown}
      end
    end
  end

  @doc """
  What is kept of each host: its state (`:unknown`, `:ready`, `:away` or `:lacking`), the
  answer a placement gave, and when, for a view or a test.
  """
  @spec states(GenServer.server()) :: %{String.t() => map} | {:unknown, term}
  def states(hosts), do: call(hosts, :states)

  # The programs are looked up on the PATH the entry's `env` gives them, when it names one, since
  # that is the PATH they run with there (F-291); ssh's own PATH can lack it (a Mac's Homebrew).
  defp find_opts(decl, timeout) do
    case List.keyfind(Map.get(decl, :env, []), "PATH", 0) do
      {"PATH", path} -> [timeout: timeout, path: path]
      nil -> [timeout: timeout]
    end
  end

  defp from_kept(name, %{state: :away}), do: {:unknown, {:host_away, name}}
  defp from_kept(_name, %{answer: answer}), do: answer

  defp find(hosts, name, decl, kept, timeout) do
    begun = mono()

    answer =
      case Programs.find(decl.host, needs(decl.host), find_opts(decl, timeout)) do
        {:ok, programs} -> rsync(name, programs, decl, kept, timeout)
        {:refused, {:not_found, missing}} -> {:refused, {:no_program, name, missing}}
        _no_answer -> {:refused, {:host_away, name}}
      end

    GenServer.cast(hosts, {:found, name, begun, answer})
    answer
  end

  # The rsync a ready host was found with was checked then: only a new one is asked its version.
  defp rsync(_name, %{paths: %{rsync: path}} = programs, decl, kept, _timeout)
       when is_map_key(kept, :entry) and kept.entry.programs.paths.rsync == path,
       do: {:ok, entry(decl, programs)}

  defp rsync(name, programs, decl, _kept, timeout) do
    case Shell.run(programs.host, programs.paths.rsync, ["--version"], timeout: timeout) do
      {:ok, %{status: 0, output: out}} ->
        line = out |> String.split("\n") |> hd()

        if version(line) >= @rsync,
          do: {:ok, entry(decl, programs)},
          else: {:refused, {:old_rsync, name, line}}

      _no_answer ->
        {:refused, {:host_away, name}}
    end
  end

  defp entry(decl, programs) do
    %{
      programs: programs,
      dir: decl.dir,
      env: Map.get(decl, :env, []),
      ssh_env: Map.get(decl, :ssh_env, [])
    }
  end

  # `rsync  version 3.2.7  protocol version 31`; any other line reads as no version.
  defp version(line) do
    case Regex.run(~r/\Arsync\s+version\s+v?(\d+)\.(\d+)\.(\d+)/, line) do
      [_ | parts] -> parts |> Enum.map(&String.to_integer/1) |> List.to_tuple()
      nil -> {0, 0, 0}
    end
  end

  defp call(hosts, request) do
    GenServer.call(hosts, request, @call)
  catch
    :exit, reason -> {:unknown, {:hosts, reason}}
  end

  defp mono, do: System.monotonic_time(:millisecond)

  @impl true
  def init(opts) do
    {:ok,
     %{decls: Keyword.fetch!(opts, :hosts), retry: Keyword.get(opts, :retry, @retry), kept: %{}}}
  end

  @impl true
  def handle_call({:get, name}, _from, s) do
    case Map.fetch(s.decls, name) do
      {:ok, decl} ->
        kept =
          with %{at: at} = kept <- Map.get(s.kept, name, :none),
               do: Map.put(kept, :due, mono() >= at + s.retry)

        {:reply, {:ok, %{decl: decl, kept: kept}}, s}

      :error ->
        {:reply, {:refused, {:no_host, name}}, s}
    end
  end

  def handle_call(:states, _from, s), do: {:reply, s.kept, s}

  @impl true
  # A find that began before the one kept answers what the host was, not what it is.
  def handle_cast({:found, name, begun, answer}, s) do
    case Map.get(s.kept, name) do
      %{at: at} when at > begun -> {:noreply, s}
      _ -> {:noreply, put_in(s.kept[name], kept(answer, begun))}
    end
  end

  defp kept({:ok, entry}, at), do: %{state: :ready, entry: entry, answer: :ok, at: at}
  defp kept({:refused, {:host_away, _}} = a, at), do: %{state: :away, answer: a, at: at}
  defp kept(refused, at), do: %{state: :lacking, answer: refused, at: at}
end
