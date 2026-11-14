defmodule CodingAgentFramework.Registry.Liveness do
  @moduledoc """
  Whether the processes session files name still run, by pid and process start time, with one
  `ps` on the host.

  Claude Code records `procStart` as `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`, trimmed; this asks
  `ps` the same way. A process is never found by its name. Each pid is:

    * `:live`: `ps` lists it, with the start time the file records;
    * `:replaced`: `ps` lists it with another start time, so the pid was reused;
    * `:gone`: a `ps` that ran cleanly does not list it;
    * `:unknown`: `ps` failed, timed out or answered something unreadable, or the file records
      no start time. A failed `ps` under load never counts a live process as gone.

      iex> CodingAgentFramework.Registry.Liveness.judge(
      ...>   {:ok, %{status: 0, output: "  7 Sat Nov 14 09:00:00 2026\\n  9 Sat Nov 14 09:00:00 2026\\n"}},
      ...>   [{7, "Sat Nov 14 09:00:00 2026"}, {8, "Sat Nov 14 09:00:00 2026"}, {9, nil}])
      %{{7, "Sat Nov 14 09:00:00 2026"} => :live, {8, "Sat Nov 14 09:00:00 2026"} => :gone, {9, nil} => :unknown}
  """

  alias CodingAgentFramework.{Host, Shell}

  @type t :: :live | :replaced | :gone | :unknown

  @doc """
  Checks `[{pid, proc_start}]` on `host`, and answers each pair's liveness. A pid can appear with
  several start times (an old file and a new one). Options, all required: `:env` and `:ps` (the
  host's programs; `ps` runs under `env LC_ALL=C TZ=UTC`, the same command on any host) and
  `:timeout` (ms).
  """
  @spec check(Host.t(), [{pos_integer, String.t() | nil}], keyword) :: %{
          {pos_integer, String.t() | nil} => t
        }
  def check(_host, [], _opts), do: %{}

  def check(%Host{} = host, procs, opts) do
    pids = procs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(",")

    ps = Keyword.fetch!(opts, :ps)
    args = ["LC_ALL=C", "TZ=UTC", ps, "-o", "pid=,lstart=", "-p", pids]

    host
    |> Shell.run(Keyword.fetch!(opts, :env), args, timeout: Keyword.fetch!(opts, :timeout))
    |> judge(procs)
  end

  @doc "Judges each `{pid, proc_start}` from a `Shell` outcome of the `ps` that `check/3` runs. Pure."
  @spec judge(Shell.outcome(), [{pos_integer, String.t() | nil}]) :: %{
          {pos_integer, String.t() | nil} => t
        }
  def judge(outcome, procs) do
    listed =
      case outcome do
        {:ok, %{status: 0, output: out}} -> listed(out)
        # ps exits 1 with no output when none of the pids exists.
        {:ok, %{status: 1, output: ""}} -> {:ok, %{}}
        _ -> :unknown
      end

    Map.new(procs, fn {pid, start} -> {{pid, start}, judge_one(listed, pid, start)} end)
  end

  defp judge_one(:unknown, _, _), do: :unknown
  defp judge_one({:ok, listed}, pid, start), do: judge_one(Map.get(listed, pid), start)

  defp judge_one(nil, _), do: :gone
  defp judge_one(_, nil), do: :unknown
  defp judge_one(start, start), do: :live
  defp judge_one(_, _), do: :replaced

  defp listed(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      with [pid, start] <- String.split(String.trim(line), ~r/\s+/, parts: 2),
           {pid, ""} <- Integer.parse(pid) do
        {:cont, {:ok, Map.put(acc, pid, String.trim(start))}}
      else
        _ -> {:halt, :unknown}
      end
    end)
  end
end
