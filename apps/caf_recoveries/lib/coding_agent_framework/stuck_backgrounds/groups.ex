defmodule CodingAgentFramework.StuckBackgrounds.Groups do
  @moduledoc """
  The process groups a delegate's process started, with the CPU time each used, read on its
  host from `/proc` (`docs/design.md`, "Metrics and healing"; F-184).

  Claude Code 2.1.322 spawns each shell command `detached`, so a background command leads a
  process group of its own, a descendant of the delegate's process (read from the bundle of
  the pinned release; no event names its pid). A group here is one led by a descendant of the
  delegate's process, other than the delegate's own group: its record is the leader's pid and
  start time (as `ps -o lstart=` prints it, `Holder.Process`' record), and its CPU time is the
  sum of `utime`, `stime`, `cutime` and `cstime` of its members, in clock ticks.

  It is read in one shell on the host: every `/proc/<pid>/stat`, then `ps` of every process's
  start time. A host with no `/proc` (macOS) answers `{:unknown, :no_proc}`, so no command of
  it is ever read as stuck.

      iex> alias CodingAgentFramework.StuckBackgrounds.Groups
      iex> stat = "7 (claude) S 1 7 7 0 -1 0 0 0 0 0 30 4 0 0 20 0 1 0 900 0\\n" <>
      ...>   "9 (bash) S 7 9 9 0 -1 0 0 0 0 0 1 1 2 0 20 0 1 0 950 0\\n" <>
      ...>   "10 (sleep) S 9 9 9 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 951 0\\n"
      iex> ps = "  7 Sat Nov 21 09:00:00 2026\\n  9 Sat Nov 21 09:01:00 2026\\n"
      iex> Groups.parse(stat <> "--\\n" <> ps, %{pid: 7, start: "Sat Nov 21 09:00:00 2026"})
      {:ok, [%{pid: 9, start: "Sat Nov 21 09:01:00 2026", cpu: 4}]}
  """

  alias CodingAgentFramework.{Holder, Shell}

  @type group :: %{pid: pos_integer, start: String.t(), cpu: non_neg_integer}

  # $1 ps. Each stat file in one read; a process gone between the list and the read is skipped.
  @read ~S"""
  [ -r /proc/self/stat ] || { echo no-proc; exit 0; }
  for f in /proc/[0-9]*/stat; do { read -r l < "$f"; } 2>/dev/null && printf '%s\n' "$l"; done
  echo --
  LC_ALL=C TZ=UTC "$1" -A -o pid=,lstart=
  """

  @doc """
  Reads the groups of the process with `record`'s pid and start time on `procs`' host. Answers
  `{:ok, groups}` (none when that process is gone or another one has its pid), or `{:unknown,
  reason}`: `:no_proc` on a host with no `/proc`, or a read that failed.
  """
  @spec read(Holder.Process.t(), Holder.Process.held(), keyword) ::
          {:ok, [group]} | {:unknown, term}
  def read(%Holder.Process{holder: h} = procs, record, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, h.timeout)

    case Shell.run(h.host, h.sh, ["-c", @read, "caf-groups", procs.ps], timeout: timeout) do
      {:ok, %{status: 0, output: out}} -> parse(out, record)
      other -> {:unknown, {:read, other}}
    end
  end

  @doc "Parses what `read/3`'s shell printed, for the delegate's `record`. Pure."
  @spec parse(String.t(), Holder.Process.held()) :: {:ok, [group]} | {:unknown, term}
  def parse("no-proc\n", _record), do: {:unknown, :no_proc}

  def parse(out, %{pid: pid, start: start}) do
    with [stat, ps] <- String.split(out, "--\n", parts: 2),
         {:ok, starts} <- starts(ps) do
      procs = stat |> String.split("\n", trim: true) |> Enum.flat_map(&stat_line/1)
      by_pid = Map.new(procs, &{&1.pid, &1})

      case by_pid[pid] do
        %{pgrp: own} when is_map_key(starts, pid) ->
          if starts[pid] == Holder.Process.normal(start),
            do: {:ok, groups(procs, by_pid, starts, pid, own)},
            else: {:ok, []}

        _gone ->
          {:ok, []}
      end
    else
      _ -> {:unknown, {:unreadable, out}}
    end
  end

  defp groups(procs, by_pid, starts, pid, own) do
    leaders =
      for p <- procs, p.pgrp == p.pid, p.pgrp != own, descends?(by_pid, p.pid, pid, 64), do: p

    for l <- Enum.sort_by(leaders, & &1.pid), is_map_key(starts, l.pid) do
      cpu = procs |> Enum.filter(&(&1.pgrp == l.pid)) |> Enum.map(& &1.cpu) |> Enum.sum()
      %{pid: l.pid, start: starts[l.pid], cpu: cpu}
    end
  end

  # Up its parents to the delegate's process; a bounded walk, since a read is not atomic.
  defp descends?(_by_pid, _p, _root, 0), do: false

  defp descends?(by_pid, p, root, n) do
    case by_pid[p] do
      %{ppid: ^root} -> true
      %{ppid: parent} when parent > 1 -> descends?(by_pid, parent, root, n - 1)
      _ -> false
    end
  end

  # `pid (comm) state ppid pgrp …`: the name may hold spaces and parentheses, so the fields are
  # read after its last `)`.
  defp stat_line(line) do
    with [head, rest] <- split_last(line),
         {pid, ""} <- Integer.parse(String.trim(String.trim_trailing(head))),
         [_state, ppid, pgrp | more] <- String.split(rest),
         [ut, st, cut, cst | _] <- Enum.drop(more, 8),
         nums when length(nums) == 6 <- ints([ppid, pgrp, ut, st, cut, cst]) do
      [ppid, pgrp | ticks] = nums
      [%{pid: pid, ppid: ppid, pgrp: pgrp, cpu: Enum.sum(ticks)}]
    else
      _ -> []
    end
  end

  defp split_last(line) do
    case :binary.matches(line, ")") do
      [] ->
        :none

      matches ->
        {at, 1} = List.last(matches)

        [
          hd(String.split(binary_part(line, 0, at), " (", parts: 2)),
          binary_part(line, at + 1, byte_size(line) - at - 1)
        ]
    end
  end

  defp ints(words) do
    for w <- words, {n, ""} <- [Integer.parse(w)], do: n
  end

  defp starts(ps) do
    ps
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      with [pid, start] <- String.split(String.trim(line), ~r/\s+/, parts: 2),
           {pid, ""} <- Integer.parse(pid) do
        {:cont, {:ok, Map.put(acc, pid, Holder.Process.normal(start))}}
      else
        _ -> {:halt, :unreadable}
      end
    end)
  end
end
