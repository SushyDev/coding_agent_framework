defmodule CodingAgentFramework.Cues do
  @moduledoc """
  One per instance: it hands each cue to every part that declared the cue's topic. Its only
  job is routing; the order in which the system settles ("The parts" in `docs/design.md`) is
  the sum of the parts' declarations, not the app's.

  **A declaration** is data a part gives (its `reads/0`): `%{topics: patterns, cue: fun}`,
  where `fun` takes the part's process and the cue (the part's own `cue/2`), and `patterns`
  is `:all` or a list of topic patterns. A pattern is words joined by `:`, `*` standing for any
  one word; it matches a topic whose words begin with its words. So `"stream"` matches
  `"stream:laptop"`, and `"intake:*:*:waiters"` matches `"intake:laptop:work:waiters"` but not
  `"intake:laptop:work"`.

  **The parts' processes.** The embedding app's tree says `started/3` with each part's process
  as it starts it, and a restart's new process replaces the last one. A part not started yet,
  or not started at all, misses the cue: every part reads its whole table when it starts. A
  cue for no declared topic goes nowhere. Each part's `cue` must answer at once and not raise;
  one that raises is logged, and the other parts still get the cue.

      {:ok, cues} = Cues.start_link(parts: [sessions: Sessions.reads(), tracker: Tracker.reads()])
      Cues.started(cues, :sessions, sessions)
      Cues.cue(cues, %{topic: "registry:laptop:work", ids: [3]})
      #=> :ok

  A part's `notify:` is then `&Cues.cue(cues, &1)`. Nothing here keeps a cue: a cue is a hint
  to read rows again, never the data.

  **The app's subscribers.** A process outside the parts, the app's own (a view, a sync of its
  own rows), gets the cues of the topics it names with `subscribe/3`: each as a message
  `{:caf_cue, cue}`, by a plain `send`, after the parts got theirs. A subscriber may name only
  topics the parts declare (`topics/1`), as patterns of the same shape. It is monitored and
  removed when it exits. The subscriptions are rows in an ETS table its starter may own
  (`subscriptions:`), so a `Cues` a restart replaced re-adopts them, and a subscriber that
  exited meanwhile is removed then.

      {:ok, ref} = Cues.subscribe(cues, self(), ["sessions"])
      Cues.cue(cues, %{topic: "sessions:ws", ids: [4]})
      #=> the subscriber gets {:caf_cue, %{topic: "sessions:ws", ids: [4]}}
  """

  use GenServer

  require Logger

  @type declaration :: %{topics: :all | [String.t()], cue: (pid, map -> term)}

  @timeout 5_000

  @doc """
  Starts it. Options: `parts:`, a keyword list (or map) of each part's key to its declaration;
  `subscriptions:`, a public ETS set its starter owns, which keeps the subscriptions across a
  restart of `Cues` (without it, one of its own); and `registry: {name, key}`, a `Registry` it
  registers itself in under `key`, so the app finds it by its instance's name.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Hands it a cue to route. Answers `:ok` at once, also when `cues` is nil."
  @spec cue(GenServer.server() | nil, term) :: :ok
  def cue(nil, _cue), do: :ok
  def cue(cues, cue), do: GenServer.cast(cues, {:cue, cue})

  @doc """
  Says that `pid` is part `key`'s process from now on; a key no declaration names is kept and
  never handed a cue. Answers `:ok` at once, also when `cues` is nil.
  """
  @spec started(GenServer.server() | nil, term, pid) :: :ok
  def started(nil, _key, _pid), do: :ok
  def started(cues, key, pid) when is_pid(pid), do: GenServer.cast(cues, {:started, key, pid})

  @doc """
  Sends `pid` each later cue whose topic one of `topics` matches, as `{:caf_cue, cue}`, until
  `pid` exits or `unsubscribe/2`. Each topic is a pattern as a declaration's are, so
  `"sessions"` matches `"sessions:ws"`; a trailing `:` is the same as none. Answers `{:ok,
  ref}`, `{:refused, {:bad, :topics}}` when `topics` is not a list of such patterns, or
  `{:refused, {:undeclared, topic}}` for the first topic no part declares (`topics/1`), or
  `{:unknown, reason}` when `Cues` did not answer.
  """
  @spec subscribe(GenServer.server(), pid, [String.t()]) ::
          {:ok, reference} | {:refused, term} | {:unknown, term}
  def subscribe(cues, pid, topics) when is_pid(pid), do: call(cues, {:subscribe, pid, topics})

  @doc """
  Ends the subscription `ref`. Answers `:ok`, `{:refused, :no_subscription}` for a ref it does
  not hold, or `{:unknown, reason}` when `Cues` did not answer.
  """
  @spec unsubscribe(GenServer.server(), reference) :: :ok | {:refused, term} | {:unknown, term}
  def unsubscribe(cues, ref) when is_reference(ref), do: call(cues, {:unsubscribe, ref})

  @doc "The subscriptions it holds now, as `{ref, pid, topics}`."
  @spec subscriptions(GenServer.server()) :: {:ok, list} | {:unknown, term}
  def subscriptions(cues), do: call(cues, :subscriptions)

  defp call(cues, request) do
    GenServer.call(cues, request, @timeout)
  catch
    :exit, reason -> {:unknown, {:no_answer, reason}}
  end

  @doc ~S"""
  The topics the parts declare, each once and in order: the patterns an app may subscribe to.
  A part that reads every topic (`:all`) adds none.

      iex> parts = [a: %{topics: ["stream", "intake:*:*:waiters"], cue: nil},
      ...>          b: %{topics: :all, cue: nil}, c: %{topics: ["stream", "registry"], cue: nil}]
      iex> CodingAgentFramework.Cues.topics(parts)
      ["intake:*:*:waiters", "registry", "stream"]
  """
  @spec topics(Enumerable.t()) :: [String.t()]
  def topics(parts) do
    parts
    |> Enum.flat_map(fn {_key, %{topics: t}} -> if t == :all, do: [], else: t end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc ~S"""
  `topics` checked against the parts' declarations, each with its trailing `:` cut: a topic is
  declared when a declared pattern matches it.

      iex> parts = [a: %{topics: ["sessions", "intake:*:*:waiters"], cue: nil}]
      iex> CodingAgentFramework.Cues.check(parts, ["sessions:", "intake:ws:work:waiters"])
      {:ok, ["sessions", "intake:ws:work:waiters"]}
      iex> CodingAgentFramework.Cues.check(parts, ["acts"])
      {:refused, {:undeclared, "acts"}}
      iex> CodingAgentFramework.Cues.check(parts, [])
      {:refused, {:bad, :topics}}
  """
  @spec check(Enumerable.t(), term) :: {:ok, [String.t()]} | {:refused, term}
  def check(parts, [_ | _] = topics) do
    declared = topics(parts)

    Enum.reduce_while(topics, {:ok, []}, fn topic, {:ok, acc} ->
      cond do
        not topic?(topic) -> {:halt, {:refused, {:bad, :topics}}}
        reads?(declared, words(topic)) -> {:cont, {:ok, [cut(topic) | acc]}}
        true -> {:halt, {:refused, {:undeclared, topic}}}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      refused -> refused
    end)
  end

  def check(_parts, _topics), do: {:refused, {:bad, :topics}}

  defp topic?(topic), do: is_binary(topic) and Enum.all?(words(topic), &(&1 != ""))
  defp words(topic), do: String.split(cut(topic), ":")
  defp cut(topic), do: String.replace_suffix(topic, ":", "")

  @doc ~S"""
  The keys of the parts a cue of `topic` reaches, in the declarations' order.

      iex> parts = [a: %{topics: ["stream", "intake:*:*:waiters"], cue: nil},
      ...>          b: %{topics: :all, cue: nil}, c: %{topics: ["registry"], cue: nil}]
      iex> CodingAgentFramework.Cues.routes(parts, "stream:laptop")
      [:a, :b]
      iex> CodingAgentFramework.Cues.routes(parts, "intake:laptop:work:waiters")
      [:a, :b]
      iex> CodingAgentFramework.Cues.routes(parts, "intake:laptop:work")
      [:b]
  """
  @spec routes(Enumerable.t(), String.t()) :: [term]
  def routes(parts, topic) when is_binary(topic) do
    words = String.split(topic, ":")
    for {key, %{topics: patterns}} <- parts, reads?(patterns, words), do: key
  end

  defp reads?(:all, _words), do: true
  defp reads?(patterns, words), do: Enum.any?(patterns, &words?(String.split(&1, ":"), words))

  defp words?([], _words), do: true
  defp words?(["*" | pattern], [_ | words]), do: words?(pattern, words)
  defp words?([word | pattern], [word | words]), do: words?(pattern, words)
  defp words?(_pattern, _words), do: false

  @impl true
  def init(opts) do
    parts = Keyword.fetch!(opts, :parts) |> Enum.to_list()
    subs = Keyword.get_lazy(opts, :subscriptions, fn -> :ets.new(__MODULE__, [:set]) end)

    with {name, key} <- Keyword.get(opts, :registry),
         do: {:ok, _} = Registry.register(name, key, nil)

    # Re-adopted: each subscriber monitored again; one that exited meanwhile is removed by
    # its `:DOWN`, which comes at once.
    watched =
      for {ref, pid, _topics} <- :ets.tab2list(subs),
          into: %{},
          do: {Process.monitor(pid), ref}

    {:ok, %{parts: parts, pids: %{}, subs: subs, watched: watched}}
  end

  @impl true
  def handle_call({:subscribe, pid, topics}, _from, s) do
    case check(s.parts, topics) do
      {:ok, topics} ->
        ref = make_ref()
        true = :ets.insert(s.subs, {ref, pid, topics})
        {:reply, {:ok, ref}, put_in(s.watched[Process.monitor(pid)], ref)}

      refused ->
        {:reply, refused, s}
    end
  end

  def handle_call({:unsubscribe, ref}, _from, s) do
    case Enum.find(s.watched, fn {_mon, r} -> r == ref end) do
      {mon, ^ref} ->
        Process.demonitor(mon, [:flush])
        true = :ets.delete(s.subs, ref)
        {:reply, :ok, %{s | watched: Map.delete(s.watched, mon)}}

      nil ->
        {:reply, {:refused, :no_subscription}, s}
    end
  end

  def handle_call(:subscriptions, _from, s), do: {:reply, {:ok, :ets.tab2list(s.subs)}, s}

  @impl true
  def handle_cast({:started, key, pid}, s), do: {:noreply, put_in(s.pids[key], pid)}

  def handle_cast({:cue, %{topic: topic} = cue}, s) when is_binary(topic) do
    for key <- routes(s.parts, topic), pid = s.pids[key], do: hand(s, key, pid, cue)
    words = String.split(topic, ":")

    # A plain send: a subscriber that is slow, or gone, costs this nothing.
    :ets.foldl(
      fn {_ref, pid, topics}, :ok ->
        if reads?(topics, words), do: send(pid, {:caf_cue, cue}), else: :ok
      end,
      :ok,
      s.subs
    )

    {:noreply, s}
  end

  def handle_cast({:cue, _not_a_cue}, s), do: {:noreply, s}

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, _reason}, s) do
    {ref, watched} = Map.pop(s.watched, mon)
    if ref, do: :ets.delete(s.subs, ref)
    {:noreply, %{s | watched: watched}}
  end

  defp hand(s, key, pid, cue) do
    {^key, part} = List.keyfind(s.parts, key, 0)
    part.cue.(pid, cue)
  catch
    kind, reason ->
      Logger.warning("caf: the cue of #{inspect(key)} raised: #{inspect({kind, reason})}")
  end
end
