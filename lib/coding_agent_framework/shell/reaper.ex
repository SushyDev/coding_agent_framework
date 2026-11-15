defmodule CodingAgentFramework.Shell.Reaper do
  @moduledoc """
  Ends a `CodingAgentFramework.Shell` command's process group when the process that ran it dies
  first, or when the VM dies (see `model/tla/Shell.tla`). It is one process per host, with no
  name, started by the host app's supervision tree; `Shell.run/4` uses it when given it as
  `:reaper`.

  While a command runs, the reaper holds its group with its owner, the process in `Shell.run/4`,
  and monitors the owner. When the owner dies before the command ends, the reaper sends TERM to
  the group, then KILL half a second later, with this machine's `kill`. `Shell` drops the group
  once it has taken the command's exit or sent its own KILL, so the reaper never aims at an
  ended command's id.

  For the VM's death the reaper keeps one watcher: this machine's `sh`, reading a line from the
  reaper for each group it holds and each it drops, blocked in `read` between them. When the VM
  dies its stdin closes, and it sends TERM to every group it still holds, waits half a second
  with this machine's `sleep`, and sends KILL. The reaper's own death closes the same pipe, so it
  ends the groups it holds too.

      {:ok, programs} = CodingAgentFramework.Programs.find(host, [:sh, :sleep, :kill])
      {:ok, reaper} = CodingAgentFramework.Shell.Reaper.start_link(programs: programs)
      CodingAgentFramework.Shell.run(host, "/run/bin/git", ["status"], timeout: 5_000, reaper: reaper)
  """

  use GenServer

  alias CodingAgentFramework.{Programs, Shell}

  @grace 500
  # $1 is sleep. h is the groups held, as " id id …"; a drop rebuilds it, so it stays as long
  # as the commands that run at once. The sh's own messages, such as kill's for a group gone,
  # go to /dev/null.
  @watcher ~S"""
  g=$1; h=
  exec 2>/dev/null
  while read -r l; do
    case $l in
      +*) h="$h ${l#+}" ;;
      -*) n=; for p in $h; do [ "$p" = "${l#-}" ] || n="$n $p"; done; h=$n ;;
    esac
  done
  [ -n "$h" ] || exit 0
  for p in $h; do kill -s TERM -- "-$p"; done
  "$g" 0.5
  for p in $h; do kill -s KILL -- "-$p"; done
  """

  @doc """
  Starts the reaper and its watcher. Options: `:programs`, this machine's
  `CodingAgentFramework.Programs` with `sh`, `sleep` and `kill`. Takes no name.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :programs))

  @doc "The watcher's script, for `sh -c`. Pure."
  @spec watcher() :: String.t()
  def watcher, do: @watcher

  @doc """
  Holds the group `pgid` for the calling process, which runs its command. Answers at once.
  """
  @spec hold(GenServer.server(), pos_integer) :: :ok
  def hold(reaper, pgid), do: GenServer.cast(reaper, {:hold, pgid, self()})

  @doc "Drops the group `pgid`: its command has ended. Answers at once."
  @spec drop(GenServer.server(), pos_integer) :: :ok
  def drop(reaper, pgid), do: GenServer.cast(reaper, {:drop, pgid})

  @doc "The groups held, as `%{pgid => owner}`."
  @spec held(GenServer.server()) :: %{pos_integer => pid}
  def held(reaper), do: GenServer.call(reaper, :held, 5_000)

  @impl true
  def init(%Programs{} = programs) do
    case Programs.take(programs, [:sh, :sleep, :kill]) do
      {:ok, %{sh: sh, sleep: sleep, kill: kill}} ->
        port =
          Port.open({:spawn_executable, sh}, [
            :binary,
            :exit_status,
            args: ["-c", @watcher, "watcher", sleep]
          ])

        {:ok, %{port: port, kill: kill, groups: %{}}}

      refused ->
        {:stop, refused}
    end
  end

  @impl true
  def handle_cast({:hold, pgid, owner}, s) do
    ref = Process.monitor(owner)
    Port.command(s.port, "+#{pgid}\n")
    {:noreply, put_in(s.groups[pgid], {owner, ref})}
  end

  def handle_cast({:drop, pgid}, s) do
    case Map.pop(s.groups, pgid) do
      {{_owner, ref}, groups} ->
        Process.demonitor(ref, [:flush])
        Port.command(s.port, "-#{pgid}\n")
        {:noreply, %{s | groups: groups}}

      {nil, _} ->
        {:noreply, s}
    end
  end

  @impl true
  def handle_call(:held, _from, s),
    do: {:reply, Map.new(s.groups, fn {pgid, {owner, _}} -> {pgid, owner} end), s}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Enum.find(s.groups, fn {_, {_, r}} -> r == ref end) do
      {pgid, _} ->
        Shell.signal(s.kill, "TERM", pgid)
        Process.send_after(self(), {:kill, pgid}, @grace)
        {:noreply, s}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info({:kill, pgid}, s) do
    Shell.signal(s.kill, "KILL", pgid)
    Port.command(s.port, "-#{pgid}\n")
    {:noreply, %{s | groups: Map.delete(s.groups, pgid)}}
  end

  # Without its watcher the reaper cannot keep its promise for the VM's death: it stops, and
  # its supervisor decides.
  def handle_info({port, {:exit_status, status}}, %{port: port} = s),
    do: {:stop, {:watcher_exited, status}, s}

  def handle_info({port, {:data, _}}, %{port: port} = s), do: {:noreply, s}
end
