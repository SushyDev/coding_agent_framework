defmodule CodingAgentFramework.TmuxSampler do
  @moduledoc """
  Samples one host's tmux server and held sockets, and writes their join
  (`CodingAgentFramework.TmuxSampler.Join`) to `CodingAgentFramework.TmuxSampler.Table`, which
  it alone writes (`model/tla/Agent.tla`, `SamplerReads`).

  The caller's supervision tree starts one per host, with no name, given the host's `Tmux`
  server and its `Holder`. A sample reads the server's panes (`Tmux.list_panes/1`), then the
  held sockets (`Holder.list/1`): reading the sockets too is what shows a held agent whose
  viewer is gone, since it has no pane left to read. A held agent with no viewer is
  `:unviewed`; with no server, `:no_server`. The two reads are not one instant: a viewer that
  closes between them shows on the next sample.

  A sample whose reads fail answers `{:unknown, reason}`, writes no row, and records the failure
  beside the last good sample, whose rows and age stay. Before the first good sample, `rows/2`
  answers `:unread`. It acts on nothing: reopening a lost viewer is `Recoveries`' job.

  After a sample that changed rows, the first one, or a failure, it calls `notify` with
  `%{topic: "tmux:<host>:<server>", ids: ids}`, as `Registry` does. `notify` must not raise. `Cues`
  hands the same cue to `Sessions`, which settles its rows again when a held socket goes away or
  goes stale (`model/tla/Start.tla`, `DtachExits`), and to `Recoveries`.

      iex> {:ok, pid} = CodingAgentFramework.Tmux.Fake.start_link(key: {"test", "fake"})
      iex> server = CodingAgentFramework.Tmux.Fake.new(pid, {"test", "fake"})
      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> {:ok, holder} = CodingAgentFramework.Holder.new(CodingAgentFramework.TestHost.programs(), dir)
      iex> {:ok, s} = CodingAgentFramework.TmuxSampler.start_link(
      ...>   server: server, holder: holder, db: Path.join(dir, "s.db"))
      iex> CodingAgentFramework.TmuxSampler.rows(s)
      :unread
      iex> {:ok, %{up: false, held: 0}} = CodingAgentFramework.TmuxSampler.sample(s)
      iex> {:ok, %{up: false, rows: []}} = CodingAgentFramework.TmuxSampler.rows(s)
  """

  use GenServer

  alias CodingAgentFramework.{Holder, Reader, Tmux}
  alias CodingAgentFramework.TmuxSampler.{Join, Table}

  @timeout 10_000

  @doc """
  Starts a sampler. Options: `server:` (a `Tmux` server), `holder:` (a `Holder` on the same
  host), `db:` (this instance's SQLite path), and optionally `notify:` (a function of one cue),
  `interval:` (ms between samples; without it, samples happen only on `sample/2`), and `clock:`
  (a function answering the time in ms, by default the system's). It fails to start with
  `{:host_mismatch, server_host, holder_host}`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Samples now. Returns `{:ok, %{up, generation, held, unviewed, viewers, problems, ids}}`, where
  `ids` are the rows written, or `{:unknown, reason}` when a read failed.
  """
  @spec sample(GenServer.server(), keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def sample(sampler, opts \\ []), do: call(sampler, :sample, opts)

  @doc """
  The last good sample: `{:ok, %{read_at, age, up, generation, failed_at, problem, rows}}`, or
  `:unread` before one. `read_at` is when its reads began, and `age` is ms since then;
  `failed_at` is set when a newer sample failed.
  """
  @spec rows(GenServer.server(), keyword) ::
          :unread | {:ok, map} | {:refused, term} | {:unknown, term}
  def rows(sampler, opts \\ []), do: call(sampler, :rows, opts)

  defp call(sampler, request, opts),
    do: Reader.call(sampler, request, Keyword.get(opts, :timeout, 2 * @timeout), :no_sampler)

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :server)
    %Holder{} = holder = Keyword.fetch!(opts, :holder)
    {host, name} = Tmux.key(server)

    with :ok <- same_host(host, holder.host.name),
         {:ok, db} <- Table.open(Keyword.fetch!(opts, :db)) do
      {last, cache} =
        case Table.rows(db, host, name) do
          :unread -> {nil, %{}}
          {:ok, read} -> {read, Map.new(read.rows, &{&1.key, Map.take(&1, Join.columns())})}
        end

      state = %{
        server: server,
        holder: holder,
        host: host,
        name: name,
        db: db,
        last: last,
        cache: cache,
        failing: is_integer((Table.last_read(db, host, name) || %{})[:failed_at]),
        clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end)
      }

      {:ok, Map.merge(state, Reader.loop(opts))}
    else
      {:refused, reason} -> {:stop, reason}
    end
  end

  defp same_host(host, host), do: :ok
  defp same_host(a, b), do: {:refused, {:host_mismatch, a, b}}

  @impl true
  def handle_call(:sample, _from, state) do
    {reply, state} = sample_now(state)
    {:reply, reply, state}
  end

  def handle_call(:rows, _from, state) do
    reply =
      with {:ok, read} <- Table.rows(state.db, state.host, state.name),
           do: {:ok, Map.put(read, :age, max(state.clock.() - read.read_at, 0))}

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, Reader.tick(state, &sample_now/1)}

  defp sample_now(state) do
    # Stamped before the reads: a sample stamped after an act was read after it (`Recoveries`).
    at = state.clock.()

    panes =
      case Tmux.list_panes(state.server) do
        {:refused, :no_server} -> :no_server
        other -> other
      end

    case {panes, Holder.list(state.holder)} do
      {{:ok, _} = panes, {:ok, held}} -> write(state, Join.join(panes, held, state.last), at)
      {:no_server, {:ok, held}} -> write(state, Join.join(:no_server, held, state.last), at)
      {{:ok, _}, failure} -> fail(state, {:holder, failure})
      {:no_server, failure} -> fail(state, {:holder, failure})
      {failure, _} -> fail(state, {:tmux, failure})
    end
  end

  defp fail(state, reason) do
    :ok = Table.failed(state.db, state.host, state.name, state.clock.(), reason)
    state.notify.(%{topic: topic(state), ids: []})
    {{:unknown, reason}, %{state | failing: true}}
  end

  defp write(state, join, at) do
    read = Map.put(Map.take(join, [:up, :generation, :start, :ids]), :read_at, at)

    {:ok, %{ids: ids} = result} =
      Table.write(state.db, state.host, state.name, Reader.diff(state.cache, join.rows), read)

    # A good sample after a failed one clears the failure the source shows: that is a change too.
    Reader.cue(state.notify, topic(state), result, state.failing)

    statuses = join.rows |> Map.values() |> Enum.frequencies_by(&{&1.kind, &1.status})
    count = fn kind -> Enum.sum(for {{^kind, _}, n} <- statuses, do: n) end

    summary = %{
      up: join.up,
      generation: join.generation,
      held: count.(:held),
      unviewed: Map.get(statuses, {:held, :unviewed}, 0),
      viewers: count.(:viewer),
      problems: count.(:problem),
      ids: ids
    }

    {{:ok, summary}, %{state | cache: join.rows, last: join, failing: false}}
  end

  defp topic(state), do: "tmux:#{state.host}:#{state.name}"
end
