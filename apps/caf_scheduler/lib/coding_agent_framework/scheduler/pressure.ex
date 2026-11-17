defmodule CodingAgentFramework.Scheduler.Pressure do
  @moduledoc """
  The host's pressure as three states, `:ok`, `:high` and `:severe`, read from the host's own
  signals and never from the load average (`docs/design.md`, "A lease"). A pure module: the
  `Scheduler` reads a sample on its interval and folds it here.

  **Linux** (`source: :psi`): pressure stall information, `<dir>/{cpu,memory,io}`. Each file's
  `some` line (and `full`, for memory and io) carries a cumulative `total` in microseconds; the
  share of a span stalled is the growth of `total` over the span's length. Any `some` share
  above its threshold (`cpu:`, `memory:`, `io:`) asks for `high`; a memory `full` share above
  `full:` asks for `severe`.

  **macOS** (`source: {:level, read}`): no stall times; `read` is a function the embedding app
  gives that answers `{:ok, level}`, the kernel's memory-pressure level as an integer. A level
  at or above `level_severe:` asks for `severe`, at or above `level_high:` for `high`. Heavy
  runs there are bounded by a static slot count, the capacity of their resource.

  **Hysteresis.** `severe` is taken at once. `high` is taken once it was asked for a whole
  `window:` (ms), and a lower state only once it was asked for a whole `window:` too, so one
  quiet sample does not admit work again.

  Every threshold here is a placeholder until it is measured on the workstation: each is an
  option with a default.

      iex> alias CodingAgentFramework.Scheduler.Pressure
      iex> p = Pressure.new(window: 1_000)
      iex> p = Pressure.step(p, {:psi, %{cpu: %{some: 0}, memory: %{some: 0, full: 0}, io: %{some: 0, full: 0}}}, 0)
      iex> p = Pressure.step(p, {:psi, %{cpu: %{some: 900_000}, memory: %{some: 0, full: 0}, io: %{some: 0, full: 0}}}, 1_000)
      iex> p.level
      :ok
      iex> p = Pressure.step(p, {:psi, %{cpu: %{some: 1_800_000}, memory: %{some: 0, full: 0}, io: %{some: 0, full: 0}}}, 2_000)
      iex> p.level
      :high
      iex> Pressure.bars?(:high, :heavy)
      true
  """

  @defaults [
    window: 10_000,
    cpu: 0.25,
    memory: 0.10,
    io: 0.20,
    full: 0.0,
    level_high: 2,
    level_severe: 4
  ]

  @rank %{ok: 0, high: 1, severe: 2}

  @type level :: :ok | :high | :severe
  @type sample :: {:psi, map} | {:level, integer}
  @type t :: %{level: level, at: integer | nil, last: map | nil, toward: {level, integer} | nil}

  @doc "The default thresholds and window: placeholders, measured on the workstation later."
  @spec defaults() :: keyword
  def defaults, do: @defaults

  @doc "A fresh state, `:ok`, with the thresholds in `opts` over the defaults."
  @spec new(keyword) :: map
  def new(opts \\ []),
    do: %{level: :ok, last: nil, at: nil, toward: nil, opts: Keyword.merge(@defaults, opts)}

  @doc """
  Whether `level` bars a new request of `class`: `severe` bars every class but a person's main
  session, which is always admitted; `high` bars a heavy run.

      iex> CodingAgentFramework.Scheduler.Pressure.bars?(:severe, :main)
      false
  """
  @spec bars?(level, atom) :: boolean
  def bars?(:severe, class), do: class != :main
  def bars?(:high, class), do: class == :heavy
  def bars?(:ok, _class), do: false

  @doc "Folds one sample taken at `now` (ms) into the state."
  @spec step(map, sample, integer) :: map
  def step(%{last: nil} = p, {:psi, sample}, now), do: %{p | last: sample, at: now}

  def step(p, {:psi, sample}, now) when now > p.at do
    o = p.opts
    share = fn file, line -> share(p.last, sample, file, line, now - p.at) end

    asked =
      cond do
        share.(:memory, :full) > o[:full] -> :severe
        share.(:cpu, :some) > o[:cpu] -> :high
        share.(:memory, :some) > o[:memory] -> :high
        share.(:io, :some) > o[:io] -> :high
        true -> :ok
      end

    judge(%{p | last: sample, at: now}, asked, now)
  end

  def step(p, {:psi, _sample}, _now), do: p

  def step(p, {:level, n}, now) when is_integer(n) do
    asked =
      cond do
        n >= p.opts[:level_severe] -> :severe
        n >= p.opts[:level_high] -> :high
        true -> :ok
      end

    judge(p, asked, now)
  end

  # Severe at once; any other change once it was asked for a whole window.
  defp judge(p, :severe, _now), do: %{p | level: :severe, toward: nil}
  defp judge(%{level: level} = p, level, _now), do: %{p | toward: nil}

  defp judge(p, asked, now) do
    since =
      case p.toward do
        {^asked, since} -> since
        _ -> now
      end

    if now - since >= p.opts[:window] and @rank[asked] != @rank[p.level],
      do: %{p | level: asked, toward: nil},
      else: %{p | toward: {asked, since}}
  end

  # The share of `span` ms that `total` (µs) grew by; a counter that went back (a reboot) is 0.
  defp share(last, now, file, line, span) do
    with %{^line => a} <- Map.get(last, file),
         %{^line => b} <- Map.get(now, file),
         true <- b >= a do
      (b - a) / (span * 1000)
    else
      _ -> 0.0
    end
  end

  @doc """
  Reads `<dir>/{cpu,memory,io}` once: `{:ok, {:psi, sample}}`, each file's lines by kind with
  their `total`, or `{:unknown, reason}` when a file cannot be read.

      iex> CodingAgentFramework.Scheduler.Pressure.parse("some avg10=0.00 avg60=0.00 avg300=0.00 total=42\\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=7\\n")
      %{some: 42, full: 7}
  """
  @spec psi(String.t()) :: {:ok, sample} | {:unknown, term}
  def psi(dir \\ "/proc/pressure") do
    Enum.reduce_while([:cpu, :memory, :io], {:ok, %{}}, fn file, {:ok, acc} ->
      case File.read(Path.join(dir, Atom.to_string(file))) do
        {:ok, text} -> {:cont, {:ok, Map.put(acc, file, parse(text))}}
        {:error, reason} -> {:halt, {:unknown, {:psi, file, reason}}}
      end
    end)
    |> case do
      {:ok, sample} -> {:ok, {:psi, sample}}
      unknown -> unknown
    end
  end

  @doc "A pressure file's lines: `some` and `full`, each with its `total`."
  @spec parse(String.t()) :: %{optional(:some | :full) => non_neg_integer}
  def parse(text) do
    for line <- String.split(text, "\n", trim: true),
        [kind | fields] = String.split(line),
        kind in ["some", "full"],
        "total=" <> n <- fields,
        {total, ""} <- [Integer.parse(n)],
        into: %{},
        do: {String.to_existing_atom(kind), total}
  end
end
