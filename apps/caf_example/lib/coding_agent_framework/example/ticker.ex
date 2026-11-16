defmodule CodingAgentFramework.Example.Ticker do
  @moduledoc """
  Calls `tick`, a function of no arguments, every `interval` ms, in its own process. The example
  app ticks the parts that read only when asked (`Stream`, `Transcripts`) and the settles of
  `Jobs` and `Services`; what each tick's calls answer is in their tables, not here.

      {:ok, _} = Ticker.start_link(interval: 2_000, tick: fn -> Stream.read(stream) end)
  """

  use GenServer

  @doc "Starts the ticker. Options: `interval:` (ms) and `tick:`."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    s = %{tick: Keyword.fetch!(opts, :tick), interval: Keyword.fetch!(opts, :interval)}
    Process.send_after(self(), :tick, s.interval)
    {:ok, s}
  end

  @impl true
  def handle_info(:tick, s) do
    s.tick.()
    Process.send_after(self(), :tick, s.interval)
    {:noreply, s}
  end
end
