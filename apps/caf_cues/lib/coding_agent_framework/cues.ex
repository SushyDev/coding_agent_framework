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
  """

  use GenServer

  require Logger

  @type declaration :: %{topics: :all | [String.t()], cue: (pid, map -> term)}

  @doc """
  Starts it. Option: `parts:`, a keyword list (or map) of each part's key to its declaration.
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
    {:ok, %{parts: parts, pids: %{}}}
  end

  @impl true
  def handle_cast({:started, key, pid}, s), do: {:noreply, put_in(s.pids[key], pid)}

  def handle_cast({:cue, %{topic: topic} = cue}, s) when is_binary(topic) do
    for key <- routes(s.parts, topic), pid = s.pids[key], do: hand(s, key, pid, cue)
    {:noreply, s}
  end

  def handle_cast({:cue, _not_a_cue}, s), do: {:noreply, s}

  defp hand(s, key, pid, cue) do
    {^key, part} = List.keyfind(s.parts, key, 0)
    part.cue.(pid, cue)
  catch
    kind, reason ->
      Logger.warning("caf: the cue of #{inspect(key)} raised: #{inspect({kind, reason})}")
  end
end
