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
  runs there are bounded by a static slot count, the capacity of their resource. The app's
  default `read` runs `sysctl -n kern.memorystatus_vm_pressure_level`, read by `sysctl/1`:
  1 (normal) is `ok`, 2 (warn) `high`, 4 (critical) `severe`; any other value is unknown, never
  `ok`.

  **Hysteresis.** `severe` is taken at once. `high` is taken once each sample of a whole
  `window:` (ms) asked for it. A lower state is taken once no sample of a whole `window:` asked
  for the current state or above, and it is the highest state any of them asked: one quiet
  sample does not admit work again, and samples that flip between `ok` and `high` take
  `severe` down to `high`.

  **The reading.** `reading` holds what set the level: the file and line read, its `share` of
  the span (or the macOS level), the `threshold` it passed and the sample's time `at`, as
  `%{file: :memory, line: :full, share: 0.02, threshold: 0.01, at: ms}`. A `pressure` refusal
  carries it. At `ok` it is nil.

  **The shares** (F-300). `shares` holds every line the last span read, at every level, `ok`
  included: each is a reading with the level it `asks` for once its share passes its
  threshold, in the order they are checked: memory `full` (`severe`), then the `some` lines of
  cpu, memory and io (`high`). On Linux a share is the growth of the line's `total` over the
  span, the number its threshold is held to, not the kernel's own `avg10`. On macOS there are
  no shares, only the kernel's level, held to `level_severe:` and to `level_high:`: two entries
  of `file: :level`. It is nil until a span has been read, since a first sample only starts
  one.

      [%{file: :memory, line: :full, share: 0.0, threshold: 0.01, asks: :severe, at: ms},
       %{file: :cpu, line: :some, share: 0.03, threshold: 0.25, asks: :high, at: ms}, ...]

  Each threshold is an option with a default. Memory `full`'s, 1% of the span, is measured
  (`docs/build-notes/F-273.md`): on the Linux workstation it grew by under 0.001% of any 2 s
  span at rest and under the test suite, so 1% reads only a real stall. The others are
  placeholders until they are measured.

      iex> alias CodingAgentFramework.Scheduler.Pressure
      iex> p = Pressure.new(window: 1_000)
      iex> p = Pressure.step(p, {:psi, %{cpu: %{some: 0}, memory: %{some: 0, full: 0}, io: %{some: 0, full: 0}}}, 0)
      iex> p = Pressure.step(p, {:psi, %{cpu: %{some: 900_000}, memory: %{some: 0, full: 0}, io: %{some: 0, full: 0}}}, 1_000)
      iex> p.level
      :ok
      iex> for s <- p.shares, do: {s.file, s.line, s.share, s.threshold}
      [{:memory, :full, 0.0, 0.01}, {:cpu, :some, 0.9, 0.25}, {:memory, :some, 0.0, 0.1}, {:io, :some, 0.0, 0.2}]
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
    full: 0.01,
    level_high: 2,
    level_severe: 4
  ]

  @rank %{ok: 0, high: 1, severe: 2}

  @type level :: :ok | :high | :severe
  @type sample :: {:psi, map} | {:level, integer}
  @type reading :: %{file: atom, line: atom, share: number, threshold: number, at: integer}
  @type share :: %{
          file: atom,
          line: atom,
          share: number,
          threshold: number,
          asks: :high | :severe,
          at: integer
        }
  @type t :: %{
          level: level,
          reading: reading | nil,
          shares: [share] | nil,
          at: integer | nil,
          last: map | nil,
          toward: {level, integer, reading | nil} | nil,
          opts: keyword
        }

  @doc "The default thresholds and window (see the module's doc for which are measured)."
  @spec defaults() :: keyword
  def defaults, do: @defaults

  @doc "A fresh state, `:ok`, with the thresholds in `opts` over the defaults."
  @spec new(keyword) :: map
  def new(opts \\ []) do
    %{
      level: :ok,
      reading: nil,
      shares: nil,
      last: nil,
      at: nil,
      toward: nil,
      opts: Keyword.merge(@defaults, opts)
    }
  end

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

  @doc """
  Folds one sample taken at `now` (ms) into the state. The first sample, and one taken at or
  before the last (a clock set back), only start the next span: a span is never shorter than
  the time between two samples, so no growth is divided by a span it did not happen in.
  """
  @spec step(map, sample, integer) :: map
  def step(%{last: nil} = p, {:psi, sample}, now), do: %{p | last: sample, at: now}

  def step(p, {:psi, sample}, now) when now > p.at do
    o = p.opts
    span = now - p.at

    read = fn file, line, threshold ->
      read(p.last, sample, file, line, span, o[threshold], now)
    end

    checks = [
      {:severe, read.(:memory, :full, :full)},
      {:high, read.(:cpu, :some, :cpu)},
      {:high, read.(:memory, :some, :memory)},
      {:high, read.(:io, :some, :io)}
    ]

    {asked, reading} =
      Enum.find(checks, {:ok, nil}, fn {_, r} -> r.share > r.threshold end)

    judge(%{p | last: sample, at: now, shares: shares(checks)}, asked, reading, now)
  end

  def step(p, {:psi, sample}, now), do: %{p | last: sample, at: now}

  def step(p, {:level, n}, now) when is_integer(n) do
    o = p.opts

    held_to = fn threshold ->
      %{file: :level, line: :level, share: n, threshold: o[threshold], at: now}
    end

    checks = [severe: held_to.(:level_severe), high: held_to.(:level_high)]

    {asked, reading} =
      Enum.find(checks, {:ok, nil}, fn {_, r} -> r.share >= r.threshold end)

    judge(%{p | shares: shares(checks)}, asked, reading, now)
  end

  defp shares(checks), do: for({asks, r} <- checks, do: Map.put(r, :asks, asks))

  # Severe at once. Up to `high` once each sample of a whole window asked for it. Down once no
  # sample of a whole window asked for the level or above, to the highest any of them asked:
  # samples that flip between `ok` and `high` take a `severe` level down to `high`.
  defp judge(p, :severe, reading, _now), do: %{p | level: :severe, reading: reading, toward: nil}
  defp judge(%{level: level} = p, level, reading, _now), do: %{p | reading: reading, toward: nil}

  defp judge(p, asked, reading, now) do
    {target, since, kept} =
      case p.toward do
        nil ->
          {asked, now, reading}

        {target, since, kept} ->
          if @rank[asked] >= @rank[target],
            do: {asked, since, reading},
            else: {target, since, kept}
      end

    if now - since >= p.opts[:window],
      do: %{p | level: target, reading: kept, toward: nil},
      else: %{p | toward: {target, since, kept}}
  end

  # One file's line over a span of `span` ms: the share of the span its `total` (µs) grew by,
  # with the threshold it is held to. A line that is missing, or a counter that went back (a
  # reboot), reads 0.
  defp read(last, now_sample, file, line, span, threshold, at) do
    share =
      with %{^line => a} <- Map.get(last, file),
           %{^line => b} <- Map.get(now_sample, file),
           true <- b >= a do
        (b - a) / (span * 1000)
      else
        _ -> 0.0
      end

    %{file: file, line: line, share: share, threshold: threshold, at: at}
  end

  @doc """
  The macOS kernel's memory-pressure level as `sysctl -n kern.memorystatus_vm_pressure_level`
  prints it (`Shell`'s outcome of that run), as a `{:level, read}` source's `read` answers:
  `{:ok, n}` for 1 (normal), 2 (warn) and 4 (critical), the values the kernel reports there, or `{:unknown, reason}` for any other
  value, output or failure, so a reading nobody knows is never taken for `ok`.

      iex> alias CodingAgentFramework.Scheduler.Pressure
      iex> Pressure.sysctl({:ok, %{status: 0, output: "2\\n"}})
      {:ok, 2}
      iex> Pressure.sysctl({:ok, %{status: 0, output: "3\\n"}})
      {:unknown, {:level, "3"}}
  """
  @spec sysctl(term) :: {:ok, 1 | 2 | 4} | {:unknown, term}
  def sysctl({:ok, %{status: 0, output: out}}) do
    case String.trim(out) do
      n when n in ["1", "2", "4"] -> {:ok, String.to_integer(n)}
      other -> {:unknown, {:level, other}}
    end
  end

  def sysctl(other), do: {:unknown, {:sysctl, other}}

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
