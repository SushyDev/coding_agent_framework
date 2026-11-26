defmodule CodingAgentFramework.HomeTest do
  # F-214: a home keeps its kind. Each test has homes of its own, and trees under them with their
  # own tmux servers, ports and instance names. A refused start answers before any part starts, so
  # the test reads the home before and after it and finds it the same.
  use ExUnit.Case, async: true

  doctest CodingAgentFramework.Home

  import CodingAgentFramework.TestHost

  alias CodingAgentFramework.{Config, Delegates, HeadlessStandIn, Home, Sessions, Store, Tmux}

  setup do
    %{dir: test_dir()}
  end

  # The config of a tree with agents on `home`.
  defp agents_config(dir, home) do
    {:ok, c} =
      Config.new(
        home: home,
        instance: name("full"),
        programs: programs().paths,
        accounts: ["work"],
        ports: %{intake: free_port(), mcp: free_port()},
        claude: HeadlessStandIn.write!(dir, :on_message),
        env: %{home: dir, path: "/nonexistent", term: "xterm-256color", lang: "C.UTF-8"},
        user: "tester",
        interval: 200,
        undeclared_cues: :raise
      )

    c
  end

  # A tree with agents that can start: its tmux server is the test's own, ended with it.
  defp agentful(dir, home) do
    c = agents_config(dir, home)
    File.mkdir_p!(home)
    {:ok, server} = CodingAgentFramework.server(c)
    on_exit(fn -> Tmux.kill_server(server) end)
    c
  end

  # A tree without agents: no gh, ssh or ssh-keygen, which it makes no tool home for (F-201).
  defp agentless(home) do
    programs = Map.drop(programs().paths, [:gh, :ssh, :ssh_keygen])

    {:ok, c} =
      Config.new(
        home: home,
        instance: name("less"),
        programs: programs,
        env: %{path: "/nonexistent"},
        agents: false,
        interval: 200
      )

    c
  end

  # The instance names are this test's own, so another test's trees in this VM never meet them.
  defp name(label), do: "home-#{label}-#{System.unique_integer([:positive])}"

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start(c), do: start_supervised!({CodingAgentFramework, c})
  defp stop(c), do: stop_supervised!({CodingAgentFramework, c.instance})

  defp db(c), do: Path.join(c.home, "caf.db")

  # Every row of every table of the home's database, and every file under the home but SQLite's
  # own journal files, which come and go with a connection.
  defp state(c) do
    {:ok, counts} =
      Store.snapshot(db(c), fn db, tables ->
        for table <- tables, into: %{} do
          {table, db |> Store.query("SELECT count(*) FROM #{table}", []) |> hd() |> hd()}
        end
      end)

    files = Path.wildcard(Path.join(c.home, "**"), match_dot: true)
    {counts, Enum.reject(files, &String.ends_with?(&1, ["-wal", "-shm"]))}
  end

  # The mark as the database holds it, none before a tree has started.
  defp mark(c) do
    {:ok, rows} =
      Store.read_only(db(c), "home", [], &Store.select(&1, "home", [:id, :kind], "1 = 1", []))

    rows
  end

  test "a new home takes the kind of its first tree", ctx do
    full = agentful(ctx.dir, Path.join(ctx.dir, "a"))
    less = agentless(Path.join(ctx.dir, "b"))

    # Neither home has a database yet: reading its kind makes none.
    assert CodingAgentFramework.home_kind(full) == {:ok, :new}
    assert CodingAgentFramework.home_kind(less) == {:ok, :new}
    refute File.exists?(db(full))
    refute File.exists?(db(less))

    start(full)
    start(less)
    assert CodingAgentFramework.home_kind(full) == {:ok, :agents}
    assert CodingAgentFramework.home_kind(less) == {:ok, :agentless}
    assert mark(full) == [%{id: 1, kind: "agents"}]
    assert mark(less) == [%{id: 1, kind: "agentless"}]
  end

  for kind <- [:agents, :agentless] do
    test "a home marked #{kind} refuses a tree of the other kind and accepts its own", ctx do
      home = Path.join(ctx.dir, "home")
      {full, less} = {agentful(ctx.dir, home), agentless(home)}
      {own, other} = if unquote(kind) == :agents, do: {full, less}, else: {less, full}

      start(own)
      stop(own)
      before = state(own)

      # Nothing starts and nothing is written: the same rows and files after the refusal, and
      # no instance of either name.
      assert CodingAgentFramework.start_link(other) == {:refused, {:home_kind, unquote(kind)}}
      assert state(own) == before
      assert CodingAgentFramework.agent_rows(other.instance) == {:refused, :no_instance}
      assert CodingAgentFramework.home_kind(other) == {:ok, unquote(kind)}

      # Its own kind goes on, as often as it starts.
      start(own)
      assert CodingAgentFramework.home_kind(own) == {:ok, unquote(kind)}
      assert mark(own) == [%{id: 1, kind: Atom.to_string(unquote(kind))}]
    end
  end

  # What a home that ran before the mark held: an agent row (a main session is one), or a
  # delegate row, and no `home` table.
  defp ran_before(:agent, c) do
    {:ok, db} = Sessions.Table.open(db(c))
    Sessions.Table.declare(db, "ws", "app-main", "app")
  end

  defp ran_before(:delegate, c) do
    {:ok, db} = Delegates.Table.open(db(c))
    row = %{host: "ws", name: "app-unit-one", branch: "unit/one", model: "opus"}
    Delegates.Table.starting(db, Map.merge(row, %{brief_uuid: "b1", deadline: 0}))
  end

  for row <- [:agent, :delegate] do
    test "an unmarked home that holds a #{row} row is marked agents", ctx do
      home = Path.join(ctx.dir, "home")
      {full, less} = {agentful(ctx.dir, home), agentless(home)}
      ran_before(unquote(row), less)
      assert mark(less) == []

      # Read as the next start would find it, with no mark written by the read.
      assert CodingAgentFramework.home_kind(less) == {:ok, :agents}
      assert mark(less) == []

      # The first start after the mark came is the one that writes it, a refused one too.
      assert CodingAgentFramework.start_link(less) == {:refused, {:home_kind, :agents}}
      assert mark(less) == [%{id: 1, kind: "agents"}]

      start(full)
      assert CodingAgentFramework.home_kind(less) == {:ok, :agents}
    end
  end

  test "tables with no row in them do not make a home agentful", ctx do
    # A home whose tables were made and hold nothing: no tree of either kind left a row.
    less = agentless(Path.join(ctx.dir, "home"))
    File.mkdir_p!(less.home)
    {:ok, _} = Sessions.Table.open(db(less))
    {:ok, _} = Delegates.Table.open(db(less))

    assert CodingAgentFramework.home_kind(less) == {:ok, :new}
    start(less)
    assert CodingAgentFramework.home_kind(less) == {:ok, :agentless}
  end

  test "home_kind/1 starts no process, makes no file and refuses a database it cannot read",
       ctx do
    less = agentless(Path.join(ctx.dir, "home"))
    start(less)
    stop(less)
    links = Process.info(self(), :links)

    assert CodingAgentFramework.home_kind(less) == {:ok, :agentless}
    assert CodingAgentFramework.agent_rows(less.instance) == {:refused, :no_instance}
    assert Process.info(self(), :links) == links

    # A home with no database: its kind is new, and asking makes nothing.
    new = agentless(Path.join(ctx.dir, "new"))
    assert CodingAgentFramework.home_kind(new) == {:ok, :new}
    refute File.exists?(new.home)

    # A file that is no database: the kind is not known, and a start is refused, not crashed.
    # It is a home no tree ran on. A stopped tree's connections close when the VM frees their
    # processes, which can come after the stop returns (F-272); the last one's close writes its
    # WAL into the file, so a file it had open reads "malformed" instead of refusing the open.
    broken = agentless(Path.join(ctx.dir, "broken"))
    File.mkdir_p!(broken.home)
    File.write!(db(broken), String.duplicate("not a database ", 20))
    assert {:refused, {:home_mark, _}} = CodingAgentFramework.home_kind(broken)
    assert {:refused, {:sqlite, _}} = CodingAgentFramework.start_link(broken)
  end

  # Two trees of different kinds start at once on a home no tree has started on: the write lock
  # of SQLite decides, so one of them is told the kind the other one recorded.
  test "two first starts of different kinds on one new home leave one refused", ctx do
    for n <- 1..25 do
      home = Path.join(ctx.dir, "race-#{n}")
      File.mkdir_p!(home)
      {full, less} = {agents_config(ctx.dir, home), agentless(home)}

      tasks =
        for c <- [full, less] do
          Task.async(fn ->
            receive do
              :go -> Home.mark(c)
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))

      # At most one kind wins, and the other is told which: SQLite's lock may also refuse a
      # first open that came at the same instant (`Store.open/3` has no retry), and then that
      # start did not go on. Never both.
      case Task.await_many(tasks) do
        [:ok, {:refused, {:home_kind, :agents}}] ->
          assert CodingAgentFramework.home_kind(full) == {:ok, :agents}

        [{:refused, {:home_kind, :agentless}}, :ok] ->
          assert CodingAgentFramework.home_kind(full) == {:ok, :agentless}

        [:ok, {:refused, {:sqlite, _}}] ->
          assert CodingAgentFramework.home_kind(full) == {:ok, :agents}

        [{:refused, {:sqlite, _}}, :ok] ->
          assert CodingAgentFramework.home_kind(full) == {:ok, :agentless}

        [{:refused, {:sqlite, _}}, {:refused, {:sqlite, _}}] ->
          :neither

        other ->
          flunk("at most one of the two starts goes on, got #{inspect(other)}")
      end
    end
  end
end
