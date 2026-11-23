defmodule CodingAgentFramework.Home.Lock do
  @moduledoc """
  A home belongs to one tree at a time (F-215, `model/tla/HomeLock.tla`). Two trees on one home
  would share its `caf.db`, its tmux and dtach sockets, its leases and its tool home, so a tree
  takes the home before it opens anything in it and holds it for its whole life. This is the
  process that holds it: one per tree, with no name but the instance's own, started by
  `CodingAgentFramework.start_link/1` and then the tree's first child, so it stops last.

  **The lock** is SQLite's write lock on `<home>/home.lock`, an empty file of its own, taken by
  an immediate transaction that is never committed (`CodingAgentFramework.Store.hold/1`).
  SQLite takes that lock from the operating system, so:

    * it is one try, which gets the lock or is refused at once, between two takers in one VM
      as between two VMs on one host;
    * the operating system gives it back when the VM that holds it dies, and this process's
      connection is closed when it ends, so a death leaves nothing a person must clear. The
      file stays, and holds nothing.

  **The holder's record.** Right after its take, the holder writes `<home>/home.holder`: its
  instance, its VM's OS pid, its node and when it took the home, one `key value` per line. A
  refused start reads it into `{:refused, {:home_held, holder}}`, a map of those four keys, or
  `:unknown` when there is none to read. The record is written after the take, so a refusal in
  that instant names the one before it, if any. A normal stop removes it; a death leaves it,
  and the next holder writes over it.

      {:ok, lock} = CodingAgentFramework.Home.Lock.take(config)
      {:refused, {:home_held, %{instance: "a", os_pid: "4242", node: "nonode@nohost",
                                taken_at: 1_795_400_000_000}}} =
        CodingAgentFramework.Home.Lock.take(other_config_on_the_same_home)
  """

  use GenServer

  alias CodingAgentFramework.{Config, Store}

  @call 5_000
  @prefix "Elixir.CodingAgentFramework.Home.Lock."

  @doc """
  Takes the home `config` names, for the calling process: starts the holder, which makes the
  home's directory, takes the lock and writes its record. Answers `{:ok, pid}`; `{:refused,
  {:home_held, holder}}` when another tree holds the home, having written nothing;
  `{:refused, {:instance_running, name}}` when a holder of this instance's name still runs in
  this VM; `{:refused, {:sqlite, reason}}` when the lock's file cannot be opened or locked; or
  `{:unknown, reason}` when the directory or the record cannot be written, or the holder did
  not answer (its lock is given back as it ends).

  Until a tree adopts it (`adopt/1`), the holder ends with the calling process.
  """
  @spec take(Config.t()) :: {:ok, pid} | {:refused, term} | {:unknown, term}
  def take(%Config{} = c) do
    case GenServer.start(__MODULE__, {c, self()}, name: name(c.instance), timeout: @call) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:shutdown, {:refused, _} = refused}} -> refused
      {:error, {:shutdown, {:unknown, _} = unknown}} -> unknown
      {:error, {:already_started, _}} -> {:refused, {:instance_running, c.instance}}
      {:error, reason} -> {:unknown, {:home_lock, reason}}
    end
  end

  @doc false
  # The tree's child start for the holder: run in the tree's supervisor, which the holder then
  # ends with. The holder is already running, so a restart of this child finds it gone.
  def adopt(lock) do
    GenServer.call(lock, {:adopt, self()}, @call)
    {:ok, lock}
  catch
    :exit, _ -> {:error, :home_lost}
  end

  @doc """
  Gives the home back: stops the holder, which removes its record and closes the lock's file.
  For a start that took the home and then did not start its tree. Answers `:ok`, also for a
  holder already ended.
  """
  @spec release(pid) :: :ok
  def release(lock) do
    GenServer.stop(lock, :normal, @call)
  catch
    :exit, _ -> :ok
  end

  @doc """
  The holder of the instance named `instance` in this VM, or nil: what a start of the same name
  waits for, as it waits for the instance's `Registry`.
  """
  @spec whereis(String.t()) :: pid | nil
  def whereis(instance) do
    Process.whereis(String.to_existing_atom(@prefix <> instance))
  rescue
    ArgumentError -> nil
  end

  defp name(instance), do: String.to_atom(@prefix <> instance)

  @impl true
  def init({c, starter}) do
    # The tree's exit reaches the holder as a message, so it closes the file before it ends.
    Process.flag(:trap_exit, true)
    lock = Config.path(c, "home.lock")
    record = Config.path(c, "home.holder")

    with :ok <- dir(c.home),
         {:ok, db} <- take(lock, record),
         :ok <- write_record(c, record, db) do
      {:ok, %{db: db, record: record, starter: Process.monitor(starter)}}
    else
      outcome -> {:stop, {:shutdown, outcome}}
    end
  end

  defp dir(home) do
    case File.mkdir_p(home) do
      :ok -> :ok
      {:error, reason} -> {:unknown, {home, reason}}
    end
  end

  defp take(lock, record) do
    case Store.hold(lock) do
      {:ok, db} -> {:ok, db}
      {:refused, :held} -> {:refused, {:home_held, holder(record)}}
      {:refused, _} = refused -> refused
    end
  end

  defp write_record(c, record, db) do
    fields = [
      instance: c.instance,
      os_pid: System.pid(),
      node: Atom.to_string(node()),
      taken_at: System.os_time(:millisecond)
    ]

    text = Enum.map_join(fields, fn {k, v} -> "#{k} #{v}\n" end)
    # Written whole, then renamed into place, so a reader never reads half of it.
    new = "#{record}.#{System.pid()}.new"

    with :ok <- File.write(new, text),
         :ok <- File.rename(new, record) do
      :ok
    else
      {:error, reason} ->
        Store.let_go(db)
        {:unknown, {record, reason}}
    end
  end

  # The record as the holder wrote it, or :unknown.
  defp holder(record) do
    with {:ok, text} <- File.read(record),
         %{instance: _, os_pid: _, node: _, taken_at: at} = fields <- parse(text),
         {at, ""} <- Integer.parse(at) do
      %{fields | taken_at: at}
    else
      _ -> :unknown
    end
  end

  defp parse(text) do
    for line <- String.split(text, "\n", trim: true),
        [key, value] <- [String.split(line, " ", parts: 2)],
        key in ~w(instance os_pid node taken_at),
        into: %{},
        do: {String.to_existing_atom(key), value}
  end

  @impl true
  def handle_call({:adopt, tree}, _from, s) do
    Process.demonitor(s.starter, [:flush])
    Process.link(tree)
    {:reply, :ok, %{s | starter: nil}}
  end

  @impl true
  # The start that took the home ended before a tree adopted it.
  def handle_info({:DOWN, ref, :process, _, _}, %{starter: ref} = s), do: {:stop, :normal, s}
  # The tree ended: its shutdown, or its death.
  def handle_info({:EXIT, _tree, _reason}, s), do: {:stop, :shutdown, s}
  def handle_info(_other, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    # The record first, while the home is still held, so it never names a later holder.
    File.rm(s.record)
    Store.let_go(s.db)
  end
end
