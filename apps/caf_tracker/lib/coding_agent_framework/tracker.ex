defmodule CodingAgentFramework.Tracker do
  @moduledoc """
  The state views read: the fold (`CodingAgentFramework.Tracker.Fold`) of every reader's rows.

  The caller's supervision tree starts one `Tracker` per instance, with no name, and gives it
  its sources as `{module, opts}` (`CodingAgentFramework.Tracker.Source`), such as
  `{Tracker.RegistrySource, db: path, host: "laptop", account: "work"}`. At start it reads
  every source in full, so a restarted `Tracker` comes back from the tables alone.

  A reader's cue (`cue/2`, which an embedding app wires to the reader's `notify:`) names a topic and
  row ids; the `Tracker` re-reads those rows from the table by id. A cue is never the data, so
  cues may come late, twice, out of order or before their rows. A cue for a source still
  `:unread`, or one with no list of ids, re-reads the whole topic; a cue for an unknown topic,
  or of no known shape, is dropped.

  When rows change it calls `notify` with `%{topic: "tracker:<host>:<account>", changed: keys}`,
  where `keys` are `{source_topic, id}` (or `{source_topic, :source}` when a source's status
  changed). Per topic it calls at most once a second by the `clock:` it is given, and gathers
  what changed in between into the next call. `notify` must not raise.

      iex> dir = CodingAgentFramework.TestHost.test_dir()
      iex> me = self()
      iex> {:ok, tracker} = CodingAgentFramework.Tracker.start_link(
      ...>   sources: [{CodingAgentFramework.Tracker.RegistrySource,
      ...>              db: Path.join(dir, "r.db"), host: "laptop", account: "work"}],
      ...>   notify: &send(me, &1))
      iex> {:ok, view} = CodingAgentFramework.Tracker.view(tracker)
      iex> view[{"laptop", "work"}].age
      :unread
      iex> CodingAgentFramework.Tracker.behind(tracker, 60_000)
      {:ok, [{"registry:laptop:work", :unread}]}
  """

  use GenServer

  alias CodingAgentFramework.Tracker.Fold

  @second 1_000
  @timeout 5_000

  @doc """
  Starts a `Tracker`. Options: `sources:` (a list of `{module, opts}`), and optionally
  `notify:` (a function of one cue), `clock:` (a function answering ms of wall time, default
  `System.os_time(:millisecond)`; ages and the once-a-second limit are measured by it) and
  `timer: false` (no timer sends a held cue; the caller calls `flush/2`, as tests do).
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Hands the `Tracker` a reader's cue. Never raises and never waits."
  @spec cue(GenServer.server(), term) :: :ok
  def cue(tracker, cue), do: GenServer.cast(tracker, {:cue, cue})

  @doc "The state per `{host, account}` (`Fold.view/2`), with each source's newest read re-read."
  @spec view(GenServer.server(), keyword) :: {:ok, map} | {:refused, term} | {:unknown, term}
  def view(tracker, opts \\ []), do: call(tracker, :view, opts)

  @doc "The sources `:unread`, or whose newest read is older than `bound` ms (`Fold.behind/3`)."
  @spec behind(GenServer.server(), non_neg_integer, keyword) ::
          {:ok, list} | {:refused, term} | {:unknown, term}
  def behind(tracker, bound, opts \\ []), do: call(tracker, {:behind, bound}, opts)

  @doc "Sends every held cue whose second has passed by the clock."
  @spec flush(GenServer.server(), keyword) :: :ok | {:refused, term} | {:unknown, term}
  def flush(tracker, opts \\ []), do: call(tracker, :flush, opts)

  defp call(tracker, request, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    try do
      GenServer.call(tracker, request, timeout)
    catch
      :exit, {:noproc, _} -> {:refused, :no_tracker}
      :exit, {:timeout, _} -> {:unknown, {:timeout, timeout}}
      :exit, {reason, _} -> {:unknown, {:exit, reason}}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      sources: %{},
      fold: Fold.new(),
      notify: Keyword.get(opts, :notify, fn _ -> :ok end),
      clock: Keyword.get(opts, :clock, fn -> System.os_time(:millisecond) end),
      timer: Keyword.get(opts, :timer, true),
      last: %{},
      held: %{},
      armed: MapSet.new()
    }

    state = Enum.reduce(Keyword.get(opts, :sources, []), state, &add_source/2)
    {:ok, Enum.reduce(Map.keys(state.sources), state, &reload(&2, &1, :all))}
  end

  # A source that cannot open is still shown, with its problem, rather than stopping the boot.
  defp add_source({module, opts}, state) do
    describe = module.describe(opts)
    fold = Fold.source(state.fold, describe.topic, describe.scope, describe.kind)

    case safe(fn -> module.open(opts) end) do
      {:ok, source} ->
        %{state | fold: fold, sources: Map.put(state.sources, describe.topic, {module, source})}

      other ->
        {fold, _} = Fold.read(fold, describe.topic, [], {:unknown, other})
        %{state | fold: fold}
    end
  end

  @impl true
  def handle_cast({:cue, %{topic: topic, ids: ids}}, state) when is_list(ids) do
    if Enum.all?(ids, &is_integer/1),
      do: {:noreply, changed(state, topic, ids)},
      else: {:noreply, changed(state, topic, :all)}
  end

  def handle_cast({:cue, %{topic: topic}}, state), do: {:noreply, changed(state, topic, :all)}
  def handle_cast({:cue, _}, state), do: {:noreply, state}

  @impl true
  def handle_call(:view, _from, state) do
    state = refresh(state)
    {:reply, {:ok, Fold.view(state.fold, state.clock.())}, state}
  end

  def handle_call({:behind, bound}, _from, state) do
    state = refresh(state)
    {:reply, {:ok, Fold.behind(state.fold, state.clock.(), bound)}, state}
  end

  def handle_call(:flush, _from, state),
    do: {:reply, :ok, Enum.reduce(Map.keys(state.held), state, &send_due(&2, &1))}

  @impl true
  def handle_info({:flush, topic}, state),
    do: {:noreply, send_due(%{state | armed: MapSet.delete(state.armed, topic)}, topic)}

  # Each source's newest read, which a read that changed no row does not cue.
  defp refresh(state), do: Enum.reduce(Map.keys(state.sources), state, &changed(&2, &1, []))

  defp changed(state, topic, ids) do
    ids = if Fold.status(state.fold, topic) == :unread, do: :all, else: ids
    reload(state, topic, ids)
  end

  defp reload(state, topic, ids) do
    case state.sources do
      %{^topic => {module, source}} ->
        {fold, changed} =
          Fold.read(state.fold, topic, ids, safe(fn -> module.read(source, ids) end))

        hold(%{state | fold: fold}, topic, changed)

      _ ->
        state
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:unknown, {:raised, Exception.message(e)}}
  end

  defp hold(state, _topic, []), do: state

  defp hold(state, topic, changed) do
    {host, account} = state.fold.sources[topic].scope
    view = "tracker:#{host}:#{account}"

    held =
      Map.update(state.held, view, MapSet.new(changed), &MapSet.union(&1, MapSet.new(changed)))

    send_due(%{state | held: held}, view)
  end

  defp send_due(state, view) do
    now = state.clock.()
    last = state.last[view]

    cond do
      not Map.has_key?(state.held, view) ->
        state

      is_nil(last) or now - last >= @second ->
        state.notify.(%{topic: view, changed: Enum.sort(state.held[view])})
        %{state | held: Map.delete(state.held, view), last: Map.put(state.last, view, now)}

      state.timer and not MapSet.member?(state.armed, view) ->
        Process.send_after(self(), {:flush, view}, @second - (now - last))
        %{state | armed: MapSet.put(state.armed, view)}

      true ->
        state
    end
  end
end
